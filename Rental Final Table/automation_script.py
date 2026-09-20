"""
LetzRyd - Rental Final Table Automation & Calculation Engine (Unified Architecture)
===================================================================================
Orchestrates daily rent calculation and Hisaab settlement synchronization via
high-performance set-based PostgreSQL stored procedures.

Key Procedures:
  1. public.sp_calculate_daily_rent(start_date, end_date)
     - Implements the 100% data-driven 5-Tier Precedence Waterfall natively in PostgreSQL:
       Tier 1: Exceptions / Overrides (rental_exceptions)
       Tier 2: Partner Custom Plan Cards (rental_custom_partner_plans)
       Tier 3: Dynamic Reducing Trip Slabs & Operator Brackets (rental_rate_slabs)
       Tier 4: Model Specific Fallback Baselines (rental_model_baselines)
       Tier 5: Master City Default Base Plans (core_rental_plans)
     - Writes to public.daily_rent_log at the grain: UNIQUE(log_date, vehicle_number, partner_id)
     - Records full lineage tracking: matched_plan_id, matched_slab_id, matched_custom_plan_id

  2. public.sp_sync_rent_to_hisaab(week_id)
     - Set-based batch synchronization of daily rent into public.hisaab_daily_ledger
     - Triggers bulk weekly reconciliation in public.hisaab_vehicle_weekly and hisaab_partner_weekly
     - 100% trigger-free to protect telemetry and vehicle status operational tables

Scheduled via pg_cron:
  - 02:00 UTC daily: CALL public.sp_calculate_daily_rent(CURRENT_DATE - 1, CURRENT_DATE);
  - 02:30 UTC daily: CALL public.sp_sync_rent_to_hisaab(NULL);

Usage:
  python automation_script.py --audit
  python automation_script.py --calculate-rent --start-date 2026-09-07 --end-date 2026-09-13
  python automation_script.py --sync-hisaab --week-id CY26WK37
"""

import os
import sys
import argparse
import datetime
import psycopg2
from psycopg2.extras import RealDictCursor

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

def audit_rental_system():
    """Audits the unified rental tables, indexes, constraints, and pg_cron jobs."""
    print("=" * 70)
    print("           LETZRYD UNIFIED RENTAL SYSTEM AUDIT")
    print("=" * 70)
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    tables = [
        ('core_rental_plans', 'Master Plan Catalogue (Integer PK)'),
        ('rental_rate_slabs', 'Dynamic Rate Slabs & Operator Brackets'),
        ('rental_custom_partner_plans', 'Partner Custom Agreements'),
        ('rental_exceptions', 'Approved Governance Overrides'),
        ('rental_fee_rules', 'Indemnity Fees & Policy Waivers'),
        ('rental_model_baselines', 'Vehicle Model Fallbacks'),
        ('daily_rent_log', 'Daily Output Rent Ledger (with Lineage)'),
        ('hisaab_daily_ledger', 'Hisaab Daily Settlement Ledger'),
        ('hisaab_vehicle_weekly', 'Hisaab Weekly Vehicle Summary')
    ]

    print("\n--- Table Record Counts ---")
    for tbl, desc in tables:
        cur.execute(f"SELECT count(*) as cnt FROM public.{tbl};")
        cnt = cur.fetchone()['cnt']
        print(f"  {tbl:<30} : {cnt:>8} rows  ({desc})")

    print("\n--- Primary Key Check (Integer Serial IDs: 1, 2, 3...) ---")
    pks = [
        ('core_rental_plans', 'plan_id'),
        ('rental_rate_slabs', 'slab_id'),
        ('rental_custom_partner_plans', 'custom_plan_id'),
        ('rental_model_baselines', 'baseline_id'),
        ('rental_fee_rules', 'fee_rule_id'),
        ('rental_exceptions', 'exception_id'),
        ('daily_rent_log', 'id')
    ]
    for tbl, col in pks:
        cur.execute(f"""
            SELECT data_type 
            FROM information_schema.columns 
            WHERE table_name = '{tbl}' AND column_name = '{col}';
        """)
        row = cur.fetchone()
        dtype = row['data_type'] if row else 'UNKNOWN'
        print(f"  {tbl:<30} PK: {col:<16} Type: {dtype}")

    print("\n--- Operator Custom Slabs in rental_rate_slabs ---")
    cur.execute("SELECT count(*) as cnt FROM public.rental_rate_slabs WHERE partner_id <> 'ALL';")
    custom_op_slabs = cur.fetchone()['cnt']
    print(f"  Custom Operator Slab Records: {custom_op_slabs} rows")

    print("\n--- Lineage Columns in daily_rent_log ---")
    cur.execute("""
        SELECT column_name, data_type 
        FROM information_schema.columns 
        WHERE table_name = 'daily_rent_log' 
          AND column_name IN ('matched_plan_id', 'matched_slab_id', 'matched_custom_plan_id');
    """)
    for r in cur.fetchall():
        print(f"  Column: {r['column_name']:<25} Type: {r['data_type']}")

    print("\n--- Trigger Safety Audit ---")
    cur.execute("""
        SELECT tgrelid::regclass as tbl, tgname 
        FROM pg_trigger 
        WHERE tgrelid IN ('public.daily_rent_log'::regclass, 'public.hisaab_daily_ledger'::regclass)
          AND NOT tgisinternal;
    """)
    triggers = cur.fetchall()
    if not triggers:
        print("  [OK] Zero row-level triggers detected. Operational tables completely safe!")
    else:
        for t in triggers:
            print(f"  [TRIGGER] Table: {t['tbl']}, Trigger: {t['tgname']}")

    print("\n--- pg_cron Job Automation ---")
    cur.execute("SELECT jobid, jobname, schedule, command, active FROM cron.job ORDER BY jobid;")
    jobs = cur.fetchall()
    for j in jobs:
        status = "ACTIVE" if j['active'] else "DISABLED"
        print(f"  Job #{j['jobid']:<2} [{status}] ({j['schedule']:<15}) {j['jobname'] or 'Unnamed'}")
        print(f"         Command: {j['command']}")

    print("\n--- daily_rent_log Grain Constraint ---")
    cur.execute("""
        SELECT conname, pg_get_constraintdef(oid) as cdef
        FROM pg_constraint
        WHERE conrelid = 'public.daily_rent_log'::regclass
          AND contype = 'u';
    """)
    constraints = cur.fetchall()
    for c in constraints:
        print(f"  Constraint: {c['conname']} -> {c['cdef']}")

    cur.close()
    conn.close()
    print("\n" + "=" * 70)
    print("Audit completed successfully.")
    print("=" * 70)

