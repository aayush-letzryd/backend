"""
LetzRyd - Fleet Maintenance Final Table Automation & Health Engine
===================================================================
Synchronizes, audits, and validates public.core_maintenance as the
Single Source of Truth combining:
  1. public.sheet_maintenance (Google Sheets operational status extract)
  2. public.july_maintenance_in & public.july_maintenance_out (Web Portal)

Architectural Guarantees:
  - Dual-source consolidation into canonical public.core_maintenance
  - Temporal interval pairing (inward entry to outward release)
  - Zero negative duration enforcement (end_date >= start_date)
  - Soft-delete propagation (is_deleted = TRUE, deleted_at = CURRENT_TIMESTAMP)
  - Gapless sequential primary key integrity

Usage:
    python automation_script.py --audit
    python automation_script.py --backfill
    python automation_script.py --verify-triggers
    python automation_script.py --repair-intervals
"""

import os
import sys
import argparse
import logging
from datetime import datetime
import psycopg2
from psycopg2.extras import RealDictCursor

# Database credentials configuration
DB_HOST = os.getenv("DB_HOST", "35.200.196.113")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", r"8S5]U3@L^Xz)\FH}")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("core_maintenance_engine")


def get_connection():
    """Establishes connection to the PostgreSQL database."""
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD
        )
        conn.autocommit = True
        return conn
    except Exception as e:
        logger.error(f"Failed to connect to database at {DB_HOST}:{DB_PORT}/{DB_NAME}: {e}")
        raise


