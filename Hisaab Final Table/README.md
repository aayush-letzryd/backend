# Hisaab Final Table Architecture & Settlement Engine

## 1. System Mission & Scope

The **Hisaab Final Table** engine is the ultimate financial, operational, and settlement authority for LetzRyd. It bridges real-time vehicle telemetry, daily lease rentals, multi-platform ride revenues (Uber, Ola, Rapido), operational adjustments, and regulatory tax compliance into an automated, audit-proof settlement ledger.

### Key Capabilities:
1. **Multi-Partner Support**:
   - **Individual Drivers**: 1 vehicle, daily mobile app telemetry feed, weekly net payout statement.
   - **Multi-Car Fleet Operators**: 2 to 100+ vehicles, itemized vehicle-by-vehicle breakdown, and a single consolidated bank payout statement.
2. **Mid-Week Vehicle Swaps**: Seamlessly handles drivers switching vehicles mid-week (e.g. Car A Mon–Wed, Car B Thu–Sun) without losing attendance, rent, or trip accuracy.
3. **The Monday 11:00 AM Audit Lock**: Hard freeze cutoff. After Monday 11:00 AM, the closed week becomes immutable (`is_locked = TRUE`).
4. **Prior-Period Roll-Forward**: Retrospective traffic fines or maintenance adjustments for locked past weeks automatically route forward to the active cycle as prior-period adjustments.

---

## 2. Multi-Tier Architecture & Data Flow

```
========================================================================================
                              NORMALIZED CORE DATA SOURCES
========================================================================================
  * daily_rent_log          (Attendance, billable status, applied rent & indemnity)
  * core_uber_daily         (Daily completed trips, fare earnings, cash collected, tolls)
  * core_ola_daily          (Daily completed trips, operator bill, cash, online payouts)
  * hisaab_adjustments_ledger (Approved G-Form tyre, rent-offs, damages, traffic fines)
                                      |
                                      v
========================================================================================
                      TIER 1: DAILY SHIFT GRAIN (DRIVER APP)
========================================================================================
  * public.hisaab_daily_ledger
    - Grain: (log_date, vehicle_number, partner_id)
    - Continuous Upsert: As Ola, Uber, or adjustments arrive, row builds live.
    - Powers Driver Mobile App: Yesterday's trips, earnings, cash collected, rent & balance.
    - Sunday Credit: Milestone target incentives posted on Sunday row (week_end).
                                      |
                                      v
========================================================================================
                   TIER 2: WEEKLY VEHICLE BREAKDOWN (FINAL HISAAB)
========================================================================================
  * public.hisaab_vehicle_weekly
    - Grain: (week_id, vehicle_number, partner_id)
    - 1-to-1 match with Excel 'Uber + OLA Final Hisaab' sheet across BLR, HYD, MUM.
    - Full vehicle breakdown for multi-car fleet operators and mid-week swaps.
    - Calculates vehicle current_week_os, 1% TDS, and company gross margin.
                                      |
                                      v
========================================================================================
              TIER 3: CONSOLIDATED PARTNER PAYOUT STATEMENT (HISAAB SUMMARY)
========================================================================================
  * public.hisaab_partner_weekly
    - Grain: (week_id, partner_id)
    - 1-to-1 match with Excel 'Hisaab Summary' / 'Revised Hisaab Summary'.
    - Sums all vehicles owned by an operator into a single bank payout statement.
    - Incorporates opening dues, mid-week collections, and prior-period adjustments.
    - Monday 11:00 AM: Frozen and pushed to banking / collection teams.
```

---

## 3. The 5 Dedicated Hisaab Tables

| # | Table Name | Grain / Primary Key | Core Purpose |
| :--- | :--- | :--- | :--- |
| **1** | `public.hisaab_settlement_weeks` | `week_id` | Master calendar and **Monday 11:00 AM Lock Switch**. |
| **2** | `public.hisaab_adjustments_ledger` | `id` | Financial adjustment registry & prior-period router. |
| **3** | `public.hisaab_daily_ledger` | `(log_date, vehicle_number, partner_id)` | Real-time daily app feed and pacing tracker. |
| **4** | `public.hisaab_vehicle_weekly` | `(week_id, vehicle_number, partner_id)` | Itemized vehicle breakdown (Uber+Ola Final Hisaab). |
| **5** | `public.hisaab_partner_weekly` | `(week_id, partner_id)` | Final consolidated bank payout statement (Hisaab Summary). |

---

## 4. Production Schemas

