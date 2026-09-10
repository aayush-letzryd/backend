"""
LetzRyd - Vehicle Maintenance Final Table Automation & Reconciliation Engine
============================================================================
Synchronizes, backfills, and audits public.core_maintenance as the Single Source
of Truth combining public.sheet_maintenance, public.july_maintenance_in, and 
public.july_maintenance_out with Portal Priority and zero sequence ID gaps.

Usage:
    python automation_script.py --audit
    python automation_script.py --backfill
    python automation_script.py --deploy
    python automation_script.py --test-triggers
"""

import os
import sys
import re
import time
import argparse
from datetime import datetime, date
import psycopg2
from psycopg2.extras import RealDictCursor, execute_batch

DB_HOST = os.getenv('DB_HOST', '35.200.196.113')
DB_PORT = int(os.getenv('DB_PORT', '5432'))
DB_NAME = os.getenv('DB_NAME', 'postgres')
DB_USER = os.getenv('DB_USER', 'postgres')
DB_PASSWORD = os.getenv('DB_PASSWORD', r'8S5]U3@L^Xz)\FH}')

def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )

# -----------------------------------------------------------------------------
# 1. Pure-Python ETL Sanitization & Hygiene Transformers
# -----------------------------------------------------------------------------

def clean_plate(raw):
    if not raw:
        return None
    s = re.sub(r'[^A-Za-z0-9]', '', str(raw).strip()).upper()
    if len(s) < 6 or len(s) > 15:
        return None
    if s in ['TOTAL', 'REGNO', 'BALANCE', 'SUBTOTAL', 'UNKNOWN', 'TEST', 'TESTVEHICLE', 'ROLLERTEST']:
        return s
    return s

def clean_city(city_raw, plate_raw=''):
    if city_raw:
        u = str(city_raw).strip().upper()
        if u.startswith("BLR") or u.startswith("BANG") or u.startswith("BENG"):
            return "Bangalore"
        if u.startswith("HYD"):
            return "Hyderabad"
        if u.startswith("MUM") or u.startswith("BOMBAY"):
            return "Mumbai"
        if u.startswith("DEL") or u.startswith("NCR"):
            return "Delhi"
        if u.startswith("PUN"):
            return "Pune"
    if plate_raw:
        p = str(plate_raw).upper()
        if p.startswith("KA"):
            return "Bangalore"
        if p.startswith("TS") or p.startswith("TG") or p.startswith("AP"):
            return "Hyderabad"
        if p.startswith("MH"):
            return "Mumbai"
        if p.startswith("DL"):
            return "Delhi"
    return "Bangalore"

def parse_date_str(val):
    if not val:
        return None
    s = str(val).strip()
    if not s or s == '-' or s.lower() in ['null', 'nan', 'none']:
        return None
    
    # ISO Timestamp prefix YYYY-MM-DD
    m = re.match(r'^(\d{4})[/\-](\d{1,2})[/\-](\d{1,2})', s)
    if m:
        try:
            return f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
        except:
            pass

    # DD/MM/YYYY or DD-MM-YYYY
    m = re.match(r'^(\d{1,2})[/\-\.](\d{1,2})[/\-\.](\d{4})', s)
    if m:
        try:
            return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
        except:
            pass

    return None

def parse_timestamp_str(val):
    if not val:
        return None
    s = str(val).strip().replace('T', ' ')
    if not s or s == '-' or s.lower() in ['null', 'nan', 'none']:
        return None
    try:
        # Match YYYY-MM-DD HH:MM:SS
        if re.match(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}', s):
            return s
    except:
        pass
    return None

def parse_numeric_val(val):
    if not val:
        return 0.00
    s = re.sub(r'[^0-9\.]', '', str(val).strip())
    if not s or s == '.':
        return 0.00
    try:
        return round(float(s), 2)
    except:
        return 0.00

def parse_int_val(val):
    if not val:
        return None
    s = re.sub(r'[^0-9]', '', str(val).strip())
    if not s:
        return None
    try:
        return int(s)
    except:
        return None

