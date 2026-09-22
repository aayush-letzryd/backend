-- ============================================================================
-- LetzRyd Unified Rental Staging Architecture: Single Portal Table
-- ============================================================================
-- Purpose:
--   Single unified configuration table for portal operations:
--   - Master Plan definitions
--   - Partner Custom Agreements & Plan Assignments
--   - Dynamic Trip Slab configurations
--   - Model Baseline fallback rates
--   - Temporary Exceptions / Concessions
--   - Indemnity Fee Policies & Waivers
--
-- Note:
--   Completely isolated from live production tables.
--   Verified records can be promoted into the 7 backend tables:
--   (core_rental_plans, rental_rate_slabs, rental_custom_partner_plans,
--    rental_exceptions, rental_fee_rules, rental_model_baselines, daily_rent_log).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.portal_rental_plans (
    id SERIAL PRIMARY KEY,

    -- Operational Configuration Type
    -- Values: 'PARTNER_DEAL', 'EXCEPTION_OVERRIDE', 'RATE_SLAB', 'MODEL_BASELINE', 'FEE_WAIVER', 'CORE_PLAN'
    config_type VARCHAR(32) NOT NULL,

    -- Geography Scope
    -- Values: 'Bangalore', 'Hyderabad', 'Mumbai', 'ALL'
    city VARCHAR(32) NOT NULL DEFAULT 'Bangalore',

    -- Plan Master Metadata (for CORE_PLAN, or referenced by other types)
    plan_id INT,
    plan_code VARCHAR(64),
    plan_name VARCHAR(128),
    plan_category VARCHAR(32) DEFAULT 'STANDARD', -- 'STANDARD', 'CUSTOM'
    calculation_type VARCHAR(32) DEFAULT 'SLAB_TIERED', -- 'SLAB_TIERED', 'FLAT_RATE', 'PLATFORM_SPLIT', 'MODEL_FALLBACK'

    -- Targeting & Entities
    partner_id VARCHAR(64),                        -- Operator/Driver partner code (e.g. 'LETZBLR_HAMZA', 'LETZHYDIP9701685282')
    partner_name VARCHAR(128),
    customer_type VARCHAR(32) DEFAULT 'ALL',       -- 'Individual', 'Operator', 'ALL'
    vehicle_manufacturer VARCHAR(64),              -- e.g. 'Maruti Suzuki', 'Tata'
    vehicle_model VARCHAR(64) DEFAULT 'ALL',       -- 'WagonR', 'Dzire', 'EC3', 'ALL'
    vehicle_number VARCHAR(32),                    -- For specific vehicle assignments/exceptions (e.g. 'TS09EA1001')
    vehicle_age VARCHAR(32),                       -- Legacy / optional filter (e.g. '0-2 Years', '3-5 Years')

    -- Dynamic Slab Parameters (used when config_type = 'RATE_SLAB')
    metric_type VARCHAR(32) DEFAULT 'UBER_TRIPS',  -- 'UBER_TRIPS', 'OLA_TRIPS', 'TOTAL_TRIPS'
    condition_rule VARCHAR(128) DEFAULT 'NONE',    -- 'NONE', 'OLA_GE_1', 'OLA_GE_1_UBER_ZERO', 'OLA_ZERO'
    trip_min INT DEFAULT 0,
    trip_max INT,                                  -- NULL or upper limit (e.g. 54, 64, 9999)

    -- Financial Rates
    daily_rent NUMERIC(10,2) NOT NULL,             -- Base daily rental rate in ₹
    daily_fee NUMERIC(10,2) NOT NULL DEFAULT 30.00,-- Indemnity fee in ₹/day (standard ₹30, ₹0 for waivers)
    is_fee_waiver BOOLEAN NOT NULL DEFAULT FALSE,  -- True if fee is fully waived (₹0)

    -- Model Baseline Specifics
    all_platform_flat_rent NUMERIC(10,2),          -- Flat rent for multi-platform fallback (e.g. ₹1,050)

    -- Validity Period
    valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to DATE NOT NULL DEFAULT '9999-12-31',

    -- Audit, Governance & Lineage
    reason_or_notes TEXT,                          -- Concession justification, deal notes
    evidence_source VARCHAR(128),                  -- WhatsApp approval, management directive, email thread
    approved_by VARCHAR(64) DEFAULT 'Operations Head',
    created_by VARCHAR(64),
    status VARCHAR(32) NOT NULL DEFAULT 'Active',  -- 'Pending', 'Active', 'Rejected', 'Expired'

    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Indices for rapid portal querying & filtering
CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_type ON public.portal_rental_plans(config_type);
CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_city ON public.portal_rental_plans(city);
CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_partner ON public.portal_rental_plans(partner_id);
CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_veh ON public.portal_rental_plans(vehicle_number);
CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_dates ON public.portal_rental_plans(valid_from, valid_to);
