# LetzRyd Maintenance Pipeline - Data Quality Audit & Issues Specification

This document details the data quality anomalies identified in vehicle maintenance and downtime records within the LetzRyd fleet management tracking sheets. It documents the root cause, business and billing impact, and automated standardization rules implemented in `schema.sql` and `maintenance_pipeline_appscript.js`.

---

## Executive Summary of Anomalies

| Issue ID | Affected Field | Raw Anomaly Pattern | Severity | Resolution Layer |
| :--- | :--- | :--- | :--- | :--- |
| `MAINT-01` | `workshop_name` | Placeholder strings (`'-'`, `'NA'`, `'Local Workshop'`, `'TBD'`) | High | Apps Script & SQL NULLIF regex |
| `MAINT-02` | `job_card_number` | Missing, blank, or placeholder job card strings | Critical | Strict placeholder filtering & audit logging |
| `MAINT-03` | `vehicle_number`, `maintenance_date` | Multiple records on same vehicle on same calendar date | High | Composite Unique Key & Upsert resolution |
| `MAINT-04` | `partner_id` | Driver assignment retention for IP operators vs Individual | Critical | Conditional IP prefix retention logic |
| `MAINT-05` | `final_status`, `cohort` | Taxonomy drift (`'Maintenance'`, `'Workshop'`, `'Accidental'`, `'BD'`) | High | Ingestion condition mapping & status normalization |
| `MAINT-06` | `maintenance_date` | Excel epoch serial day floats (`45658.0`) and mixed formats | High | Multi-format date parsing engine |
| `MAINT-07` | `vehicle_number` | Plate casing, spacing, and hyphen variations | Medium | Canonical alphanumeric regex sanitization |
| `MAINT-08` | `city` | Inconsistent city abbreviations (`BLR`, `HYD`, `MUM`) and blanks | Medium | Canonical city dictionary with state plate fallback |
| `MAINT-09` | `dm_name` | Duty Manager name variations and missing POC values | Low | Title trimming and whitespace collapse |
| `MAINT-10` | `maintenance_reason` | Vague descriptions (`'check'`, `'problem'`) and multi-line remarks | Medium | Text sanitization and whitespace normalization |

---

## Detailed Issue Specifications

### MAINT-01: Placeholder Strings in Workshop Names

- **Affected Column**: `workshop_name` (Target: `public.sheet_maintenance.workshop_name`)
- **Raw Anomaly**:
  Workshop names in manual tracker entries frequently contain placeholder strings rather than authorized garage entities:
  - Hyphens and punctuation: `'-'`, `'--'`, `'.'`
  - Generic abbreviations: `'NA'`, `'N/A'`, `'NONE'`, `'NULL'`, `'NIL'`
  - Vague location labels: `'Local Workshop'`, `'Local'`, `'Outside'`, `'Near Hub'`, `'Yard'`, `'TBD'`
- **Root Cause**:
  Field operators log a vehicle as Off Road due to breakdown before the vehicle has been physically towed or assigned to an empanelled garage partner (e.g. Carnation, Castrol, Bosch, or Maruti Authorized Service Center). Operators enter temporary strings to bypass spreadsheet validations.
- **Impact on Operations & Accounting**:
  - Distorts vendor performance scorecards and turnaround time (TAT) tracking.
  - Prevents automated matching against monthly workshop invoices in `public.maintenance_invoices`.
  - Obstructs warranty and insurance claim attribution.
- **Standardization & Code Resolution**:
  Both the Google Apps Script (`cleanWorkshopName`) and PostgreSQL ingestion trigger sanitize the input against a comprehensive exclusion list:
  ```sql
  CASE 
      WHEN UPPER(TRIM(COALESCE(workshop_name, ''))) IN (
          '', '-', '--', '---', 'NA', 'N/A', 'NONE', 'NULL', 'NIL', 
          'LOCAL', 'LOCAL WORKSHOP', 'TBD', '.', '..', 'UNKNOWN', 'NO'
      ) THEN NULL 
      ELSE TRIM(workshop_name) 
  END
  ```
  Legitimate authorized workshops (e.g. `'Maruti True Value - Whitefield'`, `'Bosch Car Service - Begumpet'`) are preserved verbatim.

---

### MAINT-02: Missing, Blank, or Placeholder Job Card Numbers

- **Affected Column**: `job_card_number` (Target: `public.sheet_maintenance.job_card_number`)
- **Raw Anomaly**:
  Approximately 35% to 45% of daily maintenance entries have empty or pseudo-job cards such as `'-'`, `'Pending'`, `'Awaiting'`, `'Not Generated'`, or `'NA'`. In some cases, operators type repair estimate numbers or invoice reference IDs into the job card column.
- **Root Cause**:
  Job cards are issued by external workshops only after physical intake inspection. If a vehicle breaks down on day 1 and sits in queue, the job card is not generated until day 2 or day 3. However, operations logs the downtime immediately on day 1.
- **Impact on Operations & Accounting**:
  - Job card number is the legal audit link required to reconcile parts replaced under warranty.
  - Lack of a job card allows unauthorized or fraudulent repair claims.
