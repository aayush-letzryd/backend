"""
===============================================================================
LetzRyd Hisaab Engine Automation CLI & Runner
Module: Hisaab Final Table
Database: PostgreSQL 14+ on 35.200.196.113:5432
Purpose:
  Provides manual and automated execution triggers for Hisaab weekly settlement
  calculations via public.sp_sync_hisaab_vehicle_weekly().
===============================================================================
"""

import sys
import logging
import argparse
import psycopg2

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

DB_URI = "postgresql://postgres:8S5%5DU3%40L%5EXz)%5CFH%7D@35.200.196.113:5432/postgres"

def get_connection():
    return psycopg2.connect(DB_URI)

def sync_hisaab_weekly(week_id=None):
    """
    Executes public.sp_sync_hisaab_vehicle_weekly(week_id).
    If week_id is None, syncs all open settlement weeks.
    """
    logger.info(f"Triggering Hisaab Vehicle Weekly Sync (Week: {week_id or 'ALL OPEN WEEKS'})...")
    conn = get_connection()
    conn.autocommit = True
    cur = conn.cursor()
    try:
        cur.execute("CALL public.sp_sync_hisaab_vehicle_weekly(%s);", (week_id,))
        for notice in conn.notices:
            logger.info(notice.strip())
        logger.info("Sync completed successfully.")
        
        # Report summary
        cur.execute("""
            SELECT week_id, count(*), sum(net_weekly_lease_rental), sum(uber_trips), sum(ola_trips)
            FROM public.hisaab_vehicle_weekly
            WHERE (%s IS NULL OR week_id = %s)
            GROUP BY week_id
            ORDER BY week_id DESC LIMIT 5;
        """, (week_id, week_id))
        rows = cur.fetchall()
        for r in rows:
            logger.info(f"Week {r[0]}: {r[1]} vehicles | Total Lease Rent: Rs. {float(r[2] or 0):,.2f} | Uber Trips: {r[3]} | Ola Trips: {r[4]}")
            
    except Exception as e:
        logger.error(f"Error during Hisaab sync: {e}")
        raise
    finally:
        cur.close()
        conn.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="LetzRyd Hisaab Engine CLI")
    parser.add_argument("--week", type=str, default=None, help="Target week ID (e.g. CY26WK26). If omitted, syncs open weeks.")
    args = parser.parse_args()
    sync_hisaab_weekly(args.week)