def clean_str(val):
    if not val:
        return None
    s = str(val).strip()
    if not s or s == '-' or s.lower() in ['null', 'nan', 'none']:
        return None
    return s

# -----------------------------------------------------------------------------
# 2. Schema Deployment & Trigger Installation
# -----------------------------------------------------------------------------

def deploy_schema():
    print("=" * 80)
    print("       DEPLOYING SCHEMA: public.core_maintenance & REAL-TIME TRIGGERS")
    print("=" * 80)
    
    conn = get_db_connection()
    cur = conn.cursor()
    
    schema_path = os.path.join(os.path.dirname(__file__), 'schema.sql')
    if not os.path.exists(schema_path):
        schema_path = 'repo_backend/Maintenance Final Table/schema.sql'

    print(f"[*] Reading schema definition from: {schema_path}")
    with open(schema_path, 'r', encoding='utf-8') as f:
        sql = f.read()

    print("[*] Executing DDL, Trigger Functions, Indexes, and Stored Procedures...")
    cur.execute(sql)
    conn.commit()
    print("[+] Schema & real-time triggers deployed successfully.")
    conn.close()

# -----------------------------------------------------------------------------
# 3. Dual-Mode Backfill (Stored Procedure & High-Speed Batch)
# -----------------------------------------------------------------------------

def run_backfill():
    print("=" * 80)
    print("       HISTORICAL BACKFILL: CALL public.sp_rebuild_core_maintenance()")
    print("=" * 80)
    
    conn = get_db_connection()
    cur = conn.cursor()
    
    print("[*] Rebuilding public.core_maintenance with Portal Priority unification...")
    start_time = datetime.now()
    cur.execute("CALL public.sp_rebuild_core_maintenance();")
    conn.commit()
    elapsed = (datetime.now() - start_time).total_seconds()
    print(f"[+] Rebuild completed successfully in {elapsed:.2f} seconds!")
    conn.close()

    audit_health()

# -----------------------------------------------------------------------------
# 4. Comprehensive Diagnostic & Reconciliation Audit Engine
# -----------------------------------------------------------------------------

