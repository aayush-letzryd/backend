# Fleet Vehicle Status Architecture & Production Ledger Runbook

## 1. System Mission & Scope

The Fleet Vehicle Status Architecture is the definitive operational authority for the entire LetzRyd vehicle fleet. It is architected to answer two fundamental operational and financial questions with mathematical certainty:

1. **Real-Time Operational State:** What is the precise operational disposition of every single vehicle in the fleet right now? Is it active on the road with an assigned driver, standing ready for deployment (RFD) in a hub yard, or undergoing maintenance in an authorized workshop?
2. **Historical Attendance Ledger:** What was the exact operational status, assigned driver, and rent billability for every vehicle on any given calendar date in history?

This engine provides the foundational source of truth required by downstream systems, including driver weekly settlement (Hisaab), leaseholder billing, insurance claims, and traffic challan attribution.

---

## 2. Multi-Layer Architecture & Data Flow

The operational status infrastructure is designed in three discrete tiers to isolate raw external inputs from core transactional data and business-ready ledger views:

```
========================================================================================
                                LAYER 1: RAW SOURCE TABLES
========================================================================================
         GOOGLE SHEETS INGESTION                         WEB PORTAL INGESTION
    +--------------------------------+             +------------------------------+
    | * sheet_vehicle_onboarding     |             | * july_vehicle_onboarding    |
    | * sheet_vehicle_allocations    |             | * july_allocation_form       |
    | * sheet_dropoffs               |             | * july_vehicle_dropoffs      |
    | * sheet_vehicle_status (Daily) |             | * july_maintenance_in / out |
    +----------------+---------------+             +--------------+---------------+
                     |                                            |
                     +---------------------+----------------------+
                                           |
                                           v
========================================================================================
                      LAYER 2: UNIFIED CORE TRANSACTIONAL TABLES
========================================================================================
    +----------------------------------------------------------------------------------+
    | 1. public.core_vehicle_onboarding  <- Master Asset Denominator (1,623 vehicles)  |
    | 2. public.core_vehicle_allocation  <- Unified Trip Starts (7,273 records)        |
    | 3. public.core_dropoffs            <- Unified Trip Ends (6,297 records)          |
    | 4. public.core_maintenance         <- Unified Workshop Downtime Events           |
    +--------------------------------------|-------------------------------------------+
                                           |
                                           v
========================================================================================
                      LAYER 3: FINAL OPERATIONAL STATUS OUTPUTS
========================================================================================
    +----------------------------------------------------------------------------------+
    | 1. public.v_vehicle_trip_intervals   <- Continuous Trip Intervals & Yard Gaps    |
    | 2. public.v_current_live_fleet_status<- Real-Time Fleet Snapshot (Live Moment)   |
    | 3. public.core_daily_vehicle_status  <- Master Daily Attendance Calendar         |
    |                                         (1 row per vehicle per calendar date)    |
    +----------------------------------------------------------------------------------+
```

### Architectural Layer Definitions

* **Layer 1 (Raw Ingestion):** Captures operational entries submitted across distributed Google Sheets and Web Portal forms. External payloads are audited and cleansed before promotion.
* **Layer 2 (Core Master Transactions):** Canonical, deduplicated tables storing physical vehicle onboarding (`core_vehicle_onboarding`), trip start events (`core_vehicle_allocation`), trip end events (`core_dropoffs`), and workshop maintenance records (`core_maintenance`).
* **Layer 3 (Operational Outputs):** The mathematical resolution views and stored procedures providing live fleet visibility and persistent daily attendance records for downstream reporting.

---

## 3. Database Object Specifications

### 1. `public.core_daily_vehicle_status` (Master Daily Attendance Ledger)
The central persistent daily ledger. Generates exactly one record per vehicle per calendar day ($1,623 \text{ vehicles} \times 1 \text{ day} = 1,623 \text{ rows/day}$).