def audit_health():
    """Runs a full integrity audit on core_maintenance and upstream sources."""
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    print("=" * 80)
    print("      FLEET MAINTENANCE (public.core_maintenance) HEALTH & AUDIT REPORT      ")
    print("=" * 80)

    # 1. Table Existence Check
    tables_to_check = [
        "core_maintenance",
        "sheet_maintenance",
        "july_maintenance_in",
        "july_maintenance_out"
    ]
    existence = {}
    for table in tables_to_check:
        cur.execute("""
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables 
                WHERE table_schema = 'public' AND table_name = %s
            ) AS tbl_exists;
        """, (table,))
        existence[table] = cur.fetchone()["tbl_exists"]

    print("\n[1] Upstream & Master Table Existence:")
    for table, exists in existence.items():
        status_label = "EXISTS" if exists else "MISSING"
        print(f"    - public.{table:<25}: {status_label}")

    if not existence["core_maintenance"]:
        print("\n[!] Error: Table public.core_maintenance does not exist. Run schema.sql first.")
        conn.close()
        return

    # 2. Row Counts Across Sources
    counts = {}
    for table in ["july_maintenance_in", "july_maintenance_out", "sheet_maintenance"]:
        if existence[table]:
            cur.execute(f"SELECT COUNT(*) AS cnt FROM public.{table};")
            counts[table] = cur.fetchone()["cnt"]
        else:
            counts[table] = 0

    cur.execute("SELECT COUNT(*) AS cnt FROM public.core_maintenance;")
    total_core = cur.fetchone()["cnt"]

    cur.execute("SELECT COUNT(*) AS cnt FROM public.core_maintenance WHERE is_deleted = FALSE;")
    active_core = cur.fetchone()["cnt"]

    cur.execute("SELECT COUNT(*) AS cnt FROM public.core_maintenance WHERE is_deleted = TRUE;")
    deleted_core = cur.fetchone()["cnt"]

    print("\n[2] Record Counts & Provenance:")
    print(f"    - Web Portal Inward (july_maintenance_in)   : {counts['july_maintenance_in']:,} rows")
    print(f"    - Web Portal Outward (july_maintenance_out) : {counts['july_maintenance_out']:,} rows")
    print(f"    - Google Sheets (sheet_maintenance)         : {counts['sheet_maintenance']:,} rows")
    print(f"    - Master Core Table Total Records           : {total_core:,} rows")
    print(f"      * Active Records (is_deleted = FALSE)     : {active_core:,} rows")
    print(f"      * Soft-Deleted (is_deleted = TRUE)        : {deleted_core:,} rows")

    # 3. Data Source Breakdown
    cur.execute("""
        SELECT data_source, COUNT(*) AS cnt
        FROM public.core_maintenance
        WHERE is_deleted = FALSE
        GROUP BY data_source
        ORDER BY cnt DESC;
    """)
    source_dist = cur.fetchall()
    print("\n[3] Active Records by Data Source:")
    for row in source_dist:
        print(f"    - {row['data_source']:<28}: {row['cnt']:,} rows")

    # 4. Maintenance Status Breakdown
    cur.execute("""
        SELECT status, COUNT(*) AS cnt
        FROM public.core_maintenance
        WHERE is_deleted = FALSE
        GROUP BY status
        ORDER BY cnt DESC;
    """)
    status_dist = cur.fetchall()
    print("\n[4] Maintenance Status Breakdown:")
    for row in status_dist:
        print(f"    - {row['status']:<28}: {row['cnt']:,} rows")

    # 5. Continuous Interval Pairing Audit
    if existence["july_maintenance_in"] and existence["july_maintenance_out"]:
        cur.execute("""
            SELECT 
                COUNT(*) FILTER (WHERE mo.id IS NOT NULL) AS paired_count,
                COUNT(*) FILTER (WHERE mo.id IS NULL AND mi.is_closed = FALSE) AS open_inward_count,
                COUNT(*) FILTER (WHERE mo.id IS NULL AND mi.is_closed = TRUE) AS closed_without_outward
            FROM public.july_maintenance_in mi
            LEFT JOIN public.july_maintenance_out mo ON mo.inward_id = mi.id;
        """)
        pairing_stats = cur.fetchone()

        cur.execute("""
            SELECT COUNT(*) AS orphaned_outward
            FROM public.july_maintenance_out mo
            LEFT JOIN public.july_maintenance_in mi ON mo.inward_id = mi.id
            WHERE mi.id IS NULL;
        """)
        orphaned_outward = cur.fetchone()["orphaned_outward"]

        print("\n[5] Portal Interval Pairing Integrity:")
        print(f"    - Inward Paired with Outward Record         : {pairing_stats['paired_count']:,} pairs")
        print(f"    - Open In-Progress Inward Records           : {pairing_stats['open_inward_count']:,} rows")
        print(f"    - Closed Inward without Outward Record      : {pairing_stats['closed_without_outward']:,} rows")
        print(f"    - Orphaned Outward Records (No Inward)      : {orphaned_outward:,} rows")

    # 6. Zero Negative Duration Check
    cur.execute("""
        SELECT COUNT(*) AS neg_cnt
        FROM public.core_maintenance
        WHERE is_deleted = FALSE
          AND end_date IS NOT NULL
          AND end_date < start_date;
    """)
    negative_duration_count = cur.fetchone()["neg_cnt"]

    print("\n[6] Interval Duration Integrity (end_date >= start_date):")
    if negative_duration_count == 0:
        print("    - Negative Duration Violations              : 0 (PASSED)")
    else:
        print(f"    - Negative Duration Violations              : {negative_duration_count} (FAILED)")
        cur.execute("""
            SELECT id, vehicle_number, start_date, end_date, (end_date - start_date) AS diff_days
            FROM public.core_maintenance
            WHERE is_deleted = FALSE
              AND end_date IS NOT NULL
              AND end_date < start_date
            LIMIT 5;
        """)
        violators = cur.fetchall()
        print("      Sample Violations:")
        for v in violators:
            print(f"      * ID {v['id']} ({v['vehicle_number']}): {v['start_date']} to {v['end_date']} ({v['diff_days']} days)")

    # 7. Active Workshop Summary & Longest Downtimes
    cur.execute("""
        SELECT 
            COALESCE(workshop_name, 'Unassigned Workshop') AS workshop_name,
            city,
            COUNT(*) AS vehicle_count,
            MIN(start_date) AS earliest_entry,
            MAX(CURRENT_DATE - start_date) AS max_days_in_shop
        FROM public.core_maintenance
        WHERE is_deleted = FALSE
          AND status = 'IN_PROGRESS'
          AND end_date IS NULL
        GROUP BY COALESCE(workshop_name, 'Unassigned Workshop'), city
        ORDER BY vehicle_count DESC;
    """)
    workshop_summary = cur.fetchall()

    print("\n[7] Active Workshop Breakdown (Vehicles Currently in Repair):")
    if workshop_summary:
        print(f"    {'Workshop Name':<35} {'City':<15} {'Vehicles':<10} {'Max Days in Shop':<15}")
        print("    " + "-" * 75)
        for ws in workshop_summary:
            print(f"    {ws['workshop_name'][:34]:<35} {ws['city']:<15} {ws['vehicle_count']:<10} {ws['max_days_in_shop']:<15}")
    else:
        print("    - No vehicles currently in workshop.")

    # 8. Financial Cost Reconciliation
    cur.execute("""
        SELECT 
            COALESCE(SUM(estimated_cost), 0.00) AS total_est,
            COALESCE(SUM(actual_cost), 0.00) AS total_act,
            COUNT(*) FILTER (WHERE actual_cost > estimated_cost * 1.5 AND estimated_cost > 0) AS high_cost_variance_count,
            COUNT(*) FILTER (WHERE status = 'COMPLETED' AND actual_cost = 0) AS zero_cost_completed_count
        FROM public.core_maintenance
        WHERE is_deleted = FALSE;
    """)
    fin = cur.fetchone()

    print("\n[8] Financial & Invoicing Audit:")
    print(f"    - Total Estimated Cost                     : Rs. {fin['total_est']:,.2f}")
    print(f"    - Total Actual Invoiced Cost               : Rs. {fin['total_act']:,.2f}")
    print(f"    - Jobs with Cost Variance > 50%            : {fin['high_cost_variance_count']:,} jobs")
    print(f"    - Completed Jobs with Zero Actual Cost     : {fin['zero_cost_completed_count']:,} jobs")

    print("\n" + "=" * 80)
    print("                              AUDIT COMPLETE                              ")
    print("=" * 80 + "\n")

    conn.close()


