-- ============================================================================
-- HISAAB INTERNAL AUTOMATION ENGINE & REAL-TIME TRIGGER ARCHITECTURE
-- Database: PostgreSQL 14+
-- Module: LetzRyd Hisaab Engine (Daily Shift -> Vehicle Weekly -> Partner Payout)
-- File: backend/Hisaab Final Table/triggers.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. HELPER: fn_ensure_hisaab_week
-- Ensures a settlement week entry exists in hisaab_settlement_weeks.
-- Parses ISO week format (e.g. CY26WK36 or 2026-W36) or calculates from log_date.
-- Hard lock cutoff: Monday 11:00:00 AM IST following the week_end (Sunday).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ensure_hisaab_week(
    p_week_id VARCHAR DEFAULT NULL,
    p_log_date DATE DEFAULT NULL
) RETURNS VARCHAR AS $$
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
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- 2. CORE PROCEDURAL FUNCTION: fn_sync_hisaab_daily_upsert
-- Core procedural logic merging:
--   - public.daily_rent_log (attendance, billable status, lease rent, indemnity)
--   - public.core_uber_daily (completed trips, fare earnings, cash collected, tolls, subscription)
--   - public.core_ola_daily (completed trips, operator bill, cash collected, tolls, online payouts)
--   - public.hisaab_adjustments_ledger (in-week approved challans, damages, adjustments)
--   - public.core_uber_weekly & core_ola_weekly (milestone incentive credited on Sunday shift)
-- Calculates daily_net_balance for mobile app live feed.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sync_hisaab_daily_upsert(
    p_log_date DATE,
    p_vehicle VARCHAR,
    p_partner VARCHAR DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_week_id VARCHAR;
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_is_locked BOOLEAN;
    v_partner_record RECORD;
    v_found_partners BOOLEAN := FALSE;
    
    -- Local variables for calculated metrics
    v_target_partner VARCHAR := p_partner;
    v_partner_type VARCHAR;
    v_city VARCHAR;
    v_vehicle_model VARCHAR;
    v_attendance_status VARCHAR;
    v_is_billable_day BOOLEAN;
    v_daily_rent_applied NUMERIC(12,2) := 0.00;
    v_daily_indemnity_fee NUMERIC(12,2) := 0.00;
    v_net_daily_rent NUMERIC(12,2) := 0.00;

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

    v_daily_adjustments NUMERIC(12,2) := 0.00;
    v_daily_challans NUMERIC(12,2) := 0.00;
    v_daily_accident_recovery NUMERIC(12,2) := 0.00;
    v_weekly_incentive_credit NUMERIC(12,2) := 0.00;
    v_daily_net_balance NUMERIC(12,2) := 0.00;
BEGIN
    IF p_log_date IS NULL OR p_vehicle IS NULL THEN
        RETURN;
    END IF;

    -- 1. Ensure settlement week exists and check lock status
    v_week_id := public.fn_ensure_hisaab_week(NULL, p_log_date);
    SELECT is_locked, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = v_week_id;

    IF v_is_locked = TRUE THEN
        RETURN; -- Settlement week is frozen; immutable
    END IF;

    -- 2. Partner Resolution:
    -- If p_partner is not specified or not in daily_rent_log, resolve all partners linked to this vehicle on this date
    IF v_target_partner IS NULL OR v_target_partner = '' THEN
        FOR v_partner_record IN
            SELECT DISTINCT partner_id FROM (
                SELECT partner_id FROM public.daily_rent_log WHERE log_date = p_log_date AND vehicle_number = p_vehicle
                UNION
                SELECT partner_id FROM public.hisaab_daily_ledger WHERE log_date = p_log_date AND vehicle_number = p_vehicle
                UNION
                SELECT partner_id FROM public.hisaab_adjustments_ledger WHERE incident_date = p_log_date AND vehicle_number = p_vehicle
                UNION
                SELECT partner_id FROM public.core_rent WHERE vehicle_number = p_vehicle AND is_active = TRUE
            ) sub WHERE partner_id IS NOT NULL AND partner_id <> ''
        LOOP
            v_found_partners := TRUE;
            PERFORM public.fn_sync_hisaab_daily_upsert(p_log_date, p_vehicle, v_partner_record.partner_id);
        END LOOP;

        IF v_found_partners THEN
            RETURN;
        END IF;

        -- Fallback if no partner found anywhere
        v_target_partner := 'UNKNOWN';
    END IF;

    -- 3. Attendance & Rent (daily_rent_log)
    SELECT 
        r.city,
        r.vehicle_model,
        r.attendance_status,
        r.is_billable_day,
        COALESCE(r.applied_daily_rent, 0.00),
        COALESCE(r.applied_daily_indemnity, 0.00),
        COALESCE(r.net_daily_rent, 0.00)
    INTO 
        v_city,
        v_vehicle_model,
        v_attendance_status,
        v_is_billable_day,
        v_daily_rent_applied,
        v_daily_indemnity_fee,
        v_net_daily_rent
    FROM public.daily_rent_log r
    WHERE r.log_date = p_log_date 
      AND r.vehicle_number = p_vehicle 
      AND r.partner_id = v_target_partner;

    -- Fallback vehicle model and city from core_rent if not in daily_rent_log
    IF v_city IS NULL THEN
        SELECT city, vehicle_model INTO v_city, v_vehicle_model 
        FROM public.core_rent 
        WHERE vehicle_number = p_vehicle 
        ORDER BY is_active DESC NULLS LAST, id DESC 
        LIMIT 1;
    END IF;

    -- Determine partner type: Operator vs Individual
    IF v_target_partner ILIKE '%IP%' OR v_target_partner ILIKE '%OP%' THEN
        v_partner_type := 'Operator';
    ELSE
        v_partner_type := 'Individual';
    END IF;

    -- 4. Uber Telemetry (core_uber_daily)
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

    -- 5. Ola Telemetry (core_ola_daily)
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

    -- 6. In-Week Adjustments & Challans (hisaab_adjustments_ledger)
    SELECT 
        COALESCE(SUM(CASE WHEN adjustment_category = 'Challan' THEN amount ELSE 0 END), 0.00),
        COALESCE(SUM(CASE WHEN adjustment_category = 'Accident Damage' THEN amount ELSE 0 END), 0.00),
        COALESCE(SUM(CASE WHEN adjustment_category NOT IN ('Challan', 'Accident Damage') THEN amount ELSE 0 END), 0.00)
    INTO 
        v_daily_challans,
        v_daily_accident_recovery,
        v_daily_adjustments
    FROM public.hisaab_adjustments_ledger
    WHERE incident_date = p_log_date 
      AND vehicle_number = p_vehicle 
      AND partner_id = v_target_partner
      AND settlement_week_id = v_week_id
      AND approval_status = 'Approved';

    -- 7. Sunday Milestone Incentives Credit
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

    -- 8. Daily Net Balance Calculation:
    -- Net Daily Rent + ABS(Cash Collected) - Digital Fare Earnings - Online Pay + Challans/Damages/Adjustments - Incentive
    v_daily_net_balance := 
        COALESCE(v_net_daily_rent, 0.00)
        + (ABS(COALESCE(v_uber_cash_collected, 0.00)) + ABS(COALESCE(v_ola_cash_collected, 0.00)))
        - (COALESCE(v_uber_fare_earnings, 0.00) + COALESCE(v_ola_net_revenue, 0.00))
        - COALESCE(v_ola_online_payment, 0.00)
        + COALESCE(v_daily_challans, 0.00)
        + COALESCE(v_daily_accident_recovery, 0.00)
        + COALESCE(v_daily_adjustments, 0.00)
        - COALESCE(v_weekly_incentive_credit, 0.00);

    -- 9. Upsert into hisaab_daily_ledger
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
        COALESCE(v_city, 'Unknown'),
        v_vehicle_model,
        COALESCE(v_attendance_status, 'Active'),
        COALESCE(v_is_billable_day, TRUE),
        COALESCE(v_daily_rent_applied, 0.00),
        COALESCE(v_daily_indemnity_fee, 0.00),
        COALESCE(v_net_daily_rent, 0.00),
        COALESCE(v_uber_trips, 0),
        COALESCE(v_uber_fare_earnings, 0.00),
        COALESCE(v_uber_cash_collected, 0.00),
        COALESCE(v_uber_tolls, 0.00),
        COALESCE(v_uber_subscription_charge, 0.00),
        COALESCE(v_ola_trips, 0),
        COALESCE(v_ola_net_revenue, 0.00),
        COALESCE(v_ola_cash_collected, 0.00),
        COALESCE(v_ola_tolls, 0.00),
        COALESCE(v_ola_online_payment, 0.00),
        COALESCE(v_daily_adjustments, 0.00),
        COALESCE(v_daily_challans, 0.00),
        COALESCE(v_daily_accident_recovery, 0.00),
        COALESCE(v_weekly_incentive_credit, 0.00),
        COALESCE(v_daily_net_balance, 0.00),
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
        daily_adjustments = EXCLUDED.daily_adjustments,
        daily_challans = EXCLUDED.daily_challans,
        daily_accident_recovery = EXCLUDED.daily_accident_recovery,
        weekly_incentive_credit = EXCLUDED.weekly_incentive_credit,
        daily_net_balance = EXCLUDED.daily_net_balance,
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_daily_ledger.is_locked = FALSE;

END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- 3. WEEKLY ROLL-UP PROCEDURE: sp_sync_hisaab_vehicle_weekly
-- Mirrors 1-to-1 Excel 'Uber + OLA Final Hisaab' sheet.
-- Aggregates hisaab_daily_ledger to hisaab_vehicle_weekly.
-- Parameters:
--   p_week_id: Target week (e.g. 'CY26WK36')
--   p_vehicle: Vehicle registration (NULL for all vehicles in week)
--   p_partner: Partner code (NULL for all partners in week)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_vehicle_weekly(
    p_week_id VARCHAR,
    p_vehicle VARCHAR DEFAULT NULL,
    p_partner VARCHAR DEFAULT NULL
) LANGUAGE plpgsql AS $$
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

    -- Ensure week exists
    PERFORM public.fn_ensure_hisaab_week(p_week_id, NULL);
    SELECT is_locked, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = p_week_id;

    IF v_is_locked = TRUE THEN
        RETURN; -- Locked week cannot be recalculated
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
            COALESCE(SUM(d.ola_tolls), 0.00) AS ola_toll,
            COALESCE(SUM(d.ola_online_payment), 0.00) AS ola_online_payment,
            COALESCE(SUM(d.rapido_trips), 0)::INT AS rapido_trips,
            COALESCE(SUM(d.rapido_net_revenue), 0.00) AS rapido_net_revenue,
            COALESCE(SUM(d.weekly_incentive_credit), 0.00) AS weekly_platform_incentive,
            COALESCE(SUM(d.daily_adjustments), 0.00) AS vehicle_adjustments,
            COALESCE(SUM(d.daily_challans), 0.00) AS challan_amount,
            COALESCE(SUM(d.daily_accident_recovery), 0.00) AS accident_penalties
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
        ola_toll,
        ola_gst,
        ola_online_payment,
        ola_week_os,
        rapido_trips,
        rapido_net_revenue,
        weekly_platform_incentive,
        vehicle_adjustments,
        challan_amount,
        accident_penalties,
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
        d.week_id,
        v_week_start,
        v_week_end,
        d.vehicle_number,
        d.partner_id,
        COALESCE(dr.full_name, d.partner_id) AS partner_name,
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
        -- uber_week_os = -(Total Earnings - Cash Collection + Toll - Sub Charge)
        -(d.uber_total_earnings - ABS(d.uber_cash_collection) + d.uber_toll - d.uber_driver_sub_charge) AS uber_week_os,
        d.ola_trips,
        d.ola_net_revenue,
        d.ola_toll,
        CASE WHEN d.city = 'BLR' OR d.city ILIKE '%Bengaluru%' THEN ROUND(d.ola_net_revenue * 0.05, 2) ELSE 0.00 END AS ola_gst,
        d.ola_online_payment,
        -(d.ola_online_payment) AS ola_week_os,
        d.rapido_trips,
        d.rapido_net_revenue,
        d.weekly_platform_incentive,
        d.vehicle_adjustments,
        d.challan_amount,
        d.accident_penalties,
        0.00 AS dead_mile_charges,
        -- TDS 1% for Individual Drivers if Net Earnings > Rent
        CASE 
            WHEN d.partner_type = 'Operator' THEN 0.00
            WHEN (d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) > 0 
            THEN ROUND((d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
            ELSE 0.00 
        END AS tds_amount,
        -- Current Week Outstanding
        (
            d.net_weekly_lease_rental
            - (d.uber_total_earnings - ABS(d.uber_cash_collection) + d.uber_toll - d.uber_driver_sub_charge)
            - d.ola_online_payment
            - d.weekly_platform_incentive
            + d.vehicle_adjustments
            + d.challan_amount
            + d.accident_penalties
            + (CASE 
                WHEN d.partner_type = 'Operator' THEN 0.00
                WHEN (d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) > 0 
                THEN ROUND((d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
                ELSE 0.00 
               END)
        ) AS current_week_os,
        GREATEST(0, (
            d.net_weekly_lease_rental
            - (d.uber_total_earnings - ABS(d.uber_cash_collection) + d.uber_toll - d.uber_driver_sub_charge)
            - d.ola_online_payment
            - d.weekly_platform_incentive
            + d.vehicle_adjustments
            + d.challan_amount
            + d.accident_penalties
            + (CASE 
                WHEN d.partner_type = 'Operator' THEN 0.00
                WHEN (d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) > 0 
                THEN ROUND((d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
                ELSE 0.00 
               END)
        )) AS to_collect,
        ABS(LEAST(0, (
            d.net_weekly_lease_rental
            - (d.uber_total_earnings - ABS(d.uber_cash_collection) + d.uber_toll - d.uber_driver_sub_charge)
            - d.ola_online_payment
            - d.weekly_platform_incentive
            + d.vehicle_adjustments
            + d.challan_amount
            + d.accident_penalties
            + (CASE 
                WHEN d.partner_type = 'Operator' THEN 0.00
                WHEN (d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) > 0 
                THEN ROUND((d.uber_total_earnings + d.ola_net_revenue - d.net_weekly_lease_rental) * 0.01, 2)
                ELSE 0.00 
               END)
        ))) AS to_payout,
        (d.net_weekly_lease_rental + d.vehicle_adjustments - d.challan_amount) AS letzryd_earning,
        CASE WHEN d.onroad_days > 0 THEN ROUND((d.net_weekly_lease_rental + d.vehicle_adjustments - d.challan_amount) / d.onroad_days, 2) ELSE 0.00 END AS letzryd_earning_per_day,
        'OPEN' AS settlement_status,
        CURRENT_TIMESTAMP AS updated_at
    FROM daily_agg d
    LEFT JOIN LATERAL (
        SELECT partner_id, plan_scheme FROM public.core_rent 
        WHERE vehicle_number = d.vehicle_number 
        ORDER BY is_active DESC NULLS LAST, id DESC LIMIT 1
    ) p ON TRUE
    LEFT JOIN LATERAL (
        SELECT full_name FROM public.drivers 
        WHERE driver_code = d.partner_id LIMIT 1
    ) dr ON TRUE
    ON CONFLICT (week_id, vehicle_number, partner_id) DO UPDATE SET
        partner_name = EXCLUDED.partner_name,
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
        ola_toll = EXCLUDED.ola_toll,
        ola_gst = EXCLUDED.ola_gst,
        ola_online_payment = EXCLUDED.ola_online_payment,
        ola_week_os = EXCLUDED.ola_week_os,
        rapido_trips = EXCLUDED.rapido_trips,
        rapido_net_revenue = EXCLUDED.rapido_net_revenue,
        weekly_platform_incentive = EXCLUDED.weekly_platform_incentive,
        vehicle_adjustments = EXCLUDED.vehicle_adjustments,
        challan_amount = EXCLUDED.challan_amount,
        accident_penalties = EXCLUDED.accident_penalties,
        tds_amount = EXCLUDED.tds_amount,
        current_week_os = EXCLUDED.current_week_os,
        to_collect = EXCLUDED.to_collect,
        to_payout = EXCLUDED.to_payout,
        letzryd_earning = EXCLUDED.letzryd_earning,
        letzryd_earning_per_day = EXCLUDED.letzryd_earning_per_day,
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_vehicle_weekly.settlement_status = 'OPEN';

END;
$$;


-- ----------------------------------------------------------------------------
-- 4. PARTNER CONSOLIDATED PAYOUT PROCEDURE: sp_sync_hisaab_partner_weekly
-- Mirrors 1-to-1 Excel 'Hisaab Summary' / 'Revised Hisaab Summary'.
-- Consolidates all vehicle performances into a single partner settlement statement.
-- Factors in:
--   - opening balance from previous week
--   - mid-week collections
--   - prior-period adjustments routed from locked weeks
--   - bank payout account details from drivers registry
-- Parameters:
--   p_week_id: Target week (e.g. 'CY26WK36')
--   p_partner: Partner code (NULL for all partners in week)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_sync_hisaab_partner_weekly(
    p_week_id VARCHAR,
    p_partner VARCHAR DEFAULT NULL
) LANGUAGE plpgsql AS $$
DECLARE
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_is_locked BOOLEAN;
    v_prev_week_id VARCHAR;
    v_prev_week_end DATE;
BEGIN
    IF p_week_id IS NULL THEN
        RETURN;
    END IF;

    -- Ensure week exists
    PERFORM public.fn_ensure_hisaab_week(p_week_id, NULL);
    SELECT is_locked, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = p_week_id;

    IF v_is_locked = TRUE THEN
        RETURN; -- Locked week cannot be recalculated
    END IF;

    -- Calculate previous week ID
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
            SUM(ABS(v.uber_cash_collection) + ABS(v.ola_online_payment)) AS total_cash_collected,
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
            SUM(amount) AS prior_period_adjustments
        FROM public.hisaab_adjustments_ledger
        WHERE settlement_week_id = p_week_id 
          AND is_prior_period = TRUE
          AND approval_status = 'Approved'
          AND (p_partner IS NULL OR partner_id = p_partner)
        GROUP BY partner_id
    ),
    prev_dues AS (
        SELECT 
            partner_id,
            total_outstanding AS previous_outstanding
        FROM public.hisaab_partner_weekly
        WHERE week_id = v_prev_week_id
          AND (p_partner IS NULL OR partner_id = p_partner)
    ),
    all_partners AS (
        SELECT partner_id FROM veh_summary
        UNION
        SELECT partner_id FROM prior_adj
        UNION
        SELECT partner_id FROM prev_dues
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
        COALESCE(v.partner_name, dr.full_name, ap.partner_id) AS partner_name,
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
        0.00 AS amount_paid_during_week,
        COALESCE(pa.prior_period_adjustments, 0.00) AS prior_period_adjustments,
        5000.00 AS security_deposit_target,
        5000.00 AS security_deposit_paid,
        0.00 AS deposit_deduction_current_week,
        0.00 AS pending_deposit,
        (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00)) AS total_outstanding,
        ABS(LEAST(0, (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00)))) AS net_bank_payout,
        GREATEST(0, (COALESCE(v.current_week_os, 0.00) + COALESCE(pd.previous_outstanding, 0.00) + COALESCE(pa.prior_period_adjustments, 0.00))) AS net_amount_to_collect,
        'DRAFT' AS settlement_status,
        dr.account_no AS payout_account_number,
        dr.ifsc_code AS payout_ifsc,
        CURRENT_TIMESTAMP AS updated_at
    FROM all_partners ap
    LEFT JOIN veh_summary v ON ap.partner_id = v.partner_id
    LEFT JOIN prior_adj pa ON ap.partner_id = pa.partner_id
    LEFT JOIN prev_dues pd ON ap.partner_id = pd.partner_id
    LEFT JOIN LATERAL (
        SELECT account_no, ifsc_code, full_name FROM public.drivers 
        WHERE driver_code = ap.partner_id LIMIT 1
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
        total_outstanding = EXCLUDED.total_outstanding,
        net_bank_payout = EXCLUDED.net_bank_payout,
        net_amount_to_collect = EXCLUDED.net_amount_to_collect,
        payout_account_number = COALESCE(EXCLUDED.payout_account_number, public.hisaab_partner_weekly.payout_account_number),
        payout_ifsc = COALESCE(EXCLUDED.payout_ifsc, public.hisaab_partner_weekly.payout_ifsc),
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_partner_weekly.settlement_status = 'DRAFT';

END;
$$;


-- ----------------------------------------------------------------------------
-- 5. CASCADE TRIGGER: trg_cascade_daily_to_weekly
-- Attached to public.hisaab_daily_ledger.
-- Whenever a daily shift record is inserted or updated:
--   - Automatically invokes sp_sync_hisaab_vehicle_weekly for that vehicle & partner
--   - Automatically invokes sp_sync_hisaab_partner_weekly for that partner
-- Supports session setting 'hisaab.skip_cascade' to allow high-speed batch loads.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_trg_cascade_daily_to_weekly()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_cascade_daily_to_weekly ON public.hisaab_daily_ledger;
CREATE TRIGGER trg_cascade_daily_to_weekly
AFTER INSERT OR UPDATE ON public.hisaab_daily_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_cascade_daily_to_weekly();


-- ----------------------------------------------------------------------------
-- 6. SOURCE AUTOMATION TRIGGERS
-- ----------------------------------------------------------------------------

-- A. DAILY RENT LOG TRIGGER: trg_sync_hisaab_from_rent
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_rent()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM public.fn_sync_hisaab_daily_upsert(NEW.log_date, NEW.vehicle_number, NEW.partner_id);
    IF TG_OP = 'UPDATE' THEN
        IF (OLD.log_date <> NEW.log_date OR OLD.vehicle_number <> NEW.vehicle_number OR OLD.partner_id <> NEW.partner_id) THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.log_date, OLD.vehicle_number, OLD.partner_id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_rent ON public.daily_rent_log;
CREATE TRIGGER trg_sync_hisaab_from_rent
AFTER INSERT OR UPDATE ON public.daily_rent_log
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_rent();


-- B. UBER DAILY FEED TRIGGER: trg_sync_hisaab_from_uber
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_uber()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM public.fn_sync_hisaab_daily_upsert(NEW.operational_date, NEW.vehicle_number, NEW.vendor_code);
    IF TG_OP = 'UPDATE' THEN
        IF (OLD.operational_date <> NEW.operational_date OR OLD.vehicle_number <> NEW.vehicle_number OR COALESCE(OLD.vendor_code, '') <> COALESCE(NEW.vendor_code, '')) THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.operational_date, OLD.vehicle_number, OLD.vendor_code);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_uber ON public.core_uber_daily;
CREATE TRIGGER trg_sync_hisaab_from_uber
AFTER INSERT OR UPDATE ON public.core_uber_daily
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_uber();


-- C. OLA DAILY FEED TRIGGER: trg_sync_hisaab_from_ola
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_ola()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM public.fn_sync_hisaab_daily_upsert(NEW.service_date, NEW.vehicle_number, NULL);
    IF TG_OP = 'UPDATE' THEN
        IF (OLD.service_date <> NEW.service_date OR OLD.vehicle_number <> NEW.vehicle_number) THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.service_date, OLD.vehicle_number, NULL);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_ola ON public.core_ola_daily;
CREATE TRIGGER trg_sync_hisaab_from_ola
AFTER INSERT OR UPDATE ON public.core_ola_daily
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_ola();


-- D. HISAAB ADJUSTMENTS LEDGER TRIGGER: trg_sync_hisaab_from_adj
-- Routes in-week adjustments to daily ledger, and prior-period adjustments directly to partner weekly.
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_adj()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_prior_period = FALSE THEN
        PERFORM public.fn_sync_hisaab_daily_upsert(NEW.incident_date, NEW.vehicle_number, NEW.partner_id);
    ELSE
        CALL public.sp_sync_hisaab_partner_weekly(NEW.settlement_week_id, NEW.partner_id);
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.is_prior_period = FALSE THEN
            PERFORM public.fn_sync_hisaab_daily_upsert(OLD.incident_date, OLD.vehicle_number, OLD.partner_id);
        ELSE
            CALL public.sp_sync_hisaab_partner_weekly(OLD.settlement_week_id, OLD.partner_id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_adj ON public.hisaab_adjustments_ledger;
CREATE TRIGGER trg_sync_hisaab_from_adj
AFTER INSERT OR UPDATE ON public.hisaab_adjustments_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_adj();


-- E. UBER WEEKLY INCENTIVE TRIGGER: trg_sync_hisaab_from_uber_weekly
-- When Uber milestone incentive is posted into core_uber_weekly, updates Sunday daily row and weekly hisaabs live.
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_uber_weekly()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_uber_weekly ON public.core_uber_weekly;
CREATE TRIGGER trg_sync_hisaab_from_uber_weekly
AFTER INSERT OR UPDATE ON public.core_uber_weekly
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_uber_weekly();


-- F. OLA WEEKLY INCENTIVE TRIGGER: trg_sync_hisaab_from_ola_weekly
-- When Ola portal milestone incentive is posted into core_ola_weekly, updates Sunday daily row and weekly hisaabs live.
CREATE OR REPLACE FUNCTION public.fn_trg_sync_hisaab_from_ola_weekly()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_hisaab_from_ola_weekly ON public.core_ola_weekly;
CREATE TRIGGER trg_sync_hisaab_from_ola_weekly
AFTER INSERT OR UPDATE ON public.core_ola_weekly
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_sync_hisaab_from_ola_weekly();


-- ----------------------------------------------------------------------------
-- 7. BATCH RECONCILIATION ENGINE: sp_run_full_week_hisaab
-- High-speed set-based reconciliation procedure.
-- Populates and refreshes an entire historical week (10,000+ shifts) in seconds.
-- Steps:
--   1. Ensures settlement week calendar entry exists.
--   2. Sets session parameter 'hisaab.skip_cascade' = 'true' to avoid N row cascade overhead.
--   3. Executes single set-based bulk upsert into hisaab_daily_ledger.
--   4. Executes set-based roll-up into hisaab_vehicle_weekly.
--   5. Executes set-based roll-up into hisaab_partner_weekly.
--   6. Restores session parameter 'hisaab.skip_cascade' = 'false'.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_run_full_week_hisaab(
    p_week_id VARCHAR
) LANGUAGE plpgsql AS $$
DECLARE
    v_week_id VARCHAR;
    v_week_start DATE;
    v_week_end DATE;
    v_year INT;
    v_week_num INT;
    v_is_locked BOOLEAN;
    v_start_time TIMESTAMPTZ := clock_timestamp();
    v_daily_count INT;
    v_veh_count INT;
    v_partner_count INT;
BEGIN
    IF p_week_id IS NULL THEN
        RAISE EXCEPTION 'p_week_id must be provided to sp_run_full_week_hisaab';
    END IF;

    -- Ensure week exists
    v_week_id := public.fn_ensure_hisaab_week(p_week_id, NULL);
    SELECT is_locked, week_start, week_end, settlement_year, settlement_week
    INTO v_is_locked, v_week_start, v_week_end, v_year, v_week_num
    FROM public.hisaab_settlement_weeks
    WHERE week_id = v_week_id;

    IF v_is_locked = TRUE THEN
        RAISE EXCEPTION 'Settlement week % is LOCKED. Immutable history cannot be modified.', v_week_id;
    END IF;

    -- Suppress row-level cascade triggers during batch bulk execution
    PERFORM set_config('hisaab.skip_cascade', 'true', true);

    -- 1. Bulk Upsert into hisaab_daily_ledger for the entire week
    WITH base_rent AS (
        SELECT 
            log_date,
            vehicle_number,
            partner_id,
            city,
            vehicle_model,
            attendance_status,
            is_billable_day,
            applied_daily_rent,
            applied_daily_indemnity,
            net_daily_rent
        FROM public.daily_rent_log
        WHERE log_date BETWEEN v_week_start AND v_week_end
    ),
    uber_agg AS (
        SELECT 
            operational_date,
            vehicle_number,
            SUM(completed_trips) AS uber_trips,
            SUM(net_fare_earnings) AS uber_fare_earnings,
            SUM(cash_collected) AS uber_cash_collected,
            SUM(tolls_refunded) AS uber_tolls,
            SUM(driver_subscription_charge) AS uber_subscription_charge
        FROM public.core_uber_daily
        WHERE operational_date BETWEEN v_week_start AND v_week_end
        GROUP BY operational_date, vehicle_number
    ),
    ola_agg AS (
        SELECT 
            service_date,
            vehicle_number,
            SUM(completed_trips) AS ola_trips,
            SUM(operator_bill) AS ola_net_revenue,
            SUM(cash_collected) AS ola_cash_collected,
            SUM(toll_and_parking) AS ola_tolls,
            SUM(online_payouts) AS ola_online_payment
        FROM public.core_ola_daily
        WHERE service_date BETWEEN v_week_start AND v_week_end
        GROUP BY service_date, vehicle_number
    ),
    adj_agg AS (
        SELECT 
            incident_date,
            vehicle_number,
            partner_id,
            SUM(CASE WHEN adjustment_category = 'Challan' THEN amount ELSE 0 END) AS daily_challans,
            SUM(CASE WHEN adjustment_category = 'Accident Damage' THEN amount ELSE 0 END) AS daily_accidents,
            SUM(CASE WHEN adjustment_category NOT IN ('Challan', 'Accident Damage') THEN amount ELSE 0 END) AS daily_adjustments
        FROM public.hisaab_adjustments_ledger
        WHERE incident_date BETWEEN v_week_start AND v_week_end 
          AND settlement_week_id = v_week_id
          AND approval_status = 'Approved'
        GROUP BY incident_date, vehicle_number, partner_id
    ),
    sunday_inc AS (
        SELECT 
            COALESCE(u.vehicle_number, o.vehicle_number) AS vehicle_number,
            (COALESCE(u.uber_inc, 0) + COALESCE(o.ola_inc, 0)) AS total_inc
        FROM (
            SELECT vehicle_number, SUM(uber_vehicle_incentive) AS uber_inc
            FROM public.core_uber_weekly
            WHERE week_id = v_week_id OR (settlement_year = v_year AND settlement_week = v_week_num)
            GROUP BY vehicle_number
        ) u
        FULL OUTER JOIN (
            SELECT vehicle_number, SUM(ola_portal_incentive) AS ola_inc
            FROM public.core_ola_weekly
            WHERE week_id = v_week_id
            GROUP BY vehicle_number
        ) o ON u.vehicle_number = o.vehicle_number
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
        v_week_id,
        r.vehicle_number,
        r.partner_id,
        CASE WHEN r.partner_id ILIKE '%IP%' OR r.partner_id ILIKE '%OP%' THEN 'Operator' ELSE 'Individual' END,
        COALESCE(r.city, 'Unknown'),
        r.vehicle_model,
        COALESCE(r.attendance_status, 'Active'),
        COALESCE(r.is_billable_day, TRUE),
        COALESCE(r.applied_daily_rent, 0.00),
        COALESCE(r.applied_daily_indemnity, 0.00),
        COALESCE(r.net_daily_rent, 0.00),
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
        COALESCE(a.daily_adjustments, 0.00),
        COALESCE(a.daily_challans, 0.00),
        COALESCE(a.daily_accidents, 0.00),
        CASE WHEN r.log_date = v_week_end THEN COALESCE(sinc.total_inc, 0.00) ELSE 0.00 END AS weekly_incentive_credit,
        (
            COALESCE(r.net_daily_rent, 0.00)
            + (ABS(COALESCE(u.uber_cash_collected, 0.00)) + ABS(COALESCE(o.ola_cash_collected, 0.00)))
            - (COALESCE(u.uber_fare_earnings, 0.00) + COALESCE(o.ola_net_revenue, 0.00))
            - COALESCE(o.ola_online_payment, 0.00)
            + COALESCE(a.daily_challans, 0.00)
            + COALESCE(a.daily_accidents, 0.00)
            + COALESCE(a.daily_adjustments, 0.00)
            - (CASE WHEN r.log_date = v_week_end THEN COALESCE(sinc.total_inc, 0.00) ELSE 0.00 END)
        ) AS daily_net_balance,
        FALSE,
        CURRENT_TIMESTAMP
    FROM base_rent r
    LEFT JOIN uber_agg u ON r.log_date = u.operational_date AND r.vehicle_number = u.vehicle_number
    LEFT JOIN ola_agg o ON r.log_date = o.service_date AND r.vehicle_number = o.vehicle_number
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
        daily_adjustments = EXCLUDED.daily_adjustments,
        daily_challans = EXCLUDED.daily_challans,
        daily_accident_recovery = EXCLUDED.daily_accident_recovery,
        weekly_incentive_credit = EXCLUDED.weekly_incentive_credit,
        daily_net_balance = EXCLUDED.daily_net_balance,
        updated_at = CURRENT_TIMESTAMP
    WHERE public.hisaab_daily_ledger.is_locked = FALSE;

    GET DIAGNOSTICS v_daily_count = ROW_COUNT;

    -- 2. Bulk Roll-up into hisaab_vehicle_weekly
    CALL public.sp_sync_hisaab_vehicle_weekly(v_week_id, NULL, NULL);
    SELECT count(*) INTO v_veh_count FROM public.hisaab_vehicle_weekly WHERE week_id = v_week_id;

    -- 3. Bulk Roll-up into hisaab_partner_weekly
    CALL public.sp_sync_hisaab_partner_weekly(v_week_id, NULL);
    SELECT count(*) INTO v_partner_count FROM public.hisaab_partner_weekly WHERE week_id = v_week_id;

    -- Restore session configuration
    PERFORM set_config('hisaab.skip_cascade', 'false', true);

    RAISE NOTICE 'sp_run_full_week_hisaab complete for % in % ms. Daily rows: %, Vehicles: %, Partners: %',
        v_week_id,
        EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time),
        v_daily_count,
        v_veh_count,
        v_partner_count;
END;
$$;


-- ----------------------------------------------------------------------------
-- 8. MONDAY 11:00 AM LOCK & PRIOR-PERIOD AUTO-ROUTING
-- Hard cutoff: Monday 11:00 AM IST.
-- Automatically freezes weeks, daily shifts, and vehicle/partner weekly statements.
-- Automatically routes late adjustments from locked cycles to the active open settlement week.
-- ----------------------------------------------------------------------------

-- A. Daily Ledger Lock Protection Function & Trigger
CREATE OR REPLACE FUNCTION public.fn_prevent_locked_hisaab_update()
RETURNS TRIGGER AS $$
DECLARE
    v_locked BOOLEAN;
BEGIN
    -- Allow administrative lock enforcement procedure to update records
    IF current_setting('hisaab.enforcing_lock', true) = 'true' THEN
        RETURN NEW;
    END IF;

    -- If row itself is already locked, prevent modifications
    IF OLD.is_locked = TRUE THEN
        RAISE EXCEPTION 'Hisaab daily record % (cycle %) is already LOCKED. No further modifications allowed.', OLD.id, OLD.week_id;
    END IF;

    -- Check if settlement week is locked
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


-- B. Stored Procedure: sp_check_and_enforce_monday_lock
-- Finds any week in hisaab_settlement_weeks where is_locked = FALSE and CURRENT_TIMESTAMP >= lock_cutoff_at.
-- Locks settlement week, daily shifts, vehicle weekly (FROZEN), and partner weekly (FROZEN + frozen_at).
CREATE OR REPLACE PROCEDURE public.sp_check_and_enforce_monday_lock(
    p_target_week_id VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
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
$$;

-- Function wrapper for SQL callers / cron environments
CREATE OR REPLACE FUNCTION public.fn_check_and_enforce_monday_lock(
    p_target_week_id VARCHAR DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_locked_count INT := 0;
BEGIN
    CALL public.sp_check_and_enforce_monday_lock(p_target_week_id);
    SELECT COUNT(*) INTO v_locked_count 
    FROM public.hisaab_settlement_weeks 
    WHERE is_locked = TRUE 
      AND locked_by = 'system_scheduled_cutoff'
      AND (p_target_week_id IS NULL OR week_id = p_target_week_id);
    RETURN v_locked_count;
END;
$$;


-- C. Prior-Period Routing Function & Trigger: trg_auto_route_prior_period_adjustment
-- BEFORE INSERT ON public.hisaab_adjustments_ledger
-- Determines incident_week_id from NEW.incident_date.
-- If week is locked (or past lock_cutoff_at): routes to active open week, sets is_prior_period = TRUE,
-- and appends [Prior Period from {incident_date}] to remarks.
CREATE OR REPLACE FUNCTION public.fn_trg_auto_route_prior_period_adjustment()
RETURNS TRIGGER AS $$
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

    -- 1. Determine incident_week_id from NEW.incident_date (or validate provided incident_week_id)
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
        -- Find the current active open week
        SELECT week_id INTO v_active_week_id
        FROM public.hisaab_settlement_weeks
        WHERE is_locked = FALSE
        ORDER BY week_start DESC
        LIMIT 1;

        IF v_active_week_id IS NULL THEN
            RAISE EXCEPTION 'Cannot route prior-period adjustment: No active open settlement week found in hisaab_settlement_weeks.';
        END IF;

        NEW.settlement_week_id := v_active_week_id;
        NEW.is_prior_period := TRUE;

        -- Append [Prior Period from {incident_date}] to NEW.remarks
        v_prior_tag := '[Prior Period from ' || to_char(NEW.incident_date, 'YYYY-MM-DD') || ']';
        IF NEW.remarks IS NULL OR TRIM(NEW.remarks) = '' THEN
            NEW.remarks := v_prior_tag;
        ELSIF NEW.remarks NOT LIKE '%' || v_prior_tag || '%' THEN
            NEW.remarks := TRIM(NEW.remarks) || ' ' || v_prior_tag;
        END IF;
    ELSE
        NEW.settlement_week_id := v_incident_week_id;
        NEW.is_prior_period := FALSE;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_auto_route_prior_period_adjustment ON public.hisaab_adjustments_ledger;
CREATE TRIGGER trg_auto_route_prior_period_adjustment
BEFORE INSERT ON public.hisaab_adjustments_ledger
FOR EACH ROW EXECUTE FUNCTION public.fn_trg_auto_route_prior_period_adjustment();

-- End of triggers.sql
