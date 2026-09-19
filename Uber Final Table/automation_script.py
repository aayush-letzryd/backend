"""
Uber Final Table Automation & Transformation Pipeline
=====================================================
Target Tables: public.core_uber_daily, public.core_uber_weekly
Source Tables: public.uber_pipeline_trips, public.uber_pipeline_order_transactions, public.uber_vehicle_incentives_raw
Integration: public.core_daily_vehicle_status (for driver allocation and operating city)
Scheduler: Native PostgreSQL pg_cron ('sync-core-uber' every 30 minutes)

Architecture Standard:
1. 100% Decoupled, Zero-Trigger Fault Isolation (Raw tables have strictly 0 triggers).
2. 04:00 AM IST Shift Cutoff (Rides between 00:00 and 03:59:59 belong to previous operational day).
3. Case-insensitive trip status filtering (LOWER(trip_status) = 'completed').
4. Correct cash collection sign handling (ABS(cash_collected) deducted from earnings).
5. Robust fallback cascade for order transactions lacking trip_uuid.
6. Multi-vendor vehicle incentive de-duplication.
"""

import os
import sys
import argparse
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
        password=DB_PASS,
        connect_timeout=15
    )

def run_sync(start_date=None, end_date=None, lookback_days=7):
    """Invokes stored procedure sp_sync_core_uber."""
    logger.info(f"Connecting to database {DB_HOST}:{DB_PORT}/{DB_NAME}...")
    conn = get_connection()
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            if start_date and end_date:
                logger.info(f"Executing CALL public.sp_sync_core_uber('{start_date}', '{end_date}');")
                cur.execute("CALL public.sp_sync_core_uber(%s, %s, NULL);", (start_date, end_date))
            else:
                logger.info(f"Executing CALL public.sp_sync_core_uber(NULL, NULL, {lookback_days});")
                cur.execute("CALL public.sp_sync_core_uber(NULL, NULL, %s);", (lookback_days,))
        logger.info("Uber Core sync procedure completed successfully.")
    except Exception as e:
        logger.error(f"Sync procedure failed: {e}", exc_info=True)
        raise e
    finally:
        conn.close()

def main():
    parser = argparse.ArgumentParser(description="LetzRyd Uber Core Table Sync Runner")
    parser.add_argument("--start", type=str, default=None, help="Start date (YYYY-MM-DD)")
    parser.add_argument("--end", type=str, default=None, help="End date (YYYY-MM-DD)")
    parser.add_argument("--lookback", type=int, default=7, help="Lookback days window (default: 7)")
    args = parser.parse_args()

    run_sync(start_date=args.start, end_date=args.end, lookback_days=args.lookback)

if __name__ == "__main__":
    main()
