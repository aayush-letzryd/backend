-- =============================================================================
-- LetzRyd Single Source of Truth: public.core_walkin Schema & Live Triggers
-- =============================================================================
-- Description:
-- Unifies three independent walk-in data sources:
--   1. public.sheet_walkins (Google Sheet synced via Apps Script)
--   2. public.july_new_walkins (Portal Onboarding for new candidates)
--   3. public.july_existing_walkins (Portal Visits for existing partners)
--
-- Features:
--   - Real-time synchronization via PostgreSQL triggers (zero app changes required)
--   - Full audit lineage (source_system, source_table, original primary key IDs)
--   - Automated data standardization (cities, phone numbers, name cleaning)
--   - Verbatim reason preservation + standardized categorization
-- =============================================================================

-- 1. Master Table Definition
CREATE TABLE IF NOT EXISTS public.core_walkin (
    id BIGSERIAL PRIMARY KEY,
    
    -- Provenance & Source References
    source_system VARCHAR(50) NOT NULL, -- 'GOOGLE_SHEET', 'PORTAL_NEW', 'PORTAL_EXISTING'
    source_table VARCHAR(100) NOT NULL, -- 'sheet_walkins', 'july_new_walkins', 'july_existing_walkins'
    sheet_walkin_id BIGINT,             -- Pointer to sheet_walkins.id
    portal_new_walkin_id INTEGER,       -- Pointer to july_new_walkins.id
    portal_existing_walkin_id INTEGER,  -- Pointer to july_existing_walkins.id
    walkin_type VARCHAR(50) NOT NULL,   -- 'NEW_CANDIDATE', 'EXISTING_PARTNER'
    
    -- Temporal & Location
    walkin_date DATE NOT NULL,
    walkin_time VARCHAR(20),
    walkin_timestamp TIMESTAMP WITH TIME ZONE,
    city VARCHAR(50) NOT NULL,
    operating_place VARCHAR(200),
    
    -- Visitor Profile
    full_name VARCHAR(255) NOT NULL,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    phone_number VARCHAR(20) NOT NULL,
    partner_role VARCHAR(50) DEFAULT 'Driver',
    
    -- KYC & Documents
    dl_number VARCHAR(100),
    aadhaar_number VARCHAR(30),
    dl_image_url TEXT,
    aadhaar_image_url TEXT,
    
    -- Visit Details & Status
    visiting_reason VARCHAR(255),
    visiting_reason_category VARCHAR(100),
    joined_status VARCHAR(100),
    is_joined BOOLEAN DEFAULT FALSE,
    joined_date DATE,
    submission_status VARCHAR(50) DEFAULT 'Submitted',
    
    -- Acquisition & Referral
    lead_channel VARCHAR(100),
    lead_channel_details VARCHAR(300),
    referred_by_name VARCHAR(100),
    referred_by_phone VARCHAR(20),
    
    -- Executive & Operational Notes
    attending_executive VARCHAR(255),
    attending_executive_id INTEGER,
    submitter_email VARCHAR(255),
    remarks TEXT,
    visit_notes TEXT,
    sheet_row_number INTEGER,
    
    -- Audit Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Performance & Analytics Indexes
CREATE INDEX IF NOT EXISTS idx_core_walkin_date ON public.core_walkin (walkin_date DESC);
CREATE INDEX IF NOT EXISTS idx_core_walkin_phone ON public.core_walkin (phone_number);
CREATE INDEX IF NOT EXISTS idx_core_walkin_city ON public.core_walkin (city);
CREATE INDEX IF NOT EXISTS idx_core_walkin_source ON public.core_walkin (source_system);
CREATE INDEX IF NOT EXISTS idx_core_walkin_reason_cat ON public.core_walkin (visiting_reason_category);
CREATE INDEX IF NOT EXISTS idx_core_walkin_sheet_id ON public.core_walkin (sheet_walkin_id);
CREATE INDEX IF NOT EXISTS idx_core_walkin_portal_new_id ON public.core_walkin (portal_new_walkin_id);
CREATE INDEX IF NOT EXISTS idx_core_walkin_portal_ex_id ON public.core_walkin (portal_existing_walkin_id);

-- -----------------------------------------------------------------------------
-- 2. Trigger Function 1: Sync from sheet_walkins
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sync_core_walkin_from_sheet()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone VARCHAR(20);
    v_clean_city VARCHAR(50);
    v_f_name VARCHAR(100);
    v_l_name VARCHAR(100);
    v_full_name VARCHAR(255);
    v_reason_cat VARCHAR(100);
    v_is_joined BOOLEAN;
    v_w_type VARCHAR(50);
    v_time_str VARCHAR(20);
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM public.core_walkin WHERE sheet_walkin_id = OLD.id;
        RETURN OLD;
    END IF;

    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(NEW.partner_number, ''), '\D', '', 'g'), 10);
    
    v_clean_city := CASE 
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('bangalore', 'bengaluru', 'blr') THEN 'Bengaluru'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('hyderabad', 'hyd') THEN 'Hyderabad'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('mumbai', 'mum') THEN 'Mumbai'
        ELSE INITCAP(TRIM(COALESCE(NEW.city, 'Unknown')))
    END;

    v_full_name := UPPER(TRIM(REGEXP_REPLACE(COALESCE(NEW.partner_name, 'UNKNOWN'), '\s+', ' ', 'g')));
    v_f_name := SPLIT_PART(v_full_name, ' ', 1);
    v_l_name := SUBSTRING(v_full_name FROM LENGTH(v_f_name) + 2);
    IF v_l_name = '' THEN v_l_name := NULL; END IF;

    v_reason_cat := CASE 
        WHEN NEW.visiting_reason ILIKE '%new joining%' OR NEW.visiting_reason ILIKE '%onboarding%' OR NEW.visiting_reason ILIKE '%re-joining%' OR NEW.visiting_reason ILIKE '%adding new vehicle%' THEN 'ONBOARDING'
        WHEN NEW.visiting_reason ILIKE '%enquiry%' OR NEW.visiting_reason ILIKE '%inquiry%' THEN 'ENQUIRY'
        WHEN NEW.visiting_reason ILIKE '%hisaab%' OR NEW.visiting_reason ILIKE '%payout%' OR NEW.visiting_reason ILIKE '%earnings%' THEN 'PAYOUT_HISAAB'
        WHEN NEW.visiting_reason ILIKE '%maintenance%' OR NEW.visiting_reason ILIKE '%tyre%' OR NEW.visiting_reason ILIKE '%swap%' OR NEW.visiting_reason ILIKE '%drop off%' THEN 'VEHICLE_MAINTENANCE'
        WHEN NEW.visiting_reason ILIKE '%meet%' OR NEW.visiting_reason ILIKE '%manager%' OR NEW.visiting_reason ILIKE '%dm%' THEN 'MEETING_COMPLAINT'
        ELSE 'OTHER'
    END;

    v_w_type := CASE 
        WHEN v_reason_cat IN ('PAYOUT_HISAAB', 'VEHICLE_MAINTENANCE') THEN 'EXISTING_PARTNER'
        ELSE 'NEW_CANDIDATE'
    END;

    v_is_joined := (NEW.joined_status ILIKE 'joined%' AND NEW.joined_status NOT ILIKE '%not%' AND NEW.joined_status NOT ILIKE '%false%');
    v_time_str := TO_CHAR(NEW.submission_timestamp AT TIME ZONE 'Asia/Kolkata', 'HH24:MI');

    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.core_walkin (
            source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
            walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
            full_name, first_name, last_name, phone_number, partner_role,
            dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
            visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
            lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
            attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
            sheet_row_number, created_at, updated_at
        ) VALUES (
            'GOOGLE_SHEET', 'sheet_walkins', NEW.id, NULL, NULL,
            v_w_type, NEW.submission_timestamp::date, v_time_str, NEW.submission_timestamp, v_clean_city, NULL,
            v_full_name, v_f_name, v_l_name, v_clean_phone, 'Driver',
            NEW.dl_number, NULL, NULL, NULL,
            NEW.visiting_reason, v_reason_cat, NEW.joined_status, v_is_joined, NEW.joined_date, 'Submitted',
            NULL, NULL, NULL, NULL,
            NEW.attending_executive, NULL, NEW.submitter_email, NEW.remarks, NULL,
            NEW.sheet_row_number, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
        );
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE public.core_walkin SET
            walkin_date = NEW.submission_timestamp::date,
            walkin_time = v_time_str,
            walkin_timestamp = NEW.submission_timestamp,
            city = v_clean_city,
            full_name = v_full_name,
            first_name = v_f_name,
            last_name = v_l_name,
            phone_number = v_clean_phone,
            dl_number = NEW.dl_number,
            visiting_reason = NEW.visiting_reason,
            visiting_reason_category = v_reason_cat,
            joined_status = NEW.joined_status,
            is_joined = v_is_joined,
            joined_date = NEW.joined_date,
            attending_executive = NEW.attending_executive,
            submitter_email = NEW.submitter_email,
            remarks = NEW.remarks,
            sheet_row_number = NEW.sheet_row_number,
            updated_at = COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
        WHERE sheet_walkin_id = NEW.id;
        
        IF NOT FOUND THEN
            INSERT INTO public.core_walkin (
                source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
                walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
                full_name, first_name, last_name, phone_number, partner_role,
                dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
                visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
                lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
                attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
                sheet_row_number, created_at, updated_at
            ) VALUES (
                'GOOGLE_SHEET', 'sheet_walkins', NEW.id, NULL, NULL,
                v_w_type, NEW.submission_timestamp::date, v_time_str, NEW.submission_timestamp, v_clean_city, NULL,
                v_full_name, v_f_name, v_l_name, v_clean_phone, 'Driver',
                NEW.dl_number, NULL, NULL, NULL,
                NEW.visiting_reason, v_reason_cat, NEW.joined_status, v_is_joined, NEW.joined_date, 'Submitted',
                NULL, NULL, NULL, NULL,
                NEW.attending_executive, NULL, NEW.submitter_email, NEW.remarks, NULL,
                NEW.sheet_row_number, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_walkin_from_sheet ON public.sheet_walkins;
CREATE TRIGGER trg_sync_core_walkin_from_sheet
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_walkins
FOR EACH ROW EXECUTE FUNCTION fn_sync_core_walkin_from_sheet();

-- -----------------------------------------------------------------------------
-- 3. Trigger Function 2: Sync from july_new_walkins (Portal New Candidates)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sync_core_walkin_from_portal_new()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone VARCHAR(20);
    v_clean_city VARCHAR(50);
    v_f_name VARCHAR(100);
    v_l_name VARCHAR(100);
    v_full_name VARCHAR(255);
    v_reason_cat VARCHAR(100);
    v_is_joined BOOLEAN;
    v_time_str VARCHAR(20);
    v_date DATE;
    v_exec_name VARCHAR(255);
    v_exec_email VARCHAR(255);
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM public.core_walkin WHERE portal_new_walkin_id = OLD.id;
        RETURN OLD;
    END IF;

    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(NEW.person_number, ''), '\D', '', 'g'), 10);
    
    v_clean_city := CASE 
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('bangalore', 'bengaluru', 'blr') THEN 'Bengaluru'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('hyderabad', 'hyd') THEN 'Hyderabad'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('mumbai', 'mum') THEN 'Mumbai'
        ELSE INITCAP(TRIM(COALESCE(NEW.city, 'Unknown')))
    END;

    -- Strip accidentally pasted email addresses from name fields
    v_full_name := INITCAP(TRIM(REGEXP_REPLACE(REGEXP_REPLACE(COALESCE(NEW.person_name, ''), '\S+@\S+', '', 'g'), '\s+', ' ', 'g')));
    IF v_full_name = '' THEN
        v_full_name := INITCAP(TRIM(CONCAT(COALESCE(NEW.first_name, ''), ' ', COALESCE(NEW.last_name, ''))));
        v_full_name := TRIM(REGEXP_REPLACE(REGEXP_REPLACE(v_full_name, '\S+@\S+', '', 'g'), '\s+', ' ', 'g'));
    END IF;
    IF v_full_name = '' THEN v_full_name := 'UNKNOWN'; END IF;
    
    v_f_name := SPLIT_PART(v_full_name, ' ', 1);
    v_l_name := SUBSTRING(v_full_name FROM LENGTH(v_f_name) + 2);
    IF v_l_name = '' THEN v_l_name := NULL; END IF;

    v_reason_cat := CASE 
        WHEN NEW.visiting_reason ILIKE '%new joining%' OR NEW.visiting_reason ILIKE '%onboarding%' OR NEW.visiting_reason ILIKE '%re-joining%' OR NEW.visiting_reason ILIKE '%adding new vehicle%' THEN 'ONBOARDING'
        WHEN NEW.visiting_reason ILIKE '%enquiry%' OR NEW.visiting_reason ILIKE '%inquiry%' THEN 'ENQUIRY'
        WHEN NEW.visiting_reason ILIKE '%hisaab%' OR NEW.visiting_reason ILIKE '%payout%' OR NEW.visiting_reason ILIKE '%earnings%' THEN 'PAYOUT_HISAAB'
        WHEN NEW.visiting_reason ILIKE '%maintenance%' OR NEW.visiting_reason ILIKE '%tyre%' OR NEW.visiting_reason ILIKE '%swap%' OR NEW.visiting_reason ILIKE '%drop off%' THEN 'VEHICLE_MAINTENANCE'
        WHEN NEW.visiting_reason ILIKE '%meet%' OR NEW.visiting_reason ILIKE '%manager%' OR NEW.visiting_reason ILIKE '%dm%' THEN 'MEETING_COMPLAINT'
        ELSE 'OTHER'
    END;

    v_is_joined := (NEW.joined_status ILIKE 'joined%' AND NEW.joined_status NOT ILIKE '%not%' AND NEW.joined_status NOT ILIKE '%false%');
    v_date := COALESCE(NEW.event_date, NEW.created_at::date, CURRENT_DATE);
    v_time_str := COALESCE(NEW.enquiry_time, TO_CHAR(COALESCE(NEW.created_at, CURRENT_TIMESTAMP), 'HH24:MI'));

    -- Resolve executive from portal users and employee directory
    SELECT 
        COALESCE(NULLIF(TRIM(CONCAT(e.first_name, ' ', e.last_name)), ''), pu.username, 'Executive'),
        COALESCE(pu.email, pu.username, '')
    INTO v_exec_name, v_exec_email
    FROM july_portal_users pu
    LEFT JOIN july_employees e ON e.employee_id = pu.employee_id
    WHERE pu.portal_user_id = COALESCE(NEW.created_by, NEW.executive_id)
    LIMIT 1;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.core_walkin (
            source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
            walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
            full_name, first_name, last_name, phone_number, partner_role,
            dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
            visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
            lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
            attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
            sheet_row_number, created_at, updated_at
        ) VALUES (
            'PORTAL_NEW', 'july_new_walkins', NULL, NEW.id, NULL,
            'NEW_CANDIDATE', v_date, v_time_str, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), v_clean_city, NEW.operating_place,
            v_full_name, v_f_name, v_l_name, v_clean_phone, COALESCE(NEW.interested_position, 'Driver'),
            NEW.dl_number, NEW.aadhaar_number, NEW.dl_image, NEW.aadhaar_image,
            NEW.visiting_reason, v_reason_cat, NEW.joined_status, v_is_joined, NULL, COALESCE(NEW.submission_status, 'Submitted'),
            NEW.lead_channel, NEW.lead_channel_details, NEW.referred_by_name, NEW.referred_by_phone,
            COALESCE(v_exec_name, 'Executive'), COALESCE(NEW.created_by, NEW.executive_id), v_exec_email, NEW.remarks, NULL,
            NULL, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
        );
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE public.core_walkin SET
            walkin_date = v_date,
            walkin_time = v_time_str,
            city = v_clean_city,
            operating_place = NEW.operating_place,
            full_name = v_full_name,
            first_name = v_f_name,
            last_name = v_l_name,
            phone_number = v_clean_phone,
            partner_role = COALESCE(NEW.interested_position, 'Driver'),
            dl_number = NEW.dl_number,
            aadhaar_number = NEW.aadhaar_number,
            dl_image_url = NEW.dl_image,
            aadhaar_image_url = NEW.aadhaar_image,
            visiting_reason = NEW.visiting_reason,
            visiting_reason_category = v_reason_cat,
            joined_status = NEW.joined_status,
            is_joined = v_is_joined,
            submission_status = COALESCE(NEW.submission_status, 'Submitted'),
            lead_channel = NEW.lead_channel,
            lead_channel_details = NEW.lead_channel_details,
            referred_by_name = NEW.referred_by_name,
            referred_by_phone = NEW.referred_by_phone,
            attending_executive = COALESCE(v_exec_name, attending_executive),
            attending_executive_id = COALESCE(NEW.created_by, NEW.executive_id),
            submitter_email = COALESCE(v_exec_email, submitter_email),
            remarks = NEW.remarks,
            updated_at = COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
        WHERE portal_new_walkin_id = NEW.id;

        IF NOT FOUND THEN
            INSERT INTO public.core_walkin (
                source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
                walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
                full_name, first_name, last_name, phone_number, partner_role,
                dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
                visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
                lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
                attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
                sheet_row_number, created_at, updated_at
            ) VALUES (
                'PORTAL_NEW', 'july_new_walkins', NULL, NEW.id, NULL,
                'NEW_CANDIDATE', v_date, v_time_str, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), v_clean_city, NEW.operating_place,
                v_full_name, v_f_name, v_l_name, v_clean_phone, COALESCE(NEW.interested_position, 'Driver'),
                NEW.dl_number, NEW.aadhaar_number, NEW.dl_image, NEW.aadhaar_image,
                NEW.visiting_reason, v_reason_cat, NEW.joined_status, v_is_joined, NULL, COALESCE(NEW.submission_status, 'Submitted'),
                NEW.lead_channel, NEW.lead_channel_details, NEW.referred_by_name, NEW.referred_by_phone,
                COALESCE(v_exec_name, 'Executive'), COALESCE(NEW.created_by, NEW.executive_id), v_exec_email, NEW.remarks, NULL,
                NULL, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_walkin_from_portal_new ON public.july_new_walkins;
