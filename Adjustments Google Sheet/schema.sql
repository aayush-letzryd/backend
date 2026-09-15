-- ==============================================================================
-- LETZRYD ADJUSTMENTS GOOGLE SHEET STAGING SCHEMA DDL
-- ==============================================================================
-- Target Database: postgres
-- Target Schema  : public
-- Target Table   : public.sheet_adjustments (Google Sheet 'Adjustment-Form' Staging)
-- Description    : Raw staging table capturing submissions from Google Sheets.
--                  Synchronizes in real-time downstream into public.core_adjustments.
-- ==============================================================================

-- 1. TABLE DDL: public.sheet_adjustments
CREATE TABLE IF NOT EXISTS public.sheet_adjustments (
    id BIGSERIAL PRIMARY KEY,
    submission_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    submitter_email TEXT,
    city_name TEXT NOT NULL,
    partner_type TEXT DEFAULT 'Individual',
    adjustment_type TEXT NOT NULL,
    partner_name TEXT,
    partner_phone TEXT,
    partner_code TEXT,
    vehicle_number TEXT,
    remittance_towards TEXT,
    rent_deduction NUMERIC(12,2) DEFAULT 0.00,
    adjustment_date DATE NOT NULL,
    amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    photo_url TEXT,
    remarks TEXT,
    adjustment_related_to TEXT,
    gps_data TEXT,
    first_level_approver TEXT,
    first_level_status TEXT,
    first_level_timestamp TIMESTAMP WITH TIME ZONE,
    finance_team_status TEXT,
    finance_team_remarks TEXT,
    final_level_approver TEXT,
    final_status TEXT DEFAULT 'Pending',
    final_timestamp TIMESTAMP WITH TIME ZONE,
    hisaab_week_str TEXT,
    hisaab_week_number INTEGER,
    ingested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_sheet_adjustments_amount CHECK (amount >= 0.00)
);

-- 2. UNIQUE COMPOSITE DEDUPLICATION INDEX
CREATE UNIQUE INDEX IF NOT EXISTS uq_sheet_adjustments_dedup 
ON public.sheet_adjustments (
    submission_timestamp, 
    COALESCE(partner_phone, 'NO_PHONE'), 
    adjustment_date, 
    adjustment_type
);

-- 3. PERFORMANCE B-TREE INDEXES
CREATE INDEX IF NOT EXISTS idx_sheet_adj_partner ON public.sheet_adjustments (partner_code);
CREATE INDEX IF NOT EXISTS idx_sheet_adj_phone ON public.sheet_adjustments (partner_phone);
CREATE INDEX IF NOT EXISTS idx_sheet_adj_veh ON public.sheet_adjustments (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_sheet_adj_date ON public.sheet_adjustments (adjustment_date);
CREATE INDEX IF NOT EXISTS idx_sheet_adj_status ON public.sheet_adjustments (final_status);

-- 4. VERIFICATION QUERIES
-- Check current staging row count
-- SELECT count(*) FROM public.sheet_adjustments;

-- Check sequence continuity
-- SELECT min(id), max(id), count(id) FROM public.sheet_adjustments;