- **Standardization & Code Resolution**:
  - Map all placeholder strings to SQL `NULL` during ingestion:
    ```sql
    CASE 
        WHEN UPPER(TRIM(COALESCE(job_card_number, ''))) IN (
            '', '-', '--', 'NA', 'N/A', 'NONE', 'NULL', 'PENDING', 
            'TBD', '.', 'NO', 'NIL', 'NOT GENERATED', 'AWAITING'
        ) THEN NULL 
        ELSE TRIM(job_card_number) 
    END
    ```
  - Upstream updates in `sheet_vehicle_status` that subsequently populate the job card automatically update `sheet_maintenance` via `trg_extract_maintenance_from_sheet_status` using `COALESCE(EXCLUDED.job_card_number, target.job_card_number)`.

---

### MAINT-03: Multiple Maintenance Records on Same Vehicle on Same Date

- **Affected Columns**: `vehicle_number`, `maintenance_date`
- **Raw Anomaly**:
  A single vehicle appears multiple times on the same date in raw status sheets:
  - Morning entry indicates `'Breakdown'` while evening entry indicates `'Workshop'`.
  - Two different hub coordinators submit duplicate status sheets for the same city.
  - A vehicle is transferred from an internal hub yard to an external workshop within the same 24-hour cycle.
- **Root Cause**:
  Decentralized multi-hub operations logging status updates at different shifts without a shared database transaction coordinator.
- **Impact on Operations & Accounting**:
  - Duplicate rows inflate off-road fleet downtime statistics.
  - Causes primary key collision errors in relational databases.
  - Risk of duplicate daily rental waivers in Hisaab driver settlement calculations.
- **Standardization & Code Resolution**:
  - Natural key constraint defined on `(maintenance_date, vehicle_number)`.
  - Idempotent upsert semantics (`ON CONFLICT (maintenance_date, vehicle_number) DO UPDATE SET ...`) ensures exactly one consolidated downtime record exists per vehicle per date.
  - Non-null operational attributes (job card, workshop name, detailed remarks) from later updates overlay and enrich earlier placeholder submissions.

---

### MAINT-04: Driver Retention Disparity (IP Operators vs Individual Drivers)

- **Affected Columns**: `partner_id`, `cohort`
- **Raw Anomaly**:
  When a vehicle enters maintenance:
  - For **Individual Drivers**, the driver is de-allocated from the vehicle, `partner_id` should become `NULL`, and daily rental billing is paused/waived.
  - For **IP (Institutional / Investor Partner) Operators**, the fleet operator retains administrative ownership of the vehicle during the entire workshop duration. The raw sheet frequently retains the operator code (e.g. `LETZBLRIP004`), but sometimes an operator clears the column or replaces it with `'Self'`.
- **Root Cause**:
  Different contractual structures:
  - Individual drivers rent 1:1 and cannot be billed rent when the asset is physically unavailable.
  - IP operators manage multi-vehicle portfolios under commercial fleet contracts with specific SLA-based maintenance replacement policies.
- **Impact on Operations & Accounting**:
  - If an individual driver's ID is erroneously retained during maintenance, automated Hisaab settlement engines bill the driver for downtime days, leading to disputes and chargebacks.
  - If an IP operator ID is cleared, the vehicle becomes an unassigned orphan, making it impossible to attribute vehicle handover liability or track operator downtime SLAs.
- **Standardization & Code Resolution**:
  - The extraction trigger and Apps Script preserve `partner_id` if it conforms to an authorized partner ID format (`LETZ...`), particularly IP operator prefixes (`LETZ%IP%`).
  - For non-IP individual drivers, downstream status pairing disassociates the active allocation during maintenance intervals while recording downtime rent waiver codes (`rent_waived_reason = 'WORKSHOP_MAINTENANCE'`).

---

### MAINT-05: Status and Cohort Taxonomy Drift

- **Affected Columns**: `final_status`, `cohort`
- **Raw Anomaly**:
  Different coordinators and historical sheet templates use divergent terminology for maintenance states:
  - Final status variants: `'Maintenance'`, `'Workshop'`, `'Accidental'`, `'BD'`, `'Breakdown'`, `'Under Repair'`, `'Service'`, `'PDI Hold'`
  - Cohort variants: `'Off Road'`, `'Off-Road'`, `'Offroad'`, `'Maintenance'`, `'In Yard'`
- **Root Cause**:
  Lack of strict data validation dropdowns in legacy Google Sheets across regional offices.
- **Impact on Operations & Accounting**:
  - Ingestion queries filtering strictly on `final_status = 'Maintenance'` miss 30% or more of actual off-road downtime events (especially `'BD'` and `'Accidental'`).
  - Flawed fleet utilization metrics presented to management.
- **Standardization & Code Resolution**:
  - Unified extraction criteria in SQL and JavaScript:
    ```sql
    WHERE UPPER(TRIM(COALESCE(final_status, ''))) IN ('MAINTENANCE', 'WORKSHOP', 'ACCIDENTAL', 'BD')
       OR UPPER(TRIM(COALESCE(cohort, ''))) = 'OFF ROAD'
    ```
  - Target table normalizes cohort strictly to canonical `'Off Road'`.

