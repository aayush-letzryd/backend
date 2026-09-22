-- ============================================================================
-- LetzRyd Uber Final Table Architecture: Production DDL
-- Tables: public.core_uber_daily, public.core_uber_weekly
-- Procedure: public.sp_sync_core_uber(p_start_date, p_end_date, p_lookback_days)
-- Automation Engine: Native PostgreSQL pg_cron (Staggered: 5,35 * * * *)
-- Architecture Standard: 100% Decoupled, Zero-Trigger Fault Isolation
-- ============================================================================

-- 1. core_uber_daily (Grain: operational_date + vehicle_number + driver_uuid)
CREATE TABLE IF NOT EXISTS public.core_uber_daily (
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
    net_fare_earnings           NUMERIC(12,2) DEFAULT 0.00,     -- Gross rider fare earnings (excluding promotions & sub fees)
    cash_collected              NUMERIC(12,2) DEFAULT 0.00,     -- Rider cash collected by driver (strictly positive ABS magnitude)
    tolls_refunded              NUMERIC(12,2) DEFAULT 0.00,     -- Toll reimbursements
    driver_subscription_charge  NUMERIC(12,2) DEFAULT 0.00,     -- Platform / subscription debits
    net_driver_day_balance      NUMERIC(12,2) DEFAULT 0.00,     -- Daily net (earnings - cash_collected + toll - sub_charge)
    
    -- Metadata
    source_origin               VARCHAR(64) DEFAULT 'uber_pipeline',
    created_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_core_uber_daily UNIQUE (operational_date, vehicle_number, driver_uuid)
);

COMMENT ON COLUMN public.core_uber_daily.cash_collected IS 'Rider cash collected by driver (strictly stored as positive magnitude ABS).';
COMMENT ON COLUMN public.core_uber_daily.net_driver_day_balance IS 'Daily net balance: (net_fare_earnings - cash_collected + tolls_refunded - driver_subscription_charge).';

