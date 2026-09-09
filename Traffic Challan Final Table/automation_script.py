"""
LetzRyd - Traffic Challan Master Core Table Automation & Reconciliation Engine
=============================================================================
Synchronizes, backfills, and audits public.core_challans as the Single Source
of Truth combining public.sheet_challans and public.vehicle_challans (Karnataka One Scraper).

Usage:
    python automation_script.py --audit
    python automation_script.py --backfill
"""

import os
import sys
import re
import argparse
import psycopg2
from psycopg2.extras import RealDictCursor

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

def audit_health():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    print("=" * 70)
    print("=== Master Traffic Challans (public.core_challans) Health Audit ===")
    print("=" * 70)

    # Check table existence
    cur.execute("""
        SELECT EXISTS (
            SELECT FROM information_schema.tables 
            WHERE table_schema = 'public' AND table_name = 'core_challans'
        );
    """)
    if not cur.fetchone()['exists']:
        print("[!] Table public.core_challans does not exist yet. Run --backfill first.")
        conn.close()
        return

    cur.execute("SELECT count(*) as cnt FROM public.sheet_challans;")
    sheet_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.vehicle_challans;")
    auto_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.core_challans;")
    core_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.core_challans WHERE is_deleted = FALSE;")
    active_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.core_challans WHERE is_deleted = TRUE;")
    deleted_count = cur.fetchone()['cnt']

    cur.execute("SELECT MIN(id) as min_id, MAX(id) as max_id FROM public.core_challans;")
    id_range = cur.fetchone()

    # Gap check
    cur.execute("""
        SELECT s.i 
        FROM generate_series(1, COALESCE((SELECT MAX(id) FROM public.core_challans), 0)) s(i) 
        LEFT JOIN public.core_challans c ON s.i = c.id 
        WHERE c.id IS NULL;
    """)
    gaps = cur.fetchall()

    print(f"\n[+] Upstream Source Counts:")
    print(f"    - public.sheet_challans (Manual Ops Sheets) : {sheet_count:,} rows")
    print(f"    - public.vehicle_challans (Karnataka One)  : {auto_count:,} rows")
    print(f"\n[+] Master Core Table (public.core_challans):")
    print(f"    - Total Master Records                      : {core_count:,}")
    print(f"    - Active Records                            : {active_count:,}")
    print(f"    - Soft Deleted Records                      : {deleted_count:,}")
    print(f"    - ID Sequence Range                         : {id_range['min_id']} to {id_range['max_id']}")
    print(f"    - Sequence Gaps (Missing IDs)               : {len(gaps)}")

    # Distribution by Source System
    cur.execute("""
        SELECT source_system, count(*) as cnt, COALESCE(SUM(total_pending), 0) as total_debt
        FROM public.core_challans 
        GROUP BY source_system 
        ORDER BY cnt DESC;
    """)
    print("\n[+] Source System Breakdown:")
    for row in cur.fetchall():
        print(f"    - {row['source_system']:<28}: {row['cnt']:,} rows | Pending: Rs. {row['total_debt']:,.2f}")

    # Breakdown by City
    cur.execute("""
        SELECT city, count(*) as cnt, COALESCE(SUM(total_pending), 0) as total_debt
        FROM public.core_challans 
        GROUP BY city 
        ORDER BY cnt DESC;
    """)
    print("\n[+] City Breakdown:")
    for row in cur.fetchall():
        print(f"    - {row['city']:<20}: {row['cnt']:,} rows | Pending: Rs. {row['total_debt']:,.2f}")

    # Breakdown by Liability Type
    cur.execute("""
        SELECT liability_type, count(*) as cnt, COALESCE(SUM(challan_amount), 0) as fine_sum, COALESCE(SUM(total_pending), 0) as pend_sum
        FROM public.core_challans 
        GROUP BY liability_type 
        ORDER BY cnt DESC;
    """)
    print("\n[+] Liability Type Breakdown:")
    for row in cur.fetchall():
        print(f"    - {row['liability_type']:<20}: {row['cnt']:,} rows | Fines: Rs. {row['fine_sum']:,.2f} | Pending: Rs. {row['pend_sum']:,.2f}")

    # Breakdown by Payment Status
    cur.execute("""
        SELECT payment_status, count(*) as cnt 
        FROM public.core_challans 
        GROUP BY payment_status 
        ORDER BY cnt DESC;
    """)
    print("\n[+] Payment Status Breakdown:")
    for row in cur.fetchall():
        print(f"    - {row['payment_status']:<20}: {row['cnt']:,} rows")

    conn.close()
    print("\n" + "=" * 70)

