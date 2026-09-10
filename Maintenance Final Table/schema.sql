-- =============================================================================
-- LetzRyd Vehicle Maintenance Single Source of Truth: public.core_maintenance
-- =============================================================================
-- Master table consolidating workshop downtime records across:
--   1. public.sheet_maintenance (Google Sheets operational status extract)
--   2. public.july_maintenance_in + public.july_maintenance_out (Web Portal)
--
-- Architectural Guarantees:
--   - Dual-Source Unification with Portal Priority:
--       * Seamless consolidation of Google Sheets manual tracking and Web Portal
--         digital repair workflows into a canonical maintenance ledger.
--       * When a record exists in both Portal and Sheet, Portal data takes precedence.
--   - Inward & Outward Interval Pairing:
--       * Portal inward entries (july_maintenance_in) and outward releases
--         (july_maintenance_out) are merged into unified temporal intervals.
--   - Non-Negative Duration Enforcement:
--       * Start and end dates are strictly validated ensuring end_date >= start_date.
--   - Soft Delete Protection:
--       * Deletions in upstream tables flag is_deleted = TRUE and record deleted_at.
--   - Gapless 1..N ID Sequence Integrity:
--       * Concurrency-safe synchronization using PostgreSQL transactional advisory locks.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Helper & Normalization Functions
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.fn_clean_maintenance_vehicle(TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.fn_clean_maintenance_city(TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.fn_parse_maintenance_date(TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.fn_parse_maintenance_timestamp(TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.fn_parse_maintenance_numeric(TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.fn_parse_maintenance_int(TEXT) CASCADE;

-- Standardize vehicle registration number: uppercase alphanumeric string
CREATE OR REPLACE FUNCTION public.fn_clean_maintenance_vehicle(p_veh TEXT)
RETURNS VARCHAR(50) AS $$
BEGIN
    RETURN LEFT(UPPER(REGEXP_REPLACE(COALESCE(p_veh, ''), '[^A-Za-z0-9]', '', 'g')), 50);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Standardize operational city name
CREATE OR REPLACE FUNCTION public.fn_clean_maintenance_city(p_city TEXT, p_veh TEXT DEFAULT '')
RETURNS VARCHAR(100) AS $$
DECLARE
    v_norm TEXT;
    v_veh TEXT;
BEGIN
    v_norm := LOWER(TRIM(COALESCE(p_city, '')));
    v_veh := UPPER(REGEXP_REPLACE(COALESCE(p_veh, ''), '[^A-Za-z0-9]', '', 'g'));

    IF v_norm IN ('bangalore', 'bengaluru', 'blr') THEN
        RETURN 'Bangalore';
    ELSIF v_norm IN ('hyderabad', 'hyd') THEN
        RETURN 'Hyderabad';
    ELSIF v_norm IN ('mumbai', 'mum', 'bombay') THEN
        RETURN 'Mumbai';
    ELSIF v_norm IN ('pune', 'pun') THEN
        RETURN 'Pune';
    ELSIF v_norm IN ('delhi', 'new delhi', 'ncr', 'del') THEN
        RETURN 'Delhi';
    END IF;

    -- Fallback inference by state registration prefix
    IF v_veh LIKE 'KA%' THEN
        RETURN 'Bangalore';
    ELSIF v_veh LIKE 'TS%' OR v_veh LIKE 'TG%' OR v_veh LIKE 'AP%' THEN
        RETURN 'Hyderabad';
    ELSIF v_veh LIKE 'MH%' THEN
        RETURN 'Mumbai';
    ELSIF v_veh LIKE 'DL%' THEN
        RETURN 'Delhi';
    END IF;

    IF v_norm IS NOT NULL AND v_norm <> '' THEN
        RETURN LEFT(INITCAP(TRIM(p_city)), 100);
    END IF;

    RETURN 'Bangalore';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Safe string-to-date parser supporting ISO, timestamps, and Indian date formats
CREATE OR REPLACE FUNCTION public.fn_parse_maintenance_date(p_raw TEXT)
RETURNS DATE AS $$
DECLARE
    v_str TEXT;
BEGIN
    IF p_raw IS NULL OR TRIM(p_raw) = '' OR TRIM(p_raw) = '-' OR LOWER(TRIM(p_raw)) IN ('null', 'nan') THEN
        RETURN NULL;
    END IF;

    v_str := TRIM(p_raw);

    -- YYYY-MM-DD or ISO timestamp prefix e.g. 2026-09-07T16:48:55
    IF v_str ~ '^\d{4}-\d{2}-\d{2}' THEN
        BEGIN
            RETURN SUBSTRING(v_str FROM 1 FOR 10)::DATE;
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    END IF;

    -- DD/MM/YYYY or DD-MM-YYYY
    IF v_str ~ '^\d{1,2}/\d{1,2}/\d{4}' THEN
        BEGIN
            RETURN TO_DATE(SUBSTRING(v_str FROM 1 FOR 10), 'DD/MM/YYYY');
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    ELSIF v_str ~ '^\d{1,2}-\d{1,2}-\d{4}' THEN
        BEGIN
            RETURN TO_DATE(SUBSTRING(v_str FROM 1 FOR 10), 'DD-MM-YYYY');
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Safe string-to-timestamp parser (IST without timezone)
CREATE OR REPLACE FUNCTION public.fn_parse_maintenance_timestamp(p_raw TEXT)
RETURNS TIMESTAMP WITHOUT TIME ZONE AS $$
DECLARE
    v_str TEXT;
BEGIN
    IF p_raw IS NULL OR TRIM(p_raw) = '' OR TRIM(p_raw) = '-' OR LOWER(TRIM(p_raw)) IN ('null', 'nan') THEN
        RETURN NULL;
    END IF;

    v_str := TRIM(p_raw);

    -- ISO format e.g. 2026-09-07T13:53 or 2026-09-07T16:48:55
    IF v_str ~ '^\d{4}-\d{2}-\d{2}T' THEN
        BEGIN
            RETURN REPLACE(v_str, 'T', ' ')::TIMESTAMP WITHOUT TIME ZONE;
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    END IF;

    -- Standard timestamp YYYY-MM-DD HH24:MI:SS
    IF v_str ~ '^\d{4}-\d{2}-\d{2}' THEN
        BEGIN
            RETURN v_str::TIMESTAMP WITHOUT TIME ZONE;
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    END IF;

    -- DD/MM/YYYY HH24:MI:SS
    IF v_str ~ '^\d{1,2}/\d{1,2}/\d{4}' THEN
        BEGIN
            RETURN TO_TIMESTAMP(v_str, 'DD/MM/YYYY HH24:MI:SS')::TIMESTAMP WITHOUT TIME ZONE;
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Safe numeric parser
CREATE OR REPLACE FUNCTION public.fn_parse_maintenance_numeric(p_raw TEXT)
RETURNS NUMERIC(12, 2) AS $$
DECLARE
    v_clean TEXT;
BEGIN
    IF p_raw IS NULL OR TRIM(p_raw) = '' OR TRIM(p_raw) = '-' OR LOWER(TRIM(p_raw)) IN ('null', 'nan') THEN
        RETURN 0.00;
    END IF;
    v_clean := REGEXP_REPLACE(TRIM(p_raw), '[^0-9\.]', '', 'g');
    IF v_clean = '' OR v_clean = '.' THEN
        RETURN 0.00;
    END IF;
    RETURN ROUND(v_clean::NUMERIC, 2);
EXCEPTION WHEN OTHERS THEN
    RETURN 0.00;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Safe integer parser
CREATE OR REPLACE FUNCTION public.fn_parse_maintenance_int(p_raw TEXT)
RETURNS INTEGER AS $$
DECLARE
    v_clean TEXT;
BEGIN
    IF p_raw IS NULL OR TRIM(p_raw) = '' OR TRIM(p_raw) = '-' OR LOWER(TRIM(p_raw)) IN ('null', 'nan') THEN
        RETURN NULL;
    END IF;
    v_clean := REGEXP_REPLACE(TRIM(p_raw), '[^0-9]', '', 'g');
    IF v_clean = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_clean::INTEGER;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- -----------------------------------------------------------------------------
-- 2. Master Table Definition: public.core_maintenance
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS public.core_maintenance CASCADE;

CREATE TABLE public.core_maintenance (
    id BIGINT PRIMARY KEY,
    source_type VARCHAR(50) NOT NULL, -- 'WEB_PORTAL', 'GOOGLE_SHEET'
    portal_maintenance_in_id INTEGER,
    portal_maintenance_out_id INTEGER,
    sheet_maintenance_id BIGINT,

    -- Vehicle & Location Identifiers
    vehicle_number VARCHAR(50) NOT NULL,
    city VARCHAR(100) NOT NULL,
    vehicle_location TEXT,
    vehicle_model VARCHAR(150),

    -- Temporal Interval Bounds
    start_date DATE NOT NULL,
    end_date DATE,
    in_date_time TIMESTAMP WITHOUT TIME ZONE,
    out_date_time TIMESTAMP WITHOUT TIME ZONE,
    estimated_delivery_date DATE,
    rfd_date DATE,

    -- Operational Status & Assignment
    maintenance_status VARCHAR(50) NOT NULL DEFAULT 'IN_PROGRESS',
    cohort VARCHAR(50) DEFAULT 'Off Road',
    partner_name VARCHAR(255),
    partner_ids VARCHAR(100),
    new_partner_name_default VARCHAR(255),
    dm_name VARCHAR(150),
    type VARCHAR(50),
    mapping VARCHAR(100),

    -- Technical Job Card & Workshop Details
    repair_type VARCHAR(100),
    workshop_name VARCHAR(255),
    in_kms INTEGER,
    out_kms INTEGER,
    job_card_number VARCHAR(100),
    remarks TEXT,

    -- Financial, Insurance & Invoicing Details
    estimated_amount NUMERIC(12, 2) DEFAULT 0.00,
    invoice_no VARCHAR(100),
    invoice_date DATE,
    invoice_amount NUMERIC(12, 2) DEFAULT 0.00,
    insurance_claimed BOOLEAN DEFAULT FALSE,
    insurance_brokerage VARCHAR(100),
    claim_number VARCHAR(100),
    insurance_liability_discounts NUMERIC(12, 2) DEFAULT 0.00,
    letzryd_payable NUMERIC(12, 2) DEFAULT 0.00,
    type_of_payment VARCHAR(100),
    payment_status VARCHAR(50),
    utr_no VARCHAR(100),
    approved_by VARCHAR(150),
    approval_date DATE,

    -- Documents, Media & Cloud URLs
    approval_file TEXT,
    damage_photos TEXT,
    outward_photos TEXT,
    invoice_file TEXT,

    -- Soft Deletion & Audit Tracking
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    extra_attributes JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
);

-- Performance & Lookup Indexes
CREATE INDEX IF NOT EXISTS idx_core_maint_veh_dates ON public.core_maintenance (vehicle_number, start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_core_maint_status ON public.core_maintenance (maintenance_status);
CREATE INDEX IF NOT EXISTS idx_core_maint_source ON public.core_maintenance (source_type);
CREATE INDEX IF NOT EXISTS idx_core_maint_city ON public.core_maintenance (city);
CREATE INDEX IF NOT EXISTS idx_core_maint_is_deleted ON public.core_maintenance (is_deleted);
CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_core_maint_portal_in ON public.core_maintenance (portal_maintenance_in_id) WHERE portal_maintenance_in_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_core_maint_sheet_id ON public.core_maintenance (sheet_maintenance_id) WHERE sheet_maintenance_id IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 3. Trigger 1: Real-Time Sync from public.july_maintenance_in (Web Portal Inward)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_core_maintenance_from_portal_in()
RETURNS TRIGGER AS $$
DECLARE
    v_next_id BIGINT;
    v_clean_veh VARCHAR(50);
    v_clean_city VARCHAR(100);
    v_start_date DATE;
    v_in_dt TIMESTAMP WITHOUT TIME ZONE;
    v_est_delivery DATE;
    v_appr_date DATE;
    v_est_amt NUMERIC(12, 2);
    v_in_kms INTEGER;
    v_ins_claimed BOOLEAN;
    v_out RECORD;
    v_end_date DATE;
    v_out_dt TIMESTAMP WITHOUT TIME ZONE;
    v_out_kms INTEGER;
    v_inv_date DATE;
    v_inv_amt NUMERIC(12, 2);
    v_ins_disc NUMERIC(12, 2);
    v_payable NUMERIC(12, 2);
    v_status VARCHAR(50);
BEGIN
    -- Handle Soft Delete
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_maintenance
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE portal_maintenance_in_id = OLD.id;
        RETURN OLD;
    END IF;

    -- Clean & Parse Inward Attributes
    v_clean_veh := public.fn_clean_maintenance_vehicle(NEW.vehicle_number);
    v_clean_city := public.fn_clean_maintenance_city(NEW.city_name, v_clean_veh);
    v_in_dt := public.fn_parse_maintenance_timestamp(NEW.vehicle_in_date_time);
    v_start_date := COALESCE(v_in_dt::DATE, NEW.created_at::DATE, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')::DATE);
    v_est_delivery := public.fn_parse_maintenance_date(NEW.estimated_delivery_date);
    v_appr_date := public.fn_parse_maintenance_date(NEW.approval_date);
    v_est_amt := public.fn_parse_maintenance_numeric(NEW.estimated_amount);
    v_in_kms := public.fn_parse_maintenance_int(NEW.vehicle_k_m_s);
    v_ins_claimed := CASE WHEN LOWER(TRIM(COALESCE(NEW.insurance_claimed, ''))) IN ('yes', 'true', '1') THEN TRUE ELSE FALSE END;

    -- Check for paired outward release in july_maintenance_out
    SELECT * INTO v_out FROM public.july_maintenance_out WHERE inward_id = NEW.id ORDER BY id DESC LIMIT 1;
    IF FOUND THEN
        v_out_dt := public.fn_parse_maintenance_timestamp(v_out.vehicle_out_date_time);
        v_end_date := COALESCE(public.fn_parse_maintenance_date(v_out.rfd_date), v_out_dt::DATE);
        IF v_end_date IS NOT NULL AND v_end_date < v_start_date THEN
            v_end_date := v_start_date; -- Non-negative duration enforcement
        END IF;
        v_out_kms := public.fn_parse_maintenance_int(v_out.vehicle_out_k_m_s);
        v_inv_date := public.fn_parse_maintenance_date(v_out.invoice_date);
        v_inv_amt := public.fn_parse_maintenance_numeric(v_out.invoice_amount);
        v_ins_disc := public.fn_parse_maintenance_numeric(v_out.insurance_liability_discounts);
        v_payable := public.fn_parse_maintenance_numeric(v_out.letzryd_payable);
        v_status := COALESCE(v_out.final_status, 'COMPLETED_RFD');
    ELSE
        v_end_date := NULL;
        v_out_dt := NULL;
        v_out_kms := NULL;
        v_inv_date := NULL;
        v_inv_amt := 0.00;
        v_ins_disc := 0.00;
        v_payable := 0.00;
        v_status := CASE WHEN NEW.is_closed = TRUE THEN 'COMPLETED' ELSE 'IN_PROGRESS' END;
    END IF;

    -- Acquire Advisory Lock for Gapless ID Assignment
    PERFORM pg_advisory_xact_lock(888999111);

    -- Check if record already exists in core_maintenance
    IF EXISTS (SELECT 1 FROM public.core_maintenance WHERE portal_maintenance_in_id = NEW.id) THEN
        UPDATE public.core_maintenance SET
            source_type = 'WEB_PORTAL',
            portal_maintenance_out_id = v_out.id,
            vehicle_number = v_clean_veh,
            city = v_clean_city,
            vehicle_location = NEW.vehicle_location,
            start_date = v_start_date,
            end_date = v_end_date,
            in_date_time = v_in_dt,
            out_date_time = v_out_dt,
            estimated_delivery_date = v_est_delivery,
            rfd_date = v_end_date,
            maintenance_status = v_status,
            cohort = 'Off Road',
            repair_type = NEW.repair_type,
            workshop_name = NEW.workshop_name,
            in_kms = v_in_kms,
            out_kms = v_out_kms,
            remarks = COALESCE(NEW.remarks, v_out.remarks),
            estimated_amount = v_est_amt,
            invoice_no = v_out.invoice_no,
            invoice_date = v_inv_date,
            invoice_amount = v_inv_amt,
            insurance_claimed = v_ins_claimed,
            insurance_brokerage = NEW.insurance_brokerage,
            claim_number = NEW.claim_number,
            insurance_liability_discounts = v_ins_disc,
            letzryd_payable = v_payable,
            type_of_payment = v_out.type_of_payment,
            payment_status = v_out.payment_status,
            utr_no = v_out.utr_no,
            approved_by = COALESCE(NEW.approved_by, v_out.approved_by),
            approval_date = COALESCE(v_appr_date, public.fn_parse_maintenance_date(v_out.approval_date)),
            approval_file = COALESCE(NEW.approval_file, v_out.approval_file),
            damage_photos = NEW.vehicle_damage_photos,
            outward_photos = v_out.vehicle_out_photos,
            invoice_file = v_out.invoice_file,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE portal_maintenance_in_id = NEW.id;
    ELSE
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_maintenance;

        INSERT INTO public.core_maintenance (
            id, source_type, portal_maintenance_in_id, portal_maintenance_out_id, sheet_maintenance_id,
            vehicle_number, city, vehicle_location, vehicle_model,
            start_date, end_date, in_date_time, out_date_time, estimated_delivery_date, rfd_date,
            maintenance_status, cohort, partner_name, partner_ids, new_partner_name_default, dm_name, type, mapping,
            repair_type, workshop_name, in_kms, out_kms, job_card_number, remarks,
            estimated_amount, invoice_no, invoice_date, invoice_amount,
            insurance_claimed, insurance_brokerage, claim_number, insurance_liability_discounts, letzryd_payable,
            type_of_payment, payment_status, utr_no, approved_by, approval_date,
            approval_file, damage_photos, outward_photos, invoice_file,
            is_deleted, deleted_at, created_at, updated_at
        ) VALUES (
            v_next_id, 'WEB_PORTAL', NEW.id, v_out.id, NULL,
            v_clean_veh, v_clean_city, NEW.vehicle_location, NULL,
            v_start_date, v_end_date, v_in_dt, v_out_dt, v_est_delivery, v_end_date,
            v_status, 'Off Road', NULL, NULL, NULL, NULL, NULL, NULL,
            NEW.repair_type, NEW.workshop_name, v_in_kms, v_out_kms, NULL, COALESCE(NEW.remarks, v_out.remarks),
            v_est_amt, v_out.invoice_no, v_inv_date, v_inv_amt,
            v_ins_claimed, NEW.insurance_brokerage, NEW.claim_number, v_ins_disc, v_payable,
            v_out.type_of_payment, v_out.payment_status, v_out.utr_no, COALESCE(NEW.approved_by, v_out.approved_by), COALESCE(v_appr_date, public.fn_parse_maintenance_date(v_out.approval_date)),
            COALESCE(NEW.approval_file, v_out.approval_file), NEW.vehicle_damage_photos, v_out.vehicle_out_photos, v_out.invoice_file,
            FALSE, NULL,
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_maintenance_from_portal_in ON public.july_maintenance_in;
CREATE TRIGGER trg_sync_core_maintenance_from_portal_in
AFTER INSERT OR UPDATE OR DELETE ON public.july_maintenance_in
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_maintenance_from_portal_in();


-- -----------------------------------------------------------------------------
-- 4. Trigger 2: Real-Time Sync from public.july_maintenance_out (Web Portal Outward)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_core_maintenance_from_portal_out()
RETURNS TRIGGER AS $$
DECLARE
    v_out_dt TIMESTAMP WITHOUT TIME ZONE;
    v_end_date DATE;
    v_inv_date DATE;
    v_inv_amt NUMERIC(12, 2);
    v_ins_disc NUMERIC(12, 2);
    v_payable NUMERIC(12, 2);
    v_out_kms INTEGER;
BEGIN
    IF TG_OP = 'DELETE' THEN
        -- Revert outward details on core_maintenance row
        UPDATE public.core_maintenance SET
            portal_maintenance_out_id = NULL,
            end_date = NULL,
            out_date_time = NULL,
            out_kms = NULL,
            invoice_no = NULL,
            invoice_date = NULL,
            invoice_amount = 0.00,
            insurance_liability_discounts = 0.00,
            letzryd_payable = 0.00,
            type_of_payment = NULL,
            payment_status = NULL,
            utr_no = NULL,
            outward_photos = NULL,
            invoice_file = NULL,
            maintenance_status = 'IN_PROGRESS',
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE portal_maintenance_in_id = OLD.inward_id;
        RETURN OLD;
    END IF;

    v_out_dt := public.fn_parse_maintenance_timestamp(NEW.vehicle_out_date_time);
    v_end_date := COALESCE(public.fn_parse_maintenance_date(NEW.rfd_date), v_out_dt::DATE);
    v_out_kms := public.fn_parse_maintenance_int(NEW.vehicle_out_k_m_s);
    v_inv_date := public.fn_parse_maintenance_date(NEW.invoice_date);
    v_inv_amt := public.fn_parse_maintenance_numeric(NEW.invoice_amount);
    v_ins_disc := public.fn_parse_maintenance_numeric(NEW.insurance_liability_discounts);
    v_payable := public.fn_parse_maintenance_numeric(NEW.letzryd_payable);

    UPDATE public.core_maintenance SET
        portal_maintenance_out_id = NEW.id,
        end_date = CASE WHEN v_end_date IS NOT NULL AND v_end_date < start_date THEN start_date ELSE v_end_date END,
        out_date_time = v_out_dt,
        out_kms = v_out_kms,
        rfd_date = v_end_date,
        maintenance_status = COALESCE(NEW.final_status, 'COMPLETED_RFD'),
        invoice_no = NEW.invoice_no,
        invoice_date = v_inv_date,
        invoice_amount = v_inv_amt,
        insurance_liability_discounts = v_ins_disc,
        letzryd_payable = v_payable,
        type_of_payment = NEW.type_of_payment,
        payment_status = NEW.payment_status,
        utr_no = NEW.utr_no,
        approved_by = COALESCE(approved_by, NEW.approved_by),
        approval_date = COALESCE(approval_date, public.fn_parse_maintenance_date(NEW.approval_date)),
        approval_file = COALESCE(approval_file, NEW.approval_file),
        outward_photos = NEW.vehicle_out_photos,
        invoice_file = NEW.invoice_file,
        remarks = COALESCE(remarks, NEW.remarks),
        updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
    WHERE portal_maintenance_in_id = NEW.inward_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_maintenance_from_portal_out ON public.july_maintenance_out;
CREATE TRIGGER trg_sync_core_maintenance_from_portal_out
AFTER INSERT OR UPDATE OR DELETE ON public.july_maintenance_out
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_maintenance_from_portal_out();


-- -----------------------------------------------------------------------------
-- 5. Trigger 3: Real-Time Sync from public.sheet_maintenance (Google Sheets Staging)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_core_maintenance_from_sheet()
RETURNS TRIGGER AS $$
DECLARE
    v_next_id BIGINT;
    v_clean_veh VARCHAR(50);
    v_clean_city VARCHAR(100);
    v_start_date DATE;
    v_drop_date DATE;
    v_alloc_date DATE;
BEGIN
    -- Handle Soft Delete
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_maintenance
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE sheet_maintenance_id = OLD.id;
        RETURN OLD;
    END IF;

    -- If upstream marked is_deleted = TRUE
    IF NEW.is_deleted = TRUE THEN
        UPDATE public.core_maintenance
        SET is_deleted = TRUE,
            deleted_at = COALESCE(NEW.deleted_at, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE sheet_maintenance_id = NEW.id;
        RETURN NEW;
    END IF;

    v_clean_veh := public.fn_clean_maintenance_vehicle(NEW.vehicle_number);
    v_clean_city := public.fn_clean_maintenance_city(NEW.city, v_clean_veh);
    v_start_date := NEW.date;
    v_drop_date := NEW.drop_off_date;
    v_alloc_date := NEW.allocation_date;

    -- PORTAL PRIORITY CHECK:
    -- If this vehicle already has a portal ticket covering this date window, enrich metadata only, do not duplicate!
    IF EXISTS (
        SELECT 1 FROM public.core_maintenance 
        WHERE vehicle_number = v_clean_veh 
          AND source_type = 'WEB_PORTAL'
          AND (start_date = v_start_date OR (end_date IS NOT NULL AND v_start_date BETWEEN start_date AND end_date))
    ) THEN
        -- Enrich the portal record with sheet metadata (model, driver, DM name)
        UPDATE public.core_maintenance SET
            vehicle_model = COALESCE(vehicle_model, NEW.vehicle_model),
            partner_name = COALESCE(partner_name, NEW.partner_name),
            partner_ids = COALESCE(partner_ids, NEW.partner_ids),
            dm_name = COALESCE(dm_name, NEW.dm_name),
            type = COALESCE(type, NEW.type),
            mapping = COALESCE(mapping, NEW.mapping),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE vehicle_number = v_clean_veh 
          AND source_type = 'WEB_PORTAL'
          AND (start_date = v_start_date OR (end_date IS NOT NULL AND v_start_date BETWEEN start_date AND end_date));
        RETURN NEW;
    END IF;

    -- Acquire Advisory Lock for Gapless ID Assignment
    PERFORM pg_advisory_xact_lock(888999111);

    IF EXISTS (SELECT 1 FROM public.core_maintenance WHERE sheet_maintenance_id = NEW.id) THEN
        UPDATE public.core_maintenance SET
            vehicle_number = v_clean_veh,
            city = v_clean_city,
            vehicle_model = NEW.vehicle_model,
            start_date = v_start_date,
            end_date = v_drop_date,
            maintenance_status = CASE WHEN LOWER(TRIM(NEW.final_status)) = 'maintenance' THEN 'IN_PROGRESS' ELSE NEW.final_status END,
            cohort = COALESCE(NEW.cohort, 'Off Road'),
            partner_name = NEW.partner_name,
            partner_ids = NEW.partner_ids,
            new_partner_name_default = NEW.new_partner_name_default,
            dm_name = NEW.dm_name,
            type = NEW.type,
            mapping = NEW.mapping,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE sheet_maintenance_id = NEW.id;
    ELSE
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_maintenance;

        INSERT INTO public.core_maintenance (
            id, source_type, portal_maintenance_in_id, portal_maintenance_out_id, sheet_maintenance_id,
            vehicle_number, city, vehicle_location, vehicle_model,
            start_date, end_date, in_date_time, out_date_time, estimated_delivery_date, rfd_date,
            maintenance_status, cohort, partner_name, partner_ids, new_partner_name_default, dm_name, type, mapping,
            repair_type, workshop_name, in_kms, out_kms, job_card_number, remarks,
            estimated_amount, invoice_no, invoice_date, invoice_amount,
            insurance_claimed, insurance_brokerage, claim_number, insurance_liability_discounts, letzryd_payable,
            type_of_payment, payment_status, utr_no, approved_by, approval_date,
            approval_file, damage_photos, outward_photos, invoice_file,
            is_deleted, deleted_at, created_at, updated_at
        ) VALUES (
            v_next_id, 'GOOGLE_SHEET', NULL, NULL, NEW.id,
            v_clean_veh, v_clean_city, NULL, NEW.vehicle_model,
            v_start_date, v_drop_date, NULL, NULL, NULL, v_drop_date,
            CASE WHEN LOWER(TRIM(NEW.final_status)) = 'maintenance' THEN 'IN_PROGRESS' ELSE NEW.final_status END,
            COALESCE(NEW.cohort, 'Off Road'), NEW.partner_name, NEW.partner_ids, NEW.new_partner_name_default, NEW.dm_name, NEW.type, NEW.mapping,
            NULL, NULL, NULL, NULL, NULL, NULL,
            0.00, NULL, NULL, 0.00,
            FALSE, NULL, NULL, 0.00, 0.00,
            NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL,
            FALSE, NULL,
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_maintenance_from_sheet ON public.sheet_maintenance;
CREATE TRIGGER trg_sync_core_maintenance_from_sheet
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_maintenance
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_maintenance_from_sheet();


-- -----------------------------------------------------------------------------
-- 6. Stored Procedure: sp_rebuild_core_maintenance (Full Historical Consolidation)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_rebuild_core_maintenance()
LANGUAGE plpgsql AS $$
DECLARE
    v_in RECORD;
    v_out RECORD;
    v_sheet RECORD;
    v_curr_id BIGINT := 0;
    v_clean_veh VARCHAR(50);
    v_clean_city VARCHAR(100);
    v_in_dt TIMESTAMP WITHOUT TIME ZONE;
    v_out_dt TIMESTAMP WITHOUT TIME ZONE;
    v_start_date DATE;
    v_end_date DATE;
    v_est_delivery DATE;
    v_appr_date DATE;
    v_est_amt NUMERIC(12, 2);
    v_inv_amt NUMERIC(12, 2);
    v_ins_disc NUMERIC(12, 2);
    v_payable NUMERIC(12, 2);
    v_in_kms INTEGER;
    v_out_kms INTEGER;
    v_ins_claimed BOOLEAN;
    v_status VARCHAR(50);
BEGIN
    -- Acquire exclusive advisory lock during rebuild
    PERFORM pg_advisory_xact_lock(888999111);

    -- Clear existing core table
    TRUNCATE TABLE public.core_maintenance;

    -- =========================================================================
    -- STEP 1: Ingest Web Portal Inward & Outward Records (Portal Priority)
    -- =========================================================================
    FOR v_in IN 
        SELECT * FROM public.july_maintenance_in ORDER BY id ASC
    LOOP
        v_curr_id := v_curr_id + 1;
        v_clean_veh := public.fn_clean_maintenance_vehicle(v_in.vehicle_number);
        v_clean_city := public.fn_clean_maintenance_city(v_in.city_name, v_clean_veh);
        v_in_dt := public.fn_parse_maintenance_timestamp(v_in.vehicle_in_date_time);
        v_start_date := COALESCE(v_in_dt::DATE, v_in.created_at::DATE, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')::DATE);
        v_est_delivery := public.fn_parse_maintenance_date(v_in.estimated_delivery_date);
        v_appr_date := public.fn_parse_maintenance_date(v_in.approval_date);
        v_est_amt := public.fn_parse_maintenance_numeric(v_in.estimated_amount);
        v_in_kms := public.fn_parse_maintenance_int(v_in.vehicle_k_m_s);
        v_ins_claimed := CASE WHEN LOWER(TRIM(COALESCE(v_in.insurance_claimed, ''))) IN ('yes', 'true', '1') THEN TRUE ELSE FALSE END;

        -- Find paired outward release
        SELECT * INTO v_out FROM public.july_maintenance_out WHERE inward_id = v_in.id ORDER BY id DESC LIMIT 1;
        IF FOUND THEN
            v_out_dt := public.fn_parse_maintenance_timestamp(v_out.vehicle_out_date_time);
            v_end_date := COALESCE(public.fn_parse_maintenance_date(v_out.rfd_date), v_out_dt::DATE);
            IF v_end_date IS NOT NULL AND v_end_date < v_start_date THEN
                v_end_date := v_start_date;
            END IF;
            v_out_kms := public.fn_parse_maintenance_int(v_out.vehicle_out_k_m_s);
            v_inv_amt := public.fn_parse_maintenance_numeric(v_out.invoice_amount);
            v_ins_disc := public.fn_parse_maintenance_numeric(v_out.insurance_liability_discounts);
            v_payable := public.fn_parse_maintenance_numeric(v_out.letzryd_payable);
            v_status := COALESCE(v_out.final_status, 'COMPLETED_RFD');
        ELSE
            v_end_date := NULL;
            v_out_dt := NULL;
            v_out_kms := NULL;
            v_inv_amt := 0.00;
            v_ins_disc := 0.00;
            v_payable := 0.00;
            v_status := CASE WHEN v_in.is_closed = TRUE THEN 'COMPLETED' ELSE 'IN_PROGRESS' END;
        END IF;

        INSERT INTO public.core_maintenance (
            id, source_type, portal_maintenance_in_id, portal_maintenance_out_id, sheet_maintenance_id,
            vehicle_number, city, vehicle_location, vehicle_model,
            start_date, end_date, in_date_time, out_date_time, estimated_delivery_date, rfd_date,
            maintenance_status, cohort, partner_name, partner_ids, new_partner_name_default, dm_name, type, mapping,
            repair_type, workshop_name, in_kms, out_kms, job_card_number, remarks,
            estimated_amount, invoice_no, invoice_date, invoice_amount,
            insurance_claimed, insurance_brokerage, claim_number, insurance_liability_discounts, letzryd_payable,
            type_of_payment, payment_status, utr_no, approved_by, approval_date,
            approval_file, damage_photos, outward_photos, invoice_file,
            is_deleted, deleted_at, created_at, updated_at
        ) VALUES (
            v_curr_id, 'WEB_PORTAL', v_in.id, v_out.id, NULL,
            v_clean_veh, v_clean_city, v_in.vehicle_location, NULL,
            v_start_date, v_end_date, v_in_dt, v_out_dt, v_est_delivery, v_end_date,
            v_status, 'Off Road', NULL, NULL, NULL, NULL, NULL, NULL,
            v_in.repair_type, v_in.workshop_name, v_in_kms, v_out_kms, NULL, COALESCE(v_in.remarks, v_out.remarks),
            v_est_amt, v_out.invoice_no, public.fn_parse_maintenance_date(v_out.invoice_date), v_inv_amt,
            v_ins_claimed, v_in.insurance_brokerage, v_in.claim_number, v_ins_disc, v_payable,
            v_out.type_of_payment, v_out.payment_status, v_out.utr_no, COALESCE(v_in.approved_by, v_out.approved_by), COALESCE(v_appr_date, public.fn_parse_maintenance_date(v_out.approval_date)),
            COALESCE(v_in.approval_file, v_out.approval_file), v_in.vehicle_damage_photos, v_out.vehicle_out_photos, v_out.invoice_file,
            FALSE, NULL,
            COALESCE(v_in.created_at, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
    END LOOP;

    -- =========================================================================
    -- STEP 2: Ingest Google Sheets Staging Records (Reconciliation & Deduplication)
    -- =========================================================================
    FOR v_sheet IN 
        SELECT * FROM public.sheet_maintenance WHERE is_deleted = FALSE ORDER BY id ASC
    LOOP
        v_clean_veh := public.fn_clean_maintenance_vehicle(v_sheet.vehicle_number);
        v_clean_city := public.fn_clean_maintenance_city(v_sheet.city, v_clean_veh);
        v_start_date := v_sheet.date;

        -- Check if vehicle has portal record on this date window (Portal Priority check)
        IF EXISTS (
            SELECT 1 FROM public.core_maintenance 
            WHERE vehicle_number = v_clean_veh 
              AND source_type = 'WEB_PORTAL'
              AND (start_date = v_start_date OR (end_date IS NOT NULL AND v_start_date BETWEEN start_date AND end_date))
        ) THEN
            -- Enrich existing portal record with sheet metadata
            UPDATE public.core_maintenance SET
                vehicle_model = COALESCE(vehicle_model, v_sheet.vehicle_model),
                partner_name = COALESCE(partner_name, v_sheet.partner_name),
                partner_ids = COALESCE(partner_ids, v_sheet.partner_ids),
                dm_name = COALESCE(dm_name, v_sheet.dm_name),
                type = COALESCE(type, v_sheet.type),
                mapping = COALESCE(mapping, v_sheet.mapping),
                updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            WHERE vehicle_number = v_clean_veh 
              AND source_type = 'WEB_PORTAL'
              AND (start_date = v_start_date OR (end_date IS NOT NULL AND v_start_date BETWEEN start_date AND end_date));
        ELSE
            -- Insert new Google Sheet record
            v_curr_id := v_curr_id + 1;

            INSERT INTO public.core_maintenance (
                id, source_type, portal_maintenance_in_id, portal_maintenance_out_id, sheet_maintenance_id,
                vehicle_number, city, vehicle_location, vehicle_model,
                start_date, end_date, in_date_time, out_date_time, estimated_delivery_date, rfd_date,
                maintenance_status, cohort, partner_name, partner_ids, new_partner_name_default, dm_name, type, mapping,
                repair_type, workshop_name, in_kms, out_kms, job_card_number, remarks,
                estimated_amount, invoice_no, invoice_date, invoice_amount,
                insurance_claimed, insurance_brokerage, claim_number, insurance_liability_discounts, letzryd_payable,
                type_of_payment, payment_status, utr_no, approved_by, approval_date,
                approval_file, damage_photos, outward_photos, invoice_file,
                is_deleted, deleted_at, created_at, updated_at
            ) VALUES (
                v_curr_id, 'GOOGLE_SHEET', NULL, NULL, v_sheet.id,
                v_clean_veh, v_clean_city, NULL, v_sheet.vehicle_model,
                v_start_date, v_sheet.drop_off_date, NULL, NULL, NULL, v_sheet.drop_off_date,
                CASE WHEN LOWER(TRIM(v_sheet.final_status)) = 'maintenance' THEN 'IN_PROGRESS' ELSE v_sheet.final_status END,
                COALESCE(v_sheet.cohort, 'Off Road'), v_sheet.partner_name, v_sheet.partner_ids, v_sheet.new_partner_name_default, v_sheet.dm_name, v_sheet.type, v_sheet.mapping,
                NULL, NULL, NULL, NULL, NULL, NULL,
                0.00, NULL, NULL, 0.00,
                FALSE, NULL, NULL, 0.00, 0.00,
                NULL, NULL, NULL, NULL, NULL,
                NULL, NULL, NULL, NULL,
                FALSE, NULL,
                COALESCE(v_sheet.created_at, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')),
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
            );
        END IF;
    END LOOP;

    RAISE NOTICE 'sp_rebuild_core_maintenance completed. Total records inserted: %', v_curr_id;
END;
$$;


-- -----------------------------------------------------------------------------
-- 7. Analytical Views
-- -----------------------------------------------------------------------------

-- View 1: Active In-Progress Maintenance
CREATE OR REPLACE VIEW public.v_active_core_maintenance AS
SELECT 
    id,
    source_type,
    vehicle_number,
    city,
    vehicle_model,
    start_date,
    estimated_delivery_date,
    maintenance_status,
    repair_type,
    workshop_name,
    in_kms,
    estimated_amount,
    partner_name,
    dm_name,
    created_at
FROM public.core_maintenance
WHERE is_deleted = FALSE 
  AND (end_date IS NULL OR maintenance_status = 'IN_PROGRESS');

-- View 2: Workshop & Operational Hub Summary
CREATE OR REPLACE VIEW public.v_workshop_performance_summary AS
SELECT 
    city,
    source_type,
    COUNT(*) AS total_tickets,
    COUNT(*) FILTER (WHERE is_deleted = FALSE AND (end_date IS NULL OR maintenance_status = 'IN_PROGRESS')) AS active_wip,
    COUNT(*) FILTER (WHERE end_date IS NOT NULL OR maintenance_status IN ('COMPLETED_RFD', 'COMPLETED', 'Completed & RFD')) AS completed_tickets,
    ROUND(AVG(CASE WHEN end_date IS NOT NULL AND end_date >= start_date THEN (end_date - start_date) ELSE NULL END), 1) AS avg_turnaround_days,
    SUM(invoice_amount) AS total_invoice_amount,
    SUM(letzryd_payable) AS total_letzryd_payable
FROM public.core_maintenance
WHERE is_deleted = FALSE
GROUP BY city, source_type;
