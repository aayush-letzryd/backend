# Complete Vehicle Status Architecture & Resolution Engine

## 1. Objective & Scope

The sole purpose of this architecture is to provide an accurate, automated, and real-time operational status for **every single vehicle in the fleet**, answering two fundamental questions:
1. **What is the status of each vehicle right now?** (Is it Active on road with a driver, Ready for Deployment in a yard, or in a Workshop undergoing maintenance?)
2. **What was the status of each vehicle on any historical date?** (A complete, auditable daily attendance ledger for the entire fleet).

Downstream systems (such as financial billing, rent calculations, or traffic challan attribution) are outside the scope of this engine. This engine focuses strictly on **operational state resolution**.

---

## 2. Complete Inventory of All Required Tables

The architecture is structured in 3 distinct layers:

```
========================================================================================
                                LAYER 1: RAW SOURCE TABLES
========================================================================================
        GOOGLE SHEETS INGESTION                          WEB PORTAL INGESTION
   ┌────────────────────────────────┐              ┌──────────────────────────────┐
   │ • sheet_vehicle_onboarding     │              │ • july_vehicle_onboarding    │
   │ • sheet_vehicle_allocations    │              │ • july_allocation_form       │
   │ • sheet_dropoffs               │              │ • july_vehicle_dropoffs      │
   │ • sheet_vehicle_status (Daily) │              │ • july_maintenance_in / out │
   └───────────────┬────────────────┘              └──────────────┬───────────────┘
                   │                                              │
                   └──────────────────────┬───────────────────────┘
                                          │
                                          ▼
========================================================================================
                     LAYER 2: UNIFIED CORE TRANSACTIONAL TABLES
========================================================================================
   ┌────────────────────────────────────────────────────────────────────────────────┐
   │ 1. public.core_vehicle_onboarding  <- Master Asset Denominator (1,623 vehicles)│
   │ 2. public.core_vehicle_allocation  <- Unified Trip Starts (7,269 records)      │
   │ 3. public.core_dropoffs            <- Unified Trip Ends (6,293 records)        │
   │ 4. public.core_maintenance         <- Unified Workshop Downtime Records        │
   └──────────────────────────────────────┬─────────────────────────────────────────┘
                                          │
                                          ▼
========================================================================================
                     LAYER 3: FINAL OPERATIONAL STATUS OUTPUTS
========================================================================================
   ┌────────────────────────────────────────────────────────────────────────────────┐
   │ 1. public.v_vehicle_trip_intervals   <- Continuous Trip Intervals & Yard Gaps   │
   │ 2. public.v_current_live_fleet_status<- Real-Time Fleet Status (Current Moment) │
   │ 3. public.core_daily_vehicle_status  <- Master Daily Attendance Calendar        │
   │                                         (1 row per vehicle per calendar date)  │
   └────────────────────────────────────────────────────────────────────────────────┘
```

### Detailed Table Specifications

#### Layer 1: Raw Ingestion Sources

| Table Name | Source Platform | Nature | What It Records |
| :--- | :--- | :--- | :--- |
| `sheet_vehicle_onboarding` | Google Sheets | Asset Entry | New car onboarding records from Google Forms |
| `july_vehicle_onboarding` | Web Portal | Asset Entry | New car onboarding records from Web Portal |
| `sheet_vehicle_allocations`| Google Sheets | Event | Pickup timestamp, driver ID, vehicle plate, initial odometer |
| `july_allocation_form` | Web Portal | Event | Pickup timestamp, driver ID, vehicle plate, inspection photos |
| `sheet_dropoffs` | Google Sheets | Event | Return timestamp, driver ID, vehicle plate, return liabilities |
| `july_vehicle_dropoffs` | Web Portal | Event | Return timestamp, driver ID, vehicle plate, return inspection |
| `sheet_vehicle_status` | Google Sheets | Daily Log | Daily manual tracker sheet (used to extract historical maintenance rows) |
| `july_maintenance_in` | Web Portal | Event | Workshop entry date, repair reason, estimated delivery date |
| `july_maintenance_out` | Web Portal | Event | Workshop exit date, RFD date, actual invoice amount, closure flag |

