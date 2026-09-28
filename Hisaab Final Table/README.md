# LetzRyd Hisaab Engine - Architecture & Settlement Specification

## 1. System Mission & Rebuilt Architecture

The **LetzRyd Hisaab Engine** serves as the automated financial, operational, and settlement authority for LetzRyd. Following an empirical audit of historical weekly workbooks (CY26WK26, CY26WK27, CY26WK37) against live PostgreSQL production tables, the engine was redesigned from the ground up.

### Core Architectural Principles:
1. **100% Downstream Decoupling (Zero Triggers)**:
   - In accordance with production stability requirements, **all triggers attached to upstream core tables (`core_adjustments`, `core_challans`, `core_gps`, `core_ola_daily`, `core_ola_weekly`) have been permanently removed**.
   - Raw ingestion pipelines (Uber sync, Ola sync, vehicle status, adjustments) operate independently at full speed without database table locks or transaction cascades.
2. **Dual-Table Architecture (Audit Truth Ledger vs. Operational Payout Ledger)**:
   - **`public.hisaab_vehicle_weekly` (Audit / Calendar Truth Ledger)**: Preserves 100% calendar ground truth without cutoffs. All rent, trips, core adjustments, and unpaid challans (`TRAFFIC_FINE` & `STICKER_FINE`) are booked strictly to the exact week of their occurrence / violation date.
   - **`public.hisaab_vehicle_payout_weekly` (Operational Payout Ledger)**: Enforces an immutable weekly settlement freeze on the prior week every **Monday at 11:00 AM IST (`lock_cutoff_at`)**. Any late-arriving data (e.g. challans scraped after Monday 11 AM, adjustments approved late) cannot alter the frozen prior week and are systematically rolled forward into the next active week as adjustments (`challan_adjustment_amount`, `prior_period_adjustment_amount`).
3. **Automated Scheduled Batching via `pg_cron`**:
   - The audit engine executes hourly at **minute 45 (`45 * * * *`)** via `sp_sync_hisaab_vehicle_weekly(NULL)`.
   - The operational payout engine executes hourly at **minute 50 (`50 * * * *`)** via `sp_sync_hisaab_vehicle_payout_weekly(NULL)`.
   - The app tables sync executes at **minute 00 (`0 * * * *`)** via `fn_sync_hisaab_to_app_tables()`.
4. **Strictly Scoped & Empirically Verified**:
   - Focuses on verified telemetry, rental waterfall, and live adjustments:
     - **Onroad & Allotted Days** (with fractional day support, e.g. 6.5 days)
     - **Lease Rent** (Daily Rate, Base Rental, Indemnity Fee, Net Weekly Rent)
     - **Uber Telemetry & Revenue** (Trips, Earnings, Cash Collected, Toll, Driver Subscription, Incentive, Week O/S)
     - **Ola Telemetry & Revenue** (Trips, Revenue, Cash Collected, Toll, GST, Online Payouts, Incentive, Week O/S)
     - **Core Adjustments (LIVE)**: Integrates approved credits/debits from `public.core_adjustments` with full polarity support (+ Debit, - Credit).
     - **Traffic & Sticker Challans (LIVE)**: Integrates unpaid fines from `public.core_challans` (`TRAFFIC_FINE` and `STICKER_FINE`) attributed to driver custody on `violation_date` via `daily_rent_log`. Fines marked `PAID` are strictly excluded.
     - **Current Week O/S & Driver Payouts**: Real-time evaluation of `current_week_os`, `net_to_collect_from_driver`, and `net_payout_to_driver`.

---

## 2. Table Specifications

### A. `public.hisaab_settlement_weeks`
Master settlement calendar managing weekly billing cycle boundaries and lock guards.
- **Grain**: One record per settlement week (`week_id`, e.g. `'CY26WK26'`).
- **Columns**: `week_id`, `settlement_year`, `settlement_week`, `week_start`, `week_end`, `lock_cutoff_at`, `is_locked`, `locked_at`, `locked_by`, `notes`.

### B. `public.hisaab_vehicle_weekly` (Audit Truth Ledger)
Calendar violation-date settlement table matching verified fields of weekly workbooks without cutoffs.
- **Primary Key**: `id BIGSERIAL`
- **Unique Constraint**: `(week_id, vehicle_number)`
- **Behavior**: Strictly reflects all trips, rents, adjustments, and challans on their actual calendar dates.

