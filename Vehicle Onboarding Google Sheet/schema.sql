-- =============================================================================
-- LetzRyd Vehicle Onboarding Live Pipeline - PostgreSQL Database Schema
-- =============================================================================
-- Target Database: postgres
-- Target Schema  : public
-- Target Table   : sheet_vehicle_onboarding
-- Host           : 35.200.196.113:5432
-- Description    : Central master table storing real-time vehicle onboarding data
--                  synced from Google Sheets (tab: Unified_Vehicle_onboarding_source).
-- =============================================================================

-- 1. Table DDL
CREATE TABLE IF NOT EXISTS public.sheet_vehicle_onboarding (
    -- Internal Primary Sequence
    id BIGSERIAL PRIMARY KEY,
    
    -- Primary Unique Business Key
    registration_no VARCHAR(20) NOT NULL,
    
    -- Asset Specifications (Cols 1 - 26)
    sl VARCHAR(255),
    city VARCHAR(255),
    registered_owner_name VARCHAR(255),
    chassis_no VARCHAR(255),
    engine_no VARCHAR(255),
    hp VARCHAR(255),
    dealer VARCHAR(255),
    model VARCHAR(255),
    vehicle_status VARCHAR(255),
    payment_date DATE,
    delivery_date DATE,
    gps VARCHAR(255),
    mfg_mm_yy VARCHAR(255),
    financier VARCHAR(255),
    ownership VARCHAR(255),
    registration_date DATE,
    ageing VARCHAR(255),
    rto_tax_validity DATE,
    permit_validity DATE,
    fitness_validity DATE,
    pollution_validity DATE,
    insurance_validity DATE,
    delivered_month_y VARCHAR(255),
    pdi_status VARCHAR(255),
    platform VARCHAR(255),
    
    -- Master Document Sheet (Cols 27 - 40)
    mds_timestamp TIMESTAMP WITH TIME ZONE,
    mds_email_address VARCHAR(255),
    mds_vehicle_number VARCHAR(255),
    registration_certificate TEXT,
    fitness TEXT,
    permit TEXT,
    insurance TEXT,
    pollution TEXT,
    letzryd_serial_number VARCHAR(255),
    insurance_endorsement TEXT,
    invoice_copy TEXT,
    front_photo TEXT,
    back_photo TEXT,
    comments TEXT,
    
    -- Letzryd PDI Inspection (Cols 41 - 73)
    pdi_timestamp TIMESTAMP WITH TIME ZONE,
    pdi_email_address VARCHAR(255),
    pdi_city VARCHAR(255),
    pdi_reg_no VARCHAR(255),
    received_or_allocated VARCHAR(255),
    engine_and_chasis_no VARCHAR(255),
    battery_sl_no VARCHAR(255),
    engine_compartment TEXT,
    vehicle_image_front TEXT,
    vehicle_image_lh TEXT,
    vehicle_image_back TEXT,
    vehicle_image_rh TEXT,
    kms_reading NUMERIC(10, 2),
    fast_tag_image_from_inside TEXT,
    music_system_image TEXT,
    key_quantity TEXT,
    rh_fr_tyre_brand_sl_no TEXT,
    lh_fr_tyre_brand_sl_no TEXT,
    rh_rear_tyre_brand_sl_no TEXT,
    lh_rear_tyre_brand_sl_no TEXT,
    spare_wheel_brand_sl_no TEXT,
    jack VARCHAR(255),
    jack_rod VARCHAR(255),
    spanner VARCHAR(255),
    parking_triangle VARCHAR(255),
    fire_extinguishers VARCHAR(255),
    seat_cover VARCHAR(255),
    floor_carpet VARCHAR(255),
    tracking_device_vendor VARCHAR(255),
    tracking_device_type VARCHAR(255),
    letzryd_unique_vehicle_no VARCHAR(255),
    cng_plate VARCHAR(255),
    cng_installation_date DATE,
    
    -- Metadata & Row Traceability
    sheet_row_number INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Constraints
    CONSTRAINT uq_sheet_vehicle_registration UNIQUE (registration_no)
);

-- 2. Performance B-Tree Indexes
CREATE INDEX IF NOT EXISTS idx_sheet_vehicle_reg_no 
    ON public.sheet_vehicle_onboarding (registration_no);

CREATE INDEX IF NOT EXISTS idx_sheet_vehicle_chassis 
    ON public.sheet_vehicle_onboarding (chassis_no);

CREATE INDEX IF NOT EXISTS idx_sheet_vehicle_city 
    ON public.sheet_vehicle_onboarding (city);

CREATE INDEX IF NOT EXISTS idx_sheet_vehicle_status 
    ON public.sheet_vehicle_onboarding (vehicle_status);

CREATE INDEX IF NOT EXISTS idx_sheet_vehicle_letzryd_serial 
    ON public.sheet_vehicle_onboarding (letzryd_serial_number);

CREATE INDEX IF NOT EXISTS idx_sheet_vehicle_pdi_status 
    ON public.sheet_vehicle_onboarding (pdi_status);

CREATE INDEX IF NOT EXISTS idx_sheet_vehicle_delivery_date 
    ON public.sheet_vehicle_onboarding (delivery_date DESC);
