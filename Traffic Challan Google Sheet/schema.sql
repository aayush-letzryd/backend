-- ==============================================================================
-- LETZRYD TRAFFIC CHALLAN MASTER TABLE DDL
-- Target Table: public.sheet_challans
-- Host: 35.200.196.113:5432 | DB: postgres | Schema: public
-- Source: 'Traffic Challan details' (All 38 weekly & monthly tabs)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.sheet_challans (
    id BIGSERIAL PRIMARY KEY,
    vehicle_reg_no VARCHAR(50) NOT NULL,
    notice_no VARCHAR(150) NOT NULL,
    city VARCHAR(100),
    week_cycle VARCHAR(100) NOT NULL,
    
    -- Financial Balances
    previous_balance NUMERIC(12, 2) DEFAULT 0.00,
    audit_date DATE,
    
    -- Violation Details (NULL for non-violating balance rows)
    notice_date DATE,
    violation_date DATE,
    violation_time TIME,
    
    -- Fine & Settlement Breakdown
    challan_amount NUMERIC(12, 2) DEFAULT 0.00,
    sticker_fine NUMERIC(12, 2) DEFAULT 0.00,
    amount_paid NUMERIC(12, 2) DEFAULT 0.00,
    total_pending NUMERIC(12, 2) DEFAULT 0.00,
    remarks TEXT,
    
    -- Pipeline Traceability & Soft-Delete Metadata
    source_tab VARCHAR(100),
    sheet_row_number INTEGER,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Composite Natural Key for Idempotent Ingestion
    CONSTRAINT uq_sheet_challans_reg_notice UNIQUE (vehicle_reg_no, notice_no)
);

-- Performance B-Tree Indexes
CREATE INDEX IF NOT EXISTS idx_challans_reg_no ON public.sheet_challans(vehicle_reg_no);
CREATE INDEX IF NOT EXISTS idx_challans_notice_no ON public.sheet_challans(notice_no);
CREATE INDEX IF NOT EXISTS idx_challans_city ON public.sheet_challans(city);
CREATE INDEX IF NOT EXISTS idx_challans_violation_date ON public.sheet_challans(violation_date);
CREATE INDEX IF NOT EXISTS idx_challans_total_pending ON public.sheet_challans(total_pending);
CREATE INDEX IF NOT EXISTS idx_challans_week_cycle ON public.sheet_challans(week_cycle);

-- ==============================================================================
-- VERIFICATION & DATA QUALITY QUERIES
-- ==============================================================================

-- 1. Check total rows synced
-- SELECT count(*) FROM public.sheet_challans;

-- 2. Check active violations vs rolling balances
-- SELECT 
--     COUNT(*) AS total_records,
--     COUNT(CASE WHEN challan_amount > 0 THEN 1 END) AS active_violations,
--     COUNT(CASE WHEN challan_amount = 0 THEN 1 END) AS balance_snapshot_rows,
--     SUM(challan_amount) AS total_fines_incurred,
--     SUM(amount_paid) AS total_fines_paid,
--     SUM(total_pending) AS total_pending_balance
-- FROM public.sheet_challans;

-- 3. Check city distribution
-- SELECT city, count(*) 
-- FROM public.sheet_challans 
-- GROUP BY city 
-- ORDER BY count(*) DESC;

-- 4. Inspect sample active violations
-- SELECT vehicle_reg_no, notice_no, city, violation_date, violation_time, challan_amount, total_pending 
-- FROM public.sheet_challans 
-- WHERE challan_amount > 0 
-- ORDER BY id ASC 
-- LIMIT 10;
