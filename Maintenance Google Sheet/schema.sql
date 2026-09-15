-- ==============================================================================
-- LETZRYD MAINTENANCE ENGINE - POSTGRESQL SCHEMA DDL & EXTRACTION PIPELINE
-- ==============================================================================
-- Target Database : postgres
-- Target Schema   : public
-- Source Table    : public.sheet_vehicle_status (Daily manual tracker / attendance log)
-- Staging Table   : public.sheet_maintenance (Dedicated maintenance downtime staging)
-- Core Target     : public.core_maintenance (Consolidated maintenance master)
-- Host            : YOUR_DB_HOST_HERE:5432
-- Description     : Schema definition for sheet_maintenance, automated extraction
--                   trigger from sheet_vehicle_status, batch backfill procedure,
--                   performance indexes, and verification audit queries.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. BASELINE SOURCE TABLE: public.sheet_vehicle_status
-- Ensures the upstream daily vehicle tracker table exists for trigger binding.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sheet_vehicle_status (
    id BIGSERIAL PRIMARY KEY,
    status_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(20),
    final_status VARCHAR(50) NOT NULL,
    cohort VARCHAR(50) NOT NULL DEFAULT 'In Yard',
    partner_id VARCHAR(50),
    partner_name VARCHAR(150),
    partner_phone VARCHAR(20),
    dm_name VARCHAR(100),
    hub_name VARCHAR(100),
    vehicle_model VARCHAR(100),
    workshop_name VARCHAR(150),
    job_card_number VARCHAR(100),
    maintenance_reason TEXT,
    sheet_row_number INTEGER,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_sheet_vehicle_status UNIQUE (status_date, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_svs_status_date ON public.sheet_vehicle_status (status_date DESC);
CREATE INDEX IF NOT EXISTS idx_svs_vehicle_num ON public.sheet_vehicle_status (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_svs_final_status ON public.sheet_vehicle_status (final_status);
CREATE INDEX IF NOT EXISTS idx_svs_cohort ON public.sheet_vehicle_status (cohort);

-- ------------------------------------------------------------------------------
-- 2. TARGET TABLE: public.sheet_maintenance
-- Dedicated staging table isolating maintenance downtime records.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sheet_maintenance (
    id BIGSERIAL PRIMARY KEY,
    city VARCHAR(20),
    vehicle_number VARCHAR(20) NOT NULL,
    date DATE NOT NULL,
    allocation_date DATE,
    drop_off_date DATE,
    final_status VARCHAR(50) NOT NULL DEFAULT 'Maintenance',
    cohort VARCHAR(50) DEFAULT 'Off Road',
    mapping VARCHAR(100),
    partner_name VARCHAR(150),
    partner_ids VARCHAR(50),
    new_partner_name_default VARCHAR(150),
    vehicle_model VARCHAR(100),
    dm_name VARCHAR(100),
    type VARCHAR(50),
    sheet_row_number INTEGER,
    source_tab VARCHAR(50) DEFAULT 'Daily Vehicle Status',
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    extra_attributes JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    CONSTRAINT uq_sheet_maintenance UNIQUE (vehicle_number, date)
);

-- ------------------------------------------------------------------------------
-- 3. PERFORMANCE B-TREE INDEXES
-- Optimized for high-throughput upserts, date-range filtering, and Hisaab joins.
-- ------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_sheet_maint_veh_date 
    ON public.sheet_maintenance (vehicle_number, maintenance_date DESC);

CREATE INDEX IF NOT EXISTS idx_sheet_maint_date 
    ON public.sheet_maintenance (maintenance_date DESC);

CREATE INDEX IF NOT EXISTS idx_sheet_maint_city 
    ON public.sheet_maintenance (city);

CREATE INDEX IF NOT EXISTS idx_sheet_maint_workshop 
    ON public.sheet_maintenance (workshop_name);

CREATE INDEX IF NOT EXISTS idx_sheet_maint_jobcard 
    ON public.sheet_maintenance (job_card_number);

CREATE INDEX IF NOT EXISTS idx_sheet_maint_partner 
    ON public.sheet_maintenance (partner_id);

CREATE INDEX IF NOT EXISTS idx_sheet_maint_dm 
    ON public.sheet_maintenance (dm_name);

CREATE INDEX IF NOT EXISTS idx_sheet_maint_status_id 
    ON public.sheet_maintenance (sheet_status_id);

CREATE INDEX IF NOT EXISTS idx_sheet_maint_cohort 
    ON public.sheet_maintenance (cohort);

-- ------------------------------------------------------------------------------
-- 4. AUTOMATED EXTRACTION TRIGGER FUNCTION: fn_extract_maintenance_from_sheet_status()
-- Filters: final_status IN ('Maintenance', 'Workshop', 'Accidental', 'BD') OR cohort = 'Off Road'
-- Performs zero-burn idempotent upserts into public.sheet_maintenance.
-- Handles updates where status transitions away from maintenance by removing stale records.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_extract_maintenance_from_sheet_status()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_vehicle VARCHAR(20);
    v_clean_city VARCHAR(20);
    v_clean_workshop VARCHAR(150);
    v_clean_job_card VARCHAR(100);
    v_clean_reason TEXT;
    v_clean_partner VARCHAR(50);
    v_clean_dm VARCHAR(100);
    v_clean_model VARCHAR(100);
    v_clean_cohort VARCHAR(50);
    v_is_maintenance BOOLEAN;
    v_was_maintenance BOOLEAN;
BEGIN
    -- Handle DELETE operation
    IF (TG_OP = 'DELETE') THEN
        DELETE FROM public.sheet_maintenance
        WHERE sheet_status_id = OLD.id
           OR (maintenance_date = OLD.status_date AND vehicle_number = UPPER(TRIM(OLD.vehicle_number)));
        RETURN OLD;
    END IF;

    -- Evaluate whether NEW row qualifies as maintenance downtime
    v_is_maintenance := (
        UPPER(TRIM(COALESCE(NEW.final_status, ''))) IN ('MAINTENANCE', 'WORKSHOP', 'ACCIDENTAL', 'BD')
        OR UPPER(TRIM(COALESCE(NEW.cohort, ''))) = 'OFF ROAD'
    );

    IF (TG_OP = 'UPDATE') THEN
        v_was_maintenance := (
            UPPER(TRIM(COALESCE(OLD.final_status, ''))) IN ('MAINTENANCE', 'WORKSHOP', 'ACCIDENTAL', 'BD')
            OR UPPER(TRIM(COALESCE(OLD.cohort, ''))) = 'OFF ROAD'
        );

        -- If row transitioned away from maintenance, remove the downtime staging record
        IF (v_was_maintenance AND NOT v_is_maintenance) THEN
            DELETE FROM public.sheet_maintenance
            WHERE sheet_status_id = OLD.id
               OR (maintenance_date = OLD.status_date AND vehicle_number = UPPER(TRIM(OLD.vehicle_number)));
            RETURN NEW;
        END IF;
    END IF;

    -- If row qualifies as maintenance, sanitize fields and upsert
    IF (v_is_maintenance) THEN
        -- Normalize vehicle registration plate
        v_clean_vehicle := UPPER(REGEXP_REPLACE(COALESCE(NEW.vehicle_number, ''), '[^a-zA-Z0-9]', '', 'g'));

        -- Skip if vehicle number is invalid
        IF (LENGTH(v_clean_vehicle) < 6) THEN
            RETURN NEW;
        END IF;

        -- Normalize city
        v_clean_city := TRIM(COALESCE(NEW.city, ''));
        IF (v_clean_city = '' OR UPPER(v_clean_city) IN ('NA', 'N/A', '-', 'UNKNOWN')) THEN
            IF (v_clean_vehicle ~ '^KA') THEN v_clean_city := 'Bengaluru';
            ELSIF (v_clean_vehicle ~ '^(TS|TG)') THEN v_clean_city := 'Hyderabad';
            ELSIF (v_clean_vehicle ~ '^MH') THEN v_clean_city := 'Mumbai';
            ELSIF (v_clean_vehicle ~ '^DL') THEN v_clean_city := 'Delhi';
            ELSIF (v_clean_vehicle ~ '^TN') THEN v_clean_city := 'Chennai';
            ELSE v_clean_city := 'Unknown';
            END IF;
        END IF;

        -- Sanitize workshop name (strip placeholders)
        v_clean_workshop := TRIM(COALESCE(NEW.workshop_name, ''));
        IF (UPPER(v_clean_workshop) IN ('-', 'NA', 'N/A', 'NONE', 'NULL', 'LOCAL WORKSHOP', 'LOCAL', 'TBD', '.', 'UNKNOWN', 'NO')) THEN
            v_clean_workshop := NULL;
        END IF;

        -- Sanitize job card number (strip placeholders)
        v_clean_job_card := TRIM(COALESCE(NEW.job_card_number, ''));
        IF (UPPER(v_clean_job_card) IN ('-', 'NA', 'N/A', 'NONE', 'NULL', 'PENDING', 'TBD', '.', 'NO', 'NIL')) THEN
            v_clean_job_card := NULL;
        END IF;

        -- Sanitize maintenance reason
        v_clean_reason := NULLIF(TRIM(COALESCE(NEW.maintenance_reason, '')), '');

        -- Cohort default
        v_clean_cohort := COALESCE(NULLIF(TRIM(NEW.cohort), ''), 'Off Road');

        -- Sanitize Partner ID (handle IP operator retention)
        v_clean_partner := NULLIF(TRIM(COALESCE(NEW.partner_id, '')), '');
        IF (v_clean_partner IS NOT NULL AND UPPER(v_clean_partner) IN ('-', 'NA', 'N/A', 'NONE', 'NULL', 'UNKNOWN')) THEN
            v_clean_partner := NULL;
        END IF;

        -- Sanitize Duty Manager / POC name
        v_clean_dm := NULLIF(TRIM(COALESCE(NEW.dm_name, '')), '');
        IF (v_clean_dm IS NOT NULL AND UPPER(v_clean_dm) IN ('-', 'NA', 'N/A', 'NONE', 'NULL', 'UNKNOWN')) THEN
            v_clean_dm := NULL;
        END IF;

        -- Sanitize vehicle model
        v_clean_model := NULLIF(TRIM(COALESCE(NEW.vehicle_model, '')), '');
        IF (v_clean_model IS NOT NULL AND UPPER(v_clean_model) IN ('-', 'NA', 'N/A', 'NONE', 'NULL', 'UNKNOWN')) THEN
            v_clean_model := NULL;
        END IF;

        -- Upsert into public.sheet_maintenance
        INSERT INTO public.sheet_maintenance (
            city, vehicle_number, date, allocation_date, drop_off_date,
            final_status, cohort, mapping, partner_name, partner_ids,
            new_partner_name_default, vehicle_model, dm_name, type,
            sheet_row_number, source_tab, created_at, updated_at
        ) VALUES (
            v_clean_city,
            v_clean_vehicle,
            NEW.status_date,
            NEW.allocation_date,
            NEW.dropoff_date,
            NEW.final_status,
            COALESCE(NEW.cohort, 'Off Road'),
            NEW.mapping_key,
            NEW.partner_name,
            NEW.partner_id,
            NEW.new_partner_name,
            NEW.vehicle_model,
            NEW.dm_name,
            NEW.vehicle_type,
            NEW.sheet_row_number,
            'Daily Vehicle Status',
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        )
        ON CONFLICT (vehicle_number, date)
        DO UPDATE SET
            city = EXCLUDED.city,
            allocation_date = EXCLUDED.allocation_date,
            drop_off_date = EXCLUDED.drop_off_date,
            final_status = EXCLUDED.final_status,
            cohort = EXCLUDED.cohort,
            mapping = EXCLUDED.mapping,
            partner_name = EXCLUDED.partner_name,
            partner_ids = EXCLUDED.partner_ids,
            new_partner_name_default = EXCLUDED.new_partner_name_default,
            vehicle_model = EXCLUDED.vehicle_model,
            dm_name = EXCLUDED.dm_name,
            type = EXCLUDED.type,
            sheet_row_number = EXCLUDED.sheet_row_number,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------------------------
-- 5. TRIGGER DEFINITION: trg_extract_maintenance_from_sheet_status
-- Executes on INSERT, UPDATE, or DELETE on public.sheet_vehicle_status.
-- ------------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_extract_maintenance_from_sheet_status ON public.sheet_vehicle_status;

CREATE TRIGGER trg_extract_maintenance_from_sheet_status
    AFTER INSERT OR UPDATE OR DELETE ON public.sheet_vehicle_status
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_extract_maintenance_from_sheet_status();

-- ------------------------------------------------------------------------------
-- 6. BATCH BACKFILL PROCEDURE: sp_extract_all_sheet_maintenance()
-- Performs a complete historical extraction from sheet_vehicle_status into
-- sheet_maintenance, applying all standardization and deduplication rules.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_extract_all_sheet_maintenance()
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_rows_inserted INTEGER := 0;
BEGIN
    INSERT INTO public.sheet_maintenance (
        city, vehicle_number, date, allocation_date, drop_off_date,
        final_status, cohort, mapping, partner_name, partner_ids,
        new_partner_name_default, vehicle_model, dm_name, type,
        sheet_row_number, source_tab, created_at, updated_at
    )
    SELECT 
        CASE 
            WHEN TRIM(COALESCE(s.city, '')) NOT IN ('', 'NA', 'N/A', '-', 'UNKNOWN') THEN TRIM(s.city)
            WHEN UPPER(REGEXP_REPLACE(s.vehicle_number, '[^a-zA-Z0-9]', '', 'g')) ~ '^KA' THEN 'Bengaluru'
            WHEN UPPER(REGEXP_REPLACE(s.vehicle_number, '[^a-zA-Z0-9]', '', 'g')) ~ '^(TS|TG)' THEN 'Hyderabad'
            WHEN UPPER(REGEXP_REPLACE(s.vehicle_number, '[^a-zA-Z0-9]', '', 'g')) ~ '^MH' THEN 'Mumbai'
            WHEN UPPER(REGEXP_REPLACE(s.vehicle_number, '[^a-zA-Z0-9]', '', 'g')) ~ '^DL' THEN 'Delhi'
            ELSE 'Bengaluru'
        END AS city,
        UPPER(REGEXP_REPLACE(s.vehicle_number, '[^a-zA-Z0-9]', '', 'g')) AS vehicle_number,
        s.status_date AS date,
        s.allocation_date,
        s.dropoff_date AS drop_off_date,
        s.final_status,
        COALESCE(s.cohort, 'Off Road') AS cohort,
        s.mapping_key AS mapping,
        s.partner_name,
        s.partner_id AS partner_ids,
        s.new_partner_name AS new_partner_name_default,
        s.vehicle_model,
        s.dm_name,
        s.vehicle_type AS type,
        s.sheet_row_number,
        'Daily Vehicle Status' AS source_tab,
        (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') AS created_at,
        (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') AS updated_at
    FROM public.sheet_vehicle_status s
    WHERE UPPER(TRIM(COALESCE(s.final_status, ''))) = 'MAINTENANCE'
      AND LENGTH(REGEXP_REPLACE(s.vehicle_number, '[^a-zA-Z0-9]', '', 'g')) >= 6
      AND NOT EXISTS (
          SELECT 1 FROM public.sheet_maintenance sm 
          WHERE sm.vehicle_number = UPPER(REGEXP_REPLACE(s.vehicle_number, '[^a-zA-Z0-9]', '', 'g'))
            AND sm.date = s.status_date
      )
    ON CONFLICT (vehicle_number, date) DO NOTHING;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    RAISE NOTICE 'Batch extraction complete: % records inserted into public.sheet_maintenance.', v_rows_inserted;
END;
$procedure$;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    RAISE NOTICE 'Batch extraction complete: % records processed into public.sheet_maintenance.', v_rows_processed;
END;
$procedure$;

-- ------------------------------------------------------------------------------
-- 7. OPERATIONAL VERIFICATION & AUDIT QUERIES
-- ------------------------------------------------------------------------------
-- Total extracted maintenance records
-- SELECT COUNT(*) AS total_maintenance_records,
--        MIN(maintenance_date) AS earliest_date,
--        MAX(maintenance_date) AS latest_date
-- FROM public.sheet_maintenance;

-- Breakdown by city and cohort
-- SELECT city, cohort, COUNT(*) AS volume
-- FROM public.sheet_maintenance
-- GROUP BY city, cohort
-- ORDER BY volume DESC;

-- Workshop workload distribution
-- SELECT COALESCE(workshop_name, 'UNSPECIFIED_WORKSHOP') AS workshop,
--        COUNT(*) AS total_downtime_days,
--        COUNT(DISTINCT vehicle_number) AS unique_vehicles
-- FROM public.sheet_maintenance
-- GROUP BY workshop_name
-- ORDER BY total_downtime_days DESC;

-- Job card coverage audit
-- SELECT 
--     COUNT(*) AS total_records,
--     COUNT(job_card_number) AS records_with_job_card,
--     COUNT(*) - COUNT(job_card_number) AS records_missing_job_card,
--     ROUND((COUNT(job_card_number)::NUMERIC / COUNT(*)) * 100, 2) AS job_card_coverage_pct
-- FROM public.sheet_maintenance;

-- IP Operator vehicle maintenance audit (driver retained during workshop visit)
-- SELECT vehicle_number, maintenance_date, partner_id, workshop_name, maintenance_reason
-- FROM public.sheet_maintenance
-- WHERE UPPER(partner_id) LIKE '%IP%'
-- ORDER BY maintenance_date DESC
-- LIMIT 25;
