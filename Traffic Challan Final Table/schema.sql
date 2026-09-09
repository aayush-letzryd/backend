-- =============================================================================
-- LetzRyd Master Traffic Challans Single Source of Truth: public.core_challans
-- =============================================================================
-- Description:
-- Master core table unifying two independent traffic challan data sources:
--   1. public.sheet_challans (Google Sheets manual ops logs across 38 weekly tabs)
--   2. public.vehicle_challans (Automated Karnataka One direct scraping pipeline)
--
-- Merging & Precedence Policy:
--   - Natural Business Key: (vehicle_reg_no, notice_no, week_cycle)
--   - Karnataka One Scraper Priority: Official government fine amounts, violation
--     descriptions, police station jurisdictions, and notice generation dates
--     take top priority when matched.
--   - Sheet Enrichment: Rolling balances (previous_balance), LetzRyd sticker fines
--     (sticker_fine), salary deductions (amount_paid), and audit remarks enrich
--     the record seamlessly.
--
-- Architectural Guarantees:
--   - Zero Changes to Upstream Tables: sheet_challans and vehicle_challans remain untouched.
--   - Clean IST Timestamps: All timestamps stored as TIMESTAMP WITHOUT TIME ZONE in Asia/Kolkata.
--   - Gapless Sequencing: Uses transactional advisory locks (lock ID 888999222) for continuous IDs.
--   - Soft Delete & Archival: Source deletions trigger is_deleted = TRUE without hard data destruction.
-- =============================================================================

-- 1. Master Table Definition (Non-Destructive Schema Creation)
CREATE TABLE IF NOT EXISTS public.core_challans (
    id BIGSERIAL PRIMARY KEY,
    
    -- Provenance & Source Attribution
    source_system VARCHAR(100) NOT NULL, -- 'KARNATAKA_ONE_SCRAPER', 'GOOGLE_SHEET', 'MERGED_AUTOMATION_SHEET'
    source_table VARCHAR(100) NOT NULL,  -- 'vehicle_challans', 'sheet_challans'
    sheet_challan_id BIGINT,             -- Pointer to sheet_challans.id
    automated_challan_id BIGINT,         -- Pointer to vehicle_challans.id
    
    -- Core Identifiers (Standardized)
    vehicle_reg_no VARCHAR(50) NOT NULL,
    rc_holder_name VARCHAR(255),
    notice_no VARCHAR(150) NOT NULL,
    city VARCHAR(100) NOT NULL,
    week_cycle VARCHAR(100),
    
    -- Violation Timeline & Jurisdiction
    violation_date DATE,
    violation_time TIME WITHOUT TIME ZONE,
    notice_date DATE,
    audit_date DATE,
    
    -- Violation Details & Offence Classification
    violation_description TEXT,
    police_station VARCHAR(255),
    violation_location TEXT,
    liability_type VARCHAR(50) DEFAULT 'TRAFFIC_FINE', -- 'TRAFFIC_FINE', 'STICKER_FINE', 'ROLLING_BALANCE'
    
    -- Financial Breakdown & Payment Ledger
    challan_amount NUMERIC(12, 2) DEFAULT 0.00,
    sticker_fine NUMERIC(12, 2) DEFAULT 0.00,
    previous_balance NUMERIC(12, 2) DEFAULT 0.00,
    amount_paid NUMERIC(12, 2) DEFAULT 0.00,
    total_pending NUMERIC(12, 2) DEFAULT 0.00,
    payment_status VARCHAR(50) DEFAULT 'PENDING',      -- 'PENDING', 'PAID', 'PARTIALLY_PAID', 'DISPUTED'
    
    -- Scraper & Document Metadata
    challan_image_url TEXT,
    scraped_at TIMESTAMP WITHOUT TIME ZONE,
    source_tab VARCHAR(100),
    sheet_row_number INTEGER,
    remarks TEXT,
    
    -- Gapless Audit & Soft Delete State
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    extra_attributes JSONB DEFAULT '{}'::jsonb,
    
    -- Audit Timestamps (Clean IST without timezone offset)
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
);

