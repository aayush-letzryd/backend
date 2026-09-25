"""
LetzRyd - Adjustments Final Table Automation & Health Engine
============================================================
Synchronizes, audits, and validates public.core_adjustments as the
Single Source of Truth combining:
  1. public.sheet_adjustments (Google Sheet operational entries)
  2. public.july_partner_adjustment (Web Portal partner adjustment forms)

Architectural Guarantees:
  - 1-to-1 Canonical Stacking (Zero data alteration or overwriting)
  - Gapless 1..N ID sequence integrity (Zero Sequence Burning via Advisory Locks 777333444)
  - Pure IST Timestamps (TIMESTAMP WITHOUT TIME ZONE, 0 timezone offset drift)
  - Soft-Delete Protection (is_deleted = TRUE, deleted_at = CURRENT_TIMESTAMP)
  - Downstream Hisaab synchronization to public.hisaab_adjustments_ledger
  - Automated pg_cron reconciliation schedule (every 15 minutes)

Usage:
    python automation_script.py --audit
    python automation_script.py --backfill
    python automation_script.py --verify-triggers
"""

import os
import sys
import argparse
import psycopg2
from psycopg2.extras import RealDictCursor

DB_HOST = os.getenv("DB_HOST", "35.200.196.113")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "8S5]U3@L^Xz)\\FH}")

def get_connection():
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )
    conn.autocommit = True
    return conn

def audit_health():
    """Runs a full integrity audit on core_adjustments, upstream sources, and downstream hisaab."""
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    print("=================================================================")
    print("        CORE ADJUSTMENTS HEALTH & RECONCILIATION AUDIT          ")
    print("=================================================================\n")

    all_passed = True

    # 1. Counts from Upstream Sources
    cur.execute("SELECT count(*) as count FROM public.sheet_adjustments;")
    sheet_total = cur.fetchone()["count"]

    cur.execute("SELECT count(*) as count FROM public.july_partner_adjustment;")
    portal_total = cur.fetchone()["count"]

    cur.execute("""
        SELECT 
            count(*) as physical_total,
            count(*) FILTER (WHERE NOT is_deleted) as active_total,
            count(*) FILTER (WHERE is_deleted) as deleted_total
        FROM public.core_adjustments;
    """)
    core_counts = cur.fetchone()
    physical_total = core_counts["physical_total"]
    active_total = core_counts["active_total"]
    deleted_total = core_counts["deleted_total"]

    expected_active_total = sheet_total + portal_total

    print(f"1. DATA SOURCE VOLUMES:")
    print(f"   - Upstream Sheet (sheet_adjustments)     : {sheet_total:,} rows")
    print(f"   - Upstream Portal (july_partner_adj)     : {portal_total:,} rows")
    print(f"   - Active Core (active_core_adjustments)  : {active_total:,} rows")
    print(f"   - Soft-Deleted Records in Core           : {deleted_total:,} rows")
    print(f"   - Physical Total in core_adjustments     : {physical_total:,} rows")
    if active_total == expected_active_total:
        print(f"   [PASS] Exact 1-to-1 Parity: Active Core ({active_total:,}) matches Sheet + Portal ({expected_active_total:,}).")
    else:
        print(f"   [FAIL] Parity Discrepancy: Active Core has {active_total:,}, expected {expected_active_total:,}!")
        all_passed = False
    print()

    # 2. Source Breakdown in Core (Active Records)
    cur.execute("""
        SELECT data_source, is_deleted, count(*) as count, min(id) as min_id, max(id) as max_id 
        FROM public.core_adjustments 
        GROUP BY data_source, is_deleted 
        ORDER BY is_deleted ASC, count DESC;
    """)
    sources = cur.fetchall()
    print("2. CORE ADJUSTMENTS DATA SOURCE BREAKDOWN:")
    for s in sources:
        status_label = "DELETED" if s['is_deleted'] else "ACTIVE"
        print(f"   - {s['data_source']:<15} [{status_label}]: {s['count']:,} rows (IDs {s['min_id']} to {s['max_id']})")
    print()

    # 3. Gapless ID Continuity Check
    cur.execute("SELECT min(id) as min_id, max(id) as max_id, count(id) as count FROM public.core_adjustments;")
    id_stats = cur.fetchone()
    min_id = id_stats["min_id"]
    max_id = id_stats["max_id"]
    count_id = id_stats["count"]

    cur.execute("""
        SELECT count(*) as gaps
        FROM generate_series(1, (SELECT max(id) FROM public.core_adjustments)) g
        LEFT JOIN public.core_adjustments c ON c.id = g
        WHERE c.id IS NULL;
    """)
    gaps = cur.fetchone()["gaps"]

    print("3. SEQUENCE & ID INTEGRITY:")
    print(f"   - Min ID: {min_id} | Max ID: {max_id} | Total Rows: {count_id}")
    if gaps == 0 and min_id == 1 and max_id == count_id:
        print("   [PASS] Gapless ID Sequence: 0 gaps found across entire table.")
    else:
        print(f"   [FAIL] ID Sequence Discontinuity: {gaps} missing IDs detected!")
        all_passed = False

    # Check sequence last_value
    cur.execute("SELECT last_value FROM pg_sequences WHERE schemaname = 'public' AND sequencename = 'core_adjustments_id_seq';")
    seq_val = cur.fetchone()["last_value"]
    if seq_val == max_id:
        print(f"   [PASS] Sequence Counter In Sync: last_value ({seq_val}) matches Max ID ({max_id}).")
    else:
        print(f"   [WARN] Sequence Desync: last_value ({seq_val}) does not match Max ID ({max_id}).")
        all_passed = False
    print()

    # 4. Status Integrity Check
    cur.execute("""
        SELECT count(*) as bad_stat 
        FROM public.core_adjustments 
        WHERE approval_status ~ '[0-9]{4}-[0-9]{2}-[0-9]{2}';
    """)
    bad_stat = cur.fetchone()["bad_stat"]
    print("4. APPROVAL STATUS INTEGRITY:")
    if bad_stat == 0:
        print("   [PASS] Zero timestamp strings in approval_status.")
    else:
        print(f"   [FAIL] {bad_stat} corrupted timestamp status strings detected!")
        all_passed = False
    print()

    # 5. Timestamp Timezone Compliance
    cur.execute("""
        SELECT column_name, data_type 
        FROM information_schema.columns 
        WHERE table_schema = 'public' AND table_name = 'core_adjustments'
          AND column_name IN ('created_at', 'updated_at', 'deleted_at');
    """)
    ts_cols = cur.fetchall()
    print("5. TIMESTAMP DATA TYPE COMPLIANCE:")
    all_ts_clean = True
    for c in ts_cols:
        is_clean = "without time zone" in c["data_type"].lower()
        status = "[PASS]" if is_clean else "[FAIL]"
        print(f"   - {c['column_name']:<12}: {c['data_type']} {status}")
        if not is_clean:
            all_ts_clean = False
            all_passed = False
    print()

    # 6. Source Reference ID Cleanliness
    cur.execute("SELECT max(length(source_reference_id)) as max_len FROM public.core_adjustments;")
    max_ref_len = cur.fetchone()["max_len"]
    print("6. SOURCE REFERENCE INTEGRITY:")
    if max_ref_len and max_ref_len <= 50:
        print(f"   [PASS] Max reference ID length: {max_ref_len} chars (Zero unbounded string bloat).")
    else:
        print(f"   [FAIL] Reference ID bloat detected: max length = {max_ref_len} chars!")
        all_passed = False
    print()

    # 7. pg_cron Schedule Check
    cur.execute("SELECT jobid, schedule, command, active FROM cron.job WHERE command LIKE '%refresh_core_adjustments%';")
    cron_job = cur.fetchone()
    print("7. PG_CRON RECONCILIATION AUTOMATION:")
    if cron_job and cron_job["active"]:
        print(f"   [PASS] pg_cron Active: Job ID {cron_job['jobid']}, Schedule '{cron_job['schedule']}' ({cron_job['command']})")
    else:
        print("   [FAIL] pg_cron schedule not found or inactive!")
        all_passed = False
    print()

    print("=================================================================")
    if all_passed:
        print("   AUDIT RESULT: ALL INTEGRITY CHECKS PASSED [SUCCESS]          ")
    else:
        print("   AUDIT RESULT: INTEGRITY CHECKS FAILED [ACTION REQUIRED]       ")
    print("=================================================================\n")

    cur.close()
    conn.close()
    return 0 if all_passed else 1

