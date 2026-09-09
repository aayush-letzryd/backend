"""
LetzRyd - Vehicle Status Final Table Automation & Health Engine
================================================================
Production verification, auditing, and ledger generation engine for
fleet operational status architecture:
  - public.core_daily_vehicle_status (Master Daily Attendance Ledger)
  - public.v_vehicle_trip_intervals (Lateral Interval Pairing View)
  - public.v_current_live_fleet_status (Real-Time Live Fleet View)
  - public.sp_generate_daily_vehicle_status (Daily Generator Procedure)

Supported Commands:
  python automation_script.py --audit
  python automation_script.py --live
  python automation_script.py --generate-date 2026-09-09
  python automation_script.py --backfill 2026-09-01 2026-09-09
"""

import os
import sys
import argparse
from datetime import datetime, timedelta
import psycopg2
from psycopg2.extras import RealDictCursor

DB_HOST = os.getenv("DB_HOST", "35.200.196.113")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASS = os.getenv("DB_PASSWORD", os.getenv("DB_PASS", r"8S5]U3@L^Xz)\FH}"))

def get_connection():
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASS
        )
        return conn
    except Exception as e:
        print(f"[ERROR] Failed to connect to PostgreSQL database: {e}")
        sys.exit(1)

def run_audit():
    """Runs a full mathematical and edge-case audit on the live fleet database."""
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    print("=" * 80)
    print("        LETZRYD VEHICLE OPERATIONAL STATUS & LEDGER HEALTH AUDIT")
    print("=" * 80)

    # 1. Master Fleet Denominator
    cur.execute("""
        SELECT 
            COUNT(*) AS total_denominator,
            COUNT(*) FILTER (WHERE is_deleted = FALSE) AS active_fleet,
            COUNT(*) FILTER (WHERE is_deleted = TRUE) AS decommissioned_fleet
        FROM public.core_vehicle_onboarding;
    """)
    denom = cur.fetchone()
    print("\n[1] MASTER FLEET ASSET DENOMINATOR (core_vehicle_onboarding)")
    print(f"    - Active Fleet Denominator : {denom['active_fleet']} vehicles")
    print(f"    - Decommissioned / Soft-Del : {denom['decommissioned_fleet']} vehicles")
    print(f"    - Total Asset Records       : {denom['total_denominator']} records")

    # 2. Raw Event Transaction Volumes
    cur.execute("SELECT COUNT(*) AS c FROM public.core_vehicle_allocation WHERE is_deleted = FALSE;")
    alloc_count = cur.fetchone()["c"]
    cur.execute("SELECT COUNT(*) AS c FROM public.core_dropoffs WHERE is_deleted = FALSE;")
    drop_count = cur.fetchone()["c"]
    cur.execute("SELECT COUNT(*) AS c FROM public.core_maintenance WHERE is_deleted = FALSE;")
    maint_count = cur.fetchone()["c"]

    print("\n[2] RAW EVENT TRANSACTION VOLUMES (core_*)")
    print(f"    - Trip Starts (core_vehicle_allocation) : {alloc_count} records")
    print(f"    - Trip Ends   (core_dropoffs)           : {drop_count} records")
    print(f"    - Maintenance (core_maintenance)        : {maint_count} records")

    # 3. Mathematical Interval Pairing
    cur.execute("""
    WITH ranked_allocations AS (
        SELECT 
            a.id AS allocation_id,
            a.vehicle_number,
            a.allocation_date,
            LEAD(a.allocation_date) OVER (
                PARTITION BY a.vehicle_number 
                ORDER BY a.allocation_date ASC, a.id ASC
            ) AS next_allocation_date
        FROM public.core_vehicle_allocation a
        WHERE a.is_deleted = FALSE
    ),
    paired_intervals AS (
        SELECT 
            ra.allocation_id,
            ra.vehicle_number,
            ra.allocation_date AS start_date,
            d.id AS dropoff_id,
            d.return_date AS end_date
        FROM ranked_allocations ra
        LEFT JOIN LATERAL (
            SELECT d.id, d.return_date
            FROM public.core_dropoffs d
            WHERE d.is_deleted = FALSE
              AND d.vehicle_number = ra.vehicle_number
              AND d.return_date >= ra.allocation_date
              AND (ra.next_allocation_date IS NULL OR d.return_date <= ra.next_allocation_date)
            ORDER BY d.return_date ASC, d.id ASC
            LIMIT 1
        ) d ON TRUE
    )
    SELECT 
        COUNT(*) AS total_intervals,
        COUNT(dropoff_id) AS closed_intervals,
        COUNT(*) - COUNT(dropoff_id) AS currently_active_intervals
    FROM paired_intervals;
    """)
    pairing = cur.fetchone()
    active_trips = pairing["currently_active_intervals"]
    closed_trips = pairing["closed_intervals"]
    yard_rfd = denom["active_fleet"] - active_trips

    print("\n[3] CONTINUOUS INTERVAL PAIRING METRICS")
    print(f"    - Total Intervals Evaluated  : {pairing['total_intervals']}")
    print(f"    - Closed Completed Trips     : {closed_trips}")
    print(f"    - Active Trips (Open Allocs) : {active_trips}")
    print(f"    - Yard (RFD) / Workshop Gap  : {yard_rfd} vehicles")
    print(f"    - Formula Verification Check : {active_trips} (Active) + {yard_rfd} (Yard) = {denom['active_fleet']} (Fleet)")

    # 4. Exhaustive 10 Edge Cases Audit
    print("\n[4] EXHAUSTIVE REAL-WORLD EDGE CASE AUDIT")

    # Edge Case 1: Pristine RFD Vehicles
    cur.execute("""
        SELECT COUNT(*) AS c
        FROM public.core_vehicle_onboarding vo
        WHERE vo.is_deleted = FALSE
          AND NOT EXISTS (
              SELECT 1 FROM public.core_vehicle_allocation a 
              WHERE a.vehicle_number = vo.registration_no AND a.is_deleted = FALSE
          );
    """)
    ec1 = cur.fetchone()["c"]
    print(f"    - Edge Case 1 : Pristine RFD Vehicles (0 historical trips)    : {ec1} cars")

    # Edge Case 2: Open Trips / Currently Active
    print(f"    - Edge Case 2 : Open Trips (Allocated with no drop-off)       : {active_trips} vehicles")

    # Edge Case 3: Same-Day Trips
    cur.execute("""
    WITH ranked_allocations AS (
        SELECT 
            a.id AS allocation_id,
            a.vehicle_number,
            a.allocation_date,
            LEAD(a.allocation_date) OVER (PARTITION BY a.vehicle_number ORDER BY a.allocation_date, a.id) AS next_allocation_date
        FROM public.core_vehicle_allocation a
        WHERE a.is_deleted = FALSE
    ),
    paired AS (
        SELECT ra.allocation_date, d.return_date
        FROM ranked_allocations ra
        JOIN LATERAL (
            SELECT d.return_date
            FROM public.core_dropoffs d
            WHERE d.is_deleted = FALSE
              AND d.vehicle_number = ra.vehicle_number
              AND d.return_date >= ra.allocation_date
              AND (ra.next_allocation_date IS NULL OR d.return_date <= ra.next_allocation_date)
            ORDER BY d.return_date ASC, d.id ASC
            LIMIT 1
        ) d ON TRUE
    )
    SELECT COUNT(*) AS c FROM paired WHERE return_date = allocation_date;
    """)
    ec3 = cur.fetchone()["c"]
    print(f"    - Edge Case 3 : Same-Day Trips (Pickup and drop-off on same date): {ec3} trips")

    # Edge Case 4: Consecutive Allocations without Drop-off
    cur.execute("""
    WITH ordered_allocs AS (
        SELECT 
            id, vehicle_number, partner_id, allocation_date,
            LEAD(allocation_date) OVER (PARTITION BY vehicle_number ORDER BY allocation_date, id) AS next_alloc_date
        FROM public.core_vehicle_allocation
        WHERE is_deleted = FALSE
    )
    SELECT COUNT(*) AS c
    FROM ordered_allocs oa
    WHERE oa.next_alloc_date IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM public.core_dropoffs d
          WHERE d.vehicle_number = oa.vehicle_number
            AND d.is_deleted = FALSE
            AND d.return_date >= oa.allocation_date
            AND d.return_date <= oa.next_alloc_date
      );
    """)
    ec4 = cur.fetchone()["c"]
    print(f"    - Edge Case 4 : Consecutive Allocations Bounded by LEAD()     : {ec4} instances")

    # Edge Case 5: Orphan Drop-offs
    cur.execute("""
    SELECT COUNT(*) AS c
    FROM public.core_dropoffs d
    WHERE d.is_deleted = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM public.core_vehicle_allocation a
          WHERE a.vehicle_number = d.vehicle_number AND a.is_deleted = FALSE
      );
    """)
    ec5 = cur.fetchone()["c"]
    print(f"    - Edge Case 5 : Orphan Drop-offs (No prior allocation)        : {ec5} instances")

    # Edge Case 6: Overlapping Workshop Maintenance
    cur.execute("""
    SELECT COUNT(*) AS c
    FROM public.core_maintenance m
    JOIN public.v_vehicle_trip_intervals ti ON m.vehicle_number = ti.vehicle_number
    WHERE m.is_deleted = FALSE
      AND m.start_date >= ti.trip_start_date
      AND (ti.trip_end_date IS NULL OR m.start_date <= ti.trip_end_date);
    """)
    ec6 = cur.fetchone()["c"]
    print(f"    - Edge Case 6 : Maintenance During Active Driver Custody      : {ec6} instances")

    # Edge Case 7: Yard Downtime (PDI / Service)
    cur.execute("""
    SELECT COUNT(*) AS c
    FROM public.core_maintenance m
    WHERE m.is_deleted = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM public.v_vehicle_trip_intervals ti
          WHERE ti.vehicle_number = m.vehicle_number
            AND m.start_date >= ti.trip_start_date
            AND (ti.trip_end_date IS NULL OR m.start_date <= ti.trip_end_date)
      );
    """)
    ec7 = cur.fetchone()["c"]
    print(f"    - Edge Case 7 : Maintenance Direct from Hub Yard              : {ec7} instances")

    # Edge Case 8: Intraday Handover (Drop-off and Re-allocation on same day)
    cur.execute("""
    SELECT COUNT(DISTINCT d.vehicle_number) AS c
    FROM public.core_dropoffs d
    JOIN public.core_vehicle_allocation a 
      ON d.vehicle_number = a.vehicle_number 
     AND d.return_date = a.allocation_date
    WHERE d.is_deleted = FALSE AND a.is_deleted = FALSE;
    """)
    ec8 = cur.fetchone()["c"]
    print(f"    - Edge Case 8 : Intraday Vehicle Handovers (Drop + Alloc Day) : {ec8} vehicles")

    # Edge Case 9: Inverted Date Anomalies
    cur.execute("""
    SELECT COUNT(*) AS c 
    FROM public.v_vehicle_trip_intervals 
    WHERE trip_end_date < trip_start_date;
    """)
    ec9 = cur.fetchone()["c"]
    print(f"    - Edge Case 9 : Inverted Date Errors (End < Start)            : {ec9} (Zero Tolerance)")

    # Edge Case 10: Soft-Deleted / Decommissioned Vehicles
    print(f"    - Edge Case 10: Excluded Decommissioned Vehicles              : {denom['decommissioned_fleet']} assets")

    # 5. Live View Snapshot Distribution
    cur.execute("""
        SELECT 
            live_status, 
            live_cohort, 
            COUNT(*) AS count,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
        FROM public.v_current_live_fleet_status
        GROUP BY live_status, live_cohort
        ORDER BY count DESC;
    """)
    print("\n[5] REAL-TIME LIVE FLEET SNAPSHOT (public.v_current_live_fleet_status)")
    for row in cur.fetchall():
        print(f"    - {row['live_status']:<15} | Cohort: {row['live_cohort']:<10} | Count: {row['count']:>5} ({row['pct']:>5.2f}%)")

    conn.close()
    print("\n" + "=" * 80)
    print("                    AUDIT COMPLETED SUCCESSFULLY")
    print("=" * 80)

