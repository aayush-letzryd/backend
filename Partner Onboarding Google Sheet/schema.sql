-- =============================================================================
-- LetzRyd Partner Onboarding Data Pipeline - PostgreSQL Database Schema
-- =============================================================================
-- Target Database: postgres
-- Target Schema  : public
-- Source Tables  : sheet_driver_onboarding (Google Sheet) + july_form_onboarding (Portal Form)
-- Master Table   : core_partner_onboarding
-- Host           : YOUR_DB_HOST_HERE:5432
-- Description    : Central table definitions, gapless sequencing with advisory locks,
--                  IST timestamp contracts, performance indexes, and automated
--                  consolidation procedures for LetzRyd Driver-Partner Onboarding.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. LANDING TABLE: public.sheet_driver_onboarding (Google Sheets Ingestion)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.sheet_driver_onboarding (
    id BIGSERIAL PRIMARY KEY,
    submission_timestamp TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    submitter_email VARCHAR(255),
    city VARCHAR(100),
    onboarding_type VARCHAR(50) DEFAULT 'Individual',
    lead_source VARCHAR(100),
    driver_plan VARCHAR(100),
    driver_name VARCHAR(255) NOT NULL,
    driver_phone VARCHAR(20) NOT NULL,
    whatsapp_phone VARCHAR(20),
    emergency_name VARCHAR(255),
    emergency_phone VARCHAR(20),
    reference_name VARCHAR(255),
    reference_phone VARCHAR(20),
    father_name VARCHAR(255),
    dob DATE,
    aadhaar_address TEXT,
    present_address TEXT,
    pan_number VARCHAR(50),
    aadhaar_number VARCHAR(50),
    dl_expiry DATE,
    dl_number VARCHAR(100),
    upi_id VARCHAR(100),
    pan_aadhaar_linked VARCHAR(50),
    dl_front TEXT,
    dl_back TEXT,
    aadhaar_front TEXT,
    aadhaar_back TEXT,
    pan_card TEXT,
    local_address_proof TEXT,
    selfie_photo TEXT,
    pan_aadhaar_photo TEXT,
    bank_details_doc TEXT,
    referral_phone VARCHAR(20),
    referral_name VARCHAR(255),
    account_name VARCHAR(255),
    account_number VARCHAR(100),
    ifsc_code VARCHAR(50),
    deposit_amount NUMERIC(12, 2) DEFAULT 0.00,
    partner_id VARCHAR(50),
    sheet_row_number INTEGER,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    CONSTRAINT uq_sheet_driver_onboarding UNIQUE (submission_timestamp, driver_phone)
);

-- Performance Indexes for sheet_driver_onboarding
CREATE INDEX IF NOT EXISTS idx_sheet_driver_phone ON public.sheet_driver_onboarding (driver_phone);
CREATE INDEX IF NOT EXISTS idx_sheet_driver_dl ON public.sheet_driver_onboarding (dl_number);
CREATE INDEX IF NOT EXISTS idx_sheet_driver_aadhaar ON public.sheet_driver_onboarding (aadhaar_number);
CREATE INDEX IF NOT EXISTS idx_sheet_driver_pan ON public.sheet_driver_onboarding (pan_number);
CREATE INDEX IF NOT EXISTS idx_sheet_driver_city ON public.sheet_driver_onboarding (city);
CREATE INDEX IF NOT EXISTS idx_sheet_driver_ts ON public.sheet_driver_onboarding (submission_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_sheet_driver_partner_id ON public.sheet_driver_onboarding (partner_id);

-- -----------------------------------------------------------------------------
-- 2. MASTER UNIFIED TABLE: public.core_partner_onboarding
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.core_partner_onboarding (
    id BIGINT PRIMARY KEY,
    partner_id VARCHAR(50) UNIQUE,
    driver_name VARCHAR(255) NOT NULL,
    phone_number VARCHAR(20) NOT NULL UNIQUE,
    whatsapp_number VARCHAR(20),
    dob DATE,
    city VARCHAR(100),
    onboarding_type VARCHAR(50) DEFAULT 'Individual',
    lead_source VARCHAR(100),
    driver_plan VARCHAR(100),
    father_name VARCHAR(255),
    present_address TEXT,
    permanent_address TEXT,
    emergency_name VARCHAR(255),
    emergency_phone VARCHAR(20),
    emergency_relationship VARCHAR(50),
    reference_name VARCHAR(255),
    reference_phone VARCHAR(20),
    dl_number VARCHAR(100),
    dl_expiry_date DATE,
    pan_number VARCHAR(50),
    aadhaar_number VARCHAR(50),
    pan_aadhaar_linked VARCHAR(50),
    bank_name VARCHAR(255),
    account_name VARCHAR(255),
    account_number VARCHAR(100),
    ifsc_code VARCHAR(50),
    upi_id VARCHAR(100),
    security_deposit NUMERIC(12, 2) DEFAULT 0.00,
    selfie_photo TEXT,
    dl_front TEXT,
    dl_back TEXT,
    aadhaar_card_front TEXT,
    aadhaar_card_back TEXT,
    pan_card_photo TEXT,
    local_address_proof TEXT,
    cancelled_cheque_photo TEXT,
    approval_status VARCHAR(50) DEFAULT 'Draft',
    is_documents_verified BOOLEAN DEFAULT FALSE,
    is_spring_verified BOOLEAN DEFAULT FALSE,
    source_origin VARCHAR(50) NOT NULL, -- 'GOOGLE_SHEET', 'PORTAL_FORM', or 'MERGED'
    source_sheet_row_id BIGINT,
    source_portal_form_id INTEGER,
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    onboarding_timestamp TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
);

-- Performance Indexes for core_partner_onboarding
CREATE INDEX IF NOT EXISTS idx_core_partner_phone ON public.core_partner_onboarding (phone_number);
CREATE INDEX IF NOT EXISTS idx_core_partner_dl ON public.core_partner_onboarding (dl_number);
CREATE INDEX IF NOT EXISTS idx_core_partner_aadhaar ON public.core_partner_onboarding (aadhaar_number);
CREATE INDEX IF NOT EXISTS idx_core_partner_pan ON public.core_partner_onboarding (pan_number);
CREATE INDEX IF NOT EXISTS idx_core_partner_city ON public.core_partner_onboarding (city);
CREATE INDEX IF NOT EXISTS idx_core_partner_status ON public.core_partner_onboarding (approval_status);
CREATE INDEX IF NOT EXISTS idx_core_partner_ts ON public.core_partner_onboarding (onboarding_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_core_partner_active ON public.core_partner_onboarding (is_deleted);

-- Active Filtered View for Downstream Reporting & Operations
CREATE OR REPLACE VIEW public.active_core_partner_onboarding AS
SELECT * FROM public.core_partner_onboarding
WHERE is_deleted = FALSE;

-- -----------------------------------------------------------------------------
-- 3. HELPER FUNCTIONS: Canonical Partner ID & Safe Date Casting
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_canonical_partner_id(p_city VARCHAR, p_phone VARCHAR)
RETURNS VARCHAR AS $$
DECLARE
    v_clean_phone VARCHAR(10);
    v_prefix VARCHAR(10);
    v_clean_city VARCHAR(100);
BEGIN
    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(p_phone, ''), '[^0-9]', '', 'g'), 10);
    IF LENGTH(v_clean_phone) < 10 THEN
        v_clean_phone := '0000000000';
    END IF;

    v_clean_city := UPPER(TRIM(COALESCE(p_city, 'BLR')));
    
    v_prefix := CASE 
        WHEN v_clean_city ~* '^(BANGALORE|BENGALURU|BLR)' THEN 'BLR'
        WHEN v_clean_city ~* '^(HYDERABAD|HYD)' THEN 'HYD'
        WHEN v_clean_city ~* '^(MUMBAI|MUM|BOMBAY)' THEN 'MUM'
        WHEN v_clean_city ~* '^(PUNE|PUN)' THEN 'PUN'
        WHEN v_clean_city ~* '^(DELHI|NEW DELHI|DEL)' THEN 'DEL'
        WHEN v_clean_city ~* '^(CHENNAI|MADRAS|CHN)' THEN 'CHN'
        WHEN v_clean_city ~* '^(AHMEDABAD|AHM)' THEN 'AHM'
        WHEN v_clean_city ~* '^(KOCHI|COCHIN|KOC)' THEN 'KOC'
        WHEN v_clean_city ~* '^(KOLKATA|CALCUTTA|CCU|KOL)' THEN 'KOL'
        ELSE UPPER(LEFT(v_clean_city, 3))
    END;

    RETURN 'LETZ' || v_prefix || v_clean_phone;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.fn_safe_cast_date(p_val VARCHAR)
