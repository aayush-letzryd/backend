CREATE OR REPLACE PROCEDURE public.sp_calculate_daily_rent(
    p_start_date DATE DEFAULT NULL::date,
    p_end_date DATE DEFAULT NULL::date
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_date DATE;
    v_calc_start DATE;
    v_calc_end DATE;
    v_rows_processed INT := 0;
    v_billable_days INT := 0;
    v_zero_rent_days INT := 0;
BEGIN
    v_calc_start := COALESCE(p_start_date, CURRENT_DATE - 1);
    v_calc_end   := COALESCE(p_end_date, v_calc_start);

    RAISE NOTICE 'Starting Daily Rent Calculation from % to %', v_calc_start, v_calc_end;

    v_curr_date := v_calc_start;
    WHILE v_curr_date <= v_calc_end LOOP
        
        WITH raw_status AS (
            SELECT 
                s.status_date AS log_date,
                UPPER(REPLACE(REPLACE(s.vehicle_number, ' ', ''), '-', '')) AS vehicle_number,
                COALESCE(NULLIF(TRIM(s.partner_id), ''), 'SYSTEM_ONBOARDED') AS partner_id,
                CASE 
                    WHEN s.city ILIKE 'blr%' OR s.city ILIKE 'bengalur%' THEN 'Bangalore'
                    WHEN s.city ILIKE 'hyd%' THEN 'Hyderabad'
                    WHEN s.city ILIKE 'mum%' OR s.city ILIKE 'bombay%' THEN 'Mumbai'
                    ELSE COALESCE(s.city, 'Hyderabad')
                END AS city,
                COALESCE(s.car_model, 'Unknown') AS vehicle_model,
                COALESCE(s.final_status, 'Active') AS attendance_status,
                s.billable_rent_day,
                s.allocation_id,
                s.allocation_date,
                s.dropoff_date,
                COALESCE(
                    hw.week_id,
                    'CY' || TO_CHAR(s.status_date, 'YY') || 'WK' || LPAD(TO_CHAR(s.status_date, 'IW'), 2, '0')
                ) AS week_id,
                COALESCE(hw.week_start, s.status_date - (EXTRACT(ISODOW FROM s.status_date)::INT - 1)) AS week_start,
                COALESCE(hw.week_end, s.status_date + (7 - EXTRACT(ISODOW FROM s.status_date)::INT)) AS week_end,
                -- Explicit partner classification (Read-only, never mutate core tables)
                COALESCE(po.onboarding_type, 
                    CASE WHEN s.partner_id ILIKE '%OP%' OR s.partner_id ILIKE '%FLEET%' OR s.partner_id ILIKE '%IP%' THEN 'Operator' ELSE 'Individual' END
                ) AS customer_type,
                -- Dynamic Plan Code Resolution inside SQL (Zero writes to core_partner_onboarding)
                COALESCE(cp_plan.plan_id, p_enrolled.plan_id) AS enrolled_plan_id
            FROM public.core_daily_vehicle_status s
            LEFT JOIN public.hisaab_settlement_weeks hw 
                ON s.status_date BETWEEN hw.week_start AND hw.week_end
            LEFT JOIN public.core_partner_onboarding po
                ON po.partner_id = s.partner_id
            LEFT JOIN LATERAL (
                SELECT plan_id FROM public.rental_custom_partner_plans
                WHERE partner_id = s.partner_id AND plan_id IS NOT NULL AND is_active = TRUE
                ORDER BY custom_plan_id DESC LIMIT 1
            ) cp_plan ON TRUE
            LEFT JOIN public.core_rental_plans p_enrolled
                ON p_enrolled.plan_code = CASE 
                    -- Dynamic mapping from raw operational onboarding strings to canonical rental plan codes
                    WHEN po.driver_plan ILIKE '%Uber Reducing%' AND (s.city ILIKE 'blr%' OR s.city ILIKE 'bengalur%') THEN 'BLR_UBER_TBS'
                    WHEN po.driver_plan IN ('D2R', 'Drive to Rent') AND (s.city ILIKE 'blr%' OR s.city ILIKE 'bengalur%') THEN 'BLR_MASTER_IND'
                    WHEN po.driver_plan ILIKE 'Rapido%' AND (s.city ILIKE 'blr%' OR s.city ILIKE 'bengalur%') THEN 'BLR_ALL_PLATFORM'
                    WHEN (po.driver_plan ILIKE '%EBS%' OR po.driver_plan = 'LIP') AND (s.city ILIKE 'hyd%') THEN 'HYD_UBER_EBS'
                    -- Contracted operator specific agreements
                    WHEN s.partner_id = 'LETZBLRIP7034607989' THEN 'BLR_OP_HAMZA'
                    WHEN s.partner_id = 'LETZBLRIP7026684292' THEN 'BLR_OP_SUBHAN'
                    WHEN s.partner_id IN ('LETZBLRIP9656907001', 'LETZBLR9656907001') THEN 'BLR_OP_RISHAD_EBS'
                    WHEN s.partner_id = 'LETZBLRIP7356813050' THEN 'BLR_OP_RISHAN_SARBAS'
                    WHEN s.partner_id = 'LETZBLRIP8075280208' THEN 'BLR_OP_RAMEES'
                    ELSE po.driver_plan
                END
            WHERE s.status_date = v_curr_date
        ),
        daily_trips AS (
            SELECT 
                u.vehicle_number,
                COALESCE(SUM(CASE WHEN ub.operational_date = v_curr_date THEN ub.completed_trips ELSE 0 END), 0) +
                COALESCE(SUM(CASE WHEN ol.service_date = v_curr_date THEN ol.completed_trips ELSE 0 END), 0) AS day_trips,
                COALESCE(ub_w.completed_trips, SUM(ub.completed_trips), 0) + COALESCE(ol_w.completed_trips, SUM(ol.completed_trips), 0) AS week_trips,
                COALESCE(ol_w.completed_trips, SUM(ol.completed_trips), 0) AS week_ola_trips
            FROM (SELECT DISTINCT vehicle_number, week_start, week_end, week_id FROM raw_status) u
            LEFT JOIN public.core_uber_weekly ub_w
                ON ub_w.week_id = u.week_id AND UPPER(REPLACE(ub_w.vehicle_number, ' ', '')) = u.vehicle_number
            LEFT JOIN public.core_uber_daily ub 
                ON UPPER(REPLACE(ub.vehicle_number, ' ', '')) = u.vehicle_number
                AND ub.operational_date BETWEEN u.week_start AND u.week_end
            LEFT JOIN public.core_ola_weekly ol_w
                ON ol_w.week_id = u.week_id AND UPPER(REPLACE(ol_w.vehicle_number, ' ', '')) = u.vehicle_number
            LEFT JOIN public.core_ola_daily ol 
                ON UPPER(REPLACE(ol.vehicle_number, ' ', '')) = u.vehicle_number
                AND ol.service_date BETWEEN u.week_start AND u.week_end
            GROUP BY u.vehicle_number, ub_w.completed_trips, ol_w.completed_trips
        ),
        status_with_billability AS (
            SELECT 
                rs.log_date,
                rs.week_id,
                rs.vehicle_number,
                rs.partner_id,
                rs.city,
                rs.vehicle_model,
                rs.customer_type,
                rs.enrolled_plan_id,
                rs.allocation_date,
                CASE 
                    WHEN COALESCE(dt.day_trips, 0) > 0 AND rs.attendance_status IN ('Drop Off', 'Drop-off', 'RFD', 'Unassigned', 'Maintenance', 'Breakdown', 'Accident') THEN 'Active'
                    ELSE rs.attendance_status
                END AS attendance_status,
                CASE 
                    WHEN rs.partner_id IS NULL OR rs.partner_id = '' OR rs.partner_id = 'SYSTEM_ONBOARDED' THEN FALSE
                    WHEN COALESCE(dt.day_trips, 0) > 0 THEN TRUE
                    WHEN rs.attendance_status IN ('Drop Off', 'Drop-off', 'RFD', 'Unassigned') THEN FALSE
                    WHEN rs.attendance_status IN ('Maintenance', 'Breakdown', 'Accident') AND NOT rs.billable_rent_day THEN FALSE
                    -- Allocation day: Active on handover is billable per company operations policy
                    ELSE TRUE
                END AS is_billable_day,
                COALESCE(dt.week_trips, 0)::INT AS weekly_completed_trips,
                COALESCE(dt.week_ola_trips, 0)::INT AS weekly_ola_trips,
                COALESCE(rs.enrolled_plan_id,
                    CASE 
                        WHEN rs.city = 'Hyderabad' THEN 6   -- HYD_UBER_TBS
                        WHEN rs.city = 'Mumbai' THEN 10      -- MUM_UBER_REDUCING
                        WHEN rs.city = 'Bangalore' THEN
                            CASE WHEN rs.customer_type = 'Operator' THEN 20 ELSE 1 END
                        ELSE 9
                    END
                ) AS default_plan_id
            FROM raw_status rs
            LEFT JOIN daily_trips dt ON dt.vehicle_number = rs.vehicle_number
        ),
        waterfall AS (
            SELECT 
                swb.log_date,
                swb.week_id,
                swb.vehicle_number,
                swb.partner_id,
                swb.city,
                swb.vehicle_model,
                swb.attendance_status,
                swb.is_billable_day,
                swb.weekly_completed_trips,

                CASE 
                    WHEN NOT swb.is_billable_day THEN 0.00
                    WHEN ex.override_daily_rent IS NOT NULL THEN ex.override_daily_rent
                    -- Mumbai Dzire rule: Flat Rs 1,100 base rate takes priority over general partner cards
                    WHEN swb.city = 'Mumbai' AND (swb.vehicle_model ILIKE '%dzire%' OR swb.vehicle_model ILIKE '%tour s%') THEN 1100.00
                    WHEN cp.custom_daily_rent IS NOT NULL THEN cp.custom_daily_rent
                    WHEN slab.base_daily_rent IS NOT NULL THEN slab.base_daily_rent
                    WHEN mb.default_base_rent IS NOT NULL THEN mb.default_base_rent
                    WHEN p.default_daily_rent IS NOT NULL THEN p.default_daily_rent
                    ELSE 0.00
                END AS applied_daily_rent,

                CASE 
                    WHEN NOT swb.is_billable_day THEN 0.00
                    WHEN ex.override_fee IS NOT NULL THEN ex.override_fee
                    WHEN fee.is_waiver = TRUE THEN 0.00
                    WHEN fee.fee_amount IS NOT NULL THEN fee.fee_amount
                    WHEN cp.custom_daily_fee IS NOT NULL AND cp.custom_daily_rent IS NOT NULL THEN cp.custom_daily_fee
                    WHEN swb.city = 'Mumbai' THEN 30.00
                    WHEN slab.default_daily_fee IS NOT NULL THEN slab.default_daily_fee
                    WHEN mb.default_daily_indemnity IS NOT NULL THEN mb.default_daily_indemnity
                    WHEN p.default_daily_fee IS NOT NULL THEN p.default_daily_fee
                    ELSE 30.00
                END AS applied_daily_indemnity,

                CASE 
                    WHEN NOT swb.is_billable_day THEN NULL
                    WHEN ex.override_daily_rent IS NOT NULL THEN NULL
                    WHEN cp.custom_daily_rent IS NOT NULL THEN COALESCE(cp.plan_id, swb.default_plan_id)
                    WHEN swb.city = 'Mumbai' AND (swb.vehicle_model ILIKE '%dzire%' OR swb.vehicle_model ILIKE '%tour s%') THEN 11
                    WHEN slab.base_daily_rent IS NOT NULL THEN slab.plan_id
                    WHEN mb.default_base_rent IS NOT NULL THEN NULL
                    ELSE swb.default_plan_id
                END AS matched_plan_id,

                slab.slab_id AS matched_slab_id,
                cp.custom_plan_id AS matched_custom_plan_id,

                CASE 
                    WHEN NOT swb.is_billable_day THEN 'Non-billable status: ' || swb.attendance_status
                    WHEN ex.override_daily_rent IS NOT NULL THEN 'Priority 1: Approved Exception (ID #' || ex.exception_id || ')'
                    WHEN cp.custom_daily_rent IS NOT NULL THEN 'Priority 2: Custom Partner Deal (Card #' || cp.custom_plan_id || ': ' || COALESCE(cp.plan_label, 'Flat') || ')'
                    WHEN swb.city = 'Mumbai' AND (swb.vehicle_model ILIKE '%dzire%' OR swb.vehicle_model ILIKE '%tour s%') 
                        THEN 'Priority 4: Mumbai Dzire Flat Standard (Rs 1,100 + Rs 30)'
                    WHEN slab.base_daily_rent IS NOT NULL THEN 'Priority 3: Dynamic Slab (Plan #' || slab.plan_id || ': ' || slab.plan_code || ', Slab #' || slab.slab_id || ')'
                    WHEN mb.default_base_rent IS NOT NULL THEN 'Priority 4: Model Baseline (Baseline #' || mb.baseline_id || ': ' || mb.vehicle_model || ')'
                    WHEN p.default_daily_rent IS NOT NULL THEN 'Priority 5: Master City Default (Plan #' || p.plan_id || ': ' || p.plan_code || ')'
                    ELSE 'Priority 5: Fallback Zero'
                END AS calculation_rule

            FROM status_with_billability swb

            -- Priority 1: rental_exceptions
            LEFT JOIN LATERAL (
                SELECT exception_id, override_daily_rent, override_fee, reason
                FROM public.rental_exceptions
                WHERE status IN ('APPROVED', 'PENDING_CONFIRMATION')
                  AND swb.log_date BETWEEN valid_from AND valid_to
                  AND (
                      (partner_id = swb.partner_id AND vehicle_number = swb.vehicle_number)
                      OR (vehicle_number = swb.vehicle_number AND partner_id IS NULL)
                      OR (partner_id = swb.partner_id AND vehicle_number IS NULL)
                  )
                ORDER BY 
                    CASE WHEN partner_id IS NOT NULL AND vehicle_number IS NOT NULL THEN 1
                         WHEN vehicle_number IS NOT NULL THEN 2
                         ELSE 3 END
                LIMIT 1
            ) ex ON TRUE

            -- Priority 2: rental_custom_partner_plans
            LEFT JOIN LATERAL (
                SELECT custom_plan_id, custom_daily_rent, custom_daily_fee, plan_label, plan_id
                FROM public.rental_custom_partner_plans
                WHERE partner_id = swb.partner_id 
                  AND is_active = TRUE
                  AND swb.log_date BETWEEN valid_from AND valid_to
                  AND (vehicle_model = 'ALL' 
                       OR vehicle_model IS NULL
                       OR REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') || '%'
                       OR REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%')
                  AND (vehicle_number = swb.vehicle_number OR vehicle_number IS NULL)
                ORDER BY 
                    CASE WHEN vehicle_number IS NOT NULL THEN 1 ELSE 2 END,
                    CASE WHEN vehicle_model IS NOT NULL AND vehicle_model <> 'ALL' THEN 1 ELSE 2 END
                LIMIT 1
            ) cp ON TRUE

            -- Priority 3: rental_rate_slabs
            LEFT JOIN LATERAL (
                SELECT s.slab_id, s.plan_id, s.base_daily_rent, s.default_daily_fee, s.partner_id, p.plan_code
                FROM public.rental_rate_slabs s
                JOIN public.core_rental_plans p ON p.plan_id = s.plan_id
                WHERE s.city = swb.city
                  AND (
                      (s.partner_id = swb.partner_id AND (swb.enrolled_plan_id IS NULL OR s.plan_id = swb.enrolled_plan_id))
                      OR 
                      (s.partner_id = 'ALL' AND s.plan_id = swb.default_plan_id)
                  )
                  AND (s.customer_type = 'ALL' OR s.customer_type = swb.customer_type)
                  AND (s.vehicle_model = 'ALL' 
                       OR REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(s.vehicle_model), '-', ''), ' ', '') || '%'
                       OR REPLACE(REPLACE(LOWER(s.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%')
                  AND (
                      (s.condition_rule = 'OLA_GE_1' AND swb.weekly_ola_trips >= 1)
                      OR
                      (s.condition_rule = 'OLA_GE_1_UBER_ZERO' AND swb.weekly_ola_trips >= 1 AND (swb.weekly_completed_trips - swb.weekly_ola_trips) = 0)
                      OR
                      (s.condition_rule = 'OLA_ZERO' AND swb.weekly_ola_trips = 0)
                      OR
                      (s.condition_rule = 'NONE')
                  )
                  AND swb.weekly_completed_trips >= s.trip_min
                  AND (s.trip_max IS NULL OR swb.weekly_completed_trips <= s.trip_max)
                  AND swb.log_date BETWEEN s.valid_from AND s.valid_to
                ORDER BY 
                    CASE WHEN s.partner_id <> 'ALL' THEN 1 ELSE 2 END,
                    s.slab_id ASC
                LIMIT 1
            ) slab ON TRUE

            -- Priority 4: rental_model_baselines
            LEFT JOIN LATERAL (
                SELECT baseline_id, default_base_rent, default_daily_indemnity, vehicle_model
                FROM public.rental_model_baselines
                WHERE city = swb.city
                  AND is_active = TRUE
                  AND (
                      vehicle_model = 'ALL'
                      OR REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') || '%'
                      OR REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%'
                  )
                ORDER BY CASE WHEN vehicle_model <> 'ALL' THEN 1 ELSE 2 END
                LIMIT 1
            ) mb ON TRUE

            -- Priority 5: core_rental_plans city master default
            LEFT JOIN public.core_rental_plans p 
                ON p.plan_id = swb.default_plan_id

            -- Fee Rules Check: rental_fee_rules
            LEFT JOIN LATERAL (
                SELECT fee_amount, is_waiver, reason
                FROM public.rental_fee_rules
                WHERE city = swb.city
                  AND swb.log_date BETWEEN valid_from AND valid_to
                  AND (
                      (partner_id = swb.partner_id AND vehicle_model = swb.vehicle_model)
                      OR (partner_id = swb.partner_id AND vehicle_model = 'ALL')
                      OR (partner_id = 'ALL' AND vehicle_model = swb.vehicle_model)
                      OR (partner_id = 'ALL' AND vehicle_model = 'ALL')
                  )
                ORDER BY 
                    CASE WHEN partner_id <> 'ALL' AND vehicle_model <> 'ALL' THEN 1
                         WHEN partner_id <> 'ALL' THEN 2
                         WHEN vehicle_model <> 'ALL' THEN 3
                         ELSE 4 END
                LIMIT 1
            ) fee ON TRUE
        )
        INSERT INTO public.daily_rent_log (
            log_date,
            week_id,
            vehicle_number,
            partner_id,
            city,
            vehicle_model,
            attendance_status,
            is_billable_day,
            weekly_completed_trips,
            applied_daily_rent,
            applied_daily_indemnity,
            net_daily_rent,
            calculation_rule,
            matched_plan_id,
            matched_slab_id,
            matched_custom_plan_id
        )
        SELECT 
            w.log_date,
            w.week_id,
            w.vehicle_number,
            w.partner_id,
            w.city,
            w.vehicle_model,
            w.attendance_status,
            w.is_billable_day,
            w.weekly_completed_trips,
            w.applied_daily_rent,
            w.applied_daily_indemnity,
            w.applied_daily_rent + w.applied_daily_indemnity AS net_daily_rent,
            w.calculation_rule,
            w.matched_plan_id,
            w.matched_slab_id,
            w.matched_custom_plan_id
        FROM waterfall w
        ON CONFLICT (log_date, vehicle_number, partner_id) 
        DO UPDATE SET
            week_id = EXCLUDED.week_id,
            city = EXCLUDED.city,
            vehicle_model = EXCLUDED.vehicle_model,
            attendance_status = EXCLUDED.attendance_status,
            is_billable_day = EXCLUDED.is_billable_day,
            weekly_completed_trips = EXCLUDED.weekly_completed_trips,
            applied_daily_rent = EXCLUDED.applied_daily_rent,
            applied_daily_indemnity = EXCLUDED.applied_daily_indemnity,
            net_daily_rent = EXCLUDED.net_daily_rent,
            calculation_rule = EXCLUDED.calculation_rule,
            matched_plan_id = EXCLUDED.matched_plan_id,
            matched_slab_id = EXCLUDED.matched_slab_id,
            matched_custom_plan_id = EXCLUDED.matched_custom_plan_id;

        v_curr_date := v_curr_date + 1;
    END LOOP;

    RAISE NOTICE 'Daily Rent Calculation completed successfully.';
END;
$$;
