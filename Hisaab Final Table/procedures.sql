-- ============================================================================
-- LETZRYD HISAAB ENGINE - PRODUCTION STORED PROCEDURES & CANONICAL VIEWS
-- Verified on: September 29, 2026
-- Includes:
-- 1. sp_sync_hisaab_vehicle_weekly (Audit Ledger + Daily Telematics & Dead Mile Penalty)
-- 2. sp_sync_hisaab_partner_weekly (Multi-vehicle partner aggregation & rollups)
-- 3. sp_sync_rent_to_hisaab (Nightly daily ledger sync with core_gps telematics)
-- 4. v_hisaab_partner_settlement_statement (Canonical settlement statement view)
-- 5. sp_sync_hisaab_vehicle_payout_weekly (Operational payout cutoff & frozen ledger)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. sp_sync_hisaab_vehicle_weekly
-- Calendar violation-date settlement procedure with daily GPS dead mile penalty
-- ----------------------------------------------------------------------------
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
        
        RAISE NOTICE 'Processing Hisaab Vehicle Weekly sync with GPS telematics for week: % (% to %)', v_week.week_id, v_week.week_start, v_week.week_end;

        SELECT COUNT(*) INTO v_uber_count FROM public.core_uber_weekly WHERE week_id = v_week.week_id;
        SELECT COUNT(*) INTO v_ola_count FROM public.core_ola_weekly WHERE week_id = v_week.week_id;

        -- Clean up orphaned / stale rows in hisaab_vehicle_weekly that no longer exist in daily_rent_log for this week
        DELETE FROM public.hisaab_vehicle_weekly h
        WHERE h.week_id = v_week.week_id
          AND h.settlement_status <> 'LOCKED'
          AND (
              NOT EXISTS (
                  SELECT 1 FROM public.daily_rent_log d
                  WHERE d.log_date BETWEEN v_week.week_start AND v_week.week_end
                    AND UPPER(REPLACE(REPLACE(d.vehicle_number, ' ', ''), '-', '')) = UPPER(REPLACE(REPLACE(h.vehicle_number, ' ', ''), '-', ''))
                    AND COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') = h.partner_id
              )
              OR
              (
                  h.partner_id = 'SYSTEM_ONBOARDED'
                  AND EXISTS (
                      SELECT 1 FROM public.daily_rent_log d
                      WHERE d.log_date BETWEEN v_week.week_start AND v_week.week_end
                        AND UPPER(REPLACE(REPLACE(d.vehicle_number, ' ', ''), '-', '')) = UPPER(REPLACE(REPLACE(h.vehicle_number, ' ', ''), '-', ''))
                        AND COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') <> 'SYSTEM_ONBOARDED'
                  )
              )
          );

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
        daily_driver_custody AS (
            SELECT 
                d.log_date,
                d.vehicle_number,
                d.partner_id,
                d.is_billable_day,
                ROW_NUMBER() OVER (
                    PARTITION BY d.log_date, d.vehicle_number
                    ORDER BY 
                        CASE WHEN COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') <> 'SYSTEM_ONBOARDED' THEN 0 ELSE 1 END,
                        d.net_daily_rent DESC,
                        d.id DESC
                ) AS custody_rank
            FROM public.daily_rent_log d
            WHERE d.log_date BETWEEN v_week.week_start AND v_week.week_end
        ),
        daily_gps AS (
            SELECT 
                g.record_date,
                UPPER(REPLACE(REPLACE(public.fn_clean_gps_vehicle_number(g.vehicle_number), ' ', ''), '-', '')) AS clean_veh,
                SUM(COALESCE(g.distance_km, 0.00)) AS gps_dist
            FROM public.core_gps g
            WHERE g.record_date BETWEEN v_week.week_start AND v_week.week_end
            GROUP BY g.record_date, UPPER(REPLACE(REPLACE(public.fn_clean_gps_vehicle_number(g.vehicle_number), ' ', ''), '-', ''))
        ),
        daily_uber AS (
            SELECT 
                u.operational_date,
                UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', '')) AS clean_veh,
                SUM(COALESCE(u.total_trip_distance_km, 0.00)) AS uber_dist,
                SUM(COALESCE(u.completed_trips, 0)) AS uber_trips,
                SUM(ABS(u.net_fare_earnings)) AS uber_earnings,
                SUM(ABS(u.cash_collected)) AS uber_cash,
                SUM(ABS(u.tolls_refunded)) AS uber_toll,
                SUM(ABS(u.driver_subscription_charge)) AS uber_sub
            FROM public.core_uber_daily u
            WHERE u.operational_date BETWEEN v_week.week_start AND v_week.week_end
            GROUP BY u.operational_date, UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', ''))
        ),
        daily_ola AS (
            SELECT 
                o.service_date,
                UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', '')) AS clean_veh,
                SUM(COALESCE(o.total_kms, 0.00)) AS ola_dist,
                SUM(COALESCE(o.completed_trips, 0)) AS ola_trips,
                SUM(ABS(o.operator_bill)) AS ola_revenue,
                SUM(ABS(o.cash_collected)) AS ola_cash,
                SUM(ABS(o.toll_and_parking)) AS ola_toll,
                SUM(ABS(o.online_payouts)) AS ola_payout,
                SUM(ABS(o.portal_incentive)) AS ola_inc
            FROM public.core_ola_daily o
            WHERE o.service_date BETWEEN v_week.week_start AND v_week.week_end
            GROUP BY o.service_date, UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', ''))
        ),
        uber_daily_partner_agg AS (
            SELECT 
                dc.vehicle_number,
                dc.partner_id,
                COALESCE(SUM(u.uber_trips), 0) AS uber_trips,
                COALESCE(SUM(u.uber_earnings), 0.00) AS uber_total_earnings,
                COALESCE(SUM(u.uber_cash), 0.00) AS uber_cash_collection,
                COALESCE(SUM(u.uber_toll), 0.00) AS uber_toll,
                COALESCE(SUM(u.uber_sub), 0.00) AS uber_driver_sub_charge,
                COALESCE(SUM(u.uber_earnings + u.uber_toll - u.uber_cash - u.uber_sub), 0.00) AS uber_week_os
            FROM daily_driver_custody dc
            JOIN daily_uber u ON u.operational_date = dc.log_date AND u.clean_veh = dc.vehicle_number
            WHERE dc.custody_rank = 1
            GROUP BY dc.vehicle_number, dc.partner_id
        ),
        ola_daily_partner_agg AS (
            SELECT 
                dc.vehicle_number,
                dc.partner_id,
                COALESCE(SUM(o.ola_trips), 0) AS ola_trips,
                COALESCE(SUM(o.ola_revenue), 0.00) AS ola_net_revenue,
                COALESCE(SUM(o.ola_cash), 0.00) AS ola_cash_collection,
                COALESCE(SUM(o.ola_toll), 0.00) AS ola_toll,
                0.00 AS ola_gst,
                COALESCE(SUM(o.ola_payout), 0.00) AS ola_online_payment,
                COALESCE(SUM(o.ola_inc), 0.00) AS ola_incentive,
                COALESCE(SUM(o.ola_revenue + o.ola_inc + o.ola_toll - o.ola_cash), 0.00) AS ola_week_os
            FROM daily_driver_custody dc
            JOIN daily_ola o ON o.service_date = dc.log_date AND o.clean_veh = dc.vehicle_number
            WHERE dc.custody_rank = 1
            GROUP BY dc.vehicle_number, dc.partner_id
        ),
        gps_daily_partner_agg AS (
            SELECT 
                dc.vehicle_number,
                dc.partner_id,
                COALESCE(SUM(g.gps_dist), 0.00) AS total_gps_km,
                COALESCE(SUM(COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00)), 0.00) AS total_trip_km,
                COALESCE(SUM(
                    GREATEST(0.00, COALESCE(g.gps_dist, 0.00) - (
                        (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                        + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                        + (CASE WHEN dc.is_billable_day THEN 25.00 ELSE 0.00 END)
                    ))
                ), 0.00) AS gps_dead_km,
                COALESCE(SUM(
                    CASE 
                        WHEN (COALESCE(po.onboarding_type, 'Individual') = 'Individual' OR po.driver_plan ILIKE '%D2R%')
                             AND (COALESCE(g.gps_dist, 0.00) - (
                                 (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                                 + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                                 + (CASE WHEN dc.is_billable_day THEN 25.00 ELSE 0.00 END)
                             )) > 0
                        THEN ROUND((COALESCE(g.gps_dist, 0.00) - (
                                 (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                                 + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                                 + (CASE WHEN dc.is_billable_day THEN 25.00 ELSE 0.00 END)
                             )) * 3.00, 2)
                        ELSE 0.00
                    END
                ), 0.00) AS gps_dead_mile_penalty
            FROM daily_driver_custody dc
            LEFT JOIN daily_gps g ON g.record_date = dc.log_date AND g.clean_veh = dc.vehicle_number
            LEFT JOIN daily_uber u ON u.operational_date = dc.log_date AND u.clean_veh = dc.vehicle_number
            LEFT JOIN daily_ola o ON o.service_date = dc.log_date AND o.clean_veh = dc.vehicle_number
            LEFT JOIN public.core_partner_onboarding po ON po.partner_id = dc.partner_id
            WHERE dc.custody_rank = 1
            GROUP BY dc.vehicle_number, dc.partner_id
        ),
        adj_agg AS (
            SELECT 
                UPPER(REPLACE(REPLACE(c.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                c.partner_id,
                COALESCE(SUM(CASE WHEN c.financial_direction = 'CREDIT' THEN -c.amount ELSE c.amount END), 0.00) AS net_adj_signed
            FROM public.core_adjustments c
            WHERE c.is_deleted = FALSE 
              AND c.approval_status = 'Approved'
              AND c.adjustment_date BETWEEN v_week.week_start AND v_week.week_end
              AND c.vehicle_number IS NOT NULL AND TRIM(c.vehicle_number) <> ''
            GROUP BY UPPER(REPLACE(REPLACE(c.vehicle_number, ' ', ''), '-', '')), c.partner_id
        ),
        adj_veh_fallback AS (
            SELECT 
                UPPER(REPLACE(REPLACE(c.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(SUM(CASE WHEN c.financial_direction = 'CREDIT' THEN -c.amount ELSE c.amount END), 0.00) AS net_adj_signed
            FROM public.core_adjustments c
            WHERE c.is_deleted = FALSE 
              AND c.approval_status = 'Approved'
              AND c.adjustment_date BETWEEN v_week.week_start AND v_week.week_end
              AND c.vehicle_number IS NOT NULL AND TRIM(c.vehicle_number) <> ''
              AND (c.partner_id IS NULL OR TRIM(c.partner_id) = '')
            GROUP BY UPPER(REPLACE(REPLACE(c.vehicle_number, ' ', ''), '-', ''))
        ),
        challan_daily_partner_agg AS (
            SELECT 
                c.vehicle_number,
                COALESCE(SUM(c.challan_amount), 0.00) AS challan_amount
            FROM (
                SELECT 
                    UPPER(REPLACE(REPLACE(c.vehicle_reg_no, ' ', ''), '-', '')) AS vehicle_number,
                    c.violation_date,
                    COALESCE(NULLIF(c.net_pending_amount, 0.00), c.total_fine_amount) AS challan_amount
                FROM public.core_challans c
                WHERE c.violation_date BETWEEN v_week.week_start AND v_week.week_end
                  AND c.is_deleted = FALSE
                  AND c.payment_status IN ('UNPAID', 'PARTIALLY_PAID')
                  AND c.liability_type IN ('TRAFFIC_FINE', 'STICKER_FINE')
            ) c
            GROUP BY c.vehicle_number
        ),
        existing_hisaab AS (
            SELECT 
                vehicle_number,
                partner_id,
                COALESCE(accident_deduction, 0.00) AS accident_deduction,
                COALESCE(tds_amount, 0.00) AS tds_amount,
                COALESCE(gps_dead_mile_penalty, 0.00) AS gps_dead_mile_penalty
            FROM public.hisaab_vehicle_weekly
            WHERE week_id = v_week.week_id
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
            adjustment_amount, challan_amount, gps_dead_km, gps_dead_mile_penalty, current_week_os, net_to_collect_from_driver, net_payout_to_driver,
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
            COALESCE(udpa.uber_trips, CASE WHEN r.partner_rank = 1 THEN u.uber_trips ELSE 0 END, 0),
            COALESCE(udpa.uber_total_earnings, CASE WHEN r.partner_rank = 1 THEN u.uber_total_earnings ELSE 0.00 END, 0.00),
            COALESCE(udpa.uber_cash_collection, CASE WHEN r.partner_rank = 1 THEN u.uber_cash_collection ELSE 0.00 END, 0.00),
            COALESCE(udpa.uber_toll, CASE WHEN r.partner_rank = 1 THEN u.uber_toll ELSE 0.00 END, 0.00),
            COALESCE(udpa.uber_driver_sub_charge, CASE WHEN r.partner_rank = 1 THEN u.uber_driver_sub_charge ELSE 0.00 END, 0.00),
            CASE WHEN r.partner_rank = 1 THEN COALESCE(u.uber_incentive, 0.00) ELSE 0.00 END,
            COALESCE(udpa.uber_week_os, CASE WHEN r.partner_rank = 1 THEN u.uber_week_os ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_trips, CASE WHEN r.partner_rank = 1 THEN o.ola_trips ELSE 0 END, 0),
            COALESCE(odpa.ola_net_revenue, CASE WHEN r.partner_rank = 1 THEN o.ola_net_revenue ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_cash_collection, CASE WHEN r.partner_rank = 1 THEN o.ola_cash_collection ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_toll, CASE WHEN r.partner_rank = 1 THEN o.ola_toll ELSE 0.00 END, 0.00),
            0.00,
            COALESCE(odpa.ola_online_payment, CASE WHEN r.partner_rank = 1 THEN o.ola_online_payment ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_incentive, CASE WHEN r.partner_rank = 1 THEN o.ola_incentive ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_week_os, CASE WHEN r.partner_rank = 1 THEN o.ola_week_os ELSE 0.00 END, 0.00),
            COALESCE(adj.net_adj_signed, CASE WHEN r.partner_rank = 1 THEN afb.net_adj_signed ELSE 0.00 END, 0.00) AS adjustment_amount,
            CASE WHEN r.partner_rank = 1 THEN COALESCE(ch.challan_amount, 0.00) ELSE 0.00 END AS challan_amount,
            COALESCE(gdpa.gps_dead_km, 0.00) AS gps_dead_km,
            COALESCE(gdpa.gps_dead_mile_penalty, eh.gps_dead_mile_penalty, 0.00) AS gps_dead_mile_penalty,
            (
                r.net_weekly_lease_rental
                - (COALESCE(udpa.uber_week_os, CASE WHEN r.partner_rank = 1 THEN u.uber_week_os ELSE 0.00 END, 0.00)
                   + COALESCE(odpa.ola_week_os, CASE WHEN r.partner_rank = 1 THEN o.ola_week_os ELSE 0.00 END, 0.00))
                + CASE WHEN r.partner_rank = 1 THEN COALESCE(ch.challan_amount, 0.00) ELSE 0.00 END
                + COALESCE(eh.accident_deduction, 0.00)
                + COALESCE(gdpa.gps_dead_mile_penalty, eh.gps_dead_mile_penalty, 0.00)
                + COALESCE(adj.net_adj_signed, CASE WHEN r.partner_rank = 1 THEN afb.net_adj_signed ELSE 0.00 END, 0.00)
            ) AS current_week_os,
            GREATEST(0.00, (
                r.net_weekly_lease_rental
                - (COALESCE(udpa.uber_week_os, CASE WHEN r.partner_rank = 1 THEN u.uber_week_os ELSE 0.00 END, 0.00)
                   + COALESCE(odpa.ola_week_os, CASE WHEN r.partner_rank = 1 THEN o.ola_week_os ELSE 0.00 END, 0.00))
                + CASE WHEN r.partner_rank = 1 THEN COALESCE(ch.challan_amount, 0.00) ELSE 0.00 END
                + COALESCE(eh.accident_deduction, 0.00)
                + COALESCE(gdpa.gps_dead_mile_penalty, eh.gps_dead_mile_penalty, 0.00)
                + COALESCE(adj.net_adj_signed, CASE WHEN r.partner_rank = 1 THEN afb.net_adj_signed ELSE 0.00 END, 0.00)
            )) AS net_to_collect_from_driver,
            GREATEST(0.00, -(
                r.net_weekly_lease_rental
                - (COALESCE(udpa.uber_week_os, CASE WHEN r.partner_rank = 1 THEN u.uber_week_os ELSE 0.00 END, 0.00)
                   + COALESCE(odpa.ola_week_os, CASE WHEN r.partner_rank = 1 THEN o.ola_week_os ELSE 0.00 END, 0.00))
                + CASE WHEN r.partner_rank = 1 THEN COALESCE(ch.challan_amount, 0.00) ELSE 0.00 END
                + COALESCE(eh.accident_deduction, 0.00)
                + COALESCE(gdpa.gps_dead_mile_penalty, eh.gps_dead_mile_penalty, 0.00)
                + COALESCE(adj.net_adj_signed, CASE WHEN r.partner_rank = 1 THEN afb.net_adj_signed ELSE 0.00 END, 0.00)
            )) AS net_payout_to_driver,
            'CALCULATED',
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
        FROM rent_ranked r
        LEFT JOIN partner_names pn ON r.partner_id = pn.partner_id
        LEFT JOIN custom_names cn ON r.partner_id = cn.partner_id
        LEFT JOIN uber_daily_partner_agg udpa ON r.vehicle_number = udpa.vehicle_number AND r.partner_id = udpa.partner_id
        LEFT JOIN ola_daily_partner_agg odpa ON r.vehicle_number = odpa.vehicle_number AND r.partner_id = odpa.partner_id
        LEFT JOIN gps_daily_partner_agg gdpa ON r.vehicle_number = gdpa.vehicle_number AND r.partner_id = gdpa.partner_id
        LEFT JOIN uber_agg u ON r.partner_rank = 1 AND UPPER(REPLACE(REPLACE(r.vehicle_number, ' ', ''), '-', '')) = u.vehicle_number
        LEFT JOIN ola_agg o ON r.partner_rank = 1 AND UPPER(REPLACE(REPLACE(r.vehicle_number, ' ', ''), '-', '')) = o.vehicle_number
        LEFT JOIN adj_agg adj ON UPPER(REPLACE(REPLACE(r.vehicle_number, ' ', ''), '-', '')) = adj.vehicle_number AND r.partner_id = adj.partner_id
        LEFT JOIN adj_veh_fallback afb ON UPPER(REPLACE(REPLACE(r.vehicle_number, ' ', ''), '-', '')) = afb.vehicle_number
        LEFT JOIN challan_daily_partner_agg ch ON UPPER(REPLACE(REPLACE(r.vehicle_number, ' ', ''), '-', '')) = ch.vehicle_number
        LEFT JOIN existing_hisaab eh ON r.vehicle_number = eh.vehicle_number AND r.partner_id = eh.partner_id
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
            adjustment_amount = EXCLUDED.adjustment_amount,
            challan_amount = EXCLUDED.challan_amount,
            gps_dead_km = EXCLUDED.gps_dead_km,
            gps_dead_mile_penalty = EXCLUDED.gps_dead_mile_penalty,
            current_week_os = EXCLUDED.current_week_os,
            net_to_collect_from_driver = EXCLUDED.net_to_collect_from_driver,
            net_payout_to_driver = EXCLUDED.net_payout_to_driver,
            settlement_status = 'CALCULATED',
            updated_at = CURRENT_TIMESTAMP;

    END LOOP;
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 2. sp_sync_hisaab_partner_weekly
-- Partner-level aggregation procedure with multi-vehicle rollup and dead mile penalty
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_partner_weekly(
    IN p_week_id character varying, 
    IN p_partner character varying DEFAULT NULL::character varying
)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year INT;
    v_week_num INT;
    v_week_start DATE;
    v_week_end DATE;
    v_prev_week_id VARCHAR(20);
    v_enable_roll_forward BOOLEAN := FALSE;
BEGIN
    SELECT settlement_year, settlement_week, week_start, week_end 
    INTO v_year, v_week_num, v_week_start, v_week_end
    FROM public.hisaab_settlement_weeks 
    WHERE week_id = p_week_id;

    IF v_week_num > 1 THEN
        v_prev_week_id := 'CY' || TO_CHAR(v_year, 'YY') || 'WK' || LPAD((v_week_num - 1)::TEXT, 2, '0');
    ELSE
        v_prev_week_id := 'CY' || TO_CHAR(v_year - 1, 'YY') || 'WK52';
    END IF;

    SELECT COALESCE(config_value = 'true', FALSE) INTO v_enable_roll_forward
    FROM public.hisaab_system_config
    WHERE config_key = 'ENABLE_AUTO_ROLL_FORWARD';

    WITH veh_summary AS (
        SELECT 
            v.partner_id,
            (ARRAY_AGG(v.partner_name ORDER BY v.onroad_days DESC, v.net_weekly_lease_rental DESC))[1] AS partner_name,
            (ARRAY_AGG(v.city ORDER BY v.onroad_days DESC, v.net_weekly_lease_rental DESC))[1] AS city,
            CASE WHEN v.partner_id ILIKE '%IP%' OR v.partner_id ILIKE '%OP%' THEN 'Operator' ELSE 'Individual' END AS partner_type,
            COUNT(DISTINCT v.vehicle_number) AS allotted_cars_count,
            SUM(v.onroad_days) AS total_onroad_days,
            SUM(v.uber_trips + v.ola_trips) AS total_trips,
            SUM(v.net_weekly_lease_rental) AS total_net_rent_billed,
            SUM(COALESCE(v.uber_total_earnings, 0.00) + COALESCE(v.ola_net_revenue, 0.00)) AS total_platform_earnings,
            SUM(COALESCE(v.uber_cash_collection, 0.00) + COALESCE(v.ola_cash_collection, 0.00)) AS total_cash_collected,
            SUM(COALESCE(v.uber_incentive, 0.00) + COALESCE(v.ola_incentive, 0.00)) AS total_platform_incentives,
            SUM(COALESCE(v.adjustment_amount, 0.00)) AS total_adjustments,
            SUM(COALESCE(v.challan_amount, 0.00)) AS total_challans,
            SUM(COALESCE(v.accident_deduction, 0.00)) AS total_accidents,
            SUM(COALESCE(v.tds_amount, 0.00)) AS total_tds,
            SUM(COALESCE(v.gps_dead_mile_penalty, 0.00)) AS total_dead_mile_penalty,
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
        total_dead_mile_penalty,
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
        COALESCE(v.total_dead_mile_penalty, 0.00) AS total_dead_mile_penalty,
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
        total_dead_mile_penalty = EXCLUDED.total_dead_mile_penalty,
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
    WHERE public.hisaab_partner_weekly.settlement_status IN ('DRAFT', 'OPEN') OR public.hisaab_partner_weekly.settlement_status IS NULL;
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 3. sp_sync_rent_to_hisaab
-- Nightly sync procedure updating hisaab_daily_ledger with daily rent, daily GPS & dead penalty
-- ----------------------------------------------------------------------------
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

    -- Update hisaab_daily_ledger in set-based batch including daily GPS & dead mile calculations
    WITH daily_gps AS (
        SELECT 
            g.record_date,
            UPPER(REPLACE(REPLACE(public.fn_clean_gps_vehicle_number(g.vehicle_number), ' ', ''), '-', '')) AS clean_veh,
            SUM(COALESCE(g.distance_km, 0.00)) AS gps_dist
        FROM public.core_gps g
        WHERE (v_week_start IS NULL OR g.record_date BETWEEN v_week_start AND v_week_end)
        GROUP BY g.record_date, UPPER(REPLACE(REPLACE(public.fn_clean_gps_vehicle_number(g.vehicle_number), ' ', ''), '-', ''))
    ),
    daily_uber AS (
        SELECT 
            u.operational_date,
            UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', '')) AS clean_veh,
            SUM(COALESCE(u.total_trip_distance_km, 0.00)) AS uber_dist,
            SUM(COALESCE(u.completed_trips, 0)) AS uber_trips
        FROM public.core_uber_daily u
        WHERE (v_week_start IS NULL OR u.operational_date BETWEEN v_week_start AND v_week_end)
        GROUP BY u.operational_date, UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', ''))
    ),
    daily_ola AS (
        SELECT 
            o.service_date,
            UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', '')) AS clean_veh,
            SUM(COALESCE(o.total_kms, 0.00)) AS ola_dist,
            SUM(COALESCE(o.completed_trips, 0)) AS ola_trips
        FROM public.core_ola_daily o
        WHERE (v_week_start IS NULL OR o.service_date BETWEEN v_week_start AND v_week_end)
        GROUP BY o.service_date, UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', ''))
    )
    UPDATE public.hisaab_daily_ledger h
    SET 
        daily_rent_applied = d.applied_daily_rent,
        daily_indemnity_fee = d.applied_daily_indemnity,
        net_daily_rent = d.net_daily_rent,
        attendance_status = d.attendance_status,
        is_billable_day = d.is_billable_day,
        daily_gps_distance_km = COALESCE(g.gps_dist, 0.00),
        daily_trip_distance_km = COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00),
        daily_dead_km = GREATEST(0.00, COALESCE(g.gps_dist, 0.00) - (
            (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
            + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
            + (CASE WHEN d.is_billable_day THEN 25.00 ELSE 0.00 END)
        )),
        daily_dead_mile_penalty = CASE 
            WHEN (COALESCE(h.partner_type, 'Individual') = 'Individual') 
                 AND (COALESCE(g.gps_dist, 0.00) - (
                     (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                     + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                     + (CASE WHEN d.is_billable_day THEN 25.00 ELSE 0.00 END)
                 )) > 0
            THEN ROUND((COALESCE(g.gps_dist, 0.00) - (
                     (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                     + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                     + (CASE WHEN d.is_billable_day THEN 25.00 ELSE 0.00 END)
                 )) * 3.00, 2)
            ELSE 0.00
        END,
        daily_net_balance = (
            COALESCE(d.net_daily_rent, 0.00)
            + (ABS(COALESCE(h.uber_cash_collected, 0.00)) + ABS(COALESCE(h.ola_cash_collected, 0.00)) + ABS(COALESCE(h.rapido_cash_collected, 0.00)))
            - (COALESCE(h.uber_fare_earnings, 0.00) + COALESCE(h.ola_net_revenue, 0.00) + COALESCE(h.rapido_net_revenue, 0.00))
            - COALESCE(h.ola_online_payment, 0.00)
            + COALESCE(h.daily_challans, 0.00)
            + COALESCE(h.daily_accident_recovery, 0.00)
            + CASE 
                WHEN (COALESCE(h.partner_type, 'Individual') = 'Individual') 
                     AND (COALESCE(g.gps_dist, 0.00) - (
                         (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                         + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                         + (CASE WHEN d.is_billable_day THEN 25.00 ELSE 0.00 END)
                     )) > 0
                THEN ROUND((COALESCE(g.gps_dist, 0.00) - (
                         (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                         + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                         + (CASE WHEN d.is_billable_day THEN 25.00 ELSE 0.00 END)
                     )) * 3.00, 2)
                ELSE 0.00
              END
            - COALESCE(h.daily_adjustments, 0.00)
            - COALESCE(h.weekly_incentive_credit, 0.00)
        ),
        updated_at = CURRENT_TIMESTAMP
    FROM public.daily_rent_log d
    LEFT JOIN daily_gps g ON g.record_date = d.log_date AND g.clean_veh = d.vehicle_number
    LEFT JOIN daily_uber u ON u.operational_date = d.log_date AND u.clean_veh = d.vehicle_number
    LEFT JOIN daily_ola o ON o.service_date = d.log_date AND o.clean_veh = d.vehicle_number
    WHERE h.log_date = d.log_date
      AND h.vehicle_number = d.vehicle_number
      AND h.partner_id = d.partner_id
      AND (h.week_id = v_week_id OR (v_week_start IS NOT NULL AND h.log_date BETWEEN v_week_start AND v_week_end));

    -- Bulk aggregate weekly vehicle ledger
    CALL public.sp_sync_hisaab_vehicle_weekly(v_week_id);

    -- Bulk aggregate weekly partner ledger
    CALL public.sp_sync_hisaab_partner_weekly(v_week_id, NULL);

    RAISE NOTICE 'Successfully synced rent and daily GPS telematics to hisaab for week %', v_week_id;
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 4. Canonical View: v_hisaab_partner_settlement_statement
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_hisaab_partner_settlement_statement;
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
    h.gps_dead_km,
    h.gps_dead_mile_penalty,
    (h.uber_week_os + h.ola_week_os) AS total_net_platform_earnings,
    h.net_weekly_lease_rental AS total_company_lease_dues,
    (h.net_weekly_lease_rental - (h.uber_week_os + h.ola_week_os) + h.gps_dead_mile_penalty) AS net_driver_balance_due,
    ((h.uber_week_os + h.ola_week_os) - h.net_weekly_lease_rental - h.gps_dead_mile_penalty) AS net_payout_to_driver
FROM public.hisaab_vehicle_weekly h;

-- ----------------------------------------------------------------------------
-- 5. sp_sync_hisaab_vehicle_payout_weekly
-- Operational Payout Settlement Procedure with strict Monday 11:00 AM IST cutoff freeze
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_vehicle_payout_weekly(IN p_week_id character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week RECORD;
    v_prev_cutoff TIMESTAMPTZ;
    v_curr_cutoff TIMESTAMPTZ;
    v_uber_count INT;
    v_ola_count INT;
BEGIN
    FOR v_week IN (
        SELECT week_id, week_start, week_end, lock_cutoff_at, is_locked
        FROM public.hisaab_settlement_weeks
        WHERE (p_week_id IS NOT NULL AND week_id = p_week_id)
           OR (p_week_id IS NULL AND week_start <= CURRENT_DATE)
        ORDER BY week_start
    ) LOOP
        
        v_curr_cutoff := COALESCE(v_week.lock_cutoff_at, (v_week.week_end + INTERVAL '1 day 5 hours 30 minutes'));
        v_prev_cutoff := (v_week.week_start - INTERVAL '6 days 18 hours 30 minutes');

        RAISE NOTICE 'Processing Payout Hisaab with GPS telematics for week: % (Cutoff: %)', v_week.week_id, v_curr_cutoff;

        SELECT COUNT(*) INTO v_uber_count FROM public.core_uber_weekly WHERE week_id = v_week.week_id;
        SELECT COUNT(*) INTO v_ola_count FROM public.core_ola_weekly WHERE week_id = v_week.week_id;

        -- Clean up orphaned / stale rows in hisaab_vehicle_payout_weekly
        DELETE FROM public.hisaab_vehicle_payout_weekly h
        WHERE h.week_id = v_week.week_id
          AND h.settlement_status <> 'FROZEN'
          AND (
              NOT EXISTS (
                  SELECT 1 FROM public.daily_rent_log d
                  WHERE d.log_date BETWEEN v_week.week_start AND v_week.week_end
                    AND UPPER(REPLACE(REPLACE(d.vehicle_number, ' ', ''), '-', '')) = UPPER(REPLACE(REPLACE(h.vehicle_number, ' ', ''), '-', ''))
                    AND COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') = h.partner_id
              )
              OR
              (
                  h.partner_id = 'SYSTEM_ONBOARDED'
                  AND EXISTS (
                      SELECT 1 FROM public.daily_rent_log d
                      WHERE d.log_date BETWEEN v_week.week_start AND v_week.week_end
                        AND UPPER(REPLACE(REPLACE(d.vehicle_number, ' ', ''), '-', '')) = UPPER(REPLACE(REPLACE(h.vehicle_number, ' ', ''), '-', ''))
                        AND COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') <> 'SYSTEM_ONBOARDED'
                  )
              )
          );

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
        all_daily_custody AS (
            SELECT 
                d.log_date,
                d.vehicle_number,
                d.partner_id,
                d.is_billable_day,
                ROW_NUMBER() OVER (
                    PARTITION BY d.log_date, d.vehicle_number
                    ORDER BY 
                        CASE WHEN COALESCE(NULLIF(TRIM(d.partner_id), ''), 'SYSTEM_ONBOARDED') <> 'SYSTEM_ONBOARDED' THEN 0 ELSE 1 END,
                        d.net_daily_rent DESC,
                        d.id DESC
                ) AS custody_rank
            FROM public.daily_rent_log d
            WHERE d.log_date BETWEEN v_week.week_start AND v_week.week_end
        ),
        daily_gps AS (
            SELECT 
                g.record_date,
                UPPER(REPLACE(REPLACE(public.fn_clean_gps_vehicle_number(g.vehicle_number), ' ', ''), '-', '')) AS clean_veh,
                SUM(COALESCE(g.distance_km, 0.00)) AS gps_dist
            FROM public.core_gps g
            WHERE g.record_date BETWEEN v_week.week_start AND v_week.week_end
            GROUP BY g.record_date, UPPER(REPLACE(REPLACE(public.fn_clean_gps_vehicle_number(g.vehicle_number), ' ', ''), '-', ''))
        ),
        daily_uber AS (
            SELECT 
                u.operational_date,
                UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', '')) AS clean_veh,
                SUM(COALESCE(u.total_trip_distance_km, 0.00)) AS uber_dist,
                SUM(COALESCE(u.completed_trips, 0)) AS uber_trips,
                SUM(ABS(u.net_fare_earnings)) AS uber_earnings,
                SUM(ABS(u.cash_collected)) AS uber_cash,
                SUM(ABS(u.tolls_refunded)) AS uber_toll,
                SUM(ABS(u.driver_subscription_charge)) AS uber_sub
            FROM public.core_uber_daily u
            WHERE u.operational_date BETWEEN v_week.week_start AND v_week.week_end
            GROUP BY u.operational_date, UPPER(REPLACE(REPLACE(u.vehicle_number, ' ', ''), '-', ''))
        ),
        daily_ola AS (
            SELECT 
                o.service_date,
                UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', '')) AS clean_veh,
                SUM(COALESCE(o.total_kms, 0.00)) AS ola_dist,
                SUM(COALESCE(o.completed_trips, 0)) AS ola_trips,
                SUM(ABS(o.operator_bill)) AS ola_revenue,
                SUM(ABS(o.cash_collected)) AS ola_cash,
                SUM(ABS(o.toll_and_parking)) AS ola_toll,
                SUM(ABS(o.online_payouts)) AS ola_payout,
                SUM(ABS(o.portal_incentive)) AS ola_inc
            FROM public.core_ola_daily o
            WHERE o.service_date BETWEEN v_week.week_start AND v_week.week_end
            GROUP BY o.service_date, UPPER(REPLACE(REPLACE(o.vehicle_number, ' ', ''), '-', ''))
        ),
        uber_daily_partner_agg AS (
            SELECT 
                dc.vehicle_number,
                dc.partner_id,
                COALESCE(SUM(u.uber_trips), 0) AS uber_trips,
                COALESCE(SUM(u.uber_earnings), 0.00) AS uber_total_earnings,
                COALESCE(SUM(u.uber_cash), 0.00) AS uber_cash_collection,
                COALESCE(SUM(u.uber_toll), 0.00) AS uber_toll,
                COALESCE(SUM(u.uber_sub), 0.00) AS uber_driver_sub_charge,
                COALESCE(SUM(u.uber_earnings + u.uber_toll - u.uber_cash - u.uber_sub), 0.00) AS uber_week_os
            FROM all_daily_custody dc
            JOIN daily_uber u ON u.operational_date = dc.log_date AND u.clean_veh = dc.vehicle_number
            WHERE dc.custody_rank = 1
            GROUP BY dc.vehicle_number, dc.partner_id
        ),
        ola_daily_partner_agg AS (
            SELECT 
                dc.vehicle_number,
                dc.partner_id,
                COALESCE(SUM(o.ola_trips), 0) AS ola_trips,
                COALESCE(SUM(o.ola_revenue), 0.00) AS ola_net_revenue,
                COALESCE(SUM(o.ola_cash), 0.00) AS ola_cash_collection,
                COALESCE(SUM(o.ola_toll), 0.00) AS ola_toll,
                0.00 AS ola_gst,
                COALESCE(SUM(o.ola_payout), 0.00) AS ola_online_payment,
                COALESCE(SUM(o.ola_inc), 0.00) AS ola_incentive,
                COALESCE(SUM(o.ola_revenue + o.ola_inc + o.ola_toll - o.ola_cash), 0.00) AS ola_week_os
            FROM all_daily_custody dc
            JOIN daily_ola o ON o.service_date = dc.log_date AND o.clean_veh = dc.vehicle_number
            WHERE dc.custody_rank = 1
            GROUP BY dc.vehicle_number, dc.partner_id
        ),
        gps_daily_partner_agg AS (
            SELECT 
                dc.vehicle_number,
                dc.partner_id,
                COALESCE(SUM(g.gps_dist), 0.00) AS total_gps_km,
                COALESCE(SUM(COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00)), 0.00) AS total_trip_km,
                COALESCE(SUM(
                    GREATEST(0.00, COALESCE(g.gps_dist, 0.00) - (
                        (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                        + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                        + (CASE WHEN dc.is_billable_day THEN 25.00 ELSE 0.00 END)
                    ))
                ), 0.00) AS gps_dead_km,
                COALESCE(SUM(
                    CASE 
                        WHEN (COALESCE(po.onboarding_type, 'Individual') = 'Individual' OR po.driver_plan ILIKE '%D2R%')
                             AND (COALESCE(g.gps_dist, 0.00) - (
                                 (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                                 + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                                 + (CASE WHEN dc.is_billable_day THEN 25.00 ELSE 0.00 END)
                             )) > 0
                        THEN ROUND((COALESCE(g.gps_dist, 0.00) - (
                                 (COALESCE(u.uber_dist, 0.00) + COALESCE(o.ola_dist, 0.00))
                                 + ((COALESCE(u.uber_trips, 0) + COALESCE(o.ola_trips, 0)) * 3.00)
                                 + (CASE WHEN dc.is_billable_day THEN 25.00 ELSE 0.00 END)
                             )) * 3.00, 2)
                        ELSE 0.00
                    END
                ), 0.00) AS gps_dead_mile_penalty
            FROM all_daily_custody dc
            LEFT JOIN daily_gps g ON g.record_date = dc.log_date AND g.clean_veh = dc.vehicle_number
            LEFT JOIN daily_uber u ON u.operational_date = dc.log_date AND u.clean_veh = dc.vehicle_number
            LEFT JOIN daily_ola o ON o.service_date = dc.log_date AND o.clean_veh = dc.vehicle_number
            LEFT JOIN public.core_partner_onboarding po ON po.partner_id = dc.partner_id
            WHERE dc.custody_rank = 1
            GROUP BY dc.vehicle_number, dc.partner_id
        ),
        uber_vehicles_with_daily AS (
            SELECT DISTINCT vehicle_number FROM uber_daily_partner_agg
        ),
        ola_vehicles_with_daily AS (
            SELECT DISTINCT vehicle_number FROM ola_daily_partner_agg
        ),
        -- 1. On-Time In-Week Challans (Violation in week AND created <= Monday 11:00 AM)
        challan_ontime_agg AS (
            SELECT 
                c.vehicle_number,
                COALESCE(NULLIF(TRIM(c.partner_id), ''), 'SYSTEM_ONBOARDED') AS partner_id,
                COALESCE(SUM(c.challan_amount), 0.00) AS challan_amount
            FROM (
                SELECT 
                    UPPER(REPLACE(REPLACE(c.vehicle_reg_no, ' ', ''), '-', '')) AS vehicle_number,
                    c.violation_date,
                    COALESCE(NULLIF(c.net_pending_amount, 0.00), c.total_fine_amount) AS challan_amount,
                    dc.partner_id
                FROM public.core_challans c
                LEFT JOIN all_daily_custody dc
                  ON c.violation_date = dc.log_date
                 AND UPPER(REPLACE(REPLACE(c.vehicle_reg_no, ' ', ''), '-', '')) = dc.vehicle_number
                 AND dc.custody_rank = 1
                WHERE c.violation_date BETWEEN v_week.week_start AND v_week.week_end
                  AND (c.created_at <= v_curr_cutoff OR v_week.week_start < '2026-09-21')
                  AND c.is_deleted = FALSE
                  AND c.payment_status IN ('UNPAID', 'PARTIALLY_PAID')
                  AND c.liability_type IN ('TRAFFIC_FINE', 'STICKER_FINE')
            ) c
            GROUP BY c.vehicle_number, COALESCE(NULLIF(TRIM(c.partner_id), ''), 'SYSTEM_ONBOARDED')
        ),
        -- 2. Late Past Challans (Violation < week_start AND created after prev_cutoff AND <= curr_cutoff)
        challan_late_agg AS (
            SELECT 
                c.vehicle_number,
                COALESCE(NULLIF(TRIM(c.partner_id), ''), 'SYSTEM_ONBOARDED') AS partner_id,
                COALESCE(SUM(c.challan_amount), 0.00) AS challan_adjustment_amount
            FROM (
                SELECT 
                    UPPER(REPLACE(REPLACE(c.vehicle_reg_no, ' ', ''), '-', '')) AS vehicle_number,
                    c.violation_date,
                    COALESCE(NULLIF(c.net_pending_amount, 0.00), c.total_fine_amount) AS challan_amount,
                    dc.partner_id
                FROM public.core_challans c
                LEFT JOIN all_daily_custody dc
                  ON c.violation_date = dc.log_date
                 AND UPPER(REPLACE(REPLACE(c.vehicle_reg_no, ' ', ''), '-', '')) = dc.vehicle_number
                 AND dc.custody_rank = 1
                WHERE c.violation_date < v_week.week_start
                  AND c.created_at > v_prev_cutoff
                  AND c.created_at <= v_curr_cutoff
                  AND v_week.week_start >= '2026-09-28'
                  AND c.is_deleted = FALSE
                  AND c.payment_status IN ('UNPAID', 'PARTIALLY_PAID')
                  AND c.liability_type IN ('TRAFFIC_FINE', 'STICKER_FINE')
            ) c
            GROUP BY c.vehicle_number, COALESCE(NULLIF(TRIM(c.partner_id), ''), 'SYSTEM_ONBOARDED')
        ),
        -- 3. On-Time In-Week Adjustments
        adj_ontime_agg AS (
            SELECT 
                UPPER(REPLACE(REPLACE(c.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                c.partner_id,
                COALESCE(SUM(CASE WHEN c.financial_direction = 'CREDIT' THEN -c.amount ELSE c.amount END), 0.00) AS net_adj_signed
            FROM public.core_adjustments c
            WHERE c.is_deleted = FALSE 
              AND c.approval_status = 'Approved'
              AND c.adjustment_date BETWEEN v_week.week_start AND v_week.week_end
              AND (COALESCE(c.updated_at, c.created_at) <= v_curr_cutoff OR v_week.week_start < '2026-09-21')
              AND c.vehicle_number IS NOT NULL AND TRIM(c.vehicle_number) <> ''
            GROUP BY UPPER(REPLACE(REPLACE(c.vehicle_number, ' ', ''), '-', '')), c.partner_id
        ),
        -- 4. Late Past Adjustments
        adj_late_agg AS (
            SELECT 
                UPPER(REPLACE(REPLACE(c.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                c.partner_id,
                COALESCE(SUM(CASE WHEN c.financial_direction = 'CREDIT' THEN -c.amount ELSE c.amount END), 0.00) AS net_late_adj_signed
            FROM public.core_adjustments c
            WHERE c.is_deleted = FALSE 
              AND c.approval_status = 'Approved'
              AND c.adjustment_date < v_week.week_start
              AND COALESCE(c.updated_at, c.created_at) > v_prev_cutoff
              AND COALESCE(c.updated_at, c.created_at) <= v_curr_cutoff
              AND v_week.week_start >= '2026-09-28'
              AND c.vehicle_number IS NOT NULL AND TRIM(c.vehicle_number) <> ''
            GROUP BY UPPER(REPLACE(REPLACE(c.vehicle_number, ' ', ''), '-', '')), c.partner_id
        ),
        target_keys AS (
            SELECT vehicle_number, partner_id FROM rent_ranked
            UNION
            SELECT vehicle_number, partner_id FROM challan_late_agg WHERE partner_id <> 'SYSTEM_ONBOARDED'
            UNION
            SELECT vehicle_number, partner_id FROM adj_late_agg WHERE partner_id <> 'SYSTEM_ONBOARDED'
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
        INSERT INTO public.hisaab_vehicle_payout_weekly (
            week_id, week_start, week_end, lock_cutoff_at, vehicle_number, partner_id, partner_name,
            city, vehicle_model, rental_plan, allotted_days, onroad_days,
            daily_rent_applied, weekly_lease_rental, weekly_indemnity_fees, net_weekly_lease_rental,
            uber_trips, uber_total_earnings, uber_cash_collection, uber_toll, uber_driver_sub_charge, uber_incentive, uber_week_os,
            ola_trips, ola_net_revenue, ola_cash_collection, ola_toll, ola_gst, ola_online_payment, ola_incentive, ola_week_os,
            adjustment_amount, prior_period_adjustment_amount, challan_amount, challan_adjustment_amount,
            accident_deduction, tds_amount, gps_dead_km, gps_dead_mile_penalty,
            current_week_os, net_to_collect_from_driver, net_payout_to_driver,
            settlement_status, created_at, updated_at
        )
        SELECT 
            v_week.week_id,
            v_week.week_start,
            v_week.week_end,
            v_curr_cutoff,
            tk.vehicle_number,
            tk.partner_id,
            COALESCE(pn.driver_name, cn.partner_name, tk.partner_id) AS partner_name,
            COALESCE(r.city, 'HYD') AS city,
            COALESCE(r.vehicle_model, 'Fleet Vehicle') AS vehicle_model,
            r.rental_plan,
            COALESCE(r.allotted_days, 0.0) AS allotted_days,
            COALESCE(r.onroad_days, 0.0) AS onroad_days,
            COALESCE(r.daily_rent_applied, 0.00) AS daily_rent_applied,
            COALESCE(r.weekly_lease_rental, 0.00) AS weekly_lease_rental,
            COALESCE(r.weekly_indemnity_fees, 0.00) AS weekly_indemnity_fees,
            COALESCE(r.net_weekly_lease_rental, 0.00) AS net_weekly_lease_rental,
            COALESCE(udpa.uber_trips, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_trips ELSE 0 END, 0),
            COALESCE(udpa.uber_total_earnings, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_total_earnings ELSE 0.00 END, 0.00),
            COALESCE(udpa.uber_cash_collection, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_cash_collection ELSE 0.00 END, 0.00),
            COALESCE(udpa.uber_toll, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_toll ELSE 0.00 END, 0.00),
            COALESCE(udpa.uber_driver_sub_charge, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_driver_sub_charge ELSE 0.00 END, 0.00),
            CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN COALESCE(u.uber_incentive, 0.00) ELSE 0.00 END,
            COALESCE(udpa.uber_week_os, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_week_os ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_trips, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_trips ELSE 0 END, 0),
            COALESCE(odpa.ola_net_revenue, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_net_revenue ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_cash_collection, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_cash_collection ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_toll, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_toll ELSE 0.00 END, 0.00),
            0.00,
            COALESCE(odpa.ola_online_payment, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_online_payment ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_incentive, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_incentive ELSE 0.00 END, 0.00),
            COALESCE(odpa.ola_week_os, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_week_os ELSE 0.00 END, 0.00),
            -- On-time adjustments
            COALESCE(adj_on.net_adj_signed, 0.00) AS adjustment_amount,
            -- Late past adjustments routed to this week
            COALESCE(adj_lt.net_late_adj_signed, 0.00) AS prior_period_adjustment_amount,
            -- On-time in-week challans
            COALESCE(ch_on.challan_amount, 0.00) AS challan_amount,
            -- Late past challans routed to this week as adjustment
            COALESCE(ch_lt.challan_adjustment_amount, 0.00) AS challan_adjustment_amount,
            0.00 AS accident_deduction,
            0.00 AS tds_amount,
            COALESCE(gdpa.gps_dead_km, 0.00) AS gps_dead_km,
            COALESCE(gdpa.gps_dead_mile_penalty, 0.00) AS gps_dead_mile_penalty,
            -- Current Week O/S Formula
            (
                COALESCE(r.net_weekly_lease_rental, 0.00)
                - (COALESCE(udpa.uber_week_os, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_week_os ELSE 0.00 END, 0.00)
                   + COALESCE(odpa.ola_week_os, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_week_os ELSE 0.00 END, 0.00))
                + COALESCE(ch_on.challan_amount, 0.00)
                + COALESCE(ch_lt.challan_adjustment_amount, 0.00)
                + COALESCE(adj_on.net_adj_signed, 0.00)
                + COALESCE(adj_lt.net_late_adj_signed, 0.00)
                + COALESCE(gdpa.gps_dead_mile_penalty, 0.00)
            ) AS current_week_os,
            GREATEST(0.00, (
                COALESCE(r.net_weekly_lease_rental, 0.00)
                - (COALESCE(udpa.uber_week_os, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_week_os ELSE 0.00 END, 0.00)
                   + COALESCE(odpa.ola_week_os, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_week_os ELSE 0.00 END, 0.00))
                + COALESCE(ch_on.challan_amount, 0.00)
                + COALESCE(ch_lt.challan_adjustment_amount, 0.00)
                + COALESCE(adj_on.net_adj_signed, 0.00)
                + COALESCE(adj_lt.net_late_adj_signed, 0.00)
                + COALESCE(gdpa.gps_dead_mile_penalty, 0.00)
            )) AS net_to_collect_from_driver,
            GREATEST(0.00, -(
                COALESCE(r.net_weekly_lease_rental, 0.00)
                - (COALESCE(udpa.uber_week_os, CASE WHEN r.partner_rank = 1 AND uvwd.vehicle_number IS NULL THEN u.uber_week_os ELSE 0.00 END, 0.00)
                   + COALESCE(odpa.ola_week_os, CASE WHEN r.partner_rank = 1 AND ovwd.vehicle_number IS NULL THEN o.ola_week_os ELSE 0.00 END, 0.00))
                + COALESCE(ch_on.challan_amount, 0.00)
                + COALESCE(ch_lt.challan_adjustment_amount, 0.00)
                + COALESCE(adj_on.net_adj_signed, 0.00)
                + COALESCE(adj_lt.net_late_adj_signed, 0.00)
                + COALESCE(gdpa.gps_dead_mile_penalty, 0.00)
            )) AS net_payout_to_driver,
            CASE WHEN CURRENT_TIMESTAMP >= v_curr_cutoff THEN 'FROZEN' ELSE 'CALCULATED' END AS settlement_status,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
        FROM target_keys tk
        LEFT JOIN rent_ranked r ON tk.vehicle_number = r.vehicle_number AND tk.partner_id = r.partner_id
        LEFT JOIN partner_names pn ON tk.partner_id = pn.partner_id
        LEFT JOIN custom_names cn ON tk.partner_id = cn.partner_id
        LEFT JOIN uber_daily_partner_agg udpa ON tk.vehicle_number = udpa.vehicle_number AND tk.partner_id = udpa.partner_id
        LEFT JOIN ola_daily_partner_agg odpa ON tk.vehicle_number = odpa.vehicle_number AND tk.partner_id = odpa.partner_id
        LEFT JOIN gps_daily_partner_agg gdpa ON tk.vehicle_number = gdpa.vehicle_number AND tk.partner_id = gdpa.partner_id
        LEFT JOIN uber_vehicles_with_daily uvwd ON tk.vehicle_number = uvwd.vehicle_number
        LEFT JOIN ola_vehicles_with_daily ovwd ON tk.vehicle_number = ovwd.vehicle_number
        LEFT JOIN uber_agg u ON r.partner_rank = 1 AND UPPER(REPLACE(REPLACE(tk.vehicle_number, ' ', ''), '-', '')) = u.vehicle_number
        LEFT JOIN ola_agg o ON r.partner_rank = 1 AND UPPER(REPLACE(REPLACE(tk.vehicle_number, ' ', ''), '-', '')) = o.vehicle_number
        LEFT JOIN challan_ontime_agg ch_on ON UPPER(REPLACE(REPLACE(tk.vehicle_number, ' ', ''), '-', '')) = ch_on.vehicle_number AND tk.partner_id = ch_on.partner_id
        LEFT JOIN challan_late_agg ch_lt ON UPPER(REPLACE(REPLACE(tk.vehicle_number, ' ', ''), '-', '')) = ch_lt.vehicle_number AND tk.partner_id = ch_lt.partner_id
        LEFT JOIN adj_ontime_agg adj_on ON UPPER(REPLACE(REPLACE(tk.vehicle_number, ' ', ''), '-', '')) = adj_on.vehicle_number AND tk.partner_id = adj_on.partner_id
        LEFT JOIN adj_late_agg adj_lt ON UPPER(REPLACE(REPLACE(tk.vehicle_number, ' ', ''), '-', '')) = adj_lt.vehicle_number AND tk.partner_id = adj_lt.partner_id
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
            adjustment_amount = EXCLUDED.adjustment_amount,
            prior_period_adjustment_amount = EXCLUDED.prior_period_adjustment_amount,
            challan_amount = EXCLUDED.challan_amount,
            challan_adjustment_amount = EXCLUDED.challan_adjustment_amount,
            gps_dead_km = EXCLUDED.gps_dead_km,
            gps_dead_mile_penalty = EXCLUDED.gps_dead_mile_penalty,
            current_week_os = EXCLUDED.current_week_os,
            net_to_collect_from_driver = EXCLUDED.net_to_collect_from_driver,
            net_payout_to_driver = EXCLUDED.net_payout_to_driver,
            settlement_status = EXCLUDED.settlement_status,
            updated_at = CURRENT_TIMESTAMP
        WHERE hisaab_vehicle_payout_weekly.settlement_status <> 'FROZEN';

        RAISE NOTICE 'Completed payout sync for week %', v_week.week_id;
    END LOOP;
END;
$procedure$;
