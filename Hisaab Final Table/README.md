# LetzRyd Hisaab Engine - Architecture & Settlement Specification

## 1. System Mission & Rebuilt Architecture

The **LetzRyd Hisaab Engine** serves as the automated financial, operational, and settlement authority for LetzRyd. Following an empirical audit of historical weekly workbooks (CY26WK26, CY26WK27, CY26WK37) against live PostgreSQL production tables, the engine was redesigned from the ground up.

### Core Architectural Principles:
1. **100% Downstream Decoupling (Zero Triggers)**:
   - In accordance with production stability requirements, **all triggers attached to upstream core tables (`core_adjustments`, `core_challans`, `core_gps`, `core_ola_daily`, `core_ola_weekly`) have been permanently removed**.
   - Raw ingestion pipelines (Uber sync, Ola sync, vehicle status, adjustments) operate independently at full speed without database table locks or transaction cascades.
2. **Automated Scheduled Batching via `pg_cron`**:
   - The engine is driven by a scheduled PostgreSQL cron job (`hisaab-vehicle-weekly-sync`), executing daily at **03:00 AM UTC (08:30 AM IST)**.
   - Runs immediately after the rental waterfall calculation (`rental-daily-calculation` at 02:00 AM UTC).
3. **Strictly Scoped & Empirically Verified**:
   - Focuses strictly on verified telemetry and core billing components:
     - **Onroad & Allotted Days** (with fractional day support, e.g. 6.5 days)
     - **Lease Rent** (Daily Rate, Base Rental, Indemnity Fee, Net Weekly Rent)
     - **Uber Telemetry & Revenue** (Trips, Earnings, Cash Collected, Toll, Driver Subscription, Incentive, Week O/S)
     - **Ola Telemetry & Revenue** (Trips, Revenue, Cash Collected, Toll, GST, Online Payouts, Incentive, Week O/S)
   - Unverified items (**Current Week O/S, Adjustments, Challans, Accidents, TDS, Dead Miles, Partner Summary**) are explicitly excluded until upstream audits are finalized.

---

## 2. Table Specifications

### A. `public.hisaab_settlement_weeks`
Master settlement calendar managing weekly billing cycle boundaries and lock guards.
- **Grain**: One record per settlement week (`week_id`, e.g. `'CY26WK26'`).
- **Columns**: `week_id`, `settlement_year`, `settlement_week`, `week_start`, `week_end`, `lock_cutoff_at`, `is_locked`, `locked_at`, `locked_by`, `notes`.

### B. `public.hisaab_vehicle_weekly`
Core weekly settlement table matching the verified fields of the weekly Hisaab workbooks (`Uber + OLA Final Hisaab`).
- **Primary Key**: `id BIGSERIAL`
- **Unique Constraint**: `(week_id, vehicle_number)`
- **Schema**:
  | Column Group | Columns | Data Type | Notes |
  | :--- | :--- | :--- | :--- |
  | **Identity** | `week_id`, `week_start`, `week_end`, `vehicle_number`, `partner_id`, `partner_name`, `city`, `vehicle_model`, `rental_plan` | `VARCHAR`, `DATE` | Resolved from `daily_rent_log`, `core_partner_onboarding`, and `rental_custom_partner_plans` |
  | **Attendance** | `allotted_days`, `onroad_days` | `NUMERIC(4, 1)` | Supports fractional days (e.g. 6.5) |
  | **Lease Rent** | `daily_rent_applied`, `weekly_lease_rental`, `weekly_indemnity_fees`, `net_weekly_lease_rental` | `NUMERIC(10/12, 2)` | Aggregated from 5-tier waterfall in `daily_rent_log` |
  | **Uber** | `uber_trips`, `uber_total_earnings`, `uber_cash_collection`, `uber_toll`, `uber_driver_sub_charge`, `uber_incentive`, `uber_week_os` | `INT`, `NUMERIC(12, 2)` | Pre-aggregated from `core_uber_weekly` (fallback: `core_uber_daily`) |
  | **Ola** | `ola_trips`, `ola_net_revenue`, `ola_cash_collection`, `ola_toll`, `ola_gst`, `ola_online_payment`, `ola_incentive`, `ola_week_os` | `INT`, `NUMERIC(12, 2)` | Pre-aggregated from `core_ola_weekly` (fallback: `core_ola_daily`) |
  | **Audit** | `settlement_status`, `created_at`, `updated_at` | `VARCHAR`, `TIMESTAMPTZ` | `'CALCULATED'`, `'VERIFIED'`, `'LOCKED'` |

