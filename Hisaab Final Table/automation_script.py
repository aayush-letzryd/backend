"""
===============================================================================
LetzRyd Hisaab Engine Automation Script
Module: Hisaab Final Table
Database: PostgreSQL 14+ on 35.200.196.113:5432
Purpose:
  1. Synchronizes daily attendance & rent (daily_rent_log), Uber telemetry (core_uber_daily),
     Ola telemetry (core_ola_daily), and adjustments into hisaab_daily_ledger.
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
from psycopg2.extras import RealDictCursor, execute_batch

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

DB_URI = "postgresql://postgres:8S5%5DU3%40L%5EXz)%5CFH%7D@35.200.196.113:5432/postgres"

def get_connection():
    return psycopg2.connect(DB_URI)

def ensure_settlement_week(cur, week_id, week_start, week_end):
    """
    Ensures that the settlement week exists in hisaab_settlement_weeks.
    Default lock_cutoff_at is the Monday following week_end at 11:00 AM IST.
    """
    # Cutoff is Monday at 11:00 AM IST (which is week_end + 1 day at 11:00:00+05:30)
    cutoff_dt = datetime.datetime.combine(week_end + datetime.timedelta(days=1), datetime.time(11, 0, 0))
    # year and week number
    year, week_num, _ = week_start.isocalendar()
    
    cur.execute("""
        INSERT INTO public.hisaab_settlement_weeks (
            week_id, settlement_year, settlement_week, week_start, week_end, lock_cutoff_at, is_locked
        ) VALUES (%s, %s, %s, %s, %s, %s::timestamptz, FALSE)
        ON CONFLICT (week_id) DO NOTHING;
    """, (week_id, year, week_num, week_start, week_end, cutoff_dt.isoformat() + "+05:30"))

def sync_daily_hisaab(target_date):
    """
    Idempotent daily upsert into hisaab_daily_ledger for a specific operational date.
    Merges:
      - daily_rent_log (attendance, billable status, rent, indemnity)
      - core_uber_daily (trips, fare earnings, cash collected, tolls, subscription)
      - core_ola_daily (trips, operator bill, cash collected, tolls, online payouts)
      - hisaab_adjustments_ledger (in-week adjustments & challans)
    """
    logger.info(f"--- Starting Daily Hisaab Sync for Date: {target_date} ---")
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    try:
        # Determine week_id, week_start (Mon), week_end (Sun)
        dt = target_date if isinstance(target_date, datetime.date) else datetime.datetime.strptime(str(target_date), "%Y-%m-%d").date()
        year, week_num, weekday = dt.isocalendar()
        week_start = dt - datetime.timedelta(days=weekday - 1)
        week_end = week_start + datetime.timedelta(days=6)
        week_id = f"CY{str(year)[-2:]}WK{week_num:02d}"

        # 1. Ensure week exists and check lock status
        ensure_settlement_week(cur, week_id, week_start, week_end)
        cur.execute("SELECT is_locked FROM public.hisaab_settlement_weeks WHERE week_id = %s;", (week_id,))
        week_info = cur.fetchone()
        if week_info and week_info['is_locked']:
            logger.warning(f"Settlement Week {week_id} is LOCKED. Skipping daily update for {dt}.")
            return

        # 2. Main Daily Upsert Query
        upsert_query = """
        WITH base_rent AS (
            SELECT 
                log_date,
                vehicle_number,
                partner_id,
                city,
                vehicle_model,
                attendance_status,
                is_billable_day,
                applied_daily_rent,
                applied_daily_indemnity,
                net_daily_rent
            FROM public.daily_rent_log
            WHERE log_date = %s
        ),
        uber_agg AS (
            SELECT 
                operational_date,
                vehicle_number,
                COALESCE(vendor_code, '') AS vendor_code,
                SUM(completed_trips) AS uber_trips,
                SUM(net_fare_earnings) AS uber_fare_earnings,
                SUM(cash_collected) AS uber_cash_collected,
                SUM(tolls_refunded) AS uber_tolls,
                SUM(driver_subscription_charge) AS uber_subscription_charge
            FROM public.core_uber_daily
            WHERE operational_date = %s
            GROUP BY operational_date, vehicle_number, COALESCE(vendor_code, '')
        ),
        ola_agg AS (
            SELECT 
                service_date,
                vehicle_number,
                SUM(completed_trips) AS ola_trips,
                SUM(operator_bill) AS ola_net_revenue,
                SUM(cash_collected) AS ola_cash_collected,
                SUM(toll_and_parking) AS ola_tolls,
                SUM(online_payouts) AS ola_online_payment
            FROM public.core_ola_daily
            WHERE service_date = %s
            GROUP BY service_date, vehicle_number
        ),
        adj_agg AS (
            SELECT 
                incident_date,
                vehicle_number,
                partner_id,
                SUM(CASE WHEN adjustment_category = 'Challan' THEN amount ELSE 0 END) AS daily_challans,
                SUM(CASE WHEN adjustment_category = 'Accident Damage' THEN amount ELSE 0 END) AS daily_accidents,
                SUM(CASE WHEN adjustment_category NOT IN ('Challan', 'Accident Damage') THEN amount ELSE 0 END) AS daily_adjustments
            FROM public.hisaab_adjustments_ledger
            WHERE incident_date = %s AND settlement_week_id = %s
            GROUP BY incident_date, vehicle_number, partner_id
        )
        INSERT INTO public.hisaab_daily_ledger (
            log_date,
            week_id,
            vehicle_number,
            partner_id,
            partner_type,
            city,
            vehicle_model,
            attendance_status,
            is_billable_day,
            daily_rent_applied,
            daily_indemnity_fee,
            net_daily_rent,
            uber_trips,
            uber_fare_earnings,
            uber_cash_collected,
            uber_tolls,
            uber_subscription_charge,
            ola_trips,
            ola_net_revenue,
            ola_cash_collected,
            ola_tolls,
            ola_online_payment,
            daily_adjustments,
            daily_challans,
            daily_accident_recovery,
            daily_net_balance,
            updated_at
        )
        SELECT 
            r.log_date,
            %s AS week_id,
            r.vehicle_number,
            r.partner_id,
            CASE WHEN r.partner_id ILIKE '%%IP%%' THEN 'Operator' ELSE 'Individual' END AS partner_type,
            COALESCE(r.city, 'Unknown') AS city,
            r.vehicle_model,
            r.attendance_status,
            r.is_billable_day,
            COALESCE(r.applied_daily_rent, 0) AS daily_rent_applied,
            COALESCE(r.applied_daily_indemnity, 0) AS daily_indemnity_fee,
            COALESCE(r.net_daily_rent, 0) AS net_daily_rent,
            COALESCE(u.uber_trips, 0) AS uber_trips,
            COALESCE(u.uber_fare_earnings, 0) AS uber_fare_earnings,
            COALESCE(u.uber_cash_collected, 0) AS uber_cash_collected,
            COALESCE(u.uber_tolls, 0) AS uber_tolls,
            COALESCE(u.uber_subscription_charge, 0) AS uber_subscription_charge,
            COALESCE(o.ola_trips, 0) AS ola_trips,
            COALESCE(o.ola_net_revenue, 0) AS ola_net_revenue,
            COALESCE(o.ola_cash_collected, 0) AS ola_cash_collected,
            COALESCE(o.ola_tolls, 0) AS ola_tolls,
            COALESCE(o.ola_online_payment, 0) AS ola_online_payment,
            COALESCE(a.daily_adjustments, 0) AS daily_adjustments,
            COALESCE(a.daily_challans, 0) AS daily_challans,
            COALESCE(a.daily_accidents, 0) AS daily_accident_recovery,
            -- daily_net_balance calculation:
            -- Rent + Cash Collected (driver kept cash) - Digital Fares - Online Pay + Challans/Adjustments
            (
                COALESCE(r.net_daily_rent, 0)
                + (ABS(COALESCE(u.uber_cash_collected, 0)) + ABS(COALESCE(o.ola_cash_collected, 0)))
                - (COALESCE(u.uber_fare_earnings, 0) + COALESCE(o.ola_net_revenue, 0))
                - COALESCE(o.ola_online_payment, 0)
                + COALESCE(a.daily_challans, 0)
                + COALESCE(a.daily_accidents, 0)
                + COALESCE(a.daily_adjustments, 0)
            ) AS daily_net_balance,
            CURRENT_TIMESTAMP AS updated_at
        FROM base_rent r
        LEFT JOIN uber_agg u ON r.vehicle_number = u.vehicle_number
        LEFT JOIN ola_agg o ON r.vehicle_number = o.vehicle_number
        LEFT JOIN adj_agg a ON r.vehicle_number = a.vehicle_number AND r.partner_id = a.partner_id
        ON CONFLICT (log_date, vehicle_number, partner_id) DO UPDATE SET
            attendance_status = EXCLUDED.attendance_status,
            is_billable_day = EXCLUDED.is_billable_day,
            daily_rent_applied = EXCLUDED.daily_rent_applied,
            daily_indemnity_fee = EXCLUDED.daily_indemnity_fee,
            net_daily_rent = EXCLUDED.net_daily_rent,
            uber_trips = EXCLUDED.uber_trips,
            uber_fare_earnings = EXCLUDED.uber_fare_earnings,
            uber_cash_collected = EXCLUDED.uber_cash_collected,
            uber_tolls = EXCLUDED.uber_tolls,
            uber_subscription_charge = EXCLUDED.uber_subscription_charge,
            ola_trips = EXCLUDED.ola_trips,
            ola_net_revenue = EXCLUDED.ola_net_revenue,
            ola_cash_collected = EXCLUDED.ola_cash_collected,
            ola_tolls = EXCLUDED.ola_tolls,
            ola_online_payment = EXCLUDED.ola_online_payment,
            daily_adjustments = EXCLUDED.daily_adjustments,
            daily_challans = EXCLUDED.daily_challans,
            daily_accident_recovery = EXCLUDED.daily_accident_recovery,
            daily_net_balance = EXCLUDED.daily_net_balance,
            updated_at = CURRENT_TIMESTAMP
        WHERE public.hisaab_daily_ledger.is_locked = FALSE;
        """
        cur.execute(upsert_query, (dt, dt, dt, dt, week_id, week_id))
        rows_affected = cur.rowcount
        conn.commit()
        logger.info(f"Daily Hisaab Sync complete for {dt}. Rows upserted/updated: {rows_affected}")

        # Check if dt is Sunday (end of week), if so, credit weekly milestone incentives
        if dt == week_end:
            credit_sunday_weekly_incentives(conn, week_id, week_end)

    except Exception as e:
        conn.rollback()
        logger.error(f"Error syncing daily hisaab for {target_date}: {e}", exc_info=True)
    finally:
        cur.close()
        conn.close()

def credit_sunday_weekly_incentives(conn, week_id, sunday_date):
    """
    Credits platform weekly milestone incentives on Sunday's row in hisaab_daily_ledger.
    Pulls from core_uber_weekly (uber_vehicle_incentive) and core_ola_weekly (ola_portal_incentive).
    """
    logger.info(f"Crediting Sunday weekly milestone incentives for week {week_id} on {sunday_date}...")
    cur = conn.cursor()
    try:
        update_incentives_query = """
        WITH weekly_inc AS (
            SELECT 
                COALESCE(u.vehicle_number, o.vehicle_number) AS vehicle_number,
                COALESCE(u.uber_vehicle_incentive, 0) AS uber_inc,
                COALESCE(o.ola_portal_incentive, 0) AS ola_inc,
                (COALESCE(u.uber_vehicle_incentive, 0) + COALESCE(o.ola_portal_incentive, 0)) AS total_inc
            FROM (
                SELECT vehicle_number, SUM(uber_vehicle_incentive) AS uber_vehicle_incentive
                FROM public.core_uber_weekly
                WHERE week_id = %s OR (settlement_year = %s AND settlement_week = %s)
                GROUP BY vehicle_number
            ) u
            FULL OUTER JOIN (
                SELECT vehicle_number, SUM(ola_portal_incentive) AS ola_portal_incentive
                FROM public.core_ola_weekly
                WHERE week_id = %s
                GROUP BY vehicle_number
            ) o ON u.vehicle_number = o.vehicle_number
        )
        UPDATE public.hisaab_daily_ledger d
        SET 
            weekly_incentive_credit = w.total_inc,
            daily_net_balance = d.daily_net_balance - w.total_inc,
            updated_at = CURRENT_TIMESTAMP
        FROM weekly_inc w
        WHERE d.log_date = %s 
          AND d.vehicle_number = w.vehicle_number
          AND d.is_locked = FALSE;
        """
        year, week_num = (2000 + int(week_id[2:4]), int(week_id[6:])) if week_id.startswith('CY') else (int(week_id.split('-W')[0]), int(week_id.split('-W')[1]))
        cur.execute(update_incentives_query, (week_id, year, week_num, week_id, sunday_date))
        conn.commit()
        logger.info(f"Weekly incentives credited on Sunday ({sunday_date}) rows: {cur.rowcount}")
    except Exception as e:
        conn.rollback()
        logger.error(f"Error crediting Sunday weekly incentives: {e}")
    finally:
        cur.close()

def sync_weekly_vehicle_hisaab(week_id):
    """
    Rolls up hisaab_daily_ledger into hisaab_vehicle_weekly for a given week.
    Grain: (week_id, vehicle_number, partner_id)
    Mirrors the Excel 'Uber + OLA Final Hisaab' sheet.
    """
    logger.info(f"--- Starting Weekly Vehicle Hisaab Roll-up for Week: {week_id} ---")
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    try:
        cur.execute("SELECT week_start, week_end, is_locked FROM public.hisaab_settlement_weeks WHERE week_id = %s;", (week_id,))
        week_info = cur.fetchone()
        if not week_info:
            logger.error(f"Week {week_id} not found in hisaab_settlement_weeks.")
            return

        if week_info['is_locked']:
            logger.warning(f"Week {week_id} is LOCKED. Cannot re-aggregate weekly vehicle hisaab.")
            return

        week_start = week_info['week_start']
        week_end = week_info['week_end']
        year, week_num = (2000 + int(week_id[2:4]), int(week_id[6:])) if week_id.startswith('CY') else (int(week_id.split('-W')[0]), int(week_id.split('-W')[1]))

        vehicle_weekly_query = """
        WITH daily_agg AS (
            SELECT 
                week_id,
                vehicle_number,
                partner_id,
                MAX(partner_type) AS partner_type,
                MAX(city) AS city,
                MAX(vehicle_model) AS vehicle_model,
                COUNT(*) AS allotted_days,
                SUM(CASE WHEN is_billable_day THEN 1 ELSE 0 END) AS onroad_days,
                AVG(daily_rent_applied) AS daily_rent_applied,
                SUM(daily_rent_applied) AS weekly_lease_rental,
                SUM(daily_indemnity_fee) AS weekly_indemnity_fees,
                SUM(net_daily_rent) AS net_weekly_lease_rental,
                SUM(uber_trips) AS uber_trips,
                SUM(uber_fare_earnings) AS uber_total_earnings,
                SUM(uber_cash_collected) AS uber_cash_collection,
                SUM(uber_tolls) AS uber_toll,
                SUM(uber_subscription_charge) AS uber_driver_sub_charge,
                SUM(ola_trips) AS ola_trips,
                SUM(ola_net_revenue) AS ola_net_revenue,
                SUM(ola_tolls) AS ola_toll,
                SUM(ola_online_payment) AS ola_online_payment,
                SUM(weekly_incentive_credit) AS weekly_platform_incentive,
                SUM(daily_adjustments) AS vehicle_adjustments,
                SUM(daily_challans) AS challan_amount,
                SUM(daily_accident_recovery) AS accident_penalties
            FROM public.hisaab_daily_ledger
            WHERE week_id = %s
            GROUP BY week_id, vehicle_number, partner_id
        )
        INSERT INTO public.hisaab_vehicle_weekly (
            settlement_year,
            settlement_week,
            week_id,
            week_start,
            week_end,
            vehicle_number,
            partner_id,
            partner_name,
            partner_type,
            city,
            vehicle_model,
            rental_plan,
            allotted_days,
            onroad_days,
            daily_rent_applied,
            weekly_lease_rental,
            weekly_indemnity_fees,
            net_weekly_lease_rental,
            uber_trips,
            uber_total_earnings,
            uber_cash_collection,
            uber_toll,
            uber_driver_sub_charge,
            uber_week_os,
            ola_trips,
            ola_net_revenue,
            ola_toll,
            ola_gst,
            ola_online_payment,
            ola_week_os,
            weekly_platform_incentive,
            vehicle_adjustments,
            challan_amount,
            accident_penalties,
            dead_mile_charges,
            tds_amount,
            current_week_os,
            to_collect,
            to_payout,
            letzryd_earning,
            letzryd_earning_per_day,
            settlement_status,
            updated_at
        )
        SELECT 
            %s AS settlement_year,
            %s AS settlement_week,
            d.week_id,
            %s AS week_start,
            %s AS week_end,
            d.vehicle_number,
            d.partner_id,
            COALESCE(dr.driver_name, d.partner_id) AS partner_name,
            d.partner_type,
            d.city,
            d.vehicle_model,
            COALESCE(p.plan_scheme, 'Standard') AS rental_plan,
            d.allotted_days,
            d.onroad_days,
            d.daily_rent_applied,
            d.weekly_lease_rental,
            d.weekly_indemnity_fees,
            d.net_weekly_lease_rental,
            d.uber_trips,
            d.uber_total_earnings,
            d.uber_cash_collection,
            d.uber_toll,
            d.uber_driver_sub_charge,
            -- uber_week_os = -(Total Earnings + Cash Collection [negative] + Toll + Sub Charge)
            -(d.uber_total_earnings + d.uber_cash_collection + d.uber_toll - d.uber_driver_sub_charge) AS uber_week_os,
            d.ola_trips,
            d.ola_net_revenue,
            d.ola_toll,
            CASE WHEN d.city = 'BLR' THEN ROUND(d.ola_net_revenue * 0.05, 2) ELSE 0.00 END AS ola_gst,
            d.ola_online_payment,
            -- ola_week_os = -(Online payment + incentives)
            -(d.ola_online_payment) AS ola_week_os,
            d.weekly_platform_incentive,
            d.vehicle_adjustments,
            d.challan_amount,
            d.accident_penalties,
            0.00 AS dead_mile_charges,
            -- TDS 1% for Individual Drivers if Net Earnings > Rent
            CASE 
                WHEN d.partner_type = 'Operator' THEN 0.00
                WHEN (d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) > 0 
                THEN ROUND((d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
                ELSE 0.00 
            END AS tds_amount,
            -- current_week_os: Net vehicle position
            (
                d.net_weekly_lease_rental
                - (d.uber_total_earnings + d.uber_cash_collection + d.uber_toll - d.uber_driver_sub_charge)
                - d.ola_online_payment
                - d.weekly_platform_incentive
                + d.vehicle_adjustments
                + d.challan_amount
                + d.accident_penalties
                + CASE 
                    WHEN d.partner_type = 'Operator' THEN 0.00
                    WHEN (d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) > 0 
                    THEN ROUND((d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
                    ELSE 0.00 
                  END
            ) AS current_week_os,
            -- to_collect & to_payout
            GREATEST(0, (
                d.net_weekly_lease_rental
                - (d.uber_total_earnings + d.uber_cash_collection + d.uber_toll - d.uber_driver_sub_charge)
                - d.ola_online_payment
                - d.weekly_platform_incentive
                + d.vehicle_adjustments
                + d.challan_amount
                + d.accident_penalties
            )) AS to_collect,
            ABS(LEAST(0, (
                d.net_weekly_lease_rental
                - (d.uber_total_earnings + d.uber_cash_collection + d.uber_toll - d.uber_driver_sub_charge)
                - d.ola_online_payment
                - d.weekly_platform_incentive
                + d.vehicle_adjustments
                + d.challan_amount
                + d.accident_penalties
            ))) AS to_payout,
            -- LetzRyd margin = net rent + adjustments - challans
            (d.net_weekly_lease_rental + d.vehicle_adjustments - d.challan_amount) AS letzryd_earning,
            CASE WHEN d.onroad_days > 0 THEN ROUND((d.net_weekly_lease_rental + d.vehicle_adjustments - d.challan_amount) / d.onroad_days, 2) ELSE 0 END AS letzryd_earning_per_day,
            'OPEN' AS settlement_status,
            CURRENT_TIMESTAMP AS updated_at
        FROM daily_agg d
        LEFT JOIN LATERAL (
            SELECT partner_id, plan_scheme FROM public.core_rent 
            WHERE vehicle_number = d.vehicle_number 
            ORDER BY is_active DESC NULLS LAST, id DESC LIMIT 1
        ) p ON TRUE
        LEFT JOIN LATERAL (
            SELECT driver_name FROM public.core_partner_onboarding 
            WHERE partner_id = d.partner_id LIMIT 1
        ) dr ON TRUE
        ON CONFLICT (week_id, vehicle_number, partner_id) DO UPDATE SET
            allotted_days = EXCLUDED.allotted_days,
            onroad_days = EXCLUDED.onroad_days,
            daily_rent_applied = EXCLUDED.daily_rent_applied,
            weekly_lease_rental = EXCLUDED.weekly_lease_rental,
            weekly_indemnity_fees = EXCLUDED.weekly_indemnity_fees,
            net_weekly_lease_rental = EXCLUDED.net_weekly_lease_rental,
            uber_trips = EXCLUDED.uber_trips,
            uber_total_earnings = EXCLUDED.uber_total_earnings,
            uber_cash_collection = EXCLUDED.uber_cash_collection,
            uber_toll = EXCLUDED.uber_toll,
            uber_driver_sub_charge = EXCLUDED.uber_driver_sub_charge,
            uber_week_os = EXCLUDED.uber_week_os,
            ola_trips = EXCLUDED.ola_trips,
            ola_net_revenue = EXCLUDED.ola_net_revenue,
            ola_toll = EXCLUDED.ola_toll,
            ola_gst = EXCLUDED.ola_gst,
            ola_online_payment = EXCLUDED.ola_online_payment,
            ola_week_os = EXCLUDED.ola_week_os,
            weekly_platform_incentive = EXCLUDED.weekly_platform_incentive,
            vehicle_adjustments = EXCLUDED.vehicle_adjustments,
            challan_amount = EXCLUDED.challan_amount,
            accident_penalties = EXCLUDED.accident_penalties,
            tds_amount = EXCLUDED.tds_amount,
            current_week_os = EXCLUDED.current_week_os,
            to_collect = EXCLUDED.to_collect,
            to_payout = EXCLUDED.to_payout,
            letzryd_earning = EXCLUDED.letzryd_earning,
            letzryd_earning_per_day = EXCLUDED.letzryd_earning_per_day,
            updated_at = CURRENT_TIMESTAMP
        WHERE public.hisaab_vehicle_weekly.settlement_status = 'OPEN';
        """
        cur.execute(vehicle_weekly_query, (week_id, year, week_num, week_start, week_end))
        conn.commit()
        logger.info(f"Weekly vehicle hisaab roll-up completed for {week_id}. Rows affected: {cur.rowcount}")

        # Now consolidate into hisaab_partner_weekly
        sync_partner_weekly_payout(conn, week_id, year, week_num, week_start, week_end)

    except Exception as e:
        conn.rollback()
        logger.error(f"Error rolling up weekly vehicle hisaab for {week_id}: {e}", exc_info=True)
    finally:
        cur.close()
        conn.close()

def sync_partner_weekly_payout(conn, week_id, year, week_num, week_start, week_end):
    """
    Consolidates vehicle breakdowns into hisaab_partner_weekly.
    Grain: (week_id, partner_id)
    Mirrors Excel 'Hisaab Summary' / 'Revised Hisaab Summary'.
    Pulls opening dues from prior week and routes prior-period adjustments.
    """
    logger.info(f"Consolidating Partner Weekly Payout statements for week {week_id}...")
    cur = conn.cursor(cursor_factory=RealDictCursor)
    try:
        # Determine previous week ID
        prev_week_end = week_start - datetime.timedelta(days=1)
        prev_year, prev_week_num, _ = prev_week_end.isocalendar()
        prev_week_id = f"CY{str(prev_year)[-2:]}WK{prev_week_num:02d}"

        partner_payout_query = """
        WITH veh_summary AS (
            SELECT 
                partner_id,
                MAX(partner_name) AS partner_name,
                MAX(partner_type) AS partner_type,
                MAX(city) AS city,
                COUNT(DISTINCT vehicle_number) AS allotted_cars_count,
                SUM(onroad_days) AS total_onroad_days,
                SUM(uber_trips + ola_trips + rapido_trips) AS total_trips,
                SUM(net_weekly_lease_rental) AS total_net_rent_billed,
                SUM(uber_total_earnings + ola_net_revenue + rapido_net_revenue) AS total_platform_earnings,
                SUM(ABS(uber_cash_collection) + ABS(ola_online_payment)) AS total_cash_collected,
                SUM(weekly_platform_incentive) AS total_platform_incentives,
                SUM(vehicle_adjustments) AS total_adjustments,
                SUM(challan_amount) AS total_challans,
                SUM(accident_penalties) AS total_accidents,
                SUM(tds_amount) AS total_tds,
                SUM(current_week_os) AS current_week_os
            FROM public.hisaab_vehicle_weekly
            WHERE week_id = %s
            GROUP BY partner_id
        ),
        prior_adj AS (
            SELECT 
                partner_id,
                SUM(amount) AS prior_period_adjustments
            FROM public.hisaab_adjustments_ledger
            WHERE settlement_week_id = %s AND is_prior_period = TRUE
            GROUP BY partner_id
        ),
        prev_dues AS (
            SELECT 
                partner_id,
                total_outstanding AS previous_outstanding
            FROM public.hisaab_partner_weekly
            WHERE week_id = %s
        )
        INSERT INTO public.hisaab_partner_weekly (
            settlement_year,
            settlement_week,
            week_id,
            week_start,
            week_end,
            partner_id,
            partner_name,
            partner_type,
            city,
            allotted_cars_count,
            total_onroad_days,
            total_trips,
            total_net_rent_billed,
            total_platform_earnings,
            total_cash_collected,
            total_platform_incentives,
            total_adjustments,
            total_challans,
            total_accidents,
            total_tds,
            current_week_os,
            previous_outstanding,
            amount_paid_during_week,
            prior_period_adjustments,
            security_deposit_target,
            security_deposit_paid,
            deposit_deduction_current_week,
            pending_deposit,
            total_outstanding,
            net_bank_payout,
            net_amount_to_collect,
            settlement_status,
            updated_at
        )
        SELECT 
            %s AS settlement_year,
            %s AS settlement_week,
            %s AS week_id,
            %s AS week_start,
            %s AS week_end,
            v.partner_id,
            v.partner_name,
            v.partner_type,
            v.city,
            v.allotted_cars_count,
            v.total_onroad_days,
            v.total_trips,
            v.total_net_rent_billed,
            v.total_platform_earnings,
            v.total_cash_collected,
            v.total_platform_incentives,
            v.total_adjustments,
            v.total_challans,
            v.total_accidents,
            v.total_tds,
            v.current_week_os,
            COALESCE(pd.previous_outstanding, 0.00) AS previous_outstanding,
            0.00 AS amount_paid_during_week,
            COALESCE(pa.prior_period_adjustments, 0.00) AS prior_period_adjustments,
            5000.00 AS security_deposit_target,
            5000.00 AS security_deposit_paid,
            0.00 AS deposit_deduction_current_week,
            0.00 AS pending_deposit,
            -- total_outstanding = current_week_os + previous_outstanding + prior_period_adjustments
            (v.current_week_os + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00)) AS total_outstanding,
            -- net_bank_payout = if negative, company pays partner
            ABS(LEAST(0, (v.current_week_os + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00)))) AS net_bank_payout,
            -- net_amount_to_collect = if positive, partner owes company
            GREATEST(0, (v.current_week_os + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00)))) AS net_amount_to_collect,
            'DRAFT' AS settlement_status,
            CURRENT_TIMESTAMP AS updated_at
        FROM veh_summary v
        LEFT JOIN prior_adj pa ON v.partner_id = pa.partner_id
        LEFT JOIN prev_dues pd ON v.partner_id = pd.partner_id
        ON CONFLICT (week_id, partner_id) DO UPDATE SET
            allotted_cars_count = EXCLUDED.allotted_cars_count,
            total_onroad_days = EXCLUDED.total_onroad_days,
            total_trips = EXCLUDED.total_trips,
            total_net_rent_billed = EXCLUDED.total_net_rent_billed,
            total_platform_earnings = EXCLUDED.total_platform_earnings,
            total_cash_collected = EXCLUDED.total_cash_collected,
            total_platform_incentives = EXCLUDED.total_platform_incentives,
            total_adjustments = EXCLUDED.total_adjustments,
            total_challans = EXCLUDED.total_challans,
            total_accidents = EXCLUDED.total_accidents,
            total_tds = EXCLUDED.total_tds,
            current_week_os = EXCLUDED.current_week_os,
            previous_outstanding = EXCLUDED.previous_outstanding,
            prior_period_adjustments = EXCLUDED.prior_period_adjustments,
            total_outstanding = EXCLUDED.total_outstanding,
            net_bank_payout = EXCLUDED.net_bank_payout,
            net_amount_to_collect = EXCLUDED.net_amount_to_collect,
            updated_at = CURRENT_TIMESTAMP
        WHERE public.hisaab_partner_weekly.settlement_status = 'DRAFT';
        """
        cur.execute(partner_payout_query, (week_id, week_id, prev_week_id, year, week_num, week_id, week_start, week_end))
        conn.commit()
        logger.info(f"Consolidated Partner Weekly statements updated: {cur.rowcount}")
    except Exception as e:
        conn.rollback()
        logger.error(f"Error in sync_partner_weekly_payout: {e}", exc_info=True)
    finally:
        cur.close()

def lock_settlement_week(week_id, locked_by='finance_admin'):
    """
    Engages the Monday 11:00 AM lock switch for a given settlement week.
    Freezes hisaab_settlement_weeks, hisaab_daily_ledger, hisaab_vehicle_weekly,
    and hisaab_partner_weekly.
    """
    logger.info(f"Engaging Settlement Lock for Week: {week_id} by {locked_by}...")
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SET hisaab.enforcing_lock = 'true';")
        cur.execute("""
            UPDATE public.hisaab_settlement_weeks
            SET is_locked = TRUE, locked_at = CURRENT_TIMESTAMP, locked_by = %s
            WHERE week_id = %s;
        """, (locked_by, week_id))

        cur.execute("""
            UPDATE public.hisaab_daily_ledger
            SET is_locked = TRUE
            WHERE week_id = %s;
        """, (week_id,))

        cur.execute("""
            UPDATE public.hisaab_vehicle_weekly
            SET settlement_status = 'FROZEN'
            WHERE week_id = %s;
        """, (week_id,))

        cur.execute("""
            UPDATE public.hisaab_partner_weekly
            SET settlement_status = 'FROZEN', frozen_at = CURRENT_TIMESTAMP
            WHERE week_id = %s;
        """, (week_id,))

        conn.commit()
        logger.info(f"Week {week_id} is now FROZEN and IMMUTABLE.")
    except Exception as e:
        conn.rollback()
        logger.error(f"Error locking week {week_id}: {e}")
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
        logger.info("Usage: python automation_script.py [--daily YYYY-MM-DD | --weekly YYYY-Www | --lock YYYY-Www]")
