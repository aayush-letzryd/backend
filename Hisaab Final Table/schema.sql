-- ============================================================================
-- HISAAB FINAL TABLE SCHEMA SPECIFICATION
-- Database: PostgreSQL 14+
-- Module: Hisaab Engine & Partner Settlement
-- Target Architecture: 3-Tier Multi-Grain (Daily Ledger -> Vehicle Weekly -> Partner Payout)
-- Includes: Master Week Calendar & Lock Switch, Prior-Period Adjustment Routing
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. hisaab_settlement_weeks
-- Master calendar and lock switch for company billing cycles.
-- Hard cutoff: Monday 11:00 AM IST. Once locked, the week becomes immutable.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_settlement_weeks (
    week_id VARCHAR(16) PRIMARY KEY,                    -- e.g. '2026-W26'
    settlement_year INT NOT NULL,                       -- e.g. 2026
    settlement_week INT NOT NULL,                       -- e.g. 26
    week_start DATE NOT NULL,                           -- Monday date
    week_end DATE NOT NULL,                             -- Sunday date
    lock_cutoff_at TIMESTAMPTZ NOT NULL,                -- Monday 11:00:00 AM IST
    is_locked BOOLEAN NOT NULL DEFAULT FALSE,           -- Locked status switch
    locked_at TIMESTAMPTZ,                              -- Exact freeze timestamp
    locked_by VARCHAR(64),                              -- Admin or system user
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_hisaab_weeks_dates ON public.hisaab_settlement_weeks (week_start, week_end);
CREATE INDEX IF NOT EXISTS idx_hisaab_weeks_locked ON public.hisaab_settlement_weeks (is_locked);

-- ----------------------------------------------------------------------------
-- 2. hisaab_adjustments_ledger
-- Central financial adjustments ledger (reimbursements, fines, rent-offs, damages).
-- Automatically routes late items for locked weeks into active settlement cycles.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_adjustments_ledger (
    id BIGSERIAL PRIMARY KEY,
    incident_date DATE NOT NULL,                        -- True historical date of occurrence
    incident_week_id VARCHAR(16),                       -- Week where event occurred
    settlement_week_id VARCHAR(16) NOT NULL REFERENCES public.hisaab_settlement_weeks (week_id),
    vehicle_number VARCHAR(32) NOT NULL,                -- Vehicle registration plate
    partner_id VARCHAR(64) NOT NULL,                    -- Driver or Operator code
    partner_type VARCHAR(32) DEFAULT 'Individual',      -- 'Individual' or 'Operator'
    adjustment_category VARCHAR(64) NOT NULL,           -- 'Challan', 'Rent Off', 'Maintenance/Tyre', 'Accident Damage', 'Bonus'
    amount NUMERIC(12,2) NOT NULL,                      -- Positive = Deduction; Negative = Credit/Reimbursement
    is_prior_period BOOLEAN NOT NULL DEFAULT FALSE,     -- TRUE if incident week was already locked
    effective_date DATE DEFAULT CURRENT_DATE,           -- Date posted to daily ledger (CURRENT_DATE for prior-period, incident_date for in-week)
    approval_status VARCHAR(32) NOT NULL DEFAULT 'Approved', -- 'Approved', 'Pending', 'Rejected'
    approved_by VARCHAR(64),
    reference_doc_url TEXT,                             -- Google Drive link or PDF URL
    remarks TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_hisaab_adj_settlement ON public.hisaab_adjustments_ledger (settlement_week_id, partner_id);
CREATE INDEX IF NOT EXISTS idx_hisaab_adj_vehicle ON public.hisaab_adjustments_ledger (vehicle_number, incident_date);
CREATE INDEX IF NOT EXISTS idx_hisaab_adj_prior ON public.hisaab_adjustments_ledger (is_prior_period);
CREATE INDEX IF NOT EXISTS idx_hisaab_adj_effective ON public.hisaab_adjustments_ledger (effective_date);
CREATE INDEX IF NOT EXISTS idx_hisaab_adj_approval ON public.hisaab_adjustments_ledger (approval_status);
CREATE INDEX IF NOT EXISTS idx_hisaab_adj_daily_lookup ON public.hisaab_adjustments_ledger (COALESCE(effective_date, incident_date), vehicle_number, partner_id);

-- ----------------------------------------------------------------------------
-- 3. hisaab_daily_ledger (Tier 1: Daily Shift Grain)
-- Powers the Driver Mobile App live feed, tracks pacing, and mid-week swaps day-by-day.
-- Grain: (log_date, vehicle_number, partner_id)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_daily_ledger (
    id BIGSERIAL PRIMARY KEY,
    log_date DATE NOT NULL,                             -- Calendar date (Monday to Sunday)
    week_id VARCHAR(16) NOT NULL REFERENCES public.hisaab_settlement_weeks (week_id),
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    partner_type VARCHAR(32) DEFAULT 'Individual',      -- 'Individual' or 'Operator'
    city VARCHAR(32) NOT NULL,                          -- 'BLR', 'HYD', 'MUM'
    vehicle_model VARCHAR(64),                          -- WagonR, Dzire, Xcent, EC3, etc.
    
    -- Attendance & Daily Rent
    attendance_status VARCHAR(32) NOT NULL DEFAULT 'Active', -- 'Active', 'Maintenance', 'Breakdown', 'RFD'
    is_billable_day BOOLEAN NOT NULL DEFAULT TRUE,
    daily_rent_applied NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    daily_indemnity_fee NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    net_daily_rent NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- daily_rent + indemnity (0 if non-billable)

    -- Uber Telemetry (from core_uber_daily)
    uber_trips INT NOT NULL DEFAULT 0,
    uber_fare_earnings NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    uber_cash_collected NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Stored negative
    uber_tolls NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    uber_subscription_charge NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Ola Telemetry (from core_ola_daily)
    ola_trips INT NOT NULL DEFAULT 0,
    ola_net_revenue NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- operator_bill_raw
    ola_cash_collected NUMERIC(12,2) NOT NULL DEFAULT 0.00,  -- Stored negative
    ola_tolls NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    ola_online_payment NUMERIC(12,2) NOT NULL DEFAULT 0.00,  -- Driver paid to Ola

    -- Rapido Telemetry (Future Extension)
    rapido_trips INT NOT NULL DEFAULT 0,
    rapido_net_revenue NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    rapido_cash_collected NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Daily Adjustments & Challans
    daily_adjustments NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    daily_challans NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    daily_accident_recovery NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Weekly Incentive Credit (Unlocked & credited on Sunday's row)
    weekly_incentive_credit NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Daily Net Balance for Driver App
    daily_net_balance NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Net daily delta (+ owes company, - company owes)
    is_locked BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_hisaab_daily_grain UNIQUE (log_date, vehicle_number, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_hisaab_daily_lookup ON public.hisaab_daily_ledger (partner_id, log_date);
CREATE INDEX IF NOT EXISTS idx_hisaab_daily_week ON public.hisaab_daily_ledger (week_id, vehicle_number);
CREATE INDEX IF NOT EXISTS idx_hisaab_daily_city ON public.hisaab_daily_ledger (city, log_date);

-- ----------------------------------------------------------------------------
-- 4. hisaab_vehicle_weekly (Tier 2: Weekly Vehicle Grain)
-- Mirrors 1-to-1 the Excel 'Uber + OLA Final Hisaab' sheet.
-- Itemizes every car for fleet operators and mid-week swaps.
-- Grain: (week_id, vehicle_number, partner_id)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_vehicle_weekly (
    id BIGSERIAL PRIMARY KEY,
    settlement_year INT NOT NULL,
    settlement_week INT NOT NULL,
    week_id VARCHAR(16) NOT NULL REFERENCES public.hisaab_settlement_weeks (week_id),
    week_start DATE NOT NULL,
    week_end DATE NOT NULL,
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    partner_name VARCHAR(128),
    partner_type VARCHAR(32) DEFAULT 'Individual',
    city VARCHAR(32) NOT NULL,
    vehicle_model VARCHAR(64),
    rental_plan VARCHAR(64),

    -- Operational Attendance
    allotted_days INT NOT NULL DEFAULT 0,
    onroad_days INT NOT NULL DEFAULT 0,

    -- Rent Totals
    daily_rent_applied NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    weekly_lease_rental NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- onroad_days * daily_rent_applied
    weekly_indemnity_fees NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- onroad_days * indemnity_rate
    net_weekly_lease_rental NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Platform Weekly Aggregates
    uber_trips INT NOT NULL DEFAULT 0,
    uber_total_earnings NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    uber_cash_collection NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    uber_toll NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    uber_driver_sub_charge NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    uber_week_os NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    ola_trips INT NOT NULL DEFAULT 0,
    ola_net_revenue NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    ola_toll NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    ola_gst NUMERIC(12,2) NOT NULL DEFAULT 0.00,        -- BLR 5%
    ola_online_payment NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    ola_week_os NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    rapido_trips INT NOT NULL DEFAULT 0,
    rapido_net_revenue NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Platform Milestone Incentive
    weekly_platform_incentive NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- In-Week Deductions & Adjustments
    vehicle_adjustments NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    challan_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    accident_penalties NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    dead_mile_charges NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    tds_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,     -- 1% Section 194C for Individuals

    -- Settlement Output
    current_week_os NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Net vehicle position
    to_collect NUMERIC(12,2) NOT NULL DEFAULT 0.00,      -- GREATEST(current_week_os, 0)
    to_payout NUMERIC(12,2) NOT NULL DEFAULT 0.00,       -- ABS(LEAST(current_week_os, 0))

    -- GPS Telemetry & Telematics Metrics
    total_trip_km NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_gps_km NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    ideal_gps_km NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    dead_mile_km NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    dead_mile_pct NUMERIC(8,4) NOT NULL DEFAULT 0.0000,

    -- Company Analytics
    letzryd_earning NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    letzryd_earning_per_day NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    settlement_status VARCHAR(32) NOT NULL DEFAULT 'OPEN', -- 'OPEN', 'FROZEN'
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_hisaab_veh_weekly UNIQUE (week_id, vehicle_number, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_hisaab_veh_partner ON public.hisaab_vehicle_weekly (week_id, partner_id);
CREATE INDEX IF NOT EXISTS idx_hisaab_veh_plate ON public.hisaab_vehicle_weekly (vehicle_number);

-- ----------------------------------------------------------------------------
-- 5. hisaab_partner_weekly (Tier 3: Partner Settlement & Payout Statement)
-- Mirrors 1-to-1 the Excel 'Hisaab Summary' / 'Revised Hisaab Summary'.
-- Consolidates all cars for operators into a single bank transfer / collection.
-- Grain: (week_id, partner_id)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_partner_weekly (
    id BIGSERIAL PRIMARY KEY,
    settlement_year INT NOT NULL,
    settlement_week INT NOT NULL,
    week_id VARCHAR(16) NOT NULL REFERENCES public.hisaab_settlement_weeks (week_id),
    week_start DATE NOT NULL,
    week_end DATE NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    partner_name VARCHAR(128),
    partner_type VARCHAR(32) DEFAULT 'Individual',
    city VARCHAR(32) NOT NULL,

    -- Fleet Aggregates
    allotted_cars_count INT NOT NULL DEFAULT 1,
    total_onroad_days INT NOT NULL DEFAULT 0,
    total_trips INT NOT NULL DEFAULT 0,
    total_net_rent_billed NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_platform_earnings NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_cash_collected NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_platform_incentives NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_adjustments NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_challans NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_accidents NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_tds NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Financial Balance Roll-Up
    current_week_os NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Sum of vehicle current_week_os
    previous_outstanding NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Opening dues from prior week
    amount_paid_during_week NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Mid-week collections
    prior_period_adjustments NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Late items from locked past weeks

    -- Security Deposit Ledger
    security_deposit_target NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    security_deposit_paid NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    deposit_deduction_current_week NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    pending_deposit NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Final Settlement
    total_outstanding NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- current + prev - paid + prior
    net_bank_payout NUMERIC(12,2) NOT NULL DEFAULT 0.00,   -- Negative total -> Company pays partner
    net_amount_to_collect NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Positive total -> Partner pays company

    settlement_status VARCHAR(32) NOT NULL DEFAULT 'DRAFT', -- 'DRAFT', 'FROZEN', 'DISBURSED', 'COLLECTED'
    frozen_at TIMESTAMPTZ,
    bank_utr_reference VARCHAR(64),
    payout_account_number VARCHAR(64),
    payout_ifsc VARCHAR(32),

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_hisaab_partner_weekly UNIQUE (week_id, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_hisaab_partner_lookup ON public.hisaab_partner_weekly (partner_id);
CREATE INDEX IF NOT EXISTS idx_hisaab_partner_status ON public.hisaab_partner_weekly (settlement_status);

-- ----------------------------------------------------------------------------
-- Automatic Lock Enforcement Function & Trigger
-- Prevents updating daily rows if the associated week is locked.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_prevent_locked_hisaab_update()
RETURNS TRIGGER AS $$
DECLARE
    v_locked BOOLEAN;
BEGIN
    SELECT is_locked INTO v_locked
    FROM public.hisaab_settlement_weeks
    WHERE week_id = NEW.week_id;

    IF v_locked = TRUE THEN
        RAISE EXCEPTION 'Hisaab cycle % is LOCKED. No further modifications allowed.', NEW.week_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_hisaab_daily_lock ON public.hisaab_daily_ledger;
CREATE TRIGGER trg_check_hisaab_daily_lock
BEFORE UPDATE ON public.hisaab_daily_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_prevent_locked_hisaab_update();
