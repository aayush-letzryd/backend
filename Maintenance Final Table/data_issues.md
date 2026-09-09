# Fleet Maintenance Data Reconciliation & Issue Catalog

## 1. Executive Summary

The unified table `public.core_maintenance` serves as the authoritative Single Source of Truth for fleet vehicle downtime and workshop repairs across LetzRyd operations. Prior to consolidation, maintenance tracking was fragmented across two disparate operational channels:

1. **Web Portal Maintenance Workflows**: Driven by two relational tables—`public.july_maintenance_in` (inward entry, estimated delivery, and repair diagnosis) and `public.july_maintenance_out` (outward release, RFD date, job card invoice number, and payment reconciliation).
2. **Google Sheets Operations Logs**: Historical downtime tracking recorded in `sheet_vehicle_status` and `sheet_maintenance`, managed manually by city fleet coordinators with varying date formats, unvalidated text notes, and retrospective edits.

This document details the primary structural anomalies, reconciliation conflicts, and temporal discrepancies identified between these systems, along with the algorithmic resolutions enforced in `public.core_maintenance`.

---

## 2. Issue 1: Open Maintenance Intervals (Missing Exit / RFD Dates)

### Description
A significant proportion of vehicles logged into workshops via `july_maintenance_in` or `sheet_maintenance` lack a corresponding outward record in `july_maintenance_out` or have a NULL `end_date`. In standard workflow, a vehicle entering the workshop receives an inward entry; upon completion of mechanical repair, an outward entry is filed with the final Ready-for-Deployment (RFD) date.

### Root Causes
- **Operational Leakage**: Vehicles are repaired and immediately handed back to a driver or deployed to a hub without the workshop manager submitting the digital exit form.
- **Form Disconnection**: Inward and outward tickets were historically entered as independent forms without a strictly enforced foreign key link (`inward_id` remaining NULL).
- **Work In Progress (WIP)**: Genuine long-duration repairs (engine overhauls, major accidental insurance claims) remaining physically in the workshop across weeks.

### Operational & Financial Impact
- **Fleet Availability Distortions**: Vehicles appear stuck in workshop status indefinitely, lowering apparent fleet utilization metrics.
- **Hisaab Rent Waiver Errors**: The automated hisaab billing engine references maintenance intervals to waive daily vehicle rent. An unclosed maintenance interval causes false rent waivers, creating substantial revenue leakage.

### Resolution Logic & Thresholds
1. **Aging Classification Matrix**:
   - **Active WIP (0 to 7 Days)**: Considered normal maintenance turnaround. Marked as `status = 'IN_PROGRESS'` with `end_date = NULL`.
   - **Extended WIP (8 to 14 Days)**: Flagged for mandatory city fleet manager verification.
   - **Critical Overdue (> 14 Days)**: Triggers operational alert. If the vehicle has an active allocation record in `public.core_vehicle_allocation` dated after the maintenance start date, the maintenance interval is retroactively closed as of the allocation date.
2. **Subsequent Allocation Imputation**:
   - If vehicle `V` has an open maintenance interval starting on `T_start`, and subsequently receives a vehicle allocation on `T_alloc` (`T_alloc > T_start`), `end_date` is imputed as `T_alloc - 1 day` with status updated to `'COMPLETED'`.

---

## 3. Issue 2: Negative and Inverted Durations (end_date < start_date)

### Description
Instances where the recorded outward release date or RFD date precedes the recorded inward maintenance date.

```
Example Discrepancy:
vehicle_number : TS09UA1234
start_date     : 2026-09-08
end_date       : 2026-09-02 (Negative duration: -6 days)
```

### Root Causes
- **Format Inversion (DD/MM vs MM/DD)**: Operators in Google Sheets or web input boxes entering `02/09/2026` intending September 2, parsed as February 9.
- **Retrospective Logging**: A workshop manager logging vehicle exit on the actual release day, but entering the past entry date inaccurately from memory.
- **Timezone Timestamp Skew**: Timestamp strings formatted with inconsistent offsets causing boundary inversion around midnight transitions.

