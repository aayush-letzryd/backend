# LetzRyd Maintenance Pipeline (sheet_maintenance) - Fixed Issues Catalog

This document details all data quality anomalies, architectural defects, and ingestion issues identified and permanently resolved in the Google Sheet Maintenance staging pipeline (`public.sheet_maintenance`) and its Google Apps Script ingestion engine.

---

## 1. Issue MNT-01: Yard Attendance Cohort Contamination (8,029 RFD Records)

- **Affected Column**: `final_status`, `cohort` (Target: `public.sheet_maintenance`)
- **Raw Anomaly**:
  The master tracker sheet (`Daily Vehicle Status`) categorized all idle assets under `cohort = 'Off Road'`. This included both genuine workshop downtime vehicles (`final_status = 'Maintenance'`) and yard-idle assets waiting for drivers (`final_status = 'RFD'`). Early scripts ingested over 8,029 RFD rows, 159 Drop Off rows, and 91 New Deployment rows into the maintenance staging table.
- **Root Cause**:
  Ingestion filter evaluated `cohort = 'Off Road'` as a blanket maintenance indicator rather than strictly isolating genuine workshop repair taxonomy.
- **Resolution**:
  - Refactored `isMaintenanceDowntime()` filter in Apps Script to strictly match genuine repair statuses: `'Maintenance'`, `'Workshop'`, `'Accidental'`, `'BD'`, `'Breakdown'`, `'Under Repair'`, `'Repair'`, `'Service'`.
  - Explicitly excluded `'RFD'`, `'Drop Off'`, `'New Deployment'`, `'Active'`, and `'Allocation'`.
  - Purged 8,029 RFD rows, 159 Drop Off rows, and 91 New Deployment rows from `public.sheet_maintenance` and re-indexed the table to 5,007 pure maintenance records.

---

## 2. Issue MNT-02: Google Apps Script 6-Minute Execution Quota Timeout

- **Affected Layer**: Apps Script Ingestion Layer (`syncAllMaintenance`)
- **Raw Anomaly**:
  Attempting to extract and push all 45,039 master tracker rows over JDBC in chunks of 200 required over 225 network round-trips. Each batch took ~5-7 seconds due to row-level database triggers, exceeding Google's strict 360-second execution quota and aborting mid-flight.
- **Root Cause**:
  Client-side un-indexed full historical scans over WAN JDBC connections from Google's US servers to PostgreSQL in India.
- **Resolution**:
  - Architected a dual-speed pipeline:
    1. High-speed server-side batch backfill script inserting historical records (`< 2026-09-13`) directly in PostgreSQL in 2.67 seconds.
    2. Automated 5-minute sliding-window trigger (`syncRecentMaintenance`) inspecting the latest 1,000 rows, executing in 2 to 3 seconds.

---

## 3. Issue MNT-03: Modern V8 Engine Incompatibility (`ReferenceError: java is not defined`)

- **Affected Layer**: Apps Script JDBC PreparedStatement Binding
- **Raw Anomaly**:
  `syncAllMaintenance` and `upsertMaintenanceRecords` crashed with `ReferenceError: java is not defined at line 475`.
- **Root Cause**:
  Google Apps Script runs on the modern V8 JavaScript runtime where Java SDK global namespaces (`java.sql.Types`, `java.sql.Date`) are undefined.
- **Resolution**:
  - Replaced all `java.sql.Types` references with standard numeric JDBC SQL constants:
    - `12` for `VARCHAR`
    - `91` for `DATE`
    - `4` for `INTEGER`
  - Replaced `java.sql.Date.valueOf()` with standard string parameter bindings (`ps.setString(col, dateStr)`) coupled with PostgreSQL casting (`?::date`).

---

## 4. Issue MNT-04: Primary Key Sequence Burning on Duplicate Upsert

- **Affected Column**: Primary Key `id` / `public.sheet_maintenance_id_seq`
- **Raw Anomaly**:
  Standard PostgreSQL `INSERT ... ON CONFLICT (vehicle_number, date) DO UPDATE` advances the internal `BIGSERIAL` sequence counter for every evaluated row, even when only updating an existing record. Over recurring 5-minute syncs, this burned millions of IDs and created massive sequence gaps.
