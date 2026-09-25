"""
LetzRyd - Master Traffic Challans Automation & Operational Audit Engine
=============================================================================
Manages public.core_challans as the Single Source of Truth for all traffic
violations across Bangalore (scraped), Mumbai, and Hyderabad (sheets).

Usage:
    python automation_script.py --sync
    python automation_script.py --audit
    python automation_script.py --vehicle KA05AP6034
    python automation_script.py --weekly CY26WK37
"""

import os
import sys
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

def sync_core():
    print("=== Executing public.sp_sync_core_challans() ===")
    conn = get_db_connection()
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("CALL public.sp_sync_core_challans();")
    print("[+] Synchronization completed successfully in PostgreSQL.")
    conn.close()

def audit_health():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    print("=" * 75)
    print("=== Master Traffic Challans (public.core_challans) Operational Audit ===")
    print("=" * 75)

    cur.execute("SELECT count(*) as cnt FROM public.core_challans;")
    total_cnt = cur.fetchone()['cnt']
    print(f"Total Master Records: {total_cnt}")

    cur.execute("""
        SELECT 
            city,
            COUNT(*) AS total_count,
            COUNT(CASE WHEN payment_status = 'UNPAID' THEN 1 END) AS unpaid_count,
            COUNT(CASE WHEN payment_status = 'PAID' THEN 1 END) AS paid_count,
            SUM(challan_amount) AS total_fines,
            SUM(CASE WHEN payment_status = 'UNPAID' THEN net_pending_amount ELSE 0.00 END) AS pending_liability
        FROM public.core_challans
        WHERE is_deleted = FALSE
        GROUP BY city
        ORDER BY total_count DESC;
    """)
    print("\n--- City Breakdown (Total vs Technically Pending) ---")
    for r in cur.fetchall():
        print(f"  {r['city']:<12}: Total={r['total_count']:<5} | Unpaid={r['unpaid_count']:<5} | Paid={r['paid_count']:<5} | Fines=Rs. {r['total_fines']:<10.2f} | Pending Dues=Rs. {r['pending_liability']:<10.2f}")

    cur.execute("""
        SELECT source_system, source_priority, COUNT(*) as cnt, SUM(challan_amount) as sum_fines
        FROM public.core_challans
        WHERE is_deleted = FALSE
        GROUP BY source_system, source_priority
        ORDER BY cnt DESC;
    """)
    print("\n--- Source Hierarchy Distribution ---")
    for r in cur.fetchall():
        print(f"  {r['source_system']:<25} ({r['source_priority']:<15}): {r['cnt']:<5} records | Rs. {r['sum_fines']:<10.2f}")

    cur.execute("""
        SELECT vehicle_reg_no, notice_no, COUNT(*) as cnt
        FROM public.core_challans
        GROUP BY vehicle_reg_no, notice_no
        HAVING COUNT(*) > 1;
    """)
    dups = cur.fetchall()
    print(f"\n[+] Duplicate Notice Check: {len(dups)} duplicates found (0 expected).")

    cur.execute("SELECT COUNT(*) as cnt FROM public.core_challans WHERE violation_date IS NULL;")
    null_dates = cur.fetchone()['cnt']
    print(f"[+] Missing Violation Dates: {null_dates} records (0 expected).")

    conn.close()

def query_vehicle(reg_no):
    clean_reg = reg_no.replace(' ', '').replace('-', '').upper()
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    print(f"\n=== Challan History for Vehicle: {clean_reg} ===")
    
    cur.execute("""
        SELECT 
            violation_date, violation_time, notice_no, offence_description,
            police_station, challan_amount, sticker_fine, net_pending_amount,
            payment_status, source_system
        FROM public.core_challans
        WHERE vehicle_reg_no = %s AND is_deleted = FALSE
        ORDER BY violation_date DESC, violation_time DESC NULLS LAST;
    """, (clean_reg,))
    rows = cur.fetchall()
    if not rows:
        print(f"No records found for vehicle {clean_reg}.")
    else:
        print(f"Found {len(rows)} infraction record(s):")
        for r in rows:
            print(f"  [{r['violation_date']} {r['violation_time'] or ''}] Notice: {r['notice_no']} | {r['offence_description'] or 'N/A'} | Fine: Rs. {r['challan_amount']} | Pending: Rs. {r['net_pending_amount']} | Status: {r['payment_status']} ({r['source_system']})")
    conn.close()

def query_weekly(week_id):
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    print(f"\n=== Weekly Pending Challans for Hisaab Cycle: {week_id} ===")
    
    cur.execute("""
        SELECT 
            vehicle_reg_no, city, total_violations, pending_count,
            week_police_fine, week_pending_amount, notice_numbers
        FROM public.v_weekly_vehicle_pending_challans
        WHERE settlement_week = %s AND pending_count > 0
        ORDER BY week_pending_amount DESC
        LIMIT 25;
    """, (week_id,))
    rows = cur.fetchall()
    if not rows:
        print(f"No pending challans found for settlement week {week_id}.")
    else:
        print(f"Top {len(rows)} vehicle(s) with pending challans in {week_id}:")
        for r in rows:
            print(f"  {r['vehicle_reg_no']} ({r['city']}): {r['pending_count']} pending | Total Dues: Rs. {r['week_pending_amount']} | Notices: {r['notice_numbers']}")
    conn.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Master Traffic Challan Operations Engine')
    parser.add_argument('--sync', action='store_true', help='Execute hourly batch sync procedure')
    parser.add_argument('--audit', action='store_true', help='Audit public.core_challans health & integrity')
    parser.add_argument('--vehicle', type=str, help='Query challans for a specific vehicle registration plate')
    parser.add_argument('--weekly', type=str, help='Query pending challans for a Hisaab settlement week (e.g. CY26WK37)')

    args = parser.parse_args()

    if args.sync:
        sync_core()
    elif args.audit:
        audit_health()
    elif args.vehicle:
        query_vehicle(args.vehicle)
    elif args.weekly:
        query_weekly(args.weekly)
    else:
        audit_health()