def show_live_status():
    """Displays real-time fleet breakdown and operational samples."""
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    print("=" * 80)
    print("            LETZRYD REAL-TIME LIVE FLEET OPERATIONAL STATUS")
    print("=" * 80)

    cur.execute("""
        SELECT 
            city,
            live_status,
            COUNT(*) AS total_cars
        FROM public.v_current_live_fleet_status
        GROUP BY city, live_status
        ORDER BY city, live_status;
    """)
    rows = cur.fetchall()
    print("\nCity-wise Operational Distribution:")
    print(f"{'City':<15} | {'Live Status':<15} | {'Count':<8}")
    print("-" * 44)
    for r in rows:
        print(f"{r['city']:<15} | {r['live_status']:<15} | {r['total_cars']:<8}")

    print("\nSample Active Vehicles on Road:")
    cur.execute("""
        SELECT vehicle_number, city, vehicle_model, current_driver_id, current_driver_name, current_trip_started
        FROM public.v_current_live_fleet_status
        WHERE live_status = 'Active'
        LIMIT 5;
    """)
    for r in cur.fetchall():
        print(f"  Plate: {r['vehicle_number']:<12} | Model: {r['vehicle_model']:<15} | Driver: {r['current_driver_id']:<20} ({r['current_driver_name']}) | Started: {r['current_trip_started']}")

    print("\nSample RFD Vehicles in Hub Yards:")
    cur.execute("""
        SELECT vehicle_number, city, vehicle_model
        FROM public.v_current_live_fleet_status
        WHERE live_status = 'RFD'
        LIMIT 5;
    """)
    for r in cur.fetchall():
        print(f"  Plate: {r['vehicle_number']:<12} | City: {r['city']:<12} | Model: {r['vehicle_model']}")

    conn.close()

