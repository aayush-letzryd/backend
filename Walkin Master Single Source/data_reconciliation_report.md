# Walk-in Data Quality & Standardization Audit Report

This report documents the schema variances, data quality anomalies, and operational discrepancies discovered across the three walk-in data sources:
1. `public.sheet_walkins` (Google Sheet form entries synced via Google Apps Script)
2. `public.july_new_walkins` (Web portal onboarding form entries)
3. `public.july_existing_walkins` (Web portal returning partner visit logs)

---

## 1. Discovered Data Quality & Standardization Issues

### Issue 1: Executive Email Pasted into Candidate Name Field (Portal Form)
- **Root Cause**: In the web portal onboarding form, hub executives (specifically Radha Krishna on August 31) entered their own company email (`radha.krishna@letzryd.com`) into the candidate's last name input field.
- **Affected Rows in `july_new_walkins`**:
  - Phone `9866153295`: Candidate name saved as `Utpal Dhar radha.krishna@letzryd.com`.
  - Phone `9027310514`: Candidate name saved as `Bittu Chauhan radha.krishna@letzryd.com`.
- **Automated Fix in `core_walkin`**:
  - The ingestion engine and PostgreSQL database trigger use regular expressions to automatically detect and strip email address patterns (`\S+@\S+`) from all name tokens before writing to `core_walkin`.
  - Stored cleanly as `Utpal Dhar` and `Bittu Chauhan`.
- **Recommended Fix at Source**:
  - Add client-side and backend validation on the Portal form to reject names containing `@` or matching email patterns.
  - Review browser autofill settings on hub executive laptops, as browsers often auto-suggest the logged-in user's email into text fields.

---

### Issue 2: Dummy Aadhaar Number Entry (Portal Form)
- **Root Cause**: The Aadhaar number field in `july_new_walkins` allowed placeholder inputs.
- **Affected Rows**:
  - Phone `9027310514` (Bittu Chauhan): Aadhaar saved as `1111 1111 1111`.
- **Automated Fix in `core_walkin`**:
  - Values consisting of repeated digits (`1111 1111 1111`, `0000 0000 0000`) are treated as unverified placeholders.
- **Recommended Fix at Source**:
  - Enforce standard 12-digit Indian Aadhaar format with Verhoeff checksum algorithm or reject repeated/consecutive sequences.

---

### Issue 3: City Spelling Inconsistency (`Bangalore` vs `Bengaluru`)
- **Root Cause**: Executives had access to different spelling variants across forms.
- **Observed Distribution**:
  - `sheet_walkins`: `Bengaluru` (214), `Hyderabad` (671), `Mumbai` (1).
  - `july_new_walkins`: `Bangalore` (7), `Bengaluru` (62), `Hyderabad` (8), `Mumbai` (5).
  - `july_existing_walkins`: `Bangalore` (2), `Hyderabad` (1), `Mumbai` (5).
- **Automated Fix in `core_walkin`**:
  - The trigger and backfill script automatically standardize all variants (`Bangalore`, `bangalore`, `blr`) to `Bengaluru`.
- **Recommended Fix at Source**:
  - In the Portal dropdown and Google Form dropdown, restrict options to standard names: `Bengaluru`, `Hyderabad`, `Mumbai`.

---

### Issue 4: Dual Submission on the Same Day (Google Form + Portal Form)
- **Root Cause**: On August 21 and August 31, field executives logged the same candidate into both Google Forms and the Portal Form within minutes of each other.
- **Observed Cases**:
  1. Phone `9347929919` (2026-08-21): Logged in Sheet at 16:21 IST, logged in Portal at 16:01 IST.
  2. Phone `9866153295` (2026-08-31): Logged in Sheet at 12:50 IST, logged in Portal at 13:52 IST.
  3. Phone `9027310514` (2026-08-31): Logged in Sheet at 13:52 IST, logged in Portal at 13:49 IST.
- **Handling in `core_walkin`**:
  - Per the operational model where walk-ins represent an append-only event stream, both entries are preserved with their respective source indicators (`GOOGLE_SHEET` and `PORTAL_NEW`). No data is discarded.
- **Recommended Fix at Source**:
  - Clarify standard operating procedure (SOP) with hub managers regarding whether candidates should be entered into Google Forms or the Web Portal, avoiding duplicate data entry.

---

### Issue 5: Visiting Reason Taxonomies
- **Root Cause**: Different forms used completely different dropdown options.
  - Google Form options: `Enquiry [ About Plans ]`, `New Joining`, `Hisaab Related`, `Re-joining`, `Drop off`, `Car Swap Or Vehicle Maintenance`.
  - Portal New options: `Onboarding`, `Onboarding Inquiry`, `Driver Manager (DM) Meet`.
  - Portal Existing options: `Adding New Vehicle to Fleet`, `Tyre Issue`, `Hisaab & Payout`, `DM Meet`, `Payout & Earnings`.
- **Automated Fix in `core_walkin`**:
  - Verbatim text is stored in `visiting_reason`.
  - A standardized category is computed in `visiting_reason_category`:
    - `ONBOARDING`: `New Joining`, `Onboarding`, `Re-joining`, `Adding New Vehicle to Fleet`
    - `ENQUIRY`: `Enquiry [ About Plans ]`, `Onboarding Inquiry`
    - `PAYOUT_HISAAB`: `Hisaab Related`, `Hisaab & Payout`, `Payout & Earnings`
    - `VEHICLE_MAINTENANCE`: `Car Swap Or Vehicle Maintenance`, `Tyre Issue`, `Drop off`
    - `MEETING_COMPLAINT`: `Driver Manager (DM) Meet`, `DM Meet`
    - `OTHER`: Any other category
- **Recommended Fix at Source**:
  - Unify the dropdown options across Google Forms and the Portal Form so that reporting categories match from day one.

---

### Issue 6: Hub / Operating Location Field
- **Root Cause**:
  - Google Sheet lacked a dedicated "Hub / Branch" column. Executives occasionally typed locations (e.g. "From JNTU", "Kondapur") in remarks.
  - Portal Form has `operating_place`, but it was optional, leaving many records blank.
- **Recommended Fix at Source**:
  - Make "Operating Hub" a required dropdown in both Google Form and Portal Form (e.g., Kondapur, JNTU, HSR Layout, Bellandur, Marathahalli).
