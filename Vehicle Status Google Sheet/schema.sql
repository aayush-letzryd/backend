-- ==============================================================================
-- LETZRYD FLEET MANAGEMENT PLATFORM
-- TABLE DEFINITION: public.sheet_vehicle_status
-- ==============================================================================
-- Target Database : PostgreSQL 14+
-- Target Schema   : public
-- Table Name      : sheet_vehicle_status
-- Primary Key     : id (BIGSERIAL, unbroken sequential order via zero-burn CTE)
-- Natural Key     : (status_date, vehicle_number)
-- Source Ingestion: Daily Vehicle Status Google Sheet / Excel Tracker
-- Documentation   : Knowledge Transfer Runbook (README.md)
-- ==============================================================================

-- 1. Table Creation
CREATE TABLE IF NOT EXISTS public.sheet_vehicle_status (
    id BIGSERIAL PRIMARY KEY,
    
    -- Location & Asset Identifiers
    city VARCHAR(20),
    vehicle_number VARCHAR(20) NOT NULL,
    status_date DATE NOT NULL,
    
    -- Operational Transition Dates
    allocation_date DATE,
    dropoff_date DATE,
    
    -- Vehicle State & Cohort Classification
    final_status VARCHAR(50) NOT NULL,
    cohort VARCHAR(50),
    mapping_key VARCHAR(100),
    
    -- Partner & Driver Information
    partner_name VARCHAR(150),
    partner_id VARCHAR(50),
    new_partner_name VARCHAR(150),
    
    -- Fleet & Operations Management
    vehicle_model VARCHAR(100),
    dm_name VARCHAR(100),
    vehicle_type VARCHAR(50),
    
    -- Pipeline Lineage & Audit Tracking
    sheet_row_number INTEGER,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Natural Unique Constraint (Conflict Target for Upserts)
    CONSTRAINT uq_sheet_vehicle_status UNIQUE (status_date, vehicle_number)
);

-- 2. Performance & Operational Indexes
-- Index on status_date for daily partition scans and date-range reporting
CREATE INDEX IF NOT EXISTS idx_svs_status_date 
    ON public.sheet_vehicle_status (status_date DESC);

-- Index on vehicle_number for single-vehicle history lookups
CREATE INDEX IF NOT EXISTS idx_svs_vehicle_number 
    ON public.sheet_vehicle_status (vehicle_number);

-- Index on final_status for fleet-wide operational availability queries
CREATE INDEX IF NOT EXISTS idx_svs_final_status 
    ON public.sheet_vehicle_status (final_status);

-- Composite index on (status_date, final_status) for daily fleet health dashboards
CREATE INDEX IF NOT EXISTS idx_svs_date_status 
    ON public.sheet_vehicle_status (status_date DESC, final_status);

-- Composite index on city and status_date for regional operational reviews
CREATE INDEX IF NOT EXISTS idx_svs_city_date 
    ON public.sheet_vehicle_status (city, status_date DESC);

-- Index on partner_id for driver attendance and reconciliation queries
CREATE INDEX IF NOT EXISTS idx_svs_partner_id 
    ON public.sheet_vehicle_status (partner_id) 
    WHERE partner_id IS NOT NULL;

-- 3. Comments on Database Objects
COMMENT ON TABLE public.sheet_vehicle_status IS 
'Raw staging table ingesting daily vehicle status records from Google Sheets (Daily Vehicle Status tracker).';

COMMENT ON COLUMN public.sheet_vehicle_status.id IS 
'Synthetic surrogate primary key generated via sequence.';

COMMENT ON COLUMN public.sheet_vehicle_status.city IS 
'Operating city (e.g. BLR, MUM, HYD).';

COMMENT ON COLUMN public.sheet_vehicle_status.vehicle_number IS 
'Sanitized vehicle registration number in uppercase alphanumeric format (e.g. KA05AP6038).';

COMMENT ON COLUMN public.sheet_vehicle_status.status_date IS 
'The operational calendar date representing attendance and fleet state.';

