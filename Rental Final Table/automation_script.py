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
    Preloads active vehicle and partner contracts from core_rent and rate slabs from sheet_rental_slabs
    into memory for high-performance vectorized lookups adhering to the standard 4-Tier Plan Logic.
    """
    cur.execute("SELECT * FROM core_rent WHERE is_active = TRUE;")
    core_rent_rows = cur.fetchall()
    
    partner_veh_map = {}
    partner_model_map = {}
    veh_model_map = {}
    
    for r in core_rent_rows:
        p_id = (r['partner_id'] or '').strip().upper()
        v_no = (r['vehicle_number'] or '').strip().upper()
        m_name = (r['vehicle_model'] or '').strip().lower()
        if p_id and v_no:
            partner_veh_map[(p_id, v_no)] = r
        if p_id and m_name:
            partner_model_map[(p_id, m_name)] = r
        if v_no and v_no not in veh_model_map and r['vehicle_model']:
            veh_model_map[v_no] = r['vehicle_model']

    cur.execute("SELECT * FROM sheet_rental_slabs ORDER BY min_trips DESC;")
    slabs_list = cur.fetchall()

    return partner_veh_map, partner_model_map, veh_model_map, slabs_list

def calculate_single_vehicle_day(
    veh_clean,
    log_date,
    week_id,
    attendance_status,
    is_billable,
    weekly_trips,
    ola_trips,
    partner_veh_map,
    partner_model_map,
    veh_model_map,
    slabs_list,
    fallback_city='Bengaluru',
    fallback_partner=None,
    fallback_model=None
):
    """
    Pure in-memory calculation of daily rent and indemnity adhering to standard 4-Tier Plan Logic:
      Tier 1: Non-billable status or unassigned yard -> ₹0.00
      Tier 2: Partner-specific exception rate card (keyed by partner_id / LID)
      Tier 3: Model-specific rates (e.g. Mumbai Dzire = 1130, Hyderabad EC3 = 1400)
      Tier 4: Dynamic Reducing Rent Slabs by weekly completed trips
    """
    p_id_clean = (fallback_partner or '').strip().upper()
    v_clean = (veh_clean or '').strip().upper()

    actual_model = fallback_model or veh_model_map.get(v_clean) or 'Maruti Wagonr Tour H3 CNG'
    m_token = actual_model.split()[0].lower()
    city = fallback_city or 'Bengaluru'

    # Contract lookup: Priority 1: (partner_id, vehicle_number), Priority 2: (partner_id, model)
    contract = partner_veh_map.get((p_id_clean, v_clean))
    if not contract and p_id_clean:
        for (cp_id, cm_name), cr in partner_model_map.items():
            if cp_id == p_id_clean and (m_token in cm_name or cm_name in actual_model.lower()):
                contract = cr
                break

    partner_id = p_id_clean if (p_id_clean and p_id_clean != 'UNMAPPED') else (contract['partner_id'] if contract else '')
    custom_rent = contract['custom_daily_rent'] if contract else None
    plan_scheme = contract['plan_scheme'] if contract else 'Uber Reducing Rent'

    # MANDATE: Unconditionally zero-rent statuses (Yard / Unassigned / Dropoff / RFD) always clear partner.
    # Maintenance/Breakdown/Accident CAN be billable when Ops explicitly sets billable_rent_day = True.
    UNCONDITIONAL_ZERO_STATUSES = ('Drop Off', 'Drop-off', 'RFD', 'Unassigned')
    CONDITIONAL_ZERO_STATUSES   = ('Maintenance', 'Breakdown', 'Accident')

    if attendance_status in UNCONDITIONAL_ZERO_STATUSES:
        # Yard / Drop-off vehicles are NEVER billable regardless of billable_rent_day
        partner_id = ''
        is_billable = False
    elif not is_billable and attendance_status in CONDITIONAL_ZERO_STATUSES:
        # Maintenance/Breakdown/Accident are zero-rent only when Ops did NOT mark them billable
        partner_id = ''

    # Primary condition for charging daily rent is successful trip activity (>0) — overrides non-billable
    if (float(weekly_trips or 0) > 0 or float(ola_trips or 0) > 0):
        is_billable = True
        if attendance_status in UNCONDITIONAL_ZERO_STATUSES:
            attendance_status = 'Active'  # Trips override yard/RFD status
        elif attendance_status in CONDITIONAL_ZERO_STATUSES:
            attendance_status = 'Active'  # Trips override maintenance status

    # Tier 1: Non-billable attendance status -> ₹0.00
    if not is_billable or partner_id == '':
        return (
            log_date, week_id, v_clean, partner_id, city, actual_model,
            attendance_status, False, weekly_trips, 0.00, 0.00, 0.00,
            f"Non-billable status: {attendance_status}"
        )

    # --- MUMBAI PLAN LOGIC ---
    # In Mumbai, Daily Revenue Share = (Plan Rate) + 30 Indemnity baked in.
    # To maintain 100% exact parity with Mumbai Ops Sheet, applied_daily_rent stores the merged rate and indemnity = 0.00.
    if 'mumbai' in city.lower():
        if 'dzire' in actual_model.lower():
            applied_rent = 1130.00  # 1100 base + 30 indemnity
            calc_rule = "Priority 1: Mumbai Dzire Standard Rate (1100 + 30 = 1130/day)"
        elif custom_rent is not None and custom_rent > 0:
            applied_rent = float(custom_rent)
            calc_rule = f"Priority 1: Mumbai Partner Rate Card ({applied_rent}/day)"
        else:
            applied_rent = 1000.00  # 970 + 30 default base
            for slab in slabs_list:
                if 'mumbai' in slab['city'].lower() and 'wagon' in slab['vehicle_model'].lower():
                    min_t = slab['min_trips']
                    max_t = slab['max_trips'] if slab['max_trips'] is not None else 9999
                    if min_t <= weekly_trips <= max_t:
                        applied_rent = float(slab['daily_rent']) + 30.00
                        calc_rule = f"Priority 2: Mumbai Dynamic Slab ({applied_rent}/day)"
                        break
            calc_rule = calc_rule or "Priority 3: Mumbai Fallback Base (1000/day)"
        applied_indemnity = 0.00
        net_daily = applied_rent

    # --- HYDERABAD & BENGALURU PLAN LOGIC ---
    else:
        # Priority 1: Partner Exception Card
        if custom_rent is not None and custom_rent > 0:
            applied_rent = float(custom_rent)
            calc_rule = f"Priority 1: Partner Exception Card ({applied_rent}/day)"
        # Priority 2: Multi-app Ola Penalty (Bangalore)
        elif 'bengaluru' in city.lower() and float(ola_trips or 0) >= 1.0 and 'operator' not in plan_scheme.lower():
            applied_rent = 1050.00
            calc_rule = "Priority 2: Ola Multi-App Penalty Base Rate (1050/day)"
        # Priority 3: Dynamic Slabs (TBS / EBS / LIP / Uber Reducing Rent)
        else:
            driver_type = 'Operator' if ('operator' in plan_scheme.lower() or 'fleet' in plan_scheme.lower()) else 'Individual'
            # Determine target slab plan_scheme based on the contract's plan type.
            # LIP, Uber TBS, Uber Reducing Rent, D2R, D2O → use 'Uber Reducing Rent' slabs (reducing tiers).
            # All Platform Flat / Operator Custom Flat → use 'All Platform' slab.
            # Default to 'Uber Reducing Rent' when no contract exists (unknown partner defaults to reducing tier).
            ps_lower = plan_scheme.lower()
            if any(k in ps_lower for k in ('all platform', 'operator custom flat')):
                target_slab_scheme = 'All Platform'
            else:
                target_slab_scheme = 'Uber Reducing Rent'

            applied_rent = None
            calc_rule = None
            for slab in slabs_list:
                if slab['city'].lower() not in city.lower() and city.lower() not in slab['city'].lower():
                    continue
                model_first_token = actual_model.split()[0].lower()
                if model_first_token not in slab['vehicle_model'].lower() and slab['vehicle_model'].lower() not in actual_model.lower():
                    continue
                if slab['driver_type'] != 'All' and slab['driver_type'].lower() != driver_type.lower():
                    continue
                # Only match slabs for the correct plan_scheme (prevents 'All Platform' 1050 slab from
                # overriding 'Uber Reducing Rent' 989 slab for LIP/TBS/D2R/D2O partners).
                if slab.get('plan_scheme') and slab['plan_scheme'] != target_slab_scheme:
                    continue
                min_t = slab['min_trips']
                max_t = slab['max_trips'] if slab['max_trips'] is not None else 9999
                if min_t <= weekly_trips <= max_t:
                    applied_rent = float(slab['daily_rent'])
                    calc_rule = f"Priority 3: Slab Tier {slab['trip_slab_label']} ({applied_rent}/day)"
                    break
            
            if applied_rent is None:
                if 'ec3' in actual_model.lower() or 'ev' in actual_model.lower(): applied_rent = 1400.00
                elif 'dzire' in actual_model.lower(): applied_rent = 1100.00
                elif 'xcent' in actual_model.lower(): applied_rent = 0.00 if 'hyderabad' in city.lower() else 550.00
                elif 'wagon' in actual_model.lower(): applied_rent = 989.00 if 'hyderabad' in city.lower() else 1050.00
                else: applied_rent = 1050.00
                calc_rule = f"Priority 4: Fallback Base ({applied_rent}/day)"

        applied_indemnity = 0.00 if 'xcent' in actual_model.lower() else 30.00
        net_daily = applied_rent + applied_indemnity

    return (
        log_date, week_id, v_clean, partner_id, city, actual_model,
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

    partner_veh_map, partner_model_map, veh_model_map, slabs_list = load_master_rental_context(cur)
    print(f"Loaded {len(partner_veh_map)} vehicle contracts, {len(partner_model_map)} partner model contracts, and {len(slabs_list)} rate card slabs.")

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

    # Query trip counts from core_uber_daily and core_ola_daily for official completed trips in this date window
    cur.execute("""
        SELECT 
            UPPER(REPLACE(v.vehicle_number, ' ', '')) AS car_no,
            COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0) AS trip_count
        FROM (
            SELECT DISTINCT vehicle_number FROM public.core_daily_vehicle_status WHERE status_date BETWEEN %s AND %s
        ) v
        LEFT JOIN (
            SELECT UPPER(REPLACE(vehicle_number, ' ', '')) AS veh, SUM(completed_trips) AS uber_trips
            FROM public.core_uber_daily
            WHERE operational_date BETWEEN %s AND %s
            GROUP BY UPPER(REPLACE(vehicle_number, ' ', ''))
        ) u ON UPPER(REPLACE(v.vehicle_number, ' ', '')) = u.veh
        LEFT JOIN (
            SELECT UPPER(REPLACE(vehicle_number, ' ', '')) AS veh, SUM(completed_trips) AS ola_trips
            FROM public.core_ola_daily
            WHERE service_date BETWEEN %s AND %s
            GROUP BY UPPER(REPLACE(vehicle_number, ' ', ''))
        ) o ON UPPER(REPLACE(v.vehicle_number, ' ', '')) = o.veh;
    """, (start_d, end_d, start_d, end_d, start_d, end_d))
    trip_rows = cur.fetchall()
    trip_map = {}
    for r in trip_rows:
        if isinstance(r, dict):
            k = (r['car_no'] or '').strip().upper()
            v = r['trip_count']
        else:
            k = (r[0] or '').strip().upper()
            v = r[1]
        if k:
            trip_map[k] = float(v or 0)
    print(f"Loaded trip counts for {len(trip_map)} vehicles from uber_pipeline_trips.")

    # Query attendance — LEFT JOIN sheet_vehicle_status to get the billing partner_id
    # that the Excel Hisaab uses directly (sheet_vehicle_status.partner_id = NULL means non-billable).
    # core_daily_vehicle_status forward-fills partner_id from allocation, which can differ from the
    # Excel source-of-truth on Maintenance days where the sheet has no partner assigned.
    cur.execute("""
        SELECT 
            cdvs.status_date AS log_date,
            cdvs.vehicle_number,
            cdvs.city,
            cdvs.car_model AS vehicle_model,
            -- Use sheet_vehicle_status.partner_id as the billing partner (Excel source of truth).
            -- Fall back to cdvs.partner_id only when the sheet has no row for that day.
            COALESCE(NULLIF(svs.partner_id, ''), cdvs.partner_id) AS partner_id,
            cdvs.final_status AS attendance_status,
            cdvs.billable_rent_day
        FROM core_daily_vehicle_status cdvs
        LEFT JOIN sheet_vehicle_status svs
            ON svs.vehicle_number = cdvs.vehicle_number
           AND svs.status_date = cdvs.status_date
        WHERE cdvs.status_date BETWEEN %s AND %s
        ORDER BY cdvs.status_date, cdvs.vehicle_number;
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
            partner_veh_map=partner_veh_map,
            partner_model_map=partner_model_map,
            veh_model_map=veh_model_map,
            slabs_list=slabs_list,
            fallback_city=row['city'] or 'Bengaluru',
            fallback_partner=row['partner_id'],
            fallback_model=row['vehicle_model']
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
