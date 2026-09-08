# Master Vehicle Allocation Pipeline: Single Source of Truth (`public.core_vehicle_allocation`)

## 1. Executive Summary & Architecture Overview

The **Master Vehicle Allocation Pipeline** unifies vehicle allocation and driver handover events from two independent production systems into a single, high-performance, real-time Single Source of Truth (SSOT) table in PostgreSQL: **`public.core_vehicle_allocation`**.

### Upstream Source Systems
1. **Google Sheets Operational Pipeline (`public.sheet_vehicle_allocations`)**:
   * Form submissions from fleet operations executives across Bangalore, Hyderabad, and Mumbai hubs.
   * Total volume: 7,143 records (39 columns).
2. **Web Portal Digital Allocation Form (`public.july_allocation_form`)**:
   * Digital vehicle handover workflow containing comprehensive inspection checklists, 4-sided photos, security cheques, FASTag balances, and multi-tier operational approvals.
   * Total volume: 306 records (76 columns), including 51 legacy test/dummy submissions and 255 valid production handovers.

### End-to-End System Architecture

```
+---------------------------------------------------------------------------------------------------+
|                                     OPERATIONAL INTAKE SOURCES                                    |
+----------------------------------------------------+----------------------------------------------+
| 1. Google Sheets Allocation Form                   | 2. Web Portal Allocation & Handover Workflow |
|    (Fleet Operations Field Teams)                  |    (Digital Driver Handover & Inspections)   |
+----------------------------------------------------+----------------------------------------------+
                          |                                                  |
                          | Google Apps Script JDBC Ingestion                | FastAPI Web Portal Backend
                          v                                                  v
+----------------------------------------------------+----------------------------------------------+
| public.sheet_vehicle_allocations                   | public.july_allocation_form                  |
| (7,143 rows - 39 columns)                          | (306 rows - 76 columns)                      |
+----------------------------------------------------+----------------------------------------------+
                          |                                                  |
                AFTER INSERT/UPDATE/DELETE                         AFTER INSERT/UPDATE/DELETE
                [trg_sync_core_allocation_from_sheet]              [trg_sync_core_allocation_from_portal]
                          |                                                  |
                          +------------------------+-------------------------+
                                                   |
                                                   v  (Transactional Advisory Lock: 888999111)
                                 +-----------------------------------+
                                 |     POSTGRESQL TRIGGER ENGINE     |
                                 |  * Gatekeeper Check (Regex/Plates)|
                                 |  * Auto-Merge on Composite Key    |
                                 |  * Gapless Sequence: MAX(id) + 1  |
                                 |  * Clean IST Timestamp Parsing    |
                                 |  * Soft-Delete: is_deleted = TRUE |
                                 +-----------------------------------+
                                                   |
                                                   v  (<10ms Live Latency)
                                 +-----------------------------------+
                                 |        MASTER DESTINATION         |
                                 |  public.core_vehicle_allocation   |
                                 |    (7,230 Consolidated Rows)      |
                                 +-----------------------------------+
                                                   |
                                                   +---------------+
                                                   |               |
                                                   v               v
                                  +--------------------+  +--------------------+
                                  | Active Allocations |  | Soft-Deleted Audit |
                                  | (is_deleted=FALSE) |  | (is_deleted=TRUE)  |
                                  +--------------------+  +--------------------+
```

---

## 2. The 6 Core Architectural Guarantees

1. **Dual-Source Automatic Merging**:
   * Key: `(allocation_date, vehicle_number, partner_id)`.
   * When an allocation is submitted in Google Sheets and subsequently completed on the Web Portal, the triggers detect the existing event and overlay portal inspection data, photos, security cheques, and approval states in place.
   * Provenance is marked as `source_origin = 'MERGED'`, retaining both `sheet_record_id` and `portal_record_id`.

2. **Zero Sequence Burning (Strict 1..N Gapless IDs)**:
   * To prevent counter skips caused by rolled-back transactions or upsert conflicts, triggers acquire a dedicated transaction-level advisory lock (`pg_advisory_xact_lock(888999111)`).
   * New IDs are assigned sequentially using `SELECT COALESCE(MAX(id), 0) + 1`.
   * Guarantees that `MIN(id) = 1`, `MAX(id) = COUNT(*)`, and missing IDs = 0.

