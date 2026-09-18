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

-- Trigger on core_vehicle_allocation

-- Trigger on core_vehicle_allocation
CREATE OR REPLACE FUNCTION public.fn_trg_live_status_from_allocation()
RETURNS TRIGGER AS $$
DECLARE
    v_veh VARCHAR(20);
    v_date DATE;
BEGIN
    v_veh := COALESCE(NEW.vehicle_number, OLD.vehicle_number);
    v_date := COALESCE(NEW.allocation_date, OLD.allocation_date);
    
    IF v_veh IS NOT NULL THEN
        PERFORM public.fn_recalculate_vehicle_status(v_veh, CURRENT_DATE);
        IF v_date IS NOT NULL AND v_date != CURRENT_DATE THEN
            PERFORM public.fn_recalculate_vehicle_status(v_veh, v_date);
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_live_status_from_allocation ON public.core_vehicle_allocation;
CREATE TRIGGER trg_live_status_from_allocation
AFTER INSERT OR UPDATE OR DELETE ON public.core_vehicle_allocation
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_live_status_from_allocation();

-- Trigger on core_dropoffs
CREATE OR REPLACE FUNCTION public.fn_trg_live_status_from_dropoff()
RETURNS TRIGGER AS $$
DECLARE
    v_veh VARCHAR(20);
    v_date DATE;
BEGIN
    v_veh := COALESCE(NEW.vehicle_number, OLD.vehicle_number);
    v_date := COALESCE(NEW.return_date, OLD.return_date);
    
    IF v_veh IS NOT NULL THEN
        PERFORM public.fn_recalculate_vehicle_status(v_veh, CURRENT_DATE);
        IF v_date IS NOT NULL AND v_date != CURRENT_DATE THEN
            PERFORM public.fn_recalculate_vehicle_status(v_veh, v_date);
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_live_status_from_dropoff ON public.core_dropoffs;
CREATE TRIGGER trg_live_status_from_dropoff
AFTER INSERT OR UPDATE OR DELETE ON public.core_dropoffs
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_live_status_from_dropoff();

-- Trigger on core_maintenance
CREATE OR REPLACE FUNCTION public.fn_trg_live_status_from_maintenance()
RETURNS TRIGGER AS $$
DECLARE
    v_veh VARCHAR(20);
BEGIN
    v_veh := COALESCE(NEW.vehicle_number, OLD.vehicle_number);
    
    IF v_veh IS NOT NULL THEN
        PERFORM public.fn_recalculate_vehicle_status(v_veh, CURRENT_DATE);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_live_status_from_maintenance ON public.core_maintenance;
CREATE TRIGGER trg_live_status_from_maintenance
AFTER INSERT OR UPDATE OR DELETE ON public.core_maintenance
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_live_status_from_maintenance();

-- Trigger on core_vehicle_onboarding
CREATE OR REPLACE FUNCTION public.fn_trg_live_status_from_onboarding()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.registration_no IS NOT NULL AND NEW.is_deleted = FALSE THEN
        PERFORM public.fn_recalculate_vehicle_status(NEW.registration_no, CURRENT_DATE);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_live_status_from_onboarding ON public.core_vehicle_onboarding;
CREATE TRIGGER trg_live_status_from_onboarding
AFTER INSERT OR UPDATE ON public.core_vehicle_onboarding
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_live_status_from_onboarding();

-- Note: Legacy Google Sheet sync trigger trg_sync_core_daily_status_from_sheet 
-- on public.sheet_vehicle_status was explicitly decommissioned and dropped to 
-- guarantee that spreadsheet operations cannot overwrite live relational calculations.


