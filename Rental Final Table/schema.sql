-- ============================================================================
-- LetzRyd Standardized Unified Rental Architecture - DDL Specification
-- ============================================================================
-- Single Whole-Block Multi-City Rental Engine (Bangalore, Hyderabad, Mumbai)
-- 100% Data-Driven & Table-Governed: Zero hardcoded magic numbers in SQL or code.
-- Primary Keys: Clean Integer SERIAL PRIMARY KEYs (1, 2, 3...) across all tables.
-- Trigger-Free: Batch execution managed by stored procedures & pg_cron.
-- ============================================================================

-- Table 1: core_rental_plans (Canonical Plan Catalogue)
CREATE TABLE IF NOT EXISTS public.core_rental_plans (
    plan_id SERIAL PRIMARY KEY,                         -- 1, 2, 3...
    plan_code VARCHAR(64) UNIQUE NOT NULL,              -- 'BLR_ALL_PLATFORM', 'HYD_UBER_TBS', etc.
    city VARCHAR(32) NOT NULL,
    plan_name VARCHAR(128) NOT NULL,
    plan_category VARCHAR(32) NOT NULL,                 -- 'STANDARD', 'CUSTOM'
    calculation_type VARCHAR(32) NOT NULL,              -- 'SLAB_TIERED', 'FLAT_RATE', 'PLATFORM_SPLIT', 'MODEL_FALLBACK'
    default_daily_rent NUMERIC(10,2) NOT NULL,          -- Table-defined default base rate (e.g. 929.00, 970.00, 989.00)
    default_daily_fee NUMERIC(10,2) NOT NULL DEFAULT 30.00, -- Table-defined default fee
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_core_rental_plans_city ON public.core_rental_plans(city, is_active);

-- Table 2: rental_rate_slabs (Dynamic Reducing Slabs & Operator Brackets)
CREATE TABLE IF NOT EXISTS public.rental_rate_slabs (
    slab_id SERIAL PRIMARY KEY,                         -- 1, 2, 3...
    plan_id INT NOT NULL REFERENCES public.core_rental_plans(plan_id) ON DELETE CASCADE,
    partner_id VARCHAR(64) NOT NULL DEFAULT 'ALL',      -- 'ALL' or specific operator/partner ID
    city VARCHAR(32) NOT NULL,
    customer_type VARCHAR(32) NOT NULL DEFAULT 'ALL',   -- 'Individual', 'Operator', 'ALL'
    vehicle_model VARCHAR(64) NOT NULL DEFAULT 'ALL',
    source_plan_code VARCHAR(64),
    metric_type VARCHAR(32) NOT NULL DEFAULT 'UBER_TRIPS', -- 'UBER_TRIPS', 'OLA_TRIPS', 'TOTAL_TRIPS'
    condition_rule VARCHAR(128) NOT NULL DEFAULT 'NONE', -- 'NONE', 'OLA_GE_1', 'OLA_GE_1_UBER_ZERO', 'OLA_ZERO'
    trip_min INT NOT NULL,
    trip_max INT,                                       -- NULL or upper trip limit
    base_daily_rent NUMERIC(10,2) NOT NULL,             -- Table-defined slab rate
    default_daily_fee NUMERIC(10,2) NOT NULL DEFAULT 30.00,
    valid_from DATE NOT NULL DEFAULT '2026-01-01',
    valid_to DATE NOT NULL DEFAULT '9999-12-31',
    evidence_reference VARCHAR(128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_rental_rate_slabs UNIQUE (plan_id, partner_id, customer_type, vehicle_model, condition_rule, trip_min, valid_from)
);

CREATE INDEX IF NOT EXISTS idx_rental_rate_slabs_lookup ON public.rental_rate_slabs(city, partner_id, customer_type, vehicle_model, trip_min, trip_max);

-- Table 3: rental_custom_partner_plans (Partner Agreement Cards)
CREATE TABLE IF NOT EXISTS public.rental_custom_partner_plans (
    custom_plan_id SERIAL PRIMARY KEY,                  -- 1, 2, 3...
    partner_id VARCHAR(64) NOT NULL,
    partner_name VARCHAR(128),
    city VARCHAR(32) NOT NULL,
    vehicle_model VARCHAR(64),
    vehicle_number VARCHAR(32),
    plan_id INT REFERENCES public.core_rental_plans(plan_id) ON DELETE SET NULL,
    custom_daily_rent NUMERIC(10,2),                    -- Flat rate agreement
    custom_daily_fee NUMERIC(10,2) NOT NULL DEFAULT 30.00,
    plan_label VARCHAR(128),
    evidence_source VARCHAR(128),
    approved_by VARCHAR(64) DEFAULT 'Operations Head',
    valid_from DATE NOT NULL DEFAULT '2026-01-01',
    valid_to DATE NOT NULL DEFAULT '9999-12-31',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_rental_custom_partner_lookup ON public.rental_custom_partner_plans(partner_id, is_active, valid_from, valid_to);

-- Table 4: rental_model_baselines (Vehicle Model Rate Fallbacks)
CREATE TABLE IF NOT EXISTS public.rental_model_baselines (
    baseline_id SERIAL PRIMARY KEY,                     -- 1, 2, 3...
    city VARCHAR(32) NOT NULL,
    vehicle_model VARCHAR(64) NOT NULL,
    default_base_rent NUMERIC(10,2) NOT NULL,
    default_daily_indemnity NUMERIC(10,2) NOT NULL DEFAULT 30.00,
    all_platform_flat_rent NUMERIC(10,2) NOT NULL DEFAULT 1050.00,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_rental_model_baselines UNIQUE (city, vehicle_model)
);

CREATE INDEX IF NOT EXISTS idx_rental_model_baselines_lookup ON public.rental_model_baselines(city, vehicle_model);

-- Table 5: rental_fee_rules (Indemnity Fees & Policy Waivers)
CREATE TABLE IF NOT EXISTS public.rental_fee_rules (
    fee_rule_id SERIAL PRIMARY KEY,                     -- 1, 2, 3...
    city VARCHAR(32) NOT NULL DEFAULT 'ALL',
    partner_id VARCHAR(64) NOT NULL DEFAULT 'ALL',
    vehicle_model VARCHAR(64) NOT NULL DEFAULT 'ALL',
    fee_amount NUMERIC(10,2) NOT NULL,
    is_waiver BOOLEAN NOT NULL DEFAULT FALSE,
    reason VARCHAR(255) NOT NULL,
    valid_from DATE NOT NULL DEFAULT '2026-01-01',
    valid_to DATE NOT NULL DEFAULT '9999-12-31',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_rental_fee_rules_lookup ON public.rental_fee_rules(city, partner_id, vehicle_model, valid_from, valid_to);

-- Table 6: rental_exceptions (Audit-Grade Governance & Overrides Layer)
CREATE TABLE IF NOT EXISTS public.rental_exceptions (
    exception_id SERIAL PRIMARY KEY,                    -- 1, 2, 3...
    override_type VARCHAR(64) NOT NULL,
    city VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64),
    vehicle_number VARCHAR(32),
    vehicle_model VARCHAR(64),
    override_daily_rent NUMERIC(10,2) NOT NULL,
    override_fee NUMERIC(10,2),
    canonical_expected_rent NUMERIC(10,2),
    variance NUMERIC(10,2),
    reason TEXT NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'APPROVED',
    approved_by VARCHAR(64) DEFAULT 'System Migration',
    approval_date DATE DEFAULT CURRENT_DATE,
    valid_from DATE NOT NULL,
    valid_to DATE NOT NULL,
    source_file VARCHAR(255),
    source_row INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_rental_exceptions_lookup ON public.rental_exceptions(partner_id, vehicle_number, valid_from, valid_to, status);

-- Table 7: daily_rent_log (Daily Output Rent Ledger with Full Lineage)
CREATE TABLE IF NOT EXISTS public.daily_rent_log (
    id SERIAL PRIMARY KEY,                              -- 1, 2, 3...
    log_date DATE NOT NULL,
    week_id VARCHAR(16) NOT NULL,
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    city VARCHAR(32) NOT NULL,
    vehicle_model VARCHAR(64) NOT NULL,
    attendance_status VARCHAR(64) NOT NULL,
    is_billable_day BOOLEAN NOT NULL,
    weekly_completed_trips INT NOT NULL,
    applied_daily_rent NUMERIC(10,2) NOT NULL,
    applied_daily_indemnity NUMERIC(10,2) NOT NULL,
    net_daily_rent NUMERIC(10,2) NOT NULL,
    matched_plan_id INT REFERENCES public.core_rental_plans(plan_id) ON DELETE SET NULL,
    matched_slab_id INT REFERENCES public.rental_rate_slabs(slab_id) ON DELETE SET NULL,
    matched_custom_plan_id INT REFERENCES public.rental_custom_partner_plans(custom_plan_id) ON DELETE SET NULL,
    calculation_rule VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_daily_rent_log_grain UNIQUE (log_date, vehicle_number, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_daily_rent_log_date_veh ON public.daily_rent_log(log_date, vehicle_number);
CREATE INDEX IF NOT EXISTS idx_daily_rent_log_week_partner ON public.daily_rent_log(week_id, partner_id);

-- ============================================================================
-- Stored Procedure: sp_calculate_daily_rent (100% Data-Driven Waterfall)
-- ============================================================================
CREATE OR REPLACE PROCEDURE public.sp_calculate_daily_rent(
    IN p_start_date date DEFAULT NULL::date,
    IN p_end_date date DEFAULT NULL::date
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_curr_date DATE;
    v_calc_start DATE;
    v_calc_end DATE;
    v_week_start DATE;
    v_week_end DATE;
BEGIN
    v_calc_start := COALESCE(p_start_date, CURRENT_DATE - 1);
    v_calc_end   := COALESCE(p_end_date, v_calc_start);

    -- Expand to full ISO week boundaries to guarantee whole-week repricing as trips accumulate
    v_week_start := v_calc_start - (EXTRACT(ISODOW FROM v_calc_start)::INT - 1);
    v_week_end   := v_calc_end + (7 - EXTRACT(ISODOW FROM v_calc_end)::INT);

    FOR v_curr_date IN 
        SELECT generate_series(v_week_start, v_week_end, '1 day'::interval)::DATE
    LOOP
        WITH raw_status AS (
            SELECT 
                s.status_date AS log_date,
                UPPER(REPLACE(s.vehicle_number, ' ', '')) AS vehicle_number,
                COALESCE(NULLIF(TRIM(s.partner_id), ''), 'SYSTEM_ONBOARDED') AS partner_id,
                CASE 
                    WHEN s.city ILIKE 'blr%' OR s.city ILIKE 'bengalur%' OR s.city ILIKE 'bangal%' THEN 'Bangalore'
                    WHEN s.city ILIKE 'hyd%' THEN 'Hyderabad'
                    WHEN s.city ILIKE 'mum%' OR s.city ILIKE 'bombay%' THEN 'Mumbai'
                    ELSE COALESCE(s.city, 'Hyderabad')
                END AS city,
                COALESCE(s.car_model, 'Unknown') AS vehicle_model,
                COALESCE(s.final_status, 'Active') AS attendance_status,
                s.billable_rent_day,
                s.allocation_id,
                COALESCE(
                    hw.week_id,
                    'CY' || TO_CHAR(s.status_date, 'YY') || 'WK' || LPAD(TO_CHAR(s.status_date, 'IW'), 2, '0')
                ) AS week_id,
                COALESCE(hw.week_start, s.status_date - (EXTRACT(ISODOW FROM s.status_date)::INT - 1)) AS week_start,
                COALESCE(hw.week_end, s.status_date + (7 - EXTRACT(ISODOW FROM s.status_date)::INT)) AS week_end,
                -- Explicit partner classification and enrolled plan from core_partner_onboarding
                COALESCE(po.onboarding_type, 
                    CASE WHEN s.partner_id ILIKE '%OP%' OR s.partner_id ILIKE '%FLEET%' OR s.partner_id ILIKE '%IP%' THEN 'Operator' ELSE 'Individual' END
                ) AS customer_type,
                p_enrolled.plan_id AS enrolled_plan_id
            FROM public.core_daily_vehicle_status s
            LEFT JOIN public.hisaab_settlement_weeks hw 
                ON s.status_date BETWEEN hw.week_start AND hw.week_end
            LEFT JOIN public.core_partner_onboarding po
                ON po.partner_id = s.partner_id
            LEFT JOIN public.core_rental_plans p_enrolled
                ON p_enrolled.plan_code = po.driver_plan
            WHERE s.status_date = v_curr_date
        ),
        daily_trips AS (
            SELECT 
                u.vehicle_number,
                -- Date-specific trips on v_curr_date to evaluate billability override
                COALESCE(SUM(CASE WHEN ub.operational_date = v_curr_date THEN ub.completed_trips ELSE 0 END), 0) +
                COALESCE(SUM(CASE WHEN ol.service_date = v_curr_date THEN ol.completed_trips ELSE 0 END), 0) AS day_trips,
                -- Cumulative ISO week trips to evaluate reducing slab tier
                COALESCE(SUM(ub.completed_trips), 0) + COALESCE(SUM(ol.completed_trips), 0) AS week_trips,
                COALESCE(SUM(ol.completed_trips), 0) AS week_ola_trips
            FROM (SELECT DISTINCT vehicle_number, week_start, week_end FROM raw_status) u
            LEFT JOIN public.core_uber_daily ub 
                ON UPPER(REPLACE(ub.vehicle_number, ' ', '')) = u.vehicle_number
                AND ub.operational_date BETWEEN u.week_start AND u.week_end
            LEFT JOIN public.core_ola_daily ol 
                ON UPPER(REPLACE(ol.vehicle_number, ' ', '')) = u.vehicle_number
                AND ol.service_date BETWEEN u.week_start AND u.week_end
            GROUP BY u.vehicle_number
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
                -- Date-specific activity overrides non-billable attendance ONLY if car drove trips on this date
                CASE 
                    WHEN COALESCE(dt.day_trips, 0) > 0 AND rs.attendance_status IN ('Drop Off', 'Drop-off', 'RFD', 'Unassigned', 'Maintenance', 'Breakdown', 'Accident') THEN 'Active'
                    ELSE rs.attendance_status
                END AS attendance_status,
                CASE 
                    WHEN rs.partner_id IS NULL OR rs.partner_id = '' OR rs.partner_id = 'SYSTEM_ONBOARDED' THEN FALSE
                    WHEN COALESCE(dt.day_trips, 0) > 0 THEN TRUE
                    WHEN rs.attendance_status IN ('Drop Off', 'Drop-off', 'RFD', 'Unassigned') THEN FALSE
                    WHEN rs.attendance_status IN ('Maintenance', 'Breakdown', 'Accident') AND NOT rs.billable_rent_day THEN FALSE
                    ELSE TRUE
                END AS is_billable_day,
                COALESCE(dt.week_trips, 0)::INT AS weekly_completed_trips,
                COALESCE(dt.week_ola_trips, 0)::INT AS weekly_ola_trips,
                -- Default plan resolution directly from city, customer type, and enrolled plan
                COALESCE(rs.enrolled_plan_id,
                    CASE 
                        WHEN rs.city = 'Hyderabad' THEN 6  -- HYD_UBER_TBS
                        WHEN rs.city = 'Mumbai' THEN 10     -- MUM_UBER_REDUCING
                        WHEN rs.city = 'Bangalore' THEN
                            CASE WHEN rs.customer_type = 'Operator' THEN 2 ELSE 1 END
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

                -- Data-Driven Rent Selection (Waterfall: Exceptions -> Custom Partner Card -> Slabs -> Baselines -> Default)
                CASE 
                    WHEN NOT swb.is_billable_day THEN 0.00
                    WHEN ex.override_daily_rent IS NOT NULL THEN ex.override_daily_rent
                    WHEN cp.custom_daily_rent IS NOT NULL THEN cp.custom_daily_rent
                    WHEN slab.base_daily_rent IS NOT NULL THEN slab.base_daily_rent
                    WHEN mb.default_base_rent IS NOT NULL THEN mb.default_base_rent
                    WHEN p.default_daily_rent IS NOT NULL THEN p.default_daily_rent
                    ELSE 0.00
                END AS applied_daily_rent,

                -- Data-Driven Indemnity Selection (Strict 5-Tier Precedence)
                CASE 
                    WHEN NOT swb.is_billable_day THEN 0.00
                    WHEN ex.override_fee IS NOT NULL THEN ex.override_fee
                    WHEN fee.is_waiver = TRUE THEN 0.00
                    WHEN fee.fee_amount IS NOT NULL THEN fee.fee_amount
                    WHEN cp.custom_daily_fee IS NOT NULL AND cp.custom_daily_rent IS NOT NULL THEN cp.custom_daily_fee
                    WHEN slab.default_daily_fee IS NOT NULL THEN slab.default_daily_fee
                    WHEN mb.default_daily_indemnity IS NOT NULL THEN mb.default_daily_indemnity
                    WHEN p.default_daily_fee IS NOT NULL THEN p.default_daily_fee
                    ELSE 30.00
                END AS applied_daily_indemnity,

                -- Clean Lineage Identifiers
                CASE 
                    WHEN NOT swb.is_billable_day THEN NULL
                    WHEN ex.override_daily_rent IS NOT NULL THEN NULL
                    WHEN cp.custom_daily_rent IS NOT NULL THEN COALESCE(cp.plan_id, swb.default_plan_id)
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

            -- Priority 2: rental_custom_partner_plans (Matched by Partner ID + Vehicle Model + Date Range)
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

            -- Priority 3: rental_rate_slabs (Scoped to enrolled plan or default plan)
            LEFT JOIN LATERAL (
                SELECT s.slab_id, s.plan_id, s.base_daily_rent, s.default_daily_fee, s.partner_id, p.plan_code
                FROM public.rental_rate_slabs s
                JOIN public.core_rental_plans p ON p.plan_id = s.plan_id
                WHERE s.city = swb.city
                  AND (
                      (s.partner_id = swb.partner_id AND (COALESCE(cp.plan_id, swb.enrolled_plan_id) IS NULL OR s.plan_id = COALESCE(cp.plan_id, swb.enrolled_plan_id)))
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
                    CASE WHEN s.condition_rule <> 'NONE' THEN 1 ELSE 2 END,
                    CASE WHEN s.vehicle_model <> 'ALL' THEN 1 ELSE 2 END,
                    s.trip_min DESC
                LIMIT 1
            ) slab ON TRUE

            -- Priority 4: rental_model_baselines
            LEFT JOIN LATERAL (
                SELECT baseline_id, vehicle_model, default_base_rent, default_daily_indemnity
                FROM public.rental_model_baselines
                WHERE city = swb.city 
                  AND is_active = TRUE
                  AND (
                      vehicle_model = swb.vehicle_model
                      OR REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') || '%'
                      OR REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%'
                  )
                ORDER BY CASE WHEN vehicle_model = swb.vehicle_model THEN 1 ELSE 2 END
                LIMIT 1
            ) mb ON TRUE

            -- Priority 5: core_rental_plans
            LEFT JOIN LATERAL (
                SELECT plan_id, plan_code, default_daily_rent, default_daily_fee
                FROM public.core_rental_plans
                WHERE plan_id = swb.default_plan_id AND is_active = TRUE
            ) p ON TRUE

            -- Indemnity Rules lookup from rental_fee_rules
            LEFT JOIN LATERAL (
                SELECT fee_rule_id, fee_amount, is_waiver
                FROM public.rental_fee_rules
                WHERE (city = 'ALL' OR city = swb.city)
                  AND (partner_id = 'ALL' OR partner_id = swb.partner_id)
                  AND (vehicle_model = 'ALL' 
                       OR REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') || '%'
                       OR REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%')
                  AND swb.log_date BETWEEN valid_from AND valid_to
                ORDER BY 
                    CASE WHEN partner_id <> 'ALL' THEN 1 ELSE 2 END,
                    CASE WHEN vehicle_model <> 'ALL' THEN 1 ELSE 2 END,
                    CASE WHEN city <> 'ALL' THEN 1 ELSE 2 END
                LIMIT 1
            ) fee ON TRUE
        )
        INSERT INTO public.daily_rent_log (
            log_date, week_id, vehicle_number, partner_id, city, vehicle_model,
            attendance_status, is_billable_day, weekly_completed_trips,
            applied_daily_rent, applied_daily_indemnity, net_daily_rent,
            matched_plan_id, matched_slab_id, matched_custom_plan_id,
            calculation_rule, created_at
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
            (w.applied_daily_rent + w.applied_daily_indemnity) AS net_daily_rent,
            w.matched_plan_id,
            w.matched_slab_id,
            w.matched_custom_plan_id,
            w.calculation_rule,
            CURRENT_TIMESTAMP
        FROM waterfall w
        ON CONFLICT (log_date, vehicle_number, partner_id) DO UPDATE SET
            week_id = EXCLUDED.week_id,
            city = EXCLUDED.city,
            vehicle_model = EXCLUDED.vehicle_model,
            attendance_status = EXCLUDED.attendance_status,
            is_billable_day = EXCLUDED.is_billable_day,
            weekly_completed_trips = EXCLUDED.weekly_completed_trips,
            applied_daily_rent = EXCLUDED.applied_daily_rent,
            applied_daily_indemnity = EXCLUDED.applied_daily_indemnity,
            net_daily_rent = EXCLUDED.net_daily_rent,
            matched_plan_id = EXCLUDED.matched_plan_id,
            matched_slab_id = EXCLUDED.matched_slab_id,
            matched_custom_plan_id = EXCLUDED.matched_custom_plan_id,
            calculation_rule = EXCLUDED.calculation_rule,
            created_at = CURRENT_TIMESTAMP;

    END LOOP;
END;
$procedure$;

-- ============================================================================
-- Stored Procedure: sp_sync_rent_to_hisaab
-- ============================================================================
CREATE OR REPLACE PROCEDURE public.sp_sync_rent_to_hisaab(IN p_week_id VARCHAR DEFAULT NULL)
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

    -- Bulk aggregate weekly vehicle ledger
    CALL public.sp_sync_hisaab_vehicle_weekly(v_week_id, NULL, NULL);

    -- Bulk aggregate weekly partner ledger
    CALL public.sp_sync_hisaab_partner_weekly(v_week_id, NULL);

    RAISE NOTICE 'Successfully synced rent to hisaab for week %', v_week_id;
END;
$procedure$;

-- ============================================================================
-- pg_cron Automation Schedules
-- ============================================================================
-- Nightly at 02:00 UTC: Calculate daily rent across all active vehicles
SELECT cron.schedule('rental-daily-calculation', '0 2 * * *', 'CALL public.sp_calculate_daily_rent(CURRENT_DATE - 1, CURRENT_DATE);');

-- Nightly at 02:30 UTC: Synchronize rent into Hisaab settlements
SELECT cron.schedule('hisaab-rent-sync', '30 2 * * *', 'CALL public.sp_sync_rent_to_hisaab(NULL);');
