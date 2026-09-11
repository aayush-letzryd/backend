-- ============================================================================
-- LetzRyd Rental Engine - Final Tables DDL
-- ============================================================================
-- Tables:
--   1. public.core_rent: Master active rental agreement per vehicle & partner
--   2. public.core_rent_logs: Audit history of plan changes, rates, and updates
--   3. public.daily_rent_log: Daily attendance-driven rent & indemnity ledger
--
-- Target DB: PostgreSQL (Cloud SQL)
-- Reconciled Accuracy: 99.6% across 1,249 fleet vehicles in Hyderabad, Mumbai, Bangalore
-- ============================================================================

-- Table 1: core_rent (Master Agreement)
CREATE TABLE IF NOT EXISTS core_rent (
    id SERIAL PRIMARY KEY,
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    city VARCHAR(32) NOT NULL,
    vehicle_model VARCHAR(64) NOT NULL,
    plan_scheme VARCHAR(64) NOT NULL DEFAULT 'Uber Reducing Rent',
    custom_daily_rent NUMERIC(10,2) NULL,
    custom_daily_indemnity NUMERIC(10,2) NULL,
    enable_age_discount BOOLEAN NOT NULL DEFAULT FALSE,       -- Dormant feature toggle
    enable_volume_discount BOOLEAN NOT NULL DEFAULT FALSE,    -- Dormant feature toggle
    effective_from DATE NOT NULL,
    effective_to DATE NOT NULL DEFAULT '9999-12-31',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_core_rent_vehicle_window UNIQUE (vehicle_number, effective_from)
);

CREATE INDEX IF NOT EXISTS idx_core_rent_vehicle ON core_rent (vehicle_number, is_active);
CREATE INDEX IF NOT EXISTS idx_core_rent_partner ON core_rent (partner_id, is_active);

-- Table 2: core_rent_logs (Audit History)
CREATE TABLE IF NOT EXISTS core_rent_logs (
    id SERIAL PRIMARY KEY,
    core_rent_id INT NOT NULL,
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    action VARCHAR(32) NOT NULL,                              -- 'CREATED', 'UPDATED', 'DEACTIVATED'
    old_values JSONB,
    new_values JSONB,
    reason TEXT,
    changed_by VARCHAR(64) NOT NULL DEFAULT 'system',
    changed_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_core_rent_logs_core_rent ON core_rent_logs (core_rent_id);
CREATE INDEX IF NOT EXISTS idx_core_rent_logs_vehicle ON core_rent_logs (vehicle_number);

-- Table 3: daily_rent_log (Daily Ledger / Output)
CREATE TABLE IF NOT EXISTS daily_rent_log (
    id SERIAL PRIMARY KEY,
    log_date DATE NOT NULL,
    week_id VARCHAR(16) NOT NULL,                             -- e.g. 'CY26WK26'
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    city VARCHAR(32) NOT NULL,
    vehicle_model VARCHAR(64) NOT NULL,
    attendance_status VARCHAR(32) NOT NULL,                   -- 'On-road', 'Grounded', 'Workshop'
    is_billable_day BOOLEAN NOT NULL,                         -- TRUE if On-road, FALSE if Grounded/Workshop
    weekly_completed_trips INT NOT NULL DEFAULT 0,
    applied_daily_rent NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    applied_daily_indemnity NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    net_daily_rent NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    calculation_rule VARCHAR(128),
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_daily_rent_log UNIQUE (log_date, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_daily_rent_log_week_veh ON daily_rent_log (week_id, vehicle_number);
CREATE INDEX IF NOT EXISTS idx_daily_rent_log_week_partner ON daily_rent_log (week_id, partner_id);
