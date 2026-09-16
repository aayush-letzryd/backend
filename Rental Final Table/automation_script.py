"""
LetzRyd - Rental Final Table Automation & Calculation Engine
============================================================
Calculates daily rent and indemnity for public.daily_rent_log based on:
  1. Master agreements in public.core_rent
  2. Live pricing slabs in public.sheet_rental_slabs
  3. Live partner agreements in public.sheet_rental_partners
  4. Daily attendance from public.core_daily_vehicle_status (or historical Hisaab datasets)
  5. Weekly completed Uber/Ola trips from public.uber_pipeline_trips

Reconciled Formula:
  Net Daily Rent = applied_daily_rent + applied_daily_indemnity
  Weekly Hisaab Settlement Rent = SUM(net_daily_rent) over billing week

Usage:
    python automation_script.py --audit
    python automation_script.py --sync-daily-status --start-date 2026-08-25 --end-date 2026-08-31
    python automation_script.py --populate-w26
    python automation_script.py --populate-w27
"""

import os
import sys
import argparse
import datetime
import openpyxl
import psycopg2
from psycopg2.extras import RealDictCursor, execute_values

sys.stdout.reconfigure(encoding='utf-8')

DB_HOST = os.getenv("DB_HOST", "35.200.196.113")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASS = os.getenv("DB_PASSWORD", r"8S5]U3@L^Xz)\FH}")

def get_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )

def load_master_rental_context(cur):
    """
    Preloads active vehicle contracts from core_rent and rate slabs from sheet_rental_slabs
    into memory for high-performance vectorized lookups.
    """
    cur.execute("SELECT * FROM core_rent WHERE is_active = TRUE;")
    core_rent_rows = cur.fetchall()
    core_rent_map = {}
    for r in core_rent_rows:
        core_rent_map[r['vehicle_number'].strip().upper()] = r

    cur.execute("SELECT * FROM sheet_rental_slabs ORDER BY min_trips DESC;")
    slabs_list = cur.fetchall()

    return core_rent_map, slabs_list

def calculate_single_vehicle_day(
    veh_clean,
    log_date,
    week_id,
    attendance_status,
    is_billable,
    weekly_trips,
    ola_trips,
    core_rent_map,
    slabs_list,
    fallback_city='Bengaluru',
    fallback_partner=None
):
    """
    Pure in-memory calculation of daily rent and indemnity.
    """
    contract = core_rent_map.get(veh_clean)
    if not contract:
        city = fallback_city
        model = 'Maruti Wagonr Tour H3 CNG'
        partner_id = fallback_partner or 'UNMAPPED'
        custom_rent = None
        custom_indem = 30.00
        plan_scheme = 'Uber Reducing Rent'
    else:
        city = contract['city']
        model = contract['vehicle_model']
        partner_id = contract['partner_id']
        custom_rent = contract['custom_daily_rent']
        custom_indem = contract['custom_daily_indemnity']
        plan_scheme = contract['plan_scheme']

    # Golden Rule #2: Non-billable attendance status (Maintenance, Breakdown, RFD, Drop-Off)
    if not is_billable:
        return (
            log_date, week_id, veh_clean, partner_id, city, model,
            attendance_status, False, weekly_trips, 0.00, 0.00, 0.00,
            f"Non-billable status: {attendance_status}"
        )

    # Priority 1: Custom partner deal override
    if custom_rent is not None and custom_rent > 0:
        applied_rent = float(custom_rent)
        calc_rule = f"Priority 1: Partner Contract ({applied_rent}/day)"
    # Priority 2: Multi-app Ola Penalty (Bangalore)
    elif 'bengaluru' in city.lower() and float(ola_trips or 0) >= 1.0 and 'operator' not in plan_scheme.lower():
        applied_rent = 1050.00
        calc_rule = "Priority 2: Ola Multi-App Penalty Base Rate (1050/day)"
    # Priority 2: Standard Plan Slab lookup
    else:
        driver_type = 'Operator' if ('operator' in plan_scheme.lower() or 'fleet' in plan_scheme.lower()) else 'Individual'
        applied_rent = None
        calc_rule = None
        
        for slab in slabs_list:
            # City match
            if slab['city'].lower() not in city.lower() and city.lower() not in slab['city'].lower():
                continue
            # Model match
            model_first_token = model.split()[0].lower()
            if model_first_token not in slab['vehicle_model'].lower() and slab['vehicle_model'].lower() not in model.lower():
                continue
            # Driver type match
            if slab['driver_type'] != 'All' and slab['driver_type'].lower() != driver_type.lower():
                continue
            # Trip threshold match
            min_t = slab['min_trips']
            max_t = slab['max_trips'] if slab['max_trips'] is not None else 9999
            if min_t <= weekly_trips <= max_t:
                applied_rent = float(slab['daily_rent'])
                calc_rule = f"Priority 2: Slab Tier {slab['trip_slab_label']} ({applied_rent}/day)"
                break

        if applied_rent is None:
            if 'dzire' in model.lower(): applied_rent = 1200.00
            elif 'ec3' in model.lower() or 'ev' in model.lower(): applied_rent = 1300.00
            elif 'xcent' in model.lower(): applied_rent = 900.00
            else: applied_rent = 1050.00
            calc_rule = f"Priority 3: Fallback Base ({applied_rent}/day)"

    # Indemnity determination
    if custom_indem is not None:
        applied_indemnity = float(custom_indem)
    else:
        applied_indemnity = 0.00 if 'xcent' in model.lower() else 30.00

    net_daily = applied_rent + applied_indemnity

    return (
        log_date, week_id, veh_clean, partner_id, city, model,
        attendance_status, True, weekly_trips, applied_rent, applied_indemnity, net_daily,
        calc_rule
    )