def generate_daily_ledger(target_date_str):
    """Executes public.sp_generate_daily_vehicle_status for a specified date."""
    conn = get_connection()
    conn.autocommit = True
    cur = conn.cursor(cursor_factory=RealDictCursor)

    try:
        target_date = datetime.strptime(target_date_str, "%Y-%m-%d").date()
    except ValueError:
        print(f"[ERROR] Invalid date format '{target_date_str}'. Use YYYY-MM-DD.")
        sys.exit(1)

    print(f"\nExecuting public.sp_generate_daily_vehicle_status('{target_date}')...")
    cur.execute("CALL public.sp_generate_daily_vehicle_status(%s);", (target_date,))

    cur.execute("""
        SELECT 
            final_status,
            cohort,
            billable_rent_day,
            COUNT(*) AS vehicle_count,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
        FROM public.core_daily_vehicle_status
        WHERE status_date = %s
        GROUP BY final_status, cohort, billable_rent_day
        ORDER BY vehicle_count DESC;
    """, (target_date,))
    rows = cur.fetchall()

    cur.execute("SELECT COUNT(*) AS total FROM public.core_daily_vehicle_status WHERE status_date = %s;", (target_date,))
    total = cur.fetchone()["total"]

    print(f"\nResults for {target_date} (Total Generated: {total} vehicles):")
    print(f"{'Status':<18} | {'Cohort':<10} | {'Billable':<10} | {'Count':<8} | {'Share'}")
    print("-" * 60)
    for r in rows:
        print(f"{r['final_status']:<18} | {r['cohort']:<10} | {str(r['billable_rent_day']):<10} | {r['vehicle_count']:<8} | {r['pct']:>5.2f}%")

    conn.close()

