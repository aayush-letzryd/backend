-- ============================================================================
-- HISAAB INTERNAL AUTOMATION ENGINE & REAL-TIME TRIGGER ARCHITECTURE
-- Database: PostgreSQL 14+
-- Module: LetzRyd Hisaab Engine (Daily Shift -> Vehicle Weekly -> Partner Payout)
-- File: backend/Hisaab Final Table/triggers.sql
-- Synchronized with live verified PostgreSQL engine
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Definition: fn_ensure_hisaab_week
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ensure_hisaab_week(p_week_id character varying DEFAULT NULL::character varying, p_log_date date DEFAULT NULL::date)
 RETURNS character varying
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_week_id VARCHAR;
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_cutoff TIMESTAMPTZ;
BEGIN
    -- If week already exists, return immediately
    IF p_week_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.hisaab_settlement_weeks WHERE week_id = p_week_id) THEN
        RETURN p_week_id;
    END IF;

    IF p_log_date IS NOT NULL THEN
        v_week_start := date_trunc('week', p_log_date)::DATE;
        v_week_end := (v_week_start + INTERVAL '6 days')::DATE;
        v_year := EXTRACT(isoyear FROM p_log_date)::INT;
        v_week_num := EXTRACT(week FROM p_log_date)::INT;
        IF p_week_id IS NOT NULL THEN
            v_week_id := p_week_id;
        ELSE
            v_week_id := 'CY' || to_char(p_log_date, 'IY') || 'WK' || to_char(p_log_date, 'IW');
        END IF;
    ELSIF p_week_id IS NOT NULL THEN
        v_week_id := p_week_id;
        IF p_week_id ~* '^CY[0-9]{2}WK[0-9]{1,2}$' THEN
            v_year := 2000 + substring(p_week_id FROM 'CY([0-9]{2})')::INT;
            v_week_num := substring(p_week_id FROM 'WK([0-9]{1,2})')::INT;
        ELSIF p_week_id ~* '^[0-9]{4}-W[0-9]{1,2}$' THEN
            v_year := substring(p_week_id FROM '([0-9]{4})')::INT;
            v_week_num := substring(p_week_id FROM 'W([0-9]{1,2})')::INT;
        ELSE
            v_year := EXTRACT(isoyear FROM CURRENT_DATE)::INT;
            v_week_num := EXTRACT(week FROM CURRENT_DATE)::INT;
        END IF;
        v_week_start := to_date(v_year || '-' || v_week_num || '-1', 'IYYY-IW-ID');
        v_week_end := (v_week_start + INTERVAL '6 days')::DATE;
    ELSE
        RETURN NULL;
    END IF;

    -- Cutoff is Monday 11:00 AM IST after Sunday week_end
    v_cutoff := ((v_week_end + 1) || ' 11:00:00+05:30')::TIMESTAMPTZ;

    INSERT INTO public.hisaab_settlement_weeks (
        week_id, settlement_year, settlement_week, week_start, week_end, lock_cutoff_at, is_locked
    ) VALUES (
        v_week_id, v_year, v_week_num, v_week_start, v_week_end, v_cutoff, FALSE
    ) ON CONFLICT (week_id) DO NOTHING;

    RETURN v_week_id;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_sync_hisaab_daily_upsert
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_hisaab_daily_upsert(p_log_date date, p_vehicle character varying, p_partner character varying DEFAULT NULL::character varying)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_week_id VARCHAR(16);
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_is_locked BOOLEAN;
    v_lock_cutoff TIMESTAMPTZ;

    v_target_partner VARCHAR(64);
    v_partner_type VARCHAR(32);
    v_city VARCHAR(64);
    v_model VARCHAR(64);
    v_attendance VARCHAR(32);
    v_is_billable_day BOOLEAN;
    v_daily_rent_applied NUMERIC(12,2);
    v_daily_indemnity_fee NUMERIC(12,2);
    v_net_daily_rent NUMERIC(12,2);

    v_uber_trips INT := 0;
    v_uber_fare_earnings NUMERIC(12,2) := 0.00;
    v_uber_cash_collected NUMERIC(12,2) := 0.00;
    v_uber_tolls NUMERIC(12,2) := 0.00;
    v_uber_subscription_charge NUMERIC(12,2) := 0.00;

    v_ola_trips INT := 0;
    v_ola_net_revenue NUMERIC(12,2) := 0.00;
    v_ola_cash_collected NUMERIC(12,2) := 0.00;
    v_ola_tolls NUMERIC(12,2) := 0.00;
    v_ola_online_payment NUMERIC(12,2) := 0.00;

    v_rapido_trips INT := 0;
    v_rapido_net_revenue NUMERIC(12,2) := 0.00;
    v_rapido_cash_collected NUMERIC(12,2) := 0.00;

    v_daily_adjustments NUMERIC(12,2) := 0.00;
    v_daily_challans NUMERIC(12,2) := 0.00;
    v_daily_accident_recovery NUMERIC(12,2) := 0.00;
    v_weekly_incentive_credit NUMERIC(12,2) := 0.00;
    v_daily_net_balance NUMERIC(12,2) := 0.00;

    v_existing_id BIGINT;
    v_existing_locked BOOLEAN;
    v_sec_driver_exists BOOLEAN;
