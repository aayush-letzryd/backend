-- =============================================================================
-- GPS Final Table Architecture: public.core_gps
-- Enterprise Fleet Telematics Single Source of Truth (SSOT)
-- =============================================================================

-- 1. Table DDL: public.core_gps
CREATE TABLE IF NOT EXISTS public.core_gps (
    id BIGSERIAL PRIMARY KEY,
    record_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    distance_km NUMERIC(10,2) DEFAULT 0.00,
    city VARCHAR(20),
    partner_id VARCHAR(50),
    partner_name VARCHAR(150),
    driver_phone VARCHAR(20),
    vehicle_status VARCHAR(30) DEFAULT 'RFD',
    cohort VARCHAR(20) DEFAULT 'In Yard',
    source_provider VARCHAR(50) DEFAULT 'INTELLICAR',
    raw_vehicle_id VARCHAR(100),
    is_idle_movement_alert BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    CONSTRAINT uq_core_gps UNIQUE (record_date, vehicle_number)
);

-- 2. Performance B-Tree Indexes
CREATE INDEX IF NOT EXISTS idx_core_gps_vehicle_date ON public.core_gps (vehicle_number, record_date);
CREATE INDEX IF NOT EXISTS idx_core_gps_date ON public.core_gps (record_date);
CREATE INDEX IF NOT EXISTS idx_core_gps_city ON public.core_gps (city, record_date);
CREATE INDEX IF NOT EXISTS idx_core_gps_status ON public.core_gps (vehicle_status);
CREATE INDEX IF NOT EXISTS idx_core_gps_partner ON public.core_gps (partner_id);
CREATE INDEX IF NOT EXISTS idx_core_gps_alert ON public.core_gps (is_idle_movement_alert) WHERE is_idle_movement_alert = TRUE;

-- 3. Vehicle Plate & VIN Cleaning Function
CREATE OR REPLACE FUNCTION fn_clean_gps_vehicle_number(p_raw_id text)
RETURNS varchar AS $func$
DECLARE
    v_cleaned text;
    v_resolved varchar;
BEGIN
    IF p_raw_id IS NULL OR TRIM(p_raw_id) = '' THEN
        RETURN NULL;
    END IF;
    
    -- Strip suffix device tokens like -A, -B, _A, etc.
    v_cleaned := UPPER(REGEXP_REPLACE(TRIM(p_raw_id), '[-_\s][A-Za-z0-9]$', ''));
    -- Remove any remaining non-alphanumeric characters
    v_cleaned := REGEXP_REPLACE(v_cleaned, '[^A-Za-z0-9]', '', 'g');
    
    -- 1. Check direct registration number match
    SELECT registration_no INTO v_resolved 
    FROM core_vehicle_onboarding 
    WHERE registration_no = v_cleaned 
    LIMIT 1;
    
    IF v_resolved IS NOT NULL THEN
        RETURN v_resolved;
    END IF;
    
    -- 2. Check chassis number / VIN match (pre-registration tracking)
    SELECT registration_no INTO v_resolved 
    FROM core_vehicle_onboarding 
    WHERE chassis_no = v_cleaned 
    LIMIT 1;
    
    IF v_resolved IS NOT NULL THEN
        RETURN v_resolved;
    END IF;
    
    -- Fallback to sanitized token capped at 20 characters
    RETURN SUBSTRING(v_cleaned FROM 1 FOR 20);
END;
$func$ LANGUAGE plpgsql STABLE;

