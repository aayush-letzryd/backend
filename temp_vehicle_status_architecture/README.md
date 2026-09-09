# Vehicle Status & Daily Fleet Ledger Architecture

## 1. Executive Summary & Core Philosophy

This document provides the complete, production-ready architecture and implementation guide for the **Vehicle Status Engine** and **Daily Fleet Ledger** (`core_daily_vehicle_status`).

### The Fundamental Rule
**Vehicle Status is NOT a form that anyone fills manually.** 

In fleet management, the operational status of any vehicle on any given day is simply the mathematical result of three distinct events:
1. **Allocation Form (Trip Start):** When a driver picks up the keys.
2. **Drop-off Form (Trip End):** When the driver returns the keys to a hub.
3. **Maintenance Event (Repair):** When the car enters or exits a workshop.

> **Formula:** `Vehicle Status = Allocation (Start) + Drop-off (End) + Maintenance (Repairs)`

The operations team's Daily Status Tracker Google Sheet is **not an independent competing source of truth**; it is simply a downstream summary generated from the allocation and drop-off forms.

---

## 2. The 3 Data Pillars (Where Everything Comes From)

To determine the status of every vehicle on every calendar date, the engine reads from 3 unified pillars:

```
┌────────────────────────────────────────────────────────────────────────┐
│               PILLAR 1: MASTER ASSET REGISTRY (DENOMINATOR)            │
│                       public.core_vehicle_onboarding                   │
│  - Total physical fleet owned or leased (1,623 active vehicles)        │
│  - Registration No, Model, Make, City, Default Hub                     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
       ┌────────────────────────────┴────────────────────────────┐
       ▼                                                         ▼
┌──────────────────────────────┐              ┌──────────────────────────────────┐
│   PILLAR 2: TRIP STARTS      │              │      PILLAR 3: TRIP ENDS         │
│  public.core_vehicle_        │              │     public.core_dropoffs         │
│         allocation           │              │  - Return Date & Hub Location    │
│  - Pickup Date & Driver ID   │              │  - Final Liabilities & Odometer  │
│  - Merges Sheet + Portal     │              │  - Merges Sheet + Portal         │
└──────────────┬───────────────┘              └──────────────────┬───────────────┘
               │                                                 │
               └───────────────────────┬─────────────────────────┘
                                       │
                                       ▼
       ┌─────────────────────────────────────────────────────────────────┐
       │                 PILLAR 4: WORKSHOP & MAINTENANCE                │
       │                     public.core_maintenance                     │
       │  - Merges Portal Maintenance: july_maintenance_in / out         │
       │  - Merges Sheet Maintenance: downtime rows from Daily Sheet     │
       │  - Start Date, End Date, Workshop Name, In-Progress Status      │
       └───────────────────────────────┬─────────────────────────────────┘
                                       │
                                       ▼
       ┌─────────────────────────────────────────────────────────────────┐
       │                  LAYER 3: MASTER ATTENDANCE LEDGER              │
       │                  public.core_daily_vehicle_status               │
       │    1 Row per Vehicle per Calendar Date (Single Source of Truth) │
       │    Read by Hisaab for Billing & Operations for Live Status      │
       └─────────────────────────────────────────────────────────────────┘
```

### Table Roles Breakdown

| Layer / Role | Source Table(s) | Destination Table | Purpose |
| :--- | :--- | :--- | :--- |
| **Fleet Denominator** | `sheet_vehicle_onboarding`<br>`july_vehicle_onboarding` | `public.core_vehicle_onboarding` | Base asset catalog of all 1,623 cars |
| **Trip Starts** | `sheet_vehicle_allocations`<br>`july_allocation_form` | `public.core_vehicle_allocation` | Exact date, time, and driver of pickup |
| **Trip Ends** | `sheet_dropoffs`<br>`july_vehicle_dropoffs` | `public.core_dropoffs` | Exact date, time, and return liabilities |
| **Repairs & Workshop** | `july_maintenance_in` / `out`<br>`sheet_vehicle_status` (Maint rows) | `public.core_maintenance` | Unified workshop downtime (rent-waived periods) |
| **Master Attendance Ledger** | All 3 Core Event Tables | `public.core_daily_vehicle_status` | 1 row per car per day: Single source of truth for Hisaab & Dashboards |

---

## 3. The Continuous Vehicle Interval Model

Every vehicle in the fleet moves through a continuous timeline of time intervals:

```
Timeline: Jan 01 ────────── Jan 10 ────────────── Jan 25 ────────── Jan 28 ──────────────►
State:    [  RFD in Yard  ] [  Active with Ramesh ] [ RFD in Yard ] [ Active with Suresh ]
Rent:     [    ₹0 Rent    ] [  Daily Rent Billed  ] [   ₹0 Rent   ] [ Daily Rent Billed  ]
Trigger:  (Onboarding)      (Allocation Event)      (Drop-off)      (Allocation Event)
```

### The 3 Operational States
1. **Active (On Road):**
   * The vehicle is currently assigned to a partner.
   * `final_status = 'Active'`, `cohort = 'On Road'`, `partner_id` is populated.
   * **Hisaab Action:** Daily rental liability is billed to the partner.
2. **RFD (Ready for Deployment in Yard):**
   * The vehicle is parked in a LetzRyd hub or yard waiting for a new driver.
   * `final_status = 'RFD'`, `cohort = 'In Yard'`, `partner_id = NULL`.
   * **Hisaab Action:** ₹0 rent charged.
