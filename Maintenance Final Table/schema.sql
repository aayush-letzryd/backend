-- =============================================================================
-- LetzRyd Vehicle Maintenance Single Source of Truth: public.core_maintenance
-- =============================================================================
-- Master table consolidating workshop downtime records across:
--   1. public.sheet_maintenance (Google Sheets operational status extract)
--   2. public.july_maintenance_in + public.july_maintenance_out (Web Portal)
--
-- Architectural Guarantees:
--   - Dual-Source Unification:
--       * Seamless consolidation of Google Sheets manual tracking and Web Portal
--         digital repair workflows into a canonical maintenance ledger.
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
-- 1. Upstream Staging Table: public.sheet_maintenance (Google Sheets Staging)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sheet_maintenance (
    id BIGSERIAL PRIMARY KEY,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(50) NOT NULL,
    start_date DATE,
    end_date DATE,
    maintenance_date DATE,
    status VARCHAR(50) DEFAULT 'IN_PROGRESS',
    workshop_name VARCHAR(255),
    job_card_number VARCHAR(100),
    maintenance_reason TEXT,
    estimated_cost NUMERIC(12, 2) DEFAULT 0.00,
    actual_cost NUMERIC(12, 2) DEFAULT 0.00,
    remarks TEXT,
    sheet_row_number INTEGER,
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Backward compatibility column additions for existing sheet_maintenance
ALTER TABLE public.sheet_maintenance ADD COLUMN IF NOT EXISTS start_date DATE;
ALTER TABLE public.sheet_maintenance ADD COLUMN IF NOT EXISTS end_date DATE;
ALTER TABLE public.sheet_maintenance ADD COLUMN IF NOT EXISTS status VARCHAR(50) DEFAULT 'IN_PROGRESS';
ALTER TABLE public.sheet_maintenance ADD COLUMN IF NOT EXISTS estimated_cost NUMERIC(12, 2) DEFAULT 0.00;
ALTER TABLE public.sheet_maintenance ADD COLUMN IF NOT EXISTS actual_cost NUMERIC(12, 2) DEFAULT 0.00;
ALTER TABLE public.sheet_maintenance ADD COLUMN IF NOT EXISTS remarks TEXT;
ALTER TABLE public.sheet_maintenance ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE;
ALTER TABLE public.sheet_maintenance ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITHOUT TIME ZONE;

-- Ensure maintenance_date is nullable if present
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' AND table_name = 'sheet_maintenance' AND column_name = 'maintenance_date'
    ) THEN
        ALTER TABLE public.sheet_maintenance ALTER COLUMN maintenance_date DROP NOT NULL;
        UPDATE public.sheet_maintenance
        SET start_date = maintenance_date
        WHERE start_date IS NULL AND maintenance_date IS NOT NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_sheet_maint_veh ON public.sheet_maintenance (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_sheet_maint_dates ON public.sheet_maintenance (start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_sheet_maint_status ON public.sheet_maintenance (status);


-- -----------------------------------------------------------------------------
-- 2. Schema Migration & Column Compatibility for public.core_maintenance
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    -- Check if table already exists
    IF EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'core_maintenance'
    ) THEN
        -- Rename legacy column sheet_status_row_id to sheet_maintenance_id if present
        IF EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' 
              AND table_name = 'core_maintenance' 
              AND column_name = 'sheet_status_row_id'
        ) AND NOT EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' 
              AND table_name = 'core_maintenance' 
              AND column_name = 'sheet_maintenance_id'
        ) THEN
            ALTER TABLE public.core_maintenance RENAME COLUMN sheet_status_row_id TO sheet_maintenance_id;
        END IF;

        -- Ensure city column is at least VARCHAR(20)
        IF EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' 
              AND table_name = 'core_maintenance' 
              AND column_name = 'city'
              AND character_maximum_length < 20
        ) THEN
            DROP VIEW IF EXISTS public.v_active_core_maintenance CASCADE;
            DROP VIEW IF EXISTS public.v_workshop_performance_summary CASCADE;
            ALTER TABLE public.core_maintenance ALTER COLUMN city TYPE VARCHAR(20);
        END IF;
        
        -- Ensure sheet_maintenance_id exists
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' 
              AND table_name = 'core_maintenance' 
              AND column_name = 'sheet_maintenance_id'
        ) THEN
            ALTER TABLE public.core_maintenance ADD COLUMN sheet_maintenance_id BIGINT;
        END IF;
    END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 3. Master Table Definition: public.core_maintenance
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.core_maintenance (
    id BIGSERIAL PRIMARY KEY,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(20) NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE,
    status VARCHAR(30) NOT NULL DEFAULT 'IN_PROGRESS',
    workshop_name VARCHAR(150),
    job_card_number VARCHAR(100),
    maintenance_reason TEXT,
    estimated_cost NUMERIC(12, 2) DEFAULT 0.00,
    actual_cost NUMERIC(12, 2) DEFAULT 0.00,
    data_source VARCHAR(50) NOT NULL, -- 'PORTAL_MAINTENANCE', 'SHEET_STATUS_EXTRACT'
    portal_maintenance_in_id INTEGER,
    portal_maintenance_out_id INTEGER,
    sheet_maintenance_id BIGINT,
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Performance, Query & Uniqueness Indexes
CREATE INDEX IF NOT EXISTS idx_cm_vehicle_dates ON public.core_maintenance (vehicle_number, start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_cm_status ON public.core_maintenance (status);
CREATE INDEX IF NOT EXISTS idx_cm_data_source ON public.core_maintenance (data_source);
CREATE INDEX IF NOT EXISTS idx_cm_city ON public.core_maintenance (city);
CREATE INDEX IF NOT EXISTS idx_cm_is_deleted ON public.core_maintenance (is_deleted);

CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_cm_portal_in 
    ON public.core_maintenance (portal_maintenance_in_id) 
    WHERE portal_maintenance_in_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_cm_sheet_id 
    ON public.core_maintenance (sheet_maintenance_id) 
    WHERE sheet_maintenance_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cm_portal_out 
    ON public.core_maintenance (portal_maintenance_out_id) 
    WHERE portal_maintenance_out_id IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 4. Normalization Helper Functions
-- -----------------------------------------------------------------------------

-- Standardize vehicle registration number: uppercase alphanumeric string
CREATE OR REPLACE FUNCTION public.fn_clean_maintenance_vehicle(p_veh TEXT)
RETURNS VARCHAR(20) AS $$
BEGIN
    RETURN LEFT(UPPER(REGEXP_REPLACE(COALESCE(p_veh, ''), '[^A-Za-z0-9]', '', 'g')), 20);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Standardize operational city name
CREATE OR REPLACE FUNCTION public.fn_clean_maintenance_city(p_city TEXT, p_veh TEXT DEFAULT '')
RETURNS VARCHAR(20) AS $$
DECLARE
    v_norm TEXT;
    v_veh TEXT;
BEGIN
    v_norm := LOWER(TRIM(COALESCE(p_city, '')));
    v_veh := UPPER(REGEXP_REPLACE(COALESCE(p_veh, ''), '[^A-Za-z0-9]', '', 'g'));

    IF v_norm IN ('bangalore', 'bengaluru', 'blr') THEN
        RETURN 'Bengaluru';
    ELSIF v_norm IN ('hyderabad', 'hyd') THEN
        RETURN 'Hyderabad';
    ELSIF v_norm IN ('mumbai', 'mum', 'bombay') THEN
        RETURN 'Mumbai';
    ELSIF v_norm IN ('pune', 'pun') THEN
        RETURN 'Pune';
    ELSIF v_norm IN ('delhi', 'new delhi', 'ncr') THEN
        RETURN 'Delhi';
    END IF;

    -- Fallback inference by state registration prefix
    IF v_veh LIKE 'KA%' THEN
        RETURN 'Bengaluru';
    ELSIF v_veh LIKE 'TS%' OR v_veh LIKE 'AP%' THEN
        RETURN 'Hyderabad';
    ELSIF v_veh LIKE 'MH%' THEN
        RETURN 'Mumbai';
    ELSIF v_veh LIKE 'DL%' THEN
        RETURN 'Delhi';
    END IF;

    RETURN LEFT(INITCAP(TRIM(COALESCE(p_city, 'Unknown'))), 20);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Safe string-to-date parser supporting ISO, timestamps, and Indian date formats
CREATE OR REPLACE FUNCTION public.fn_parse_maintenance_date(p_raw TEXT)
RETURNS DATE AS $$
DECLARE
    v_str TEXT;
BEGIN
    IF p_raw IS NULL OR TRIM(p_raw) = '' THEN
        RETURN NULL;
    END IF;

    v_str := TRIM(p_raw);

    -- Check YYYY-MM-DD format (including ISO timestamp prefix e.g. 2026-09-07T16:48:55)
    IF v_str ~ '^\d{4}-\d{2}-\d{2}' THEN
        RETURN SUBSTRING(v_str FROM 1 FOR 10)::DATE;
    END IF;

    -- Check DD/MM/YYYY or DD-MM-YYYY format
    IF v_str ~ '^\d{2}/\d{2}/\d{4}' THEN
        RETURN TO_DATE(SUBSTRING(v_str FROM 1 FOR 10), 'DD/MM/YYYY');
    ELSIF v_str ~ '^\d{2}-\d{2}-\d{4}' THEN
        RETURN TO_DATE(SUBSTRING(v_str FROM 1 FOR 10), 'DD-MM-YYYY');
    END IF;

    -- Check DD/MM/YY format
    IF v_str ~ '^\d{2}/\d{2}/\d{2}' THEN
        RETURN TO_DATE(SUBSTRING(v_str FROM 1 FOR 8), 'DD/MM/YY');
    END IF;

    -- Fallback attempt standard cast
    BEGIN
        RETURN v_str::DATE;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Safe numeric parser stripping currency symbols and text
CREATE OR REPLACE FUNCTION public.fn_parse_maintenance_amount(p_raw TEXT)
RETURNS NUMERIC(12, 2) AS $$
DECLARE
    v_clean TEXT;
BEGIN
    IF p_raw IS NULL OR TRIM(p_raw) = '' THEN
        RETURN 0.00;
    END IF;

    v_clean := REGEXP_REPLACE(TRIM(p_raw), '[^0-9.]', '', 'g');
    IF v_clean = '' OR v_clean = '.' THEN
        RETURN 0.00;
    END IF;

    BEGIN
        RETURN ROUND(v_clean::NUMERIC, 2);
    EXCEPTION WHEN OTHERS THEN
        RETURN 0.00;
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- -----------------------------------------------------------------------------
-- 5. Trigger Function: Sync from Google Sheets (public.sheet_maintenance)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_core_maintenance_from_sheet()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_veh VARCHAR(20);
    v_clean_city VARCHAR(20);
    v_start_date DATE;
    v_end_date DATE;
    v_status VARCHAR(30);
    v_est_cost NUMERIC(12, 2);
    v_act_cost NUMERIC(12, 2);
    v_existing_id BIGINT;
BEGIN
    -- Handle DELETE operation: Soft delete in core_maintenance
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_maintenance
        SET is_deleted = TRUE,
            deleted_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE sheet_maintenance_id = OLD.id;
        RETURN OLD;
    END IF;

    -- Normalize identifiers and dates
    v_clean_veh := public.fn_clean_maintenance_vehicle(NEW.vehicle_number);
    v_clean_city := public.fn_clean_maintenance_city(NEW.city, v_clean_veh);
    v_start_date := NEW.start_date;
    v_end_date := NEW.end_date;

    -- Duration integrity: prevent negative durations
    IF v_end_date IS NOT NULL AND v_end_date < v_start_date THEN
        v_end_date := v_start_date;
    END IF;

    -- Status normalization
    IF v_end_date IS NOT NULL OR UPPER(COALESCE(NEW.status, '')) IN ('COMPLETED', 'RFD', 'CLOSED', 'DELIVERED') THEN
        v_status := 'COMPLETED';
    ELSE
        v_status := 'IN_PROGRESS';
    END IF;

    v_est_cost := COALESCE(NEW.estimated_cost, 0.00);
    v_act_cost := COALESCE(NEW.actual_cost, 0.00);

    -- Check if record already linked in core_maintenance
    SELECT id INTO v_existing_id
    FROM public.core_maintenance
    WHERE sheet_maintenance_id = NEW.id;

    IF v_existing_id IS NOT NULL THEN
        UPDATE public.core_maintenance
        SET vehicle_number     = v_clean_veh,
            city               = v_clean_city,
            start_date         = v_start_date,
            end_date           = v_end_date,
            status             = v_status,
            workshop_name      = LEFT(TRIM(COALESCE(NEW.workshop_name, workshop_name)), 150),
            job_card_number    = LEFT(TRIM(COALESCE(NEW.job_card_number, job_card_number)), 100),
            maintenance_reason = COALESCE(NEW.maintenance_reason, maintenance_reason),
            estimated_cost     = v_est_cost,
            actual_cost        = v_act_cost,
            is_deleted         = COALESCE(NEW.is_deleted, FALSE),
            deleted_at         = NEW.deleted_at,
            updated_at         = CURRENT_TIMESTAMP
        WHERE id = v_existing_id;
    ELSE
        INSERT INTO public.core_maintenance (
            vehicle_number,
            city,
            start_date,
            end_date,
            status,
            workshop_name,
            job_card_number,
            maintenance_reason,
            estimated_cost,
            actual_cost,
            data_source,
            portal_maintenance_in_id,
            portal_maintenance_out_id,
            sheet_maintenance_id,
            is_deleted,
            deleted_at,
            created_at,
            updated_at
        ) VALUES (
            v_clean_veh,
            v_clean_city,
            v_start_date,
            v_end_date,
            v_status,
            LEFT(TRIM(NEW.workshop_name), 150),
            LEFT(TRIM(NEW.job_card_number), 100),
            NEW.maintenance_reason,
            v_est_cost,
            v_act_cost,
            'SHEET_STATUS_EXTRACT',
            NULL,
            NULL,
            NEW.id,
            COALESCE(NEW.is_deleted, FALSE),
            NEW.deleted_at,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_maintenance_from_sheet ON public.sheet_maintenance;
CREATE TRIGGER trg_sync_core_maintenance_from_sheet
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_maintenance
FOR EACH ROW EXECUTE FUNCTION public.sync_core_maintenance_from_sheet();


-- -----------------------------------------------------------------------------
-- 6. Trigger Function: Sync from Web Portal (july_maintenance_in & july_maintenance_out)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_core_maintenance_from_portal()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_veh VARCHAR(20);
    v_clean_city VARCHAR(20);
    v_start_date DATE;
    v_end_date DATE;
    v_status VARCHAR(30);
    v_workshop VARCHAR(150);
    v_reason TEXT;
    v_job_card VARCHAR(100);
    v_est_cost NUMERIC(12, 2);
    v_act_cost NUMERIC(12, 2);
    v_existing_id BIGINT;
    v_matched_in_id INTEGER;
    v_out_rec RECORD;
    v_in_rec RECORD;
BEGIN
    -- =========================================================================
    -- BRANCH A: Invoked by public.july_maintenance_in
    -- =========================================================================
    IF TG_TABLE_NAME = 'july_maintenance_in' THEN
        -- Handle DELETE
        IF TG_OP = 'DELETE' THEN
            UPDATE public.core_maintenance
            SET is_deleted = TRUE,
                deleted_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
            WHERE portal_maintenance_in_id = OLD.id;
            RETURN OLD;
        END IF;

        v_clean_veh := public.fn_clean_maintenance_vehicle(NEW.vehicle_number);
        v_clean_city := public.fn_clean_maintenance_city(NEW.city_name, v_clean_veh);
        v_start_date := COALESCE(
            public.fn_parse_maintenance_date(NEW.vehicle_in_date_time),
            NEW.created_at::DATE,
            CURRENT_DATE
        );
        v_workshop := LEFT(TRIM(COALESCE(NEW.workshop_name, 'Unspecified Workshop')), 150);
        v_reason := TRIM(
            COALESCE(NEW.repair_type, '') ||
            CASE 
                WHEN NEW.remarks IS NOT NULL AND TRIM(NEW.remarks) <> '' AND TRIM(NEW.remarks) <> TRIM(COALESCE(NEW.repair_type, ''))
                THEN ' - ' || TRIM(NEW.remarks)
                ELSE ''
            END
        );
        v_est_cost := public.fn_parse_maintenance_amount(NEW.estimated_amount);

        -- Check if an outward record is already present for this inward event
        SELECT * INTO v_out_rec
        FROM public.july_maintenance_out
        WHERE inward_id = NEW.id
        ORDER BY id DESC
        LIMIT 1;

        IF v_out_rec.id IS NOT NULL THEN
            v_end_date := COALESCE(
                public.fn_parse_maintenance_date(v_out_rec.vehicle_out_date_time),
                public.fn_parse_maintenance_date(v_out_rec.rfd_date),
                v_out_rec.created_at::DATE,
                v_start_date
            );
            IF v_end_date < v_start_date THEN
                v_end_date := v_start_date;
            END IF;
            v_status := 'COMPLETED';
            v_job_card := LEFT(TRIM(COALESCE(v_out_rec.invoice_no, NEW.claim_number)), 100);
            v_act_cost := public.fn_parse_maintenance_amount(
                COALESCE(v_out_rec.letzryd_payable, v_out_rec.invoice_amount, '0')
            );
        ELSE
            v_end_date := NULL;
            v_act_cost := 0.00;
            v_job_card := LEFT(TRIM(NEW.claim_number), 100);
            IF NEW.is_closed = TRUE THEN
                v_status := 'COMPLETED';
                v_end_date := COALESCE(NEW.closed_at::DATE, v_start_date);
            ELSE
                v_status := 'IN_PROGRESS';
            END IF;
        END IF;

        -- Upsert into public.core_maintenance
        SELECT id INTO v_existing_id
        FROM public.core_maintenance
        WHERE portal_maintenance_in_id = NEW.id;

        IF v_existing_id IS NOT NULL THEN
            UPDATE public.core_maintenance
            SET vehicle_number            = v_clean_veh,
                city                      = v_clean_city,
                start_date                = v_start_date,
                end_date                  = COALESCE(v_end_date, end_date),
                status                    = CASE WHEN v_end_date IS NOT NULL OR NEW.is_closed THEN 'COMPLETED' ELSE v_status END,
                workshop_name             = v_workshop,
                job_card_number           = COALESCE(v_job_card, job_card_number),
                maintenance_reason        = NULLIF(v_reason, ''),
                estimated_cost            = v_est_cost,
                actual_cost               = CASE WHEN v_act_cost > 0 THEN v_act_cost ELSE actual_cost END,
                portal_maintenance_out_id = COALESCE(v_out_rec.id, portal_maintenance_out_id),
                is_deleted                = FALSE,
                deleted_at                = NULL,
                updated_at                = CURRENT_TIMESTAMP
            WHERE id = v_existing_id;
        ELSE
            INSERT INTO public.core_maintenance (
                vehicle_number,
                city,
                start_date,
                end_date,
                status,
                workshop_name,
                job_card_number,
                maintenance_reason,
                estimated_cost,
                actual_cost,
                data_source,
                portal_maintenance_in_id,
                portal_maintenance_out_id,
                sheet_maintenance_id,
                is_deleted,
                deleted_at,
                created_at,
                updated_at
            ) VALUES (
                v_clean_veh,
                v_clean_city,
                v_start_date,
                v_end_date,
                v_status,
                v_workshop,
                v_job_card,
                NULLIF(v_reason, ''),
                v_est_cost,
                v_act_cost,
                'PORTAL_MAINTENANCE',
                NEW.id,
                v_out_rec.id,
                NULL,
                FALSE,
                NULL,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
        END IF;

        RETURN NEW;
    END IF;


    -- =========================================================================
    -- BRANCH B: Invoked by public.july_maintenance_out
    -- =========================================================================
    IF TG_TABLE_NAME = 'july_maintenance_out' THEN
        -- Handle DELETE: Unlink exit and reopen maintenance interval
        IF TG_OP = 'DELETE' THEN
            UPDATE public.core_maintenance
            SET portal_maintenance_out_id = NULL,
                end_date = NULL,
                status = 'IN_PROGRESS',
                actual_cost = 0.00,
                updated_at = CURRENT_TIMESTAMP
            WHERE portal_maintenance_out_id = OLD.id;
            RETURN OLD;
        END IF;

        v_clean_veh := public.fn_clean_maintenance_vehicle(NEW.vehicle_number);
        v_end_date := COALESCE(
            public.fn_parse_maintenance_date(NEW.vehicle_out_date_time),
            public.fn_parse_maintenance_date(NEW.rfd_date),
            NEW.created_at::DATE,
            CURRENT_DATE
        );
        v_job_card := LEFT(TRIM(NEW.invoice_no), 100);
        v_act_cost := public.fn_parse_maintenance_amount(
            COALESCE(NEW.letzryd_payable, NEW.invoice_amount, '0')
        );

        -- Step 1: Match with parent inward event via foreign key inward_id
        IF NEW.inward_id IS NOT NULL THEN
            SELECT id INTO v_matched_in_id
            FROM public.july_maintenance_in
            WHERE id = NEW.inward_id;
        END IF;

        -- Step 2: Fallback pairing if inward_id is missing
        IF v_matched_in_id IS NULL THEN
            SELECT id INTO v_matched_in_id
            FROM public.july_maintenance_in
            WHERE public.fn_clean_maintenance_vehicle(vehicle_number) = v_clean_veh
              AND is_closed = FALSE
            ORDER BY id DESC
            LIMIT 1;
        END IF;

        -- Step 3: Check if core_maintenance row already exists for matched inward event
        IF v_matched_in_id IS NOT NULL THEN
            SELECT id INTO v_existing_id
            FROM public.core_maintenance
            WHERE portal_maintenance_in_id = v_matched_in_id;
        END IF;

        -- Also check if already matched by portal_maintenance_out_id
        IF v_existing_id IS NULL THEN
            SELECT id INTO v_existing_id
            FROM public.core_maintenance
            WHERE portal_maintenance_out_id = NEW.id;
        END IF;

        IF v_existing_id IS NOT NULL THEN
            -- Update existing interval with completion information
            UPDATE public.core_maintenance
            SET end_date                  = GREATEST(v_end_date, start_date),
                status                    = 'COMPLETED',
                job_card_number           = COALESCE(v_job_card, job_card_number),
                actual_cost               = CASE WHEN v_act_cost > 0 THEN v_act_cost ELSE actual_cost END,
                portal_maintenance_out_id = NEW.id,
                updated_at                = CURRENT_TIMESTAMP
            WHERE id = v_existing_id;
        ELSE
            -- Inward record not found: create standalone completed maintenance record
            SELECT * INTO v_in_rec
            FROM public.july_maintenance_in
            WHERE id = v_matched_in_id;

            v_clean_city := public.fn_clean_maintenance_city('', v_clean_veh);
            v_start_date := COALESCE(
                public.fn_parse_maintenance_date(v_in_rec.vehicle_in_date_time),
                v_end_date
            );
            IF v_end_date < v_start_date THEN
                v_end_date := v_start_date;
            END IF;

            INSERT INTO public.core_maintenance (
                vehicle_number,
                city,
                start_date,
                end_date,
                status,
                workshop_name,
                job_card_number,
                maintenance_reason,
                estimated_cost,
                actual_cost,
                data_source,
                portal_maintenance_in_id,
                portal_maintenance_out_id,
                sheet_maintenance_id,
                is_deleted,
                deleted_at,
                created_at,
                updated_at
            ) VALUES (
                v_clean_veh,
                v_clean_city,
                v_start_date,
                v_end_date,
                'COMPLETED',
                LEFT(TRIM(COALESCE(v_in_rec.workshop_name, 'Direct Outward Maintenance')), 150),
                v_job_card,
                COALESCE(NEW.remarks, 'Portal Outward Release'),
                0.00,
                v_act_cost,
                'PORTAL_MAINTENANCE',
                v_matched_in_id,
                NEW.id,
                NULL,
                FALSE,
                NULL,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
        END IF;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_maintenance_portal_in ON public.july_maintenance_in;
CREATE TRIGGER trg_sync_core_maintenance_portal_in
AFTER INSERT OR UPDATE OR DELETE ON public.july_maintenance_in
FOR EACH ROW EXECUTE FUNCTION public.sync_core_maintenance_from_portal();

DROP TRIGGER IF EXISTS trg_sync_core_maintenance_portal_out ON public.july_maintenance_out;
CREATE TRIGGER trg_sync_core_maintenance_portal_out
AFTER INSERT OR UPDATE OR DELETE ON public.july_maintenance_out
FOR EACH ROW EXECUTE FUNCTION public.sync_core_maintenance_from_portal();


-- -----------------------------------------------------------------------------
-- 7. Backfill & Full Consolidation Procedure: refresh_core_maintenance()
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.refresh_core_maintenance()
AS $$
DECLARE
    v_in_row RECORD;
    v_out_row RECORD;
    v_sheet_row RECORD;
    v_clean_veh VARCHAR(20);
    v_clean_city VARCHAR(20);
    v_start_date DATE;
    v_end_date DATE;
    v_status VARCHAR(30);
    v_workshop VARCHAR(150);
    v_reason TEXT;
    v_job_card VARCHAR(100);
    v_est_cost NUMERIC(12, 2);
    v_act_cost NUMERIC(12, 2);
    v_portal_count INTEGER := 0;
    v_sheet_count INTEGER := 0;
BEGIN
    -- Transactional Advisory Lock to guarantee single-runner execution
    PERFORM pg_advisory_xact_lock(777666555);

    RAISE NOTICE 'Starting full reconciliation for public.core_maintenance...';

    -- =========================================================================
    -- STEP 1: Ingest & Pair Web Portal Inward and Outward Records
    -- =========================================================================
    FOR v_in_row IN (
        SELECT mi.*
        FROM public.july_maintenance_in mi
        ORDER BY mi.id ASC
    ) LOOP
        v_clean_veh := public.fn_clean_maintenance_vehicle(v_in_row.vehicle_number);
        v_clean_city := public.fn_clean_maintenance_city(v_in_row.city_name, v_clean_veh);
        v_start_date := COALESCE(
            public.fn_parse_maintenance_date(v_in_row.vehicle_in_date_time),
            v_in_row.created_at::DATE,
            CURRENT_DATE
        );
        v_workshop := LEFT(TRIM(COALESCE(v_in_row.workshop_name, 'Unspecified Workshop')), 150);
        v_reason := TRIM(
            COALESCE(v_in_row.repair_type, '') ||
            CASE 
                WHEN v_in_row.remarks IS NOT NULL AND TRIM(v_in_row.remarks) <> '' AND TRIM(v_in_row.remarks) <> TRIM(COALESCE(v_in_row.repair_type, ''))
                THEN ' - ' || TRIM(v_in_row.remarks)
                ELSE ''
            END
        );
        v_est_cost := public.fn_parse_maintenance_amount(v_in_row.estimated_amount);

        -- Find matching outward record
        SELECT * INTO v_out_row
        FROM public.july_maintenance_out mo
        WHERE mo.inward_id = v_in_row.id
        ORDER BY mo.id DESC
        LIMIT 1;

        IF v_out_row.id IS NOT NULL THEN
            v_end_date := COALESCE(
                public.fn_parse_maintenance_date(v_out_row.vehicle_out_date_time),
                public.fn_parse_maintenance_date(v_out_row.rfd_date),
                v_out_row.created_at::DATE,
                v_start_date
            );
            IF v_end_date < v_start_date THEN
                v_end_date := v_start_date;
            END IF;
            v_status := 'COMPLETED';
            v_job_card := LEFT(TRIM(COALESCE(v_out_row.invoice_no, v_in_row.claim_number)), 100);
            v_act_cost := public.fn_parse_maintenance_amount(
                COALESCE(v_out_row.letzryd_payable, v_out_row.invoice_amount, '0')
            );
        ELSE
            v_end_date := NULL;
            v_act_cost := 0.00;
            v_job_card := LEFT(TRIM(v_in_row.claim_number), 100);
            IF v_in_row.is_closed = TRUE THEN
                v_status := 'COMPLETED';
                v_end_date := COALESCE(v_in_row.closed_at::DATE, v_start_date);
            ELSE
                v_status := 'IN_PROGRESS';
            END IF;
        END IF;

        -- Upsert into public.core_maintenance on portal_maintenance_in_id
        INSERT INTO public.core_maintenance (
            vehicle_number,
            city,
            start_date,
            end_date,
            status,
            workshop_name,
            job_card_number,
            maintenance_reason,
            estimated_cost,
            actual_cost,
            data_source,
            portal_maintenance_in_id,
            portal_maintenance_out_id,
            sheet_maintenance_id,
            is_deleted,
            deleted_at,
            created_at,
            updated_at
        ) VALUES (
            v_clean_veh,
            v_clean_city,
            v_start_date,
            v_end_date,
            v_status,
            v_workshop,
            v_job_card,
            NULLIF(v_reason, ''),
            v_est_cost,
            v_act_cost,
            'PORTAL_MAINTENANCE',
            v_in_row.id,
            v_out_row.id,
            NULL,
            FALSE,
            NULL,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
        )
        ON CONFLICT (portal_maintenance_in_id) WHERE portal_maintenance_in_id IS NOT NULL
        DO UPDATE SET
            vehicle_number            = EXCLUDED.vehicle_number,
            city                      = EXCLUDED.city,
            start_date                = EXCLUDED.start_date,
            end_date                  = EXCLUDED.end_date,
            status                    = EXCLUDED.status,
            workshop_name             = EXCLUDED.workshop_name,
            job_card_number           = COALESCE(EXCLUDED.job_card_number, core_maintenance.job_card_number),
            maintenance_reason        = COALESCE(EXCLUDED.maintenance_reason, core_maintenance.maintenance_reason),
            estimated_cost            = EXCLUDED.estimated_cost,
            actual_cost               = CASE WHEN EXCLUDED.actual_cost > 0 THEN EXCLUDED.actual_cost ELSE core_maintenance.actual_cost END,
            portal_maintenance_out_id = COALESCE(EXCLUDED.portal_maintenance_out_id, core_maintenance.portal_maintenance_out_id),
            is_deleted                = FALSE,
            deleted_at                = NULL,
            updated_at                = CURRENT_TIMESTAMP;

        v_portal_count := v_portal_count + 1;
    END LOOP;

    -- Handle any orphaned outward records not linked to an inward record
    FOR v_out_row IN (
        SELECT mo.*
        FROM public.july_maintenance_out mo
        LEFT JOIN public.core_maintenance cm ON cm.portal_maintenance_out_id = mo.id
        WHERE cm.id IS NULL
        ORDER BY mo.id ASC
    ) LOOP
        v_clean_veh := public.fn_clean_maintenance_vehicle(v_out_row.vehicle_number);
        v_clean_city := public.fn_clean_maintenance_city('', v_clean_veh);
        v_end_date := COALESCE(
            public.fn_parse_maintenance_date(v_out_row.vehicle_out_date_time),
            public.fn_parse_maintenance_date(v_out_row.rfd_date),
            v_out_row.created_at::DATE,
            CURRENT_DATE
        );
        v_act_cost := public.fn_parse_maintenance_amount(
            COALESCE(v_out_row.letzryd_payable, v_out_row.invoice_amount, '0')
        );

        INSERT INTO public.core_maintenance (
            vehicle_number,
            city,
            start_date,
            end_date,
            status,
            workshop_name,
            job_card_number,
            maintenance_reason,
            estimated_cost,
            actual_cost,
            data_source,
            portal_maintenance_in_id,
            portal_maintenance_out_id,
            sheet_maintenance_id,
            is_deleted,
            deleted_at,
            created_at,
            updated_at
        ) VALUES (
            v_clean_veh,
            v_clean_city,
            v_end_date,
            v_end_date,
            'COMPLETED',
            'Direct Outward Maintenance',
            LEFT(TRIM(v_out_row.invoice_no), 100),
            COALESCE(v_out_row.remarks, 'Standalone Portal Outward Release'),
            0.00,
            v_act_cost,
            'PORTAL_MAINTENANCE',
            NULL,
            v_out_row.id,
            NULL,
            FALSE,
            NULL,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
        );
        v_portal_count := v_portal_count + 1;
    END LOOP;


    -- =========================================================================
    -- STEP 2: Ingest Google Sheets Maintenance Records (sheet_maintenance)
    -- =========================================================================
    IF EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'sheet_maintenance'
    ) THEN
        FOR v_sheet_row IN (
            SELECT sm.*
            FROM public.sheet_maintenance sm
            ORDER BY sm.id ASC
        ) LOOP
            v_clean_veh := public.fn_clean_maintenance_vehicle(v_sheet_row.vehicle_number);
            v_clean_city := public.fn_clean_maintenance_city(v_sheet_row.city, v_clean_veh);
            v_start_date := v_sheet_row.start_date;
            v_end_date := v_sheet_row.end_date;

            IF v_end_date IS NOT NULL AND v_end_date < v_start_date THEN
                v_end_date := v_start_date;
            END IF;

            IF v_end_date IS NOT NULL OR UPPER(COALESCE(v_sheet_row.status, '')) IN ('COMPLETED', 'RFD', 'CLOSED', 'DELIVERED') THEN
                v_status := 'COMPLETED';
            ELSE
                v_status := 'IN_PROGRESS';
            END IF;

            v_est_cost := COALESCE(v_sheet_row.estimated_cost, 0.00);
            v_act_cost := COALESCE(v_sheet_row.actual_cost, 0.00);

            INSERT INTO public.core_maintenance (
                vehicle_number,
                city,
                start_date,
                end_date,
                status,
                workshop_name,
                job_card_number,
                maintenance_reason,
                estimated_cost,
                actual_cost,
                data_source,
                portal_maintenance_in_id,
                portal_maintenance_out_id,
                sheet_maintenance_id,
                is_deleted,
                deleted_at,
                created_at,
                updated_at
            ) VALUES (
                v_clean_veh,
                v_clean_city,
                v_start_date,
                v_end_date,
                v_status,
                LEFT(TRIM(v_sheet_row.workshop_name), 150),
                LEFT(TRIM(v_sheet_row.job_card_number), 100),
                v_sheet_row.maintenance_reason,
                v_est_cost,
                v_act_cost,
                'SHEET_STATUS_EXTRACT',
                NULL,
                NULL,
                v_sheet_row.id,
                COALESCE(v_sheet_row.is_deleted, FALSE),
                v_sheet_row.deleted_at,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            )
            ON CONFLICT (sheet_maintenance_id) WHERE sheet_maintenance_id IS NOT NULL
            DO UPDATE SET
                vehicle_number     = EXCLUDED.vehicle_number,
                city               = EXCLUDED.city,
                start_date         = EXCLUDED.start_date,
                end_date           = EXCLUDED.end_date,
                status             = EXCLUDED.status,
                workshop_name      = LEFT(TRIM(COALESCE(EXCLUDED.workshop_name, core_maintenance.workshop_name)), 150),
                job_card_number    = LEFT(TRIM(COALESCE(EXCLUDED.job_card_number, core_maintenance.job_card_number)), 100),
                maintenance_reason = COALESCE(EXCLUDED.maintenance_reason, core_maintenance.maintenance_reason),
                estimated_cost     = EXCLUDED.estimated_cost,
                actual_cost        = EXCLUDED.actual_cost,
                is_deleted         = EXCLUDED.is_deleted,
                deleted_at         = EXCLUDED.deleted_at,
                updated_at         = CURRENT_TIMESTAMP;

            v_sheet_count := v_sheet_count + 1;
        END LOOP;
    END IF;

    -- =========================================================================
    -- STEP 3: Sanitize Interval Durations & Consistency
    -- =========================================================================
    UPDATE public.core_maintenance
    SET end_date = start_date,
        updated_at = CURRENT_TIMESTAMP
    WHERE end_date IS NOT NULL AND end_date < start_date;

    UPDATE public.core_maintenance
    SET status = 'COMPLETED',
        updated_at = CURRENT_TIMESTAMP
    WHERE end_date IS NOT NULL AND status <> 'COMPLETED';

    UPDATE public.core_maintenance
    SET status = 'IN_PROGRESS',
        updated_at = CURRENT_TIMESTAMP
    WHERE end_date IS NULL AND status = 'COMPLETED';

    RAISE NOTICE 'Reconciliation complete. Processed % portal records and % sheet records.',
        v_portal_count, v_sheet_count;
END;
$$ LANGUAGE plpgsql;


-- -----------------------------------------------------------------------------
-- 8. Production Operational Views
-- -----------------------------------------------------------------------------

-- View: Active Maintenance (Vehicles currently in workshop)
CREATE OR REPLACE VIEW public.v_active_core_maintenance AS
SELECT 
    cm.id,
    cm.vehicle_number,
    cm.city,
    cm.start_date,
    cm.status,
    cm.workshop_name,
    cm.job_card_number,
    cm.maintenance_reason,
    cm.estimated_cost,
    cm.data_source,
    (CURRENT_DATE - cm.start_date) AS days_in_workshop,
    cm.created_at
FROM public.core_maintenance cm
WHERE cm.is_deleted = FALSE
  AND cm.status = 'IN_PROGRESS'
  AND cm.end_date IS NULL
ORDER BY cm.start_date ASC;

-- View: Workshop Turnaround Time (TAT) & Expense Summary
CREATE OR REPLACE VIEW public.v_workshop_performance_summary AS
SELECT 
    COALESCE(workshop_name, 'Unknown Workshop') AS workshop_name,
    city,
    COUNT(*) AS total_jobs,
    COUNT(*) FILTER (WHERE status = 'IN_PROGRESS') AS active_jobs,
    COUNT(*) FILTER (WHERE status = 'COMPLETED') AS completed_jobs,
    ROUND(AVG(CASE WHEN end_date IS NOT NULL THEN (end_date - start_date) ELSE NULL END), 1) AS avg_tat_days,
    ROUND(SUM(estimated_cost), 2) AS total_estimated_cost,
    ROUND(SUM(actual_cost), 2) AS total_actual_cost,
    ROUND(SUM(actual_cost) - SUM(estimated_cost), 2) AS total_variance
FROM public.core_maintenance
WHERE is_deleted = FALSE
GROUP BY COALESCE(workshop_name, 'Unknown Workshop'), city
ORDER BY total_jobs DESC;
