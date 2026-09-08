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
    liability_amount NUMERIC(12,2),
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
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_core_accidents_source UNIQUE (data_source, source_reference_id)
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
    -- Step 1: Ingest/Upsert from Google Sheet Staging (sheet_accidents) - Keyed by source record ID to prevent overwriting same-day accidents
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
        is_deleted,
        created_at,
        updated_at
    )
    SELECT
        'ACC-SHT-' || s.id::TEXT,
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
        FALSE,
        s.submission_timestamp,
        s.updated_at
    FROM public.sheet_accidents s
    LEFT JOIN LATERAL (
        SELECT partner_id 
        FROM public.core_partner_onboarding 
        WHERE phone_number = RIGHT(s.driver_partner_id, 10) 
        LIMIT 1
    ) p ON TRUE
    ON CONFLICT (data_source, source_reference_id)
    DO UPDATE SET
        vehicle_number = EXCLUDED.vehicle_number,
        city_code = EXCLUDED.city_code,
        accident_date = EXCLUDED.accident_date,
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
        mode_of_repair = COALESCE(EXCLUDED.mode_of_repair, core_accidents.mode_of_repair),
        type_of_payment = COALESCE(EXCLUDED.type_of_payment, core_accidents.type_of_payment),
        vehicle_rfd_date = COALESCE(EXCLUDED.vehicle_rfd_date, core_accidents.vehicle_rfd_date),
        incident_remarks = EXCLUDED.incident_remarks,
        is_deleted = FALSE,
        deleted_at = NULL,
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
            is_deleted,
            created_at,
            updated_at
        )
        SELECT
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
            NULL,
            0.00,
            NULL,
            NULL,
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
            FALSE,
            COALESCE(j.created_at, CURRENT_TIMESTAMP),
            COALESCE(j.updated_at, CURRENT_TIMESTAMP)
        FROM public.july_accidents_registry j
        WHERE j.vehicle_number IS NOT NULL AND j.vehicle_number != ''
        ON CONFLICT (data_source, source_reference_id)
        DO UPDATE SET
            vehicle_number = EXCLUDED.vehicle_number,
            city_code = EXCLUDED.city_code,
            accident_date = EXCLUDED.accident_date,
            driver_name = COALESCE(EXCLUDED.driver_name, core_accidents.driver_name),
            driver_partner_id = COALESCE(EXCLUDED.driver_partner_id, core_accidents.driver_partner_id),
            estimate_amount = EXCLUDED.estimate_amount,
            accident_photos_url = COALESCE(EXCLUDED.accident_photos_url, core_accidents.accident_photos_url),
            invoice_letter_url = COALESCE(EXCLUDED.invoice_letter_url, core_accidents.invoice_letter_url),
            workshop_name = COALESCE(EXCLUDED.workshop_name, core_accidents.workshop_name),
            workshop_status = EXCLUDED.workshop_status,
            incident_remarks = EXCLUDED.incident_remarks,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = CURRENT_TIMESTAMP;
    END IF;

    GET DIAGNOSTICS v_inserted_count = ROW_COUNT;
    RETURN v_inserted_count;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------------------------
-- 4. REAL-TIME ROW-LEVEL DATABASE TRIGGERS
-- ------------------------------------------------------------------------------

