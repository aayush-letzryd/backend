# LetzRyd Vehicle Dropoff Pipeline - Engineering Audit & Data Quality Specification

Source Spreadsheet: `dropoffs_form` (Spreadsheet ID: `1lb2BArHkQynUSA2hs_GAhCdjhOlwGIFIVjqA32Jw5M8`, Tab: `sheet_dropoffs`)  
Target Staging Table: `public.sheet_dropoffs` (PostgreSQL Database: `postgres`)  
Audited Rows: 6,454 rows  

---

## Executive Summary

The LetzRyd Vehicle Dropoff Google Sheet Pipeline connects front-line vehicle return operations to the central PostgreSQL database. This document details the 10 real-world engineering and data hygiene issues encountered during production operations, their root causes, architectural impacts, and production-grade solutions implemented in `schema.sql` and `dropoff_pipeline_appscript.js`.

---

## 1. Sequence Burning Bug in Legacy `ON CONFLICT`

- **Issue Classification**: Database Sequence Exhaustion & Transaction Overhead
- **Root Cause Analysis**:
  Under PostgreSQL's standard syntax:
  ```sql
  INSERT INTO public.sheet_dropoffs (source_row, return_date, vehicle_number, ...)
  VALUES (?, ?, ?, ...)
  ON CONFLICT (source_row) DO UPDATE
  SET return_date = EXCLUDED.return_date, ...;
  ```
  PostgreSQL allocates the next value of the primary key sequence (`sheet_dropoffs_dropoff_id_seq`) via `nextval()` before evaluating whether a uniqueness conflict exists on `source_row`.
- **Blast Radius & Impact**:
  Every recurring 1-minute sliding window sync evaluates 150 rows. Even when zero rows change, 150 sequence IDs are consumed every minute (216,000 IDs per day; 6.48 million IDs per month). Over time, this leads to sequence exhaustion, unnecessary sequence resets, and false alarms in sequence gap monitoring.
- **Architectural Solution**:
  Replaced `ON CONFLICT` with the Zero-Burn Common Table Expression (CTE) pattern:
  ```sql
  WITH incoming AS (
      SELECT 
          CAST(? AS integer) AS src_row,
          CAST(? AS date) AS ret_date,
          CAST(? AS varchar) AS ret_type,
          CAST(? AS varchar) AS drv_id,
          CAST(? AS varchar) AS drv_name,
          CAST(? AS varchar) AS drv_type,
          CAST(? AS varchar) AS veh_num,
          CAST(? AS varchar) AS city_name,
          CAST(? AS numeric) AS neg_bal
  ),
  upd AS (
      UPDATE public.sheet_dropoffs s
      SET 
          return_date = i.ret_date,
          return_type = i.ret_type,
          driver_id = i.drv_id,
          driver_name = i.drv_name,
          driver_type = i.drv_type,
          vehicle_number = i.veh_num,
          city = i.city_name,
          negative_balance = i.neg_bal,
          sync_status = 'SYNCED',
          updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
      FROM incoming i
      WHERE s.source_row = i.src_row
      RETURNING s.dropoff_id
  )
  INSERT INTO public.sheet_dropoffs (
      source_row, return_date, return_type, driver_id, driver_name,
      driver_type, vehicle_number, city, negative_balance, sync_status,
      created_at, updated_at
  )
  SELECT 
      i.src_row, i.ret_date, i.ret_type, i.drv_id, i.drv_name,
      i.drv_type, i.veh_num, i.city_name, i.neg_bal, 'SYNCED',
      (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
      (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
  FROM incoming i
  WHERE NOT EXISTS (SELECT 1 FROM upd);
  ```
  Because the `INSERT` clause is guarded by `WHERE NOT EXISTS (SELECT 1 FROM upd)`, existing rows trigger only the `UPDATE` branch. PostgreSQL never invokes `nextval()`, maintaining a clean, continuous sequence.

---

## 2. Primary Key Desynchronization Bug when Skipping Blank Rows