3. **Gatekeeper Quality Enforcement**:
   * Normalizes `operator_driver_id` / `driver_id` (correcting historical `'OP'` typos to canonical `'IP'`).
   * Enforces regex pattern `^LETZ(BLR|HYD|MUM|PUN)(IP)?[0-9]{10}$`.
   * Enforces vehicle registration plate length between 8 and 12 alphanumeric characters and non-null `allocation_date`.
   * Automatically isolates and rejects 51 invalid test submissions from `july_allocation_form`.

4. **Permanent Archival & Soft Deletes**:
   * When a row is deleted in `sheet_vehicle_allocations` or `july_allocation_form`, the core row is preserved.
   * Trigger sets `is_deleted = TRUE`, `deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`, and `updated_at = CURRENT_TIMESTAMP`.
   * Ensures zero historical data loss for Hisaab audit trails and vehicle tenure tracking.

5. **Clean Indian Standard Time (IST) Timestamps**:
   * All timestamp fields are stored as `TIMESTAMP WITHOUT TIME ZONE` normalized to Asia/Kolkata.
   * Completely avoids UTC `+05:30` offset shifts that lead to day-boundary discrepancies.

6. **Defensive Ingestion & String Bounding**:
   * Text fields utilize explicit length bounding (`LEFT(..., 100)`, `LEFT(..., 255)`) to eliminate truncation runtime failures.

---

## 3. Verified 19 Column Mappings

The table consolidates all attributes from `sheet_vehicle_allocations` (39 columns) and `july_allocation_form` (76 columns) using 19 verified semantic mappings:

| # | Google Sheet Column (`sheet_vehicle_allocations`) | Web Portal Column (`july_allocation_form`) | Core Unified Column (`core_vehicle_allocation`) | Data Type | Notes |
|---|---|---|---|---|---|
| 1 | `city` | `city_name` | `city` | `VARCHAR(100)` | Standardized to 'Bengaluru', 'Hyderabad', 'Mumbai', 'Pune' |
| 2 | `operator_driver_id` | `driver_id` | `partner_id` | `VARCHAR(50)` | Corrected 'OP' -> 'IP', validated via regex |
| 3 | `upload_agreement` | `driver_agreement_doc` | `driver_agreement_doc` | `TEXT` | Agreement document cloud storage URL |
| 4 | `front_car_photo` | `photo_front_side` | `photo_front_side` | `TEXT` | Vehicle front photo URL |
| 5 | `back_car_photo` | `photo_back_side` | `photo_back_side` | `TEXT` | Vehicle back photo URL |
| 6 | `lh_car_photo` | `photo_lh_side` | `photo_lh_side` | `TEXT` | Left-hand side exterior photo URL |
| 7 | `rh_car_photo` | `photo_rh_side` | `photo_rh_side` | `TEXT` | Right-hand side exterior photo URL |
| 8 | `driver_with_car_photo` | `vehicle_driver_photo` | `vehicle_driver_photo` | `TEXT` | Handover verification photo URL |
| 9 | `jack` | `insp_jack` | `jack` | `VARCHAR(50)` | Inspection accessory status |
| 10 | `jack_rod_tommy` | `insp_jack_rod` | `jack_rod_tommy` | `VARCHAR(50)` | Inspection accessory status |
| 11 | `spanner_pana` | `insp_spanner` | `spanner_pana` | `VARCHAR(50)` | Inspection accessory status |
| 12 | `stepney_tyre` | `insp_stepney` | `stepney_tyre` | `VARCHAR(50)` | Stepney tyre inspection status |
| 13 | `parking_triangle` | `insp_parking_triangle` | `parking_triangle` | `VARCHAR(50)` | Emergency triangle inspection status |
| 14 | `fire_extinguishers` | `insp_fire_extinguishers` | `fire_extinguishers` | `VARCHAR(50)` | Fire extinguisher presence |
| 15 | `floor_carpet` | `insp_floor_carpet` | `floor_carpet` | `VARCHAR(50)` | Interior floor mats inspection status |
| 16 | `seat_cover` | `insp_seat_cover` | `seat_cover` | `VARCHAR(50)` | Interior upholstery inspection status |
| 17 | `music_system` | `insp_music_system` | `music_system` | `VARCHAR(50)` | Audio system inspection status |
| 18 | `ola_negative_amount` | `ola_negative_balance` | `ola_negative_balance` | `NUMERIC(12, 2)` | Initial negative balance liability |
| 19 | `ola_negative_amount_ss` | `ola_negative_balance_proof` | `ola_negative_balance_proof` | `TEXT` | Screenshot proof URL |