RETURNS DATE AS $$
BEGIN
    IF p_val IS NULL OR TRIM(p_val) = '' OR TRIM(p_val) = '-' OR LOWER(TRIM(p_val)) = 'na' THEN
        RETURN NULL;
    END IF;
    RETURN p_val::DATE;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- -----------------------------------------------------------------------------
-- 4. REAL-TIME ROW-LEVEL DATABASE TRIGGERS WITH ZERO-BURN GAPLESS SEQUENCING
-- -----------------------------------------------------------------------------

-- Trigger function for sheet_driver_onboarding -> core_partner_onboarding
CREATE OR REPLACE FUNCTION public.fn_sync_sheet_driver_onboarding()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone VARCHAR(20);
    v_existing_id BIGINT;
    v_existing_origin VARCHAR(50);
    v_next_id BIGINT;
    v_partner_id VARCHAR(50);
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_partner_onboarding
        SET is_deleted = TRUE, 
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE source_sheet_row_id = OLD.id AND source_origin = 'GOOGLE_SHEET';
        RETURN OLD;
    END IF;

    IF NEW.driver_phone IS NOT NULL THEN
        v_clean_phone := RIGHT(REGEXP_REPLACE(NEW.driver_phone, '[^0-9]', '', 'g'), 10);
        IF LENGTH(v_clean_phone) = 10 THEN
            PERFORM pg_advisory_xact_lock(777111222);

            v_partner_id := public.fn_canonical_partner_id(NEW.city, v_clean_phone);

            SELECT id, source_origin INTO v_existing_id, v_existing_origin
            FROM public.core_partner_onboarding
            WHERE phone_number = v_clean_phone;

            IF v_existing_id IS NOT NULL THEN
                UPDATE public.core_partner_onboarding
                SET
                    partner_id = COALESCE(core_partner_onboarding.partner_id, v_partner_id),
                    driver_name = UPPER(NEW.driver_name),
                    whatsapp_number = COALESCE(RIGHT(REGEXP_REPLACE(NEW.whatsapp_phone, '[^0-9]', '', 'g'), 10), v_clean_phone, core_partner_onboarding.whatsapp_number),
                    dob = COALESCE(NEW.dob, core_partner_onboarding.dob),
                    city = COALESCE(NEW.city, core_partner_onboarding.city),
                    onboarding_type = COALESCE(NEW.onboarding_type, core_partner_onboarding.onboarding_type),
                    father_name = COALESCE(NEW.father_name, core_partner_onboarding.father_name),
                    present_address = COALESCE(NEW.present_address, NEW.aadhaar_address, core_partner_onboarding.present_address),
                    permanent_address = COALESCE(NEW.aadhaar_address, core_partner_onboarding.permanent_address),
                    emergency_name = COALESCE(NEW.emergency_name, core_partner_onboarding.emergency_name),
                    emergency_phone = COALESCE(NEW.emergency_phone, core_partner_onboarding.emergency_phone),
                    reference_name = COALESCE(NEW.reference_name, core_partner_onboarding.reference_name),
                    reference_phone = COALESCE(NEW.reference_phone, core_partner_onboarding.reference_phone),
                    dl_number = COALESCE(NEW.dl_number, core_partner_onboarding.dl_number),
                    dl_expiry_date = COALESCE(NEW.dl_expiry, core_partner_onboarding.dl_expiry_date),
                    pan_number = COALESCE(NEW.pan_number, core_partner_onboarding.pan_number),
                    aadhaar_number = COALESCE(REGEXP_REPLACE(NEW.aadhaar_number, '\s+', '', 'g'), core_partner_onboarding.aadhaar_number),
                    pan_aadhaar_linked = COALESCE(NEW.pan_aadhaar_linked, core_partner_onboarding.pan_aadhaar_linked),
                    account_name = COALESCE(NEW.account_name, core_partner_onboarding.account_name),
                    account_number = COALESCE(NEW.account_number, core_partner_onboarding.account_number),
                    ifsc_code = COALESCE(NEW.ifsc_code, core_partner_onboarding.ifsc_code),
                    upi_id = COALESCE(NEW.upi_id, core_partner_onboarding.upi_id),
                    selfie_photo = COALESCE(NEW.selfie_photo, core_partner_onboarding.selfie_photo),
                    dl_front = COALESCE(NEW.dl_front, core_partner_onboarding.dl_front),
                    dl_back = COALESCE(NEW.dl_back, core_partner_onboarding.dl_back),
                    aadhaar_card_front = COALESCE(NEW.aadhaar_front, core_partner_onboarding.aadhaar_card_front),
                    aadhaar_card_back = COALESCE(NEW.aadhaar_back, core_partner_onboarding.aadhaar_card_back),
                    pan_card_photo = COALESCE(NEW.pan_card, core_partner_onboarding.pan_card_photo),
                    local_address_proof = COALESCE(NEW.local_address_proof, core_partner_onboarding.local_address_proof),
                    cancelled_cheque_photo = COALESCE(NEW.bank_details_doc, core_partner_onboarding.cancelled_cheque_photo),
                    security_deposit = CASE WHEN COALESCE(NEW.deposit_amount, 0.00) > 0 THEN NEW.deposit_amount ELSE core_partner_onboarding.security_deposit END,
                    source_sheet_row_id = NEW.id,
                    source_origin = CASE WHEN v_existing_origin IN ('PORTAL_FORM', 'MERGED') THEN 'MERGED' ELSE 'GOOGLE_SHEET' END,
                    is_deleted = FALSE,
                    deleted_at = NULL,
                    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                WHERE id = v_existing_id;
            ELSE
                SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_partner_onboarding;

                INSERT INTO public.core_partner_onboarding (
                    id, partner_id, driver_name, phone_number, whatsapp_number, dob,
                    city, onboarding_type, lead_source, driver_plan, father_name,
                    present_address, permanent_address, emergency_name, emergency_phone,
                    reference_name, reference_phone, dl_number, dl_expiry_date,
                    pan_number, aadhaar_number, pan_aadhaar_linked, account_name,
                    account_number, ifsc_code, upi_id, security_deposit,
                    selfie_photo, dl_front, dl_back, aadhaar_card_front, aadhaar_card_back,
                    pan_card_photo, local_address_proof, cancelled_cheque_photo, approval_status,
                    source_origin, source_sheet_row_id, onboarding_timestamp, is_deleted, created_at, updated_at
                ) VALUES (
                    v_next_id,
                    v_partner_id,
                    UPPER(NEW.driver_name),
                    v_clean_phone,
                    COALESCE(RIGHT(REGEXP_REPLACE(NEW.whatsapp_phone, '[^0-9]', '', 'g'), 10), v_clean_phone),
                    NEW.dob,
                    COALESCE(NEW.city, 'Bengaluru'),
                    COALESCE(NEW.onboarding_type, 'Individual'),
                    NEW.lead_source,
                    NEW.driver_plan,
                    NEW.father_name,
                    COALESCE(NEW.present_address, NEW.aadhaar_address),
                    NEW.aadhaar_address,
                    NEW.emergency_name,
                    NEW.emergency_phone,
                    NEW.reference_name,
                    NEW.reference_phone,
                    NEW.dl_number,
                    NEW.dl_expiry,
                    NEW.pan_number,
                    REGEXP_REPLACE(NEW.aadhaar_number, '\s+', '', 'g'),
                    NEW.pan_aadhaar_linked,
                    NEW.account_name,
                    NEW.account_number,
                    NEW.ifsc_code,
                    NEW.upi_id,
                    COALESCE(NEW.deposit_amount, 0.00),
                    NEW.selfie_photo,
                    NEW.dl_front,
                    NEW.dl_back,
                    NEW.aadhaar_front,
                    NEW.aadhaar_back,
                    NEW.pan_card,
                    NEW.local_address_proof,
                    NEW.bank_details_doc,
                    'Draft',
                    'GOOGLE_SHEET',
                    NEW.id,
                    NEW.submission_timestamp,
                    FALSE,
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sheet_driver_onboarding_sync ON public.sheet_driver_onboarding;
CREATE TRIGGER trg_sheet_driver_onboarding_sync
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_driver_onboarding
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_sheet_driver_onboarding();

-- Trigger function for july_form_onboarding -> core_partner_onboarding
CREATE OR REPLACE FUNCTION public.fn_sync_july_form_onboarding()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone VARCHAR(20);
    v_existing_id BIGINT;
    v_existing_origin VARCHAR(50);
    v_next_id BIGINT;
    v_partner_id VARCHAR(50);
    v_parsed_dob DATE;
    v_parsed_dl_exp DATE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_partner_onboarding
        SET is_deleted = TRUE, 
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE source_portal_form_id = OLD.id AND source_origin = 'PORTAL_FORM';
        RETURN OLD;
    END IF;

    IF NEW.phone_number IS NOT NULL THEN
        v_clean_phone := RIGHT(REGEXP_REPLACE(NEW.phone_number, '[^0-9]', '', 'g'), 10);
        IF LENGTH(v_clean_phone) = 10 THEN
            PERFORM pg_advisory_xact_lock(777111222);

            v_partner_id := public.fn_canonical_partner_id(NEW.city, v_clean_phone);
            v_parsed_dob := public.fn_safe_cast_date(NEW.dob);
            v_parsed_dl_exp := public.fn_safe_cast_date(NEW.dl_expiry_date);

            SELECT id, source_origin INTO v_existing_id, v_existing_origin
            FROM public.core_partner_onboarding
            WHERE phone_number = v_clean_phone;

            IF v_existing_id IS NOT NULL THEN
                UPDATE public.core_partner_onboarding
                SET
                    partner_id = COALESCE(core_partner_onboarding.partner_id, v_partner_id),
                    driver_name = UPPER(NEW.driver_name),
                    whatsapp_number = COALESCE(RIGHT(REGEXP_REPLACE(COALESCE(NEW.whatsapp_number, NEW.phone_number), '[^0-9]', '', 'g'), 10), core_partner_onboarding.whatsapp_number),
                    dob = COALESCE(v_parsed_dob, core_partner_onboarding.dob),
                    father_name = COALESCE(NEW.father_name, core_partner_onboarding.father_name),
                    city = COALESCE(NEW.city, core_partner_onboarding.city),
                    present_address = COALESCE(NEW.present_address, core_partner_onboarding.present_address),
                    permanent_address = COALESCE(NEW.permanent_address, core_partner_onboarding.permanent_address),
                    emergency_name = COALESCE(NEW.emergency_name, core_partner_onboarding.emergency_name),
                    emergency_phone = COALESCE(NEW.emergency_phone, core_partner_onboarding.emergency_phone),
                    emergency_relationship = COALESCE(NEW.emergency_relationship, core_partner_onboarding.emergency_relationship),
                    dl_number = COALESCE(NEW.dl_number, core_partner_onboarding.dl_number),
                    dl_expiry_date = COALESCE(v_parsed_dl_exp, core_partner_onboarding.dl_expiry_date),
                    pan_number = COALESCE(NEW.pan_number, core_partner_onboarding.pan_number),
                    aadhaar_number = COALESCE(REGEXP_REPLACE(NEW.aadhaar_number, '\s+', '', 'g'), core_partner_onboarding.aadhaar_number),
                    pan_aadhaar_linked = COALESCE(NEW.pan_aadhaar_linked, core_partner_onboarding.pan_aadhaar_linked),
                    bank_name = COALESCE(NEW.bank_name, core_partner_onboarding.bank_name),
                    account_name = COALESCE(NEW.account_name, core_partner_onboarding.account_name),
                    account_number = COALESCE(NEW.account_number, core_partner_onboarding.account_number),
                    ifsc_code = COALESCE(NEW.ifsc_code, core_partner_onboarding.ifsc_code),
                    upi_id = COALESCE(NEW.upi_id, core_partner_onboarding.upi_id),
                    selfie_photo = COALESCE(NEW.selfie_photo, core_partner_onboarding.selfie_photo),
                    dl_front = COALESCE(NEW.dl_front, core_partner_onboarding.dl_front),
                    dl_back = COALESCE(NEW.dl_back, core_partner_onboarding.dl_back),
                    aadhaar_card_front = COALESCE(NEW.aadhaar_card_front, core_partner_onboarding.aadhaar_card_front),
                    aadhaar_card_back = COALESCE(NEW.aadhaar_card_back, core_partner_onboarding.aadhaar_card_back),
                    pan_card_photo = COALESCE(NEW.pan_card_photo, core_partner_onboarding.pan_card_photo),
                    local_address_proof = COALESCE(NEW.local_address_proof, core_partner_onboarding.local_address_proof),
                    cancelled_cheque_photo = COALESCE(NEW.cancelled_cheque_photo, core_partner_onboarding.cancelled_cheque_photo),
                    approval_status = COALESCE(NEW.approval_status, core_partner_onboarding.approval_status),
                    is_documents_verified = COALESCE(NEW.documents_verified, core_partner_onboarding.is_documents_verified),
                    is_spring_verified = COALESCE(NEW.is_spring_verified, core_partner_onboarding.is_spring_verified),
                    source_portal_form_id = NEW.id,
                    source_origin = CASE WHEN v_existing_origin IN ('GOOGLE_SHEET', 'MERGED') THEN 'MERGED' ELSE 'PORTAL_FORM' END,
                    is_deleted = FALSE,
                    deleted_at = NULL,
                    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                WHERE id = v_existing_id;
            ELSE
                SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_partner_onboarding;

                INSERT INTO public.core_partner_onboarding (
                    id, partner_id, driver_name, phone_number, whatsapp_number,
                    dob, father_name, city, present_address, permanent_address, emergency_name, emergency_phone,
                    emergency_relationship, dl_number, dl_expiry_date, lead_source, pan_number, aadhaar_number,
                    pan_aadhaar_linked, bank_name, account_name, account_number, ifsc_code,
                    upi_id, selfie_photo, dl_front, dl_back, aadhaar_card_front,
                    aadhaar_card_back, pan_card_photo, local_address_proof, cancelled_cheque_photo, approval_status,
                    is_documents_verified, is_spring_verified, source_origin, source_portal_form_id,
                    onboarding_timestamp, is_deleted, created_at, updated_at
                ) VALUES (
                    v_next_id,
                    v_partner_id,
                    UPPER(NEW.driver_name),
                    v_clean_phone,
                    RIGHT(REGEXP_REPLACE(COALESCE(NEW.whatsapp_number, NEW.phone_number), '[^0-9]', '', 'g'), 10),
                    v_parsed_dob,
                    NEW.father_name,
                    COALESCE(NEW.city, 'Bengaluru'),
                    NEW.present_address,
                    NEW.permanent_address,
                    NEW.emergency_name,
                    NEW.emergency_phone,
                    NEW.emergency_relationship,
                    NEW.dl_number,
                    v_parsed_dl_exp,
                    NEW.lead_source,
                    NEW.pan_number,
                    REGEXP_REPLACE(NEW.aadhaar_number, '\s+', '', 'g'),
                    NEW.pan_aadhaar_linked,
                    NEW.bank_name,
                    NEW.account_name,
                    NEW.account_number,
                    NEW.ifsc_code,
                    NEW.upi_id,
                    NEW.selfie_photo,
                    NEW.dl_front,
                    NEW.dl_back,
                    NEW.aadhaar_card_front,
                    NEW.aadhaar_card_back,
                    NEW.pan_card_photo,
                    NEW.local_address_proof,
                    NEW.cancelled_cheque_photo,
                    COALESCE(NEW.approval_status, 'Draft'),
                    COALESCE(NEW.documents_verified, FALSE),
                    COALESCE(NEW.is_spring_verified, FALSE),
                    'PORTAL_FORM',
                    NEW.id,
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
                    FALSE,
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_form_onboarding') THEN
        DROP TRIGGER IF EXISTS trg_july_form_onboarding_sync ON public.july_form_onboarding;
        CREATE TRIGGER trg_july_form_onboarding_sync
        AFTER INSERT OR UPDATE OR DELETE ON public.july_form_onboarding
        FOR EACH ROW EXECUTE FUNCTION public.fn_sync_july_form_onboarding();
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 5. CONSOLIDATION PROCEDURE: FULL RECONCILIATION & REFRESH
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE refresh_core_partner_onboarding()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
    v_clean_phone VARCHAR(20);
    v_partner_id VARCHAR(50);
    v_existing_id BIGINT;
    v_existing_origin VARCHAR(50);
    v_next_id BIGINT;
BEGIN
    -- Acquire transactional advisory lock
    PERFORM pg_advisory_xact_lock(777111222);

    -- 5.1 Reconcile Google Sheet Records
    FOR r IN (
        SELECT DISTINCT ON (RIGHT(REGEXP_REPLACE(driver_phone, '[^0-9]', '', 'g'), 10))
            s.*,
            RIGHT(REGEXP_REPLACE(driver_phone, '[^0-9]', '', 'g'), 10) AS clean_phone
        FROM public.sheet_driver_onboarding s
        WHERE s.driver_phone IS NOT NULL AND LENGTH(REGEXP_REPLACE(s.driver_phone, '[^0-9]', '', 'g')) >= 10
        ORDER BY RIGHT(REGEXP_REPLACE(driver_phone, '[^0-9]', '', 'g'), 10), s.submission_timestamp DESC NULLS LAST, s.id DESC
    ) LOOP
        v_clean_phone := r.clean_phone;
        v_partner_id := COALESCE(r.partner_id, public.fn_canonical_partner_id(r.city, v_clean_phone));

        SELECT id, source_origin INTO v_existing_id, v_existing_origin
        FROM public.core_partner_onboarding
        WHERE phone_number = v_clean_phone;

        IF v_existing_id IS NOT NULL THEN
            UPDATE public.core_partner_onboarding
            SET
                driver_name = UPPER(r.driver_name),
                whatsapp_number = COALESCE(RIGHT(REGEXP_REPLACE(r.whatsapp_phone, '[^0-9]', '', 'g'), 10), v_clean_phone, core_partner_onboarding.whatsapp_number),
                dob = COALESCE(r.dob, core_partner_onboarding.dob),
                city = COALESCE(r.city, core_partner_onboarding.city),
                onboarding_type = COALESCE(r.onboarding_type, core_partner_onboarding.onboarding_type),
                father_name = COALESCE(r.father_name, core_partner_onboarding.father_name),
                present_address = COALESCE(r.present_address, r.aadhaar_address, core_partner_onboarding.present_address),
                permanent_address = COALESCE(r.aadhaar_address, core_partner_onboarding.permanent_address),
                emergency_name = COALESCE(r.emergency_name, core_partner_onboarding.emergency_name),
                emergency_phone = COALESCE(r.emergency_phone, core_partner_onboarding.emergency_phone),
                reference_name = COALESCE(r.reference_name, core_partner_onboarding.reference_name),
                reference_phone = COALESCE(r.reference_phone, core_partner_onboarding.reference_phone),
                dl_number = COALESCE(r.dl_number, core_partner_onboarding.dl_number),
                dl_expiry_date = COALESCE(r.dl_expiry, core_partner_onboarding.dl_expiry_date),
                pan_number = COALESCE(r.pan_number, core_partner_onboarding.pan_number),
                aadhaar_number = COALESCE(r.aadhaar_number, core_partner_onboarding.aadhaar_number),
                pan_aadhaar_linked = COALESCE(r.pan_aadhaar_linked, core_partner_onboarding.pan_aadhaar_linked),
                account_name = COALESCE(r.account_name, core_partner_onboarding.account_name),
                account_number = COALESCE(r.account_number, core_partner_onboarding.account_number),
                ifsc_code = COALESCE(r.ifsc_code, core_partner_onboarding.ifsc_code),
                upi_id = COALESCE(r.upi_id, core_partner_onboarding.upi_id),
                selfie_photo = COALESCE(r.selfie_photo, core_partner_onboarding.selfie_photo),
                dl_front = COALESCE(r.dl_front, core_partner_onboarding.dl_front),
                dl_back = COALESCE(r.dl_back, core_partner_onboarding.dl_back),
                aadhaar_card_front = COALESCE(r.aadhaar_front, core_partner_onboarding.aadhaar_card_front),
                aadhaar_card_back = COALESCE(r.aadhaar_back, core_partner_onboarding.aadhaar_card_back),
                pan_card_photo = COALESCE(r.pan_card, core_partner_onboarding.pan_card_photo),
                local_address_proof = COALESCE(r.local_address_proof, core_partner_onboarding.local_address_proof),
                cancelled_cheque_photo = COALESCE(r.bank_details_doc, core_partner_onboarding.cancelled_cheque_photo),
                security_deposit = CASE WHEN COALESCE(r.deposit_amount, 0.00) > 0 THEN r.deposit_amount ELSE core_partner_onboarding.security_deposit END,
                source_sheet_row_id = r.id,
                source_origin = CASE WHEN v_existing_origin = 'PORTAL_FORM' THEN 'MERGED' ELSE 'GOOGLE_SHEET' END,
                is_deleted = FALSE,
                deleted_at = NULL,
                updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            WHERE id = v_existing_id;
        ELSE
            SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_partner_onboarding;

            INSERT INTO public.core_partner_onboarding (
                id, partner_id, driver_name, phone_number, whatsapp_number, dob,
                city, onboarding_type, lead_source, driver_plan, father_name,
                present_address, permanent_address, emergency_name, emergency_phone,
                reference_name, reference_phone, dl_number, dl_expiry_date,
                pan_number, aadhaar_number, pan_aadhaar_linked, account_name,
                account_number, ifsc_code, upi_id, security_deposit,
                selfie_photo, dl_front, dl_back, aadhaar_card_front, aadhaar_card_back,
                pan_card_photo, local_address_proof, cancelled_cheque_photo, approval_status,
                source_origin, source_sheet_row_id, onboarding_timestamp, is_deleted, created_at, updated_at
            ) VALUES (
                v_next_id,
                v_partner_id,
                UPPER(r.driver_name),
                v_clean_phone,
                COALESCE(RIGHT(REGEXP_REPLACE(r.whatsapp_phone, '[^0-9]', '', 'g'), 10), v_clean_phone),
                r.dob,
                COALESCE(r.city, 'Bengaluru'),
                COALESCE(r.onboarding_type, 'Individual'),
                r.lead_source,
                r.driver_plan,
                r.father_name,
                COALESCE(r.present_address, r.aadhaar_address),
                r.aadhaar_address,
                r.emergency_name,
                r.emergency_phone,
                r.reference_name,
                r.reference_phone,
                r.dl_number,
                r.dl_expiry,
                r.pan_number,
                r.aadhaar_number,
                r.pan_aadhaar_linked,
                r.account_name,
                r.account_number,
                r.ifsc_code,
                r.upi_id,
                COALESCE(r.deposit_amount, 0.00),
                r.selfie_photo,
                r.dl_front,
                r.dl_back,
                r.aadhaar_front,
                r.aadhaar_back,
                r.pan_card,
                r.local_address_proof,
                r.bank_details_doc,
                'Approved',
                'GOOGLE_SHEET',
                r.id,
                r.submission_timestamp,
                FALSE,
                (COALESCE(r.created_at, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            );
        END IF;
    END LOOP;

    -- 5.2 Reconcile Portal Form Submissions
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_form_onboarding') THEN
        FOR r IN (
            SELECT DISTINCT ON (RIGHT(REGEXP_REPLACE(phone_number, '[^0-9]', '', 'g'), 10))
                p.*,
                RIGHT(REGEXP_REPLACE(phone_number, '[^0-9]', '', 'g'), 10) AS clean_phone
            FROM public.july_form_onboarding p
            WHERE p.phone_number IS NOT NULL AND LENGTH(REGEXP_REPLACE(p.phone_number, '[^0-9]', '', 'g')) >= 10
            ORDER BY RIGHT(REGEXP_REPLACE(phone_number, '[^0-9]', '', 'g'), 10), p.created_at DESC NULLS LAST, p.id DESC
        ) LOOP
            v_clean_phone := r.clean_phone;
            v_partner_id := COALESCE(r.driver_id, public.fn_canonical_partner_id(r.city, v_clean_phone));

            SELECT id, source_origin INTO v_existing_id, v_existing_origin
            FROM public.core_partner_onboarding
            WHERE phone_number = v_clean_phone;

            IF v_existing_id IS NOT NULL THEN
                UPDATE public.core_partner_onboarding
                SET
                    driver_name = UPPER(r.driver_name),
                    whatsapp_number = COALESCE(RIGHT(REGEXP_REPLACE(COALESCE(r.whatsapp_number, r.phone_number), '[^0-9]', '', 'g'), 10), core_partner_onboarding.whatsapp_number),
                    city = COALESCE(r.city, core_partner_onboarding.city),
                    present_address = COALESCE(r.present_address, core_partner_onboarding.present_address),
                    permanent_address = COALESCE(r.permanent_address, core_partner_onboarding.permanent_address),
                    emergency_name = COALESCE(r.emergency_name, core_partner_onboarding.emergency_name),
                    emergency_phone = COALESCE(r.emergency_phone, core_partner_onboarding.emergency_phone),
                    emergency_relationship = COALESCE(r.emergency_relationship, core_partner_onboarding.emergency_relationship),
                    dl_number = COALESCE(r.dl_number, core_partner_onboarding.dl_number),
                    pan_number = COALESCE(r.pan_number, core_partner_onboarding.pan_number),
                    aadhaar_number = COALESCE(r.aadhaar_number, core_partner_onboarding.aadhaar_number),
                    pan_aadhaar_linked = COALESCE(r.pan_aadhaar_linked, core_partner_onboarding.pan_aadhaar_linked),
                    bank_name = COALESCE(r.bank_name, core_partner_onboarding.bank_name),
                    account_name = COALESCE(r.account_name, core_partner_onboarding.account_name),
                    account_number = COALESCE(r.account_number, core_partner_onboarding.account_number),
                    ifsc_code = COALESCE(r.ifsc_code, core_partner_onboarding.ifsc_code),
                    upi_id = COALESCE(r.upi_id, core_partner_onboarding.upi_id),
                    selfie_photo = COALESCE(r.selfie_photo, core_partner_onboarding.selfie_photo),
                    dl_front = COALESCE(r.dl_front, core_partner_onboarding.dl_front),
                    dl_back = COALESCE(r.dl_back, core_partner_onboarding.dl_back),
                    aadhaar_card_front = COALESCE(r.aadhaar_card_front, core_partner_onboarding.aadhaar_card_front),
                    aadhaar_card_back = COALESCE(r.aadhaar_card_back, core_partner_onboarding.aadhaar_card_back),
                    pan_card_photo = COALESCE(r.pan_card_photo, core_partner_onboarding.pan_card_photo),
                    cancelled_cheque_photo = COALESCE(r.cancelled_cheque_photo, core_partner_onboarding.cancelled_cheque_photo),
                    approval_status = COALESCE(r.approval_status, core_partner_onboarding.approval_status),
                    is_documents_verified = COALESCE(r.documents_verified, core_partner_onboarding.is_documents_verified),
                    is_spring_verified = COALESCE(r.is_spring_verified, core_partner_onboarding.is_spring_verified),
                    source_portal_form_id = r.id,
                    source_origin = CASE WHEN v_existing_origin = 'GOOGLE_SHEET' THEN 'MERGED' ELSE 'PORTAL_FORM' END,
                    is_deleted = FALSE,
                    deleted_at = NULL,
                    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                WHERE id = v_existing_id;
            ELSE
                SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_partner_onboarding;

                INSERT INTO public.core_partner_onboarding (
                    id, partner_id, driver_name, phone_number, whatsapp_number,
                    city, present_address, permanent_address, emergency_name, emergency_phone,
                    emergency_relationship, dl_number, lead_source, pan_number, aadhaar_number,
                    pan_aadhaar_linked, bank_name, account_name, account_number, ifsc_code,
                    upi_id, selfie_photo, dl_front, dl_back, aadhaar_card_front,
                    aadhaar_card_back, pan_card_photo, cancelled_cheque_photo, approval_status,
                    is_documents_verified, is_spring_verified, source_origin, source_portal_form_id,
                    onboarding_timestamp, is_deleted, created_at, updated_at
                ) VALUES (
                    v_next_id,
                    v_partner_id,
                    UPPER(r.driver_name),
                    v_clean_phone,
                    RIGHT(REGEXP_REPLACE(COALESCE(r.whatsapp_number, r.phone_number), '[^0-9]', '', 'g'), 10),
                    COALESCE(r.city, 'Bengaluru'),
                    r.present_address,
                    r.permanent_address,
                    r.emergency_name,
                    r.emergency_phone,
                    r.emergency_relationship,
                    r.dl_number,
                    r.lead_source,
                    r.pan_number,
                    r.aadhaar_number,
                    r.pan_aadhaar_linked,
                    r.bank_name,
                    r.account_name,
                    r.account_number,
                    r.ifsc_code,
                    r.upi_id,
                    r.selfie_photo,
                    r.dl_front,
                    r.dl_back,
                    r.aadhaar_card_front,
                    r.aadhaar_card_back,
                    r.pan_card_photo,
                    r.cancelled_cheque_photo,
                    COALESCE(r.approval_status, 'Draft'),
                    COALESCE(r.documents_verified, FALSE),
                    COALESCE(r.is_spring_verified, FALSE),
                    'PORTAL_FORM',
                    r.id,
                    (COALESCE(r.created_at, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                    FALSE,
                    (COALESCE(r.created_at, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                );
            END IF;
        END LOOP;
    END IF;

END;
$$;

-- -----------------------------------------------------------------------------
-- 6. ONE-TIME MIGRATION & RECONCILIATION SCRIPT
-- -----------------------------------------------------------------------------

-- Fix 6.1: Clean up corrupted LETZBEN / LETZBAN records to canonical LETZBLR
UPDATE public.core_partner_onboarding
SET partner_id = REGEXP_REPLACE(partner_id, '^LETZ(BEN|BAN)', 'LETZBLR'),
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
WHERE partner_id ~ '^LETZ(BEN|BAN)';

-- Fix 6.2: Backfill missing 2,118 bank details / cancelled cheque proofs from sheet
UPDATE public.core_partner_onboarding c
SET cancelled_cheque_photo = s.bank_details_doc,
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
FROM (
    SELECT DISTINCT ON (RIGHT(REGEXP_REPLACE(driver_phone, '[^0-9]', '', 'g'), 10))
        RIGHT(REGEXP_REPLACE(driver_phone, '[^0-9]', '', 'g'), 10) AS clean_phone,
        bank_details_doc
    FROM public.sheet_driver_onboarding
    WHERE bank_details_doc IS NOT NULL AND TRIM(bank_details_doc) != ''
    ORDER BY RIGHT(REGEXP_REPLACE(driver_phone, '[^0-9]', '', 'g'), 10), submission_timestamp DESC
) s
WHERE c.phone_number = s.clean_phone
  AND (c.cancelled_cheque_photo IS NULL OR TRIM(c.cancelled_cheque_photo) = '');

-- Fix 6.3: Audit reconciliation of source_origin tags
UPDATE public.core_partner_onboarding c
SET source_origin = CASE 
        WHEN EXISTS (
            SELECT 1 FROM public.sheet_driver_onboarding s 
            WHERE RIGHT(REGEXP_REPLACE(s.driver_phone, '[^0-9]', '', 'g'), 10) = c.phone_number
        ) AND EXISTS (
            SELECT 1 FROM public.july_form_onboarding j 
            WHERE RIGHT(REGEXP_REPLACE(j.phone_number, '[^0-9]', '', 'g'), 10) = c.phone_number
        ) THEN 'MERGED'
        WHEN EXISTS (
            SELECT 1 FROM public.july_form_onboarding j 
            WHERE RIGHT(REGEXP_REPLACE(j.phone_number, '[^0-9]', '', 'g'), 10) = c.phone_number
        ) THEN 'PORTAL_FORM'
        ELSE 'GOOGLE_SHEET'
    END,
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata');

-- Fix 6.4: Purge 2,116 whole-second duplicate records in sheet_driver_onboarding (retain primary per phone & sheet row)
WITH ranked_duplicates AS (
    SELECT id,
           ROW_NUMBER() OVER (
               PARTITION BY RIGHT(REGEXP_REPLACE(driver_phone, '[^0-9]', '', 'g'), 10), sheet_row_number 
               ORDER BY id ASC
           ) AS rnk
    FROM public.sheet_driver_onboarding
)
DELETE FROM public.sheet_driver_onboarding
WHERE id IN (SELECT id FROM ranked_duplicates WHERE rnk > 1);

-- Fix 6.5: DL Data Recovery - Extract valid expiry dates from corrupted SATSEP... strings
UPDATE public.sheet_driver_onboarding
SET dl_expiry = CASE 
        WHEN dl_number ~ '^([A-Z]{3})([A-Z]{3})([0-9]{1,2})([0-9]{4})' THEN
            TO_DATE(
                SUBSTRING(dl_number FROM 7 FOR 2) || '-' || 
                SUBSTRING(dl_number FROM 4 FOR 3) || '-' || 
                SUBSTRING(dl_number FROM 9 FOR 4), 
                'DD-Mon-YYYY'
            )
        ELSE dl_expiry
    END,
    dl_number = NULL, -- Clear corrupted date string from DL number field to allow KYC review
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
WHERE dl_number ~ '^([A-Z]{3})([A-Z]{3})([0-9]{1,2})([0-9]{4})';

-- Fix 6.6: Sanitize out-of-range calendar years in staging and core tables
UPDATE public.sheet_driver_onboarding
SET dl_expiry = NULL,
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
WHERE dl_expiry IS NOT NULL AND (EXTRACT(YEAR FROM dl_expiry) < 1990 OR EXTRACT(YEAR FROM dl_expiry) > 2060);

UPDATE public.sheet_driver_onboarding
SET dob = NULL,
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
WHERE dob IS NOT NULL AND (EXTRACT(YEAR FROM dob) < 1950 OR EXTRACT(YEAR FROM dob) > (EXTRACT(YEAR FROM CURRENT_DATE) - 18));

UPDATE public.core_partner_onboarding
SET dl_expiry_date = NULL,
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
WHERE dl_expiry_date IS NOT NULL AND (EXTRACT(YEAR FROM dl_expiry_date) < 1990 OR EXTRACT(YEAR FROM dl_expiry_date) > 2060);

UPDATE public.core_partner_onboarding
SET dob = NULL,
    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
WHERE dob IS NOT NULL AND (EXTRACT(YEAR FROM dob) < 1950 OR EXTRACT(YEAR FROM dob) > (EXTRACT(YEAR FROM CURRENT_DATE) - 18));

-- -----------------------------------------------------------------------------
-- 7. SAMPLE OPERATIONAL & VERIFICATION QUERIES
-- -----------------------------------------------------------------------------

-- Query 7.1: Overall Counts & Source Distribution in Core
SELECT 
    source_origin,
    count(*) AS total_partners,
    count(DISTINCT phone_number) AS unique_phone_numbers,
    count(CASE WHEN dl_number IS NOT NULL THEN 1 END) AS with_driving_license,
    count(CASE WHEN aadhaar_number IS NOT NULL THEN 1 END) AS with_aadhaar,
    count(CASE WHEN pan_number IS NOT NULL THEN 1 END) AS with_pan,
    count(CASE WHEN cancelled_cheque_photo IS NOT NULL THEN 1 END) AS with_bank_proof,
    count(CASE WHEN approval_status = 'Approved' THEN 1 END) AS approved_count
FROM public.core_partner_onboarding
GROUP BY source_origin;

-- Query 7.2: Verify Zero Corrupted Partner IDs
SELECT partner_id, driver_name, phone_number, city
FROM public.core_partner_onboarding
WHERE partner_id !~ '^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$';

-- Query 7.3: Verify Gapless Continuous Sequencing
SELECT 
    count(*) AS actual_rows,
    max(id) AS max_id,
    COALESCE(max(id), 0) - count(*) AS sequence_gap
FROM public.core_partner_onboarding;

-- Query 7.4: Verify Zero Corrupted DL Numbers in Staging
SELECT count(*) AS corrupted_dl_count
FROM public.sheet_driver_onboarding
WHERE dl_number ~ '^([A-Z]{3})([A-Z]{3})[0-9]';

-- Query 7.5: Verify Zero Out-of-Range Years in DOB and DL Expiry
SELECT 
    count(CASE WHEN EXTRACT(YEAR FROM dl_expiry) < 1990 OR EXTRACT(YEAR FROM dl_expiry) > 2060 THEN 1 END) AS invalid_dl_expiry_years,
    count(CASE WHEN EXTRACT(YEAR FROM dob) < 1950 OR EXTRACT(YEAR FROM dob) > 2008 THEN 1 END) AS invalid_dob_years
FROM public.sheet_driver_onboarding;

