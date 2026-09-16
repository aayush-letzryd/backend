"""
===============================================================================
LetzRyd Hisaab Engine Automation Script
Module: Hisaab Final Table
Database: PostgreSQL 14+ on 35.200.196.113:5432
Purpose:
  1. Synchronizes daily attendance & rent (daily_rent_log), Uber telemetry (core_uber_daily),
     Ola telemetry (core_ola_daily), Rapido telemetry, and adjustments into hisaab_daily_ledger.
  2. Credits weekly platform milestone incentives on Sunday's shift (log_date = week_end).
  3. Rolls up daily data into hisaab_vehicle_weekly (1-to-1 match with 'Uber + OLA Final Hisaab').
  4. Consolidates vehicle metrics into hisaab_partner_weekly (1-to-1 match with 'Hisaab Summary'),
     incorporating opening dues, mid-week collections, and prior-period adjustments.
  5. Enforces the Monday 11:00 AM lock switch (is_locked) to guarantee statement immutability.
===============================================================================
"""

import sys
import logging
import datetime
from decimal import Decimal
import psycopg2
from psycopg2.extras import RealDictCursor

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

DB_URI = "postgresql://postgres:8S5%5DU3%40L%5EXz)%5CFH%7D@35.200.196.113:5432/postgres"

def get_connection():
    return psycopg2.connect(DB_URI)

def ensure_settlement_week(cur, week_id=None, log_date=None):
    """
    Ensures that the settlement week exists in hisaab_settlement_weeks via fn_ensure_hisaab_week.
    """
    cur.execute("SELECT public.fn_ensure_hisaab_week(%s, %s);", (week_id, log_date))
    return cur.fetchone()[0]

def sync_daily_hisaab(target_date):
    """
    Idempotent daily upsert into hisaab_daily_ledger for a specific operational date.
    Invokes public.fn_sync_hisaab_daily_upsert for every active vehicle/partner on target_date.
    """
    logger.info(f"--- Starting Daily Hisaab Sync for Date: {target_date} ---")
    conn = get_connection()
    cur = conn.cursor()
    try:
        dt = target_date if isinstance(target_date, datetime.date) else datetime.datetime.strptime(str(target_date), "%Y-%m-%d").date()
        week_id = ensure_settlement_week(cur, log_date=dt)
        
        # Check lock status
        cur.execute("SELECT is_locked FROM public.hisaab_settlement_weeks WHERE week_id = %s;", (week_id,))
        week_info = cur.fetchone()
        if week_info and week_info[0]:
            logger.warning(f"Settlement Week {week_id} is LOCKED. Skipping daily update for {dt}.")
            return

        # Fetch all vehicles and partners active in daily rent log or telemetry
        cur.execute("""
            SELECT DISTINCT vehicle_number, partner_id
            FROM (
                SELECT vehicle_number, partner_id FROM public.daily_rent_log WHERE log_date = %s
                UNION
                SELECT vehicle_number, vendor_code AS partner_id FROM public.core_uber_daily WHERE operational_date = %s
                UNION
                SELECT vehicle_number, NULL AS partner_id FROM public.core_ola_daily WHERE service_date = %s
                UNION
                SELECT vehicle_number, NULL AS partner_id FROM public.core_rapido_daily WHERE operational_date = %s
            ) combined
            WHERE vehicle_number IS NOT NULL AND vehicle_number <> '';
        """, (dt, dt, dt, dt))
        
        rows = cur.fetchall()
        logger.info(f"Found {len(rows)} vehicle-partner targets for {dt}. Executing upsert...")

        success_count = 0
        for veh, partner in rows:
            cur.execute("SELECT public.fn_sync_hisaab_daily_upsert(%s, %s, %s);", (dt, veh, partner))
            success_count += 1

        conn.commit()
        logger.info(f"Daily Hisaab Sync completed successfully for {dt}: {success_count} vehicles processed.")
    except Exception as e:
        conn.rollback()
        logger.error(f"Error in sync_daily_hisaab: {e}", exc_info=True)
    finally:
        cur.close()
        conn.close()

def sync_weekly_vehicle_hisaab(week_id):
    """
    Rolls up hisaab_daily_ledger into hisaab_vehicle_weekly and hisaab_partner_weekly.
    Invokes public.sp_run_full_week_hisaab(week_id) to perform end-to-end reconciliation.
    """
    logger.info(f"--- Starting Weekly Hisaab Full Reconciliation for Week: {week_id} ---")
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT is_locked FROM public.hisaab_settlement_weeks WHERE week_id = %s;", (week_id,))
        week_info = cur.fetchone()
        if not week_info:
            ensure_settlement_week(cur, week_id=week_id)
        elif week_info[0]:
            logger.warning(f"Week {week_id} is LOCKED. Cannot re-aggregate weekly hisaab.")
            return

        cur.execute("CALL public.sp_run_full_week_hisaab(%s);", (week_id,))
        conn.commit()
        logger.info(f"Full-week hisaab reconciliation completed successfully for {week_id}.")
    except Exception as e:
        conn.rollback()
        logger.error(f"Error in sync_weekly_vehicle_hisaab: {e}", exc_info=True)
    finally:
        cur.close()
        conn.close()

def lock_settlement_week(week_id, locked_by='finance_admin'):
    """
    Engages the Monday 11:00 AM lock switch for a given settlement week.
    Freezes hisaab_settlement_weeks, hisaab_daily_ledger, hisaab_vehicle_weekly,
    and hisaab_partner_weekly via public.sp_check_and_enforce_monday_lock.
    """
    logger.info(f"Engaging Settlement Lock for Week: {week_id} by {locked_by}...")
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("CALL public.sp_check_and_enforce_monday_lock(%s);", (week_id,))
        conn.commit()
        logger.info(f"Week {week_id} is now FROZEN and IMMUTABLE.")
    except Exception as e:
        conn.rollback()
        logger.error(f"Error locking week {week_id}: {e}", exc_info=True)
    finally:
        cur.close()
        conn.close()

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == '--daily':
        sync_daily_hisaab(sys.argv[2])
    elif len(sys.argv) > 2 and sys.argv[1] == '--weekly':
        sync_weekly_vehicle_hisaab(sys.argv[2])
    elif len(sys.argv) > 2 and sys.argv[1] == '--lock':
        lock_settlement_week(sys.argv[2])
    else:
        logger.info("Usage: python automation_script.py [--daily YYYY-MM-DD | --weekly CYxxWKww | --lock CYxxWKww]")