---

## 4. Master Table DDL Reference (`public.core_vehicle_allocation`)

```sql
CREATE TABLE public.core_vehicle_allocation (
    id BIGSERIAL PRIMARY KEY,

    -- Provenance & Lineage
    source_origin VARCHAR(50) NOT NULL, -- 'GOOGLE_SHEET', 'PORTAL_FORM', 'MERGED'
    sheet_record_id BIGINT,             -- Pointer to sheet_vehicle_allocations.id
    portal_record_id INTEGER,           -- Pointer to july_allocation_form.id

    -- Core Allocation Identifiers
    allocation_date DATE NOT NULL,
    vehicle_number VARCHAR(20) NOT NULL,
    partner_id VARCHAR(50) NOT NULL,
    driver_phone VARCHAR(20) NOT NULL,
    driver_name VARCHAR(255) NOT NULL,
    city VARCHAR(100) NOT NULL,
    allocation_type VARCHAR(100) NOT NULL,
    sub_type VARCHAR(100),
    car_model VARCHAR(100),
    hub_name VARCHAR(100),

    -- Plan & Commercial Details
    driver_plan VARCHAR(100),
    type_of_plan VARCHAR(100),
    rental_plan VARCHAR(100),
    partner_type VARCHAR(50),

    -- Telematics & Vehicle State
    odometer_reading INTEGER,
    gps_active VARCHAR(10),
    duplicate_key_status VARCHAR(10),

    -- Financial Balances & Penalties
    ola_negative_balance NUMERIC(12, 2),
    ola_negative_balance_proof TEXT,
    fastag_balance_amount NUMERIC(12, 2),
    fastag_balance_proof TEXT,
    damage_penalty NUMERIC(12, 2),
    deposit_refund_status VARCHAR(50),
    pending_dues NUMERIC(12, 2),

    -- Documents & Media
    driver_agreement_doc TEXT,
    photo_front_side TEXT,
    photo_back_side TEXT,
    photo_lh_side TEXT,
    photo_rh_side TEXT,
    vehicle_driver_photo TEXT,
    battery_photo TEXT,
    odometer_photo TEXT,
    police_verification_doc TEXT,
    insp_stepney_photo TEXT,
    customer_address TEXT,

    -- Security Cheques
    security_cheque_1 TEXT,
    security_cheque_2 TEXT,
    security_cheque_3 TEXT,
    security_cheque_4 TEXT,
    security_cheques TEXT,

    -- Toolkit & Accessories Inspection
    jack VARCHAR(50),
    jack_rod_tommy VARCHAR(50),
    spanner_pana VARCHAR(50),
    stepney_tyre VARCHAR(50),
    parking_triangle VARCHAR(50),
    fire_extinguishers VARCHAR(50),
    floor_carpet VARCHAR(50),
    seat_cover VARCHAR(50),
    music_system VARCHAR(50),
    insp_remarks TEXT,

    -- Vehicle Swap & Drop-Off Return Audit
    old_vehicle_number VARCHAR(50),
    dropoff_odometer NUMERIC(12, 2),
    dropoff_remarks TEXT,
    dropoff_photo TEXT,
    dropoff_location VARCHAR(50),
    manual_dropoff_location TEXT,
    jama_form_filled BOOLEAN,
    pdi_completed BOOLEAN,
    ret_jack VARCHAR(30),
    ret_jack_rod VARCHAR(30),
    ret_spanner VARCHAR(30),
    ret_parking_triangle VARCHAR(30),
    ret_fire_extinguishers VARCHAR(30),
    ret_seat_cover VARCHAR(30),
    ret_floor_carpet VARCHAR(30),
    ret_music_system VARCHAR(30),
    ret_insp_remarks TEXT,

    -- Operational & Workflow Approvals
    status VARCHAR(50) DEFAULT 'Submitted',
    created_by INTEGER,
    updated_by INTEGER,
    current_approver_id INTEGER,
    approval_status VARCHAR(50),
    approved_by INTEGER,
    approval_remarks TEXT,
    reason_to_visit VARCHAR(255),
    vehicle_manager_poc VARCHAR(100),
    submitter_email VARCHAR(255),
    sheet_row_number INTEGER,

    -- Temporal Audit Fields (Clean IST without +05:30)
    submission_timestamp TIMESTAMP WITHOUT TIME ZONE,
    event_date_time TIMESTAMP WITHOUT TIME ZONE,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
);

-- Performance & Uniqueness Indexes
CREATE UNIQUE INDEX uq_cva_sheet_record_id ON public.core_vehicle_allocation (sheet_record_id) WHERE sheet_record_id IS NOT NULL;
CREATE UNIQUE INDEX uq_cva_alloc_event ON public.core_vehicle_allocation (allocation_date, vehicle_number, partner_id);
CREATE INDEX idx_cva_alloc_date_veh ON public.core_vehicle_allocation (allocation_date, vehicle_number);
CREATE INDEX idx_cva_partner_id ON public.core_vehicle_allocation (partner_id);
CREATE INDEX idx_cva_alloc_date_partner ON public.core_vehicle_allocation (allocation_date, partner_id);
CREATE INDEX idx_cva_veh_num ON public.core_vehicle_allocation (vehicle_number);
CREATE INDEX idx_cva_driver_phone ON public.core_vehicle_allocation (driver_phone);
CREATE INDEX idx_cva_city ON public.core_vehicle_allocation (city);
CREATE INDEX idx_cva_source_origin ON public.core_vehicle_allocation (source_origin);
CREATE INDEX idx_cva_active ON public.core_vehicle_allocation (is_deleted);
CREATE INDEX idx_cva_portal_id ON public.core_vehicle_allocation (portal_record_id);
```

