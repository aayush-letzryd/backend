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
--   - Gapless 1..N ID sequence integrity (Zero Sequence Burning)
--   - Advisory Locks (pg_advisory_xact_lock(777333444)) for strict concurrency protection
--   - Cross-system automatic deduplication between Google Sheets and Portal
--   - Pure IST timestamps (TIMESTAMP WITHOUT TIME ZONE, 0 timezone offset drift)
--   - Soft-delete support (is_deleted = TRUE, deleted_at timestamp)
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
    adjustment_nature VARCHAR(100),
    adjustment_level VARCHAR(100),
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
    data_source VARCHAR(100) NOT NULL DEFAULT 'GOOGLE_SHEET', -- 'GOOGLE_SHEET', 'PORTAL_FORM', or 'MERGED'
    source_reference_id TEXT,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    CONSTRAINT chk_core_adjustments_amount CHECK (amount >= 0.00)
);

-- Underlying Sequence for fallback tracking
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

-- 4. HELPER FUNCTION: Canonical Partner ID Resolver
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
        ELSE 'LETZ' || UPPER(LEFT(v_clean_city, 3))
    END;

    RETURN v_prefix || v_clean_phone;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 5. REAL-TIME SYNCHRONIZATION TRIGGER FUNCTIONS

-- 5.1 Trigger from sheet_adjustments -> core_adjustments
CREATE OR REPLACE FUNCTION public.fn_sync_sheet_adjustments()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone TEXT;
    v_clean_veh TEXT;
    v_clean_city TEXT;
    v_partner_id TEXT;
    v_existing_id BIGINT;
    v_existing_source TEXT;
    v_existing_ref TEXT;
    v_next_id BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_adjustments
        SET is_deleted = TRUE, 
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE source_reference_id = 'ADJ-SHT-' || OLD.id::TEXT AND data_source = 'GOOGLE_SHEET';
        RETURN OLD;
    END IF;

    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(NEW.partner_phone, ''), '[^0-9]', '', 'g'), 10);
    v_clean_veh := UPPER(REGEXP_REPLACE(COALESCE(NEW.vehicle_number, ''), '[^A-Za-z0-9]', '', 'g'));
    v_clean_city := COALESCE(NEW.city_name, 'Bengaluru');
    v_partner_id := COALESCE(NEW.partner_code, public.fn_adj_canonical_partner_id(v_clean_city, v_clean_phone));

    -- Acquire transactional advisory lock
    PERFORM pg_advisory_xact_lock(777333444);

    -- Cross-source deduplication: check matching business key or source reference ID or adjustment_id
    SELECT id, data_source, source_reference_id
    INTO v_existing_id, v_existing_source, v_existing_ref
    FROM public.core_adjustments
    WHERE adjustment_id = 'ADJ-SHT-' || NEW.id::TEXT
       OR source_reference_id = 'ADJ-SHT-' || NEW.id::TEXT
       OR source_reference_id = NEW.id::TEXT
       OR NEW.id::TEXT = ANY(string_to_array(source_reference_id, ','))
       OR ('ADJ-SHT-' || NEW.id::TEXT) = ANY(string_to_array(source_reference_id, ','))
       OR (
           ((v_clean_phone != '' AND partner_phone = v_clean_phone) OR (v_clean_phone = '' AND (partner_phone IS NULL OR partner_phone = '') AND v_clean_veh != '' AND vehicle_number = v_clean_veh))
           AND (v_clean_veh != '' AND vehicle_number = v_clean_veh)
           AND adjustment_date = NEW.adjustment_date
           AND amount = NEW.amount
           AND adjustment_type = NEW.adjustment_type
       )
    ORDER BY CASE 
        WHEN adjustment_id = 'ADJ-SHT-' || NEW.id::TEXT THEN 1
        WHEN source_reference_id = 'ADJ-SHT-' || NEW.id::TEXT THEN 2
        WHEN source_reference_id = NEW.id::TEXT THEN 3
        ELSE 4
    END
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        -- UPDATE existing row
        UPDATE public.core_adjustments
        SET
            partner_id = COALESCE(core_adjustments.partner_id, v_partner_id),
            partner_name = COALESCE(NEW.partner_name, core_adjustments.partner_name),
            partner_phone = COALESCE(v_clean_phone, core_adjustments.partner_phone),
            vehicle_number = COALESCE(v_clean_veh, core_adjustments.vehicle_number),
            city_name = COALESCE(NEW.city_name, core_adjustments.city_name),
            remittance_towards = COALESCE(NEW.remittance_towards, core_adjustments.remittance_towards),
            adjustment_related_to = COALESCE(NEW.adjustment_related_to, core_adjustments.adjustment_related_to),
            hisaab_number = COALESCE(NEW.hisaab_week_str, core_adjustments.hisaab_number),
            hisaab_week_number = COALESCE(NEW.hisaab_week_number, core_adjustments.hisaab_week_number),
            amount = NEW.amount,
            approval_status = COALESCE(NEW.final_status, NEW.first_level_status, core_adjustments.approval_status),
            first_level_approver = COALESCE(NEW.first_level_approver, core_adjustments.first_level_approver),
            final_level_approver = COALESCE(NEW.final_level_approver, core_adjustments.final_level_approver),
            remarks = COALESCE(NEW.remarks, core_adjustments.remarks),
            photo_url = COALESCE(NEW.photo_url, core_adjustments.photo_url),
            data_source = CASE WHEN v_existing_source = 'PORTAL_FORM' THEN 'MERGED' ELSE 'GOOGLE_SHEET' END,
            source_reference_id = CASE 
                WHEN v_existing_ref IS NOT NULL AND NOT (NEW.id::TEXT = ANY(string_to_array(v_existing_ref, ',')))
                THEN v_existing_ref || ',ADJ-SHT-' || NEW.id::TEXT 
                ELSE COALESCE(v_existing_ref, 'ADJ-SHT-' || NEW.id::TEXT) 
            END,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;
    ELSE
        -- INSERT new row with gapless sequence ID
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_adjustments;

        INSERT INTO public.core_adjustments (
            id,
            adjustment_id,
            partner_id,
            partner_name,
            partner_phone,
            partner_type,
            vehicle_number,
            city_name,
            adjustment_type,
            adjustment_nature,
            adjustment_level,
            adjustment_date,
            amount,
            remittance_towards,
            adjustment_related_to,
            hisaab_number,
            hisaab_week_number,
            remarks,
            approval_status,
            first_level_approver,
            final_level_approver,
            photo_url,
            data_source,
            source_reference_id,
            is_deleted,
            created_at,
            updated_at
        ) VALUES (
            v_next_id,
            'ADJ-SHT-' || NEW.id::TEXT,
            v_partner_id,
            NEW.partner_name,
            v_clean_phone,
            COALESCE(NEW.partner_type, 'Individual'),
            v_clean_veh,
            NEW.city_name,
            COALESCE(NEW.adjustment_type, 'Credit'),
            'Monetary',
            CASE WHEN LOWER(NEW.partner_type) = 'operator' THEN 'Operator' ELSE 'Driver' END,
            NEW.adjustment_date,
            NEW.amount,
            NEW.remittance_towards,
            NEW.adjustment_related_to,
            NEW.hisaab_week_str,
            NEW.hisaab_week_number,
            NEW.remarks,
            COALESCE(NEW.final_status, NEW.first_level_status, 'Pending'),
            NEW.first_level_approver,
            NEW.final_level_approver,
            NEW.photo_url,
            'GOOGLE_SHEET',
            'ADJ-SHT-' || NEW.id::TEXT,
            FALSE,
            (COALESCE(NEW.submission_timestamp, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );

        -- Keep sequence in sync with max id
        PERFORM setval('public.core_adjustments_id_seq', v_next_id, true);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sheet_adjustments_sync ON public.sheet_adjustments;
CREATE TRIGGER trg_sheet_adjustments_sync
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_adjustments
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_sheet_adjustments();

-- 5.2 Trigger from july_partner_adjustment -> core_adjustments
CREATE OR REPLACE FUNCTION public.fn_sync_july_partner_adjustment()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone TEXT;
    v_clean_veh TEXT;
    v_clean_city TEXT;
    v_partner_id TEXT;
    v_adj_date DATE;
    v_amount NUMERIC(12,2);
    v_adj_type TEXT;
    v_existing_id BIGINT;
    v_existing_source TEXT;
    v_existing_ref TEXT;
    v_next_id BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_adjustments
        SET is_deleted = TRUE, 
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE source_reference_id = 'ADJ-PORTAL-' || OLD.id::TEXT AND data_source = 'PORTAL_FORM';
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
        CURRENT_DATE
    );

    v_amount := COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(NEW.enter_amount, ''), '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00);
    v_adj_type := COALESCE(NEW.adjustment_type, 'Credit');

    -- Acquire transactional advisory lock
    PERFORM pg_advisory_xact_lock(777333444);

    SELECT id, data_source, source_reference_id
    INTO v_existing_id, v_existing_source, v_existing_ref
    FROM public.core_adjustments
    WHERE (
        ((v_clean_phone != '' AND partner_phone = v_clean_phone) OR (v_clean_phone = '' AND (partner_phone IS NULL OR partner_phone = '') AND v_clean_veh != '' AND vehicle_number = v_clean_veh))
        AND (v_clean_veh != '' AND vehicle_number = v_clean_veh)
        AND adjustment_date = v_adj_date
        AND amount = v_amount
        AND adjustment_type = v_adj_type
    ) OR source_reference_id = 'ADJ-PORTAL-' || NEW.id::TEXT
      OR NEW.id::TEXT = ANY(string_to_array(source_reference_id, ','))
      OR ('ADJ-PORTAL-' || NEW.id::TEXT) = ANY(string_to_array(source_reference_id, ','))
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        UPDATE public.core_adjustments
        SET
            partner_name = COALESCE(NEW.partner_name, core_adjustments.partner_name),
            partner_phone = COALESCE(v_clean_phone, core_adjustments.partner_phone),
            vehicle_number = COALESCE(v_clean_veh, core_adjustments.vehicle_number),
            remittance_towards = COALESCE(NEW.remittance_towards, core_adjustments.remittance_towards),
            adjustment_related_to = COALESCE(NEW.adjustment_related_to, core_adjustments.adjustment_related_to),
            hisaab_number = COALESCE(NEW.hisaab_number, core_adjustments.hisaab_number),
            contested_line_items = CASE WHEN NEW.contested_line_items IS NOT NULL AND NEW.contested_line_items != '' AND NEW.contested_line_items != 'nan' THEN NEW.contested_line_items::JSONB ELSE core_adjustments.contested_line_items END,
            severity_level = COALESCE(NEW.severity_level, core_adjustments.severity_level),
            cost_level = COALESCE(NEW.cost_level, core_adjustments.cost_level),
            remarks = COALESCE(NEW.remarks, core_adjustments.remarks),
            approval_status = COALESCE(NEW.approval_status, NEW.status, core_adjustments.approval_status),
            first_level_approver = COALESCE(NEW.first_level_approval_by, core_adjustments.first_level_approver),
            final_level_approver = COALESCE(NEW.final_level_approval_by, core_adjustments.final_level_approver),
            current_approver_id = COALESCE(NEW.current_approver_id::TEXT, core_adjustments.current_approver_id),
            approved_by = COALESCE(NEW.approved_by::TEXT, core_adjustments.approved_by),
            photo_url = COALESCE(NEW.photo, core_adjustments.photo_url),
            data_source = 'MERGED',
            source_reference_id = CASE 
                WHEN v_existing_ref IS NOT NULL AND NOT (NEW.id::TEXT = ANY(string_to_array(v_existing_ref, ',')))
                THEN v_existing_ref || ',ADJ-PORTAL-' || NEW.id::TEXT 
                ELSE COALESCE(v_existing_ref, 'ADJ-PORTAL-' || NEW.id::TEXT) 
            END,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;
    ELSE
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_adjustments;

        INSERT INTO public.core_adjustments (
            id,
            adjustment_id,
            partner_id,
            partner_name,
            partner_phone,
            partner_type,
            vehicle_number,
            city_name,
            adjustment_type,
            adjustment_nature,
            adjustment_level,
            adjustment_date,
            amount,
            remittance_towards,
            adjustment_related_to,
            hisaab_number,
            contested_line_items,
            severity_level,
            cost_level,
            remarks,
            approval_status,
            first_level_approver,
            final_level_approver,
            current_approver_id,
            approved_by,
            photo_url,
            data_source,
            source_reference_id,
            is_deleted,
            created_at,
            updated_at
        ) VALUES (
            v_next_id,
            'ADJ-PORTAL-' || NEW.id::TEXT,
            v_partner_id,
            NEW.partner_name,
            v_clean_phone,
            COALESCE(NEW.partner_type, 'Individual'),
            v_clean_veh,
            COALESCE(NEW.city_name, 'Bengaluru'),
            v_adj_type,
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
            COALESCE(NEW.approval_status, NEW.status, 'Pending'),
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

        -- Keep sequence in sync with max id
        PERFORM setval('public.core_adjustments_id_seq', v_next_id, true);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_july_partner_adjustment_sync ON public.july_partner_adjustment;
CREATE TRIGGER trg_july_partner_adjustment_sync
AFTER INSERT OR UPDATE OR DELETE ON public.july_partner_adjustment
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_july_partner_adjustment();

-- 6. FULL BACKFILL & RECONCILIATION PROCEDURE
CREATE OR REPLACE FUNCTION public.refresh_core_adjustments()
RETURNS INTEGER AS $$
DECLARE
    v_inserted_count INTEGER := 0;
    r RECORD;
    v_clean_phone TEXT;
    v_clean_veh TEXT;
    v_clean_city TEXT;
    v_partner_id TEXT;
    v_adj_date DATE;
    v_amount NUMERIC(12,2);
    v_adj_type TEXT;
    v_existing_id BIGINT;
    v_existing_source TEXT;
    v_existing_ref TEXT;
    v_next_id BIGINT;
BEGIN
    -- Acquire advisory lock
    PERFORM pg_advisory_xact_lock(777333444);

    -- Initialize sequence counter from current MAX(id)
    SELECT COALESCE(MAX(id), 0) INTO v_next_id FROM public.core_adjustments;

    -- Step 1: Ingest/Upsert from sheet_adjustments
    FOR r IN (SELECT * FROM public.sheet_adjustments ORDER BY submission_timestamp ASC, id ASC) LOOP
        v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(r.partner_phone, ''), '[^0-9]', '', 'g'), 10);
        v_clean_veh := UPPER(REGEXP_REPLACE(COALESCE(r.vehicle_number, ''), '[^A-Za-z0-9]', '', 'g'));
        v_clean_city := COALESCE(r.city_name, 'Bengaluru');
        v_partner_id := COALESCE(r.partner_code, public.fn_adj_canonical_partner_id(v_clean_city, v_clean_phone));

        SELECT id, data_source, source_reference_id
        INTO v_existing_id, v_existing_source, v_existing_ref
        FROM public.core_adjustments
        WHERE (
            ((v_clean_phone != '' AND partner_phone = v_clean_phone) OR (v_clean_phone = '' AND (partner_phone IS NULL OR partner_phone = '') AND v_clean_veh != '' AND vehicle_number = v_clean_veh))
            AND (v_clean_veh != '' AND vehicle_number = v_clean_veh)
            AND adjustment_date = r.adjustment_date
            AND amount = r.amount
            AND adjustment_type = r.adjustment_type
        ) OR source_reference_id = 'ADJ-SHT-' || r.id::TEXT
          OR r.id::TEXT = ANY(string_to_array(source_reference_id, ','))
          OR ('ADJ-SHT-' || r.id::TEXT) = ANY(string_to_array(source_reference_id, ','))
        LIMIT 1;

        IF v_existing_id IS NOT NULL THEN
            UPDATE public.core_adjustments
            SET
                partner_name = COALESCE(r.partner_name, core_adjustments.partner_name),
                partner_phone = COALESCE(v_clean_phone, core_adjustments.partner_phone),
                vehicle_number = COALESCE(v_clean_veh, core_adjustments.vehicle_number),
                remittance_towards = COALESCE(r.remittance_towards, core_adjustments.remittance_towards),
                adjustment_related_to = COALESCE(r.adjustment_related_to, core_adjustments.adjustment_related_to),
                amount = r.amount,
                approval_status = COALESCE(r.final_status, r.first_level_status, core_adjustments.approval_status),
                first_level_approver = COALESCE(r.first_level_approver, core_adjustments.first_level_approver),
                final_level_approver = COALESCE(r.final_level_approver, core_adjustments.final_level_approver),
                remarks = COALESCE(r.remarks, core_adjustments.remarks),
                photo_url = COALESCE(r.photo_url, core_adjustments.photo_url),
                data_source = CASE WHEN v_existing_source = 'PORTAL_FORM' THEN 'MERGED' ELSE 'GOOGLE_SHEET' END,
                source_reference_id = CASE 
                    WHEN v_existing_ref IS NOT NULL AND NOT (r.id::TEXT = ANY(string_to_array(v_existing_ref, ',')))
                    THEN v_existing_ref || ',ADJ-SHT-' || r.id::TEXT 
                    ELSE COALESCE(v_existing_ref, 'ADJ-SHT-' || r.id::TEXT) 
                END,
                is_deleted = FALSE,
                deleted_at = NULL,
                updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            WHERE id = v_existing_id;
        ELSE
            v_next_id := v_next_id + 1;

            INSERT INTO public.core_adjustments (
                id,
                adjustment_id,
                partner_id,
                partner_name,
                partner_phone,
                partner_type,
                vehicle_number,
                city_name,
                adjustment_type,
                adjustment_nature,
                adjustment_level,
                adjustment_date,
                amount,
                remittance_towards,
                adjustment_related_to,
                hisaab_number,
                hisaab_week_number,
                remarks,
                approval_status,
                first_level_approver,
                final_level_approver,
                photo_url,
                data_source,
                source_reference_id,
                is_deleted,
                created_at,
                updated_at
            ) VALUES (
                v_next_id,
                'ADJ-SHT-' || r.id::TEXT,
                v_partner_id,
                r.partner_name,
                v_clean_phone,
                COALESCE(r.partner_type, 'Individual'),
                v_clean_veh,
                r.city_name,
                COALESCE(r.adjustment_type, 'Credit'),
                'Monetary',
                CASE WHEN LOWER(r.partner_type) = 'operator' THEN 'Operator' ELSE 'Driver' END,
                r.adjustment_date,
                r.amount,
                r.remittance_towards,
                r.adjustment_related_to,
                r.hisaab_week_str,
                r.hisaab_week_number,
                r.remarks,
                COALESCE(r.final_status, r.first_level_status, 'Pending'),
                r.first_level_approver,
                r.final_level_approver,
                r.photo_url,
                'GOOGLE_SHEET',
                'ADJ-SHT-' || r.id::TEXT,
                FALSE,
                (COALESCE(r.submission_timestamp, CURRENT_TIMESTAMP) AT TIME ZONE 'Asia/Kolkata'),
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            );
            v_inserted_count := v_inserted_count + 1;
        END IF;
    END LOOP;

    -- Step 2: Ingest/Upsert from july_partner_adjustment
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'july_partner_adjustment') THEN
        FOR r IN (SELECT * FROM public.july_partner_adjustment ORDER BY created_at ASC, id ASC) LOOP
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
                CURRENT_DATE
            );

            v_amount := COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(r.enter_amount, ''), '[^0-9.]', '', 'g'), '')::NUMERIC, 0.00);
            v_adj_type := COALESCE(r.adjustment_type, 'Credit');

            SELECT id, data_source, source_reference_id
            INTO v_existing_id, v_existing_source, v_existing_ref
            FROM public.core_adjustments
            WHERE (
                ((v_clean_phone != '' AND partner_phone = v_clean_phone) OR (v_clean_phone = '' AND (partner_phone IS NULL OR partner_phone = '') AND v_clean_veh != '' AND vehicle_number = v_clean_veh))
                AND (v_clean_veh != '' AND vehicle_number = v_clean_veh)
                AND adjustment_date = v_adj_date
                AND amount = v_amount
                AND adjustment_type = v_adj_type
            ) OR source_reference_id = 'ADJ-PORTAL-' || r.id::TEXT
              OR r.id::TEXT = ANY(string_to_array(source_reference_id, ','))
              OR ('ADJ-PORTAL-' || r.id::TEXT) = ANY(string_to_array(source_reference_id, ','))
            LIMIT 1;

            IF v_existing_id IS NOT NULL THEN
                UPDATE public.core_adjustments
                SET
                    partner_name = COALESCE(r.partner_name, core_adjustments.partner_name),
                    partner_phone = COALESCE(v_clean_phone, core_adjustments.partner_phone),
                    vehicle_number = COALESCE(v_clean_veh, core_adjustments.vehicle_number),
                    remittance_towards = COALESCE(r.remittance_towards, core_adjustments.remittance_towards),
                    adjustment_related_to = COALESCE(r.adjustment_related_to, core_adjustments.adjustment_related_to),
                    hisaab_number = COALESCE(r.hisaab_number, core_adjustments.hisaab_number),
                    contested_line_items = CASE WHEN r.contested_line_items IS NOT NULL AND r.contested_line_items != '' AND r.contested_line_items != 'nan' THEN r.contested_line_items::JSONB ELSE core_adjustments.contested_line_items END,
                    severity_level = COALESCE(r.severity_level, core_adjustments.severity_level),
                    cost_level = COALESCE(r.cost_level, core_adjustments.cost_level),
                    remarks = COALESCE(r.remarks, core_adjustments.remarks),
                    approval_status = COALESCE(r.approval_status, r.status, core_adjustments.approval_status),
                    first_level_approver = COALESCE(r.first_level_approval_by, core_adjustments.first_level_approver),
                    final_level_approver = COALESCE(r.final_level_approval_by, core_adjustments.final_level_approver),
                    current_approver_id = COALESCE(r.current_approver_id::TEXT, core_adjustments.current_approver_id),
                    approved_by = COALESCE(r.approved_by::TEXT, core_adjustments.approved_by),
                    photo_url = COALESCE(r.photo, core_adjustments.photo_url),
                    data_source = 'MERGED',
                    source_reference_id = CASE 
                        WHEN v_existing_ref IS NOT NULL AND NOT (r.id::TEXT = ANY(string_to_array(v_existing_ref, ',')))
                        THEN v_existing_ref || ',ADJ-PORTAL-' || r.id::TEXT 
                        ELSE COALESCE(v_existing_ref, 'ADJ-PORTAL-' || r.id::TEXT) 
                    END,
                    is_deleted = FALSE,
                    deleted_at = NULL,
                    updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                WHERE id = v_existing_id;
            ELSE
                v_next_id := v_next_id + 1;

                INSERT INTO public.core_adjustments (
                    id,
                    adjustment_id,
                    partner_id,
                    partner_name,
                    partner_phone,
                    partner_type,
                    vehicle_number,
                    city_name,
                    adjustment_type,
                    adjustment_nature,
                    adjustment_level,
                    adjustment_date,
                    amount,
                    remittance_towards,
                    adjustment_related_to,
                    hisaab_number,
                    contested_line_items,
                    severity_level,
                    cost_level,
                    remarks,
                    approval_status,
                    first_level_approver,
                    final_level_approver,
                    current_approver_id,
                    approved_by,
                    photo_url,
                    data_source,
                    source_reference_id,
                    is_deleted,
                    created_at,
                    updated_at
                ) VALUES (
                    v_next_id,
                    'ADJ-PORTAL-' || r.id::TEXT,
                    v_partner_id,
                    r.partner_name,
                    v_clean_phone,
                    COALESCE(r.partner_type, 'Individual'),
                    v_clean_veh,
                    COALESCE(r.city_name, 'Bengaluru'),
                    v_adj_type,
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
                    COALESCE(r.approval_status, r.status, 'Pending'),
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
                v_inserted_count := v_inserted_count + 1;
            END IF;
        END LOOP;
    END IF;

    -- Reset underlying sequence to match max(id)
    PERFORM setval('public.core_adjustments_id_seq', COALESCE(v_next_id, 1), true);

    RETURN v_inserted_count;
END;
$$ LANGUAGE plpgsql;