def backfill_core_table():
    print("=" * 70)
    print("=== Starting Backfill for public.core_challans ===")
    print("=" * 70)

    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    # 1. Apply schema.sql
    schema_path = os.path.join(os.path.dirname(__file__), 'schema.sql')
    if os.path.exists(schema_path):
        print("[1/4] Applying schema.sql DDL & triggers...")
        with open(schema_path, 'r', encoding='utf-8') as f:
            cur.execute(f.read())
        conn.commit()

    # 2. Acquire advisory lock
    print("[2/4] Acquiring advisory lock (888999222)...")
    cur.execute("SELECT pg_advisory_xact_lock(888999222);")

    # 3. Ingest from public.vehicle_challans (Karnataka One Scraper - Status = HAS_FINES)
    print("[3/4] Ingesting automated Karnataka One violations...")
    cur.execute("""
        INSERT INTO public.core_challans (
            id,
            source_system, source_table, automated_challan_id,
            vehicle_reg_no, rc_holder_name, notice_no, city, week_cycle,
            violation_date, violation_time, notice_date,
            violation_description, police_station, violation_location, liability_type,
            challan_amount, sticker_fine, previous_balance, amount_paid, total_pending,
            payment_status, scraped_at,
            is_deleted, created_at, updated_at
        )
        SELECT 
            ROW_NUMBER() OVER (ORDER BY v.id ASC) as id,
            'KARNATAKA_ONE_SCRAPER' as source_system,
            'vehicle_challans' as source_table,
            v.id as automated_challan_id,
            public.fn_clean_challan_plate(v.vehicle_reg_no) as vehicle_reg_no,
            NULLIF(v.rc_holder_name, 'ERROR') as rc_holder_name,
            v.notice_no,
            'Bangalore' as city,
            'AUTOMATION_SCRAPER' as week_cycle,
            public.fn_parse_challan_date(v.violation_date) as violation_date,
            public.fn_parse_challan_time(v.violation_time) as violation_time,
            public.fn_parse_challan_date(v.notice_generation_date) as notice_date,
            NULLIF(v.offence_description, '') as violation_description,
            NULLIF(v.point_name, '') as police_station,
            NULLIF(v.point_name, '') as violation_location,
            'TRAFFIC_FINE' as liability_type,
            COALESCE(v.fine_amount, 0.00) as challan_amount,
            0.00 as sticker_fine,
            0.00 as previous_balance,
            0.00 as amount_paid,
            COALESCE(v.fine_amount, 0.00) as total_pending,
            'PENDING' as payment_status,
            public.fn_parse_challan_date(SUBSTRING(v.scraped_timestamp FROM 1 FOR 10)) as scraped_at,
            FALSE as is_deleted,
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') as created_at,
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') as updated_at
        FROM public.vehicle_challans v
        WHERE v.status = 'HAS_FINES' 
          AND v.notice_no != 'ERROR' 
          AND v.notice_no IS NOT NULL
          AND public.fn_clean_challan_plate(v.vehicle_reg_no) IS NOT NULL
        ON CONFLICT (id) DO NOTHING;
    """)
    conn.commit()

    # Update sequence after scraper insert
    cur.execute("SELECT COALESCE(MAX(id), 0) as max_id FROM public.core_challans;")
    max_id_after_auto = cur.fetchone()['max_id']
    print(f"    - Ingested automated scraper rows. Current MAX(id): {max_id_after_auto}")

    # 4. Ingest & Merge from public.sheet_challans
    print("[4/4] Ingesting & reconciling manual sheet challan logs...")
    cur.execute(f"""
        INSERT INTO public.core_challans (
            id,
            source_system, source_table, sheet_challan_id,
            vehicle_reg_no, notice_no, city, week_cycle,
            violation_date, violation_time, notice_date, audit_date,
            liability_type,
            challan_amount, sticker_fine, previous_balance, amount_paid, total_pending,
            payment_status, remarks, source_tab, sheet_row_number,
            is_deleted, created_at, updated_at
        )
        SELECT 
            {max_id_after_auto} + ROW_NUMBER() OVER (ORDER BY s.id ASC) as id,
            'GOOGLE_SHEET' as source_system,
            'sheet_challans' as source_table,
            s.id as sheet_challan_id,
            public.fn_clean_challan_plate(s.vehicle_reg_no) as vehicle_reg_no,
            s.notice_no,
            CASE 
                WHEN LOWER(TRIM(COALESCE(s.city, ''))) LIKE '%hyd%' THEN 'Hyderabad'
                WHEN LOWER(TRIM(COALESCE(s.city, ''))) LIKE '%mum%' THEN 'Mumbai'
                WHEN LOWER(TRIM(COALESCE(s.city, ''))) LIKE '%pun%' THEN 'Pune'
                ELSE 'Bangalore'
            END as city,
            s.week_cycle,
            s.violation_date,
            s.violation_time,
            s.notice_date,
            s.audit_date,
            CASE 
                WHEN COALESCE(s.challan_amount, 0.00) > 0 THEN 'TRAFFIC_FINE'
                WHEN COALESCE(s.sticker_fine, 0.00) > 0 THEN 'STICKER_FINE'
                ELSE 'ROLLING_BALANCE'
            END as liability_type,
            COALESCE(s.challan_amount, 0.00) as challan_amount,
            COALESCE(s.sticker_fine, 0.00) as sticker_fine,
            COALESCE(s.previous_balance, 0.00) as previous_balance,
            COALESCE(s.amount_paid, 0.00) as amount_paid,
            COALESCE(s.total_pending, 0.00) as total_pending,
            CASE 
                WHEN COALESCE(s.total_pending, 0.00) <= 0 AND (COALESCE(s.challan_amount, 0) > 0 OR COALESCE(s.sticker_fine, 0) > 0) THEN 'PAID'
                WHEN COALESCE(s.amount_paid, 0.00) > 0 AND COALESCE(s.total_pending, 0.00) > 0 THEN 'PARTIALLY_PAID'
                ELSE 'PENDING'
            END as payment_status,
            NULLIF(s.remarks, '') as remarks,
            s.source_tab,
            s.sheet_row_number,
            COALESCE(s.is_deleted, FALSE) as is_deleted,
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') as created_at,
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') as updated_at
        FROM public.sheet_challans s
        WHERE public.fn_clean_challan_plate(s.vehicle_reg_no) IS NOT NULL
        ON CONFLICT (id) DO NOTHING;
    """)
    conn.commit()

    # Set final sequence value
    cur.execute("SELECT setval('public.core_challans_id_seq', COALESCE((SELECT MAX(id) FROM public.core_challans), 1), true);")
    conn.commit()
    conn.close()

    print("\n[+] Backfill successfully completed!")
    audit_health()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Core Challans Reconciliation Engine")
    parser.add_argument('--audit', action='store_true', help='Audit public.core_challans health & reconciliation')
    parser.add_argument('--backfill', action='store_true', help='Backfill & reconcile public.core_challans')
    args = parser.parse_args()

    if args.backfill:
        backfill_core_table()
    else:
        audit_health()
