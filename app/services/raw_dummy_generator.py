"""
raw_dummy_generator.py — Generates Realistic Platform Trip & Incentive Data
===========================================================================
Populates raw_uber_data, raw_ola_data, raw_rapido_data, raw_uber_incentives,
raw_ola_incentives, raw_rapido_incentives with realistic simulated trip data
linked to vehicles and drivers currently populated in app_drivers.
"""

import random
from datetime import datetime, date, timedelta
from decimal import Decimal
from typing import List, Dict, Any
from sqlalchemy import text
from sqlalchemy.orm import Session
import psycopg2.extras
import logging

logger = logging.getLogger("raw_dummy_generator")

from typing import List, Dict, Any, Optional

def generate_raw_platform_dummy_data(db: Session, sample_size: Optional[int] = None, week_number: int = 28):
    """
    Generates realistic dummy trips and incentives in raw tables for testing
    the full end-to-end Hisaab calculation and aggregation pipeline.
    """
    logger.info(f"Generating realistic raw dummy platform data for week {week_number}...")

    # 1. Fetch active drivers and their vehicle registration numbers
    query_str = """
        SELECT app_driver_id, driver_code, full_name, vehicle_reg_number, operator_id
        FROM app_drivers
        WHERE vehicle_reg_number IS NOT NULL AND TRIM(vehicle_reg_number) != ''
    """
    if sample_size is not None:
        query_str += f" LIMIT {sample_size}"

    drivers = db.execute(text(query_str)).fetchall()

    if not drivers:
        logger.warning("No drivers found in app_drivers to generate dummy data for!")
        return

    # Calculate date range for week_number (e.g. Week 28 of 2026)
    # Week 28 in 2026 is Mon 2026-07-06 to Sun 2026-07-12
    week_start = date(2026, 7, 6)
    week_end = date(2026, 7, 12)
    now = datetime.now()

    raw_conn = db.connection().connection

    uber_trips = []
    ola_trips = []
    rapido_trips = []
    uber_inc = {}
    ola_inc = {}
    rapido_inc = {}

    random.seed(42)  # Deterministic seed for reproducible tests

    for d in drivers:
        v_num = d.vehicle_reg_number.strip()
        drv_name = d.full_name.strip()
        drv_id = d.app_driver_id

        # Generate 4-8 Uber trips for this driver
        num_uber = random.randint(4, 8)
        for i in range(num_uber):
            t_date = week_start + timedelta(days=random.randint(0, 6))
            trip_fare = round(random.uniform(250.0, 750.0), 2)
            cash_pct = random.choice([0.0, 0.0, 0.5, 1.0])
            cash_col = round(trip_fare * cash_pct, 2)
            tolls = round(random.choice([0.0, 0.0, 45.0, 90.0]), 2)
            dist_km = round(trip_fare / random.uniform(18.0, 24.0), 2)

            uber_trips.append((
                v_num, f"UBER-{drv_id}-{week_number}-{i+1}", drv_name, t_date, week_start, week_end,
                "completed", trip_fare, cash_col, tolls, 0.0, 0.0, dist_km, now
            ))

        # Generate 3-6 Ola trips for this driver
        num_ola = random.randint(3, 6)
        for i in range(num_ola):
            t_date = week_start + timedelta(days=random.randint(0, 6))
            trip_fare = round(random.uniform(200.0, 650.0), 2)
            cash_pct = random.choice([0.0, 0.0, 0.4, 1.0])
            cash_col = round(trip_fare * cash_pct, 2)
            tolls = round(random.choice([0.0, 0.0, 30.0]), 2)
            dist_km = round(trip_fare / random.uniform(17.0, 22.0), 2)

            ola_trips.append((
                v_num, f"OLA-{drv_id}-{week_number}-{i+1}", drv_name, t_date, week_start, week_end,
                "completed", trip_fare, cash_col, tolls, 0.0, 0.0, dist_km, now
            ))

        # Generate 2-5 Rapido trips for this driver
        num_rapido = random.randint(2, 5)
        for i in range(num_rapido):
            t_date = week_start + timedelta(days=random.randint(0, 6))
            trip_fare = round(random.uniform(150.0, 450.0), 2)
            cash_pct = random.choice([0.0, 0.3, 1.0])
            cash_col = round(trip_fare * cash_pct, 2)
            tolls = 0.0
            dist_km = round(trip_fare / random.uniform(16.0, 20.0), 2)

            rapido_trips.append((
                v_num, f"RAP-{drv_id}-{week_number}-{i+1}", drv_name, t_date, week_start, week_end,
                trip_fare, cash_col, tolls, 0.0, dist_km, now
            ))

        # Weekly platform incentives for this driver
        u_inc_amt = round(random.choice([0.0, 300.0, 500.0, 800.0]), 2)
        if u_inc_amt > 0:
            key = (v_num, week_start, week_end)
            if key in uber_inc:
                prev = uber_inc[key]
                uber_inc[key] = (v_num, drv_name, week_start, week_end, round(prev[4] + u_inc_amt, 2), prev[5] + num_uber, now)
            else:
                uber_inc[key] = (v_num, drv_name, week_start, week_end, u_inc_amt, num_uber, now)

        o_inc_amt = round(random.choice([0.0, 200.0, 400.0, 600.0]), 2)
        if o_inc_amt > 0:
            key = (v_num, week_start, week_end)
            if key in ola_inc:
                prev = ola_inc[key]
                ola_inc[key] = (v_num, drv_name, week_start, week_end, round(prev[4] + o_inc_amt, 2), prev[5] + num_ola, now)
            else:
                ola_inc[key] = (v_num, drv_name, week_start, week_end, o_inc_amt, num_ola, now)

        r_inc_amt = round(random.choice([0.0, 150.0, 300.0]), 2)
        if r_inc_amt > 0:
            key = (v_num, week_start, week_end)
            if key in rapido_inc:
                prev = rapido_inc[key]
                rapido_inc[key] = (v_num, drv_name, week_start, week_end, round(prev[4] + r_inc_amt, 2), prev[5] + num_rapido, now)
            else:
                rapido_inc[key] = (v_num, drv_name, week_start, week_end, r_inc_amt, num_rapido, now)

    # Bulk insert into raw tables
    with raw_conn.cursor() as cur:
        # Uber
        if uber_trips:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO raw_uber_data (
                    vehicle_number, trip_id, driver_name, trip_date, week_start, week_end,
                    trip_status, net_revenue, cash_collected, tolls, incentives, subscription_fee, distance_km, imported_at
                ) VALUES %s
            """, uber_trips, page_size=500)

        # Ola
        if ola_trips:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO raw_ola_data (
                    vehicle_number, crn, driver_name, trip_date, week_start, week_end,
                    completion_status, net_revenue, cash_collected, tolls, incentives, subscription_fee, actual_kms, imported_at
                ) VALUES %s
            """, ola_trips, page_size=500)

        # Rapido
        if rapido_trips:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO raw_rapido_data (
                    vehicle_number, trip_id, driver_name, trip_date, week_start, week_end,
                    net_revenue, cash_collected, tolls, incentives, distance_kms, imported_at
                ) VALUES %s
            """, rapido_trips, page_size=500)

        # Uber Incentives
        if uber_inc:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO raw_uber_incentives (
                    vehicle_number, driver_name, week_start, week_end, amount, trips_completed, imported_at
                ) VALUES %s
            """, list(uber_inc.values()), page_size=500)

        # Ola Incentives
        if ola_inc:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO raw_ola_incentives (
                    vehicle_number, driver_name, week_start, week_end, amount, trips_completed, imported_at
                ) VALUES %s
            """, list(ola_inc.values()), page_size=500)

        # Rapido Incentives
        if rapido_inc:
            psycopg2.extras.execute_values(cur, """
                INSERT INTO raw_rapido_incentives (
                    vehicle_number, driver_name, week_start, week_end, amount, trips_completed, imported_at
                ) VALUES %s
            """, list(rapido_inc.values()), page_size=500)

    db.commit()
    logger.info(f"Successfully generated {len(uber_trips)} Uber trips, {len(ola_trips)} Ola trips, {len(rapido_trips)} Rapido trips, and platform incentives in raw tables.")
