# Master Vehicle Dropoff Pipeline: Single Source of Truth (`public.core_dropoffs`)

## 1. Executive Summary & System Architecture Overview

The **Master Vehicle Dropoff Pipeline** unifies vehicle return, driver attrition, maintenance custody handovers, and outstanding driver liabilities from two independent production systems into a single, high-performance, real-time Single Source of Truth (SSOT) table in PostgreSQL: **`public.core_dropoffs`**.

### Operational Context & Role in LetzRyd Platform
Vehicle drop-offs represent the critical custody handover event where a driver returns an operating vehicle to a LetzRyd hub. This event:
1. Concludes the driver vehicle custody period in the trip interval pairing engine (`v_vehicle_trip_intervals`).
2. Updates daily fleet availability states in the attendance ledger (`core_daily_vehicle_status`).
3. Establishes the finalized recovery deductions (Ola/Uber negative balances, unpaid vehicle rent, FASTag tolls, and workshop repair damage penalties) for the LetzRyd Hisaab settlement engine.

### Upstream Intake Systems
1. **Google Sheets Operational Pipeline (`public.sheet_dropoffs`)**:
   - Continuous intake from ground fleet operations teams across Bengaluru, Hyderabad, Mumbai, Pune, and Delhi hubs.
   - Total volume: 6,492 raw records.
2. **Web Portal Digital Dropoff Form (`public.july_vehicle_dropoffs`)**:
   - Digital handover and workshop inspection intake with granular dues, physical damage penalties, and supervisor remarks.
   - Total volume: 121 records.

### Live Production State
- **Master Table Total Rows**: 6,531
- **Active Master Records**: 6,397 (`is_deleted = FALSE`)
- **Soft-Deleted Historical Records**: 134 (`is_deleted = TRUE`, including 27 quarantined test records and 107 collapsed older same-driver submissions)
- **Total Table Columns**: 22 (includes dedicated `sheet_dropoff_id` and `portal_dropoff_id` foreign keys)
- **Gapless Sequential Continuity**: IDs 1 to 6,531 (0 sequence gaps)
- **Source Provenance Breakdown**:
  - `GOOGLE_SHEET`: 6,254 active records
  - `MERGED`: 114 active records
  - `PORTAL_FORM`: 29 active records (27 test records safely soft-deleted)
- **Multi-Driver Same-Day Events**: 55 valid same-day multi-driver handovers preserved

### End-to-End System Architecture Diagram

```
+---------------------------------------------------------------------------------------------------+
|                                    OPERATIONAL INTAKE SOURCES                                     |
+----------------------------------------------------+----------------------------------------------+
| 1. Google Sheets "Drop off History"                | 2. Web Portal Dropoff Form                   |
|    (Fleet Operations Field Teams)                  |    (Hub Inspection & Financial Settlement)   |
+----------------------------------------------------+----------------------------------------------+
                          |                                                  |
                          | Google Apps Script JDBC Ingestion                | FastAPI Web Portal Backend
                          v                                                  v
+----------------------------------------------------+----------------------------------------------+
| public.sheet_dropoffs                              | public.july_vehicle_dropoffs                 |
| (6,492 rows - 14 columns)                          | (121 rows - 12 columns)                      |
+----------------------------------------------------+----------------------------------------------+
                          |                                                  |
                AFTER INSERT/UPDATE/DELETE                         AFTER INSERT/UPDATE/DELETE
                [trg_sheet_dropoffs_sync]                          [trg_july_vehicle_dropoffs_sync]
                          |                                                  |
                          +------------------------+-------------------------+
                                                   |
                                                   v  (Transactional Advisory Lock: 777444555)
                                 +-----------------------------------+
                                 |     POSTGRESQL TRIGGER ENGINE     |
                                 |  * Registration Plate Hygiene     |
                                 |  * City & Driver Type Resolution  |
                                 |  * Cross-Source Match & Merge     |
                                 |  * Signed Debt Polarity Contract  |
                                 |  * Gapless Sequence: MAX(id) + 1  |
                                 |  * Soft-Delete: is_deleted = TRUE |
                                 +-----------------------------------+
                                                   |
                                                   v  (<10ms Live Latency)
                                 +-----------------------------------+
                                 |        MASTER DESTINATION         |
                                 |        public.core_dropoffs       |
                                 |     (6,379 Consolidated Rows)     |
                                 +-----------------------------------+
                                                   |
                                                   +---------------+
                                                   |               |
                                                   v               v
                                  +--------------------+  +--------------------+
                                  | Active Dropoffs    |  | Soft-Deleted Audit |
                                  | (is_deleted=FALSE) |  | (is_deleted=TRUE)  |
                                  | 6,361 Active Rows  |  | 18 Preserved Rows  |
                                  +--------------------+  +--------------------+
                                                   |
                                                   v
                                  +------------------------------------+
                                  |      DOWNSTREAM CONSUMPTION        |
                                  |  1. v_vehicle_trip_intervals       |
                                  |  2. core_daily_vehicle_status      |
                                  |  3. LetzRyd Hisaab Deduction Engine|
                                  +------------------------------------+
```

