-- ============================================================================
-- LETZRYD HISAAB ENGINE - PRODUCTION STORED PROCEDURES & CANONICAL VIEWS
-- Verified on: September 22, 2026
-- ============================================================================

-- 1. sp_sync_hisaab_vehicle_weekly (Sign-Resilient)
CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_vehicle_weekly(IN p_week_id character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week RECORD;
    v_uber_count INT;
    v_ola_count INT;
BEGIN
    FOR v_week IN (
        SELECT week_id, week_start, week_end, is_locked
        FROM public.hisaab_settlement_weeks
        WHERE (p_week_id IS NOT NULL AND week_id = p_week_id)
           OR (p_week_id IS NULL AND is_locked = FALSE AND week_start <= CURRENT_DATE)
        ORDER BY week_start
    ) LOOP
        
        RAISE NOTICE 'Processing Hisaab Vehicle Weekly sync for week: % (% to %)', v_week.week_id, v_week.week_start, v_week.week_end;

        SELECT COUNT(*) INTO v_uber_count FROM public.core_uber_weekly WHERE week_id = v_week.week_id;
        SELECT COUNT(*) INTO v_ola_count FROM public.core_ola_weekly WHERE week_id = v_week.week_id;

        WITH rent_agg AS (
            SELECT 
                d.vehicle_number,
                COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') AS partner_id,
                (ARRAY_AGG(d.city ORDER BY d.log_date DESC))[1] AS city,
                (ARRAY_AGG(d.vehicle_model ORDER BY d.log_date DESC))[1] AS vehicle_model,
                (ARRAY_AGG(p.plan_name ORDER BY d.log_date DESC))[1] AS rental_plan,
                COUNT(d.log_date) AS allotted_days,
                COUNT(CASE WHEN d.attendance_status IN ('Active', 'Allocation', 'Same Day D&A') AND d.is_billable_day = TRUE THEN 1 END) AS onroad_days,
                ROUND(AVG(d.applied_daily_rent), 2) AS daily_rent_applied,
                SUM(d.applied_daily_rent) AS weekly_lease_rental,
                SUM(d.applied_daily_indemnity) AS weekly_indemnity_fees,
                SUM(d.net_daily_rent) AS net_weekly_lease_rental
            FROM public.daily_rent_log d
            LEFT JOIN public.core_rental_plans p ON d.matched_plan_id = p.plan_id
            WHERE d.log_date BETWEEN v_week.week_start AND v_week.week_end
              AND NOT (
                  COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') = 'SYSTEM_ONBOARDED'
                  AND EXISTS (
                      SELECT 1 FROM public.daily_rent_log d2
                      WHERE d2.log_date BETWEEN v_week.week_start AND v_week.week_end
                        AND d2.vehicle_number = d.vehicle_number
                        AND COALESCE(NULLIF(TRIM(d2.partner_id), ''), 'SYSTEM_ONBOARDED') <> 'SYSTEM_ONBOARDED'
                  )
              )
            GROUP BY d.vehicle_number, COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED')
        ),
        rent_ranked AS (
            SELECT 
                ra.*,
                ROW_NUMBER() OVER(
                    PARTITION BY UPPER(REPLACE(REPLACE(ra.vehicle_number, ' ', ''), '-', '')) 
                    ORDER BY ra.allotted_days DESC, ra.net_weekly_lease_rental DESC
                ) as partner_rank
            FROM rent_agg ra
        ),
        uber_agg AS (
            SELECT 
                UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(u.completed_trips), 0) AS uber_trips,
                COALESCE(SUM(ABS(u.uber_total_earnings)), 0.00) AS uber_total_earnings,
                COALESCE(SUM(ABS(u.uber_cash_collection)), 0.00) AS uber_cash_collection,
                COALESCE(SUM(ABS(u.uber_toll)), 0.00) AS uber_toll,
                COALESCE(SUM(ABS(u.uber_driver_sub_charge)), 0.00) AS uber_driver_sub_charge,
                COALESCE(SUM(ABS(u.uber_vehicle_incentive)), 0.00) AS uber_incentive,
                -- Universal sign convention: Net platform balance = (Earnings + Incentive + Toll - Cash - SubCharge)
                COALESCE(SUM(
                    ABS(u.uber_total_earnings) + ABS(u.uber_vehicle_incentive) + ABS(u.uber_toll)
                    - ABS(u.uber_cash_collection) - ABS(u.uber_driver_sub_charge)
                ), 0.00) AS uber_week_os
            FROM public.core_uber_weekly u
            WHERE u.week_id = v_week.week_id
              AND v_uber_count > 0
            GROUP BY UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', ''))
            
            UNION ALL
            
            SELECT 
                UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(u.completed_trips), 0) AS uber_trips,
                COALESCE(SUM(ABS(u.net_fare_earnings)), 0.00) AS uber_total_earnings,
                COALESCE(SUM(ABS(u.cash_collected)), 0.00) AS uber_cash_collection,
                COALESCE(SUM(ABS(u.tolls_refunded)), 0.00) AS uber_toll,
                COALESCE(SUM(ABS(u.driver_subscription_charge)), 0.00) AS uber_driver_sub_charge,
                0.00 AS uber_incentive,
                COALESCE(SUM(
                    ABS(u.net_fare_earnings) + ABS(u.tolls_refunded)
                    - ABS(u.cash_collected) - ABS(u.driver_subscription_charge)
                ), 0.00) AS uber_week_os
            FROM public.core_uber_daily u
            WHERE u.operational_date BETWEEN v_week.week_start AND v_week.week_end
              AND v_uber_count = 0
            GROUP BY UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', ''))
        ),
        ola_agg AS (
            SELECT 
                UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(o.completed_trips), 0) AS ola_trips,
                COALESCE(SUM(ABS(o.ola_net_revenue)), 0.00) AS ola_net_revenue,
                COALESCE(SUM(ABS(o.ola_cash_collected)), 0.00) AS ola_cash_collection,
                COALESCE(SUM(ABS(o.ola_toll)), 0.00) AS ola_toll,
                0.00 AS ola_gst,
                COALESCE(SUM(ABS(o.ola_online_payment_deductions)), 0.00) AS ola_online_payment,
                COALESCE(SUM(ABS(o.ola_portal_incentive)), 0.00) AS ola_incentive,
                COALESCE(SUM(
                    ABS(o.ola_net_revenue) + ABS(o.ola_portal_incentive) + ABS(o.ola_toll)
                    - ABS(o.ola_cash_collected)
                ), 0.00) AS ola_week_os
            FROM public.core_ola_weekly o
            WHERE o.week_id = v_week.week_id
              AND v_ola_count > 0
            GROUP BY UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', ''))
            
            UNION ALL
            
            SELECT 
                UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(o.completed_trips), 0) AS ola_trips,
                COALESCE(SUM(ABS(o.operator_bill)), 0.00) AS ola_net_revenue,
                COALESCE(SUM(ABS(o.cash_collected)), 0.00) AS ola_cash_collection,
                COALESCE(SUM(ABS(o.toll_and_parking)), 0.00) AS ola_toll,
                0.00 AS ola_gst,
                COALESCE(SUM(ABS(o.online_payouts)), 0.00) AS ola_online_payment,
                COALESCE(SUM(ABS(o.portal_incentive)), 0.00) AS ola_incentive,
                COALESCE(SUM(
                    ABS(o.operator_bill) + ABS(o.portal_incentive) + ABS(o.toll_and_parking)
                    - ABS(o.cash_collected)
                ), 0.00) AS ola_week_os
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
            CASE WHEN r.onroad_days > 0 THEN ROUND(r.weekly_lease_rental / r.onroad_days, 2) ELSE 0.00 END AS daily_rent_applied,
            r.weekly_lease_rental,
            r.weekly_indemnity_fees,
            r.net_weekly_lease_rental,
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
$procedure$
;