-- 4. Batch Ingestion Synchronization Procedure (Decoupled pg_cron Architecture)
CREATE OR REPLACE PROCEDURE public.sp_sync_core_gps(p_days_back INT DEFAULT 3)
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_rows_affected INT := 0;
BEGIN
    WITH cleaned_telematics AS (
        SELECT
            s.record_date,
            fn_clean_gps_vehicle_number(s.vehicle_id) AS vehicle_number,
            MAX(COALESCE(s.distance_km, 0.00)) AS distance_km,
            MAX(s.vehicle_id) AS raw_vehicle_id
        FROM public.sheet_gps_telematics s
        WHERE (p_days_back IS NULL OR s.record_date >= CURRENT_DATE - (p_days_back || ' days')::INTERVAL)
        GROUP BY s.record_date, fn_clean_gps_vehicle_number(s.vehicle_id)
        HAVING fn_clean_gps_vehicle_number(s.vehicle_id) IS NOT NULL 
           AND fn_clean_gps_vehicle_number(s.vehicle_id) != ''
    ),
    enriched AS (
        SELECT
            ct.record_date,
            ct.vehicle_number,
            ct.distance_km,
            COALESCE(dvs.city, cvo.city, 'Bangalore') AS city,
            dvs.partner_id,
            dvs.partner_name,
            dvs.partner_phone AS driver_phone,
            COALESCE(dvs.final_status, 'RFD') AS vehicle_status,
            COALESCE(dvs.cohort, 'In Yard') AS cohort,
            'INTELLICAR'::VARCHAR(50) AS source_provider,
            ct.raw_vehicle_id,
            (COALESCE(dvs.final_status, 'RFD') IN ('RFD', 'Maintenance', 'Workshop', 'Accidental', 'BD') 
             AND ct.distance_km > 5.0) AS is_idle_movement_alert
        FROM cleaned_telematics ct
        LEFT JOIN public.core_daily_vehicle_status dvs 
            ON dvs.status_date = ct.record_date AND dvs.vehicle_number = ct.vehicle_number
        LEFT JOIN public.core_vehicle_onboarding cvo 
            ON cvo.registration_no = ct.vehicle_number
    )
    INSERT INTO public.core_gps (
        record_date,
        vehicle_number,
        distance_km,
        city,
        partner_id,
        partner_name,
        driver_phone,
        vehicle_status,
        cohort,
        source_provider,
        raw_vehicle_id,
        is_idle_movement_alert,
        created_at,
        updated_at
    )
    SELECT
        e.record_date,
        e.vehicle_number,
        e.distance_km,
        e.city,
        e.partner_id,
        e.partner_name,
        e.driver_phone,
        e.vehicle_status,
        e.cohort,
        e.source_provider,
        e.raw_vehicle_id,
        e.is_idle_movement_alert,
        CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata',
        CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'
    FROM enriched e
    ON CONFLICT (record_date, vehicle_number)
    DO UPDATE SET
        distance_km = GREATEST(core_gps.distance_km, EXCLUDED.distance_km),
        city = COALESCE(EXCLUDED.city, core_gps.city),
        partner_id = COALESCE(EXCLUDED.partner_id, core_gps.partner_id),
        partner_name = COALESCE(EXCLUDED.partner_name, core_gps.partner_name),
        driver_phone = COALESCE(EXCLUDED.driver_phone, core_gps.driver_phone),
        vehicle_status = COALESCE(EXCLUDED.vehicle_status, core_gps.vehicle_status),
        cohort = COALESCE(EXCLUDED.cohort, core_gps.cohort),
        is_idle_movement_alert = (
            COALESCE(EXCLUDED.vehicle_status, core_gps.vehicle_status) IN ('RFD', 'Maintenance', 'Workshop', 'Accidental', 'BD') 
            AND GREATEST(core_gps.distance_km, EXCLUDED.distance_km) > 5.0
        ),
        updated_at = CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata';

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    RAISE NOTICE 'sp_sync_core_gps: Synced % rows into core_gps (Lookback: % days)', v_rows_affected, p_days_back;
END;
$proc$ LANGUAGE plpgsql;

-- 5. Safe Trigger Detachment (Prevents Ingestion Transaction Rollbacks)
DROP TRIGGER IF EXISTS trg_sync_core_gps_from_telematics ON public.sheet_gps_telematics;

-- 6. pg_cron Scheduling Setup
-- Run every hour at minute 25 (catches post-API runs and midday updates)
SELECT cron.schedule(
    'sync-core-gps-hourly',
    '25 * * * *',
    'CALL public.sp_sync_core_gps(3);'
);

-- Morning Deep Sync (7-day lookback) at 08:30 AM IST (03:00 AM UTC)
SELECT cron.schedule(
    'sync-core-gps-morning-deep',
    '0 3 * * *',
    'CALL public.sp_sync_core_gps(7);'
);

-- 7. Operational Verification Queries
-- Verify sequence continuity
SELECT MIN(id), MAX(id), COUNT(*), (SELECT last_value FROM pg_sequences WHERE sequencename = 'core_gps_id_seq') AS seq_last_val FROM public.core_gps;

-- Verify city telematics breakdown
SELECT city, COUNT(DISTINCT vehicle_number) AS active_vehicles, SUM(distance_km) AS total_km FROM public.core_gps GROUP BY city ORDER BY total_km DESC;

-- Verify idle movement alerts
SELECT record_date, vehicle_number, city, vehicle_status, distance_km, raw_vehicle_id FROM public.core_gps WHERE is_idle_movement_alert = TRUE ORDER BY record_date DESC, distance_km DESC LIMIT 20;

-- Verify pg_cron job status
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname LIKE '%gps%';
