# LetzRyd Accidents Pipeline - Data Quality Audit & Issues Specification

This document provides a comprehensive audit of all 10 data quality anomalies (`ACC-01` through `ACC-10`) identified during the analysis of the LetzRyd raw accident vehicle report Google Sheet (`Accident vehicle report` in `WIP- Pan India.xlsx`) and the database portal records (`july_accidents_registry`) in `Master_Issue_Standardization_Catalog.xlsx`, and details the exact standardization logic implemented in `accidents_pipeline_appscript.js` and `schema.sql`.

---

## Complete Issue Catalog (ACC-01 through ACC-10)

### 1. Vehicle Registration & Entity Keys (ACC-01 to ACC-03)

#### ACC-01: Vehicle Registration Number Casing & Spacing Inconsistency
- **Affected Column**: `Reg No` (Col C)
- **Raw Anomaly**: Vehicle numbers entered with mixed lowercase letters, hyphens, and whitespace (e.g. `mh03es1189`, `MH-03-ES-1164`, `KA 01 AB 1234`).
- **Standardization Rule**:
  `cleanVehicleNumber(reg)` converts the string to uppercase, strips all non-alphanumeric characters, and validates against canonical Indian vehicle registration regex: `^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$` (e.g. `MH03ES1189`).
- **Severity**: MEDIUM | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ACC-02: City / Location Abbreviation Fragmentation
- **Affected Column**: `Location ` (Col D)
- **Raw Anomaly**: Inconsistent usage of 3-letter city codes (`MUM`, `BLR`, `HYD`) and full city names (`Mumbai`, `Bengaluru`, `Bangalore`, `Hyderabad`).
- **Standardization Rule**:
  `standardizeCityCode(location)` maps all raw variants to canonical 3-letter uppercase codes: `'BLR'`, `'HYD'`, `'MUM'`, `'DEL'`, `'CHN'`, `'PUN'`.
- **Severity**: LOW | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ACC-03: Excel Serial Date & Float Representation
- **Affected Columns**: `Timestamp` (Col A), `Accident Date ` (Col E), `Vehicle RFD date` (Col P)
- **Raw Anomaly**: Timestamps and dates stored as floating-point day numbers since the Excel epoch (e.g. `45707.42965`, `45658.0`, `45685.0`).
- **Standardization Rule**:
  `parseExcelTimestamp(val)` and `parseExcelDate(val)` convert serial day floats to standard ISO-8601 strings (`YYYY-MM-DD HH:mm:ss` / `YYYY-MM-DD`) and SQL `TIMESTAMPTZ` / `DATE`.
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

---

### 2. Form Fragmentations & Financial Standardization (ACC-04 to ACC-06)

#### ACC-04: Fragmented Split-Column Police Status
- **Affected Columns**: `Police Acknowledgement [Yes]` (Col F), `Police Acknowledgement [NO]` (Col G), `Police Acknowledgement` (Col L)
- **Raw Anomaly**: Police status split across 3 separate columns with placeholder strings like `'Column 1'`.
- **Standardization Rule**:
  Consolidated into a single SQL `BOOLEAN police_acknowledgement`. If Col F is populated or Col L contains `'Yes'`/`'True'`, stored as `TRUE`; if Col G is populated or Col L contains `'No'`, stored as `FALSE`; otherwise `NULL`.
- **Severity**: MEDIUM | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ACC-05: Duplicate & Inconsistent Driver Columns
- **Affected Columns**: `Driver/Operator Name` (Col M & Col N)
- **Raw Anomaly**: Duplicate driver/operator name columns with slight spelling variations, casing differences, and stray whitespace.
- **Standardization Rule**:
  Prioritizes Col N (standardized name) falling back to Col M, trims whitespace, collapses double spaces, and converts to uppercase text.
- **Severity**: LOW | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ACC-06: Non-Numeric Currency Formatting & Inconsistent Decimals
- **Affected Columns**: `Estimate Amount ` (Col I), `Letzryd payable amount ` (Col K), `Labilty` (Col R), `LetzRyd Share of Invoice` (Col S), `Total Invoice` (Col Q)
- **Raw Anomaly**: Financial figures entered with currency symbols (`₹`, `Rs`), comma separators (`1,73,561.30`), and floating `.0` decimals.
- **Standardization Rule**:
  `parseNumericAmount(val)` strips non-numeric characters, parses valid floating decimals into `NUMERIC(12,2)`, and defaults empty/unbilled amounts to `NULL` or `0.00`.
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

---

### 3. Entity Resolution & Database Consolidation (ACC-07 to ACC-10)

#### ACC-07: Missing / Unresolved Driver LID Formula
- **Affected Column**: `Driver LID` (Col AD)
- **Raw Anomaly**: 64.3% of rows contain blanks or `'Not Found'` due to Google Sheets VLOOKUP table offset failures.
- **Standardization Rule**:
  Dynamic ETL lookup against `public.sheet_vehicle_allocations` / `public.core_partner_onboarding` using `vehicle_number` and `accident_date` to deterministically resolve the active `partner_id` (`LETZ<CITY><PHONE>`).
- **Severity**: CRITICAL | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ACC-08: Inline Metadata Artifacts & Ghost Formula Headers
- **Affected Columns**: `Mapping` (Col U), `Date` (Col V), `Vehicle No` (Col W), `vehicle Model` (Col X), `Vendor Name` (Col Y), `City` (Col Z), `Concatenate` (Col AA), `Duplicate Check ` (Col AE)
- **Raw Anomaly**: Table lookup headers and helper formulas embedded inside the data range.
- **Standardization Rule**:
  Dropped during ingestion. Relational integrity and deduplication are enforced natively via PostgreSQL constraints: `UNIQUE (submission_timestamp, vehicle_number, accident_date)`.
- **Severity**: LOW | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ACC-09: Fragmented Remarks & Month Tagging
- **Affected Columns**: `Remarks` (Col H), `Remarks 1` (Col O), `Remarks 1` (Col AF)
- **Raw Anomaly**: Incident narrative split across multiple remark columns with embedded month tags (e.g. `'Jan-25'`).
- **Standardization Rule**:
  Merges incident narrative while stripping standalone month tags into clean `incident_remarks` text.
- **Severity**: LOW | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ACC-10: Cross-Source Portal Consolidation & Deduplication
- **Affected Tables**: `public.sheet_accidents` + `public.july_accidents_registry` $\to$ `public.core_accidents`
- **Raw Anomaly**: Accident reports logged through both Google Form response sheets and web portal form (`july_accidents_registry`).
- **Standardization Rule**:
  Automated PostgreSQL consolidation procedure `refresh_core_accidents()` merges records on `(vehicle_number, accident_date)`, giving precedence to verified portal entries while backfilling historical Google Sheet incidents.
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)
