# Vehicle Status & Daily Fleet Ledger Architecture

## 1. Executive Summary & Objective

This document outlines the end-to-end architecture and implementation blueprint for the **Vehicle Status Engine** and **Daily Fleet Ledger** (`core_daily_vehicle_status`). 

The primary business objectives are:
1. **Live Fleet Operations:** Knowing the exact operational state of every single vehicle at any moment (On Road with Driver, In Workshop / Maintenance, or Ready for Deployment sitting in a Yard).
2. **Automated Hisaab Settlements:** Accurately calculating daily driver rental liabilities, automatically waiving rent during maintenance/workshop periods, and eliminating double-billing during intraday vehicle handovers.

This design supports all operational modes: whether the team uses **Google Sheets only**, **Web Portal forms only**, or a **hybrid of both**.

---

## 2. What Is Your Source of Vehicles? (Asset Master vs. Daily Status)

A critical distinction must be made between **the car as an asset** and **what the car is doing on any given day**:

```
┌────────────────────────────────────────────────────────┐
│   MASTER ASSET REGISTRY (The Catalog of Vehicles)      │
│            public.core_vehicle_onboarding              │
│  - 1 row per physical car (1,625 vehicles currently)   │
│  - Registration No, Chassis No, Engine No, Make, Model │
│  - Owner Name, City, PDI Date, Fastag ID               │
└───────────────────────────┬────────────────────────────┘
                            │ (Master Denominator of Fleet)
                            ▼
┌────────────────────────────────────────────────────────┐
│     DAILY FLEET LEDGER (What is each car doing today?)  │
│            public.core_daily_vehicle_status            │
│  - 1 row per vehicle per calendar date                 │
│  - Operational State (Active, RFD, Maintenance)        │
│  - Assigned Driver ID & Name (if on road)              │
│  - Hub / Yard Location (if in yard)                    │
└────────────────────────────────────────────────────────┘
```

1. **`core_vehicle_onboarding` is the Master Asset Source (Single Source of Truth for the CAR):**
   * This table represents every car owned, leased, or operated by LetzRyd.
   * A car cannot exist in the daily status engine unless it was onboarded into `core_vehicle_onboarding`.
   * It provides the total denominator of your fleet (e.g. 1,625 total cars).

2. **`core_daily_vehicle_status` is the Daily Attendance / State Calendar:**
   * It is **not** a vehicle catalog. It is a daily operational ledger: `Calendar Date x Active Vehicles`.
   * For every calendar day, it takes every vehicle in `core_vehicle_onboarding` and resolves its exact state on that day.

---

## 3. High-Level Architecture Diagram

```
========================================================================================
                          LAYER 1: INPUT DATA SOURCES
========================================================================================
       GOOGLE SHEETS PIPELINE                           WEB PORTAL PIPELINE
  ┌──────────────────────────────┐              ┌──────────────────────────────────┐
  │ • sheet_vehicle_allocations  │              │ • july_allocation_form           │
  │ • sheet_dropoffs             │              │ • july_vehicle_dropoffs          │
  │ • Daily Status Tracker Sheet │              │ • july_maintenance_in / out     │
  └──────────────┬───────────────┘              └────────────────┬─────────────────┘
                 │                                               │
                 ▼                                               ▼
========================================================================================
                 LAYER 2: CORE TRANSACTIONAL EVENT TABLES (POSTGRESQL)
========================================================================================
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │ 1. core_vehicle_onboarding   <- Master Asset Registry (Denominator of all cars)  │
  │ 2. core_vehicle_allocation   <- Merges Sheet Allocations + Portal Allocations    │
  │ 3. core_dropoffs             <- Merges Sheet Drop-offs + Portal Drop-offs        │
  │ 4. core_accidents            <- Accident & Major Damage Registry                 │
  │ 5. sheet_vehicle_status      <- Raw Staging Ingestion of Daily Tracker Sheet     │
  └────────────────────────────────────────┬─────────────────────────────────────────┘
                                           │
                                           ▼
========================================================================================
              LAYER 3: UNIFIED DAILY LEDGER & LIVE STATE (POSTGRESQL)
========================================================================================
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │                          core_daily_vehicle_status                               │
  │   - 1 row per vehicle per calendar date (e.g. 1,625 rows per day)                │
  │   - Final Operational Status: Active, RFD, Maintenance, Impounded                │
  │   - Assigned Driver ID & Driver Name                                             │
  │   - Intraday Allocation & Drop-off Timestamps                                    │
  │   - Hub Yard Location, Duty Manager, City                                        │
  └────────────────────────────────────────┬─────────────────────────────────────────┘
                                           │
                                           ▼
========================================================================================
                       DOWNSTREAM CONSUMERS & AUTOMATION
========================================================================================
  ┌────────────────────────────────────────┐    ┌───────────────────────────────────┐
  │       AUTOMATED HISAAB ENGINE          │    │     LIVE OPERATIONS DASHBOARD     │
  │ Calculates daily driver rental dues    │    │ Real-time fleet yard & road count │
  │ Pauses rent when car is RFD or in shop │    │ Shows cars ready to deploy        │
  └────────────────────────────────────────┘    └───────────────────────────────────┘
```

