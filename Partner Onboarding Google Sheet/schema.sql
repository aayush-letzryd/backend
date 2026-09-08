-- =============================================================================
-- LetzRyd Partner Onboarding Data Pipeline - PostgreSQL Database Schema
-- =============================================================================
-- Target Database: postgres
-- Target Schema  : public
-- Source Tables  : sheet_driver_onboarding (Google Sheet) + july_form_onboarding (Portal Form)
-- Master Table   : core_partner_onboarding
-- Host           : 35.200.196.113:5432
-- Description    : Central table definitions, performance indexes, and automated
--                  consolidation procedures for LetzRyd Driver-Partner Onboarding.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. LANDING TABLE: public.sheet_driver_onboarding (Google Sheets Ingestion)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.sheet_driver_onboarding (
    id BIGSERIAL PRIMARY KEY,
    submission_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
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
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
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
    id BIGSERIAL PRIMARY KEY,
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
    deleted_at TIMESTAMP WITH TIME ZONE,
    onboarding_timestamp TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Performance Indexes for core_partner_onboarding
CREATE INDEX IF NOT EXISTS idx_core_partner_phone ON public.core_partner_onboarding (phone_number);
CREATE INDEX IF NOT EXISTS idx_core_partner_dl ON public.core_partner_onboarding (dl_number);
CREATE INDEX IF NOT EXISTS idx_core_partner_aadhaar ON public.core_partner_onboarding (aadhaar_number);
CREATE INDEX IF NOT EXISTS idx_core_partner_pan ON public.core_partner_onboarding (pan_number);
CREATE INDEX IF NOT EXISTS idx_core_partner_city ON public.core_partner_onboarding (city);
CREATE INDEX IF NOT EXISTS idx_core_partner_status ON public.core_partner_onboarding (approval_status);
CREATE INDEX IF NOT EXISTS idx_core_partner_ts ON public.core_partner_onboarding (onboarding_timestamp DESC);

-- -----------------------------------------------------------------------------
-- 3. CONSOLIDATION PROCEDURE: MERGE SHEET & PORTAL DATA INTO CORE
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE refresh_core_partner_onboarding()
LANGUAGE plpgsql
AS $$
BEGIN
    -- 3.1 Upsert Google Sheet Records into core_partner_onboarding (deduplicated by phone, taking latest submission)
    INSERT INTO public.core_partner_onboarding (
        partner_id, driver_name, phone_number, whatsapp_number, dob,
        city, onboarding_type, lead_source, driver_plan, father_name,
        present_address, permanent_address, emergency_name, emergency_phone,
        reference_name, reference_phone, dl_number, dl_expiry_date,
        pan_number, aadhaar_number, pan_aadhaar_linked, account_name,
        account_number, ifsc_code, upi_id, security_deposit,
        selfie_photo, dl_front, dl_back, aadhaar_card_front, aadhaar_card_back,
        pan_card_photo, local_address_proof, cancelled_cheque_photo, approval_status,
        source_origin, source_sheet_row_id, onboarding_timestamp, created_at, updated_at
    )
    SELECT DISTINCT ON (s.driver_phone)
        COALESCE(s.partner_id, 'LETZ' || UPPER(LEFT(COALESCE(s.city, 'BLR'), 3)) || s.driver_phone) AS partner_id,
        UPPER(s.driver_name) AS driver_name,
        s.driver_phone AS phone_number,
        COALESCE(s.whatsapp_phone, s.driver_phone) AS whatsapp_number,
        s.dob,
        COALESCE(s.city, 'Bengaluru') AS city,
        COALESCE(s.onboarding_type, 'Individual') AS onboarding_type,
        s.lead_source,
        s.driver_plan,
        s.father_name,
        COALESCE(s.present_address, s.aadhaar_address) AS present_address,
        s.aadhaar_address AS permanent_address,
        s.emergency_name,
        s.emergency_phone,
        s.reference_name,
        s.reference_phone,
        s.dl_number,
        s.dl_expiry AS dl_expiry_date,
        s.pan_number,
        s.aadhaar_number,
        s.pan_aadhaar_linked,
        s.account_name,
        s.account_number,
        s.ifsc_code,
        s.upi_id,
        COALESCE(s.deposit_amount, 0.00) AS security_deposit,
        s.selfie_photo,
        s.dl_front,
        s.dl_back,
        s.aadhaar_front,
        s.aadhaar_back,
        s.pan_card,
        s.local_address_proof,
        s.bank_details_doc AS cancelled_cheque_photo,
        'Approved' AS approval_status,
        'GOOGLE_SHEET' AS source_origin,
        s.id AS source_sheet_row_id,
        s.submission_timestamp AS onboarding_timestamp,
        s.created_at,
        CURRENT_TIMESTAMP AS updated_at
    FROM public.sheet_driver_onboarding s
    WHERE s.driver_phone IS NOT NULL AND LENGTH(s.driver_phone) >= 10
    ORDER BY s.driver_phone, s.submission_timestamp DESC NULLS LAST, s.id DESC
    ON CONFLICT (phone_number) DO UPDATE
    SET
        driver_name = EXCLUDED.driver_name,
        whatsapp_number = COALESCE(EXCLUDED.whatsapp_number, core_partner_onboarding.whatsapp_number),
        dob = COALESCE(EXCLUDED.dob, core_partner_onboarding.dob),
        city = COALESCE(EXCLUDED.city, core_partner_onboarding.city),
        onboarding_type = COALESCE(EXCLUDED.onboarding_type, core_partner_onboarding.onboarding_type),
        father_name = COALESCE(EXCLUDED.father_name, core_partner_onboarding.father_name),
        present_address = COALESCE(EXCLUDED.present_address, core_partner_onboarding.present_address),
        permanent_address = COALESCE(EXCLUDED.permanent_address, core_partner_onboarding.permanent_address),
        emergency_name = COALESCE(EXCLUDED.emergency_name, core_partner_onboarding.emergency_name),
        emergency_phone = COALESCE(EXCLUDED.emergency_phone, core_partner_onboarding.emergency_phone),
        dl_number = COALESCE(EXCLUDED.dl_number, core_partner_onboarding.dl_number),
        dl_expiry_date = COALESCE(EXCLUDED.dl_expiry_date, core_partner_onboarding.dl_expiry_date),
        pan_number = COALESCE(EXCLUDED.pan_number, core_partner_onboarding.pan_number),
        aadhaar_number = COALESCE(EXCLUDED.aadhaar_number, core_partner_onboarding.aadhaar_number),
        account_name = COALESCE(EXCLUDED.account_name, core_partner_onboarding.account_name),
        account_number = COALESCE(EXCLUDED.account_number, core_partner_onboarding.account_number),
        ifsc_code = COALESCE(EXCLUDED.ifsc_code, core_partner_onboarding.ifsc_code),
        upi_id = COALESCE(EXCLUDED.upi_id, core_partner_onboarding.upi_id),
        cancelled_cheque_photo = COALESCE(EXCLUDED.cancelled_cheque_photo, core_partner_onboarding.cancelled_cheque_photo),
        security_deposit = CASE WHEN EXCLUDED.security_deposit > 0 THEN EXCLUDED.security_deposit ELSE core_partner_onboarding.security_deposit END,
        source_sheet_row_id = EXCLUDED.source_sheet_row_id,
        source_origin = CASE WHEN core_partner_onboarding.source_origin = 'PORTAL_FORM' THEN 'MERGED' ELSE 'GOOGLE_SHEET' END,
        updated_at = CURRENT_TIMESTAMP;

    -- 3.2 Upsert Portal Form Submissions (july_form_onboarding) into core_partner_onboarding (deduplicated by phone)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_form_onboarding') THEN
        INSERT INTO public.core_partner_onboarding (
            partner_id, driver_name, phone_number, whatsapp_number,
            city, present_address, permanent_address, emergency_name, emergency_phone,
            emergency_relationship, dl_number, lead_source, pan_number, aadhaar_number,
            pan_aadhaar_linked, bank_name, account_name, account_number, ifsc_code,
            upi_id, selfie_photo, dl_front, dl_back, aadhaar_card_front,
            aadhaar_card_back, pan_card_photo, cancelled_cheque_photo, approval_status,
            is_documents_verified, is_spring_verified, source_origin, source_portal_form_id,
            onboarding_timestamp, created_at, updated_at
        )
        SELECT DISTINCT ON (RIGHT(REGEXP_REPLACE(p.phone_number, '[^0-9]', '', 'g'), 10))
            COALESCE(p.driver_id, 'LETZ' || UPPER(LEFT(COALESCE(p.city, 'BLR'), 3)) || RIGHT(REGEXP_REPLACE(p.phone_number, '[^0-9]', '', 'g'), 10)) AS partner_id,
            UPPER(p.driver_name) AS driver_name,
            RIGHT(REGEXP_REPLACE(p.phone_number, '[^0-9]', '', 'g'), 10) AS phone_number,
            RIGHT(REGEXP_REPLACE(p.whatsapp_number, '[^0-9]', '', 'g'), 10) AS whatsapp_number,
            COALESCE(p.city, 'Bengaluru') AS city,
            p.present_address,
            p.permanent_address,
            p.emergency_name,
            p.emergency_phone,
            p.emergency_relationship,
            p.dl_number,
            p.lead_source,
            p.pan_number,
            p.aadhaar_number,
            p.pan_aadhaar_linked,
            p.bank_name,
            p.account_name,
            p.account_number,
            p.ifsc_code,
            p.upi_id,
            p.selfie_photo,
            p.dl_front,
            p.dl_back,
            p.aadhaar_card_front,
            p.aadhaar_card_back,
            p.pan_card_photo,
            p.cancelled_cheque_photo,
            COALESCE(p.approval_status, 'Draft') AS approval_status,
            COALESCE(p.documents_verified, FALSE) AS is_documents_verified,
            COALESCE(p.is_spring_verified, FALSE) AS is_spring_verified,
            'PORTAL_FORM' AS source_origin,
            p.id AS source_portal_form_id,
            p.created_at AS onboarding_timestamp,
            p.created_at,
            CURRENT_TIMESTAMP AS updated_at
        FROM public.july_form_onboarding p
        WHERE p.phone_number IS NOT NULL AND LENGTH(REGEXP_REPLACE(p.phone_number, '[^0-9]', '', 'g')) >= 10
        ORDER BY RIGHT(REGEXP_REPLACE(p.phone_number, '[^0-9]', '', 'g'), 10), p.created_at DESC NULLS LAST, p.id DESC
        ON CONFLICT (phone_number) DO UPDATE
        SET
            driver_name = EXCLUDED.driver_name,
            whatsapp_number = COALESCE(EXCLUDED.whatsapp_number, core_partner_onboarding.whatsapp_number),
            city = COALESCE(EXCLUDED.city, core_partner_onboarding.city),
            present_address = COALESCE(EXCLUDED.present_address, core_partner_onboarding.present_address),
            permanent_address = COALESCE(EXCLUDED.permanent_address, core_partner_onboarding.permanent_address),
            emergency_name = COALESCE(EXCLUDED.emergency_name, core_partner_onboarding.emergency_name),
            emergency_phone = COALESCE(EXCLUDED.emergency_phone, core_partner_onboarding.emergency_phone),
            emergency_relationship = COALESCE(EXCLUDED.emergency_relationship, core_partner_onboarding.emergency_relationship),
            dl_number = COALESCE(EXCLUDED.dl_number, core_partner_onboarding.dl_number),
            pan_number = COALESCE(EXCLUDED.pan_number, core_partner_onboarding.pan_number),
            aadhaar_number = COALESCE(EXCLUDED.aadhaar_number, core_partner_onboarding.aadhaar_number),
            bank_name = COALESCE(EXCLUDED.bank_name, core_partner_onboarding.bank_name),
            account_name = COALESCE(EXCLUDED.account_name, core_partner_onboarding.account_name),
            account_number = COALESCE(EXCLUDED.account_number, core_partner_onboarding.account_number),
            ifsc_code = COALESCE(EXCLUDED.ifsc_code, core_partner_onboarding.ifsc_code),
            upi_id = COALESCE(EXCLUDED.upi_id, core_partner_onboarding.upi_id),
            cancelled_cheque_photo = COALESCE(EXCLUDED.cancelled_cheque_photo, core_partner_onboarding.cancelled_cheque_photo),
            approval_status = EXCLUDED.approval_status,
            is_documents_verified = EXCLUDED.is_documents_verified,
            is_spring_verified = EXCLUDED.is_spring_verified,
            source_portal_form_id = EXCLUDED.source_portal_form_id,
            source_origin = CASE WHEN core_partner_onboarding.source_origin = 'GOOGLE_SHEET' THEN 'MERGED' ELSE 'PORTAL_FORM' END,
            updated_at = CURRENT_TIMESTAMP;
    END IF;

END;
$$;

-- -----------------------------------------------------------------------------
-- 4. REAL-TIME ROW-LEVEL DATABASE TRIGGERS
-- -----------------------------------------------------------------------------

-- Trigger function for sheet_driver_onboarding -> core_partner_onboarding
CREATE OR REPLACE FUNCTION public.fn_sync_sheet_driver_onboarding()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_partner_onboarding
        SET is_deleted = TRUE, deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE source_sheet_row_id = OLD.id AND source_origin = 'GOOGLE_SHEET';
        RETURN OLD;
    END IF;

    IF NEW.driver_phone IS NOT NULL AND LENGTH(NEW.driver_phone) >= 10 THEN
        INSERT INTO public.core_partner_onboarding (
            partner_id, driver_name, phone_number, whatsapp_number, dob,
            city, onboarding_type, lead_source, driver_plan, father_name,
            present_address, permanent_address, emergency_name, emergency_phone,
            reference_name, reference_phone, dl_number, dl_expiry_date,
            pan_number, aadhaar_number, pan_aadhaar_linked, account_name,
            account_number, ifsc_code, upi_id, security_deposit,
            selfie_photo, dl_front, dl_back, aadhaar_card_front, aadhaar_card_back,
            pan_card_photo, local_address_proof, cancelled_cheque_photo, approval_status,
            source_origin, source_sheet_row_id, onboarding_timestamp, is_deleted, created_at, updated_at
        ) VALUES (
            COALESCE(NEW.partner_id, 'LETZ' || UPPER(LEFT(COALESCE(NEW.city, 'BLR'), 3)) || NEW.driver_phone),
            UPPER(NEW.driver_name),
            NEW.driver_phone,
            COALESCE(NEW.whatsapp_phone, NEW.driver_phone),
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
            NEW.aadhaar_number,
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
            'Approved',
            'GOOGLE_SHEET',
            NEW.id,
            NEW.submission_timestamp,
            FALSE,
            COALESCE(NEW.created_at, CURRENT_TIMESTAMP),
            CURRENT_TIMESTAMP
        )
        ON CONFLICT (phone_number) DO UPDATE
        SET
            driver_name = EXCLUDED.driver_name,
            whatsapp_number = COALESCE(EXCLUDED.whatsapp_number, core_partner_onboarding.whatsapp_number),
            dob = COALESCE(EXCLUDED.dob, core_partner_onboarding.dob),
            city = COALESCE(EXCLUDED.city, core_partner_onboarding.city),
            onboarding_type = COALESCE(EXCLUDED.onboarding_type, core_partner_onboarding.onboarding_type),
            father_name = COALESCE(EXCLUDED.father_name, core_partner_onboarding.father_name),
            present_address = COALESCE(EXCLUDED.present_address, core_partner_onboarding.present_address),
            permanent_address = COALESCE(EXCLUDED.permanent_address, core_partner_onboarding.permanent_address),
            emergency_name = COALESCE(EXCLUDED.emergency_name, core_partner_onboarding.emergency_name),
            emergency_phone = COALESCE(EXCLUDED.emergency_phone, core_partner_onboarding.emergency_phone),
            dl_number = COALESCE(EXCLUDED.dl_number, core_partner_onboarding.dl_number),
            dl_expiry_date = COALESCE(EXCLUDED.dl_expiry_date, core_partner_onboarding.dl_expiry_date),
            pan_number = COALESCE(EXCLUDED.pan_number, core_partner_onboarding.pan_number),
            aadhaar_number = COALESCE(EXCLUDED.aadhaar_number, core_partner_onboarding.aadhaar_number),
            account_name = COALESCE(EXCLUDED.account_name, core_partner_onboarding.account_name),
            account_number = COALESCE(EXCLUDED.account_number, core_partner_onboarding.account_number),
            ifsc_code = COALESCE(EXCLUDED.ifsc_code, core_partner_onboarding.ifsc_code),
            upi_id = COALESCE(EXCLUDED.upi_id, core_partner_onboarding.upi_id),
            cancelled_cheque_photo = COALESCE(EXCLUDED.cancelled_cheque_photo, core_partner_onboarding.cancelled_cheque_photo),
            security_deposit = CASE WHEN EXCLUDED.security_deposit > 0 THEN EXCLUDED.security_deposit ELSE core_partner_onboarding.security_deposit END,
            source_sheet_row_id = EXCLUDED.source_sheet_row_id,
            source_origin = CASE WHEN core_partner_onboarding.source_origin = 'PORTAL_FORM' THEN 'MERGED' ELSE 'GOOGLE_SHEET' END,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = CURRENT_TIMESTAMP;
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
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_partner_onboarding
        SET is_deleted = TRUE, deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE source_portal_form_id = OLD.id AND source_origin = 'PORTAL_FORM';
        RETURN OLD;
    END IF;

    IF NEW.phone_number IS NOT NULL THEN
        v_clean_phone := RIGHT(REGEXP_REPLACE(NEW.phone_number, '[^0-9]', '', 'g'), 10);
        IF LENGTH(v_clean_phone) = 10 THEN
            INSERT INTO public.core_partner_onboarding (
                partner_id, driver_name, phone_number, whatsapp_number,
                city, present_address, permanent_address, emergency_name, emergency_phone,
                emergency_relationship, dl_number, lead_source, pan_number, aadhaar_number,
                pan_aadhaar_linked, bank_name, account_name, account_number, ifsc_code,
                upi_id, selfie_photo, dl_front, dl_back, aadhaar_card_front,
                aadhaar_card_back, pan_card_photo, cancelled_cheque_photo, approval_status,
                is_documents_verified, is_spring_verified, source_origin, source_portal_form_id,
                onboarding_timestamp, is_deleted, created_at, updated_at
            ) VALUES (
                COALESCE(NEW.driver_id, 'LETZ' || UPPER(LEFT(COALESCE(NEW.city, 'BLR'), 3)) || v_clean_phone),
                UPPER(NEW.driver_name),
                v_clean_phone,
                RIGHT(REGEXP_REPLACE(COALESCE(NEW.whatsapp_number, NEW.phone_number), '[^0-9]', '', 'g'), 10),
                COALESCE(NEW.city, 'Bengaluru'),
                NEW.present_address,
                NEW.permanent_address,
                NEW.emergency_name,
                NEW.emergency_phone,
                NEW.emergency_relationship,
                NEW.dl_number,
                NEW.lead_source,
                NEW.pan_number,
                NEW.aadhaar_number,
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
                NEW.cancelled_cheque_photo,
                COALESCE(NEW.approval_status, 'Draft'),
                COALESCE(NEW.documents_verified, FALSE),
                COALESCE(NEW.is_spring_verified, FALSE),
                'PORTAL_FORM',
                NEW.id,
                COALESCE(NEW.created_at, CURRENT_TIMESTAMP),
                FALSE,
                COALESCE(NEW.created_at, CURRENT_TIMESTAMP),
                CURRENT_TIMESTAMP
            )
            ON CONFLICT (phone_number) DO UPDATE
            SET
                driver_name = EXCLUDED.driver_name,
                whatsapp_number = COALESCE(EXCLUDED.whatsapp_number, core_partner_onboarding.whatsapp_number),
                city = COALESCE(EXCLUDED.city, core_partner_onboarding.city),
                present_address = COALESCE(EXCLUDED.present_address, core_partner_onboarding.present_address),
                permanent_address = COALESCE(EXCLUDED.permanent_address, core_partner_onboarding.permanent_address),
                emergency_name = COALESCE(EXCLUDED.emergency_name, core_partner_onboarding.emergency_name),
                emergency_phone = COALESCE(EXCLUDED.emergency_phone, core_partner_onboarding.emergency_phone),
                emergency_relationship = COALESCE(EXCLUDED.emergency_relationship, core_partner_onboarding.emergency_relationship),
                dl_number = COALESCE(EXCLUDED.dl_number, core_partner_onboarding.dl_number),
                pan_number = COALESCE(EXCLUDED.pan_number, core_partner_onboarding.pan_number),
                aadhaar_number = COALESCE(EXCLUDED.aadhaar_number, core_partner_onboarding.aadhaar_number),
                bank_name = COALESCE(EXCLUDED.bank_name, core_partner_onboarding.bank_name),
                account_name = COALESCE(EXCLUDED.account_name, core_partner_onboarding.account_name),
                account_number = COALESCE(EXCLUDED.account_number, core_partner_onboarding.account_number),
                ifsc_code = COALESCE(EXCLUDED.ifsc_code, core_partner_onboarding.ifsc_code),
                upi_id = COALESCE(EXCLUDED.upi_id, core_partner_onboarding.upi_id),
                cancelled_cheque_photo = COALESCE(EXCLUDED.cancelled_cheque_photo, core_partner_onboarding.cancelled_cheque_photo),
                approval_status = EXCLUDED.approval_status,
                is_documents_verified = EXCLUDED.is_documents_verified,
                is_spring_verified = EXCLUDED.is_spring_verified,
                source_portal_form_id = EXCLUDED.source_portal_form_id,
                source_origin = CASE WHEN core_partner_onboarding.source_origin = 'GOOGLE_SHEET' THEN 'MERGED' ELSE 'PORTAL_FORM' END,
                is_deleted = FALSE,
                deleted_at = NULL,
                updated_at = CURRENT_TIMESTAMP;
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
-- 4. SAMPLE OPERATIONAL & VERIFICATION QUERIES
-- -----------------------------------------------------------------------------

-- Query 4.1: Overall Counts & Source Distribution in Core
SELECT 
    source_origin,
    count(*) AS total_partners,
    count(DISTINCT phone_number) AS unique_phone_numbers,
    count(CASE WHEN dl_number IS NOT NULL THEN 1 END) AS with_driving_license,
    count(CASE WHEN aadhaar_number IS NOT NULL THEN 1 END) AS with_aadhaar,
    count(CASE WHEN pan_number IS NOT NULL THEN 1 END) AS with_pan,
    count(CASE WHEN approval_status = 'Approved' THEN 1 END) AS approved_count
FROM public.core_partner_onboarding
GROUP BY source_origin;

-- Query 4.2: Latest 25 Onboarded Driver Partners
SELECT 
    partner_id,
    driver_name,
    phone_number,
    city,
    onboarding_type,
    lead_source,
    approval_status,
    security_deposit,
    source_origin,
    onboarding_timestamp
FROM public.core_partner_onboarding
ORDER BY onboarding_timestamp DESC NULLS LAST
LIMIT 25;

-- Query 4.3: Partner Lookup by Phone Number
SELECT * 
FROM public.core_partner_onboarding 
WHERE phone_number = '9380465352';

-- Query 4.4: City-wise Active Partner Onboarding Breakdown
SELECT 
    COALESCE(city, 'Unknown') AS city,
    count(*) AS total_onboarded,
    sum(security_deposit) AS total_deposits_collected,
    count(CASE WHEN approval_status = 'Approved' THEN 1 END) AS active_partners
FROM public.core_partner_onboarding
GROUP BY city
ORDER BY total_onboarded DESC;
