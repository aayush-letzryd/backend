# Knowledge Transfer Runbook: Vehicle Status Google Sheet Ingestion Pipeline

## 1. Architectural Overview & System Role

The `sheet_vehicle_status` pipeline serves as the primary staging layer (Layer 1) for daily fleet operational attendance and state tracking across LetzRyd operations. It ingests data directly from the Daily Operations Tracker spreadsheet (`Vehicle Status List V3.xlsx` / `Daily Vehicle Status` tab) into PostgreSQL table `public.sheet_vehicle_status`.

```
========================================================================================
                                3-LAYER ARCHITECTURAL OVERVIEW
========================================================================================

  LAYER 1: RAW INGESTION TABLES (Google Sheets Staging)
  ┌───────────────────────────────┐
  │  public.sheet_vehicle_status  │ <--- Ingested by vehicle_status_pipeline_appscript.js
  └───────────────┬───────────────┘
                  │
                  ▼
  LAYER 2: UNIFIED CORE TRANSACTIONAL TABLES
  ┌───────────────────────────────┐      ┌───────────────────────────────┐
  │   public.core_maintenance     │ <--- │ Historical maintenance events │
  │                               │      │ extracted from status rows    │
  └───────────────┬───────────────┘      └───────────────────────────────┘
                  │
                  ▼
  LAYER 3: FINAL OPERATIONAL STATUS OUTPUTS
  ┌─────────────────────────────────┐    ┌─────────────────────────────────┐
  │ public.v_current_live_fleet_st..│    │ public.core_daily_vehicle_status│
  │ (Real-time live status)         │    │ (Daily calendar attendance)     │
  └─────────────────────────────────┘    └─────────────────────────────────┘
========================================================================================
```

### Core Responsibilities
1. **Attendance Ledger**: Captures daily snapshots of every vehicle in the fleet (Active, Maintenance, RFD, Allocation, Drop Off).
2. **Maintenance Historical Baseline**: Acts as the primary historical record for workshop downtime prior to Web Portal maintenance module rollout.
3. **Audit Lineage**: Retains original spreadsheet row numbers (`sheet_row_number`) and system ingestion timestamps (`created_at`, `updated_at`).

---

## 2. Pipeline Flow & Technical Architecture

```
┌────────────────────────────────┐
│  Daily Vehicle Status Sheet    │
│  (1,041 cars x 31 daily dates) │
└───────────────┬────────────────┘
                │
                │ 1. Dynamic Header Mapping (buildHeaderIndexMap)
                │ 2. Row Sanitization (cleanDate, cleanVehicleNumber, cleanPartnerId)
                ▼
┌────────────────────────────────┐
│   Google Apps Script Engine    │
│  - LockService Script Lock     │
│  - PropertiesService Config    │
│  - 200-Row Batches             │
└───────────────┬────────────────┘
                │
                │ 3. JDBC Connection (SSL enabled)
                │ 4. Transaction Demarcation (setAutoCommit(false))
                │ 5. Zero-Burn CTE Upsert Execution
                ▼
┌────────────────────────────────┐
│    PostgreSQL 14+ Database     │
│  public.sheet_vehicle_status   │
│  Conflict: (status_date, plate)│
└────────────────────────────────┘
```

### Key Engineering Features
- **Zero-Burn Sequence ID CTE**: High-frequency upserts frequently cause standard PostgreSQL `SERIAL` sequences to increment even when rows are updated rather than inserted. The pipeline uses a Common Table Expression (CTE) where `nextval()` is only evaluated for rows that do not exist in the update set.
- **LockService Concurrency Control**: Prevents concurrent execution of triggers. If a sync job is actively running, subsequent trigger runs gracefully exit without creating connection pool exhaustion.
- **Dynamic Header Indexing**: Column positions in operational spreadsheets often shift. The pipeline maps logical field names by inspecting row 1 dynamically rather than hardcoding column indices.
- **PropertiesService Secret Management**: Credentials are decoupled from code. Production setups store host, user, password, and port in Apps Script Script Properties.
- **Chunked JDBC Batching**: Records are processed in 200-row chunks with explicit `executeBatch()` and `commit()` calls, minimizing memory overhead and avoiding transaction buffer exhaustion.

---

## 3. Database Schema & Data Dictionary

Target Table: `public.sheet_vehicle_status`  
Primary Key: `id` (BIGSERIAL)  
Unique Constraint: `uq_sheet_vehicle_status (status_date, vehicle_number)`

