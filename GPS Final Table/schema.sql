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

-- 4. Real-time Ingestion Synchronization Trigger Function
CREATE OR REPLACE FUNCTION fn_sync_core_gps_from_telematics()
RETURNS TRIGGER AS $func$
DECLARE
    v_clean_vehicle VARCHAR(20);
    v_city VARCHAR(20);
    v_partner_id VARCHAR(50);
    v_partner_name VARCHAR(150);
    v_partner_phone VARCHAR(20);
    v_final_status VARCHAR(30) := 'RFD';
    v_cohort VARCHAR(20) := 'In Yard';
    v_is_alert BOOLEAN := FALSE;
BEGIN
    -- Clean and resolve vehicle plate or chassis number
    v_clean_vehicle := fn_clean_gps_vehicle_number(NEW.vehicle_id);
    
    IF v_clean_vehicle IS NULL OR v_clean_vehicle = '' THEN
        RETURN NEW;
    END IF;

    -- Lookup operational context from core_daily_vehicle_status
    SELECT 
        dvs.city,
        dvs.partner_id,
        dvs.partner_name,
        dvs.partner_phone,
        dvs.final_status,
        dvs.cohort
    INTO 
        v_city,
        v_partner_id,
        v_partner_name,
        v_partner_phone,
        v_final_status,
        v_cohort
    FROM core_daily_vehicle_status dvs
    WHERE dvs.status_date = NEW.record_date 
      AND dvs.vehicle_number = v_clean_vehicle
    LIMIT 1;

    -- Fallback to core_vehicle_onboarding for city if unassigned
    IF v_city IS NULL THEN
        SELECT cvo.city INTO v_city
        FROM core_vehicle_onboarding cvo
        WHERE cvo.registration_no = v_clean_vehicle
        LIMIT 1;
        
        IF v_city IS NULL THEN
            v_city := 'Bangalore';
        END IF;
    END IF;

    IF v_final_status IS NULL THEN
        v_final_status := 'RFD';
        v_cohort := 'In Yard';
    END IF;

    -- Flag idle movement alert (> 5km movement while in yard or maintenance)
    IF v_final_status IN ('RFD', 'Maintenance', 'Workshop', 'Accidental', 'BD') AND COALESCE(NEW.distance_km, 0) > 5.0 THEN
        v_is_alert := TRUE;
    END IF;

    -- Upsert into core_gps with idempotency
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
    ) VALUES (
        NEW.record_date,
        v_clean_vehicle,
        COALESCE(NEW.distance_km, 0.00),
        v_city,
        v_partner_id,
        v_partner_name,
        v_partner_phone,
        v_final_status,
        v_cohort,
        'INTELLICAR',
        NEW.vehicle_id,
        v_is_alert,
        CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata',
        CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'
    )
    ON CONFLICT (record_date, vehicle_number)
    DO UPDATE SET
        distance_km = GREATEST(core_gps.distance_km, EXCLUDED.distance_km),
        city = COALESCE(EXCLUDED.city, core_gps.city),
        partner_id = COALESCE(EXCLUDED.partner_id, core_gps.partner_id),
        partner_name = COALESCE(EXCLUDED.partner_name, core_gps.partner_name),
        driver_phone = COALESCE(EXCLUDED.driver_phone, core_gps.driver_phone),
        vehicle_status = COALESCE(EXCLUDED.vehicle_status, core_gps.vehicle_status),
        cohort = COALESCE(EXCLUDED.cohort, core_gps.cohort),
        is_idle_movement_alert = (COALESCE(EXCLUDED.vehicle_status, core_gps.vehicle_status) IN ('RFD', 'Maintenance', 'Workshop', 'Accidental', 'BD') AND GREATEST(core_gps.distance_km, EXCLUDED.distance_km) > 5.0),
        updated_at = CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata';

    RETURN NEW;
END;
$func$ LANGUAGE plpgsql;

-- 5. Trigger Installation
DROP TRIGGER IF EXISTS trg_sync_core_gps_from_telematics ON public.sheet_gps_telematics;
CREATE TRIGGER trg_sync_core_gps_from_telematics
AFTER INSERT OR UPDATE ON public.sheet_gps_telematics
FOR EACH ROW EXECUTE FUNCTION fn_sync_core_gps_from_telematics();

-- 6. Operational Verification Queries
-- Verify sequence continuity
SELECT MIN(id), MAX(id), COUNT(*), (SELECT last_value FROM pg_sequences WHERE sequencename = 'core_gps_id_seq') AS seq_last_val FROM public.core_gps;

-- Verify city telematics breakdown
SELECT city, COUNT(DISTINCT vehicle_number) AS active_vehicles, SUM(distance_km) AS total_km FROM public.core_gps GROUP BY city ORDER BY total_km DESC;

-- Verify idle movement alerts
SELECT record_date, vehicle_number, city, vehicle_status, distance_km, raw_vehicle_id FROM public.core_gps WHERE is_idle_movement_alert = TRUE ORDER BY record_date DESC, distance_km DESC LIMIT 20;
