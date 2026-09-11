-- =============================================================================
-- LetzRyd Master Vehicle Onboarding Single Source of Truth: public.core_vehicle_onboarding
-- =============================================================================
-- Description:
-- Master table unifying two independent vehicle onboarding data sources:
--   1. public.sheet_vehicle_onboarding (Google Sheet entries synced via Apps Script)
--   2. public.july_vehicle_onboarding (LetzRyd Web Portal Vehicle Onboarding Form)
--
-- Conflict & Merging Policy:
--   - Natural Primary Key: registration_no (Standardized Vehicle Plate Number).
--   - Portal Form Priority: If the same vehicle registration exists in both systems,
--     the Portal form table (july_vehicle_onboarding) takes top priority.
--   - Non-conflicting Operational Enrichment: Sheet-specific operational data
--     (e.g., PDI timestamps, financier, ageing, comments, payment dates) enriches
--     the record seamlessly.
--
-- Architectural Guarantees:
--   - Zero Changes to Upstream Tables: sheet_vehicle_onboarding and july_vehicle_onboarding
--     remain 100% untouched.
--   - Clean IST Timestamps: All timestamps stored as TIMESTAMP WITHOUT TIME ZONE in Asia/Kolkata.
--   - High-Throughput Sequencing: Native BIGSERIAL sequence generation without lock contention.
--   - Soft Delete & Archival: Source deletions trigger is_deleted = TRUE without hard data destruction.
-- =============================================================================

-- 1. Master Table Definition (Non-Destructive Schema Creation)
CREATE TABLE IF NOT EXISTS public.core_vehicle_onboarding (
    id BIGSERIAL PRIMARY KEY,
    
    -- Provenance & Source Attribution
    source_system VARCHAR(100) NOT NULL, -- 'GOOGLE_SHEET', 'PORTAL_FORM', 'MERGED_PORTAL_SHEET'
    source_table VARCHAR(100) NOT NULL,  -- 'sheet_vehicle_onboarding', 'july_vehicle_onboarding'
    sheet_vehicle_id BIGINT,             -- Pointer to sheet_vehicle_onboarding.id
    portal_vehicle_id INTEGER,           -- Pointer to july_vehicle_onboarding.id
    
    -- Core Vehicle Identifiers (Standardized)
    registration_no VARCHAR(100) NOT NULL,
    letzryd_unique_no VARCHAR(255),
    chassis_no VARCHAR(255),
    engine_no VARCHAR(255),
    
    -- Vehicle Specifications & Profile
    city VARCHAR(100) NOT NULL,
    model VARCHAR(255),
    fuel_type VARCHAR(100) DEFAULT 'CNG',
    color VARCHAR(100),
    dealer_name VARCHAR(255),
    registered_owner_name VARCHAR(255),
    ownership VARCHAR(100),
    financier VARCHAR(255),
    hp_details VARCHAR(255),
    mfg_date VARCHAR(100),
    ageing VARCHAR(255),
    
    -- Status & Operational Timeline
    vehicle_status VARCHAR(100) DEFAULT 'ACTIVE',
    received_allocated VARCHAR(255),
    delivery_month VARCHAR(100),
    registration_date DATE,
    delivery_date DATE,
    payment_date DATE,
    invoice_date DATE,
    invoice_no VARCHAR(255),
    
    -- Regulatory & Compliance Validities
    rto_tax_validity DATE,
    permit_validity DATE,
    permit_start_date DATE,
    permit_end_date DATE,
    permit_type VARCHAR(255),
    fitness_validity DATE,
    fitness_start_date DATE,
    fitness_end_date DATE,
    pollution_validity DATE,
    auth_start_date DATE,
    auth_end_date DATE,
    authorization_certificate VARCHAR(255),
    
    -- Insurance Details & Add-on Covers
    insurance_validity DATE,
    insurance_start_date DATE,
    insurance_broker VARCHAR(255),
    insurance_underwriter VARCHAR(255),
    insurance_idv VARCHAR(255),
    insurance_mapping VARCHAR(255),
    cover_engine_protect BOOLEAN DEFAULT FALSE,
    cover_consumables BOOLEAN DEFAULT FALSE,
    cover_zero_dep BOOLEAN DEFAULT FALSE,
    cover_rsa BOOLEAN DEFAULT FALSE,
    
    -- Telematics, FASTag & Odometer
    kms_reading NUMERIC,
    tracking_device_vendor VARCHAR(255),
    tracking_device_type VARCHAR(255),
    gps_status VARCHAR(255),
    fast_tag_number VARCHAR(255),
    fast_tag_vendor VARCHAR(255),
    
    -- Accessories & Inspection Checklist
    key_quantity TEXT,
    jack VARCHAR(255),
    jack_rod VARCHAR(255),
    spanner VARCHAR(255),
    parking_triangle VARCHAR(255),
    fire_extinguishers VARCHAR(255),
    seat_cover VARCHAR(255),
    floor_carpet VARCHAR(255),
    cng_installed VARCHAR(255),
    cng_plate VARCHAR(255),
    cng_tank_number VARCHAR(255),
    cng_installation_date DATE,
    
    -- PDI Audit & Form Submission Metadata
    pdi_status VARCHAR(255),
    platform VARCHAR(255),
    pdi_timestamp TIMESTAMP WITHOUT TIME ZONE,
    pdi_email_address VARCHAR(255),
    pdi_city VARCHAR(100),
    pdi_reg_no VARCHAR(100),
    mds_timestamp TIMESTAMP WITHOUT TIME ZONE,
    mds_email_address VARCHAR(255),
    mds_vehicle_number VARCHAR(100),
    sheet_row_number INTEGER,
    
    -- Document & Media URLs (Verbatim Links)
    rc_document TEXT,
    insurance_document TEXT,
    authorization_certificate_doc TEXT,
    rto_tax_receipt TEXT,
    permit_document TEXT,
    fitness_document TEXT,
    pollution_document TEXT,
    insurance_endorsement TEXT,
    invoice_copy TEXT,
    key_photo_url TEXT,
    
    -- Inspection Images
    image_front TEXT,
    image_lh TEXT,
    image_back TEXT,
    image_rh TEXT,
    engine_chasis_no_img TEXT,
    battery_sl_no_img TEXT,
    engine_compartment_img TEXT,
    fast_tag_img TEXT,
    music_system_img TEXT,
    rh_fr_tyre_img TEXT,
    lh_fr_tyre_img TEXT,
    rh_rear_tyre_img TEXT,
    lh_rear_tyre_img TEXT,
    spare_wheel_img TEXT,
    
    -- Tyre & Component Brand/Serial Numbers
    rh_fr_tyre_brand_sl_no TEXT,
    lh_fr_tyre_brand_sl_no TEXT,
    rh_rear_tyre_brand_sl_no TEXT,
    lh_rear_tyre_brand_sl_no TEXT,
    spare_wheel_brand_sl_no TEXT,
    battery_sl_no VARCHAR(255),
    
    -- Portal Approval Workflow & Operational Remarks
    approval_status VARCHAR(100) DEFAULT 'APPROVED',
    current_approver_id INTEGER,
    approved_by INTEGER,
    approval_remarks TEXT,
    comments TEXT,
    chassis_review_flag BOOLEAN DEFAULT FALSE,
    is_migrated BOOLEAN DEFAULT FALSE,
    created_by INTEGER,
    updated_by INTEGER,
    
    -- Gapless Audit & Soft Delete State
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    extra_attributes JSONB DEFAULT '{}'::jsonb,
    
    -- Audit Timestamps (Clean IST without +05:30)
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
);

