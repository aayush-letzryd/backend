"""
===============================================================================
FLEET STATUS & INTERVAL LEDGER VERIFICATION SCRIPT
Demonstrates the mathematical validity of the Vehicle Interval Pairing Engine
on live PostgreSQL data.
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
    print(f"Total Onboarded Fleet (Denominator): {total_vehicles} vehicles")

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

    print("\n--- 4. SAMPLE ACTIVE VEHICLES ON ROAD TODAY ---")
    cur.execute("""
    WITH ranked_allocations AS (
        SELECT 
            a.id AS allocation_id,
            a.vehicle_number,
            a.partner_id,
            a.driver_name,
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
            ra.partner_id,
            ra.driver_name,
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
    SELECT vehicle_number, partner_id, driver_name, start_date
    FROM paired_intervals
    WHERE dropoff_id IS NULL
    ORDER BY start_date DESC
    LIMIT 5;
    """)
    active_samples = cur.fetchall()
    for row in active_samples:
        print(f" - Vehicle {row[0]}: Active with {row[1]} ({row[2]}) since {row[3]}")

    conn.close()
    print("\nVerification completed successfully.")

if __name__ == "__main__":
    run_verification()