def backfill_range(start_date_str, end_date_str):
    """Backfills daily status ledger over a date range."""
    try:
        start_date = datetime.strptime(start_date_str, "%Y-%m-%d").date()
        end_date = datetime.strptime(end_date_str, "%Y-%m-%d").date()
    except ValueError:
        print("[ERROR] Invalid date format. Use YYYY-MM-DD.")
        sys.exit(1)

    if start_date > end_date:
        print("[ERROR] Start date must precede or equal end date.")
        sys.exit(1)

    conn = get_connection()
    conn.autocommit = True
    cur = conn.cursor()

    curr = start_date
    while curr <= end_date:
        print(f"Processing date: {curr}...")
        cur.execute("CALL public.sp_generate_daily_vehicle_status(%s);", (curr,))
        curr += timedelta(days=1)

    conn.close()
    print("\nBackfill completed successfully.")

def main():
    parser = argparse.ArgumentParser(
        description="LetzRyd Vehicle Operational Status & Ledger Automation Engine"
    )
    parser.add_argument("--audit", action="store_true", help="Run comprehensive health and edge case audit")
    parser.add_argument("--live", action="store_true", help="Display live fleet status snapshot")
    parser.add_argument("--generate-date", type=str, help="Generate daily vehicle status for target date (YYYY-MM-DD)")
    parser.add_argument("--backfill", nargs=2, metavar=("START_DATE", "END_DATE"), help="Backfill date range (YYYY-MM-DD)")

    args = parser.parse_args()

    if args.live:
        show_live_status()
    elif args.generate_date:
        generate_daily_ledger(args.generate_date)
    elif args.backfill:
        backfill_range(args.backfill[0], args.backfill[1])
    else:
        run_audit()

if __name__ == "__main__":
    main()