def backfill_consolidation():
    """Executes the full consolidation procedure refresh_core_maintenance()."""
    conn = get_connection()
    cur = conn.cursor()

    logger.info("Executing public.refresh_core_maintenance() backfill procedure...")
    start_time = datetime.now()

    try:
        cur.execute("CALL public.refresh_core_maintenance();")
        duration = (datetime.now() - start_time).total_seconds()
        logger.info(f"Consolidation procedure completed successfully in {duration:.2f} seconds.")

        cur.execute("SELECT COUNT(*) FROM public.core_maintenance WHERE is_deleted = FALSE;")
        active_count = cur.fetchone()[0]
        logger.info(f"Total active records in public.core_maintenance: {active_count:,}")
    except Exception as e:
        logger.error(f"Error executing refresh_core_maintenance: {e}")
        raise
    finally:
        conn.close()


def repair_intervals():
    """Repairs invalid intervals (end_date < start_date) and synchronizes status."""
    conn = get_connection()
    cur = conn.cursor()

    logger.info("Running automated interval repair routine...")

    try:
        # Step 1: Clamp inverted dates
        cur.execute("""
            UPDATE public.core_maintenance
            SET end_date = start_date,
                updated_at = CURRENT_TIMESTAMP
            WHERE end_date IS NOT NULL AND end_date < start_date;
        """)
        clamped_rows = cur.rowcount
        logger.info(f"Clamped {clamped_rows} inverted intervals where end_date < start_date.")

        # Step 2: Ensure status consistency
        cur.execute("""
            UPDATE public.core_maintenance
            SET status = 'COMPLETED',
                updated_at = CURRENT_TIMESTAMP
            WHERE end_date IS NOT NULL AND status <> 'COMPLETED';
        """)
        completed_rows = cur.rowcount
        logger.info(f"Synchronized {completed_rows} rows to 'COMPLETED' (end_date was present).")

        cur.execute("""
            UPDATE public.core_maintenance
            SET status = 'IN_PROGRESS',
                updated_at = CURRENT_TIMESTAMP
            WHERE end_date IS NULL AND status = 'COMPLETED';
        """)
        reopened_rows = cur.rowcount
        logger.info(f"Synchronized {reopened_rows} rows to 'IN_PROGRESS' (end_date was NULL).")

        logger.info("Interval repair routine completed successfully.")
    except Exception as e:
        logger.error(f"Interval repair failed: {e}")
        raise
    finally:
        conn.close()


