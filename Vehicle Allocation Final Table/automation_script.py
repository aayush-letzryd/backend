"""
LetzRyd - Vehicle Allocation Final Table Automation & Health Engine
====================================================================
Synchronizes, audits, and validates public.core_vehicle_allocation as the
Single Source of Truth combining:
  1. public.sheet_vehicle_allocations (Google Sheet operational entries)
  2. public.july_allocation_form (Web Portal vehicle allocations and handovers)

Architectural Guarantees:
  - Dual-Source Automatic Merging on (allocation_date, vehicle_number, partner_id)
  - Gapless 1..N ID sequence integrity (Zero Sequence Burning)
  - Pure IST Timestamps (TIMESTAMP WITHOUT TIME ZONE, 0 timezone offset)
  - Soft-Delete Protection (is_deleted = TRUE, deleted_at = CURRENT_TIMESTAMP)
  - 19 Verified Column Mappings between Sheet and Portal

Usage:
    python automation_script.py --audit
    python automation_script.py --backfill
    python automation_script.py --verify-triggers
"""

import os
import re
import sys
import argparse
import psycopg2
from psycopg2.extras import RealDictCursor

DB_HOST = os.getenv("DB_HOST", "YOUR_DB_HOST_HERE")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "YOUR_DB_PASSWORD_HERE")

