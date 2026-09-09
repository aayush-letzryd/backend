# Fleet Maintenance Single Source of Truth: public.core_maintenance

## 1. Overview & Business Objectives

In fleet operations, accurate vehicle downtime tracking is critical for fleet utilization, driver rent billing (Hisaab), and preventive maintenance management. The table `public.core_maintenance` serves as the centralized, authoritative Single Source of Truth consolidating all workshop downtime across LetzRyd operations.

Prior to the deployment of `core_maintenance`, fleet repairs were tracked across disparate channels:
- **Google Sheets Operational Trackers** (`sheet_vehicle_status` and `sheet_maintenance`): Updated manually by city fleet managers, subject to human typographical errors, ambiguous date formats, and missing exit timestamps.
- **LetzRyd Web Portal Workflows** (`july_maintenance_in` and `july_maintenance_out`): Structured digital workflows with inward check-in, repair categorization, estimated delivery dates, workshop billing, and outward Ready-for-Deployment (RFD) inspections.

### Key Architectural Guarantees:
- **Unified Master Table**: Consolidates both portal and sheet maintenance events into a single temporal ledger.
- **Inward & Outward Pairing**: Couples vehicle inward check-in with outward workshop release to produce closed temporal intervals `[start_date, end_date]`.
- **Zero Negative Durations**: Enforces the invariant `end_date >= start_date` at both trigger and batch levels.
- **Real-Time Synchronization**: Native PostgreSQL triggers propagate inserts, updates, and soft-deletes within milliseconds.
- **Audit & Financial Traceability**: Tracks initial estimates against final invoiced costs, job card numbers, and upstream foreign keys.

---

## 2. System Architecture & Ingestion Flow

```
                      +-----------------------------+
                      |   Google Sheets Staging     |
                      |  (public.sheet_maintenance) |
                      +--------------+--------------+
                                     |
                                     | trg_sync_core_maintenance_from_sheet
                                     v
+------------------------+      +----+---------------------+      +-------------------------+
|   Web Portal Inward    | ---> |                          | <--- |   Web Portal Outward    |
| (july_maintenance_in)  |      |  public.core_maintenance |      | (july_maintenance_out)  |
+------------------------+      |  (Production Master)     |      +-------------------------+
             |                  +----+---------------------+                   |
             |                               ^                                 |
             +-------------------------------+---------------------------------+
               trg_sync_core_maintenance_portal_in / portal_out
```

### Data Pipeline Stages:
1. **Inward Check-In**: When a vehicle breaks down or enters a workshop, an inward record is created in `july_maintenance_in` (or logged in `sheet_maintenance`). The trigger initiates an `IN_PROGRESS` maintenance event in `core_maintenance` with `end_date = NULL`.
2. **Repair & Invoicing**: The workshop executes repairs. The portal records estimated amounts, repair categories, and insurance claim details.
3. **Outward Release (RFD)**: Upon completion, an outward ticket is logged in `july_maintenance_out` with the vehicle release date, invoice number, and final payable amount. The trigger pairs this outward record with the inward entry, setting `end_date`, `status = 'COMPLETED'`, and updating `actual_cost`.
4. **Periodic Reconciliation**: The stored procedure `refresh_core_maintenance()` executes daily to reconcile unlinked entries, clamp inverted dates, and ensure temporal consistency.

---

## 3. Database Schema Specification

### 3.1 DDL Definition (`public.core_maintenance`)

```sql
CREATE TABLE IF NOT EXISTS public.core_maintenance (
    id BIGSERIAL PRIMARY KEY,
    vehicle_number VARCHAR(20) NOT NULL,
    city VARCHAR(20) NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE,
    status VARCHAR(30) NOT NULL DEFAULT 'IN_PROGRESS',
    workshop_name VARCHAR(150),
    job_card_number VARCHAR(100),
    maintenance_reason TEXT,
    estimated_cost NUMERIC(12, 2) DEFAULT 0.00,
    actual_cost NUMERIC(12, 2) DEFAULT 0.00,
    data_source VARCHAR(50) NOT NULL,
    portal_maintenance_in_id INTEGER,
    portal_maintenance_out_id INTEGER,
    sheet_maintenance_id BIGINT,
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
```

