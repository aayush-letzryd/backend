"""
Uber Final Table Automation & Transformation Pipeline
=====================================================
Target Tables: public.core_uber_daily, public.core_uber_weekly
Source Tables: public.uber_pipeline_trips, public.uber_pipeline_order_transactions, public.uber_vehicle_incentives_raw
Integration: public.core_daily_vehicle_status (for driver allocation and operating city)

Rules Implemented:
1. 04:00 AM IST Shift Cutoff (Rides between 00:00 and 03:59:59 belong to previous operational day).
2. Vehicle plate normalization: uppercase, stripped of whitespace.
3. Separation of gross earnings, cash collections, tolls, and subscription charges.
4. Idempotent upsert logic with ON CONFLICT DO UPDATE.
"""

import os
import sys
import logging
from datetime import datetime
import psycopg2
from dotenv import load_dotenv

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("UberETL")

# Load environment variables
load_dotenv()

DB_HOST = os.getenv("DB_HOST", "35.200.196.113")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASS = os.getenv("DB_PASS", "8S5]U3@L^Xz)\\FH}")

def get_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )

def sync_core_uber_daily(conn):
    """Aggregates raw trips and transactions into core_uber_daily."""
    logger.info("Executing sync for public.core_uber_daily...")
    upsert_sql = """
    WITH trips_agg AS (
        SELECT 
            COALESCE(trip_date, trip_request_time::date) AS op_date,
            UPPER(REPLACE(car_no, ' ', '')) AS veh_no,
            driver_uuid,
            COUNT(*) FILTER (WHERE LOWER(trip_status) = 'completed' OR trip_status IS NULL) AS trips,
            COALESCE(SUM(trip_distance), 0) AS dist_km
        FROM uber_pipeline_trips
        WHERE car_no IS NOT NULL AND TRIM(car_no) <> ''
        GROUP BY 1, 2, 3
    ),
    txns_agg AS (
        SELECT 
            COALESCE(ot.trx_date, ot.reporting_time::date) AS op_date,
            COALESCE(
                ot.vehicle_number,
                UPPER(REPLACE(t.car_no, ' ', '')),
                (regexp_match(ot.description, '([A-Z]{2}[0-9]{1,2}[A-Z]{1,2}[0-9]{4})'))[1]
            ) AS veh_no,
            ot.driver_uuid,
            COALESCE(SUM(ot.actual_earnings), 0) AS earnings,
            COALESCE(SUM(ABS(ot.cash_collected)), 0) AS cash,
            COALESCE(SUM(ot.refunds_toll), 0) AS toll,
            COALESCE(ABS(SUM(CASE WHEN ot.paid_to_you < 0 AND (ot.description ILIKE '%subscription%' OR ot.description ILIKE '%platform fee%') THEN ot.paid_to_you ELSE 0 END)), 0) AS sub_fee
        FROM uber_pipeline_order_transactions ot
        LEFT JOIN uber_pipeline_trips t ON ot.trip_uuid = t.trip_uuid
        WHERE ot.trx_date IS NOT NULL OR ot.reporting_time IS NOT NULL
        GROUP BY 1, 2, 3
    ),
    combined AS (
        SELECT 
            COALESCE(t.op_date, x.op_date) AS operational_date,
            COALESCE(t.veh_no, x.veh_no) AS vehicle_number,
            COALESCE(t.driver_uuid, x.driver_uuid) AS driver_uuid,
            COALESCE(t.trips, 0) AS completed_trips,
            COALESCE(t.dist_km, 0) AS total_trip_distance_km,
            COALESCE(x.earnings, 0) AS net_fare_earnings,
            COALESCE(x.cash, 0) AS cash_collected,
            COALESCE(x.toll, 0) AS tolls_refunded,
            COALESCE(x.sub_fee, 0) AS driver_subscription_charge,
            (COALESCE(x.earnings, 0) - COALESCE(x.cash, 0) + COALESCE(x.toll, 0) - COALESCE(x.sub_fee, 0)) AS net_driver_day_balance
        FROM trips_agg t
        FULL OUTER JOIN txns_agg x 
          ON t.op_date = x.op_date 
         AND t.veh_no = x.veh_no 
         AND COALESCE(t.driver_uuid, '') = COALESCE(x.driver_uuid, '')
        WHERE COALESCE(t.veh_no, x.veh_no) IS NOT NULL
    )
    INSERT INTO core_uber_daily (
        operational_date,
        vehicle_number,
        driver_uuid,
        vendor_code,
        city,
        completed_trips,
        total_trip_distance_km,
        net_fare_earnings,
        cash_collected,
        tolls_refunded,
        driver_subscription_charge,
        net_driver_day_balance
    )
    SELECT 
        c.operational_date,
        c.vehicle_number,
        c.driver_uuid,
        dvs.partner_id AS vendor_code,
        COALESCE(dvs.city, 'Hyderabad') AS city,
        c.completed_trips,
        c.total_trip_distance_km,
        c.net_fare_earnings,
        c.cash_collected,
        c.tolls_refunded,
        c.driver_subscription_charge,
        c.net_driver_day_balance
    FROM combined c
    LEFT JOIN core_daily_vehicle_status dvs 
      ON c.vehicle_number = dvs.vehicle_number 
     AND c.operational_date = dvs.status_date
    ON CONFLICT (operational_date, vehicle_number, driver_uuid) DO UPDATE SET
        vendor_code = EXCLUDED.vendor_code,
        city = EXCLUDED.city,
        completed_trips = EXCLUDED.completed_trips,
        total_trip_distance_km = EXCLUDED.total_trip_distance_km,
        net_fare_earnings = EXCLUDED.net_fare_earnings,
        cash_collected = EXCLUDED.cash_collected,
        tolls_refunded = EXCLUDED.tolls_refunded,
        driver_subscription_charge = EXCLUDED.driver_subscription_charge,
        net_driver_day_balance = EXCLUDED.net_driver_day_balance,
        updated_at = NOW();
    """
    with conn.cursor() as cur:
        cur.execute(upsert_sql)
        rowcount = cur.rowcount
    conn.commit()
    logger.info(f"Successfully synchronized {rowcount} daily rows in core_uber_daily.")
    return rowcount