#### Layer 2: Core Transactional Event Tables

1. **`public.core_vehicle_onboarding` (The Fleet Denominator):**
   * **Role:** Single source of truth for the physical car as an asset.
   * **Size:** Exactly 1,623 active vehicles.
   * **Rule:** A vehicle cannot exist in the status engine unless it is onboarded here.

2. **`public.core_vehicle_allocation` (Trip Starts):**
   * **Role:** Merges `sheet_vehicle_allocations` and `july_allocation_form`.
   * **Size:** 7,269 records.
   * **Rule:** Records the exact date, time, and partner when keys are handed over.

3. **`public.core_dropoffs` (Trip Ends):**
   * **Role:** Merges `sheet_dropoffs` and `july_vehicle_dropoffs`.
   * **Size:** 6,293 records.
   * **Rule:** Records the exact date, time, and liabilities when keys are returned to a hub.

4. **`public.core_maintenance` (Workshop Repairs):**
   * **Role:** Merges Portal maintenance forms (`july_maintenance_in` / `out`) and Sheet maintenance records into unified repair intervals.
   * **Rule:** Records when a car enters a workshop (`start_date`) and when it leaves (`end_date`).

#### Layer 3: Final Operational Status Outputs

1. **`public.v_vehicle_trip_intervals` (The Pairing View):**
   * Pairs every allocation with its subsequent drop-off event to create continuous trip intervals `[trip_start_date, trip_end_date]`.

2. **`public.v_current_live_fleet_status` (Real-Time Live View):**
   * Provides the live operational state of every vehicle right now (Active on road, RFD in yard, or in Maintenance).

3. **`public.core_daily_vehicle_status` (The Master Daily Attendance Table):**
   * Contains exactly 1 row per vehicle per calendar date.
   * Tells operations whether each car was Active, RFD, or in Maintenance on each day of the year.

---

## 3. How the Tables Merge (Platform Unification)

### 1. Allocations Merge (Sheets + Portal -> `core_vehicle_allocation`)
* Whenever an allocation is submitted via Google Sheets (`sheet_vehicle_allocations`) or Web Portal (`july_allocation_form`), a PostgreSQL database trigger processes the record.
* If both Google Sheet and Portal contain the same allocation event (matching on `vehicle_number`, `partner_id`, and `allocation_date`), they are unified into one record with `source_origin = 'MERGED'`.
* Portal test rows (e.g. `DR-TEST-002`, `TS09EV9999`) are filtered out by strict regex gatekeepers.

### 2. Drop-offs Merge (Sheets + Portal -> `core_dropoffs`)
* Whenever a drop-off is submitted via Google Sheets (`sheet_dropoffs`) or Web Portal (`july_vehicle_dropoffs`), a PostgreSQL database trigger processes the record.
* Matches on `vehicle_number`, `driver_id`, and `return_date`.
* Reconciles financial debt columns into a unified `negative_balance`.

### 3. Maintenance Merge (Portal In/Out + Sheet Maintenance -> `core_maintenance`)
* **From Web Portal:** Connects `july_maintenance_in` with its matching `july_maintenance_out` via `inward_id`. 
  * If `is_closed = TRUE` or a matching `maintenance_out` exists: `status = 'COMPLETED'`, `end_date = rfd_date`.
  * If `is_closed = FALSE` and no `maintenance_out` exists: `status = 'IN_PROGRESS'`, `end_date = NULL` (car is currently in the workshop!).
* **From Google Sheets:** Extracted from historical rows in `sheet_vehicle_status` where `final_status = 'Maintenance'`.

---

## 4. The Vehicle Interval Pairing Algorithm

Every vehicle in the fleet moves through a continuous chain of time intervals:

```
[Onboarding] -> [RFD in Hub] -> [Allocation Event] -> [Active on Road] -> [Drop-off Event] -> [RFD in Hub]
```

