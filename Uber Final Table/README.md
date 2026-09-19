# Uber Final Table Architecture & Production Ledger Runbook

## 1. System Mission & Scope

The **Uber Final Table** pipeline is the definitive operational authority for Uber fleet performance, driver earnings, and weekly settlement at LetzRyd. It aggregates raw API ride streams, payment transactions, and vehicle milestone incentives into clean, queryable core ledgers:

1. **`public.core_uber_daily`**: Daily operational telemetry and financial balances per vehicle and driver shift.
2. **`public.core_uber_weekly`**: Weekly consolidated settlement metrics per vehicle and operator matching the production Hisaab workbook.

---

## 2. Multi-Layer Decoupled Architecture & Data Flow

```
========================================================================================
                                LAYER 1: RAW INGESTION
========================================================================================
  * uber_pipeline_trips                (300k+ rows, ride timestamps, GPS, distance)
  * uber_pipeline_order_transactions   (270k+ rows, fare credits, cash collections)
  * uber_vehicle_incentives_raw        (117k+ rows, target milestone bonuses)
                                      |
                                      | (100% Lock-Free, Zero Triggers on Raw Tables)
                                      v
========================================================================================
                    LAYER 2: ASYNCHRONOUS SYNTHESIS & ENRICHMENT
========================================================================================
  * Scheduler: PostgreSQL pg_cron      (Job 'sync-core-uber' running every 30 minutes)
  * Stored Procedure: sp_sync_core_uber(lookback_days)
  * 04:00 AM IST Shift Cutoff Engine   (((trip_request_time - interval '4 hours')::date))
  * Plate Normalization Engine         (UPPER(REPLACE(car_no, ' ', '')))
  * Driver & City Attribution          (core_daily_vehicle_status mapping)
  * Multi-Tier Plate Fallback Cascade  (trip_uuid -> plate regex -> driver-date lookup)
                                      |
                                      v
========================================================================================
                    LAYER 3: FINAL PRODUCTION CORE TABLES
========================================================================================
  * public.core_uber_daily             (Daily grain: operational_date + vehicle + driver)
  * public.core_uber_weekly            (Weekly grain: settlement_week + vehicle + vendor)
```

---

## 3. Production Schemas

### 3.1 `public.core_uber_daily`
| Column Name | Data Type | Description |
| :--- | :--- | :--- |
| `id` | `BIGSERIAL (PK)` | Unique row identifier |
| `operational_date` | `DATE NOT NULL` | Shift date after applying 04:00 AM IST cutoff |
| `vehicle_number` | `VARCHAR(32) NOT NULL` | Clean alphanumeric plate (e.g. `TG07T3202`) |
| `driver_uuid` | `VARCHAR(64)` | Uber driver UUID |
| `vendor_code` | `VARCHAR(64)` | Assigned LetzRyd partner ID (`core_daily_vehicle_status`) |
| `city` | `VARCHAR(32)` | Operating city (`Hyderabad`, `Bengaluru`, `Mumbai`) |
| `completed_trips` | `INT DEFAULT 0` | Total completed trips on that operational day (`LOWER(trip_status) = 'completed'`) |
| `total_trip_distance_km` | `NUMERIC(10,2)` | Total trip kilometers completed |
| `net_fare_earnings` | `NUMERIC(12,2)` | Gross passenger fares earned |
| `cash_collected` | `NUMERIC(12,2)` | Rider cash kept by driver (positive display) |
| `tolls_refunded` | `NUMERIC(12,2)` | FASTag highway tolls reimbursed |
| `driver_subscription_charge` | `NUMERIC(12,2)` | Platform access & Drive Pass fees debited |
| `net_driver_day_balance` | `NUMERIC(12,2)` | `net_fare_earnings - cash_collected + tolls - sub_charge` |

### 3.2 `public.core_uber_weekly`
| Column Name | Data Type | Description |
| :--- | :--- | :--- |
| `id` | `BIGSERIAL (PK)` | Unique row identifier |
| `settlement_year` | `INT NOT NULL` | ISO Year (e.g. `2026`) |
| `settlement_week` | `INT NOT NULL` | ISO Week Number (e.g. `26`, `37`) |
| `week_id` | `VARCHAR(32) NOT NULL` | Standardized ID (e.g. `CY26WK37`) |
| `week_start` | `DATE NOT NULL` | Monday of billing cycle |
| `week_end` | `DATE NOT NULL` | Sunday of billing cycle |
| `vehicle_number` | `VARCHAR(32) NOT NULL` | Standardized registration plate |
| `vendor_code` | `VARCHAR(64)` | Assigned operator / driver ID |
| `active_days` | `INT DEFAULT 0` | Distinct days with completed trips |
| `completed_trips` | `INT DEFAULT 0` | Weekly completed trips |
| `uber_total_earnings` | `NUMERIC(12,2)` | Total weekly fare earnings $\to$ Hisaab |
| `uber_cash_collection` | `NUMERIC(12,2)` | Driver cash collection $\to$ Hisaab |
| `uber_toll` | `NUMERIC(12,2)` | FASTag toll reimbursement $\to$ Hisaab |
| `uber_driver_sub_charge` | `NUMERIC(12,2)` | Weekly subscription fees |
| `uber_vehicle_incentive` | `NUMERIC(12,2)` | Weekly target incentive bonus (de-duplicated) |
| `uber_week_balance` | `NUMERIC(12,2)` | Final weekly Uber contribution |

---

## 4. Key Architectural Guarantees & Constraints

1. **Zero Database Triggers on Raw Ingestion:**
   * Raw tables (`uber_pipeline_trips`, `uber_pipeline_order_transactions`, `uber_vehicle_incentives_raw`) have **strictly zero triggers**.
   * Live streaming and batch ingestion operate with 100% fault isolation and zero lock contention.
2. **04:00 AM IST Shift Cutoff:**
   * Any trip between 00:00:00 and 03:59:59 AM IST belongs to the previous calendar day's shift.
3. **Correct Sign Arithmetic:**
   * Driver cash kept is treated as a positive unsigned quantity and subtracted from earnings to produce true net driver balances.
4. **Scheduled Background Processing:**
   * Automated via `pg_cron` running every 30 minutes (`*/30 * * * *`) via `CALL public.sp_sync_core_uber(NULL, NULL, 7);`.

---

## 5. Execution Runbook

### Automatic Schedule:
Managed via PostgreSQL `pg_cron` job `sync-core-uber`:
```sql
SELECT * FROM cron.job WHERE jobname = 'sync-core-uber';
SELECT * FROM cron.job_run_details WHERE jobid = 3 ORDER BY start_time DESC LIMIT 5;
```

### Manual Trigger / Backfill via CLI:
```bash
# Default 7-day rolling window:
python "Uber Final Table/automation_script.py"

# Custom 30-day window:
python "Uber Final Table/automation_script.py" --lookback 30

# Specific date range:
python "Uber Final Table/automation_script.py" --start 2026-08-23 --end 2026-09-19
```