-- -----------------------------------------------------------------------------
-- Indexes for High-Performance Queries, Integrity & Idempotency
-- -----------------------------------------------------------------------------

-- Unique Constraint on Normalized Plate for Single Source of Truth
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_vehicle_reg_no 
    ON public.core_vehicle_onboarding (registration_no);

-- Partial Unique Indexes for Source Pointers
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_vehicle_sheet_id 
    ON public.core_vehicle_onboarding (sheet_vehicle_id) WHERE sheet_vehicle_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_vehicle_portal_id 
    ON public.core_vehicle_onboarding (portal_vehicle_id) WHERE portal_vehicle_id IS NOT NULL;

-- Query & Analytical Performance Indexes
CREATE INDEX IF NOT EXISTS idx_core_veh_city ON public.core_vehicle_onboarding (city);
CREATE INDEX IF NOT EXISTS idx_core_veh_status ON public.core_vehicle_onboarding (vehicle_status);
CREATE INDEX IF NOT EXISTS idx_core_veh_model ON public.core_vehicle_onboarding (model);
CREATE INDEX IF NOT EXISTS idx_core_veh_source ON public.core_vehicle_onboarding (source_system);
CREATE INDEX IF NOT EXISTS idx_core_veh_reg_date ON public.core_vehicle_onboarding (registration_date DESC);
CREATE INDEX IF NOT EXISTS idx_core_veh_active ON public.core_vehicle_onboarding (is_deleted);
CREATE INDEX IF NOT EXISTS idx_core_veh_city_status ON public.core_vehicle_onboarding (city, vehicle_status);


-- =============================================================================
-- 2. Helper Normalization Functions
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_clean_plate(p_input TEXT)
RETURNS VARCHAR AS $$
BEGIN
    IF p_input IS NULL OR TRIM(p_input) = '' THEN
        RETURN NULL;
    END IF;
    RETURN UPPER(REGEXP_REPLACE(TRIM(p_input), '[^A-Za-z0-9]', '', 'g'));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.fn_clean_city_name(p_input TEXT)
RETURNS VARCHAR AS $$
DECLARE
    v_clean TEXT;
BEGIN
    IF p_input IS NULL OR TRIM(p_input) = '' THEN
        RETURN 'Unknown';
    END IF;
    v_clean := LOWER(TRIM(p_input));
    IF v_clean IN ('bangalore', 'bengaluru', 'blr') THEN
        RETURN 'Bengaluru';
    ELSIF v_clean IN ('hyderabad', 'hyd') THEN
        RETURN 'Hyderabad';
    ELSIF v_clean IN ('mumbai', 'mum') THEN
        RETURN 'Mumbai';
    ELSIF v_clean IN ('delhi', 'new delhi', 'ncr') THEN
        RETURN 'Delhi';
    ELSE
        RETURN INITCAP(TRIM(p_input));
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.fn_parse_flexible_date(p_input TEXT)
RETURNS DATE AS $$
DECLARE
    v_trimmed TEXT;