def run_daily_calculation(start_date=None, end_date=None):
    """Executes public.sp_calculate_daily_rent for a date window."""
    conn = get_connection()
    conn.autocommit = True
    cur = conn.cursor()
    print(f"Triggering rental calculation from {start_date or 'yesterday'} to {end_date or start_date or 'yesterday'}...")
    t0 = datetime.datetime.now()
    cur.execute("CALL public.sp_calculate_daily_rent(%s::date, %s::date);", (start_date, end_date))
    dur = (datetime.datetime.now() - t0).total_seconds()
    print(f"[OK] Daily rental calculated in {dur:.2f} seconds.")
    cur.close()
    conn.close()

def run_hisaab_sync(week_id=None):
    """Executes public.sp_sync_rent_to_hisaab for a settlement week."""
    conn = get_connection()
    conn.autocommit = True
    cur = conn.cursor()
    print(f"Triggering Hisaab rent sync for week: {week_id or 'current active week'}...")
    t0 = datetime.datetime.now()
    cur.execute("CALL public.sp_sync_rent_to_hisaab(%s);", (week_id,))
    dur = (datetime.datetime.now() - t0).total_seconds()
    print(f"[OK] Hisaab rent sync and weekly aggregations completed in {dur:.2f} seconds.")
    cur.close()
    conn.close()

def main():
    parser = argparse.ArgumentParser(description="LetzRyd Unified Rental Automation Engine")
    parser.add_argument("--audit", action="store_true", help="Audit database tables, triggers, and cron schedules")
    parser.add_argument("--calculate-rent", action="store_true", help="Run daily rent calculation stored procedure")
    parser.add_argument("--sync-hisaab", action="store_true", help="Run Hisaab rent sync stored procedure")
    parser.add_argument("--start-date", type=str, help="Start date (YYYY-MM-DD) for rent calculation")
    parser.add_argument("--end-date", type=str, help="End date (YYYY-MM-DD) for rent calculation")
    parser.add_argument("--week-id", type=str, help="Settlement week ID (e.g., CY26WK37) for Hisaab sync")

    args = parser.parse_args()

    if args.audit:
        audit_rental_system()
    elif args.calculate_rent:
        run_daily_calculation(args.start_date, args.end_date)
    elif args.sync_hisaab:
        run_hisaab_sync(args.week_id)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
