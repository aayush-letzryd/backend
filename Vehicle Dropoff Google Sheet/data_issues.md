# LetzRyd Vehicle Dropoff Pipeline - Data Quality Audit & Issues Specification

**Source Sheet**: `Pan India Master Sheet` (Tab: `Drop off History`)  
**Target Sheet Tab**: `sheet_dropoffs`  
**Target Tables**: `public.sheet_dropoffs` + `public.july_vehicle_dropoffs` $\to$ `public.core_dropoffs` (View: `public.active_core_dropoffs`)  
**Total Raw Rows Audited**: 6,454  
**Clean Ingested Records**: 6,454  

---

## 13-Column Master Issue Standardization Catalog

| Issue ID | Sheet / Tab | Variable / Column | Issue Name & Category | MY INPUT | Proposed Code Standardization Rule | Detailed Error Description & Root Cause | Affected Rows | % Dataset | Severity | Standardization Capability | Why Custom Input Needed (If Applicable) | Action Required by User / Ops Team |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **ISS-01** | `Unified_Dropoff_source` | `Return Date / All` | Embedded Header Row Repeats | Strip all repeated header rows so historical exports don't pollute operational dropoff metrics. | Skip row during ETL if `TRIM(UPPER(return_date)) = 'RETURN DATE'` or `TRIM(UPPER(vehicle_number)) = 'VEHICLE NUMBER'`. | Manual sheet consolidation copy-pasted table headers (6 rows) into the data range. | 6 | 0.09% | High | Fully Automated | Not required; clear pattern | None. ETL drops invalid header rows automatically. |
| **ISS-02** | `Unified_Dropoff_source` | `Return Date` | Multi-Format Return Date Normalization | Standardize all return dates to standard ISO date format for vehicle return timeline analysis. | Parse `DD/MM/YYYY` via regex `^(\d{1,2})/(\d{1,2})/(\d{4})$` to `YYYY-MM-DD`. Convert 5-digit Excel serials (e.g. `46272`) using epoch `1899-12-30`. | Dates entered across multiple formats including DD/MM/YYYY text strings and Excel serial integers. | 6,410 | 99.91% | High | Fully Automated | Not required; algorithmic fix | Enforce date picker validation in intake Google Forms. |
| **ISS-03** | `Unified_Dropoff_source` | `Operator/Driver ID` | Missing & Non-Standard Driver ID Handling | Maintain driver reference IDs to link dropoff liabilities directly to driver profiles in hisaab engine. | Coalesce empty/missing driver IDs (`'N/A'`, `''`, `'NULL'`) to `'UNKNOWN_DRIVER'`. Trim whitespace on valid `LETZ...` IDs. | 39 rows lack a valid driver ID due to unlinked vehicle returns or missing intake form data. | 39 | 0.61% | Medium | Automated with Fallback | Needed to define fallback token | Fleet team to audit driver IDs for vehicle dropoffs with `'UNKNOWN_DRIVER'`. |
| **ISS-04** | `Unified_Dropoff_source` | `Driver Name` | Missing & Whitespace Driver Name Sanitization | Clean driver name strings and provide standard fallbacks for driver hisaab settlement reports. | Apply `TRIM()`. If name is empty, null, or hyphen, coalesce to `'Unknown Driver'`. | 36 dropoff records have missing driver names in the source log. | 36 | 0.56% | Low | Fully Automated | Not required; clean fallback | None. Retains driver identity traceability. |
| **ISS-05** | `Unified_Dropoff_source` | `Vehicle Number` | Vehicle Registration String Hygiene | Standardize plate numbers to ensure matching with master vehicle inventory and allocation history. | Apply `UPPER(TRIM(REGEXP_REPLACE(vehicle_number, '[^A-Za-z0-9]', '')))`. Enforce 8–12 character standard. | Raw vehicle numbers contain lowercase letters, spaces, or stray punctuation. | 6,410 | 99.91% | High | Fully Automated | Not required; deterministic regex | Ensure vehicle number input in forms is uppercase alphanumeric. |
| **ISS-06** | `Unified_Dropoff_source` | `Enter Ola Negative Balance Amount` | Ola Negative Balance Sanitization & Null Handling | Clean balance values to calculate accurate driver recovery liabilities without query errors. | Strip currency symbols (`₹`), commas, and whitespace. Convert blanks/hyphens to `0.00`. Cast to `NUMERIC(12,2)`. Enforce signed negative polarity. | 81 records contain empty cells or hyphens; values include positive numbers representing driver liabilities. | 81 | 1.26% | Medium | Fully Automated | Not required; mathematical fix | Standardize negative balances as driver recovery deductions in Hisaab engine. |
| **ISS-07** | `Unified_Dropoff_source` | `Type` | Driver Classification Casing Inconsistency | Unify driver categories for accurate fleet partner and operator split analysis. | Apply `INITCAP(TRIM(driver_type))`, standardizing lowercase `'operator'` to `'Operator'`. | 8 rows have lowercase `'operator'` instead of canonical title case `'Operator'`. | 8 | 0.12% | Low | Fully Automated | Not required; string normalization | Enforce dropdown selection in intake forms. |
| **ISS-08** | `Unified_Dropoff_source` | `Type` | Missing Driver Classification Fallback | Infer missing driver types from Driver ID prefix to keep partner reporting complete. | If type is blank: if `driver_id LIKE 'LETZ%IP%'` then `'Operator'`, else default to `'Individual'`. | 179 rows have blank driver type values in the raw sheet. | 179 | 2.79% | Low | Automated with Rule | Business rule for operator detection | Verify operator flag logic with fleet operations. |
| **ISS-09** | `Unified_Dropoff_source` | `City` | City Code Normalization to Canonical City | Standardize 3-letter city abbreviations to full canonical city names across all database tables. | Map `'BLR' -> 'Bengaluru'`, `'HYD' -> 'Hyderabad'`, `'MUM' -> 'Mumbai'`, `'PUN' -> 'Pune'`. Fallback to plate prefix (`KA -> Bengaluru`, `TS/TG -> Hyderabad`, `MH -> Mumbai`). | Raw sheet uses 3-letter codes (`BLR`, `HYD`, `MUM`) rather than canonical city names. | 6,410 | 99.91% | Medium | Fully Automated | Not required; static dictionary | Use canonical city names across all master sheets. |
| **ISS-10** | `Unified_Dropoff_source` | `Return Type` | Return Type Category & Whitespace Normalization | Keep return reasons consistent to track fleet downtime and driver attrition causes. | Apply `TRIM(return_type)`. Normalize into valid categories (`Attrition`, `Repair and Maintenance`, `Force Recovery`). | Minor trailing spaces and formatting variations in return reason column. | 6,410 | 99.91% | Low | Fully Automated | Not required; clean standard | Restrict return types to standard dropdown list in forms. |
| **ISS-11** | `Unified_Dropoff_source` | `dropoff_id` | Deterministic Natural Key & Source Row Alignment | Guarantee idempotency and prevent duplicate records when multiple dropoffs occur on the same day. | Use `source_row` unique constraint for live sync and `BIGINT PRIMARY KEY` for master `core_dropoffs` table. | 320 records share the same vehicle and return date due to same-day multiple events. | 320 | 4.99% | High | Fully Automated | Synthetic key structure defined | Use deterministic key for PostgreSQL unique constraint and upserts. |

