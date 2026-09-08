-- ==============================================================================
-- LETZRYD ACCIDENTS ENGINE - POSTGRESQL SCHEMA DDL & CONSOLIDATION PROCEDURES
-- ==============================================================================
-- Target Database: postgres
-- Target Schema  : public
-- Source 1       : public.sheet_accidents (Ingested from Google Sheets 'Accident vehicle report')
-- Source 2       : public.july_accidents_registry (Portal Form submissions)
-- Target         : public.core_accidents (Consolidated Master Table)
-- Host           : YOUR_DB_HOST_HERE:5432
-- Description    : Central table definitions, gapless sequencing with advisory locks (777222333),
--                  cross-source deduplication, multi-angle photo retention, and IST timestamps.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. TABLE: public.sheet_accidents (Raw Standardized Staging from Google Sheet)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sheet_accidents (
    id BIGSERIAL PRIMARY KEY,
    submission_timestamp TIMESTAMP WITHOUT TIME ZONE NOT NULL,
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
    ingested_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
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
    id BIGINT PRIMARY KEY,
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
    data_source VARCHAR(50) NOT NULL, -- 'GOOGLE_SHEET', 'PORTAL_FORM', or 'MERGED'
    source_reference_id VARCHAR(100),
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
);

-- Indexes for core_accidents
CREATE INDEX IF NOT EXISTS idx_core_accidents_veh_date ON public.core_accidents (vehicle_number, accident_date);
CREATE INDEX IF NOT EXISTS idx_core_accidents_veh ON public.core_accidents (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_accidents_date ON public.core_accidents (accident_date);
CREATE INDEX IF NOT EXISTS idx_core_accidents_partner ON public.core_accidents (driver_partner_id);
CREATE INDEX IF NOT EXISTS idx_core_accidents_city ON public.core_accidents (city_code);
CREATE INDEX IF NOT EXISTS idx_core_accidents_active ON public.core_accidents (is_deleted);

-- Active Filtered View
CREATE OR REPLACE VIEW public.active_core_accidents AS
SELECT * FROM public.core_accidents
WHERE is_deleted = FALSE;

-- ------------------------------------------------------------------------------
-- 3. HELPER FUNCTIONS FOR ACCIDENT PIPELINE
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_combine_portal_photos(
    p_front TEXT, p_back TEXT, p_right TEXT, p_left TEXT
) RETURNS TEXT AS $$
DECLARE
    v_combined TEXT;
BEGIN
    v_combined := NULLIF(CONCAT_WS(',', 
        NULLIF(TRIM(COALESCE(p_front, '')), ''), 
        NULLIF(TRIM(COALESCE(p_back, '')), ''), 
        NULLIF(TRIM(COALESCE(p_right, '')), ''), 
        NULLIF(TRIM(COALESCE(p_left, '')), '')
    ), '');
    RETURN v_combined;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ------------------------------------------------------------------------------
-- 4. REAL-TIME ROW-LEVEL DATABASE TRIGGERS WITH CROSS-SOURCE DEDUPLICATION
-- ------------------------------------------------------------------------------

-- Trigger function for sheet_accidents -> core_accidents
CREATE OR REPLACE FUNCTION public.fn_sync_sheet_accidents()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_veh VARCHAR(20);
    v_clean_city VARCHAR(10);
    v_existing_id BIGINT;
    v_existing_source VARCHAR(50);
    v_existing_ref VARCHAR(100);
    v_existing_photos TEXT;
    v_next_id BIGINT;
    v_partner_id VARCHAR(50);
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_accidents
        SET is_deleted = TRUE, 
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE source_reference_id = 'ACC-SHT-' || OLD.id::TEXT AND data_source = 'GOOGLE_SHEET';
        RETURN OLD;
    END IF;

    v_clean_veh := UPPER(REGEXP_REPLACE(COALESCE(NEW.vehicle_number, ''), '[^A-Za-z0-9]', '', 'g'));
    v_clean_city := UPPER(TRIM(COALESCE(NEW.city_code, 'BLR')));
    
    IF v_clean_veh = '' THEN
        RETURN NEW;
    END IF;

    -- Lookup Partner ID from core_partner_onboarding if not present
    v_partner_id := NEW.driver_partner_id;
    IF v_partner_id IS NULL OR TRIM(v_partner_id) = '' THEN
        SELECT partner_id INTO v_partner_id
        FROM public.core_partner_onboarding
        WHERE phone_number = RIGHT(REGEXP_REPLACE(COALESCE(NEW.driver_partner_id, ''), '[^0-9]', '', 'g'), 10)
        LIMIT 1;
    END IF;

    -- Transactional advisory lock for gapless zero-burn concurrency
    PERFORM pg_advisory_xact_lock(777222333);

    -- Priority 1: Match MERGED records or cross-source reference ID or (vehicle, date)
    SELECT id, data_source, source_reference_id, accident_photos_url
    INTO v_existing_id, v_existing_source, v_existing_ref, v_existing_photos
    FROM public.core_accidents
    WHERE (
           source_reference_id LIKE '%,' || NEW.id::TEXT || '%'
        OR source_reference_id LIKE NEW.id::TEXT || ',%'
        OR source_reference_id = 'ACC-SHT-' || NEW.id::TEXT
        OR source_reference_id = NEW.id::TEXT
        OR accident_id = 'ACC-SHT-' || NEW.id::TEXT
        OR (vehicle_number = v_clean_veh AND accident_date = NEW.accident_date)
    )
    ORDER BY 
        CASE 
            WHEN data_source = 'MERGED' THEN 1
            WHEN source_reference_id LIKE '%,' || NEW.id::TEXT || '%' OR source_reference_id LIKE NEW.id::TEXT || ',%' THEN 2
            WHEN source_reference_id = 'ACC-SHT-' || NEW.id::TEXT OR source_reference_id = NEW.id::TEXT THEN 3
            ELSE 4
        END,
        id ASC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        -- UPDATE existing row and merge data
        UPDATE public.core_accidents
        SET
            vehicle_number = v_clean_veh,
            city_code = v_clean_city,
            accident_date = NEW.accident_date,
            driver_name = COALESCE(NEW.driver_name, core_accidents.driver_name),
            driver_partner_id = COALESCE(v_partner_id, core_accidents.driver_partner_id),
            police_acknowledgement = COALESCE(NEW.police_acknowledgement, core_accidents.police_acknowledgement),
            estimate_amount = COALESCE(NEW.estimate_amount, core_accidents.estimate_amount),
            liability_amount = COALESCE(NEW.liability_amount, core_accidents.liability_amount),
            letzryd_payable_amount = COALESCE(NEW.letzryd_payable_amount, core_accidents.letzryd_payable_amount),
            total_invoice_amount = COALESCE(NEW.total_invoice, core_accidents.total_invoice_amount),
            letzryd_share_amount = COALESCE(NEW.letzryd_share, core_accidents.letzryd_share_amount),
            accident_photos_url = COALESCE(NEW.accident_photos_link, core_accidents.accident_photos_url),
            invoice_letter_url = COALESCE(NEW.invoice_letter_link, core_accidents.invoice_letter_url),
            workshop_name = COALESCE(NEW.workshop_name, core_accidents.workshop_name),
            workshop_status = COALESCE(NEW.workshop_status, core_accidents.workshop_status),
            mode_of_repair = COALESCE(NEW.mode_of_repair, core_accidents.mode_of_repair),
            type_of_payment = COALESCE(NEW.type_of_payment, core_accidents.type_of_payment),
            vehicle_rfd_date = COALESCE(NEW.vehicle_rfd_date, core_accidents.vehicle_rfd_date),
            incident_remarks = COALESCE(NEW.incident_remarks, core_accidents.incident_remarks),
            data_source = CASE WHEN v_existing_source = 'PORTAL_FORM' THEN 'MERGED' ELSE core_accidents.data_source END,
            source_reference_id = CASE 
                WHEN v_existing_ref IS NOT NULL AND v_existing_ref NOT LIKE '%' || NEW.id::TEXT || '%' 
                THEN v_existing_ref || ',' || NEW.id::TEXT 
                ELSE COALESCE(v_existing_ref, NEW.id::TEXT) 
            END,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;

        -- Clean up any secondary unmerged duplicate row for this ID if this record was merged
        DELETE FROM public.core_accidents 
        WHERE id != v_existing_id 
          AND (
              accident_id = 'ACC-SHT-' || NEW.id::TEXT
              OR (vehicle_number = v_clean_veh AND accident_date = NEW.accident_date)
          );
    ELSE
        -- INSERT new row with gapless ID
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_accidents;

        INSERT INTO public.core_accidents (
            id,
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
            v_next_id,
            'ACC-SHT-' || NEW.id::TEXT,
            v_clean_veh,
            v_clean_city,
            NEW.accident_date,
            NEW.driver_name,
            v_partner_id,
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
            'ACC-SHT-' || NEW.id::TEXT,
            FALSE,
            (COALESCE(NEW.submission_timestamp, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
    END IF;

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
DECLARE
    v_clean_veh VARCHAR(20);
    v_clean_city VARCHAR(10);
    v_accident_date DATE;
    v_photos TEXT;
    v_estimate NUMERIC(12,2);
    v_existing_id BIGINT;
    v_existing_source VARCHAR(50);
    v_existing_ref VARCHAR(100);
    v_next_id BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_accidents
        SET is_deleted = TRUE, 
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE source_reference_id = 'ACC-PORTAL-' || OLD.id::TEXT AND data_source = 'PORTAL_FORM';
        RETURN OLD;
    END IF;

    IF NEW.vehicle_number IS NOT NULL AND NEW.vehicle_number != '' THEN
        v_clean_veh := UPPER(REGEXP_REPLACE(NEW.vehicle_number, '[^A-Za-z0-9]', '', 'g'));
        v_clean_city := UPPER(TRIM(COALESCE(LEFT(NEW.city_name, 3), 'BLR')));
        
        -- Flexible Accident Date parsing
        v_accident_date := COALESCE(
            CASE 
                WHEN NEW.date_of_accident ~ '^\d{4}-\d{2}-\d{2}' THEN NEW.date_of_accident::DATE
                WHEN NEW.date_of_accident ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(NEW.date_of_accident, 'DD/MM/YYYY')
                ELSE NULL
            END,
            CURRENT_DATE
        );

        -- Combine all 4 inspection photo angles without dropping any
        v_photos := public.fn_combine_portal_photos(
            NEW.front_vehicle_photo, NEW.back_vehicle_photo, NEW.right_vehicle_photo, NEW.left_vehicle_photo
        );

        v_estimate := COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(NEW.repair_cost, ''), '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00);

        -- Transactional advisory lock for gapless zero-burn concurrency
        PERFORM pg_advisory_xact_lock(777222333);

        -- Cross-source deduplication: check matching vehicle + accident date or exact source reference
        SELECT id, data_source, source_reference_id
        INTO v_existing_id, v_existing_source, v_existing_ref
        FROM public.core_accidents
        WHERE (vehicle_number = v_clean_veh AND accident_date = v_accident_date)
           OR source_reference_id = 'ACC-PORTAL-' || NEW.id::TEXT
        ORDER BY CASE WHEN source_reference_id = 'ACC-PORTAL-' || NEW.id::TEXT THEN 1 ELSE 2 END
        LIMIT 1;

        IF v_existing_id IS NOT NULL THEN
            -- UPDATE and merge portal fields onto existing accident record
            UPDATE public.core_accidents
            SET
                city_code = COALESCE(core_accidents.city_code, v_clean_city),
                driver_name = COALESCE(core_accidents.driver_name, NEW.driver_name),
                driver_partner_id = COALESCE(core_accidents.driver_partner_id, NEW.driver_id),
                police_acknowledgement = CASE WHEN LOWER(COALESCE(NEW.fir_filed, '')) IN ('yes', 'true', '1') THEN TRUE ELSE core_accidents.police_acknowledgement END,
                estimate_amount = CASE WHEN core_accidents.estimate_amount > 0 THEN core_accidents.estimate_amount ELSE v_estimate END,
                accident_photos_url = CASE 
                    WHEN core_accidents.accident_photos_url IS NOT NULL AND v_photos IS NOT NULL 
                    THEN core_accidents.accident_photos_url || ',' || v_photos
                    ELSE COALESCE(core_accidents.accident_photos_url, v_photos)
                END,
                invoice_letter_url = COALESCE(core_accidents.invoice_letter_url, NEW.fir_document_copy),
                workshop_name = COALESCE(core_accidents.workshop_name, NEW.vendor_name),
                workshop_status = COALESCE(core_accidents.workshop_status, NEW.approval_status, NEW.vehicle_status),
                incident_remarks = COALESCE(core_accidents.incident_remarks, NEW.comments, NEW.accident_reason),
                data_source = CASE WHEN v_existing_source = 'GOOGLE_SHEET' THEN 'MERGED' ELSE 'PORTAL_FORM' END,
                source_reference_id = CASE 
                    WHEN v_existing_ref IS NOT NULL AND v_existing_ref NOT LIKE '%ACC-PORTAL-' || NEW.id::TEXT || '%' 
                    THEN v_existing_ref || ',ACC-PORTAL-' || NEW.id::TEXT 
                    ELSE COALESCE(v_existing_ref, 'ACC-PORTAL-' || NEW.id::TEXT) 
                END,
                is_deleted = FALSE,
                deleted_at = NULL,
                updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            WHERE id = v_existing_id;
        ELSE
            -- INSERT new row with gapless ID
            SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_accidents;

            INSERT INTO public.core_accidents (
                id,
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
                v_next_id,
                'ACC-PORTAL-' || NEW.id::TEXT,
                v_clean_veh,
                v_clean_city,
                v_accident_date,
                NEW.driver_name,
                NEW.driver_id,
                CASE WHEN LOWER(COALESCE(NEW.fir_filed, '')) IN ('yes', 'true', '1') THEN TRUE ELSE FALSE END,
                v_estimate,
                NULL,
                0.00,
                NULL,
                NULL,
                v_photos,
                NEW.fir_document_copy,
                NEW.vendor_name,
                COALESCE(NEW.approval_status, NEW.vehicle_status, 'Portal Logged'),
                'Accident',
                COALESCE(NEW.insurance_status, 'Insurance'),
                NULL,
                COALESCE(NEW.comments, NEW.accident_reason),
                'PORTAL_FORM',
                'ACC-PORTAL-' || NEW.id::TEXT,
                FALSE,
                (COALESCE(NEW.created_at, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            );
        END IF;
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

-- ------------------------------------------------------------------------------
-- 5. CONSOLIDATION STORED PROCEDURE: refresh_core_accidents()
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.refresh_core_accidents()
RETURNS INTEGER AS $$
DECLARE
    v_inserted_count INTEGER := 0;
    r RECORD;
    v_clean_veh VARCHAR(20);
    v_clean_city VARCHAR(10);
    v_existing_id BIGINT;
    v_existing_source VARCHAR(50);
    v_existing_ref VARCHAR(100);
    v_next_id BIGINT;
    v_partner_id VARCHAR(50);
    v_photos TEXT;
    v_estimate NUMERIC(12,2);
    v_accident_date DATE;
BEGIN
    -- Acquire advisory lock
    PERFORM pg_advisory_xact_lock(777222333);

    -- Step 5.1: Ingest/Upsert from sheet_accidents
    FOR r IN (SELECT * FROM public.sheet_accidents ORDER BY submission_timestamp ASC, id ASC) LOOP
        v_clean_veh := UPPER(REGEXP_REPLACE(COALESCE(r.vehicle_number, ''), '[^A-Za-z0-9]', '', 'g'));
        v_clean_city := UPPER(TRIM(COALESCE(r.city_code, 'BLR')));
        
        IF v_clean_veh != '' THEN
            v_partner_id := r.driver_partner_id;
            IF v_partner_id IS NULL OR TRIM(v_partner_id) = '' THEN
                SELECT partner_id INTO v_partner_id
                FROM public.core_partner_onboarding
                WHERE phone_number = RIGHT(REGEXP_REPLACE(COALESCE(r.driver_partner_id, ''), '[^0-9]', '', 'g'), 10)
                LIMIT 1;
            END IF;

            SELECT id, data_source, source_reference_id
            INTO v_existing_id, v_existing_source, v_existing_ref
            FROM public.core_accidents
            WHERE (vehicle_number = v_clean_veh AND accident_date = r.accident_date)
               OR source_reference_id = 'ACC-SHT-' || r.id::TEXT
            LIMIT 1;

            IF v_existing_id IS NOT NULL THEN
                UPDATE public.core_accidents
                SET
                    driver_name = COALESCE(r.driver_name, core_accidents.driver_name),
                    driver_partner_id = COALESCE(v_partner_id, core_accidents.driver_partner_id),
                    police_acknowledgement = COALESCE(r.police_acknowledgement, core_accidents.police_acknowledgement),
                    estimate_amount = COALESCE(r.estimate_amount, core_accidents.estimate_amount),
                    liability_amount = COALESCE(r.liability_amount, core_accidents.liability_amount),
                    letzryd_payable_amount = COALESCE(r.letzryd_payable_amount, core_accidents.letzryd_payable_amount),
                    total_invoice_amount = COALESCE(r.total_invoice, core_accidents.total_invoice_amount),
                    letzryd_share_amount = COALESCE(r.letzryd_share, core_accidents.letzryd_share_amount),
                    accident_photos_url = COALESCE(r.accident_photos_link, core_accidents.accident_photos_url),
                    invoice_letter_url = COALESCE(r.invoice_letter_link, core_accidents.invoice_letter_url),
                    workshop_name = COALESCE(r.workshop_name, core_accidents.workshop_name),
                    workshop_status = COALESCE(r.workshop_status, core_accidents.workshop_status),
                    mode_of_repair = COALESCE(r.mode_of_repair, core_accidents.mode_of_repair),
                    type_of_payment = COALESCE(r.type_of_payment, core_accidents.type_of_payment),
                    vehicle_rfd_date = COALESCE(r.vehicle_rfd_date, core_accidents.vehicle_rfd_date),
                    incident_remarks = COALESCE(r.incident_remarks, core_accidents.incident_remarks),
                    data_source = CASE WHEN v_existing_source = 'PORTAL_FORM' THEN 'MERGED' ELSE 'GOOGLE_SHEET' END,
                    source_reference_id = CASE 
                        WHEN v_existing_ref IS NOT NULL AND v_existing_ref NOT LIKE '%ACC-SHT-' || r.id::TEXT || '%' 
                        THEN v_existing_ref || ',ACC-SHT-' || r.id::TEXT 
                        ELSE COALESCE(v_existing_ref, 'ACC-SHT-' || r.id::TEXT) 
                    END,
                    is_deleted = FALSE,
                    deleted_at = NULL,
                    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                WHERE id = v_existing_id;
            ELSE
                SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_accidents;

                INSERT INTO public.core_accidents (
                    id,
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
                    v_next_id,
                    'ACC-SHT-' || r.id::TEXT,
                    v_clean_veh,
                    v_clean_city,
                    r.accident_date,
                    r.driver_name,
                    v_partner_id,
                    r.police_acknowledgement,
                    r.estimate_amount,
                    r.liability_amount,
                    r.letzryd_payable_amount,
                    r.total_invoice,
                    r.letzryd_share,
                    r.accident_photos_link,
                    r.invoice_letter_link,
                    r.workshop_name,
                    COALESCE(r.workshop_status, 'Reported'),
                    r.mode_of_repair,
                    r.type_of_payment,
                    r.vehicle_rfd_date,
                    r.incident_remarks,
                    'GOOGLE_SHEET',
                    'ACC-SHT-' || r.id::TEXT,
                    FALSE,
                    (COALESCE(r.submission_timestamp, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                );
                v_inserted_count := v_inserted_count + 1;
            END IF;
        END IF;
    END LOOP;

    -- Step 5.2: Ingest/Upsert from july_accidents_registry
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_accidents_registry') THEN
        FOR r IN (SELECT * FROM public.july_accidents_registry WHERE vehicle_number IS NOT NULL AND vehicle_number != '' ORDER BY created_at ASC, id ASC) LOOP
            v_clean_veh := UPPER(REGEXP_REPLACE(r.vehicle_number, '[^A-Za-z0-9]', '', 'g'));
            v_clean_city := UPPER(TRIM(COALESCE(LEFT(r.city_name, 3), 'BLR')));
            
            v_accident_date := COALESCE(
                CASE 
                    WHEN r.date_of_accident ~ '^\d{4}-\d{2}-\d{2}' THEN r.date_of_accident::DATE
                    WHEN r.date_of_accident ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(r.date_of_accident, 'DD/MM/YYYY')
                    ELSE NULL
                END,
                CURRENT_DATE
            );

            v_photos := public.fn_combine_portal_photos(
                r.front_vehicle_photo, r.back_vehicle_photo, r.right_vehicle_photo, r.left_vehicle_photo
            );

            v_estimate := COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(r.repair_cost, ''), '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00);

            SELECT id, data_source, source_reference_id
            INTO v_existing_id, v_existing_source, v_existing_ref
            FROM public.core_accidents
            WHERE (vehicle_number = v_clean_veh AND accident_date = v_accident_date)
               OR source_reference_id = 'ACC-PORTAL-' || r.id::TEXT
            LIMIT 1;

            IF v_existing_id IS NOT NULL THEN
                UPDATE public.core_accidents
                SET
                    driver_name = COALESCE(core_accidents.driver_name, r.driver_name),
                    driver_partner_id = COALESCE(core_accidents.driver_partner_id, r.driver_id),
                    police_acknowledgement = CASE WHEN LOWER(COALESCE(r.fir_filed, '')) IN ('yes', 'true', '1') THEN TRUE ELSE core_accidents.police_acknowledgement END,
                    estimate_amount = CASE WHEN core_accidents.estimate_amount > 0 THEN core_accidents.estimate_amount ELSE v_estimate END,
                    accident_photos_url = CASE 
                        WHEN core_accidents.accident_photos_url IS NOT NULL AND v_photos IS NOT NULL 
                        THEN core_accidents.accident_photos_url || ',' || v_photos
                        ELSE COALESCE(core_accidents.accident_photos_url, v_photos)
                    END,
                    invoice_letter_url = COALESCE(core_accidents.invoice_letter_url, r.fir_document_copy),
                    workshop_name = COALESCE(core_accidents.workshop_name, r.vendor_name),
                    workshop_status = COALESCE(core_accidents.workshop_status, r.approval_status, r.vehicle_status),
                    incident_remarks = COALESCE(core_accidents.incident_remarks, r.comments, r.accident_reason),
                    data_source = CASE WHEN v_existing_source = 'GOOGLE_SHEET' THEN 'MERGED' ELSE 'PORTAL_FORM' END,
                    source_reference_id = CASE 
                        WHEN v_existing_ref IS NOT NULL AND v_existing_ref NOT LIKE '%ACC-PORTAL-' || r.id::TEXT || '%' 
                        THEN v_existing_ref || ',ACC-PORTAL-' || r.id::TEXT 
                        ELSE COALESCE(v_existing_ref, 'ACC-PORTAL-' || r.id::TEXT) 
                    END,
                    is_deleted = FALSE,
                    deleted_at = NULL,
                    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                WHERE id = v_existing_id;
            ELSE
                SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_accidents;

                INSERT INTO public.core_accidents (
                    id,
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
                    v_next_id,
                    'ACC-PORTAL-' || r.id::TEXT,
                    v_clean_veh,
                    v_clean_city,
                    v_accident_date,
                    r.driver_name,
                    r.driver_id,
                    CASE WHEN LOWER(COALESCE(r.fir_filed, '')) IN ('yes', 'true', '1') THEN TRUE ELSE FALSE END,
                    v_estimate,
                    NULL,
                    0.00,
                    NULL,
                    NULL,
                    v_photos,
                    r.fir_document_copy,
                    r.vendor_name,
                    COALESCE(r.approval_status, r.vehicle_status, 'Portal Logged'),
                    'Accident',
                    COALESCE(r.insurance_status, 'Insurance'),
                    NULL,
                    COALESCE(r.comments, r.accident_reason),
                    'PORTAL_FORM',
                    'ACC-PORTAL-' || r.id::TEXT,
                    FALSE,
                    (COALESCE(r.created_at, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                );
                v_inserted_count := v_inserted_count + 1;
            END IF;
        END LOOP;
    END IF;

    RETURN v_inserted_count;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------------------------
-- 6. ONE-TIME MIGRATION & RECONCILIATION SCRIPT FOR ACCIDENTS
-- ------------------------------------------------------------------------------

-- Fix 6.1: Cleanly deduplicate existing cross-source duplicate rows in core_accidents
WITH ranked AS (
    SELECT id, vehicle_number, accident_date,
           ROW_NUMBER() OVER (PARTITION BY vehicle_number, accident_date ORDER BY 
               CASE WHEN data_source = 'MERGED' THEN 1 WHEN data_source = 'PORTAL_FORM' THEN 2 ELSE 3 END, id ASC) AS rn
    FROM public.core_accidents
    WHERE is_deleted = FALSE
)
UPDATE public.core_accidents c
SET is_deleted = TRUE,
    deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
FROM ranked r
WHERE c.id = r.id AND r.rn > 1;

-- Fix 6.2: Backfill missing multi-angle photos from portal table
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_accidents_registry') THEN
        UPDATE public.core_accidents c
        SET accident_photos_url = public.fn_combine_portal_photos(
                j.front_vehicle_photo, j.back_vehicle_photo, j.right_vehicle_photo, j.left_vehicle_photo
            ),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        FROM public.july_accidents_registry j
        WHERE c.source_reference_id LIKE '%ACC-PORTAL-' || j.id::TEXT || '%'
          AND (c.accident_photos_url IS NULL OR c.accident_photos_url = j.front_vehicle_photo);
    END IF;
END $$;

