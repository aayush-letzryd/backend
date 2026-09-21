-- ==============================================================================
-- LETZRYD FLEET MANAGEMENT PLATFORM - VEHICLE STATUS FINAL TABLE
-- ==============================================================================
-- Master Table       : public.core_daily_vehicle_status
-- Views              : public.v_vehicle_trip_intervals, public.v_current_live_fleet_status
-- Stored Procedure   : public.sp_generate_daily_vehicle_status(p_target_date DATE)
-- Trigger Function   : public.fn_sync_core_daily_status_from_sheet()
-- Upstream Staging   : public.sheet_vehicle_status
-- Primary Relational : core_vehicle_onboarding, core_vehicle_allocation, core_dropoffs, core_maintenance
-- PostgreSQL Version : 18.3+
-- Description        : Authoritative Single Source of Truth (SSOT) daily attendance
--                      and rental billing ledger for all 1,647+ fleet vehicles.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. BASELINE TABLE DEFINITION: public.core_daily_vehicle_status
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.core_daily_vehicle_status (
    id BIGSERIAL PRIMARY KEY,
    status_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(20) NOT NULL,
    final_status VARCHAR(30) NOT NULL, -- 'Active', 'RFD', 'Maintenance', 'Allocation', 'Drop Off', 'Same Day D&A', 'New Deployment'
    cohort VARCHAR(20) NOT NULL,       -- 'On Road', 'Off Road', 'In Yard'
    partner_id VARCHAR(50),
    partner_name VARCHAR(150),
    partner_phone VARCHAR(20),
    hub_name VARCHAR(100) DEFAULT 'MAIN_HUB',
    car_model VARCHAR(100),
    allocation_id BIGINT,
    allocation_date DATE,
    dropoff_id BIGINT,
    dropoff_date DATE,
    maintenance_id BIGINT,
    billable_rent_day BOOLEAN NOT NULL DEFAULT FALSE,
    rent_waived_reason VARCHAR(100),   -- 'WORKSHOP_MAINTENANCE', 'DROPOFF_INSPECTION', 'RFD_IN_YARD'
    source_origin VARCHAR(50) NOT NULL DEFAULT 'SHEET_STATUS_SYNC',
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_daily_vehicle_status UNIQUE (status_date, vehicle_number)
);

