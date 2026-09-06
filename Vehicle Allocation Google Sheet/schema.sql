-- ==============================================================================
-- LETZRYD - VEHICLE ALLOCATION TABLE SCHEMA (sheet_vehicle_allocations)
-- ==============================================================================
-- Target Database : PostgreSQL 14+
-- Target Schema   : public.sheet_vehicle_allocations
-- Primary Key     : id (BIGSERIAL, unbroken sequential order)
-- Conflict Target : (allocation_date, vehicle_number, driver_phone)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.sheet_vehicle_allocations (
    id BIGSERIAL PRIMARY KEY,
    
    -- Submission metadata
    submission_timestamp TIMESTAMP WITH TIME ZONE,
    submitter_email VARCHAR(255),
    city VARCHAR(50),
    reason_to_visit VARCHAR(255),
    
    -- Allocation core
    allocation_date DATE NOT NULL,
    operator_driver_id VARCHAR(50),
    allocation_type VARCHAR(100),
    driver_name VARCHAR(255),
    driver_phone VARCHAR(20) NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    car_model VARCHAR(100),
    
    -- Plan details
    driver_plan VARCHAR(100),
    type_of_plan VARCHAR(100),
    rental_plan VARCHAR(100), -- From Column AI (Unnamed: 34), standardized per user direction
    partner_type VARCHAR(50),  -- From Column AH (Type: Operator / Individual)
    
    -- Financials & Readings
    ola_negative_amount NUMERIC(12, 2),
    odometer_reading INTEGER,
    
    -- Media & Documents (Drive / Cloud Storage URLs)
    upload_agreement TEXT,
    ola_negative_amount_ss TEXT,
    driver_with_car_photo TEXT,
    front_car_photo TEXT,
    lh_car_photo TEXT,
    rh_car_photo TEXT,
    back_car_photo TEXT,
    battery_photo TEXT,
    
    -- Toolkit & Accessories Handover Checklist
    stepney_tyre VARCHAR(50),
    spanner_pana VARCHAR(50),
    jack VARCHAR(50),
    jack_rod_tommy VARCHAR(50),
    parking_triangle VARCHAR(50),
    fire_extinguishers VARCHAR(50),
    floor_carpet VARCHAR(50),
    seat_cover VARCHAR(50),
    music_system VARCHAR(50),
    
    -- Management
    vehicle_manager_poc VARCHAR(100),
    
    -- System Audit & Lineage
    sheet_row_number INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Unique constraint for Upsert (Zero-burn conflict target)
    CONSTRAINT uq_sva_allocation_event UNIQUE (allocation_date, vehicle_number, driver_phone)
);

-- B-Tree Indexes for Query Performance & Operational Dashboards
CREATE INDEX IF NOT EXISTS idx_sva_alloc_date ON public.sheet_vehicle_allocations (allocation_date DESC);
CREATE INDEX IF NOT EXISTS idx_sva_veh_num ON public.sheet_vehicle_allocations (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_sva_driver_phone ON public.sheet_vehicle_allocations (driver_phone);
CREATE INDEX IF NOT EXISTS idx_sva_city ON public.sheet_vehicle_allocations (city);
CREATE INDEX IF NOT EXISTS idx_sva_poc ON public.sheet_vehicle_allocations (vehicle_manager_poc);
CREATE INDEX IF NOT EXISTS idx_sva_partner_type ON public.sheet_vehicle_allocations (partner_type);

-- Operational Verification Queries
-- 1. Total row count and sequence state
-- SELECT COUNT(*), MAX(id), MIN(id) FROM public.sheet_vehicle_allocations;
--
-- 2. Check allocation volume by city
-- SELECT city, COUNT(*) FROM public.sheet_vehicle_allocations GROUP BY city ORDER BY 2 DESC;
--
-- 3. Check recent allocations
-- SELECT id, allocation_date, vehicle_number, driver_name, driver_phone, city, rental_plan 
-- FROM public.sheet_vehicle_allocations ORDER BY id DESC LIMIT 10;
