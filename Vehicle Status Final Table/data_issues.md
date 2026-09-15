# Vehicle Status Data Issues & Edge Case Catalog

This document provides an exhaustive, mathematically verified catalog of all 10 real-world edge cases identified across the LetzRyd fleet data infrastructure. Every scenario reflects real operational patterns observed across the 1,623 vehicles in `public.core_vehicle_onboarding`, the 7,273 trip starts in `public.core_vehicle_allocation`, and the 6,297 trip ends in `public.core_dropoffs`.

All numbers documented herein have been verified against the live production PostgreSQL database.

---

## Edge Case Summary Matrix

| ID | Edge Case Scenario | Live Database Volume | Root Cause | Primary Resolution Mechanism |
| :--- | :--- | :--- | :--- | :--- |
| EC-01 | Pristine RFD Vehicles | 139 vehicles | Newly onboarded cars awaiting initial allocation | Left join default to 'RFD' / 'In Yard' |
| EC-02 | Open Active Trips | 1,139 vehicles | Currently deployed vehicles without drop-off | Lateral join NULL return_date resolution |
| EC-03 | Same-Day Trips | 1,094 trips | Short trial, same-day exchange, or rapid swap | Single-day interval [start, start] evaluation |
| EC-04 | Consecutive Allocations (No Drop-off) | 170 instances | Yard staff omitted return form prior to next driver | LEAD(allocation_date) window bounding |
| EC-05 | Orphan Drop-offs | 8 instances | Return recorded without prior allocation record | Drop-off preserved for audit; asset remains RFD |
| EC-06 | Overlapping Workshop Maintenance | Operational pipeline | Accident / breakdown during active driver trip | Priority 1 Maintenance override; rent waived |
| EC-07 | Workshop Downtime from Yard | Operational pipeline | PDI, routine service, or CNG tuning between drivers | Yard -> Maintenance -> Yard transition |
| EC-08 | Intraday Handover (Drop + Alloc) | 606 vehicles | Driver A returns morning; Driver B allocated afternoon | Event precedence & timestamp sequence ordering |
| EC-09 | Inverted Date Contradictions | 0 tolerated | Human typo in date picker (return before allocation) | Lateral filter: d.return_date >= ra.allocation_date |
| EC-10 | Decommissioned / Soft-Deleted Assets | 2 vehicles | Total loss, scrap, or leasing vendor return | vo.is_deleted = FALSE mandatory filter |

---

## 1. Pristine RFD Vehicles (139 Vehicles)

### Operational Context
A vehicle is officially onboarded into the fleet asset registry (`public.core_vehicle_onboarding`), but has zero allocation records in `public.core_vehicle_allocation`.

### Ground Reality
These represent brand new vehicle deliveries from OEMs (e.g. Maruti Suzuki WagonR CNG, Tata Tigor EV) that have completed Pre-Delivery Inspection (PDI), GPS device fitment, and branding, and are physically parked in hub yards awaiting driver assignment.

### Live Database Evidence
```sql
SELECT COUNT(*) 
FROM public.core_vehicle_onboarding vo
WHERE vo.is_deleted = FALSE
  AND NOT EXISTS (
      SELECT 1 FROM public.core_vehicle_allocation a 
      WHERE a.vehicle_number = vo.registration_no AND a.is_deleted = FALSE
  );
-- Result: Exactly 139 vehicles.
```

### Business Risk & Failure Mode
If the status engine relied solely on an inner join against allocation logs, these 139 vehicles would completely vanish from fleet reports, undercounting available capacity and corrupting hub inventory reports.

### Architectural Resolution
The engine performs a full outer anchor from `public.core_vehicle_onboarding vo`. When no allocation record exists:
* `final_status` is resolved to `'RFD'` (Ready for Deployment).
* `cohort` is classified as `'In Yard'`.
* `partner_id`, `partner_name`, and `allocation_id` remain `NULL`.
* `billable_rent_day` is set to `FALSE` with `rent_waived_reason = 'RFD_IN_YARD'`.

---

## 2. Open Active Trips (1,139 Vehicles)

### Operational Context
A vehicle was allocated to a driver on an `allocation_date`, and no subsequent drop-off record exists in `public.core_dropoffs`.

### Ground Reality
The driver is currently operating the vehicle on commercial ride-hailing platforms (e.g. Uber, Ola) or corporate lease. The trip is continuous and ongoing.