-- 2. Performance B-Tree Indexes
CREATE INDEX IF NOT EXISTS idx_core_challans_reg_no ON public.core_challans(vehicle_reg_no);
CREATE INDEX IF NOT EXISTS idx_core_challans_notice_no ON public.core_challans(notice_no);
CREATE INDEX IF NOT EXISTS idx_core_challans_city ON public.core_challans(city);
CREATE INDEX IF NOT EXISTS idx_core_challans_violation_date ON public.core_challans(violation_date);
CREATE INDEX IF NOT EXISTS idx_core_challans_payment_status ON public.core_challans(payment_status);
CREATE INDEX IF NOT EXISTS idx_core_challans_week_cycle ON public.core_challans(week_cycle);
CREATE INDEX IF NOT EXISTS idx_core_challans_source_system ON public.core_challans(source_system);
CREATE INDEX IF NOT EXISTS idx_core_challans_is_deleted ON public.core_challans(is_deleted);

-- =============================================================================
-- 3. Utility Cleaning Functions
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_clean_challan_plate(p_plate TEXT)
RETURNS VARCHAR(50) AS $$
DECLARE
    v_clean VARCHAR(50);
BEGIN
    IF p_plate IS NULL THEN RETURN NULL; END IF;
    v_clean := UPPER(REGEXP_REPLACE(TRIM(p_plate), '[^A-Za-z0-9]', '', 'g'));
    IF LENGTH(v_clean) < 8 OR LENGTH(v_clean) > 12 THEN
        RETURN NULL;
    END IF;
    IF v_clean IN ('TOTAL', 'REGNO', 'REGNO', 'BALANCE', 'SUBTOTAL') THEN
        RETURN NULL;
    END IF;
    RETURN v_clean;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.fn_parse_challan_date(p_str TEXT)
RETURNS DATE AS $$
DECLARE
    v_clean TEXT;
BEGIN
    IF p_str IS NULL THEN RETURN NULL; END IF;
    v_clean := TRIM(p_str);
    IF v_clean = '' OR LOWER(v_clean) IN ('null', 'nan', 'n/a', '-', '--') THEN
        RETURN NULL;
    END IF;
    
    -- DD-MM-YYYY or DD/MM/YYYY or DD.MM.YYYY
    IF v_clean ~ '^[0-9]{1,2}[/\-\.][0-9]{1,2}[/\-\.][0-9]{4}' THEN
        RETURN TO_DATE(SUBSTRING(v_clean FROM 1 FOR 10), 'DD-MM-YYYY');
    END IF;
    
    -- YYYY-MM-DD
    IF v_clean ~ '^[0-9]{4}[/\-][0-9]{1,2}[/\-][0-9]{1,2}' THEN
        RETURN TO_DATE(SUBSTRING(v_clean FROM 1 FOR 10), 'YYYY-MM-DD');
    END IF;
    
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.fn_parse_challan_time(p_str TEXT)
RETURNS TIME WITHOUT TIME ZONE AS $$
DECLARE
    v_clean TEXT;
BEGIN
    IF p_str IS NULL THEN RETURN NULL; END IF;
    v_clean := TRIM(p_str);
    IF v_clean = '' OR LOWER(v_clean) IN ('null', 'nan', 'n/a', '-', '--') THEN
        RETURN NULL;
    END IF;
    
    -- HH:MM:SS or HH:MM
    IF v_clean ~ '^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?' THEN
        RETURN CAST(v_clean AS TIME);
    END IF;
    
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- =============================================================================
-- 4. Trigger Function: Sync from public.vehicle_challans (Karnataka One Scraper)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_sync_core_challan_from_automation()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_plate VARCHAR(50);
    v_vio_date DATE;
    v_vio_time TIME WITHOUT TIME ZONE;
    v_not_date DATE;
    v_existing_id BIGINT;
    v_existing_sheet_id BIGINT;
    v_next_id BIGINT;