| Column Name | Data Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| `id` | BIGSERIAL | NO | Auto-incrementing surrogate primary key. |
| `status_date` | DATE | NO | Calendar date of observation. |
| `vehicle_number` | VARCHAR(20) | NO | Vehicle registration number (e.g. `KA51AL1878`). |
| `city` | VARCHAR(10) | NO | Operating city (`Bengaluru`, `Hyderabad`, `Mumbai`). |
| `final_status` | VARCHAR(30) | NO | Operational state (`Active`, `RFD`, `Maintenance`, `Same Day D&A`, `Allocation`, `Drop Off`). |
| `cohort` | VARCHAR(20) | NO | Physical placement (`On Road`, `In Yard`, `Off Road`). |
| `partner_id` | VARCHAR(50) | YES | Driver/Operator ID (`LETZ<CITY><PHONE>` or `LETZ<CITY>IP<PHONE>`). |
| `partner_name` | VARCHAR(150) | YES | Full registered driver or operator name. |
| `partner_phone` | VARCHAR(20) | YES | Cleaned 10-digit driver mobile number. |
| `hub_name` | VARCHAR(100) | YES | Originating base hub (e.g. `BTM Layout Hub`). |
| `car_model` | VARCHAR(100) | YES | Vehicle make and model (e.g. `Maruti Wagonr Tour H3 CNG`). |
| `allocation_id` | BIGINT | YES | Foreign key linking to active `public.core_vehicle_allocation.id`. |
| `allocation_date` | DATE | YES | Start date of current driver trip interval. |
| `dropoff_id` | BIGINT | YES | Foreign key linking to closing `public.core_dropoffs.id`. |
| `dropoff_date` | DATE | YES | Return date of vehicle handover. |
| `maintenance_id` | BIGINT | YES | Foreign key linking to `public.core_maintenance.id`. |
| `billable_rent_day` | BOOLEAN | NO | Direct billing directive for Hisaab (`TRUE` = charge daily rent). |
| `rent_waived_reason`| VARCHAR(100) | YES | Reason if rent waived (`RFD_IN_YARD`, `WORKSHOP_MAINTENANCE`, `DROPOFF_INSPECTION`). |
| `source_origin` | VARCHAR(50) | NO | Audit provenance tag (`ACTIVE_INTERVAL`, `SAME_DAY_HANDOVER`, `YARD_ROLLOVER`, etc.). |
| `created_at` | TIMESTAMP | YES | Audit creation timestamp (IST). |
| `updated_at` | TIMESTAMP | YES | Audit update timestamp (IST). |

**Table Constraints & Indexes:**
* `uq_daily_vehicle_status UNIQUE (status_date, vehicle_number)`
* `idx_cdvs_date_partner ON (status_date, partner_id)`
* `idx_cdvs_vehicle_date ON (vehicle_number, status_date)`
* `idx_cdvs_status_date ON (final_status, status_date)`

---

### 2. `public.v_vehicle_trip_intervals` (Continuous Interval Pairing View)
Constructs continuous trip intervals by pairing allocation events with subsequent drop-off events using windowed lookaheads and lateral subqueries.

**Core Technical Logic:**
* **Window Bounding:** Applies `LEAD(a.allocation_date) OVER (PARTITION BY a.vehicle_number ORDER BY a.allocation_date ASC, a.id ASC)` to capture subsequent allocation events.
* **Lateral Matching:** Joins `core_dropoffs` matching `vehicle_number`, bounded between `ra.allocation_date` and `ra.next_allocation_date`.
* **Same-Day Resolution:** Disambiguates multiple driver handovers on the same date by asserting `(d.driver_id = ra.partner_id OR ra.partner_id IS NULL)`.
* **Operator Custody Retention:** For individual partner (`IP`) operators, drop-offs of type `Repair and Maintenance` do not truncate the trip interval unless a subsequent allocation supersedes it.

---

### 3. `public.v_current_live_fleet_status` (Real-Time Snapshot View)
Provides immediate operational visibility for every active vehicle ($N = 1,623$) at the current moment:
* Anchored on `public.core_vehicle_onboarding WHERE is_deleted = FALSE`.
* Left joins the latest allocation interval from `v_vehicle_trip_intervals`.
* Left joins open workshop tickets from `core_maintenance WHERE (end_date IS NULL OR end_date >= CURRENT_DATE)`.
* Resolves `live_status` (`Active`, `RFD`, `Maintenance`), `live_cohort` (`On Road`, `In Yard`, `Off Road`), and current driver assignment.

---

### 4. `public.sp_generate_daily_vehicle_status(IN p_target_date DATE)` (Stored Procedure)
Populates or refreshes `public.core_daily_vehicle_status` for any specified target date. Implements idempotent `ON CONFLICT (status_date, vehicle_number) DO UPDATE` semantics to ensure repeated executions do not burn sequences or create duplicate records.

---

## 4. Mathematical Interval Pairing Model

Every onboarded vehicle moves continuously across alternating periods of Driver Custody and Yard Custody:

```
[Onboarding] ---> [Yard RFD] ---> [Allocation Event] ---> [Active Driver Trip] ---> [Drop-off Event] ---> [Yard RFD]
```

### Mathematical Formalization

For each vehicle $V \in \text{core\_vehicle\_onboarding}$:
1. Let the ordered sequence of trip allocations be:
   $$A = \{A_1, A_2, \dots, A_k\} \quad \text{where } A_i.\text{date} \le A_{i+1}.\text{date}$$
2. For each allocation $A_i$, the upper bound is defined by $A_{i+1}.\text{date}$ (or $\infty$ if $i = k$).
3. The paired drop-off $D_j$ is the earliest return event satisfying:
   $$D_j.\text{vehicle} = A_i.\text{vehicle}$$
   $$D_j.\text{date} \ge A_i.\text{date}$$
   $$D_j.\text{date} \le A_{i+1}.\text{date} \quad (\text{if } A_{i+1} \text{ exists})$$
4. **Trip State Classification:**
   * **Closed Trip:** If $D_j$ exists $\rightarrow$ Duration is $[A_i.\text{date}, D_j.\text{date}]$.
   * **Open Trip:** If no $D_j$ exists $\rightarrow$ Vehicle is currently deployed on road ($[A_i.\text{date}, \text{CURRENT\_DATE}]$).
5. **Yard RFD Invariance:**
   Any date falling in the gap between $D_j.\text{date}$ and $A_{i+1}.\text{date}$, or preceding $A_1.\text{date}$, is formally classified as **RFD (Ready for Deployment)**.

### Fleet Conservation Invariant

Across the entire fleet at any point in time $t$:
$$\text{Total Active Fleet (1,623)} = \text{Active on Road (1,139)} + \text{Yard / Workshop (484)}$$

---

## 5. Priority Precedence Rules Engine

When resolving vehicle status on calendar date $D$, the engine strictly enforces three priority tiers:

```
+-----------------------------------------------------------------------+
|                PRIORITY 1: IS VEHICLE IN THE WORKSHOP?                |
|      Check core_maintenance: start_date <= D AND end_date >= D        |
+-----------------------------------+-----------------------------------+
                                    |
                    +---------------+---------------+
                   YES                              NO
                    |                               |
                    v                               v
       +------------------------+      +--------------------------------+
       | STATUS = 'Maintenance' |      | PRIORITY 2: IS CAR IN A TRIP?  |
       | COHORT = 'Off Road'    |      | Check v_vehicle_trip_intervals |
       | RENT   = Waived        |      | start_date <= D AND            |
       +------------------------+      | (end_date IS NULL OR >= D)     |
                                       +----------------+---------------+
                                                        |
                                        +---------------+---------------+
                                       YES                              NO
                                        |                               |
                                        v                               v
                           +------------------------+      +------------------------+
                           | STATUS = 'Active'      |      | STATUS = 'RFD'         |
                           | COHORT = 'On Road'     |      | COHORT = 'In Yard'     |
                           | RENT   = Billable      |      | RENT   = Waived        |
                           +------------------------+      +------------------------+
```

### Precedence Rule Definitions

1. **Priority 1: Workshop Maintenance Override**
   * Trigger: Vehicle has an active entry in `core_maintenance` or an unclosed `Repair and Maintenance` drop-off within 7 days.
   * Status: `'Maintenance'` | Cohort: `'Off Road'`.
   * Rent Rule: `billable_rent_day = FALSE`, `rent_waived_reason = 'WORKSHOP_MAINTENANCE'`.
   * Partner Rule: Driver assignment is cleared (`NULL`) for retail drivers. For `IP` operators, partner attribution is retained while rent billing is stopped.

2. **Priority 2: Active Trip Interval**
   * Trigger: Date $D$ falls within an allocation interval $[\text{trip\_start\_date}, \text{trip\_end\_date}]$.
   * Status: `'Active'` | Cohort: `'On Road'`.
   * Rent Rule: `billable_rent_day = TRUE`.
   * Partner Rule: Assigned to active driver (`partner_id`, `partner_name`, `partner_phone`).

3. **Priority 3: Hub Yard Default (Ready for Deployment)**
   * Trigger: Vehicle is neither undergoing repairs nor assigned to an active trip.
   * Status: `'RFD'` | Cohort: `'In Yard'`.
   * Rent Rule: `billable_rent_day = FALSE`, `rent_waived_reason = 'RFD_IN_YARD'`.
   * Partner Rule: `partner_id = NULL`.