- **Issue Classification**: Relational Integrity & Data Overwrite
- **Root Cause Analysis**:
  Legacy ingestion scripts attempted to derive database primary keys or unique row numbers from loop iteration offsets:
  ```javascript
  // Legacy buggy logic
  const dropoff_id = rowIdx - 1; // Assumed row 2 = ID 1, row 3 = ID 2, etc.
  ```
  When the script skipped empty rows, blank trailing rows, or embedded header repeats, the offset shifted. For example, if row 15 was an empty spacer row and was skipped, row 16 was assigned synthetic ID 14 instead of 15.
- **Blast Radius & Impact**:
  Subsequent single-row edits to row 16 updated the database record corresponding to row 15, silently overwriting unrelated vehicle dropoff records.
- **Architectural Solution**:
  Decoupled physical loop offsets from relational identity by introducing a dedicated, unique `source_row` column:
  - Database constraint: `source_row INTEGER UNIQUE NOT NULL`.
  - Script logic: The physical spreadsheet row number (`rowIdx`) or the explicit "Source Row" value in Column A is transmitted directly as `source_row`.
  - All upserts match strictly on `s.source_row = i.src_row`.

---

## 3. Multi-Row Paste Bug in `handleOnEdit`

- **Issue Classification**: Real-Time Trigger Event Truncation
- **Root Cause Analysis**:
  The default Google Apps Script `onEdit(e)` event passes `e.range`. Legacy handlers only inspected the top-left cell:
  ```javascript
  // Legacy buggy logic
  const row = e.range.getRow();
  syncSingleRow(row);
  ```
  When fleet operators copied and pasted a block of 10 or 50 rows from another spreadsheet into `sheet_dropoffs`, `e.range.getRow()` returned only the first row of the pasted block. `e.value` was either undefined or contained only a single cell's string.
- **Blast Radius & Impact**:
  Only the top row of any pasted block synced to PostgreSQL. The remaining 9 to 49 rows remained un-synced until an hourly or full manual sync occurred, creating major lag in operational reporting.
- **Architectural Solution**:
  Implemented full range boundary traversal in `handleOnEdit(e)`:
  ```javascript
  const startRow = e.range.getRow();
  const endRow = e.range.getLastRow();
  const actualStart = Math.max(2, startRow);
  const numRows = endRow - actualStart + 1;
  const rawData = sheet.getRange(actualStart, 1, numRows, sheet.getLastColumn()).getValues();

  const records = [];
  for (let i = 0; i < rawData.length; i++) {
    const transformed = transformDropoffRow(rawData[i], actualStart + i, hMap);
    if (transformed) records.push(transformed);
  }
  if (records.length > 0) upsertDropoffRecords(records);
  ```
  This processes every row within the pasted range in a single batch transaction.

---

## 4. Dynamic Header Shifts (Handling 'Source Row' in Col A)

- **Issue Classification**: Schema Fragility & Schema Evolution
- **Root Cause Analysis**:
  Legacy scripts relied on hardcoded array indices:
  ```javascript
  // Legacy fragile index mapping
  const returnDate = row[0];
  const vehicleNumber = row[4];
  const negativeBalance = row[5];
  ```
  When a "Source Row" audit column was added at Column A (shifting the return date to Column B and vehicle number to Column E/F), all field extractions shifted right by one index. Numeric balance parsers attempted to read vehicle strings, crashing the pipeline.
- **Blast Radius & Impact**:
  Pipeline failure on any column insertion, reordering, or deletion by operations staff.
- **Architectural Solution**:
  Implemented dynamic header mapping via `getHeaderIndexMap(headers)`:
  - Scans row 1 during execution and matches column headers using case-insensitive regular expressions:
    - `/source.*row|^row$/i` -> `sourceRow`
    - `/return.*date|drop.*off.*date/i` -> `returnDate`
    - `/return.*type|reason/i` -> `returnType`
    - `/driver.*id|operator.*id/i` -> `driverId`
    - `/driver.*name/i` -> `driverName`
    - `/driver.*type|^type$/i` -> `driverType`
    - `/vehicle.*number|plate.*number/i` -> `vehicleNumber`
    - `/^city$|^hub$/i` -> `city`
    - `/negative.*balance|closing.*balance|balance/i` -> `negativeBalance`
    - `/sync.*status/i` -> `syncStatus`
    - `/last.*sync/i` -> `lastSyncedAt`
  - Provides deterministic positional fallbacks only if headers are absent.