---

### MAINT-06: Excel Epoch Serial Dates & Format Fragmentation

- **Affected Column**: `status_date` / `maintenance_date`
- **Raw Anomaly**:
  Dates appear as:
  - 5-digit Excel epoch floats: `45658`, `45707.42965`
  - Indian slash format: `05/09/2026`
  - Hyphenated format: `05-09-2026`
  - ISO format: `2026-09-05`
  - Leading/trailing whitespace: `' 2026-09-05 '`
- **Root Cause**:
  Data migrated across Excel workbooks (`.xlsx`) and Google Sheets without uniform cell formatting. Copy-pasting raw values converts native dates to serial integers representing days since December 30, 1899.
- **Impact on Operations & Accounting**:
  - Direct SQL casting (`::DATE`) fails on raw serial integers, halting ingestion pipelines.
  - Date misinterpretation (e.g. `05/09/2026` read as May 9 instead of September 5) corrupts chronological maintenance intervals.
- **Standardization & Code Resolution**:
  - Apps Script `parseDate(val)` detects numeric serial ranges (`30000 < serial < 60000`), converts epoch milliseconds to canonical Indian Standard Time (`Asia/Kolkata`), and outputs formatted `YYYY-MM-DD` strings.
  - String date parsing handles both day-first (`DD/MM/YYYY`) and ISO formats.

---

### MAINT-07: Vehicle Registration Plate Formatting

- **Affected Column**: `vehicle_number`
- **Raw Anomaly**:
  Plates entered with inconsistent casing, whitespace, hyphens, and missing characters:
  - Lowercase: `ka01ab1234`
  - Hyphenated: `KA-01-AB-1234`
  - Spaced: `KA 01 AB 1234`
  - Trailing punctuation: `KA01AB1234.`
- **Root Cause**:
  Manual keyboard typing by field staff on mobile devices and laptops without input masking.
- **Impact on Operations & Accounting**:
  - Prevents joins against `public.core_vehicle_onboarding` and `public.core_vehicle_allocation`.
  - Generates duplicate records for the same physical vehicle under different string keys.
- **Standardization & Code Resolution**:
  Standardized regex stripping applied across SQL and Apps Script:
  ```sql
  UPPER(REGEXP_REPLACE(vehicle_number, '[^a-zA-Z0-9]', '', 'g'))
  ```
  Enforces minimum length of 6 characters and maximum of 15 characters.

---

### MAINT-08: City Abbreviation and Hub Mapping Fragmentation

- **Affected Column**: `city`
- **Raw Anomaly**:
  City names entered as 3-letter codes (`BLR`, `HYD`, `MUM`, `DEL`), full historical names (`Bangalore`, `Bombay`), or left completely blank.
- **Root Cause**:
  Absence of mandatory city dropdown in legacy attendance templates.
- **Impact on Operations & Accounting**:
  - Segmented city reporting breaks down.
  - Regional maintenance budgets and local vendor allocations cannot be aggregated.
- **Standardization & Code Resolution**:
  - Dictionary mapping normalizes all known city variants to canonical title case names (`Bengaluru`, `Hyderabad`, `Mumbai`, `Delhi`, `Pune`, `Chennai`).
  - If city is blank or placeholder, fallback logic infers city deterministically from the state registration code:
    * `KA%` -> `Bengaluru`
    * `TS%` / `TG%` -> `Hyderabad`
    * `MH%` -> `Mumbai`
    * `DL%` -> `Delhi`
    * `TN%` -> `Chennai`

---

### MAINT-09: Duty Manager / POC Name Inconsistencies

- **Affected Column**: `dm_name`
- **Raw Anomaly**:
  Names entered with informal nicknames, job titles appended (e.g. `'Suresh - Yard Incharge'`), casing discrepancies, or generic placeholders (`'DM'`, `'Staff'`).
- **Root Cause**:
  Free-text input field without employee ID validation.
- **Impact on Operations & Accounting**:
  - Complicates operational audit trails when investigating why an unroadworthy car was released.
- **Standardization & Code Resolution**:
  - Strips job title suffixes and collapses multiple spaces.
  - Maps placeholder values (`'-'`, `'NA'`, `'NONE'`, `'NULL'`) to SQL `NULL`.

---

### MAINT-10: Vague and Unstructured Maintenance Reasons

- **Affected Column**: `maintenance_reason`
- **Raw Anomaly**:
  Free-text descriptions with unhelpful one-word notes (`'check'`, `'problem'`, `'issue'`, `'work'`, `'running'`), multi-line copy-pasted diagnostic logs, or special characters.
- **Root Cause**:
  No standardized maintenance taxonomy or fault category picker (e.g. Electrical, Suspension, Brakes, Transmission, Bodywork, Periodic Service).
- **Impact on Operations & Accounting**:
  - Impedes automated categorization of recurring vehicle defects by model or manufacturer.
  - Hinders identification of chronic mechanical issues for warranty recovery.
- **Standardization & Code Resolution**:
  - Strips carriage returns and line feeds into unified single-line strings.
  - Collapses redundant whitespace.
  - Nullifies non-informative placeholder strings.