### 3.2 Column Dictionary

| Column Name | Data Type | Nullable | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `id` | BIGSERIAL | NO | `nextval(...)` | Canonical primary key. Gapless sequential identifier. |
| `vehicle_number` | VARCHAR(20) | NO | None | Standardized uppercase registration number without spaces (e.g. `TS09CD2002`). |
| `city` | VARCHAR(20) | NO | None | Canonical operational city (`Bengaluru`, `Hyderabad`, `Mumbai`, `Pune`, `Delhi`). |
| `start_date` | DATE | NO | None | Date the vehicle entered the workshop for maintenance. |
| `end_date` | DATE | YES | `NULL` | Date the vehicle exited the workshop / was marked Ready for Deployment (RFD). `NULL` indicates open maintenance. |
| `status` | VARCHAR(30) | NO | `'IN_PROGRESS'` | Current state of repair: `'IN_PROGRESS'` or `'COMPLETED'`. |
| `workshop_name` | VARCHAR(150) | YES | `NULL` | Name of the servicing workshop or hub garage. |
| `job_card_number` | VARCHAR(100) | YES | `NULL` | Workshop job card number, invoice reference, or insurance claim identifier. |
| `maintenance_reason` | TEXT | YES | `NULL` | Description of breakdown, repair type, or mechanical diagnosis. |
| `estimated_cost` | NUMERIC(12, 2) | YES | `0.00` | Initial cost estimate quoted at vehicle entry. |
| `actual_cost` | NUMERIC(12, 2) | YES | `0.00` | Final invoiced amount or net LetzRyd payable liability upon release. |
| `data_source` | VARCHAR(50) | NO | None | Provenance indicator: `'PORTAL_MAINTENANCE'` or `'SHEET_STATUS_EXTRACT'`. |
| `portal_maintenance_in_id` | INTEGER | YES | `NULL` | Foreign key referencing `public.july_maintenance_in(id)`. |
| `portal_maintenance_out_id` | INTEGER | YES | `NULL` | Foreign key referencing `public.july_maintenance_out(id)`. |
| `sheet_maintenance_id` | BIGINT | YES | `NULL` | Foreign key referencing `public.sheet_maintenance(id)`. |
| `is_deleted` | BOOLEAN | YES | `FALSE` | Soft-delete flag. Set to `TRUE` if upstream source row is deleted. |
| `deleted_at` | TIMESTAMP | YES | `NULL` | Timestamp when record was soft-deleted. |
| `created_at` | TIMESTAMP | YES | `CURRENT_TIMESTAMP` | Audit timestamp when record was first inserted into core. |
| `updated_at` | TIMESTAMP | YES | `CURRENT_TIMESTAMP` | Audit timestamp when record was last updated. |

### 3.3 Indexes & Performance Constraints

```sql
CREATE INDEX IF NOT EXISTS idx_cm_vehicle_dates ON public.core_maintenance (vehicle_number, start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_cm_status ON public.core_maintenance (status);
CREATE INDEX IF NOT EXISTS idx_cm_data_source ON public.core_maintenance (data_source);
CREATE INDEX IF NOT EXISTS idx_cm_city ON public.core_maintenance (city);
CREATE INDEX IF NOT EXISTS idx_cm_is_deleted ON public.core_maintenance (is_deleted);

CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_cm_portal_in 
    ON public.core_maintenance (portal_maintenance_in_id) 
    WHERE portal_maintenance_in_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_cm_sheet_id 
    ON public.core_maintenance (sheet_maintenance_id) 
    WHERE sheet_maintenance_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cm_portal_out 
    ON public.core_maintenance (portal_maintenance_out_id) 
    WHERE portal_maintenance_out_id IS NOT NULL;
```

---

## 4. Portal-to-Sheet Unification Logic

