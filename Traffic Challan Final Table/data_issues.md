# Master Traffic Challan Data Quality & Edge Cases Catalog

This catalog documents the data discrepancies, schema variations, formatting inconsistencies, and operational edge cases discovered during the consolidation of LetzRyd's traffic challan data sources:
1. `public.sheet_challans` (36,239 manual Google Sheet logs across 38 weekly audit cycles)
2. `public.vehicle_challans` (594 direct Karnataka One traffic portal scraper logs)

---

## 1. Standardization & Data Governance Policy

Per LetzRyd engineering standards and master table architecture:
- **Natural Key Identification**:
  - `vehicle_reg_no`: Standardized via alphanumeric regex cleaning (`UPPER(REGEXP_REPLACE(p_plate, '[^A-Za-z0-9]', '', 'g'))`) and length validation (8-12 characters).
  - `notice_no`: Official traffic violation notice number used in conjunction with `vehicle_reg_no` for record uniqueness.
- **Scraper Priority (Single Source of Truth Rule)**:
  - If a violation appears in both the manual Google Sheet ledger and the Karnataka One Scraper table:
    - **Karnataka One Scraper (`public.vehicle_challans`)** takes strict precedence for official legal fine amounts, violation date/time, offence description, and police station point name.
    - **Google Sheet Ledger (`public.sheet_challans`)** enriches non-conflicting operational attributes: `previous_balance`, `sticker_fine`, driver `amount_paid`, `week_cycle`, and `remarks`.
    - The consolidated record is tagged with `source_system = 'MERGED_AUTOMATION_SHEET'`.
- **Zero Modifications to Source Tables**:
  - `public.sheet_challans` and `public.vehicle_challans` remain 100% untouched.

---

## 2. Catalog of Discovered Issues & Resolution Strategy

### ISS-01: Phantom Debt Summary & Header Rows in Sheet Data
- **Source Table**: `public.sheet_challans`.
- **Symptoms**: Summary/total rows (e.g. `REGNO`, `TOTAL`, `BALANCE`, `SUBTOTAL`) embedded inside weekly Google Sheet tabs.
- **Root Cause**: Manual spreadsheets included intermediate sum formulas that were ingested as data rows.
- **Pipeline Handling**: Excluded via `fn_clean_challan_plate()` which rejects keywords (`TOTAL`, `REGNO`, `BALANCE`, `SUBTOTAL`) and enforces 8-12 character alphanumeric length validation.
- **Ops Recommendation**: Lock formula cells and use dedicated summary tabs rather than in-table summary rows.

---

### ISS-02: Plate Number Formatting Variations (Spaces, Hyphens, Case)
- **Source Tables**: Both `public.sheet_challans` and `public.vehicle_challans`.
- **Symptoms**: Formats like `KA 01 AB 1234`, `ka-01-ab-1234`, `KA.01.AB.1234`, or `KA01AB1234`.
- **Pipeline Handling**: Cleaned deterministically using `fn_clean_challan_plate()` to output standard uppercase alphanumeric strings (`KA01AB1234`).
- **Ops Recommendation**: Implement strict regex input validation on intake forms and UI inputs.

---

### ISS-03: Multiple Date & Time String Formats
- **Source Tables**: `public.vehicle_challans` (stores timestamps as text like `09-09-2026 14:30:00` or `09-09-2026`), `public.sheet_challans` (stores dates as text / dates across multiple sheets).
- **Symptoms**: Inconsistent date representations (`DD-MM-YYYY`, `YYYY-MM-DD`, `DD/MM/YYYY`).
- **Pipeline Handling**: Handled dynamically using `fn_parse_challan_date()` and `fn_parse_challan_time()` with robust regex matching and exception-safe fallback to `NULL`.
- **Ops Recommendation**: Enforce ISO-8601 formatting (`YYYY-MM-DD` and `HH24:MI:SS`) in all scraper pipelines and database ingestion scripts.

---

### ISS-04: Liability Classification (`TRAFFIC_FINE` vs `STICKER_FINE` vs `ROLLING_BALANCE`)
- **Source Table**: `public.sheet_challans`.
- **Symptoms**: Spreadsheets track multiple liability types in the same ledger without an explicit categorization column.
- **Pipeline Handling**: Deterministically categorized in the master pipeline:
  - If `challan_amount > 0` $\rightarrow$ `TRAFFIC_FINE`
  - If `sticker_fine > 0` and `challan_amount = 0` $\rightarrow$ `STICKER_FINE`
  - If `challan_amount = 0` and `sticker_fine = 0` and `previous_balance > 0` $\rightarrow$ `ROLLING_BALANCE`
- **Ops Recommendation**: Maintain dedicated liability categories in future Google Sheet templates.

---

### ISS-05: Gapless Sequential Primary Key Allocation
- **Issue**: Standard PostgreSQL `SERIAL` sequences burn IDs when `INSERT ... ON CONFLICT` or validation exceptions occur, creating sequence gaps in financial audit tables.
- **Pipeline Handling**: Implemented transactional advisory locks (`pg_advisory_xact_lock(888999222)`) computing `SELECT COALESCE(MAX(id), 0) + 1` atomically on inserts, guaranteeing strictly continuous primary keys from `1` to `N` (`36,461`).
- **Ops Recommendation**: Standard pattern across all LetzRyd master tables (`core_vehicle_onboarding`, `core_challans`, `core_walkin`).

---

### ISS-06: Soft Deletion & Audit Trail Preservation
- **Issue**: If a row is deleted from Google Sheets or an automated scraper run re-evaluates records, hard deletion would destroy financial recovery history.
- **Pipeline Handling**: Triggers intercept `DELETE` actions on staging tables and convert them to `is_deleted = TRUE` with `deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.
- **Ops Recommendation**: Use `WHERE is_deleted = FALSE` for operational queries and full table scans for compliance audits.
