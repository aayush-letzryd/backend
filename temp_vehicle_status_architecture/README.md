# Vehicle Status & Daily Fleet Ledger Architecture

## 1. Executive Summary & Objective

This document outlines the end-to-end architecture and implementation blueprint for the **Vehicle Status Engine** and **Daily Fleet Ledger** (`core_daily_vehicle_status`). 

The primary business objective is to create an automated, audit-proof single source of truth for:
1. **Live Fleet Operations:** Knowing the exact operational state of every vehicle at any moment (On Road, Maintenance/Workshop, Ready for Deployment in Yard).
2. **Automated Hisaab Settlements:** Accurately calculating daily driver rental liabilities, waiving rent during maintenance periods, and eliminating double-billing during intraday vehicle handovers.

This design supports all operational modes: whether the team uses **Google Sheets only**, **Web Portal forms only**, or a **hybrid of both**.

---

## 2. High-Level Architecture Diagram

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
  │ 1. core_vehicle_allocation   <- Merges Sheet Allocations + Portal Allocations    │
  │ 2. core_vehicle_dropoff      <- Merges Sheet Drop-offs + Portal Drop-offs        │
  │ 3. core_vehicle_maintenance  <- Merges Portal In/Out + Sheet Maintenance Entries │
  │ 4. sheet_vehicle_status      <- Raw Staging Ingestion of Daily Tracker Sheet     │
  └────────────────────────────────────────┬─────────────────────────────────────────┘
                                           │
                                           ▼
========================================================================================
              LAYER 3: UNIFIED DAILY LEDGER & LIVE STATE (POSTGRESQL)
========================================================================================
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │                          core_daily_vehicle_status                               │
  │   - 1 row per vehicle per calendar date                                          │
  │   - Final Operational Status (Active, Maintenance, RFD, Impounded)               │
  │   - Assigned Driver ID & Driver Name                                             │
  │   - Intraday Allocation & Drop-off Timestamps                                    │
  │   - DM Name, City, Vehicle Model, Hub Location                                   │
  └────────────────────────────────────────┬─────────────────────────────────────────┘
                                           │
                                           ▼
========================================================================================
                       DOWNSTREAM CONSUMERS & AUTOMATION
========================================================================================
  ┌────────────────────────────────────────┐    ┌───────────────────────────────────┐
  │       AUTOMATED HISAAB ENGINE          │    │     LIVE OPERATIONS DASHBOARD     │
  │ Direct SQL Settlement Queries          │    │ Real-time vehicle location & state│
  └────────────────────────────────────────┘    └───────────────────────────────────┘
