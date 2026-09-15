# Master Traffic Challan Data Quality & Edge Cases Catalog

This catalog documents the data discrepancies, schema variations, formatting inconsistencies, and operational edge cases discovered and resolved during the consolidation of LetzRyd's traffic challan data sources:
1. `public.sheet_challans` (37,948 manual Google Sheet logs across 38 weekly audit cycles)
2. `public.vehicle_challans` (1,129 direct Karnataka One traffic portal scraper logs)
3. `public.core_challans` (38,710 master unified Single Source of Truth records)

---

## 1. Standardization & Governance Policies

- **Natural Business Key Identification**:
  - `vehicle_reg_no`: Standardized via alphanumeric regex cleaning (`UPPER(REGEXP_REPLACE(p_plate, '[^A-Za-z0-9]', '', 'g'))`) and length validation (8-12 characters).
  - `notice_no`: Official traffic violation notice number used in conjunction with `vehicle_reg_no` and `week_cycle` for uniqueness.
- **Scraper Priority (Single Source of Truth Rule)**:
  - If a violation appears in both the manual Google Sheet ledger and the Karnataka One Scraper table:
    - **Karnataka One Scraper (`public.vehicle_challans`)** takes strict precedence for official legal fine amounts, violation date/time, offence description, and police station point name.
    - **Google Sheet Ledger (`public.sheet_challans`)** enriches non-conflicting operational attributes: `previous_balance`, `sticker_fine`, driver `amount_paid`, `week_cycle`, and `remarks`.
    - The consolidated record is tagged with `source_system = 'MERGED_AUTOMATION_SHEET'` or `KARNATAKA_ONE_SCRAPER`.
- **Zero Modifications to Upstream Tables**:
  - `public.sheet_challans` and `public.vehicle_challans` remain 100% untouched.

---

## 2. Catalog of Discovered Issues & Resolution Strategy

### ISS-01: Summary Rows Embedded in Weekly Sheet Tabs
- **Source Table**: `public.sheet_challans`.
- **Symptoms**: Embedded formula total rows (e.g. `REGNO`, `TOTAL`, `BALANCE`, `SUBTOTAL`).
- **Remediation**: Filtered deterministically via `fn_clean_challan_plate()` which rejects keywords and validates 8-12 alphanumeric characters.

### ISS-02: Plate Number Variations (Spaces, Hyphens, Lowercase)
- **Source Tables**: Both `public.sheet_challans` and `public.vehicle_challans`.
- **Symptoms**: Formats like `KA 01 AB 1234`, `ka-01-ab-1234`, `KA.01.AB.1234`.
- **Remediation**: Standardized to canonical uppercase alphanumeric strings (`KA01AB1234`) across all lookups and indexes.

### ISS-03: Diverse Date and Time String Representations
- **Source Tables**: Both upstream sources.
- **Symptoms**: Formats varying across `DD-MM-YYYY`, `YYYY-MM-DD`, `DD/MM/YYYY`, with text timestamp concatenations.
- **Remediation**: Evaluated dynamically using `fn_parse_challan_date()` and `fn_parse_challan_time()` with robust regex matching and exception-safe fallback to `NULL`.

### ISS-04: Liability Classification Taxonomy
- **Source Table**: `public.sheet_challans`.
- **Symptoms**: Spreadsheets mix traffic fines, internal sticker fines, and carried-forward rolling debt in common columns.
- **Remediation**: Categorized into explicit liability types:
  - `challan_amount > 0` -> `TRAFFIC_FINE`
  - `sticker_fine > 0` and `challan_amount = 0` -> `STICKER_FINE`
  - `challan_amount = 0` and `sticker_fine = 0` and `previous_balance > 0` -> `ROLLING_BALANCE`

### ISS-05: Gapless Sequential Primary Key Allocation
- **Problem**: Standard `SERIAL` sequences burn IDs on conflict or rollback, creating sequence gaps in financial audit records.
- **Remediation**: Transactional advisory locks (`pg_advisory_xact_lock(888999222)`) compute `SELECT COALESCE(MAX(id), 0) + 1` atomically on inserts, guaranteeing strictly continuous primary keys from `1` to `38,710`.

### ISS-06: Non-Destructive Soft Deletion Preservation
- **Problem**: Hard deletes on upstream staging sheets destroy financial recovery tracking and alter primary key sequencing.
- **Remediation**: Triggers intercept `DELETE` actions on staging tables and convert them to `is_deleted = TRUE` with `deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.

### ISS-07: Cross-Week Duplicate Notice Handling
- **Problem**: Unpaid violations are frequently copied forward across weekly tabs in manual spreadsheets.
- **Remediation**: Ingestion indexes on `(vehicle_reg_no, notice_no, week_cycle)` ensure each weekly billing snapshot maintains its independent settlement state without colliding.

### ISS-08: Karnataka One Portal Scraper Precedence
- **Problem**: Manual spreadsheet entries for Bangalore fines often contain typographical fine amounts or lagged payment statuses.
- **Remediation**: The automated scraper pipeline (`public.vehicle_challans`) supersedes manual records for Bangalore, updating fine amounts and police station details with official government portal data.
