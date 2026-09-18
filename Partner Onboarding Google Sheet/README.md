# LetzRyd Partner Onboarding Live Pipeline - Knowledge Transfer Documentation

| System Metadata | Details |
|---|---|
| **Target Database Host** | YOUR_DB_HOST_HERE:5432 |
| **Database Engine** | PostgreSQL 14+ |
| **Database Name** | postgres |
| **Target Landing Table** | public.sheet_driver_onboarding |
| **Source Master Sheet** | Pan India Master Sheet (Tab: Onboarding form_V2) |
| **Clean Intermediate Tab** | sheet_driver_onboarding |
| **Technology Stack** | Google Apps Script (JavaScript), PostgreSQL JDBC |

---

## 1. Executive Summary & Architecture Overview

The **LetzRyd Partner Onboarding Google Sheet Pipeline** provides real-time data ingestion, multi-field standardization, and zero-burn upserts for all driver-partner onboarding records coming from Google Sheets into the PostgreSQL public.sheet_driver_onboarding landing table.

### Operational Data Flow

`	ext
+---------------------------------------------------------------------------------+
|                            Pan India Master Sheet                               |
|                  Tab: 'Onboarding form_V2' (View-Only Access)                   |
+---------------------------------------------------------------------------------+
                                         |
                                         | Direct Apps Script Background Pull
                                         | (openByUrl - No IMPORTRANGE dependency)
                                         v
+---------------------------------------------------------------------------------+
|                         Google Apps Script Pipeline Engine                      |
|                  - 47-Issue Standardization (ISS-16 to ISS-62)                  |
|                  - Micro-Batch JDBC Upserts (BATCH_SIZE = 5)                    |
|                  - Headless UI Safety & Row-Level Fallback                      |
+---------------------------------------------------------------------------------+
                     |                                           |
                     v                                           v
+------------------------------------------+   +----------------------------------+
|           Editable Google Sheet          |   |        PostgreSQL Database       |
|       Tab: sheet_driver_onboarding       |   |  Table: sheet_driver_onboarding  |
+------------------------------------------+   +----------------------------------+
`

### Key Engineering Guarantees
- **Direct Background Pulling**: Eliminates formula freeze and cell limit issues by reading directly in memory via openByUrl().
- **Micro-Batch JDBC Engine**: Processes rows using parameterized batching (BATCH_SIZE = 5) with row-level error fallback, preventing SQL statement size limit exceptions (Argument too large: sql).
- **IST Timestamp Contract**: Timestamps are stored as clean TIMESTAMP WITHOUT TIME ZONE in Indian Standard Time (Asia/Kolkata).
- **Deterministic Canonical Partner IDs**: Validated company-wide pattern ^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$.
- **47-Issue Data Hygiene**: Automatically sanitizes OCR errors, DL expiry date strings, phone number floats/scientific notation, text case formatting, and missing documents.

---

## 2. Directory Structure & Key Artifacts

| File | Description |
|---|---|
| [partner_onboarding_pipeline_appscript.js](./partner_onboarding_pipeline_appscript.js) | Production Google Apps Script engine featuring 1-minute automated polling, 47-issue standardization engine, micro-batch JDBC upsert, and headless UI safety. |
| [schema.sql](./schema.sql) | PostgreSQL DDL definitions for public.sheet_driver_onboarding, performance indexes, and operational verification queries. |
| [data_issues.md](./data_issues.md) | Comprehensive audit of all 47 data quality anomalies (ISS-16 through ISS-62) from Master_Issue_Standardization_Catalog.xlsx and their exact programmatic transformations. |
| [README.md](./README.md) | Complete Knowledge Transfer (KT) document, system architecture, and operational runbook. |

---

## 3. Database Schema DDL: public.sheet_driver_onboarding

`sql
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
`

---

## 4. Operational Runbook & Verification Queries

`sql
-- Query 4.1: Total records & unique phone numbers in landing table
SELECT 
    count(*) AS total_rows,
    count(DISTINCT driver_phone) AS unique_phone_count,
    min(id) AS min_id,
    max(id) AS max_id,
    max(submission_timestamp) AS latest_submission
FROM public.sheet_driver_onboarding;

-- Query 4.2: City distribution in landing staging
SELECT city, count(*) AS total_records
FROM public.sheet_driver_onboarding
GROUP BY city
ORDER BY total_records DESC;
`
