-- ============================================================================
-- LETZRYD HISAAB ENGINE - REBUILT PRODUCTION SCHEMA
-- Database: PostgreSQL 14+
-- Module: Hisaab Engine & Daily / Weekly Settlements
-- Architecture: 100% Downstream Batch Aggregation (Zero Upstream Triggers)
-- Scope: Daily Ledger, Onroad Attendance, Lease Rent, Uber, Ola, Rapido, GPS Telematics, Challans, Adjustments
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. hisaab_settlement_weeks
-- Master settlement calendar and billing cycle boundaries.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_settlement_weeks (
    week_id VARCHAR(20) PRIMARY KEY,                    -- e.g. 'CY26WK26'
    settlement_year INT NOT NULL,                       -- e.g. 2026
    settlement_week INT NOT NULL,                       -- e.g. 26
    week_start DATE NOT NULL,                           -- Monday date
    week_end DATE NOT NULL,                             -- Sunday date
    lock_cutoff_at TIMESTAMPTZ NOT NULL,                -- Weekly settlement cutoff timestamp
    is_locked BOOLEAN NOT NULL DEFAULT FALSE,           -- Locked status switch
    locked_at TIMESTAMPTZ,                              -- Exact freeze timestamp
    locked_by VARCHAR(64),                              -- Admin or system user
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_hisaab_settlement_weeks_year_week UNIQUE (settlement_year, settlement_week)
);

CREATE INDEX IF NOT EXISTS idx_hisaab_weeks_dates ON public.hisaab_settlement_weeks (week_start, week_end);
CREATE INDEX IF NOT EXISTS idx_hisaab_weeks_locked ON public.hisaab_settlement_weeks (is_locked);