---

## 2. The 6 Core Architectural Guarantees

1. **Strict 1..N Gapless ID Sequence (Zero Sequence Burning)**:
   - Eliminates sequence skipping caused by transactional rollbacks or multi-row trigger conflicts.
   - All write operations acquire exclusive transaction-level advisory lock `pg_advisory_xact_lock(777444555)`.
   - Primary key is assigned via `SELECT COALESCE(MAX(id), 0) + 1`.
   - Verified state: `MIN(id) = 1`, `MAX(id) = 6379`, `COUNT(*) = 6379`, `Gaps = 0`.

2. **Cross-Source Automatic Deduplication & Merging**:
   - Reconciles overlapping submissions matching on `(vehicle_number, return_date)`.
   - When a vehicle drop-off is submitted in both Google Sheets and the Web Portal, the portal inspection notes, dues, and penalties merge onto the existing record.
   - Provenance is marked as `data_source = 'MERGED'`, retaining composite reference tracking.

3. **Signed Debt Polarity Contract**:
   - Downstream Hisaab settlement engines require all liabilities, pending dues, and damage penalties to have negative polarity (`-500.00`).
   - Formula: `total_liability = -1.0 * (ABS(negative_balance) + ABS(pending_dues) + ABS(damage_penalty))`.
   - Prevents accidental credit inversions during driver payouts.

