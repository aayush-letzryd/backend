-- =============================================================================
-- LetzRyd Vehicle Allocation Single Source of Truth: public.core_vehicle_allocation
-- =============================================================================
-- Master table unifying vehicle allocation and handover records from:
--   1. public.sheet_vehicle_allocations (Google Sheets operational form)
--   2. public.july_allocation_form (Web Portal digital vehicle allocation workflow)
--
-- Architectural Guarantees:
--   - Dual-Source Automatic Merging:
--       * Records sharing (allocation_date, vehicle_number, partner_id) merge seamlessly
--         into a single row with source_origin = 'MERGED'.
--   - Gapless 1..N ID Sequence (Zero Sequence Thrashing):
--       * Uses pg_advisory_xact_lock(888999111) and continuous MAX(id) + 1 numbering.
--   - Pure IST Timestamps (Zero Timezone Shift):
--       * All timestamps stored as TIMESTAMP WITHOUT TIME ZONE in Indian Standard Time (IST).
--   - Soft Delete Protection:
--       * Deletions in upstream tables set is_deleted = TRUE and deleted_at = CURRENT_TIMESTAMP.
--   - 19 Verified Column Mappings:
--       * city / city_name -> city
--       * operator_driver_id / driver_id -> partner_id
--       * upload_agreement / driver_agreement_doc -> driver_agreement_doc
--       * front_car_photo / photo_front_side -> photo_front_side
--       * back_car_photo / photo_back_side -> photo_back_side
--       * lh_car_photo / photo_lh_side -> photo_lh_side
--       * rh_car_photo / photo_rh_side -> photo_rh_side
--       * driver_with_car_photo / vehicle_driver_photo -> vehicle_driver_photo
--       * jack / insp_jack -> jack
--       * jack_rod_tommy / insp_jack_rod -> jack_rod_tommy
--       * spanner_pana / insp_spanner -> spanner_pana
--       * stepney_tyre / insp_stepney -> stepney_tyre
--       * parking_triangle / insp_parking_triangle -> parking_triangle
--       * fire_extinguishers / insp_fire_extinguishers -> fire_extinguishers
--       * floor_carpet / insp_floor_carpet -> floor_carpet
--       * seat_cover / insp_seat_cover -> seat_cover
--       * music_system / insp_music_system -> music_system
--       * ola_negative_amount / ola_negative_balance -> ola_negative_balance
--       * ola_negative_amount_ss / ola_negative_balance_proof -> ola_negative_balance_proof
-- =============================================================================

-- 1. Master Table Definition
CREATE TABLE IF NOT EXISTS public.core_vehicle_allocation (
    id BIGSERIAL PRIMARY KEY,

    -- Provenance & Source References
    source_origin VARCHAR(50) NOT NULL, -- 'GOOGLE_SHEET', 'PORTAL_FORM', 'MERGED'
    sheet_record_id BIGINT,             -- Pointer to sheet_vehicle_allocations.id
    portal_record_id INTEGER,           -- Pointer to july_allocation_form.id

    -- Core Allocation Identifiers (Cleaned / Canonical)
    allocation_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    partner_id VARCHAR(50) NOT NULL,
    driver_phone VARCHAR(20) NOT NULL,
    driver_name VARCHAR(255) NOT NULL,
    city VARCHAR(100) NOT NULL,
    allocation_type VARCHAR(100) NOT NULL,
    sub_type VARCHAR(100),
    car_model VARCHAR(100),
    hub_name VARCHAR(100),

    -- Plan & Commercial Details
    driver_plan VARCHAR(100),
    type_of_plan VARCHAR(100),
    rental_plan VARCHAR(100),
    partner_type VARCHAR(50),

    -- Telematics & Vehicle State
    odometer_reading INTEGER,
    gps_active VARCHAR(10),
    duplicate_key_status VARCHAR(10),

    -- Financial Balances & Penalties
    ola_negative_balance NUMERIC(12, 2),
    ola_negative_balance_proof TEXT,
    fastag_balance_amount NUMERIC(12, 2),
    fastag_balance_proof TEXT,
    damage_penalty NUMERIC(12, 2),
    deposit_refund_status VARCHAR(50),
    pending_dues NUMERIC(12, 2),

    -- Documents & Media (Cloud / Drive URLs)
    driver_agreement_doc TEXT,
    photo_front_side TEXT,
    photo_back_side TEXT,
    photo_lh_side TEXT,
    photo_rh_side TEXT,
    vehicle_driver_photo TEXT,
    battery_photo TEXT,
    odometer_photo TEXT,
    police_verification_doc TEXT,
    insp_stepney_photo TEXT,
    customer_address TEXT,

    -- Financial Security Cheques
    security_cheque_1 TEXT,
    security_cheque_2 TEXT,
    security_cheque_3 TEXT,
    security_cheque_4 TEXT,
    security_cheques TEXT,

    -- Toolkit & Accessories Inspection (Handover Checklist)
    jack VARCHAR(50),
    jack_rod_tommy VARCHAR(50),
    spanner_pana VARCHAR(50),
    stepney_tyre VARCHAR(50),
    parking_triangle VARCHAR(50),
    fire_extinguishers VARCHAR(50),
    floor_carpet VARCHAR(50),
    seat_cover VARCHAR(50),
    music_system VARCHAR(50),
    insp_remarks TEXT,

    -- Vehicle Swap & Drop-Off Return Audit
    old_vehicle_number VARCHAR(50),
    dropoff_odometer NUMERIC(12, 2),
    dropoff_remarks TEXT,
    dropoff_photo TEXT,
    dropoff_location VARCHAR(50),
    manual_dropoff_location TEXT,
    jama_form_filled BOOLEAN,
    pdi_completed BOOLEAN,
    ret_jack VARCHAR(30),
    ret_jack_rod VARCHAR(30),
    ret_spanner VARCHAR(30),
    ret_parking_triangle VARCHAR(30),
    ret_fire_extinguishers VARCHAR(30),
    ret_seat_cover VARCHAR(30),
    ret_floor_carpet VARCHAR(30),
    ret_music_system VARCHAR(30),
    ret_insp_remarks TEXT,

    -- Operational & Workflow Approvals
    status VARCHAR(50) DEFAULT 'Submitted',
    created_by INTEGER,
    updated_by INTEGER,
    current_approver_id INTEGER,
    approval_status VARCHAR(50),
    approved_by INTEGER,
    approval_remarks TEXT,
    reason_to_visit VARCHAR(255),
    vehicle_manager_poc VARCHAR(100),
    submitter_email VARCHAR(255),
    sheet_row_number INTEGER,

    -- Temporal Audit Fields (Clean IST Timestamps without +05:30)
    submission_timestamp TIMESTAMP WITHOUT TIME ZONE,
    event_date_time TIMESTAMP WITHOUT TIME ZONE,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
);

-- Partial Unique Constraints for Provenance Pointers
CREATE UNIQUE INDEX IF NOT EXISTS uq_cva_sheet_record_id
    ON public.core_vehicle_allocation (sheet_record_id) WHERE sheet_record_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cva_alloc_event
    ON public.core_vehicle_allocation (allocation_date, vehicle_number, partner_id);

