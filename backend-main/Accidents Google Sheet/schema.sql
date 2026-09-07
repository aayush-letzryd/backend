-- ==============================================================================
-- LETZRYD ACCIDENTS ENGINE - POSTGRESQL SCHEMA DDL & CONSOLIDATION PROCEDURES
-- ==============================================================================
-- Source 1 : public.sheet_accidents (Ingested from Google Sheets 'Accident vehicle report')
-- Source 2 : public.july_accidents_registry (Portal Form submissions)
-- Target   : public.core_accidents (Consolidated Master Table)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. TABLE: public.sheet_accidents (Raw Standardized Staging from Google Sheet)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sheet_accidents (
    id SERIAL PRIMARY KEY,
    submission_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    submitter_email VARCHAR(255),
    vehicle_number VARCHAR(20) NOT NULL,
    city_code VARCHAR(10) NOT NULL,
    accident_date DATE NOT NULL,
    police_acknowledgement BOOLEAN DEFAULT FALSE,
    estimate_amount NUMERIC(12,2) DEFAULT 0.00,
    accident_photos_link TEXT,
    letzryd_payable_amount NUMERIC(12,2) DEFAULT 0.00,
    driver_name VARCHAR(255),
    driver_partner_id VARCHAR(50),
    vehicle_rfd_date DATE,
    total_invoice NUMERIC(12,2),
    liability_amount NUMERIC(12,2),
    letzryd_share NUMERIC(12,2),
    invoice_letter_link TEXT,
    incident_remarks TEXT,
    workshop_name VARCHAR(255),
    workshop_status VARCHAR(50),
    mode_of_repair VARCHAR(50),
    type_of_payment VARCHAR(50),
    ingested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_sheet_accidents UNIQUE (submission_timestamp, vehicle_number, accident_date)
);