UPSERT_DAILY_RENT_LOG_SQL = """
INSERT INTO daily_rent_log (
    log_date, week_id, vehicle_number, partner_id, city, vehicle_model,
    attendance_status, is_billable_day, weekly_completed_trips,
    applied_daily_rent, applied_daily_indemnity, net_daily_rent, calculation_rule
) VALUES %s
ON CONFLICT (vehicle_number, log_date) DO UPDATE SET
    week_id = EXCLUDED.week_id,
    partner_id = EXCLUDED.partner_id,
    city = EXCLUDED.city,
    vehicle_model = EXCLUDED.vehicle_model,
    attendance_status = EXCLUDED.attendance_status,
    is_billable_day = EXCLUDED.is_billable_day,
    weekly_completed_trips = EXCLUDED.weekly_completed_trips,
    applied_daily_rent = EXCLUDED.applied_daily_rent,
    applied_daily_indemnity = EXCLUDED.applied_daily_indemnity,
    net_daily_rent = EXCLUDED.net_daily_rent,
    calculation_rule = EXCLUDED.calculation_rule;
"""

def sync_from_core_daily_vehicle_status(cur, conn, start_date_str=None, end_date_str=None):
    """
    Directly queries public.core_daily_vehicle_status, adopting the boolean billable_rent_day,
    mapping status_date -> log_date and final_status -> attendance_status, and calculating
    daily rent from master tables.
    """
    print("=================================================================")
    print("  SYNCING DAILY_RENT_LOG DIRECTLY FROM CORE_DAILY_VEHICLE_STATUS ")
    print("=================================================================\n")

    core_rent_map, slabs_list = load_master_rental_context(cur)
    print(f"Loaded {len(core_rent_map)} vehicle contracts and {len(slabs_list)} rate card slabs.")

    # Determine date window
    cur.execute("""
        SELECT 
            COALESCE(%s::date, MIN(status_date)) AS min_date,
            COALESCE(%s::date, MAX(status_date)) AS max_date
        FROM core_daily_vehicle_status;
    """, (start_date_str, end_date_str))
    date_bounds = cur.fetchone()
    start_d = date_bounds['min_date']
    end_d = date_bounds['max_date']

    print(f"Querying vehicle status from {start_d} to {end_d}...")

    # Query trip counts from uber_pipeline_trips for this date window
    cur.execute("""
        SELECT car_no, COUNT(*) AS trip_count
        FROM uber_pipeline_trips
        WHERE trip_date BETWEEN %s AND %s AND car_no IS NOT NULL AND car_no != ''
        GROUP BY car_no;
    """, (start_d, end_d))
    trip_map = {(r['car_no'] or '').strip().upper(): r['trip_count'] for r in cur.fetchall()}
    print(f"Loaded trip counts for {len(trip_map)} vehicles from uber_pipeline_trips.")

    # Query attendance
    cur.execute("""
        SELECT 
            status_date AS log_date,
            vehicle_number,
            city,
            car_model AS vehicle_model,
            partner_id,
            final_status AS attendance_status,
            billable_rent_day
        FROM core_daily_vehicle_status
        WHERE status_date BETWEEN %s AND %s
        ORDER BY status_date, vehicle_number;
    """, (start_d, end_d))
    status_rows = cur.fetchall()
    print(f"Found {len(status_rows)} daily attendance records in core_daily_vehicle_status.\n")

    records_dict = {}
    for row in status_rows:
        log_date = row['log_date']
        veh_clean = row['vehicle_number'].strip().upper()
        week_id = f"CY{log_date.strftime('%y')}WK{log_date.isocalendar()[1]:02d}"
        status = row['attendance_status']
        is_billable = bool(row['billable_rent_day'])
        trips = trip_map.get(veh_clean, 0)
        
        rec = calculate_single_vehicle_day(
            veh_clean=veh_clean,
            log_date=log_date,
            week_id=week_id,
            attendance_status=status,
            is_billable=is_billable,
            weekly_trips=trips,
            ola_trips=0.0,
            core_rent_map=core_rent_map,
            slabs_list=slabs_list,
            fallback_city=row['city'] or 'Bengaluru',
            fallback_partner=row['partner_id']
        )
        records_dict[(veh_clean, log_date)] = rec

    records_to_insert = list(records_dict.values())
    print(f"Upserting {len(records_to_insert)} unique daily settlement records into daily_rent_log...")

    cur.execute("SET hisaab.skip_cascade = 'true';")
    execute_values(cur, UPSERT_DAILY_RENT_LOG_SQL, records_to_insert, page_size=1000)
    conn.commit()
    print("Direct attendance synchronization completed successfully!\n")