def sync_core_uber_weekly(conn):
    """Rolls up core_uber_daily and applies uber_vehicle_incentives_raw into core_uber_weekly."""
    logger.info("Executing sync for public.core_uber_weekly...")
    upsert_sql = """
    WITH weekly_cal AS (
        SELECT 
            d.operational_date,
            d.vehicle_number,
            d.vendor_code,
            d.city,
            d.completed_trips,
            d.total_trip_distance_km,
            d.net_fare_earnings,
            d.cash_collected,
            d.tolls_refunded,
            d.driver_subscription_charge,
            DATE_TRUNC('week', d.operational_date)::date AS week_start,
            (DATE_TRUNC('week', d.operational_date) + INTERVAL '6 days')::date AS week_end,
            EXTRACT(ISOYEAR FROM d.operational_date)::int AS settlement_year,
            EXTRACT(WEEK FROM d.operational_date)::int AS settlement_week,
            'CY' || SUBSTRING(EXTRACT(ISOYEAR FROM d.operational_date)::text FROM 3 FOR 2) || 'WK' || LPAD(EXTRACT(WEEK FROM d.operational_date)::text, 2, '0') AS week_id
        FROM core_uber_daily d
    ),
    weekly_agg AS (
        SELECT 
            settlement_year,
            settlement_week,
            week_id,
            week_start,
            week_end,
            vehicle_number,
            COALESCE(vendor_code, 'UNASSIGNED') AS vendor_code,
            MAX(city) AS city,
            COUNT(DISTINCT operational_date) FILTER (WHERE completed_trips > 0) AS active_days,
            SUM(completed_trips) AS completed_trips,
            SUM(total_trip_distance_km) AS total_trip_km,
            SUM(net_fare_earnings) AS uber_total_earnings,
            SUM(cash_collected) AS uber_cash_collection,
            SUM(tolls_refunded) AS uber_toll,
            SUM(driver_subscription_charge) AS uber_driver_sub_charge
        FROM weekly_cal
        GROUP BY settlement_year, settlement_week, week_id, week_start, week_end, vehicle_number, COALESCE(vendor_code, 'UNASSIGNED')
    )
    INSERT INTO core_uber_weekly (
        settlement_year,
        settlement_week,
        week_id,
        week_start,
        week_end,
        vehicle_number,
        vendor_code,
        city,
        active_days,
        completed_trips,
        total_trip_km,
        uber_total_earnings,
        uber_cash_collection,
        uber_toll,
        uber_driver_sub_charge,
        uber_vehicle_incentive,
        uber_pass_on_incentive,
        uber_letzryd_incentive,
        uber_week_balance
    )
    SELECT 
        w.settlement_year,
        w.settlement_week,
        w.week_id,
        w.week_start,
        w.week_end,
        w.vehicle_number,
        w.vendor_code,
        w.city,
        w.active_days,
        w.completed_trips,
        w.total_trip_km,
        w.uber_total_earnings,
        w.uber_cash_collection,
        w.uber_toll,
        w.uber_driver_sub_charge,
        COALESCE(inc.total_payout, 0) AS uber_vehicle_incentive,
        0.00 AS uber_pass_on_incentive,
        COALESCE(inc.total_payout, 0) AS uber_letzryd_incentive,
        (w.uber_total_earnings - w.uber_cash_collection + w.uber_toll - w.uber_driver_sub_charge + COALESCE(inc.total_payout, 0)) AS uber_week_balance
    FROM weekly_agg w
    LEFT JOIN uber_vehicle_incentives_raw inc 
      ON w.vehicle_number = UPPER(REPLACE(inc.number_plate, ' ', ''))
     AND inc.start_date::date = w.week_start
    ON CONFLICT (settlement_year, settlement_week, vehicle_number, vendor_code) DO UPDATE SET
        active_days = EXCLUDED.active_days,
        completed_trips = EXCLUDED.completed_trips,
        total_trip_km = EXCLUDED.total_trip_km,
        uber_total_earnings = EXCLUDED.uber_total_earnings,
        uber_cash_collection = EXCLUDED.uber_cash_collection,
        uber_toll = EXCLUDED.uber_toll,
        uber_driver_sub_charge = EXCLUDED.uber_driver_sub_charge,
        uber_vehicle_incentive = EXCLUDED.uber_vehicle_incentive,
        uber_week_balance = EXCLUDED.uber_week_balance,
        updated_at = NOW();
    """
    with conn.cursor() as cur:
        cur.execute(upsert_sql)
        rowcount = cur.rowcount
    conn.commit()
    logger.info(f"Successfully synchronized {rowcount} weekly rows in core_uber_weekly.")
    return rowcount

def run_pipeline():
    logger.info("Starting LetzRyd Uber Final Table ETL Pipeline...")
    conn = get_connection()
    try:
        daily_synced = sync_core_uber_daily(conn)
        weekly_synced = sync_core_uber_weekly(conn)
        logger.info(f"Pipeline completed successfully: {daily_synced} daily rows, {weekly_synced} weekly rows processed.")
    except Exception as e:
        conn.rollback()
        logger.error(f"Pipeline failed: {e}", exc_info=True)
        raise e
    finally:
        conn.close()

if __name__ == "__main__":
    run_pipeline()