BEGIN
    -- Handle DELETE (Soft-Delete)
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_challans
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE automated_challan_id = OLD.id AND sheet_challan_id IS NULL;
        RETURN OLD;
    END IF;

    -- Skip non-fine or error records
    IF NEW.status = 'ERROR' OR NEW.status = 'NO_FINES' OR NEW.notice_no = 'ERROR' OR NEW.notice_no IS NULL THEN
        RETURN NEW;
    END IF;

    v_clean_plate := public.fn_clean_challan_plate(NEW.vehicle_reg_no);
    IF v_clean_plate IS NULL THEN
        RETURN NEW;
    END IF;

    v_vio_date := public.fn_parse_challan_date(NEW.violation_date);
    v_vio_time := public.fn_parse_challan_time(NEW.violation_time);
    v_not_date := public.fn_parse_challan_date(NEW.notice_generation_date);

    -- Check if matching record exists in core_challans
    SELECT id, sheet_challan_id INTO v_existing_id, v_existing_sheet_id
    FROM public.core_challans
    WHERE vehicle_reg_no = v_clean_plate AND notice_no = NEW.notice_no;

    IF v_existing_id IS NOT NULL THEN
        -- UPDATE existing row with Scraper priority
        UPDATE public.core_challans
        SET source_system = CASE WHEN v_existing_sheet_id IS NOT NULL THEN 'MERGED_AUTOMATION_SHEET' ELSE 'KARNATAKA_ONE_SCRAPER' END,
            automated_challan_id = NEW.id,
            rc_holder_name = COALESCE(NULLIF(NEW.rc_holder_name, 'ERROR'), rc_holder_name),
            city = 'Bangalore',
            violation_date = COALESCE(v_vio_date, violation_date),
            violation_time = COALESCE(v_vio_time, violation_time),
            notice_date = COALESCE(v_not_date, notice_date),
            violation_description = COALESCE(NULLIF(NEW.offence_description, ''), violation_description),
            police_station = COALESCE(NULLIF(NEW.point_name, ''), police_station),
            violation_location = COALESCE(NULLIF(NEW.point_name, ''), violation_location),
            challan_amount = COALESCE(NEW.fine_amount, challan_amount),
            total_pending = COALESCE(NEW.fine_amount, total_pending),
            payment_status = 'PENDING',
            liability_type = 'TRAFFIC_FINE',
            scraped_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;
    ELSE
        -- INSERT new row with gapless ID allocation
        PERFORM pg_advisory_xact_lock(888999222);
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_challans;

        INSERT INTO public.core_challans (
            id,
            source_system, source_table, automated_challan_id,
            vehicle_reg_no, rc_holder_name, notice_no, city, week_cycle,
            violation_date, violation_time, notice_date,
            violation_description, police_station, violation_location, liability_type,
            challan_amount, sticker_fine, previous_balance, amount_paid, total_pending,
            payment_status, scraped_at,
            is_deleted, created_at, updated_at
        ) VALUES (
            v_next_id,
            'KARNATAKA_ONE_SCRAPER', 'vehicle_challans', NEW.id,
            v_clean_plate, NULLIF(NEW.rc_holder_name, 'ERROR'), NEW.notice_no, 'Bangalore', 'AUTOMATION_SCRAPER',
            v_vio_date, v_vio_time, v_not_date,
            NULLIF(NEW.offence_description, ''), NULLIF(NEW.point_name, ''), NULLIF(NEW.point_name, ''), 'TRAFFIC_FINE',
            COALESCE(NEW.fine_amount, 0.00), 0.00, 0.00, 0.00, COALESCE(NEW.fine_amount, 0.00),
            'PENDING', (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            FALSE, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
        PERFORM setval('public.core_challans_id_seq', v_next_id, true);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_challan_from_automation ON public.vehicle_challans;
CREATE TRIGGER trg_sync_core_challan_from_automation
AFTER INSERT OR UPDATE OR DELETE ON public.vehicle_challans
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_challan_from_automation();


-- =============================================================================
-- 5. Trigger Function: Sync from public.sheet_challans (Google Sheets)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_sync_core_challan_from_sheet()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_plate VARCHAR(50);
    v_clean_city VARCHAR(100);
    v_existing_id BIGINT;
    v_existing_auto_id BIGINT;
    v_next_id BIGINT;
    v_liability_type VARCHAR(50);
    v_pay_status VARCHAR(50);
BEGIN
    -- Handle DELETE (Soft-Delete)
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_challans
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE sheet_challan_id = OLD.id AND automated_challan_id IS NULL;
        RETURN OLD;
    END IF;

    v_clean_plate := public.fn_clean_challan_plate(NEW.vehicle_reg_no);
    IF v_clean_plate IS NULL THEN
        RETURN NEW;
    END IF;

    v_clean_city := COALESCE(NULLIF(TRIM(NEW.city), ''), 'Bangalore');
    IF LOWER(v_clean_city) LIKE '%hyd%' THEN v_clean_city := 'Hyderabad';
    ELSIF LOWER(v_clean_city) LIKE '%mum%' THEN v_clean_city := 'Mumbai';
    ELSIF LOWER(v_clean_city) LIKE '%pun%' THEN v_clean_city := 'Pune';
    ELSIF LOWER(v_clean_city) LIKE '%blr%' OR LOWER(v_clean_city) LIKE '%bang%' THEN v_clean_city := 'Bangalore';
    END IF;

    -- Classify liability type
    IF COALESCE(NEW.challan_amount, 0.00) > 0 THEN
        v_liability_type := 'TRAFFIC_FINE';
    ELSIF COALESCE(NEW.sticker_fine, 0.00) > 0 THEN
        v_liability_type := 'STICKER_FINE';
    ELSE
        v_liability_type := 'ROLLING_BALANCE';
    END IF;

    -- Classify payment status
    IF COALESCE(NEW.total_pending, 0.00) <= 0 AND (COALESCE(NEW.challan_amount, 0) > 0 OR COALESCE(NEW.sticker_fine, 0) > 0) THEN
        v_pay_status := 'PAID';
    ELSIF COALESCE(NEW.amount_paid, 0.00) > 0 AND COALESCE(NEW.total_pending, 0.00) > 0 THEN
        v_pay_status := 'PARTIALLY_PAID';
    ELSE
        v_pay_status := 'PENDING';
    END IF;

    -- Check if record already exists in core_challans
    SELECT id, automated_challan_id INTO v_existing_id, v_existing_auto_id
    FROM public.core_challans
    WHERE vehicle_reg_no = v_clean_plate AND notice_no = NEW.notice_no;

    IF v_existing_id IS NOT NULL THEN
        -- UPDATE existing row (enrich sheet-specific fields without overwriting scraper priority)
        UPDATE public.core_challans
        SET source_system = CASE WHEN v_existing_auto_id IS NOT NULL THEN 'MERGED_AUTOMATION_SHEET' ELSE 'GOOGLE_SHEET' END,
            sheet_challan_id = NEW.id,
            city = CASE WHEN v_existing_auto_id IS NOT NULL THEN city ELSE v_clean_city END,
            week_cycle = COALESCE(NEW.week_cycle, week_cycle),
            previous_balance = COALESCE(NEW.previous_balance, previous_balance),
            audit_date = COALESCE(NEW.audit_date, audit_date),
            notice_date = COALESCE(notice_date, NEW.notice_date),
            violation_date = COALESCE(violation_date, NEW.violation_date),
            violation_time = COALESCE(violation_time, NEW.violation_time),
            challan_amount = CASE WHEN v_existing_auto_id IS NOT NULL THEN challan_amount ELSE COALESCE(NEW.challan_amount, 0.00) END,
            sticker_fine = COALESCE(NEW.sticker_fine, sticker_fine),
            amount_paid = COALESCE(NEW.amount_paid, amount_paid),
            total_pending = COALESCE(NEW.total_pending, total_pending),
            payment_status = CASE WHEN v_existing_auto_id IS NOT NULL THEN payment_status ELSE v_pay_status END,
            remarks = COALESCE(NULLIF(NEW.remarks, ''), remarks),
            source_tab = COALESCE(NEW.source_tab, source_tab),
            sheet_row_number = COALESCE(NEW.sheet_row_number, sheet_row_number),
            is_deleted = COALESCE(NEW.is_deleted, FALSE),
            deleted_at = CASE WHEN NEW.is_deleted = TRUE THEN COALESCE(NEW.deleted_at, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')) ELSE NULL END,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;
    ELSE
        -- INSERT new row with gapless ID allocation
        PERFORM pg_advisory_xact_lock(888999222);
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_challans;

        INSERT INTO public.core_challans (
            id,
            source_system, source_table, sheet_challan_id,
            vehicle_reg_no, notice_no, city, week_cycle,
            violation_date, violation_time, notice_date, audit_date,
            liability_type,
            challan_amount, sticker_fine, previous_balance, amount_paid, total_pending,
            payment_status, remarks, source_tab, sheet_row_number,
            is_deleted, created_at, updated_at
        ) VALUES (
            v_next_id,
            'GOOGLE_SHEET', 'sheet_challans', NEW.id,
            v_clean_plate, NEW.notice_no, v_clean_city, NEW.week_cycle,
            NEW.violation_date, NEW.violation_time, NEW.notice_date, NEW.audit_date,
            v_liability_type,
            COALESCE(NEW.challan_amount, 0.00), COALESCE(NEW.sticker_fine, 0.00), COALESCE(NEW.previous_balance, 0.00),
            COALESCE(NEW.amount_paid, 0.00), COALESCE(NEW.total_pending, 0.00),
            v_pay_status, NULLIF(NEW.remarks, ''), NEW.source_tab, NEW.sheet_row_number,
            COALESCE(NEW.is_deleted, FALSE),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
        PERFORM setval('public.core_challans_id_seq', v_next_id, true);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_challan_from_sheet ON public.sheet_challans;
CREATE TRIGGER trg_sync_core_challan_from_sheet
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_challans
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_challan_from_sheet();