---

## 5. Financial Negative Balance Formatting (Parentheses vs Signed Numbers)

- **Issue Classification**: Financial Data Loss & Type Conversion
- **Root Cause Analysis**:
  Accounting software and financial operators write negative balances enclosed in parentheses, such as `(500.00)` to represent a Rs. 500 liability. Standard JavaScript `parseFloat("(500.00)")` parses characters up to the opening parenthesis and returns `NaN`.
  Common fallback code converted `NaN` to `0.00`:
  ```javascript
  // Legacy buggy conversion
  const balance = parseFloat(rawVal) || 0.00; // "(500.00)" -> 0.00
  ```
  Furthermore, inputs frequently contained currency symbols (`Rs.`, `$`), comma separators (`1,250.00`), or text placeholders (`Pending`, `TBD`).
- **Blast Radius & Impact**:
  Driver liabilities were converted to `0.00`, causing unrecoverable debt write-offs in the downstream Hisaab settlement ledger.
- **Architectural Solution**:
  Implemented accounting negative parser in `cleanBalance`:
  ```javascript
  function cleanBalance(rawVal) {
    if (rawVal === null || rawVal === undefined || rawVal === '') return 0.00;
    let str = String(rawVal).replace(/[Rs.$,\s]/g, '').trim();
    if (!str || str === '-' || str.toLowerCase() === 'null' || str.toLowerCase() === 'n/a') return 0.00;
    if (str.toLowerCase() === 'pending' || str.toLowerCase() === 'tbd') return null;

    if (str.startsWith("(") && str.endsWith(")")) {
      const inner = str.slice(1, -1).replace(/[Rs.$,\s]/g, '').trim();
      const num = parseFloat(inner);
      return isNaN(num) ? null : -Math.abs(num);
    }

    const num = parseFloat(str);
    if (isNaN(num)) return null;
    return num;
  }
  ```

---

## 6. Timezone 1-Day Backward Shift in V8 `new Date()`

- **Issue Classification**: Temporal Desynchronization
- **Root Cause Analysis**:
  In Google Apps Script's modern V8 runtime, parsing ISO date strings like `"2024-07-15"` via `new Date("2024-07-15")` creates a Date object at UTC midnight (`2024-07-15T00:00:00.000Z`).
  When standard date extractors or timezones behind UTC (or conversions without timezone specifiers) serialize this object:
  ```javascript
  // If evaluated in an offset environment
  date.toISOString().split('T')[0]; // Can shift backwards to 2024-07-14
  ```
- **Blast Radius & Impact**:
  Dropoff dates shifted 1 day into the past, causing mismatches with physical vehicle return logs, false claims of unauthorized vehicle usage, and distorted driver attendance.
- **Architectural Solution**:
  - Enforced `Utilities.formatDate(date, "Asia/Kolkata", "yyyy-MM-dd")` for all Date instances.
  - Added direct regex pattern parsers for string inputs (`DD/MM/YYYY`, `DD-MM-YYYY`, `YYYY-MM-DD`, and text months) to bypass JavaScript timezone instantiation entirely.
  - Handled 5-digit Excel serial numbers (e.g. `45658`) by computing days from the `1899-12-30` epoch in pure IST.

---

## 7. Multiple Drop-offs on Same Date for Same Vehicle (171 Rows in Sheet)

- **Issue Classification**: Physical Domain Modeling & False Deduplication
- **Root Cause Analysis**:
  A naive data engineering assumption was that `(vehicle_number, return_date)` formed a natural unique key for vehicle returns.
  However, in physical fleet operations, 171 records in the drop-off sheet represent legitimate distinct drop-off events on the same calendar day for the same vehicle:
  - Morning drop-off by Driver A due to maintenance or shift completion.
  - Immediate vehicle inspection and afternoon reallocation to Driver B.
  - Evening drop-off by Driver B due to attrition.
- **Blast Radius & Impact**:
  If the staging table enforced a unique constraint on `(vehicle_number, return_date)`, or if an upsert keyed on vehicle + return date, the second dropoff overwrote the first, obliterating driver liability records and vehicle return histories.