4. **Permanent Soft-Delete Protection**:
   - Deletions in upstream staging tables trigger an update setting `is_deleted = TRUE` and `deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.
   - Raw drop-off records are never hard-deleted, protecting historical vehicle tenure intervals.

5. **Pure Indian Standard Time (IST) Contract**:
   - All timestamps are stored as `TIMESTAMP WITHOUT TIME ZONE` normalized to `Asia/Kolkata`.
   - Completely prevents offset drift (+05:30) and day-boundary calculation errors.

6. **Defensive Ingestion & Registration Plate Hygiene**:
   - Registration numbers are trimmed, uppercased, and stripped of non-alphanumeric characters.
   - Restricts plates between 8 and 12 characters.
   - Automatically identifies and isolates web portal dummy entries (e.g. `TEST0485`).

---

## 3. Core Table Schema & Data Dictionary

Table Name: **`public.core_dropoffs`**  
Total Columns: **20**

| # | Column Name | Data Type | Constraints | Description |
|---|---|---|---|---|
| 1 | `id` | `BIGINT` | `PRIMARY KEY` | Gapless continuous integer sequence assigned via advisory lock `777444555`. |
| 2 | `dropoff_id` | `VARCHAR(50)` | `UNIQUE NOT NULL` | Plain numerical business identifier matching `id::TEXT` (`'1578'`). |
| 3 | `sheet_dropoff_id` | `BIGINT` | Nullable | Relational foreign key reference linking directly to `sheet_dropoffs(dropoff_id)`. |
| 4 | `portal_dropoff_id` | `INTEGER` | Nullable | Relational foreign key reference linking directly to `july_vehicle_dropoffs(id)`. |
| 5 | `return_date` | `DATE` | `NOT NULL` | Standardized ISO calendar date of vehicle return (`YYYY-MM-DD`). |
| 6 | `return_type` | `VARCHAR(50)` | `NOT NULL` | Classification: `Attrition`, `Repair and Maintenance`, `Force Recovery`. |
| 7 | `driver_id` | `VARCHAR(50)` | Nullable | Identifier linking to `core_partner_onboarding` (e.g. `LETZBLRIP9876543210`). |
| 8 | `driver_name` | `VARCHAR(255)` | Nullable | Driver full name, standardized with Title Case. |
| 9 | `driver_type` | `VARCHAR(30)` | Nullable | Driver classification: `Individual` or `Operator`. |
| 10 | `vehicle_number` | `VARCHAR(20)` | `NOT NULL` | Normalized uppercase alphanumeric vehicle plate (8-12 characters). |
| 11 | `city` | `VARCHAR(50)` | `NOT NULL` | Canonical city: `Bengaluru`, `Hyderabad`, `Mumbai`, `Pune`, `Delhi`. |
| 12 | `negative_balance` | `NUMERIC(12,2)` | `DEFAULT 0.00` | Signed negative liability from Ola/Uber balances. |
| 13 | `pending_dues` | `NUMERIC(12,2)` | `DEFAULT 0.00` | Signed negative liability from unpaid vehicle rent and tolls. |
| 14 | `damage_penalty` | `NUMERIC(12,2)` | `DEFAULT 0.00` | Signed negative liability from vehicle body and mechanical damage. |
| 15 | `total_liability` | `NUMERIC(12,2)` | `DEFAULT 0.00` | Total driver liability: `negative_balance + pending_dues + damage_penalty`. |
| 16 | `remarks` | `TEXT` | Nullable | Detailed handover notes, inspection comments, or reason for return. |
| 17 | `data_source` | `VARCHAR(50)` | `NOT NULL` | Source provenance: `GOOGLE_SHEET`, `PORTAL_FORM`, or `MERGED`. |
| 18 | `source_reference_id` | `VARCHAR(100)` | Nullable | Plain numerical upstream system reference pointer (`'1402'`, `'88'`, or `'1402,88'`). |
| 19 | `is_deleted` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Soft-delete flag for audit preservation. |
| 20 | `deleted_at` | `TIMESTAMP WITHOUT TIME ZONE` | Nullable | IST timestamp when record was soft-deleted. |
| 21 | `created_at` | `TIMESTAMP WITHOUT TIME ZONE` | `DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')` | Pure IST record creation timestamp. |
| 22 | `updated_at` | `TIMESTAMP WITHOUT TIME ZONE` | `DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')` | Pure IST record modification timestamp. |

---

## 4. Synchronization Triggers & Deduplication Logic

### Trigger 1: `trg_sheet_dropoffs_sync` on `public.sheet_dropoffs`
- **Execution Event**: `AFTER INSERT OR UPDATE OR DELETE ON public.sheet_dropoffs FOR EACH ROW`
- **Function**: `public.fn_sync_sheet_dropoffs()`
- **Logic**:
  1. Acquires transactional advisory lock `777444555`.
  2. On `DELETE`: Performs soft-delete `UPDATE public.core_dropoffs SET is_deleted = TRUE` where `source_reference_id` matches.
  3. Sanitizes vehicle registration number and validates minimum length of 8 characters.
  4. Resolves canonical city using `fn_normalize_dropoff_city()` and driver type using `fn_resolve_driver_type()`.
  5. Enforces negative debt polarity on `negative_balance`.
  6. Checks if drop-off event already exists on `(vehicle_number, return_date)`:
     - If found: Updates existing record, merges liabilities, and updates `updated_at`.
     - If new: Fetches `MAX(id) + 1` and inserts row with `data_source = 'GOOGLE_SHEET'`.

