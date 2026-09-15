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
-- 5. TRIGGER FUNCTION: fn_sync_core_daily_status_from_sheet()
-- Real-time synchronization from public.sheet_vehicle_status with Zero-Burn guard.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_core_daily_status_from_sheet()
RETURNS TRIGGER AS $$
DECLARE
    v_cohort VARCHAR(20);
    v_billable BOOLEAN;
    v_waive_reason VARCHAR(100);
BEGIN
    -- Handle soft/hard delete
    IF TG_OP = 'DELETE' THEN
        DELETE FROM public.core_daily_vehicle_status 
        WHERE status_date = OLD.status_date AND vehicle_number = OLD.vehicle_number;
        RETURN OLD;
    END IF;

    -- Compute cohort from final_status
    IF NEW.cohort IS NOT NULL AND NEW.cohort != '' THEN
        v_cohort := NEW.cohort;
    ELSIF NEW.final_status IN ('Active', 'Allocation', 'Same Day D&A') THEN
        v_cohort := 'On Road';
    ELSIF NEW.final_status IN ('Maintenance', 'Drop Off') THEN
        v_cohort := 'Off Road';
    ELSE
        v_cohort := 'In Yard';
    END IF;

    -- Compute billing eligibility and rent waiver rationale
    IF NEW.final_status IN ('Active', 'Allocation', 'Same Day D&A') THEN
        v_billable := TRUE;
        v_waive_reason := NULL;
    ELSIF NEW.final_status = 'Maintenance' THEN
        v_billable := FALSE;
        v_waive_reason := 'WORKSHOP_MAINTENANCE';
    ELSIF NEW.final_status = 'Drop Off' THEN
        v_billable := FALSE;
        v_waive_reason := 'DROPOFF_INSPECTION';
    ELSE
        v_billable := FALSE;
        v_waive_reason := 'RFD_IN_YARD';
    END IF;

    -- Zero-Burn Check: Update if exists, Insert only when missing
    IF EXISTS (
        SELECT 1 FROM public.core_daily_vehicle_status 
        WHERE status_date = NEW.status_date AND vehicle_number = NEW.vehicle_number
    ) THEN
        UPDATE public.core_daily_vehicle_status SET
            city = COALESCE(NEW.city, 'UNKNOWN'),
            final_status = NEW.final_status,
            cohort = v_cohort,
            partner_id = NEW.partner_id,
            partner_name = NEW.partner_name,
            car_model = NEW.vehicle_model,
            allocation_date = NEW.allocation_date,
            dropoff_date = NEW.dropoff_date,
            billable_rent_day = v_billable,
            rent_waived_reason = v_waive_reason,
            source_origin = 'SHEET_STATUS_SYNC',
            updated_at = CURRENT_TIMESTAMP
        WHERE status_date = NEW.status_date AND vehicle_number = NEW.vehicle_number;
    ELSE
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
            allocation_date,
            dropoff_date,
            billable_rent_day,
            rent_waived_reason,
            source_origin,
            updated_at
        ) VALUES (
            NEW.status_date,
            NEW.vehicle_number,
            COALESCE(NEW.city, 'UNKNOWN'),
            NEW.final_status,
            v_cohort,
            NEW.partner_id,
            NEW.partner_name,
            NULL,
            'MAIN_HUB',
            NEW.vehicle_model,
            NEW.allocation_date,
            NEW.dropoff_date,
            v_billable,
            v_waive_reason,
            'SHEET_STATUS_SYNC',
            CURRENT_TIMESTAMP
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Bind trigger to sheet_vehicle_status
DROP TRIGGER IF EXISTS trg_sync_core_daily_status_from_sheet ON public.sheet_vehicle_status;
CREATE TRIGGER trg_sync_core_daily_status_from_sheet
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_vehicle_status
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_daily_status_from_sheet();

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
            COALESCE(ti.city, vo.city, 'UNKNOWN') AS city,
            
            -- Operational Status Classification
            CASE 
                WHEN alloc_today.id IS NOT NULL AND drop_today.id IS NOT NULL THEN 'Same Day D&A'
                WHEN alloc_today.id IS NOT NULL THEN 'Allocation'
                WHEN drop_today.id IS NOT NULL AND drop_today.return_type IN ('Attrition', 'Force Recovery') THEN 'Drop Off'
                WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 'Maintenance'
                WHEN ti.allocation_id IS NOT NULL THEN 'Active'
                ELSE 'RFD'
            END AS final_status,
            
            -- Cohort Classification
            CASE 
                WHEN alloc_today.id IS NOT NULL AND drop_today.id IS NOT NULL THEN 'On Road'
                WHEN alloc_today.id IS NOT NULL THEN 'On Road'
                WHEN drop_today.id IS NOT NULL AND drop_today.return_type IN ('Attrition', 'Force Recovery') THEN 'Off Road'
                WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 'Off Road'
                WHEN ti.allocation_id IS NOT NULL THEN 'On Road'
                ELSE 'In Yard'
            END AS cohort,
            
            -- Partner ID Assignment (IP operator custody retention)
            CASE 
                WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 
                    CASE WHEN UPPER(COALESCE(ti.partner_id, '')) LIKE '%IP%' THEN ti.partner_id ELSE NULL END
                WHEN ti.allocation_id IS NOT NULL THEN ti.partner_id
                ELSE NULL
            END AS partner_id,
            
            -- Partner Name Assignment
            CASE 
                WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 
                    CASE WHEN UPPER(COALESCE(ti.partner_id, '')) LIKE '%IP%' THEN ti.driver_name ELSE NULL END
                WHEN ti.allocation_id IS NOT NULL THEN ti.driver_name
                ELSE NULL
            END AS partner_name,
            
            -- Partner Phone Assignment
            CASE 
                WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 
                    CASE WHEN UPPER(COALESCE(ti.partner_id, '')) LIKE '%IP%' THEN ti.driver_phone ELSE NULL END
                WHEN ti.allocation_id IS NOT NULL THEN ti.driver_phone
                ELSE NULL
            END AS partner_phone,
            
            COALESCE(ti.hub_name, 'MAIN_HUB') AS hub_name,
            COALESCE(ti.car_model, vo.model) AS car_model,
            ti.allocation_id,
            ti.trip_start_date AS allocation_date,
            ti.dropoff_id,
            ti.trip_end_date AS dropoff_date,
            cm.id AS maintenance_id,
            
            -- Billing Flag
            CASE 
                WHEN alloc_today.id IS NOT NULL AND drop_today.id IS NOT NULL THEN TRUE
                WHEN alloc_today.id IS NOT NULL THEN TRUE
                WHEN drop_today.id IS NOT NULL AND drop_today.return_type IN ('Attrition', 'Force Recovery') THEN FALSE
                WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN FALSE
                WHEN ti.allocation_id IS NOT NULL THEN TRUE
                ELSE FALSE
            END AS billable_rent_day,
            
            -- Rent Waived Reason
            CASE 
                WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 'WORKSHOP_MAINTENANCE'
                WHEN drop_today.id IS NOT NULL THEN 'DROPOFF_INSPECTION'
                WHEN ti.allocation_id IS NULL THEN 'RFD_IN_YARD'
                ELSE NULL
            END AS rent_waived_reason,
            
            -- Provenance Source Origin
            CASE 
                WHEN alloc_today.id IS NOT NULL AND drop_today.id IS NOT NULL THEN 'SAME_DAY_HANDOVER'
                WHEN alloc_today.id IS NOT NULL THEN 'ALLOCATION_EVENT'
                WHEN drop_today.id IS NOT NULL THEN 'DROPOFF_EVENT'
                WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 'MAINTENANCE_PIPELINE'
                WHEN ti.allocation_id IS NOT NULL THEN 'ACTIVE_INTERVAL'
                ELSE 'YARD_ROLLOVER'
            END AS source_origin
        FROM public.core_vehicle_onboarding vo
        
        -- Priority 1: Check Master Maintenance Table
        LEFT JOIN LATERAL (
            SELECT id
            FROM public.core_maintenance
            WHERE is_deleted = FALSE
              AND vehicle_number = vo.registration_no
              AND start_date <= p_target_date
              AND (end_date IS NULL OR end_date >= p_target_date)
            ORDER BY start_date DESC
            LIMIT 1
        ) cm ON TRUE

        -- Priority 2: Fallback Dropoff Maintenance Check
        LEFT JOIN LATERAL (
            SELECT id, return_date
            FROM public.core_dropoffs
            WHERE is_deleted = FALSE
              AND vehicle_number = vo.registration_no
              AND return_type = 'Repair and Maintenance'
              AND return_date <= p_target_date
              AND return_date >= p_target_date - INTERVAL '7 days'
            ORDER BY return_date DESC, id DESC
            LIMIT 1
        ) rm_today ON TRUE
        
        -- Priority 3: Allocation Event on Target Date
        LEFT JOIN LATERAL (
            SELECT id, partner_id, driver_name, driver_phone, hub_name, car_model, city
            FROM public.core_vehicle_allocation
            WHERE is_deleted = FALSE
              AND vehicle_number = vo.registration_no
              AND allocation_date = p_target_date
            ORDER BY id DESC
            LIMIT 1
        ) alloc_today ON TRUE

        -- Priority 4: Dropoff Event on Target Date
        LEFT JOIN LATERAL (
            SELECT id, return_type
            FROM public.core_dropoffs
            WHERE is_deleted = FALSE
              AND vehicle_number = vo.registration_no
              AND return_date = p_target_date
            ORDER BY id DESC
            LIMIT 1
        ) drop_today ON TRUE

        -- Priority 5: Active Trip Interval
        LEFT JOIN LATERAL (
            SELECT *
            FROM public.v_vehicle_trip_intervals ti
            WHERE ti.vehicle_number = vo.registration_no
              AND ti.trip_start_date <= p_target_date
              AND (ti.trip_end_date IS NULL OR ti.trip_end_date > p_target_date)
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