3. **Maintenance (In Workshop):**
   * The vehicle is undergoing repairs, bodywork, or servicing.
   * `final_status = 'Maintenance'`, `cohort = 'Off Road'`.
   * **Hisaab Action:** Rent is waived so drivers are never penalized for downtime.

---

## 4. How the Pairing Engine Works (The Algorithm)

For every vehicle:
1. Fetch all allocations ordered by date: `Allocation 1, Allocation 2, ...`.
2. For each allocation, find the earliest drop-off such that:
   ```
   dropoff.return_date >= allocation.allocation_date
   ```
   and the drop-off occurs before the vehicle's next allocation.
3. This creates a **Trip Interval** `[trip_start_date, trip_end_date]`:
   * **If a matching drop-off exists:** The interval is a **Closed Trip**. The driver had the car from `trip_start_date` to `trip_end_date`.
   * **If no drop-off exists yet:** The interval is an **Open Trip**. The driver has had the car since `trip_start_date` and is **currently active on the road today**.
4. **RFD (Ready for Deployment) Period:** As soon as a vehicle is dropped off, it is immediately **RFD (Ready for Deployment)** sitting in the hub. It remains in RFD with ₹0 rent until either a new allocation happens or a maintenance form is submitted.

### Real Live Numbers (Verified on PostgreSQL)
* Total Onboarded Fleet: **1,623 vehicles**
* Total Historical Allocations: **7,269 trip starts**
* Closed Trips (Paired with Drop-off): **6,128 completed trips**
* Currently Active on Road (Open Allocations): **1,141 vehicles**
* Currently in Yard (RFD) / Maintenance: **482 vehicles** (1,623 total - 1,141 active)

---

## 5. Handling Real-World Edge Cases

### Edge Case 1: Same-Day Drop-off
* **Scenario:** Driver picks up a car at 9:00 AM and returns it at 6:00 PM on the same date.
* **Resolution:** `start_date = end_date`. The trip duration is 0 days (or partial day). Hisaab can charge a half-day or 1-day rental based on company policy.

### Edge Case 2: Intraday Handover (Same Car, Two Drivers on Same Day)
* **Scenario:** Driver Ramesh drops off car KA05... at 10:00 AM. Driver Suresh is allocated the same car at 2:00 PM.
* **Resolution:** 
  * Allocation for Suresh has an exact timestamp later than Ramesh's drop-off.
  * In the daily status table, Suresh is recorded as the ending active driver for that calendar date.
  * Hisaab bills Ramesh up to his drop-off hour and starts Suresh's billing from 2:00 PM onward.

### Edge Case 3: Vehicle Dropped Off with Dues / Damage
* **Scenario:** A driver returns a damaged car with ₹5,000 pending dues.
* **Resolution:** 
  * The moment the drop-off form is submitted, the vehicle immediately transitions to **RFD (Ready for Deployment)** in the hub with ₹0 driver rent.
  * It remains RFD until a workshop executive submits a **Maintenance In** form. Once the maintenance form is submitted, the vehicle transitions from **RFD to Maintenance**. If no maintenance form is submitted, it remains RFD.
  * The driver's financial dues (₹5,000) are routed directly to the Hisaab Settlement Ledger.

---

## 6. Target Database Schema & Code

The complete SQL DDL, views, and stored procedures are in `schema.sql`:

1. **`public.core_maintenance`**: Merges Portal maintenance forms (`july_maintenance_in` / `out`) and Sheet maintenance records into a single workshop downtime table.
2. **`public.core_daily_vehicle_status`**: The master table storing 1 row per car per day (the single source of truth for Hisaab).
3. **`public.v_vehicle_trip_intervals`**: A view that pairs allocations with their corresponding drop-offs across the entire fleet.
4. **`public.v_current_live_fleet_status`**: A real-time view giving operations an instant snapshot of all 1,623 cars right now.
5. **`public.sp_generate_daily_vehicle_status(target_date)`**: A stored procedure that populates the daily ledger for any given date.

---

## 7. Downstream Systems & Integrations

### 1. Automated Hisaab Settlements Engine
```sql
-- Query to calculate driver weekly rent dues:
SELECT 
    partner_id,
    partner_name,
    COUNT(*) AS total_days_billed,
    COUNT(*) * 800 AS rental_due_inr
FROM public.core_daily_vehicle_status
WHERE partner_id = 'LETZBLR9008528502'
  AND status_date BETWEEN '2026-09-01' AND '2026-09-07'
  AND billable_rent_day = TRUE
GROUP BY partner_id, partner_name;
```

### 2. Traffic Challans Driver Attribution
When a traffic challan arrives for vehicle `KA05AQ4847` on `2026-09-06 14:30:00`:
```sql
-- Instantly find which driver had the car at that exact moment:
SELECT partner_id, partner_name, partner_phone
FROM public.v_vehicle_trip_intervals
WHERE vehicle_number = 'KA05AQ4847'
  AND '2026-09-06' BETWEEN trip_start_date AND COALESCE(trip_end_date, CURRENT_DATE);
```

### 3. Live Operations Dashboard
```sql
-- Real-time count of Yard vs Road:
SELECT live_status, live_cohort, COUNT(*) 
FROM public.v_current_live_fleet_status
GROUP BY live_status, live_cohort;
```

---

## 8. Verification & Health Check

A Python verification script is included in this directory:
```bash
# Run the verification script against the database:
python verify_engine.py
```
This tests the live pairing of allocations, drop-offs, and open trips on PostgreSQL and outputs real-time fleet numbers.