- **Root Cause**:
  PostgreSQL allocates the next sequence value before evaluating unique index conflict constraints.
- **Resolution**:
  - Implemented a zero-burn CTE upsert pattern in both SQL and Apps Script:
    ```sql
    WITH upd AS (
      UPDATE public.sheet_maintenance SET ...
      WHERE vehicle_number = ? AND date = ?::date
      RETURNING id
    )
    INSERT INTO public.sheet_maintenance (...)
    SELECT ...
    WHERE NOT EXISTS (SELECT 1 FROM upd);
    ```
  - Primary key IDs now increment strictly on new record inserts, maintaining a perfect 1..N gapless sequence.

---

## 5. Issue MNT-05: Google Sheet Dynamic Dimension Out-of-Bounds Error

- **Affected Layer**: Apps Script Sheet Writing Engine (`syncAllMaintenance`, `syncRecentMaintenance`)
- **Raw Anomaly**:
  New Google Sheets start with 1,000 rows by default. When the script attempted to write ~5,000 extracted maintenance rows, Google Sheets threw:
  `Exception: The coordinates or dimensions of the range are invalid`.
- **Root Cause**:
  `sheet.getRange(row, col, numRows, numCols)` cannot write past `sheet.getMaxRows()`.
- **Resolution**:
  - Added automated sheet pre-allocation logic before chunked block writes:
    ```javascript
    var maxRows = targetSheet.getMaxRows();
    var requiredRows = sheetRows.length + 10;
    if (requiredRows > maxRows) {
      targetSheet.insertRowsAfter(maxRows, requiredRows - maxRows);
    }
    ```

---

## 6. Issue MNT-06: Local Sheet Tab Duplicate Record Accumulation

- **Affected Layer**: High-Frequency 5-Minute Sliding-Window Trigger (`syncRecentMaintenance`)
- **Raw Anomaly**:
  Sliding-window extraction appending rows on every 5-minute cycle caused duplicate records to pile up in the local `sheet_maintenance` spreadsheet tab.
- **Root Cause**:
  Lack of client-side deduplication against existing sheet rows before invoking `setValues()`.
- **Resolution**:
  - Added in-memory composite key indexing (`vehicle_number + "_" + date`) checking existing rows in `sheet_maintenance` before appending:
    ```javascript
    var newSheetRows = [];
    for (var k = 0; k < records.length; k++) {
      var recKey = records[k].vehicle_number + "_" + records[k].date;
      if (!existingKeys[recKey]) {
        newSheetRows.push(sheetRows[k]);
        existingKeys[recKey] = true;
      }
    }
    ```

---

## 7. Issue MNT-07: Apps Script JDBC Proxy Overhead & Idle-in-Transaction Timeout

- **Affected Layer**: High-Frequency 5-Minute Trigger (`syncRecentMaintenance`)
- **Raw Anomaly**:
  - Scanning from bottom of master sheet hit 1,422 trailing formatted rows with dashes (`-`), resulting in `0` detected records or incorrect window bounds.
  - Looping 15 parameter setters (`ps.setString`) across hundreds of records in Google Apps Script generated 14,000+ Java-RPC bridge calls, taking > 5 minutes and triggering PostgreSQL `FATAL: terminating connection due to idle-in-transaction timeout`.
  - Reading and appending into local spreadsheet tabs accumulated DOM latency and blank row gaps.
- **Root Cause**:
  1. Google Sheets `getLastRow()` counting trailing formatted rows beyond actual data row 44,100.
  2. Google Apps Script's JDBC proxy RPC latency on per-field `PreparedStatement` calls.
  3. PostgreSQL 5-minute `idle_in_transaction_session_timeout`.
- **Resolution**:
  - Implemented `getLastDataRow()` using native regex `TextFinder` on Column B (`[A-Za-z0-9]`) to locate true active data rows instantly (< 0.05s).
  - Transitioned to direct-to-database streaming, skipping Google Sheet DOM writes entirely.
  - Implemented multi-row SQL streaming (`INSERT INTO ... VALUES (...) ON CONFLICT DO UPDATE`), grouping 100 records into a single SQL statement. Reduced database execution time from 5 minutes to 0.2 seconds.

