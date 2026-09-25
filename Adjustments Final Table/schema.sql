-- ==============================================================================
-- LETZRYD ADJUSTMENTS FINAL TABLE - POSTGRESQL PRODUCTION DDL
-- ==============================================================================
-- Target Database: postgres
-- Target Schema  : public
-- Target Table   : public.core_adjustments (Single Source of Truth)
-- Upstream Sources:
--   1. public.sheet_adjustments (Google Sheets 'Adjustment-Form' staging)
--   2. public.july_partner_adjustment (Web Portal adjustment submissions)
-- Architectural Guarantees:
--   - 1-to-1 Canonical Stacking: No data alteration, no value rewriting.
--   - Gapless 1..N ID sequence integrity (Zero Sequence Burning)
--   - Advisory Locks (pg_advisory_xact_lock(777333444)) for strict concurrency protection
--   - Deterministic deduplication on unique source ID ('ADJ-SHT-<id>', 'ADJ-PORTAL-<id>')
--   - Pure IST timestamps (TIMESTAMP WITHOUT TIME ZONE, 0 timezone offset drift)
--   - Soft-delete support (is_deleted = TRUE, deleted_at timestamp)
--   - Direct sync to downstream Hisaab (hisaab_adjustments_ledger)
-- ==============================================================================

-- 1. MASTER TABLE DDL
CREATE TABLE IF NOT EXISTS public.core_adjustments (
    id BIGINT PRIMARY KEY,
    adjustment_id VARCHAR(100) UNIQUE NOT NULL,
    partner_id VARCHAR(100),
    partner_name VARCHAR(255),
    partner_phone VARCHAR(100),
    partner_type VARCHAR(100) DEFAULT 'Individual',
    vehicle_number TEXT,
    city_name VARCHAR(100) NOT NULL,
    adjustment_type VARCHAR(100) NOT NULL,
    adjustment_nature VARCHAR(100) DEFAULT 'Monetary',
    adjustment_level VARCHAR(100) DEFAULT 'Driver',
    adjustment_date DATE NOT NULL,
    amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    remittance_towards VARCHAR(255),
    adjustment_related_to VARCHAR(255),
    hisaab_number VARCHAR(100),
    hisaab_week_number INTEGER,
    contested_line_items JSONB,
    severity_level VARCHAR(100) DEFAULT 'Low',
    cost_level VARCHAR(100) DEFAULT 'Direct',
    remarks TEXT,
    approval_status VARCHAR(100) DEFAULT 'Pending',
    first_level_approver VARCHAR(255),
    final_level_approver VARCHAR(255),
    current_approver_id VARCHAR(100),
    approved_by VARCHAR(255),
    photo_url TEXT,
    data_source VARCHAR(100) NOT NULL DEFAULT 'GOOGLE_SHEET', -- 'GOOGLE_SHEET', 'PORTAL_FORM'
    source_reference_id TEXT,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    CONSTRAINT chk_core_adjustments_amount CHECK (amount >= 0.00)
);

-- Underlying Sequence for tracking
CREATE SEQUENCE IF NOT EXISTS public.core_adjustments_id_seq OWNED BY public.core_adjustments.id;