- **Architectural Solution**:
  - Staging table `public.sheet_dropoffs` keys uniqueness strictly on `source_row INTEGER UNIQUE`.
  - Both drop-off events are fully ingested and preserved as separate staging records.
  - Downstream reconciliation in `core_dropoffs` assigns unique synthetic dropoff identifiers (`DRP-SHT-<id>`) to each event.

---

## 8. Google Apps Script 6-Minute Execution Quota

- **Issue Classification**: Platform Quota Exhaustion & Script Termination
- **Root Cause Analysis**:
  Google Apps Script limits single executions to a strict 6-minute ceiling. Ingesting all 6,400+ rows sequentially over JDBC PreparedStatement takes 45 to 75 seconds.
  If a full sync runs on a 1-minute time trigger, executions overlap. Each execution waits on database locks, exceeds the 6-minute window, and is terminated by Google infrastructure.
- **Blast Radius & Impact**:
  Trigger disabled by Google due to excessive failures; database connections left open; pipeline halted.
- **Architectural Solution**:
  Implemented dual-cadence synchronization:
  - **Sliding Window Catch-Up (`syncRecentDropoffs`)**: Runs every 1 minute via time-driven trigger. Inspects only the last 150 rows (`WINDOW_SIZE = 150`). Executes in 1.2 to 1.8 seconds, utilizing under 0.5% of the execution quota.
  - **Full Historical Sync (`syncAllDropoffs`)**: Executed on demand via custom spreadsheet menu or scheduled nightly. Uses 100-row batch commits (`stmt.executeBatch()` and `conn.commit()`) to complete all 6,400+ rows in ~35 seconds.

---

## 9. Vehicle Plate Sanitization

- **Issue Classification**: Foreign Key Integrity & String Hygiene
- **Root Cause Analysis**:
  Vehicle registration plates entered manually in Google Sheets contain multiple variations:
  - Lowercase characters: `ka01ab1234`
  - Whitespace and hyphens: `KA - 05 - NB - 9821`
  - Non-alphanumeric noise: `KA.03.MM.1122`, `KA/01/P/9988`
  - Placeholder strings: `N/A`, `TBD`, `-`, `NONE`, `0`
- **Blast Radius & Impact**:
  Failed joins against master vehicle inventory tables (`public.master_vehicles`), leading to orphan drop-off records.
- **Architectural Solution**:
  Implemented strict plate sanitization in `cleanVehicleNumber(rawPlate)`:
  - Strips all non-alphanumeric characters: `str.replace(/[^A-Z0-9]/g, '')`.
  - Converts to uppercase.
  - Filters out known placeholders (`NA`, `NAN`, `NULL`, `NONE`, `-`, `0`).
  - Enforces length between 8 and 12 characters.
  - Validates against the official Indian registration plate regex:
    `^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$`
  - Rejects malformed plates by returning `null`, preventing garbage entries from entering the database.

---

## 10. Concurrency Deadlocks and LockService Guard

- **Issue Classification**: Distributed Race Conditions & Database Deadlocks
- **Root Cause Analysis**:
  In a live Google Sheet environment, multiple execution triggers can fire simultaneously:
  - User edits cell -> `handleOnEdit` fires.
  - Another user submits a Google Form -> `handleOnFormSubmit` fires.
  - 1-minute timer fires -> `syncRecentDropoffs` fires.
  Without mutual exclusion, three separate Google Apps Script instances establish JDBC connections and issue concurrent `UPDATE` and `INSERT` statements against `public.sheet_dropoffs`, leading to database row lock deadlocks and connection pool exhaustion.
- **Blast Radius & Impact**:
  PostgreSQL `deadlock detected` errors, connection timeouts, and skipped data writes.
- **Architectural Solution**:
  Guarded all four entry points (`syncAllDropoffs`, `syncRecentDropoffs`, `handleOnEdit`, `handleOnFormSubmit`) with `LockService.getScriptLock()` using a 30-second timeout:
  ```javascript
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("Lock acquisition timed out (30s). Another execution is active. Skipping.");
    return;
  }
  try {
    // Pipeline execution logic
  } finally {
    lock.releaseLock();
  }
  ```
  This serializes access across all triggers, ensuring only one instance accesses the JDBC connection and updates `public.sheet_dropoffs` at any given moment.
