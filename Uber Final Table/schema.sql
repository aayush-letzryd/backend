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

-- ============================================================================
-- 3. Native Real-Time PostgreSQL Trigger (No External Scheduler Needed)
-- Automatically refreshes core_uber_daily and core_uber_weekly on batch insert
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_sync_core_uber()
RETURNS TRIGGER AS $$
BEGIN
    -- Refresh core_uber_daily for active 30-day window
    WITH driver_daily_veh AS (
        SELECT DISTINCT ON (driver_uuid, trip_date)
            driver_uuid,
            trip_date,
            UPPER(REPLACE(car_no, ' ', '')) AS veh_no
        FROM uber_pipeline_trips
        WHERE car_no IS NOT NULL AND TRIM(car_no) <> ''
          AND trip_date >= (CURRENT_DATE - INTERVAL '30 days')
        ORDER BY driver_uuid, trip_date, trip_request_time DESC
    ),
    driver_week_veh AS (
        SELECT DISTINCT ON (driver_uuid, date_trunc('week', trip_date))
            driver_uuid,
            date_trunc('week', trip_date) AS week_start,
            UPPER(REPLACE(car_no, ' ', '')) AS veh_no
        FROM uber_pipeline_trips
        WHERE car_no IS NOT NULL AND TRIM(car_no) <> ''
          AND trip_date >= (CURRENT_DATE - INTERVAL '30 days')
        ORDER BY driver_uuid, date_trunc('week', trip_date), trip_request_time DESC
    ),
    trips_agg AS (
        SELECT 
            COALESCE(trip_date, trip_request_time::date) AS op_date,
            UPPER(REPLACE(car_no, ' ', '')) AS veh_no,
            driver_uuid,
            COUNT(*) FILTER (WHERE LOWER(trip_status) = 'completed' OR trip_status IS NULL) AS trips,
            COALESCE(SUM(trip_distance), 0) AS dist_km
        FROM uber_pipeline_trips
        WHERE car_no IS NOT NULL AND TRIM(car_no) <> ''
          AND COALESCE(trip_date, trip_request_time::date) >= (CURRENT_DATE - INTERVAL '30 days')
        GROUP BY 1, 2, 3
    ),
    txns_agg AS (
        SELECT 
            COALESCE(t.trip_date, t.trip_request_time::date, ot.trx_date, ot.reporting_time::date) AS op_date,
            COALESCE(
                ot.vehicle_number,
                UPPER(REPLACE(t.car_no, ' ', '')),
                (regexp_match(ot.description, '([A-Z]{2}[0-9]{1,2}[A-Z]{1,2}[0-9]{4})'))[1],
                ddv.veh_no,
                dwv.veh_no
            ) AS veh_no,
            ot.driver_uuid,
            COALESCE(SUM(CASE WHEN ot.description NOT ILIKE '%promotion%' AND ot.description NOT ILIKE '%incentive%' THEN ot.actual_earnings ELSE 0 END), 0) AS earnings,
            COALESCE(SUM(ABS(ot.cash_collected)), 0) AS cash,
            COALESCE(SUM(ot.refunds_toll), 0) AS toll,
            COALESCE(ABS(SUM(CASE WHEN ot.paid_to_you < 0 AND (ot.description ILIKE '%subscription%' OR ot.description ILIKE '%platform fee%' OR ot.description ILIKE '%Drive Pass%' OR ot.description ILIKE '%ड्राइव%') THEN ot.paid_to_you ELSE 0 END)), 0) AS sub_fee
        FROM uber_pipeline_order_transactions ot
        LEFT JOIN uber_pipeline_trips t ON ot.trip_uuid = t.trip_uuid
        LEFT JOIN driver_daily_veh ddv 
          ON ot.driver_uuid = ddv.driver_uuid 
         AND COALESCE(ot.trx_date, ot.reporting_time::date) = ddv.trip_date
        LEFT JOIN driver_week_veh dwv 
          ON ot.driver_uuid = dwv.driver_uuid 
         AND date_trunc('week', COALESCE(ot.trx_date, ot.reporting_time::date)) = dwv.week_start
        WHERE (ot.trx_date >= (CURRENT_DATE - INTERVAL '30 days') OR ot.reporting_time >= (CURRENT_DATE - INTERVAL '30 days') OR t.trip_date >= (CURRENT_DATE - INTERVAL '30 days'))
        GROUP BY 1, 2, 3
    ),
    combined AS (
        SELECT 
            COALESCE(t.op_date, x.op_date) AS operational_date,
            COALESCE(t.veh_no, x.veh_no) AS vehicle_number,
            COALESCE(t.driver_uuid, x.driver_uuid) AS driver_uuid,
            COALESCE(t.trips, 0) AS completed_trips,
            COALESCE(t.dist_km, 0) AS total_trip_distance_km,
            COALESCE(x.earnings, 0) AS net_fare_earnings,
            COALESCE(x.cash, 0) AS cash_collected,
            COALESCE(x.toll, 0) AS tolls_refunded,
            COALESCE(x.sub_fee, 0) AS driver_subscription_charge,
            (COALESCE(x.earnings, 0) - COALESCE(x.cash, 0) + COALESCE(x.toll, 0) - COALESCE(x.sub_fee, 0)) AS net_driver_day_balance
        FROM trips_agg t
        FULL OUTER JOIN txns_agg x 
          ON t.op_date = x.op_date 
         AND t.veh_no = x.veh_no 
         AND COALESCE(t.driver_uuid, '') = COALESCE(x.driver_uuid, '')
        WHERE COALESCE(t.veh_no, x.veh_no) IS NOT NULL
    )
    INSERT INTO core_uber_daily (
        operational_date, vehicle_number, driver_uuid, vendor_code, city,
        completed_trips, total_trip_distance_km, net_fare_earnings, cash_collected,
        tolls_refunded, driver_subscription_charge, net_driver_day_balance
    )
    SELECT 
        c.operational_date, c.vehicle_number, c.driver_uuid, dvs.partner_id AS vendor_code,
        COALESCE(dvs.city, 'Hyderabad') AS city, c.completed_trips, c.total_trip_distance_km,
        c.net_fare_earnings, c.cash_collected, c.tolls_refunded, c.driver_subscription_charge,
        c.net_driver_day_balance
    FROM combined c
    LEFT JOIN core_daily_vehicle_status dvs 
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

    -- Refresh core_uber_weekly for active 30-day window
    WITH weekly_cal AS (
        SELECT 
            d.operational_date, d.vehicle_number, d.vendor_code, d.city,
            d.completed_trips, d.total_trip_distance_km, d.net_fare_earnings,
            d.cash_collected, d.tolls_refunded, d.driver_subscription_charge,
            DATE_TRUNC('week', d.operational_date)::date AS week_start,
            (DATE_TRUNC('week', d.operational_date) + INTERVAL '6 days')::date AS week_end,
            EXTRACT(ISOYEAR FROM d.operational_date)::int AS settlement_year,
            EXTRACT(WEEK FROM d.operational_date)::int AS settlement_week,
            'CY' || SUBSTRING(EXTRACT(ISOYEAR FROM d.operational_date)::text FROM 3 FOR 2) || 'WK' || LPAD(EXTRACT(WEEK FROM d.operational_date)::text, 2, '0') AS week_id
        FROM core_uber_daily d
        WHERE d.operational_date >= (CURRENT_DATE - INTERVAL '30 days')
    ),
    weekly_agg AS (
        SELECT 
            settlement_year, settlement_week, week_id, week_start, week_end, vehicle_number,
            COALESCE(vendor_code, 'UNASSIGNED') AS vendor_code, MAX(city) AS city,
            COUNT(DISTINCT operational_date) FILTER (WHERE completed_trips > 0) AS active_days,
            SUM(completed_trips) AS completed_trips, SUM(total_trip_distance_km) AS total_trip_km,
            SUM(net_fare_earnings) AS uber_total_earnings, SUM(cash_collected) AS uber_cash_collection,
            SUM(tolls_refunded) AS uber_toll, SUM(driver_subscription_charge) AS uber_driver_sub_charge
        FROM weekly_cal
        GROUP BY settlement_year, settlement_week, week_id, week_start, week_end, vehicle_number, COALESCE(vendor_code, 'UNASSIGNED')
    ),
    raw_inc_agg AS (
        SELECT 
            UPPER(REPLACE(number_plate, ' ', '')) AS veh_no,
            start_date::date AS week_start,
            SUM(total_payout) AS total_payout
        FROM uber_vehicle_incentives_raw
        WHERE number_plate IS NOT NULL AND TRIM(number_plate) <> '' AND number_plate <> 'nan'
          AND start_date::date >= (CURRENT_DATE - INTERVAL '30 days')
        GROUP BY 1, 2
    )
    INSERT INTO core_uber_weekly (
        settlement_year, settlement_week, week_id, week_start, week_end, vehicle_number,
        vendor_code, city, active_days, completed_trips, total_trip_km, uber_total_earnings,
        uber_cash_collection, uber_toll, uber_driver_sub_charge, uber_vehicle_incentive,
        uber_pass_on_incentive, uber_letzryd_incentive, uber_week_balance
    )
    SELECT 
        w.settlement_year, w.settlement_week, w.week_id, w.week_start, w.week_end, w.vehicle_number,
        w.vendor_code, w.city, w.active_days, w.completed_trips, w.total_trip_km,
        w.uber_total_earnings, w.uber_cash_collection, w.uber_toll, w.uber_driver_sub_charge,
        COALESCE(inc.total_payout, 0.00) AS uber_vehicle_incentive, 0.00 AS uber_pass_on_incentive,
        COALESCE(inc.total_payout, 0.00) AS uber_letzryd_incentive,
        (w.uber_total_earnings - w.uber_cash_collection + w.uber_toll - w.uber_driver_sub_charge + COALESCE(inc.total_payout, 0.00)) AS uber_week_balance
    FROM weekly_agg w
    LEFT JOIN raw_inc_agg inc 
      ON w.vehicle_number = inc.veh_no AND inc.week_start = w.week_start
    ON CONFLICT (settlement_year, settlement_week, vehicle_number, vendor_code) DO UPDATE SET
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

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Statement-level Trigger on uber_pipeline_trips
DROP TRIGGER IF EXISTS trg_sync_core_uber ON uber_pipeline_trips;
CREATE TRIGGER trg_sync_core_uber
AFTER INSERT OR UPDATE ON uber_pipeline_trips
FOR EACH STATEMENT
EXECUTE FUNCTION fn_sync_core_uber();
