# Vehicle Dropoff Data Issues, Anomalies & Architectural Conflict Catalog

Master Table: `public.core_dropoffs`  
Active Filtered View: `public.active_core_dropoffs` (`WHERE is_deleted = FALSE`)  
Upstream Sources: `public.sheet_dropoffs` (6,492 rows) and `public.july_vehicle_dropoffs` (121 rows)  
Live Production Master Volume: 6,379 Total Rows (6,361 Active, 18 Soft-Deleted, 0 Sequence Gaps)  

---

## Technical Overview

The vehicle drop-off domain records the return of fleet assets from drivers to operating hubs across Bengaluru, Hyderabad, Mumbai, Pune, and Delhi. Because vehicle returns trigger the finalization of driver tenures, inventory re-entry into maintenance or yard inventory, and financial reconciliation in the LetzRyd Hisaab engine, any data anomaly directly threatens fleet utilization calculations and financial settlement balances.

This catalog details the 7 primary structural anomalies, cross-system collisions, and business logic edge cases identified during the master table consolidation, together with the mathematical and database-level resolution mechanisms implemented in `public.core_dropoffs`.

---

## 1. Same-Day Multiple Return Submissions in Google Sheets (171 Rows)

### Root Cause Analysis
In the legacy operational workflow, fleet supervisors and hub operations executives entered vehicle returns manually into the Google Sheet (`Drop off History` tab). When a vehicle return was delayed, handed over across shift changes, or corrected after an initial submission, executives frequently entered a second or third return row for the same vehicle on the same calendar date.
- Across 6,492 raw Google Sheet rows, 171 records represent duplicate same-day return submissions for identical `(vehicle_number, return_date)` combinations.
- In 14 cases, the same driver entered a return in the morning, which was subsequently updated in the evening with revised negative balance figures.

### Operational & Downstream Impact
If these records are ingested naively into `public.core_dropoffs`:
- Downstream trip interval generation engines (`v_vehicle_trip_intervals`) fail due to zero-day overlapping custody intervals.
- The Hisaab driver settlement system double-deducts negative balance liabilities, producing incorrect debt ledgers and triggering driver payment disputes.
- Yard intake calculations over-count returned vehicles by 171 units.