def verify_triggers():
    """Performs simulated transactional insert/update/delete tests to verify triggers."""
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )
    # Use explicit transaction so all test rows are rolled back
    conn.autocommit = False
    cur = conn.cursor(cursor_factory=RealDictCursor)

    test_vehicle = "TEST99ZZ0001"
    print("=" * 80)
    print("               TRIGGER SYNCHRONIZATION TRANSACTIONAL TEST                ")
    print("=" * 80)

    try:
        # Test 1: Web Portal Inward Trigger
        print("\n[Test 1] Testing sync_core_maintenance_from_portal() on july_maintenance_in...")
        cur.execute("""
            INSERT INTO public.july_maintenance_in (
                vehicle_number, city_name, vehicle_in_date_time, vehicle_k_m_s,
                repair_type, workshop_name, estimated_amount, is_closed
            ) VALUES (
                %s, 'Bengaluru', '2026-09-01 10:00:00', '15000',
                'Brake Pad Replacement', 'Apex Auto Bengaluru', '3500.00', FALSE
            ) RETURNING id;
        """, (test_vehicle,))
        in_id = cur.fetchone()["id"]

        cur.execute("""
            SELECT * FROM public.core_maintenance
            WHERE portal_maintenance_in_id = %s;
        """, (in_id,))
        core_in = cur.fetchone()

        if core_in and core_in["status"] == "IN_PROGRESS" and core_in["vehicle_number"] == test_vehicle:
            print("    -> PASS: Inward record successfully propagated to core_maintenance.")
        else:
            print(f"    -> FAIL: Record not propagated properly: {core_in}")

        # Test 2: Web Portal Outward Trigger
        print("\n[Test 2] Testing sync_core_maintenance_from_portal() on july_maintenance_out...")
        cur.execute("""
            INSERT INTO public.july_maintenance_out (
                inward_id, vehicle_number, vehicle_out_date_time, vehicle_out_k_m_s,
                invoice_no, letzryd_payable, invoice_amount, final_status
            ) VALUES (
                %s, %s, '2026-09-03 16:00:00', '15050',
                'INV-TEST-001', '3200.00', '3200.00', 'Completed & RFD'
            ) RETURNING id;
        """, (in_id, test_vehicle))
        out_id = cur.fetchone()["id"]

        cur.execute("""
            SELECT * FROM public.core_maintenance
            WHERE portal_maintenance_in_id = %s;
        """, (in_id,))
        core_closed = cur.fetchone()

        if core_closed and core_closed["status"] == "COMPLETED" and core_closed["actual_cost"] == 3200.00:
            print("    -> PASS: Outward release closed the interval in core_maintenance with actual cost.")
        else:
            print(f"    -> FAIL: Outward pairing failed: {core_closed}")

        # Test 3: Google Sheets Staging Trigger
        print("\n[Test 3] Testing sync_core_maintenance_from_sheet() on sheet_maintenance...")
        cur.execute("""
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables 
                WHERE table_schema = 'public' AND table_name = 'sheet_maintenance'
            ) AS tbl_exists;
        """)
        sheet_exists = cur.fetchone()["tbl_exists"]

        if sheet_exists:
            test_sheet_veh = "TEST99ZZ0002"
            cur.execute("""
                INSERT INTO public.sheet_maintenance (
                    vehicle_number, city, start_date, end_date, maintenance_date, status,
                    workshop_name, estimated_cost, actual_cost
                ) VALUES (
                    %s, 'Hyderabad', '2026-09-05', '2026-09-07', '2026-09-05', 'COMPLETED',
                    'Speedy Service Hub', 2500.00, 2400.00
                ) RETURNING id;
            """, (test_sheet_veh,))
            sheet_id = cur.fetchone()["id"]

            cur.execute("""
                SELECT * FROM public.core_maintenance
                WHERE sheet_maintenance_id = %s;
            """, (sheet_id,))
            core_sheet = cur.fetchone()

            if core_sheet and core_sheet["data_source"] == "SHEET_STATUS_EXTRACT" and core_sheet["status"] == "COMPLETED":
                print("    -> PASS: Google Sheets record synced into core_maintenance.")
            else:
                print(f"    -> FAIL: Sheet sync failed: {core_sheet}")

            # Test Soft Delete on Sheet
            cur.execute("DELETE FROM public.sheet_maintenance WHERE id = %s;", (sheet_id,))
            cur.execute("SELECT is_deleted FROM public.core_maintenance WHERE sheet_maintenance_id = %s;", (sheet_id,))
            del_check = cur.fetchone()
            if del_check and del_check["is_deleted"] is True:
                print("    -> PASS: Deleting from sheet_maintenance flagged soft-delete in core_maintenance.")
            else:
                print(f"    -> FAIL: Soft delete propagation failed: {del_check}")
        else:
            print("    -> SKIP: public.sheet_maintenance does not exist yet.")

    except Exception as e:
        print(f"\n[!] Trigger test raised exception: {e}")
    finally:
        # Always rollback test transaction
        conn.rollback()
        conn.close()
        print("\n[!] Test transaction rolled back cleanly. No dummy data committed.")
        print("=" * 80 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="LetzRyd Fleet Maintenance Master Table Automation & Verification Engine"
    )
    parser.add_argument("--audit", action="store_true", help="Run comprehensive health and integrity audit")
    parser.add_argument("--backfill", action="store_true", help="Execute consolidation backfill procedure")
    parser.add_argument("--verify-triggers", action="store_true", help="Test trigger synchronization with rollback")
    parser.add_argument("--repair-intervals", action="store_true", help="Repair inverted intervals and status flags")

    args = parser.parse_args()

    if not any([args.audit, args.backfill, args.verify_triggers, args.repair_intervals]):
        parser.print_help()
        sys.exit(1)

    if args.backfill:
        backfill_consolidation()
    if args.repair_intervals:
        repair_intervals()
    if args.verify_triggers:
        verify_triggers()
    if args.audit:
        audit_health()


if __name__ == "__main__":
    main()