-- Performance & Reporting Indexes
CREATE INDEX IF NOT EXISTS idx_cva_alloc_date_veh ON public.core_vehicle_allocation (allocation_date, vehicle_number);
CREATE INDEX IF NOT EXISTS idx_cva_partner_id ON public.core_vehicle_allocation (partner_id);
CREATE INDEX IF NOT EXISTS idx_cva_alloc_date_partner ON public.core_vehicle_allocation (allocation_date, partner_id);
CREATE INDEX IF NOT EXISTS idx_cva_veh_num ON public.core_vehicle_allocation (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_cva_driver_phone ON public.core_vehicle_allocation (driver_phone);
CREATE INDEX IF NOT EXISTS idx_cva_city ON public.core_vehicle_allocation (city);
CREATE INDEX IF NOT EXISTS idx_cva_source_origin ON public.core_vehicle_allocation (source_origin);
CREATE INDEX IF NOT EXISTS idx_cva_active ON public.core_vehicle_allocation (is_deleted);
CREATE INDEX IF NOT EXISTS idx_cva_portal_id ON public.core_vehicle_allocation (portal_record_id);


-- -----------------------------------------------------------------------------
-- 2. Trigger Function: Sync from sheet_vehicle_allocations
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_core_allocation_from_sheet()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_vnum VARCHAR(20);
    v_norm_partner_id VARCHAR(50);
    v_clean_phone VARCHAR(20);
    v_clean_city VARCHAR(100);
    v_clean_alloc_type VARCHAR(100);
    v_clean_name VARCHAR(255);
    v_existing_id BIGINT;
    v_existing_portal_id INTEGER;
    v_source_origin VARCHAR(50);
    v_next_id BIGINT;
    v_sub_ts TIMESTAMP WITHOUT TIME ZONE;
    v_created_ts TIMESTAMP WITHOUT TIME ZONE;
    v_updated_ts TIMESTAMP WITHOUT TIME ZONE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_vehicle_allocation
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE sheet_record_id = OLD.id;
        RETURN OLD;
    END IF;

    -- Normalization
    v_clean_vnum := UPPER(REGEXP_REPLACE(COALESCE(NEW.vehicle_number, ''), '[^A-Z0-9]', '', 'g'));
    v_norm_partner_id := REGEXP_REPLACE(UPPER(TRIM(COALESCE(NEW.operator_driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP');
    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(NEW.driver_phone, ''), '\D', '', 'g'), 10);

    -- Gatekeeper check
    IF NEW.allocation_date IS NULL OR LENGTH(v_clean_vnum) NOT BETWEEN 8 AND 12 OR v_norm_partner_id !~ '^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$' THEN
        RETURN NEW;
    END IF;

    -- City canonicalization
    v_clean_city := CASE 
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('bangalore', 'bengaluru', 'blr') THEN 'Bengaluru'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('hyderabad', 'hyd') THEN 'Hyderabad'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('mumbai', 'mum') THEN 'Mumbai'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('pune', 'pun') THEN 'Pune'
        ELSE LEFT(INITCAP(TRIM(COALESCE(NEW.city, 'Unknown'))), 100)
    END;

    -- Allocation type standardization
    v_clean_alloc_type := CASE
        WHEN LOWER(TRIM(COALESCE(NEW.allocation_type, ''))) IN ('fresh allocation', 'allocation', 'new allocation') THEN 'New Allocation'
        WHEN LOWER(TRIM(COALESCE(NEW.allocation_type, ''))) IN ('swap', 'car swap') THEN 'Car Swap'
        WHEN LOWER(TRIM(COALESCE(NEW.allocation_type, ''))) = 'reallocation' THEN 'Reallocation'
        WHEN LOWER(TRIM(COALESCE(NEW.allocation_type, ''))) = 'drop-off' THEN 'Drop-Off'
        ELSE INITCAP(TRIM(COALESCE(NEW.allocation_type, 'New Allocation')))
    END;

    v_clean_name := LEFT(TRIM(REGEXP_REPLACE(COALESCE(NEW.driver_name, 'UNKNOWN'), '\s+', ' ', 'g')), 255);
    IF v_clean_name = '' OR v_clean_name IS NULL THEN v_clean_name := 'UNKNOWN'; END IF;

    v_sub_ts := NEW.submission_timestamp AT TIME ZONE 'Asia/Kolkata';
    v_created_ts := COALESCE(NEW.created_at AT TIME ZONE 'Asia/Kolkata', (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'));
    v_updated_ts := COALESCE(NEW.updated_at AT TIME ZONE 'Asia/Kolkata', (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'));

    PERFORM pg_advisory_xact_lock(888999111);

    -- Check if record exists on (allocation_date, vehicle_number, partner_id) or sheet_record_id
    SELECT id, portal_record_id 
    INTO v_existing_id, v_existing_portal_id
    FROM public.core_vehicle_allocation
    WHERE (sheet_record_id = NEW.id) 
       OR (allocation_date = NEW.allocation_date AND vehicle_number = v_clean_vnum AND partner_id = v_norm_partner_id)
    ORDER BY (sheet_record_id = NEW.id) DESC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        -- Record exists: Update in place & mark MERGED if portal record exists
        IF v_existing_portal_id IS NOT NULL THEN
            v_source_origin := 'MERGED';
        ELSE
            v_source_origin := 'GOOGLE_SHEET';
        END IF;

        UPDATE public.core_vehicle_allocation SET
            source_origin = v_source_origin,
            sheet_record_id = NEW.id,
            allocation_date = NEW.allocation_date,
            vehicle_number = v_clean_vnum,
            partner_id = v_norm_partner_id,
            driver_phone = v_clean_phone,
            driver_name = v_clean_name,
            city = v_clean_city,
            allocation_type = v_clean_alloc_type,
            car_model = LEFT(NEW.car_model, 100),
            driver_plan = LEFT(NEW.driver_plan, 100),
            type_of_plan = LEFT(NEW.type_of_plan, 100),
            rental_plan = LEFT(NEW.rental_plan, 100),
            partner_type = LEFT(NEW.partner_type, 50),
            odometer_reading = NEW.odometer_reading,
            ola_negative_balance = COALESCE(NEW.ola_negative_amount, ola_negative_balance),
            ola_negative_balance_proof = COALESCE(NEW.ola_negative_amount_ss, ola_negative_balance_proof),
            driver_agreement_doc = COALESCE(NEW.upload_agreement, driver_agreement_doc),
            vehicle_driver_photo = COALESCE(NEW.driver_with_car_photo, vehicle_driver_photo),
            photo_front_side = COALESCE(NEW.front_car_photo, photo_front_side),
            photo_lh_side = COALESCE(NEW.lh_car_photo, photo_lh_side),
            photo_rh_side = COALESCE(NEW.rh_car_photo, photo_rh_side),
            photo_back_side = COALESCE(NEW.back_car_photo, photo_back_side),
            battery_photo = COALESCE(NEW.battery_photo, battery_photo),
            stepney_tyre = COALESCE(NEW.stepney_tyre, stepney_tyre),
            spanner_pana = COALESCE(NEW.spanner_pana, spanner_pana),
            jack = COALESCE(NEW.jack, jack),
            jack_rod_tommy = COALESCE(NEW.jack_rod_tommy, jack_rod_tommy),
            parking_triangle = COALESCE(NEW.parking_triangle, parking_triangle),
            fire_extinguishers = COALESCE(NEW.fire_extinguishers, fire_extinguishers),
            floor_carpet = COALESCE(NEW.floor_carpet, floor_carpet),
            seat_cover = COALESCE(NEW.seat_cover, seat_cover),
            music_system = COALESCE(NEW.music_system, music_system),
            vehicle_manager_poc = LEFT(NEW.vehicle_manager_poc, 100),
            reason_to_visit = LEFT(NEW.reason_to_visit, 255),
            submitter_email = LEFT(NEW.submitter_email, 255),
            sheet_row_number = NEW.sheet_row_number,
            submission_timestamp = v_sub_ts,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = v_updated_ts
        WHERE id = v_existing_id;

    ELSE
        -- Record does not exist: insert new with MAX(id) + 1
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_vehicle_allocation;

        INSERT INTO public.core_vehicle_allocation (
            id, source_origin, sheet_record_id, portal_record_id,
            allocation_date, vehicle_number, partner_id, driver_phone, driver_name,
            city, allocation_type, sub_type, car_model, hub_name,
            driver_plan, type_of_plan, rental_plan, partner_type,
            odometer_reading, ola_negative_balance, ola_negative_balance_proof,
            fastag_balance_amount, fastag_balance_proof, damage_penalty, deposit_refund_status, pending_dues, gps_active, duplicate_key_status,
            driver_agreement_doc, photo_front_side, photo_back_side, photo_lh_side, photo_rh_side, vehicle_driver_photo, battery_photo, odometer_photo, police_verification_doc, insp_stepney_photo, customer_address,
            security_cheque_1, security_cheque_2, security_cheque_3, security_cheque_4, security_cheques,
            jack, jack_rod_tommy, spanner_pana, stepney_tyre, parking_triangle, fire_extinguishers, floor_carpet, seat_cover, music_system, insp_remarks,
            old_vehicle_number, dropoff_odometer, dropoff_remarks, dropoff_photo, dropoff_location, manual_dropoff_location, jama_form_filled, pdi_completed,
            ret_jack, ret_jack_rod, ret_spanner, ret_parking_triangle, ret_fire_extinguishers, ret_seat_cover, ret_floor_carpet, ret_music_system, ret_insp_remarks,
            status, created_by, updated_by, current_approver_id, approval_status, approved_by, approval_remarks,
            reason_to_visit, vehicle_manager_poc, submitter_email, sheet_row_number,
            submission_timestamp, event_date_time, is_deleted, deleted_at, created_at, updated_at
        ) VALUES (
            v_next_id, 'GOOGLE_SHEET', NEW.id, NULL,
            NEW.allocation_date, v_clean_vnum, v_norm_partner_id, v_clean_phone, v_clean_name,
            v_clean_city, v_clean_alloc_type, NULL, LEFT(NEW.car_model, 100), NULL,
            LEFT(NEW.driver_plan, 100), LEFT(NEW.type_of_plan, 100), LEFT(NEW.rental_plan, 100), LEFT(NEW.partner_type, 50),
            NEW.odometer_reading, NEW.ola_negative_amount, NEW.ola_negative_amount_ss,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            NEW.upload_agreement, NEW.front_car_photo, NEW.back_car_photo, NEW.lh_car_photo, NEW.rh_car_photo, NEW.driver_with_car_photo, NEW.battery_photo, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL, NULL,
            NEW.jack, NEW.jack_rod_tommy, NEW.spanner_pana, NEW.stepney_tyre, NEW.parking_triangle, NEW.fire_extinguishers, NEW.floor_carpet, NEW.seat_cover, NEW.music_system, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            'Submitted', NULL, NULL, NULL, NULL, NULL, NULL,
            LEFT(NEW.reason_to_visit, 255), LEFT(NEW.vehicle_manager_poc, 100), LEFT(NEW.submitter_email, 255), NEW.sheet_row_number,
            v_sub_ts, NULL, FALSE, NULL, v_created_ts, v_updated_ts
        );

        PERFORM setval('public.core_vehicle_allocation_id_seq', v_next_id, true);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_allocation_from_sheet ON public.sheet_vehicle_allocations;
CREATE TRIGGER trg_sync_core_allocation_from_sheet
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_vehicle_allocations
FOR EACH ROW EXECUTE FUNCTION public.sync_core_allocation_from_sheet();


-- -----------------------------------------------------------------------------
-- 3. Trigger Function: Sync from july_allocation_form
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_core_allocation_from_portal()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_vnum VARCHAR(20);
    v_norm_partner_id VARCHAR(50);
    v_clean_phone VARCHAR(20);
    v_clean_city VARCHAR(100);
    v_clean_alloc_type VARCHAR(100);
    v_clean_name VARCHAR(255);
    v_existing_id BIGINT;
    v_existing_sheet_id BIGINT;
    v_source_origin VARCHAR(50);
    v_next_id BIGINT;
    v_event_ts TIMESTAMP WITHOUT TIME ZONE;
    v_created_ts TIMESTAMP WITHOUT TIME ZONE;
    v_updated_ts TIMESTAMP WITHOUT TIME ZONE;
    v_odo_val INTEGER;
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_vehicle_allocation
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE portal_record_id = OLD.id;
        RETURN OLD;
    END IF;

    -- Normalization
    v_clean_vnum := UPPER(REGEXP_REPLACE(COALESCE(NEW.vehicle_number, ''), '[^A-Z0-9]', '', 'g'));
    v_norm_partner_id := REGEXP_REPLACE(UPPER(TRIM(COALESCE(NEW.driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP');
    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(NEW.driver_phone, ''), '\D', '', 'g'), 10);

    -- Gatekeeper check (Rejects 51 test records!)
    IF NEW.allocation_date IS NULL OR LENGTH(v_clean_vnum) NOT BETWEEN 8 AND 12 OR v_norm_partner_id !~ '^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$' THEN
        RETURN NEW;
    END IF;

    -- City canonicalization
    v_clean_city := CASE 
        WHEN LOWER(TRIM(COALESCE(NEW.city_name, ''))) IN ('bangalore', 'bengaluru', 'blr') THEN 'Bengaluru'
        WHEN LOWER(TRIM(COALESCE(NEW.city_name, ''))) IN ('hyderabad', 'hyd') THEN 'Hyderabad'
        WHEN LOWER(TRIM(COALESCE(NEW.city_name, ''))) IN ('mumbai', 'mum') THEN 'Mumbai'
        WHEN LOWER(TRIM(COALESCE(NEW.city_name, ''))) IN ('pune', 'pun') THEN 'Pune'
        ELSE LEFT(INITCAP(TRIM(COALESCE(NEW.city_name, 'Unknown'))), 100)
    END;

    -- Allocation type standardization
    v_clean_alloc_type := CASE
        WHEN LOWER(TRIM(COALESCE(NEW.allocation_type, ''))) IN ('fresh allocation', 'allocation', 'new allocation') THEN 'New Allocation'
        WHEN LOWER(TRIM(COALESCE(NEW.allocation_type, ''))) IN ('swap', 'car swap') THEN 'Car Swap'
        WHEN LOWER(TRIM(COALESCE(NEW.allocation_type, ''))) = 'reallocation' THEN 'Reallocation'
        WHEN LOWER(TRIM(COALESCE(NEW.allocation_type, ''))) = 'drop-off' THEN 'Drop-Off'
        ELSE INITCAP(TRIM(COALESCE(NEW.allocation_type, 'New Allocation')))
    END;

    v_clean_name := LEFT(TRIM(REGEXP_REPLACE(COALESCE(NEW.driver_name, 'UNKNOWN'), '\s+', ' ', 'g')), 255);
    IF v_clean_name = '' OR v_clean_name IS NULL THEN v_clean_name := 'UNKNOWN'; END IF;

    -- Odometer reading parsing
    v_odo_val := CASE 
        WHEN NEW.odometer_reading ~ '^[0-9]+(\.[0-9]+)?$' THEN ROUND(NEW.odometer_reading::numeric)::integer
        ELSE NULL
    END;

    v_event_ts := NEW.event_date_time AT TIME ZONE 'Asia/Kolkata';
    v_created_ts := COALESCE(NEW.created_at AT TIME ZONE 'Asia/Kolkata', (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'));
    v_updated_ts := COALESCE(NEW.updated_at AT TIME ZONE 'Asia/Kolkata', (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'));

    PERFORM pg_advisory_xact_lock(888999111);

    -- Check if record exists on (allocation_date, vehicle_number, partner_id) or portal_record_id
    SELECT id, sheet_record_id 
    INTO v_existing_id, v_existing_sheet_id
    FROM public.core_vehicle_allocation
    WHERE (portal_record_id = NEW.id) 
       OR (allocation_date = NEW.allocation_date AND vehicle_number = v_clean_vnum AND partner_id = v_norm_partner_id)
    ORDER BY (portal_record_id = NEW.id) DESC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        -- Record exists: overlay portal inspection data, photos, cheques & mark MERGED
        IF v_existing_sheet_id IS NOT NULL THEN
            v_source_origin := 'MERGED';
        ELSE
            v_source_origin := 'PORTAL_FORM';
        END IF;

        UPDATE public.core_vehicle_allocation SET
            source_origin = v_source_origin,
            portal_record_id = NEW.id,
            allocation_date = NEW.allocation_date,
            vehicle_number = v_clean_vnum,
            partner_id = v_norm_partner_id,
            driver_phone = COALESCE(NULLIF(v_clean_phone, ''), driver_phone),
            driver_name = COALESCE(NULLIF(v_clean_name, 'UNKNOWN'), driver_name),
            city = COALESCE(NULLIF(v_clean_city, 'Unknown'), city),
            allocation_type = COALESCE(v_clean_alloc_type, allocation_type),
            sub_type = LEFT(NEW.sub_type, 100),
            car_model = COALESCE(LEFT(NEW.car_model, 100), car_model),
            hub_name = LEFT(NEW.hub_name, 100),
            driver_plan = COALESCE(LEFT(NEW.driver_plan, 100), driver_plan),
            type_of_plan = COALESCE(LEFT(NEW.type_of_plan, 100), type_of_plan),
            gps_active = LEFT(NEW.gps_active, 10),
            ola_negative_balance = COALESCE(NEW.ola_negative_balance, ola_negative_balance),
            ola_negative_balance_proof = COALESCE(NEW.ola_negative_balance_proof, ola_negative_balance_proof),
            fastag_balance_amount = NEW.fastag_balance_amount,
            fastag_balance_proof = NEW.fastag_balance_proof,
            damage_penalty = NEW.damage_penalty,
            deposit_refund_status = LEFT(NEW.deposit_refund_status, 50),
            pending_dues = NEW.pending_dues,
            duplicate_key_status = LEFT(NEW.duplicate_key_status, 10),
            driver_agreement_doc = COALESCE(NEW.driver_agreement_doc, driver_agreement_doc),
            photo_front_side = COALESCE(NEW.photo_front_side, photo_front_side),
            photo_back_side = COALESCE(NEW.photo_back_side, photo_back_side),
            photo_lh_side = COALESCE(NEW.photo_lh_side, photo_lh_side),
            photo_rh_side = COALESCE(NEW.photo_rh_side, photo_rh_side),
            vehicle_driver_photo = COALESCE(NEW.vehicle_driver_photo, vehicle_driver_photo),
            battery_photo = COALESCE(NEW.battery_photo, battery_photo),
            odometer_photo = NEW.odometer_photo,
            insp_stepney_photo = NEW.insp_stepney_photo,
            police_verification_doc = NEW.police_verification_doc,
            customer_address = NEW.customer_address,
            security_cheque_1 = NEW.security_cheque_1,
            security_cheque_2 = NEW.security_cheque_2,
            security_cheque_3 = NEW.security_cheque_3,
            security_cheque_4 = NEW.security_cheque_4,
            security_cheques = NEW.security_cheques,
            jack = COALESCE(NEW.insp_jack, jack),
            jack_rod_tommy = COALESCE(NEW.insp_jack_rod, jack_rod_tommy),
            spanner_pana = COALESCE(NEW.insp_spanner, spanner_pana),
            stepney_tyre = COALESCE(NEW.insp_stepney, stepney_tyre),
            parking_triangle = COALESCE(NEW.insp_parking_triangle, parking_triangle),
            fire_extinguishers = COALESCE(NEW.insp_fire_extinguishers, fire_extinguishers),
            floor_carpet = COALESCE(NEW.insp_floor_carpet, floor_carpet),
            seat_cover = COALESCE(NEW.insp_seat_cover, seat_cover),
            music_system = COALESCE(NEW.insp_music_system, music_system),
            insp_remarks = NEW.insp_remarks,
            old_vehicle_number = LEFT(NEW.old_vehicle_number, 50),
            dropoff_odometer = NEW.dropoff_odometer,
            dropoff_remarks = NEW.dropoff_remarks,
            dropoff_photo = NEW.dropoff_photo,
            dropoff_location = LEFT(NEW.dropoff_location, 50),
            manual_dropoff_location = NEW.manual_dropoff_location,
            jama_form_filled = NEW.jama_form_filled,
            pdi_completed = NEW.pdi_completed,
            ret_jack = LEFT(NEW.ret_jack, 30),
            ret_jack_rod = LEFT(NEW.ret_jack_rod, 30),
            ret_spanner = LEFT(NEW.ret_spanner, 30),
            ret_parking_triangle = LEFT(NEW.ret_parking_triangle, 30),
            ret_fire_extinguishers = LEFT(NEW.ret_fire_extinguishers, 30),
            ret_seat_cover = LEFT(NEW.ret_seat_cover, 30),
            ret_floor_carpet = LEFT(NEW.ret_floor_carpet, 30),
            ret_music_system = LEFT(NEW.ret_music_system, 30),
            ret_insp_remarks = NEW.ret_insp_remarks,
            status = COALESCE(LEFT(NEW.status, 50), status),
            created_by = COALESCE(NEW.created_by, created_by),
            updated_by = COALESCE(NEW.updated_by, updated_by),
            current_approver_id = NEW.current_approver_id,
            approval_status = LEFT(NEW.approval_status, 50),
            approved_by = NEW.approved_by,
            approval_remarks = NEW.approval_remarks,
            odometer_reading = COALESCE(v_odo_val, odometer_reading),
            event_date_time = COALESCE(v_event_ts, event_date_time),
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = v_updated_ts
        WHERE id = v_existing_id;

    ELSE
        -- Record does not exist: insert new with MAX(id) + 1
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_vehicle_allocation;

        INSERT INTO public.core_vehicle_allocation (
            id, source_origin, sheet_record_id, portal_record_id,
            allocation_date, vehicle_number, partner_id, driver_phone, driver_name,
            city, allocation_type, sub_type, car_model, hub_name,
            driver_plan, type_of_plan, rental_plan, partner_type,
            odometer_reading, ola_negative_balance, ola_negative_balance_proof,
            fastag_balance_amount, fastag_balance_proof, damage_penalty, deposit_refund_status, pending_dues, gps_active, duplicate_key_status,
            driver_agreement_doc, photo_front_side, photo_back_side, photo_lh_side, photo_rh_side, vehicle_driver_photo, battery_photo, odometer_photo, police_verification_doc, insp_stepney_photo, customer_address,
            security_cheque_1, security_cheque_2, security_cheque_3, security_cheque_4, security_cheques,
            jack, jack_rod_tommy, spanner_pana, stepney_tyre, parking_triangle, fire_extinguishers, floor_carpet, seat_cover, music_system, insp_remarks,
            old_vehicle_number, dropoff_odometer, dropoff_remarks, dropoff_photo, dropoff_location, manual_dropoff_location, jama_form_filled, pdi_completed,
            ret_jack, ret_jack_rod, ret_spanner, ret_parking_triangle, ret_fire_extinguishers, ret_seat_cover, ret_floor_carpet, ret_music_system, ret_insp_remarks,
            status, created_by, updated_by, current_approver_id, approval_status, approved_by, approval_remarks,
            reason_to_visit, vehicle_manager_poc, submitter_email, sheet_row_number,
            submission_timestamp, event_date_time, is_deleted, deleted_at, created_at, updated_at
        ) VALUES (
            v_next_id, 'PORTAL_FORM', NULL, NEW.id,
            NEW.allocation_date, v_clean_vnum, v_norm_partner_id, v_clean_phone, v_clean_name,
            v_clean_city, v_clean_alloc_type, LEFT(NEW.sub_type, 100), LEFT(NEW.car_model, 100), LEFT(NEW.hub_name, 100),
            LEFT(NEW.driver_plan, 100), LEFT(NEW.type_of_plan, 100), NULL, NULL,
            v_odo_val, NEW.ola_negative_balance, NEW.ola_negative_balance_proof,
            NEW.fastag_balance_amount, NEW.fastag_balance_proof, NEW.damage_penalty, LEFT(NEW.deposit_refund_status, 50), NEW.pending_dues, LEFT(NEW.gps_active, 10), LEFT(NEW.duplicate_key_status, 10),
            NEW.driver_agreement_doc, NEW.photo_front_side, NEW.photo_back_side, NEW.photo_lh_side, NEW.photo_rh_side, NEW.vehicle_driver_photo, NEW.battery_photo, NEW.odometer_photo, NEW.police_verification_doc, NEW.insp_stepney_photo, NEW.customer_address,
            NEW.security_cheque_1, NEW.security_cheque_2, NEW.security_cheque_3, NEW.security_cheque_4, NEW.security_cheques,
            NEW.insp_jack, NEW.insp_jack_rod, NEW.insp_spanner, NEW.insp_stepney, NEW.insp_parking_triangle, NEW.insp_fire_extinguishers, NEW.insp_floor_carpet, NEW.insp_seat_cover, NEW.insp_music_system, NEW.insp_remarks,
            LEFT(NEW.old_vehicle_number, 50), NEW.dropoff_odometer, NEW.dropoff_remarks, NEW.dropoff_photo, LEFT(NEW.dropoff_location, 50), NEW.manual_dropoff_location, NEW.jama_form_filled, NEW.pdi_completed,
            LEFT(NEW.ret_jack, 30), LEFT(NEW.ret_jack_rod, 30), LEFT(NEW.ret_spanner, 30), LEFT(NEW.ret_parking_triangle, 30), LEFT(NEW.ret_fire_extinguishers, 30), LEFT(NEW.ret_seat_cover, 30), LEFT(NEW.ret_floor_carpet, 30), LEFT(NEW.ret_music_system, 30), NEW.ret_insp_remarks,
            COALESCE(LEFT(NEW.status, 50), 'Submitted'), NEW.created_by, NEW.updated_by, NEW.current_approver_id, LEFT(NEW.approval_status, 50), NEW.approved_by, NEW.approval_remarks,
            NULL, NULL, NULL, NULL,
            NULL, v_event_ts, FALSE, NULL, v_created_ts, v_updated_ts
        );

        PERFORM setval('public.core_vehicle_allocation_id_seq', v_next_id, true);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_allocation_from_portal ON public.july_allocation_form;
CREATE TRIGGER trg_sync_core_allocation_from_portal
AFTER INSERT OR UPDATE OR DELETE ON public.july_allocation_form
FOR EACH ROW EXECUTE FUNCTION public.sync_core_allocation_from_portal();


-- -----------------------------------------------------------------------------
-- 4. Historical Backfill Stored Procedure
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_backfill_core_vehicle_allocation()
LANGUAGE plpgsql AS $$
DECLARE
    v_sheet_count INTEGER := 0;
    v_portal_merged INTEGER := 0;
    v_portal_new INTEGER := 0;
    v_max_id BIGINT := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(888999111);

    TRUNCATE TABLE public.core_vehicle_allocation RESTART IDENTITY;

    -- Step 1: Ingest all valid records from sheet_vehicle_allocations (1..N sequence)
    INSERT INTO public.core_vehicle_allocation (
        id, source_origin, sheet_record_id, portal_record_id,
        allocation_date, vehicle_number, partner_id, driver_phone, driver_name,
        city, allocation_type, sub_type, car_model, hub_name,
        driver_plan, type_of_plan, rental_plan, partner_type,
        odometer_reading, ola_negative_balance, ola_negative_balance_proof,
        fastag_balance_amount, fastag_balance_proof, damage_penalty, deposit_refund_status, pending_dues, gps_active, duplicate_key_status,
        driver_agreement_doc, photo_front_side, photo_back_side, photo_lh_side, photo_rh_side, vehicle_driver_photo, battery_photo, odometer_photo, police_verification_doc, insp_stepney_photo, customer_address,
        security_cheque_1, security_cheque_2, security_cheque_3, security_cheque_4, security_cheques,
        jack, jack_rod_tommy, spanner_pana, stepney_tyre, parking_triangle, fire_extinguishers, floor_carpet, seat_cover, music_system, insp_remarks,
        old_vehicle_number, dropoff_odometer, dropoff_remarks, dropoff_photo, dropoff_location, manual_dropoff_location, jama_form_filled, pdi_completed,
        ret_jack, ret_jack_rod, ret_spanner, ret_parking_triangle, ret_fire_extinguishers, ret_seat_cover, ret_floor_carpet, ret_music_system, ret_insp_remarks,
        status, created_by, updated_by, current_approver_id, approval_status, approved_by, approval_remarks,
        reason_to_visit, vehicle_manager_poc, submitter_email, sheet_row_number,
        submission_timestamp, event_date_time, is_deleted, deleted_at, created_at, updated_at
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY s.allocation_date ASC, s.submission_timestamp ASC NULLS LAST, s.id ASC) AS id,
        'GOOGLE_SHEET' AS source_origin,
        s.id AS sheet_record_id,
        NULL::INTEGER AS portal_record_id,
        s.allocation_date,
        UPPER(REGEXP_REPLACE(COALESCE(s.vehicle_number, ''), '[^A-Z0-9]', '', 'g')) AS vehicle_number,
        REGEXP_REPLACE(UPPER(TRIM(COALESCE(s.operator_driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP') AS partner_id,
        RIGHT(REGEXP_REPLACE(COALESCE(s.driver_phone, ''), '\D', '', 'g'), 10) AS driver_phone,
        LEFT(TRIM(REGEXP_REPLACE(COALESCE(s.driver_name, 'UNKNOWN'), '\s+', ' ', 'g')), 255) AS driver_name,
        CASE 
            WHEN LOWER(TRIM(COALESCE(s.city, ''))) IN ('bangalore', 'bengaluru', 'blr') THEN 'Bengaluru'
            WHEN LOWER(TRIM(COALESCE(s.city, ''))) IN ('hyderabad', 'hyd') THEN 'Hyderabad'
            WHEN LOWER(TRIM(COALESCE(s.city, ''))) IN ('mumbai', 'mum') THEN 'Mumbai'
            WHEN LOWER(TRIM(COALESCE(s.city, ''))) IN ('pune', 'pun') THEN 'Pune'
            ELSE LEFT(INITCAP(TRIM(COALESCE(s.city, 'Unknown'))), 100)
        END AS city,
        CASE
            WHEN LOWER(TRIM(COALESCE(s.allocation_type, ''))) IN ('fresh allocation', 'allocation', 'new allocation') THEN 'New Allocation'
            WHEN LOWER(TRIM(COALESCE(s.allocation_type, ''))) IN ('swap', 'car swap') THEN 'Car Swap'
            WHEN LOWER(TRIM(COALESCE(s.allocation_type, ''))) = 'reallocation' THEN 'Reallocation'
            WHEN LOWER(TRIM(COALESCE(s.allocation_type, ''))) = 'drop-off' THEN 'Drop-Off'
            ELSE INITCAP(TRIM(COALESCE(s.allocation_type, 'New Allocation')))
        END AS allocation_type,
        NULL AS sub_type,
        LEFT(s.car_model, 100) AS car_model,
        NULL AS hub_name,
        LEFT(s.driver_plan, 100) AS driver_plan,
        LEFT(s.type_of_plan, 100) AS type_of_plan,
        LEFT(s.rental_plan, 100) AS rental_plan,
        LEFT(s.partner_type, 50) AS partner_type,
        s.odometer_reading,
        s.ola_negative_amount AS ola_negative_balance,
        s.ola_negative_amount_ss AS ola_negative_balance_proof,
        NULL::NUMERIC AS fastag_balance_amount,
        NULL::TEXT AS fastag_balance_proof,
        NULL::NUMERIC AS damage_penalty,
        NULL::VARCHAR AS deposit_refund_status,
        NULL::NUMERIC AS pending_dues,
        NULL::VARCHAR AS gps_active,
        NULL::VARCHAR AS duplicate_key_status,
        s.upload_agreement AS driver_agreement_doc,
        s.front_car_photo AS photo_front_side,
        s.back_car_photo AS photo_back_side,
        s.lh_car_photo AS photo_lh_side,
        s.rh_car_photo AS photo_rh_side,
        s.driver_with_car_photo AS vehicle_driver_photo,
        s.battery_photo,
        NULL::TEXT AS odometer_photo,
        NULL::TEXT AS police_verification_doc,
        NULL::TEXT AS insp_stepney_photo,
        NULL::TEXT AS customer_address,
        NULL::TEXT AS security_cheque_1,
        NULL::TEXT AS security_cheque_2,
        NULL::TEXT AS security_cheque_3,
        NULL::TEXT AS security_cheque_4,
        NULL::TEXT AS security_cheques,
        s.jack,
        s.jack_rod_tommy,
        s.spanner_pana,
        s.stepney_tyre,
        s.parking_triangle,
        s.fire_extinguishers,
        s.floor_carpet,
        s.seat_cover,
        s.music_system,
        NULL::TEXT AS insp_remarks,
        NULL::VARCHAR AS old_vehicle_number,
        NULL::NUMERIC AS dropoff_odometer,
        NULL::TEXT AS dropoff_remarks,
        NULL::TEXT AS dropoff_photo,
        NULL::VARCHAR AS dropoff_location,
        NULL::TEXT AS manual_dropoff_location,
        NULL::BOOLEAN AS jama_form_filled,
        NULL::BOOLEAN AS pdi_completed,
        NULL::VARCHAR AS ret_jack,
        NULL::VARCHAR AS ret_jack_rod,
        NULL::VARCHAR AS ret_spanner,
        NULL::VARCHAR AS ret_parking_triangle,
        NULL::VARCHAR AS ret_fire_extinguishers,
        NULL::VARCHAR AS ret_seat_cover,
        NULL::VARCHAR AS ret_floor_carpet,
        NULL::VARCHAR AS ret_music_system,
        NULL::TEXT AS ret_insp_remarks,
        'Submitted' AS status,
        NULL::INTEGER AS created_by,
        NULL::INTEGER AS updated_by,
        NULL::INTEGER AS current_approver_id,
        NULL::VARCHAR AS approval_status,
        NULL::INTEGER AS approved_by,
        NULL::TEXT AS approval_remarks,
        LEFT(s.reason_to_visit, 255) AS reason_to_visit,
        LEFT(s.vehicle_manager_poc, 100) AS vehicle_manager_poc,
        LEFT(s.submitter_email, 255) AS submitter_email,
        s.sheet_row_number,
        s.submission_timestamp AT TIME ZONE 'Asia/Kolkata' AS submission_timestamp,
        NULL::TIMESTAMP WITHOUT TIME ZONE AS event_date_time,
        FALSE AS is_deleted,
        NULL::TIMESTAMP WITHOUT TIME ZONE AS deleted_at,
        COALESCE(s.created_at AT TIME ZONE 'Asia/Kolkata', CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') AS created_at,
        COALESCE(s.updated_at AT TIME ZONE 'Asia/Kolkata', CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') AS updated_at
    FROM public.sheet_vehicle_allocations s
    WHERE s.allocation_date IS NOT NULL
      AND LENGTH(UPPER(REGEXP_REPLACE(COALESCE(s.vehicle_number, ''), '[^A-Z0-9]', '', 'g'))) BETWEEN 8 AND 12
      AND REGEXP_REPLACE(UPPER(TRIM(COALESCE(s.operator_driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP') ~ '^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$';

    GET DIAGNOSTICS v_sheet_count = ROW_COUNT;

    -- Step 2: Overlay valid records from july_allocation_form matching core events (MERGE)
    WITH portal_ranked AS (
        SELECT p.*,
               UPPER(REGEXP_REPLACE(COALESCE(p.vehicle_number, ''), '[^A-Z0-9]', '', 'g')) AS clean_vnum,
               REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP') AS norm_id,
               ROW_NUMBER() OVER (
                   PARTITION BY p.allocation_date, 
                                UPPER(REGEXP_REPLACE(COALESCE(p.vehicle_number, ''), '[^A-Z0-9]', '', 'g')),
                                REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP')
                   ORDER BY p.created_at DESC NULLS LAST, p.id DESC
               ) as rn
        FROM public.july_allocation_form p
        WHERE p.allocation_date IS NOT NULL
          AND LENGTH(UPPER(REGEXP_REPLACE(COALESCE(p.vehicle_number, ''), '[^A-Z0-9]', '', 'g'))) BETWEEN 8 AND 12
          AND REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP') ~ '^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$'
    ),
    portal_clean AS (
        SELECT * FROM portal_ranked WHERE rn = 1
    )
    UPDATE public.core_vehicle_allocation c
    SET source_origin = 'MERGED',
        portal_record_id = p.id,
        sub_type = LEFT(p.sub_type, 100),
        hub_name = LEFT(p.hub_name, 100),
        gps_active = LEFT(p.gps_active, 10),
        ola_negative_balance = COALESCE(p.ola_negative_balance, c.ola_negative_balance),
        ola_negative_balance_proof = COALESCE(p.ola_negative_balance_proof, c.ola_negative_balance_proof),
        fastag_balance_amount = p.fastag_balance_amount,
        fastag_balance_proof = p.fastag_balance_proof,
        damage_penalty = p.damage_penalty,
        deposit_refund_status = LEFT(p.deposit_refund_status, 50),
        pending_dues = p.pending_dues,
        duplicate_key_status = LEFT(p.duplicate_key_status, 10),
        driver_agreement_doc = COALESCE(p.driver_agreement_doc, c.driver_agreement_doc),
        photo_front_side = COALESCE(p.photo_front_side, c.photo_front_side),
        photo_back_side = COALESCE(p.photo_back_side, c.photo_back_side),
        photo_lh_side = COALESCE(p.photo_lh_side, c.photo_lh_side),
        photo_rh_side = COALESCE(p.photo_rh_side, c.photo_rh_side),
        vehicle_driver_photo = COALESCE(p.vehicle_driver_photo, c.vehicle_driver_photo),
        battery_photo = COALESCE(p.battery_photo, c.battery_photo),
        odometer_photo = p.odometer_photo,
        insp_stepney_photo = p.insp_stepney_photo,
        police_verification_doc = p.police_verification_doc,
        customer_address = p.customer_address,
        security_cheque_1 = p.security_cheque_1,
        security_cheque_2 = p.security_cheque_2,
        security_cheque_3 = p.security_cheque_3,
        security_cheque_4 = p.security_cheque_4,
        security_cheques = p.security_cheques,
        jack = COALESCE(p.insp_jack, c.jack),
        jack_rod_tommy = COALESCE(p.insp_jack_rod, c.jack_rod_tommy),
        spanner_pana = COALESCE(p.insp_spanner, c.spanner_pana),
        stepney_tyre = COALESCE(p.insp_stepney, c.stepney_tyre),
        parking_triangle = COALESCE(p.insp_parking_triangle, c.parking_triangle),
        fire_extinguishers = COALESCE(p.insp_fire_extinguishers, c.fire_extinguishers),
        floor_carpet = COALESCE(p.insp_floor_carpet, c.floor_carpet),
        seat_cover = COALESCE(p.insp_seat_cover, c.seat_cover),
        music_system = COALESCE(p.insp_music_system, c.music_system),
        insp_remarks = p.insp_remarks,
        old_vehicle_number = LEFT(p.old_vehicle_number, 50),
        dropoff_odometer = p.dropoff_odometer,
        dropoff_remarks = p.dropoff_remarks,
        dropoff_photo = p.dropoff_photo,
        dropoff_location = LEFT(p.dropoff_location, 50),
        manual_dropoff_location = p.manual_dropoff_location,
        jama_form_filled = p.jama_form_filled,
        pdi_completed = p.pdi_completed,
        ret_jack = LEFT(p.ret_jack, 30),
        ret_jack_rod = LEFT(p.ret_jack_rod, 30),
        ret_spanner = LEFT(p.ret_spanner, 30),
        ret_parking_triangle = LEFT(p.ret_parking_triangle, 30),
        ret_fire_extinguishers = LEFT(p.ret_fire_extinguishers, 30),
        ret_seat_cover = LEFT(p.ret_seat_cover, 30),
        ret_floor_carpet = LEFT(p.ret_floor_carpet, 30),
        ret_music_system = LEFT(p.ret_music_system, 30),
        ret_insp_remarks = p.ret_insp_remarks,
        status = COALESCE(LEFT(p.status, 50), c.status),
        created_by = COALESCE(p.created_by, c.created_by),
        updated_by = COALESCE(p.updated_by, c.updated_by),
        current_approver_id = p.current_approver_id,
        approval_status = LEFT(p.approval_status, 50),
        approved_by = p.approved_by,
        approval_remarks = p.approval_remarks,
        odometer_reading = CASE 
            WHEN p.odometer_reading ~ '^[0-9]+(\.[0-9]+)?$' THEN ROUND(p.odometer_reading::numeric)::integer 
            ELSE c.odometer_reading 
        END,
        event_date_time = COALESCE(p.event_date_time AT TIME ZONE 'Asia/Kolkata', c.event_date_time)
    FROM portal_clean p
    WHERE c.allocation_date = p.allocation_date
      AND c.vehicle_number = p.clean_vnum
      AND c.partner_id = p.norm_id;

    GET DIAGNOSTICS v_portal_merged = ROW_COUNT;

    -- Step 3: Insert portal-only valid records (PORTAL_FORM)
    SELECT COALESCE(MAX(id), 0) INTO v_max_id FROM public.core_vehicle_allocation;

    WITH portal_ranked AS (
        SELECT p.*,
               UPPER(REGEXP_REPLACE(COALESCE(p.vehicle_number, ''), '[^A-Z0-9]', '', 'g')) AS clean_vnum,
               REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP') AS norm_id,
               ROW_NUMBER() OVER (
                   PARTITION BY p.allocation_date, 
                                UPPER(REGEXP_REPLACE(COALESCE(p.vehicle_number, ''), '[^A-Z0-9]', '', 'g')),
                                REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP')
                   ORDER BY p.created_at DESC NULLS LAST, p.id DESC
               ) as rn
        FROM public.july_allocation_form p
        WHERE p.allocation_date IS NOT NULL
          AND LENGTH(UPPER(REGEXP_REPLACE(COALESCE(p.vehicle_number, ''), '[^A-Z0-9]', '', 'g'))) BETWEEN 8 AND 12
          AND REGEXP_REPLACE(UPPER(TRIM(COALESCE(p.driver_id, ''))), '^(LETZ(?:BLR|HYD|MUM|PUN))OP', '\1IP') ~ '^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$'
    ),
    portal_clean AS (
        SELECT * FROM portal_ranked WHERE rn = 1
    ),
    portal_new_records AS (
        SELECT p.*,
               ROW_NUMBER() OVER (ORDER BY p.allocation_date ASC, p.created_at ASC NULLS LAST, p.id ASC) AS portal_seq
        FROM portal_clean p
        LEFT JOIN public.core_vehicle_allocation c 
          ON c.allocation_date = p.allocation_date
         AND c.vehicle_number = p.clean_vnum
         AND c.partner_id = p.norm_id
        WHERE c.id IS NULL
    )
    INSERT INTO public.core_vehicle_allocation (
        id, source_origin, sheet_record_id, portal_record_id,
        allocation_date, vehicle_number, partner_id, driver_phone, driver_name,
        city, allocation_type, sub_type, car_model, hub_name,
        driver_plan, type_of_plan, rental_plan, partner_type,
        odometer_reading, ola_negative_balance, ola_negative_balance_proof,
        fastag_balance_amount, fastag_balance_proof, damage_penalty, deposit_refund_status, pending_dues, gps_active, duplicate_key_status,
        driver_agreement_doc, photo_front_side, photo_back_side, photo_lh_side, photo_rh_side, vehicle_driver_photo, battery_photo, odometer_photo, police_verification_doc, insp_stepney_photo, customer_address,
        security_cheque_1, security_cheque_2, security_cheque_3, security_cheque_4, security_cheques,
        jack, jack_rod_tommy, spanner_pana, stepney_tyre, parking_triangle, fire_extinguishers, floor_carpet, seat_cover, music_system, insp_remarks,
        old_vehicle_number, dropoff_odometer, dropoff_remarks, dropoff_photo, dropoff_location, manual_dropoff_location, jama_form_filled, pdi_completed,
        ret_jack, ret_jack_rod, ret_spanner, ret_parking_triangle, ret_fire_extinguishers, ret_seat_cover, ret_floor_carpet, ret_music_system, ret_insp_remarks,
        status, created_by, updated_by, current_approver_id, approval_status, approved_by, approval_remarks,
        reason_to_visit, vehicle_manager_poc, submitter_email, sheet_row_number,
        submission_timestamp, event_date_time, is_deleted, deleted_at, created_at, updated_at
    )
    SELECT
        v_max_id + p.portal_seq AS id,
        'PORTAL_FORM' AS source_origin,
        NULL::BIGINT AS sheet_record_id,
        p.id AS portal_record_id,
        p.allocation_date,
        p.clean_vnum AS vehicle_number,
        p.norm_id AS partner_id,
        RIGHT(REGEXP_REPLACE(COALESCE(p.driver_phone, ''), '\D', '', 'g'), 10) AS driver_phone,
        LEFT(TRIM(REGEXP_REPLACE(COALESCE(p.driver_name, 'UNKNOWN'), '\s+', ' ', 'g')), 255) AS driver_name,
        CASE 
            WHEN LOWER(TRIM(COALESCE(p.city_name, ''))) IN ('bangalore', 'bengaluru', 'blr') THEN 'Bengaluru'
            WHEN LOWER(TRIM(COALESCE(p.city_name, ''))) IN ('hyderabad', 'hyd') THEN 'Hyderabad'
            WHEN LOWER(TRIM(COALESCE(p.city_name, ''))) IN ('mumbai', 'mum') THEN 'Mumbai'
            WHEN LOWER(TRIM(COALESCE(p.city_name, ''))) IN ('pune', 'pun') THEN 'Pune'
            ELSE LEFT(INITCAP(TRIM(COALESCE(p.city_name, 'Unknown'))), 100)
        END AS city,
        CASE
            WHEN LOWER(TRIM(COALESCE(p.allocation_type, ''))) IN ('fresh allocation', 'allocation', 'new allocation') THEN 'New Allocation'
            WHEN LOWER(TRIM(COALESCE(p.allocation_type, ''))) IN ('swap', 'car swap') THEN 'Car Swap'
            WHEN LOWER(TRIM(COALESCE(p.allocation_type, ''))) = 'reallocation' THEN 'Reallocation'
            WHEN LOWER(TRIM(COALESCE(p.allocation_type, ''))) = 'drop-off' THEN 'Drop-Off'
            ELSE INITCAP(TRIM(COALESCE(p.allocation_type, 'New Allocation')))
        END AS allocation_type,
        LEFT(p.sub_type, 100) AS sub_type,
        LEFT(p.car_model, 100) AS car_model,
        LEFT(p.hub_name, 100) AS hub_name,
        LEFT(p.driver_plan, 100) AS driver_plan,
        LEFT(p.type_of_plan, 100) AS type_of_plan,
        NULL::VARCHAR AS rental_plan,
        NULL::VARCHAR AS partner_type,
        CASE 
            WHEN p.odometer_reading ~ '^[0-9]+(\.[0-9]+)?$' THEN ROUND(p.odometer_reading::numeric)::integer 
            ELSE NULL 
        END AS odometer_reading,
        p.ola_negative_balance,
        p.ola_negative_balance_proof,
        p.fastag_balance_amount,
        p.fastag_balance_proof,
        p.damage_penalty,
        LEFT(p.deposit_refund_status, 50) AS deposit_refund_status,
        p.pending_dues,
        LEFT(p.gps_active, 10) AS gps_active,
        LEFT(p.duplicate_key_status, 10) AS duplicate_key_status,
        p.driver_agreement_doc,
        p.photo_front_side,
        p.photo_back_side,
        p.photo_lh_side,
        p.photo_rh_side,
        p.vehicle_driver_photo,
        p.battery_photo,
        p.odometer_photo,
        p.police_verification_doc,
        p.insp_stepney_photo,
        p.customer_address,
        p.security_cheque_1,
        p.security_cheque_2,
        p.security_cheque_3,
        p.security_cheque_4,
        p.security_cheques,
        p.insp_jack AS jack,
        p.insp_jack_rod AS jack_rod_tommy,
        p.insp_spanner AS spanner_pana,
        p.insp_stepney AS stepney_tyre,
        p.insp_parking_triangle AS parking_triangle,
        p.insp_fire_extinguishers AS fire_extinguishers,
        p.insp_floor_carpet AS floor_carpet,
        p.insp_seat_cover AS seat_cover,
        p.insp_music_system AS music_system,
        p.insp_remarks,
        LEFT(p.old_vehicle_number, 50) AS old_vehicle_number,
        p.dropoff_odometer,
        p.dropoff_remarks,
        p.dropoff_photo,
        LEFT(p.dropoff_location, 50) AS dropoff_location,
        p.manual_dropoff_location,
        p.jama_form_filled,
        p.pdi_completed,
        LEFT(p.ret_jack, 30) AS ret_jack,
        LEFT(p.ret_jack_rod, 30) AS ret_jack_rod,
        LEFT(p.ret_spanner, 30) AS ret_spanner,
        LEFT(p.ret_parking_triangle, 30) AS ret_parking_triangle,
        LEFT(p.ret_fire_extinguishers, 30) AS ret_fire_extinguishers,
        LEFT(p.ret_seat_cover, 30) AS ret_seat_cover,
        LEFT(p.ret_floor_carpet, 30) AS ret_floor_carpet,
        LEFT(p.ret_music_system, 30) AS ret_music_system,
        p.ret_insp_remarks,
        COALESCE(LEFT(p.status, 50), 'Submitted') AS status,
        p.created_by,
        p.updated_by,
        p.current_approver_id,
        LEFT(p.approval_status, 50) AS approval_status,
        p.approved_by,
        p.approval_remarks,
        NULL::VARCHAR AS reason_to_visit,
        NULL::VARCHAR AS vehicle_manager_poc,
        NULL::VARCHAR AS submitter_email,
        NULL::INTEGER AS sheet_row_number,
        NULL::TIMESTAMP WITHOUT TIME ZONE AS submission_timestamp,
        p.event_date_time AT TIME ZONE 'Asia/Kolkata' AS event_date_time,
        FALSE AS is_deleted,
        NULL::TIMESTAMP WITHOUT TIME ZONE AS deleted_at,
        COALESCE(p.created_at AT TIME ZONE 'Asia/Kolkata', CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') AS created_at,
        COALESCE(p.updated_at AT TIME ZONE 'Asia/Kolkata', CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata') AS updated_at
    FROM portal_new_records p;

    GET DIAGNOSTICS v_portal_new = ROW_COUNT;

    -- Step 4: Reset the ID sequence to exactly match MAX(id)
    PERFORM setval('public.core_vehicle_allocation_id_seq', COALESCE((SELECT MAX(id) FROM public.core_vehicle_allocation), 1), true);

    RAISE NOTICE 'Backfill Completed: Sheet Rows = %, Portal Merged = %, Portal New = %, Total Core Rows = %',
        v_sheet_count, v_portal_merged, v_portal_new, (v_sheet_count + v_portal_new);
END;
$$;

-- Execute Initial Backfill
CALL public.sp_backfill_core_vehicle_allocation();