### Resolution Logic & Trigger Enforcement
1. **Deduplication Key**: Composite key `(vehicle_number, return_date)`.
2. **Prioritization Hierarchy**:
   - If a record for `(vehicle_number, return_date)` already exists in `public.core_dropoffs`, the real-time trigger `fn_sync_sheet_dropoffs()` executes an in-place `UPDATE` rather than an `INSERT`.
   - The trigger merges newer non-null attributes and updates `updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.
   - In batch consolidation (`refresh_core_dropoffs()`), window functions partition by `(vehicle_number, return_date)`:
     ```sql
     WITH duplicates AS (
         SELECT id,
                ROW_NUMBER() OVER (
                    PARTITION BY vehicle_number, return_date 
                    ORDER BY CASE WHEN data_source = 'MERGED' THEN 1 WHEN data_source = 'PORTAL_FORM' THEN 2 ELSE 3 END, id ASC
                ) AS rn
         FROM public.core_dropoffs
         WHERE is_deleted = FALSE
     )
     UPDATE public.core_dropoffs c
     SET is_deleted = TRUE,
         deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
         updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
     FROM duplicates d
     WHERE c.id = d.id AND d.rn > 1;
     ```
3. **Audit Verification**:
   ```sql
   SELECT vehicle_number, return_date, COUNT(*) AS duplicate_count
   FROM public.active_core_dropoffs
   GROUP BY vehicle_number, return_date
   HAVING COUNT(*) > 1;
   -- Expected result: 0 rows returned.
   ```

---

## 2. Cross-System Collision & Merging between Google Sheet and Web Portal (76 Rows Merged)

### Root Cause Analysis
During July, August, and September 2026, LetzRyd operated a hybrid transition:
- Hub ground teams recorded daily vehicle drop-offs in Google Sheets.
- Operations executives simultaneously completed the digital Vehicle Drop-off Form on the new Web Portal (`public.july_vehicle_dropoffs`).
- This produced 76 distinct vehicle drop-off events recorded in both Google Sheets and the Web Portal for the exact same vehicle on the same date.

### Conflict Characteristics
The two systems capture complementary but non-identical datasets:
- **Google Sheets (`sheet_dropoffs`)**: High-accuracy partner IDs (`LETZ...`), historical driver tenure notes, and primary Ola/Uber negative balances.
- **Web Portal (`july_vehicle_dropoffs`)**: Hub inspection notes, digital verification timestamps, detailed pending rental dues, and physical damage penalties assessed by workshop inspectors.

### Resolution Logic & Merge Mechanics
1. **Provenance Tracking**:
   - Google Sheet-only records: `data_source = 'GOOGLE_SHEET'`.
   - Portal-only records: `data_source = 'PORTAL_FORM'`.
   - Reconciled dual submissions: `data_source = 'MERGED'`.
   - `source_reference_id` stores composite provenance as plain numbers, e.g., `'1402,88'` (or `'1402'`).
   - Dedicated foreign key columns `sheet_dropoff_id BIGINT` and `portal_dropoff_id INTEGER` provide indexed relational linkage.
3. **Trigger Implementation**:
   - When `fn_sync_july_vehicle_dropoffs()` executes on an incoming portal row:
     ```sql
     SELECT id, data_source, source_reference_id, negative_balance
     INTO v_existing_id, v_existing_source, v_existing_ref, v_existing_neg
     FROM public.core_dropoffs
     WHERE dropoff_id = v_ref_id
        OR source_reference_id = v_ref_id
        OR (vehicle_number = v_clean_veh AND return_date = v_return_date AND is_deleted = FALSE)
     ORDER BY CASE WHEN data_source = 'MERGED' THEN 1 WHEN data_source = 'GOOGLE_SHEET' THEN 2 ELSE 3 END, id ASC
     LIMIT 1;

     IF v_existing_id IS NOT NULL THEN
         UPDATE public.core_dropoffs
         SET
             city = COALESCE(NULLIF(TRIM(v_clean_city), ''), core_dropoffs.city),
             driver_name = COALESCE(NULLIF(TRIM(NEW.driver_name), ''), core_dropoffs.driver_name),
             driver_id = COALESCE(NULLIF(TRIM(NEW.driver_id), ''), core_dropoffs.driver_id),
             pending_dues = -1.0 * ABS(COALESCE(NEW.pending_dues, 0.00)),
             damage_penalty = -1.0 * ABS(COALESCE(NEW.damage_penalty, 0.00)),
             total_liability = public.fn_calculate_dropoff_liability(
                 COALESCE(v_existing_neg, 0.00),
                 -1.0 * ABS(COALESCE(NEW.pending_dues, 0.00)),
                 -1.0 * ABS(COALESCE(NEW.damage_penalty, 0.00))
             ),
             remarks = COALESCE(NULLIF(TRIM(NEW.remarks), ''), core_dropoffs.remarks),
             data_source = 'MERGED',
             updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
         WHERE id = v_existing_id;
     ```
4. **Current Status**: 76 records successfully merged in production without sequence disruption or data loss.

---

## 3. Web Portal Dummy & Test Plate Entries (22 Rows)

### Root Cause Analysis
During QA testing, staging validation, and user onboarding of the Web Portal dropoff form, developers and training executives submitted mock returns with invalid registration plates, such as:
- `TEST0485`
- `TS09TEST02`
- `KA01TEST01`
- `DUMMY1234`
- `TEMP001`
A total of 22 test rows were discovered in `public.july_vehicle_dropoffs`.

### Downstream Threat
- Dummy vehicle numbers do not map to `public.core_vehicle_onboarding` or the master fleet inventory (`core_daily_vehicle_status`).
- If allowed into active reporting, they distort total fleet size metrics, create phantom unallocated vehicles, and pollute analytics dashboards.

### Resolution Logic & Defensive Ingestion
1. **Registration Plate Hygiene Filter**:
   All trigger functions and consolidation stored procedures enforce plate validation:
   - Strip all non-alphanumeric characters: `REGEXP_REPLACE(vehicle_number, '[^A-Za-z0-9]', '', 'g')`.
   - Enforce character length constraint between 8 and 12 characters (`LENGTH(cleaned) BETWEEN 8 AND 12`).
   - Explicitly filter out test patterns: `vehicle_number NOT ~* 'TEST|DUMMY|TEMP'`.
2. **Audit Isolation**:
   In `automation_script.py`, Section 6 audits for any remaining test plates:
   ```sql
   SELECT vehicle_number, return_date, data_source
   FROM public.core_dropoffs
   WHERE vehicle_number ~* 'TEST|DUMMY'
      OR LENGTH(vehicle_number) < 8
      OR LENGTH(vehicle_number) > 12;
   ```
   All 22 dummy portal submissions are isolated and prevented from creating phantom fleet records.

---

## 4. Financial Debt Polarity & Liability Formula

### Root Cause Analysis
In source Google Sheets and the Web Portal, liabilities were recorded inconsistently:
- **Sheet Negative Balances**: Stored as positive numbers representing debt owed by the driver (e.g., `500.00` meaning the driver owes INR 500), string representations with currency symbols (`₹ 1,250.00`), or accounting formats with parentheses `(750.00)`.
- **Portal Liabilities**: Captured as separate fields `pending_dues` (unpaid daily rent/FASTag) and `damage_penalty` (physical vehicle damage).
- **Polarity Inversion Bug**: If positive numbers are directly fed into the driver settlement ledger (Hisaab), positive values would be treated as driver earnings or credits rather than deductions, causing cash loss.

### The Signed Polarity Contract
The LetzRyd unified accounting standard requires that all driver debts and liabilities be stored with **strictly negative polarity**:
- Negative balance of INR 500 -> stored as `-500.00`.
- Pending dues of INR 200 -> stored as `-200.00`.
- Damage penalty of INR 300 -> stored as `-300.00`.
- Total liability -> stored as `-1000.00`.

### Mathematical Formulation
```
total_liability = -1.0 * (ABS(negative_balance) + ABS(pending_dues) + ABS(damage_penalty))
```
In database triggers and procedures, this is enforced via `public.fn_calculate_dropoff_liability()`:
```sql
CREATE OR REPLACE FUNCTION public.fn_calculate_dropoff_liability(
    p_neg NUMERIC, p_dues NUMERIC, p_dmg NUMERIC
) RETURNS NUMERIC(12,2) AS $$
BEGIN
    RETURN -1.0 * (
        ABS(COALESCE(p_neg, 0.00)) + 
        ABS(COALESCE(p_dues, 0.00)) + 
        ABS(COALESCE(p_dmg, 0.00))
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;
```

### Audit Verification
The automation script verifies that zero rows violate this accounting contract:
```sql
SELECT COUNT(*) 
FROM public.core_dropoffs
WHERE ABS(total_liability - (negative_balance + pending_dues + damage_penalty)) > 0.01
   OR negative_balance > 0 
   OR pending_dues > 0 
   OR damage_penalty > 0 
   OR total_liability > 0;
-- Verified: 0 rows violating polarity or mathematical formula.
```

---

## 5. Soft-Delete Mechanics vs Hard Deletes

### Root Cause Analysis
In spreadsheet workflows, users frequently press delete on rows or remove test rows. If an operational deletion in Google Sheets propagates as a SQL `DELETE` in PostgreSQL:
- Historical trip intervals in `v_vehicle_trip_intervals` break, leaving open-ended active trips for drivers who returned their vehicles months ago.
- The financial audit trail for historical Hisaab settlements is severed.
- Relational integrity with downstream maintenance and recovery ledgers is corrupted.

### Architecture Implementation
1. **Preservation via Flags**:
   - `is_deleted BOOLEAN NOT NULL DEFAULT FALSE`
   - `deleted_at TIMESTAMP WITHOUT TIME ZONE`
2. **Trigger-Level Soft-Delete Handlers**:
   When an upstream row is deleted in `sheet_dropoffs` or `july_vehicle_dropoffs`:
   ```sql
   IF TG_OP = 'DELETE' THEN
       UPDATE public.core_dropoffs
       SET is_deleted = TRUE, 
           deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), 
           updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
       WHERE sheet_dropoff_id = OLD.dropoff_id;
       RETURN OLD;
   END IF;
   ```
3. **Active Consumer View**:
   All operational microservices, views, and dashboards read from `public.active_core_dropoffs`:
   ```sql
   CREATE OR REPLACE VIEW public.active_core_dropoffs AS
   SELECT * FROM public.core_dropoffs
   WHERE is_deleted = FALSE;
   ```
4. **Current Metric**:
   - Exactly 18 records are preserved in soft-deleted state (`is_deleted = TRUE`).
   - Exactly 6,361 records are active.

---

## 6. Drop-off Classification & Custody Impact on Fleet Status

### Root Cause Analysis
Not every vehicle drop-off terminates a driver's custody of the vehicle. Conflating operational maintenance returns with driver attrition damages fleet tracking accuracy:
- **`Attrition` / `Voluntary Return`**: The driver voluntarily terminates their lease. Driver custody ends immediately; the vehicle transitions to `Yard` (`Available` or `Inspection`).
- **`Force Recovery`**: The vehicle is repossessed due to debt default, police challans, or contract breach. Driver custody ends immediately; the vehicle transitions to `Yard` (`Impounded` / `Recovery`).
- **`Repair and Maintenance`**: The vehicle has mechanical issues and enters the workshop.

### The Individual Partner (`IP`) Maintenance Custody Exception
Under LetzRyd fleet policies, Individual Partners (`LETZ...IP...`) retain contractual custody of their assigned vehicle even while it undergoes workshop repairs. Truncating the trip interval on a routine maintenance return would falsely flag the driver as unassigned and make the vehicle appear available for reallocation to another driver.

### Implementation in Downstream Interval Engine (`v_vehicle_trip_intervals`)
```sql
CASE 
    WHEN d.return_type = 'Repair and Maintenance' AND UPPER(ra.partner_id) LIKE '%IP%' 
        THEN ra.next_allocation_date
    ELSE COALESCE(d.return_date, ra.next_allocation_date)
