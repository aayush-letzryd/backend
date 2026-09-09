# Data Quality Audit: Daily Vehicle Status Tracker

## 1. Executive Summary

This audit catalogs data anomalies, formatting shifts, and manual entry artifacts observed across the LetzRyd daily fleet tracking system (`Vehicle Status List V3.xlsx` / `Daily Vehicle Status` tab and historical iterations). 

The `sheet_vehicle_status` ingestion pipeline acts as the raw staging layer (Layer 1) ingesting daily operational logs (over 31,000 rows spanning 1,041 active vehicles across 31 daily attendance ledgers). Because these sheets are populated daily by distributed fleet managers and operational Delivery Managers (DMs), the raw data exhibits substantial semantic variation, structural evolution, and schema drifting.

The automated Google Apps Script pipeline and PostgreSQL DDL (`schema.sql`) implement strict sanitization guards to resolve these anomalies before downstream consumption by operational status engines.

---

## 2. Issue Inventory & Categorization

### Issue 1: Operational Status Casing and Semantic Fragmentation

#### Observation
The `Final Status` field records the physical and contractual state of each vehicle on a given date. Across the dataset, status strings vary in casing, spacing, and semantic granularity:
- Standard Cased: `Active` (20,719 rows), `Maintenance` (4,952 rows), `RFD` (4,841 rows).
- Lowercase Variations: `active` (382 rows in legacy sheets).
- Operational Transitions: `Allocation` (445 rows), `Drop Off` (162 rows), `Same Day D&A` (69 rows), `New Deployment` (34 rows).
- Composite Status Strings with Embedded Dates: In legacy sheets, operations appended the action date to the status itself, such as `Allocation - 06-08-2024` (21 rows), `Maintenance - 06-08-2024` (19 rows), and `Dropoff - 06-08-2024` (18 rows).

#### Impact
Downstream aggregations group `Active` and `active` as separate operational categories, leading to underreported active fleet counts and incorrect billing triggers. Composite strings prevent simple categorical filtering.

#### Remediation Strategy
1. The Apps Script pipeline applies a deterministic case-insensitive dictionary normalization:
   - `active` -> `Active`
   - `drop off`, `dropoff` -> `Drop Off`
   - `same day d&a`, `same day da` -> `Same Day D&A`
   - Strips appended hyphenated dates when standardizing core status.
2. The database column is sized at `VARCHAR(50)` to accommodate operational compound statuses while maintaining index query performance.

---

### Issue 2: Partner ID Overloading on Unallocated Vehicles

#### Observation
In the source Google Sheet, the `partner IDs` column is dual-purposed:
- When a car is with an active driver or operator, it stores the partner identifier (e.g. `LETZBLR9633943403` or `LETZBLRIP9656907001`).
- When a car is unallocated (in workshop maintenance, idle in yard as Ready For Deployment, or awaiting onboarding handover), manual operators typed the status name or a dash directly into the partner ID cell:
  - Value `RFD`: 4,841 rows
  - Value `Maintenance`: 4,717 rows
  - Value `New Deployment`: 34 rows
  - Value `-`: 9,592 rows in partner name/type fields

#### Impact
Treating `Maintenance` or `RFD` as partner IDs causes foreign key joins against driver masters to fail or corrupt driver attribution reports, showing non-existent drivers named "Maintenance" or "RFD".

#### Remediation Strategy
1. The ingestion pipeline (`cleanPartnerId`) scans for non-partner tokens:
   - If `partner_id` in `['Maintenance', 'RFD', 'New Deployment', 'Allocation', 'Drop Off', '-', '--', 'NA']`, it is coerced to `NULL`.
2. This cleanly separates vehicle allocation state (`final_status`) from partner attribution (`partner_id`).

---

### Issue 3: Partner ID Syntax Variations and IP Operator Notation

#### Observation
Partner IDs do not follow a uniform regex across all cities and partner types:
- Standard Individual Partner: `LETZ` + `CITY` + `10-digit Phone` (e.g. `LETZBLR9633943403`, `LETZHYD9603099039`).
- Institutional Partner (IP) Operator: `LETZ` + `CITY` + `IP` + `10-digit Phone` (e.g. `LETZBLRIP9656907001`, `LETZMUMIP8169028670`). This is the dominant cohort in Mumbai and Bengaluru (over 14,800 rows).
- Spaced Notation: Operators occasionally entered spaces between tokens (e.g. `LETZ BLR 8861214022`, `LETZ BLR 8892182061`).
- Naked Phone Numbers: Driver mobile numbers entered without company prefix (e.g. `9705666795`, `9916578768`).

#### Impact
Join mismatches when linking `sheet_vehicle_status` with `sheet_vehicle_allocations` or web portal driver masters where strings are formatted without spaces.

#### Remediation Strategy
1. Whitespace is stripped across all partner IDs: `.toUpperCase().replace(/\s+/g, '')`.
2. Preserves the `IP` infix to distinguish institutional fleet operators from individual lease drivers.

---

### Issue 4: Date Serialization Shifts & Mapping Key Syntax

#### Observation
1. Date Representation:
   - Current sheet: Ingested as native Excel `datetime` timestamps (e.g. `2026-05-04 00:00:00`).
   - Legacy sheets: Stored as formatted date strings (`DD-MM-YYYY`, `YYYY-MM-DD`).