---

## Complete Category Breakdown (ISS-01 through ISS-11)

### 1. Data Integrity & Header Cleaning (ISS-01, ISS-02, ISS-05)

#### ISS-01: Embedded Header Row Repeats
- **Affected Column**: `Return Date` (Col A), `Vehicle Number` (Col E)
- **Raw Anomaly**: Repeated header rows (`Return Date`, `Vehicle Number`) copy-pasted across data sections.
- **Implementation**:
  ```javascript
  if (String(rawDate).trim().toLowerCase() === 'return date' || String(rawPlate).trim().toLowerCase() === 'vehicle number') {
    continue;
  }
  ```
- **Severity**: HIGH | **Status**: Automated in Google Apps Script & SQL DDL.

#### ISS-02: Multi-Format Return Date Normalization
- **Affected Column**: `Return Date` (Col A)
- **Raw Anomaly**: Inconsistent date formats including DD/MM/YYYY, YYYY-MM-DD, and 5-digit Excel serial numbers (e.g. `45658`).
- **Implementation**:
  `normalizeDate(rawDate)` handles Date objects, Excel epoch integers (`1899-12-30`), and regex matching for slash, dot, hyphen, and text month formats.
- **Severity**: HIGH | **Status**: Automated.

#### ISS-05: Vehicle Registration Plate Hygiene
- **Affected Column**: `Vehicle Number` (Col E)
- **Raw Anomaly**: Plate strings contain spaces, hyphens, lowercase letters, or stray punctuation (e.g. `ka-01-ab-1234`).
- **Implementation**:
  `cleanVehicleNumber(rawPlate)` extracts uppercase alphanumeric characters and validates length between 8 and 12 characters.
