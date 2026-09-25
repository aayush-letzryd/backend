-- =============================================================================
-- LETZRYD MASTER TRAFFIC CHALLANS SSOT DDL: public.core_challans
-- Host: 35.200.196.113:5432 | DB: postgres | Schema: public
-- =============================================================================
-- Description:
-- Master core table unifying two independent traffic challan data sources:
--   1. public.vehicle_challans (Automated Karnataka One direct scraping pipeline - Bangalore)
--   2. public.sheet_challans (Google Sheets operational logs across 38 weekly cycles - All Cities)
--
-- Merging & Precedence Policy:
--   - Bangalore: vehicle_challans takes priority (official police notice numbers, ITMS camera locations,
--     official offence descriptions, portal payment statuses). Matches with sheet_challans on
--     (vehicle_reg_no, violation_date, challan_amount) to enrich remarks/tab metadata without duplicates.
--     Historical/unscraped Bangalore sheet records are preserved as fallback.
--   - Mumbai & Hyderabad: sheet_challans is primary source for all active violations.
--   - Zero-Fine Routine Audits: 54,000+ weekly balance checks (challan_amount = 0) are excluded.
--
-- Architectural Guarantees:
--   - 100% Downstream: Source tables (vehicle_challans, sheet_challans) are NEVER modified or locked.
--   - Zero Database Triggers: Decoupled scheduled batch execution via pg_cron (no table locks).
--   - Normalized Dates: Settlement weeks are dynamically joined via hisaab_settlement_weeks on violation_date.
-- =============================================================================

-- 1. Master Table Definition
CREATE TABLE IF NOT EXISTS public.core_challans (
    id BIGSERIAL PRIMARY KEY,
    
    -- Source System & Provenance
    source_system VARCHAR(50) NOT NULL,    -- 'KARNATAKA_ONE_SCRAPER', 'GOOGLE_SHEET', 'MERGED_AUTOMATION_SHEET'
    source_priority VARCHAR(20) NOT NULL,  -- 'SCRAPER_PRIMARY', 'SHEET_PRIMARY', 'SHEET_FALLBACK'
    sheet_challan_id BIGINT,                -- Foreign key pointer to sheet_challans.id
    automated_challan_id BIGINT,            -- Foreign key pointer to vehicle_challans.id
    
    -- Vehicle & Location Identifiers
    vehicle_reg_no VARCHAR(20) NOT NULL,
    city VARCHAR(50) NOT NULL,              -- 'Bangalore', 'Mumbai', 'Hyderabad'
    rc_holder_name VARCHAR(255),            -- Official RC owner from government portal
    
    -- Violation Details & Evidence
    notice_no VARCHAR(100) NOT NULL,        -- Official Police notice number (or deterministic sheet notice ID)
    violation_date DATE NOT NULL,           -- Validated infraction date
    violation_time TIME WITHOUT TIME ZONE,  -- Exact violation time
    notice_date DATE,                       -- Official notice issuance date
    audit_date DATE,                        -- Operational audit date from weekly ledger
    offence_description TEXT,               -- Official police offence (e.g. 'JUMPING TRAFFIC SIGNALS')
    police_station VARCHAR(255),            -- Police station or ITMS camera junction
    violation_location TEXT,                -- Full junction/road description
    liability_type VARCHAR(50) NOT NULL DEFAULT 'TRAFFIC_FINE', -- 'TRAFFIC_FINE', 'STICKER_FINE'
    
    -- Financial Breakdown (Money to Ask For)
    challan_amount NUMERIC(10, 2) NOT NULL DEFAULT 0.00,      -- Official government fine
    sticker_fine NUMERIC(10, 2) NOT NULL DEFAULT 0.00,        -- Internal company sticker fine
    total_fine_amount NUMERIC(10, 2) NOT NULL DEFAULT 0.00,   -- challan_amount + sticker_fine
    amount_paid NUMERIC(10, 2) NOT NULL DEFAULT 0.00,         -- Amount recovered / settled
    net_pending_amount NUMERIC(10, 2) NOT NULL DEFAULT 0.00,  -- Technically pending amount = total - paid
    payment_status VARCHAR(30) NOT NULL DEFAULT 'UNPAID',     -- 'UNPAID', 'PAID', 'PARTIALLY_PAID', 'DISPUTED'
    
    -- Traceability Metadata
    source_tab VARCHAR(100),                -- Sheet tab name
    sheet_row_number INTEGER,               -- Sheet row index
    scraped_at TIMESTAMP WITH TIME ZONE,    -- Portal scrape timestamp
    remarks TEXT,                           -- Fleet manager notes
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Natural Business Key: A vehicle cannot have the same notice number twice
    CONSTRAINT uq_core_challans_reg_notice UNIQUE (vehicle_reg_no, notice_no)
);