END AS trip_end_date,

CASE
    WHEN d.return_type = 'Repair and Maintenance' AND UPPER(ra.partner_id) LIKE '%IP%' AND ra.next_allocation_date IS NULL 
        THEN 'OPERATOR_MAINTENANCE_ACTIVE'
    WHEN d.id IS NOT NULL 
        THEN 'CLOSED_TRIP'
    WHEN ra.next_allocation_date IS NOT NULL 
        THEN 'SUPERSEDED_BY_NEXT_ALLOCATION'
    ELSE 'CURRENTLY_ACTIVE'
END AS trip_state
```
This guarantees that an IP operator's vehicle in maintenance status correctly reflects `Off Road` (`Maintenance`) in `core_daily_vehicle_status` without severing driver commercial assignment.

---

## 7. Gapless Primary Key Generation via Advisory Locks

### Root Cause Analysis
Standard PostgreSQL sequences (`BIGSERIAL` or `GENERATED ALWAYS AS IDENTITY`) employ non-transactional cache sequences. In high-concurrency environments:
- Rolled back transactions burn sequence IDs.
- Concurrent trigger calls or upsert conflicts burn numbers (e.g. producing IDs 1, 2, 5, 8, 12...).
- When auditors or accounting engines verify ledger continuity, sequence gaps create suspicion of deleted or hidden financial records.

### Transactional Advisory Locking Architecture
To guarantee a strictly continuous `1, 2, 3... N` integer primary key (`MIN(id) = 1`, `MAX(id) = COUNT(*)`, `GAPS = 0`), the ingestion triggers and consolidation procedures execute:
1. **Advisory Lock Acquisition**:
   ```sql
   PERFORM pg_advisory_xact_lock(777444555);
   ```
   - Lock ID `777444555` is exclusive to the dropoff pipeline.
   - Automatically releases at transaction commit or rollback.
2. **Next Sequential ID Assignment**:
   ```sql
   SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_dropoffs;
   ```
3. **Continuous State Verification**:
   The live database contains exactly 6,379 rows spanning `id = 1` to `id = 6379` with zero gaps.
   ```sql
   SELECT s.i AS missing_id
   FROM generate_series(1, COALESCE((SELECT MAX(id) FROM public.core_dropoffs), 0)) s(i)
   LEFT JOIN public.core_dropoffs c ON s.i = c.id
   WHERE c.id IS NULL;
   -- Verified: Exactly 0 rows returned.
   ```

---

## Summary Status

All 7 operational anomalies have been engineered into database triggers, DDL constraints, stored procedures, and audit verification scripts. Production validation confirms 100% compliance across all 6,379 consolidated drop-off records.
