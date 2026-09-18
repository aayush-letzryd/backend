# LetzRyd Partner Onboarding Live Pipeline - Knowledge Transfer Documentation

Target Database: YOUR_DB_HOST_HERE:5432  
Database Name: postgres  
Target Landing Table: public.sheet_driver_onboarding  
Source Google Sheet Tab: Onboarding form_V2 (from Pan India Master Sheet)  
Clean Intermediate Sheet Tab: sheet_driver_onboarding  
Technology Stack: Google Apps Script (JavaScript), PostgreSQL 14+, JDBC  

---

## 1. Executive Summary & Overview

The **LetzRyd Partner Onboarding Google Sheet Pipeline** provides automated data ingestion, multi-field standardization, and zero-burn upserts for all driver-partner onboarding submissions from Google Sheets into the public.sheet_driver_onboarding PostgreSQL landing table.

### Primary System Guarantees
- **Direct Background Pulling**: Bypasses formula cell freeze and IMPORTRANGE limitations using Apps Script openByUrl().
- **Micro-Batch JDBC Engine**: Ingests data using parameterized batching (BATCH_SIZE = 5) with row-level error fallback, preventing SQL size limit exceptions.
- **IST Timestamp Contract**: Stored as clean TIMESTAMP WITHOUT TIME ZONE in Indian Standard Time (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata').
- **Deterministic Canonical Partner IDs**: Validated pattern ^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$.
- **47-Issue Data Hygiene**: Cleans OCR errors, DL expiry date strings, phone floats/scientific notation, and text case.

---

## 2. Directory Contents

| File | Description |
|---|---|
| [partner_onboarding_pipeline_appscript.js](./partner_onboarding_pipeline_appscript.js) | Production Google Apps Script engine featuring 1-minute automated polling, 47-issue standardization engine, micro-batch JDBC upsert, and headless UI safety. |
| [schema.sql](./schema.sql) | PostgreSQL DDL definitions for sheet_driver_onboarding, performance indexes, and verification queries. |
| [data_issues.md](./data_issues.md) | Comprehensive audit of all 47 data quality anomalies (ISS-16 through ISS-62) from Master_Issue_Standardization_Catalog.xlsx and their programmatic transformations. |
| [README.md](./README.md) | Complete Knowledge Transfer (KT) document, system architecture, and operational runbook. |

---

## 3. Database Schema: public.sheet_driver_onboarding

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

## 4. Verification Queries

`sql
SELECT 
    count(*) AS total_rows,
    count(DISTINCT driver_phone) AS unique_phone_count,
    min(id) AS min_id,
    max(id) AS max_id,
    max(submission_timestamp) AS latest_submission
FROM public.sheet_driver_onboarding;
`