---

## 4. The "Ready for Deployment" (RFD) State Machine & Lifecycle

How does a car transition between states? A car in the fleet moves through a continuous circle of operational states:

```
                      ┌────────────────────────────┐
                      │    VEHICLE ONBOARDING      │
                      │ (Car arrives at company)   │
                      └─────────────┬──────────────┘
                                    │
                                    ▼
       ┌────────────────────────────────────────────────────────┐
       │             READY FOR DEPLOYMENT (RFD)                 │
       │  - Location: Hub / Yard                                │
       │  - Driver: NULL (No active driver)                     │
       │  - Hisaab: Zero driver rent charged                    │
       └──────────────┬──────────────────────────▲──────────────┘
                      │                          │
        Driver Takes  │                          │ Driver Returns
          Allocation  │                          │    Car (Drop-off)
                      ▼                          │
       ┌───────────────────────────┐             │
       │      ACTIVE / ON ROAD     │             │
       │ - Driver: Ramesh (Assigned│─────────────┘
       │ - Hisaab: Daily rent billed│
       └──────────────┬────────────┘
                      │
        Accident /    │
     Maintenance Need │
                      ▼
       ┌───────────────────────────┐
       │   MAINTENANCE / WORKSHOP  │
       │ - Location: Workshop      │─────────────┐
       │ - Driver: Paused / None   │             │
       │ - Hisaab: Rent WAIVED     │             │ Repairs Completed
       └───────────────────────────┘             │ (Ready for Yard)
                                                 ▼
                                     Back to RFD in Yard
```

### Operational Definitions:
* **RFD (Ready for Deployment):**
  * The vehicle is parked in a LetzRyd hub or yard.
  * It has completed PDI/inspection, has clean documents, and is physically waiting for an available driver.
  * Driver ID is `NULL`. Hisaab charges ₹0 rental to drivers.
* **Active (On Road):**
  * The vehicle has been handed over to a driver via `core_vehicle_allocation`.
  * The driver is responsible for daily rent, traffic challans, and vehicle safety.
* **Maintenance (Off Road):**
  * The vehicle is in a workshop or undergoing repair.
  * Driver rent is paused or waived so drivers are not unfairly billed for downtime.
* **Accidental / Impounded:**
  * Vehicle is under insurance claim, police custody, or RTO impoundment.

---

## 5. How the Resolution Engine Works Each Day (The 4-Step Priority Hierarchy)

Every night at midnight (or dynamically on query), the system generates or updates the daily status for date `D` across all 1,625 vehicles in `core_vehicle_onboarding`. 

It evaluates the following 4-step precedence hierarchy:

```
Step 1: Check Maintenance / Workshop Events
   │
   ├─► Is the car currently in workshop? (Maintenance In without Maintenance Out, or Accidental)
   │     YES ──► Status = 'Maintenance', Driver = NULL, Rent = WAIVED
   │     NO
   ▼
Step 2: Check Intraday Event Forms (Allocations & Drop-offs)
   │
   ├─► Did an Allocation occur on Date D? (`core_vehicle_allocation`)
   │     YES ──► Status = 'Active', Driver = Allocated Driver, Rent = CHARGED
   │
   ├─► Did a Drop-off occur on Date D? (`core_dropoffs`)
   │     YES ──► Status shifts to 'RFD', Driver = NULL (Previous driver billed only up to return hour)
   │     NO
   ▼
Step 3: Check Daily Tracker Sheet (Ground-Truth Safety Net)
   │
   ├─► Does the Daily Tracker Sheet have an explicit row for this vehicle on Date D?
   │     YES ──► OVERRIDE / BACKFILL with ground-truth entry:
   │             If tracker says "RFD in Hub Bangalore" ──► Status = 'RFD', Driver = NULL
   │             If tracker says "Active with Driver Suresh" ──► Status = 'Active', Driver = Suresh
   │     NO
   ▼
Step 4: Rollover from Previous Day (State Persistence)
   │
   └─► If yesterday the car was 'RFD' in the yard and no event happened today:
         It remains 'RFD' in the yard today!
       If yesterday the car was 'Active' with Driver Ramesh and no drop-off happened today:
         It remains 'Active' with Driver Ramesh today!
```