-- Trigger function for sheet_accidents -> core_accidents
CREATE OR REPLACE FUNCTION public.fn_sync_sheet_accidents()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_accidents
        SET is_deleted = TRUE, deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE source_reference_id = OLD.id::TEXT AND data_source = 'GOOGLE_SHEET';
        RETURN OLD;
    END IF;

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
        is_deleted,
        created_at,
        updated_at
    ) VALUES (
        'ACC-SHT-' || NEW.id::TEXT,
        UPPER(NEW.vehicle_number),
        UPPER(NEW.city_code),
        NEW.accident_date,
        NEW.driver_name,
        NEW.driver_partner_id,
        NEW.police_acknowledgement,
        NEW.estimate_amount,
        NEW.liability_amount,
        NEW.letzryd_payable_amount,
        NEW.total_invoice,
        NEW.letzryd_share,
        NEW.accident_photos_link,
        NEW.invoice_letter_link,
        NEW.workshop_name,
        COALESCE(NEW.workshop_status, 'Reported'),
        NEW.mode_of_repair,
        NEW.type_of_payment,
        NEW.vehicle_rfd_date,
        NEW.incident_remarks,
        'GOOGLE_SHEET',
        NEW.id::TEXT,
        FALSE,
        COALESCE(NEW.submission_timestamp, CURRENT_TIMESTAMP),
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (data_source, source_reference_id)
    DO UPDATE SET
        vehicle_number = EXCLUDED.vehicle_number,
        city_code = EXCLUDED.city_code,
        accident_date = EXCLUDED.accident_date,
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
        mode_of_repair = COALESCE(EXCLUDED.mode_of_repair, core_accidents.mode_of_repair),
        type_of_payment = COALESCE(EXCLUDED.type_of_payment, core_accidents.type_of_payment),
        vehicle_rfd_date = COALESCE(EXCLUDED.vehicle_rfd_date, core_accidents.vehicle_rfd_date),
        incident_remarks = EXCLUDED.incident_remarks,
        is_deleted = FALSE,
        deleted_at = NULL,
        updated_at = CURRENT_TIMESTAMP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sheet_accidents_sync ON public.sheet_accidents;
CREATE TRIGGER trg_sheet_accidents_sync
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_accidents
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_sheet_accidents();

-- Trigger function for july_accidents_registry -> core_accidents
CREATE OR REPLACE FUNCTION public.fn_sync_july_accidents_registry()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_accidents
        SET is_deleted = TRUE, deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE source_reference_id = OLD.id::TEXT AND data_source = 'PORTAL_FORM';
        RETURN OLD;
    END IF;

    IF NEW.vehicle_number IS NOT NULL AND NEW.vehicle_number != '' THEN
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
            is_deleted,
            created_at,
            updated_at
        ) VALUES (
            'ACC-PORTAL-' || NEW.id::TEXT,
            UPPER(REGEXP_REPLACE(NEW.vehicle_number, '[^A-Za-z0-9]', '', 'g')),
            COALESCE(UPPER(LEFT(NEW.city_name, 3)), 'BLR'),
            COALESCE(
                CASE 
                    WHEN NEW.date_of_accident ~ '^\d{4}-\d{2}-\d{2}' THEN NEW.date_of_accident::DATE
                    WHEN NEW.date_of_accident ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(NEW.date_of_accident, 'DD/MM/YYYY')
                    ELSE CURRENT_DATE
                END,
                CURRENT_DATE
            ),
            NEW.driver_name,
            NEW.driver_id,
            CASE WHEN LOWER(NEW.fir_filed) IN ('yes', 'true', '1') THEN TRUE ELSE FALSE END,
            COALESCE(NULLIF(REGEXP_REPLACE(NEW.repair_cost, '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00),
            NULL,
            0.00,
            NULL,
            NULL,
            COALESCE(NEW.front_vehicle_photo, NEW.back_vehicle_photo, NEW.right_vehicle_photo, NEW.left_vehicle_photo),
            NEW.fir_document_copy,
            NEW.vendor_name,
            COALESCE(NEW.approval_status, NEW.vehicle_status, 'Portal Logged'),
            'Accident',
            COALESCE(NEW.insurance_status, 'Insurance'),
            NULL,
            COALESCE(NEW.comments, NEW.accident_reason),
            'PORTAL_FORM',
            NEW.id::TEXT,
            FALSE,
            COALESCE(NEW.created_at, CURRENT_TIMESTAMP),
            CURRENT_TIMESTAMP
        )
        ON CONFLICT (data_source, source_reference_id)
        DO UPDATE SET
            vehicle_number = EXCLUDED.vehicle_number,
            city_code = EXCLUDED.city_code,
            accident_date = EXCLUDED.accident_date,
            driver_name = COALESCE(EXCLUDED.driver_name, core_accidents.driver_name),
            driver_partner_id = COALESCE(EXCLUDED.driver_partner_id, core_accidents.driver_partner_id),
            estimate_amount = EXCLUDED.estimate_amount,
            accident_photos_url = COALESCE(EXCLUDED.accident_photos_url, core_accidents.accident_photos_url),
            invoice_letter_url = COALESCE(EXCLUDED.invoice_letter_url, core_accidents.invoice_letter_url),
            workshop_name = COALESCE(EXCLUDED.workshop_name, core_accidents.workshop_name),
            workshop_status = EXCLUDED.workshop_status,
            incident_remarks = EXCLUDED.incident_remarks,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = CURRENT_TIMESTAMP;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_accidents_registry') THEN
        DROP TRIGGER IF EXISTS trg_july_accidents_registry_sync ON public.july_accidents_registry;
        CREATE TRIGGER trg_july_accidents_registry_sync
        AFTER INSERT OR UPDATE OR DELETE ON public.july_accidents_registry
        FOR EACH ROW EXECUTE FUNCTION public.fn_sync_july_accidents_registry();
    END IF;
END $$;