### Operational & Financial Impact
- Causes integer underflow or negative downtime days in fleet utilization dashboards.
- Breaks interval queries calculating Mean Time to Repair (MTTR) and Turnaround Time (TAT).

### Resolution Logic
1. **Trigger Clamping Rule**: Both `sync_core_maintenance_from_portal()` and `sync_core_maintenance_from_sheet()` enforce non-negative duration:
   ```sql
   IF v_end_date IS NOT NULL AND v_end_date < v_start_date THEN
       v_end_date := v_start_date;
   END IF;
   ```
2. **Deterministic Procedure Rectification**: `public.refresh_core_maintenance()` and the Python automation repair routine automatically execute:
   ```sql
   UPDATE public.core_maintenance
   SET end_date = start_date,
       updated_at = CURRENT_TIMESTAMP
   WHERE end_date IS NOT NULL AND end_date < start_date;
   ```

---

## 4. Issue 3: Multi-Day Gaps and Overlapping Interval Resolution

### Description
Vehicles appearing with overlapping maintenance records across different sources, or multiple fragmented entries for what was physically a single repair event.

```
Overlapping Record Scenario:
Record A (Sheet)  : 2026-08-10 to 2026-08-16 (Workshop: Bosch Car Care)
Record B (Portal) : 2026-08-14 to 2026-08-18 (Workshop: Bosch Car Care)
```

### Root Causes
- **Parallel Dual Entry**: Operations coordinators entering the initial breakdown in the Google Sheet while the hub mechanic independently files a portal inward ticket 4 days later.
- **Workshop Transfer**: Vehicle moved from a local hub service center to an authorized OEM workshop for specialized mechanical work.

### Operational & Financial Impact
- Double-counting fleet downtime days for a single vehicle.
- Conflicting workshop expense attribution across vendors.

### Resolution Logic
1. **Source Hierarchy**: Web Portal events take precedence over Google Sheet extracts:
   - When a portal event and a sheet extract share the same `(vehicle_number, start_date)`, the portal record is designated as canonical (`data_source = 'PORTAL_MAINTENANCE'`).
2. **Interval Boundary Merging**:
   - If two maintenance records for the same vehicle overlap (`start_B <= end_A`), the earlier `start_date` and latest `end_date` are merged into a continuous interval, preserving the maximum reported actual cost.

---

## 5. Issue 4: Workshop Cost Discrepancies and Invoicing Inconsistencies

### Description
Disparities between initial quotes, workshop physical tax invoices, and authorized payout amounts:
- Initial verbal quote in `estimated_amount` differs significantly from the invoice submitted at release.
- Completed maintenance records where `actual_cost` is 0.00 or NULL despite `status = 'COMPLETED'`.
- Deductions for insurance claims or warranties causing discrepancies between invoice total and `letzryd_payable`.

### Financial Impact
- Inability to audit fleet maintenance expenditure per vehicle.
- Reconciliation delays between workshop accounts payable and finance ledger.

### Resolution Logic & Data Standards
1. **Three-Tier Cost Model**:
   - `estimated_cost`: Populated strictly from `july_maintenance_in.estimated_amount` or sheet initial quotation.
   - `actual_cost`: Populated from `july_maintenance_out.letzryd_payable` (net liability payable by LetzRyd). If `letzryd_payable` is empty, falls back to `july_maintenance_out.invoice_amount`.
2. **Variance Audit Flags**:
   - Maintenance jobs where `actual_cost > estimated_cost * 1.5` are flagged for management approval.
   - Completed jobs with `actual_cost = 0.00` are audited to verify whether the repair was covered under warranty, insurance claim, or represents missing invoice paperwork.

---

## 6. Issue 5: Identifier Fragmentation and Job Card Tracking