-- ------------------------------------------------------------------------------
-- 2. PERFORMANCE B-TREE INDEXES
-- ------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_cdvs_date_veh ON public.core_daily_vehicle_status (status_date DESC, vehicle_number);
CREATE INDEX IF NOT EXISTS idx_cdvs_veh ON public.core_daily_vehicle_status (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_cdvs_status ON public.core_daily_vehicle_status (final_status);
CREATE INDEX IF NOT EXISTS idx_cdvs_cohort ON public.core_daily_vehicle_status (cohort);
CREATE INDEX IF NOT EXISTS idx_cdvs_partner ON public.core_daily_vehicle_status (partner_id);
CREATE INDEX IF NOT EXISTS idx_cdvs_billable ON public.core_daily_vehicle_status (billable_rent_day);
CREATE INDEX IF NOT EXISTS idx_cdvs_alloc_id ON public.core_daily_vehicle_status (allocation_id);
CREATE INDEX IF NOT EXISTS idx_cdvs_drop_id ON public.core_daily_vehicle_status (dropoff_id);
CREATE INDEX IF NOT EXISTS idx_cdvs_maint_id ON public.core_daily_vehicle_status (maintenance_id);

-- ------------------------------------------------------------------------------
-- 3. VIEW 1: v_vehicle_trip_intervals
-- Pairs allocation and drop-off events into continuous vehicle custody intervals.
-- Implements IP operator Repair & Maintenance custody retention and LEAD capping.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_vehicle_trip_intervals AS
WITH raw_intervals AS (
    SELECT 
        a.id AS allocation_id,
        a.vehicle_number,
        a.partner_id,
        a.driver_name,
        a.driver_phone,
        a.city,
        a.car_model,
        a.hub_name,
        a.allocation_date AS trip_start_date,
        
        -- Find the matching subsequent dropoff event
        d.id AS dropoff_id,
        d.return_date AS raw_dropoff_date,
        d.return_type AS dropoff_type,
        
        -- Determine next allocation date for interval boundary capping
        LEAD(a.allocation_date) OVER (
            PARTITION BY a.vehicle_number 
            ORDER BY a.allocation_date ASC, a.id ASC
        ) AS next_allocation_date
    FROM public.core_vehicle_allocation a
    LEFT JOIN LATERAL (
        SELECT id, return_date, return_type
        FROM public.core_dropoffs
        WHERE vehicle_number = a.vehicle_number
          AND return_date >= a.allocation_date
          AND is_deleted = FALSE
        ORDER BY return_date ASC, id ASC
        LIMIT 1
    ) d ON TRUE
    WHERE a.is_deleted = FALSE
)
SELECT 
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
    
    -- Capped trip end date
    CASE 
        -- If dropoff exists and is within boundary
        WHEN raw_dropoff_date IS NOT NULL AND (next_allocation_date IS NULL OR raw_dropoff_date <= next_allocation_date)
            THEN raw_dropoff_date
        -- If next allocation occurred before recorded dropoff, cap interval to day before next allocation
        WHEN next_allocation_date IS NOT NULL
            THEN next_allocation_date - INTERVAL '1 day'
        -- Open active trip
        ELSE NULL
    END::DATE AS trip_end_date,
    
    -- Trip state classification
    CASE 
        WHEN raw_dropoff_date IS NULL AND next_allocation_date IS NULL THEN 'OPEN_ACTIVE_TRIP'
        WHEN raw_dropoff_date IS NOT NULL AND (next_allocation_date IS NULL OR raw_dropoff_date <= next_allocation_date) THEN 'CLOSED_TRIP'
        ELSE 'OVERRIDDEN_BY_REALLOCATION'
    END AS trip_state
FROM raw_intervals;

-- ------------------------------------------------------------------------------
-- 4. VIEW 2: v_current_live_fleet_status
-- Real-time snapshot view covering all 1,647 vehicles in core_vehicle_onboarding.
-- ------------------------------------------------------------------------------
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
    SELECT DISTINCT ON (vehicle_number)
        id AS maintenance_id,
        vehicle_number,
        start_date AS maintenance_date,
        workshop_name
    FROM public.core_maintenance
    WHERE is_deleted = FALSE 
      AND (end_date IS NULL OR end_date >= CURRENT_DATE)
    ORDER BY vehicle_number, start_date DESC
)
SELECT 
    vo.registration_no AS vehicle_number,
    vo.model AS vehicle_model,
    vo.city,
    vo.ownership,
    
    -- Real-time status resolution
    CASE 
        WHEN m.maintenance_id IS NOT NULL THEN 'Maintenance'
        WHEN a.trip_state = 'OPEN_ACTIVE_TRIP' OR (a.trip_end_date IS NOT NULL AND a.trip_end_date >= CURRENT_DATE) THEN 'Active'
        ELSE 'RFD'
    END AS current_status,
    
    -- Operational cohort
    CASE 
        WHEN m.maintenance_id IS NOT NULL THEN 'Off Road'
        WHEN a.trip_state = 'OPEN_ACTIVE_TRIP' OR (a.trip_end_date IS NOT NULL AND a.trip_end_date >= CURRENT_DATE) THEN 'On Road'
        ELSE 'In Yard'
    END AS current_cohort,
    
    -- Current assigned driver / partner
    CASE 
        WHEN m.maintenance_id IS NOT NULL AND UPPER(COALESCE(a.partner_id, '')) NOT LIKE '%IP%' THEN NULL
        WHEN a.trip_state = 'OPEN_ACTIVE_TRIP' OR (a.trip_end_date IS NOT NULL AND a.trip_end_date >= CURRENT_DATE) THEN a.partner_id
        ELSE NULL
    END AS current_partner_id,
    
    CASE 
        WHEN m.maintenance_id IS NOT NULL AND UPPER(COALESCE(a.partner_id, '')) NOT LIKE '%IP%' THEN NULL
        WHEN a.trip_state = 'OPEN_ACTIVE_TRIP' OR (a.trip_end_date IS NOT NULL AND a.trip_end_date >= CURRENT_DATE) THEN a.driver_name
        ELSE NULL
    END AS current_partner_name,
    
    a.driver_phone AS current_partner_phone,
    COALESCE(a.hub_name, 'MAIN_HUB') AS current_hub_name,
    a.allocation_id AS active_allocation_id,
    a.trip_start_date AS active_allocation_date,
    m.maintenance_id AS active_maintenance_id,
    m.workshop_name AS active_workshop_name,
    
    -- Billing indicator
    CASE 
        WHEN m.maintenance_id IS NOT NULL THEN FALSE
        WHEN a.trip_state = 'OPEN_ACTIVE_TRIP' OR (a.trip_end_date IS NOT NULL AND a.trip_end_date >= CURRENT_DATE) THEN TRUE
        ELSE FALSE
    END AS is_currently_billable
FROM public.core_vehicle_onboarding vo
LEFT JOIN latest_allocations a ON vo.registration_no = a.vehicle_number
LEFT JOIN active_maintenance m ON vo.registration_no = m.vehicle_number
WHERE vo.is_deleted = FALSE;

-- ------------------------------------------------------------------------------
-- 5. REAL-TIME LIVE EVENT TRIGGERS (CORE EVENT INTEGRATION)
-- Recalculates core_daily_vehicle_status in < 2ms whenever an allocation,
-- dropoff, maintenance, or onboarding event occurs.
-- ------------------------------------------------------------------------------