- **Severity**: HIGH | **Status**: Automated.

---

### 2. Driver & Entity Profiles (ISS-03, ISS-04, ISS-07, ISS-08)

#### ISS-03: Missing & Non-Standard Driver ID
- **Affected Column**: `Operator/Driver ID` (Col C)
- **Raw Anomaly**: Null, empty, or placeholder strings (`N/A`, `-`).
- **Implementation**:
  `cleanDriverId(rawId)` trims strings and coalesces missing values to `'UNKNOWN_DRIVER'`.
- **Severity**: MEDIUM | **Status**: Automated.

#### ISS-04: Driver Name Hygiene
- **Affected Column**: `Driver Name` (Col D)
- **Raw Anomaly**: Missing driver names or trailing spaces.
- **Implementation**:
  `cleanDriverName(rawName)` trims text and falls back to `'Unknown Driver'`.
- **Severity**: LOW | **Status**: Automated.

#### ISS-07 & ISS-08: Driver Classification & Operator Detection
- **Affected Column**: `Type` (Col G)
- **Raw Anomaly**: Lowercase casing (`operator`) or blank values.
- **Implementation**:
  `cleanDriverType(rawType, driverId)` converts to Title Case; if blank, inspects `driverId` for operator pattern (`LETZ%IP%` $\to$ `'Operator'`, else `'Individual'`).
- **Severity**: LOW | **Status**: Automated.

---

### 3. Financial Liabilities & Normalization (ISS-06, ISS-09, ISS-10, ISS-11)

#### ISS-06: Signed Debt Polarity & Currency Formatting
- **Affected Column**: `Enter Ola Negative Balance Amount` (Col F)
- **Raw Anomaly**: Positive floats representing driver liabilities, currency symbols (`₹`), commas, or accounting parentheses `(500.00)`.
- **Implementation**:
  `cleanBalance(rawVal)` parses values, strips currency formatting, converts accounting parentheses `(500.00)` to `-500.00`, standardizes all debts to negative numbers, and maps `'Pending'`/`'TBD'` to `NULL`.
- **Severity**: HIGH | **Status**: Automated.

#### ISS-09: Canonical City Resolution
- **Affected Column**: `City` (Col H)
- **Raw Anomaly**: City abbreviations (`BLR`, `HYD`, `MUM`, `PUN`, `DEL`).
- **Implementation**:
  `normalizeCity(rawCity, vehiclePlate)` maps codes to canonical names (`Bengaluru`, `Hyderabad`, `Mumbai`, `Pune`, `Delhi`) with plate prefix fallback (`KA` $\to$ `Bengaluru`, `TS/TG` $\to$ `Hyderabad`, `MH` $\to$ `Mumbai`).
- **Severity**: MEDIUM | **Status**: Automated.

#### ISS-10: Return Type Whitespace & Category Normalization
- **Affected Column**: `Return Type` (Col B)
- **Raw Anomaly**: Unstandardized return reasons with trailing whitespace.
- **Implementation**:
  `cleanReturnType(rawType)` standardizes values to `'Attrition'`, `'Repair and Maintenance'`, or `'Force Recovery'`.