### Description
Inconsistent tracking identifiers across sources:
- Google Sheets entries frequently omit job card numbers or store free-text remarks like "General service done at Hyd Hub".
- Web Portal records capture disparate identifiers across `inward_id`, `invoice_no`, `claim_number`, and `utr_no`.

### Resolution Logic
1. Canonical `job_card_number` is mapped from:
   - Priority 1: `july_maintenance_out.invoice_no`
   - Priority 2: `july_maintenance_in.claim_number`
   - Priority 3: `sheet_maintenance.job_card_number`
2. Unique composite foreign key pointers are retained in `core_maintenance`:
   - `portal_maintenance_in_id` (Pointer to `july_maintenance_in.id`)
   - `portal_maintenance_out_id` (Pointer to `july_maintenance_out.id`)
   - `sheet_maintenance_id` (Pointer to `sheet_maintenance.id`)

---

## 7. Master Issue Standardization Matrix

| Issue ID | Anomaly Category | Root Cause | Detection Condition | Remediation Rule |
| :--- | :--- | :--- | :--- | :--- |
| **MNT-01** | Open Intervals | Missing outward form submission | `end_date IS NULL AND CURRENT_DATE - start_date > 7` | Impute exit via subsequent allocation date; flag for review |
| **MNT-02** | Inverted Dates | Operator typing format error | `end_date < start_date` | Clamp `end_date = start_date`; force non-negative duration |
| **MNT-03** | Dual Entry Overlap | Simultaneous Sheet and Portal logging | Matching `(vehicle_number, start_date)` in both sources | Deduplicate to single record; set `data_source = 'PORTAL_MAINTENANCE'` |
| **MNT-04** | Missing Actual Cost | Invoice not uploaded at vehicle exit | `status = 'COMPLETED' AND actual_cost = 0.00` | Flag for workshop invoice reconciliation audit |
| **MNT-05** | High Cost Variance | Unforeseen mechanical damage discovered | `actual_cost > estimated_cost * 1.5 AND estimated_cost > 0` | Flag for operations leadership sign-off |
| **MNT-06** | City Vocabulary | Inconsistent city naming ('Bangalore', 'hyd') | Non-canonical city strings | Functional normalization to canonical city names |
| **MNT-07** | Vehicle Formatting | Spaces, hyphens, lowercase letters | `vehicle_number ~ '[^A-Z0-9]'` | Alphanumeric uppercase strip via `fn_clean_maintenance_vehicle()` |

---

## 8. Diagnostic SQL Verification Queries

### Audit 1: Find Active Maintenance Jobs Exceeding 14 Days
```sql
SELECT 
    id,
    vehicle_number,
    city,
    start_date,
    workshop_name,
    maintenance_reason,
    (CURRENT_DATE - start_date) AS days_in_shop,
    data_source
FROM public.core_maintenance
WHERE is_deleted = FALSE
  AND status = 'IN_PROGRESS'
  AND end_date IS NULL
  AND (CURRENT_DATE - start_date) > 14
ORDER BY days_in_shop DESC;
```

### Audit 2: Detect Inverted Maintenance Intervals
```sql
SELECT 
    id,
    vehicle_number,
    city,
    start_date,
    end_date,
    (end_date - start_date) AS negative_days,
    data_source
FROM public.core_maintenance
WHERE is_deleted = FALSE
  AND end_date IS NOT NULL
  AND end_date < start_date;
```

### Audit 3: Completed Repairs with Zero Invoiced Cost
```sql
SELECT 
    id,
    vehicle_number,
    city,
    start_date,
    end_date,
    workshop_name,
    job_card_number,
    estimated_cost,
    actual_cost,
    data_source
FROM public.core_maintenance
WHERE is_deleted = FALSE
  AND status = 'COMPLETED'
  AND (actual_cost = 0.00 OR actual_cost IS NULL)
ORDER BY end_date DESC;
```