BEGIN
    IF p_input IS NULL OR TRIM(p_input) = '' THEN
        RETURN NULL;
    END IF;
    v_trimmed := TRIM(p_input);
    
    -- ISO Format (YYYY-MM-DD)
    IF v_trimmed ~ '^\d{4}-\d{2}-\d{2}' THEN
        RETURN SUBSTRING(v_trimmed FROM 1 FOR 10)::DATE;
    END IF;
    -- DD/MM/YYYY or DD-MM-YYYY
    IF v_trimmed ~ '^\d{1,2}[/-]\d{1,2}[/-]\d{4}' THEN
        BEGIN
            RETURN TO_DATE(v_trimmed, 'DD-MM-YYYY');
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    END IF;
    -- Try direct cast
    BEGIN
        RETURN v_trimmed::DATE;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- =============================================================================
-- 3. Trigger Function: Sync from public.july_vehicle_onboarding (Portal Form)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_sync_core_vehicle_from_portal()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_plate VARCHAR(50);
    v_clean_city VARCHAR(100);
    v_reg_date DATE;
    v_rto_tax DATE;
    v_permit_val DATE;
    v_fit_val DATE;
    v_pol_val DATE;
    v_ins_val DATE;
    v_ins_start DATE;
    v_cng_date DATE;
    v_existing_id BIGINT;
    v_existing_sheet_id BIGINT;