-- Indexes for sheet_accidents
CREATE INDEX IF NOT EXISTS idx_sheet_accidents_veh ON public.sheet_accidents (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_sheet_accidents_date ON public.sheet_accidents (accident_date);
CREATE INDEX IF NOT EXISTS idx_sheet_accidents_partner ON public.sheet_accidents (driver_partner_id);

-- ------------------------------------------------------------------------------
-- 2. TABLE: public.core_accidents (Consolidated Master Table)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.core_accidents (
    id SERIAL PRIMARY KEY,
    accident_id VARCHAR(50) UNIQUE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    city_code VARCHAR(10) NOT NULL,
    accident_date DATE NOT NULL,
    driver_name VARCHAR(255),
    driver_partner_id VARCHAR(50),
    police_acknowledgement BOOLEAN DEFAULT FALSE,
    estimate_amount NUMERIC(12,2) DEFAULT 0.00,
    liability_amount NUMERIC(12,2) DEFAULT 0.00,
    letzryd_payable_amount NUMERIC(12,2) DEFAULT 0.00,
    total_invoice_amount NUMERIC(12,2),
    letzryd_share_amount NUMERIC(12,2),
    accident_photos_url TEXT,
    invoice_letter_url TEXT,
    workshop_name VARCHAR(255),
    workshop_status VARCHAR(50) DEFAULT 'Reported',
    mode_of_repair VARCHAR(50),
    type_of_payment VARCHAR(50),
    vehicle_rfd_date DATE,
    incident_remarks TEXT,
    data_source VARCHAR(50) NOT NULL, -- 'GOOGLE_SHEET' or 'PORTAL_FORM'
    source_reference_id VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_core_accidents UNIQUE (vehicle_number, accident_date)
);

-- Indexes for core_accidents
CREATE INDEX IF NOT EXISTS idx_core_accidents_veh ON public.core_accidents (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_accidents_date ON public.core_accidents (accident_date);
CREATE INDEX IF NOT EXISTS idx_core_accidents_partner ON public.core_accidents (driver_partner_id);
CREATE INDEX IF NOT EXISTS idx_core_accidents_city ON public.core_accidents (city_code);

-- ------------------------------------------------------------------------------
-- 3. CONSOLIDATION STORED PROCEDURE: refresh_core_accidents()
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_core_accidents()
RETURNS INTEGER AS $$
DECLARE
    v_inserted_count INTEGER := 0;
BEGIN
    -- Step 1: Ingest/Upsert from Google Sheet Staging (sheet_accidents) with DISTINCT ON to prevent multi-hit conflicts
    INSERT INTO public.core_accidents (
        accident_id,
        vehicle_number,
        city_code,
        accident_date,
        driver_name,
        driver_partner_id,
        police_acknowledgement,
        estimate_amount,
        liability_amount,
        letzryd_payable_amount,
        total_invoice_amount,
        letzryd_share_amount,
        accident_photos_url,
        invoice_letter_url,
        workshop_name,
        workshop_status,
        mode_of_repair,
        type_of_payment,
        vehicle_rfd_date,
        incident_remarks,
        data_source,
        source_reference_id,
        created_at,
        updated_at
    )
    SELECT DISTINCT ON (s.vehicle_number, s.accident_date)
        'ACC-' || UPPER(s.city_code) || '-' || REPLACE(s.vehicle_number, ' ', '') || '-' || TO_CHAR(s.accident_date, 'YYYYMMDD'),
        UPPER(s.vehicle_number),
        UPPER(s.city_code),
        s.accident_date,
        s.driver_name,
        COALESCE(s.driver_partner_id, p.partner_id),
        s.police_acknowledgement,
        s.estimate_amount,
        s.liability_amount,
        s.letzryd_payable_amount,
        s.total_invoice,
        s.letzryd_share,
        s.accident_photos_link,
        s.invoice_letter_link,
        s.workshop_name,
        COALESCE(s.workshop_status, 'Reported'),
        s.mode_of_repair,
        s.type_of_payment,
        s.vehicle_rfd_date,
        s.incident_remarks,
        'GOOGLE_SHEET',
        s.id::TEXT,
        s.submission_timestamp,
        s.updated_at
    FROM public.sheet_accidents s
    LEFT JOIN LATERAL (
        SELECT partner_id 
        FROM public.core_partner_onboarding 
        WHERE phone_number = RIGHT(s.driver_partner_id, 10) 
        LIMIT 1
    ) p ON TRUE
    ORDER BY s.vehicle_number, s.accident_date, s.submission_timestamp DESC, s.id DESC
    ON CONFLICT (vehicle_number, accident_date)
    DO UPDATE SET
        driver_name = EXCLUDED.driver_name,
        driver_partner_id = COALESCE(EXCLUDED.driver_partner_id, core_accidents.driver_partner_id),
        police_acknowledgement = EXCLUDED.police_acknowledgement,
        estimate_amount = EXCLUDED.estimate_amount,
        liability_amount = EXCLUDED.liability_amount,
        letzryd_payable_amount = EXCLUDED.letzryd_payable_amount,
        total_invoice_amount = EXCLUDED.total_invoice_amount,
        letzryd_share_amount = EXCLUDED.letzryd_share_amount,
        accident_photos_url = COALESCE(EXCLUDED.accident_photos_url, core_accidents.accident_photos_url),
        invoice_letter_url = COALESCE(EXCLUDED.invoice_letter_url, core_accidents.invoice_letter_url),
        workshop_name = COALESCE(EXCLUDED.workshop_name, core_accidents.workshop_name),
        workshop_status = COALESCE(EXCLUDED.workshop_status, core_accidents.workshop_status),
        vehicle_rfd_date = COALESCE(EXCLUDED.vehicle_rfd_date, core_accidents.vehicle_rfd_date),
        incident_remarks = EXCLUDED.incident_remarks,
        updated_at = CURRENT_TIMESTAMP;

    -- Step 2: Ingest/Upsert from Portal Registry (july_accidents_registry)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_accidents_registry') THEN
        INSERT INTO public.core_accidents (
            accident_id,
            vehicle_number,
            city_code,
            accident_date,
            driver_name,
            driver_partner_id,
            police_acknowledgement,
            estimate_amount,
            liability_amount,
            letzryd_payable_amount,
            total_invoice_amount,
            letzryd_share_amount,
            accident_photos_url,
            invoice_letter_url,
            workshop_name,
            workshop_status,
            mode_of_repair,
            type_of_payment,
            vehicle_rfd_date,
            incident_remarks,
            data_source,
            source_reference_id,
            created_at,
            updated_at
        )
        SELECT DISTINCT ON (UPPER(REGEXP_REPLACE(j.vehicle_number, '[^A-Za-z0-9]', '', 'g')), COALESCE(CASE WHEN j.date_of_accident ~ '^\d{4}-\d{2}-\d{2}' THEN j.date_of_accident::DATE WHEN j.date_of_accident ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(j.date_of_accident, 'DD/MM/YYYY') ELSE CURRENT_DATE END, CURRENT_DATE))
            'ACC-PORTAL-' || j.id::TEXT,
            UPPER(REGEXP_REPLACE(j.vehicle_number, '[^A-Za-z0-9]', '', 'g')),
            COALESCE(UPPER(LEFT(j.city_name, 3)), 'BLR'),
            COALESCE(
                CASE 
                    WHEN j.date_of_accident ~ '^\d{4}-\d{2}-\d{2}' THEN j.date_of_accident::DATE
                    WHEN j.date_of_accident ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(j.date_of_accident, 'DD/MM/YYYY')
                    ELSE CURRENT_DATE
                END,
                CURRENT_DATE
            ),
            j.driver_name,
            j.driver_id,
            CASE WHEN LOWER(j.fir_filed) IN ('yes', 'true', '1') THEN TRUE ELSE FALSE END,
            COALESCE(NULLIF(REGEXP_REPLACE(j.repair_cost, '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00),
            0.00,
            0.00,
            0.00,
            0.00,
            COALESCE(j.front_vehicle_photo, j.back_vehicle_photo, j.right_vehicle_photo, j.left_vehicle_photo),
            j.fir_document_copy,
            j.vendor_name,
            COALESCE(j.approval_status, j.vehicle_status, 'Portal Logged'),
            'Accident',
            COALESCE(j.insurance_status, 'Insurance'),
            NULL,
            COALESCE(j.comments, j.accident_reason),
            'PORTAL_FORM',
            j.id::TEXT,
            COALESCE(j.created_at, CURRENT_TIMESTAMP),
            COALESCE(j.updated_at, CURRENT_TIMESTAMP)
        FROM public.july_accidents_registry j
        WHERE j.vehicle_number IS NOT NULL AND j.vehicle_number != ''
        ORDER BY UPPER(REGEXP_REPLACE(j.vehicle_number, '[^A-Za-z0-9]', '', 'g')), 
                 COALESCE(CASE WHEN j.date_of_accident ~ '^\d{4}-\d{2}-\d{2}' THEN j.date_of_accident::DATE WHEN j.date_of_accident ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(j.date_of_accident, 'DD/MM/YYYY') ELSE CURRENT_DATE END, CURRENT_DATE),
                 j.id DESC
        ON CONFLICT (vehicle_number, accident_date)
        DO UPDATE SET
            driver_name = COALESCE(EXCLUDED.driver_name, core_accidents.driver_name),
            driver_partner_id = COALESCE(EXCLUDED.driver_partner_id, core_accidents.driver_partner_id),
            estimate_amount = EXCLUDED.estimate_amount,
            accident_photos_url = COALESCE(EXCLUDED.accident_photos_url, core_accidents.accident_photos_url),
            workshop_name = COALESCE(EXCLUDED.workshop_name, core_accidents.workshop_name),
            workshop_status = EXCLUDED.workshop_status,
            incident_remarks = EXCLUDED.incident_remarks,
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
CREATE OR REPLACE FUNCTION public.trg_fn_sync_sheet_accidents()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM public.refresh_core_accidents();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sheet_accidents_refresh ON public.sheet_accidents;
CREATE TRIGGER trg_sheet_accidents_refresh
AFTER INSERT OR UPDATE ON public.sheet_accidents
FOR EACH STATEMENT
EXECUTE FUNCTION public.trg_fn_sync_sheet_accidents();