CREATE INDEX IF NOT EXISTS idx_core_uber_daily_date ON public.core_uber_daily (operational_date);
CREATE INDEX IF NOT EXISTS idx_core_uber_daily_veh ON public.core_uber_daily (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_uber_daily_vendor ON public.core_uber_daily (vendor_code);
CREATE INDEX IF NOT EXISTS idx_core_uber_daily_date_veh ON public.core_uber_daily (operational_date, vehicle_number);

-- 2. core_uber_weekly (Grain: settlement_year + settlement_week + vehicle_number)
CREATE TABLE IF NOT EXISTS public.core_uber_weekly (
    id                          BIGSERIAL PRIMARY KEY,
    settlement_year             INT NOT NULL,                   -- ISO Year (e.g. 2026)
    settlement_week             INT NOT NULL,                   -- ISO Week (e.g. 26, 37)
    week_id                     VARCHAR(32) NOT NULL,           -- Formatted Week ID (e.g. 'CY26WK37')
    week_start                  DATE NOT NULL,                  -- Monday of settlement week
    week_end                    DATE NOT NULL,                  -- Sunday of settlement week
    vehicle_number              VARCHAR(32) NOT NULL,
    vendor_code                 VARCHAR(64),                    -- Primary assigned partner ID (dominant in week)
    city                        VARCHAR(32) DEFAULT 'Hyderabad',
    
    -- Aggregated Weekly Trip Metrics
    active_days                 INT DEFAULT 0,                  -- Days vehicle had >=1 completed trip
    completed_trips             INT DEFAULT 0,
    total_trip_km               NUMERIC(10,2) DEFAULT 0.00,
    
    -- Weekly Financials for Hisaab Settlement
    uber_total_earnings         NUMERIC(12,2) DEFAULT 0.00,     -- Net Fare + Promotions -> Hisaab
    uber_cash_collection        NUMERIC(12,2) DEFAULT 0.00,     -- Total cash collected by driver (strictly positive ABS magnitude)
    uber_toll                   NUMERIC(12,2) DEFAULT 0.00,     -- Toll reimbursement -> Hisaab
    uber_driver_sub_charge      NUMERIC(12,2) DEFAULT 0.00,     -- Driver subscription charge -> Hisaab
    uber_vehicle_incentive      NUMERIC(12,2) DEFAULT 0.00,     -- Vehicle milestone incentive
    uber_pass_on_incentive      NUMERIC(12,2) DEFAULT 0.00,     -- Driver share based on target slab
    uber_letzryd_incentive      NUMERIC(12,2) DEFAULT 0.00,     -- Retained company incentive
    
    -- Net Weekly Balance
    uber_week_balance           NUMERIC(12,2) DEFAULT 0.00,     -- (earnings - cash_collected + toll - sub_charge + incentive)
    
    created_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at                  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_core_uber_weekly UNIQUE (settlement_year, settlement_week, vehicle_number)
);

COMMENT ON COLUMN public.core_uber_weekly.uber_cash_collection IS 'Total rider cash collected by driver (strictly stored as positive magnitude ABS).';
COMMENT ON COLUMN public.core_uber_weekly.uber_week_balance IS 'Weekly net balance: (uber_total_earnings - uber_cash_collection + uber_toll - uber_driver_sub_charge + uber_vehicle_incentive).';

CREATE INDEX IF NOT EXISTS idx_core_uber_weekly_week ON public.core_uber_weekly (settlement_year, settlement_week);
CREATE INDEX IF NOT EXISTS idx_core_uber_weekly_week_id ON public.core_uber_weekly (week_id);
CREATE INDEX IF NOT EXISTS idx_core_uber_weekly_veh ON public.core_uber_weekly (vehicle_number);
CREATE INDEX IF NOT EXISTS idx_core_uber_weekly_vendor ON public.core_uber_weekly (vendor_code);

-- 3. Required Performance Indexes on Raw Pipeline Tables (Created CONCURRENTLY)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_uber_trips_req_time 
    ON public.uber_pipeline_trips (trip_request_time);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_uber_trips_op_date 
    ON public.uber_pipeline_trips (((trip_request_time - INTERVAL '4 hours')::date), driver_uuid, car_no);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_uber_txns_rep_time 
    ON public.uber_pipeline_order_transactions (reporting_time);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_uber_txns_op_date 
    ON public.uber_pipeline_order_transactions (((reporting_time + INTERVAL '1 hour 30 minutes')::date), driver_uuid);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_uber_txns_coalesce_op_date 
    ON public.uber_pipeline_order_transactions (COALESCE(((reporting_time + INTERVAL '1 hour 30 minutes')::date), trx_date), driver_uuid);

-- ============================================================================
-- 4. Asynchronous Stored Procedure (Scheduled via pg_cron, Zero Triggers on Raw)
-- ============================================================================

CREATE OR REPLACE PROCEDURE public.sp_sync_core_uber(
    IN p_start_date DATE DEFAULT NULL,
    IN p_end_date DATE DEFAULT NULL,
    IN p_lookback_days INT DEFAULT 7
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_date DATE;
    v_end_date DATE;
    v_weekly_start DATE;
    v_weekly_end DATE;
    v_daily_count INT := 0;
    v_weekly_count INT := 0;
BEGIN
    -- Determine target processing date range for core_uber_daily and core_uber_weekly
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        v_start_date := p_start_date;
        v_end_date := p_end_date;
        -- Explicit date range: weekly window aggregates full ISO weeks covering the entire range
        v_weekly_start := DATE_TRUNC('week', v_start_date)::date;
        v_weekly_end := (DATE_TRUNC('week', v_end_date) + INTERVAL '6 days')::date;
    ELSIF p_lookback_days IS NOT NULL THEN
        v_start_date := CURRENT_DATE - (p_lookback_days || ' days')::INTERVAL;
        v_end_date := CURRENT_DATE;
        -- Lookback window: weekly aggregates full ISO weeks covering at least current week and previous 2 complete ISO weeks
        v_weekly_start := LEAST(
            DATE_TRUNC('week', v_start_date)::date,
            (DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '14 days')::date
        );
        v_weekly_end := (DATE_TRUNC('week', v_end_date) + INTERVAL '6 days')::date;
    ELSE
        v_start_date := CURRENT_DATE - INTERVAL '7 days';
        v_end_date := CURRENT_DATE;
        v_weekly_start := (DATE_TRUNC('week', CURRENT_DATE) - INTERVAL '14 days')::date;
        v_weekly_end := (DATE_TRUNC('week', v_end_date) + INTERVAL '6 days')::date;
    END IF;

    RAISE NOTICE '[sp_sync_core_uber] Daily window: [% to %], Weekly ISO window: [% to %]',
        v_start_date, v_end_date, v_weekly_start, v_weekly_end;

    -- ========================================================================
    -- 1. SYNC CORE_UBER_DAILY
    -- ========================================================================
    WITH driver_daily_veh AS (
        SELECT DISTINCT ON (driver_uuid, ((trip_request_time - INTERVAL '4 hours')::date))
            driver_uuid,
            ((trip_request_time - INTERVAL '4 hours')::date) AS op_date,
            UPPER(REPLACE(car_no, ' ', '')) AS veh_no
        FROM public.uber_pipeline_trips
        WHERE car_no IS NOT NULL AND TRIM(car_no) <> ''
          AND ((trip_request_time - INTERVAL '4 hours')::date) BETWEEN v_start_date AND v_end_date
        ORDER BY driver_uuid, ((trip_request_time - INTERVAL '4 hours')::date), trip_request_time DESC
    ),
    driver_week_veh AS (
        SELECT DISTINCT ON (driver_uuid, DATE_TRUNC('week', (trip_request_time - INTERVAL '4 hours')::date)::date)
            driver_uuid,
            DATE_TRUNC('week', (trip_request_time - INTERVAL '4 hours')::date)::date AS week_start,
            UPPER(REPLACE(car_no, ' ', '')) AS veh_no
        FROM public.uber_pipeline_trips
        WHERE car_no IS NOT NULL AND TRIM(car_no) <> ''
          AND ((trip_request_time - INTERVAL '4 hours')::date) BETWEEN (v_start_date - INTERVAL '7 days') AND (v_end_date + INTERVAL '7 days')
        ORDER BY driver_uuid, DATE_TRUNC('week', (trip_request_time - INTERVAL '4 hours')::date)::date, trip_request_time DESC
    ),
    trips_agg AS (
        SELECT 
            ((t.trip_request_time - INTERVAL '4 hours')::date) AS op_date,
            UPPER(REPLACE(t.car_no, ' ', '')) AS veh_no,
            t.driver_uuid,
            COUNT(*) FILTER (WHERE LOWER(t.trip_status) = 'completed') AS trips,
            COALESCE(SUM(t.trip_distance), 0.0) AS dist_km
        FROM public.uber_pipeline_trips t
        WHERE ((t.trip_request_time - INTERVAL '4 hours')::date) BETWEEN v_start_date AND v_end_date
          AND t.car_no IS NOT NULL AND TRIM(t.car_no) <> ''
        GROUP BY 1, 2, 3
    ),
    txns_raw AS (
        SELECT 
            ot.id,
            -- Fixed operational date: trip operational date for trip-linked transactions;
            -- UTC reporting_time converted to IST (+5h30m - 4h = +1h30m) for non-trip transactions.
            COALESCE(
                ((t.trip_request_time - INTERVAL '4 hours')::date),
                ((ot.reporting_time + INTERVAL '1 hour 30 minutes')::date),
                ot.trx_date
            ) AS op_date,
            COALESCE(
                NULLIF(UPPER(REPLACE(ot.vehicle_number, ' ', '')), ''),
                NULLIF(UPPER(REPLACE(t.car_no, ' ', '')), ''),
                (regexp_match(ot.description, '([A-Z]{2}[0-9]{1,2}[A-Z]{1,2}[0-9]{4})'))[1]
            ) AS raw_veh_no,
            COALESCE(ot.driver_uuid, t.driver_uuid) AS driver_uuid,
            ot.description,
            COALESCE(ot.actual_earnings, 0.0) AS actual_earnings,
            COALESCE(ot.paid_to_you, 0.0) AS paid_to_you,
            COALESCE(ot.cash_collected, 0.0) AS cash_collected,
            COALESCE(ot.refunds_toll, 0.0) AS refunds_toll
        FROM public.uber_pipeline_order_transactions ot
        LEFT JOIN public.uber_pipeline_trips t ON ot.trip_uuid = t.trip_uuid
        WHERE COALESCE(
            ((t.trip_request_time - INTERVAL '4 hours')::date),
            ((ot.reporting_time + INTERVAL '1 hour 30 minutes')::date),
            ot.trx_date
        ) BETWEEN v_start_date AND v_end_date
    ),
    txns_agg AS (
        SELECT 
            r.op_date,
            COALESCE(
                r.raw_veh_no,
                ddv.veh_no,
                dwv.veh_no
            ) AS veh_no,
            r.driver_uuid,
            -- Net Fare Earnings: exclude promotions, milestone incentives, and platform fees (which are accounted in sub_fee)
            SUM(CASE 
                WHEN r.description NOT ILIKE '%promotion%' 
                 AND r.description NOT ILIKE '%incentive%'
                 AND NOT (r.paid_to_you < 0 AND (r.description ILIKE '%subscription%' OR r.description ILIKE '%platform fee%' OR r.description ILIKE '%Drive Pass%' OR r.description ILIKE '%ड्राइव%'))
                THEN r.actual_earnings 
                ELSE 0.0 
            END) AS earnings,
            SUM(ABS(r.cash_collected)) AS cash,
            SUM(r.refunds_toll) AS toll,
            SUM(CASE 
                WHEN r.paid_to_you < 0 AND (r.description ILIKE '%subscription%' OR r.description ILIKE '%platform fee%' OR r.description ILIKE '%Drive Pass%' OR r.description ILIKE '%ड्राइव%') 
                THEN ABS(r.paid_to_you) 
                ELSE 0.0 
            END) AS sub_fee
        FROM txns_raw r
        LEFT JOIN driver_daily_veh ddv 
          ON r.driver_uuid = ddv.driver_uuid 
         AND r.op_date = ddv.op_date
        LEFT JOIN driver_week_veh dwv 
          ON r.driver_uuid = dwv.driver_uuid 
         AND DATE_TRUNC('week', r.op_date)::date = dwv.week_start
        GROUP BY 1, 2, 3
    ),
    combined AS (
        SELECT 
            COALESCE(t.op_date, x.op_date) AS operational_date,
            COALESCE(t.veh_no, x.veh_no) AS vehicle_number,
            COALESCE(t.driver_uuid, x.driver_uuid) AS driver_uuid,
            COALESCE(t.trips, 0) AS completed_trips,
            COALESCE(t.dist_km, 0.0) AS total_trip_distance_km,
            COALESCE(x.earnings, 0.0) AS net_fare_earnings,
            ABS(COALESCE(x.cash, 0.0)) AS cash_collected,
            COALESCE(x.toll, 0.0) AS tolls_refunded,
            COALESCE(x.sub_fee, 0.0) AS driver_subscription_charge,
            (COALESCE(x.earnings, 0.0) - ABS(COALESCE(x.cash, 0.0)) + COALESCE(x.toll, 0.0) - COALESCE(x.sub_fee, 0.0)) AS net_driver_day_balance
        FROM trips_agg t
        FULL OUTER JOIN txns_agg x 
          ON t.op_date = x.op_date 
         AND t.veh_no = x.veh_no 
         AND COALESCE(t.driver_uuid, '') = COALESCE(x.driver_uuid, '')
        WHERE COALESCE(t.veh_no, x.veh_no) IS NOT NULL
          AND COALESCE(t.veh_no, x.veh_no) <> ''
    )
    INSERT INTO public.core_uber_daily (
        operational_date, vehicle_number, driver_uuid, vendor_code, city,
        completed_trips, total_trip_distance_km, net_fare_earnings, cash_collected,
        tolls_refunded, driver_subscription_charge, net_driver_day_balance, updated_at
    )
    SELECT 
        c.operational_date,
        c.vehicle_number,
        c.driver_uuid,
        dvs.partner_id AS vendor_code,
        COALESCE(dvs.city, 'Hyderabad') AS city,
        c.completed_trips,
        c.total_trip_distance_km,
        c.net_fare_earnings,
        c.cash_collected,
        c.tolls_refunded,
        c.driver_subscription_charge,
        c.net_driver_day_balance,
        NOW()
    FROM combined c
    LEFT JOIN public.core_daily_vehicle_status dvs 
      ON c.vehicle_number = dvs.vehicle_number AND c.operational_date = dvs.status_date
    ON CONFLICT (operational_date, vehicle_number, driver_uuid) DO UPDATE SET
        vendor_code = EXCLUDED.vendor_code,
        city = EXCLUDED.city,
        completed_trips = EXCLUDED.completed_trips,
        total_trip_distance_km = EXCLUDED.total_trip_distance_km,
        net_fare_earnings = EXCLUDED.net_fare_earnings,
        cash_collected = EXCLUDED.cash_collected,
        tolls_refunded = EXCLUDED.tolls_refunded,
        driver_subscription_charge = EXCLUDED.driver_subscription_charge,
        net_driver_day_balance = EXCLUDED.net_driver_day_balance,
        updated_at = NOW();

    GET DIAGNOSTICS v_daily_count = ROW_COUNT;

    -- ========================================================================
    -- 2. SYNC CORE_UBER_WEEKLY
    -- Aggregates full ISO weeks by vehicle to represent full activity,
    -- then resolves primary vendor without discarding any vehicle telemetry.
    -- ========================================================================
    WITH weekly_cal AS (
        SELECT 
            d.operational_date,
            d.vehicle_number,
            d.vendor_code,
            d.city,
            d.completed_trips,
            d.total_trip_distance_km,
            d.net_fare_earnings,
            ABS(d.cash_collected) AS cash_collected,
            d.tolls_refunded,
            d.driver_subscription_charge,
            DATE_TRUNC('week', d.operational_date)::date AS week_start,
            (DATE_TRUNC('week', d.operational_date) + INTERVAL '6 days')::date AS week_end,
            EXTRACT(ISOYEAR FROM d.operational_date)::int AS settlement_year,
            EXTRACT(WEEK FROM d.operational_date)::int AS settlement_week,
            'CY' || SUBSTRING(EXTRACT(ISOYEAR FROM d.operational_date)::text FROM 3 FOR 2) || 'WK' || LPAD(EXTRACT(WEEK FROM d.operational_date)::text, 2, '0') AS week_id
        FROM public.core_uber_daily d
        WHERE d.operational_date BETWEEN v_weekly_start AND v_weekly_end
    ),
    veh_weekly_agg AS (
        SELECT 
            settlement_year,
            settlement_week,
            week_id,
            week_start,
            week_end,
            vehicle_number,
            COUNT(DISTINCT operational_date) FILTER (WHERE completed_trips > 0) AS active_days,
            SUM(completed_trips) AS completed_trips,
            SUM(total_trip_distance_km) AS total_trip_km,
            SUM(net_fare_earnings) AS uber_total_earnings,
            SUM(cash_collected) AS uber_cash_collection,
            SUM(tolls_refunded) AS uber_toll,
            SUM(driver_subscription_charge) AS uber_driver_sub_charge
        FROM weekly_cal
        GROUP BY settlement_year, settlement_week, week_id, week_start, week_end, vehicle_number
    ),
    primary_vendor AS (
        SELECT DISTINCT ON (settlement_year, settlement_week, vehicle_number)
            settlement_year,
            settlement_week,
            vehicle_number,
            vendor_code,
            city
        FROM (
            SELECT 
                settlement_year,
                settlement_week,
                vehicle_number,
                vendor_code,
                city,
                SUM(completed_trips) AS vendor_trips,
                COUNT(DISTINCT operational_date) AS vendor_days,
                MAX(operational_date) AS max_op_date
            FROM weekly_cal
            WHERE vendor_code IS NOT NULL AND TRIM(vendor_code) <> '' AND vendor_code <> 'UNASSIGNED'
            GROUP BY settlement_year, settlement_week, vehicle_number, vendor_code, city
            
            UNION ALL
            
            SELECT 
                settlement_year,
                settlement_week,
                vehicle_number,
                'UNASSIGNED' AS vendor_code,
                MAX(city) AS city,
                -1 AS vendor_trips,
                -1 AS vendor_days,
                '1970-01-01'::date AS max_op_date
            FROM weekly_cal
            GROUP BY settlement_year, settlement_week, vehicle_number
        ) sub
        ORDER BY settlement_year, settlement_week, vehicle_number, vendor_trips DESC, vendor_days DESC, max_op_date DESC
    ),
    raw_inc_agg AS (
        SELECT 
            UPPER(REPLACE(number_plate, ' ', '')) AS veh_no,
            start_date::date AS week_start,
            SUM(total_payout) AS total_payout
        FROM public.uber_vehicle_incentives_raw
        WHERE number_plate IS NOT NULL AND TRIM(number_plate) <> '' AND number_plate <> 'nan'
          AND start_date::date BETWEEN v_weekly_start AND v_weekly_end
        GROUP BY 1, 2
    )
    INSERT INTO public.core_uber_weekly (
        settlement_year, settlement_week, week_id, week_start, week_end, vehicle_number,
        vendor_code, city, active_days, completed_trips, total_trip_km, uber_total_earnings,
        uber_cash_collection, uber_toll, uber_driver_sub_charge, uber_vehicle_incentive,
        uber_pass_on_incentive, uber_letzryd_incentive, uber_week_balance, updated_at
    )
    SELECT 
        v.settlement_year,
        v.settlement_week,
        v.week_id,
        v.week_start,
        v.week_end,
        v.vehicle_number,
        COALESCE(
            NULLIF(pv.vendor_code, 'UNASSIGNED'),
            (SELECT partner_id 
             FROM public.core_daily_vehicle_status dvs 
             WHERE dvs.vehicle_number = v.vehicle_number 
               AND dvs.status_date BETWEEN v.week_start AND v.week_end
               AND dvs.partner_id IS NOT NULL AND TRIM(dvs.partner_id) <> ''
             GROUP BY partner_id 
             ORDER BY COUNT(*) DESC, MAX(status_date) DESC LIMIT 1),
            (SELECT partner_id
             FROM public.daily_rent_log drl
             WHERE drl.vehicle_number = v.vehicle_number
               AND drl.log_date BETWEEN v.week_start AND v.week_end
               AND drl.partner_id IS NOT NULL AND TRIM(drl.partner_id) <> ''
             GROUP BY partner_id
             ORDER BY COUNT(*) DESC, MAX(log_date) DESC LIMIT 1),
            'UNASSIGNED'
        ) AS vendor_code,
        COALESCE(pv.city, 'Hyderabad') AS city,
        v.active_days,
        v.completed_trips,
        v.total_trip_km,
        v.uber_total_earnings,
        v.uber_cash_collection,
        v.uber_toll,
        v.uber_driver_sub_charge,
        COALESCE(inc.total_payout, 0.00) AS uber_vehicle_incentive,
        0.00 AS uber_pass_on_incentive,
        COALESCE(inc.total_payout, 0.00) AS uber_letzryd_incentive,
        (v.uber_total_earnings - v.uber_cash_collection + v.uber_toll - v.uber_driver_sub_charge + COALESCE(inc.total_payout, 0.00)) AS uber_week_balance,
        NOW()
    FROM veh_weekly_agg v
    LEFT JOIN primary_vendor pv 
      ON v.settlement_year = pv.settlement_year 
     AND v.settlement_week = pv.settlement_week 
     AND v.vehicle_number = pv.vehicle_number
    LEFT JOIN raw_inc_agg inc 
      ON v.vehicle_number = inc.veh_no AND inc.week_start = v.week_start
    ON CONFLICT (settlement_year, settlement_week, vehicle_number) DO UPDATE SET
        week_id = EXCLUDED.week_id,
        week_start = EXCLUDED.week_start,
        week_end = EXCLUDED.week_end,
        vendor_code = EXCLUDED.vendor_code,
        city = EXCLUDED.city,
        active_days = EXCLUDED.active_days,
        completed_trips = EXCLUDED.completed_trips,
        total_trip_km = EXCLUDED.total_trip_km,
        uber_total_earnings = EXCLUDED.uber_total_earnings,
        uber_cash_collection = EXCLUDED.uber_cash_collection,
        uber_toll = EXCLUDED.uber_toll,
        uber_driver_sub_charge = EXCLUDED.uber_driver_sub_charge,
        uber_vehicle_incentive = EXCLUDED.uber_vehicle_incentive,
        uber_pass_on_incentive = EXCLUDED.uber_pass_on_incentive,
        uber_letzryd_incentive = EXCLUDED.uber_letzryd_incentive,
        uber_week_balance = EXCLUDED.uber_week_balance,
        updated_at = NOW();

    GET DIAGNOSTICS v_weekly_count = ROW_COUNT;
    RAISE NOTICE '[sp_sync_core_uber] Completed: % daily rows, % weekly rows synced.', v_daily_count, v_weekly_count;
END;
$$;

-- ============================================================================
-- 5. Native pg_cron Job Registration
-- ============================================================================
-- Staggered at minute 5 and 35 to prevent lock and pool contention:
-- SELECT cron.schedule(
--     'sync-core-uber',
--     '5,35 * * * *',
--     'CALL public.sp_sync_core_uber(NULL, NULL, 7);'
-- );
