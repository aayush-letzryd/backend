# Uber Final Table Architecture & Production Ledger Runbook

## 1. System Mission & Scope

The **Uber Final Table** pipeline is the definitive operational authority for Uber fleet performance, driver earnings, and weekly settlement at LetzRyd. It aggregates raw API ride streams and order payment transactions into clean, queryable core ledgers:

1. **`public.core_uber_daily`**: Daily operational telemetry and financial balances per vehicle and driver shift.
2. **`public.core_uber_weekly`**: Weekly consolidated settlement metrics per vehicle and operator matching the production Hisaab workbook.

---

## 2. Multi-Layer Architecture & Data Flow

```
========================================================================================
                                LAYER 1: RAW INGESTION
========================================================================================
  * uber_pipeline_trips                (254k+ rows, ride timestamps, GPS, distance)
  * uber_pipeline_order_transactions   (233k+ rows, fare credits, cash collections)
  * uber_vehicle_incentives_raw        (38k+ rows, target milestone bonuses)
                                      |
                                      v
========================================================================================
                          LAYER 2: CORE SYNTHESIS & ENRICHMENT
========================================================================================
  * core_daily_vehicle_status          (resolves driver allocation & city)
  * 04:00 AM IST Shift Cutoff Engine   (shifts 00:00-03:59:59 to previous calendar day)
  * Plate Normalization Engine         (UPPER(REPLACE(car_no, ' ', '')))
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
| `completed_trips` | `INT DEFAULT 0` | Total completed trips on that operational day |
| `total_trip_distance_km` | `NUMERIC(10,2)` | Total trip kilometers completed |
| `net_fare_earnings` | `NUMERIC(12,2)` | Gross passenger fares earned |
| `cash_collected` | `NUMERIC(12,2)` | Rider cash kept by driver |
| `tolls_refunded` | `NUMERIC(12,2)` | FASTag highway tolls reimbursed |
| `driver_subscription_charge` | `NUMERIC(12,2)` | Platform access fees debited |
| `net_driver_day_balance` | `NUMERIC(12,2)` | `net_fare_earnings - cash_collected + tolls - sub_charge` |

### 3.2 `public.core_uber_weekly`
| Column Name | Data Type | Description |
| :--- | :--- | :--- |
| `id` | `BIGSERIAL (PK)` | Unique row identifier |
| `settlement_year` | `INT NOT NULL` | ISO Year (e.g. `2026`) |
| `settlement_week` | `INT NOT NULL` | ISO Week Number (e.g. `26`, `34`) |
| `week_id` | `VARCHAR(32) NOT NULL` | Standardized ID (e.g. `CY26WK26`) |
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
| `uber_vehicle_incentive` | `NUMERIC(12,2)` | Weekly target incentive bonus |
| `uber_week_balance` | `NUMERIC(12,2)` | Final weekly Uber contribution |

---

## 4. Operational Rules & Cutoffs

1. **The 04:00 AM IST Shift Rule:**
   - Any ride or order completed between `00:00:00` and `03:59:59` is attributed to the **previous calendar day**:
     ```sql
     (trip_request_time AT TIME ZONE 'Asia/Kolkata' - INTERVAL '4 hours')::date
     ```
2. **The `paid_to_you` Caveat:**
   - `paid_to_you` in Uber's raw transaction feed is net of driver cash collected and bank payouts.
   - We extract `net_fare_earnings` and `cash_collected` as distinct unsigned positive quantities to preserve full auditability.
3. **Multi-Driver Mid-Week Reallocations:**
   - If Vehicle A changes from Driver 1 to Driver 2 on Thursday, both `core_uber_daily` and `core_uber_weekly` partition the records by `(vehicle_number, vendor_code)`.

---

## 5. Deployment & Execution Runbook

Run the pipeline manually or via scheduled Cloud Scheduler / Cron:
```bash
python "Uber Final Table/automation_script.py"
```
