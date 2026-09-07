# LetzRyd Adjustments Pipeline - Data Quality Audit & Issues Specification

This document provides a comprehensive audit of all 11 data quality anomalies (`ADJ-01` through `ADJ-11`) identified during the analysis of the LetzRyd raw adjustments Google Sheet (`Adjustment-Form` in `Pan India Master Sheet.xlsx`) and the database portal records (`july_partner_adjustment`) in `Master_Issue_Standardization_Catalog.xlsx`, and details the exact standardization logic implemented in `adjustments_pipeline_appscript.js` and `schema.sql`.

---

## Complete Issue Catalog (ADJ-01 through ADJ-11)

### 1. Demographics & Entity Identification (ADJ-01 to ADJ-05)

#### ADJ-01: City Name Casing & Whitespace Variations
- **Affected Column**: `City Name` (Col C)
- **Raw Anomaly**: Inconsistent capitalization, leading/trailing whitespace, and mixed city abbreviations (e.g. `bengaluru`, `MUMBAI `, `bangalore`).
- **Standardization Rule**:
  `standardizeCity(city)` trims whitespace and converts string to canonical Title Case (`'Bengaluru'`, `'Mumbai'`, `'Hyderabad'`, `'Delhi'`, `'Chennai'`, `'Pune'`).
- **Severity**: LOW | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ADJ-02: Partner Type Casing & Trailing Space in Header
- **Affected Column**: `Partner Type ` (Col D)
- **Raw Anomaly**: Column header contains trailing space (`'Partner Type '`) and entries vary in casing and formatting (`Operator`, `individual`, `na`).
- **Standardization Rule**:
  Standardized to canonical Title Case ENUM (`'Individual'`, `'Operator'`, `'Fleet'`, `'Rental'`).
- **Severity**: LOW | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ADJ-03: Phone Number Float & Scientific Notation Glitches
- **Affected Column**: `Partner Number` (Col G)
- **Raw Anomaly**: Phone numbers formatted as floating-point numbers (`9136840411.0`), scientific notation (`9.13684E+09`), 9-digit truncated strings (`934693940`), or placeholder strings (`'nan'`).
- **Standardization Rule**:
  `sanitizePhoneNumber(phone)` strips non-digits, extracts the last 10 valid digits, and validates the Indian mobile prefix (`^[6-9][0-9]{9}$`). Invalid/placeholder values are stored as `NULL`.
- **Severity**: CRITICAL | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ADJ-04: Placeholder Strings & Missing Partner Code
- **Affected Column**: `Partner Code` (Col H)
- **Raw Anomaly**: Missing partner codes or literal placeholders (`'na'`, `'nan'`, `'-'`).
- **Standardization Rule**:
  `generatePartnerId(city, phone)` automatically generates deterministic partner ID: `LETZ` + `CITY_CODE` + `10_DIGIT_PHONE` (e.g. `LETZMUM9136840411`).
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ADJ-05: Malformed Vehicle Numbers & Short Digit Snippets
- **Affected Column**: `Vehicle number` (Col I)
- **Raw Anomaly**: Vehicle numbers entered as 4-digit snippets (`'5548'`, `'1050'`, `'1480'`), negative prefixes (`'-882'`), or placeholder strings (`'na'`).
- **Standardization Rule**:
  `sanitizeVehicleNumber(veh)` converts to uppercase, strips non-alphanumeric characters, validates against regex `^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$`, or flags snippet for partner allocation lookup.
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

---

### 2. Financials & Multi-Level Approval State (ADJ-06 to ADJ-08)

#### ADJ-06: Negative Amounts, Non-Numeric Strings & Blanks
- **Affected Column**: `Enter Amount` (Col M)
- **Raw Anomaly**: Negative values (`'-100'`), currency symbols, strings, and missing values in unapproved drafts.
- **Standardization Rule**:
  `parseAdjustmentAmount(amt)` extracts absolute decimal value `ABS(CAST(clean_amt AS NUMERIC(12,2)))`, defaulting missing values to `0.00`.
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ADJ-07: Multi-Level Approval State Contradictions
- **Affected Columns**: `Status` (Col T), `Timestamp` (Col U), `Final Level Approval by` (Col X), ` Status` (Col Y), `Timestamp` (Col Z)
- **Raw Anomaly**: 382 rows exhibit conflicting statuses between First Level Approval (`Col T`) and Final Level Approval (`Col Y`), e.g. Level 1 Approved vs Final Level Rejected.
- **Standardization Rule**:
  State precedence hierarchy enforced: Final Level Approval (Col Y) > First Level Approval (Col T) > Default (`'Pending'`). Dual timestamps and approver IDs preserved in audit logs.
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ADJ-08: Excel Serial Days Stored as Strings
- **Affected Columns**: `Timestamp` (Col A), `Adjustment Date` (Col L), `Timestamp` (Col U), `Timestamp` (Col Z)
- **Raw Anomaly**: 99.95% of records store timestamps and adjustment dates as raw floating-point serial days (e.g. `45705.43008`, `45704`).
- **Standardization Rule**:
  Multi-format parser converts serial day numbers to standard ISO-8601 timestamps and SQL `DATE` values.
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

---

### 3. Reporting & Master Consolidation (ADJ-09 to ADJ-11)

#### ADJ-09: Redundant Spreadsheet Helper Formula Column
- **Affected Column**: `Duplicate Check` (Col AA)
- **Raw Anomaly**: Spreadsheet helper formula `=COUNTIF(...)` slows workbook performance.
- **Standardization Rule**:
  Dropped during ingestion. Relational deduplication enforced natively via PostgreSQL composite unique constraint: `UNIQUE (submission_timestamp, partner_number, adjustment_date, adjustment_type)`.
- **Severity**: LOW | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ADJ-10: Free-Text Hisaab Week String Parsing
- **Affected Columns**: `Adjustment Done Week` (Col AC), `Hisaab Week Number` (Col AD)
- **Raw Anomaly**: Hisaab week recorded as unstructured strings (`'21. MUM Hisaab -May 19th to May 25th CY25WK21'`).
- **Standardization Rule**:
  Regex parser extracts clean integer week number (`21`) and canonical week identifier (`CY25WK21`).
- **Severity**: LOW | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)

#### ADJ-11: Cross-Source Portal Consolidation & JSON Approval Chains
- **Affected Tables**: `public.sheet_adjustments` + `public.july_partner_adjustment` $\to$ `public.core_adjustments`
- **Raw Anomaly**: Adjustments logged across Google Sheets and web portal forms with JSON approval chains and contested line items.
- **Standardization Rule**:
  Consolidation procedure `refresh_core_adjustments()` merges both sources into `public.core_adjustments`, preserving portal JSON approval metadata and hisaab line items.
- **Severity**: HIGH | **Capability**: CAN BE FIXED BY STANDARDIZATION (CODE)
