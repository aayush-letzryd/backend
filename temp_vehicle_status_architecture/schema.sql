-- ============================================================================
-- FLEET STATUS & INTERVAL LEDGER ENGINE SCHEMA
-- Master Target: public.core_daily_vehicle_status
-- Views: public.v_vehicle_trip_intervals, public.v_current_live_fleet_status
-- Procedure: public.sp_generate_daily_vehicle_status(target_date DATE)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Master Daily Status Calendar Table
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.core_daily_vehicle_status (
    id BIGSERIAL PRIMARY KEY,
    status_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(10) NOT NULL,
    
    -- Operational Status
    final_status VARCHAR(30) NOT NULL,      -- 'Active', 'RFD', 'Maintenance', 'Accidental', 'Impounded'
    cohort VARCHAR(20) NOT NULL,            -- 'On Road', 'In Yard', 'Off Road'
    
    -- Active Driver Assignment (NULL if RFD / in yard)
    partner_id VARCHAR(50),
    partner_name VARCHAR(150),
    partner_phone VARCHAR(20),
    hub_name VARCHAR(100),
    car_model VARCHAR(100),
    
    -- Active Interval Linkage
    allocation_id BIGINT,
    allocation_date DATE,
    dropoff_id BIGINT,
    dropoff_date DATE,
    maintenance_id BIGINT,
    
    -- Billing Directives for Hisaab
    billable_rent_day BOOLEAN NOT NULL DEFAULT FALSE,
    rent_waived_reason VARCHAR(100),        -- 'RFD_IN_YARD', 'WORKSHOP_MAINTENANCE', 'ACCIDENT_DOWNTIME'
    
    -- Audit & Metadata
    source_origin VARCHAR(50) NOT NULL,     -- 'INTERVAL_MATCH', 'OPEN_ALLOCATION', 'YARD_ROLLOVER', 'WORKSHOP_EVENT'
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_daily_vehicle_status UNIQUE (status_date, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_cdvs_date_partner ON public.core_daily_vehicle_status (status_date, partner_id);
CREATE INDEX IF NOT EXISTS idx_cdvs_vehicle_date ON public.core_daily_vehicle_status (vehicle_number, status_date);
CREATE INDEX IF NOT EXISTS idx_cdvs_status_date ON public.core_daily_vehicle_status (final_status, status_date);

-- ----------------------------------------------------------------------------
-- 2. Master View: Continuous Vehicle Trip Intervals
-- Pairs every allocation with its subsequent drop-off event
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_vehicle_trip_intervals AS
WITH ranked_allocations AS (
    SELECT 
        a.id AS allocation_id,
        a.vehicle_number,
        a.partner_id,
        a.driver_name,
        a.driver_phone,
        a.city,
        a.car_model,
        a.hub_name,
        a.allocation_date,
        LEAD(a.allocation_date) OVER (
            PARTITION BY a.vehicle_number 
            ORDER BY a.allocation_date ASC, a.id ASC
        ) AS next_allocation_date
    FROM public.core_vehicle_allocation a
    WHERE a.is_deleted = FALSE
)
SELECT 
    ra.allocation_id,
    ra.vehicle_number,
    ra.partner_id,
    ra.driver_name,
    ra.driver_phone,
    ra.city,
    ra.car_model,
    ra.hub_name,
    ra.allocation_date AS trip_start_date,
    d.id AS dropoff_id,
    d.return_date AS trip_end_date,
    d.return_type,
    d.negative_balance AS final_debt,
    CASE 
        WHEN d.id IS NOT NULL THEN 'CLOSED_TRIP'
        ELSE 'CURRENTLY_ACTIVE'
    END AS trip_state,
    CASE 
        WHEN d.return_date IS NOT NULL THEN (d.return_date - ra.allocation_date)
        ELSE (CURRENT_DATE - ra.allocation_date)
    END AS days_duration
FROM ranked_allocations ra
LEFT JOIN LATERAL (
    SELECT 
        d.id,
        d.return_date,
        d.return_type,
        d.negative_balance
    FROM public.core_dropoffs d
    WHERE d.is_deleted = FALSE
      AND d.vehicle_number = ra.vehicle_number
      AND d.return_date >= ra.allocation_date
      AND (ra.next_allocation_date IS NULL OR d.return_date <= ra.next_allocation_date)
    ORDER BY d.return_date ASC, d.id ASC
    LIMIT 1
) d ON TRUE;

-- ----------------------------------------------------------------------------
-- 3. Master View: Real-Time Live Fleet Snapshot (Current Moment)
-- Gives operations instant visibility into all 1,625 vehicles right now
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_current_live_fleet_status AS
WITH latest_allocations AS (
    SELECT DISTINCT ON (vehicle_number)
        allocation_id,
        vehicle_number,
        partner_id,
        driver_name,
        driver_phone,
        city,
        car_model,
        hub_name,
        trip_start_date,
        dropoff_id,
        trip_end_date,
        trip_state
    FROM public.v_vehicle_trip_intervals
    ORDER BY vehicle_number, trip_start_date DESC, allocation_id DESC
),
active_maintenance AS (
    SELECT DISTINCT ON (vehicle_reg_no)
        id AS maintenance_id,
        vehicle_reg_no,
        job_card_date AS maintenance_date
    FROM public.july_maintenance_in mi
    WHERE NOT EXISTS (
        SELECT 1 FROM public.july_maintenance_out mo 
        WHERE mo.vehicle_reg_no = mi.vehicle_reg_no 
          AND mo.created_at >= mi.created_at
    )
    ORDER BY vehicle_reg_no, job_card_date DESC
)
SELECT 
    vo.registration_no AS vehicle_number,
    vo.vehicle_make,
    vo.vehicle_model,
    vo.assigned_city AS city,
    vo.hub AS default_hub,
    CASE 
        WHEN m.maintenance_id IS NOT NULL THEN 'Maintenance'
        WHEN la.trip_state = 'CURRENTLY_ACTIVE' THEN 'Active'
        ELSE 'RFD'
    END AS live_status,
    CASE 
        WHEN m.maintenance_id IS NOT NULL THEN 'Off Road'
        WHEN la.trip_state = 'CURRENTLY_ACTIVE' THEN 'On Road'
        ELSE 'In Yard'
    END AS live_cohort,
    CASE 
        WHEN m.maintenance_id IS NOT NULL THEN NULL
        WHEN la.trip_state = 'CURRENTLY_ACTIVE' THEN la.partner_id
        ELSE NULL
    END AS current_driver_id,
    CASE 
        WHEN m.maintenance_id IS NOT NULL THEN NULL
        WHEN la.trip_state = 'CURRENTLY_ACTIVE' THEN la.driver_name
        ELSE NULL
    END AS current_driver_name,
    la.trip_start_date AS current_trip_started,
    m.maintenance_date AS maintenance_started,
    CURRENT_TIMESTAMP AS snapshot_at
FROM public.core_vehicle_onboarding vo
LEFT JOIN latest_allocations la ON vo.registration_no = la.vehicle_number
LEFT JOIN active_maintenance m ON vo.registration_no = m.vehicle_reg_no
WHERE vo.is_deleted = FALSE;

-- ----------------------------------------------------------------------------
-- 4. Daily Status Ledger Generation Stored Procedure
-- Populates core_daily_vehicle_status for any given calendar date
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_generate_daily_vehicle_status(p_target_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO public.core_daily_vehicle_status (
        status_date,
        vehicle_number,
        city,
        final_status,
        cohort,
        partner_id,
        partner_name,
        partner_phone,
        hub_name,
        car_model,
        allocation_id,
        allocation_date,
        dropoff_id,
        dropoff_date,
        billable_rent_day,
        rent_waived_reason,
        source_origin,
        updated_at
    )
    SELECT 
        p_target_date AS status_date,
        vo.registration_no AS vehicle_number,
        COALESCE(ti.city, vo.assigned_city, 'UNKNOWN') AS city,
        CASE 
            WHEN ti.allocation_id IS NOT NULL THEN 'Active'
            ELSE 'RFD'
        END AS final_status,
        CASE 
            WHEN ti.allocation_id IS NOT NULL THEN 'On Road'
            ELSE 'In Yard'
        END AS cohort,
        ti.partner_id,
        ti.driver_name,
        ti.driver_phone,
        COALESCE(ti.hub_name, vo.hub),
        COALESCE(ti.car_model, vo.vehicle_model),
        ti.allocation_id,
        ti.trip_start_date,
        ti.dropoff_id,
        ti.trip_end_date,
        CASE 
            WHEN ti.allocation_id IS NOT NULL THEN TRUE
            ELSE FALSE
        END AS billable_rent_day,
        CASE 
            WHEN ti.allocation_id IS NULL THEN 'RFD_IN_YARD'
            ELSE NULL
        END AS rent_waived_reason,
        CASE 
            WHEN ti.dropoff_id IS NOT NULL THEN 'INTERVAL_MATCH'
            WHEN ti.allocation_id IS NOT NULL THEN 'OPEN_ALLOCATION'
            ELSE 'YARD_ROLLOVER'
        END AS source_origin,
        CURRENT_TIMESTAMP AS updated_at
    FROM public.core_vehicle_onboarding vo
    LEFT JOIN LATERAL (
        SELECT *
        FROM public.v_vehicle_trip_intervals ti
        WHERE ti.vehicle_number = vo.registration_no
          AND ti.trip_start_date <= p_target_date
          AND (ti.trip_end_date IS NULL OR ti.trip_end_date >= p_target_date)
        ORDER BY ti.trip_start_date DESC
        LIMIT 1
    ) ti ON TRUE
    WHERE vo.is_deleted = FALSE
    ON CONFLICT (status_date, vehicle_number)
    DO UPDATE SET
        final_status = EXCLUDED.final_status,
        cohort = EXCLUDED.cohort,
        partner_id = EXCLUDED.partner_id,
        partner_name = EXCLUDED.partner_name,
        partner_phone = EXCLUDED.partner_phone,
        hub_name = EXCLUDED.hub_name,
        car_model = EXCLUDED.car_model,
        allocation_id = EXCLUDED.allocation_id,
        allocation_date = EXCLUDED.allocation_date,
        dropoff_id = EXCLUDED.dropoff_id,
        dropoff_date = EXCLUDED.dropoff_date,
        billable_rent_day = EXCLUDED.billable_rent_day,
        rent_waived_reason = EXCLUDED.rent_waived_reason,
        source_origin = EXCLUDED.source_origin,
        updated_at = CURRENT_TIMESTAMP;
END;
$$;