### 4.1 Inward and Outward Pairing
1. **Primary Linking via `inward_id`**: Each outward record in `july_maintenance_out` holds a foreign key `inward_id` pointing directly to `july_maintenance_in(id)`. When an outward record is inserted, the trigger matches this `inward_id` and updates the existing `core_maintenance` record.
2. **Fallback Pairing Heuristic**: If `inward_id` is omitted in the outward submission, the system searches for the most recent open `IN_PROGRESS` maintenance event for that vehicle:
   ```sql
   SELECT id FROM public.july_maintenance_in
   WHERE fn_clean_maintenance_vehicle(vehicle_number) = v_clean_veh
     AND is_closed = FALSE
   ORDER BY id DESC LIMIT 1;
   ```
3. **Standalone Outward Entries**: If an outward record cannot be paired with any inward record, a completed maintenance interval is created with `start_date = end_date` and `workshop_name = 'Direct Outward Maintenance'`.

### 4.2 Cross-Source Conflict Resolution
When the same vehicle repair event is documented in both Google Sheets and the Web Portal:
- **Priority Rule**: The Web Portal record (`data_source = 'PORTAL_MAINTENANCE'`) takes precedence over Google Sheets extracts (`data_source = 'SHEET_STATUS_EXTRACT'`).
- **Deduplication**: If a Google Sheets entry matches a Portal event on `(vehicle_number, start_date)`, the Portal event remains the active master record, preventing duplicate counting of downtime days in downstream billing.

---

## 5. Interval Calculation Rules & State Machine

### 5.1 Maintenance State Transitions

```
[Vehicle Breakdown / Check-in]
             |
             v
   +--------------------+
   |    IN_PROGRESS     |  (start_date NOT NULL, end_date NULL)
   +--------------------+
             |
             | [Workshop Outward Release / RFD]
             v
   +--------------------+
   |     COMPLETED      |  (start_date NOT NULL, end_date NOT NULL)
   +--------------------+
```

### 5.2 Temporal Rules
1. **Zero Negative Duration**:
   If an outward date precedes an inward date due to a human input typo, the system clamps the interval to prevent negative duration:
   $$\text{end\_date} = \max(\text{end\_date}, \text{start\_date})$$
2. **Open Interval Handling**:
   A vehicle with `status = 'IN_PROGRESS'` and `end_date = NULL` is actively considered under maintenance. If the vehicle subsequently receives an active allocation in `public.core_vehicle_allocation` on date $T_{\text{alloc}} > \text{start\_date}$, the maintenance event is closed with $\text{end\_date} = T_{\text{alloc}} - 1$.

---

## 6. Database Trigger Specifications

### 6.1 `sync_core_maintenance_from_sheet()`
- **Target**: `public.sheet_maintenance`
- **Events**: `AFTER INSERT OR UPDATE OR DELETE`
- **Operations**:
  - **DELETE**: Soft-deletes matching record in `core_maintenance` (`is_deleted = TRUE`, `deleted_at = CURRENT_TIMESTAMP`).
  - **INSERT / UPDATE**: Normalizes vehicle number, cleans city name, validates dates, sets status to `'COMPLETED'` if `end_date` is populated, and upserts into `core_maintenance` matching on `sheet_maintenance_id`.

### 6.2 `sync_core_maintenance_from_portal()`
- **Targets**: `public.july_maintenance_in` and `public.july_maintenance_out`
- **Events**: `AFTER INSERT OR UPDATE OR DELETE`
- **Operations on `july_maintenance_in`**:
  - Inward check-in creates or updates `core_maintenance` with `portal_maintenance_in_id = NEW.id`.
  - Parses `vehicle_in_date_time` to extract clean `start_date`.
  - Normalizes `estimated_amount` to numeric `estimated_cost`.
- **Operations on `july_maintenance_out`**:
  - Outward release updates matched `core_maintenance` record.
  - Sets `end_date`, `portal_maintenance_out_id = NEW.id`, `status = 'COMPLETED'`.
  - Populates `actual_cost` from `letzryd_payable` or `invoice_amount`.
  - If outward record is deleted, reopens the maintenance interval (`end_date = NULL`, `status = 'IN_PROGRESS'`).