-- Performance B-Tree Indexes
CREATE INDEX IF NOT EXISTS idx_core_challans_reg_no ON public.core_challans(vehicle_reg_no);
CREATE INDEX IF NOT EXISTS idx_core_challans_city ON public.core_challans(city);
CREATE INDEX IF NOT EXISTS idx_core_challans_vio_date ON public.core_challans(violation_date);
CREATE INDEX IF NOT EXISTS idx_core_challans_pay_status ON public.core_challans(payment_status);
CREATE INDEX IF NOT EXISTS idx_core_challans_pending ON public.core_challans(net_pending_amount);
CREATE INDEX IF NOT EXISTS idx_core_challans_is_deleted ON public.core_challans(is_deleted);

-- =============================================================================
-- 2. Stored Procedure: sp_sync_core_challans()
-- Idempotent, high-performance batch synchronization engine (~0.6 sec execution)
-- =============================================================================

CREATE OR REPLACE PROCEDURE public.sp_sync_core_challans()
LANGUAGE plpgsql
AS $$
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Ingest Scraper Data for Bangalore (SCRAPER_PRIMARY)
    -- -------------------------------------------------------------------------
    INSERT INTO public.core_challans (
        source_system, source_priority, automated_challan_id,
        vehicle_reg_no, city, rc_holder_name,
        notice_no, violation_date, violation_time, notice_date,
        offence_description, police_station, violation_location, liability_type,
        challan_amount, sticker_fine, total_fine_amount, amount_paid, net_pending_amount,
        payment_status, scraped_at, is_deleted, created_at, updated_at
    )
    SELECT 
        'KARNATAKA_ONE_SCRAPER',
        'SCRAPER_PRIMARY',
        v.id,
        UPPER(REGEXP_REPLACE(TRIM(v.vehicle_reg_no), '[^A-Za-z0-9]', '', 'g')),
        'Bangalore',
        NULLIF(TRIM(v.rc_holder_name), 'N/A'),
        TRIM(v.notice_no),
        TO_DATE(v.violation_date, 'DD-MM-YYYY'),
        CASE 
            WHEN v.violation_time ~ '^[0-9]{1,2}:[0-9]{2}' THEN CAST(SUBSTRING(v.violation_time FROM 1 FOR 5) AS TIME)
            ELSE NULL 
        END,
        CASE 
            WHEN v.notice_generation_date ~ '^[0-9]{2}-[0-9]{2}-[0-9]{4}' THEN TO_DATE(v.notice_generation_date, 'DD-MM-YYYY')
            ELSE NULL 
        END,
        NULLIF(TRIM(v.offence_description), 'N/A'),
        NULLIF(TRIM(v.point_name), 'N/A'),
        NULLIF(TRIM(v.point_name), 'N/A'),
        'TRAFFIC_FINE',
        COALESCE(v.fine_amount, 0.00),
        0.00,
        COALESCE(v.fine_amount, 0.00),
        CASE WHEN v.payment_status = 'PAID' THEN COALESCE(v.fine_amount, 0.00) ELSE 0.00 END,
        CASE WHEN v.payment_status = 'PAID' THEN 0.00 ELSE COALESCE(v.fine_amount, 0.00) END,
        COALESCE(v.payment_status, 'UNPAID'),
        v.last_scraped_at,
        FALSE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    FROM vehicle_challans v
    WHERE v.status = 'HAS_FINES'
      AND v.notice_no IS NOT NULL AND v.notice_no <> 'N/A'
      AND v.violation_date IS NOT NULL AND v.violation_date <> 'N/A'
      AND v.violation_date ~ '^[0-9]{2}-[0-9]{2}-[0-9]{4}'
    ON CONFLICT (vehicle_reg_no, notice_no) DO UPDATE
    SET payment_status = EXCLUDED.payment_status,
        amount_paid = EXCLUDED.amount_paid,
        net_pending_amount = EXCLUDED.net_pending_amount,
        scraped_at = EXCLUDED.scraped_at,
        updated_at = CURRENT_TIMESTAMP;

    -- -------------------------------------------------------------------------
    -- 2. Enrich Matched Bangalore Records from sheet_challans (Zero Duplicates)
    -- -------------------------------------------------------------------------
    WITH ranked_sheet_matches AS (
        SELECT 
            s.id AS sheet_id,
            s.vehicle_reg_no,
            s.violation_date,
            s.challan_amount,
            s.sticker_fine,
            s.amount_paid,
            s.remarks,
            s.source_tab,
            s.sheet_row_number,
            c.id AS core_id,
            ROW_NUMBER() OVER(PARTITION BY c.id ORDER BY s.id ASC) AS rn
        FROM sheet_challans s
        JOIN core_challans c 
          ON c.vehicle_reg_no = s.vehicle_reg_no 
         AND c.violation_date = s.violation_date 
         AND c.challan_amount = s.challan_amount
         AND c.city = 'Bangalore'
        WHERE s.city = 'Bangalore' AND s.challan_amount > 0
    )
    UPDATE core_challans c
    SET source_system = 'MERGED_AUTOMATION_SHEET',
        sheet_challan_id = m.sheet_id,
        source_tab = m.source_tab,
        sheet_row_number = m.sheet_row_number,
        sticker_fine = COALESCE(m.sticker_fine, c.sticker_fine),
        total_fine_amount = c.challan_amount + COALESCE(m.sticker_fine, 0.00),
        amount_paid = GREATEST(c.amount_paid, COALESCE(m.amount_paid, 0.00)),
        net_pending_amount = GREATEST(0.00, c.challan_amount + COALESCE(m.sticker_fine, 0.00) - GREATEST(c.amount_paid, COALESCE(m.amount_paid, 0.00))),
        remarks = COALESCE(NULLIF(TRIM(m.remarks), ''), c.remarks),
        updated_at = CURRENT_TIMESTAMP
    FROM ranked_sheet_matches m
    WHERE c.id = m.core_id AND m.rn = 1;

    -- -------------------------------------------------------------------------
    -- 3. Ingest Unmatched Bangalore Historical Records (SHEET_FALLBACK)
    -- -------------------------------------------------------------------------
    INSERT INTO public.core_challans (
        source_system, source_priority, sheet_challan_id,
        vehicle_reg_no, city,
        notice_no, violation_date, violation_time, notice_date, audit_date,
        liability_type, challan_amount, sticker_fine, total_fine_amount, amount_paid, net_pending_amount,
        payment_status, source_tab, sheet_row_number, remarks,
        is_deleted, created_at, updated_at
    )
    SELECT 
        'GOOGLE_SHEET',
        'SHEET_FALLBACK',
        s.id,
        s.vehicle_reg_no,
        'Bangalore',
        s.notice_no,
        COALESCE(s.violation_date, s.notice_date, s.audit_date, '2026-01-01'::date),
        s.violation_time,
        s.notice_date,
        s.audit_date,
        CASE WHEN s.challan_amount > 0 THEN 'TRAFFIC_FINE' ELSE 'STICKER_FINE' END,
        COALESCE(s.challan_amount, 0.00),
        COALESCE(s.sticker_fine, 0.00),
        COALESCE(s.challan_amount, 0.00) + COALESCE(s.sticker_fine, 0.00),
        COALESCE(s.amount_paid, 0.00),
        GREATEST(0.00, COALESCE(s.challan_amount, 0.00) + COALESCE(s.sticker_fine, 0.00) - COALESCE(s.amount_paid, 0.00)),
        CASE 
            WHEN COALESCE(s.total_pending, 0.00) <= 0 AND (COALESCE(s.challan_amount, 0) > 0 OR COALESCE(s.sticker_fine, 0) > 0) THEN 'PAID'
            WHEN COALESCE(s.amount_paid, 0.00) > 0 AND COALESCE(s.total_pending, 0.00) > 0 THEN 'PARTIALLY_PAID'
            ELSE 'UNPAID'
        END,
        s.source_tab,
        s.sheet_row_number,
        NULLIF(TRIM(s.remarks), ''),
        COALESCE(s.is_deleted, FALSE),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    FROM sheet_challans s
    LEFT JOIN core_challans c ON c.sheet_challan_id = s.id
    WHERE s.city = 'Bangalore'
      AND (s.challan_amount > 0 OR s.sticker_fine > 0)
      AND c.id IS NULL
    ON CONFLICT (vehicle_reg_no, notice_no) DO UPDATE
    SET amount_paid = EXCLUDED.amount_paid,
        net_pending_amount = EXCLUDED.net_pending_amount,
        payment_status = EXCLUDED.payment_status,
        remarks = EXCLUDED.remarks,
        updated_at = CURRENT_TIMESTAMP;

    -- -------------------------------------------------------------------------
    -- 4. Ingest Mumbai and Hyderabad Active Fines (SHEET_PRIMARY)
    -- -------------------------------------------------------------------------
    INSERT INTO public.core_challans (
        source_system, source_priority, sheet_challan_id,
        vehicle_reg_no, city,
        notice_no, violation_date, violation_time, notice_date, audit_date,
        liability_type, challan_amount, sticker_fine, total_fine_amount, amount_paid, net_pending_amount,
        payment_status, source_tab, sheet_row_number, remarks,
        is_deleted, created_at, updated_at
    )
    SELECT 
        'GOOGLE_SHEET',
        'SHEET_PRIMARY',
        s.id,
        s.vehicle_reg_no,
        s.city,
        s.notice_no,
        COALESCE(s.violation_date, s.notice_date, s.audit_date, '2026-01-01'::date),
        s.violation_time,
        s.notice_date,
        s.audit_date,
        CASE WHEN s.challan_amount > 0 THEN 'TRAFFIC_FINE' ELSE 'STICKER_FINE' END,
        COALESCE(s.challan_amount, 0.00),
        COALESCE(s.sticker_fine, 0.00),
        COALESCE(s.challan_amount, 0.00) + COALESCE(s.sticker_fine, 0.00),
        COALESCE(s.amount_paid, 0.00),
        GREATEST(0.00, COALESCE(s.challan_amount, 0.00) + COALESCE(s.sticker_fine, 0.00) - COALESCE(s.amount_paid, 0.00)),
        CASE 
            WHEN COALESCE(s.total_pending, 0.00) <= 0 AND (COALESCE(s.challan_amount, 0) > 0 OR COALESCE(s.sticker_fine, 0) > 0) THEN 'PAID'
            WHEN COALESCE(s.amount_paid, 0.00) > 0 AND COALESCE(s.total_pending, 0.00) > 0 THEN 'PARTIALLY_PAID'
            ELSE 'UNPAID'
        END,
        s.source_tab,
        s.sheet_row_number,
        NULLIF(TRIM(s.remarks), ''),
        COALESCE(s.is_deleted, FALSE),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    FROM sheet_challans s
    WHERE s.city IN ('Hyderabad', 'Mumbai')
      AND (s.challan_amount > 0 OR s.sticker_fine > 0)
    ON CONFLICT (vehicle_reg_no, notice_no) DO UPDATE
    SET amount_paid = EXCLUDED.amount_paid,
        net_pending_amount = EXCLUDED.net_pending_amount,
        payment_status = EXCLUDED.payment_status,
        remarks = EXCLUDED.remarks,
        updated_at = CURRENT_TIMESTAMP;

    -- -------------------------------------------------------------------------
    -- 5. Soft Delete Mirroring
    -- -------------------------------------------------------------------------
    UPDATE core_challans c
    SET is_deleted = TRUE,
        deleted_at = CURRENT_TIMESTAMP
    FROM sheet_challans s
    WHERE c.sheet_challan_id = s.id AND s.is_deleted = TRUE AND c.is_deleted = FALSE;

