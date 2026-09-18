-- =============================================================================
-- LetzRyd Partner Onboarding Google Sheet Pipeline - PostgreSQL Schema
-- =============================================================================
-- Target Database: postgres
-- Target Schema  : public
-- Source Sheet   : 'Pan India Master Sheet' -> Tab: 'Onboarding form_V2'
-- Target Landing : public.sheet_driver_onboarding
-- Host           : YOUR_DB_HOST_HERE:5432
-- Description    : Schema definition, performance indexes, and verification
--                  queries for Google Sheets Ingestion into sheet_driver_onboarding.
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
-- 2. OPERATIONAL VERIFICATION QUERIES (LANDING TABLE)
-- -----------------------------------------------------------------------------

-- Query 2.1: Total records & unique phone numbers in landing table
SELECT 
    count(*) AS total_rows,
    count(DISTINCT driver_phone) AS unique_phone_count,
    min(id) AS min_id,
    max(id) AS max_id,
    max(submission_timestamp) AS latest_submission
FROM public.sheet_driver_onboarding;

-- Query 2.2: City distribution in staging
SELECT city, count(*) AS total_records
FROM public.sheet_driver_onboarding
GROUP BY city
ORDER BY total_records DESC;

-- Query 2.3: Check for invalid or missing phone numbers
SELECT id, driver_name, driver_phone, city
FROM public.sheet_driver_onboarding
WHERE driver_phone IS NULL OR length(driver_phone) < 10;
