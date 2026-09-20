"""
Ola Final Table Automation & Transformation Pipeline
====================================================
Target Tables: public.core_ola_daily, public.core_ola_weekly
Source Tables: public.ola_raw_crns, public.ola_raw_transactions
Integration: public.core_daily_vehicle_status (for driver allocation and operating city)
Scheduling: Automated via pg_cron (sync_core_ola_30m every 30 minutes)

Rules Implemented:
1. Complete isolation of raw pipelines: ZERO triggers on raw ingestion tables.
2. Vehicle plate normalization: UPPER(REPLACE(vehicle_number, ' ', '')).
3. Exact net revenue basis: operator_bill_raw + cancellation fee compensation.
4. Cash collected is enforced positive magnitude via ABS(...).
5. Collection transactions mapped: digital fare collections and subscription offsets.
6. Full-week boundary protection: Weekly rollup calculates full Monday-Sunday boundaries.
7. Robust vendor attribution: Resolves dominant partner across the week, avoiding Monday NULLs.
"""

import os
import sys
import argparse
import logging
from datetime import datetime, date
import psycopg2
from dotenv import load_dotenv

sys.stdout.reconfigure(encoding='utf-8')

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("OlaETL")

# Load environment variables
load_dotenv()

DB_HOST = os.getenv("DB_HOST", "35.200.196.113")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASS = os.getenv("DB_PASS", r"8S5]U3@L^Xz)\FH}")

def get_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )

def run_sp_sync(conn, start_date=None, end_date=None):
    """Executes the production sp_sync_core_ola stored procedure."""
    logger.info(f"Executing sp_sync_core_ola(start_date={start_date}, end_date={end_date})...")
    with conn.cursor() as cur:
        cur.execute("CALL public.sp_sync_core_ola(%s, %s);", (start_date, end_date))
    conn.commit()
    logger.info("sp_sync_core_ola executed successfully.")

def get_stats(conn, start_date=None, end_date=None):
    """Fetches summary stats of updated rows."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT 
                COUNT(*) as daily_rows,
                COALESCE(SUM(completed_trips), 0) as comp_trips,
                COALESCE(SUM(operator_bill), 0) as oper_bill,
                COALESCE(SUM(cash_collected), 0) as cash
            FROM public.core_ola_daily
            WHERE (%s::date IS NULL OR service_date >= %s::date)
              AND (%s::date IS NULL OR service_date <= %s::date);
        """, (start_date, start_date, end_date, end_date))
        d_stats = cur.fetchone()

        cur.execute("""
            SELECT 
                COUNT(*) as weekly_rows,
                COALESCE(SUM(completed_trips), 0) as comp_trips,
                COALESCE(SUM(ola_net_revenue), 0) as net_rev,
                COALESCE(SUM(ola_cash_collected), 0) as cash
            FROM public.core_ola_weekly
            WHERE (%s::date IS NULL OR week_start >= DATE_TRUNC('week', %s::date)::date)
              AND (%s::date IS NULL OR week_end <= (DATE_TRUNC('week', %s::date) + INTERVAL '6 days')::date);
        """, (start_date, start_date, end_date, end_date))
        w_stats = cur.fetchone()

    logger.info(f"Daily Core Status: {d_stats[0]} rows, {d_stats[1]} completed trips, Rs. {d_stats[2]:,.2f} revenue, Rs. {d_stats[3]:,.2f} cash")
    logger.info(f"Weekly Core Status: {w_stats[0]} rows, {w_stats[1]} completed trips, Rs. {w_stats[2]:,.2f} revenue, Rs. {w_stats[3]:,.2f} cash")

def main():
    parser = argparse.ArgumentParser(description="LetzRyd Ola Final Table ETL Pipeline")
    parser.add_argument("--start", type=str, default=None, help="Start date (YYYY-MM-DD), defaults to CURRENT_DATE - 14 days")
    parser.add_argument("--end", type=str, default=None, help="End date (YYYY-MM-DD), defaults to CURRENT_DATE")
    args = parser.parse_args()

    conn = get_connection()
    try:
        run_sp_sync(conn, args.start, args.end)
        get_stats(conn, args.start, args.end)
    except Exception as e:
        conn.rollback()
        logger.error(f"Pipeline failed: {e}", exc_info=True)
        sys.exit(1)
    finally:
        conn.close()

if __name__ == "__main__":
    main()
