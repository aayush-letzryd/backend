# Master Maintenance Pipeline: Single Source of Truth (`public.core_maintenance`)
**LetzRyd Engineering Blueprint & Table Replication Guide**

---

## 1. Executive Summary & Purpose

The **Master Maintenance Pipeline** unifies LetzRyd's dual operational maintenance intake systems into a single, high-performance, real-time Single Source of Truth (SSOT) table in PostgreSQL: **`public.core_maintenance`**.

### Integrated Source Systems
1. **`public.sheet_maintenance`**: Google Sheets operational maintenance records synchronized via automated 1-minute Apps Script JDBC triggers from the intermediate master sheet (`Unified_Maintenance_source`).
2. **`public.july_maintenance_in`**: LetzRyd Web Portal Inward Maintenance Ticket (capturing repair diagnosis, estimates, approval documents, and damage photos).
3. **`public.july_maintenance_out`**: LetzRyd Web Portal Outward Maintenance Ticket (capturing repair completion, release odometer, invoices, insurance liability deductions, payment UTRs, and repaired vehicle photos).

---

## 2. End-to-End System Architecture

```
+---------------------------------------------------------------------------------------------------+
|                                     OPERATIONAL INTAKE SOURCES                                    |
+------------------------------------+----------------------------------+---------------------------+
| 1. Google Sheets Operations Sheet  | 2. Web Portal Inward Form        | 3. Web Portal Outward Form|
|    (Daily Vehicle Status)          |    (Workshop Intake / Diagnosis) |    (Release / Invoicing)  |
+------------------------------------+----------------------------------+---------------------------+
                  |                                   |                               |
                  | 1-Min Apps Script JDBC            | FastAPI Backend               | FastAPI Backend
                  v                                   v                               v
+------------------------------------+----------------------------------+---------------------------+
| public.sheet_maintenance           | public.july_maintenance_in       | public.july_maintenance_ou|
+------------------------------------+----------------------------------+---------------------------+
                  |                                   |                               |
        AFTER INSERT/UPDATE/DELETE          AFTER INSERT/UPDATE/DELETE      AFTER INSERT/UPDATE/DELETE
        [trg_sync_core_maintenance_from_sheet] [trg_sync_core_maintenance_from_in] [trg_sync_core_maintenance_from_out]
                  |                                   |                               |
                  +-----------------------------------+-------------------------------+
                                                      |
                                                      v  (Transactional Advisory Lock: 888999111)
                                    +-----------------------------------+
                                    |     POSTGRESQL TRIGGER ENGINE     |
                                    |  * Portal Priority Deduplication  |
                                    |  * Gapless Sequence: MAX(id) + 1  |
                                    |  * Inward + Outward Interval Pair |
                                    |  * Non-Negative Duration Clamping |
                                    |  * Soft-Delete: is_deleted = TRUE |
                                    +-----------------------------------+
                                                      |
                                                      v  (<10ms Live Latency)
                                    +-----------------------------------+
                                    |        MASTER DESTINATION         |
                                    |      public.core_maintenance      |
                                    |   (100% History & Full Audit)     |
                                    +-----------------------------------+
                                                      |
                                       +---------------+---------------+
                                       |                               |
                                       v                               v
                      +---------------------------------+  +-------------------------------+
                      |      Live Operations / BI       |  |  Audit & Compliance History   |
                      |   (WHERE is_deleted = FALSE)    |  |  (WHERE is_deleted = TRUE)    |
                      +---------------------------------+  +-------------------------------+
```

---

## 3. The 6 Core Architectural Guarantees

1. **Zero Modifications to Source Systems**:
   - Source tables (`sheet_maintenance`, `july_maintenance_in`, `july_maintenance_out`) remain 100% decoupled and untouched.
2. **Instant Live Synchronization (<10ms)**:
   - Native PostgreSQL database triggers execute immediately `AFTER INSERT OR UPDATE OR DELETE`.
3. **Portal Priority Rule**:
   - When a vehicle maintenance event is recorded on both the Web Portal and Google Sheets, **the Web Portal entry takes precedence** and is enriched with Google Sheet metadata.
4. **Gapless Sequential Primary Keys (`1, 2, 3... N`)**:
   - Concurrency-safe sequence generation via transactional advisory lock (`pg_advisory_xact_lock(888999111)`).
5. **Permanent Archival & Soft Deletes**:
   - Deletions in upstream tables flag `is_deleted = TRUE` and record `deleted_at`, preserving full audit compliance.