### 4.1 `public.hisaab_settlement_weeks`
Controls company billing cycles, week dates, and lock cutoff:
```sql
CREATE TABLE public.hisaab_settlement_weeks (
    week_id VARCHAR(16) PRIMARY KEY,        -- e.g. '2026-W26'
    settlement_year INT NOT NULL,
    settlement_week INT NOT NULL,
    week_start DATE NOT NULL,               -- Monday
    week_end DATE NOT NULL,                 -- Sunday
    lock_cutoff_at TIMESTAMPTZ NOT NULL,    -- Monday 11:00 AM IST
    is_locked BOOLEAN NOT NULL DEFAULT FALSE,
    locked_at TIMESTAMPTZ,
    locked_by VARCHAR(64),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

### 4.2 `public.hisaab_adjustments_ledger`
Captures operational adjustments with automatic prior-period routing:
```sql
CREATE TABLE public.hisaab_adjustments_ledger (
    id BIGSERIAL PRIMARY KEY,
    incident_date DATE NOT NULL,            -- True historical occurrence date
    incident_week_id VARCHAR(16),
    settlement_week_id VARCHAR(16) NOT NULL REFERENCES public.hisaab_settlement_weeks(week_id),
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    partner_type VARCHAR(32) DEFAULT 'Individual',
    adjustment_category VARCHAR(64) NOT NULL, -- 'Challan', 'Rent Off', 'Maintenance/Tyre', 'Accident Damage'
    amount NUMERIC(12,2) NOT NULL,          -- Positive = Deduction; Negative = Reimbursement
    is_prior_period BOOLEAN DEFAULT FALSE,  -- True if incident was in an already-locked week
    approval_status VARCHAR(32) DEFAULT 'Approved',
    remarks TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

### 4.3 `public.hisaab_daily_ledger`
Tier 1 daily shift feed powering mobile apps and daily pacing:
```sql
CREATE TABLE public.hisaab_daily_ledger (
    id BIGSERIAL PRIMARY KEY,
    log_date DATE NOT NULL,                 -- Operational shift (04:00 AM to 04:00 AM)
    week_id VARCHAR(16) NOT NULL REFERENCES public.hisaab_settlement_weeks(week_id),
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    partner_type VARCHAR(32) DEFAULT 'Individual',
    city VARCHAR(32) NOT NULL,
    vehicle_model VARCHAR(64),
    attendance_status VARCHAR(32) DEFAULT 'Active',
    is_billable_day BOOLEAN DEFAULT TRUE,
    daily_rent_applied NUMERIC(12,2) DEFAULT 0.00,
    daily_indemnity_fee NUMERIC(12,2) DEFAULT 0.00,
    net_daily_rent NUMERIC(12,2) DEFAULT 0.00,
    uber_trips INT DEFAULT 0,
    uber_fare_earnings NUMERIC(12,2) DEFAULT 0.00,
    uber_cash_collected NUMERIC(12,2) DEFAULT 0.00,
    uber_tolls NUMERIC(12,2) DEFAULT 0.00,
    uber_subscription_charge NUMERIC(12,2) DEFAULT 0.00,
    ola_trips INT DEFAULT 0,
    ola_net_revenue NUMERIC(12,2) DEFAULT 0.00,
    ola_cash_collected NUMERIC(12,2) DEFAULT 0.00,
    ola_tolls NUMERIC(12,2) DEFAULT 0.00,
    ola_online_payment NUMERIC(12,2) DEFAULT 0.00,
    rapido_trips INT DEFAULT 0,
    rapido_net_revenue NUMERIC(12,2) DEFAULT 0.00,
    daily_adjustments NUMERIC(12,2) DEFAULT 0.00,
    daily_challans NUMERIC(12,2) DEFAULT 0.00,
    daily_accident_recovery NUMERIC(12,2) DEFAULT 0.00,
    weekly_incentive_credit NUMERIC(12,2) DEFAULT 0.00, -- Credited on Sunday row
    daily_net_balance NUMERIC(12,2) DEFAULT 0.00,
    is_locked BOOLEAN DEFAULT FALSE,
    CONSTRAINT uq_hisaab_daily_grain UNIQUE (log_date, vehicle_number, partner_id)
);
```

### 4.4 `public.hisaab_vehicle_weekly`
Tier 2 weekly breakdown per vehicle (1-to-1 match with `Uber + OLA Final Hisaab`):
```sql
CREATE TABLE public.hisaab_vehicle_weekly (
    id BIGSERIAL PRIMARY KEY,
    settlement_year INT NOT NULL,
    settlement_week INT NOT NULL,
    week_id VARCHAR(16) NOT NULL REFERENCES public.hisaab_settlement_weeks(week_id),
    week_start DATE NOT NULL,
    week_end DATE NOT NULL,
    vehicle_number VARCHAR(32) NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    partner_name VARCHAR(128),
    partner_type VARCHAR(32) DEFAULT 'Individual',
    city VARCHAR(32) NOT NULL,
    vehicle_model VARCHAR(64),
    rental_plan VARCHAR(64),
    allotted_days INT DEFAULT 0,
    onroad_days INT DEFAULT 0,
    daily_rent_applied NUMERIC(12,2) DEFAULT 0.00,
    weekly_lease_rental NUMERIC(12,2) DEFAULT 0.00,
    weekly_indemnity_fees NUMERIC(12,2) DEFAULT 0.00,
    net_weekly_lease_rental NUMERIC(12,2) DEFAULT 0.00,
    uber_trips INT DEFAULT 0,
    uber_total_earnings NUMERIC(12,2) DEFAULT 0.00,
    uber_cash_collection NUMERIC(12,2) DEFAULT 0.00,
    uber_toll NUMERIC(12,2) DEFAULT 0.00,
    uber_driver_sub_charge NUMERIC(12,2) DEFAULT 0.00,
    uber_week_os NUMERIC(12,2) DEFAULT 0.00,
    ola_trips INT DEFAULT 0,
    ola_net_revenue NUMERIC(12,2) DEFAULT 0.00,
    ola_toll NUMERIC(12,2) DEFAULT 0.00,
    ola_gst NUMERIC(12,2) DEFAULT 0.00,
    ola_online_payment NUMERIC(12,2) DEFAULT 0.00,
    ola_week_os NUMERIC(12,2) DEFAULT 0.00,
    rapido_trips INT DEFAULT 0,
    rapido_net_revenue NUMERIC(12,2) DEFAULT 0.00,
    weekly_platform_incentive NUMERIC(12,2) DEFAULT 0.00,
    vehicle_adjustments NUMERIC(12,2) DEFAULT 0.00,
    challan_amount NUMERIC(12,2) DEFAULT 0.00,
    accident_penalties NUMERIC(12,2) DEFAULT 0.00,
    dead_mile_charges NUMERIC(12,2) DEFAULT 0.00,
    tds_amount NUMERIC(12,2) DEFAULT 0.00,
    current_week_os NUMERIC(12,2) DEFAULT 0.00,
    to_collect NUMERIC(12,2) DEFAULT 0.00,
    to_payout NUMERIC(12,2) DEFAULT 0.00,
    letzryd_earning NUMERIC(12,2) DEFAULT 0.00,
    letzryd_earning_per_day NUMERIC(12,2) DEFAULT 0.00,
    settlement_status VARCHAR(32) DEFAULT 'OPEN',
    CONSTRAINT uq_hisaab_veh_weekly UNIQUE (week_id, vehicle_number, partner_id)
);
```

### 4.5 `public.hisaab_partner_weekly`
Tier 3 consolidated partner payout statement (1-to-1 match with `Hisaab Summary`):
```sql
CREATE TABLE public.hisaab_partner_weekly (
    id BIGSERIAL PRIMARY KEY,
    settlement_year INT NOT NULL,
    settlement_week INT NOT NULL,
    week_id VARCHAR(16) NOT NULL REFERENCES public.hisaab_settlement_weeks(week_id),
    week_start DATE NOT NULL,
    week_end DATE NOT NULL,
    partner_id VARCHAR(64) NOT NULL,
    partner_name VARCHAR(128),
    partner_type VARCHAR(32) DEFAULT 'Individual',
    city VARCHAR(32) NOT NULL,
    allotted_cars_count INT DEFAULT 1,
    total_onroad_days INT DEFAULT 0,
    total_trips INT DEFAULT 0,
    total_net_rent_billed NUMERIC(12,2) DEFAULT 0.00,
    total_platform_earnings NUMERIC(12,2) DEFAULT 0.00,
    total_cash_collected NUMERIC(12,2) DEFAULT 0.00,
    total_platform_incentives NUMERIC(12,2) DEFAULT 0.00,
    total_adjustments NUMERIC(12,2) DEFAULT 0.00,
    total_challans NUMERIC(12,2) DEFAULT 0.00,
    total_accidents NUMERIC(12,2) DEFAULT 0.00,
    total_tds NUMERIC(12,2) DEFAULT 0.00,
    current_week_os NUMERIC(12,2) DEFAULT 0.00,
    previous_outstanding NUMERIC(12,2) DEFAULT 0.00,
    amount_paid_during_week NUMERIC(12,2) DEFAULT 0.00,
    prior_period_adjustments NUMERIC(12,2) DEFAULT 0.00,
    security_deposit_target NUMERIC(12,2) DEFAULT 0.00,
    security_deposit_paid NUMERIC(12,2) DEFAULT 0.00,
    deposit_deduction_current_week NUMERIC(12,2) DEFAULT 0.00,
    pending_deposit NUMERIC(12,2) DEFAULT 0.00,
    total_outstanding NUMERIC(12,2) DEFAULT 0.00,
    net_bank_payout NUMERIC(12,2) DEFAULT 0.00,
    net_amount_to_collect NUMERIC(12,2) DEFAULT 0.00,
    settlement_status VARCHAR(32) DEFAULT 'DRAFT',
    frozen_at TIMESTAMPTZ,
    bank_utr_reference VARCHAR(64),
    CONSTRAINT uq_hisaab_partner_weekly UNIQUE (week_id, partner_id)
);
```

---

## 5. Execution & Automation Runbook

The automation pipeline is self-contained and executable via Python or scheduled cron jobs:

```bash
# 1. Run daily sync for yesterday's shift
python "Hisaab Final Table/automation_script.py" --daily 2026-06-25

# 2. Run weekly roll-up for vehicle and partner statements
python "Hisaab Final Table/automation_script.py" --weekly 2026-W26

# 3. Engage the Monday 11:00 AM lock on a completed settlement week
python "Hisaab Final Table/automation_script.py" --lock 2026-W26
```