-- 2. sp_sync_hisaab_partner_weekly
CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_partner_weekly(IN p_week_id character varying, IN p_partner character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_is_locked BOOLEAN;
    v_prev_week_id VARCHAR;
    v_prev_week_end DATE;
    v_enable_roll_forward BOOLEAN := FALSE;
BEGIN
    IF p_week_id IS NULL THEN
        RETURN;
    END IF;

    PERFORM public.fn_ensure_hisaab_week(p_week_id, NULL);
    SELECT is_locked, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = p_week_id;

    IF v_is_locked = TRUE THEN
        RETURN;
    END IF;

    SELECT (COALESCE(config_value, 'false') = 'true') INTO v_enable_roll_forward
    FROM public.hisaab_system_config
    WHERE config_key = 'enable_roll_forward';

    v_prev_week_end := v_week_start - INTERVAL '1 day';
    v_prev_week_id := 'CY' || to_char(v_prev_week_end, 'IY') || 'WK' || to_char(v_prev_week_end, 'IW');

    WITH veh_summary AS (
        SELECT 
            v.partner_id,
            MAX(v.partner_name) AS partner_name,
            CASE WHEN v.partner_id ILIKE '%IP%' OR v.partner_id ILIKE '%OP%' THEN 'Operator' ELSE 'Individual' END AS partner_type,
            MAX(v.city) AS city,
            COUNT(DISTINCT v.vehicle_number)::INT AS allotted_cars_count,
            SUM(COALESCE(v.onroad_days, 0))::INT AS total_onroad_days,
            SUM(COALESCE(v.uber_trips, 0) + COALESCE(v.ola_trips, 0))::INT AS total_trips,
            SUM(COALESCE(v.net_weekly_lease_rental, 0.00)) AS total_net_rent_billed,
            SUM(COALESCE(v.uber_total_earnings, 0.00) + COALESCE(v.ola_net_revenue, 0.00)) AS total_platform_earnings,
            SUM(ABS(COALESCE(v.uber_cash_collection, 0.00)) + ABS(COALESCE(v.ola_cash_collection, 0.00))) AS total_cash_collected,
            SUM(COALESCE(v.uber_incentive, 0.00) + COALESCE(v.ola_incentive, 0.00)) AS total_platform_incentives,
            SUM(COALESCE(v.adjustment_amount, 0.00)) AS total_adjustments,
            SUM(COALESCE(v.challan_amount, 0.00)) AS total_challans,
            SUM(COALESCE(v.accident_deduction, 0.00)) AS total_accidents,
            SUM(COALESCE(v.tds_amount, 0.00)) AS total_tds,
            SUM(COALESCE(v.current_week_os, 0.00)) AS current_week_os
        FROM public.hisaab_vehicle_weekly v
        WHERE v.week_id = p_week_id
          AND (p_partner IS NULL OR v.partner_id = p_partner)
        GROUP BY v.partner_id
    ),
    prior_adj AS (
        SELECT 
            partner_id,
            COALESCE(SUM(CASE WHEN polarity = 'DEBIT' THEN amount ELSE -amount END), 0.00) AS prior_period_adjustments
        FROM public.hisaab_adjustments_ledger
        WHERE approval_status = 'APPROVED'
          AND settlement_week_id = p_week_id
          AND is_prior_period = TRUE
          AND (p_partner IS NULL OR partner_id = p_partner)
        GROUP BY partner_id
    ),
    prev_dues AS (
        SELECT 
            ap.partner_id,
            CASE 
                WHEN op.opening_balance_due IS NOT NULL THEN op.opening_balance_due
                WHEN v_enable_roll_forward = TRUE AND pw.total_outstanding > 0 THEN pw.total_outstanding
                ELSE 0.00 
            END AS previous_outstanding
        FROM (
            SELECT partner_id FROM veh_summary
            UNION
            SELECT partner_id FROM prior_adj
            UNION
            SELECT partner_id FROM public.hisaab_partner_opening_balances WHERE effective_week_id = p_week_id
            UNION
            SELECT partner_id FROM public.hisaab_partner_weekly WHERE v_enable_roll_forward = TRUE AND week_id = v_prev_week_id AND total_outstanding > 0
        ) ap
        LEFT JOIN public.hisaab_partner_opening_balances op 
            ON op.partner_id = ap.partner_id AND op.effective_week_id = p_week_id
        LEFT JOIN public.hisaab_partner_weekly pw 
            ON pw.week_id = v_prev_week_id AND pw.partner_id = ap.partner_id
        WHERE (p_partner IS NULL OR ap.partner_id = p_partner)
    ),
    existing_payments AS (
        SELECT 
            partner_id,
            COALESCE(amount_paid_during_week, 0.00) AS amount_paid_during_week
        FROM public.hisaab_partner_weekly
        WHERE week_id = p_week_id
          AND (p_partner IS NULL OR partner_id = p_partner)
    ),
    all_partners AS (
        SELECT partner_id FROM prev_dues
        WHERE previous_outstanding <> 0.00 
           OR partner_id IN (SELECT partner_id FROM veh_summary)
           OR partner_id IN (SELECT partner_id FROM prior_adj)
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
        payout_account_number,
        payout_ifsc,
        updated_at
    )
    SELECT 
        v_year,
        v_week_num,
        p_week_id,
        v_week_start,
        v_week_end,
        ap.partner_id,
        COALESCE(v.partner_name, dr.driver_name, ap.partner_id) AS partner_name,
        COALESCE(v.partner_type, CASE WHEN ap.partner_id ILIKE '%IP%' OR ap.partner_id ILIKE '%OP%' THEN 'Operator' ELSE 'Individual' END) AS partner_type,
        COALESCE(v.city, 'HYD') AS city,
        COALESCE(v.allotted_cars_count, 0) AS allotted_cars_count,
        COALESCE(v.total_onroad_days, 0) AS total_onroad_days,
        COALESCE(v.total_trips, 0) AS total_trips,
        COALESCE(v.total_net_rent_billed, 0.00) AS total_net_rent_billed,
        COALESCE(v.total_platform_earnings, 0.00) AS total_platform_earnings,
        COALESCE(v.total_cash_collected, 0.00) AS total_cash_collected,
        COALESCE(v.total_platform_incentives, 0.00) AS total_platform_incentives,
        COALESCE(v.total_adjustments, 0.00) AS total_adjustments,
        COALESCE(v.total_challans, 0.00) AS total_challans,
        COALESCE(v.total_accidents, 0.00) AS total_accidents,
        COALESCE(v.total_tds, 0.00) AS total_tds,
        COALESCE(v.current_week_os, 0.00) AS current_week_os,
        COALESCE(pd.previous_outstanding, 0.00) AS previous_outstanding,
        COALESCE(ep.amount_paid_during_week, 0.00) AS amount_paid_during_week,
        COALESCE(pa.prior_period_adjustments, 0.00) AS prior_period_adjustments,
        COALESCE(dr.security_deposit, 5000.00) AS security_deposit_target,
        COALESCE(dr.security_deposit, 5000.00) AS security_deposit_paid,
        0.00 AS deposit_deduction_current_week,
        0.00 AS pending_deposit,
        (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00) - COALESCE(ep.amount_paid_during_week, 0.00)) AS total_outstanding,
        ABS(LEAST(0, (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00) - COALESCE(ep.amount_paid_during_week, 0.00)))) AS net_bank_payout,
        GREATEST(0, (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00) - COALESCE(ep.amount_paid_during_week, 0.00))) AS net_amount_to_collect,
        'DRAFT' AS settlement_status,
        dr.account_number AS payout_account_number,
        dr.ifsc_code AS payout_ifsc,
        CURRENT_TIMESTAMP AS updated_at
    FROM all_partners ap
    LEFT JOIN veh_summary v ON ap.partner_id = v.partner_id
    LEFT JOIN prior_adj pa ON ap.partner_id = pa.partner_id
    LEFT JOIN prev_dues pd ON ap.partner_id = pd.partner_id
    LEFT JOIN existing_payments ep ON ap.partner_id = ep.partner_id
    LEFT JOIN LATERAL (
        SELECT account_number, ifsc_code, driver_name, security_deposit FROM public.core_partner_onboarding 
        WHERE partner_id = ap.partner_id LIMIT 1
    ) dr ON TRUE
    ON CONFLICT (week_id, partner_id) DO UPDATE SET
        partner_name = COALESCE(EXCLUDED.partner_name, public.hisaab_partner_weekly.partner_name),
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
        amount_paid_during_week = COALESCE(public.hisaab_partner_weekly.amount_paid_during_week, 0.00),
        security_deposit_target = EXCLUDED.security_deposit_target,
        security_deposit_paid = EXCLUDED.security_deposit_paid,
        total_outstanding = (EXCLUDED.current_week_os + EXCLUDED.previous_outstanding + EXCLUDED.prior_period_adjustments - COALESCE(public.hisaab_partner_weekly.amount_paid_during_week, 0.00)),
        net_bank_payout = ABS(LEAST(0, (EXCLUDED.current_week_os + EXCLUDED.previous_outstanding + EXCLUDED.prior_period_adjustments - COALESCE(public.hisaab_partner_weekly.amount_paid_during_week, 0.00)))),
        net_amount_to_collect = GREATEST(0, (EXCLUDED.current_week_os + EXCLUDED.previous_outstanding + EXCLUDED.prior_period_adjustments - COALESCE(public.hisaab_partner_weekly.amount_paid_during_week, 0.00))),
        payout_account_number = COALESCE(EXCLUDED.payout_account_number, public.hisaab_partner_weekly.payout_account_number),
        payout_ifsc = COALESCE(EXCLUDED.payout_ifsc, public.hisaab_partner_weekly.payout_ifsc),
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_partner_weekly.settlement_status IN ('DRAFT', 'OPEN');
END;
$procedure$
;