2. Mapping Key Construction:
   - The sheet generates a composite formula `Mapping = B2 & C2` (Vehicle Number concatenated with Date).
   - In Excel, concatenating a text string with a Date cell results in the plate plus the Excel numeric epoch serial date:
     - Example: `KA05AP6038` + `2026-05-04` = `KA05AP603846146` (where `46146` is the serial day count since January 0, 1900).
   - In older versions of the tracker, the key was constructed as `TS07UH0224_27-06-2024`.

#### Impact
Relying on `mapping_key` as a natural key creates breaking inconsistencies if the sheet calculation mode or date format changes.

#### Remediation Strategy
1. The database primary natural key is strictly defined as `(status_date, vehicle_number)`, independent of spreadsheet formula strings.
2. The `cleanDate` parser in Apps Script evaluates cell types dynamically:
   - Date instances are formatted using `Asia/Kolkata` time zone.
   - Numeric values between 20,000 and 80,000 are converted via the standard epoch offset formula: `new Date(Math.round((num - 25569) * 86400 * 1000))`.
   - String dates are matched against regex patterns for both `DD-MM-YYYY` and `YYYY-MM-DD`.

---

### Issue 5: Text Formatting and Whitespace Contamination

#### Observation
- Leading and Trailing Whitespace: Detected in over 1,360 rows in `partner Name` (e.g. `'MUHAMMED RAUOOF K P  '`, `'SHANKAR KUMAR N '`).
- Double Spaces and Tabs: Occasional multiple consecutive spaces inside driver names.
- Placeholder Symbols: Widespread use of `-`, `--`, `None`, and `NA` across `partner Name`, `DM Name`, and `Type` columns.

#### Impact
String lookups, equality checks (`WHERE partner_name = 'X'`), and group-by aggregations produce duplicate buckets for identical driver names with differing trailing spaces.

#### Remediation Strategy
1. Trimming and internal space collapsing applied to all text fields: `.replace(/\s+/g, ' ').trim()`.
2. Uniform placeholder filtering: common placeholders (`-`, `none`, `na`, `nil`) are converted directly to SQL `NULL`.

---

### Issue 6: Cohort and Contract Type Granularity

#### Observation
- Cohort values in the current tracker are divided into two high-level operational groupings:
  - `On Road`: 21,233 rows
  - `Off Road`: 9,989 rows
  - In legacy sheets, spelling variants appeared: `Onroad`, `Offroad`.
- Operational Contract Type:
  - `Operator`: 15,666 rows
  - `Individual`: 5,964 rows
  - `-` (Unallocated/Yard): 9,592 rows
- The `New Partner Name` column:
  - Only populated during driver turnover events (e.g. `Same Day D&A` or `Allocation`).
  - In 71 cases, this column contains a partner ID code (`LETZBLR8089141929`) rather than a driver name.

#### Impact
Downstream daily status aggregation engines require predictable cohort categories to distinguish available inventory from active revenue-generating vehicles.

#### Remediation Strategy
1. Standardize cohort casing to `On Road` and `Off Road`.
2. Retain `new_partner_name` as `VARCHAR(150)` to allow recording either handover driver names or replacement partner codes.

---

### Issue 7: Operating City Codes vs Full City Names

#### Observation
- Current production tracker uses 3-letter airport city codes:
  - `BLR` (19,752 rows)
  - `MUM` (6,603 rows)
  - `HYD` (4,867 rows)
- Historical sheets and onboarding forms use full names (`Bangalore`, `Bengaluru`, `Mumbai`, `Hyderabad`).

#### Impact
City filtering queries across tables require complex `CASE WHEN` or `ILIKE` statements if values are not normalized.

#### Remediation Strategy
1. The Apps Script pipeline maps all variations to canonical 3-letter codes (`BLR`, `MUM`, `HYD`) for consistency with current operational tracking standards.

---

## 3. Data Anomaly & Remediation Matrix

| Category | Observed Raw Value | Cleaned Target Value | Handling Layer |
| :--- | :--- | :--- | :--- |
| Status Casing | `active` | `Active` | Apps Script `cleanStatus()` |
| Status Spacing | `dropoff` / `Drop Off` | `Drop Off` | Apps Script `cleanStatus()` |
| Unallocated Partner | `Maintenance`, `RFD` | `NULL` | Apps Script `cleanPartnerId()` |
| Placeholder Characters | `-`, `--`, `NA`, `None` | `NULL` | Apps Script `cleanPlaceholder()` |
| Partner ID Spaces | `LETZ BLR 8861214022` | `LETZBLR8861214022` | Apps Script `cleanPartnerId()` |
| Excel Serial Date | `46146` | `2026-05-04` | Apps Script `cleanDate()` |
| Date Format | `04/05/2026`, `2026-05-04` | `2026-05-04` | Apps Script `cleanDate()` |
| Vehicle Number Typo | `MH-02 FG 2423` | `MH02FG2423` | Apps Script `cleanVehicleNumber()` |
| Vehicle OCR Typo | `TGO7X9865` | `TG07X9865` | Apps Script `cleanVehicleNumber()` |
| Trailing Whitespace | `'SHANKAR KUMAR N '` | `'SHANKAR KUMAR N'` | Apps Script `cleanPartnerName()` |
| City Names | `Bengaluru`, `Bangalore` | `BLR` | Apps Script `cleanCity()` |
| Natural Key Conflict | Multiple updates to same date & car | In-place update | PostgreSQL Zero-Burn CTE |

---

## 4. Conclusion

By enforcing these sanitization layers at the ingestion boundary, `public.sheet_vehicle_status` provides an auditable, high-fidelity daily attendance ledger that can be reliably consumed by downstream Layer 2 merge engines (`core_maintenance`, `core_daily_vehicle_status`) without downstream pipeline failures.