| Column Name | Data Type | Nullable | Default | Source Header | Normalization Rules | Description |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `id` | BIGSERIAL | NO | `nextval(...)` | None | Sequence generated via zero-burn CTE | Synthetic surrogate primary key |
| `city` | VARCHAR(20) | YES | NULL | `City` | Standardized to `BLR`, `MUM`, `HYD` | Operating regional hub |
| `vehicle_number` | VARCHAR(20) | NO | - | `Vehicle Number` | Uppercase, whitespace and dashes stripped | Official registration plate |
| `status_date` | DATE | NO | - | `Date` / `Status Date` | Parsed to `YYYY-MM-DD` | Attendance calendar date |
| `allocation_date` | DATE | YES | NULL | `Allocation Date` | Parsed to `YYYY-MM-DD` | Handover date if reallocated |
| `dropoff_date` | DATE | YES | NULL | `Drop Off Date` | Parsed to `YYYY-MM-DD` | Return date if dropped off |
| `final_status` | VARCHAR(50) | NO | - | `Final Status` | Standardized casing and spacing | Status (`Active`, `RFD`, `Maintenance`) |
| `cohort` | VARCHAR(50) | YES | NULL | `Cohort` | Standardized to `On Road`, `Off Road` | High-level fleet grouping |
| `mapping_key` | VARCHAR(100) | YES | NULL | `Mapping` | Stored as string | Plate + Serial Date composite key |
| `partner_name` | VARCHAR(150) | YES | NULL | `partner Name` | Whitespace trimmed, placeholders to NULL | Name of driver or operator |
| `partner_id` | VARCHAR(50) | YES | NULL | `partner IDs` | Placeholders ('Maintenance', 'RFD') to NULL | Identifier (`LETZ...` or `LETZ...IP...`) |
| `new_partner_name`| VARCHAR(150) | YES | NULL | `New partner Name` | Whitespace trimmed | Replacement driver name or code |
| `vehicle_model` | VARCHAR(100) | YES | NULL | `Vehicle Model` | Whitespace trimmed | Vehicle make and model |
| `dm_name` | VARCHAR(100) | YES | NULL | `DM Name` | Placeholders ('-') to NULL | Assigned Delivery Manager |
| `vehicle_type` | VARCHAR(50) | YES | NULL | `Type` | Standardized to `Operator`, `Individual` | Contractual operating model |
| `sheet_row_number`| INTEGER | YES | NULL | Auto | Extracted row index | Source row number for auditability |
| `created_at` | TIMESTAMP | YES | `CURRENT_TIMESTAMP` | System | Auto-generated timestamp | Record creation timestamp in UTC |
| `updated_at` | TIMESTAMP | YES | `CURRENT_TIMESTAMP` | System | Updated on upsert | Record modification timestamp in UTC |

---

## 4. Setup and Configuration Guide

### Step 1: Create Database Table and Indexes
Execute `schema.sql` in target PostgreSQL database:
```bash
psql -h <DB_HOST> -U <DB_USER> -d <DB_NAME> -f schema.sql
```

### Step 2: Configure Apps Script Project
1. Open the target Google Sheet (`Daily Vehicle Status`).
2. Navigate to **Extensions** -> **Apps Script**.
3. Replace existing code in `Code.gs` with the content of `vehicle_status_pipeline_appscript.js`.
4. Navigate to **Project Settings** (gear icon) -> **Script Properties**.
5. Add the following properties:
   - `DB_HOST`: Database IP address or hostname.
   - `DB_PORT`: `5432`.
   - `DB_NAME`: Database name (e.g. `postgres`).
   - `DB_USER`: Database username.
   - `DB_PASSWORD`: Database password.
   - `TAB_NAME`: `Daily Vehicle Status`.
   - `BATCH_SIZE`: `200`.

### Step 3: Network & Security Configuration
PostgreSQL must accept inbound TCP connections from Google Apps Script IP ranges on port 5432.
- Configure firewall / security groups to whitelist Google Apps Script IP blocks.
- Ensure `pg_hba.conf` allows MD5/SCRAM authentication for the ingestion user:
```text
host    all    postgres    0.0.0.0/0    scram-sha-256
```

---

## 5. Execution Modes & Trigger Management

### Interactive Execution (Spreadsheet Menu)
Upon opening the spreadsheet, a custom menu `LetzRyd Vehicle Status Sync` appears:
1. **1. Test Database Connection**: Queries `public.sheet_vehicle_status` and alerts current row count and maximum sequence ID.
2. **2. Sync Recent Status Rows (500)**: Scans the most recent 500 rows and executes the zero-burn upsert. Runtime is typically 3 to 6 seconds.
3. **3. Sync Entire Sheet (Batch 200)**: Iterates across all data rows (e.g. 31,000+ rows) in 1,000-row memory blocks and 200-row transactional database commits.
4. **4. Install Automated 5-Min Trigger**: Installs a time-driven trigger executing `syncRecentVehicleStatus` every 5 minutes.
5. **5. Remove Automated Triggers**: Removes all project triggers to halt automated polling.