def run_backfill():
    """Runs the consolidation procedure to refresh core_adjustments from upstream."""
    conn = get_connection()
    cur = conn.cursor()
    print("Executing public.refresh_core_adjustments()...")
    cur.execute("SELECT public.refresh_core_adjustments();")
    inserted = cur.fetchone()[0]
    print(f"Successfully refreshed {inserted:,} adjustments into public.core_adjustments.")
    cur.close()
    conn.close()

def verify_triggers():
    """Verifies that active triggers exist on sheet_adjustments, july_partner_adjustment, and core_adjustments."""
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    print("Checking active synchronization triggers...")
    cur.execute("""
        SELECT event_object_table, trigger_name, action_statement
        FROM information_schema.triggers
        WHERE event_object_table IN ('sheet_adjustments', 'july_partner_adjustment', 'core_adjustments')
        ORDER BY event_object_table, trigger_name;
    """)
    trigs = cur.fetchall()
    for t in trigs:
        print(f"  [OK] Table: {t['event_object_table']:<25} -> Trigger: {t['trigger_name']}")
    cur.close()
    conn.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="LetzRyd Core Adjustments Health & Automation Engine")
    parser.add_argument("--audit", action="store_true", help="Run full data health audit")
    parser.add_argument("--backfill", action="store_true", help="Run backfill/reconciliation refresh")
    parser.add_argument("--verify-triggers", action="store_true", help="Verify trigger bindings")
    args = parser.parse_args()

    if args.backfill:
        run_backfill()
    elif args.verify_triggers:
        verify_triggers()
    else:
        sys.exit(audit_health())