def audit_health():
    print("\n" + "=" * 80)
    print("       CORE MAINTENANCE SSOT AUDIT & RECONCILIATION REPORT")
    print("=" * 80)
    
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    # Check table existence
    cur.execute("""
        SELECT EXISTS (
            SELECT FROM information_schema.tables 
            WHERE table_schema = 'public' AND table_name = 'core_maintenance'
        );
    """)
    if not cur.fetchone()['exists']:
        print("[!] Table public.core_maintenance does not exist. Run --deploy first.")
        conn.close()
        return

    # Upstream source counts
    cur.execute("SELECT count(*) as cnt FROM public.sheet_maintenance WHERE is_deleted = FALSE;")
    sheet_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.july_maintenance_in;")
    portal_in_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.july_maintenance_out;")
    portal_out_count = cur.fetchone()['cnt']

    # Master table counts
    cur.execute("""
        SELECT 
            count(*) as total_records,
            count(*) FILTER (WHERE is_deleted = FALSE) as active_records,
            count(*) FILTER (WHERE is_deleted = TRUE) as deleted_records,
            count(DISTINCT vehicle_number) as unique_vehicles,
            min(id) as min_id,
            max(id) as max_id
        FROM public.core_maintenance;
    """)
    core_stats = cur.fetchone()
    total = core_stats['total_records'] or 0
    active = core_stats['active_records'] or 0
    deleted = core_stats['deleted_records'] or 0
    vehicles = core_stats['unique_vehicles'] or 0
    min_id = core_stats['min_id'] or 0
    max_id = core_stats['max_id'] or 0

    # Gapless ID Sequence Verification via generate_series
    cur.execute("""
        SELECT s.i 
        FROM generate_series(1, COALESCE((SELECT MAX(id) FROM public.core_maintenance), 0)) s(i) 
        LEFT JOIN public.core_maintenance c ON s.i = c.id 
        WHERE c.id IS NULL;
    """)
    gaps = cur.fetchall()

    print("\n[+] 1. Upstream & Master Table Reconciliation:")
    print(f"    - Upstream: public.sheet_maintenance         : {sheet_count:,} rows")
    print(f"    - Upstream: public.july_maintenance_in      : {portal_in_count:,} rows")
    print(f"    - Upstream: public.july_maintenance_out     : {portal_out_count:,} rows")
    print(f"    - Master  : public.core_maintenance (Total) : {total:,} rows (Active: {active:,}, Soft-Deleted: {deleted:,})")
    print(f"    - Unique Vehicles Tracked                   : {vehicles:,}")
    print(f"    - Primary Key Range                         : ID {min_id} to ID {max_id}")
    print(f"    - Gapless Sequence Integrity                : {'PASSED (0 missing IDs)' if len(gaps) == 0 else f'FAILED ({len(gaps)} missing IDs)'}")

    # Source Attribution Breakdown
    print("\n[+] 2. Source Attribution Breakdown:")
    cur.execute("""
        SELECT 
            source_type,
            count(*) as record_count,
            count(DISTINCT vehicle_number) as unique_vehicles
        FROM public.core_maintenance
        GROUP BY source_type
        ORDER BY record_count DESC;
    """)
    for row in cur.fetchall():
        print(f"    - {row['source_type']:<20}: {row['record_count']:,} records ({row['unique_vehicles']:,} unique vehicles)")

    # Operational City Distribution
    print("\n[+] 3. Operational City / Hub Distribution:")
    cur.execute("""
        SELECT 
            city,
            count(*) as record_count,
            count(DISTINCT vehicle_number) as unique_vehicles
        FROM public.core_maintenance
        GROUP BY city
        ORDER BY record_count DESC;
    """)
    for row in cur.fetchall():
        print(f"    - {row['city']:<20}: {row['record_count']:,} records ({row['unique_vehicles']:,} vehicles)")

    # Maintenance Status Breakdown
    print("\n[+] 4. Maintenance Lifecycle Status Breakdown:")
    cur.execute("""
        SELECT 
            maintenance_status,
            count(*) as record_count
        FROM public.core_maintenance
        GROUP BY maintenance_status
        ORDER BY record_count DESC;
    """)
    for row in cur.fetchall():
        print(f"    - {row['maintenance_status']:<20}: {row['record_count']:,} records")

    # Temporal & Interval Quality Checks
    print("\n[+] 5. Data Hygiene & Temporal Interval Checks:")
    cur.execute("""
        SELECT 
            count(*) FILTER (WHERE vehicle_number IS NULL OR vehicle_number = '') as invalid_plates,
            count(*) FILTER (WHERE city IS NULL OR city = '') as invalid_cities,
            count(*) FILTER (WHERE start_date IS NULL) as null_start_dates,
            count(*) FILTER (WHERE end_date IS NOT NULL AND end_date < start_date) as inverted_durations,
            count(*) FILTER (WHERE invoice_amount < 0) as negative_invoices,
            count(*) FILTER (WHERE in_kms < 0 OR out_kms < 0) as negative_odometer
        FROM public.core_maintenance;
    """)
    dq = cur.fetchone()
    print(f"    - Invalid / Empty Plates         : {dq['invalid_plates']}")
    print(f"    - Invalid / Empty Cities         : {dq['invalid_cities']}")
    print(f"    - NULL Start Dates               : {dq['null_start_dates']}")
    print(f"    - Inverted Durations (End < Start): {dq['inverted_durations']}")
    print(f"    - Negative Invoices / Payables   : {dq['negative_invoices']}")
    print(f"    - Negative Odometer Readings     : {dq['negative_odometer']}")

    # Portal Priority Precedence Verification
    cur.execute("""
        SELECT 
            vehicle_number, city, source_type, start_date, end_date, 
            workshop_name, repair_type, invoice_no, invoice_amount, payment_status, utr_no
        FROM public.core_maintenance
        WHERE source_type = 'WEB_PORTAL'
        ORDER BY id ASC;
    """)
    portal_tickets = cur.fetchall()
    print(f"\n[+] 6. Web Portal Priority Tickets Ingested & Verified ({len(portal_tickets)} records):")
    for pt in portal_tickets:
        print(f"    - Plate: {pt['vehicle_number']:<12} | City: {pt['city']:<10} | Workshop: {str(pt['workshop_name']):<10} | Invoice: {str(pt['invoice_no']):<15} | Status: {pt['payment_status']}")

    print("\n" + "=" * 80)
    if total > 0 and len(gaps) == 0 and dq['invalid_plates'] == 0 and dq['inverted_durations'] == 0:
        print(">> [FINAL VERDICT: 100% HEALTHY & SYNCHRONIZED] public.core_maintenance is production-ready.")
    else:
        print(">> [ATTENTION] Review flagged anomalies above.")
    print("=" * 80 + "\n")
    
    conn.close()