CREATE TRIGGER trg_sync_core_walkin_from_portal_new
AFTER INSERT OR UPDATE OR DELETE ON public.july_new_walkins
FOR EACH ROW EXECUTE FUNCTION fn_sync_core_walkin_from_portal_new();

-- -----------------------------------------------------------------------------
-- 4. Trigger Function 3: Sync from july_existing_walkins (Portal Returning Partners)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sync_core_walkin_from_portal_existing()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_phone VARCHAR(20);
    v_clean_city VARCHAR(50);
    v_f_name VARCHAR(100);
    v_l_name VARCHAR(100);
    v_full_name VARCHAR(255);
    v_reason_cat VARCHAR(100);
    v_time_str VARCHAR(20);
    v_date DATE;
    v_exec_name VARCHAR(255);
    v_exec_email VARCHAR(255);
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM public.core_walkin WHERE portal_existing_walkin_id = OLD.id;
        RETURN OLD;
    END IF;

    v_clean_phone := RIGHT(REGEXP_REPLACE(COALESCE(NEW.person_number, ''), '\D', '', 'g'), 10);
    
    v_clean_city := CASE 
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('bangalore', 'bengaluru', 'blr') THEN 'Bengaluru'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('hyderabad', 'hyd') THEN 'Hyderabad'
        WHEN LOWER(TRIM(COALESCE(NEW.city, ''))) IN ('mumbai', 'mum') THEN 'Mumbai'
        ELSE INITCAP(TRIM(COALESCE(NEW.city, 'Unknown')))
    END;

    v_full_name := INITCAP(TRIM(REGEXP_REPLACE(REGEXP_REPLACE(COALESCE(NEW.person_name, ''), '\S+@\S+', '', 'g'), '\s+', ' ', 'g')));
    IF v_full_name = '' THEN
        v_full_name := INITCAP(TRIM(CONCAT(COALESCE(NEW.first_name, ''), ' ', COALESCE(NEW.last_name, ''))));
        v_full_name := TRIM(REGEXP_REPLACE(REGEXP_REPLACE(v_full_name, '\S+@\S+', '', 'g'), '\s+', ' ', 'g'));
    END IF;
    IF v_full_name = '' THEN v_full_name := 'UNKNOWN'; END IF;
    
    v_f_name := SPLIT_PART(v_full_name, ' ', 1);
    v_l_name := SUBSTRING(v_full_name FROM LENGTH(v_f_name) + 2);
    IF v_l_name = '' THEN v_l_name := NULL; END IF;

    v_reason_cat := CASE 
        WHEN NEW.visiting_reason ILIKE '%new joining%' OR NEW.visiting_reason ILIKE '%onboarding%' OR NEW.visiting_reason ILIKE '%re-joining%' OR NEW.visiting_reason ILIKE '%adding new vehicle%' THEN 'ONBOARDING'
        WHEN NEW.visiting_reason ILIKE '%enquiry%' OR NEW.visiting_reason ILIKE '%inquiry%' THEN 'ENQUIRY'
        WHEN NEW.visiting_reason ILIKE '%hisaab%' OR NEW.visiting_reason ILIKE '%payout%' OR NEW.visiting_reason ILIKE '%earnings%' THEN 'PAYOUT_HISAAB'
        WHEN NEW.visiting_reason ILIKE '%maintenance%' OR NEW.visiting_reason ILIKE '%tyre%' OR NEW.visiting_reason ILIKE '%swap%' OR NEW.visiting_reason ILIKE '%drop off%' THEN 'VEHICLE_MAINTENANCE'
        WHEN NEW.visiting_reason ILIKE '%meet%' OR NEW.visiting_reason ILIKE '%manager%' OR NEW.visiting_reason ILIKE '%dm%' THEN 'MEETING_COMPLAINT'
        ELSE 'OTHER'
    END;

    v_date := COALESCE(NEW.event_date, NEW.created_at::date, CURRENT_DATE);
    v_time_str := COALESCE(NEW.enquiry_time, TO_CHAR(COALESCE(NEW.created_at, CURRENT_TIMESTAMP), 'HH24:MI'));

    SELECT 
        COALESCE(NULLIF(TRIM(CONCAT(e.first_name, ' ', e.last_name)), ''), pu.username, 'Executive'),
        COALESCE(pu.email, pu.username, '')
    INTO v_exec_name, v_exec_email
    FROM july_portal_users pu
    LEFT JOIN july_employees e ON e.employee_id = pu.employee_id
    WHERE pu.portal_user_id = COALESCE(NEW.created_by, NEW.executive_id)
    LIMIT 1;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.core_walkin (
            source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
            walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
            full_name, first_name, last_name, phone_number, partner_role,
            dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
            visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
            lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
            attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
            sheet_row_number, created_at, updated_at
        ) VALUES (
            'PORTAL_EXISTING', 'july_existing_walkins', NULL, NULL, NEW.id,
            'EXISTING_PARTNER', v_date, v_time_str, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), v_clean_city, NULL,
            v_full_name, v_f_name, v_l_name, v_clean_phone, COALESCE(NEW.partner_type, 'Driver'),
            NULL, NULL, NULL, NULL,
            NEW.visiting_reason, v_reason_cat, 'Partner Visit', FALSE, NULL, COALESCE(NEW.submission_status, 'Submitted'),
            NULL, NULL, NULL, NULL,
            COALESCE(v_exec_name, 'Executive'), COALESCE(NEW.created_by, NEW.executive_id), v_exec_email, NULL, NEW.visit_notes,
            NULL, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
        );
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE public.core_walkin SET
            walkin_date = v_date,
            walkin_time = v_time_str,
            city = v_clean_city,
            full_name = v_full_name,
            first_name = v_f_name,
            last_name = v_l_name,
            phone_number = v_clean_phone,
            partner_role = COALESCE(NEW.partner_type, 'Driver'),
            visiting_reason = NEW.visiting_reason,
            visiting_reason_category = v_reason_cat,
            submission_status = COALESCE(NEW.submission_status, 'Submitted'),
            attending_executive = COALESCE(v_exec_name, attending_executive),
            attending_executive_id = COALESCE(NEW.created_by, NEW.executive_id),
            submitter_email = COALESCE(v_exec_email, submitter_email),
            visit_notes = NEW.visit_notes,
            updated_at = COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
        WHERE portal_existing_walkin_id = NEW.id;

        IF NOT FOUND THEN
            INSERT INTO public.core_walkin (
                source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
                walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
                full_name, first_name, last_name, phone_number, partner_role,
                dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
                visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
                lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
                attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
                sheet_row_number, created_at, updated_at
            ) VALUES (
                'PORTAL_EXISTING', 'july_existing_walkins', NULL, NULL, NEW.id,
                'EXISTING_PARTNER', v_date, v_time_str, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), v_clean_city, NULL,
                v_full_name, v_f_name, v_l_name, v_clean_phone, COALESCE(NEW.partner_type, 'Driver'),
                NULL, NULL, NULL, NULL,
                NEW.visiting_reason, v_reason_cat, 'Partner Visit', FALSE, NULL, COALESCE(NEW.submission_status, 'Submitted'),
                NULL, NULL, NULL, NULL,
                COALESCE(v_exec_name, 'Executive'), COALESCE(NEW.created_by, NEW.executive_id), v_exec_email, NULL, NEW.visit_notes,
                NULL, COALESCE(NEW.created_at, CURRENT_TIMESTAMP), COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_core_walkin_from_portal_existing ON public.july_existing_walkins;
CREATE TRIGGER trg_sync_core_walkin_from_portal_existing
AFTER INSERT OR UPDATE OR DELETE ON public.july_existing_walkins
FOR EACH ROW EXECUTE FUNCTION fn_sync_core_walkin_from_portal_existing();