-- ------------------------------------------------------------------------------
-- 6. STORED PROCEDURE: sp_generate_daily_vehicle_status()
-- Stateful ground-truth generation for all 1,647 onboarded fleet vehicles.
-- Uses PostgreSQL 18+ MERGE to prevent sequence burning.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_generate_daily_vehicle_status(IN p_target_date DATE)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    MERGE INTO public.core_daily_vehicle_status AS target
    USING (
        SELECT 
            p_target_date AS status_date,
            vo.registration_no AS vehicle_number,
            COALESCE(svs.city, ti.city, vo.city, 'UNKNOWN') AS city,
            
            -- Operational Status Classification (Trip Override & Event Hierarchy)
            CASE 
                WHEN (COALESCE(u.completed_trips, 0) + COALESCE(o.completed_trips, 0)) > 0 THEN 'Active'
                WHEN alloc_today.id IS NOT NULL AND drop_today.id IS NOT NULL THEN 'Same Day D&A'
                WHEN alloc_today.id IS NOT NULL THEN 'Allocation'
                WHEN drop_today.id IS NOT NULL AND drop_today.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Maintenance'
                WHEN drop_today.id IS NOT NULL THEN 'Drop Off'
                WHEN recent_drop.id IS NOT NULL AND (alloc_after_drop.id IS NULL) THEN
                    CASE WHEN recent_drop.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Maintenance' ELSE 'RFD' END
                WHEN cm.id IS NOT NULL THEN 'Maintenance'
                WHEN svs.final_status IS NOT NULL THEN svs.final_status
                WHEN ti.allocation_id IS NOT NULL THEN 'Active'
                ELSE 'RFD'
            END AS final_status,
            
            -- Cohort Classification
            CASE 
                WHEN (COALESCE(u.completed_trips, 0) + COALESCE(o.completed_trips, 0)) > 0 THEN 'On Road'
                WHEN alloc_today.id IS NOT NULL AND drop_today.id IS NOT NULL THEN 'On Road'
                WHEN alloc_today.id IS NOT NULL THEN 'On Road'
                WHEN drop_today.id IS NOT NULL AND drop_today.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Off Road'
                WHEN drop_today.id IS NOT NULL THEN 'In Yard'
                WHEN recent_drop.id IS NOT NULL AND (alloc_after_drop.id IS NULL) THEN
                    CASE WHEN recent_drop.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'Off Road' ELSE 'In Yard' END
                WHEN cm.id IS NOT NULL THEN 'Off Road'
                WHEN svs.final_status IS NOT NULL THEN 
                    COALESCE(svs.cohort, CASE 
                        WHEN svs.final_status IN ('Active', 'Allocation', 'Same Day D&A', 'New Deployment') THEN 'On Road' 
                        WHEN svs.final_status = 'Maintenance' THEN 'Off Road' 
                        ELSE 'In Yard' 
                    END)
                WHEN ti.allocation_id IS NOT NULL THEN 'On Road'
                ELSE 'In Yard'
            END AS cohort,
            
            -- Partner ID Assignment
            CASE 
                WHEN recent_drop.id IS NOT NULL AND (alloc_after_drop.id IS NULL) THEN NULL
                WHEN alloc_today.id IS NOT NULL THEN alloc_today.partner_id
                WHEN drop_today.id IS NOT NULL THEN drop_today.driver_id
                WHEN svs.partner_id IS NOT NULL AND svs.partner_id != '' THEN svs.partner_id
                WHEN ti.allocation_id IS NOT NULL THEN ti.partner_id
                WHEN (COALESCE(u.completed_trips, 0) + COALESCE(o.completed_trips, 0)) > 0 THEN 
                    NULLIF(u.vendor_code, '')
                ELSE NULL
            END AS partner_id,
            
            -- Partner Name Assignment
            CASE 
                WHEN recent_drop.id IS NOT NULL AND (alloc_after_drop.id IS NULL) THEN NULL
                WHEN alloc_today.id IS NOT NULL THEN alloc_today.driver_name
                WHEN drop_today.id IS NOT NULL THEN drop_today.driver_name
                WHEN svs.partner_id IS NOT NULL AND svs.partner_id != '' THEN COALESCE(svs.partner_name, svs.new_partner_name)
                WHEN ti.allocation_id IS NOT NULL THEN ti.driver_name
                ELSE NULL
            END AS partner_name,
            
            -- Partner Phone Assignment
            CASE 
                WHEN recent_drop.id IS NOT NULL AND (alloc_after_drop.id IS NULL) THEN NULL
                WHEN alloc_today.id IS NOT NULL THEN alloc_today.driver_phone
                WHEN ti.allocation_id IS NOT NULL THEN ti.driver_phone
                ELSE NULL
            END AS partner_phone,
            
            COALESCE(alloc_today.hub_name, ti.hub_name, 'MAIN_HUB') AS hub_name,
            COALESCE(svs.vehicle_model, alloc_today.car_model, ti.car_model, vo.model) AS car_model,
            COALESCE(alloc_today.id, ti.allocation_id) AS allocation_id,
            COALESCE(alloc_today.allocation_date, ti.trip_start_date) AS allocation_date,
            COALESCE(drop_today.id, ti.dropoff_id) AS dropoff_id,
            COALESCE(drop_today.return_date, ti.trip_end_date) AS dropoff_date,
            cm.id AS maintenance_id,
            
            -- Billing Flag
            CASE 
                WHEN (COALESCE(u.completed_trips, 0) + COALESCE(o.completed_trips, 0)) > 0 THEN TRUE
                WHEN recent_drop.id IS NOT NULL AND (alloc_after_drop.id IS NULL) THEN FALSE
                WHEN alloc_today.id IS NOT NULL THEN TRUE
                WHEN drop_today.id IS NOT NULL AND drop_today.return_type NOT IN ('Attrition', 'Force Recovery', 'Non-payment / Default', 'Voluntary Return') THEN TRUE
                WHEN drop_today.id IS NOT NULL THEN FALSE
                WHEN cm.id IS NOT NULL THEN FALSE
                WHEN svs.final_status IS NOT NULL THEN
                    CASE 
                        WHEN svs.final_status IN ('Maintenance', 'Drop Off', 'Drop-off', 'RFD', 'Unassigned') THEN FALSE
                        WHEN svs.final_status IN ('Active', 'Allocation', 'Same Day D&A', 'New Deployment') THEN TRUE
                        WHEN svs.partner_id IS NOT NULL AND svs.partner_id != '' THEN TRUE
                        ELSE FALSE
                    END
                WHEN ti.allocation_id IS NOT NULL THEN TRUE
                ELSE FALSE
            END AS billable_rent_day,
            
            -- Rent Waived Reason
            CASE 
                WHEN (COALESCE(u.completed_trips, 0) + COALESCE(o.completed_trips, 0)) > 0 THEN NULL
                WHEN recent_drop.id IS NOT NULL AND (alloc_after_drop.id IS NULL) THEN
                    CASE WHEN recent_drop.return_type IN ('Repair and Maintenance', 'Vehicle Breakdown / Maintenance') THEN 'WORKSHOP_MAINTENANCE' ELSE 'RFD_IN_YARD' END
                WHEN cm.id IS NOT NULL THEN 'WORKSHOP_MAINTENANCE'
                WHEN drop_today.id IS NOT NULL THEN 'DROPOFF_INSPECTION'
                WHEN svs.final_status = 'Maintenance' THEN 'WORKSHOP_MAINTENANCE' 
                WHEN svs.final_status IN ('Drop Off', 'Drop-off') THEN 'DROPOFF_INSPECTION' 
                WHEN svs.final_status = 'RFD' THEN 'RFD_IN_YARD' 
                WHEN ti.allocation_id IS NULL THEN 'RFD_IN_YARD'
                ELSE NULL
            END AS rent_waived_reason,
            
            -- Provenance Source Origin
            CASE 
                WHEN (COALESCE(u.completed_trips, 0) + COALESCE(o.completed_trips, 0)) > 0 THEN 'PLATFORM_TRIPS_VERIFIED'
                WHEN alloc_today.id IS NOT NULL AND drop_today.id IS NOT NULL THEN 'SAME_DAY_HANDOVER'
                WHEN alloc_today.id IS NOT NULL THEN 'ALLOCATION_EVENT'
                WHEN drop_today.id IS NOT NULL THEN 'DROPOFF_EVENT'
                WHEN recent_drop.id IS NOT NULL AND (alloc_after_drop.id IS NULL) THEN 'POST_DROPOFF_YARD'
                WHEN cm.id IS NOT NULL THEN 'MAINTENANCE_PIPELINE'
                WHEN svs.final_status IS NOT NULL THEN 'SHEET_STATUS_SYNC'
                WHEN ti.allocation_id IS NOT NULL THEN 'ACTIVE_INTERVAL'
                ELSE 'YARD_ROLLOVER'
            END AS source_origin
        FROM public.core_vehicle_onboarding vo
        
        -- Platform Trips Check
        LEFT JOIN LATERAL (
            SELECT completed_trips, vendor_code 
            FROM public.core_uber_daily 
            WHERE vehicle_number = vo.registration_no AND operational_date = p_target_date
            ORDER BY completed_trips DESC LIMIT 1
        ) u ON TRUE
        LEFT JOIN LATERAL (
            SELECT completed_trips 
            FROM public.core_ola_daily 
            WHERE vehicle_number = vo.registration_no AND service_date = p_target_date
            ORDER BY completed_trips DESC LIMIT 1
        ) o ON TRUE

        -- Today's Allocation Event
        LEFT JOIN LATERAL (
            SELECT id, partner_id, driver_name, driver_phone, hub_name, car_model, city, allocation_date
            FROM public.core_vehicle_allocation
            WHERE is_deleted = FALSE
              AND vehicle_number = vo.registration_no
              AND allocation_date = p_target_date
            ORDER BY id DESC
            LIMIT 1
        ) alloc_today ON TRUE

        -- Today's Dropoff Event
        LEFT JOIN LATERAL (
            SELECT id, return_type, return_date, driver_id, driver_name
            FROM public.core_dropoffs
            WHERE is_deleted = FALSE
              AND vehicle_number = vo.registration_no
              AND return_date = p_target_date
            ORDER BY id DESC
            LIMIT 1
        ) drop_today ON TRUE

        -- Recent Dropoff before today in current cycle (from Monday of current week)
        LEFT JOIN LATERAL (
            SELECT id, return_type, return_date
            FROM public.core_dropoffs
            WHERE is_deleted = FALSE AND vehicle_number = vo.registration_no 
              AND return_date >= DATE_TRUNC('week', p_target_date)::date 
              AND return_date < p_target_date
            ORDER BY return_date DESC, id DESC LIMIT 1
        ) recent_drop ON TRUE

        -- Allocation occurring AFTER recent dropoff up to today
        LEFT JOIN LATERAL (
            SELECT id
            FROM public.core_vehicle_allocation
            WHERE is_deleted = FALSE AND vehicle_number = vo.registration_no 
              AND allocation_date >= recent_drop.return_date AND allocation_date <= p_target_date
            LIMIT 1
        ) alloc_after_drop ON recent_drop.id IS NOT NULL

        -- Check Master Maintenance Table with Stale Ticket Guard
        LEFT JOIN LATERAL (
            SELECT id
            FROM public.core_maintenance
            WHERE is_deleted = FALSE
              AND vehicle_number = vo.registration_no
              AND start_date <= p_target_date
              AND (
                  end_date >= p_target_date
                  OR (
                      end_date IS NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM public.core_vehicle_allocation a
                          WHERE a.vehicle_number = vo.registration_no
                            AND a.is_deleted = FALSE
                            AND a.allocation_date > start_date
                            AND a.allocation_date <= p_target_date
                      )
                  )
              )
            ORDER BY start_date DESC
            LIMIT 1
        ) cm ON TRUE

        -- Ground Truth from sheet_vehicle_status
        LEFT JOIN LATERAL (
            SELECT 
                final_status,
                cohort,
                partner_id,
                partner_name,
                new_partner_name,
                vehicle_model,
                city
            FROM public.sheet_vehicle_status
            WHERE vehicle_number = vo.registration_no
              AND status_date = p_target_date
            ORDER BY id DESC
            LIMIT 1
        ) svs ON TRUE

        -- Active Trip Interval
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
    ) AS source
    ON target.status_date = source.status_date AND target.vehicle_number = source.vehicle_number
    WHEN MATCHED THEN
        UPDATE SET
            city = source.city,
            final_status = source.final_status,
            cohort = source.cohort,
            partner_id = source.partner_id,
            partner_name = source.partner_name,
            partner_phone = source.partner_phone,
            hub_name = source.hub_name,
            car_model = source.car_model,
            allocation_id = source.allocation_id,
            allocation_date = source.allocation_date,
            dropoff_id = source.dropoff_id,
            dropoff_date = source.dropoff_date,
            maintenance_id = source.maintenance_id,
            billable_rent_day = source.billable_rent_day,
            rent_waived_reason = source.rent_waived_reason,
            source_origin = source.source_origin,
            updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN
        INSERT (
            status_date, vehicle_number, city, final_status, cohort,
            partner_id, partner_name, partner_phone, hub_name, car_model,
            allocation_id, allocation_date, dropoff_id, dropoff_date, maintenance_id,
            billable_rent_day, rent_waived_reason, source_origin, created_at, updated_at
        ) VALUES (
            source.status_date, source.vehicle_number, source.city, source.final_status, source.cohort,
            source.partner_id, source.partner_name, source.partner_phone, source.hub_name, source.car_model,
            source.allocation_id, source.allocation_date, source.dropoff_id, source.dropoff_date, source.maintenance_id,
            source.billable_rent_day, source.rent_waived_reason, source.source_origin, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        );
END;
$procedure$;
