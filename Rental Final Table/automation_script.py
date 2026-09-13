"""
LetzRyd - Rental Final Table Automation & Calculation Engine
============================================================
Calculates daily rent and indemnity for public.daily_rent_log based on:
  1. Master agreements in public.core_rent
  2. Live pricing slabs in public.sheet_rental_slabs
  3. Live partner agreements in public.sheet_rental_partners
  4. Daily attendance from public.sheet_vehicle_status
  5. Weekly completed Uber/Ola trips

Reconciled Formula:
  Net Daily Rent = applied_daily_rent + applied_daily_indemnity
  Weekly Hisaab Settlement Rent = (Daily Rent * On-road Days) + (Daily Indemnity * On-road Days)

Usage:
    python automation_script.py --audit
"""

import os
import sys
import argparse
import psycopg2
from psycopg2.extras import RealDictCursor
from datetime import date

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

def audit_rental_engine():
    """Audits the health and row counts of all 5 rental tables."""
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
    cur.execute("SELECT COUNT(*) AS c FROM daily_rent_log;")
    daily_rent_cnt = cur.fetchone()['c']
    
    print("1. Upstream Staging Tables (Google Sheet Sync):")
    print(f"   - sheet_rental_slabs:    {slabs_cnt} active slab tiers")
    print(f"   - sheet_rental_partners: {partners_cnt} partner platform agreements\n")
    
    print("2. Core Master & Audit Tables:")
    print(f"   - core_rent (active):    {core_rent_cnt} master vehicle plans")
    print(f"   - core_rent_logs:        {core_rent_logs_cnt} audit log records\n")
    
    print("3. Settlement & Ledger Table:")
    print(f"   - daily_rent_log:        {daily_rent_cnt} daily settlement records\n")
    
    conn.close()
    print("Integrity audit complete.")

def calculate_daily_rent_record(cur, vehicle_number, log_date, week_id, attendance_status, weekly_trips=0, ola_trips=0):
    """
    Computes daily rent & indemnity for a vehicle based on attendance, plan, slabs, and multi-app rules.
    """
    cur.execute("""
        SELECT * FROM core_rent 
        WHERE vehicle_number = %s AND is_active = TRUE 
          AND effective_from <= %s AND effective_to >= %s
        LIMIT 1;
    """, (vehicle_number, log_date, log_date))
    contract = cur.fetchone()
    if not contract:
        return None

    city = contract['city']
    model = contract['vehicle_model']
    partner_id = contract['partner_id']
    plan_scheme = contract['plan_scheme']
    custom_rent = contract['custom_daily_rent']
    custom_indemnity = contract['custom_daily_indemnity']

    # 1. Golden Rule #2: Off-road / Maintenance attendance
    is_billable = (attendance_status.strip().lower() in ('on-road', 'on road', 'active'))
    if not is_billable:
        return {
            'log_date': log_date,
            'week_id': week_id,
            'vehicle_number': vehicle_number,
            'partner_id': partner_id,
            'city': city,
            'vehicle_model': model,
            'attendance_status': attendance_status,
            'is_billable_day': False,
            'weekly_completed_trips': weekly_trips,
            'applied_daily_rent': 0.00,
            'applied_daily_indemnity': 0.00,
            'net_daily_rent': 0.00,
            'calculation_rule': f'Non-billable status: {attendance_status}'
        }

    # 2. Priority 1: Custom partner deal override
    if custom_rent is not None and custom_rent > 0:
        applied_rent = float(custom_rent)
        calc_rule = f'Priority 1: Partner Contract ({applied_rent}/day)'
    # 3. Priority 2: Multi-app Ola Penalty (Bangalore)
    elif 'bengaluru' in city.lower() and float(ola_trips or 0) >= 1.0 and 'operator' not in plan_scheme.lower():
        applied_rent = 1050.00
        calc_rule = 'Priority 2: Ola Multi-App Penalty Base Rate (1050/day)'
    # 4. Priority 2: Allocated Plan from sheet_rental_slabs
    else:
        # Determine driver type
        driver_type = 'Operator' if ('operator' in plan_scheme.lower() or 'fleet' in plan_scheme.lower()) else 'Individual'
        
        cur.execute("""
            SELECT daily_rent, trip_slab_label 
            FROM sheet_rental_slabs
            WHERE city ILIKE %s 
              AND vehicle_model ILIKE %s
              AND (driver_type = %s OR driver_type = 'All')
              AND %s >= min_trips
              AND (%s <= max_trips OR max_trips IS NULL)
            ORDER BY min_trips DESC
            LIMIT 1;
        """, (f"%{city}%", f"%{model.split()[0]}%", driver_type, weekly_trips, weekly_trips))
        slab = cur.fetchone()
        if slab:
            applied_rent = float(slab['daily_rent'])
            calc_rule = f"Priority 2: Slab Tier {slab['trip_slab_label']} ({applied_rent}/day)"
        else:
            # 5. Priority 3: Fallback Base Rate
            if 'dzire' in model.lower(): applied_rent = 1200.00
            elif 'ec3' in model.lower() or 'ev' in model.lower(): applied_rent = 1400.00
            elif 'xcent' in model.lower(): applied_rent = 900.00
            else: applied_rent = 1050.00
            calc_rule = f"Priority 3: Fallback Base ({applied_rent}/day)"

    # Indemnity calculation
    if custom_indemnity is not None:
        applied_indemnity = float(custom_indemnity)
    else:
        applied_indemnity = 0.00 if 'xcent' in model.lower() else 30.00

    net_daily = applied_rent + applied_indemnity

    return {
        'log_date': log_date,
        'week_id': week_id,
        'vehicle_number': vehicle_number,
        'partner_id': partner_id,
        'city': city,
        'vehicle_model': model,
        'attendance_status': attendance_status,
        'is_billable_day': True,
        'weekly_completed_trips': weekly_trips,
        'applied_daily_rent': applied_rent,
        'applied_daily_indemnity': applied_indemnity,
        'net_daily_rent': net_daily,
        'calculation_rule': calc_rule
    }

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="LetzRyd Rental Final Table Engine")
    parser.add_argument("--audit", action="store_true", help="Run integrity audit")
    args = parser.parse_args()
    
    if args.audit or len(sys.argv) == 1:
        audit_rental_engine()
