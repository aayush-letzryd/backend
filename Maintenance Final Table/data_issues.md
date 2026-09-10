# Fleet Maintenance Single Source of Truth: Data Reconciliation & Issue Catalog (`public.core_maintenance`)

## 1. Executive Summary & Unification Scope

The unified table **`public.core_maintenance`** serves as the authoritative Single Source of Truth (SSOT) for fleet vehicle downtime and workshop repairs across all LetzRyd operations. It consolidates two distinct operational intake systems:

1. **Web Portal Maintenance Workflows**:
   - **`public.july_maintenance_in`**: Inward repair ticket, intake odometer (`vehicle_k_m_s`), repair diagnosis, estimated delivery, estimated amount, insurance claim filing, and damage photos.
   - **`public.july_maintenance_out`**: Outward release ticket, release odometer (`vehicle_out_k_m_s`), RFD date, job card invoice number, invoice amount, insurance liability deductions, payable amount, payment status, and release photos.
2. **Google Sheets Operations Staging**:
   - **`public.sheet_maintenance`**: Daily fleet status maintenance records (4,792 rows) synchronized in real-time from the master operations sheet (`Unified_Maintenance_source`).

---

## 2. Master Reconciliation Rules & Conflict Resolution

### 2.1 Portal Priority Deduplication Rule
- **Rule**: When a vehicle maintenance event is recorded on **both** the Web Portal and Google Sheets for the same vehicle and date window:
  - **The Web Portal data takes absolute precedence** as the primary record (`source_type = 'WEB_PORTAL'`).
  - Google Sheet metadata (driver allocation, DM name, vehicle model) is enriched onto the portal record.
  - Duplicate Google Sheet entries are skipped to prevent duplicate downtime intervals.

### 2.2 Temporal Pairing & Interval Closure
- **Rule**: Every `july_maintenance_in` row is joined with its corresponding `july_maintenance_out` row via `inward_id`.
- If an outward ticket exists: `start_date` = inward date, `end_date` = RFD date / outward date, `maintenance_status` = `'COMPLETED_RFD'`.
- If no outward ticket exists: `start_date` = inward date, `end_date` = `NULL`, `maintenance_status` = `'IN_PROGRESS'`.

### 2.3 Non-Negative Duration Clamping
- **Rule**: If an outward release date is recorded before the inward date (`end_date < start_date` due to manual typo):
  - The trigger clamps `end_date := start_date`, ensuring repair duration is never negative.

### 2.4 Soft Deletion Protection (Zero Data Destruction)
- **Rule**: When a record is deleted or changes status in an upstream table:
  - The trigger sets `is_deleted = TRUE` and records `deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.
  - Upstream deletion never causes hard row destruction in `public.core_maintenance`.

---

## 3. Data Quality Anomaly Matrix

| Issue ID | Source System | Column / Field | Issue Description & Root Cause | Standardization & Resolution Algorithm | Severity |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **CORE-M-01** | All Sources | `vehicle_number` | Plate spacing, special characters, and Greek homoglyphs | `UPPER(REGEXP_REPLACE(vehicle_number, '[^A-Za-z0-9]', '', 'g'))`. | `CRITICAL` |
| **CORE-M-02** | All Sources | `city` / `city_name` | City abbreviations (`BLR`, `HYD`, `MUM`, `DEL`) and case differences | Standardize via `fn_clean_maintenance_city` with state prefix fallback (`KA` -> `Bangalore`, `TS/TG` -> `Hyderabad`, `MH` -> `Mumbai`, `DL` -> `Delhi`). | `LOW` |
| **CORE-M-03** | Web Portal | `vehicle_in_date_time` | ISO timestamp text (`2026-09-07T13:53`) | Parse ISO string to `TIMESTAMP WITHOUT TIME ZONE` and extract `start_date` as `DATE`. | `HIGH` |
| **CORE-M-04** | Web Portal | `vehicle_out_date_time` | Outward ISO timestamp text | Parse to `TIMESTAMP WITHOUT TIME ZONE` and extract `end_date` as `DATE`. | `HIGH` |
| **CORE-M-05** | Web Portal | `estimated_amount`, `invoice_amount` | Currency strings with commas or symbols | Strip non-numeric characters via `fn_parse_maintenance_numeric` and round to `NUMERIC(12,2)`. | `MEDIUM` |
| **CORE-M-06** | Web Portal | `vehicle_k_m_s`, `vehicle_out_k_m_s` | Odometer text with non-numeric noise | Strip non-digits via `fn_parse_maintenance_int` and cast to `INTEGER`. | `LOW` |
| **CORE-M-07** | Web Portal | `insurance_claimed` | Text indicators (`Yes`, `No`, `true`) | Convert to native SQL `BOOLEAN` (`TRUE` / `FALSE`). | `LOW` |
| **CORE-M-08** | Google Sheet | `partner_ids` | Literal `"Maintenance"` in driver ID column | Map `"Maintenance"`, `"RFD"`, `"-"` to SQL `NULL`. | `HIGH` |
| **CORE-M-09** | Google Sheet | `partner_name`, `dm_name` | Hyphen `"-"` placeholders | Convert `"-"` and empty strings to SQL `NULL`. | `LOW` |
| **CORE-M-10** | Dual Sources | Overlapping Events | Same vehicle entering workshop simultaneously in Portal & Sheet | Apply Portal Priority rule: Portal record creates core row; Sheet record enriches metadata. | `CRITICAL` |