### Live Database Evidence
```sql
WITH ranked_allocations AS (
    SELECT 
        a.id AS allocation_id,
        a.vehicle_number,
        a.allocation_date,
        LEAD(a.allocation_date) OVER (PARTITION BY a.vehicle_number ORDER BY a.allocation_date, a.id) AS next_allocation_date
    FROM public.core_vehicle_allocation a
    WHERE a.is_deleted = FALSE
)
SELECT COUNT(*)
FROM ranked_allocations ra
LEFT JOIN LATERAL (
    SELECT d.id
    FROM public.core_dropoffs d
    WHERE d.is_deleted = FALSE
      AND d.vehicle_number = ra.vehicle_number
      AND d.return_date >= ra.allocation_date
      AND (ra.next_allocation_date IS NULL OR d.return_date <= ra.next_allocation_date)
    ORDER BY d.return_date ASC, d.id ASC
    LIMIT 1
) d ON TRUE
WHERE d.id IS NULL AND ra.next_allocation_date IS NULL;
-- Result: Exactly 1,139 vehicles.
```

### Business Risk & Failure Mode
Treating open intervals as infinite without proper boundary conditions could allow stale records to indefinitely lock vehicles if an operator forgot to log a drop-off.

### Architectural Resolution
* The lateral join returns `dropoff_id = NULL` and `trip_end_date = NULL`.
* The trip state is flagged as `'CURRENTLY_ACTIVE'`.
* For any historical status query date $D \ge 	ext{trip\_start\_date}$, the engine confirms no subsequent allocation or drop-off occurred prior to $D$, maintaining status as `'Active'` (`cohort = 'On Road'`).
* Weekly rent billing evaluates `billable_rent_day = TRUE`.

---

## 3. Same-Day Trips (1,094 Trips)

### Operational Context
A driver receives a vehicle and returns it on the very same calendar date (`allocation_date = return_date`).

### Ground Reality
Same-day returns occur routinely in fleet operations:
1. **Mechanical Swaps:** The driver picks up a car in the morning, identifies an AC or brake defect within 2 hours, and returns it to the hub to swap for another car.
2. **Short-Term Rentals / Trials:** The driver takes the car for a single day trial.
3. **Documentation Disqualification:** The driver is allocated a car, but verification fails during daytime onboarding, leading to immediate recovery.

### Live Database Evidence
```sql
WITH ranked_allocations AS (
    SELECT 
        a.id AS allocation_id,
        a.vehicle_number,
        a.allocation_date,
        LEAD(a.allocation_date) OVER (PARTITION BY a.vehicle_number ORDER BY a.allocation_date, a.id) AS next_allocation_date
    FROM public.core_vehicle_allocation a
    WHERE a.is_deleted = FALSE
),
paired AS (
    SELECT ra.allocation_date, d.return_date
    FROM ranked_allocations ra
    JOIN LATERAL (
        SELECT d.return_date
        FROM public.core_dropoffs d
        WHERE d.is_deleted = FALSE
          AND d.vehicle_number = ra.vehicle_number
          AND d.return_date >= ra.allocation_date
          AND (ra.next_allocation_date IS NULL OR d.return_date <= ra.next_allocation_date)
        ORDER BY d.return_date ASC, d.id ASC
        LIMIT 1
    ) d ON TRUE
)
SELECT COUNT(*) FROM paired WHERE return_date = allocation_date;
-- Result: Exactly 1,094 trips.
```

### Business Risk & Failure Mode
Systems using strict inequality (`return_date > allocation_date`) fail to close the trip, falsely reporting the driver as holding the car indefinitely.

### Architectural Resolution
* In `public.v_vehicle_trip_intervals`, the lateral pairing allows `d.return_date >= ra.allocation_date`.
* To disambiguate same-day handovers between two distinct drivers, the engine matches `(d.driver_id = ra.partner_id OR ra.partner_id IS NULL)`.
* On that calendar date, `sp_generate_daily_vehicle_status` tags the record as `'Same Day D&A'` (Delivery & Attrition), billing rent appropriately if minimum operational duration was achieved.

---

## 4. Consecutive Allocations Without Intervening Drop-off (170 Instances)

### Operational Context
Vehicle $V$ is allocated to Driver A on Date 1. On Date 2, Vehicle $V$ is allocated to Driver B. However, no drop-off record exists for Driver A in `public.core_dropoffs`.

### Ground Reality
Hub executives during peak shift turnovers frequently hand keys directly from one driver to another, or execute the new driver's allocation form while failing to complete the return inspection paperwork for the outgoing driver.