---

## 5. Live Synchronization Triggers

Native database triggers handle live events across both source tables:

```sql
-- Trigger on sheet_vehicle_allocations
CREATE TRIGGER trg_sync_core_allocation_from_sheet
AFTER INSERT OR UPDATE OR DELETE ON public.sheet_vehicle_allocations
FOR EACH ROW EXECUTE FUNCTION public.sync_core_allocation_from_sheet();

-- Trigger on july_allocation_form
CREATE TRIGGER trg_sync_core_allocation_from_portal
AFTER INSERT OR UPDATE OR DELETE ON public.july_allocation_form
FOR EACH ROW EXECUTE FUNCTION public.sync_core_allocation_from_portal();
```

---

## 6. Automation & Verification Script (`automation_script.py`)

The companion automation engine provides command-line verification and health check capabilities:

### Usage

```bash
# 1. Run full database health audit
python automation_script.py --audit

# 2. Execute full historical backfill procedure
python automation_script.py --backfill

# 3. Test live trigger operations (INSERT, UPDATE, MERGE, SOFT-DELETE)
python automation_script.py --verify-triggers
```

### Verified Audit Results

```
=================================================================
      CORE VEHICLE ALLOCATION HEALTH & RECONCILIATION AUDIT      
=================================================================

1. Upstream Source Volume:
   - Google Sheets (sheet_vehicle_allocations) : 7,143 rows
   - Web Portal    (july_allocation_form)       : 306 rows (Valid: 255, Test/Rejected: 51)

2. Master Table Volume (core_vehicle_allocation):
   - Total Records     : 7,230
   - Active Records    : 7,230
   - Soft-Deleted Rows : 0

3. Provenance Distribution (source_origin):
   - GOOGLE_SHEET       : 6,987 rows
   - MERGED             : 156 rows
   - PORTAL_FORM        : 87 rows

4. City Distribution (Standardized):
   - Bengaluru          : 4,306 rows
   - Mumbai             : 1,622 rows
   - Hyderabad          : 1,302 rows

5. Allocation Type Distribution (Standardized):
   - New Allocation     : 5,643 rows
   - Reallocation       : 1,143 rows
   - Car Swap           : 379 rows
   - Drop-Off           : 65 rows

6. ID Sequence Continuity Integrity:
   - ID Range          : 1 to 7,230
   - Total Rows        : 7,230
   - Sequence Gaps     : 0
   - Gapless Status    : PASSED (Continuous 1..N Sequence, Zero Gaps)

7. Timestamp Integrity:
   - Timestamp Columns : created_at, deleted_at, event_date_time, submission_timestamp, updated_at
   - Types Compliance  : PASSED (All TIMESTAMP WITHOUT TIME ZONE)

=================================================================
                      AUDIT COMPLETE                             
=================================================================
```
