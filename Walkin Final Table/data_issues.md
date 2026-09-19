# Walk-in Data Quality & Operational Issues Catalog

This catalog documents the data discrepancies and anomalies discovered across the three walk-in data sources:
1. `public.sheet_walkins` (Google Sheet submissions via Apps Script)
2. `public.july_new_walkins` (Web portal onboarding form submissions)
3. `public.july_existing_walkins` (Web portal returning partner visit logs)

---

## 1. Standardization & Data Governance Policy

Per operational guidelines:
- **Functional Columns Standardized**:
  - `city`: Standardized to canonical hub names (`Bengaluru`, `Hyderabad`, `Mumbai`) for cross-table joins, reporting, and city-level slicing.
  - `phone_number`: Cleaned to standard 10-digit mobile numbers for relational joins and communication pipelines.
  - `visiting_reason_category`: Standardized canonical categories (`ONBOARDING`, `ENQUIRY`, `PAYOUT_HISAAB`, `VEHICLE_MAINTENANCE`, `MEETING_COMPLAINT`, `OTHER`).
- **Verbatim Pass-Through (Untouched by Pipeline)**:
  - Input anomalies originating on the form side (such as an executive typing an email into a name field, or typing a placeholder Aadhaar) are **passed through verbatim** into `public.core_walkin`.
  - The pipeline does not alter or censor user input; data quality corrections belong on the form/ops side.
- **Zero Modifications to Source Tables**:
  - `sheet_walkins`, `july_new_walkins`, and `july_existing_walkins` remain 100% untouched.

---

## 2. Catalog of Discovered Issues

### ISS-01: Executive Email Typed into Candidate Last Name (Portal Form)
- **Source Table**: `public.july_new_walkins`
- **Affected Rows**: 9 candidates across multiple executives (Radha Krishna, Ankita, Sandeep), e.g. Phones `9866153295` (`Utpal Dhar radha.krishna@letzryd.com`), `9027310514` (`Bittu Chauhan radha.krishna@letzryd.com`), `9652539266` (`Goddanla Pochaiah radha.krishna@letzryd.com`), `7738192978` (`Lakhan ankita@letzryd.com`), `7093738811` (`kishore kumar sandeep@letzryd.com`).
- **Root Cause**: Field executives' browser autofill automatically populates their saved corporate email into the candidate's last name input field on the portal form.
- **Pipeline Handling**: Preserved verbatim as submitted.
- **Ops Recommendation**: Add `autoComplete="off"` on the Portal form and disallow `@` in candidate name fields.

---

### ISS-02: Placeholder Aadhaar Numbers (Portal Form)
- **Source Table**: `public.july_new_walkins`
- **Affected Rows**: 19 records contain empty strings `''` or repetitive sequences (`1111 1111 1111`, `1111 1111 1112`).
- **Root Cause**: The Aadhaar input field allowed repetitive dummy numbers.
- **Pipeline Handling**: Preserved verbatim as submitted.
- **Ops Recommendation**: Enforce 12-digit numeric validation and reject repeated sequences (`0000 0000 0000`, `1111 1111 1111`).

---

### ISS-03: City Spelling Variations (`Bangalore` vs `Bengaluru`)
- **Source Tables**: `public.july_new_walkins` (7 rows) and `public.july_existing_walkins` (2 rows) contain `Bangalore`, while `sheet_walkins` has `Bengaluru`.
- **Root Cause**: Different forms used different spelling options for the city of Bengaluru.
- **Pipeline Handling**: **Functionally Standardized**. The database triggers automatically convert `Bangalore`, `bangalore`, and `blr` to `Bengaluru` in `public.core_walkin`.
- **Ops Recommendation**: Restrict the Portal dropdown to canonical city names (`Bengaluru`, `Hyderabad`, `Mumbai`).

---

### ISS-04: Phone Number Formatting & Non-Digit Characters
- **Source Tables**: All source tables.
- **Root Cause**: Inputs may contain spaces, leading zeroes, or country codes (`+91`).
- **Pipeline Handling**: **Functionally Standardized**. Strips all non-digit characters and standardizes to the trailing 10-digit mobile number (`VARCHAR(20)`).
- **Ops Recommendation**: Enforce 10-digit regex pattern on input fields.

---

### ISS-05: Dual Submissions on the Same Day (Google Form + Portal Form)
- **Source Tables**: `sheet_walkins` and `july_new_walkins`
- **Affected Rows**: 7 candidates submitted on the same date (phones `9652539266`, `9549024324`, `9110513610`, `8305762724`, `9027310514`, `9866153295`, `9347929919`).
- **Root Cause**: Hub executives entered the candidate in both Google Forms and the Portal Form on the same afternoon.
- **Pipeline Handling**: Raw entries are preserved as separate events in `core_walkin` for 100% auditability. Downstream BI queries should use `public.vw_core_walkin_merged` to view deduplicated records without double counting.
- **Ops Recommendation**: Establish standard operating procedures (SOP) on whether hub executives should use Google Forms or Portal Forms.

---

### ISS-06: Visiting Reason Options Discrepancy
- **Source Tables**: Free-text tags in Google Sheet vs fixed dropdown in Portal.
- **Pipeline Handling**: The verbatim reason string is retained in `visiting_reason`, while a standardized reporting category is populated in `visiting_reason_category`.
- **Ops Recommendation**: Align dropdown choices between the Google Form and the Portal Form.

---

### ISS-07: Trigger Column Mismatch on `july_existing_walkins` (Resolved)
- **Source Table**: `public.july_existing_walkins`
- **Root Cause**: The live PostgreSQL trigger function `fn_sync_core_walkin_from_portal_existing` had an outdated definition referencing `NEW.operating_place` and `NEW.remarks`, causing runtime crashes on insert/update.
- **Resolution**: Re-deployed corrected function mapping `NEW.visit_notes` and setting `operating_place` to `NULL`. Confirmed live passing tests.

---

### ISS-08: `is_joined` Tri-State Inconsistency (`NULL` vs `FALSE`) (Resolved)
- **Source Table**: `public.sheet_walkins`
- **Root Cause**: When `joined_status` was NULL, `NULL ILIKE ...` returned `NULL`, inserting 86 rows with `is_joined = NULL` into `core_walkin`.
- **Resolution**: Wrapped trigger assignments in `COALESCE(..., FALSE)` and backfilled existing 86 rows to `FALSE`. Live `core_walkin` now has strictly 0 NULLs.