### Mathematical Pairing Logic

For each vehicle $V \in \text{core\_vehicle\_onboarding}$:
1. Retrieve all allocation events from `core_vehicle_allocation` ordered chronologically:
   $$A_1, A_2, \dots, A_k \quad \text{where } A_i.\text{date} \le A_{i+1}.\text{date}$$
2. For each allocation $A_i$, look ahead to find the next allocation date $A_{i+1}.\text{date}$.
3. Find the earliest drop-off event $D_j \in \text{core\_dropoffs}$ satisfying:
   $$D_j.\text{vehicle} = A_i.\text{vehicle}$$
   $$D_j.\text{return\_date} \ge A_i.\text{allocation\_date}$$
   $$D_j.\text{return\_date} \le A_{i+1}.\text{allocation\_date} \quad (\text{if } A_{i+1} \text{ exists})$$
4. This produces a **Trip Interval**:
   * **Closed Trip:** If $D_j$ is found $\rightarrow$ Interval is $[A_i.\text{allocation\_date}, D_j.\text{return\_date}]$. The driver had the car from start date to end date.
   * **Open Trip:** If no $D_j$ is found $\rightarrow$ Interval is $[A_i.\text{allocation\_date}, \infty)$. The vehicle is **currently active on the road today** with that driver.
5. **RFD (Ready for Deployment) In Yard:**
   * Any calendar date falling between the end of one trip $D_j.\text{return\_date}$ and the start of the next trip $A_{i+1}.\text{allocation\_date}$ is resolved as **RFD**.
   * Any vehicle from `core_vehicle_onboarding` with 0 allocations is resolved as **RFD** from its onboarding date forward.

---

## 5. Exhaustive Edge Cases & Handling Rules

Every real-world operational edge case has been checked and quantified against the live PostgreSQL database:

### Edge Case 1: Pristine RFD Vehicles (139 vehicles in live DB)
* **What it is:** A vehicle is onboarded in `core_vehicle_onboarding`, but has 0 allocation records in the entire database.
* **Why it happens:** Brand new cars that arrived at the hub, completed PDI, and are parked in the yard waiting for their first driver.
* **Handling:** The engine assigns `final_status = 'RFD'`, `cohort = 'In Yard'`, `partner_id = NULL`.

### Edge Case 2: Open Trips / Currently Active (1,141 vehicles in live DB)
* **What it is:** An allocation exists, but no drop-off has occurred.
* **Why it happens:** The driver is currently driving the car on the road right now.
* **Handling:** The engine sets `trip_state = 'CURRENTLY_ACTIVE'`, `trip_end_date = NULL`. The car remains `Active` with that driver on every calendar date from `allocation_date` up to `CURRENT_DATE`.

### Edge Case 3: Same-Day Trips (1,093 trips in live DB)
* **What it is:** `allocation_date = return_date`.
* **Why it happens:** A driver took the car in the morning and returned it in the evening (trial run, car swap, or quick return).
* **Handling:** The interval is valid: `[start_date, start_date]`. On that calendar date, the vehicle records the driver who had it during the day. By the end of the day, the vehicle transitions to `RFD`.

### Edge Case 4: Back-to-Back Allocations Without a Drop-off (170 instances in live DB)
* **What it is:** Vehicle is allocated to Driver 1 on Jan 10. On Jan 20, the vehicle is allocated to Driver 2, but no drop-off form was submitted for Driver 1.
* **Why it happens:** Yard staff forgot to submit the drop-off form when Driver 1 returned the car, and immediately submitted the allocation form for Driver 2.
* **Handling:**
  * The window function `LEAD(allocation_date)` bounds Driver 1's trip strictly to `[Jan 10, Jan 20)`.
  * On Jan 20, Driver 2 takes ownership.
  * Driver 1's trip is capped so Driver 1 is not shown as holding the car after Driver 2 was allocated.
  * The system flags `source_origin = 'CAPPED_OPEN_ALLOCATION'` for audit review.