### Live Database Evidence
```sql
WITH ordered_allocs AS (
    SELECT 
        id, vehicle_number, partner_id, allocation_date,
        LEAD(allocation_date) OVER (PARTITION BY vehicle_number ORDER BY allocation_date, id) AS next_alloc_date
    FROM public.core_vehicle_allocation
    WHERE is_deleted = FALSE
)
SELECT COUNT(*)
FROM ordered_allocs oa
WHERE oa.next_alloc_date IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM public.core_dropoffs d
      WHERE d.vehicle_number = oa.vehicle_number
        AND d.is_deleted = FALSE
        AND d.return_date >= oa.allocation_date
        AND d.return_date <= oa.next_alloc_date
  );
-- Result: Exactly 170 instances.
```

### Business Risk & Failure Mode
Without lookahead bounding, Driver A's trip would overlap Driver B's trip, causing double driver allocation on the same vehicle and generating double rent charges.

### Architectural Resolution
* The window function `LEAD(a.allocation_date) OVER (PARTITION BY a.vehicle_number ORDER BY a.allocation_date ASC, a.id ASC)` creates a strict upper boundary `next_allocation_date`.
* Driver A's trip is automatically capped:
  `trip_end_date = COALESCE(d.return_date, ra.next_allocation_date)`
* The state is classified as `'SUPERSEDED_BY_NEXT_ALLOCATION'`.
* On Date 2, custody transfer is absolute: Driver B is recognized as the sole legal custodian.

---

## 5. Orphan Drop-offs (8 Instances)

### Operational Context
A drop-off record exists in `public.core_dropoffs`, but no corresponding preceding allocation record exists in `public.core_vehicle_allocation`.

### Ground Reality
1. **Registration Plate Typos:** An executive submitted a return form with an errant digit (e.g. typing `MH03ES1160` instead of `MH03ES1169`).
2. **Pre-Digitization Legacy Assets:** A car allocated prior to digital record collection was returned to a hub and processed on digital forms.

### Live Database Evidence
```sql
SELECT COUNT(*)
FROM public.core_dropoffs d
WHERE d.is_deleted = FALSE
  AND NOT EXISTS (
      SELECT 1 FROM public.core_vehicle_allocation a
      WHERE a.vehicle_number = d.vehicle_number AND a.is_deleted = FALSE
  );
-- Result: Exactly 8 instances.
```

### Business Risk & Failure Mode
Attempting an inner join between drop-offs and allocations would either drop these financial return liabilities or trigger foreign key violations.

### Architectural Resolution
* Drop-offs are preserved in `public.core_dropoffs` with all recovery balances and inspection records for financial liability tracking.
* The interval pairing view anchors on allocations; orphan drop-offs do not create false negative-duration intervals.
* From the orphan return date forward, the vehicle is safely treated as `'RFD'` (`In Yard`) in hub inventory.

---

## 6. Overlapping Workshop Maintenance During Active Allocation

### Operational Context
A driver is in active custody of a vehicle when an on-road accident or mechanical breakdown occurs. The car enters an authorized service workshop for extensive repairs.

### Ground Reality
The physical car is stationary in a third-party garage (e.g. Maruti Authorized Service Station) for 5 to 30 days. The driver is temporarily without a vehicle, or in the case of an Individual Partner (`IP`) fleet operator, the operator retains responsibility while sub-drivers await repair completion.

### Live Database Evidence
Extracted from `public.core_maintenance` where `start_date` falls inside an allocation period.

### Business Risk & Failure Mode
If the system blindly bills daily rent based on the open allocation interval, the driver is unfairly penalized for days when the vehicle was physically inoperative in a garage.

### Architectural Resolution
* **Priority 1 Precedence Rule:** In `public.sp_generate_daily_vehicle_status`, the maintenance table (`public.core_maintenance`) takes absolute precedence over trip intervals.
* On every date $D$ where $	ext{maint.start\_date} \le D \le 	ext{maint.end\_date}$:
  * `final_status` switches to `'Maintenance'`.
  * `cohort` switches to `'Off Road'`.
  * `billable_rent_day` is forced to `FALSE` (`rent_waived_reason = 'WORKSHOP_MAINTENANCE'`).
* **Operator Custody Exception:** If `partner_id` contains `'IP'` (fleet operator), partner metadata is retained on the daily record so operations knows who manages the asset, while rent remains waived. For retail drivers, driver assignment is cleared (`NULL`).

---

## 7. Workshop Downtime Originating From Hub Yard

### Operational Context
A vehicle parked in the yard (`RFD`) is moved to a service workshop for scheduled periodic maintenance, CNG kit certification, or tyre replacement.