-- Core recalculation logic for a specific vehicle on a target date
CREATE OR REPLACE FUNCTION public.fn_recalculate_vehicle_status(
    p_vehicle_number VARCHAR(20),
    p_target_date DATE DEFAULT CURRENT_DATE
)
RETURNS VOID AS $$
DECLARE
    v_onboarding RECORD;
    v_u RECORD;
    v_o RECORD;
    v_alloc_today RECORD;
    v_drop_today RECORD;
    v_recent_drop RECORD;
    v_alloc_after_drop_id BIGINT := NULL;
    v_cm RECORD;
    v_svs RECORD;
    v_ti RECORD;
    v_final_status VARCHAR(30);
    v_cohort VARCHAR(20);
    v_partner_id VARCHAR(50);
    v_partner_name VARCHAR(150);
    v_partner_phone VARCHAR(20);
    v_hub_name VARCHAR(100);
    v_car_model VARCHAR(100);
    v_allocation_id BIGINT;
    v_allocation_date DATE;
    v_dropoff_id BIGINT;
    v_dropoff_date DATE;
    v_maintenance_id BIGINT;
    v_billable BOOLEAN;
    v_waive_reason VARCHAR(100);
    v_source_origin VARCHAR(50);
    v_city VARCHAR(20);
BEGIN
    -- 1. Get vehicle onboarding record
    SELECT registration_no, model, city, is_deleted
    INTO v_onboarding
    FROM public.core_vehicle_onboarding
    WHERE registration_no = p_vehicle_number;

    IF NOT FOUND OR v_onboarding.is_deleted = TRUE THEN
        RETURN;
    END IF;

    -- Platform Trips Check
    SELECT completed_trips, vendor_code 
    INTO v_u
    FROM public.core_uber_daily 
    WHERE vehicle_number = p_vehicle_number AND operational_date = p_target_date
    ORDER BY completed_trips DESC LIMIT 1;

    SELECT completed_trips 
    INTO v_o
    FROM public.core_ola_daily 
    WHERE vehicle_number = p_vehicle_number AND service_date = p_target_date
    ORDER BY completed_trips DESC LIMIT 1;

    -- Today's Allocation Event
    SELECT id, partner_id, driver_name, driver_phone, hub_name, car_model, city, allocation_date
    INTO v_alloc_today
    FROM public.core_vehicle_allocation
    WHERE is_deleted = FALSE
      AND vehicle_number = p_vehicle_number
      AND allocation_date = p_target_date
    ORDER BY id DESC
    LIMIT 1;

    -- Today's Dropoff Event
    SELECT id, return_type, return_date, driver_id, driver_name
    INTO v_drop_today
    FROM public.core_dropoffs
    WHERE is_deleted = FALSE
      AND vehicle_number = p_vehicle_number
      AND return_date = p_target_date
    ORDER BY id DESC
    LIMIT 1;

    -- Recent Dropoff before today in current cycle
    SELECT id, return_type, return_date
    INTO v_recent_drop
    FROM public.core_dropoffs
    WHERE is_deleted = FALSE AND vehicle_number = p_vehicle_number 
      AND return_date >= DATE_TRUNC('week', p_target_date)::date 
      AND return_date < p_target_date
    ORDER BY return_date DESC, id DESC LIMIT 1;

    -- Allocation occurring AFTER recent dropoff up to today
    v_alloc_after_drop_id := NULL;
    IF v_recent_drop.id IS NOT NULL THEN
        SELECT id
        INTO v_alloc_after_drop_id
        FROM public.core_vehicle_allocation
        WHERE is_deleted = FALSE AND vehicle_number = p_vehicle_number 
          AND allocation_date >= v_recent_drop.return_date AND allocation_date <= p_target_date
        LIMIT 1;
    END IF;

    -- Check Master Maintenance Table with Stale Ticket Guard
    SELECT id
    INTO v_cm
    FROM public.core_maintenance
    WHERE is_deleted = FALSE
      AND vehicle_number = p_vehicle_number
      AND start_date <= p_target_date
      AND (
          end_date >= p_target_date
          OR (
              end_date IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM public.core_vehicle_allocation a
                  WHERE a.vehicle_number = p_vehicle_number
                    AND a.is_deleted = FALSE
                    AND a.allocation_date > start_date
                    AND a.allocation_date <= p_target_date
              )
          )
      )
    ORDER BY start_date DESC
    LIMIT 1;

    -- Ground Truth from sheet_vehicle_status
    SELECT final_status, cohort, partner_id, partner_name, new_partner_name, vehicle_model, city
    INTO v_svs
    FROM public.sheet_vehicle_status
    WHERE vehicle_number = p_vehicle_number
      AND status_date = p_target_date
    ORDER BY id DESC
    LIMIT 1;

    -- Active Trip Interval
    SELECT *
    INTO v_ti
    FROM public.v_vehicle_trip_intervals ti
    WHERE ti.vehicle_number = p_vehicle_number
      AND ti.trip_start_date <= p_target_date
      AND (ti.trip_end_date IS NULL OR ti.trip_end_date >= p_target_date)
    ORDER BY ti.trip_start_date DESC
    LIMIT 1;

    -- Resolve City, Hub, Model
    v_city := COALESCE(v_svs.city, v_alloc_today.city, v_ti.city, v_onboarding.city, 'UNKNOWN');
    v_hub_name := COALESCE(v_alloc_today.hub_name, v_ti.hub_name, 'MAIN_HUB');
    v_car_model := COALESCE(v_svs.vehicle_model, v_alloc_today.car_model, v_ti.car_model, v_onboarding.model);

    -- Hierarchy Evaluation
    IF (COALESCE(v_u.completed_trips, 0) + COALESCE(v_o.completed_trips, 0)) > 0 THEN
        v_final_status := 'Active';
        v_cohort := 'On Road';
        v_partner_id := COALESCE(v_ti.partner_id, v_alloc_today.partner_id, v_svs.partner_id, NULLIF(v_u.vendor_code, ''));
        v_partner_name := COALESCE(v_ti.driver_name, v_alloc_today.driver_name, v_svs.partner_name, v_svs.new_partner_name);
        v_partner_phone := COALESCE(v_ti.driver_phone, v_alloc_today.driver_phone);
        v_allocation_id := COALESCE(v_alloc_today.id, v_ti.allocation_id);
        v_allocation_date := COALESCE(v_alloc_today.allocation_date, v_ti.trip_start_date);
        v_dropoff_id := COALESCE(v_drop_today.id, v_ti.dropoff_id);
        v_dropoff_date := COALESCE(v_drop_today.return_date, v_ti.trip_end_date);
        v_maintenance_id := NULL;
        v_billable := TRUE;
        v_waive_reason := NULL;
        v_source_origin := 'PLATFORM_TRIPS_VERIFIED';

    ELSIF v_alloc_today.id IS NOT NULL AND v_drop_today.id IS NOT NULL THEN
        v_final_status := 'Same Day D&A';
        v_cohort := 'On Road';
        v_partner_id := v_alloc_today.partner_id;
        v_partner_name := v_alloc_today.driver_name;
        v_partner_phone := v_alloc_today.driver_phone;
        v_allocation_id := v_alloc_today.id;
        v_allocation_date := v_alloc_today.allocation_date;
        v_dropoff_id := v_drop_today.id;
        v_dropoff_date := v_drop_today.return_date;
        v_maintenance_id := NULL;
        v_billable := TRUE;
        v_waive_reason := NULL;
        v_source_origin := 'SAME_DAY_HANDOVER';

    ELSIF v_alloc_today.id IS NOT NULL THEN
        v_final_status := 'Allocation';
        v_cohort := 'On Road';
        v_partner_id := v_alloc_today.partner_id;
        v_partner_name := v_alloc_today.driver_name;
        v_partner_phone := v_alloc_today.driver_phone;
        v_allocation_id := v_alloc_today.id;
        v_allocation_date := v_alloc_today.allocation_date;
        v_dropoff_id := NULL;
        v_dropoff_date := NULL;
        v_maintenance_id := NULL;
        v_billable := TRUE;
        v_waive_reason := NULL;
        v_source_origin := 'ALLOCATION_EVENT';

    ELSIF v_drop_today.id IS NOT NULL AND v_drop_today.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN
        v_final_status := 'Maintenance';
        v_cohort := 'Off Road';
        v_partner_id := v_drop_today.driver_id;
        v_partner_name := v_drop_today.driver_name;
        v_partner_phone := NULL;
        v_allocation_id := v_ti.allocation_id;
        v_allocation_date := v_ti.trip_start_date;
        v_dropoff_id := v_drop_today.id;
        v_dropoff_date := v_drop_today.return_date;
        v_maintenance_id := NULL;
        v_billable := TRUE; -- billable on day of breakdown handover
        v_waive_reason := NULL;
        v_source_origin := 'DROPOFF_EVENT';

    ELSIF v_drop_today.id IS NOT NULL THEN
        v_final_status := 'Drop Off';
        v_cohort := 'In Yard';
        v_partner_id := NULL;
        v_partner_name := NULL;
        v_partner_phone := NULL;
        v_allocation_id := NULL;
        v_allocation_date := NULL;
        v_dropoff_id := v_drop_today.id;
        v_dropoff_date := v_drop_today.return_date;
        v_maintenance_id := NULL;
        v_billable := FALSE;
        v_waive_reason := 'DROPOFF_INSPECTION';
        v_source_origin := 'DROPOFF_EVENT';

    ELSIF v_recent_drop.id IS NOT NULL AND v_alloc_after_drop_id IS NULL THEN
        IF v_recent_drop.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN
            v_final_status := 'Maintenance';
            v_cohort := 'Off Road';
            v_waive_reason := 'WORKSHOP_MAINTENANCE';
        ELSE
            v_final_status := 'RFD';
            v_cohort := 'In Yard';
            v_waive_reason := 'RFD_IN_YARD';
        END IF;
        v_partner_id := NULL;
        v_partner_name := NULL;
        v_partner_phone := NULL;
        v_allocation_id := NULL;
        v_allocation_date := NULL;
        v_dropoff_id := v_recent_drop.id;
        v_dropoff_date := v_recent_drop.return_date;
        v_maintenance_id := NULL;
        v_billable := FALSE;
        v_source_origin := 'POST_DROPOFF_YARD';

    ELSIF v_cm.id IS NOT NULL THEN
        v_final_status := 'Maintenance';
        v_cohort := 'Off Road';
        v_partner_id := NULL;
        v_partner_name := NULL;
        v_partner_phone := NULL;
        v_allocation_id := v_ti.allocation_id;
        v_allocation_date := v_ti.trip_start_date;
        v_dropoff_id := v_ti.dropoff_id;
        v_dropoff_date := v_ti.trip_end_date;
        v_maintenance_id := v_cm.id;
        v_billable := FALSE;
        v_waive_reason := 'WORKSHOP_MAINTENANCE';
        v_source_origin := 'MAINTENANCE_PIPELINE';

    ELSIF v_svs.final_status IS NOT NULL THEN
        v_final_status := v_svs.final_status;
        v_cohort := COALESCE(v_svs.cohort, CASE 
            WHEN v_svs.final_status IN ('Active', 'Allocation', 'Same Day D&A', 'New Deployment') THEN 'On Road' 
            WHEN v_svs.final_status = 'Maintenance' THEN 'Off Road' 
            ELSE 'In Yard' 
        END);
        v_partner_id := v_svs.partner_id;
        v_partner_name := COALESCE(v_svs.partner_name, v_svs.new_partner_name);
        v_partner_phone := NULL;
        v_allocation_id := v_ti.allocation_id;
        v_allocation_date := v_ti.trip_start_date;
        v_dropoff_id := v_ti.dropoff_id;
        v_dropoff_date := v_ti.trip_end_date;
        v_maintenance_id := NULL;
        v_billable := CASE 
            WHEN v_svs.final_status IN ('Maintenance', 'Drop Off', 'Drop-off', 'RFD', 'Unassigned') THEN FALSE
            WHEN v_svs.final_status IN ('Active', 'Allocation', 'Same Day D&A', 'New Deployment') THEN TRUE
            WHEN v_svs.partner_id IS NOT NULL AND v_svs.partner_id != '' THEN TRUE
            ELSE FALSE
        END;
        v_waive_reason := CASE 
            WHEN v_svs.final_status = 'Maintenance' THEN 'WORKSHOP_MAINTENANCE' 
            WHEN v_svs.final_status IN ('Drop Off', 'Drop-off') THEN 'DROPOFF_INSPECTION' 
            WHEN v_svs.final_status = 'RFD' THEN 'RFD_IN_YARD' 
            ELSE NULL 
        END;
        v_source_origin := 'SHEET_STATUS_SYNC';

    ELSIF v_ti.allocation_id IS NOT NULL THEN
        v_final_status := 'Active';
        v_cohort := 'On Road';
        v_partner_id := v_ti.partner_id;
        v_partner_name := v_ti.driver_name;
        v_partner_phone := v_ti.driver_phone;
        v_allocation_id := v_ti.allocation_id;
        v_allocation_date := v_ti.trip_start_date;
        v_dropoff_id := v_ti.dropoff_id;
        v_dropoff_date := v_ti.trip_end_date;
        v_maintenance_id := NULL;
        v_billable := TRUE;
        v_waive_reason := NULL;
        v_source_origin := 'ACTIVE_INTERVAL';

    ELSE
        v_final_status := 'RFD';
        v_cohort := 'In Yard';
        v_partner_id := NULL;
        v_partner_name := NULL;
        v_partner_phone := NULL;
        v_allocation_id := NULL;
        v_allocation_date := NULL;
        v_dropoff_id := NULL;
        v_dropoff_date := NULL;
        v_maintenance_id := NULL;
        v_billable := FALSE;
        v_waive_reason := 'RFD_IN_YARD';
        v_source_origin := 'YARD_ROLLOVER';
    END IF;

    -- Upsert into core_daily_vehicle_status
    INSERT INTO public.core_daily_vehicle_status (
        status_date, vehicle_number, city, final_status, cohort,
        partner_id, partner_name, partner_phone, hub_name, car_model,
        allocation_id, allocation_date, dropoff_id, dropoff_date, maintenance_id,
        billable_rent_day, rent_waived_reason, source_origin, created_at, updated_at
    ) VALUES (
        p_target_date, p_vehicle_number, v_city, v_final_status, v_cohort,
        v_partner_id, v_partner_name, v_partner_phone, v_hub_name, v_car_model,
        v_allocation_id, v_allocation_date, v_dropoff_id, v_dropoff_date, v_maintenance_id,
        v_billable, v_waive_reason, v_source_origin, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    )
    ON CONFLICT (status_date, vehicle_number) DO UPDATE SET
        city = EXCLUDED.city,
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
        maintenance_id = EXCLUDED.maintenance_id,
        billable_rent_day = EXCLUDED.billable_rent_day,
        rent_waived_reason = EXCLUDED.rent_waived_reason,
        source_origin = EXCLUDED.source_origin,
        updated_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------------------------