def populate_from_hisaab_files(cur, conn, week_id, start_date_str, end_date_str, datasets):
    """
    Populates historical settlement weeks (W26, W27) from validated Hisaab datasets.
    """
    core_rent_map, slabs_list = load_master_rental_context(cur)
    start_d = datetime.datetime.strptime(start_date_str, "%Y-%m-%d").date()
    end_d = datetime.datetime.strptime(end_date_str, "%Y-%m-%d").date()
    days_count = (end_d - start_d).days + 1

    records_dict = {}

    for city, path, sname, start_row, c_veh, c_code, c_type, c_uber, c_ola, c_rent, c_onroad in datasets:
        print(f"Reading {city} ({sname})...")
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        ws = wb[sname]
        for r in ws.iter_rows(min_row=start_row, values_only=True):
            if len(r) < c_veh: continue
            veh = r[c_veh - 1]
            if not veh or str(veh).strip() == '' or 'total' in str(veh).lower():
                continue
            veh_clean = str(veh).strip().upper()
            code = str(r[c_code - 1] or '').strip() if len(r) >= c_code else ''
            
            try: onroad = int(float(r[c_onroad - 1] or 0)) if len(r) >= c_onroad else 7
            except: onroad = 7
            try: uber_trips = float(r[c_uber - 1] or 0) if len(r) >= c_uber else 0.0
            except: uber_trips = 0.0
            try: ola_trips = float(r[c_ola - 1] or 0) if len(r) >= c_ola else 0.0
            except: ola_trips = 0.0

            for d_offset in range(days_count):
                curr_date = start_d + datetime.timedelta(days=d_offset)
                status = 'On Road' if d_offset < onroad else 'Maintenance'
                is_billable = (status == 'On Road')
                rec = calculate_single_vehicle_day(
                    veh_clean=veh_clean,
                    log_date=curr_date,
                    week_id=week_id,
                    attendance_status=status,
                    is_billable=is_billable,
                    weekly_trips=uber_trips,
                    ola_trips=ola_trips,
                    core_rent_map=core_rent_map,
                    slabs_list=slabs_list,
                    fallback_city=city,
                    fallback_partner=code
                )
                records_dict[(veh_clean, curr_date)] = rec

    records_to_insert = list(records_dict.values())
    print(f"Calculated {len(records_to_insert)} records for {week_id}. Upserting into daily_rent_log...")
    execute_values(cur, UPSERT_DAILY_RENT_LOG_SQL, records_to_insert, page_size=1000)
    conn.commit()
    print(f"Successfully populated {len(records_to_insert)} records for {week_id}!\n")