def get_connection():
    if DB_HOST == "YOUR_DB_HOST_HERE" or DB_PASSWORD == "YOUR_DB_PASSWORD_HERE":
        raise ValueError(
            "Database credentials not configured. Please set the DB_HOST, DB_PORT, "
            "DB_NAME, DB_USER, and DB_PASSWORD environment variables."
        )
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
    """Runs a full integrity audit on core_vehicle_allocation and upstream sources."""
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    print("=================================================================")
    print("      CORE VEHICLE ALLOCATION HEALTH & RECONCILIATION AUDIT      ")
    print("=================================================================\n")

    # 1. Counts from Upstream Sources
    cur.execute("SELECT count(*) as count FROM public.sheet_vehicle_allocations;")
    sheet_total = cur.fetchone()["count"]

    cur.execute("SELECT count(*) as count FROM public.july_allocation_form;")
    portal_total = cur.fetchone()["count"]

    # Portal valid vs rejected (excluding drop-offs and invalid formats)
    cur.execute("""
        SELECT count(*) as count 
        FROM public.july_allocation_form
        WHERE allocation_date IS NOT NULL
          AND LENGTH(REGEXP_REPLACE(UPPER(COALESCE(vehicle_number, '')), '[^A-Z0-9]', '', 'g')) BETWEEN 8 AND 12
          AND REGEXP_REPLACE(UPPER(TRIM(COALESCE(driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\\1IP') ~ '^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$'
          AND REGEXP_REPLACE(LOWER(TRIM(COALESCE(allocation_type, ''))), '[\\s\\-_]', '', 'g') != 'dropoff';
    """)
    portal_valid = cur.fetchone()["count"]
    portal_rejected = portal_total - portal_valid

    # 2. Counts in Core Master Table
    cur.execute("SELECT count(*) as count FROM public.core_vehicle_allocation;")
    core_total = cur.fetchone()["count"]

    cur.execute("SELECT count(*) as count FROM public.core_vehicle_allocation WHERE is_deleted = FALSE;")
    core_active = cur.fetchone()["count"]

    cur.execute("SELECT count(*) as count FROM public.core_vehicle_allocation WHERE is_deleted = TRUE;")
    core_deleted = cur.fetchone()["count"]

    print("1. Upstream Source Volume:")
    print(f"   - Google Sheets (sheet_vehicle_allocations) : {sheet_total} rows")
    print(f"   - Web Portal    (july_allocation_form)       : {portal_total} rows (Valid: {portal_valid}, Test/Rejected: {portal_rejected})")
    print(f"\n2. Master Table Volume (core_vehicle_allocation):")
    print(f"   - Total Records     : {core_total}")
    print(f"   - Active Records    : {core_active}")
    print(f"   - Soft-Deleted Rows : {core_deleted}")

    # 3. Source Origin Breakdown
    print("\n3. Provenance Distribution (source_origin):")
    cur.execute("""
        SELECT source_origin, count(*) as count 
        FROM public.core_vehicle_allocation 
        GROUP BY source_origin 
        ORDER BY count DESC;
    """)
    for r in cur.fetchall():
        print(f"   - {r['source_origin']:18} : {r['count']} rows")

    # 4. Hub / City Breakdown
    print("\n4. City Distribution (Standardized):")
    cur.execute("""
        SELECT city, count(*) as count 
        FROM public.core_vehicle_allocation 
        GROUP BY city 
        ORDER BY count DESC;
    """)
    for r in cur.fetchall():
        print(f"   - {r['city']:18} : {r['count']} rows")

    # 5. Allocation Type Breakdown
    print("\n5. Allocation Type Distribution (Standardized):")
    cur.execute("""
        SELECT allocation_type, count(*) as count 
        FROM public.core_vehicle_allocation 
        GROUP BY allocation_type 
        ORDER BY count DESC;
    """)
    for r in cur.fetchall():
        print(f"   - {r['allocation_type']:18} : {r['count']} rows")

    # 6. ID Sequence Continuity
    cur.execute("SELECT MIN(id) as min_id, MAX(id) as max_id FROM public.core_vehicle_allocation;")
    id_range = cur.fetchone()
    min_id = id_range["min_id"]
    max_id = id_range["max_id"]

    cur.execute("""
        SELECT s.i 
        FROM generate_series(1, COALESCE((SELECT MAX(id) FROM public.core_vehicle_allocation), 0)) s(i) 
        LEFT JOIN public.core_vehicle_allocation c ON s.i = c.id 
        WHERE c.id IS NULL;
    """)
    gaps = cur.fetchall()

    is_gapless = (min_id == 1 and max_id == core_total and len(gaps) == 0)
    print(f"\n6. ID Sequence Continuity Integrity:")
    print(f"   - ID Range          : {min_id} to {max_id}")
    print(f"   - Total Rows        : {core_total}")
    print(f"   - Sequence Gaps     : {len(gaps)}")
    print(f"   - Gapless Status    : {'PASSED (Continuous 1..N Sequence, Zero Gaps)' if is_gapless else 'FAILED'}")

    # 7. Timestamp Offset Verification
    cur.execute("""
        SELECT column_name, data_type 
        FROM information_schema.columns 
        WHERE table_schema = 'public' 
          AND table_name = 'core_vehicle_allocation'
          AND data_type LIKE '%timestamp%'
        ORDER BY column_name;
    """)
    ts_cols = cur.fetchall()
    all_ts_clean = all(c["data_type"] == "timestamp without time zone" for c in ts_cols)
    print(f"\n7. Timestamp Integrity:")
    print(f"   - Timestamp Columns : {', '.join(c['column_name'] for c in ts_cols)}")
    print(f"   - Types Compliance  : {'PASSED (All TIMESTAMP WITHOUT TIME ZONE)' if all_ts_clean else 'FAILED'}")

    print("\n=================================================================")
    print("                      AUDIT COMPLETE                             ")
    print("=================================================================\n")

    conn.close()

def run_backfill():
    """Calls the stored procedure sp_backfill_core_vehicle_allocation() to re-seed core."""
    conn = get_connection()
    cur = conn.cursor()
    print("Executing public.sp_backfill_core_vehicle_allocation()...")
    cur.execute("CALL public.sp_backfill_core_vehicle_allocation();")
    for notice in conn.notices:
        print("NOTICE:", notice.strip())
    print("Backfill procedure executed successfully.")
    conn.close()
    audit_health()

