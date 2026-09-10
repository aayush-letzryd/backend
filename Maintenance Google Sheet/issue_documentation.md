# Master Maintenance Pipeline: Issue & Remediation Documentation
**Engineering Review & Audit Report for Team Lead Anurag**

---

## 1. Overview

This document presents the detailed Problem-Consequence-Fix breakdown for the **`public.sheet_maintenance`** staging pipeline, ingesting workshop maintenance logs from `Daily Vehicle Status` in `Vehicle Status List_V3` into PostgreSQL.

---

## 2. Issue Remediation Matrix

### Issue 1: Large Spreadsheet IMPORTRANGE Transfer Limit
- **Problem**: Querying `Daily Vehicle Status!A:N` across tens of thousands of rows exceeded Google Sheets' internal formula payload limit (`Error: Result too large`).
- **Consequence**: Master Google Sheet tab failed to load with `#ERROR!`.
- **Fix**: Applied bounded range querying (`'Daily Vehicle Status'!A1:N15000`) and implemented an Apps Script direct batch importer (`syncMaintenanceSheetToPostgres`) that pulls records in chunks, bypassing formula limits completely.

---

### Issue 2: Hyphen Placeholder Contamination in Relational Columns
- **Problem**: Unassigned spreadsheet cells for `partner Name`, `DM Name`, `partner IDs`, and `Type` contained literal hyphens (`"-"`) instead of empty/null values.
- **Consequence**: Dirty foreign keys and invalid string literals stored in relational columns.
- **Fix**: Implemented strict sanitization mapping `"-"` and whitespace-only strings to SQL `NULL` before database insertion.

---

### Issue 3: Driver Code vs Workshop Status Text Collisions
- **Problem**: The source `partner IDs` column contained the literal string `"Maintenance"` for cars in workshop with no active driver, but valid alphanumeric driver codes (`LETZBLR...`) for cars returned mid-shift.
- **Consequence**: String `"Maintenance"` stored as a driver ID, corrupting driver dimension lookups.
- **Fix**: Evaluated `partner_ids`: if the value is `"Maintenance"`, `"RFD"`, or `"-"`, it is stored as `NULL` for driver identity while preserving the workshop lifecycle state in `final_status`.

---

### Issue 4: Sequence ID Burning During 1-Minute Automated Syncs
- **Problem**: Frequent 1-minute time triggers executing standard `INSERT ... ON CONFLICT DO UPDATE` burn `BIGSERIAL` sequence numbers on every conflict check.
- **Consequence**: Rapid sequence gap explosion in the database.
- **Fix**: Implemented CTE-based parameterized UPSERT (`WITH existing AS ... SELECT ... WHERE NOT EXISTS ...`), completely eliminating sequence thrashing.

---

### Issue 5: Soft Deletion on Operational Status Transitions
- **Problem**: When a vehicle completes maintenance and is marked `Active` or `RFD` by Ops, simply deleting or ignoring the row would lose historical maintenance repair logs.
- **Consequence**: Permanent loss of workshop downtime history required for Hisaab rent waiver reconciliation.
- **Fix**: Deployed soft-delete handling marking `is_deleted = TRUE` and recording `deleted_at`, preserving the entire workshop history for the Hisaab billing engine.

---

### Issue 6: IST Timezone Standardization
- **Problem**: Inconsistent timestamp storage with mixed UTC and offset notations.
- **Consequence**: Misaligned daily maintenance ledger queries.
- **Fix**: Standardized all timestamp columns to `TIMESTAMP WITHOUT TIME ZONE` with defaults explicitly set to `(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.