### Edge Case 5: Orphan Drop-offs (8 instances in live DB)
* **What it is:** A drop-off record exists for a vehicle that has no preceding allocation record.
* **Why it happens:** An executive filled a drop-off form for an unrecorded legacy allocation or typed the vehicle plate with a typo.
* **Handling:**
  * Orphan drop-offs cannot pair with an allocation.
  * The engine preserves the drop-off in `core_dropoffs` for liability audit, but for operational status, the vehicle remains `RFD` starting from the drop-off date.

### Edge Case 6: Workshop Downtime Overlapping an Active Trip
* **What it is:** A driver is on an active trip, gets into an accident, and the car enters a workshop.
* **Why it happens:** The car is physically undergoing repair while administratively still assigned to a driver.
* **Handling:**
  * **Priority 1 applies:** The moment `core_maintenance` has an active record (`start_date <= Date <= end_date`), the vehicle status shifts to **`Maintenance`** (`cohort = 'Off Road'`).
  * Maintenance overrides the active allocation for the duration of the repair.
  * Once the vehicle exits the workshop (`end_date`), if the driver has not dropped off the car, status returns to `Active`. If a drop-off was submitted during repairs, status returns to `RFD`.

### Edge Case 7: Workshop Downtime from the Yard (PDI or Periodic Service)
* **What it is:** A car sitting in the hub yard (RFD) is sent to the workshop for periodic servicing, CNG tuning, or minor repairs.
* **Why it happens:** Maintenance between drivers.
* **Handling:**
  * Car transitions from `RFD` -> `Maintenance` on `start_date`.
  * On `end_date`, car transitions from `Maintenance` -> `RFD`.
  * `partner_id` remains `NULL` throughout.

### Edge Case 8: Intraday Handover (Two Actions on the Same Day)
* **What it is:** Driver A returns a car at 10:00 AM (`core_dropoffs`). Driver B is allocated the same car at 2:00 PM (`core_vehicle_allocation`).
* **Handling:**
  * The allocation for Driver B has a later timestamp than the drop-off.
  * The real-time view `v_current_live_fleet_status` shows Driver B as the current live driver.
  * The daily ledger `core_daily_vehicle_status` records Driver B as the active driver by close of day, while storing the drop-off reference from the morning.

### Edge Case 9: Date Formatting & Inverted Dates
* **What it is:** A human types `return_date` as `05/09/2026` intending Sep 5, but Apps Script or raw inputs parse it as May 9 (`2026-05-09`), making return date appear earlier than allocation date (`2026-09-01`).
* **Handling:**
  * In `v_vehicle_trip_intervals`, the lateral join enforces `d.return_date >= ra.allocation_date`.
  * Any drop-off date strictly earlier than the allocation date is rejected by the pairing engine, preventing inverted negative duration trips.

### Edge Case 10: Decommissioned / Deleted Vehicles
* **What it is:** A vehicle is sold, total-loss damaged, or returned to a leasing vendor (`is_deleted = TRUE` in `core_vehicle_onboarding`).
* **Handling:**
  * All views and procedures filter on `vo.is_deleted = FALSE`.
  * Decommissioned vehicles are completely excluded from active fleet counters and daily status generation.

---

## 6. The 3 Priority Precedence Rules

For any vehicle on any date $D$, the operational state is determined by this strict order:

```
┌────────────────────────────────────────────────────────────────────────┐
│               PRIORITY 1: IS THE CAR IN THE WORKSHOP?                  │
│       Check core_maintenance: start_date <= D AND end_date >= D        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                   YES                              NO
                    │                               │
                    ▼                               ▼
       ┌────────────────────────┐      ┌─────────────────────────────────┐
       │ STATUS = 'Maintenance' │      │ PRIORITY 2: IS CAR IN A TRIP?   │
       │ COHORT = 'Off Road'    │      │ Check v_vehicle_trip_intervals: │
       │ DRIVER = NULL          │      │ start_date <= D AND             │
       └────────────────────────┘      │ (end_date IS NULL OR >= D)      │
                                       └────────────────┬────────────────┘
                                                        │
                                        ┌───────────────┴───────────────┐
                                       YES                              NO
                                        │                               │
                                        ▼                               ▼
                           ┌────────────────────────┐      ┌────────────────────────┐
                           │ STATUS = 'Active'      │      │ STATUS = 'RFD'         │
                           │ COHORT = 'On Road'     │      │ COHORT = 'In Yard'     │
                           │ DRIVER = Partner ID    │      │ DRIVER = NULL          │
                           └────────────────────────┘      └────────────────────────┘
```

