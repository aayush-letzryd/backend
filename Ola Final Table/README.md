# Ola Final Table Architecture & Production Ledger Runbook

## 1. System Mission & Scope

The **Ola Final Table** pipeline is the definitive operational authority for Ola fleet rides, driver telemetry, revenue accounting, and weekly settlement at LetzRyd. It aggregates raw trip booking telemetry (`ola_raw_crns`) and financial transactions (`ola_raw_transactions`) into clean, queryable core ledgers:

1. **`public.core_ola_daily`**: Daily operational telemetry and financial balances per vehicle.
2. **`public.core_ola_weekly`**: Weekly consolidated settlement metrics per vehicle matching the production Hisaab workbook.

---

## 2. Multi-Layer Architecture & Data Flow

```
========================================================================================
                                LAYER 1: RAW INGESTION
========================================================================================
  * ola_raw_crns                       (19,319+ rows, CRN trip records, fares, tolls)
  * ola_raw_transactions               (2,333+ rows, itemized financial transactions)
                                      |
                                      v
========================================================================================
                          LAYER 2: CORE SYNTHESIS & ENRICHMENT
========================================================================================
  * core_daily_vehicle_status          (resolves driver allocation & city)
  * Plate Normalization Engine         (UPPER(REPLACE(vehicle_number, ' ', '')))
  * Ledger Sign Resolution Engine      (Credit: + / Debit: -)
                                      |
                                      v
========================================================================================
                          LAYER 3: FINAL PRODUCTION CORE TABLES
========================================================================================
  * public.core_ola_daily              (Daily grain: service_date + vehicle_number)
  * public.core_ola_weekly             (Weekly grain: week_start + week_end + vehicle)
```

---

## 3. Production Schemas

### 3.1 `public.core_ola_daily`
| Column Name | Data Type | Description |
| :--- | :--- | :--- |
| `id` | `BIGSERIAL (PK)` | Unique row identifier |
| `service_date` | `DATE NOT NULL` | Operational ride date (`stmt_date` / `date_for`) |
| `vehicle_number` | `VARCHAR(32) NOT NULL` | Clean alphanumeric plate (e.g. `KA05AP6033`) |
| `city` | `VARCHAR(32)` | Operating city (`Bengaluru`, `Hyderabad`, `Mumbai`) |
| `primary_driver_name` | `VARCHAR(128)` | Assigned driver name |
| `completed_trips` | `INT DEFAULT 0` | Total completed trips |
| `cancelled_trips` | `INT DEFAULT 0` | Total cancelled trips |
| `total_kms` | `NUMERIC(10,2)` | Total kilometers travelled |
| `operator_bill` | `NUMERIC(12,2)` | Net Ola revenue payable to LetzRyd (Hisaab basis) |
| `toll_and_parking` | `NUMERIC(12,2)` | Toll reimbursements |
| `cash_collected` | `NUMERIC(12,2)` | Rider cash collected by driver |
| `net_ola_to_pay` | `NUMERIC(12,2)` | Net portal payout balance |
| `daily_driver_balance` | `NUMERIC(12,2)` | Daily net balance |

### 3.2 `public.core_ola_weekly`
| Column Name | Data Type | Description |
| :--- | :--- | :--- |
| `id` | `BIGSERIAL (PK)` | Unique row identifier |
| `week_id` | `VARCHAR(32) NOT NULL` | Standardized ID (e.g. `CY26WK34`) |
| `week_start` | `DATE NOT NULL` | Monday of billing cycle |
| `week_end` | `DATE NOT NULL` | Sunday of billing cycle |
| `vehicle_number` | `VARCHAR(32) NOT NULL` | Standardized registration plate |
| `city` | `VARCHAR(32)` | Operating city |
| `vendor_code` | `VARCHAR(64)` | Assigned LetzRyd partner ID |
| `onroad_days` | `INT DEFAULT 0` | Distinct days with completed trips |
| `completed_trips` | `INT DEFAULT 0` | Weekly completed trips |
| `ola_net_revenue` | `NUMERIC(12,2)` | Weekly net revenue (`operator_bill`) $\to$ Hisaab |
| `ola_toll` | `NUMERIC(12,2)` | Weekly FASTag toll reimbursements $\to$ Hisaab |
| `ola_cash_collected` | `NUMERIC(12,2)` | Driver cash collection |
| `ola_portal_incentive` | `NUMERIC(12,2)` | Portal incentives |
| `ola_online_payment_deductions` | `NUMERIC(12,2)` | Online payouts debited |
| `ola_week_outstanding` | `NUMERIC(12,2)` | Final weekly Ola contribution |

---

## 4. Key Financial Rules

1. **`operator_bill_raw` is the Real Revenue:**
   - Hisaab's `OLA Net Revenue` maps strictly to `operator_bill_raw` (net after Ola platform commission), not `customer_bill_raw`.
2. **Cash is an Asset Offset:**
   - Cash collected by driver is stored as positive magnitude in summary and subtracted from company payout to driver.
3. **Transaction Ledger Signs:**
   - In `ola_raw_transactions`, amounts are unsigned decimals. The financial direction is governed by `payment_type`: `credit` (+ money to driver) vs `debit` (- money from driver).

---

## 5. Deployment & Execution Runbook

Run the pipeline manually or via scheduled Cloud Scheduler / Cron:
```bash
python "Ola Final Table/automation_script.py"
```