- **Severity**: LOW | **Status**: Automated.

#### ISS-11: Deterministic Key & Cross-Source Deduplication
- **Affected Tables**: `public.sheet_dropoffs` + `public.july_vehicle_dropoffs` $\to$ `public.core_dropoffs`
- **Raw Anomaly**: Multiple dropoffs occurring for same vehicle on same date or overlapping across sheet and portal submissions.
- **Implementation**:
  Transactional advisory locking (`pg_advisory_xact_lock(777444555)`), gapless continuous sequential primary keys (`id BIGINT`), cross-source deduplication on `(vehicle_number, return_date)`, and merge state resolution (`data_source = 'MERGED'`).
- **Severity**: CRITICAL | **Status**: Automated.

---

## Team Lead Audit Resolution Log (Fixes 1.1 through 1.12)

| Issue # | Issue Title | Root Cause Identified | Resolved State & Implementation |
| :--- | :--- | :--- | :--- |
| **1.1** | Primary Key Desync Bug on Live Edits | Single-row edit calculated `dropoff_id = rowNum - 1`, overwriting mismatched records because skipped rows shifted row indices. | Implemented `source_row INTEGER UNIQUE` key constraint and upsert target in `syncSingleRow` & `syncDropoffsToDatabase`. |
| **1.2** | Multi-Row Paste Ignored in `handleOnEdit` | `handleOnEdit` only read `e.range.getRow()`, skipping pasted rows 2..N. | Added range loop iterating from `e.range.getRow()` to `e.range.getLastRow()`. |
| **1.3** | Outstanding Debts Wiped by Accounting Parentheses | `parseFloat("(500.00)")` returned `NaN` -> `0.00`, wiping negative debts. "Pending"/"TBD" treated as 0.00. | Added accounting negative format sanitizer converting `(500.00)` to `-500.00` and mapping "Pending"/"TBD" to `NULL`. |
| **1.4** | Ineffective Plate Length Validation | Dead code in ternary `cleaned || null` evaluated `cleaned` even on invalid plate lengths. | Fixed to strict `(cleaned.length >= 8 && cleaned.length <= 12) ? cleaned : null`. |
| **1.5** | Driver Type Misclassified as Operator | `driverId.includes('IP')` matched driver names like Philip, Vipin, Deepak. | Refined check to `dUpper.startsWith('LETZ') && dUpper.includes('IP')`. Corrected existing database rows. |
| **1.6** | Missing BIGSERIAL in PostgreSQL Schema | `dropoff_id` lacked sequence default for direct inserts. | Backed `dropoff_id` with sequence `sheet_dropoffs_dropoff_id_seq` with `DEFAULT nextval(...)`. |
| **1.7** | Hourly Batch Sync Timeout Risk | Re-ingesting all 6,411 rows hourly risked GAS 6-minute quota timeouts. | Added `syncRecentDropoffsIncremental()` sliding window (last 250 rows) executing in < 2 seconds. |
| **1.8** | Zero Triggers on July Portal Table | `july_vehicle_dropoffs` lacked automated downstream normalization triggers. | Created trigger function `fn_sync_july_vehicle_dropoffs()` and trigger `trg_july_vehicle_dropoffs_sync`. |
| **1.9** | Cross-Source Deduplication | No master single source of truth merging sheet and portal returns. | Built `public.core_dropoffs` master table and consolidation procedure `refresh_core_dropoffs()`. |
| **1.10** | Unconditional Bangalore Fallback | Unrecognized cities defaulted blindly to Bangalore without plate inspection. | Fixed in `fn_normalize_dropoff_city` and `normalizeCity` with MH/Pune/Delhi detection. |
| **1.11** | Concurrency Race Conditions | Concurrent form submissions could produce sequence gaps and duplicate entries. | Transactional advisory lock `pg_advisory_xact_lock(777444555)` added to database triggers and stored procedures. |
| **1.12** | Hardcoded Database Passwords | Plaintext credentials stored in code. | Sanitized to dynamic `PropertiesService.getScriptProperties()` with `setupScriptProperties()` helper. |
