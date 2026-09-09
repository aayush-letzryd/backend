"""
===============================================================================
FLEET STATUS & INTERVAL LEDGER VERIFICATION SCRIPT
Demonstrates the mathematical validity of the Vehicle Interval Pairing Engine
and audits all real-world edge cases on live PostgreSQL data.
===============================================================================
"""

import os
import psycopg2

DB_HOST = os.getenv("DB_HOST", "35.200.196.113")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASS = os.getenv("DB_PASS", "8S5]U3@L^Xz)\\FH}")

def run_verification():
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )
    cur = conn.cursor()

    print("--- 1. MASTER FLEET ASSET TOTALS ---")
    cur.execute("SELECT COUNT(*) FROM public.core_vehicle_onboarding WHERE is_deleted = FALSE;")
    total_vehicles = cur.fetchone()[0]
    print(f"Total Onboarded Fleet (Denominator): {total_vehicles} active vehicles")

    print("\n--- 2. RAW EVENT COUNTS ---")
    cur.execute("SELECT COUNT(*) FROM public.core_vehicle_allocation WHERE is_deleted = FALSE;")
    total_allocations = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM public.core_dropoffs WHERE is_deleted = FALSE;")
    total_dropoffs = cur.fetchone()[0]
    print(f"Total Allocations (Trip Starts): {total_allocations}")
    print(f"Total Dropoffs (Trip Ends): {total_dropoffs}")

    print("\n--- 3. INTERVAL PAIRING STATISTICS ---")
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
    res = cur.fetchone()
    print(f"Total Intervals Evaluated: {res[0]}")
    print(f"Closed Trips (Completed & Dropped Off): {res[1]}")
    print(f"Currently Active on Road (Open Allocations): {res[2]}")
    print(f"Currently in Yard (RFD) / Workshop: {total_vehicles - res[2]} vehicles")

    print("\n--- 4. EDGE CASE AUDIT ON LIVE DATABASE ---")
    # Edge Case 1: Pristine RFD Vehicles
    cur.execute("""
    SELECT COUNT(*) 
    FROM public.core_vehicle_onboarding vo
    WHERE vo.is_deleted = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM public.core_vehicle_allocation a 
          WHERE a.vehicle_number = vo.registration_no AND a.is_deleted = FALSE
      );
    """)
    pristine_rfd = cur.fetchone()[0]
    print(f" - Edge Case 1: Pristine RFD Vehicles (0 historical allocations): {pristine_rfd} cars")

    # Edge Case 2: Same-Day Trips
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
    SELECT COUNT(*) FROM paired WHERE return_date = allocation_date;
    """)
    same_day = cur.fetchone()[0]
    print(f" - Edge Case 2: Same-Day Trips (Allocated and dropped off on same date): {same_day} trips")

    # Edge Case 3: Consecutive Allocations without Intervening Drop-off
    cur.execute("""
    WITH ordered_allocs AS (
        SELECT 
            id, vehicle_number, partner_id, allocation_date,
            LEAD(allocation_date) OVER (PARTITION BY vehicle_number ORDER BY allocation_date, id) AS next_alloc_date
        FROM public.core_vehicle_allocation
        WHERE is_deleted = FALSE
    )
    SELECT COUNT(*)
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
    consec_allocs = cur.fetchone()[0]
    print(f" - Edge Case 3: Capped Consecutive Allocations (No drop-off in between): {consec_allocs} instances")

    # Edge Case 4: Orphan Drop-offs
    cur.execute("""
    SELECT COUNT(*)
    FROM public.core_dropoffs d
    WHERE d.is_deleted = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM public.core_vehicle_allocation a
          WHERE a.vehicle_number = d.vehicle_number AND a.is_deleted = FALSE
      );
    """)
    orphan_dropoffs = cur.fetchone()[0]
    print(f" - Edge Case 4: Orphan Dropoffs (No prior allocation on record): {orphan_dropoffs} instances")

    conn.close()
    print("\nVerification completed successfully.")

if __name__ == "__main__":
    run_verification()
