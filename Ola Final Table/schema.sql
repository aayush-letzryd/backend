-- ============================================================================
-- LetzRyd Ola Final Table Architecture: Production DDL
-- Tables: public.core_ola_daily, public.core_ola_weekly
-- Purpose: Standardized Daily & Weekly Ola Revenue and Rides for Hisaab
-- ============================================================================

-- 1. core_ola_daily (Grain: service_date + vehicle_number)
CREATE TABLE IF NOT EXISTS core_ola_daily (
    id                          BIGSERIAL PRIMARY KEY,
    service_date                DATE NOT NULL,                  -- Operational ride date (from stmt_date / date_for)
    vehicle_number              VARCHAR(32) NOT NULL,           -- Clean alphanumeric license plate
    city                        VARCHAR(32) DEFAULT 'Bengaluru',-- Operating city
    primary_driver_name         VARCHAR(128),
    primary_driver_number       VARCHAR(32),
    
    -- Trip Performance Metrics
    completed_trips             INT DEFAULT 0,
    cancelled_trips             INT DEFAULT 0,
    total_bookings              INT DEFAULT 0,
    total_kms                   NUMERIC(10,2) DEFAULT 0.00,
    
    -- Revenue & Telemetry
    customer_bill               NUMERIC(12,2) DEFAULT 0.00,     -- Gross passenger fare
    operator_bill               NUMERIC(12,2) DEFAULT 0.00,     -- Net Ola revenue payable to LetzRyd (Hisaab basis)
    cancellation_revenue        NUMERIC(12,2) DEFAULT 0.00,     -- Cancellation fee compensation
    toll_and_parking            NUMERIC(12,2) DEFAULT 0.00,     -- Toll reimbursements
    cash_collected              NUMERIC(12,2) DEFAULT 0.00,     -- Driver cash collections (positive display)
    net_ola_to_pay              NUMERIC(12,2) DEFAULT 0.00,     -- Net balance from portal
    
    -- Ledger Items from Transactions
    portal_incentive            NUMERIC(12,2) DEFAULT 0.00,     -- Target incentives from transactions
    platform_fee                NUMERIC(12,2) DEFAULT 0.00,     -- Daily access fee debited
    subscription_fee            NUMERIC(12,2) DEFAULT 0.00,     -- Vehicle subscription debited
    online_payouts              NUMERIC(12,2) DEFAULT 0.00,     -- On-demand & Instapay withdrawals
    daily_driver_balance        NUMERIC(12,2) DEFAULT 0.00,     -- Daily net balance
    
    created_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_core_ola_daily UNIQUE (service_date, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_core_ola_daily_date ON core_ola_daily (service_date);
CREATE INDEX IF NOT EXISTS idx_core_ola_daily_veh ON core_ola_daily (vehicle_number);

-- 2. core_ola_weekly (Grain: week_start + week_end + vehicle_number)
CREATE TABLE IF NOT EXISTS core_ola_weekly (
    id                              BIGSERIAL PRIMARY KEY,
    week_id                         VARCHAR(32) NOT NULL,           -- e.g. 'CY26WK34'
    week_start                      DATE NOT NULL,                  -- Monday of settlement cycle
    week_end                        DATE NOT NULL,                  -- Sunday of settlement cycle
    vehicle_number                  VARCHAR(32) NOT NULL,
    city                            VARCHAR(32) DEFAULT 'Bengaluru',
    vendor_code                     VARCHAR(64),                    -- Assigned LetzRyd partner ID
    driver_name                     VARCHAR(128),
    
    -- Aggregated Weekly Trip Volumes
    onroad_days                     INT DEFAULT 0,                  -- Days with completed trips
    completed_trips                 INT DEFAULT 0,
    cancelled_trips                 INT DEFAULT 0,
    total_trips                     INT DEFAULT 0,
    total_kms                       NUMERIC(10,2) DEFAULT 0.00,
    
    -- Core Hisaab Platform Settlement Columns
    ola_net_revenue                 NUMERIC(12,2) DEFAULT 0.00,     -- SUM(operator_bill) -> Matches Hisaab Col P
    ola_toll                        NUMERIC(12,2) DEFAULT 0.00,     -- SUM(toll_parking)  -> Matches Hisaab Col Q
    ola_cash_collected              NUMERIC(12,2) DEFAULT 0.00,     -- Driver cash collection (positive display)
    ola_portal_incentive            NUMERIC(12,2) DEFAULT 0.00,     -- Actual incentives received from portal
    ola_online_payment_deductions   NUMERIC(12,2) DEFAULT 0.00,     -- Online payouts / ondemand debits
    ola_platform_fees               NUMERIC(12,2) DEFAULT 0.00,     -- Total platform access charges
    ola_subscription_fees           NUMERIC(12,2) DEFAULT 0.00,     -- Total vehicle subscriptions
    ola_week_outstanding           NUMERIC(12,2) DEFAULT 0.00,     -- Hisaab net balance contribution
    
    created_at                      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at                      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_core_ola_weekly UNIQUE (week_start, week_end, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_core_ola_weekly_week ON core_ola_weekly (week_start, week_end);
CREATE INDEX IF NOT EXISTS idx_core_ola_weekly_week_id ON core_ola_weekly (week_id);
CREATE INDEX IF NOT EXISTS idx_core_ola_weekly_veh ON core_ola_weekly (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_ola_weekly_vendor ON core_ola_weekly (vendor_code);
