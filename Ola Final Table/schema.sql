-- ============================================================================
-- LetzRyd Ola Final Table Architecture: Production DDL
-- Tables: public.core_ola_daily, public.core_ola_weekly
-- Purpose: Standardized Daily & Weekly Ola Revenue and Telemetry for Hisaab
-- Execution Engine: pg_cron (Asynchronous, Zero-Trigger Isolation from Raw)
-- ============================================================================

-- 1. core_ola_daily (Grain: service_date + vehicle_number)
CREATE TABLE IF NOT EXISTS core_ola_daily (
    id                          BIGSERIAL PRIMARY KEY,
    service_date                DATE NOT NULL,                  -- Operational ride date (from stmt_date / date_for)
    vehicle_number              VARCHAR(32) NOT NULL,           -- Clean alphanumeric license plate (e.g. KA05AP6033)
    city                        VARCHAR(32) DEFAULT 'Bengaluru',-- Operating city (Bengaluru, Hyderabad, Mumbai)
    primary_driver_name         VARCHAR(128),                   -- Driver name from telemetry or allocation
    primary_driver_number       VARCHAR(32),                    -- Driver phone number
    
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
    cash_collected              NUMERIC(12,2) DEFAULT 0.00,     -- Driver cash collections (positive magnitude)
    net_ola_to_pay              NUMERIC(12,2) DEFAULT 0.00,     -- Net balance from portal
    
    -- Ledger Items from Transactions
    portal_incentive            NUMERIC(12,2) DEFAULT 0.00,     -- Target incentives from transactions
    platform_fee                NUMERIC(12,2) DEFAULT 0.00,     -- Daily access fee debited
    subscription_fee            NUMERIC(12,2) DEFAULT 0.00,     -- Net vehicle subscription (debits minus credits)
    online_payouts              NUMERIC(12,2) DEFAULT 0.00,     -- On-demand, Instapay withdrawals & digital fare credits
    daily_driver_balance        NUMERIC(12,2) DEFAULT 0.00,     -- Driver net balance (Positive = Driver owes, Negative = Company owes)
    
    created_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_core_ola_daily UNIQUE (service_date, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_core_ola_daily_date ON core_ola_daily (service_date);
CREATE INDEX IF NOT EXISTS idx_core_ola_daily_veh ON core_ola_daily (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_ola_daily_city ON core_ola_daily (city);

-- 2. core_ola_weekly (Grain: week_start + week_end + vehicle_number)
CREATE TABLE IF NOT EXISTS core_ola_weekly (
    id                              BIGSERIAL PRIMARY KEY,
    week_id                         VARCHAR(32) NOT NULL,           -- e.g. 'CY26WK37'
    week_start                      DATE NOT NULL,                  -- Monday of settlement cycle
    week_end                        DATE NOT NULL,                  -- Sunday of settlement cycle
    vehicle_number                  VARCHAR(32) NOT NULL,
    city                            VARCHAR(32) DEFAULT 'Bengaluru',
    vendor_code                     VARCHAR(64),                    -- Assigned LetzRyd partner ID (dominant in week)
    driver_name                     VARCHAR(128),
    
    -- Aggregated Weekly Trip Volumes
    onroad_days                     INT DEFAULT 0,                  -- Days with completed trips
    completed_trips                 INT DEFAULT 0,
    cancelled_trips                 INT DEFAULT 0,
    total_trips                     INT DEFAULT 0,
    total_kms                       NUMERIC(10,2) DEFAULT 0.00,
    
    -- Core Hisaab Platform Settlement Columns
    ola_net_revenue                 NUMERIC(12,2) DEFAULT 0.00,     -- SUM(operator_bill) -> Matches Hisaab Col P/S
    ola_toll                        NUMERIC(12,2) DEFAULT 0.00,     -- SUM(toll_parking)  -> Matches Hisaab Col Q/T
    ola_cash_collected              NUMERIC(12,2) DEFAULT 0.00,     -- Driver cash collection (positive magnitude)
    ola_portal_incentive            NUMERIC(12,2) DEFAULT 0.00,     -- Actual incentives received from portal
    ola_online_payment_deductions   NUMERIC(12,2) DEFAULT 0.00,     -- Online payouts / ondemand debits / online collections
    ola_platform_fees               NUMERIC(12,2) DEFAULT 0.00,     -- Total platform access charges
    ola_subscription_fees           NUMERIC(12,2) DEFAULT 0.00,     -- Total net vehicle subscriptions
    ola_week_outstanding           NUMERIC(12,2) DEFAULT 0.00,     -- Hisaab net balance: Cash - Net Revenue - Online Payouts
    
    created_at                      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at                      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_core_ola_weekly UNIQUE (week_start, week_end, vehicle_number)
);

CREATE INDEX IF NOT EXISTS idx_core_ola_weekly_week ON core_ola_weekly (week_start, week_end);
CREATE INDEX IF NOT EXISTS idx_core_ola_weekly_week_id ON core_ola_weekly (week_id);
CREATE INDEX IF NOT EXISTS idx_core_ola_weekly_veh ON core_ola_weekly (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_ola_weekly_vendor ON core_ola_weekly (vendor_code);

-- ============================================================================
-- 3. Production Stored Procedure: sp_sync_core_ola
-- Idempotent, full-week safe rollup with zero raw trigger dependencies
-- ============================================================================

CREATE OR REPLACE PROCEDURE public.sp_sync_core_ola(
    p_start_date DATE DEFAULT NULL,
    p_end_date   DATE DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start DATE := COALESCE(p_start_date, CURRENT_DATE - INTERVAL '14 days');
    v_end   DATE := COALESCE(p_end_date, CURRENT_DATE);
    v_week_start DATE;
    v_week_end   DATE;
BEGIN
    -- Derive Monday of earliest week and Sunday of latest week to guarantee full weekly rollup
    v_week_start := DATE_TRUNC('week', v_start)::date;
    v_week_end   := (DATE_TRUNC('week', v_end) + INTERVAL '6 days')::date;

    RAISE NOTICE '[sp_sync_core_ola] Syncing Daily [% to %] and Weekly [% to %]', v_start, v_end, v_week_start, v_week_end;

    -- 1. Refresh core_ola_daily for target date window
    WITH trips_daily AS (
        SELECT 
            c.stmt_date AS service_date,
            UPPER(REPLACE(c.vehicle_number, ' ', '')) AS veh_no,
            MAX(NULLIF(TRIM(c.driver_name), '')) AS driver_name,
            MAX(NULLIF(TRIM(c.driver_number), '')) AS driver_number,
            COUNT(DISTINCT c.crn) FILTER (WHERE c.completion_status ILIKE '%complete%') AS completed_trips,
            COUNT(DISTINCT c.crn) FILTER (WHERE c.completion_status ILIKE '%cancel%') AS cancelled_trips,
            COUNT(DISTINCT c.crn) AS total_bookings,
            COALESCE(SUM(c.actual_kms_raw), 0.00) AS total_kms,
            COALESCE(SUM(c.customer_bill_raw), 0.00) AS customer_bill,
            COALESCE(SUM(c.operator_bill_raw), 0.00) AS operator_bill,
            COALESCE(SUM(CASE WHEN c.completion_status ILIKE '%cancel%' THEN c.operator_bill_raw ELSE 0.00 END), 0.00) AS cancellation_revenue,
            COALESCE(SUM(c.toll_parking_raw), 0.00) AS toll_and_parking,
            COALESCE(SUM(ABS(c.cash_collected_by_driver_raw)), 0.00) AS cash_collected,
            COALESCE(SUM(c.ola_to_pay), 0.00) AS net_ola_to_pay
        FROM public.ola_raw_crns c
        WHERE c.vehicle_number IS NOT NULL AND TRIM(c.vehicle_number) <> ''
          AND c.stmt_date BETWEEN v_start AND v_end
        GROUP BY 1, 2
    ),
    txns_daily AS (
        SELECT 
            COALESCE(t.date_for, t.stmt_date) AS service_date,
            UPPER(REPLACE(t.vehicle_number, ' ', '')) AS veh_no,
            COALESCE(SUM(t.amount_raw) FILTER (WHERE t.transaction_type ILIKE '%incentive%'), 0.00) AS portal_incentive,
            COALESCE(SUM(t.amount_raw) FILTER (WHERE t.transaction_type ILIKE '%platform%' OR t.transaction_type = 'bank_transfer_charge'), 0.00) AS platform_fee,
            COALESCE(SUM(t.amount_raw) FILTER (WHERE t.transaction_type ILIKE '%subscription%' AND t.payment_type = 'debit'), 0.00)
              - COALESCE(SUM(t.amount_raw) FILTER (WHERE t.transaction_type = 'collection' AND t.sub_category = 'subscription_fee'), 0.00) AS subscription_fee,
            COALESCE(SUM(t.amount_raw) FILTER (
                WHERE (t.transaction_type IN ('ondemand_account_transfer', 'bank_account_transfer') AND t.payment_type = 'debit')
                   OR (t.transaction_type = 'collection' AND t.sub_category = 'online_payment')
            ), 0.00)
              - COALESCE(SUM(t.amount_raw) FILTER (
                WHERE t.transaction_type = 'failed_ondemand_account_transfer' AND t.payment_type = 'credit'
            ), 0.00) AS online_payouts
        FROM public.ola_raw_transactions t
        WHERE t.transaction_status <> 'Reversed'
          AND t.vehicle_number IS NOT NULL AND TRIM(t.vehicle_number) <> ''
          AND COALESCE(t.date_for, t.stmt_date) BETWEEN v_start AND v_end
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
            COALESCE(t.total_kms, 0.00) AS total_kms,
            COALESCE(t.customer_bill, 0.00) AS customer_bill,
            COALESCE(t.operator_bill, 0.00) AS operator_bill,
            COALESCE(t.cancellation_revenue, 0.00) AS cancellation_revenue,
            COALESCE(t.toll_and_parking, 0.00) AS toll_and_parking,
            COALESCE(t.cash_collected, 0.00) AS cash_collected,
            COALESCE(t.net_ola_to_pay, 0.00) AS net_ola_to_pay,
            COALESCE(x.portal_incentive, 0.00) AS portal_incentive,
            COALESCE(x.platform_fee, 0.00) AS platform_fee,
            COALESCE(x.subscription_fee, 0.00) AS subscription_fee,
            COALESCE(x.online_payouts, 0.00) AS online_payouts,
            (COALESCE(t.cash_collected, 0.00) - COALESCE(t.operator_bill, 0.00) - COALESCE(x.online_payouts, 0.00) - COALESCE(x.portal_incentive, 0.00) + COALESCE(x.platform_fee, 0.00) + COALESCE(x.subscription_fee, 0.00)) AS daily_driver_balance
        FROM trips_daily t
        FULL OUTER JOIN txns_daily x 
          ON t.service_date = x.service_date AND t.veh_no = x.veh_no
        WHERE COALESCE(t.veh_no, x.veh_no) IS NOT NULL
    )
    INSERT INTO public.core_ola_daily (
        service_date, vehicle_number, city, primary_driver_name, primary_driver_number,
        completed_trips, cancelled_trips, total_bookings, total_kms, customer_bill,
        operator_bill, cancellation_revenue, toll_and_parking, cash_collected,
        net_ola_to_pay, portal_incentive, platform_fee, subscription_fee, online_payouts,
        daily_driver_balance, updated_at
    )
    SELECT 
        c.service_date,
        c.vehicle_number,
        COALESCE(
            dvs.city, 
            veh_meta.city, 
            CASE 
                WHEN c.vehicle_number LIKE 'TG%' OR c.vehicle_number LIKE 'TS%' THEN 'Hyderabad'
                WHEN c.vehicle_number LIKE 'MH%' THEN 'Mumbai'
                WHEN c.vehicle_number LIKE 'KA%' THEN 'Bengaluru'
                ELSE 'Bengaluru'
            END
        ) AS city,
        COALESCE(NULLIF(c.primary_driver_name, ''), NULLIF(dvs.partner_name, '')) AS primary_driver_name,
        COALESCE(NULLIF(c.primary_driver_number, ''), NULLIF(dvs.partner_phone, '')) AS primary_driver_number,
        c.completed_trips, c.cancelled_trips, c.total_bookings, c.total_kms, c.customer_bill,
        c.operator_bill, c.cancellation_revenue, c.toll_and_parking, c.cash_collected,
        c.net_ola_to_pay, c.portal_incentive, c.platform_fee, c.subscription_fee, c.online_payouts,
        c.daily_driver_balance,
        NOW()
    FROM combined c
    LEFT JOIN public.core_daily_vehicle_status dvs 
      ON c.vehicle_number = dvs.vehicle_number AND c.service_date = dvs.status_date
    LEFT JOIN LATERAL (
        SELECT city 
        FROM public.core_daily_vehicle_status 
        WHERE vehicle_number = c.vehicle_number AND city IS NOT NULL 
        ORDER BY status_date DESC LIMIT 1
    ) veh_meta ON TRUE
    ON CONFLICT (service_date, vehicle_number) DO UPDATE SET
        city = EXCLUDED.city,
        primary_driver_name = COALESCE(EXCLUDED.primary_driver_name, core_ola_daily.primary_driver_name),
        primary_driver_number = COALESCE(EXCLUDED.primary_driver_number, core_ola_daily.primary_driver_number),
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

    -- 2. Refresh core_ola_weekly for FULL weeks overlapping the window
    WITH weekly_cal AS (
        SELECT 
            d.service_date, d.vehicle_number, d.city, d.primary_driver_name,
            d.completed_trips, d.cancelled_trips, d.total_bookings, d.total_kms,
            d.operator_bill, d.toll_and_parking, d.cash_collected, d.portal_incentive,
            d.platform_fee, d.subscription_fee, d.online_payouts,
            DATE_TRUNC('week', d.service_date)::date AS week_start,
            (DATE_TRUNC('week', d.service_date) + INTERVAL '6 days')::date AS week_end,
            'CY' || SUBSTRING(EXTRACT(ISOYEAR FROM d.service_date)::text FROM 3 FOR 2) || 'WK' || LPAD(EXTRACT(WEEK FROM d.service_date)::text, 2, '0') AS week_id
        FROM public.core_ola_daily d
        WHERE d.service_date BETWEEN v_week_start AND v_week_end
    ),
    weekly_agg AS (
        SELECT 
            w.week_id, w.week_start, w.week_end, w.vehicle_number,
            MODE() WITHIN GROUP (ORDER BY w.city) AS city,
            MAX(NULLIF(w.primary_driver_name, '')) AS driver_name,
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
            (SUM(w.cash_collected) - SUM(w.operator_bill) - SUM(w.online_payouts)) AS ola_week_outstanding
        FROM weekly_cal w
        GROUP BY w.week_id, w.week_start, w.week_end, w.vehicle_number
    ),
    weekly_vendor AS (
        SELECT 
            w.week_start,
            w.vehicle_number,
            COALESCE(
                (SELECT partner_id 
                 FROM public.core_daily_vehicle_status dvs 
                 WHERE dvs.vehicle_number = w.vehicle_number 
                   AND dvs.status_date BETWEEN w.week_start AND w.week_end
                   AND dvs.partner_id IS NOT NULL AND TRIM(dvs.partner_id) <> ''
                 GROUP BY partner_id 
                 ORDER BY COUNT(*) DESC, MAX(status_date) DESC LIMIT 1),
                (SELECT partner_id 
                 FROM public.rental_custom_partner_plans cr 
                 WHERE cr.vehicle_number = w.vehicle_number AND cr.is_active = TRUE 
                 LIMIT 1)
            ) AS vendor_code
        FROM (SELECT DISTINCT week_start, week_end, vehicle_number FROM weekly_agg) w
    )
    INSERT INTO public.core_ola_weekly (
        week_id, week_start, week_end, vehicle_number, city, vendor_code, driver_name,
        onroad_days, completed_trips, cancelled_trips, total_trips, total_kms,
        ola_net_revenue, ola_toll, ola_cash_collected, ola_portal_incentive,
        ola_online_payment_deductions, ola_platform_fees, ola_subscription_fees,
        ola_week_outstanding, updated_at
    )
    SELECT 
        w.week_id, w.week_start, w.week_end, w.vehicle_number, w.city,
        wv.vendor_code, w.driver_name, w.onroad_days,
        w.completed_trips, w.cancelled_trips, w.total_trips, w.total_kms,
        w.ola_net_revenue, w.ola_toll, w.ola_cash_collected, w.ola_portal_incentive,
        w.ola_online_payment_deductions, w.ola_platform_fees, w.ola_subscription_fees,
        w.ola_week_outstanding,
        NOW()
    FROM weekly_agg w
    LEFT JOIN weekly_vendor wv 
      ON w.week_start = wv.week_start AND w.vehicle_number = wv.vehicle_number
    ON CONFLICT (week_start, week_end, vehicle_number) DO UPDATE SET
        city = EXCLUDED.city,
        vendor_code = COALESCE(EXCLUDED.vendor_code, core_ola_weekly.vendor_code),
        driver_name = COALESCE(EXCLUDED.driver_name, core_ola_weekly.driver_name),
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

    RAISE NOTICE '[sp_sync_core_ola] Sync completed successfully.';
END;
$$;

-- 4. Overloaded Procedure Signatures for Type-Safety (Handles Timestamp from INTERVAL math)
CREATE OR REPLACE PROCEDURE public.sp_sync_core_ola(
    p_start_date TIMESTAMP WITHOUT TIME ZONE,
    p_end_date   DATE DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    CALL public.sp_sync_core_ola(p_start_date::date, p_end_date);
END;
$$;

CREATE OR REPLACE PROCEDURE public.sp_sync_core_ola(
    p_start_date TIMESTAMP WITHOUT TIME ZONE,
    p_end_date   TIMESTAMP WITHOUT TIME ZONE
)
LANGUAGE plpgsql
AS $$
BEGIN
    CALL public.sp_sync_core_ola(p_start_date::date, p_end_date::date);
END;
$$;

-- 5. Backward Compatibility Wrapper Function
CREATE OR REPLACE FUNCTION public.fn_sync_core_ola(
    p_start_date DATE DEFAULT NULL::date,
    p_end_date   DATE DEFAULT NULL::date
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    CALL public.sp_sync_core_ola(p_start_date, p_end_date);
END;
$$;

-- ============================================================================
-- 6. pg_cron Recurring Schedule Configuration (Runs Every 30 Minutes)
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        -- Unschedule existing job if present
        PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'sync_core_ola_30m';
        
        -- Schedule 30-minute recurring execution
        PERFORM cron.schedule(
            'sync_core_ola_30m',
            '*/30 * * * *',
            'CALL public.sp_sync_core_ola((CURRENT_DATE - INTERVAL ''14 days'')::date, CURRENT_DATE);'
        );
        RAISE NOTICE 'pg_cron job sync_core_ola_30m scheduled successfully.';
    END IF;
END $$;