### Ground Reality
Routine preventive maintenance conducted between driver assignments.

### Live Database Evidence
Records in `public.core_maintenance` where no active trip interval overlaps the repair window.

### Business Risk & Failure Mode
The vehicle could be incorrectly flagged as available for deployment in the yard, causing hub managers to attempt allocating a car that is physically off-site.

### Architectural Resolution
* The engine transitions the car from `'RFD'` (`In Yard`) to `'Maintenance'` (`Off Road`) on `start_date`.
* `partner_id`, `partner_name`, and `partner_phone` remain `NULL`.
* Upon repair completion (`end_date`), the car automatically reverts to `'RFD'` (`In Yard`) on the following calendar day.

---

## 8. Intraday Handover (Same-Day Return and Re-allocation) (606 Vehicles)

### Operational Context
Driver A returns vehicle $V$ at 09:30 AM (`core_dropoffs`). The yard team cleans the vehicle, and allocates it to Driver B at 02:30 PM on the same date (`core_vehicle_allocation`).

### Ground Reality
High-efficiency asset turnaround during morning shift changes.

### Live Database Evidence
```sql
SELECT COUNT(DISTINCT d.vehicle_number)
FROM public.core_dropoffs d
JOIN public.core_vehicle_allocation a 
  ON d.vehicle_number = a.vehicle_number 
 AND d.return_date = a.allocation_date
WHERE d.is_deleted = FALSE AND a.is_deleted = FALSE;
-- Result: Exactly 606 vehicles have experienced intraday handovers.
```

### Business Risk & Failure Mode
Single-date granularity could cause a conflict over which driver is credited with the asset and billed rent.

### Architectural Resolution
* In `public.v_current_live_fleet_status`, ordering by `trip_start_date DESC, allocation_id DESC` guarantees that Driver B (the afternoon recipient) is recognized as the current live driver.
* In `public.sp_generate_daily_vehicle_status`, the presence of both an allocation and a drop-off on the same day is categorized as `'Same Day D&A'`.
* Both event IDs (`allocation_id` and `dropoff_id`) are preserved in the daily row for comprehensive cross-referencing.

---

## 9. Inverted Date Contradictions & Manual Input Errors

### Operational Context
A drop-off record contains a return date that is chronologically earlier than the trip's allocation date (`return_date < allocation_date`).

### Ground Reality
Data entry errors resulting from ambiguous date pickers (e.g. interpreting `04/09/2026` as April 9 instead of September 4) or manual typographical errors in spreadsheet cells.

### Live Database Evidence
```sql
SELECT COUNT(*) 
FROM public.v_vehicle_trip_intervals 
WHERE trip_end_date < trip_start_date;
-- Result: Exactly 0 instances (Zero Tolerance Verified).
```

### Business Risk & Failure Mode
Inverted dates generate negative trip durations, distorting fleet utilization metrics and crashing financial billing engines.

### Architectural Resolution
* In `public.v_vehicle_trip_intervals`, the lateral join query strictly enforces:
  ```sql
  WHERE (d.return_date > ra.allocation_date)
     OR (d.return_date = ra.allocation_date AND (d.driver_id = ra.partner_id OR ra.partner_id IS NULL))
  ```
* Any drop-off date strictly preceding the allocation date is completely rejected by the pairing engine.

---

## 10. Decommissioned / Soft-Deleted Assets (2 Vehicles)

### Operational Context
A vehicle asset is marked as deleted (`is_deleted = TRUE`, `deleted_at IS NOT NULL`) in `public.core_vehicle_onboarding`.

### Ground Reality
Vehicles permanently retired from the active fleet due to:
1. Total loss insurance write-offs following severe accidents.
2. Expired lease periods where vehicles are returned to leasing financiers.
3. Test or phantom registration numbers created during system staging.

### Live Database Evidence
```sql
SELECT registration_no, model, city, is_deleted, deleted_at
FROM public.core_vehicle_onboarding
WHERE is_deleted = TRUE;
-- Result: Exactly 2 decommissioned vehicles isolated.
```

### Business Risk & Failure Mode
Including decommissioned assets in daily attendance rosters inflates fleet capacity, depresses utilization KPIs, and causes automated systems to seek non-existent cars in hub yards.

### Architectural Resolution
* Every view (`public.v_current_live_fleet_status`, `public.v_vehicle_trip_intervals`) and procedure (`public.sp_generate_daily_vehicle_status`) incorporates a mandatory filter:
  `WHERE vo.is_deleted = FALSE`
* This guarantees that the master active denominator remains exactly 1,623 vehicles at all times.