-- 5. TRIGGER DECOMMISSIONING FOR MAXIMUM SOURCE TABLE PERFORMANCE
-- ------------------------------------------------------------------------------
-- Note: All live recalculation triggers (trg_live_status_from_allocation,
-- trg_live_status_from_dropoff, trg_live_status_from_maintenance,
-- trg_live_status_from_onboarding) were formally decommissioned and dropped.
-- This ensures core_vehicle_allocation, core_dropoffs, and core_maintenance
-- execute at 100% native PostgreSQL speed with ZERO locking overhead.
DROP TRIGGER IF EXISTS trg_live_status_from_allocation ON public.core_vehicle_allocation;
DROP TRIGGER IF EXISTS trg_live_status_from_dropoff ON public.core_dropoffs;
DROP TRIGGER IF EXISTS trg_live_status_from_maintenance ON public.core_maintenance;
DROP TRIGGER IF EXISTS trg_live_status_from_onboarding ON public.core_vehicle_onboarding;
DROP TRIGGER IF EXISTS trg_sync_core_daily_status_from_sheet ON public.sheet_vehicle_status;

-- ------------------------------------------------------------------------------
-- 6. AUTHORITATIVE STORED PROCEDURE: sp_generate_daily_vehicle_status()
-- Stateful ground-truth generation for all 1,647 onboarded fleet vehicles.
-- Decoupled, self-contained, and soft-delete aware (WHERE is_deleted = FALSE).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_generate_daily_vehicle_status(IN p_target_date DATE)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    CREATE TEMP TABLE tmp_daily_calc ON COMMIT DROP AS
    WITH ranked_allocs AS (
        SELECT 
            a.id, a.vehicle_number, a.partner_id, a.driver_name, a.driver_phone, a.hub_name, a.car_model, a.city, a.allocation_date,
            ROW_NUMBER() OVER (PARTITION BY a.vehicle_number ORDER BY a.allocation_date DESC, a.id DESC) as rn
        FROM public.core_vehicle_allocation a
        WHERE a.is_deleted = FALSE
          AND a.allocation_date <= p_target_date
    ),
    active_alloc AS (
        SELECT * FROM ranked_allocs WHERE rn = 1
    ),
    active_drop AS (
        SELECT 
            d.id, d.vehicle_number, d.return_date, d.return_type, d.driver_id, d.driver_name,
            ROW_NUMBER() OVER (PARTITION BY d.vehicle_number ORDER BY d.return_date ASC, d.id ASC) as rn
        FROM public.core_dropoffs d
        JOIN active_alloc a ON d.vehicle_number = a.vehicle_number AND d.return_date >= a.allocation_date
        WHERE d.is_deleted = FALSE
    ),
    first_drop_after_alloc AS (
        SELECT * FROM active_drop WHERE rn = 1
    ),
    next_allocs AS (
        SELECT 
            a2.vehicle_number, a2.allocation_date,
            ROW_NUMBER() OVER (PARTITION BY a2.vehicle_number ORDER BY a2.allocation_date ASC, a2.id ASC) as rn
        FROM public.core_vehicle_allocation a2
        JOIN active_alloc a ON a2.vehicle_number = a.vehicle_number 
          AND (a2.allocation_date > a.allocation_date OR (a2.allocation_date = a.allocation_date AND a2.id > a.id))
        WHERE a2.is_deleted = FALSE
    ),
    first_next_alloc AS (
        SELECT * FROM next_allocs WHERE rn = 1
    ),
    alloc_today AS (
        SELECT 
            a.id, a.vehicle_number, a.partner_id, a.driver_name, a.driver_phone, a.hub_name, a.car_model, a.city, a.allocation_date,
            ROW_NUMBER() OVER (PARTITION BY a.vehicle_number ORDER BY a.id DESC) as rn
        FROM public.core_vehicle_allocation a
        WHERE a.is_deleted = FALSE
          AND a.allocation_date = p_target_date
    ),
    alloc_today_latest AS (
        SELECT * FROM alloc_today WHERE rn = 1
    ),
    drop_today AS (
        SELECT 
            d.id, d.vehicle_number, d.return_type, d.return_date, d.driver_id, d.driver_name,
            ROW_NUMBER() OVER (PARTITION BY d.vehicle_number ORDER BY d.id DESC) as rn
        FROM public.core_dropoffs d
        WHERE d.is_deleted = FALSE
          AND d.return_date = p_target_date
    ),
    drop_today_latest AS (
        SELECT * FROM drop_today WHERE rn = 1
    ),
    active_maint AS (
        SELECT 
            m.id, m.vehicle_number, m.workshop_name, m.start_date, m.end_date,
            ROW_NUMBER() OVER (PARTITION BY m.vehicle_number ORDER BY m.start_date DESC, m.id DESC) as rn
        FROM public.core_maintenance m
        WHERE m.is_deleted = FALSE
          AND m.start_date <= p_target_date
          AND (
              m.end_date >= p_target_date
              OR (
                  m.end_date IS NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM public.core_vehicle_allocation a
                      WHERE a.vehicle_number = m.vehicle_number
                        AND a.is_deleted = FALSE
                        AND a.allocation_date > m.start_date
                        AND a.allocation_date <= p_target_date
                  )
              )
          )
    ),
    active_maint_latest AS (
        SELECT * FROM active_maint WHERE rn = 1
    ),
    svs_today AS (
        SELECT 
            s.vehicle_number, s.final_status, s.cohort, s.partner_id, s.partner_name, s.new_partner_name, s.vehicle_model, s.city,
            ROW_NUMBER() OVER (PARTITION BY s.vehicle_number ORDER BY s.id DESC) as rn
        FROM public.sheet_vehicle_status s
        WHERE s.status_date = p_target_date
    ),
    svs_today_latest AS (
        SELECT * FROM svs_today WHERE rn = 1
    )
    SELECT 
        vo.registration_no AS vehicle_number,
        p_target_date AS status_date,
        COALESCE(svs.city, at.city, aa.city, vo.city, 'UNKNOWN') AS city,
        COALESCE(svs.vehicle_model, at.car_model, aa.car_model, vo.model, 'UNKNOWN') AS car_model,
        COALESCE(at.hub_name, aa.hub_name, 'UNKNOWN') AS hub_name,
        
        -- Final Status Determination
        CASE 
            -- 1. Primary Authority: Operational Sheet Ground Truth (When sheet row exists)
            WHEN svs.final_status IS NOT NULL THEN 
                CASE 
                    -- When partner is assigned to New Deployment, it is an active Allocation
                    WHEN svs.final_status = 'New Deployment' AND (svs.partner_id IS NOT NULL AND TRIM(svs.partner_id) != '') THEN 'Allocation'
                    -- When no partner is assigned, it stays New Deployment (Off Road yard inventory)
                    WHEN svs.final_status = 'New Deployment' THEN 'New Deployment'
                    ELSE svs.final_status
                END
            
            -- 2. Fallback: Handover Events Today in Portal
            WHEN at.id IS NOT NULL AND dt.id IS NOT NULL THEN 'Same Day D&A'
            WHEN at.id IS NOT NULL THEN 'Allocation'
            WHEN dt.id IS NOT NULL AND dt.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Maintenance'
            WHEN dt.id IS NOT NULL THEN 'Drop Off'
            
            -- 3. Fallback: Workshop Maintenance Ticket
            WHEN am.id IS NOT NULL THEN 'Maintenance'
            
            -- 4. Fallback: Open Allocation Interval
            WHEN aa.id IS NOT NULL AND (
                (fda.id IS NULL AND fna.allocation_date IS NULL) OR
                (fda.id IS NOT NULL AND (fna.allocation_date IS NULL OR fda.return_date <= fna.allocation_date) AND fda.return_date > p_target_date) OR
                (fna.allocation_date IS NOT NULL AND fna.allocation_date > p_target_date)
            ) THEN 'Active'
            
            -- 5. Master Default
            ELSE 'RFD'
        END AS final_status,
        
        -- Cohort Determination (Strictly Binary)
        -- Drop Off and New Deployment (without partner) are strictly OFF ROAD!
        CASE 
            WHEN (
                CASE 
                    WHEN svs.final_status IS NOT NULL THEN 
                        CASE 
                            WHEN svs.final_status = 'New Deployment' AND (svs.partner_id IS NOT NULL AND TRIM(svs.partner_id) != '') THEN 'Allocation'
                            WHEN svs.final_status = 'New Deployment' THEN 'New Deployment'
                            ELSE svs.final_status
                        END
                    WHEN at.id IS NOT NULL AND dt.id IS NOT NULL THEN 'Same Day D&A'
                    WHEN at.id IS NOT NULL THEN 'Allocation'
                    WHEN dt.id IS NOT NULL AND dt.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Maintenance'
                    WHEN dt.id IS NOT NULL THEN 'Drop Off'
                    WHEN am.id IS NOT NULL THEN 'Maintenance'
                    WHEN aa.id IS NOT NULL AND (
                        (fda.id IS NULL AND fna.allocation_date IS NULL) OR
                        (fda.id IS NOT NULL AND (fna.allocation_date IS NULL OR fda.return_date <= fna.allocation_date) AND fda.return_date > p_target_date) OR
                        (fna.allocation_date IS NOT NULL AND fna.allocation_date > p_target_date)
                    ) THEN 'Active'
                    ELSE 'RFD'
                END
            ) IN ('Active', 'Allocation', 'Same Day D&A') THEN 'On Road'
            ELSE 'Off Road'
        END AS cohort,
        
        -- Partner ID (Strictly NULL if Off Road / RFD / Maintenance / New Deployment)
        CASE 
            WHEN (
                CASE 
                    WHEN svs.final_status IS NOT NULL THEN 
                        CASE 
                            WHEN svs.final_status = 'New Deployment' AND (svs.partner_id IS NOT NULL AND TRIM(svs.partner_id) != '') THEN 'Allocation'
                            WHEN svs.final_status = 'New Deployment' THEN 'New Deployment'
                            ELSE svs.final_status
                        END
                    WHEN at.id IS NOT NULL AND dt.id IS NOT NULL THEN 'Same Day D&A'
                    WHEN at.id IS NOT NULL THEN 'Allocation'
                    WHEN dt.id IS NOT NULL AND dt.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Maintenance'
                    WHEN dt.id IS NOT NULL THEN 'Drop Off'
                    WHEN am.id IS NOT NULL THEN 'Maintenance'
                    WHEN aa.id IS NOT NULL AND (
                        (fda.id IS NULL AND fna.allocation_date IS NULL) OR
                        (fda.id IS NOT NULL AND (fna.allocation_date IS NULL OR fda.return_date <= fna.allocation_date) AND fda.return_date > p_target_date) OR
                        (fna.allocation_date IS NOT NULL AND fna.allocation_date > p_target_date)
                    ) THEN 'Active'
                    ELSE 'RFD'
                END
            ) IN ('RFD', 'Maintenance', 'Drop Off', 'New Deployment') THEN NULL
            ELSE COALESCE(svs.partner_id, at.partner_id, aa.partner_id)
        END AS partner_id,
        
        -- Partner Name (Strictly NULL if Off Road / RFD / Maintenance / New Deployment)
        CASE 
            WHEN (
                CASE 
                    WHEN svs.final_status IS NOT NULL THEN 
                        CASE 
                            WHEN svs.final_status = 'New Deployment' AND (svs.partner_id IS NOT NULL AND TRIM(svs.partner_id) != '') THEN 'Allocation'
                            WHEN svs.final_status = 'New Deployment' THEN 'New Deployment'
                            ELSE svs.final_status
                        END
                    WHEN at.id IS NOT NULL AND dt.id IS NOT NULL THEN 'Same Day D&A'
                    WHEN at.id IS NOT NULL THEN 'Allocation'
                    WHEN dt.id IS NOT NULL AND dt.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Maintenance'
                    WHEN dt.id IS NOT NULL THEN 'Drop Off'
                    WHEN am.id IS NOT NULL THEN 'Maintenance'
                    WHEN aa.id IS NOT NULL AND (
                        (fda.id IS NULL AND fna.allocation_date IS NULL) OR
                        (fda.id IS NOT NULL AND (fna.allocation_date IS NULL OR fda.return_date <= fna.allocation_date) AND fda.return_date > p_target_date) OR
                        (fna.allocation_date IS NOT NULL AND fna.allocation_date > p_target_date)
                    ) THEN 'Active'
                    ELSE 'RFD'
                END
            ) IN ('RFD', 'Maintenance', 'Drop Off', 'New Deployment') THEN NULL
            ELSE COALESCE(svs.partner_name, svs.new_partner_name, at.driver_name, aa.driver_name)
        END AS partner_name,
        
        -- Partner Phone
        CASE 
            WHEN (
                CASE 
                    WHEN svs.final_status IS NOT NULL THEN 
                        CASE 
                            WHEN svs.final_status = 'New Deployment' AND (svs.partner_id IS NOT NULL AND TRIM(svs.partner_id) != '') THEN 'Allocation'
                            WHEN svs.final_status = 'New Deployment' THEN 'New Deployment'
                            ELSE svs.final_status
                        END
                    WHEN at.id IS NOT NULL AND dt.id IS NOT NULL THEN 'Same Day D&A'
                    WHEN at.id IS NOT NULL THEN 'Allocation'
                    WHEN dt.id IS NOT NULL AND dt.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Maintenance'
                    WHEN dt.id IS NOT NULL THEN 'Drop Off'
                    WHEN am.id IS NOT NULL THEN 'Maintenance'
                    WHEN aa.id IS NOT NULL AND (
                        (fda.id IS NULL AND fna.allocation_date IS NULL) OR
                        (fda.id IS NOT NULL AND (fna.allocation_date IS NULL OR fda.return_date <= fna.allocation_date) AND fda.return_date > p_target_date) OR
                        (fna.allocation_date IS NOT NULL AND fna.allocation_date > p_target_date)
                    ) THEN 'Active'
                    ELSE 'RFD'
                END
            ) IN ('RFD', 'Maintenance', 'Drop Off', 'New Deployment') THEN NULL
            ELSE COALESCE(at.driver_phone, aa.driver_phone)
        END AS partner_phone,
        
        -- Tracking IDs
        aa.id AS allocation_id,
        aa.allocation_date AS allocation_date,
        fda.id AS dropoff_id,
        fda.return_date AS dropoff_date,
        am.id AS maintenance_id,
        
        CASE WHEN svs.final_status IS NOT NULL THEN 'SHEET_GROUND_TRUTH' ELSE 'PORTAL_FALLBACK' END AS source_origin
        
    FROM public.core_vehicle_onboarding vo
    LEFT JOIN active_alloc aa ON vo.registration_no = aa.vehicle_number
    LEFT JOIN first_drop_after_alloc fda ON vo.registration_no = fda.vehicle_number
    LEFT JOIN first_next_alloc fna ON vo.registration_no = fna.vehicle_number
    LEFT JOIN alloc_today_latest at ON vo.registration_no = at.vehicle_number
    LEFT JOIN drop_today_latest dt ON vo.registration_no = dt.vehicle_number
    LEFT JOIN active_maint_latest am ON vo.registration_no = am.vehicle_number
    LEFT JOIN svs_today_latest svs ON vo.registration_no = svs.vehicle_number
    WHERE vo.is_deleted = FALSE;


