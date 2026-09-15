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

-- ============================================================================
-- 3. Native Real-Time PostgreSQL Trigger (No External Scheduler Needed)
-- Automatically refreshes core_ola_daily and core_ola_weekly on batch insert
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_sync_core_ola()
RETURNS TRIGGER AS $$
BEGIN
    -- Refresh core_ola_daily
    WITH trips_daily AS (
        SELECT 
            c.stmt_date AS service_date,
            UPPER(REPLACE(c.vehicle_number, ' ', '')) AS veh_no,
            MAX(c.driver_name) AS driver_name,
            MAX(c.driver_number) AS driver_number,
            COUNT(*) FILTER (WHERE c.completion_status ILIKE '%complete%') AS completed_trips,
            COUNT(*) FILTER (WHERE c.completion_status ILIKE '%cancel%') AS cancelled_trips,
            COUNT(*) AS total_bookings,
            COALESCE(SUM(c.actual_kms_raw), 0) AS total_kms,
            COALESCE(SUM(c.customer_bill_raw), 0) AS customer_bill,
            COALESCE(SUM(c.operator_bill_raw), 0) AS operator_bill,
            COALESCE(SUM(CASE WHEN c.completion_status ILIKE '%cancel%' THEN c.operator_bill_raw ELSE 0 END), 0) AS cancellation_revenue,
            COALESCE(SUM(c.toll_parking_raw), 0) AS toll_and_parking,
            COALESCE(ABS(SUM(c.cash_collected_by_driver_raw)), 0) AS cash_collected,
            COALESCE(SUM(c.ola_to_pay), 0) AS net_ola_to_pay
        FROM ola_raw_crns c
        WHERE c.vehicle_number IS NOT NULL AND TRIM(c.vehicle_number) <> ''
        GROUP BY 1, 2
    ),
    txns_daily AS (
        SELECT 
            t.date_for AS service_date,
            UPPER(REPLACE(t.vehicle_number, ' ', '')) AS veh_no,
            COALESCE(SUM(t.amount_raw) FILTER (WHERE t.transaction_type ILIKE '%incentive%'), 0) AS portal_incentive,
            COALESCE(SUM(t.amount_raw) FILTER (WHERE t.transaction_type ILIKE '%platform%'), 0) AS platform_fee,
            COALESCE(SUM(t.amount_raw) FILTER (WHERE t.transaction_type ILIKE '%subscription%'), 0) AS subscription_fee,
            COALESCE(SUM(t.amount_raw) FILTER (WHERE t.transaction_type IN ('ondemand_account_transfer', 'bank_account_transfer') AND t.payment_type = 'debit'), 0) AS online_payouts
        FROM ola_raw_transactions t
        WHERE t.transaction_status <> 'Reversed' AND t.vehicle_number IS NOT NULL
        GROUP BY 1, 2
    ),
    combined AS (
        SELECT 
            COALESCE(t.service_date, x.service_date) AS service_date,
            COALESCE(t.veh_no, x.veh_no) AS vehicle_number,
            COALESCE(t.driver_name, '') AS primary_driver_name,
            COALESCE(t.driver_number, '') AS primary_driver_number,
            COALESCE(t.completed_trips, 0) AS completed_trips,
            COALESCE(t.cancelled_trips, 0) AS cancelled_trips,
            COALESCE(t.total_bookings, 0) AS total_bookings,
            COALESCE(t.total_kms, 0) AS total_kms,
            COALESCE(t.customer_bill, 0) AS customer_bill,
            COALESCE(t.operator_bill, 0) AS operator_bill,
            COALESCE(t.cancellation_revenue, 0) AS cancellation_revenue,
            COALESCE(t.toll_and_parking, 0) AS toll_and_parking,
            COALESCE(t.cash_collected, 0) AS cash_collected,
            COALESCE(t.net_ola_to_pay, 0) AS net_ola_to_pay,
            COALESCE(x.portal_incentive, 0) AS portal_incentive,
            COALESCE(x.platform_fee, 0) AS platform_fee,
            COALESCE(x.subscription_fee, 0) AS subscription_fee,
            COALESCE(x.online_payouts, 0) AS online_payouts,
            (COALESCE(t.operator_bill, 0) - COALESCE(t.cash_collected, 0) + COALESCE(t.toll_and_parking, 0) + COALESCE(x.portal_incentive, 0) - COALESCE(x.platform_fee, 0) - COALESCE(x.subscription_fee, 0) - COALESCE(x.online_payouts, 0)) AS daily_driver_balance
        FROM trips_daily t
        FULL OUTER JOIN txns_daily x 
          ON t.service_date = x.service_date AND t.veh_no = x.veh_no
        WHERE COALESCE(t.veh_no, x.veh_no) IS NOT NULL
    )
    INSERT INTO core_ola_daily (
        service_date, vehicle_number, city, primary_driver_name, primary_driver_number,
        completed_trips, cancelled_trips, total_bookings, total_kms, customer_bill,
        operator_bill, cancellation_revenue, toll_and_parking, cash_collected,
        net_ola_to_pay, portal_incentive, platform_fee, subscription_fee, online_payouts,
        daily_driver_balance
    )
    SELECT 
        c.service_date, c.vehicle_number, COALESCE(dvs.city, 'Bengaluru'), c.primary_driver_name, c.primary_driver_number,
        c.completed_trips, c.cancelled_trips, c.total_bookings, c.total_kms, c.customer_bill,
        c.operator_bill, c.cancellation_revenue, c.toll_and_parking, c.cash_collected,
        c.net_ola_to_pay, c.portal_incentive, c.platform_fee, c.subscription_fee, c.online_payouts,
        c.daily_driver_balance
    FROM combined c
    LEFT JOIN core_daily_vehicle_status dvs 
      ON c.vehicle_number = dvs.vehicle_number AND c.service_date = dvs.status_date
    ON CONFLICT (service_date, vehicle_number) DO UPDATE SET
        city = EXCLUDED.city,
        primary_driver_name = EXCLUDED.primary_driver_name,
        primary_driver_number = EXCLUDED.primary_driver_number,
        completed_trips = EXCLUDED.completed_trips,
        cancelled_trips = EXCLUDED.cancelled_trips,
        total_bookings = EXCLUDED.total_bookings,
        total_kms = EXCLUDED.total_kms,
        customer_bill = EXCLUDED.customer_bill,
        operator_bill = EXCLUDED.operator_bill,
        cancellation_revenue = EXCLUDED.cancellation_revenue,
        toll_and_parking = EXCLUDED.toll_and_parking,
        cash_collected = EXCLUDED.cash_collected,
        net_ola_to_pay = EXCLUDED.net_ola_to_pay,
        portal_incentive = EXCLUDED.portal_incentive,
        platform_fee = EXCLUDED.platform_fee,
        subscription_fee = EXCLUDED.subscription_fee,
        online_payouts = EXCLUDED.online_payouts,
        daily_driver_balance = EXCLUDED.daily_driver_balance,
        updated_at = NOW();

    -- Refresh core_ola_weekly
    WITH weekly_cal AS (
        SELECT 
            d.service_date, d.vehicle_number, d.city, d.primary_driver_name,
            d.completed_trips, d.cancelled_trips, d.total_bookings, d.total_kms,
            d.operator_bill, d.toll_and_parking, d.cash_collected, d.portal_incentive,
            d.platform_fee, d.subscription_fee, d.online_payouts,
            DATE_TRUNC('week', d.service_date)::date AS week_start,
            (DATE_TRUNC('week', d.service_date) + INTERVAL '6 days')::date AS week_end,
            'CY' || SUBSTRING(EXTRACT(ISOYEAR FROM d.service_date)::text FROM 3 FOR 2) || 'WK' || LPAD(EXTRACT(WEEK FROM d.service_date)::text, 2, '0') AS week_id
        FROM core_ola_daily d
    ),
    weekly_agg AS (
        SELECT 
            w.week_id, w.week_start, w.week_end, w.vehicle_number,
            MAX(w.city) AS city, MAX(w.primary_driver_name) AS driver_name,
            COUNT(DISTINCT w.service_date) FILTER (WHERE w.completed_trips > 0) AS onroad_days,
            SUM(w.completed_trips) AS completed_trips,
            SUM(w.cancelled_trips) AS cancelled_trips,
            SUM(w.total_bookings) AS total_trips,
            SUM(w.total_kms) AS total_kms,
            SUM(w.operator_bill) AS ola_net_revenue,
            SUM(w.toll_and_parking) AS ola_toll,
            SUM(w.cash_collected) AS ola_cash_collected,
            SUM(w.portal_incentive) AS ola_portal_incentive,
            SUM(w.online_payouts) AS ola_online_payment_deductions,
            SUM(w.platform_fee) AS ola_platform_fees,
            SUM(w.subscription_fee) AS ola_subscription_fees,
            (SUM(w.operator_bill) - SUM(w.cash_collected) + SUM(w.toll_and_parking) + SUM(w.portal_incentive) - SUM(w.platform_fee) - SUM(w.subscription_fee) - SUM(w.online_payouts)) AS ola_week_outstanding
        FROM weekly_cal w
        GROUP BY w.week_id, w.week_start, w.week_end, w.vehicle_number
    )
    INSERT INTO core_ola_weekly (
        week_id, week_start, week_end, vehicle_number, city, vendor_code, driver_name,
        onroad_days, completed_trips, cancelled_trips, total_trips, total_kms,
        ola_net_revenue, ola_toll, ola_cash_collected, ola_portal_incentive,
        ola_online_payment_deductions, ola_platform_fees, ola_subscription_fees, ola_week_outstanding
    )
    SELECT 
        w.week_id, w.week_start, w.week_end, w.vehicle_number, w.city,
        dvs.partner_id AS vendor_code, w.driver_name, w.onroad_days,
        w.completed_trips, w.cancelled_trips, w.total_trips, w.total_kms,
        w.ola_net_revenue, w.ola_toll, w.ola_cash_collected, w.ola_portal_incentive,
        w.ola_online_payment_deductions, w.ola_platform_fees, w.ola_subscription_fees, w.ola_week_outstanding
    FROM weekly_agg w
    LEFT JOIN core_daily_vehicle_status dvs 
      ON w.vehicle_number = dvs.vehicle_number AND w.week_start = dvs.status_date
    ON CONFLICT (week_start, week_end, vehicle_number) DO UPDATE SET
        city = EXCLUDED.city,
        vendor_code = EXCLUDED.vendor_code,
        driver_name = EXCLUDED.driver_name,
        onroad_days = EXCLUDED.onroad_days,
        completed_trips = EXCLUDED.completed_trips,
        cancelled_trips = EXCLUDED.cancelled_trips,
        total_trips = EXCLUDED.total_trips,
        total_kms = EXCLUDED.total_kms,
        ola_net_revenue = EXCLUDED.ola_net_revenue,
        ola_toll = EXCLUDED.ola_toll,
        ola_cash_collected = EXCLUDED.ola_cash_collected,
        ola_portal_incentive = EXCLUDED.ola_portal_incentive,
        ola_online_payment_deductions = EXCLUDED.ola_online_payment_deductions,
        ola_platform_fees = EXCLUDED.ola_platform_fees,
        ola_subscription_fees = EXCLUDED.ola_subscription_fees,
        ola_week_outstanding = EXCLUDED.ola_week_outstanding,
        updated_at = NOW();

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Statement-level Trigger on ola_raw_crns
DROP TRIGGER IF EXISTS trg_sync_core_ola ON ola_raw_crns;
CREATE TRIGGER trg_sync_core_ola
AFTER INSERT OR UPDATE ON ola_raw_crns
FOR EACH STATEMENT
EXECUTE FUNCTION fn_sync_core_ola();