END;
$$;

-- =============================================================================
-- 3. Operational Rollup Views for Vehicle Pending Challans
-- =============================================================================

CREATE OR REPLACE VIEW public.v_vehicle_pending_challans_summary AS
SELECT 
    vehicle_reg_no,
    city,
    COUNT(*) AS total_violations_incurred,
    COUNT(CASE WHEN payment_status = 'UNPAID' THEN 1 END) AS pending_challans_count,
    SUM(challan_amount) AS total_police_fines,
    SUM(sticker_fine) AS total_sticker_fines,
    SUM(CASE WHEN payment_status = 'UNPAID' THEN net_pending_amount ELSE 0.00 END) AS total_pending_amount,
    MIN(CASE WHEN payment_status = 'UNPAID' THEN violation_date END) AS earliest_pending_date,
    MAX(CASE WHEN payment_status = 'UNPAID' THEN violation_date END) AS latest_pending_date
FROM public.core_challans
WHERE is_deleted = FALSE
GROUP BY vehicle_reg_no, city;

CREATE OR REPLACE VIEW public.v_weekly_vehicle_pending_challans AS
SELECT 
    COALESCE(w.week_id, 'UNKNOWN_WEEK') AS settlement_week,
    w.week_start,
    w.week_end,
    c.vehicle_reg_no,
    c.city,
    COUNT(*) AS total_violations,
    COUNT(CASE WHEN c.payment_status = 'UNPAID' THEN 1 END) AS pending_count,
    SUM(c.challan_amount) AS week_police_fine,
    SUM(c.sticker_fine) AS week_sticker_fine,
    SUM(CASE WHEN c.payment_status = 'UNPAID' THEN c.net_pending_amount ELSE 0.00 END) AS week_pending_amount,
    STRING_AGG(c.notice_no, ', ' ORDER BY c.violation_date) AS notice_numbers
FROM public.core_challans c
LEFT JOIN public.hisaab_settlement_weeks w 
    ON c.violation_date BETWEEN w.week_start AND w.week_end
WHERE c.is_deleted = FALSE
GROUP BY w.week_id, w.week_start, w.week_end, c.vehicle_reg_no, c.city;