COMMENT ON COLUMN public.sheet_vehicle_status.allocation_date IS 
'Timestamp or date when vehicle was allocated to a driver during that day, if applicable.';

COMMENT ON COLUMN public.sheet_vehicle_status.dropoff_date IS 
'Timestamp or date when vehicle was returned or dropped off during that day, if applicable.';

COMMENT ON COLUMN public.sheet_vehicle_status.final_status IS 
'Operational status classification: Active, Maintenance, RFD, Allocation, Drop Off, Same Day D&A, New Deployment.';

COMMENT ON COLUMN public.sheet_vehicle_status.cohort IS 
'Operational cohort grouping: On Road, Off Road.';

COMMENT ON COLUMN public.sheet_vehicle_status.mapping_key IS 
'Tracking key constructed in Google Sheets (e.g. Plate + Excel Serial Date or Plate + Date).';

COMMENT ON COLUMN public.sheet_vehicle_status.partner_name IS 
'Name of assigned driver or fleet partner. NULL or cleaned if vehicle is unallocated.';

COMMENT ON COLUMN public.sheet_vehicle_status.partner_id IS 
'Unique partner/operator identifier (e.g. LETZBLR9633943403, LETZBLRIP9656907001). Cleaned of placeholders.';

COMMENT ON COLUMN public.sheet_vehicle_status.new_partner_name IS 
'Replacement driver name or partner code in allocation/turnover scenarios.';

COMMENT ON COLUMN public.sheet_vehicle_status.vehicle_model IS 
'Make and model of vehicle (e.g. Maruti Wagonr Tour H3 CNG, Tata Tigor EV).';

COMMENT ON COLUMN public.sheet_vehicle_status.dm_name IS 
'Assigned Delivery Manager or Fleet Operations Lead handling the vehicle.';

COMMENT ON COLUMN public.sheet_vehicle_status.vehicle_type IS 
'Operating contract classification: Operator, Individual.';

COMMENT ON COLUMN public.sheet_vehicle_status.sheet_row_number IS 
'Original 1-based row number in the source spreadsheet for lineage tracking.';

COMMENT ON COLUMN public.sheet_vehicle_status.created_at IS 
'UTC timestamp when the row was first ingested into PostgreSQL.';

COMMENT ON COLUMN public.sheet_vehicle_status.updated_at IS 
'UTC timestamp when the row was last updated via upsert.';

-- ==============================================================================
-- OPERATIONAL & VERIFICATION QUERIES
-- ==============================================================================

-- Verification 1: Total records and sequence integrity
-- SELECT COUNT(*) AS total_rows, MIN(id) AS min_id, MAX(id) AS max_id, COUNT(DISTINCT vehicle_number) AS total_vehicles
-- FROM public.sheet_vehicle_status;

-- Verification 2: Fleet status breakdown on the most recent date
-- SELECT final_status, COUNT(*) AS vehicle_count,
--        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_fleet
-- FROM public.sheet_vehicle_status
-- WHERE status_date = (SELECT MAX(status_date) FROM public.sheet_vehicle_status)
-- GROUP BY final_status
-- ORDER BY vehicle_count DESC;

-- Verification 3: City-wise fleet status breakdown
-- SELECT city, final_status, COUNT(*) AS count
-- FROM public.sheet_vehicle_status
-- WHERE status_date = (SELECT MAX(status_date) FROM public.sheet_vehicle_status)
-- GROUP BY city, final_status
-- ORDER BY city, count DESC;

-- Verification 4: Vehicle status timeline check for an individual vehicle
-- SELECT status_date, final_status, cohort, partner_name, partner_id, dm_name
-- FROM public.sheet_vehicle_status
-- WHERE vehicle_number = 'KA05AP6038'
-- ORDER BY status_date DESC
-- LIMIT 30;

-- Verification 5: Maintenance transition audit
-- SELECT status_date, city, vehicle_number, partner_name, dm_name, vehicle_model
-- FROM public.sheet_vehicle_status
-- WHERE final_status = 'Maintenance'
--   AND status_date >= CURRENT_DATE - INTERVAL '7 days'
-- ORDER BY status_date DESC, city, vehicle_number;