---

## 6. Real-World Scenarios Solved

### Scenario A: Executive forgets to fill the Drop-off Form
* **What happened on ground:** Driver Ramesh returned his car on Monday evening. The hub executive forgot to fill the drop-off form.
* **How the system handles it:** 
  1. On Tuesday morning, the hub manager fills the Daily Tracker Sheet and marks: *Vehicle KA05...: RFD / In Hub Bangalore, Driver: None*.
  2. The system sees Step 2 has no drop-off form, but **Step 3 (Daily Tracker)** explicitly says the car is sitting in the yard.
  3. The system sets status to **RFD** and stops billing Ramesh for Tuesday.
  4. **Result:** Ramesh is not over-billed, and the fleet dashboard immediately reflects the car as available for a new driver.

### Scenario B: Executive forgets to fill the Allocation Form
* **What happened on ground:** On Wednesday morning, Driver Suresh takes the car. The executive forgets to submit the allocation form.
* **How the system handles it:**
  1. The Daily Tracker Sheet records Suresh as the active driver.
  2. The Daily Tracker backfills the record: status = **Active**, driver = **Suresh**.
  3. Hisaab bills Suresh, and the operations dashboard shows the car as On Road.

### Scenario C: Normal Operations (Forms filled on time)
* **What happened on ground:** All forms are submitted via Web Portal or Google Sheets.
* **How the system handles it:**
  1. Step 2 detects the allocation or drop-off event immediately.
  2. The daily record updates in real time (under 10 milliseconds).
  3. The Daily Tracker simply corroborates the event.

---

## 7. PostgreSQL Target Schema Definition

```sql
-- Target Master Table: public.core_daily_vehicle_status
CREATE TABLE IF NOT EXISTS public.core_daily_vehicle_status (
    id BIGSERIAL PRIMARY KEY,
    status_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(10) NOT NULL,
    
    -- Operational Status
    final_status VARCHAR(30) NOT NULL,      -- Active, RFD, Maintenance, Accidental, Impounded
    cohort VARCHAR(20) NOT NULL,            -- On Road, In Yard, Off Road
    
    -- Partner & Driver Information
    partner_id VARCHAR(50),                 -- Driver Code / ID (NULL if RFD)
    partner_name VARCHAR(150),
    partner_type VARCHAR(30),               -- Individual, Operator
    hub_location VARCHAR(100),              -- Bangalore Yard 1, Hyderabad Hub, etc.
    dm_name VARCHAR(100),                   -- Duty Manager / Fleet Manager
    vehicle_model VARCHAR(100),
    
    -- Event Lifecycle Timestamps
    allocation_timestamp TIMESTAMP WITHOUT TIME ZONE,
    dropoff_timestamp TIMESTAMP WITHOUT TIME ZONE,
    maintenance_in_timestamp TIMESTAMP WITHOUT TIME ZONE,
    maintenance_out_timestamp TIMESTAMP WITHOUT TIME ZONE,
    
    -- Provenance & Metadata
    source_origin VARCHAR(50) NOT NULL,     -- EVENT_TRIGGER, DAILY_TRACKER_BACKFILL, STATE_ROLLOVER
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_daily_vehicle_status UNIQUE (status_date, vehicle_number),
    CONSTRAINT fk_daily_status_vehicle FOREIGN KEY (vehicle_number) 
        REFERENCES public.core_vehicle_onboarding(registration_no)
);

-- Indexes for Fast Queries & Hisaab Settlements
CREATE INDEX IF NOT EXISTS idx_cdvs_date_partner ON public.core_daily_vehicle_status (status_date, partner_id);
CREATE INDEX IF NOT EXISTS idx_cdvs_vehicle_date ON public.core_daily_vehicle_status (vehicle_number, status_date);
CREATE INDEX IF NOT EXISTS idx_cdvs_status ON public.core_daily_vehicle_status (final_status, status_date);
```
