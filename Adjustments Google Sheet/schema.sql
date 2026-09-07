-- ==============================================================================
-- LETZRYD ADJUSTMENTS ENGINE - POSTGRESQL SCHEMA DDL & CONSOLIDATION PROCEDURES
-- ==============================================================================
-- Source 1 : public.sheet_adjustments (Ingested from Google Sheets 'Adjustment-Form')
-- Source 2 : public.july_partner_adjustment (Portal Form submissions)
-- Target   : public.core_adjustments (Consolidated Master Table)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. TABLE: public.sheet_adjustments (Raw Standardized Staging from Google Sheet)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sheet_adjustments (
    id SERIAL PRIMARY KEY,
    submission_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    submitter_email VARCHAR(255),
    city_name VARCHAR(100) NOT NULL,
    partner_type VARCHAR(100) DEFAULT 'Individual',
    adjustment_type VARCHAR(100) NOT NULL,
    partner_name VARCHAR(255),
    partner_phone VARCHAR(100),
    partner_code VARCHAR(100),
    vehicle_number VARCHAR(100),
    remittance_towards VARCHAR(255),
    rent_deduction NUMERIC(12,2) DEFAULT 0.00,
    adjustment_date DATE NOT NULL,
    amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    photo_url TEXT,
    remarks TEXT,
    adjustment_related_to VARCHAR(255),
    gps_data VARCHAR(255),
    first_level_approver VARCHAR(255),
    first_level_status VARCHAR(100),
    first_level_timestamp TIMESTAMP WITH TIME ZONE,
    finance_team_status VARCHAR(100),
    finance_team_remarks TEXT,
    final_level_approver VARCHAR(255),
    final_status VARCHAR(100) DEFAULT 'Pending',
    final_timestamp TIMESTAMP WITH TIME ZONE,
    hisaab_week_str VARCHAR(255),
    hisaab_week_number INTEGER,
    ingested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_sheet_adjustments UNIQUE (submission_timestamp, partner_phone, adjustment_date, adjustment_type)
);