### C. `public.hisaab_vehicle_payout_weekly` (Operational Payout Ledger)
Driver payout table enforcing the Monday 11:00 AM IST cutoff freeze.
- **Primary Key**: `id BIGSERIAL`
- **Unique Constraint**: `(week_id, vehicle_number, partner_id)`
- **Behavior**:
  - Automatically transitions to `'FROZEN'` once `CURRENT_TIMESTAMP >= lock_cutoff_at` (Monday 11:00 AM IST).
  - Frozen weeks are immutable and protected against updates.
  - In-week challans created $\le$ Monday 11:00 AM IST are billed in `challan_amount`.
  - Late challans scraped after Monday 11:00 AM IST for prior weeks roll into the next active week's `challan_adjustment_amount`.
  - In-week approved adjustments created $\le$ Monday 11:00 AM IST are booked in `adjustment_amount`.
  - Late approved adjustments for prior weeks roll into `prior_period_adjustment_amount`.

---

## 3. Mathematical Formulas

### Lease Rent:
$$\text{Net Weekly Lease Rental} = \text{Weekly Lease Rental} + \text{Weekly Indemnity Fees}$$
$$\text{Daily Rent Applied} = \frac{\text{Net Weekly Lease Rental}}{\text{Onroad Days}} \quad (\text{if } \text{Onroad Days} > 0)$$

### Uber Week Outstanding (O/S):
$$\text{Uber Week O/S} = \text{Uber Total Earnings} - \text{Uber Cash Collection} - \text{Driver Subscription Charge}$$

### Ola Week Outstanding (O/S):
$$\text{Ola Week O/S} = \text{Ola Net Revenue} - \text{Ola Cash Collection}$$

### Challan Deductions:
$$\text{Challan Amount} = \sum \text{Pending Fine Amount} \quad (\text{where } \text{status} = \text{'UNPAID'} \land \text{liability} \in \{\text{'TRAFFIC\_FINE'}, \text{'STICKER\_FINE'}\})$$
*Attributed strictly to driver custody on `violation_date` via `daily_rent_log`.*

### Current Week Outstanding (O/S) & Payouts:
#### For Audit Ledger (`hisaab_vehicle_weekly`):
$$\text{Current Week O/S} = \text{Net Rent} - (\text{Uber O/S} + \text{Ola O/S}) + \text{Challan Amount} + \text{Adjustment Amount}$$

#### For Payout Ledger (`hisaab_vehicle_payout_weekly`):
$$\text{Current Week O/S} = \text{Net Rent} - (\text{Uber O/S} + \text{Ola O/S}) + \text{Challan Amount} + \mathbf{challan\_adjustment\_amount} + \text{Adjustment Amount} + \mathbf{prior\_period\_adjustment\_amount}$$
$$\text{Net to Collect from Driver} = \max(0, \text{Current Week O/S})$$
$$\text{Net Payout to Driver} = \max(0, -\text{Current Week O/S})$$

---

## 4. Automation & Stored Procedures

### Stored Procedures:
1. `public.sp_sync_hisaab_vehicle_weekly(p_week_id VARCHAR DEFAULT NULL)`:
   - Synchronizes `hisaab_vehicle_weekly` (Audit Ledger).
   - Driven by `pg_cron` at **`:45`** hourly.
2. `public.sp_sync_hisaab_vehicle_payout_weekly(p_week_id VARCHAR DEFAULT NULL)`:
   - Synchronizes `hisaab_vehicle_payout_weekly` (Payout Ledger).
   - Freezes weeks past Monday 11:00 AM IST and rolls late challans/adjustments forward.
   - Driven by `pg_cron` at **`:50`** hourly.

### `pg_cron` Scheduling:
```sql
-- Audit Ledger Sync (Minute 45)
SELECT cron.schedule(
    'hisaab-vehicle-weekly-sync',
    '45 * * * *',
    'CALL public.sp_sync_hisaab_vehicle_weekly(NULL);'
);

-- Operational Payout Sync (Minute 50)
SELECT cron.schedule(
    'hisaab-vehicle-payout-sync',
    '50 * * * *',
    'CALL public.sp_sync_hisaab_vehicle_payout_weekly(NULL);'
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
