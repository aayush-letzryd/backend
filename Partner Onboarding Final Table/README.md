# LetzRyd Core Partner Onboarding (Final Table) - Knowledge Transfer Documentation

Target Database: YOUR_DB_HOST_HERE:5432  
Database Name: postgres  
Target Master Table: public.core_partner_onboarding  
Active Filtered View: public.active_core_partner_onboarding  
Staging Source 1: public.sheet_driver_onboarding (Google Sheet Ingestion)  
Staging Source 2: public.july_form_onboarding (LetzRyd Web Portal Intake Form)  
Advisory Lock ID: 777111222  
Technology Stack: PostgreSQL 14+, PL/pgSQL, Real-Time Ingestion Triggers  

---

## 1. Executive Summary & Architecture

The **public.core_partner_onboarding** table serves as the definitive, company-wide **Single Source of Truth (SSOT)** for all driver-partner KYC and onboarding records across LetzRyd fleet operations.

It unifies incoming driver registrations across both operational channels:
1. **Google Sheets (sheet_driver_onboarding)**: Historical and operational physical entries synchronized via automated Google Apps Script.
2. **Web Portal (july_form_onboarding)**: Digital driver submissions from the LetzRyd Driver Portal.

### Primary Engineering Guarantees
- **Unified Master Entity**: Consolidates multiple submission channels by unique driver phone number (phone_number VARCHAR(20) UNIQUE).
- **Gapless Sequential Primary Key**: Sequence allocation governed by transactional advisory locking (pg_advisory_xact_lock(777111222)) guaranteeing continuous id (1..N) without sequence burning or gaps.
- **Real-Time Bidirectional Synchronization Triggers**: Native PostgreSQL triggers (	rg_sheet_driver_onboarding_sync and 	rg_july_form_onboarding_sync) ensure immediate, sub-10ms consolidation upon any INSERT or UPDATE in either staging source.
- **Source Origin Attribution**: Stamped as GOOGLE_SHEET, PORTAL_FORM, or MERGED depending on channel provenance.
- **Permanent Archival & Non-Destructive Soft Deletes**: Ingests deletions with is_deleted = TRUE and deleted_at = NOW(), preserving historical audit integrity and gapless IDs.
- **Active Master View**: Filtered access provided via public.active_core_partner_onboarding (WHERE is_deleted = FALSE).
- **Standardized Partner IDs**: Enforces deterministic canonical ID format ^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$.
- **IST Timestamp Standardization**: Timestamps stored without timezone offsets in clean Indian Standard Time (Asia/Kolkata).

---

## 2. Directory Contents

| File | Description |
|---|---|
| [schema.sql](./schema.sql) | Master DDL for core_partner_onboarding, filtered view ctive_core_partner_onboarding, advisory locks, canonical ID generator, real-time triggers, and the stored consolidation procedure 
efresh_core_partner_onboarding(). |
| [data_issues.md](./data_issues.md) | Comprehensive audit catalog of all 47 data anomalies (ISS-16 through ISS-62), document extraction fixes, and standardization rules. |
| [README.md](./README.md) | Exhaustive architectural blueprint, trigger specification, operational runbook, and verification queries. |

---

## 3. Database Schema DDL: public.core_partner_onboarding

`sql
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

CREATE OR REPLACE VIEW public.active_core_partner_onboarding AS
SELECT * FROM public.core_partner_onboarding
WHERE is_deleted = FALSE;
`

---

## 4. Trigger Consolidation Architecture

`mermaid
flowchart TD
    A[public.sheet_driver_onboarding] -->|AFTER INSERT OR UPDATE
trg_sheet_driver_onboarding_sync| C{Advisory Lock
777111222}
    B[public.july_form_onboarding] -->|AFTER INSERT OR UPDATE
trg_july_form_onboarding_sync| C
    C -->|Deterministic Upsert by Phone| D[(public.core_partner_onboarding)]
    D -->|WHERE is_deleted = FALSE| E[public.active_core_partner_onboarding]
`

When new records or updates arrive in either source table:
1. The transaction acquires transactional advisory lock 777111222.
2. Checks if a master record already exists for the standardized 10-digit phone number.
3. If new, allocates the next gapless id = COALESCE(MAX(id), 0) + 1 and inserts.
4. If existing, performs zero-burn CTE update, merging non-null portal and sheet data fields.
5. Updates source_origin to MERGED if records exist in both sources.

---

## 5. Stored Consolidation Procedure

To perform an idempotent full reconciliation or scheduled bulk refresh:
`sql
CALL public.refresh_core_partner_onboarding();
`

---

## 6. Operational Verification Queries

`sql
-- Query 6.1: Overall counts and source origin breakdown
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

-- Query 6.2: Verify zero sequence gaps
SELECT 
    count(*) AS actual_rows,
    max(id) AS max_id,
    COALESCE(max(id), 0) - count(*) AS sequence_gap
FROM public.core_partner_onboarding;

-- Query 6.3: Verify canonical partner ID formatting
SELECT partner_id, driver_name, phone_number, city
FROM public.core_partner_onboarding
WHERE partner_id !~ '^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$';
`
