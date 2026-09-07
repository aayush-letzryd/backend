-- ==============================================================================
-- LETZRYD - VEHICLE DROPOFF PIPELINE DDL (sheet_dropoffs)
-- ==============================================================================
-- Schema      : public
-- Table Name  : sheet_dropoffs
-- Primary Key : dropoff_id (Synthetic Deterministic Key: DROP-<Plate>-<YYYYMMDD>-<DriverHash>)
-- Downstream  : Feeds dropoff_final (Driver Hisaab Engine)
-- ==============================================================================

-- 1. Drop existing table if recreating
DROP TABLE IF EXISTS public.sheet_dropoffs CASCADE;

-- 2. Create public.sheet_dropoffs table
CREATE TABLE public.sheet_dropoffs (
    -- Primary / Natural Key
    dropoff_id VARCHAR(100) PRIMARY KEY,
    
    -- Source Traceability
    source_row INTEGER,
    
    -- Dropoff Core Attributes
    return_date DATE NOT NULL,
    return_type VARCHAR(50) NOT NULL,
    
    -- Driver & Operator Details
    driver_id VARCHAR(50),
    driver_name VARCHAR(100),
    driver_type VARCHAR(30) DEFAULT 'Individual',
    
    -- Vehicle & Location
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(50) NOT NULL,
    
    -- Financial Liability
    negative_balance NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Audit & System Timestamps
    sync_status VARCHAR(20) DEFAULT 'SYNCED',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    
    -- Idempotency Composite Constraint
    CONSTRAINT uq_sheet_dropoffs_composite UNIQUE (dropoff_id)
);

-- 3. High-Performance B-Tree Indexes
CREATE INDEX idx_sheet_dropoffs_vehicle ON public.sheet_dropoffs(vehicle_number);
CREATE INDEX idx_sheet_dropoffs_driver ON public.sheet_dropoffs(driver_id);
CREATE INDEX idx_sheet_dropoffs_return_date ON public.sheet_dropoffs(return_date);
CREATE INDEX idx_sheet_dropoffs_city ON public.sheet_dropoffs(city);
CREATE INDEX idx_sheet_dropoffs_return_type ON public.sheet_dropoffs(return_type);
CREATE INDEX idx_sheet_dropoffs_driver_type ON public.sheet_dropoffs(driver_type);

-- 4. Table & Column Documentation Comments
COMMENT ON TABLE public.sheet_dropoffs IS 'Consolidated vehicle dropoff and return logs feeding downstream dropoff_final in Hisaab Engine.';
COMMENT ON COLUMN public.sheet_dropoffs.dropoff_id IS 'Deterministic synthetic primary key (DROP-<Plate>-<YYYYMMDD>-<Driver/RowHash>).';
COMMENT ON COLUMN public.sheet_dropoffs.return_date IS 'Standardized ISO return date (YYYY-MM-DD).';
COMMENT ON COLUMN public.sheet_dropoffs.return_type IS 'Reason for vehicle return (Attrition, Repair and Maintenance, Force Recovery).';
COMMENT ON COLUMN public.sheet_dropoffs.negative_balance IS 'Ola negative wallet balance / outstanding driver liability (NUMERIC 12,2).';
COMMENT ON COLUMN public.sheet_dropoffs.city IS 'Canonical city name (Bangalore, Hyderabad, Mumbai).';