BEGIN
    -- Handle DELETE (Soft-Delete)
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_vehicle_onboarding
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE portal_vehicle_id = OLD.id;
        RETURN OLD;
    END IF;

    -- Clean Key Values
    v_clean_plate := public.fn_clean_plate(NEW.vehicle_number);
    v_clean_city := public.fn_clean_city_name(NEW.city_name);
    
    IF v_clean_plate IS NULL THEN
        RETURN NEW;
    END IF;

    -- Parse Dates
    v_reg_date   := public.fn_parse_flexible_date(NEW.registration_date);
    v_rto_tax    := public.fn_parse_flexible_date(NEW.rto_tax_validity);
    v_permit_val := COALESCE(NEW.permit_end_date, public.fn_parse_flexible_date(NEW.permit_validity));
    v_fit_val    := COALESCE(NEW.fitness_end_date, public.fn_parse_flexible_date(NEW.fitness_validity));
    v_pol_val    := public.fn_parse_flexible_date(NEW.pollution_validity);
    v_ins_val    := public.fn_parse_flexible_date(NEW.insurance_validity);
    v_ins_start  := public.fn_parse_flexible_date(NEW.insurance_start_date);
    v_cng_date   := public.fn_parse_flexible_date(NEW.cng_installation_date);

    -- Check if record already exists under this Plate
    SELECT id, sheet_vehicle_id INTO v_existing_id, v_existing_sheet_id
    FROM public.core_vehicle_onboarding
    WHERE registration_no = v_clean_plate;

    IF v_existing_id IS NOT NULL THEN
        -- UPDATE with Portal Precedence
        UPDATE public.core_vehicle_onboarding
        SET 
            source_system = CASE WHEN v_existing_sheet_id IS NOT NULL THEN 'MERGED_PORTAL_SHEET' ELSE 'PORTAL_FORM' END,
            source_table = 'july_vehicle_onboarding',
            portal_vehicle_id = NEW.id,
            letzryd_unique_no = COALESCE(NULLIF(NEW.letzryd_unique_no, ''), letzryd_unique_no),
            chassis_no = COALESCE(NULLIF(NEW.chassis_number, ''), chassis_no),
            engine_no = COALESCE(NULLIF(NEW.engine_number, ''), engine_no),
            city = v_clean_city,
            model = COALESCE(NULLIF(NEW.model, ''), model),
            fuel_type = COALESCE(NULLIF(NEW.fuel_type, ''), fuel_type, 'CNG'),
            color = COALESCE(NULLIF(NEW.color, ''), color),
            dealer_name = COALESCE(NULLIF(NEW.dealer_name, ''), dealer_name),
            registered_owner_name = COALESCE(NULLIF(NEW.registered_owner_name, ''), registered_owner_name),
            hp_details = COALESCE(NULLIF(NEW.hp_details, ''), hp_details),
            mfg_date = COALESCE(NULLIF(NEW.mfg_date, ''), mfg_date),
            received_allocated = COALESCE(NULLIF(NEW.received_allocated, ''), received_allocated),
            delivery_month = COALESCE(NULLIF(NEW.delivery_month, ''), delivery_month),
            registration_date = COALESCE(v_reg_date, registration_date),
            invoice_date = COALESCE(NEW.invoice_date, invoice_date),
            invoice_no = COALESCE(NULLIF(NEW.invoice_no, ''), invoice_no),
            rto_tax_validity = COALESCE(v_rto_tax, rto_tax_validity),
            permit_validity = COALESCE(v_permit_val, permit_validity),
            permit_start_date = COALESCE(NEW.permit_start_date, permit_start_date),
            permit_end_date = COALESCE(NEW.permit_end_date, permit_end_date),
            permit_type = COALESCE(NULLIF(NEW.permit_type, ''), permit_type),
            fitness_validity = COALESCE(v_fit_val, fitness_validity),
            fitness_start_date = COALESCE(NEW.fitness_start_date, fitness_start_date),
            fitness_end_date = COALESCE(NEW.fitness_end_date, fitness_end_date),
            pollution_validity = COALESCE(v_pol_val, pollution_validity),
            auth_start_date = COALESCE(NEW.auth_start_date, auth_start_date),
            auth_end_date = COALESCE(NEW.auth_end_date, auth_end_date),
            authorization_certificate = COALESCE(NULLIF(NEW.authorization_certificate, ''), authorization_certificate),
            insurance_validity = COALESCE(v_ins_val, insurance_validity),
            insurance_start_date = COALESCE(v_ins_start, insurance_start_date),
            insurance_broker = COALESCE(NULLIF(NEW.insurance_broker, ''), insurance_broker),
            insurance_underwriter = COALESCE(NULLIF(NEW.insurance_underwriter, ''), insurance_underwriter),
            insurance_idv = COALESCE(NULLIF(NEW.insurance_idv, ''), insurance_idv),
            insurance_mapping = COALESCE(NULLIF(NEW.insurance_mapping, ''), insurance_mapping),
            cover_engine_protect = COALESCE(NEW.cover_engine_protect, cover_engine_protect),
            cover_consumables = COALESCE(NEW.cover_consumables, cover_consumables),
            cover_zero_dep = COALESCE(NEW.cover_zero_dep, cover_zero_dep),
            cover_rsa = COALESCE(NEW.cover_rsa, cover_rsa),
            kms_reading = COALESCE(NULLIF(REGEXP_REPLACE(NEW.kms_reading, '[^0-9.]', '', 'g'), '')::NUMERIC, kms_reading),
            tracking_device_vendor = COALESCE(NULLIF(NEW.tracking_device_vendor, ''), tracking_device_vendor),
            tracking_device_type = COALESCE(NULLIF(NEW.tracking_device_type, ''), tracking_device_type),
            fast_tag_number = COALESCE(NULLIF(NEW.fast_tag_number, ''), fast_tag_number),
            fast_tag_vendor = COALESCE(NULLIF(NEW.fast_tag_vendor, ''), fast_tag_vendor),
            key_quantity = COALESCE(NEW.key_quantity::TEXT, key_quantity),
            jack = COALESCE(NULLIF(NEW.jack, ''), jack),
            jack_rod = COALESCE(NULLIF(NEW.jack_rod, ''), jack_rod),
            spanner = COALESCE(NULLIF(NEW.spanner, ''), spanner),
            parking_triangle = COALESCE(NULLIF(NEW.parking_triangle, ''), parking_triangle),
            fire_extinguishers = COALESCE(NULLIF(NEW.fire_extinguishers, ''), fire_extinguishers),
            seat_cover = COALESCE(NULLIF(NEW.seat_cover, ''), seat_cover),
            floor_carpet = COALESCE(NULLIF(NEW.floor_carpet, ''), floor_carpet),
            cng_installed = COALESCE(NULLIF(NEW.cng_installed, ''), cng_installed),
            cng_plate = COALESCE(NULLIF(NEW.cng_plate, ''), cng_plate),
            cng_tank_number = COALESCE(NULLIF(NEW.cng_tank_number, ''), cng_tank_number),
            cng_installation_date = COALESCE(v_cng_date, cng_installation_date),
            rc_document = COALESCE(NULLIF(NEW.rc_document, ''), rc_document),
            insurance_document = COALESCE(NULLIF(NEW.insurance_document, ''), insurance_document),
            authorization_certificate_doc = COALESCE(NULLIF(NEW.authorization_certificate_doc, ''), authorization_certificate_doc),
            rto_tax_receipt = COALESCE(NULLIF(NEW.rto_tax_receipt, ''), rto_tax_receipt),
            image_front = COALESCE(NULLIF(NEW.image_front, ''), image_front),
            image_lh = COALESCE(NULLIF(NEW.image_lh, ''), image_lh),
            image_back = COALESCE(NULLIF(NEW.image_back, ''), image_back),
            image_rh = COALESCE(NULLIF(NEW.image_rh, ''), image_rh),
            engine_chasis_no_img = COALESCE(NULLIF(NEW.engine_chasis_no_img, ''), engine_chasis_no_img),
            battery_sl_no_img = COALESCE(NULLIF(NEW.battery_sl_no_img, ''), battery_sl_no_img),
            engine_compartment_img = COALESCE(NULLIF(NEW.engine_compartment_img, ''), engine_compartment_img),
            fast_tag_img = COALESCE(NULLIF(NEW.fast_tag_img, ''), fast_tag_img),
            music_system_img = COALESCE(NULLIF(NEW.music_system_img, ''), music_system_img),
            rh_fr_tyre_img = COALESCE(NULLIF(NEW.rh_fr_tyre_img, ''), rh_fr_tyre_img),
            lh_fr_tyre_img = COALESCE(NULLIF(NEW.lh_fr_tyre_img, ''), lh_fr_tyre_img),
            rh_rear_tyre_img = COALESCE(NULLIF(NEW.rh_rear_tyre_img, ''), rh_rear_tyre_img),
            lh_rear_tyre_img = COALESCE(NULLIF(NEW.lh_rear_tyre_img, ''), lh_rear_tyre_img),
            spare_wheel_img = COALESCE(NULLIF(NEW.spare_wheel_img, ''), spare_wheel_img),
            approval_status = COALESCE(NULLIF(NEW.approval_status, ''), approval_status),
            current_approver_id = COALESCE(NEW.current_approver_id, current_approver_id),
            approved_by = COALESCE(NEW.approved_by, approved_by),
            approval_remarks = COALESCE(NULLIF(NEW.approval_remarks, ''), approval_remarks),
            chassis_review_flag = (LENGTH(TRIM(COALESCE(NEW.chassis_number, ''))) != 17),
            is_migrated = COALESCE(NEW.is_migrated, is_migrated),
            created_by = COALESCE(NEW.created_by, created_by),
            updated_by = COALESCE(NEW.updated_by, updated_by),
            is_deleted = CASE WHEN is_deleted THEN is_deleted ELSE FALSE END,
            deleted_at = CASE WHEN is_deleted THEN deleted_at ELSE NULL END,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;
    ELSE
        -- INSERT New Master Row from Portal
        INSERT INTO public.core_vehicle_onboarding (
            source_system, source_table, portal_vehicle_id,
            registration_no, letzryd_unique_no, chassis_no, engine_no,
            city, model, fuel_type, color, dealer_name, registered_owner_name,
            hp_details, mfg_date, received_allocated, delivery_month,
            registration_date, invoice_date, invoice_no,
            rto_tax_validity, permit_validity, permit_start_date, permit_end_date, permit_type,
            fitness_validity, fitness_start_date, fitness_end_date,
            pollution_validity, auth_start_date, auth_end_date, authorization_certificate,
            insurance_validity, insurance_start_date, insurance_broker, insurance_underwriter,
            insurance_idv, insurance_mapping, cover_engine_protect, cover_consumables,
            cover_zero_dep, cover_rsa,
            kms_reading, tracking_device_vendor, tracking_device_type,
            fast_tag_number, fast_tag_vendor,
            key_quantity, jack, jack_rod, spanner, parking_triangle, fire_extinguishers,
            seat_cover, floor_carpet, cng_installed, cng_plate, cng_tank_number, cng_installation_date,
            rc_document, insurance_document, authorization_certificate_doc, rto_tax_receipt,
            image_front, image_lh, image_back, image_rh,
            engine_chasis_no_img, battery_sl_no_img, engine_compartment_img,
            fast_tag_img, music_system_img,
            rh_fr_tyre_img, lh_fr_tyre_img, rh_rear_tyre_img, lh_rear_tyre_img, spare_wheel_img,
            approval_status, current_approver_id, approved_by, approval_remarks,
            chassis_review_flag, is_migrated, created_by, updated_by,
            is_deleted, created_at, updated_at
        ) VALUES (
            'PORTAL_FORM', 'july_vehicle_onboarding', NEW.id,
            v_clean_plate, LEFT(NEW.letzryd_unique_no, 100), LEFT(NEW.chassis_number, 100), LEFT(NEW.engine_number, 100),
            v_clean_city, LEFT(NEW.model, 100), LEFT(COALESCE(NEW.fuel_type, 'CNG'), 50), LEFT(NEW.color, 100), LEFT(NEW.dealer_name, 255), LEFT(NEW.registered_owner_name, 255),
            LEFT(NEW.hp_details, 100), LEFT(NEW.mfg_date, 50), LEFT(NEW.received_allocated, 100), LEFT(NEW.delivery_month, 100),
            v_reg_date, NEW.invoice_date, LEFT(NEW.invoice_no, 100),
            v_rto_tax, v_permit_val, NEW.permit_start_date, NEW.permit_end_date, LEFT(NEW.permit_type, 100),
            v_fit_val, NEW.fitness_start_date, NEW.fitness_end_date,
            v_pol_val, NEW.auth_start_date, NEW.auth_end_date, LEFT(NEW.authorization_certificate, 255),
            v_ins_val, v_ins_start, LEFT(NEW.insurance_broker, 255), LEFT(NEW.insurance_underwriter, 255),
            LEFT(NEW.insurance_idv, 100), LEFT(NEW.insurance_mapping, 255), COALESCE(NEW.cover_engine_protect, FALSE), COALESCE(NEW.cover_consumables, FALSE),
            COALESCE(NEW.cover_zero_dep, FALSE), COALESCE(NEW.cover_rsa, FALSE),
            NULLIF(REGEXP_REPLACE(NEW.kms_reading, '[^0-9.]', '', 'g'), '')::NUMERIC, LEFT(NEW.tracking_device_vendor, 100), LEFT(NEW.tracking_device_type, 100),
            LEFT(NEW.fast_tag_number, 100), LEFT(NEW.fast_tag_vendor, 100),
            LEFT(NEW.key_quantity::TEXT, 50), LEFT(NEW.jack, 50), LEFT(NEW.jack_rod, 50), LEFT(NEW.spanner, 50), LEFT(NEW.parking_triangle, 50), LEFT(NEW.fire_extinguishers, 50),
            LEFT(NEW.seat_cover, 50), LEFT(NEW.floor_carpet, 50), LEFT(NEW.cng_installed, 50), LEFT(NEW.cng_plate, 100), LEFT(NEW.cng_tank_number, 100), v_cng_date,
            NEW.rc_document, NEW.insurance_document, NEW.authorization_certificate_doc, NEW.rto_tax_receipt,
            NEW.image_front, NEW.image_lh, NEW.image_back, NEW.image_rh,
            NEW.engine_chasis_no_img, NEW.battery_sl_no_img, NEW.engine_compartment_img,
            NEW.fast_tag_img, NEW.music_system_img,
            NEW.rh_fr_tyre_img, NEW.lh_fr_tyre_img, NEW.rh_rear_tyre_img, NEW.lh_rear_tyre_img, NEW.spare_wheel_img,
            LEFT(COALESCE(NEW.approval_status, 'APPROVED'), 50), NEW.current_approver_id, NEW.approved_by, NEW.approval_remarks,
            (LENGTH(TRIM(COALESCE(NEW.chassis_number, ''))) != 17), COALESCE(NEW.is_migrated, FALSE), NEW.created_by, NEW.updated_by,
            FALSE, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- 4. Trigger Function: Sync from public.sheet_vehicle_onboarding (Google Sheet)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_sync_core_vehicle_from_sheet()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_plate VARCHAR(50);
    v_clean_city VARCHAR(100);
    v_existing_id BIGINT;
    v_existing_portal_id INTEGER;
BEGIN
    -- Handle DELETE (Soft-Delete)
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_vehicle_onboarding
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE sheet_vehicle_id = OLD.id AND portal_vehicle_id IS NULL;
        RETURN OLD;
    END IF;

    -- Clean Key Values
    v_clean_plate := public.fn_clean_plate(NEW.registration_no);
    v_clean_city := public.fn_clean_city_name(COALESCE(NEW.city, NEW.pdi_city));
    
    IF v_clean_plate IS NULL THEN
        RETURN NEW;
    END IF;

    -- Check if record already exists under this Plate
    SELECT id, portal_vehicle_id INTO v_existing_id, v_existing_portal_id
    FROM public.core_vehicle_onboarding
    WHERE registration_no = v_clean_plate;

    IF v_existing_id IS NOT NULL THEN
        -- If Portal Record Exists, Enrich Sheet-Specific Fields without Overwriting Portal Precedence
        UPDATE public.core_vehicle_onboarding
        SET 
            source_system = CASE WHEN v_existing_portal_id IS NOT NULL THEN 'MERGED_PORTAL_SHEET' ELSE 'GOOGLE_SHEET' END,
            sheet_vehicle_id = NEW.id,
            -- Non-conflicting Operational & Financial Fields
            ownership = COALESCE(ownership, NULLIF(NEW.ownership, '')),
            financier = COALESCE(financier, NULLIF(NEW.financier, '')),
            ageing = COALESCE(ageing, NULLIF(NEW.ageing, '')),
            vehicle_status = COALESCE(vehicle_status, NULLIF(NEW.vehicle_status, ''), 'ACTIVE'),
            delivery_date = COALESCE(delivery_date, NEW.delivery_date),
            payment_date = COALESCE(payment_date, NEW.payment_date),
            gps_status = COALESCE(gps_status, NULLIF(NEW.gps, '')),
            pdi_status = COALESCE(pdi_status, NULLIF(NEW.pdi_status, '')),
            platform = COALESCE(platform, NULLIF(NEW.platform, '')),
            pdi_timestamp = COALESCE(pdi_timestamp, (NEW.pdi_timestamp AT TIME ZONE 'Asia/Kolkata')::TIMESTAMP),
            pdi_email_address = COALESCE(pdi_email_address, NULLIF(NEW.pdi_email_address, '')),
            pdi_city = COALESCE(pdi_city, NULLIF(NEW.pdi_city, '')),
            pdi_reg_no = COALESCE(pdi_reg_no, NULLIF(NEW.pdi_reg_no, '')),
            mds_timestamp = COALESCE(mds_timestamp, (NEW.mds_timestamp AT TIME ZONE 'Asia/Kolkata')::TIMESTAMP),
            mds_email_address = COALESCE(mds_email_address, NULLIF(NEW.mds_email_address, '')),
            mds_vehicle_number = COALESCE(mds_vehicle_number, NULLIF(NEW.mds_vehicle_number, '')),
            permit_document = COALESCE(permit_document, NULLIF(NEW.permit, '')),
            fitness_document = COALESCE(fitness_document, NULLIF(NEW.fitness, '')),
            pollution_document = COALESCE(pollution_document, NULLIF(NEW.pollution, '')),
            insurance_endorsement = COALESCE(insurance_endorsement, NULLIF(NEW.insurance_endorsement, '')),
            invoice_copy = COALESCE(invoice_copy, NULLIF(NEW.invoice_copy, '')),
            key_photo_url = COALESCE(key_photo_url, NULLIF(NEW.key_photo_url, '')),
            rh_fr_tyre_brand_sl_no = COALESCE(rh_fr_tyre_brand_sl_no, NULLIF(NEW.rh_fr_tyre_brand_sl_no, '')),
            lh_fr_tyre_brand_sl_no = COALESCE(lh_fr_tyre_brand_sl_no, NULLIF(NEW.lh_fr_tyre_brand_sl_no, '')),
            rh_rear_tyre_brand_sl_no = COALESCE(rh_rear_tyre_brand_sl_no, NULLIF(NEW.rh_rear_tyre_brand_sl_no, '')),
            lh_rear_tyre_brand_sl_no = COALESCE(lh_rear_tyre_brand_sl_no, NULLIF(NEW.lh_rear_tyre_brand_sl_no, '')),
            spare_wheel_brand_sl_no = COALESCE(spare_wheel_brand_sl_no, NULLIF(NEW.spare_wheel_brand_sl_no, '')),
            battery_sl_no = COALESCE(battery_sl_no, NULLIF(NEW.battery_sl_no, '')),
            comments = COALESCE(comments, NULLIF(NEW.comments, '')),
            sheet_row_number = NEW.sheet_row_number,
            chassis_review_flag = (LENGTH(TRIM(COALESCE(
                CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.chassis_no, ''), chassis_no) ELSE chassis_no END
            , ''))) != 17),
            -- If not from portal, update primary specs from sheet
            letzryd_unique_no = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.letzryd_unique_vehicle_no, ''), NULLIF(NEW.letzryd_serial_number, ''), letzryd_unique_no) ELSE letzryd_unique_no END,
            chassis_no = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.chassis_no, ''), chassis_no) ELSE chassis_no END,
            engine_no = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.engine_no, ''), engine_no) ELSE engine_no END,
            city = CASE WHEN v_existing_portal_id IS NULL THEN v_clean_city ELSE city END,
            model = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.model, ''), model) ELSE model END,
            dealer_name = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.dealer, ''), dealer_name) ELSE dealer_name END,
            registered_owner_name = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.registered_owner_name, ''), registered_owner_name) ELSE registered_owner_name END,
            hp_details = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.hp, ''), hp_details) ELSE hp_details END,
            mfg_date = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.mfg_mm_yy, ''), mfg_date) ELSE mfg_date END,
            received_allocated = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.received_or_allocated, ''), received_allocated) ELSE received_allocated END,
            delivery_month = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.delivered_month_y, ''), delivery_month) ELSE delivery_month END,
            registration_date = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NEW.registration_date, registration_date) ELSE registration_date END,
            rto_tax_validity = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NEW.rto_tax_validity, rto_tax_validity) ELSE rto_tax_validity END,
            permit_validity = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NEW.permit_validity, permit_validity) ELSE permit_validity END,
            fitness_validity = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NEW.fitness_validity, fitness_validity) ELSE fitness_validity END,
            pollution_validity = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NEW.pollution_validity, pollution_validity) ELSE pollution_validity END,
            insurance_validity = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NEW.insurance_validity, insurance_validity) ELSE insurance_validity END,
            kms_reading = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NEW.kms_reading, kms_reading) ELSE kms_reading END,
            key_quantity = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.key_quantity, ''), key_quantity) ELSE key_quantity END,
            jack = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.jack, ''), jack) ELSE jack END,
            jack_rod = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.jack_rod, ''), jack_rod) ELSE jack_rod END,
            spanner = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.spanner, ''), spanner) ELSE spanner END,
            parking_triangle = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.parking_triangle, ''), parking_triangle) ELSE parking_triangle END,
            fire_extinguishers = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.fire_extinguishers, ''), fire_extinguishers) ELSE fire_extinguishers END,
            seat_cover = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.seat_cover, ''), seat_cover) ELSE seat_cover END,
            floor_carpet = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.floor_carpet, ''), floor_carpet) ELSE floor_carpet END,
            cng_plate = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.cng_plate, ''), cng_plate) ELSE cng_plate END,
            cng_installation_date = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NEW.cng_installation_date, cng_installation_date) ELSE cng_installation_date END,
            tracking_device_vendor = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.tracking_device_vendor, ''), tracking_device_vendor) ELSE tracking_device_vendor END,
            tracking_device_type = CASE WHEN v_existing_portal_id IS NULL THEN COALESCE(NULLIF(NEW.tracking_device_type, ''), tracking_device_type) ELSE tracking_device_type END,
            is_deleted = CASE WHEN is_deleted THEN is_deleted ELSE FALSE END,
            deleted_at = CASE WHEN is_deleted THEN deleted_at ELSE NULL END,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE id = v_existing_id;
    ELSE
        -- INSERT New Master Row from Sheet
        INSERT INTO public.core_vehicle_onboarding (
            source_system, source_table, sheet_vehicle_id,
            registration_no, letzryd_unique_no, chassis_no, engine_no,
            city, model, fuel_type, dealer_name, registered_owner_name,
            ownership, financier, hp_details, mfg_date, ageing, vehicle_status,
            received_allocated, delivery_month, registration_date, delivery_date, payment_date,
            rto_tax_validity, permit_validity, fitness_validity, pollution_validity, insurance_validity,
            kms_reading, tracking_device_vendor, tracking_device_type, gps_status,
            key_quantity, jack, jack_rod, spanner, parking_triangle, fire_extinguishers,
            seat_cover, floor_carpet, cng_plate, cng_installation_date,
            pdi_status, platform, pdi_timestamp, pdi_email_address, pdi_city, pdi_reg_no,
            mds_timestamp, mds_email_address, mds_vehicle_number, sheet_row_number,
            rc_document, permit_document, fitness_document, pollution_document, insurance_document,
            insurance_endorsement, invoice_copy, key_photo_url,
            image_front, image_back, image_lh, image_rh,
            engine_chasis_no_img, battery_sl_no_img, engine_compartment_img,
            fast_tag_img, music_system_img,
            rh_fr_tyre_brand_sl_no, lh_fr_tyre_brand_sl_no, rh_rear_tyre_brand_sl_no,
            lh_rear_tyre_brand_sl_no, spare_wheel_brand_sl_no, battery_sl_no,
            comments, chassis_review_flag,
            is_deleted, created_at, updated_at
        ) VALUES (
            'GOOGLE_SHEET', 'sheet_vehicle_onboarding', NEW.id,
            v_clean_plate, LEFT(COALESCE(NEW.letzryd_unique_vehicle_no, NEW.letzryd_serial_number), 100), LEFT(NEW.chassis_no, 100), LEFT(NEW.engine_no, 100),
            v_clean_city, LEFT(NEW.model, 100), 'CNG', LEFT(NEW.dealer, 255), LEFT(NEW.registered_owner_name, 255),
            LEFT(NEW.ownership, 100), LEFT(NEW.financier, 255), LEFT(NEW.hp, 100), LEFT(NEW.mfg_mm_yy, 50), LEFT(NEW.ageing, 50), LEFT(COALESCE(NEW.vehicle_status, 'ACTIVE'), 100),
            LEFT(NEW.received_or_allocated, 100), LEFT(NEW.delivered_month_y, 100), NEW.registration_date, NEW.delivery_date, NEW.payment_date,
            NEW.rto_tax_validity, NEW.permit_validity, NEW.fitness_validity, NEW.pollution_validity, NEW.insurance_validity,
            NEW.kms_reading, LEFT(NEW.tracking_device_vendor, 100), LEFT(NEW.tracking_device_type, 100), LEFT(NEW.gps, 100),
            LEFT(NEW.key_quantity, 50), LEFT(NEW.jack, 50), LEFT(NEW.jack_rod, 50), LEFT(NEW.spanner, 50), LEFT(NEW.parking_triangle, 50), LEFT(NEW.fire_extinguishers, 50),
            LEFT(NEW.seat_cover, 50), LEFT(NEW.floor_carpet, 50), LEFT(NEW.cng_plate, 100), NEW.cng_installation_date,
            LEFT(NEW.pdi_status, 100), LEFT(NEW.platform, 100), 
            (NEW.pdi_timestamp AT TIME ZONE 'Asia/Kolkata')::TIMESTAMP, LEFT(NEW.pdi_email_address, 255), LEFT(NEW.pdi_city, 100), LEFT(NEW.pdi_reg_no, 50),
            (NEW.mds_timestamp AT TIME ZONE 'Asia/Kolkata')::TIMESTAMP, LEFT(NEW.mds_email_address, 255), LEFT(NEW.mds_vehicle_number, 50), NEW.sheet_row_number,
            NEW.registration_certificate, NEW.permit, NEW.fitness, NEW.pollution, NEW.insurance,
            NEW.insurance_endorsement, NEW.invoice_copy, NEW.key_photo_url,
            COALESCE(NEW.front_photo, NEW.vehicle_image_front), COALESCE(NEW.back_photo, NEW.vehicle_image_back),
            NEW.vehicle_image_lh, NEW.vehicle_image_rh,
            NEW.engine_and_chasis_no, NEW.battery_sl_no, NEW.engine_compartment,
            NEW.fast_tag_image_from_inside, NEW.music_system_image,
            NEW.rh_fr_tyre_brand_sl_no, NEW.lh_fr_tyre_brand_sl_no, NEW.rh_rear_tyre_brand_sl_no,
            NEW.lh_rear_tyre_brand_sl_no, NEW.spare_wheel_brand_sl_no, LEFT(NEW.battery_sl_no, 100),
            NEW.comments, (LENGTH(TRIM(COALESCE(NEW.chassis_no, ''))) != 17),
            FALSE, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- 5. Trigger Attachments
-- =============================================================================

DROP TRIGGER IF EXISTS trg_sync_core_veh_from_portal ON public.july_vehicle_onboarding;
CREATE TRIGGER trg_sync_core_veh_from_portal
AFTER INSERT OR UPDATE OR DELETE ON public.july_vehicle_onboarding
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_vehicle_from_portal();

DROP TRIGGER IF EXISTS trg_sync_core_veh_from_sheet ON public.sheet_vehicle_onboarding;
CREATE TRIGGER trg_sync_core_veh_from_sheet
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_vehicle_onboarding
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_vehicle_from_sheet();