BEGIN
    IF p_log_date IS NULL OR p_vehicle IS NULL THEN
        RETURN;
    END IF;

    -- 1. Ensure settlement week exists and check lock state
    v_week_id := public.fn_ensure_hisaab_week(NULL, p_log_date);
    SELECT is_locked, lock_cutoff_at, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_lock_cutoff, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = v_week_id;

    IF v_is_locked = TRUE THEN
        RETURN; -- Locked week cannot be updated
    END IF;

    -- 2. Determine target partner
    v_target_partner := p_partner;
    IF v_target_partner IS NULL THEN
        SELECT partner_id INTO v_target_partner
        FROM public.daily_rent_log
        WHERE log_date = p_log_date AND vehicle_number = p_vehicle
        LIMIT 1;

        IF v_target_partner IS NULL THEN
            SELECT vendor_code INTO v_target_partner
            FROM public.core_uber_daily
            WHERE operational_date = p_log_date AND vehicle_number = p_vehicle AND vendor_code IS NOT NULL
            LIMIT 1;
        END IF;

        IF v_target_partner IS NULL THEN
            SELECT partner_id INTO v_target_partner
            FROM public.core_rent
            WHERE vehicle_number = p_vehicle
            ORDER BY is_active DESC NULLS LAST, id DESC
            LIMIT 1;
        END IF;

        IF v_target_partner IS NULL THEN
            v_target_partner := 'UNKNOWN';
        END IF;
    END IF;

    -- 3. Resolve Partner Type, City, Vehicle Model, and Attendance from daily_rent_log
    v_partner_type := CASE WHEN v_target_partner ILIKE '%IP%' OR v_target_partner ILIKE '%OP%' THEN 'Operator' ELSE 'Individual' END;

    SELECT 
        COALESCE(city, 'HYD'),
        vehicle_model,
        attendance_status,
        is_billable_day,
        applied_daily_rent,
        applied_daily_indemnity,
        net_daily_rent
    INTO 
        v_city,
        v_model,
        v_attendance,
        v_is_billable_day,
        v_daily_rent_applied,
        v_daily_indemnity_fee,
        v_net_daily_rent
    FROM public.daily_rent_log
    WHERE log_date = p_log_date AND vehicle_number = p_vehicle AND partner_id = v_target_partner
    LIMIT 1;

    -- Fallbacks if daily_rent_log doesn't match
    IF v_partner_type IS NULL THEN
        IF v_target_partner ILIKE '%IP%' OR v_target_partner ILIKE '%OP%' THEN
            v_partner_type := 'Operator';
        ELSE
            v_partner_type := 'Individual';
        END IF;
    END IF;

    IF v_city IS NULL THEN
        SELECT city INTO v_city FROM public.core_rent WHERE vehicle_number = p_vehicle LIMIT 1;
        IF v_city IS NULL THEN v_city := 'HYD'; END IF;
    END IF;

    IF v_attendance IS NULL THEN v_attendance := 'Active'; END IF;
    IF v_is_billable_day IS NULL THEN v_is_billable_day := TRUE; END IF;
    IF v_model IS NULL THEN v_model := 'Unknown'; END IF;

    IF v_daily_rent_applied IS NULL THEN
        SELECT custom_daily_rent, custom_daily_indemnity INTO v_daily_rent_applied, v_daily_indemnity_fee
        FROM public.core_rent
        WHERE vehicle_number = p_vehicle
        ORDER BY is_active DESC NULLS LAST, id DESC LIMIT 1;

        IF v_daily_rent_applied IS NULL THEN v_daily_rent_applied := 856.00; END IF;
        IF v_daily_indemnity_fee IS NULL THEN v_daily_indemnity_fee := 0.00; END IF;
        v_net_daily_rent := v_daily_rent_applied + v_daily_indemnity_fee;
    END IF;

    -- Secondary Driver Double-Rent Protection:
    IF v_partner_type = 'Individual' THEN
        SELECT EXISTS (
            SELECT 1 FROM public.daily_rent_log
            WHERE log_date = p_log_date 
              AND vehicle_number = p_vehicle 
              AND partner_id <> v_target_partner
              AND is_billable_day = TRUE 
              AND net_daily_rent > 0
        ) INTO v_sec_driver_exists;

        IF v_sec_driver_exists THEN
            v_daily_rent_applied := 0.00;
            v_daily_indemnity_fee := 0.00;
            v_net_daily_rent := 0.00;
            v_is_billable_day := FALSE;
        END IF;
    END IF;

    -- Operator 7-Day Billing Contract Rule:
    IF v_partner_type = 'Operator' THEN
        IF v_attendance NOT IN ('Maintenance', 'Breakdown', 'Accident') THEN
            v_is_billable_day := TRUE;
            IF v_net_daily_rent <= 0.00 THEN
                v_daily_rent_applied := 856.00;
                v_net_daily_rent := 856.00;
            END IF;
        END IF;
    END IF;

    -- 4. Uber Telemetry (core_uber_daily) with operator multi-driver attribution
    SELECT 
        COALESCE(SUM(completed_trips), 0),
        COALESCE(SUM(net_fare_earnings), 0.00),
        COALESCE(SUM(cash_collected), 0.00),
        COALESCE(SUM(tolls_refunded), 0.00),
        COALESCE(SUM(driver_subscription_charge), 0.00)
    INTO 
        v_uber_trips,
        v_uber_fare_earnings,
        v_uber_cash_collected,
        v_uber_tolls,
        v_uber_subscription_charge
    FROM public.core_uber_daily
    WHERE operational_date = p_log_date AND vehicle_number = p_vehicle;

    -- 5. Ola Telemetry (core_ola_daily) with operator multi-driver attribution
    SELECT 
        COALESCE(SUM(completed_trips), 0),
        COALESCE(SUM(operator_bill), 0.00),
        COALESCE(SUM(cash_collected), 0.00),
        COALESCE(SUM(toll_and_parking), 0.00),
        COALESCE(SUM(online_payouts), 0.00)
    INTO 
        v_ola_trips,
        v_ola_net_revenue,
        v_ola_cash_collected,
        v_ola_tolls,
        v_ola_online_payment
    FROM public.core_ola_daily
    WHERE service_date = p_log_date AND vehicle_number = p_vehicle;

    -- 6. Rapido Telemetry (core_rapido_daily)
    SELECT 
        COALESCE(SUM(completed_trips), 0),
        COALESCE(SUM(net_revenue), 0.00),
        COALESCE(SUM(cash_collected), 0.00)
    INTO 
        v_rapido_trips,
        v_rapido_net_revenue,
        v_rapido_cash_collected
    FROM public.core_rapido_daily
    WHERE operational_date = p_log_date AND vehicle_number = p_vehicle;

    -- OPERATIONAL TRIP OVERRIDE ON LEASE RENT:
    IF (v_net_daily_rent <= 0.00 OR v_is_billable_day = FALSE) AND (v_uber_trips > 0 OR v_ola_trips > 0 OR v_rapido_trips > 0) THEN
        v_is_billable_day := TRUE;
        v_attendance := 'Active (Trip Override)';

        SELECT 
            COALESCE(custom_daily_rent, 856.00),
            COALESCE(custom_daily_indemnity, 0.00)
        INTO v_daily_rent_applied, v_daily_indemnity_fee
        FROM public.core_rent
        WHERE vehicle_number = p_vehicle
        ORDER BY is_active DESC NULLS LAST, id DESC
        LIMIT 1;

        IF v_daily_rent_applied IS NULL OR v_daily_rent_applied <= 0.00 THEN
            v_daily_rent_applied := 856.00;
        END IF;

        v_net_daily_rent := v_daily_rent_applied + COALESCE(v_daily_indemnity_fee, 0.00);
    END IF;

    -- 7. In-Week Adjustments & Challans (Disentangled & Partitioned)
    SELECT 
        COALESCE(SUM(CASE WHEN polarity = 'DEBIT' AND NOT (adjustment_category ILIKE '%accident%' OR adjustment_category ILIKE '%damage%') THEN amount ELSE 0.00 END), 0.00),
        COALESCE(SUM(CASE WHEN polarity = 'DEBIT' AND (adjustment_category ILIKE '%accident%' OR adjustment_category ILIKE '%damage%') THEN amount ELSE 0.00 END), 0.00),
        COALESCE(SUM(CASE WHEN polarity = 'CREDIT' THEN amount ELSE 0.00 END), 0.00)
    INTO 
        v_daily_challans,
        v_daily_accident_recovery,
        v_daily_adjustments
    FROM public.hisaab_adjustments_ledger
    WHERE COALESCE(effective_date, incident_date) = p_log_date 
      AND vehicle_number = p_vehicle 
      AND partner_id = v_target_partner
      AND settlement_week_id = v_week_id
      AND approval_status = 'Approved';

    -- 8. Sunday Milestone Incentives Credit
    IF p_log_date = v_week_end THEN
        SELECT 
            COALESCE(u.uber_inc, 0.00) + COALESCE(o.ola_inc, 0.00)
        INTO v_weekly_incentive_credit
        FROM (SELECT 1) dummy
        LEFT JOIN (
            SELECT SUM(uber_vehicle_incentive) AS uber_inc
            FROM public.core_uber_weekly
            WHERE (week_id = v_week_id OR (settlement_year = v_year AND settlement_week = v_week_num))
              AND vehicle_number = p_vehicle
        ) u ON TRUE
        LEFT JOIN (
            SELECT SUM(ola_portal_incentive) AS ola_inc
            FROM public.core_ola_weekly
            WHERE week_id = v_week_id AND vehicle_number = p_vehicle
        ) o ON TRUE;
    ELSE
        v_weekly_incentive_credit := 0.00;
    END IF;

    -- 9. Daily Net Balance Calculation:
    v_daily_net_balance := 
        COALESCE(v_net_daily_rent, 0.00)
        + (ABS(COALESCE(v_uber_cash_collected, 0.00)) + ABS(COALESCE(v_ola_cash_collected, 0.00)) + ABS(COALESCE(v_rapido_cash_collected, 0.00)))
        - (COALESCE(v_uber_fare_earnings, 0.00) + COALESCE(v_ola_net_revenue, 0.00) + COALESCE(v_rapido_net_revenue, 0.00))
        - COALESCE(v_ola_online_payment, 0.00)
        + COALESCE(v_daily_challans, 0.00)
        + COALESCE(v_daily_accident_recovery, 0.00)
        - COALESCE(v_daily_adjustments, 0.00)
        - COALESCE(v_weekly_incentive_credit, 0.00);

    -- 10. Upsert into hisaab_daily_ledger
    INSERT INTO public.hisaab_daily_ledger (
        log_date,
        week_id,
        vehicle_number,
        partner_id,
        partner_type,
        city,
        vehicle_model,
        attendance_status,
        is_billable_day,
        daily_rent_applied,
        daily_indemnity_fee,
        net_daily_rent,
        uber_trips,
        uber_fare_earnings,
        uber_cash_collected,
        uber_tolls,
        uber_subscription_charge,
        ola_trips,
        ola_net_revenue,
        ola_cash_collected,
        ola_tolls,
        ola_online_payment,
        rapido_trips,
        rapido_net_revenue,
        rapido_cash_collected,
        daily_adjustments,
        daily_challans,
        daily_accident_recovery,
        weekly_incentive_credit,
        daily_net_balance,
        is_locked,
        updated_at
    ) VALUES (
        p_log_date,
        v_week_id,
        p_vehicle,
        v_target_partner,
        v_partner_type,
        v_city,
        v_model,
        v_attendance,
        v_is_billable_day,
        COALESCE(v_daily_rent_applied, 0.00),
        COALESCE(v_daily_indemnity_fee, 0.00),
        COALESCE(v_net_daily_rent, 0.00),
        v_uber_trips,
        v_uber_fare_earnings,
        v_uber_cash_collected,
        v_uber_tolls,
        v_uber_subscription_charge,
        v_ola_trips,
        v_ola_net_revenue,
        v_ola_cash_collected,
        v_ola_tolls,
        v_ola_online_payment,
        v_rapido_trips,
        v_rapido_net_revenue,
        v_rapido_cash_collected,
        COALESCE(v_daily_adjustments, 0.00),
        COALESCE(v_daily_challans, 0.00),
        COALESCE(v_daily_accident_recovery, 0.00),
        COALESCE(v_weekly_incentive_credit, 0.00),
        v_daily_net_balance,
        FALSE,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (log_date, vehicle_number, partner_id) DO UPDATE SET
        partner_type = EXCLUDED.partner_type,
        city = CASE WHEN EXCLUDED.city <> 'Unknown' THEN EXCLUDED.city ELSE public.hisaab_daily_ledger.city END,
        vehicle_model = COALESCE(EXCLUDED.vehicle_model, public.hisaab_daily_ledger.vehicle_model),
        attendance_status = EXCLUDED.attendance_status,
        is_billable_day = EXCLUDED.is_billable_day,
        daily_rent_applied = EXCLUDED.daily_rent_applied,
        daily_indemnity_fee = EXCLUDED.daily_indemnity_fee,
        net_daily_rent = EXCLUDED.net_daily_rent,
        uber_trips = EXCLUDED.uber_trips,
        uber_fare_earnings = EXCLUDED.uber_fare_earnings,
        uber_cash_collected = EXCLUDED.uber_cash_collected,
        uber_tolls = EXCLUDED.uber_tolls,
        uber_subscription_charge = EXCLUDED.uber_subscription_charge,
        ola_trips = EXCLUDED.ola_trips,
        ola_net_revenue = EXCLUDED.ola_net_revenue,
        ola_cash_collected = EXCLUDED.ola_cash_collected,
        ola_tolls = EXCLUDED.ola_tolls,
        ola_online_payment = EXCLUDED.ola_online_payment,
        rapido_trips = EXCLUDED.rapido_trips,
        rapido_net_revenue = EXCLUDED.rapido_net_revenue,
        rapido_cash_collected = EXCLUDED.rapido_cash_collected,
        daily_adjustments = EXCLUDED.daily_adjustments,
        daily_challans = EXCLUDED.daily_challans,
        daily_accident_recovery = EXCLUDED.daily_accident_recovery,
        weekly_incentive_credit = EXCLUDED.weekly_incentive_credit,
        daily_net_balance = EXCLUDED.daily_net_balance,
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_daily_ledger.is_locked = FALSE;

END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: sp_sync_hisaab_vehicle_weekly
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_vehicle_weekly(IN p_week_id character varying, IN p_vehicle character varying DEFAULT NULL::character varying, IN p_partner character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_is_locked BOOLEAN;
BEGIN
    IF p_week_id IS NULL THEN
        RETURN;
    END IF;

    PERFORM public.fn_ensure_hisaab_week(p_week_id, NULL);
    SELECT is_locked, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = p_week_id;

    IF v_is_locked = TRUE THEN
        RETURN;
    END IF;

    WITH daily_agg AS (
        SELECT 
            d.week_id,
            d.vehicle_number,
            d.partner_id,
            MAX(d.partner_type) AS partner_type,
            MAX(d.city) AS city,
            MAX(d.vehicle_model) AS vehicle_model,
            COUNT(*)::INT AS allotted_days,
            SUM(CASE WHEN d.is_billable_day THEN 1 ELSE 0 END)::INT AS onroad_days,
            COALESCE(AVG(d.daily_rent_applied), 0.00) AS daily_rent_applied,
            COALESCE(SUM(d.daily_rent_applied), 0.00) AS weekly_lease_rental,
            COALESCE(SUM(d.daily_indemnity_fee), 0.00) AS weekly_indemnity_fees,
            COALESCE(SUM(d.net_daily_rent), 0.00) AS net_weekly_lease_rental,
            COALESCE(SUM(d.uber_trips), 0)::INT AS uber_trips,
            COALESCE(SUM(d.uber_fare_earnings), 0.00) AS uber_total_earnings,
            COALESCE(SUM(d.uber_cash_collected), 0.00) AS uber_cash_collection,
            COALESCE(SUM(d.uber_tolls), 0.00) AS uber_toll,
            COALESCE(SUM(d.uber_subscription_charge), 0.00) AS uber_driver_sub_charge,
            COALESCE(SUM(d.ola_trips), 0)::INT AS ola_trips,
            COALESCE(SUM(d.ola_net_revenue), 0.00) AS ola_net_revenue,
            COALESCE(SUM(d.ola_cash_collected), 0.00) AS ola_cash_collection,
            COALESCE(SUM(d.ola_tolls), 0.00) AS ola_toll,
            COALESCE(SUM(d.ola_online_payment), 0.00) AS ola_online_payment,
            COALESCE(SUM(d.rapido_trips), 0)::INT AS rapido_trips,
            COALESCE(SUM(d.rapido_net_revenue), 0.00) AS rapido_net_revenue,
            COALESCE(SUM(d.rapido_cash_collected), 0.00) AS rapido_cash_collected,
            COALESCE(SUM(d.weekly_incentive_credit), 0.00) AS weekly_platform_incentive,
            COALESCE(SUM(d.daily_adjustments), 0.00) AS vehicle_adjustments,
            COALESCE(SUM(d.daily_challans), 0.00) AS challan_amount,
            COALESCE(SUM(d.daily_accident_recovery), 0.00) AS accident_penalties,
            MIN(d.log_date) AS partner_min_date,
            MAX(d.log_date) AS partner_max_date
        FROM public.hisaab_daily_ledger d
        WHERE d.week_id = p_week_id
          AND (p_vehicle IS NULL OR d.vehicle_number = p_vehicle)
          AND (p_partner IS NULL OR d.partner_id = p_partner)
        GROUP BY d.week_id, d.vehicle_number, d.partner_id
    )
    INSERT INTO public.hisaab_vehicle_weekly (
        settlement_year,
        settlement_week,
        week_id,
        week_start,
        week_end,
        vehicle_number,
        partner_id,
        partner_name,
        partner_type,
        city,
        vehicle_model,
        rental_plan,
        allotted_days,
        onroad_days,
        daily_rent_applied,
        weekly_lease_rental,
        weekly_indemnity_fees,
        net_weekly_lease_rental,
        uber_trips,
        uber_total_earnings,
        uber_cash_collection,
        uber_toll,
        uber_driver_sub_charge,
        uber_week_os,
        ola_trips,
        ola_net_revenue,
        ola_cash_collection,
        ola_toll,
        ola_gst,
        ola_online_payment,
        ola_week_os,
        rapido_trips,
        rapido_net_revenue,
        rapido_cash_collected,
        weekly_platform_incentive,
        vehicle_adjustments,
        challan_amount,
        accident_penalties,
        total_trip_km,
        total_gps_km,
        ideal_gps_km,
        dead_mile_km,
        dead_mile_pct,
        dead_mile_charges,
        tds_amount,
        current_week_os,
        to_collect,
        to_payout,
        letzryd_earning,
        letzryd_earning_per_day,
        settlement_status,
        updated_at
    )
    SELECT 
        v_year,
        v_week_num,
        p_week_id,
        v_week_start,
        v_week_end,
        d.vehicle_number,
        d.partner_id,
        COALESCE(dr.driver_name, d.partner_id) AS partner_name,
        d.partner_type,
        d.city,
        d.vehicle_model,
        COALESCE(p.plan_scheme, 'Standard') AS rental_plan,
        d.allotted_days,
        d.onroad_days,
        d.daily_rent_applied,
        d.weekly_lease_rental,
        d.weekly_indemnity_fees,
        d.net_weekly_lease_rental,
        d.uber_trips,
        d.uber_total_earnings,
        d.uber_cash_collection,
        d.uber_toll,
        d.uber_driver_sub_charge,
        (d.uber_cash_collection - d.uber_total_earnings + d.uber_driver_sub_charge) AS uber_week_os,
        d.ola_trips,
        d.ola_net_revenue,
        d.ola_cash_collection,
        d.ola_toll,
        0.00 AS ola_gst,
        d.ola_online_payment,
        (d.ola_cash_collection - d.ola_net_revenue - d.ola_online_payment) AS ola_week_os,
        d.rapido_trips,
        d.rapido_net_revenue,
        d.rapido_cash_collected,
        d.weekly_platform_incentive,
        d.vehicle_adjustments,
        d.challan_amount,
        d.accident_penalties,
        
        -- Telematics with Rapido trip km included
        COALESCE(trip_km.in_trip_km, 0.00) AS total_trip_km,
        COALESCE(gps.total_gps_km, 0.00) AS total_gps_km,
        COALESCE(ideal.ideal_gps_km, 0.00) AS ideal_gps_km,
        CASE 
            WHEN d.partner_type = 'Individual' 
                 AND (COALESCE(p.plan_scheme, '') ILIKE '%D2R%' OR COALESCE(p.plan_scheme, '') ILIKE '%TBS%' OR COALESCE(p.plan_scheme, '') ILIKE '%Reducing Rent%')
                 AND d.city <> 'Mumbai' 
                 AND gps.total_gps_km > 0 
            THEN GREATEST(0, gps.total_gps_km - ideal.ideal_gps_km)
            ELSE 0.00
        END AS dead_mile_km,
        CASE 
            WHEN d.partner_type = 'Individual' 
                 AND (COALESCE(p.plan_scheme, '') ILIKE '%D2R%' OR COALESCE(p.plan_scheme, '') ILIKE '%TBS%' OR COALESCE(p.plan_scheme, '') ILIKE '%Reducing Rent%')
                 AND d.city <> 'Mumbai' 
                 AND gps.total_gps_km > 0 
            THEN ROUND(GREATEST(0, gps.total_gps_km - ideal.ideal_gps_km) / NULLIF(gps.total_gps_km, 0) * 100, 2)
            ELSE 0.00
        END AS dead_mile_pct,
        CASE 
            WHEN d.partner_type = 'Individual' 
                 AND (COALESCE(p.plan_scheme, '') ILIKE '%D2R%' OR COALESCE(p.plan_scheme, '') ILIKE '%TBS%' OR COALESCE(p.plan_scheme, '') ILIKE '%Reducing Rent%')
                 AND d.city <> 'Mumbai' 
                 AND gps.total_gps_km > 0 
            THEN ROUND(GREATEST(0, gps.total_gps_km - ideal.ideal_gps_km) * 3.00, 2)
            ELSE 0.00
        END AS dead_mile_charges,
        
        -- TDS Section 194C
        CASE 
            WHEN d.partner_type = 'Operator' THEN 0.00
            WHEN (d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue - d.net_weekly_lease_rental) > 0 
            THEN ROUND((d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
            ELSE 0.00 
        END AS tds_amount,
        
        -- Current Week Outstanding Formula
        (
            d.net_weekly_lease_rental
            + ABS(d.uber_cash_collection) + ABS(d.ola_cash_collection) + ABS(d.rapido_cash_collected)
            - (d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue)
            + d.uber_driver_sub_charge
            - d.ola_online_payment
            - d.weekly_platform_incentive
            - d.vehicle_adjustments
            + d.challan_amount
            + d.accident_penalties
            + (CASE 
                WHEN d.partner_type = 'Individual' 
                     AND (COALESCE(p.plan_scheme, '') ILIKE '%D2R%' OR COALESCE(p.plan_scheme, '') ILIKE '%TBS%' OR COALESCE(p.plan_scheme, '') ILIKE '%Reducing Rent%')
                     AND d.city <> 'Mumbai' 
                     AND gps.total_gps_km > 0 
                THEN ROUND(GREATEST(0, gps.total_gps_km - ideal.ideal_gps_km) * 3.00, 2)
                ELSE 0.00 
               END)
            + (CASE 
                WHEN d.partner_type = 'Operator' THEN 0.00
                WHEN (d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue - d.net_weekly_lease_rental) > 0 
                THEN ROUND((d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
                ELSE 0.00 
               END)
        ) AS current_week_os,
        
        GREATEST(0, (
            d.net_weekly_lease_rental
            + ABS(d.uber_cash_collection) + ABS(d.ola_cash_collection) + ABS(d.rapido_cash_collected)
            - (d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue)
            + d.uber_driver_sub_charge
            - d.ola_online_payment
            - d.weekly_platform_incentive
            - d.vehicle_adjustments
            + d.challan_amount
            + d.accident_penalties
            + (CASE 
                WHEN d.partner_type = 'Individual' 
                     AND (COALESCE(p.plan_scheme, '') ILIKE '%D2R%' OR COALESCE(p.plan_scheme, '') ILIKE '%TBS%' OR COALESCE(p.plan_scheme, '') ILIKE '%Reducing Rent%')
                     AND d.city <> 'Mumbai' 
                     AND gps.total_gps_km > 0 
                THEN ROUND(GREATEST(0, gps.total_gps_km - ideal.ideal_gps_km) * 3.00, 2)
                ELSE 0.00 
               END)
            + (CASE 
                WHEN d.partner_type = 'Operator' THEN 0.00
                WHEN (d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue - d.net_weekly_lease_rental) > 0 
                THEN ROUND((d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
                ELSE 0.00 
               END)
        )) AS to_collect,
        
        ABS(LEAST(0, (
            d.net_weekly_lease_rental
            + ABS(d.uber_cash_collection) + ABS(d.ola_cash_collection) + ABS(d.rapido_cash_collected)
            - (d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue)
            + d.uber_driver_sub_charge
            - d.ola_online_payment
            - d.weekly_platform_incentive
            - d.vehicle_adjustments
            + d.challan_amount
            + d.accident_penalties
            + (CASE 
                WHEN d.partner_type = 'Individual' 
                     AND (COALESCE(p.plan_scheme, '') ILIKE '%D2R%' OR COALESCE(p.plan_scheme, '') ILIKE '%TBS%' OR COALESCE(p.plan_scheme, '') ILIKE '%Reducing Rent%')
                     AND d.city <> 'Mumbai' 
                     AND gps.total_gps_km > 0 
                THEN ROUND(GREATEST(0, gps.total_gps_km - ideal.ideal_gps_km) * 3.00, 2)
                ELSE 0.00 
               END)
            + (CASE 
                WHEN d.partner_type = 'Operator' THEN 0.00
                WHEN (d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue - d.net_weekly_lease_rental) > 0 
                THEN ROUND((d.uber_total_earnings + d.ola_net_revenue + d.rapido_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
                ELSE 0.00 
               END)
        ))) AS to_payout,
        
        d.net_weekly_lease_rental AS letzryd_earning,
        COALESCE(ROUND(d.net_weekly_lease_rental / NULLIF(d.onroad_days, 0), 2), 0.00) AS letzryd_earning_per_day,
        'DRAFT' AS settlement_status,
        CURRENT_TIMESTAMP AS updated_at
    FROM daily_agg d
    LEFT JOIN LATERAL (
        SELECT partner_id, plan_scheme FROM public.core_rent 
        WHERE vehicle_number = d.vehicle_number 
        ORDER BY is_active DESC NULLS LAST, id DESC LIMIT 1
    ) p ON TRUE
    LEFT JOIN LATERAL (
        SELECT driver_name FROM public.core_partner_onboarding 
        WHERE partner_id = d.partner_id LIMIT 1
    ) dr ON TRUE
    LEFT JOIN LATERAL (
        SELECT 
            COALESCE(SUM(u.total_trip_distance_km), 0.00) + COALESCE(SUM(o.total_kms), 0.00) + COALESCE(SUM(rp.total_trip_distance_km), 0.00) AS in_trip_km
        FROM (SELECT 1) dummy
        LEFT JOIN public.core_uber_daily u 
            ON u.vehicle_number = d.vehicle_number 
           AND u.operational_date BETWEEN d.partner_min_date AND d.partner_max_date
           AND (d.partner_type = 'Operator' OR u.vendor_code = d.partner_id OR u.vendor_code IS NULL)
        LEFT JOIN public.core_ola_daily o 
            ON o.vehicle_number = d.vehicle_number 
           AND o.service_date BETWEEN d.partner_min_date AND d.partner_max_date
        LEFT JOIN public.core_rapido_daily rp
            ON rp.vehicle_number = d.vehicle_number
           AND rp.operational_date BETWEEN d.partner_min_date AND d.partner_max_date
    ) trip_km ON TRUE
    LEFT JOIN LATERAL (
        SELECT 
            COALESCE(SUM(distance_km), 0.00) AS total_gps_km
        FROM public.core_gps
        WHERE vehicle_number = d.vehicle_number
          AND record_date BETWEEN d.partner_min_date AND d.partner_max_date
    ) gps ON TRUE
    LEFT JOIN LATERAL (
        SELECT 
            CASE 
                WHEN d.city = 'Hyderabad' THEN (trip_km.in_trip_km * 1.05) + (d.uber_trips + d.ola_trips + d.rapido_trips) * 4.00 + (d.onroad_days * 25.00)
                ELSE (trip_km.in_trip_km * 1.05) + (d.uber_trips + d.ola_trips + d.rapido_trips) * 3.00 + (d.onroad_days * 30.00)
            END AS ideal_gps_km
    ) ideal ON TRUE
    ON CONFLICT (week_id, vehicle_number, partner_id) DO UPDATE SET
        allotted_days = EXCLUDED.allotted_days,
        onroad_days = EXCLUDED.onroad_days,
        daily_rent_applied = EXCLUDED.daily_rent_applied,
        weekly_lease_rental = EXCLUDED.weekly_lease_rental,
        weekly_indemnity_fees = EXCLUDED.weekly_indemnity_fees,
        net_weekly_lease_rental = EXCLUDED.net_weekly_lease_rental,
        uber_trips = EXCLUDED.uber_trips,
        uber_total_earnings = EXCLUDED.uber_total_earnings,
        uber_cash_collection = EXCLUDED.uber_cash_collection,
        uber_toll = EXCLUDED.uber_toll,
        uber_driver_sub_charge = EXCLUDED.uber_driver_sub_charge,
        uber_week_os = EXCLUDED.uber_week_os,
        ola_trips = EXCLUDED.ola_trips,
        ola_net_revenue = EXCLUDED.ola_net_revenue,
        ola_cash_collection = EXCLUDED.ola_cash_collection,
        ola_toll = EXCLUDED.ola_toll,
        ola_online_payment = EXCLUDED.ola_online_payment,
        ola_week_os = EXCLUDED.ola_week_os,
        rapido_trips = EXCLUDED.rapido_trips,
        rapido_net_revenue = EXCLUDED.rapido_net_revenue,
        rapido_cash_collected = EXCLUDED.rapido_cash_collected,
        weekly_platform_incentive = EXCLUDED.weekly_platform_incentive,
        vehicle_adjustments = EXCLUDED.vehicle_adjustments,
        challan_amount = EXCLUDED.challan_amount,
        accident_penalties = EXCLUDED.accident_penalties,
        total_trip_km = EXCLUDED.total_trip_km,
        total_gps_km = EXCLUDED.total_gps_km,
        ideal_gps_km = EXCLUDED.ideal_gps_km,
        dead_mile_km = EXCLUDED.dead_mile_km,
        dead_mile_pct = EXCLUDED.dead_mile_pct,
        dead_mile_charges = EXCLUDED.dead_mile_charges,
        tds_amount = EXCLUDED.tds_amount,
        current_week_os = EXCLUDED.current_week_os,
        to_collect = EXCLUDED.to_collect,
        to_payout = EXCLUDED.to_payout,
        letzryd_earning = EXCLUDED.letzryd_earning,
        letzryd_earning_per_day = EXCLUDED.letzryd_earning_per_day,
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_vehicle_weekly.settlement_status IN ('DRAFT', 'OPEN');

END;
$procedure$;

-- ----------------------------------------------------------------------------
-- Definition: sp_sync_hisaab_partner_weekly
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_partner_weekly(IN p_week_id character varying, IN p_partner character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_is_locked BOOLEAN;
    v_prev_week_id VARCHAR;
    v_prev_week_end DATE;
    v_enable_roll_forward BOOLEAN := FALSE;
BEGIN
    IF p_week_id IS NULL THEN
        RETURN;
    END IF;

    PERFORM public.fn_ensure_hisaab_week(p_week_id, NULL);
    SELECT is_locked, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = p_week_id;

    IF v_is_locked = TRUE THEN
        RETURN;
    END IF;

    SELECT (COALESCE(config_value, 'false') = 'true') INTO v_enable_roll_forward
    FROM public.hisaab_system_config
    WHERE config_key = 'enable_roll_forward';

    v_prev_week_end := v_week_start - INTERVAL '1 day';
    v_prev_week_id := 'CY' || to_char(v_prev_week_end, 'IY') || 'WK' || to_char(v_prev_week_end, 'IW');

    WITH veh_summary AS (
        SELECT 
            v.partner_id,
            MAX(v.partner_name) AS partner_name,
            MAX(v.partner_type) AS partner_type,
            MAX(v.city) AS city,
            COUNT(DISTINCT v.vehicle_number)::INT AS allotted_cars_count,
            SUM(v.onroad_days)::INT AS total_onroad_days,
            SUM(v.uber_trips + v.ola_trips + v.rapido_trips)::INT AS total_trips,
            SUM(v.net_weekly_lease_rental) AS total_net_rent_billed,
            SUM(v.uber_total_earnings + v.ola_net_revenue + v.rapido_net_revenue) AS total_platform_earnings,
            -- DEFECT 1 FIX: Clean passenger cash summation across Uber, Ola, and Rapido
            SUM(ABS(COALESCE(v.uber_cash_collection, 0.00)) + ABS(COALESCE(v.ola_cash_collection, 0.00)) + ABS(COALESCE(v.rapido_cash_collected, 0.00))) AS total_cash_collected,
            SUM(v.weekly_platform_incentive) AS total_platform_incentives,
            SUM(v.vehicle_adjustments) AS total_adjustments,
            SUM(v.challan_amount) AS total_challans,
            SUM(v.accident_penalties) AS total_accidents,
            SUM(v.tds_amount) AS total_tds,
            SUM(v.current_week_os) AS current_week_os
        FROM public.hisaab_vehicle_weekly v
        WHERE v.week_id = p_week_id
          AND (p_partner IS NULL OR v.partner_id = p_partner)
        GROUP BY v.partner_id
    ),
    prior_adj AS (
        SELECT 
            partner_id,
            COALESCE(SUM(CASE WHEN polarity = 'DEBIT' THEN amount ELSE -amount END), 0.00) AS prior_period_adjustments
        FROM public.hisaab_adjustments_ledger
        WHERE settlement_week_id = p_week_id 
          AND is_prior_period = TRUE
          AND approval_status = 'Approved'
          AND (p_partner IS NULL OR partner_id = p_partner)
        GROUP BY partner_id
    ),
    prev_dues AS (
        SELECT 
            ap.partner_id,
            CASE 
                WHEN op.opening_balance_due IS NOT NULL THEN op.opening_balance_due
                WHEN v_enable_roll_forward = TRUE AND pw.total_outstanding > 0 THEN pw.total_outstanding
                ELSE 0.00 
            END AS previous_outstanding
        FROM (
            SELECT partner_id FROM veh_summary
            UNION
            SELECT partner_id FROM prior_adj
            UNION
            SELECT partner_id FROM public.hisaab_partner_opening_balances WHERE effective_week_id = p_week_id
            UNION
            SELECT partner_id FROM public.hisaab_partner_weekly WHERE v_enable_roll_forward = TRUE AND week_id = v_prev_week_id AND total_outstanding > 0
        ) ap
        LEFT JOIN public.hisaab_partner_opening_balances op 
            ON op.partner_id = ap.partner_id AND op.effective_week_id = p_week_id
        LEFT JOIN public.hisaab_partner_weekly pw 
            ON pw.week_id = v_prev_week_id AND pw.partner_id = ap.partner_id
        WHERE (p_partner IS NULL OR ap.partner_id = p_partner)
    ),
    existing_payments AS (
        SELECT 
            partner_id,
            COALESCE(amount_paid_during_week, 0.00) AS amount_paid_during_week
        FROM public.hisaab_partner_weekly
        WHERE week_id = p_week_id
          AND (p_partner IS NULL OR partner_id = p_partner)
    ),
    all_partners AS (
        SELECT partner_id FROM prev_dues
        WHERE previous_outstanding <> 0.00 
           OR partner_id IN (SELECT partner_id FROM veh_summary)
           OR partner_id IN (SELECT partner_id FROM prior_adj)
    )
    INSERT INTO public.hisaab_partner_weekly (
        settlement_year,
        settlement_week,
        week_id,
        week_start,
        week_end,
        partner_id,
        partner_name,
        partner_type,
        city,
        allotted_cars_count,
        total_onroad_days,
        total_trips,
        total_net_rent_billed,
        total_platform_earnings,
        total_cash_collected,
        total_platform_incentives,
        total_adjustments,
        total_challans,
        total_accidents,
        total_tds,
        current_week_os,
        previous_outstanding,
        amount_paid_during_week,
        prior_period_adjustments,
        security_deposit_target,
        security_deposit_paid,
        deposit_deduction_current_week,
        pending_deposit,
        total_outstanding,
        net_bank_payout,
        net_amount_to_collect,
        settlement_status,
        payout_account_number,
        payout_ifsc,
        updated_at
    )
    SELECT 
        v_year,
        v_week_num,
        p_week_id,
        v_week_start,
        v_week_end,
        ap.partner_id,
        COALESCE(v.partner_name, dr.driver_name, ap.partner_id) AS partner_name,
        COALESCE(v.partner_type, CASE WHEN ap.partner_id ILIKE '%IP%' OR ap.partner_id ILIKE '%OP%' THEN 'Operator' ELSE 'Individual' END) AS partner_type,
        COALESCE(v.city, 'HYD') AS city,
        COALESCE(v.allotted_cars_count, 0) AS allotted_cars_count,
        COALESCE(v.total_onroad_days, 0) AS total_onroad_days,
        COALESCE(v.total_trips, 0) AS total_trips,
        COALESCE(v.total_net_rent_billed, 0.00) AS total_net_rent_billed,
        COALESCE(v.total_platform_earnings, 0.00) AS total_platform_earnings,
        COALESCE(v.total_cash_collected, 0.00) AS total_cash_collected,
        COALESCE(v.total_platform_incentives, 0.00) AS total_platform_incentives,
        COALESCE(v.total_adjustments, 0.00) AS total_adjustments,
        COALESCE(v.total_challans, 0.00) AS total_challans,
        COALESCE(v.total_accidents, 0.00) AS total_accidents,
        COALESCE(v.total_tds, 0.00) AS total_tds,
        COALESCE(v.current_week_os, 0.00) AS current_week_os,
        COALESCE(pd.previous_outstanding, 0.00) AS previous_outstanding,
        -- DEFECT 2 FIX: Read and preserve interim collections
        COALESCE(ep.amount_paid_during_week, 0.00) AS amount_paid_during_week,
        COALESCE(pa.prior_period_adjustments, 0.00) AS prior_period_adjustments,
        COALESCE(dr.security_deposit, 5000.00) AS security_deposit_target,
        COALESCE(dr.security_deposit, 5000.00) AS security_deposit_paid,
        0.00 AS deposit_deduction_current_week,
        0.00 AS pending_deposit,
        -- DEFECT 2 FIX: Total outstanding = current_week_os + previous_outstanding + prior_period_adjustments - amount_paid_during_week
        (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00) - COALESCE(ep.amount_paid_during_week, 0.00)) AS total_outstanding,
        ABS(LEAST(0, (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00) - COALESCE(ep.amount_paid_during_week, 0.00)))) AS net_bank_payout,
        GREATEST(0, (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00) - COALESCE(ep.amount_paid_during_week, 0.00))) AS net_amount_to_collect,
        'DRAFT' AS settlement_status,
        dr.account_number AS payout_account_number,
        dr.ifsc_code AS payout_ifsc,
        CURRENT_TIMESTAMP AS updated_at
    FROM all_partners ap
    LEFT JOIN veh_summary v ON ap.partner_id = v.partner_id
    LEFT JOIN prior_adj pa ON ap.partner_id = pa.partner_id
    LEFT JOIN prev_dues pd ON ap.partner_id = pd.partner_id
    LEFT JOIN existing_payments ep ON ap.partner_id = ep.partner_id
    LEFT JOIN LATERAL (
        SELECT account_number, ifsc_code, driver_name, security_deposit FROM public.core_partner_onboarding 
        WHERE partner_id = ap.partner_id LIMIT 1
    ) dr ON TRUE
    ON CONFLICT (week_id, partner_id) DO UPDATE SET
        partner_name = COALESCE(EXCLUDED.partner_name, public.hisaab_partner_weekly.partner_name),
        allotted_cars_count = EXCLUDED.allotted_cars_count,
        total_onroad_days = EXCLUDED.total_onroad_days,
        total_trips = EXCLUDED.total_trips,
        total_net_rent_billed = EXCLUDED.total_net_rent_billed,
        total_platform_earnings = EXCLUDED.total_platform_earnings,
        total_cash_collected = EXCLUDED.total_cash_collected,
        total_platform_incentives = EXCLUDED.total_platform_incentives,
        total_adjustments = EXCLUDED.total_adjustments,
        total_challans = EXCLUDED.total_challans,
        total_accidents = EXCLUDED.total_accidents,
        total_tds = EXCLUDED.total_tds,
        current_week_os = EXCLUDED.current_week_os,
        previous_outstanding = EXCLUDED.previous_outstanding,
        prior_period_adjustments = EXCLUDED.prior_period_adjustments,
        amount_paid_during_week = COALESCE(public.hisaab_partner_weekly.amount_paid_during_week, 0.00),
        security_deposit_target = EXCLUDED.security_deposit_target,
        security_deposit_paid = EXCLUDED.security_deposit_paid,
        -- DEFECT 2 FIX: preserve amount_paid_during_week in total_outstanding calculation
        total_outstanding = (EXCLUDED.current_week_os + EXCLUDED.previous_outstanding + EXCLUDED.prior_period_adjustments - COALESCE(public.hisaab_partner_weekly.amount_paid_during_week, 0.00)),
        net_bank_payout = ABS(LEAST(0, (EXCLUDED.current_week_os + EXCLUDED.previous_outstanding + EXCLUDED.prior_period_adjustments - COALESCE(public.hisaab_partner_weekly.amount_paid_during_week, 0.00)))),
        net_amount_to_collect = GREATEST(0, (EXCLUDED.current_week_os + EXCLUDED.previous_outstanding + EXCLUDED.prior_period_adjustments - COALESCE(public.hisaab_partner_weekly.amount_paid_during_week, 0.00))),
        payout_account_number = COALESCE(EXCLUDED.payout_account_number, public.hisaab_partner_weekly.payout_account_number),
        payout_ifsc = COALESCE(EXCLUDED.payout_ifsc, public.hisaab_partner_weekly.payout_ifsc),
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_partner_weekly.settlement_status IN ('DRAFT', 'OPEN');

    DELETE FROM public.hisaab_partner_weekly
    WHERE week_id = p_week_id
      AND settlement_status IN ('DRAFT', 'OPEN')
      AND (p_partner IS NULL OR partner_id = p_partner)
      AND partner_id NOT IN (
          SELECT partner_id FROM public.hisaab_vehicle_weekly WHERE week_id = p_week_id
          UNION
          SELECT partner_id FROM public.hisaab_adjustments_ledger WHERE settlement_week_id = p_week_id AND is_prior_period = TRUE AND approval_status = 'Approved'
          UNION
          SELECT partner_id FROM public.hisaab_partner_opening_balances WHERE effective_week_id = p_week_id
          UNION
          SELECT partner_id FROM public.hisaab_partner_weekly WHERE v_enable_roll_forward = TRUE AND week_id = v_prev_week_id AND total_outstanding > 0
      );

END;
$procedure$;

-- ----------------------------------------------------------------------------
-- Definition: sp_run_full_week_hisaab
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_run_full_week_hisaab(IN p_week_id character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_is_locked BOOLEAN;
    v_start_time TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF p_week_id IS NULL THEN
        RAISE EXCEPTION 'p_week_id must be provided to sp_run_full_week_hisaab';
    END IF;

    PERFORM public.fn_ensure_hisaab_week(p_week_id, NULL);
    SELECT is_locked, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = p_week_id;

    IF v_is_locked = TRUE THEN
        RAISE EXCEPTION 'Settlement week % is LOCKED. Batch reconciliation aborted.', p_week_id;
    END IF;

    -- Suppress per-row trigger cascades during batch daily upsert
    PERFORM set_config('hisaab.skip_cascade', 'true', true);

    -- 1. Ingest/Update hisaab_daily_ledger across entire 7-day window
    WITH base_rent AS (
        SELECT 
            r.log_date,
            r.vehicle_number,
            r.partner_id,
            CASE WHEN r.partner_id ILIKE '%IP%' OR r.partner_id ILIKE '%OP%' THEN 'Operator' ELSE 'Individual' END AS partner_type,
            COALESCE(r.city, 'HYD') AS city,
            r.vehicle_model,
            r.attendance_status,
            r.is_billable_day,
            COALESCE(r.applied_daily_rent, 0.00) AS applied_daily_rent,
            COALESCE(r.applied_daily_indemnity, 0.00) AS applied_daily_indemnity,
            COALESCE(r.net_daily_rent, 0.00) AS net_daily_rent
        FROM public.daily_rent_log r
        WHERE r.log_date BETWEEN v_week_start AND v_week_end
    ),
    uber_agg AS (
        SELECT 
            u.operational_date,
            u.vehicle_number,
            COALESCE(SUM(u.completed_trips), 0)::INT AS uber_trips,
            COALESCE(SUM(u.net_fare_earnings), 0.00) AS uber_fare_earnings,
            COALESCE(SUM(u.cash_collected), 0.00) AS uber_cash_collected,
            COALESCE(SUM(u.tolls_refunded), 0.00) AS uber_tolls,
            COALESCE(SUM(u.driver_subscription_charge), 0.00) AS uber_subscription_charge
        FROM public.core_uber_daily u
        WHERE u.operational_date BETWEEN v_week_start AND v_week_end
        GROUP BY u.operational_date, u.vehicle_number
    ),
    ola_agg AS (
        SELECT 
            o.service_date,
            o.vehicle_number,
            COALESCE(SUM(o.completed_trips), 0)::INT AS ola_trips,
            COALESCE(SUM(o.operator_bill), 0.00) AS ola_net_revenue,
            COALESCE(SUM(o.cash_collected), 0.00) AS ola_cash_collected,
            COALESCE(SUM(o.toll_and_parking), 0.00) AS ola_tolls,
            COALESCE(SUM(o.online_payouts), 0.00) AS ola_online_payment
        FROM public.core_ola_daily o
        WHERE o.service_date BETWEEN v_week_start AND v_week_end
        GROUP BY o.service_date, o.vehicle_number
    ),
    rapido_agg AS (
        SELECT 
            rp.operational_date,
            rp.vehicle_number,
            COALESCE(SUM(rp.completed_trips), 0)::INT AS rapido_trips,
            COALESCE(SUM(rp.net_revenue), 0.00) AS rapido_net_revenue,
            COALESCE(SUM(rp.cash_collected), 0.00) AS rapido_cash_collected
        FROM public.core_rapido_daily rp
        WHERE rp.operational_date BETWEEN v_week_start AND v_week_end
        GROUP BY rp.operational_date, rp.vehicle_number
    ),
    adj_agg AS (
        SELECT 
            COALESCE(effective_date, incident_date) AS incident_date,
            vehicle_number,
            partner_id,
            SUM(CASE WHEN polarity = 'DEBIT' AND NOT (adjustment_category ILIKE '%accident%' OR adjustment_category ILIKE '%damage%') THEN amount ELSE 0.00 END) AS daily_challans,
            SUM(CASE WHEN polarity = 'DEBIT' AND (adjustment_category ILIKE '%accident%' OR adjustment_category ILIKE '%damage%') THEN amount ELSE 0.00 END) AS daily_accidents,
            SUM(CASE WHEN polarity = 'CREDIT' THEN amount ELSE 0.00 END) AS daily_adjustments
        FROM public.hisaab_adjustments_ledger
        WHERE settlement_week_id = p_week_id
          AND approval_status = 'Approved'
        GROUP BY COALESCE(effective_date, incident_date), vehicle_number, partner_id
    ),
    sunday_inc AS (
        SELECT 
            vehicle_number,
            COALESCE(SUM(inc), 0.00) AS total_inc
        FROM (
            SELECT vehicle_number, SUM(uber_vehicle_incentive) AS inc
            FROM public.core_uber_weekly
            WHERE (week_id = p_week_id OR (settlement_year = v_year AND settlement_week = v_week_num))
            GROUP BY vehicle_number
            UNION ALL
            SELECT vehicle_number, SUM(ola_portal_incentive) AS inc
            FROM public.core_ola_weekly
            WHERE week_id = p_week_id
            GROUP BY vehicle_number
        ) all_inc
        GROUP BY vehicle_number
    )
    INSERT INTO public.hisaab_daily_ledger (
        log_date,
        week_id,
        vehicle_number,
        partner_id,
        partner_type,
        city,
        vehicle_model,
        attendance_status,
        is_billable_day,
        daily_rent_applied,
        daily_indemnity_fee,
        net_daily_rent,
        uber_trips,
        uber_fare_earnings,
        uber_cash_collected,
        uber_tolls,
        uber_subscription_charge,
        ola_trips,
        ola_net_revenue,
        ola_cash_collected,
        ola_tolls,
        ola_online_payment,
        rapido_trips,
        rapido_net_revenue,
        rapido_cash_collected,
        daily_adjustments,
        daily_challans,
        daily_accident_recovery,
        weekly_incentive_credit,
        daily_net_balance,
        is_locked,
        updated_at
    )
    SELECT 
        r.log_date,
        p_week_id,
        r.vehicle_number,
        r.partner_id,
        CASE WHEN r.partner_id ILIKE '%IP%' OR r.partner_id ILIKE '%OP%' THEN 'Operator' ELSE 'Individual' END AS partner_type,
        r.city,
        r.vehicle_model,
        CASE 
            WHEN r.partner_type = 'Operator' AND r.attendance_status NOT IN ('Maintenance', 'Breakdown', 'Accident')
            THEN 'Active (Operator Contract)'
            WHEN (COALESCE(r.net_daily_rent, 0.00) <= 0.00 OR r.is_billable_day = FALSE) 
             AND (COALESCE(u.uber_trips, 0) > 0 OR COALESCE(o.ola_trips, 0) > 0 OR COALESCE(rp.rapido_trips, 0) > 0)
            THEN 'Active (Trip Override)'
            ELSE r.attendance_status
        END,
        CASE 
            WHEN r.partner_type = 'Operator' AND r.attendance_status NOT IN ('Maintenance', 'Breakdown', 'Accident')
            THEN TRUE
            WHEN (COALESCE(r.net_daily_rent, 0.00) <= 0.00 OR r.is_billable_day = FALSE) 
             AND (COALESCE(u.uber_trips, 0) > 0 OR COALESCE(o.ola_trips, 0) > 0 OR COALESCE(rp.rapido_trips, 0) > 0)
            THEN TRUE
            ELSE r.is_billable_day
        END,
        CASE 
            WHEN r.partner_type = 'Operator' AND r.attendance_status NOT IN ('Maintenance', 'Breakdown', 'Accident')
            THEN COALESCE(NULLIF(r.applied_daily_rent, 0.00), cr.custom_daily_rent, 856.00)
            WHEN (COALESCE(r.net_daily_rent, 0.00) <= 0.00 OR r.is_billable_day = FALSE) 
             AND (COALESCE(u.uber_trips, 0) > 0 OR COALESCE(o.ola_trips, 0) > 0 OR COALESCE(rp.rapido_trips, 0) > 0)
            THEN COALESCE(cr.custom_daily_rent, 856.00)
            ELSE r.applied_daily_rent
        END,
        r.applied_daily_indemnity,
        CASE 
            WHEN r.partner_type = 'Operator' AND r.attendance_status NOT IN ('Maintenance', 'Breakdown', 'Accident')
            THEN COALESCE(NULLIF(r.applied_daily_rent, 0.00), cr.custom_daily_rent, 856.00) + COALESCE(r.applied_daily_indemnity, 0.00)
            WHEN (COALESCE(r.net_daily_rent, 0.00) <= 0.00 OR r.is_billable_day = FALSE) 
             AND (COALESCE(u.uber_trips, 0) > 0 OR COALESCE(o.ola_trips, 0) > 0 OR COALESCE(rp.rapido_trips, 0) > 0)
            THEN COALESCE(cr.custom_daily_rent, 856.00) + COALESCE(r.applied_daily_indemnity, 0.00)
            ELSE r.net_daily_rent
        END,
        COALESCE(u.uber_trips, 0),
        COALESCE(u.uber_fare_earnings, 0.00),
        COALESCE(u.uber_cash_collected, 0.00),
        COALESCE(u.uber_tolls, 0.00),
        COALESCE(u.uber_subscription_charge, 0.00),
        COALESCE(o.ola_trips, 0),
        COALESCE(o.ola_net_revenue, 0.00),
        COALESCE(o.ola_cash_collected, 0.00),
        COALESCE(o.ola_tolls, 0.00),
        COALESCE(o.ola_online_payment, 0.00),
        COALESCE(rp.rapido_trips, 0),
        COALESCE(rp.rapido_net_revenue, 0.00),
        COALESCE(rp.rapido_cash_collected, 0.00),
        COALESCE(a.daily_adjustments, 0.00),
        COALESCE(a.daily_challans, 0.00),
        COALESCE(a.daily_accidents, 0.00),
        CASE WHEN r.log_date = v_week_end THEN COALESCE(sinc.total_inc, 0.00) ELSE 0.00 END AS weekly_incentive_credit,
        (
            -- Rent
            (CASE 
                WHEN r.partner_type = 'Operator' AND r.attendance_status NOT IN ('Maintenance', 'Breakdown', 'Accident')
                THEN COALESCE(NULLIF(r.applied_daily_rent, 0.00), cr.custom_daily_rent, 856.00) + COALESCE(r.applied_daily_indemnity, 0.00)
                WHEN (COALESCE(r.net_daily_rent, 0.00) <= 0.00 OR r.is_billable_day = FALSE) 
                 AND (COALESCE(u.uber_trips, 0) > 0 OR COALESCE(o.ola_trips, 0) > 0 OR COALESCE(rp.rapido_trips, 0) > 0)
                THEN COALESCE(cr.custom_daily_rent, 856.00) + COALESCE(r.applied_daily_indemnity, 0.00)
                ELSE COALESCE(r.net_daily_rent, 0.00)
             END)
            -- Cash Collected
            + (ABS(COALESCE(u.uber_cash_collected, 0.00)) + ABS(COALESCE(o.ola_cash_collected, 0.00)) + ABS(COALESCE(rp.rapido_cash_collected, 0.00)))
            -- Digital Fare Earnings
            - (COALESCE(u.uber_fare_earnings, 0.00) + COALESCE(o.ola_net_revenue, 0.00) + COALESCE(rp.rapido_net_revenue, 0.00))
            - COALESCE(o.ola_online_payment, 0.00)
            -- Debits
            + COALESCE(a.daily_challans, 0.00)
            + COALESCE(a.daily_accidents, 0.00)
            -- Credits
            - COALESCE(a.daily_adjustments, 0.00)
            - (CASE WHEN r.log_date = v_week_end THEN COALESCE(sinc.total_inc, 0.00) ELSE 0.00 END)
        ) AS daily_net_balance,
        FALSE,
        CURRENT_TIMESTAMP
    FROM base_rent r
    LEFT JOIN LATERAL (
        SELECT custom_daily_rent 
        FROM public.core_rent 
        WHERE vehicle_number = r.vehicle_number 
        ORDER BY is_active DESC NULLS LAST, id DESC LIMIT 1
    ) cr ON TRUE
    LEFT JOIN uber_agg u ON r.log_date = u.operational_date AND r.vehicle_number = u.vehicle_number
    LEFT JOIN ola_agg o ON r.log_date = o.service_date AND r.vehicle_number = o.vehicle_number
    LEFT JOIN rapido_agg rp ON r.log_date = rp.operational_date AND r.vehicle_number = rp.vehicle_number
    LEFT JOIN adj_agg a ON r.log_date = a.incident_date AND r.vehicle_number = a.vehicle_number AND r.partner_id = a.partner_id
    LEFT JOIN sunday_inc sinc ON r.vehicle_number = sinc.vehicle_number
    ON CONFLICT (log_date, vehicle_number, partner_id) DO UPDATE SET
        partner_type = EXCLUDED.partner_type,
        city = CASE WHEN EXCLUDED.city <> 'Unknown' THEN EXCLUDED.city ELSE public.hisaab_daily_ledger.city END,
        vehicle_model = COALESCE(EXCLUDED.vehicle_model, public.hisaab_daily_ledger.vehicle_model),
        attendance_status = EXCLUDED.attendance_status,
        is_billable_day = EXCLUDED.is_billable_day,
        daily_rent_applied = EXCLUDED.daily_rent_applied,
        daily_indemnity_fee = EXCLUDED.daily_indemnity_fee,
        net_daily_rent = EXCLUDED.net_daily_rent,
        uber_trips = EXCLUDED.uber_trips,
        uber_fare_earnings = EXCLUDED.uber_fare_earnings,
        uber_cash_collected = EXCLUDED.uber_cash_collected,
        uber_tolls = EXCLUDED.uber_tolls,
        uber_subscription_charge = EXCLUDED.uber_subscription_charge,
        ola_trips = EXCLUDED.ola_trips,
        ola_net_revenue = EXCLUDED.ola_net_revenue,
        ola_cash_collected = EXCLUDED.ola_cash_collected,
        ola_tolls = EXCLUDED.ola_tolls,
        ola_online_payment = EXCLUDED.ola_online_payment,
        rapido_trips = EXCLUDED.rapido_trips,
        rapido_net_revenue = EXCLUDED.rapido_net_revenue,
        rapido_cash_collected = EXCLUDED.rapido_cash_collected,
        daily_adjustments = EXCLUDED.daily_adjustments,
        daily_challans = EXCLUDED.daily_challans,
        daily_accident_recovery = EXCLUDED.daily_accident_recovery,
        weekly_incentive_credit = EXCLUDED.weekly_incentive_credit,
        daily_net_balance = EXCLUDED.daily_net_balance,
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_daily_ledger.is_locked = FALSE;

    -- 2. Bulk Roll-up into hisaab_vehicle_weekly
    CALL public.sp_sync_hisaab_vehicle_weekly(p_week_id, NULL, NULL);

    -- 3. Bulk Roll-up into hisaab_partner_weekly
    CALL public.sp_sync_hisaab_partner_weekly(p_week_id, NULL);

    PERFORM set_config('hisaab.skip_cascade', 'false', true);

    RAISE NOTICE 'sp_run_full_week_hisaab complete for % in % ms.',
        p_week_id, (EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000)::INT;
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- Definition: sp_check_and_enforce_monday_lock
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_check_and_enforce_monday_lock(IN p_target_week_id character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_week RECORD;
    v_locked_count INT := 0;
    v_daily_count INT := 0;
    v_veh_count INT := 0;
    v_partner_count INT := 0;
BEGIN
    -- Enable bypass flags for administrative lock enforcement
    PERFORM set_config('hisaab.enforcing_lock', 'true', true);
    PERFORM set_config('hisaab.skip_cascade', 'true', true);

    FOR v_week IN
        SELECT week_id, lock_cutoff_at
        FROM public.hisaab_settlement_weeks
        WHERE is_locked = FALSE
          AND (
              (p_target_week_id IS NOT NULL AND week_id = p_target_week_id)
              OR (p_target_week_id IS NULL AND CURRENT_TIMESTAMP >= lock_cutoff_at)
          )
        ORDER BY week_start ASC
    LOOP
        -- 1. Lock daily shift records
        UPDATE public.hisaab_daily_ledger
        SET is_locked = TRUE,
            updated_at = CURRENT_TIMESTAMP
        WHERE week_id = v_week.week_id
          AND is_locked = FALSE;
        GET DIAGNOSTICS v_daily_count = ROW_COUNT;

        -- 2. Freeze weekly vehicle settlements
        UPDATE public.hisaab_vehicle_weekly
        SET settlement_status = 'FROZEN',
            updated_at = CURRENT_TIMESTAMP
        WHERE week_id = v_week.week_id
          AND settlement_status <> 'FROZEN';
        GET DIAGNOSTICS v_veh_count = ROW_COUNT;

        -- 3. Freeze partner weekly payout statements
        UPDATE public.hisaab_partner_weekly
        SET settlement_status = 'FROZEN',
            frozen_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE week_id = v_week.week_id
          AND settlement_status <> 'FROZEN';
        GET DIAGNOSTICS v_partner_count = ROW_COUNT;

        -- 4. Mark master settlement week as locked
        UPDATE public.hisaab_settlement_weeks
        SET is_locked = TRUE,
            locked_at = CURRENT_TIMESTAMP,
            locked_by = 'system_scheduled_cutoff',
            updated_at = CURRENT_TIMESTAMP
        WHERE week_id = v_week.week_id;

        v_locked_count := v_locked_count + 1;
        RAISE NOTICE 'Enforced Monday 11:00 AM lock for week %: % daily rows, % vehicle records, % partner statements frozen.',
            v_week.week_id, v_daily_count, v_veh_count, v_partner_count;
    END LOOP;

    -- Reset bypass flags
    PERFORM set_config('hisaab.enforcing_lock', 'false', true);
    PERFORM set_config('hisaab.skip_cascade', 'false', true);

    IF v_locked_count = 0 THEN
        RAISE NOTICE 'No open weeks found requiring Monday 11:00 AM cutoff enforcement.';
    END IF;
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- Definition: fn_prevent_locked_hisaab_update
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_prevent_locked_hisaab_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_is_locked BOOLEAN;
    v_week_id VARCHAR(16);
BEGIN
    IF current_setting('hisaab.enforcing_lock', true) = 'true' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    IF TG_OP = 'INSERT' THEN
        v_week_id := NEW.week_id;
    ELSE
        v_week_id := OLD.week_id;
    END IF;

    SELECT is_locked INTO v_is_locked
    FROM public.hisaab_settlement_weeks
    WHERE week_id = v_week_id;

    IF v_is_locked = TRUE OR (TG_OP <> 'INSERT' AND OLD.is_locked = TRUE) THEN
        RAISE EXCEPTION 'Hisaab daily cycle % is LOCKED. Modifications not allowed.', v_week_id;
    END IF;

    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_prevent_locked_adjustment_update
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_prevent_locked_adjustment_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_locked BOOLEAN;
BEGIN
    IF current_setting('hisaab.enforcing_lock', true) = 'true' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    -- Guard against modifying existing locked records
    SELECT is_locked INTO v_locked
    FROM public.hisaab_settlement_weeks
    WHERE week_id = OLD.settlement_week_id;

    IF v_locked = TRUE THEN
        RAISE EXCEPTION 'Hisaab cycle % is LOCKED. No modifications allowed to adjustments.', OLD.settlement_week_id;
    END IF;

    -- Guard against reassigning records into locked records on UPDATE
    IF TG_OP = 'UPDATE' AND NEW.settlement_week_id IS DISTINCT FROM OLD.settlement_week_id THEN
        SELECT is_locked INTO v_locked
        FROM public.hisaab_settlement_weeks
        WHERE week_id = NEW.settlement_week_id;

        IF v_locked = TRUE THEN
            RAISE EXCEPTION 'Cannot reassign adjustment to LOCKED Hisaab cycle %.', NEW.settlement_week_id;
        END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_prevent_frozen_vehicle_weekly_update
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_prevent_frozen_vehicle_weekly_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_is_locked BOOLEAN;
    v_week_id VARCHAR(16);
BEGIN
    IF current_setting('hisaab.enforcing_lock', true) = 'true' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    IF TG_OP = 'INSERT' THEN
        v_week_id := NEW.week_id;
    ELSE
        v_week_id := OLD.week_id;
    END IF;

    SELECT is_locked INTO v_is_locked
    FROM public.hisaab_settlement_weeks
    WHERE week_id = v_week_id;

    IF v_is_locked = TRUE OR (TG_OP <> 'INSERT' AND OLD.settlement_status = 'FROZEN') THEN
        RAISE EXCEPTION 'Hisaab vehicle weekly cycle % is LOCKED/FROZEN. Modifications not allowed.', v_week_id;
    END IF;

    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_prevent_frozen_partner_weekly_update
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_prevent_frozen_partner_weekly_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_is_locked BOOLEAN;
    v_week_id VARCHAR(16);
BEGIN
    IF current_setting('hisaab.enforcing_lock', true) = 'true' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    IF TG_OP = 'INSERT' THEN
        v_week_id := NEW.week_id;
    ELSE
        v_week_id := OLD.week_id;
    END IF;

    SELECT is_locked INTO v_is_locked
    FROM public.hisaab_settlement_weeks
    WHERE week_id = v_week_id;

    IF v_is_locked = TRUE OR (TG_OP <> 'INSERT' AND OLD.settlement_status = 'FROZEN') THEN
        RAISE EXCEPTION 'Hisaab partner weekly cycle % is LOCKED/FROZEN. Modifications not allowed.', v_week_id;
    END IF;

    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_trg_auto_route_prior_period_adjustment
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_auto_route_prior_period_adjustment()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_incident_week_id VARCHAR(16);
    v_is_locked BOOLEAN := FALSE;
    v_lock_cutoff_at TIMESTAMPTZ;
    v_active_week_id VARCHAR(16);
    v_prior_tag TEXT;
BEGIN
    IF NEW.incident_date IS NULL THEN
        RAISE EXCEPTION 'incident_date cannot be NULL in hisaab_adjustments_ledger';
    END IF;

    -- 1. Determine incident_week_id from NEW.incident_date
    IF NEW.incident_week_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.hisaab_settlement_weeks WHERE week_id = NEW.incident_week_id) THEN
        v_incident_week_id := NEW.incident_week_id;
        SELECT is_locked, lock_cutoff_at
        INTO v_is_locked, v_lock_cutoff_at
        FROM public.hisaab_settlement_weeks
        WHERE week_id = v_incident_week_id;
    ELSE
        SELECT week_id, is_locked, lock_cutoff_at
        INTO v_incident_week_id, v_is_locked, v_lock_cutoff_at
        FROM public.hisaab_settlement_weeks
        WHERE NEW.incident_date >= week_start AND NEW.incident_date <= week_end
        ORDER BY week_start DESC
        LIMIT 1;

        IF v_incident_week_id IS NULL THEN
            v_incident_week_id := public.fn_ensure_hisaab_week(NULL, NEW.incident_date);
            SELECT is_locked, lock_cutoff_at
            INTO v_is_locked, v_lock_cutoff_at
            FROM public.hisaab_settlement_weeks
            WHERE week_id = v_incident_week_id;
        END IF;

        NEW.incident_week_id := v_incident_week_id;
    END IF;

    -- 2. Check if incident week is locked OR if current timestamp is past lock_cutoff_at
    IF COALESCE(v_is_locked, FALSE) = TRUE OR (v_lock_cutoff_at IS NOT NULL AND CURRENT_TIMESTAMP >= v_lock_cutoff_at) THEN
        -- DEFECT 5 FIX: Select the currently active OPEN week containing CURRENT_DATE
        SELECT week_id INTO v_active_week_id
        FROM public.hisaab_settlement_weeks
        WHERE is_locked = FALSE
          AND CURRENT_DATE >= week_start AND CURRENT_DATE <= week_end
        LIMIT 1;

        -- Fallback: Earliest open week that has not passed cutoff
        IF v_active_week_id IS NULL THEN
            SELECT week_id INTO v_active_week_id
            FROM public.hisaab_settlement_weeks
            WHERE is_locked = FALSE
              AND (lock_cutoff_at IS NULL OR CURRENT_TIMESTAMP < lock_cutoff_at)
            ORDER BY week_start ASC
            LIMIT 1;
        END IF;

        IF v_active_week_id IS NULL THEN
            RAISE EXCEPTION 'Cannot route prior-period adjustment: No active open settlement week found in hisaab_settlement_weeks.';
        END IF;

        NEW.settlement_week_id := v_active_week_id;
        NEW.is_prior_period := TRUE;
        NEW.effective_date := COALESCE(NEW.effective_date, CURRENT_DATE);

        v_prior_tag := '[Prior Period from ' || to_char(NEW.incident_date, 'YYYY-MM-DD') || ']';
        IF NEW.remarks IS NULL OR TRIM(NEW.remarks) = '' THEN
            NEW.remarks := v_prior_tag;
        ELSIF NEW.remarks NOT LIKE '%' || v_prior_tag || '%' THEN
            NEW.remarks := TRIM(NEW.remarks) || ' ' || v_prior_tag;
        END IF;
    ELSE
        NEW.settlement_week_id := v_incident_week_id;
        NEW.is_prior_period := FALSE;
        NEW.effective_date := NEW.incident_date;
    END IF;

    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_trg_sync_hisaab_from_adj
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_adj()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_target_date DATE;
BEGIN
    IF current_setting('hisaab.skip_cascade', true) = 'true' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_target_date := COALESCE(OLD.effective_date, OLD.incident_date);
        PERFORM public.fn_sync_hisaab_daily_upsert(v_target_date, OLD.vehicle_number, OLD.partner_id);
        RETURN OLD;
    END IF;

    v_target_date := COALESCE(NEW.effective_date, NEW.incident_date);
    PERFORM public.fn_sync_hisaab_daily_upsert(v_target_date, NEW.vehicle_number, NEW.partner_id);

    IF TG_OP = 'UPDATE' THEN
        IF OLD.effective_date IS NOT NULL AND OLD.effective_date <> v_target_date THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.effective_date, OLD.vehicle_number, OLD.partner_id);
        ELSIF OLD.incident_date <> v_target_date THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.incident_date, OLD.vehicle_number, OLD.partner_id);
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_trg_cascade_daily_to_weekly
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_cascade_daily_to_weekly()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Skip cascade if batch reconciliation is actively running
    IF current_setting('hisaab.skip_cascade', true) = 'true' THEN
        RETURN NEW;
    END IF;

    CALL public.sp_sync_hisaab_vehicle_weekly(NEW.week_id, NEW.vehicle_number, NEW.partner_id);
    CALL public.sp_sync_hisaab_partner_weekly(NEW.week_id, NEW.partner_id);

    IF TG_OP = 'UPDATE' THEN
        IF (OLD.week_id <> NEW.week_id OR OLD.vehicle_number <> NEW.vehicle_number OR OLD.partner_id <> NEW.partner_id) THEN
            CALL public.sp_sync_hisaab_vehicle_weekly(OLD.week_id, OLD.vehicle_number, OLD.partner_id);
            CALL public.sp_sync_hisaab_partner_weekly(OLD.week_id, OLD.partner_id);
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_sync_core_to_hisaab_adjustments
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_core_to_hisaab_adjustments()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_rec_id BIGINT;
    v_veh TEXT;
    v_cat TEXT;
    v_polarity VARCHAR(8);
BEGIN
    -- 1. DELETE
    IF (TG_OP = 'DELETE') THEN
        DELETE FROM public.hisaab_adjustments_ledger
        WHERE remarks LIKE 'CORE_ADJ:' || OLD.adjustment_id || '%'
           OR (vehicle_number = OLD.vehicle_number AND partner_id = OLD.partner_id AND incident_date = OLD.adjustment_date AND amount = OLD.amount);
        RETURN OLD;
    END IF;

    -- 2. Soft-deleted or Unapproved / Rejected -> Remove from hisaab ledger
    IF (NEW.is_deleted IS TRUE OR NEW.approval_status != 'Approved') THEN
        DELETE FROM public.hisaab_adjustments_ledger
        WHERE remarks LIKE 'CORE_ADJ:' || NEW.adjustment_id || '%'
           OR remarks LIKE 'CORE_ADJ:' || OLD.adjustment_id || '%';
        RETURN NEW;
    END IF;

    -- 3. Approved & Active -> Upsert into hisaab_adjustments_ledger
    v_veh := COALESCE(UPPER(REPLACE(NEW.vehicle_number, ' ', '')), 'UNKNOWN');
    v_cat := COALESCE(NEW.remittance_towards, NEW.adjustment_type, 'General Adjustment');

    -- Compute polarity
    IF (v_cat ILIKE '%remove%' OR v_cat ILIKE '%waiver%' OR v_cat ILIKE '%waive%' OR v_cat ILIKE '%reversal%' OR v_cat ILIKE '%reverse%' OR v_cat ILIKE '%refund%' OR v_cat ILIKE '%rent-off%' OR v_cat ILIKE '%leave%' OR v_cat ILIKE '%service%' OR v_cat ILIKE '%breakdown%' OR v_cat ILIKE '%parking%' OR v_cat ILIKE '%health%' OR v_cat ILIKE '%bonus%' OR v_cat ILIKE '%credit%') THEN
        v_polarity := 'CREDIT';
    ELSIF (v_cat = 'Challan' OR v_cat ILIKE '%fine%' OR v_cat ILIKE '%penalty%' OR v_cat ILIKE '%challan%' OR v_cat ILIKE '%damage%' OR v_cat ILIKE '%violation%' OR v_cat ILIKE '%rto%' OR v_cat ILIKE '%towing%' OR v_cat ILIKE '%accident%' OR v_cat ILIKE '%recovery%' OR v_cat ILIKE '%debit%') THEN
        v_polarity := 'DEBIT';
    ELSE
        v_polarity := 'CREDIT';
    END IF;

    SELECT id INTO v_rec_id
    FROM public.hisaab_adjustments_ledger
    WHERE remarks LIKE 'CORE_ADJ:' || NEW.adjustment_id || '%'
    LIMIT 1;

    IF v_rec_id IS NOT NULL THEN
        UPDATE public.hisaab_adjustments_ledger
        SET amount = NEW.amount,
            incident_date = NEW.adjustment_date,
            vehicle_number = v_veh,
            partner_id = NEW.partner_id,
            partner_type = COALESCE(NEW.partner_type, 'Individual'),
            adjustment_category = v_cat,
            polarity = v_polarity,
            approval_status = NEW.approval_status,
            approved_by = NEW.approved_by,
            reference_doc_url = NEW.photo_url,
            remarks = 'CORE_ADJ:' || NEW.adjustment_id || ' - ' || COALESCE(NEW.remarks, ''),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_rec_id;
    ELSE
        INSERT INTO public.hisaab_adjustments_ledger (
            incident_date,
            vehicle_number,
            partner_id,
            partner_type,
            adjustment_category,
            polarity,
            amount,
            approval_status,
            approved_by,
            reference_doc_url,
            remarks
        ) VALUES (
            NEW.adjustment_date,
            v_veh,
            NEW.partner_id,
            COALESCE(NEW.partner_type, 'Individual'),
            v_cat,
            v_polarity,
            NEW.amount,
            NEW.approval_status,
            NEW.approved_by,
            NEW.photo_url,
            'CORE_ADJ:' || NEW.adjustment_id || ' - ' || COALESCE(NEW.remarks, '')
        );
    END IF;

    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_sync_core_to_hisaab_challans
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_core_to_hisaab_challans()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
    DECLARE
        v_rec_id BIGINT;
        v_veh TEXT;
        v_notice TEXT;
    BEGIN
        v_notice := COALESCE(CASE WHEN TG_OP = 'DELETE' THEN OLD.notice_no ELSE NEW.notice_no END, 'UNKNOWN');

        IF (TG_OP = 'DELETE') THEN
            DELETE FROM public.hisaab_adjustments_ledger
            WHERE remarks LIKE 'CHALLAN:' || v_notice || '%';
            RETURN OLD;
        END IF;

        IF (NEW.payment_status = 'PAID' OR NEW.is_deleted = TRUE) THEN
            DELETE FROM public.hisaab_adjustments_ledger
            WHERE remarks LIKE 'CHALLAN:' || v_notice || '%';
            RETURN NEW;
        END IF;

        v_veh := COALESCE(UPPER(REPLACE(NEW.vehicle_reg_no, ' ', '')), 'UNKNOWN');

        SELECT id INTO v_rec_id
        FROM public.hisaab_adjustments_ledger
        WHERE remarks LIKE 'CHALLAN:' || v_notice || '%'
        LIMIT 1;

        IF v_rec_id IS NOT NULL THEN
            UPDATE public.hisaab_adjustments_ledger
            SET amount = COALESCE(NEW.challan_amount, 0.00),
                incident_date = NEW.violation_date,
                vehicle_number = v_veh,
                partner_id = NULL,
                partner_type = 'Individual',
                adjustment_category = 'Challan',
                polarity = 'DEBIT',
                approval_status = 'Approved',
                reference_doc_url = NEW.challan_image_url,
                remarks = 'CHALLAN:' || v_notice || ' - ' || COALESCE(NEW.violation_description, ''),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = v_rec_id;
        ELSE
            INSERT INTO public.hisaab_adjustments_ledger (
                incident_date,
                vehicle_number,
                partner_id,
                partner_type,
                adjustment_category,
                polarity,
                amount,
                approval_status,
                reference_doc_url,
                remarks
            ) VALUES (
                NEW.violation_date,
                v_veh,
                NULL,
                'Individual',
                'Challan',
                'DEBIT',
                COALESCE(NEW.challan_amount, 0.00),
                'Approved',
                NEW.challan_image_url,
                'CHALLAN:' || v_notice || ' - ' || COALESCE(NEW.violation_description, '')
            );
        END IF;

        RETURN NEW;
    END;
    $function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_trg_sync_hisaab_from_rent
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_rent()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.fn_sync_hisaab_daily_upsert(NEW.log_date, NEW.vehicle_number, NEW.partner_id);
    IF TG_OP = 'UPDATE' THEN
        IF (OLD.log_date <> NEW.log_date OR OLD.vehicle_number <> NEW.vehicle_number OR OLD.partner_id <> NEW.partner_id) THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.log_date, OLD.vehicle_number, OLD.partner_id);
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_trg_sync_hisaab_from_uber
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_uber()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.fn_sync_hisaab_daily_upsert(NEW.operational_date, NEW.vehicle_number, NEW.vendor_code);
    IF TG_OP = 'UPDATE' THEN
        IF (OLD.operational_date <> NEW.operational_date OR OLD.vehicle_number <> NEW.vehicle_number OR COALESCE(OLD.vendor_code, '') <> COALESCE(NEW.vendor_code, '')) THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.operational_date, OLD.vehicle_number, OLD.vendor_code);
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_trg_sync_hisaab_from_uber_weekly
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_uber_weekly()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    r RECORD;
    v_week_end DATE;
BEGIN
    SELECT week_end INTO v_week_end FROM public.hisaab_settlement_weeks WHERE week_id = NEW.week_id;
    IF v_week_end IS NULL THEN
        PERFORM public.fn_ensure_hisaab_week(NEW.week_id, NULL);
        SELECT week_end INTO v_week_end FROM public.hisaab_settlement_weeks WHERE week_id = NEW.week_id;
    END IF;

    FOR r IN 
        SELECT DISTINCT partner_id 
        FROM public.hisaab_daily_ledger 
        WHERE week_id = NEW.week_id AND vehicle_number = NEW.vehicle_number
        UNION
        SELECT partner_id 
        FROM public.core_rent 
        WHERE vehicle_number = NEW.vehicle_number AND is_active = TRUE
    LOOP
        IF v_week_end IS NOT NULL THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(v_week_end, NEW.vehicle_number, r.partner_id);
        END IF;
        CALL public.sp_sync_hisaab_vehicle_weekly(NEW.week_id, NEW.vehicle_number, r.partner_id);
        CALL public.sp_sync_hisaab_partner_weekly(NEW.week_id, r.partner_id);
    END LOOP;
    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_trg_sync_hisaab_from_ola
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_ola()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.fn_sync_hisaab_daily_upsert(NEW.service_date, NEW.vehicle_number, NULL);
    IF TG_OP = 'UPDATE' THEN
        IF (OLD.service_date <> NEW.service_date OR OLD.vehicle_number <> NEW.vehicle_number) THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.service_date, OLD.vehicle_number, NULL);
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_trg_sync_hisaab_from_ola_weekly
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_ola_weekly()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    r RECORD;
    v_week_end DATE;
BEGIN
    SELECT week_end INTO v_week_end FROM public.hisaab_settlement_weeks WHERE week_id = NEW.week_id;
    IF v_week_end IS NULL THEN
        PERFORM public.fn_ensure_hisaab_week(NEW.week_id, NULL);
        SELECT week_end INTO v_week_end FROM public.hisaab_settlement_weeks WHERE week_id = NEW.week_id;
    END IF;

    FOR r IN 
        SELECT DISTINCT partner_id 
        FROM public.hisaab_daily_ledger 
        WHERE week_id = NEW.week_id AND vehicle_number = NEW.vehicle_number
        UNION
        SELECT partner_id 
        FROM public.core_rent 
        WHERE vehicle_number = NEW.vehicle_number AND is_active = TRUE
    LOOP
        IF v_week_end IS NOT NULL THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(v_week_end, NEW.vehicle_number, r.partner_id);
        END IF;
        CALL public.sp_sync_hisaab_vehicle_weekly(NEW.week_id, NEW.vehicle_number, r.partner_id);
        CALL public.sp_sync_hisaab_partner_weekly(NEW.week_id, r.partner_id);
    END LOOP;
    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_sync_hisaab_from_gps
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_hisaab_from_gps()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_week_id VARCHAR;
    v_is_locked BOOLEAN;
BEGIN
    SELECT week_id, is_locked INTO v_week_id, v_is_locked
    FROM public.hisaab_settlement_weeks
    WHERE NEW.record_date BETWEEN week_start AND week_end
    LIMIT 1;

    IF v_week_id IS NOT NULL AND v_is_locked = FALSE THEN
        CALL public.sp_sync_hisaab_vehicle_weekly(v_week_id, NEW.vehicle_number, NULL);
    END IF;

    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Definition: fn_prevent_unauthorized_week_unlock
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_prevent_unauthorized_week_unlock()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF current_setting('hisaab.enforcing_lock', true) = 'true' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.is_locked = TRUE AND NEW.is_locked = FALSE THEN
        RAISE EXCEPTION 'Settlement week % is LOCKED. Unlocking requires admin session authorization (hisaab.enforcing_lock).', OLD.week_id;
    END IF;

    IF TG_OP = 'DELETE' AND OLD.is_locked = TRUE THEN
        RAISE EXCEPTION 'Settlement week % is LOCKED and cannot be deleted.', OLD.week_id;
    END IF;

    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

-- ============================================================================
-- TRIGGER ATTACHMENTS ACROSS HISAAB & CORE TABLES
-- ============================================================================

-- 1. hisaab_settlement_weeks lock guard
DROP TRIGGER IF EXISTS trg_hisaab_week_lock_guard ON public.hisaab_settlement_weeks;
CREATE TRIGGER trg_hisaab_week_lock_guard
BEFORE UPDATE OR DELETE ON public.hisaab_settlement_weeks
FOR EACH ROW EXECUTE FUNCTION public.fn_prevent_unauthorized_week_unlock();

-- 2. hisaab_adjustments_ledger triggers
DROP TRIGGER IF EXISTS trg_auto_route_prior_period_adjustment ON public.hisaab_adjustments_ledger;
CREATE TRIGGER trg_auto_route_prior_period_adjustment
BEFORE INSERT ON public.hisaab_adjustments_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_auto_route_prior_period_adjustment();

DROP TRIGGER IF EXISTS trg_check_hisaab_adj_lock ON public.hisaab_adjustments_ledger;
CREATE TRIGGER trg_check_hisaab_adj_lock
BEFORE UPDATE OR DELETE ON public.hisaab_adjustments_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_prevent_locked_adjustment_update();

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_adj ON public.hisaab_adjustments_ledger;
CREATE TRIGGER trg_sync_hisaab_from_adj
AFTER INSERT OR UPDATE OR DELETE ON public.hisaab_adjustments_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_adj();

-- 3. hisaab_daily_ledger triggers
DROP TRIGGER IF EXISTS trg_check_hisaab_daily_lock ON public.hisaab_daily_ledger;
CREATE TRIGGER trg_check_hisaab_daily_lock
BEFORE INSERT OR UPDATE OR DELETE ON public.hisaab_daily_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_prevent_locked_hisaab_update();

DROP TRIGGER IF EXISTS trg_cascade_daily_to_weekly ON public.hisaab_daily_ledger;
CREATE TRIGGER trg_cascade_daily_to_weekly
AFTER INSERT OR UPDATE ON public.hisaab_daily_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_cascade_daily_to_weekly();

-- 4. hisaab_vehicle_weekly triggers
DROP TRIGGER IF EXISTS trg_check_hisaab_vehicle_lock ON public.hisaab_vehicle_weekly;
CREATE TRIGGER trg_check_hisaab_vehicle_lock
BEFORE INSERT OR UPDATE OR DELETE ON public.hisaab_vehicle_weekly
FOR EACH ROW EXECUTE FUNCTION public.fn_prevent_frozen_vehicle_weekly_update();

-- 5. hisaab_partner_weekly triggers
DROP TRIGGER IF EXISTS trg_check_hisaab_partner_lock ON public.hisaab_partner_weekly;
CREATE TRIGGER trg_check_hisaab_partner_lock
BEFORE INSERT OR UPDATE OR DELETE ON public.hisaab_partner_weekly
FOR EACH ROW EXECUTE FUNCTION public.fn_prevent_frozen_partner_weekly_update();

-- 6. Upstream sync triggers from Core tables
DROP TRIGGER IF EXISTS trg_sync_core_adjustments ON public.core_adjustments;
CREATE TRIGGER trg_sync_core_adjustments
AFTER INSERT OR UPDATE OR DELETE ON public.core_adjustments
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_to_hisaab_adjustments();

DROP TRIGGER IF EXISTS trg_sync_core_challans ON public.core_challans;
CREATE TRIGGER trg_sync_core_challans
AFTER INSERT OR UPDATE OR DELETE ON public.core_challans
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_core_to_hisaab_challans();

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_rent ON public.daily_rent_log;
CREATE TRIGGER trg_sync_hisaab_from_rent
AFTER INSERT OR UPDATE ON public.daily_rent_log
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_rent();

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_uber ON public.core_uber_daily;
CREATE TRIGGER trg_sync_hisaab_from_uber
AFTER INSERT OR UPDATE ON public.core_uber_daily
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_uber();

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_uber_weekly ON public.core_uber_weekly;
CREATE TRIGGER trg_sync_hisaab_from_uber_weekly
AFTER INSERT OR UPDATE ON public.core_uber_weekly
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_uber_weekly();

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_ola ON public.core_ola_daily;
CREATE TRIGGER trg_sync_hisaab_from_ola
AFTER INSERT OR UPDATE ON public.core_ola_daily
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_ola();

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_ola_weekly ON public.core_ola_weekly;
CREATE TRIGGER trg_sync_hisaab_from_ola_weekly
AFTER INSERT OR UPDATE ON public.core_ola_weekly
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_ola_weekly();

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_gps ON public.core_gps;
CREATE TRIGGER trg_sync_hisaab_from_gps
AFTER INSERT OR UPDATE ON public.core_gps
FOR EACH ROW EXECUTE FUNCTION public.fn_sync_hisaab_from_gps();
