# LetzRyd Adjustments Final Table - Data Quality & Issue Specification

This document details the architectural data issues, real-world anomalies, root causes, and engineering resolutions implemented for **`public.core_adjustments`**.

---

## 1. Multiple Same-Day Adjustments & Prevention of Over-Merging

### Root Cause
In real operations, a single driver frequently has multiple genuine adjustments on the exact same date for the exact same amount (e.g. Driver `6200183742` on `2026-07-15` had ₹500 for "Car wash" and ₹500 for "AC issue"). Earlier code attempted to deduplicate by matching `(partner_phone, vehicle_number, adjustment_date, amount)`, which erroneously merged the second entry into the first, deleting 414 financial adjustments.

### Resolution
- Enforced 1-to-1 canonical mapping from `sheet_adjustments` (`ADJ-SHT-<id>`) and `july_partner_adjustment` (`ADJ-PORTAL-<id>`).
- Every distinct form submission is preserved as its own line item in `core_adjustments`.
- Total rows consolidated: **15,835 rows** (15,820 from Sheet + 15 from Portal), eliminating all data loss.

---

## 2. Corrupted Approval Status (`approval_status` Storing Timestamps)

### Root Cause
During an ingestion test on 22-Sep-2026, 100 historical sheet rows had timestamps pasted into the approval status column. The previous trigger directly assigned `COALESCE(NEW.final_status, NEW.first_level_status)` without validating against the domain of allowed statuses, leaving timestamp strings in `approval_status`.

### Resolution
- Created immutable status standardizer `fn_standardize_approval_status()` which resolves all timestamp-corrupted strings to `'Approved'` (as confirmed by clean re-submissions in rows 14925–15009).
- All 15,835 rows now have clean statuses (`Approved`: 13,388, `Rejected`: 1,980, `Pending`: 456, `Draft`: 11).

---

## 3. String Bloat in `source_reference_id` (46KB+ Repetition)

### Root Cause
The previous append logic used `NOT (NEW.id::TEXT = ANY(string_to_array(v_existing_ref, ',')))`. Because `NEW.id::TEXT` is `'3047'` while elements in `v_existing_ref` are `'ADJ-SHT-3047'`, the condition was perpetually true, appending the string hundreds of times on every refresh.

### Resolution
- Standardized `source_reference_id` to exact canonical tracking identifiers (`ADJ-SHT-<id>` and `ADJ-PORTAL-<id>`).
- String length stabilized at 9–13 characters across the entire table.

---

## 4. Multi-Vehicle Fleet Operator Batches (60 Rows)

### Root Cause
Fleet operators managing multiple vehicles entered multiple registration plates into a single cell (e.g. `KA05AQ4793,KA05AQ4797,KA05AQ4828` or lists of 50 vehicles for fleet-wide TDS / Dead Mile adjustments).

### Resolution
- `core_adjustments.vehicle_number` is typed as `TEXT` to preserve raw multi-plate strings without truncation.
- Downstream in Hisaab, fleet adjustments aggregate at the **Operator level (`hisaab_partner_weekly`) by `partner_id`**, ensuring 100% accurate financial settlement.

---

## 5. Downstream Hisaab Automatic Synchronization

### Root Cause
`hisaab_adjustments_ledger` was missing approved adjustments because no trigger existed on `core_adjustments`.

### Resolution
- Created `trg_core_to_hisaab_adjustments` on `core_adjustments` executing `fn_sync_core_to_hisaab_adjustments()`.
- Automatically populates `hisaab_adjustments_ledger` for all active `Approved` adjustments, keeping Hisaab calculations in continuous real-time sync.

---

## 6. Background Automation via `pg_cron`

### Resolution
- Configured `pg_cron` schedule `sync_core_adjustments_cron` running every 15 minutes (`*/15 * * * *`) executing `SELECT public.refresh_core_adjustments();`.
- Guaranteed continuous reconciliation under transactional advisory locks (`777333444`).
