# LetzRyd Core Partner Onboarding (Final Table) - Knowledge Transfer Documentation

| System Metadata | Details |
|---|---|
| **Target Database Host** | YOUR_DB_HOST_HERE:5432 |
| **Database Engine** | PostgreSQL 14+ |
| **Database Name** | postgres |
| **Target Master Table** | public.core_partner_onboarding |
| **Active Filtered View** | public.active_core_partner_onboarding |
| **Staging Source 1** | public.sheet_driver_onboarding (Google Sheet Pipeline) |
| **Staging Source 2** | public.july_form_onboarding (Web Portal Ingestion) |
| **Transactional Advisory Lock** | 777111222 |
| **Technology Stack** | PostgreSQL PL/pgSQL, Real-Time Ingestion Triggers |

---

## 1. Executive Summary & Architecture Overview

The **public.core_partner_onboarding** table serves as the company-wide **Master Single Source of Truth (SSOT)** for all driver-partner KYC, banking, and onboarding profiles across LetzRyd.

It consolidates incoming partner entries from both operational channels:
1. **Google Sheets (sheet_driver_onboarding)**: Master onboarding submissions cleansed by Google Apps Script.
2. **Web Portal (july_form_onboarding)**: Digital driver submissions from the LetzRyd Web Portal.

### Consolidated Master Data Flow

`
+---------------------------------------------------------------------------------+
|                       Google Sheets Landing Table                               |
|                     public.sheet_driver_onboarding                              |
+---------------------------------------------------------------------------------+
                                         |
                                         | AFTER INSERT / UPDATE Trigger
                                         | (trg_sheet_driver_onboarding_sync)
                                         v
+---------------------------------------------------------------------------------+
|                           Transactional Advisory Lock                           |
|                            pg_advisory_xact_lock(777111222)                     |
+---------------------------------------------------------------------------------+
                                         ^
                                         | AFTER INSERT / UPDATE Trigger
                                         | (trg_july_form_onboarding_sync)
                                         |
+---------------------------------------------------------------------------------+
|                          Web Portal Driver Submissions                          |
|                       public.july_form_onboarding                               |
+---------------------------------------------------------------------------------+
                                         |
                                         v
+---------------------------------------------------------------------------------+
|                          Master Single Source of Truth                          |
|                        public.core_partner_onboarding                           |
+---------------------------------------------------------------------------------+
                                         |
                                         v
+---------------------------------------------------------------------------------+
|                              Active Master View                                 |
|                     public.active_core_partner_onboarding                       |
|                          (WHERE is_deleted = FALSE)                             |
+---------------------------------------------------------------------------------+
`

### Key Engineering Guarantees
- **Gapless Sequential Primary Key**: Sequence allocation governed by transactional advisory locking (pg_advisory_xact_lock(777111222)) guaranteeing continuous id (1..N) without sequence burning or gaps.
- **Real-Time Synchronization**: Sub-10ms consolidation into core_partner_onboarding triggered instantly upon source table modifications.
- **Source Origin Attribution**: Every record is tagged as GOOGLE_SHEET, PORTAL_FORM, or MERGED.
- **Permanent Archival & Non-Destructive Soft Deletes**: Ingests source deletions with is_deleted = TRUE and deleted_at = NOW(), maintaining continuous sequence IDs and audit compliance.
- **Canonical Partner IDs**: Deterministic partner ID generator enforcing pattern ^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$.

---

## 2. Directory Structure & Key Artifacts

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

## 4. Verification Queries

`sql
-- Query 4.1: Overall counts and source origin breakdown
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

-- Query 4.2: Verify zero sequence gaps
SELECT 
    count(*) AS actual_rows,
    max(id) AS max_id,
    COALESCE(max(id), 0) - count(*) AS sequence_gap
FROM public.core_partner_onboarding;
`