def verify_triggers():
    """Tests live trigger operations: insert, update, merge, soft-delete, and sequence cleanup."""
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    print("=================================================================")
    print("          LIVE TRIGGER SYNCHRONIZATION VERIFICATION              ")
    print("=================================================================\n")

    test_veh = "KA01AUTO9999"
    test_did = "LETZBLRIP9999999999"
    test_phone = "9999999999"
    test_date = "2026-09-08"

    # Pre-clean
    cur.execute("DELETE FROM public.sheet_vehicle_allocations WHERE vehicle_number = %s;", (test_veh,))
    cur.execute("DELETE FROM public.july_allocation_form WHERE vehicle_number = %s;", (test_veh,))
    cur.execute("DELETE FROM public.core_vehicle_allocation WHERE vehicle_number = %s;", (test_veh,))

    # Step 1: Sheet INSERT
    print("1. Testing Sheet Ingestion (INSERT on public.sheet_vehicle_allocations)...")
    cur.execute("""
        INSERT INTO public.sheet_vehicle_allocations (
            allocation_date, vehicle_number, operator_driver_id, driver_phone,
            driver_name, city, allocation_type, jack, created_at, updated_at
        ) VALUES (
            %s, %s, %s, %s,
            'AUTOMATION TEST DRIVER', 'Bengaluru', 'New Allocation', 'Yes',
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        ) RETURNING id;
    """, (test_date, test_veh, test_did, test_phone))
    sheet_id = cur.fetchone()["id"]
    cur.execute("SELECT id, source_origin, sheet_record_id, jack FROM public.core_vehicle_allocation WHERE vehicle_number = %s;", (test_veh,))
    core_row = cur.fetchone()
    assert core_row is not None, "Failed: Row was not synced to core_vehicle_allocation"
    assert core_row["source_origin"] == "GOOGLE_SHEET", f"Unexpected source_origin: {core_row['source_origin']}"
    assert core_row["sheet_record_id"] == sheet_id, "Sheet record id mismatch"
    print(f"   [PASS] Synced to core (id={core_row['id']}, origin={core_row['source_origin']}, sheet_id={core_row['sheet_record_id']})")

    # Step 2: Sheet UPDATE
    print("\n2. Testing Sheet Update (UPDATE on public.sheet_vehicle_allocations)...")
    cur.execute("""
        UPDATE public.sheet_vehicle_allocations 
        SET jack = 'No',
            reason_to_visit = 'Automated Verification Update',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = %s;
    """, (sheet_id,))
    cur.execute("SELECT jack, reason_to_visit FROM public.core_vehicle_allocation WHERE vehicle_number = %s;", (test_veh,))
    updated_core = cur.fetchone()
    assert updated_core["jack"] == "No", "Update failed: jack value did not sync"
    assert updated_core["reason_to_visit"] == "Automated Verification Update", "Update failed: reason did not sync"
    print(f"   [PASS] Updated in core (jack={updated_core['jack']}, reason={updated_core['reason_to_visit']})")

    # Step 3: Portal Overlay (MERGE)
    print("\n3. Testing Portal Overlay / Merge (INSERT on public.july_allocation_form)...")
    cur.execute("""
        INSERT INTO public.july_allocation_form (
            allocation_date, vehicle_number, driver_id, driver_phone,
            driver_name, city_name, allocation_type, insp_jack, insp_remarks,
            status, created_at, updated_at
        ) VALUES (
            %s, %s, %s, %s,
            'AUTOMATION TEST DRIVER', 'Bangalore', 'Fresh Allocation', 'Yes', 'Merged Audit Passed',
            'Approved', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        ) RETURNING id;
    """, (test_date, test_veh, test_did, test_phone))
    portal_id = cur.fetchone()["id"]
    cur.execute("SELECT source_origin, sheet_record_id, portal_record_id, status, insp_remarks FROM public.core_vehicle_allocation WHERE vehicle_number = %s;", (test_veh,))
    merged_core = cur.fetchone()
    assert merged_core["source_origin"] == "MERGED", f"Failed: Expected 'MERGED' but got {merged_core['source_origin']}"
    assert merged_core["portal_record_id"] == portal_id, "Portal record id mismatch"
    assert merged_core["sheet_record_id"] == sheet_id, "Sheet record id should be preserved"
    assert merged_core["status"] == "Approved", "Status not updated from portal"
    print(f"   [PASS] Successfully merged (origin={merged_core['source_origin']}, sheet_id={merged_core['sheet_record_id']}, portal_id={merged_core['portal_record_id']})")

    # Step 4: Drop-Off Rejection Verification
    print("\n4. Testing Drop-Off Rejection (INSERT Drop-Off on public.july_allocation_form)...")
    test_dropoff_veh = "TESTDROPOFF99"
    cur.execute("""
        INSERT INTO public.july_allocation_form (
            allocation_date, vehicle_number, driver_id, driver_phone,
            driver_name, city_name, allocation_type, status, created_at, updated_at
        ) VALUES (
            %s, %s, %s, %s,
            'DROPOFF TEST DRIVER', 'Bangalore', 'Drop-Off',
            'Approved', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        ) RETURNING id;
    """, (test_date, test_dropoff_veh, test_did, test_phone))
    cur.execute("SELECT count(*) as count FROM public.core_vehicle_allocation WHERE vehicle_number = %s;", (test_dropoff_veh,))
    dropoff_in_core = cur.fetchone()["count"]
    assert dropoff_in_core == 0, f"Failed: Drop-Off entered core_vehicle_allocation! Found {dropoff_in_core} rows"
    cur.execute("DELETE FROM public.july_allocation_form WHERE vehicle_number = %s;", (test_dropoff_veh,))
    print(f"   [PASS] Drop-off successfully blocked from entering core (count in core = {dropoff_in_core})")

    # Step 5: Soft-Delete
    print("\n5. Testing Soft-Delete Protection (DELETE on public.sheet_vehicle_allocations)...")
    cur.execute("DELETE FROM public.sheet_vehicle_allocations WHERE id = %s;", (sheet_id,))
    cur.execute("SELECT is_deleted, deleted_at FROM public.core_vehicle_allocation WHERE vehicle_number = %s;", (test_veh,))
    deleted_core = cur.fetchone()
    assert deleted_core["is_deleted"] is True, "Soft-delete failed: is_deleted is not TRUE"
    assert deleted_core["deleted_at"] is not None, "Soft-delete failed: deleted_at is NULL"
    print(f"   [PASS] Soft-delete verified (is_deleted={deleted_core['is_deleted']}, deleted_at={deleted_core['deleted_at']})")

    # Step 6: Cleanup & Sequence Realignment (Non-Destructive)
    print("\n6. Cleaning Up Test Artifacts & Realigning Sequence...")
    cur.execute("DELETE FROM public.sheet_vehicle_allocations WHERE vehicle_number = %s;", (test_veh,))
    cur.execute("DELETE FROM public.july_allocation_form WHERE vehicle_number = %s;", (test_veh,))
    cur.execute("DELETE FROM public.core_vehicle_allocation WHERE vehicle_number = %s;", (test_veh,))
    cur.execute("SELECT setval('public.core_vehicle_allocation_id_seq', COALESCE((SELECT MAX(id) FROM public.core_vehicle_allocation), 1), true);")

    cur.execute("SELECT count(*) as total, MIN(id) as min_id, MAX(id) as max_id FROM public.core_vehicle_allocation;")
    final_stats = cur.fetchone()
    cur.execute("""
        SELECT s.i 
        FROM generate_series(1, COALESCE((SELECT MAX(id) FROM public.core_vehicle_allocation), 0)) s(i) 
        LEFT JOIN public.core_vehicle_allocation c ON s.i = c.id 
        WHERE c.id IS NULL;
    """)
    final_gaps = cur.fetchall()
    assert len(final_gaps) == 0, f"Gaps detected after cleanup: {final_gaps}"
    print(f"   [PASS] Sequence Restored: {final_stats['total']} rows (IDs {final_stats['min_id']}..{final_stats['max_id']}), 0 gaps.")

    print("\n=================================================================")
    print("             TRIGGER VERIFICATION PASSED (100%)                  ")
    print("=================================================================\n")

    conn.close()

def main():
    parser = argparse.ArgumentParser(description="LetzRyd Vehicle Allocation Automation Engine")
    parser.add_argument("--audit", action="store_true", help="Run database health & reconciliation audit")
    parser.add_argument("--backfill", action="store_true", help="Execute full historical backfill procedure")
    parser.add_argument("--verify-triggers", action="store_true", help="Test live trigger sync, merge, and soft-delete")

    args = parser.parse_args()

    if args.backfill:
        run_backfill()
    elif args.verify_triggers:
        verify_triggers()
    else:
        audit_health()

if __name__ == "__main__":
    main()
