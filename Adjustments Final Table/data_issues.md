# LetzRyd Adjustments Final Table - Data Quality & Issue Specification

This document details the architectural data issues, real-world anomalies, root causes, and engineering resolutions implemented for **`public.core_adjustments`**.

---

## 1. Historical 1-Day Date Shift & 14,761 Phantom Duplicate Batch

### Root Cause
During early ingestion of the raw Google Sheet (`Adjustment-Form`), the Google Apps Script runtime used JavaScript V8 date parsing (`new Date().getUTCDate()`), which converted local Indian Standard Time (IST, UTC+05:30) timestamps into UTC. For dates at or around midnight, this shifted the adjustment date backward by exactly 1 calendar day (e.g. `2026-09-08` became `2026-09-07`).

When the Apps Script parser bug was identified and fixed, the entire sheet was re-ingested with correct dates. However, the database trigger function `fn_sync_sheet_adjustments()` contained a deduplication condition:
```sql
WHERE adjustment_date = NEW.adjustment_date
```
Because the newly incoming records had the true date (`2026-09-08`) while existing rows had the shifted date (`2026-09-07`), the trigger failed to recognize them as existing records. Consequently, the trigger inserted a second copy of all 14,761 adjustments, generating `adjustment_id` values from `ADJ-SHT-14910` through `ADJ-SHT-29686`.

Although `sheet_adjustments` was later purged down to its clean 14,909 rows, `core_adjustments` was never cleared, leaving 14,761 phantom duplicates lingering in production (inflating total rows to 29,679).

### Resolution
- Created safety backup table `public.core_adjustments_backup_20260915` (29,679 rows).
- Truncated `public.core_adjustments` and executed `public.refresh_core_adjustments()`.
- Re-ingested from the 14,909 verified rows in `public.sheet_adjustments` and 15 rows in `public.july_partner_adjustment`.
- Master table stabilized at **14,476 clean, deduplicated rows** (14,462 from Sheet, 13 from Portal, 1 Merged), eliminating all 14,761 phantom records.

---

## 2. Extreme Sequence Burning (13,464,566 IDs Consumed)

### Root Cause
Earlier migrations declared `id BIGSERIAL PRIMARY KEY` and executed bulk `INSERT ... ON CONFLICT (adjustment_id) DO UPDATE` queries. In PostgreSQL, calling `nextval()` occurs before conflict resolution; thus, every conflicting row burns an ID. Across multiple hourly runs and backfills of 14,000-row batches, the sequence burned over **13.4 million IDs**.

### Resolution
- Migrated `id` from `BIGSERIAL` to `BIGINT PRIMARY KEY`.
- Inside `refresh_core_adjustments()`, initialized an in-memory counter:
  ```sql
  SELECT COALESCE(MAX(id), 0) INTO v_next_id FROM public.core_adjustments;
  ```
  Incremented `v_next_id := v_next_id + 1` for new inserts only, completely eliminating sequence burning.
- Synchronized underlying sequence `core_adjustments_id_seq` to match `MAX(id)`:
  ```sql
  PERFORM setval('public.core_adjustments_id_seq', 14476, true);
  ```

---

## 3. Concurrency Deadlocks & Advisory Locking

### Root Cause
Simultaneous webhook executions from Google Forms or multi-tab edits in Google Sheets could trigger concurrent executions of `fn_sync_sheet_adjustments()`, leading to race conditions where two processes attempt to insert the same partner adjustment simultaneously.

### Resolution
- Enforced transactional advisory locking with dedicated lock key `777333444`:
  ```sql
  PERFORM pg_advisory_xact_lock(777333444);
  ```
- Any concurrent trigger invocation automatically waits until the active transaction commits, guaranteeing strict serialization and zero duplicate ID assignment.

---

## 4. Timezone Datatype Inconsistency (`TIMESTAMPTZ` vs `TIMESTAMP`)

### Root Cause
Columns `created_at`, `updated_at`, and `deleted_at` were originally declared as `TIMESTAMP WITH TIME ZONE`. This caused PostgreSQL to append UTC offsets (`+00:00` or `+05:30`), leading to day-shift display errors in frontend applications and analytics queries.

### Resolution
- Altered all timestamp columns to `TIMESTAMP WITHOUT TIME ZONE`:
  ```sql
  ALTER TABLE public.core_adjustments 
      ALTER COLUMN created_at TYPE TIMESTAMP WITHOUT TIME ZONE USING created_at AT TIME ZONE 'Asia/Kolkata',
      ALTER COLUMN updated_at TYPE TIMESTAMP WITHOUT TIME ZONE USING updated_at AT TIME ZONE 'Asia/Kolkata',
      ALTER COLUMN deleted_at TYPE TIMESTAMP WITHOUT TIME ZONE USING deleted_at AT TIME ZONE 'Asia/Kolkata';
  ```
- Defaults set to `(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.

---

## 5. Long String & Vehicle Number Truncation

### Root Cause
In raw Google Sheet entries, certain operators pasted bulk lists of up to 50 concatenated license plates (e.g. `KA05AP6033KA05AP6041KA05AP7492...`, 780 characters) or descriptive strings (e.g. `1DAYRENTOFFDRIVERTAKENLEAVE`) into the vehicle number column. PL/pgSQL variables typed as `VARCHAR(20)` crashed with `StringDataRightTruncation` (SQLSTATE 22001).

### Resolution
- Declared all string and vehicle variables in trigger and refresh functions as `TEXT`:
  ```sql
  v_clean_phone TEXT;
  v_clean_veh TEXT;
  v_clean_city TEXT;
  ```
- Preserved complete raw concatenated strings in `core_adjustments.vehicle_number` (`TEXT`) without truncation.

---

## 6. Financial Ledger Polarity & Negative Amounts

### Root Cause
Certain sheet entries had negative amounts entered as `-100.00` to denote deductions, while others relied on `adjustment_type = 'Debit'` with positive numbers.

### Resolution
- Enforced check constraint `CONSTRAINT chk_core_adjustments_amount CHECK (amount >= 0.00)`.
- Financial polarity is captured explicitly by `adjustment_type` (`Credit` vs `Debit` vs `Deposit Conversion`), while `amount` represents the absolute magnitude.