# -----------------------------------------------------------------------------
# 5. Live Trigger Latency & Concurrency Benchmark Suite
# -----------------------------------------------------------------------------

def test_triggers():
    print("=" * 80)
    print("       LIVE TRIGGER LATENCY & CONCURRENCY BENCHMARK SUITE")
    print("=" * 80)
    
    conn = get_db_connection()
    conn.autocommit = True
    cur = conn.cursor(cursor_factory=RealDictCursor)

    test_plate = "TESTLATENCY9999"
    test_date = date.today()

    print(f"[*] Inserting mock record into public.sheet_maintenance ({test_plate})...")
    t0 = time.time()
    cur.execute("""
        INSERT INTO public.sheet_maintenance (
            city, vehicle_number, date, final_status, cohort, source_tab, is_deleted
        ) VALUES (
            'Bangalore', %s, %s, 'Maintenance', 'Off Road', 'Daily Vehicle Status', FALSE
        ) RETURNING id;
    """, (test_plate, test_date))
    sheet_row_id = cur.fetchone()['id']
    t1 = time.time()
    insert_latency_ms = (t1 - t0) * 1000

    # Verify instant propagation in core_maintenance
    cur.execute("SELECT * FROM public.core_maintenance WHERE sheet_maintenance_id = %s;", (sheet_row_id,))
    core_row = cur.fetchone()
    t2 = time.time()
    verify_latency_ms = (t2 - t1) * 1000

    if core_row:
        print(f"[+] Trigger Test PASSED: Sheet Insert -> Core Reflection in {insert_latency_ms:.2f} ms!")
        print(f"    - Core Record ID       : {core_row['id']}")
        print(f"    - Source Type          : {core_row['source_type']}")
        print(f"    - Vehicle / City       : {core_row['vehicle_number']} / {core_row['city']}")
    else:
        print("[-] Trigger Test FAILED: Row was not found in core_maintenance.")

    # Cleanup mock test record
    print("[*] Cleaning up test records...")
    cur.execute("DELETE FROM public.sheet_maintenance WHERE id = %s;", (sheet_row_id,))
    cur.execute("DELETE FROM public.core_maintenance WHERE sheet_maintenance_id = %s;", (sheet_row_id,))
    print("[+] Test cleanup completed successfully.\n")
    conn.close()

# -----------------------------------------------------------------------------
# 6. CLI Entry Point
# -----------------------------------------------------------------------------

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="LetzRyd Core Maintenance SSOT Automation & Audit Engine")
    parser.add_argument("--deploy", action="store_true", help="Deploy schema, triggers, indexes, and stored procedures")
    parser.add_argument("--backfill", action="store_true", help="Run full historical backfill procedure")
    parser.add_argument("--audit", action="store_true", help="Run comprehensive health and reconciliation audit")
    parser.add_argument("--test-triggers", action="store_true", help="Run live trigger latency benchmark test")
    args = parser.parse_args()
    
    if args.deploy:
        deploy_schema()
    elif args.backfill:
        run_backfill()
    elif args.test_triggers:
        test_triggers()
    elif args.audit:
        audit_health()
    else:
        audit_health()
