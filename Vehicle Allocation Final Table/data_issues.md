# Vehicle Allocation Data Issues & Conflict Analysis

This document details the critical data issues, column mismatches, and merge conflicts discovered between `public.sheet_vehicle_allocations` (7,132 rows) and `public.july_allocation_form` (303 rows) in PostgreSQL, along with the resolution logic required for `public.core_vehicle_allocation`.

---

## 1. High Overlap & Dual-Entry Conflict (163 Overlapping Allocations)

### The Issue:
* **163 vehicle allocations exist in BOTH the Google Sheet and the Portal** for the exact same vehicle on the exact same `allocation_date`.
* **233 allocations overlap** on `(driver_phone, allocation_date)`.
* Operations teams in August and September 2026 have been submitting allocations on the Web Portal while also entering them into the Google Sheet.

### Consequence:
If records are inserted without conflict deduplication, the core table will contain 163+ duplicate vehicle allocations, distorting vehicle tenure, active driver counts, and Hisaab rent calculations.

### Resolution Logic:
* Define a composite conflict resolution key: `(allocation_date, vehicle_number)`.
* When an allocation exists in both sources:
  1. Set `source_origin = 'MERGED'`.
  2. Merge the rich portal data (inspection checklist, photos, FASTag balance, security cheques) with the verified Google Sheet metadata (submitter email, attendance executive).
  3. Avoid inserting a duplicate row.

---

## 2. Vocabulary & Taxonomy Inconsistencies

### City Standardization:
* **Sheet values:** `Bengaluru`, `Hyderabad`, `Mumbai`
* **Portal values:** `Bangalore`, `Bengaluru`, `Hyderabad`, `Mumbai`, `Pune`
* **Fix:** Standardize `Bangalore` -> `Bengaluru`.

### Allocation Type Standardization:
* **Sheet values:**
  * `New Allocation`
  * `Reallocation`
  * `Car Swap`
* **Portal values:**
  * `Fresh Allocation`
  * `New Allocation`
  * `Allocation`
  * `Reallocation`
  * `Swap`
  * `Drop-Off` (Portal allocation form includes vehicle returns during swaps)
* **Fix:** Canonical mapping:
  * `'Fresh Allocation'`, `'Allocation'` -> `'New Allocation'`
  * `'Swap'` -> `'Car Swap'`
  * `'Reallocation'` -> `'Reallocation'`
  * `'Drop-Off'` -> Route swap return data to `core_vehicle_dropoff` and mark allocation as `'Car Swap'`.

---

## 3. Plan Contradictions (Driver Plan vs. Type of Plan)

### The Issue:
In `sheet_vehicle_allocations`, there are severe internal contradictions between the `driver_plan` and `type_of_plan` columns:
* 84 rows have `driver_plan = 'LIP'` but `type_of_plan = 'Fixed'`.
* 153 rows have `driver_plan = 'LIP'` but `type_of_plan = 'Uber - TBS'`.
* 80 rows have `driver_plan = 'LIP'` but `type_of_plan = 'Uber - EBS'`.
* 13 rows have `driver_plan = 'D2R'` but `type_of_plan = 'D2O - Fixed'` or `'D2O - Only Uber'`.

### Resolution Logic:
* Add a standardized column `canonical_plan` in `core_vehicle_allocation`.
* Preserve the raw values in `driver_plan_raw` and `type_of_plan_raw` for auditability, but infer the normalized billing plan for Hisaab.

---

## 4. Operator ID vs. Phone Number Mismatches

### The Issue:
The company's standard Operator/Driver ID format embeds the driver's phone number (e.g. `LETZBLR9876543210` or `LETZBLRIP9876543210`).
* In 42 historical rows, the trailing 10 digits of `operator_driver_id` do not match the cleaned 10 digits in `driver_phone`.
* In row 2787, the `driver_name` field literally contains `LETZMUMIP9004200105` instead of a person's name.

### Resolution Logic:
* Sanitize and strip non-digits to produce a clean 10-digit `canonical_phone`.
* If `driver_name` contains an ID format (`LETZ...`), query `core_partner_onboarding` by phone to resolve the driver's actual registered name.

---

## 5. Column Asymmetry (39 Sheet Columns vs. 76 Portal Columns)

### The Issue:
* The Google Sheet contains 39 columns focusing on basic handover, odometer, and vehicle accessories (jack, spanner, stepney).
* The Web Portal contains 76 columns, introducing:
  * Dedicated vehicle inspection checklists (`insp_jack`, `insp_spanner`, `insp_fire_extinguishers`, `insp_seat_cover`, `insp_music_system`).
  * 4-sided inspection photos (`photo_lh_side`, `photo_rh_side`, `photo_front_side`, `photo_back_side`).
  * Financial security: 4 security cheque numbers (`security_cheque_1..4`), FASTag balance, damage penalties, deposit refund status.
  * Approval workflow: `approval_status`, `approved_by`, `current_approver_id`, `approval_remarks`.

### Resolution Logic:
* The unified table `core_vehicle_allocation` must incorporate all columns from both sources with zero data loss.
* Columns present only in the portal remain `NULL` for sheet-only records without breaking downstream queries.

---

## 6. Internal Duplicates Within Sources

### The Issue:
* `sheet_vehicle_allocations` has 2 duplicate pairs for the same `(vehicle_number, allocation_date)`.
* `july_allocation_form` has 11 duplicate pairs for the same `(vehicle_number, allocation_date)`.

### Resolution Logic:
* Add `submission_timestamp` / `created_at` ordering so that when multiple entries exist for the same vehicle on the same day, the latest verified submission takes precedence.

---

## 7. Portal Drop-Off Leakage Isolation (Multi-Variant Exclusion)

### The Issue:
* The web portal table `public.july_allocation_form` contains 119 records where `allocation_type` is logged as a vehicle return/drop-off.
* In initial sync configurations, 85 of these records leaked into `public.core_vehicle_allocation`.
* Drop-offs belong strictly to the vehicle drop-off domain (`public.core_dropoffs`) and must not contaminate active allocations.

### Resolution Logic:
* Implement multi-variant drop-off filtering in trigger `sync_core_allocation_from_portal()` and backfill procedure `sp_backfill_core_vehicle_allocation()`:
  ```sql
  REGEXP_REPLACE(LOWER(TRIM(COALESCE(allocation_type, ''))), '[\s\-_]', '', 'g') = 'dropoff'
  ```
* This catches all user entry variations: `Drop-Off`, `drop off`, `Drop Off`, `dropoff`, `Dropoff`, `drop_off`.
* Any matching record is blocked at the gate and never enters `core_vehicle_allocation`. If an existing allocation is modified to a drop-off, it is automatically removed from core.
* Removing these 85 leaked drop-offs reconciled `core_vehicle_allocation` from 7,335 down to exactly **7,251 clean, continuous allocations** with zero sequence gaps.

