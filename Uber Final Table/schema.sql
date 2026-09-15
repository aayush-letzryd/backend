-- ============================================================================
-- LetzRyd Uber Final Table Architecture: Production DDL
-- Tables: public.core_uber_daily, public.core_uber_weekly
-- Purpose: Standardized Daily & Weekly Uber Earnings and Trips for Hisaab
-- ============================================================================

-- 1. core_uber_daily (Grain: operational_date + vehicle_number + driver_uuid)
CREATE TABLE IF NOT EXISTS core_uber_daily (
    id                          BIGSERIAL PRIMARY KEY,
    operational_date            DATE NOT NULL,                  -- Shift date (04:00 AM IST cutoff)
    vehicle_number              VARCHAR(32) NOT NULL,           -- Clean alphanumeric license plate
    driver_uuid                 VARCHAR(64),                    -- Uber driver UUID
    vendor_code                 VARCHAR(64),                    -- Assigned partner ID (from core_daily_vehicle_status)
    city                        VARCHAR(32) DEFAULT 'Hyderabad',-- Operating city
    org_name                    VARCHAR(128),                   -- Uber organization name
    
    -- Operational Telemetry
    completed_trips             INT DEFAULT 0,
    total_trip_distance_km      NUMERIC(10,2) DEFAULT 0.00,
    
    -- Daily Financials
    net_fare_earnings           NUMERIC(12,2) DEFAULT 0.00,     -- Gross rider fare earnings
    cash_collected              NUMERIC(12,2) DEFAULT 0.00,     -- Rider cash collected by driver (positive display)
    tolls_refunded              NUMERIC(12,2) DEFAULT 0.00,     -- Toll reimbursements
    driver_subscription_charge  NUMERIC(12,2) DEFAULT 0.00,     -- Platform / subscription debits
    net_driver_day_balance      NUMERIC(12,2) DEFAULT 0.00,     -- Daily net (earnings - cash + toll - sub_charge)
    
    -- Metadata
    source_origin               VARCHAR(64) DEFAULT 'uber_pipeline',
    created_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_core_uber_daily UNIQUE (operational_date, vehicle_number, driver_uuid)
);

CREATE INDEX IF NOT EXISTS idx_core_uber_daily_date ON core_uber_daily (operational_date);
CREATE INDEX IF NOT EXISTS idx_core_uber_daily_veh ON core_uber_daily (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_uber_daily_vendor ON core_uber_daily (vendor_code);

-- 2. core_uber_weekly (Grain: settlement_year + settlement_week + vehicle_number + vendor_code)
CREATE TABLE IF NOT EXISTS core_uber_weekly (
    id                          BIGSERIAL PRIMARY KEY,
    settlement_year             INT NOT NULL,                   -- ISO Year (e.g. 2026)
    settlement_week             INT NOT NULL,                   -- ISO Week (e.g. 26, 34)
    week_id                     VARCHAR(32) NOT NULL,           -- Formatted Week ID (e.g. 'CY26WK26')
    week_start                  DATE NOT NULL,                  -- Monday of settlement week
    week_end                    DATE NOT NULL,                  -- Sunday of settlement week
    vehicle_number              VARCHAR(32) NOT NULL,
    vendor_code                 VARCHAR(64),                    -- Assigned partner ID
    city                        VARCHAR(32) DEFAULT 'Hyderabad',
    
    -- Aggregated Weekly Trip Metrics
    active_days                 INT DEFAULT 0,                  -- Days vehicle had >=1 completed trip
    completed_trips             INT DEFAULT 0,
    total_trip_km               NUMERIC(10,2) DEFAULT 0.00,
    
    -- Weekly Financials for Hisaab Settlement
    uber_total_earnings         NUMERIC(12,2) DEFAULT 0.00,     -- Net Fare + Promotions -> Hisaab
    uber_cash_collection        NUMERIC(12,2) DEFAULT 0.00,     -- Total cash collected by driver -> Hisaab
    uber_toll                   NUMERIC(12,2) DEFAULT 0.00,     -- Toll reimbursement -> Hisaab
    uber_driver_sub_charge      NUMERIC(12,2) DEFAULT 0.00,     -- Driver subscription charge -> Hisaab
    uber_vehicle_incentive      NUMERIC(12,2) DEFAULT 0.00,     -- Total incentive from uber_vehicle_incentives_raw
    uber_pass_on_incentive      NUMERIC(12,2) DEFAULT 0.00,     -- Driver share based on target slab
    uber_letzryd_incentive      NUMERIC(12,2) DEFAULT 0.00,     -- Retained company incentive
    
    -- Net Weekly Balance
    uber_week_balance           NUMERIC(12,2) DEFAULT 0.00,     -- (earnings - cash + toll - sub_charge + incentive)
    
    created_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_core_uber_weekly UNIQUE (settlement_year, settlement_week, vehicle_number, vendor_code)
);

CREATE INDEX IF NOT EXISTS idx_core_uber_weekly_week ON core_uber_weekly (settlement_year, settlement_week);
CREATE INDEX IF NOT EXISTS idx_core_uber_weekly_week_id ON core_uber_weekly (week_id);
CREATE INDEX IF NOT EXISTS idx_core_uber_weekly_veh ON core_uber_weekly (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_uber_weekly_vendor ON core_uber_weekly (vendor_code);