### Trigger 2: `trg_july_vehicle_dropoffs_sync` on `public.july_vehicle_dropoffs`
- **Execution Event**: `AFTER INSERT OR UPDATE OR DELETE ON public.july_vehicle_dropoffs FOR EACH ROW`
- **Function**: `public.fn_sync_july_vehicle_dropoffs()`
- **Logic**:
  1. Acquires transactional advisory lock `777444555`.
  2. On `DELETE`: Sets `is_deleted = TRUE` if record originated as `PORTAL_FORM`.
  3. Sanitizes plate and skips invalid test patterns (`TEST`, `DUMMY`).
  4. Parses multi-format return dates (`YYYY-MM-DD` and `DD/MM/YYYY`).
  5. Seeks existing matching drop-off record in `core_dropoffs` on `(vehicle_number, return_date)`:
     - If existing sheet record found: Overlays portal inspection remarks, pending dues, and damage penalties. Updates provenance to `data_source = 'MERGED'`.
     - If new standalone portal entry: Assigns `MAX(id) + 1`, inserts row with `data_source = 'PORTAL_FORM'`.

---

## 5. Full Refresh Consolidation Stored Procedure

Procedure Name: **`public.refresh_core_dropoffs()`**  
Return Type: `INTEGER` (Number of newly consolidated records)

### Operational Flow
```sql
SELECT public.refresh_core_dropoffs();
```

1. **Advisory Lock**: Acquires `pg_advisory_xact_lock(777444555)`.
2. **Phase 1 - Sheet Ingestion**:
   - Loops through `public.sheet_dropoffs` ordered by `return_date ASC, dropoff_id ASC`.
   - Filters invalid plates and header noise.
   - Upserts into `public.core_dropoffs`.
3. **Phase 2 - Portal Ingestion & Overlay**:
   - Loops through `public.july_vehicle_dropoffs` ordered by `id ASC`.
   - Merges portal liabilities onto matching sheet records (`data_source = 'MERGED'`).
   - Inserts unlinked portal returns as `PORTAL_FORM`.
4. **Phase 3 - Redundant Duplicate Purging**:
   - Executes partition deduplication on `(vehicle_number, return_date)`.
   - Soft-deletes any duplicate entries, preserving merged records as priority.
5. **Phase 4 - Completion Reporting**:
   - Returns count of processed records.

---

## 6. Active View & Downstream Integration

### View Definition: `public.active_core_dropoffs`
```sql
CREATE OR REPLACE VIEW public.active_core_dropoffs AS
SELECT 
    id,
    dropoff_id,
    return_date,
    return_type,
    driver_id,
    driver_name,
    driver_type,
    vehicle_number,
    city,
    negative_balance,
    pending_dues,
    damage_penalty,
    total_liability,
    remarks,
    data_source,
    source_reference_id,
    created_at,
    updated_at
FROM public.core_dropoffs
WHERE is_deleted = FALSE;
```

### Integration 1: Continuous Trip Intervals (`public.v_vehicle_trip_intervals`)
The trip interval view laterally joins `core_vehicle_allocation` with `core_dropoffs` to establish driver custody periods:
```sql
LEFT JOIN LATERAL (
    SELECT 
        d.id,
        d.return_date,
        d.return_type,
        d.negative_balance
    FROM public.core_dropoffs d
    WHERE d.is_deleted = FALSE
      AND d.vehicle_number = ra.vehicle_number
      AND (
          (d.return_date > ra.allocation_date)
          OR (d.return_date = ra.allocation_date AND (d.driver_id = ra.partner_id OR ra.partner_id IS NULL))
      )
      AND (ra.next_allocation_date IS NULL OR d.return_date <= ra.next_allocation_date)
    ORDER BY d.return_date ASC, d.id ASC
    LIMIT 1
) d ON TRUE;
```

