# LETZRYD HISAAB ENGINE: MASTER ARCHITECTURAL SPECIFICATION & TECHNICAL MANUAL

**Document Version:** 2.2.0 (Comprehensive Audit & Modular Roll-Forward Release)  
**Classification:** Enterprise Technical Reference & Financial Operational Manual  
**Last Updated:** September 16, 2026  
**Production Database:** PostgreSQL 14+ on Google Cloud Platform (`35.200.196.113:5432/postgres`)  
**Git Repositories:** `aayush-letzryd/backend.git` (tracked in `backend` and `backend_repo`)  

---

## TABLE OF CONTENTS
1. [Executive Summary & System Architecture](#1-executive-summary--system-architecture)
2. [Infrastructure & Environment Specifications](#2-infrastructure--environment-specifications)
3. [The 3-Tier Multi-Grain Settlement Pipeline](#3-the-3-tier-multi-grain-settlement-pipeline)
4. [Master Data Dictionary & Schema Reference (7 Tables)](#4-master-data-dictionary--schema-reference-7-tables)
   - [4.1 Table 1: hisaab_settlement_weeks](#41-table-1-public-hisaab_settlement_weeks)
   - [4.2 Table 2: hisaab_adjustments_ledger](#42-table-2-public-hisaab_adjustments_ledger)
   - [4.3 Table 3: hisaab_daily_ledger](#43-table-3-public-hisaab_daily_ledger)
   - [4.4 Table 4: hisaab_vehicle_weekly](#44-table-4-public-hisaab_vehicle_weekly)
   - [4.5 Table 5: hisaab_partner_weekly](#45-table-5-public-hisaab_partner_weekly)
   - [4.6 Table 6: hisaab_system_config](#46-table-6-public-hisaab_system_config)
   - [4.7 Table 7: hisaab_partner_opening_balances](#47-table-7-public-hisaab_partner_opening_balances)
   - [4.8 Upstream Core Feeds](#48-upstream-core-feeds)
5. [Entity Relationship Architecture & Data Lineage](#5-entity-relationship-architecture--data-lineage)
6. [Core Mathematical Formulations & Sign Conventions](#6-core-mathematical-formulations--sign-conventions)
   - [6.1 Sign Polarity & Debit Partitioning (Challans vs Accidents vs Credits)](#61-sign-polarity--debit-partitioning)
   - [6.2 Daily Net Balance Formula (Mobile App Grain)](#62-daily-net-balance-formula-mobile-app-grain)
   - [6.3 Vehicle Weekly Outstanding Formula](#63-vehicle-weekly-outstanding-formula)
   - [6.4 Partner Consolidated Payout & Dues Formula](#64-partner-consolidated-payout--dues-formula)
   - [6.5 Telematics, Dead Mile Penalty, & Rapido Buffer Calculation](#65-telematics-dead-mile-penalty--rapido-buffer-calculation)
   - [6.6 Statutory TDS Deduction (Section 194C)](#66-statutory-tds-deduction-section-194c)
7. [Modular Debt Roll-Forward & Opening Balance Architecture](#7-modular-debt-roll-forward--opening-balance-architecture)
8. [Operational Trip Override Engine (Anti-Leakage)](#8-operational-trip-override-engine-anti-leakage)
9. [Multi-Driver Shared Car Deduplication Engine](#9-multi-driver-shared-car-deduplication-engine)
10. [Prior-Period Adjustment Auto-Routing Engine](#10-prior-period-adjustment-auto-routing-engine)
11. [Monday 11:00 AM Hard Lock & Immutability Guards](#11-monday-1100-am-hard-lock--immutability-guards)
12. [Stored Procedures & Procedural Logic Reference](#12-stored-procedures--procedural-logic-reference)
13. [Pipeline Automation Scripts & CLI Reference](#13-pipeline-automation-scripts--cli-reference)
14. [Exhaustive Audit Chronology & Remediations](#14-exhaustive-audit-chronology--remediations)
15. [Live Verification Scorecard (Weeks 25 to 38)](#15-live-verification-scorecard-weeks-25-to-38)
16. [Operational Runbook & Maintenance](#16-operational-runbook--maintenance)

---

## 1. EXECUTIVE SUMMARY & SYSTEM ARCHITECTURE

The **LetzRyd Hisaab Engine** is the enterprise financial billing, settlement, and payout clearinghouse for LetzRyd's commercial electric vehicle fleet. It manages multi-million INR weekly cash flows across thousands of commercial vehicles, independent drivers, and multi-vehicle fleet operators in major metropolitan markets (Bangalore, Hyderabad, Mumbai).

The system aggregates high-frequency telemetry, ride-hailing revenues, operational attendance, leasing contracts, traffic challans, telematics dead mileage, and physical cash collections into an automated, idempotent 3-tier financial ledger.

```
+----------------------------------------------------------------------------------------------------+
|                                    UPSTREAM RAW OPERATIONAL DATA                                   |
|   daily_rent_log      core_uber_daily      core_ola_daily      core_rapido_daily      core_gps     |
|   core_adjustments    core_challans        core_partner_onb    core_rent              core_weekly  |
+----------------------------------------------------------------------------------------------------+
                                                  │
                                                  ▼ (Real-time Event Triggers & Batch Upserts)
+----------------------------------------------------------------------------------------------------+
| TIER 1: DAILY SHIFT LEDGER (public.hisaab_daily_ledger)                                           |
| Grain: (log_date, vehicle_number, partner_id)                                                      |
| Features: Operational Trip Override, Shift Revenue Attribution, Live Mobile App Balance Feed        |
+----------------------------------------------------------------------------------------------------+
                                                  │
                                                  ▼ (sp_sync_hisaab_vehicle_weekly / trg_cascade)
+----------------------------------------------------------------------------------------------------+
| TIER 2: VEHICLE WEEKLY SETTLEMENT (public.hisaab_vehicle_weekly)                                   |
| Grain: (week_id, vehicle_number, partner_id)                                                       |
| Features: 1-to-1 Excel Mirror, Dead Mile Penalty Math, TDS 194C, Ola/Uber/Rapido Consolidation       |
+----------------------------------------------------------------------------------------------------+
                                                  │
                                                  ▼ (sp_sync_hisaab_partner_weekly)
+----------------------------------------------------------------------------------------------------+
| TIER 3: CONSOLIDATED PARTNER PAYOUT (public.hisaab_partner_weekly)                                 |
| Grain: (week_id, partner_id)                                                                       |
| Features: Fleet Consolidation (1 to 200+ cars), Modular Roll-Forward, Direct Bank Payout Clearing   |
+----------------------------------------------------------------------------------------------------+
                                                  │
                                                  ▼ (Config & Cutover Support)
+----------------------------------------------------------------------------------------------------+
| CONTROL & MIGRATION: hisaab_system_config & hisaab_partner_opening_balances                         |
| Controls Standalone Mode vs Dynamic Roll-Forward and Driver App Live Cutover Starting Balances     |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. INFRASTRUCTURE & ENVIRONMENT SPECIFICATIONS

* **Primary Database Engine:** PostgreSQL 14+
* **Host Address:** `35.200.196.113:5432`
* **Default Database:** `postgres`
* **Timezone Standard:** Asia/Kolkata (`IST`, `UTC+05:30`)
* **Billing Calendar Cycle:** Monday 04:00 AM IST through Sunday (Cutoff: Monday 11:00:00 AM IST)
* **Primary Git Repository:** `git@github.com:aayush-letzryd/backend.git`
* **Local Workspaces:** `C:\Users\anura\RYD\backend` and `C:\Users\anura\RYD\backend_repo`
* **Engine Directory:** `Hisaab Final Table/`

---

## 3. THE 3-TIER MULTI-GRAIN SETTLEMENT PIPELINE

1. **Daily Shift Grain (`hisaab_daily_ledger`):** Key `(log_date, vehicle_number, partner_id)`. Computes daily lease rent, passenger cash collected, digital platform revenues, and shift liabilities. Directly powers the driver mobile application daily balance feed.
2. **Vehicle Weekly Grain (`hisaab_vehicle_weekly`):** Key `(week_id, vehicle_number, partner_id)`. Reconciles lease rent, multi-platform fare earnings, GPS dead miles, and statutory TDS (Section 194C). Mirrors 1-to-1 the historical Excel reconciliation model.
3. **Partner Consolidated Grain (`hisaab_partner_weekly`):** Key `(week_id, partner_id)`. Aggregates multi-car operators (from 1 to 200+ vehicles) into a single weekly treasury disbursement or collection statement.

---

## 4. MASTER DATA DICTIONARY & SCHEMA REFERENCE (7 TABLES)

### 4.1 Table 1: `public.hisaab_settlement_weeks`
Master settlement cycle calendar and immutability lock controller.

| Column | Data Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| `week_id` | `VARCHAR(16)` | `PRIMARY KEY` | Standard cycle key (e.g. `'CY26WK37'`) |
| `settlement_year` | `INT` | `NOT NULL` | ISO settlement calendar year (e.g. `2026`) |
| `settlement_week` | `INT` | `NOT NULL` | ISO settlement calendar week (e.g. `37`) |
| `week_start` | `DATE` | `NOT NULL` | Monday 04:00 AM start date |
| `week_end` | `DATE` | `NOT NULL` | Sunday calendar end date |
| `lock_cutoff_at` | `TIMESTAMPTZ`| `NOT NULL` | Hard cutoff timestamp (Monday 11:00:00 AM IST) |
| `is_locked` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Immutability lock state |
| `locked_at` | `TIMESTAMPTZ`| `NULL` | Timestamp when week was locked |
| `locked_by` | `VARCHAR(64)`| `NULL` | Operator or system job that locked week |

*Guards:* Trigger `trg_hisaab_week_lock_guard` prevents unlocking locked weeks without session-level bypass `hisaab.enforcing_lock = 'true'`.

### 4.2 Table 2: `public.hisaab_adjustments_ledger`
Ledger of all debits and credits applied to vehicles and partners.

| Column | Data Type | Description |
| :--- | :--- | :--- |
| `id` | `BIGSERIAL PRIMARY KEY` | Unique transaction ID |
| `incident_date` | `DATE NOT NULL` | Date the incident occurred |
| `settlement_week_id` | `VARCHAR(16) NOT NULL` | Target settlement cycle where financial effect is recognized |
| `vehicle_number` | `VARCHAR(32) NOT NULL` | Associated vehicle |
| `partner_id` | `VARCHAR(64) NOT NULL` | Associated driver or operator |
| `adjustment_category`| `VARCHAR(64) NOT NULL` | Description / category |
| `polarity` | `VARCHAR(8) NOT NULL` | `'DEBIT'` (adds to driver debt) or `'CREDIT'` (reduces driver debt) |
| `amount` | `NUMERIC(12,2) NOT NULL`| Absolute monetary value |
| `is_prior_period` | `BOOLEAN NOT NULL` | `TRUE` if routed from a locked historical cycle |
| `approval_status` | `VARCHAR(32) NOT NULL` | Must be `'Approved'` to take financial effect |
| `effective_date` | `DATE` | Accounting recognition date |

*Guards:* Trigger `trg_auto_route_prior_period_adjustment` automatically routes adjustments from locked cycles to the current open cycle containing `CURRENT_DATE`.

### 4.3 Table 3: `public.hisaab_daily_ledger`
Daily operational shift feed (Grain: `log_date, vehicle_number, partner_id`).

Key Columns: `net_daily_rent`, `uber_trips`, `uber_fare_earnings`, `uber_cash_collected`, `ola_trips`, `ola_net_revenue`, `ola_cash_collected`, `ola_online_payment`, `rapido_trips`, `rapido_net_revenue`, `rapido_cash_collected`, `daily_challans`, `daily_accident_recovery`, `daily_adjustments`, `weekly_incentive_credit`, `daily_net_balance`.

### 4.4 Table 4: `public.hisaab_vehicle_weekly`
Vehicle weekly reconciliation statement (Grain: `week_id, vehicle_number, partner_id`).

Key Columns: `weekly_lease_rental`, `weekly_indemnity_fees`, `net_weekly_lease_rental`, `uber_total_earnings`, `uber_cash_collection`, `ola_net_revenue`, `ola_cash_collection`, `ola_online_payment`, `rapido_net_revenue`, `rapido_cash_collected`, `total_trip_km`, `total_gps_km`, `ideal_gps_km`, `dead_mile_km`, `dead_mile_pct`, `dead_mile_charges`, `tds_amount`, `current_week_os`, `to_collect`, `to_payout`.

### 4.5 Table 5: `public.hisaab_partner_weekly`
Partner consolidated settlement statement (Grain: `week_id, partner_id`).

Key Columns: `allotted_cars_count`, `total_onroad_days`, `total_trips`, `total_net_rent_billed`, `total_platform_earnings`, `total_cash_collected`, `current_week_os`, `previous_outstanding`, `amount_paid_during_week`, `prior_period_adjustments`, `total_outstanding`, `net_bank_payout`, `net_amount_to_collect`, `payout_account_number`, `payout_ifsc`, `settlement_status`.

### 4.6 Table 6: `public.hisaab_system_config`
Runtime configuration switches controlling settlement behavior.

| Key | Default Value | Description |
| :--- | :--- | :--- |
| `enable_roll_forward` | `'false'` | `false` = Standalone Mode (`previous_outstanding = 0.00`); `true` = Dynamic debt roll-forward. |
| `roll_forward_start_week` | `'CY26WK40'` | Target settlement cycle when mobile app live opening balances begin. |

### 4.7 Table 7: `public.hisaab_partner_opening_balances`
Starting debt/credit ledger for mobile application live cutover.

| Column | Data Type | Description |
| :--- | :--- | :--- |
| `partner_id` | `VARCHAR(64)` | Partner identifier |
| `effective_week_id`| `VARCHAR(16)` | Go-live week cycle (e.g. `'CY26WK40'`) |
| `opening_balance_due` | `NUMERIC(12,2)` | Verified starting balance due (Positive = Debt, Negative = Credit) |
| `remarks` | `TEXT` | Audit notes from finance onboarding |

---

## 6. CORE MATHEMATICAL FORMULATIONS & SIGN CONVENTIONS

### 6.1 Sign Polarity & Debit Partitioning
Sign convention across all tiers:
* **Positive ($> 0$):** Partner owes company (`net_amount_to_collect`).
* **Negative ($< 0$):** Company owes partner (`net_bank_payout`).

In-Week Adjustments are cleanly partitioned into non-overlapping financial buckets:
```sql
daily_challans = SUM(CASE WHEN polarity = 'DEBIT' AND NOT (adjustment_category ILIKE '%accident%' OR adjustment_category ILIKE '%damage%') THEN amount ELSE 0.00 END)
daily_accident_recovery = SUM(CASE WHEN polarity = 'DEBIT' AND (adjustment_category ILIKE '%accident%' OR adjustment_category ILIKE '%damage%') THEN amount ELSE 0.00 END)
daily_adjustments = SUM(CASE WHEN polarity = 'CREDIT' THEN amount ELSE 0.00 END)
```

### 6.2 Daily Net Balance Formula
$$	ext{daily\_net\_balance} = 	ext{net\_daily\_rent} + 	ext{cash\_collected} - 	ext{platform\_earnings} - 	ext{ola\_online\_payment} + 	ext{daily\_challans} + 	ext{daily\_accidents} - 	ext{daily\_adjustments} - 	ext{weekly\_incentive\_credit}$$

### 6.3 Vehicle Weekly Outstanding Formula
$$	ext{current\_week\_os} = 	ext{net\_weekly\_lease\_rental} + 	ext{total\_cash\_collected} - 	ext{total\_platform\_earnings} - 	ext{ola\_online\_payment} - 	ext{platform\_incentives} - 	ext{adjustments} + 	ext{challans} + 	ext{accidents} + 	ext{dead\_mile\_charges} + 	ext{tds\_amount}$$

### 6.4 Partner Consolidated Payout & Dues Formula
$$	ext{total\_cash\_collected} = 	ext{uber\_cash} + 	ext{ola\_cash} + 	ext{rapido\_cash}$$
$$	ext{total\_outstanding} = 	ext{current\_week\_os} + 	ext{previous\_outstanding} + 	ext{prior\_period\_adjustments} - 	ext{amount\_paid\_during\_week}$$
$$	ext{net\_bank\_payout} = |\min(0, 	ext{total\_outstanding})|$$
$$	ext{net\_amount\_to\_collect} = \max(0, 	ext{total\_outstanding})$$

### 6.5 Telematics, Dead Mile Penalty, & Rapido Buffer Calculation
$$	ext{in\_trip\_km} = 	ext{uber\_km} + 	ext{ola\_km} + 	ext{rapido\_km}$$
$$	ext{ideal\_gps\_km} = (	ext{in\_trip\_km} 	imes 1.05) + [(	ext{uber\_trips} + 	ext{ola\_trips} + 	ext{rapido\_trips}) 	imes 3.0	ext{ km}] + (	ext{onroad\_days} 	imes 30.0	ext{ km})$$
$$	ext{dead\_mile\_km} = \max(0, 	ext{total\_gps\_km} - 	ext{ideal\_gps\_km})$$
$$	ext{dead\_mile\_charges} = 	ext{dead\_mile\_km} 	imes ₹3.00\quad (	ext{Individual drivers only; ₹0.00 for Operators})$$

---

## 7. MODULAR DEBT ROLL-FORWARD & OPENING BALANCE ARCHITECTURE

Because historical offline cash/UPI collections and bank disbursements were handled externally and not recorded inside PostgreSQL, the engine is architected to decouple weekly settlements from unverified historical debt:

1. **Standalone Mode (Current Default, `enable_roll_forward = 'false'`):**
   * `previous_outstanding = 0.00` across all partners.
   * Every settlement week operates as a pure standalone cycle.
   * Eliminates phantom negative payouts and avoids compounding unverified historical debts.
2. **Mobile App Live Cutover Mode (`hisaab_partner_opening_balances`):**
   * Upon app launch (target: Week 40), finance enters the single verified starting balance per partner into `hisaab_partner_opening_balances`.
   * The procedure automatically sets `previous_outstanding = op.opening_balance_due` for that cutover cycle.
3. **Dynamic Roll-Forward Mode (`enable_roll_forward = 'true'`):**
   * After app go-live, finance activates dynamic roll-forward via `UPDATE hisaab_system_config SET config_value = 'true' WHERE config_key = 'enable_roll_forward';`.
   * From then on, unpaid debts ($> 0$) carry forward automatically, while credit balances are disbursed and reset.

---

## 8. OPERATIONAL TRIP OVERRIDE ENGINE (ANTI-LEAKAGE)
If a vehicle is marked Maintenance, Breakdown, or non-billable (`is_billable_day = FALSE`), but completed trips $> 0$ or generated digital fare earnings, the engine automatically:
1. Reclassifies attendance to `'Active (Trip Override)'`.
2. Marks `is_billable_day = TRUE`.
3. Bills standard contracted lease rent from `core_rent` (fallback: ₹856.00).

---

## 9. MULTI-DRIVER SHARED CAR DEDUPLICATION ENGINE
1. **Operator Isolation:** Operators receive trip metrics only if tagged with their vendor code or untagged when no individual driver drove that shift.
2. **Double-Rent Protection:** Secondary drivers operating a vehicle on a date where the primary driver paid rent capture trip earnings with `net_daily_rent = 0.00`.

---

## 10. PRIOR-PERIOD ADJUSTMENT AUTO-ROUTING ENGINE
Trigger `trg_auto_route_prior_period_adjustment` intercepts adjustments occurring in locked past weeks before insert:
1. Assigns `settlement_week_id` to the currently active open week containing `CURRENT_DATE` (never routing into future weeks).
2. Sets `is_prior_period = TRUE` and `effective_date = CURRENT_DATE`.
3. Appends `[Prior Period from YYYY-MM-DD]` to remarks.

---

## 11. MONDAY 11:00 AM HARD LOCK & IMMUTABILITY GUARDS
1. Procedure `sp_check_and_enforce_monday_lock(p_target_week_id, p_locked_by)` freezes daily shifts, vehicle weekly rows, partner weekly rows, and locks the master week.
2. Triggers `trg_check_hisaab_daily_lock`, `trg_check_hisaab_vehicle_lock`, and `trg_check_hisaab_partner_lock` intercept `BEFORE INSERT OR UPDATE OR DELETE`, blocking direct raw inserts into locked weeks.
3. Trigger `trg_hisaab_week_lock_guard` prevents unauthorized unlocking of `hisaab_settlement_weeks`.

---

## 14. EXHAUSTIVE AUDIT CHRONOLOGY & REMEDIATIONS

### Audit Wave 1 (Initial Core Remediations)
1. Negative Roll-Forward Phantom Payouts: Eliminated ₹7.60M in duplicate partner disbursements.
2. Sign Polarity Ledger Model: Added `polarity` (`DEBIT` vs `CREDIT`) to `hisaab_adjustments_ledger`.
3. Master Adjustments Backfill: Ingested 11,788 approved adjustments (₹13.08M).
4. Trip Override on Lease Rent: Recovered 1,056 billable days (+₹641k rent in W37). Integrated Ola revenue.
5. Shared Vehicle Multi-Driver Dedup: Isolated operator telemetry from individual drivers.
6. Historical Week Locking: Enforced Monday 11:00 AM hard locks on historical cycles.
7. Multi-Grain Parity: Achieved 100% mathematical match (`diff = 0.00`) between vehicle and partner weekly.

### Audit Wave 2 (Latent Defects Remediations)
1. **Partner Weekly Cash Corruption (Defect 1):** Fixed `total_cash_collected` to sum Uber cash + Ola cash + Rapido cash. Eliminated ₹3.38M reporting variance.
2. **Interim Payments in Formula (Defect 2):** Preserved and subtracted `amount_paid_during_week` from `total_outstanding`.
3. **Accident Damage Double-Counting (Defect 3):** Disentangled accident debits from challans using mutually exclusive classification.
4. **Rapido Ideal GPS Buffer (Defect 4):** Added Rapido trip km to `in_trip_km` and `rapido_trips * 3.00` to `ideal_gps_km`.
5. **Prior-Period Target Week Routing (Defect 5):** Fixed trigger to route to open cycle containing `CURRENT_DATE`, preventing adjustments from vanishing into future weeks.
6. **Direct Insert Guards (Defect 7):** Expanded immutability triggers to `BEFORE INSERT OR UPDATE OR DELETE` across daily, vehicle weekly, and partner weekly tables.
7. **Master Week Lock Guard & Week 37 Cutoff (Defect 8):** Added `trg_hisaab_week_lock_guard` and executed scheduled lock cutoff on past-due Week 37.
8. **Pipeline Script Hardening:** Updated `automation_script.py` to union `hisaab_adjustments_ledger`, pass `locked_by`, and re-raise exceptions on failure.

---

## 15. LIVE VERIFICATION SCORECARD (WEEKS 25 TO 38)

| Week ID | Status | Daily Rows | Billed Days | Net Lease Rent | Ola Net Revenue | Vehicle Current O/S | Partner Current O/S | Bank Payout | To Collect | Parity |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **CY26WK25** | `LOCKED` | 0 | 0 | ₹0.00 | ₹0.00 | ₹0.00 | ₹0.00 | ₹0.00 | ₹0.00 | **MATCH** |
| **CY26WK26** | `LOCKED` | 8,637 | 5,706 | ₹5,112,067.00 | ₹1,051,015.65 | ₹2,068,574.47 | ₹2,068,574.47 | ₹821,013.09 | ₹2,889,587.56 | **MATCH** |
| **CY26WK27** | `LOCKED` | 7,245 | 5,701 | ₹5,255,765.00 | ₹890,563.49 | ₹1,638,108.14 | ₹1,638,108.14 | ₹521,916.64 | ₹5,041,250.61 | **MATCH** |
| **CY26WK36** | `LOCKED` | 10,009 | 7,342 | ₹5,445,578.00 | ₹747,740.67 | ₹2,707,427.00 | ₹2,707,427.00 | ₹856,115.63 | ₹3,325,818.63 | **MATCH** |
| **CY26WK37** | `LOCKED` | 11,550 | 8,443 | ₹7,048,130.00 | ₹714,094.18 | ₹3,447,415.00 | ₹3,447,415.00 | ₹897,482.53 | ₹4,344,897.53 | **MATCH** |
| **CY26WK38** | `OPEN` | 5,944 | 4,120 | ₹2,695,714.00 | ₹168,880.98 | ₹4,028,424.98 | ₹4,028,424.98 | ₹9,178,869.38 | ₹2,378,134.87 | **MATCH** |

*All weeks evaluated display exact mathematical zero-variance parity (`diff = 0.00`).*