### Production Trigger Recommendation
- For continuous real-time sync: Install the **5-minute automated trigger** (`setupTriggers()`). This ensures updates made by operations teams are reflected in PostgreSQL within minutes while staying well inside Apps Script daily execution quotas.

---

## 6. Operational & Verification Queries

### 1. Ingestion Volume and Sequence Integrity
```sql
SELECT 
    COUNT(*) AS total_rows,
    MIN(id) AS min_id,
    MAX(id) AS max_id,
    COUNT(DISTINCT vehicle_number) AS distinct_vehicles,
    COUNT(DISTINCT status_date) AS distinct_dates
FROM public.sheet_vehicle_status;
```

### 2. Daily Fleet Operational Health Summary
```sql
SELECT 
    status_date,
    COUNT(*) AS total_fleet,
    COUNT(*) FILTER (WHERE final_status = 'Active') AS active_count,
    COUNT(*) FILTER (WHERE final_status = 'RFD') AS rfd_count,
    COUNT(*) FILTER (WHERE final_status = 'Maintenance') AS maintenance_count,
    COUNT(*) FILTER (WHERE final_status IN ('Allocation', 'Drop Off', 'Same Day D&A')) AS transition_count
FROM public.sheet_vehicle_status
GROUP BY status_date
ORDER BY status_date DESC
LIMIT 14;
```

### 3. City-Wise Fleet Status Distribution (Latest Date)
```sql
SELECT 
    city,
    final_status,
    COUNT(*) AS vehicle_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY city), 2) AS city_percentage
FROM public.sheet_vehicle_status
WHERE status_date = (SELECT MAX(status_date) FROM public.sheet_vehicle_status)
GROUP BY city, final_status
ORDER BY city, vehicle_count DESC;
```

### 4. Single Vehicle Lifecycle History
```sql
SELECT 
    status_date,
    final_status,
    cohort,
    partner_name,
    partner_id,
    dm_name,
    sheet_row_number
FROM public.sheet_vehicle_status
WHERE vehicle_number = 'KA05AP6038'
ORDER BY status_date DESC;
```

### 5. Historical Workshop Maintenance Records (Layer 2 Feed)
```sql
SELECT 
    vehicle_number,
    city,
    status_date AS workshop_date,
    vehicle_model,
    dm_name,
    sheet_row_number
FROM public.sheet_vehicle_status
WHERE final_status = 'Maintenance'
ORDER BY status_date DESC, city, vehicle_number;
```

---

## 7. Troubleshooting & Failure Runbook

### Issue 1: LockService Timeout
- **Symptom**: Execution log displays `Another sync operation is running. Aborting.`
- **Cause**: A previous execution is still running or failed without releasing the lock.
- **Remedy**: The lock automatically releases after 30 seconds. If stuck due to an unhandled script error, reload the sheet and re-run.

### Issue 2: JDBC Connection Failure
- **Symptom**: `Failed to establish database connection` or `Connection timed out`.
- **Cause**: PostgreSQL host IP changed, credentials expired, or cloud firewall blocked Google Cloud IP range.
- **Remedy**: Check database listener status (`sudo systemctl status postgresql`) and test network reachability. Verify credentials in Apps Script Script Properties.

### Issue 3: Apps Script Execution Timeout (6 Minutes Limit)
- **Symptom**: `Exceeded maximum execution time` during `syncFullVehicleStatus`.
- **Cause**: Full backfills of >50,000 rows exceed the 6-minute Google Apps Script execution boundary if processed row-by-row.
- **Remedy**: Ensure `syncFullVehicleStatus` is using 200-row batching (`config.batchSize = 200`). If backfilling massive historical archives (>100,000 rows), use an external Python migration script (`psycopg2` bulk copy) for initial seed, and reserve Apps Script for incremental 5-minute syncs.

### Issue 4: Duplicate Rows on Same Date
- **Symptom**: Spreadsheet contains duplicate entries for the same vehicle on the same date.
- **Resolution**: The PostgreSQL unique constraint `uq_sheet_vehicle_status (status_date, vehicle_number)` ensures no duplicate rows enter the database. The CTE upsert updates the existing row in place with the latest spreadsheet values.
