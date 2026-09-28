-- ============================================================================
-- LETZRYD HISAAB ENGINE - REBUILT PRODUCTION SCHEMA
-- Database: PostgreSQL 14+
-- Module: Hisaab Engine & Weekly Vehicle Settlements
-- Architecture: 100% Downstream Batch Aggregation (Zero Upstream Triggers)
-- Scope: Onroad Days, Lease Rent, Uber Telemetry, Ola Telemetry
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
-- 2. hisaab_vehicle_weekly
-- Core weekly settlement table scoped strictly to verified components:
-- Attendance (Onroad/Allotted days), Lease Rent, Uber Telemetry, Ola Telemetry.
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
    
    -- Deductions, Adjustments & Challans
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
    
    CONSTRAINT uq_hisaab_veh_week UNIQUE (week_id, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_hisaab_veh_week_lookup ON public.hisaab_vehicle_weekly (week_id, vehicle_number);
CREATE INDEX IF NOT EXISTS idx_hisaab_veh_partner ON public.hisaab_vehicle_weekly (week_id, partner_id);
CREATE INDEX IF NOT EXISTS idx_hisaab_veh_city ON public.hisaab_vehicle_weekly (city, week_id);

-- ----------------------------------------------------------------------------
-- 3. hisaab_vehicle_payout_weekly
-- Operational Payout Settlement Table with strict Monday 11:00 AM IST cutoff freeze.
-- Any late data (scraped challans, adjustments approved after cutoff) for past weeks
-- is rolled forward into the next active week as an adjustment.
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
    adjustment_amount NUMERIC(12, 2) DEFAULT 0.00,               -- On-time adjustments within cutoff
    prior_period_adjustment_amount NUMERIC(12, 2) DEFAULT 0.00,  -- Late adjustments from prior frozen weeks
    challan_amount NUMERIC(12, 2) DEFAULT 0.00,                  -- On-time in-week challans (created <= Monday 11AM)
    challan_adjustment_amount NUMERIC(12, 2) DEFAULT 0.00,       -- Late past challans rolled into this week
    
    -- Other Deductions
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