-- Indexes for sheet_adjustments
CREATE INDEX IF NOT EXISTS idx_sheet_adj_partner ON public.sheet_adjustments (partner_code);
CREATE INDEX IF NOT EXISTS idx_sheet_adj_phone ON public.sheet_adjustments (partner_phone);
CREATE INDEX IF NOT EXISTS idx_sheet_adj_veh ON public.sheet_adjustments (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_sheet_adj_date ON public.sheet_adjustments (adjustment_date);

-- ------------------------------------------------------------------------------
-- 2. TABLE: public.core_adjustments (Consolidated Master Table)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.core_adjustments (
    id SERIAL PRIMARY KEY,
    adjustment_id VARCHAR(100) UNIQUE NOT NULL,
    partner_id VARCHAR(100),
    partner_name VARCHAR(255),
    partner_phone VARCHAR(100),
    partner_type VARCHAR(100) DEFAULT 'Individual',
    vehicle_number VARCHAR(100),
    city_name VARCHAR(100) NOT NULL,
    adjustment_type VARCHAR(100) NOT NULL,
    adjustment_nature VARCHAR(100),
    adjustment_level VARCHAR(100),
    adjustment_date DATE NOT NULL,
    amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    remittance_towards VARCHAR(255),
    adjustment_related_to VARCHAR(255),
    hisaab_number VARCHAR(100),
    hisaab_week_number INTEGER,
    contested_line_items JSONB,
    severity_level VARCHAR(100) DEFAULT 'Low',
    cost_level VARCHAR(100) DEFAULT 'Direct',
    remarks TEXT,
    approval_status VARCHAR(100) DEFAULT 'Pending',
    first_level_approver VARCHAR(255),
    final_level_approver VARCHAR(255),
    current_approver_id VARCHAR(100),
    approved_by VARCHAR(255),
    photo_url TEXT,
    data_source VARCHAR(100) DEFAULT 'sheet_adjustments',
    source_reference_id VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for core_adjustments
CREATE INDEX IF NOT EXISTS idx_core_adj_partner ON public.core_adjustments (partner_id);
CREATE INDEX IF NOT EXISTS idx_core_adj_phone ON public.core_adjustments (partner_phone);
CREATE INDEX IF NOT EXISTS idx_core_adj_veh ON public.core_adjustments (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_adj_date ON public.core_adjustments (adjustment_date);
CREATE INDEX IF NOT EXISTS idx_core_adj_status ON public.core_adjustments (approval_status);

-- ------------------------------------------------------------------------------
-- 3. CONSOLIDATION STORED PROCEDURE: refresh_core_adjustments()
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_core_adjustments()
RETURNS INTEGER AS $$
DECLARE
    v_inserted_count INTEGER := 0;
BEGIN
    -- Step 1: Ingest/Upsert from Google Sheet Staging (sheet_adjustments)
    INSERT INTO public.core_adjustments (
        adjustment_id,
        partner_id,
        partner_name,
        partner_phone,
        partner_type,
        vehicle_number,
        city_name,
        adjustment_type,
        adjustment_nature,
        adjustment_level,
        adjustment_date,
        amount,
        remittance_towards,
        adjustment_related_to,
        hisaab_number,
        hisaab_week_number,
        remarks,
        approval_status,
        first_level_approver,
        final_level_approver,
        photo_url,
        data_source,
        source_reference_id,
        created_at,
        updated_at
    )
    SELECT
        'ADJ-SHT-' || s.id::TEXT,
        COALESCE(s.partner_code, 'LETZ' || UPPER(LEFT(s.city_name, 3)) || COALESCE(s.partner_phone, '0000000000')),
        s.partner_name,
        s.partner_phone,
        COALESCE(s.partner_type, 'Individual'),
        s.vehicle_number,
        s.city_name,
        COALESCE(s.adjustment_type, 'Credit'),
        'Monetary',
        CASE WHEN LOWER(s.partner_type) = 'operator' THEN 'Operator' ELSE 'Driver' END,
        s.adjustment_date,
        s.amount,
        s.remittance_towards,
        s.adjustment_related_to,
        s.hisaab_week_str,
        s.hisaab_week_number,
        s.remarks,
        COALESCE(s.final_status, s.first_level_status, 'Pending'),
        s.first_level_approver,
        s.final_level_approver,
        s.photo_url,
        'GOOGLE_SHEET',
        s.id::TEXT,
        s.submission_timestamp,
        s.updated_at
    FROM public.sheet_adjustments s
    ON CONFLICT (adjustment_id)
    DO UPDATE SET
        partner_name = EXCLUDED.partner_name,
        partner_phone = EXCLUDED.partner_phone,
        vehicle_number = EXCLUDED.vehicle_number,
        remittance_towards = EXCLUDED.remittance_towards,
        adjustment_related_to = EXCLUDED.adjustment_related_to,
        amount = EXCLUDED.amount,
        approval_status = EXCLUDED.approval_status,
        final_level_approver = EXCLUDED.final_level_approver,
        remarks = EXCLUDED.remarks,
        updated_at = CURRENT_TIMESTAMP;

    -- Step 2: Ingest/Upsert from Portal Adjustments (july_partner_adjustment)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_partner_adjustment') THEN
        INSERT INTO public.core_adjustments (
            adjustment_id,
            partner_id,
            partner_name,
            partner_phone,
            partner_type,
            vehicle_number,
            city_name,
            adjustment_type,
            adjustment_nature,
            adjustment_level,
            adjustment_date,
            amount,
            remittance_towards,
            adjustment_related_to,
            hisaab_number,
            contested_line_items,
            severity_level,
            cost_level,
            remarks,
            approval_status,
            first_level_approver,
            final_level_approver,
            current_approver_id,
            approved_by,
            photo_url,
            data_source,
            source_reference_id,
            created_at,
            updated_at
        )
        SELECT
            'ADJ-PORTAL-' || j.id::TEXT,
            COALESCE(j.driver_id, j.partner_code, 'LETZ' || UPPER(LEFT(COALESCE(j.city_name, 'BLR'), 3)) || COALESCE(j.partner_number, '0000000000')),
            j.partner_name,
            j.partner_number,
            COALESCE(j.partner_type, 'Individual'),
            j.vehicle_number,
            COALESCE(j.city_name, 'Bengaluru'),
            COALESCE(j.adjustment_type, 'Credit'),
            COALESCE(j.adjustment_nature, 'Monetary'),
            COALESCE(j.adjustment_level, 'Driver'),
            COALESCE(
                CASE 
                    WHEN j.adjustment_date ~ '^\d{4}-\d{2}-\d{2}' THEN j.adjustment_date::DATE
                    WHEN j.adjustment_date ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(j.adjustment_date, 'DD/MM/YYYY')
                    ELSE CURRENT_DATE
                END,
                CURRENT_DATE
            ),
            COALESCE(NULLIF(REGEXP_REPLACE(j.enter_amount, '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00),
            j.remittance_towards,
            j.adjustment_related_to,
            j.hisaab_number,
            CASE WHEN j.contested_line_items IS NOT NULL AND j.contested_line_items != '' AND j.contested_line_items != 'nan' THEN j.contested_line_items::JSONB ELSE NULL END,
            j.severity_level,
            j.cost_level,
            j.remarks,
            COALESCE(j.approval_status, j.status, 'Pending'),
            j.first_level_approval_by,
            j.final_level_approval_by,
            j.current_approver_id::TEXT,
            j.approved_by::TEXT,
            j.photo,
            'PORTAL_FORM',
            j.id::TEXT,
            COALESCE(j.created_at, CURRENT_TIMESTAMP),
            COALESCE(j.last_edited_at, CURRENT_TIMESTAMP)
        FROM public.july_partner_adjustment j
        ON CONFLICT (adjustment_id)
        DO UPDATE SET
            partner_id = EXCLUDED.partner_id,
            partner_name = EXCLUDED.partner_name,
            partner_phone = EXCLUDED.partner_phone,
            vehicle_number = EXCLUDED.vehicle_number,
            amount = EXCLUDED.amount,
            approval_status = EXCLUDED.approval_status,
            contested_line_items = EXCLUDED.contested_line_items,
            severity_level = EXCLUDED.severity_level,
            cost_level = EXCLUDED.cost_level,
            data_source = 'PORTAL_FORM',
            source_reference_id = EXCLUDED.source_reference_id,
            updated_at = CURRENT_TIMESTAMP;
    END IF;

    GET DIAGNOSTICS v_inserted_count = ROW_COUNT;
    RETURN v_inserted_count;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------------------------
-- 4. TRIGGER: Automatic Consolidation on Sheet Ingestion
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_fn_sync_sheet_adjustments()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM public.refresh_core_adjustments();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sheet_adjustments_refresh ON public.sheet_adjustments;
CREATE TRIGGER trg_sheet_adjustments_refresh
AFTER INSERT OR UPDATE ON public.sheet_adjustments
FOR EACH STATEMENT
EXECUTE FUNCTION public.trg_fn_sync_sheet_adjustments();