1. **Priority 1: Maintenance Override**
   * If a vehicle is in the workshop, its operational state is **`Maintenance`** (`cohort = 'Off Road'`).
   * Driver assignment is set to `NULL`.

2. **Priority 2: Active Trip Interval**
   * If not in maintenance, and date $D$ falls inside an allocation interval $[A.\text{start}, D.\text{end}]$, status is **`Active`** (`cohort = 'On Road'`).
   * Driver assignment is set to the allocated partner.

3. **Priority 3: Default State (Ready for Deployment)**
   * If the car is neither in the workshop nor on an active trip, it is physically standing in a LetzRyd hub yard.
   * Status is **`RFD`** (`cohort = 'In Yard'`).
   * Driver assignment is `NULL`.

---

## 7. Target SQL Schema & Production Code

The complete SQL DDL, views, and stored procedure are in [`temp_vehicle_status_architecture/schema.sql`](file:///C:/Users/anura/RYD/backend_repo/temp_vehicle_status_architecture/schema.sql):

### 1. Master Daily Status Table
```sql
CREATE TABLE IF NOT EXISTS public.core_daily_vehicle_status (
    id BIGSERIAL PRIMARY KEY,
    status_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(10) NOT NULL,
    
    -- Operational Status
    final_status VARCHAR(30) NOT NULL,      -- 'Active', 'RFD', 'Maintenance'
    cohort VARCHAR(20) NOT NULL,            -- 'On Road', 'In Yard', 'Off Road'
    
    -- Driver Assignment (NULL if RFD or Maintenance)
    partner_id VARCHAR(50),
    partner_name VARCHAR(150),
    partner_phone VARCHAR(20),
    hub_name VARCHAR(100),
    car_model VARCHAR(100),
    
    -- Linked Events
    allocation_id BIGINT,
    allocation_date DATE,
    dropoff_id BIGINT,
    dropoff_date DATE,
    maintenance_id BIGINT,
    
    source_origin VARCHAR(50) NOT NULL,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_daily_vehicle_status UNIQUE (status_date, vehicle_number)
);
```

### 2. Live Fleet View (Instant Moment)
```sql
CREATE OR REPLACE VIEW public.v_current_live_fleet_status AS
-- Instant snapshot of all 1,623 vehicles right now (Active, RFD, Maintenance)
...
```

### 3. Daily Ledger Stored Procedure
```sql
-- Populates or refreshes core_daily_vehicle_status for any date:
CALL public.sp_generate_daily_vehicle_status('2026-09-09');
```

---

## 8. Verification on Live PostgreSQL

The verification script [`verify_engine.py`](file:///C:/Users/anura/RYD/backend_repo/temp_vehicle_status_architecture/verify_engine.py) connects directly to PostgreSQL and outputs the mathematical distribution across the fleet:

```bash
python verify_engine.py
```

### Live Database Output:
* Total Onboarded Fleet: **1,623 active vehicles**
* Total Trip Starts (Allocations): **7,273 records**
* Total Completed Trips (Closed Drop-offs): **6,134 records**
* Currently Active on Road (Open Allocations): **1,139 vehicles**
* Currently in Yard (RFD) / Workshop: **484 vehicles** ($1,623 - 1,139$)
* Pristine RFD Vehicles (0 historical allocations): **139 vehicles**
* Same-Day Completed Trips: **1,094 trips**

---

## 9. End-to-End Operational Runbook (Step-by-Step Knowledge Transfer)

This step-by-step runbook explains how to operate, deploy, query, and maintain the vehicle status engine. Follow these steps sequentially:

### Step 1: Verify Core Source Data (The Denominator & Event Sources)
Before executing the status engine, confirm that the four underlying core tables are populated and consistent:
1. **`public.core_vehicle_onboarding`**: This is the master asset denominator. Check the active fleet count:
   ```sql
   SELECT count(*) FROM public.core_vehicle_onboarding WHERE is_deleted = FALSE;
   -- Expected: Exactly 1,623 active vehicles.
   ```
2. **`public.core_vehicle_allocation`**: Unified allocation events (trip starts).
   ```sql
   SELECT count(*) FROM public.core_vehicle_allocation WHERE is_deleted = FALSE;
   -- Expected: 7,273 records.
   ```
3. **`public.core_dropoffs`**: Unified vehicle return events (trip ends).
   ```sql
   SELECT count(*) FROM public.core_dropoffs WHERE is_deleted = FALSE;
   -- Expected: 6,297 records.
   ```
4. **`public.core_maintenance`**: Unified workshop repair events.

> **Key Rule**: A vehicle cannot have an operational status unless it exists in `public.core_vehicle_onboarding`. If a vehicle appears in an allocation or drop-off sheet but is not onboarded, it will not be evaluated.

---

### Step 2: Deploy the Database Schema & Core Objects
Deploy the complete schema file [`schema.sql`](file:///C:/Users/anura/RYD/backend_repo/temp_vehicle_status_architecture/schema.sql) onto the PostgreSQL database:
```bash
psql -h 35.200.196.113 -U postgres -d postgres -f schema.sql
```

This command deploys five core database objects:
1. **`public.core_maintenance`**: Master table for workshop downtime intervals.
2. **`public.core_daily_vehicle_status`**: Master daily attendance ledger (1 row per vehicle per calendar date).
3. **`public.v_vehicle_trip_intervals`**: Mathematical view pairing allocations with drop-offs.
4. **`public.v_current_live_fleet_status`**: Real-time view for immediate fleet operational queries.
5. **`public.sp_generate_daily_vehicle_status`**: Stored procedure to generate daily attendance.

---

### Step 3: Query Real-Time Fleet Status ("What is happening right now?")
To determine what every single vehicle in the fleet is doing at the present moment, query the live view:
```sql
SELECT 
    live_status, 
    live_cohort, 
    count(*) AS vehicle_count,
    round(count(*) * 100.0 / sum(count(*)) over (), 2) AS percentage
FROM public.v_current_live_fleet_status
GROUP BY live_status, live_cohort
ORDER BY vehicle_count DESC;
```

**Expected Distribution**:
- **`Active` / `On Road`**: ~1,139 vehicles (cars assigned to a driver on an active trip).
- **`RFD` / `In Yard`**: ~484 vehicles (cars parked in hub yards ready for deployment).
- **`Maintenance` / `Off Road`**: Vehicles currently undergoing workshop repairs.

**To inspect a specific vehicle right now**:
```sql
SELECT vehicle_number, live_status, live_cohort, current_driver_id, current_driver_name, current_trip_started
FROM public.v_current_live_fleet_status
WHERE vehicle_number = 'MH03ES1169';
```

---

### Step 4: Generate the Daily Attendance Ledger ("What was the status on Date X?")
The daily ledger table `public.core_daily_vehicle_status` records the exact status of every car for each calendar day, serving as the single source of truth for weekly Hisaab and rent deductions.

**To generate or refresh status for a single date**:
```sql
CALL public.sp_generate_daily_vehicle_status('2026-09-09');
```

**To verify the generated daily records**:
```sql
SELECT final_status, cohort, count(*)
FROM public.core_daily_vehicle_status
WHERE status_date = '2026-09-09'
GROUP BY final_status, cohort
ORDER BY count(*) DESC;
-- The total count must equal exactly 1,623 rows (100% fleet coverage).
```

**To backfill historical dates (e.g. an entire month)**:
Execute a simple SQL block to iterate over the desired date range:
```sql
DO $$
DECLARE
    curr_date DATE := '2026-08-01';
    end_date DATE := '2026-08-31';
BEGIN
    WHILE curr_date <= end_date LOOP
        RAISE NOTICE 'Generating fleet status for date: %', curr_date;
        CALL public.sp_generate_daily_vehicle_status(curr_date);
        curr_date := curr_date + INTERVAL '1 day';
    END LOOP;
END $$;
```

---

### Step 5: Understand the Priority Precedence Engine
When evaluating a vehicle on any given date, the engine applies three strict priority rules in sequential order:

1. **Priority 1: Is the vehicle in a workshop?**
   - Check `core_maintenance`: Does `start_date <= target_date AND (end_date IS NULL OR end_date >= target_date)`?
   - If **YES**: Status is set to **`Maintenance`** (`cohort = 'Off Road'`). Rent is waived (`billable_rent_day = FALSE`, `rent_waived_reason = 'WORKSHOP_MAINTENANCE'`). Driver assignment is set to `NULL` for retail drivers, but preserved for `IP` operators.
2. **Priority 2: Is the vehicle on an active trip?**
   - Check `v_vehicle_trip_intervals`: Does `trip_start_date <= target_date AND (trip_end_date IS NULL OR trip_end_date > target_date)`?
   - If **YES**: Status is set to **`Active`** (`cohort = 'On Road'`). Driver assignment is populated with `partner_id` and `driver_name`. Rent is billable (`billable_rent_day = TRUE`).
3. **Priority 3: Default Yard State (Ready for Deployment)**
   - If neither Priority 1 nor Priority 2 matches: The car is parked in a hub yard.
   - Status is set to **`RFD`** (`cohort = 'In Yard'`). Driver assignment is `NULL`. Rent is waived (`billable_rent_day = FALSE`, `rent_waived_reason = 'RFD_IN_YARD'`).

---

### Step 6: Operator (`IP`) vs Retail Driver Handling
A critical fleet business distinction exists between retail drivers and operators:
- **Retail Drivers** (`LETZ<CITY><PHONE>`): Drive a single vehicle. When a retail driver drops off a car for repairs or return, the allocation interval terminates immediately, and the vehicle enters `Maintenance` or `RFD`.
- **Operators** (`LETZ<CITY>IP<PHONE>`): Rent multiple vehicles concurrently and hire sub-drivers. When an operator sends a vehicle for "Repair and Maintenance", the operator retains custody of the asset.
- **Engine Logic**: In `v_vehicle_trip_intervals`, if `return_type = 'Repair and Maintenance'` and `partner_id` contains `'IP'`, the trip interval is **NOT** truncated. The vehicle status on that day reflects `Maintenance` (`Off Road`), but the driver assignment remains credited to the `IP` operator until a new allocation supersedes it.

---

### Step 7: Automated Verification & Health Checks
Run the verification script to confirm that the mathematical pairing logic and database integrity remain 100% accurate:
```bash
python verify_engine.py
```

**Verification Checklist**:
- Total Denominator matches `core_vehicle_onboarding` (1,623).
- Allocations ($7,273$) = Closed Trips ($6,134$) + Currently Active ($1,139$).
- Active on Road ($1,139$) + Yard/Workshop ($484$) = Fleet Denominator ($1,623$).
- Zero negative duration intervals ($trip\_end\_date \ge trip\_start\_date$).
- Exactly 139 pristine RFD vehicles (brand new cars waiting for first driver).

---

### Step 8: Nightly Scheduled Operations
To ensure the fleet attendance ledger is updated daily for finance and Hisaab reporting, schedule a nightly cron job at 23:59 IST (18:29 UTC):
```bash
# Example cron entry to generate attendance for the current day
59 23 * * * psql -h 35.200.196.113 -U postgres -d postgres -c "CALL public.sp_generate_daily_vehicle_status(CURRENT_DATE);"
```

