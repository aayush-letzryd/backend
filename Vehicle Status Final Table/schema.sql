-- ============================================================================
-- FLEET STATUS & INTERVAL LEDGER ENGINE SCHEMA
-- Production Master Schema for Vehicle Status Final Table
--
-- Target Objects:
--   1. Table: public.core_maintenance
--   2. Table: public.core_daily_vehicle_status
--   3. View:  public.v_vehicle_trip_intervals
--   4. View:  public.v_current_live_fleet_status
--   5. Proc:  public.sp_generate_daily_vehicle_status(IN p_target_date DATE)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Master Table: public.core_maintenance
-- Merges:
--   - Portal: july_maintenance_in + july_maintenance_out
--   - Google Sheets: Maintenance downtime rows from sheet_vehicle_status
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.core_maintenance (
    id BIGSERIAL PRIMARY KEY,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(10) NOT NULL,
    
    -- Event Dates and Status
    start_date DATE NOT NULL,
    end_date DATE,                                     -- NULL if vehicle is actively in workshop
    status VARCHAR(30) NOT NULL DEFAULT 'IN_PROGRESS', -- 'IN_PROGRESS', 'COMPLETED'
    
    -- Workshop and Damage Details
    workshop_name VARCHAR(150),
    job_card_number VARCHAR(100),
    maintenance_reason TEXT,
    estimated_cost NUMERIC(12, 2) DEFAULT 0.00,
    actual_cost NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Provenance and Source References
    data_source VARCHAR(50) NOT NULL,                  -- 'PORTAL_MAINTENANCE', 'SHEET_STATUS_EXTRACT'
    portal_maintenance_in_id INTEGER,
    portal_maintenance_out_id INTEGER,
    sheet_status_row_id BIGINT,
    
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_cm_vehicle_dates ON public.core_maintenance (vehicle_number, start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_cm_status ON public.core_maintenance (status);

-- ----------------------------------------------------------------------------
-- 2. Master Table: public.core_daily_vehicle_status
-- Daily attendance ledger providing single source of truth for fleet attendance and billing
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.core_daily_vehicle_status (
    id BIGSERIAL PRIMARY KEY,
    status_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(10) NOT NULL,
    
    -- Operational Status Taxonomy
    final_status VARCHAR(30) NOT NULL,                 -- 'Active', 'RFD', 'Maintenance', 'Allocation', 'Drop Off', 'Same Day D&A'
    cohort VARCHAR(20) NOT NULL,                       -- 'On Road', 'In Yard', 'Off Road'
    
    -- Active Driver Assignment (NULL if In Yard / RFD or Retail Workshop Maintenance)
    partner_id VARCHAR(50),
    partner_name VARCHAR(150),
    partner_phone VARCHAR(20),
    hub_name VARCHAR(100),
    car_model VARCHAR(100),
    
    -- Active Event Linkages
    allocation_id BIGINT,
    allocation_date DATE,
    dropoff_id BIGINT,
    dropoff_date DATE,
    maintenance_id BIGINT,
    
    -- Billing Directives for Weekly Hisaab Calculations
    billable_rent_day BOOLEAN NOT NULL DEFAULT FALSE,
    rent_waived_reason VARCHAR(100),                   -- 'RFD_IN_YARD', 'WORKSHOP_MAINTENANCE', 'DROPOFF_INSPECTION'
    
    -- Provenance and Audit Trail
    source_origin VARCHAR(50) NOT NULL,                -- 'ACTIVE_INTERVAL', 'SAME_DAY_HANDOVER', 'ALLOCATION_EVENT', 'DROPOFF_EVENT', 'MAINTENANCE_PIPELINE', 'YARD_ROLLOVER'
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_daily_vehicle_status UNIQUE (status_date, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_cdvs_date_partner ON public.core_daily_vehicle_status (status_date, partner_id);
CREATE INDEX IF NOT EXISTS idx_cdvs_vehicle_date ON public.core_daily_vehicle_status (vehicle_number, status_date);
CREATE INDEX IF NOT EXISTS idx_cdvs_status_date ON public.core_daily_vehicle_status (final_status, status_date);

-- ----------------------------------------------------------------------------
-- 3. View: public.v_vehicle_trip_intervals
-- Continuous Vehicle Trip Intervals pairing allocation events with subsequent drop-offs.
-- Rules:
--   - Bounded lookahead using LEAD(allocation_date) to prevent cross-driver overlaps.
--   - IP Operator Repair & Maintenance events do not truncate driver custody unless superseded.
--   - Lateral matching on return_date >= allocation_date, with driver matching on same-day handovers.
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
    -- For IP Operators, Repair & Maintenance dropoffs do not truncate trip_end_date 
    -- unless superseded by another allocation
    CASE 
        WHEN d.return_type = 'Repair and Maintenance' AND UPPER(ra.partner_id) LIKE '%IP%' 
            THEN ra.next_allocation_date
        ELSE COALESCE(d.return_date, ra.next_allocation_date)
    END AS trip_end_date,
    d.return_type,
    d.negative_balance AS final_debt,
    CASE
        WHEN d.return_type = 'Repair and Maintenance' AND UPPER(ra.partner_id) LIKE '%IP%' AND ra.next_allocation_date IS NULL 
            THEN 'OPERATOR_MAINTENANCE_ACTIVE'
        WHEN d.id IS NOT NULL 
            THEN 'CLOSED_TRIP'
        WHEN ra.next_allocation_date IS NOT NULL 
            THEN 'SUPERSEDED_BY_NEXT_ALLOCATION'
        ELSE 'CURRENTLY_ACTIVE'
    END AS trip_state,
    CASE
        WHEN d.return_date IS NOT NULL AND NOT (d.return_type = 'Repair and Maintenance' AND UPPER(ra.partner_id) LIKE '%IP%')
            THEN d.return_date - ra.allocation_date
        WHEN ra.next_allocation_date IS NOT NULL 
            THEN ra.next_allocation_date - ra.allocation_date
        ELSE CURRENT_DATE - ra.allocation_date
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
      AND (
          (d.return_date > ra.allocation_date)
          OR (d.return_date = ra.allocation_date AND (d.driver_id = ra.partner_id OR ra.partner_id IS NULL))
      )
      AND (ra.next_allocation_date IS NULL OR d.return_date <= ra.next_allocation_date)
    ORDER BY d.return_date ASC, d.id ASC
    LIMIT 1
) d ON TRUE;

-- ----------------------------------------------------------------------------
-- 4. View: public.v_current_live_fleet_status
-- Real-time snapshot view across all 1,623 vehicles in core_vehicle_onboarding.
-- Resolves whether each vehicle is Active (On Road), RFD (In Yard), or in Maintenance (Off Road).
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
    SELECT DISTINCT ON (vehicle_number)
        id AS maintenance_id,
        vehicle_number,
        start_date AS maintenance_date
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
LEFT JOIN active_maintenance m ON vo.registration_no = m.vehicle_number
WHERE vo.is_deleted = FALSE;

-- ----------------------------------------------------------------------------
-- 5. Stored Procedure: public.sp_generate_daily_vehicle_status
-- Generates or refreshes the full daily ledger for a given target calendar date.
-- Implements the strict 3 Priority Precedence Rules:
--   Priority 1: Maintenance Override (core_maintenance or recent Repair & Maintenance drop-off)
--   Priority 2: Active Trip Interval (v_vehicle_trip_intervals)
--   Priority 3: Default Yard State (RFD / In Yard)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_generate_daily_vehicle_status(IN p_target_date DATE)
LANGUAGE plpgsql
AS $procedure$
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
        maintenance_id,
        billable_rent_day,
        rent_waived_reason,
        source_origin,
        updated_at
    )
    SELECT 
        p_target_date AS status_date,
        vo.registration_no AS vehicle_number,
        COALESCE(ti.city, vo.city, 'UNKNOWN') AS city,
        
        -- Operational Status Classification
        CASE 
            WHEN alloc_today.id IS NOT NULL AND drop_today.id IS NOT NULL 
                THEN 'Same Day D&A'
            WHEN alloc_today.id IS NOT NULL 
                THEN 'Allocation'
            WHEN drop_today.id IS NOT NULL AND drop_today.return_type IN ('Attrition', 'Force Recovery') 
                THEN 'Drop Off'
            WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL 
                THEN 'Maintenance'
            WHEN ti.allocation_id IS NOT NULL 
                THEN 'Active'
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
        
        -- Partner ID Assignment
        CASE 
            WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 
                CASE WHEN UPPER(ti.partner_id) LIKE '%IP%' THEN ti.partner_id ELSE NULL END
            WHEN ti.allocation_id IS NOT NULL THEN ti.partner_id
            ELSE NULL
        END AS partner_id,
        
        -- Partner Name Assignment
        CASE 
            WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 
                CASE WHEN UPPER(ti.partner_id) LIKE '%IP%' THEN ti.driver_name ELSE NULL END
            WHEN ti.allocation_id IS NOT NULL THEN ti.driver_name
            ELSE NULL
        END AS partner_name,
        
        -- Partner Phone Assignment
        CASE 
            WHEN cm.id IS NOT NULL OR rm_today.id IS NOT NULL THEN 
                CASE WHEN UPPER(ti.partner_id) LIKE '%IP%' THEN ti.driver_phone ELSE NULL END
            WHEN ti.allocation_id IS NOT NULL THEN ti.driver_phone
            ELSE NULL
        END AS partner_phone,
        
        COALESCE(ti.hub_name, 'MAIN_HUB') AS hub_name,
        COALESCE(ti.car_model, vo.model) AS car_model,
        ti.allocation_id,
        ti.trip_start_date,
        ti.dropoff_id,
        ti.trip_end_date,
        cm.id AS maintenance_id,
        
        -- Rent Billing Rule
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
        END AS source_origin,
        
        CURRENT_TIMESTAMP AS updated_at
    FROM public.core_vehicle_onboarding vo
    
    -- Priority 1: Check Dedicated Maintenance Table
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

    -- Priority 2: Fallback Maintenance Detection (Repair & Maintenance dropoff without subsequent closure)
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
    
    -- Priority 3: Allocation Event Today
    LEFT JOIN LATERAL (
        SELECT id, partner_id, driver_name, driver_phone, hub_name, car_model, city
        FROM public.core_vehicle_allocation
        WHERE is_deleted = FALSE
          AND vehicle_number = vo.registration_no
          AND allocation_date = p_target_date
        ORDER BY id DESC
        LIMIT 1
    ) alloc_today ON TRUE

    -- Priority 4: Dropoff Event Today
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
        maintenance_id = EXCLUDED.maintenance_id,
        billable_rent_day = EXCLUDED.billable_rent_day,
        rent_waived_reason = EXCLUDED.rent_waived_reason,
        source_origin = EXCLUDED.source_origin,
        updated_at = CURRENT_TIMESTAMP;
END;
$procedure$;
