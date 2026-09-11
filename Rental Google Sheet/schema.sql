-- ============================================================================
-- LetzRyd Rental Engine - Google Sheet Staging Tables DDL
-- ============================================================================
-- Tables:
--   1. public.sheet_rental_slabs: Live mirror of pricing menus across all cities
--   2. public.sheet_rental_partners: Live mirror of driver platforms & operator deals
--
-- Target DB: PostgreSQL (Cloud SQL)
-- Synchronization Frequency: Every 30 minutes via Google Cloud Functions / Cloud Run
-- Master Spreadsheet ID: 1xnGg3qhb1AnCP2Qv6e2gmd0zCi5j-bNbx9yDc7etzf4
-- ============================================================================

-- Table 1: sheet_rental_slabs
CREATE TABLE IF NOT EXISTS sheet_rental_slabs (
    id SERIAL PRIMARY KEY,
    city VARCHAR(32) NOT NULL,                                -- 'Hyderabad', 'Mumbai', 'Bengaluru'
    vehicle_model VARCHAR(64) NOT NULL,                       -- 'Maruti Wagonr Tour H3 CNG', 'Dzire Tour S CNG', etc.
    uber_type VARCHAR(32) DEFAULT 'TBS',                      -- 'TBS', 'EBS', 'Standard'
    plan_scheme VARCHAR(64) NOT NULL DEFAULT 'Uber Reducing Rent', -- 'Uber Reducing Rent', 'All Platform'
    trip_slab_label VARCHAR(64) NOT NULL,                     -- e.g. '0-49', '50-69', '70+', '<55 Trips', '55+ Trips'
    min_trips INT NOT NULL DEFAULT 0,                         -- Lower trip threshold (inclusive)
    max_trips INT NOT NULL DEFAULT 9999,                      -- Upper trip threshold (inclusive)
    daily_rent NUMERIC(10,2) NOT NULL,                        -- Base daily rent (INR)
    daily_indemnity NUMERIC(10,2) NOT NULL DEFAULT 30.00,     -- Standard daily indemnity (INR 30/day)
    platform VARCHAR(64) DEFAULT 'Uber',                      -- 'Uber', 'All Platform'
    pass_on_incentive VARCHAR(16) DEFAULT 'yes',              -- 'yes', 'no'
    last_synced_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_sheet_rental_slabs UNIQUE (city, vehicle_model, uber_type, plan_scheme, min_trips)
);

CREATE INDEX IF NOT EXISTS idx_sheet_rental_slabs_lookup 
ON sheet_rental_slabs (city, vehicle_model, min_trips, max_trips);

-- Table 2: sheet_rental_partners
CREATE TABLE IF NOT EXISTS sheet_rental_partners (
    vendor_code VARCHAR(64) PRIMARY KEY,                      -- Partner ID / LID (e.g. 'LETZHYDIP7569776283')
    vendor_name VARCHAR(128),                                 -- Partner / Operator legal or display name
    city VARCHAR(32) NOT NULL,                                -- 'Hyderabad', 'Mumbai', 'Bengaluru'
    vendor_type VARCHAR(32),                                  -- 'Operator', 'Individual', 'VIP'
    plan_name VARCHAR(64),                                    -- Contract plan label
    platform VARCHAR(64),                                     -- 'Uber - EBS', 'Uber - TBS', 'All Platform'
    plan_type_hisaab VARCHAR(64),                             -- 'Reducing Rental', 'Fixed', 'All Platform'
    custom_daily_rent NUMERIC(10,2) NULL,                     -- Custom negotiated flat rate (e.g. INR 900, INR 970, INR 1050)
    custom_daily_indemnity NUMERIC(10,2) NULL,                 -- Custom negotiated indemnity (INR 0 for Kareem, INR 15 for Nisamudeen)
    last_synced_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sheet_rental_partners_city 
ON sheet_rental_partners (city);