---

## 7. Backfill Procedure Specification: `refresh_core_maintenance()`

The consolidation procedure executes the following sequential steps:
1. **Advisory Lock Acquisition**: Obtains transactional lock `pg_advisory_xact_lock(777666555)` ensuring isolated execution.
2. **Phase 1 (Portal Processing)**: Iterates over all rows in `july_maintenance_in`, pairs matching rows in `july_maintenance_out`, and upserts into `core_maintenance`. Processes orphaned outward rows.
3. **Phase 2 (Sheet Ingestion)**: Ingests all records from `sheet_maintenance` into `core_maintenance` with `data_source = 'SHEET_STATUS_EXTRACT'`.
4. **Phase 3 (Sanitization)**: Clamps any inverted dates where `end_date < start_date` to `end_date = start_date`, and ensures status consistency across all rows.

---

## 8. Operational Health Check Engine (`automation_script.py`)

The companion Python script provides command-line utilities for database auditing, consolidation, and trigger verification.

### Command Reference:

```bash
# Run comprehensive health and integrity audit
python automation_script.py --audit

# Execute full consolidation backfill procedure
python automation_script.py --backfill

# Test trigger synchronization with rollback
python automation_script.py --verify-triggers

# Repair inverted dates and status inconsistencies
python automation_script.py --repair-intervals
```

### Environment Variables:
- `DB_HOST`: PostgreSQL host (Default: `35.200.196.113`)
- `DB_PORT`: PostgreSQL port (Default: `5432`)
- `DB_NAME`: Database name (Default: `postgres`)
- `DB_USER`: Database user (Default: `postgres`)
- `DB_PASSWORD`: Database password

---

## 9. Operational SQL Queries for Fleet Management

### Query 1: Vehicles Currently in Workshop (Active Downtime)
```sql
SELECT 
    cm.id,
    cm.vehicle_number,
    cm.city,
    cm.start_date,
    cm.workshop_name,
    cm.maintenance_reason,
    cm.estimated_cost,
    (CURRENT_DATE - cm.start_date) AS days_in_shop
FROM public.core_maintenance cm
WHERE cm.is_deleted = FALSE
  AND cm.status = 'IN_PROGRESS'
  AND cm.end_date IS NULL
ORDER BY cm.start_date ASC;
```

### Query 2: Workshop Turnaround Time (TAT) and Expense Summary
```sql
SELECT 
    COALESCE(workshop_name, 'Unknown Workshop') AS workshop_name,
    city,
    COUNT(*) AS total_jobs,
    COUNT(*) FILTER (WHERE status = 'IN_PROGRESS') AS active_jobs,
    COUNT(*) FILTER (WHERE status = 'COMPLETED') AS completed_jobs,
    ROUND(AVG(CASE WHEN end_date IS NOT NULL THEN (end_date - start_date) ELSE NULL END), 1) AS avg_tat_days,
    ROUND(SUM(estimated_cost), 2) AS total_estimated_cost,
    ROUND(SUM(actual_cost), 2) AS total_actual_cost,
    ROUND(SUM(actual_cost) - SUM(estimated_cost), 2) AS cost_variance
FROM public.core_maintenance
WHERE is_deleted = FALSE
GROUP BY COALESCE(workshop_name, 'Unknown Workshop'), city
ORDER BY total_jobs DESC;
```

### Query 3: Maintenance History for a Specific Vehicle
```sql
SELECT 
    id,
    start_date,
    end_date,
    status,
    COALESCE(end_date - start_date, CURRENT_DATE - start_date) AS downtime_days,
    workshop_name,
    job_card_number,
    maintenance_reason,
    estimated_cost,
    actual_cost,
    data_source
FROM public.core_maintenance
WHERE vehicle_number = 'TS09CD2002'
  AND is_deleted = FALSE
ORDER BY start_date DESC;
```