-- ----------------------------------------------------------------------------
-- 2. hisaab_daily_ledger
-- Core daily settlement ledger tracking daily rent, platform earnings, daily GPS distance, and daily dead penalty.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_daily_ledger (
    id BIGSERIAL PRIMARY KEY,
    log_date DATE NOT NULL,
    week_id VARCHAR(20) NOT NULL REFERENCES public.hisaab_settlement_weeks(week_id),
    vehicle_number VARCHAR(20) NOT NULL,
    partner_id VARCHAR(50) NOT NULL,
    partner_type VARCHAR(20) DEFAULT 'Individual',
    city VARCHAR(50),
    vehicle_model VARCHAR(50),
    attendance_status VARCHAR(50),
    is_billable_day BOOLEAN DEFAULT TRUE,
    
    -- Daily Lease Rent
    daily_rent_applied NUMERIC(10, 2) DEFAULT 0.00,
    daily_indemnity_fee NUMERIC(10, 2) DEFAULT 0.00,
    net_daily_rent NUMERIC(10, 2) DEFAULT 0.00,
    
    -- Daily Uber Telemetry
    uber_trips INTEGER DEFAULT 0,
    uber_fare_earnings NUMERIC(12, 2) DEFAULT 0.00,
    uber_cash_collected NUMERIC(12, 2) DEFAULT 0.00,
    uber_tolls NUMERIC(12, 2) DEFAULT 0.00,
    uber_subscription_charge NUMERIC(12, 2) DEFAULT 0.00,
    uber_incentive_credit NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Daily Ola Telemetry
    ola_trips INTEGER DEFAULT 0,
    ola_net_revenue NUMERIC(12, 2) DEFAULT 0.00,
    ola_cash_collected NUMERIC(12, 2) DEFAULT 0.00,
    ola_tolls NUMERIC(12, 2) DEFAULT 0.00,
    ola_online_payment NUMERIC(12, 2) DEFAULT 0.00,
    ola_incentive_credit NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Daily Rapido Telemetry
    rapido_trips INTEGER DEFAULT 0,
    rapido_net_revenue NUMERIC(12, 2) DEFAULT 0.00,
    rapido_cash_collected NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Daily GPS Telematics & Dead Mile Penalty
    daily_gps_distance_km NUMERIC(10, 2) DEFAULT 0.00,
    daily_trip_distance_km NUMERIC(10, 2) DEFAULT 0.00,
    daily_dead_km NUMERIC(10, 2) DEFAULT 0.00,
    daily_dead_mile_penalty NUMERIC(10, 2) DEFAULT 0.00,
    
    -- Daily Adjustments, Challans & Deductions
    daily_adjustments NUMERIC(12, 2) DEFAULT 0.00,
    daily_challans NUMERIC(12, 2) DEFAULT 0.00,
    daily_accident_recovery NUMERIC(12, 2) DEFAULT 0.00,
    weekly_incentive_credit NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Daily Net Balance
    daily_net_balance NUMERIC(12, 2) DEFAULT 0.00,
    is_locked BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT uq_hisaab_daily_ledger_record UNIQUE (log_date, vehicle_number, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_hisaab_daily_ledger_date ON public.hisaab_daily_ledger (log_date);
CREATE INDEX IF NOT EXISTS idx_hisaab_daily_ledger_week ON public.hisaab_daily_ledger (week_id);
CREATE INDEX IF NOT EXISTS idx_hisaab_daily_ledger_veh ON public.hisaab_daily_ledger (vehicle_number, log_date);
CREATE INDEX IF NOT EXISTS idx_hisaab_daily_ledger_partner ON public.hisaab_daily_ledger (partner_id, log_date);

-- ----------------------------------------------------------------------------
-- 3. hisaab_vehicle_weekly
-- Core weekly settlement table scoped to verified components:
-- Attendance (Onroad/Allotted days), Lease Rent, Uber, Ola, Rapido, GPS Dead Penalty, Challans, Adjustments.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_vehicle_weekly (
    id BIGSERIAL PRIMARY KEY,
    week_id VARCHAR(20) NOT NULL REFERENCES public.hisaab_settlement_weeks(week_id),
    week_start DATE NOT NULL,
    week_end DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    partner_id VARCHAR(50) NOT NULL,
    partner_name VARCHAR(150),
    city VARCHAR(50) NOT NULL,
    vehicle_model VARCHAR(50),
    rental_plan VARCHAR(150),
    
    -- Attendance & Billing Days (Supports half-days e.g. 6.5)
    allotted_days NUMERIC(4, 1) NOT NULL DEFAULT 0.0,
    onroad_days NUMERIC(4, 1) NOT NULL DEFAULT 0.0,
    
    -- Lease Rent Breakdown
    daily_rent_applied NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    weekly_lease_rental NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    weekly_indemnity_fees NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    net_weekly_lease_rental NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    
    -- Uber Telemetry & Revenue
    uber_trips INTEGER NOT NULL DEFAULT 0,
    uber_total_earnings NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    uber_cash_collection NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    uber_toll NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    uber_driver_sub_charge NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    uber_incentive NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    uber_week_os NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    
    -- Ola Telemetry & Revenue
    ola_trips INTEGER NOT NULL DEFAULT 0,
    ola_net_revenue NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    ola_cash_collection NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    ola_toll NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    ola_gst NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    ola_online_payment NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    ola_incentive NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    ola_week_os NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    
    -- Deductions, Adjustments, GPS Dead Mileage & Challans
    challan_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    adjustment_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    accident_deduction NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    tds_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    gps_dead_km NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    gps_dead_mile_penalty NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    
    -- Settlement Totals & Payouts
    current_week_os NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    net_to_collect_from_driver NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    net_payout_to_driver NUMERIC(12, 2) NOT NULL DEFAULT 0.00,

    -- Settlement Status & Audit Metadata
    settlement_status VARCHAR(20) NOT NULL DEFAULT 'CALCULATED',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT uq_hisaab_veh_week UNIQUE (week_id, vehicle_number, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_hisaab_veh_week_lookup ON public.hisaab_vehicle_weekly (week_id, vehicle_number);
CREATE INDEX IF NOT EXISTS idx_hisaab_veh_partner ON public.hisaab_vehicle_weekly (week_id, partner_id);
CREATE INDEX IF NOT EXISTS idx_hisaab_veh_city ON public.hisaab_vehicle_weekly (city, week_id);

-- ----------------------------------------------------------------------------
-- 4. hisaab_vehicle_payout_weekly
-- Operational Payout Settlement Table with strict Monday 11:00 AM IST cutoff freeze.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_vehicle_payout_weekly (
    id BIGSERIAL PRIMARY KEY,
    week_id VARCHAR(20) NOT NULL REFERENCES public.hisaab_settlement_weeks(week_id),
    week_start DATE NOT NULL,
    week_end DATE NOT NULL,
    lock_cutoff_at TIMESTAMPTZ,
    vehicle_number VARCHAR(20) NOT NULL,
    partner_id VARCHAR(50) NOT NULL,
    partner_name VARCHAR(150),
    city VARCHAR(50),
    vehicle_model VARCHAR(50),
    rental_plan VARCHAR(150),
    
    -- Attendance & Billing Days
    allotted_days NUMERIC(4, 1) DEFAULT 0.0,
    onroad_days NUMERIC(4, 1) DEFAULT 0.0,
    
    -- Lease Rent Breakdown
    daily_rent_applied NUMERIC(10, 2) DEFAULT 0.00,
    weekly_lease_rental NUMERIC(12, 2) DEFAULT 0.00,
    weekly_indemnity_fees NUMERIC(12, 2) DEFAULT 0.00,
    net_weekly_lease_rental NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Uber Telemetry & Revenue
    uber_trips INTEGER DEFAULT 0,
    uber_total_earnings NUMERIC(12, 2) DEFAULT 0.00,
    uber_cash_collection NUMERIC(12, 2) DEFAULT 0.00,
    uber_toll NUMERIC(12, 2) DEFAULT 0.00,
    uber_driver_sub_charge NUMERIC(12, 2) DEFAULT 0.00,
    uber_incentive NUMERIC(12, 2) DEFAULT 0.00,
    uber_week_os NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Ola Telemetry & Revenue
    ola_trips INTEGER DEFAULT 0,
    ola_net_revenue NUMERIC(12, 2) DEFAULT 0.00,
    ola_cash_collection NUMERIC(12, 2) DEFAULT 0.00,
    ola_toll NUMERIC(12, 2) DEFAULT 0.00,
    ola_gst NUMERIC(12, 2) DEFAULT 0.00,
    ola_online_payment NUMERIC(12, 2) DEFAULT 0.00,
    ola_incentive NUMERIC(12, 2) DEFAULT 0.00,
    ola_week_os NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Adjustments & Challans Breakdown (On-Time vs Late Roll-Forward)
    adjustment_amount NUMERIC(12, 2) DEFAULT 0.00,
    prior_period_adjustment_amount NUMERIC(12, 2) DEFAULT 0.00,
    challan_amount NUMERIC(12, 2) DEFAULT 0.00,
    challan_adjustment_amount NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Other Deductions & GPS Dead Mileage
    accident_deduction NUMERIC(12, 2) DEFAULT 0.00,
    tds_amount NUMERIC(12, 2) DEFAULT 0.00,
    gps_dead_km NUMERIC(10, 2) DEFAULT 0.00,
    gps_dead_mile_penalty NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Settlement Totals & Payouts
    current_week_os NUMERIC(12, 2) DEFAULT 0.00,
    net_to_collect_from_driver NUMERIC(12, 2) DEFAULT 0.00,
    net_payout_to_driver NUMERIC(12, 2) DEFAULT 0.00,
    
    -- Settlement Status & Audit Metadata ('CALCULATED' or 'FROZEN')
    settlement_status VARCHAR(20) DEFAULT 'CALCULATED',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT uq_payout_veh_partner_week UNIQUE (week_id, vehicle_number, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_payout_week_veh ON public.hisaab_vehicle_payout_weekly (week_id, vehicle_number);
CREATE INDEX IF NOT EXISTS idx_payout_partner ON public.hisaab_vehicle_payout_weekly (partner_id);

-- ----------------------------------------------------------------------------
-- 5. hisaab_partner_weekly
-- Partner-level weekly aggregation and multi-vehicle rollup table.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hisaab_partner_weekly (
    id BIGSERIAL PRIMARY KEY,
    settlement_year INT NOT NULL,
    settlement_week INT NOT NULL,
    week_id VARCHAR(20) NOT NULL REFERENCES public.hisaab_settlement_weeks(week_id),
    week_start DATE NOT NULL,
    week_end DATE NOT NULL,
    partner_id VARCHAR(50) NOT NULL,
    partner_name VARCHAR(150),
    partner_type VARCHAR(20) DEFAULT 'Individual',
    city VARCHAR(50),
    
    allotted_cars_count INT DEFAULT 0,
    total_onroad_days INT DEFAULT 0,
    total_trips INT DEFAULT 0,
    total_net_rent_billed NUMERIC(12, 2) DEFAULT 0.00,
    total_platform_earnings NUMERIC(12, 2) DEFAULT 0.00,
    total_cash_collected NUMERIC(12, 2) DEFAULT 0.00,
    total_platform_incentives NUMERIC(12, 2) DEFAULT 0.00,
    total_adjustments NUMERIC(12, 2) DEFAULT 0.00,
    total_challans NUMERIC(12, 2) DEFAULT 0.00,
    total_accidents NUMERIC(12, 2) DEFAULT 0.00,
    total_tds NUMERIC(12, 2) DEFAULT 0.00,
    total_dead_mile_penalty NUMERIC(12, 2) DEFAULT 0.00,
    
    current_week_os NUMERIC(12, 2) DEFAULT 0.00,
    previous_outstanding NUMERIC(12, 2) DEFAULT 0.00,
    amount_paid_during_week NUMERIC(12, 2) DEFAULT 0.00,
    prior_period_adjustments NUMERIC(12, 2) DEFAULT 0.00,
    
    security_deposit_target NUMERIC(12, 2) DEFAULT 5000.00,
    security_deposit_paid NUMERIC(12, 2) DEFAULT 5000.00,
    deposit_deduction_current_week NUMERIC(12, 2) DEFAULT 0.00,
    pending_deposit NUMERIC(12, 2) DEFAULT 0.00,
    
    total_outstanding NUMERIC(12, 2) DEFAULT 0.00,
    net_bank_payout NUMERIC(12, 2) DEFAULT 0.00,
    net_amount_to_collect NUMERIC(12, 2) DEFAULT 0.00,
    
    settlement_status VARCHAR(20) DEFAULT 'DRAFT',
    frozen_at TIMESTAMPTZ,
    bank_utr_reference VARCHAR(100),
    payout_account_number VARCHAR(50),
    payout_ifsc VARCHAR(50),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT uq_hisaab_partner_week UNIQUE (week_id, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_hisaab_partner_week ON public.hisaab_partner_weekly (week_id, partner_id);
CREATE INDEX IF NOT EXISTS idx_hisaab_partner_city ON public.hisaab_partner_weekly (city, week_id);
