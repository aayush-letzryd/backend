-- ============================================================================
-- LETZRYD HISAAB ENGINE - STORED PROCEDURES
-- Database: PostgreSQL 14+
-- Module: Hisaab Engine Automated Batch Calculations
-- Architecture: Set-based batch aggregation via pg_cron (Zero Triggers)
-- ============================================================================

CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_vehicle_weekly(IN p_week_id VARCHAR DEFAULT NULL)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week RECORD;
    v_uber_count INT;
    v_ola_count INT;
BEGIN
    -- Loop over target weeks: specific week if passed, else all open past/current weeks
    FOR v_week IN (
        SELECT week_id, week_start, week_end, is_locked
        FROM public.hisaab_settlement_weeks
        WHERE (p_week_id IS NOT NULL AND week_id = p_week_id)
           OR (p_week_id IS NULL AND is_locked = FALSE AND week_start <= CURRENT_DATE)
        ORDER BY week_start
    ) LOOP
        
        RAISE NOTICE 'Processing Hisaab Vehicle Weekly sync for week: % (% to %)', v_week.week_id, v_week.week_start, v_week.week_end;

        -- Check presence of weekly rollup data in core weekly tables
        SELECT COUNT(*) INTO v_uber_count FROM public.core_uber_weekly WHERE week_id = v_week.week_id;
        SELECT COUNT(*) INTO v_ola_count FROM public.core_ola_weekly WHERE week_id = v_week.week_id;

        -- Set-based atomic aggregation and upsert by (vehicle_number, partner_id)
        WITH rent_agg AS (
            -- RULE: Exclude SYSTEM_ONBOARDED shadow rows when a real partner already exists
            --       for the same vehicle in this week. SYSTEM_ONBOARDED only appears when
            --       no real partner has any entry in daily_rent_log for that vehicle+week.
            SELECT 
                d.vehicle_number,
                COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') AS partner_id,
                (ARRAY_AGG(d.city ORDER BY d.log_date DESC))[1] AS city,
                (ARRAY_AGG(d.vehicle_model ORDER BY d.log_date DESC))[1] AS vehicle_model,
                COUNT(DISTINCT d.log_date)::NUMERIC(4, 1) AS allotted_days,
                COUNT(DISTINCT CASE WHEN d.is_billable_day THEN d.log_date END)::NUMERIC(4, 1) AS onroad_days,
                CASE 
                    WHEN COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') ILIKE '%SYSTEM%'
                      OR SUM(CASE WHEN d.is_billable_day THEN 1 ELSE 0 END) = 0 THEN 0.00
                    ELSE COALESCE(SUM(CASE WHEN d.is_billable_day THEN d.applied_daily_rent ELSE 0 END), 0.00)
                END AS weekly_lease_rental,
                CASE 
                    WHEN COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') ILIKE '%SYSTEM%'
                      OR SUM(CASE WHEN d.is_billable_day THEN 1 ELSE 0 END) = 0 THEN 0.00
                    ELSE COALESCE(SUM(CASE WHEN d.is_billable_day THEN d.applied_daily_indemnity ELSE 0 END), 0.00)
                END AS weekly_indemnity_fees,
                CASE 
                    WHEN COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') ILIKE '%SYSTEM%'
                      OR SUM(CASE WHEN d.is_billable_day THEN 1 ELSE 0 END) = 0 THEN 0.00
                    ELSE COALESCE(SUM(CASE WHEN d.is_billable_day THEN d.net_daily_rent ELSE 0 END), 0.00)
                END AS net_weekly_lease_rental,
                MAX(d.calculation_rule) AS rental_plan
            FROM public.daily_rent_log d
            WHERE d.week_id = v_week.week_id
              AND NOT (
                  -- Drop SYSTEM_ONBOARDED when a real partner exists for this vehicle this week
                  COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') ILIKE '%SYSTEM%'
                  AND EXISTS (
                      SELECT 1 FROM public.daily_rent_log d2
                      WHERE d2.week_id = d.week_id
                        AND d2.vehicle_number = d.vehicle_number
                        AND COALESCE(NULLIF(TRIM(d2.partner_id), ''), 'SYSTEM_ONBOARDED') NOT ILIKE '%SYSTEM%'
                  )
              )
            GROUP BY d.vehicle_number, COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED')
        ),
        -- Rank partners per vehicle: partner with most allotted_days (ties broken by onroad_days)
        -- gets rank=1 and will receive 100% of Uber/OLA telemetry.
        -- This prevents double-counting when a vehicle has multiple partner rows.
        rent_ranked AS (
            SELECT *,
                ROW_NUMBER() OVER (
                    PARTITION BY vehicle_number
                    ORDER BY allotted_days DESC, onroad_days DESC
                ) AS partner_rank
            FROM rent_agg
        ),
        uber_agg AS (
            SELECT 
                UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(u.completed_trips), 0) AS uber_trips,
                COALESCE(SUM(u.uber_total_earnings), 0.00) AS uber_total_earnings,
                COALESCE(SUM(u.uber_cash_collection), 0.00) AS uber_cash_collection,
                COALESCE(SUM(u.uber_toll), 0.00) AS uber_toll,
                COALESCE(SUM(u.uber_driver_sub_charge), 0.00) AS uber_driver_sub_charge,
                COALESCE(SUM(u.uber_vehicle_incentive), 0.00) AS uber_incentive,
                COALESCE(SUM(u.uber_week_balance), 0.00) AS uber_week_os
            FROM public.core_uber_weekly u
            WHERE u.week_id = v_week.week_id
              AND v_uber_count > 0
            GROUP BY UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', ''))
            
            UNION ALL
            
            SELECT 
                UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(u.completed_trips), 0) AS uber_trips,
                COALESCE(SUM(u.net_fare_earnings), 0.00) AS uber_total_earnings,
                COALESCE(SUM(u.cash_collected), 0.00) AS uber_cash_collection,
                COALESCE(SUM(u.tolls_refunded), 0.00) AS uber_toll,
                COALESCE(SUM(u.driver_subscription_charge), 0.00) AS uber_driver_sub_charge,
                0.00 AS uber_incentive,
                (COALESCE(SUM(u.net_fare_earnings), 0.00) - COALESCE(SUM(u.cash_collected), 0.00) - COALESCE(SUM(u.driver_subscription_charge), 0.00)) AS uber_week_os
            FROM public.core_uber_daily u
            WHERE u.operational_date BETWEEN v_week.week_start AND v_week.week_end
              AND v_uber_count = 0
            GROUP BY UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', ''))
        ),
        ola_agg AS (
            SELECT 
                UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(o.completed_trips), 0) AS ola_trips,
                COALESCE(SUM(o.ola_net_revenue), 0.00) AS ola_net_revenue,
                COALESCE(SUM(o.ola_cash_collected), 0.00) AS ola_cash_collection,
                COALESCE(SUM(o.ola_toll), 0.00) AS ola_toll,
                0.00 AS ola_gst,
                COALESCE(SUM(o.ola_online_payment_deductions), 0.00) AS ola_online_payment,
                COALESCE(SUM(o.ola_portal_incentive), 0.00) AS ola_incentive,
                COALESCE(SUM(o.ola_week_outstanding), 0.00) AS ola_week_os
            FROM public.core_ola_weekly o
            WHERE o.week_id = v_week.week_id
              AND v_ola_count > 0
            GROUP BY UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', ''))
            
            UNION ALL
            
            SELECT 
                UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(o.completed_trips), 0) AS ola_trips,
                COALESCE(SUM(o.operator_bill), 0.00) AS ola_net_revenue,
                COALESCE(SUM(o.cash_collected), 0.00) AS ola_cash_collection,
                COALESCE(SUM(o.toll_and_parking), 0.00) AS ola_toll,
                0.00 AS ola_gst,
                COALESCE(SUM(o.net_ola_to_pay), 0.00) AS ola_online_payment,
                COALESCE(SUM(o.portal_incentive), 0.00) AS ola_incentive,
                (COALESCE(SUM(o.operator_bill), 0.00) - COALESCE(SUM(o.cash_collected), 0.00)) AS ola_week_os
            FROM public.core_ola_daily o
            WHERE o.service_date BETWEEN v_week.week_start AND v_week.week_end
              AND v_ola_count = 0
            GROUP BY UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', ''))
        ),
        partner_names AS (
            SELECT partner_id, driver_name FROM (
                SELECT partner_id, driver_name, ROW_NUMBER() OVER(PARTITION BY partner_id ORDER BY created_at DESC NULLS LAST) rn
                FROM public.core_partner_onboarding
            ) sub WHERE rn = 1
        ),
        custom_names AS (
            SELECT partner_id, partner_name FROM (
                SELECT partner_id, partner_name, ROW_NUMBER() OVER(PARTITION BY partner_id ORDER BY is_active DESC, custom_plan_id DESC) rn
                FROM public.rental_custom_partner_plans
                WHERE partner_name IS NOT NULL
            ) sub WHERE rn = 1
        )
        INSERT INTO public.hisaab_vehicle_weekly (
            week_id, week_start, week_end, vehicle_number, partner_id, partner_name,
            city, vehicle_model, rental_plan, allotted_days, onroad_days,
            daily_rent_applied, weekly_lease_rental, weekly_indemnity_fees, net_weekly_lease_rental,
            uber_trips, uber_total_earnings, uber_cash_collection, uber_toll, uber_driver_sub_charge, uber_incentive, uber_week_os,
            ola_trips, ola_net_revenue, ola_cash_collection, ola_toll, ola_gst, ola_online_payment, ola_incentive, ola_week_os,
            settlement_status, created_at, updated_at
        )
        SELECT 
            v_week.week_id,
            v_week.week_start,
            v_week.week_end,
            r.vehicle_number,
            r.partner_id,
            COALESCE(pn.driver_name, cn.partner_name, r.partner_id) AS partner_name,
            r.city,
            r.vehicle_model,
            r.rental_plan,
            r.allotted_days,
            r.onroad_days,
            CASE WHEN r.onroad_days > 0 THEN ROUND(r.net_weekly_lease_rental / r.onroad_days, 2) ELSE 0.00 END AS daily_rent_applied,
            r.weekly_lease_rental,
            r.weekly_indemnity_fees,
            r.net_weekly_lease_rental,
            -- Telemetry (Uber/OLA) only assigned to the partner with most allotted days (rank=1).
            -- Secondary partners get 0 to avoid double-counting telemetry across partner rows.
            CASE WHEN r.partner_rank = 1 THEN COALESCE(u.uber_trips, 0) ELSE 0 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(u.uber_total_earnings, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(u.uber_cash_collection, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(u.uber_toll, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(u.uber_driver_sub_charge, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(u.uber_incentive, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(u.uber_week_os, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(o.ola_trips, 0) ELSE 0 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(o.ola_net_revenue, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(o.ola_cash_collection, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(o.ola_toll, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(o.ola_gst, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(o.ola_online_payment, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(o.ola_incentive, 0.00) ELSE 0.00 END,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(o.ola_week_os, 0.00) ELSE 0.00 END,
            'CALCULATED',
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
        FROM rent_ranked r
        LEFT JOIN partner_names pn ON r.partner_id = pn.partner_id
        LEFT JOIN custom_names cn ON r.partner_id = cn.partner_id
        LEFT JOIN uber_agg u ON r.partner_rank = 1 AND UPPER(REPLACE(REPLACE(r.vehicle_number, ' ', ''), '-', '')) = u.vehicle_number
        LEFT JOIN ola_agg o ON r.partner_rank = 1 AND UPPER(REPLACE(REPLACE(r.vehicle_number, ' ', ''), '-', '')) = o.vehicle_number
        ON CONFLICT (week_id, vehicle_number, partner_id) DO UPDATE SET
            partner_name = EXCLUDED.partner_name,
            city = EXCLUDED.city,
            vehicle_model = EXCLUDED.vehicle_model,
            rental_plan = EXCLUDED.rental_plan,
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
            uber_incentive = EXCLUDED.uber_incentive,
            uber_week_os = EXCLUDED.uber_week_os,
            ola_trips = EXCLUDED.ola_trips,
            ola_net_revenue = EXCLUDED.ola_net_revenue,
            ola_cash_collection = EXCLUDED.ola_cash_collection,
            ola_toll = EXCLUDED.ola_toll,
            ola_gst = EXCLUDED.ola_gst,
            ola_online_payment = EXCLUDED.ola_online_payment,
            ola_incentive = EXCLUDED.ola_incentive,
            ola_week_os = EXCLUDED.ola_week_os,
            settlement_status = 'CALCULATED',
            updated_at = CURRENT_TIMESTAMP
        WHERE hisaab_vehicle_weekly.settlement_status <> 'LOCKED';
        
        RAISE NOTICE 'Completed sync for week %', v_week.week_id;
    END LOOP;
END;
$procedure$;
