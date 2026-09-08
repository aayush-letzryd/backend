# Vehicle Onboarding Data Quality & Operational Issues Catalog

This catalog documents the data discrepancies, schema variations, and operational edge cases discovered across the two upstream vehicle onboarding data sources:
1. `public.sheet_vehicle_onboarding` (Google Sheet submissions via Apps Script JDBC pipeline)
2. `public.july_vehicle_onboarding` (Web portal vehicle onboarding form submissions)

---

## 1. Standardization & Data Governance Policy

Per operational guidelines and master architecture:
- **Functional Columns Standardized**:
  - `registration_no`: Cleaned of all spaces, hyphens, special characters, and converted to uppercase (`UPPER(REGEXP_REPLACE(...))`) to serve as the unified natural primary key.
  - `city`: Standardized to canonical hub names (`Bengaluru`, `Hyderabad`, `Mumbai`, `Delhi`) for cross-table joins, reporting, and city-level slicing.
  - `dates`: Parsed flexibly across ISO (`YYYY-MM-DD`), standard Indian (`DD-MM-YYYY`), and slashed formats into standard PostgreSQL `DATE` types.
  - `kms_reading`: Cleaned of text suffixes (e.g. "kms", commas) into numeric values.
- **Portal Precedence (Single Source of Truth Rule)**:
  - If a vehicle plate exists in both Google Sheets and the Web Portal, the Portal Form (`public.july_vehicle_onboarding`) takes top priority for core vehicle specifications and documents.
  - Non-conflicting operational fields from Google Sheets (e.g. PDI audit timestamps, financier, ageing, comments) enrich the record.
- **Verbatim Pass-Through (Untouched by Pipeline)**:
  - Human notes, comments, document URLs, and remarks pass through intact without truncation or modification.
- **Zero Modifications to Source Tables**:
  - `sheet_vehicle_onboarding` and `july_vehicle_onboarding` remain 100% untouched.

---

## 2. Catalog of Discovered Issues & Resolution Strategy

### ISS-01: Plate Formatting Variations (Spaces & Hyphens)
- **Source Tables**: Both `sheet_vehicle_onboarding` and `july_vehicle_onboarding`.
- **Symptoms**: Inputs such as `KA 01 AB 1234`, `ka-01-ab-1234`, or `KA01AB1234`.
- **Pipeline Handling**: Standardized by `fn_clean_plate()` which strips all non-alphanumeric characters and transforms text to uppercase (`KA01AB1234`).
- **Ops Recommendation**: Enforce standard regex masking (`^[A-Z]{2}[0-9]{2}[A-Z]{1,2}[0-9]{4}$`) on portal form inputs.

---

### ISS-02: City Naming Variations (`Bangalore` vs `Bengaluru`)
- **Source Tables**: `july_vehicle_onboarding` (uses `Bangalore`), `sheet_vehicle_onboarding` (uses `Bengaluru`).
- **Root Cause**: Different intake portals used differing city spelling options.
- **Pipeline Handling**: **Functionally Standardized**. The database triggers automatically normalize `Bangalore`, `bangalore`, and `blr` to `Bengaluru`.
- **Ops Recommendation**: Enforce dropdown selection for hub cities on web portals.

---

### ISS-03: Chassis Number Length Discrepancies
- **Source Table**: `sheet_vehicle_onboarding`.
- **Root Cause**: Some older spreadsheet entries recorded truncated or partial chassis numbers instead of standard 17-character VINs.
- **Pipeline Handling**: Preserved verbatim in `chassis_no` with `chassis_review_flag = TRUE` where applicable, while allowing portal submissions to provide the complete 17-digit VIN.
- **Ops Recommendation**: Add front-end validation enforcing 17 alphanumeric characters for chassis inputs.

---

### ISS-04: Date Format Inconsistencies across Portal & Sheets
- **Source Tables**: `july_vehicle_onboarding` stores validity dates as text strings (`character varying`), while `sheet_vehicle_onboarding` stores them as standard `DATE`.
- **Root Cause**: The web portal form stored validity inputs as raw strings.
- **Pipeline Handling**: The trigger function `fn_parse_flexible_date()` dynamically parses multiple string date variations (`YYYY-MM-DD`, `DD/MM/YYYY`, `DD-MM-YYYY`) into native PostgreSQL `DATE` types.
- **Ops Recommendation**: Ensure the web portal backend casts date inputs to native `DATE` objects before database insertion.

---

### ISS-05: Dual Submissions across Portal & Google Sheet
- **Source Tables**: Vehicles logged in both Google Sheets and the Web Portal.
- **Pipeline Handling**: The record is merged with `source_system = 'MERGED_PORTAL_SHEET'`. Portal values take precedence for core vehicle data, while sheet metadata enriches operational details.
- **Ops Recommendation**: Direct field executives to use the Web Portal as the primary entry point to deprecate manual sheet updates over time.