---

## 6. Step-by-Step Operator Runbook

Follow this runbook to operate, deploy, monitor, and troubleshoot the fleet status infrastructure.

### Step 1: Deploy Database Objects
Execute `schema.sql` on the PostgreSQL production database:
```bash
psql -h 35.200.196.113 -U postgres -d postgres -f schema.sql
```
This idempotently creates `core_maintenance`, `core_daily_vehicle_status`, the two views, and the stored procedure.

---

### Step 2: Query Real-Time Fleet Status
To monitor live fleet deployment across all operating cities:
```sql
SELECT 
    city,
    live_status, 
    live_cohort, 
    COUNT(*) AS vehicle_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY city), 2) AS city_share_pct
FROM public.v_current_live_fleet_status
GROUP BY city, live_status, live_cohort
ORDER BY city, vehicle_count DESC;
```

---

### Step 3: Generate Daily Ledger for Target Date
To generate the daily attendance ledger for close-of-business reporting:
```sql
CALL public.sp_generate_daily_vehicle_status('2026-09-09');
```

Verify that exactly 1,623 records were generated:
```sql
SELECT COUNT(*) FROM public.core_daily_vehicle_status WHERE status_date = '2026-09-09';
-- Expected Output: 1623
```

---

### Step 4: Backfill Historical Month
To backfill attendance records across an entire month for historical audits:
```sql
DO $$
DECLARE
    curr_date DATE := '2026-08-01';
    end_date  DATE := '2026-08-31';
BEGIN
    WHILE curr_date <= end_date LOOP
        CALL public.sp_generate_daily_vehicle_status(curr_date);
        curr_date := curr_date + INTERVAL '1 day';
    END LOOP;
END $$;
```

---

### Step 5: Execute Automated Health Check
Run `automation_script.py` to audit database invariants and all 10 edge cases:
```bash
python automation_script.py --audit
```

---

## 7. Production SQL Query Catalog

### 1. Identify Available Yard Inventory by Hub
```sql
SELECT 
    COALESCE(hub_name, 'MAIN_YARD') AS hub,
    car_model,
    COUNT(*) AS available_for_deployment
FROM public.core_daily_vehicle_status
WHERE status_date = CURRENT_DATE
  AND final_status = 'RFD'
GROUP BY hub_name, car_model
ORDER BY available_for_deployment DESC;
```

### 2. Audit Trail for Specific Vehicle
```sql
SELECT 
    status_date,
    final_status,
    cohort,
    partner_id,
    partner_name,
    billable_rent_day,
    rent_waived_reason,
    source_origin
FROM public.core_daily_vehicle_status
WHERE vehicle_number = 'KA51AL1878'
ORDER BY status_date DESC
LIMIT 30;
```

### 3. Drivers with Longest Active Vehicle Custody
```sql
SELECT 
    vehicle_number,
    current_driver_id,
    current_driver_name,
    current_trip_started,
    CURRENT_DATE - current_trip_started AS days_on_road
FROM public.v_current_live_fleet_status
WHERE live_status = 'Active'
ORDER BY days_on_road DESC
LIMIT 20;
```

---

## 8. Nightly Cron Job Configuration

To automate the daily attendance ledger for finance and operations, configure a nightly cron job scheduled at 23:59 IST (18:29 UTC):

```bash
# Edit crontab
crontab -e

# Add execution entry (executes daily at 23:59 IST / 18:29 UTC)
29 18 * * * PGPASSWORD='YOUR_DB_PASSWORD' psql -h 35.200.196.113 -U postgres -d postgres -c "CALL public.sp_generate_daily_vehicle_status(CURRENT_DATE);" >> /var/log/letzryd_daily_status.log 2>&1
```

---

## 9. Automation Script Reference (`automation_script.py`)

The companion Python script provides full CLI capabilities:

| CLI Option | Description | Example Usage |
| :--- | :--- | :--- |
| `--audit` | Performs complete mathematical audit across all 10 edge cases. | `python automation_script.py --audit` |
| `--live` | Displays live operational fleet snapshot by city and cohort. | `python automation_script.py --live` |
| `--generate-date` | Generates and audits daily status for a specific date. | `python automation_script.py --generate-date 2026-09-09` |
| `--backfill` | Sequentially generates daily status across a date range. | `python automation_script.py --backfill 2026-08-01 2026-08-31` |
