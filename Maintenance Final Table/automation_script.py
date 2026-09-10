import sys
import argparse
from datetime import datetime
import psycopg2
from psycopg2.extras import RealDictCursor

DB_CONFIG = {
    "host": "35.200.196.113",
    "port": 5432,
    "dbname": "postgres",
    "user": "postgres",
    "password": r"8S5]U3@L^Xz)\FH}"
}

def get_connection():
    return psycopg2.connect(**DB_CONFIG)

def deploy_schema():
    print("=" * 80)
    print("       DEPLOYING SCHEMA: public.core_maintenance & REAL-TIME TRIGGERS")
    print("=" * 80)
    
    conn = get_connection()
    cur = conn.cursor()
    
    schema_path = 'Maintenance Final Table/schema.sql'
    try:
        with open(schema_path, 'r', encoding='utf-8') as f:
            sql = f.read()
    except FileNotFoundError:
        with open('repo_backend/Maintenance Final Table/schema.sql', 'r', encoding='utf-8') as f:
            sql = f.read()

    print("Executing DDL, Triggers, and Stored Procedures...")
    cur.execute(sql)
    conn.commit()
    print("Schema deployed successfully.")
    conn.close()

def run_backfill():
    print("=" * 80)
    print("       HISTORICAL BACKFILL: CALL public.sp_rebuild_core_maintenance()")
    print("=" * 80)
    
    conn = get_connection()
    cur = conn.cursor()
    
    print("Rebuilding public.core_maintenance (Portal Priority Unification)...")
    start_time = datetime.now()
    cur.execute("CALL public.sp_rebuild_core_maintenance();")
    conn.commit()
    elapsed = (datetime.now() - start_time).total_seconds()
    print(f"Rebuild completed successfully in {elapsed:.2f} seconds!")
    conn.close()

    run_audit()

def run_audit():
    print("\n" + "=" * 80)
    print("       CORE MAINTENANCE SSOT AUDIT REPORT (public.core_maintenance)")
    print("=" * 80)
    
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    # 1. Record Counts & Sequence Health
    print("\n[1] Record Counts & Primary Key Sequence Health:")
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
    r = cur.fetchone()
    total = r['total_records'] or 0
    min_id = r['min_id'] or 0
    max_id = r['max_id'] or 0
    gaps = (max_id - min_id + 1 - total) if (total and min_id and max_id) else 0
    
    print(f"  * Total Core Records : {total:,}")
    print(f"  * Active Records     : {r['active_records']:,}")
    print(f"  * Deleted Records    : {r['deleted_records']:,}")
    print(f"  * Unique Vehicles    : {r['unique_vehicles']:,}")
    print(f"  * ID Range           : {min_id} to {max_id}")
    print(f"  * Sequence Gaps      : {gaps}")

    # 2. Source Attribution Breakdown
    print("\n[2] Source Attribution Breakdown:")
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
        print(f"  * {row['source_type']}: {row['record_count']:,} records ({row['unique_vehicles']:,} vehicles)")

    # 3. Operational Hub Distribution
    print("\n[3] Operational City / Hub Distribution:")
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
        print(f"  * {row['city']}: {row['record_count']:,} records ({row['unique_vehicles']:,} vehicles)")

    # 4. Status Breakdown
    print("\n[4] Maintenance Status Breakdown:")
    cur.execute("""
        SELECT 
            maintenance_status,
            count(*) as record_count
        FROM public.core_maintenance
        GROUP BY maintenance_status
        ORDER BY record_count DESC;
    """)
    for row in cur.fetchall():
        print(f"  * {row['maintenance_status']}: {row['record_count']:,} records")

    # 5. Data Quality & Deduplication Checks
    print("\n[5] Data Quality & Uniqueness Integrity:")
    cur.execute("""
        SELECT 
            count(*) FILTER (WHERE vehicle_number IS NULL OR vehicle_number = '') as invalid_plates,
            count(*) FILTER (WHERE city IS NULL OR city = '') as invalid_cities,
            count(*) FILTER (WHERE start_date IS NULL) as null_start_dates,
            count(*) FILTER (WHERE end_date IS NOT NULL AND end_date < start_date) as inverted_durations
        FROM public.core_maintenance;
    """)
    dq = cur.fetchone()
    print(f"  * Invalid / Empty Plates     : {dq['invalid_plates']}")
    print(f"  * Invalid / Empty Cities     : {dq['invalid_cities']}")
    print(f"  * NULL Start Dates           : {dq['null_start_dates']}")
    print(f"  * Inverted Durations         : {dq['inverted_durations']}")

    print("\n" + "=" * 80)
    if total > 0 and gaps == 0 and dq['invalid_plates'] == 0 and dq['inverted_durations'] == 0:
        print(">> [STATUS: 100% HEALTHY] public.core_maintenance is fully synchronized and valid.")
    elif total == 0:
        print(">> [STATUS: READY] Table deployed. Run --backfill to populate historical data.")
    else:
        print(">> [ATTENTION] Review flagged anomalies above.")
    print("=" * 80)
    
    conn.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="LetzRyd Core Maintenance SSOT Automation Engine")
    parser.add_argument("--deploy", action="store_true", help="Deploy schema, triggers, and procedures")
    parser.add_argument("--backfill", action="store_true", help="Run full historical backfill procedure")
    parser.add_argument("--audit", action="store_true", help="Run diagnostic health audit")
    args = parser.parse_args()
    
    if args.deploy:
        deploy_schema()
    elif args.backfill:
        run_backfill()
    elif args.audit:
        run_audit()
    else:
        run_audit()