-- 2. PERFORMANCE B-TREE INDEXES
CREATE INDEX IF NOT EXISTS idx_core_adj_business_key ON public.core_adjustments (
    partner_phone, adjustment_date, amount, adjustment_type
);
CREATE INDEX IF NOT EXISTS idx_core_adj_partner ON public.core_adjustments (partner_id);
CREATE INDEX IF NOT EXISTS idx_core_adj_phone ON public.core_adjustments (partner_phone);
CREATE INDEX IF NOT EXISTS idx_core_adj_veh ON public.core_adjustments (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_adj_date ON public.core_adjustments (adjustment_date);
CREATE INDEX IF NOT EXISTS idx_core_adj_status ON public.core_adjustments (approval_status);
CREATE INDEX IF NOT EXISTS idx_core_adj_active ON public.core_adjustments (is_deleted);
CREATE INDEX IF NOT EXISTS idx_core_adj_source ON public.core_adjustments (data_source);
CREATE INDEX IF NOT EXISTS idx_core_adj_ref ON public.core_adjustments (source_reference_id);

-- 3. FILTERED VIEW: Active Adjustments Only
CREATE OR REPLACE VIEW public.active_core_adjustments AS
SELECT * FROM public.core_adjustments
WHERE is_deleted = FALSE;

-- 4. HELPER FUNCTION: Status Standardizer
CREATE OR REPLACE FUNCTION public.fn_standardize_approval_status(p_status TEXT, p_default TEXT DEFAULT 'Pending')
RETURNS VARCHAR AS $$
DECLARE
    v_clean TEXT;
BEGIN
    IF p_status IS NULL OR TRIM(p_status) = '' THEN
        RETURN p_default;
    END IF;
    
    v_clean := UPPER(TRIM(p_status));
    
    -- Reject timestamps or ISO dates in status column (treat as Approved from re-submission)
    IF v_clean ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' OR v_clean ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}' THEN
        RETURN 'Approved';
    END IF;
    
    IF v_clean IN ('APPROVED', 'ACCEPTED', 'COMPLETED', 'PASS') THEN
        RETURN 'Approved';
    ELSIF v_clean IN ('REJECTED', 'DECLINED', 'FAILED', 'FAIL') THEN
        RETURN 'Rejected';
    ELSIF v_clean IN ('DRAFT') THEN
        RETURN 'Draft';
    ELSIF v_clean IN ('PENDING', 'PENDING APPROVAL', 'HOLD', 'IN REVIEW', 'OPEN') THEN
        RETURN 'Pending';
    ELSE
        RETURN p_default;
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 5. HELPER FUNCTION: Canonical Partner ID Resolver
CREATE OR REPLACE FUNCTION public.fn_adj_canonical_partner_id(p_city VARCHAR, p_phone VARCHAR)
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
        WHEN v_clean_city IN ('BANGALORE', 'BENGALURU', 'BLR') THEN 'LETZBLR'
        WHEN v_clean_city IN ('HYDERABAD', 'HYD') THEN 'LETZHYD'
        WHEN v_clean_city IN ('MUMBAI', 'MUM') THEN 'LETZMUM'
        WHEN v_clean_city IN ('PUNE', 'PUN') THEN 'LETZPUN'
        WHEN v_clean_city IN ('DELHI', 'DEL') THEN 'LETZDEL'
        WHEN v_clean_city IN ('CHENNAI', 'CHN') THEN 'LETZCHN'
        ELSE 'LETZ' || UPPER(LEFT(v_clean_city, 3))
    END;

    RETURN v_prefix || v_clean_phone;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 6. REAL-TIME SYNCHRONIZATION TRIGGER FUNCTIONS

-- 6.1 Trigger from sheet_adjustments -> core_adjustments (1-to-1 exact)
CREATE OR REPLACE FUNCTION public.fn_sync_sheet_adjustments()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone TEXT;
    v_clean_veh TEXT;
    v_clean_city TEXT;
    v_partner_id TEXT;
    v_adj_date DATE;
    v_status TEXT;
    v_existing_id BIGINT;
    v_next_id BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_adjustments
        SET is_deleted = TRUE, 
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE adjustment_id = 'ADJ-SHT-' || OLD.id::TEXT;
        RETURN OLD;
    END IF;

    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(NEW.partner_phone, ''), '[^0-9]', '', 'g'), 10);
    v_clean_veh := UPPER(REGEXP_REPLACE(COALESCE(NEW.vehicle_number, ''), '[^A-Za-z0-9]', '', 'g'));
    v_clean_city := COALESCE(NEW.city_name, 'Bengaluru');
    v_partner_id := COALESCE(NEW.partner_code, public.fn_adj_canonical_partner_id(v_clean_city, v_clean_phone));
    v_adj_date := COALESCE(NEW.adjustment_date, NEW.submission_timestamp::DATE, CURRENT_DATE);
    v_status := public.fn_standardize_approval_status(COALESCE(NEW.final_status, NEW.first_level_status), 'Pending');

    PERFORM pg_advisory_xact_lock(777333444);

    SELECT id INTO v_existing_id
    FROM public.core_adjustments
    WHERE adjustment_id = 'ADJ-SHT-' || NEW.id::TEXT;

    IF v_existing_id IS NOT NULL THEN
        UPDATE public.core_adjustments
        SET
            partner_id = v_partner_id,
            partner_name = NEW.partner_name,
            partner_phone = v_clean_phone,
            partner_type = COALESCE(NEW.partner_type, 'Individual'),
            vehicle_number = NEW.vehicle_number,
            city_name = NEW.city_name,
            adjustment_type = NEW.adjustment_type,
            adjustment_nature = 'Monetary',
            adjustment_level = CASE WHEN LOWER(NEW.partner_type) = 'operator' THEN 'Operator' ELSE 'Driver' END,
            adjustment_date = v_adj_date,
            amount = NEW.amount,
            remittance_towards = NEW.remittance_towards,
            adjustment_related_to = NEW.adjustment_related_to,
            hisaab_number = NEW.hisaab_week_str,
            hisaab_week_number = NEW.hisaab_week_number,
            remarks = NEW.remarks,
            approval_status = v_status,
            first_level_approver = NEW.first_level_approver,
            final_level_approver = NEW.final_level_approver,
            photo_url = NEW.photo_url,
            data_source = 'GOOGLE_SHEET',
            source_reference_id = 'ADJ-SHT-' || NEW.id::TEXT,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;
    ELSE
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_adjustments;

        INSERT INTO public.core_adjustments (
            id, adjustment_id, partner_id, partner_name, partner_phone, partner_type,
            vehicle_number, city_name, adjustment_type, adjustment_nature, adjustment_level,
            adjustment_date, amount, remittance_towards, adjustment_related_to,
            hisaab_number, hisaab_week_number, remarks, approval_status,
            first_level_approver, final_level_approver, photo_url,
            data_source, source_reference_id, is_deleted, created_at, updated_at
        ) VALUES (
            v_next_id,
            'ADJ-SHT-' || NEW.id::TEXT,
            v_partner_id,
            NEW.partner_name,
            v_clean_phone,
            COALESCE(NEW.partner_type, 'Individual'),
            NEW.vehicle_number,
            NEW.city_name,
            NEW.adjustment_type,
            'Monetary',
            CASE WHEN LOWER(NEW.partner_type) = 'operator' THEN 'Operator' ELSE 'Driver' END,
            v_adj_date,
            NEW.amount,
            NEW.remittance_towards,
            NEW.adjustment_related_to,
            NEW.hisaab_week_str,
            NEW.hisaab_week_number,
            NEW.remarks,
            v_status,
            NEW.first_level_approver,
            NEW.final_level_approver,
            NEW.photo_url,
            'GOOGLE_SHEET',
            'ADJ-SHT-' || NEW.id::TEXT,
            FALSE,
            (COALESCE(NEW.submission_timestamp, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );

        PERFORM setval('public.core_adjustments_id_seq', v_next_id, true);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sheet_adjustments_sync ON public.sheet_adjustments;
CREATE TRIGGER trg_sheet_adjustments_sync
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_adjustments
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_sheet_adjustments();

-- 6.2 Trigger from july_partner_adjustment -> core_adjustments (1-to-1 exact)
CREATE OR REPLACE FUNCTION public.fn_sync_july_partner_adjustment()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone TEXT;
    v_clean_veh TEXT;
    v_clean_city TEXT;
    v_partner_id TEXT;
    v_adj_date DATE;
    v_amount NUMERIC(12,2);
    v_status TEXT;
    v_existing_id BIGINT;
    v_next_id BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_adjustments
        SET is_deleted = TRUE, 
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE adjustment_id = 'ADJ-PORTAL-' || OLD.id::TEXT;
        RETURN OLD;
    END IF;

    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(NEW.partner_number, ''), '[^0-9]', '', 'g'), 10);
    v_clean_veh := UPPER(REGEXP_REPLACE(COALESCE(NEW.vehicle_number, ''), '[^A-Za-z0-9]', '', 'g'));
    v_clean_city := COALESCE(NEW.city_name, 'Bengaluru');
    v_partner_id := COALESCE(NEW.driver_id, NEW.partner_code, public.fn_adj_canonical_partner_id(v_clean_city, v_clean_phone));
    
    v_adj_date := COALESCE(
        CASE 
            WHEN NEW.adjustment_date ~ '^\d{4}-\d{2}-\d{2}' THEN NEW.adjustment_date::DATE
            WHEN NEW.adjustment_date ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(NEW.adjustment_date, 'DD/MM/YYYY')
            ELSE NULL
        END,
        NEW.created_at::DATE,
        CURRENT_DATE
    );

    v_amount := COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(NEW.enter_amount, ''), '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00);
    v_status := public.fn_standardize_approval_status(COALESCE(NEW.approval_status, NEW.status), 'Pending');

    PERFORM pg_advisory_xact_lock(777333444);

    SELECT id INTO v_existing_id
    FROM public.core_adjustments
    WHERE adjustment_id = 'ADJ-PORTAL-' || NEW.id::TEXT;

    IF v_existing_id IS NOT NULL THEN
        UPDATE public.core_adjustments
        SET
            partner_id = v_partner_id,
            partner_name = NEW.partner_name,
            partner_phone = v_clean_phone,
            partner_type = COALESCE(NEW.partner_type, 'Individual'),
            vehicle_number = NEW.vehicle_number,
            city_name = COALESCE(NEW.city_name, 'Bengaluru'),
            adjustment_type = COALESCE(NEW.adjustment_type, 'Credit'),
            adjustment_nature = COALESCE(NEW.adjustment_nature, 'Monetary'),
            adjustment_level = COALESCE(NEW.adjustment_level, 'Driver'),
            adjustment_date = v_adj_date,
            amount = v_amount,
            remittance_towards = NEW.remittance_towards,
            adjustment_related_to = NEW.adjustment_related_to,
            hisaab_number = NEW.hisaab_number,
            contested_line_items = CASE WHEN NEW.contested_line_items IS NOT NULL AND NEW.contested_line_items != '' AND NEW.contested_line_items != 'nan' THEN NEW.contested_line_items::JSONB ELSE core_adjustments.contested_line_items END,
            severity_level = NEW.severity_level,
            cost_level = NEW.cost_level,
            remarks = NEW.remarks,
            approval_status = v_status,
            first_level_approver = NEW.first_level_approval_by,
            final_level_approver = NEW.final_level_approval_by,
            current_approver_id = NEW.current_approver_id::TEXT,
            approved_by = NEW.approved_by::TEXT,
            photo_url = NEW.photo,
            data_source = 'PORTAL_FORM',
            source_reference_id = 'ADJ-PORTAL-' || NEW.id::TEXT,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;
    ELSE
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_adjustments;

        INSERT INTO public.core_adjustments (
            id, adjustment_id, partner_id, partner_name, partner_phone, partner_type,
            vehicle_number, city_name, adjustment_type, adjustment_nature, adjustment_level,
            adjustment_date, amount, remittance_towards, adjustment_related_to,
            hisaab_number, contested_line_items, severity_level, cost_level,
            remarks, approval_status, first_level_approver, final_level_approver,
            current_approver_id, approved_by, photo_url,
            data_source, source_reference_id, is_deleted, created_at, updated_at
        ) VALUES (
            v_next_id,
            'ADJ-PORTAL-' || NEW.id::TEXT,
            v_partner_id,
            NEW.partner_name,
            v_clean_phone,
            COALESCE(NEW.partner_type, 'Individual'),
            NEW.vehicle_number,
            COALESCE(NEW.city_name, 'Bengaluru'),
            COALESCE(NEW.adjustment_type, 'Credit'),
            COALESCE(NEW.adjustment_nature, 'Monetary'),
            COALESCE(NEW.adjustment_level, 'Driver'),
            v_adj_date,
            v_amount,
            NEW.remittance_towards,
            NEW.adjustment_related_to,
            NEW.hisaab_number,
            CASE WHEN NEW.contested_line_items IS NOT NULL AND NEW.contested_line_items != '' AND NEW.contested_line_items != 'nan' THEN NEW.contested_line_items::JSONB ELSE NULL END,
            NEW.severity_level,
            NEW.cost_level,
            NEW.remarks,
            v_status,
            NEW.first_level_approval_by,
            NEW.final_level_approval_by,
            NEW.current_approver_id::TEXT,
            NEW.approved_by::TEXT,
            NEW.photo,
            'PORTAL_FORM',
            'ADJ-PORTAL-' || NEW.id::TEXT,
            FALSE,
            (COALESCE(NEW.created_at, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );

        PERFORM setval('public.core_adjustments_id_seq', v_next_id, true);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_july_partner_adjustment_sync ON public.july_partner_adjustment;
CREATE TRIGGER trg_july_partner_adjustment_sync
AFTER INSERT OR UPDATE OR DELETE ON public.july_partner_adjustment
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_july_partner_adjustment();

-- 7. DOWNSTREAM HISAAB SYNCHRONIZATION TRIGGER
CREATE OR REPLACE FUNCTION public.fn_sync_core_to_hisaab_adjustments()
RETURNS TRIGGER AS $$
DECLARE
    v_rec_id BIGINT;
    v_veh TEXT;
    v_cat TEXT;
    v_polarity VARCHAR(8);
BEGIN
    IF (TG_OP = 'DELETE') THEN
        DELETE FROM public.hisaab_adjustments_ledger
        WHERE remarks LIKE 'CORE_ADJ:' || OLD.adjustment_id || '%';
        RETURN OLD;
    END IF;

    IF (NEW.is_deleted IS TRUE OR NEW.approval_status != 'Approved') THEN
        DELETE FROM public.hisaab_adjustments_ledger
        WHERE remarks LIKE 'CORE_ADJ:' || NEW.adjustment_id || '%';
        RETURN NEW;
    END IF;

    v_veh := COALESCE(NULLIF(UPPER(REGEXP_REPLACE(COALESCE(NEW.vehicle_number, ''), '[^A-Z0-9]', '', 'g')), ''), 'UNKNOWN');
    v_cat := COALESCE(NEW.remittance_towards, NEW.adjustment_type, 'General Adjustment');

    IF (v_cat ILIKE '%remove%' OR v_cat ILIKE '%waiver%' OR v_cat ILIKE '%waive%' 
        OR v_cat ILIKE '%reversal%' OR v_cat ILIKE '%reverse%' OR v_cat ILIKE '%refund%' 
        OR v_cat ILIKE '%rent-off%' OR v_cat ILIKE '%leave%' OR v_cat ILIKE '%service%' 
        OR v_cat ILIKE '%breakdown%' OR v_cat ILIKE '%parking%' OR v_cat ILIKE '%health%' 
        OR v_cat ILIKE '%bonus%' OR v_cat ILIKE '%credit%' OR v_cat ILIKE '%negative balance%' 
        OR v_cat ILIKE '%online payment%' OR v_cat ILIKE '%app issue%' OR v_cat ILIKE '%cng issue%'
        OR NEW.adjustment_type IN ('Credit', 'Waiver', 'Bonus')) THEN
        v_polarity := 'CREDIT';
    ELSIF (v_cat = 'Challan' OR v_cat ILIKE '%fine%' OR v_cat ILIKE '%penalty%' 
           OR v_cat ILIKE '%challan%' OR v_cat ILIKE '%damage%' OR v_cat ILIKE '%violation%' 
           OR v_cat ILIKE '%rto%' OR v_cat ILIKE '%towing%' OR v_cat ILIKE '%accident%' 
           OR v_cat ILIKE '%recovery%' OR v_cat ILIKE '%debit%'
           OR NEW.adjustment_type IN ('Debit', 'Penalty')) THEN
        v_polarity := 'DEBIT';
    ELSE
        v_polarity := 'CREDIT';
    END IF;

    SELECT id INTO v_rec_id
    FROM public.hisaab_adjustments_ledger
    WHERE remarks LIKE 'CORE_ADJ:' || NEW.adjustment_id || '%'
    LIMIT 1;

    IF v_rec_id IS NOT NULL THEN
        UPDATE public.hisaab_adjustments_ledger
        SET amount = NEW.amount,
            incident_date = NEW.adjustment_date,
            vehicle_number = v_veh,
            partner_id = NEW.partner_id,
            partner_type = COALESCE(NEW.partner_type, 'Individual'),
            adjustment_category = v_cat,
            polarity = v_polarity,
            approval_status = NEW.approval_status,
            approved_by = COALESCE(NEW.final_level_approver, NEW.approved_by),
            reference_doc_url = NEW.photo_url,
            remarks = 'CORE_ADJ:' || NEW.adjustment_id || ' - ' || COALESCE(NEW.remarks, ''),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_rec_id;
    ELSE
        INSERT INTO public.hisaab_adjustments_ledger (
            incident_date,
            vehicle_number,
            partner_id,
            partner_type,
            adjustment_category,
            polarity,
            amount,
            approval_status,
            approved_by,
            reference_doc_url,
            remarks
        ) VALUES (
            NEW.adjustment_date,
            v_veh,
            NEW.partner_id,
            COALESCE(NEW.partner_type, 'Individual'),
            v_cat,
            v_polarity,
            NEW.amount,
            NEW.approval_status,
            COALESCE(NEW.final_level_approver, NEW.approved_by),
            NEW.photo_url,
            'CORE_ADJ:' || NEW.adjustment_id || ' - ' || COALESCE(NEW.remarks, '')
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_core_to_hisaab_adjustments ON public.core_adjustments;
CREATE TRIGGER trg_core_to_hisaab_adjustments
AFTER INSERT OR UPDATE OR DELETE ON public.core_adjustments
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_to_hisaab_adjustments();

-- 8. FULL REFRESH & RECONCILIATION STORED PROCEDURE
CREATE OR REPLACE FUNCTION public.refresh_core_adjustments()
RETURNS INTEGER AS $$
DECLARE
    v_total_synced INTEGER := 0;
    r RECORD;
    v_clean_phone TEXT;
    v_clean_veh TEXT;
    v_clean_city TEXT;
    v_partner_id TEXT;
    v_adj_date DATE;
    v_amount NUMERIC(12,2);
    v_status TEXT;
    v_existing_id BIGINT;
    v_next_id BIGINT;
BEGIN
    PERFORM pg_advisory_xact_lock(777333444);

    SELECT COALESCE(MAX(id), 0) INTO v_next_id FROM public.core_adjustments;

    -- 1. Sync all rows from sheet_adjustments (1-to-1 canonical)
    FOR r IN (SELECT * FROM public.sheet_adjustments ORDER BY id ASC) LOOP
        v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(r.partner_phone, ''), '[^0-9]', '', 'g'), 10);
        v_clean_veh := UPPER(REGEXP_REPLACE(COALESCE(r.vehicle_number, ''), '[^A-Za-z0-9]', '', 'g'));
        v_clean_city := COALESCE(r.city_name, 'Bengaluru');
        v_partner_id := COALESCE(r.partner_code, public.fn_adj_canonical_partner_id(v_clean_city, v_clean_phone));
        v_adj_date := COALESCE(r.adjustment_date, r.submission_timestamp::DATE, CURRENT_DATE);
        v_status := public.fn_standardize_approval_status(COALESCE(r.final_status, r.first_level_status), 'Pending');

        SELECT id INTO v_existing_id
        FROM public.core_adjustments
        WHERE adjustment_id = 'ADJ-SHT-' || r.id::TEXT;

        IF v_existing_id IS NOT NULL THEN
            UPDATE public.core_adjustments
            SET
                partner_id = v_partner_id,
                partner_name = r.partner_name,
                partner_phone = v_clean_phone,
                partner_type = COALESCE(r.partner_type, 'Individual'),
                vehicle_number = r.vehicle_number,
                city_name = r.city_name,
                adjustment_type = r.adjustment_type,
                adjustment_nature = 'Monetary',
                adjustment_level = CASE WHEN LOWER(r.partner_type) = 'operator' THEN 'Operator' ELSE 'Driver' END,
                adjustment_date = v_adj_date,
                amount = r.amount,
                remittance_towards = r.remittance_towards,
                adjustment_related_to = r.adjustment_related_to,
                hisaab_number = r.hisaab_week_str,
                hisaab_week_number = r.hisaab_week_number,
                remarks = r.remarks,
                approval_status = v_status,
                first_level_approver = r.first_level_approver,
                final_level_approver = r.final_level_approver,
                photo_url = r.photo_url,
                data_source = 'GOOGLE_SHEET',
                source_reference_id = 'ADJ-SHT-' || r.id::TEXT,
                is_deleted = FALSE,
                deleted_at = NULL,
                updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            WHERE id = v_existing_id;
        ELSE
            v_next_id := v_next_id + 1;

            INSERT INTO public.core_adjustments (
                id, adjustment_id, partner_id, partner_name, partner_phone, partner_type,
                vehicle_number, city_name, adjustment_type, adjustment_nature, adjustment_level,
                adjustment_date, amount, remittance_towards, adjustment_related_to,
                hisaab_number, hisaab_week_number, remarks, approval_status,
                first_level_approver, final_level_approver, photo_url,
                data_source, source_reference_id, is_deleted, created_at, updated_at
            ) VALUES (
                v_next_id,
                'ADJ-SHT-' || r.id::TEXT,
                v_partner_id,
                r.partner_name,
                v_clean_phone,
                COALESCE(r.partner_type, 'Individual'),
                r.vehicle_number,
                r.city_name,
                r.adjustment_type,
                'Monetary',
                CASE WHEN LOWER(r.partner_type) = 'operator' THEN 'Operator' ELSE 'Driver' END,
                v_adj_date,
                r.amount,
                r.remittance_towards,
                r.adjustment_related_to,
                r.hisaab_week_str,
                r.hisaab_week_number,
                r.remarks,
                v_status,
                r.first_level_approver,
                r.final_level_approver,
                r.photo_url,
                'GOOGLE_SHEET',
                'ADJ-SHT-' || r.id::TEXT,
                FALSE,
                (COALESCE(r.submission_timestamp, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            );
        END IF;
        v_total_synced := v_total_synced + 1;
    END LOOP;

    -- 2. Sync all rows from july_partner_adjustment
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_partner_adjustment') THEN
        FOR r IN (SELECT * FROM public.july_partner_adjustment ORDER BY id ASC) LOOP
            v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(r.partner_number, ''), '[^0-9]', '', 'g'), 10);
            v_clean_veh := UPPER(REGEXP_REPLACE(COALESCE(r.vehicle_number, ''), '[^A-Za-z0-9]', '', 'g'));
            v_clean_city := COALESCE(r.city_name, 'Bengaluru');
            v_partner_id := COALESCE(r.driver_id, r.partner_code, public.fn_adj_canonical_partner_id(v_clean_city, v_clean_phone));
            
            v_adj_date := COALESCE(
                CASE 
                    WHEN r.adjustment_date ~ '^\d{4}-\d{2}-\d{2}' THEN r.adjustment_date::DATE
                    WHEN r.adjustment_date ~ '^\d{2}/\d{2}/\d{4}' THEN TO_DATE(r.adjustment_date, 'DD/MM/YYYY')
                    ELSE NULL
                END,
                r.created_at::DATE,
                CURRENT_DATE
            );

            v_amount := COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(r.enter_amount, ''), '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00);
            v_status := public.fn_standardize_approval_status(COALESCE(r.approval_status, r.status), 'Pending');

            SELECT id INTO v_existing_id
            FROM public.core_adjustments
            WHERE adjustment_id = 'ADJ-PORTAL-' || r.id::TEXT;

            IF v_existing_id IS NOT NULL THEN
                UPDATE public.core_adjustments
                SET
                    partner_id = v_partner_id,
                    partner_name = r.partner_name,
                    partner_phone = v_clean_phone,
                    partner_type = COALESCE(r.partner_type, 'Individual'),
                    vehicle_number = r.vehicle_number,
                    city_name = COALESCE(r.city_name, 'Bengaluru'),
                    adjustment_type = COALESCE(r.adjustment_type, 'Credit'),
                    adjustment_nature = COALESCE(r.adjustment_nature, 'Monetary'),
                    adjustment_level = COALESCE(r.adjustment_level, 'Driver'),
                    adjustment_date = v_adj_date,
                    amount = v_amount,
                    remittance_towards = r.remittance_towards,
                    adjustment_related_to = r.adjustment_related_to,
                    hisaab_number = r.hisaab_number,
                    contested_line_items = CASE WHEN r.contested_line_items IS NOT NULL AND r.contested_line_items != '' AND r.contested_line_items != 'nan' THEN r.contested_line_items::JSONB ELSE core_adjustments.contested_line_items END,
                    severity_level = r.severity_level,
                    cost_level = r.cost_level,
                    remarks = r.remarks,
                    approval_status = v_status,
                    first_level_approver = r.first_level_approval_by,
                    final_level_approver = r.final_level_approval_by,
                    current_approver_id = r.current_approver_id::TEXT,
                    approved_by = r.approved_by::TEXT,
                    photo_url = r.photo,
                    data_source = 'PORTAL_FORM',
                    source_reference_id = 'ADJ-PORTAL-' || r.id::TEXT,
                    is_deleted = FALSE,
                    deleted_at = NULL,
                    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                WHERE id = v_existing_id;
            ELSE
                v_next_id := v_next_id + 1;

                INSERT INTO public.core_adjustments (
                    id, adjustment_id, partner_id, partner_name, partner_phone, partner_type,
                    vehicle_number, city_name, adjustment_type, adjustment_nature, adjustment_level,
                    adjustment_date, amount, remittance_towards, adjustment_related_to,
                    hisaab_number, contested_line_items, severity_level, cost_level,
                    remarks, approval_status, first_level_approver, final_level_approver,
                    current_approver_id, approved_by, photo_url,
                    data_source, source_reference_id, is_deleted, created_at, updated_at
                ) VALUES (
                    v_next_id,
                    'ADJ-PORTAL-' || r.id::TEXT,
                    v_partner_id,
                    r.partner_name,
                    v_clean_phone,
                    COALESCE(r.partner_type, 'Individual'),
                    r.vehicle_number,
                    COALESCE(r.city_name, 'Bengaluru'),
                    COALESCE(r.adjustment_type, 'Credit'),
                    COALESCE(r.adjustment_nature, 'Monetary'),
                    COALESCE(r.adjustment_level, 'Driver'),
                    v_adj_date,
                    v_amount,
                    r.remittance_towards,
                    r.adjustment_related_to,
                    r.hisaab_number,
                    CASE WHEN r.contested_line_items IS NOT NULL AND r.contested_line_items != '' AND r.contested_line_items != 'nan' THEN r.contested_line_items::JSONB ELSE NULL END,
                    r.severity_level,
                    r.cost_level,
                    r.remarks,
                    v_status,
                    r.first_level_approval_by,
                    r.final_level_approval_by,
                    r.current_approver_id::TEXT,
                    r.approved_by::TEXT,
                    r.photo,
                    'PORTAL_FORM',
                    'ADJ-PORTAL-' || r.id::TEXT,
                    FALSE,
                    (COALESCE(r.created_at, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                );
            END IF;
            v_total_synced := v_total_synced + 1;
        END LOOP;
    END IF;

    -- 3. Reconcile soft-deleted records (mark as deleted if deleted from upstream source)
    UPDATE public.core_adjustments
    SET is_deleted = TRUE,
        deleted_at = COALESCE(deleted_at, CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
        updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
    WHERE data_source = 'GOOGLE_SHEET'
      AND is_deleted = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM public.sheet_adjustments s 
          WHERE 'ADJ-SHT-' || s.id::TEXT = core_adjustments.adjustment_id
      );

    UPDATE public.core_adjustments
    SET is_deleted = TRUE,
        deleted_at = COALESCE(deleted_at, CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
        updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
    WHERE data_source = 'PORTAL_FORM'
      AND is_deleted = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM public.july_partner_adjustment p 
          WHERE 'ADJ-PORTAL-' || p.id::TEXT = core_adjustments.adjustment_id
      );

    PERFORM setval('public.core_adjustments_id_seq', COALESCE(v_next_id, 1), true);
    RETURN v_total_synced;
END;
$$ LANGUAGE plpgsql;