```

---

## 3. The 3 Data Layers Explained

### Layer 1: Input Sources
Operational data enters through two parallel channels:
1. **Google Sheets:**
   * `sheet_vehicle_allocations`: Logs vehicle allocations.
   * `sheet_dropoffs`: Logs vehicle returns and driver exits.
   * `Daily Status Tracker Sheet`: Daily ops sheet recording fleet snapshot (vehicle, final status, cohort, partner ID, hub).
2. **Web Portal:**
   * `july_allocation_form`: Portal allocations.
   * `july_vehicle_dropoffs`: Portal drop-offs.
   * `july_maintenance_in` / `july_maintenance_out`: Portal workshop check-in/out logs.

### Layer 2: Core Event Tables (Transactional History)
Every physical action is permanently recorded as an event with microsecond timestamps:
* `core_vehicle_allocation`: Built using the Walk-in pipeline pattern (merging `sheet_vehicle_allocations` and `july_allocation_form`).
* `core_vehicle_dropoff`: Built by merging `sheet_dropoffs` and `july_vehicle_dropoffs`.
* `core_vehicle_maintenance`: Built by combining portal maintenance entries with maintenance flags extracted from the daily tracker sheet.
* `sheet_vehicle_status`: Exact staging copy of the daily tracker sheet.

### Layer 3: The Daily Master Ledger (`core_daily_vehicle_status`)
This table acts as the daily attendance register for the fleet. For every single calendar date and vehicle, it records:
* Which driver was responsible for the vehicle.
* What state the vehicle was in (On Road, Maintenance, In Yard / RFD).
* What actions occurred during that day (e.g. dropped off in morning, re-allocated in afternoon).

---

## 4. Daily Data Flow & Precedence Rules

To prevent data corruption, race conditions, or conflicting entries between sheets and portal, the engine follows strict priority rules:

### Rule 1: Maintenance State Takes Highest Priority
* If a vehicle has an active `july_maintenance_in` entry without a corresponding `july_maintenance_out`, OR if the Daily Tracker Sheet marks the vehicle as `Maintenance`:
  * `final_status` = `'Maintenance'`
  * `cohort` = `'Off Road'`
  * `partner_id` = `NULL`
  * Rent is automatically paused in Hisaab.

### Rule 2: Live Drop-offs Terminate Driver Liability
* When a drop-off is recorded on date `D` (via sheet or portal):
  * The driver assignment is marked as completed on date `D`.
  * `dropoff_date` is recorded.
  * Subsequent days are marked as `RFD` (Ready for Deployment) with `partner_id = NULL` until a new allocation occurs.

### Rule 3: Allocation Assigns Driver Liability
* When an allocation is recorded on date `D`:
  * `partner_id`, `partner_name`, `partner_type`, and `plan_type` are populated from `core_vehicle_allocation`.
  * `final_status` = `'Active'`
  * `cohort` = `'On Road'`
  * Hisaab applies daily rental charges to this partner starting from the allocation timestamp.

### Rule 4: Daily Tracker Baseline Fallback
* Every morning, the Daily Tracker Sheet syncs to set the initial daily baseline.
* Any intraday event (Allocation, Drop-off, Maintenance) arriving later in the day updates the daily status row immediately.

---

## 5. Handling Intraday Transitions (Morning vs. Afternoon Changes)

A common fleet scenario occurs when a vehicle changes state twice on the same day:
* **Example:** On 09-Sept at 10:00 AM, Driver A drops off the vehicle. At 3:00 PM, Driver B takes allocation of the same vehicle.

### How the Architecture Handles This:
1. **Permanent Action Audit Log:**
   * `core_vehicle_dropoff` permanently preserves Driver A's return at `10:00 AM`.
   * `core_vehicle_allocation` permanently preserves Driver B's handover at `03:00 PM`.
2. **Daily Ledger Representation (`core_daily_vehicle_status`):**
   * The daily record stores both timestamps:
     * `dropoff_date` = `2026-09-09 10:00:00` (Driver A)
     * `allocation_date` = `2026-09-09 15:00:00` (Driver B)
     * `partner_id` = Driver B (Current active driver at close of day)
3. **Hisaab Billing Impact:**
   * Hisaab reads both events. Depending on company settlement policy (half-day billing or handover rules), Driver A is billed for morning usage and Driver B for afternoon/evening usage with zero ambiguity.

---

## 6. How All Three Operational Scenarios are Solved

| Scenario | Operational Reality | Database Resolution |
| :--- | :--- | :--- |
| **Case 1: Sheets Only** | Ops continues entering data only into Google Sheets. | `core_vehicle_allocation` and `core_vehicle_dropoff` ingest the sheets. Maintenance is extracted from `sheet_vehicle_status`. Everything functions smoothly without portal dependency. |
| **Case 2: Portal Only** | Ops stops using sheets and transitions 100% to the portal. | Portal Allocation, Drop-off, and Maintenance In/Out populate Layer 2 directly. Database triggers generate `core_daily_vehicle_status` autonomously with zero spreadsheets. |
| **Case 3: Mixed Mode (Both)** | Some hubs use portal, others use sheets; or allocations happen in portal while maintenance is marked in sheet. | Layer 2 unifies both sources into clean core tables. The latest timestamp and highest priority rule wins. Neither door interferes with the other. |

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
    cohort VARCHAR(20) NOT NULL,            -- On Road, Off Road
    
    -- Partner & Driver Information
    partner_id VARCHAR(50),                 -- Driver Code / ID
    partner_name VARCHAR(150),
    partner_type VARCHAR(30),               -- Individual, Operator
    dm_name VARCHAR(100),                   -- Duty Manager / Fleet Manager
    vehicle_model VARCHAR(100),
    
    -- Event Lifecycle Timestamps
    allocation_timestamp TIMESTAMP WITHOUT TIME ZONE,
    dropoff_timestamp TIMESTAMP WITHOUT TIME ZONE,
    maintenance_in_timestamp TIMESTAMP WITHOUT TIME ZONE,
    maintenance_out_timestamp TIMESTAMP WITHOUT TIME ZONE,
    
    -- Provenance & Metadata
    source_origin VARCHAR(50) NOT NULL,     -- DAILY_SHEET, PORTAL_EVENT, CORE_MERGE
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_daily_vehicle_status UNIQUE (status_date, vehicle_number)
);

-- Indexes for Query & Hisaab Performance
CREATE INDEX IF NOT EXISTS idx_cdvs_date_partner ON public.core_daily_vehicle_status (status_date, partner_id);
CREATE INDEX IF NOT EXISTS idx_cdvs_vehicle_date ON public.core_daily_vehicle_status (vehicle_number, status_date);
CREATE INDEX IF NOT EXISTS idx_cdvs_status ON public.core_daily_vehicle_status (final_status, status_date);
```

---

## 8. Implementation Roadmap

1. **Phase 1: Ingest Daily Tracker Sheet**
   * Create `public.sheet_vehicle_status` staging table.
   * Write Google Apps Script / Python ETL to ingest the live Daily Tracker Sheet daily.
2. **Phase 2: Build `core_vehicle_allocation`**
   * Merge `sheet_vehicle_allocations` (7,122 rows) and `july_allocation_form` (301 rows).
   * Install row-level PostgreSQL triggers following the Walk-in blueprint.
3. **Phase 3: Build `core_vehicle_dropoff`**
   * Merge `sheet_dropoffs` and `july_vehicle_dropoffs`.
   * Install row-level PostgreSQL triggers.
4. **Phase 4: Build `core_daily_vehicle_status` Engine**
   * Create the daily ledger table.
   * Configure reconciliation triggers to overlay live allocation/drop-off/maintenance events on top of daily sheet snapshots.
5. **Phase 5: Connect Hisaab Settlement Engine**
   * Point all Hisaab billing queries to `core_daily_vehicle_status`.
