-- =============================================================================
-- LetzRyd Walkin Form Live Pipeline - PostgreSQL Database Schema
-- =============================================================================
-- Target Database: postgres
-- Target Schema  : public
-- Target Table   : sheet_walkins
-- Host           : YOUR_DB_HOST_HERE:5432
-- Description    : Central table storing real-time walk-in partner data synced
--                  from Google Sheets (tab: walkin_form).
-- =============================================================================

-- 1. Table DDL
CREATE TABLE IF NOT EXISTS public.sheet_walkins (
    id BIGSERIAL PRIMARY KEY,
    submission_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    submitter_email VARCHAR(255),
    city VARCHAR(100),
    attending_executive VARCHAR(255),
    partner_name VARCHAR(255),
    partner_number VARCHAR(20),
    dl_number VARCHAR(100),
    visiting_reason TEXT,
    remarks TEXT,
    joined_date DATE,
    joined_status VARCHAR(100),
    sheet_row_number INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_sheet_walkins_event UNIQUE (submission_timestamp, partner_number)
);

-- 2. Performance B-Tree Indexes
-- Optimizes queries for operations portals, mobile apps, and analytics reporting.

CREATE INDEX IF NOT EXISTS idx_sheet_walkins_date 
    ON public.sheet_walkins (submission_timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_sheet_walkins_phone 
    ON public.sheet_walkins (partner_number);

CREATE INDEX IF NOT EXISTS idx_sheet_walkins_city 
    ON public.sheet_walkins (city);

CREATE INDEX IF NOT EXISTS idx_sheet_walkins_exec 
    ON public.sheet_walkins (attending_executive);

CREATE INDEX IF NOT EXISTS idx_sheet_walkins_dl 
    ON public.sheet_walkins (dl_number);

CREATE INDEX IF NOT EXISTS idx_sheet_walkins_jdate 
    ON public.sheet_walkins (joined_date);

CREATE INDEX IF NOT EXISTS idx_sheet_walkins_updated 
    ON public.sheet_walkins (updated_at DESC);

-- 3. Production Zero-Burn Upsert Query (Eliminates Sequence Gaps on Conflict)
-- Checks for existing rows first; only calls nextval('sheet_walkins_id_seq') for brand-new rows.
/*
WITH incoming AS (
    SELECT 
        CAST(? AS timestamptz) AS ts,
        CAST(? AS varchar) AS email,
        CAST(? AS varchar) AS city,
        CAST(? AS varchar) AS exec,
        CAST(? AS varchar) AS name,
        CAST(? AS varchar) AS phone,
        CAST(? AS varchar) AS dl,
        CAST(? AS text) AS reason,
        CAST(? AS text) AS remarks,
        CAST(? AS date) AS jDate,
        CAST(? AS varchar) AS jStatus,
        CAST(? AS integer) AS sheetRow
),
upd AS (
    UPDATE public.sheet_walkins w
    SET 
        submitter_email = i.email,
        city = i.city,
        attending_executive = i.exec,
        partner_name = i.name,
        dl_number = i.dl,
        visiting_reason = i.reason,
        remarks = i.remarks,
        joined_date = i.jDate,
        joined_status = i.jStatus,
        sheet_row_number = i.sheetRow,
        updated_at = CURRENT_TIMESTAMP
    FROM incoming i
    WHERE w.submission_timestamp = i.ts 
      AND w.partner_number = i.phone
    RETURNING w.id
)
INSERT INTO public.sheet_walkins (
    id, submission_timestamp, submitter_email, city, attending_executive,
    partner_name, partner_number, dl_number, visiting_reason, remarks,
    joined_date, joined_status, sheet_row_number, updated_at
)
SELECT 
    nextval('sheet_walkins_id_seq'),
    i.ts, i.email, i.city, i.exec,
    i.name, i.phone, i.dl, i.reason, i.remarks,
    i.jDate, i.jStatus, i.sheetRow, CURRENT_TIMESTAMP
FROM incoming i
WHERE NOT EXISTS (SELECT 1 FROM upd);
*/

-- 4. Sample Verification & Operational Queries

-- Query 4.1: Overall record counts and time bounds
SELECT 
    count(*) AS total_records,
    min(submission_timestamp) AS earliest_entry,
    max(submission_timestamp) AS latest_entry,
    count(DISTINCT partner_number) AS unique_partners
FROM public.sheet_walkins;

-- Query 4.2: Latest 25 walk-ins
SELECT 
    id,
    submission_timestamp,
    city,
    attending_executive,
    partner_name,
    partner_number,
    visiting_reason,
    joined_status,
    joined_date
FROM public.sheet_walkins
ORDER BY submission_timestamp DESC
LIMIT 25;

-- Query 4.3: Partner phone search (10 digits)
SELECT * 
FROM public.sheet_walkins 
WHERE partner_number = '8185011074';

-- Query 4.4: Partner name search (case-insensitive)
SELECT * 
FROM public.sheet_walkins 
WHERE partner_name ILIKE '%ASHRAFF%';

-- Query 4.5: City-level conversion breakdown
SELECT 
    COALESCE(city, 'Unknown') AS city,
    count(*) AS total_walkins,
    count(CASE WHEN joined_status ILIKE '%joined%' THEN 1 END) AS total_joined,
    round(count(CASE WHEN joined_status ILIKE '%joined%' THEN 1 END) * 100.0 / NULLIF(count(*), 0), 2) AS conversion_rate_pct
FROM public.sheet_walkins
GROUP BY city
ORDER BY total_walkins DESC;

-- Query 4.6: Executive performance report
SELECT 
    attending_executive,
    count(*) AS total_handled,
    count(CASE WHEN joined_status ILIKE '%joined%' THEN 1 END) AS successful_joins
FROM public.sheet_walkins
GROUP BY attending_executive
ORDER BY total_handled DESC;

-- Query 4.7: Records synced within the past 24 hours
SELECT 
    id,
    submission_timestamp,
    partner_name,
    partner_number,
    attending_executive,
    sheet_row_number,
    updated_at
FROM public.sheet_walkins
WHERE updated_at >= NOW() - INTERVAL '24 hours'
ORDER BY updated_at DESC;