-- 3. sp_sync_rent_to_hisaab
CREATE OR REPLACE PROCEDURE public.sp_sync_rent_to_hisaab(IN p_week_id character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week_id VARCHAR(16);
    v_week_start DATE;
    v_week_end DATE;
    v_is_locked BOOLEAN := FALSE;
BEGIN
    IF p_week_id IS NULL THEN
        SELECT week_id, week_start, week_end, is_locked
        INTO v_week_id, v_week_start, v_week_end, v_is_locked
        FROM public.hisaab_settlement_weeks
        WHERE CURRENT_DATE BETWEEN week_start AND week_end
        LIMIT 1;
        
        IF v_week_id IS NULL THEN
            v_week_id := 'CY' || TO_CHAR(CURRENT_DATE, 'YY') || 'WK' || LPAD(TO_CHAR(CURRENT_DATE, 'IW'), 2, '0');
        END IF;
    ELSE
        v_week_id := p_week_id;
        SELECT week_start, week_end, is_locked
        INTO v_week_start, v_week_end, v_is_locked
        FROM public.hisaab_settlement_weeks
        WHERE week_id = v_week_id
        LIMIT 1;
    END IF;

    IF v_is_locked = TRUE THEN
        RAISE NOTICE 'Week % is locked. Skipping sync.', v_week_id;
        RETURN;
    END IF;

    -- Update hisaab_daily_ledger in set-based batch
    UPDATE public.hisaab_daily_ledger h
    SET 
        daily_rent_applied = d.applied_daily_rent,
        daily_indemnity_fee = d.applied_daily_indemnity,
        net_daily_rent = d.net_daily_rent,
        attendance_status = d.attendance_status,
        is_billable_day = d.is_billable_day,
        daily_net_balance = (
            COALESCE(d.net_daily_rent, 0.00)
            + (ABS(COALESCE(h.uber_cash_collected, 0.00)) + ABS(COALESCE(h.ola_cash_collected, 0.00)) + ABS(COALESCE(h.rapido_cash_collected, 0.00)))
            - (COALESCE(h.uber_fare_earnings, 0.00) + COALESCE(h.ola_net_revenue, 0.00) + COALESCE(h.rapido_net_revenue, 0.00))
            - COALESCE(h.ola_online_payment, 0.00)
            + COALESCE(h.daily_challans, 0.00)
            + COALESCE(h.daily_accident_recovery, 0.00)
            - COALESCE(h.daily_adjustments, 0.00)
            - COALESCE(h.weekly_incentive_credit, 0.00)
        ),
        updated_at = CURRENT_TIMESTAMP
    FROM public.daily_rent_log d
    WHERE h.log_date = d.log_date
      AND h.vehicle_number = d.vehicle_number
      AND h.partner_id = d.partner_id
      AND (h.week_id = v_week_id OR (v_week_start IS NOT NULL AND h.log_date BETWEEN v_week_start AND v_week_end));

    -- Bulk aggregate weekly vehicle ledger (Correct 1 argument call)
    CALL public.sp_sync_hisaab_vehicle_weekly(v_week_id);

    -- Bulk aggregate weekly partner ledger
    CALL public.sp_sync_hisaab_partner_weekly(v_week_id, NULL);

    RAISE NOTICE 'Successfully synced rent to hisaab for week %', v_week_id;
END;
$procedure$
;

-- 4. Canonical View: v_hisaab_partner_settlement_statement
CREATE OR REPLACE VIEW public.v_hisaab_partner_settlement_statement AS
SELECT 
    h.week_id,
    h.vehicle_number,
    h.partner_id,
    h.partner_name,
    h.city,
    h.vehicle_model,
    h.onroad_days,
    h.allotted_days,
    h.net_weekly_lease_rental,
    h.uber_trips,
    h.uber_total_earnings,
    h.uber_cash_collection,
    h.uber_toll,
    h.uber_incentive,
    h.uber_driver_sub_charge,
    h.uber_week_os,
    h.ola_trips,
    h.ola_net_revenue,
    h.ola_cash_collection,
    h.ola_toll,
    h.ola_incentive,
    h.ola_online_payment,
    h.ola_week_os,
    (h.uber_week_os + h.ola_week_os) AS total_net_platform_earnings,
    h.net_weekly_lease_rental AS total_company_lease_dues,
    (h.net_weekly_lease_rental - (h.uber_week_os + h.ola_week_os)) AS net_driver_balance_due,
    ((h.uber_week_os + h.ola_week_os) - h.net_weekly_lease_rental) AS net_payout_to_driver
FROM public.hisaab_vehicle_weekly h;