6. **Standardized Clean Timestamps (IST without Offset)**:
   - Stored cleanly as `TIMESTAMP WITHOUT TIME ZONE` with default `(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.

---

## 4. Master Schema Data Dictionary (`public.core_maintenance`)

| Column Name | Data Type | Description |
|---|---|---|
| `id` | `BIGINT PRIMARY KEY` | Gapless sequential primary key (`1 .. N`) |
| `source_type` | `VARCHAR(50) NOT NULL` | Data origin: `'WEB_PORTAL'` or `'GOOGLE_SHEET'` |
| `portal_maintenance_in_id` | `INTEGER` | Reference to `july_maintenance_in.id` |
| `portal_maintenance_out_id`| `INTEGER` | Reference to `july_maintenance_out.id` |
| `sheet_maintenance_id` | `BIGINT` | Reference to `sheet_maintenance.id` |
| `vehicle_number` | `VARCHAR(50) NOT NULL` | Standardized alphanumeric vehicle registration number |
| `city` | `VARCHAR(100) NOT NULL` | Canonical operational hub (`Bangalore`, `Mumbai`, `Hyderabad`) |
| `vehicle_location` | `TEXT` | Specific physical hub or workshop address |
| `vehicle_model` | `VARCHAR(150)` | Vehicle OEM model description |
| `start_date` | `DATE NOT NULL` | Maintenance start date |
| `end_date` | `DATE` | Maintenance completion / release date |
| `in_date_time` | `TIMESTAMP WITHOUT TIME ZONE` | Exact inward timestamp |
| `out_date_time` | `TIMESTAMP WITHOUT TIME ZONE` | Exact outward timestamp |
| `estimated_delivery_date` | `DATE` | Workshop promised delivery date |
| `rfd_date` | `DATE` | Ready For Delivery date |
| `maintenance_status` | `VARCHAR(50) NOT NULL` | `'IN_PROGRESS'`, `'COMPLETED_RFD'`, `'COMPLETED'` |
| `cohort` | `VARCHAR(50)` | Fleet deployment cohort (`Off Road`) |
| `partner_name` | `VARCHAR(255)` | Attached driver name |
| `partner_ids` | `VARCHAR(100)` | Driver ID code |
| `dm_name` | `VARCHAR(150)` | Assigned fleet Duty Manager |
| `repair_type` | `VARCHAR(100)` | Repair category (`Accident`, `Periodic Service`, `Running Repair`) |
| `workshop_name` | `VARCHAR(255)` | Service garage / center name |
| `in_kms` | `INTEGER` | Odometer at workshop intake |
| `out_kms` | `INTEGER` | Odometer at workshop release |
| `estimated_amount` | `NUMERIC(12,2)` | Estimated repair cost |
| `invoice_no` | `VARCHAR(100)` | Vendor invoice number |
| `invoice_date` | `DATE` | Vendor invoice date |
| `invoice_amount` | `NUMERIC(12,2)` | Total billed repair cost |
| `insurance_claimed` | `BOOLEAN` | Whether insurance claim was filed |
| `insurance_brokerage` | `VARCHAR(100)` | Insurance broker / company |
| `claim_number` | `VARCHAR(100)` | Insurance claim reference |
| `insurance_liability_discounts` | `NUMERIC(12,2)` | Insurance payout deduction |
| `letzryd_payable` | `NUMERIC(12,2)` | Net payable liability |
| `type_of_payment` | `VARCHAR(100)` | Payment method |
| `payment_status` | `VARCHAR(50)` | Payment status (`Pending`, `Paid`, `Part-Paid`) |
| `utr_no` | `VARCHAR(100)` | Bank transfer UTR number |
| `approved_by` | `VARCHAR(150)` | Approver designation / name |
| `approval_date` | `DATE` | Date of estimate approval |
| `approval_file` | `TEXT` | Cloud URL to approval document |
| `damage_photos` | `TEXT` | Cloud URLs to damage photos |
| `outward_photos` | `TEXT` | Cloud URLs to repaired photos |
| `invoice_file` | `TEXT` | Cloud URL to invoice document |
| `is_deleted` | `BOOLEAN NOT NULL` | Soft-delete flag |
| `deleted_at` | `TIMESTAMP WITHOUT TIME ZONE` | Soft-deletion timestamp |
| `created_at` | `TIMESTAMP WITHOUT TIME ZONE` | Creation timestamp (IST) |
| `updated_at` | `TIMESTAMP WITHOUT TIME ZONE` | Last modification timestamp (IST) |

---

## 5. Operations & Verification Commands

```bash
# 1. Deploy Schema, Triggers, and Stored Procedures
python automation_script.py --deploy

# 2. Run Full Historical Backfill & Rebuild
python automation_script.py --backfill

# 3. Run Live Health Audit
python automation_script.py --audit
```
