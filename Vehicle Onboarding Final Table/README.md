# Master Vehicle Onboarding Pipeline: Single Source of Truth (`public.core_vehicle_onboarding`)
**LetzRyd Engineering Blueprint & Table Replication Guide**

---

## 1. Executive Summary & Purpose

The **Master Vehicle Onboarding Pipeline** unifies two independent, operational vehicle intake systems into a single, high-performance, real-time Single Source of Truth (SSOT) table in PostgreSQL: **`public.core_vehicle_onboarding`**.

### Integrated Source Systems
1. **`public.sheet_vehicle_onboarding`**: Google Sheets entries populated via Google Apps Script JDBC pipeline maintained by Fleet & Ops teams (1,619 records).
2. **`public.july_vehicle_onboarding`**: LetzRyd Web Portal Vehicle Onboarding Form submissions captured via FastAPI backend (8 records).

---

## 2. End-to-End System Architecture

```
+---------------------------------------------------------------------------------------------------+
|                                  OPERATIONAL INTAKE SOURCES                                       |
+-------------------------------------------------+-------------------------------------------------+
| 1. Google Sheets Pipeline                       | 2. Web Portal Vehicle Intake Form               |
|    (Fleet / Ops Field Hubs)                     |    (LetzRyd Web Portal / FastAPI)               |
+-------------------------------------------------+-------------------------------------------------+
                         |                                                 |
                         | Google Apps Script JDBC                         | FastAPI Backend
                         v                                                 v
+-------------------------------------------------+-------------------------------------------------+
| public.sheet_vehicle_onboarding                 | public.july_vehicle_onboarding                  |
+-------------------------------------------------+-------------------------------------------------+
                         |                                                 |
               AFTER INSERT/UPDATE/DELETE                        AFTER INSERT/UPDATE/DELETE
             [trg_sync_core_veh_from_sheet]                    [trg_sync_core_veh_from_portal]
                         |                                                 |
                         +------------------------+------------------------+
                                                  |
                                                  v  (Transactional Advisory Lock: 777999111)
                               +-------------------------------------+
                               |      POSTGRESQL TRIGGER ENGINE      |
                               |  * Gapless Sequence: MAX(id) + 1    |
                               |  * Standardized Plate Clean         |
                               |  * Canonical City Normalization     |
                               |  * Deterministic Portal Precedence  |
                               |  * Soft-Delete: is_deleted = TRUE   |
                               +-------------------------------------+
                                                  |
                                                  v  (<10ms Live Latency)
                               +-------------------------------------+
                               |         MASTER DESTINATION          |
                               |   public.core_vehicle_onboarding    |
                               |     (100% Complete Vehicle SSOT)    |
                               +-------------------------------------+
                                                  |
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
   - Upstream tables (`sheet_vehicle_onboarding`, `july_vehicle_onboarding`) remain 100% untouched.
   - Zero changes to existing Google Apps Script pipelines or FastAPI endpoints.
2. **Instant Live Synchronization (<10ms)**:
   - Native PostgreSQL database triggers execute immediately `AFTER INSERT OR UPDATE OR DELETE`.
   - New fleet additions entered in Google Sheets or approved on the web portal reflect in `core_vehicle_onboarding` in real time.
3. **Deterministic Conflict Priority**:
   - Natural Key = Standardized Registration Number (`registration_no`).
   - If a plate appears in both sources, **Portal Form (`july_vehicle_onboarding`) takes top priority**, while Google Sheet fields enrich non-conflicting operational attributes (PDI status, payment date, ageing, comments).
4. **Gapless Sequential Primary Keys (`1, 2, 3... N`)**:
   - Enforced via transactional advisory locks (`pg_advisory_xact_lock(777999111)`) assigning `SELECT COALESCE(MAX(id), 0) + 1`.
5. **Permanent Archival & Soft Deletes (Zero Data Loss)**:
   - Source deletions trigger `is_deleted = TRUE` and record `deleted_at = NOW()`.
   - No hard data destruction.
6. **Standardized Clean Timestamps (IST without `+05:30`)**:
   - Timestamps stored as `TIMESTAMP WITHOUT TIME ZONE` strictly in Indian Standard Time (`Asia/Kolkata`).

---

## 4. Automation & Verification Commands

To perform health audits and verification:
```bash
# Run Health & Reconciliation Audit
python automation_script.py --audit

# Deploy Schema, Triggers and Run Historical Backfill
python automation_script.py --backfill
```