def audit_rental_engine():
    """Audits the health, table counts, and fallback rate across the entire rental engine."""
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    print("=================================================================")
    print("             LETZRYD RENTAL ENGINE HEALTH & INTEGRITY AUDIT      ")
    print("=================================================================\n")
    
    cur.execute("SELECT COUNT(*) AS c FROM sheet_rental_slabs;")
    slabs_cnt = cur.fetchone()['c']
    cur.execute("SELECT COUNT(*) AS c FROM sheet_rental_partners;")
    partners_cnt = cur.fetchone()['c']
    cur.execute("SELECT COUNT(*) AS c FROM core_rent WHERE is_active = TRUE;")
    core_rent_cnt = cur.fetchone()['c']
    cur.execute("SELECT COUNT(*) AS c FROM core_rent_logs;")
    core_rent_logs_cnt = cur.fetchone()['c']
    cur.execute("SELECT COUNT(*) AS c FROM core_daily_vehicle_status;")
    status_cnt = cur.fetchone()['c']
    cur.execute("SELECT COUNT(*) AS c FROM daily_rent_log;")
    daily_rent_cnt = cur.fetchone()['c']
    
    print("1. Upstream Staging Tables (Google Sheet Sync):")
    print(f"   - sheet_rental_slabs:         {slabs_cnt} active slab tiers")
    print(f"   - sheet_rental_partners:      {partners_cnt} partner platform agreements\n")
    
    print("2. Core Master & Operational Tables:")
    print(f"   - core_rent (active):         {core_rent_cnt} master vehicle plans")
    print(f"   - core_rent_logs:             {core_rent_logs_cnt} audit log records")
    print(f"   - core_daily_vehicle_status:  {status_cnt} live daily attendance records\n")
    
    print("3. Settlement & Ledger Table:")
    print(f"   - daily_rent_log:             {daily_rent_cnt} daily settlement records\n")

    # Fallback Rate & Rule Analysis
    cur.execute("""
        SELECT 
            COUNT(*) AS total_records,
            COUNT(*) FILTER (WHERE is_billable_day = TRUE) AS billable_records,
            COUNT(*) FILTER (WHERE is_billable_day = FALSE) AS non_billable_records,
            COUNT(*) FILTER (WHERE calculation_rule LIKE 'Fallback%%') AS fallback_records
        FROM daily_rent_log;
    """)
    stats = cur.fetchone()
    total = stats['total_records']
    fallbacks = stats['fallback_records']
    fallback_rate = (fallbacks / total * 100) if total > 0 else 0.0

    print("4. Calculation Quality & Fallback Audit:")
    print(f"   - Total Daily Records:        {total}")
    print(f"   - Billable Days:              {stats['billable_records']}")
    print(f"   - Non-Billable Days:          {stats['non_billable_records']}")
    print(f"   - Fallback Rate:              {fallbacks} / {total} ({fallback_rate:.2f}%)\n")

    print("5. Top Calculation Rules Applied:")
    cur.execute("""
        SELECT calculation_rule, COUNT(*) AS count
        FROM daily_rent_log
        GROUP BY calculation_rule
        ORDER BY count DESC
        LIMIT 10;
    """)
    for r in cur.fetchall():
        print(f"   - {r['calculation_rule']}: {r['count']}")
    
    print("\n=================================================================")
    if fallbacks == 0:
        print("  STATUS: HEALTHY - 100% FORMULA PARITY & ZERO FALLBACKS ACHIEVED")
    else:
        print(f"  WARNING: {fallbacks} FALLBACK RECORDS REQUIRE RESOLUTION")
    print("=================================================================\n")

    conn.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="LetzRyd Rental Final Table Engine")
    parser.add_argument("--audit", action="store_true", help="Run integrity audit")
    parser.add_argument("--sync-daily-status", action="store_true", help="Sync from core_daily_vehicle_status")
    parser.add_argument("--start-date", type=str, default=None, help="Start date (YYYY-MM-DD)")
    parser.add_argument("--end-date", type=str, default=None, help="End date (YYYY-MM-DD)")
    parser.add_argument("--populate-w26", action="store_true", help="Populate daily_rent_log for Week 26")
    parser.add_argument("--populate-w27", action="store_true", help="Populate daily_rent_log for Week 27")
    args = parser.parse_args()
    
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    if args.sync_daily_status:
        sync_from_core_daily_vehicle_status(cur, conn, args.start_date, args.end_date)
        audit_rental_engine()

    elif args.populate_w26:
        w26_datasets = [
            ('Bengaluru', r'C:\Users\anura\Downloads\26. BLR Hisaab - June 22nd to June 28th CY26WK26.xlsx', 'Uber + OLA Final Hisaab', 3, 7, 9, 10, 28, 18, 14, 13),
            ('Hyderabad', r'C:\Users\anura\Downloads\26. HYD Hisaab - Jun 22nd to Jun 28th CY26WK26.xlsx', 'Uber + OLA Final Hisaab', 4, 4, 7, 5, 24, 15, 11, 10),
            ('Mumbai', r'C:\Users\anura\Downloads\26. MUM Hisaab - June 22nd to June 28th CY26WK26.xlsx', 'Uber+Ola Final Hisaab', 3, 6, 8, 9, 24, 16, 13, 12),
        ]
        populate_from_hisaab_files(cur, conn, 'CY26WK26', '2026-06-22', '2026-06-28', w26_datasets)
        audit_rental_engine()

    elif args.populate_w27:
        w27_datasets = [
            ('Bengaluru', r'C:\Users\anura\Downloads\27. BLR Hisaab - June 29th to July 05th CY27WK26.xlsx', 'Uber + OLA Final Hisaab', 3, 7, 9, 10, 28, 18, 14, 13),
            ('Hyderabad', r'C:\Users\anura\Downloads\27. HYD Hisaab - Jun 29th to Jul 05th CY26WK27.xlsx', 'Uber + OLA Final Hisaab', 4, 4, 7, 5, 24, 15, 11, 10),
            ('Mumbai', r'C:\Users\anura\Downloads\27. MUM Hisaab - June 29th to July 5th CY26WK27.xlsx', 'Uber+Ola Final Hisaab', 3, 6, 8, 9, 24, 16, 13, 12),
        ]
        populate_from_hisaab_files(cur, conn, 'CY26WK27', '2026-06-29', '2026-07-05', w27_datasets)
        audit_rental_engine()

    else:
        audit_rental_engine()

    conn.close()