---

## 3. Mathematical Formulas

### Lease Rent:
$$\text{Net Weekly Lease Rental} = \text{Weekly Lease Rental} + \text{Weekly Indemnity Fees}$$
$$\text{Daily Rent Applied} = \frac{\text{Net Weekly Lease Rental}}{\text{Onroad Days}} \quad (\text{if } \text{Onroad Days} > 0)$$

### Uber Week Outstanding (O/S):
$$\text{Uber Week O/S} = \text{Uber Total Earnings} - \text{Uber Cash Collection} - \text{Driver Subscription Charge}$$

### Ola Week Outstanding (O/S):
$$\text{Ola Week O/S} = \text{Ola Net Revenue} - \text{Ola Cash Collection}$$

---

## 4. Automation & Stored Procedures

### Stored Procedure:
`public.sp_sync_hisaab_vehicle_weekly(p_week_id VARCHAR DEFAULT NULL)`
- If `p_week_id` is specified, recalculates and upserts that specific week.
- If `NULL`, recalculates all unlocked settlement weeks where `week_start <= CURRENT_DATE`.
- Handles multiple partner assignments in a single week by selecting the primary partner by billable days and latest timestamp.
- Automatically leverages `core_uber_weekly` / `core_ola_weekly` if present, with transparent fallback to daily ingestion tables (`core_uber_daily` / `core_ola_daily`).

### `pg_cron` Scheduling:
```sql
SELECT cron.schedule(
    'hisaab-vehicle-weekly-sync',
    '0 3 * * *',
    'CALL public.sp_sync_hisaab_vehicle_weekly(NULL);'
);
```

---

## 5. Empirical Verification & Parity Results

Row-by-row reconciliation against production Excel workbooks for Week 26 (`CY26WK26`):

| City | Total Excel Vehicles | Onroad Days Match | Lease Rent Match | Uber Trips Match | Ola Trips Match |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Bangalore** | 807 | **97.3%** | Identity formula | **97.4%** | **99.5%** |
| **Hyderabad** | 258 | **97.3%** | **82.2%** | **96.1%** | **100.0%** |
| **Mumbai** | 184 | 65.8% | **100.0%** (via custom plan) | **95.1%** | **100.0%** |

### Resolution of Mumbai Daily Rent Discrepancy (Javed Khan):
- **Vehicle**: `MH03ES2575` | **Partner**: `LETZMUM9580424256` (`Javed Khan`)
- **Excel Values**: 6.5 Onroad Days, Daily Rent = ₹1,029.00, Net Rent = ₹6,688.50.
- **Root Cause**: Earlier standalone simulation scripts only referenced the Excel tab `Plan.json` (investor/operator rates) and fell back to standard retail slabs (₹689).
- **Resolution**: In `rental_custom_partner_plans`, the Daily Rental Agent correctly registered Javed Khan with `custom_daily_rent = 999.00` and `custom_daily_fee = 30.00` (Total = **₹1,029.00**).
- **Match Rate**: With `rental_custom_partner_plans`, Mumbai Daily Rent is **100.0% matching (184/184)**.

---

## 6. Upstream Discrepancies for Core Tables Agent

The following upstream telemetry and status gaps were identified during reconciliation and should be handed over to the core tables agent for ingestion remediation:
1. **`core_daily_vehicle_status` Historical Data Window**:
   - In PostgreSQL, `core_daily_vehicle_status` only contains records from **2026-08-11 onwards**.
   - Statuses for June/July 2026 (CY26WK26 and CY26WK27) are absent in `core_daily_vehicle_status` (currently preserved in `daily_rent_log`).
2. **`core_uber_daily` Mumbai Week 37 Ingestion**:
   - For Mumbai Week 37 (`2026-09-07` to `2026-09-13`), only 17 out of 232 vehicles have Uber telemetry in PostgreSQL (7.3% ingestion coverage). Upstream raw Uber ingestion for Mumbai Week 37 requires backfilling.
3. **Multi-Record Uber Weekly Rows**:
   - 34 vehicles in `core_uber_weekly` have multiple rows per week (e.g. across multiple vendor codes). The Hisaab procedure aggregates these cleanly via `SUM()`.