### Integration 2: Daily Fleet Status Engine (`public.core_daily_vehicle_status`)
When `sp_generate_daily_vehicle_status(target_date)` executes:
- Vehicles dropping off with `return_type = 'Attrition'` or `'Force Recovery'` transition immediately to `Yard` (`Available` or `Impounded`).
- Vehicles dropping off with `return_type = 'Repair and Maintenance'` transition to `Off Road` (`Maintenance`).
- For Individual Partners (`IP`), driver tenure remains active during maintenance until superseded by a new allocation event.

---

## 7. Automated Verification & Health Checks

The repository includes a production health check and audit CLI: [`automation_script.py`](./automation_script.py).

### Commands

1. **Run Full Database Health & Integrity Audit**:
   ```bash
   python automation_script.py --audit
   ```
   Verifies:
   - 20-column schema compliance.
   - Master record counts (6,379 total, 6,361 active, 18 soft-deleted).
   - Upstream reconciliation (6,492 sheet rows, 121 portal rows).
   - Gapless continuous integer sequence 1..N (0 gaps).
   - Zero duplicate drop-off events on `(vehicle_number, return_date)` in active view.
   - 100% negative debt polarity and mathematical balance.
   - Clean IST timestamps (`timestamp without time zone`).

2. **Execute Full Consolidation Refresh**:
   ```bash
   python automation_script.py --refresh
   ```

3. **Verify Live Trigger Synchronizations**:
   ```bash
   python automation_script.py --verify-triggers
   ```
   Executes live test cycle:
   - Tests Sheet INSERT synchronization.
   - Tests Sheet UPDATE modification.
   - Tests Portal overlay and automatic transition to `data_source = 'MERGED'`.
   - Tests Soft-delete handling.
   - Non-destructively removes test rows and verifies sequence continuity.

---

## 8. Operational Queries for Data Engineering & Analytics

### Query 1: Source Distribution & Financial Exposure
```sql
SELECT 
    data_source,
    COUNT(*) AS total_records,
    COUNT(*) FILTER (WHERE is_deleted = FALSE) AS active_records,
    COUNT(DISTINCT vehicle_number) AS unique_vehicles,
    ROUND(SUM(negative_balance), 2) AS total_negative_balance,
    ROUND(SUM(pending_dues), 2) AS total_pending_dues,
    ROUND(SUM(damage_penalty), 2) AS total_damage_penalties,
    ROUND(SUM(total_liability), 2) AS total_recovery_liability
FROM public.core_dropoffs
GROUP BY data_source
ORDER BY total_records DESC;
```

### Query 2: Gapless Sequence Continuity Audit
```sql
SELECT 
    MIN(id) AS min_id,
    MAX(id) AS max_id,
    COUNT(*) AS total_rows,
    MAX(id) - COUNT(*) AS sequence_gaps,
    CASE 
        WHEN COUNT(*) = MAX(id) AND MIN(id) = 1 
        THEN 'PASSED: 100% Continuous 1..N Sequence'
        ELSE 'FAILED: Sequence Gaps Detected'
    END AS sequence_health
FROM public.core_dropoffs;
```

### Query 3: Missing Sequence IDs Enumerator
```sql
SELECT s.i AS missing_id
FROM generate_series(1, COALESCE((SELECT MAX(id) FROM public.core_dropoffs), 0)) s(i)
LEFT JOIN public.core_dropoffs c ON s.i = c.id
WHERE c.id IS NULL;
```

### Query 4: City Fleet Return Distribution
```sql
SELECT 
    city,
    COUNT(*) AS total_dropoffs,
    COUNT(DISTINCT vehicle_number) AS unique_vehicles,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS percentage_share
FROM public.active_core_dropoffs
GROUP BY city
ORDER BY total_dropoffs DESC;
```

### Query 5: Operational Return Type Breakdown
```sql
SELECT 
    return_type,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS percentage_share,
    ROUND(AVG(total_liability), 2) AS avg_liability_per_return
FROM public.active_core_dropoffs
GROUP BY return_type
ORDER BY count DESC;
```
