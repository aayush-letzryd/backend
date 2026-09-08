# Walk-in Final Table (`public.core_walkin`)

## 1. Overview
`public.core_walkin` is the unified master single source of truth for all driver and partner walk-in event records at LetzRyd. It integrates records from three production pipelines:
1. `public.sheet_walkins` (Google Sheet submissions synchronized via Google Apps Script)
2. `public.july_new_walkins` (Web portal onboarding form for new candidates)
3. `public.july_existing_walkins` (Web portal visit logs for active partners)

---

## 2. Architectural Design & Guarantees

1. **Zero Modifications to Existing Tables**:
   - Source tables (`sheet_walkins`, `july_new_walkins`, `july_existing_walkins`) remain 100% untouched.
   - They are strictly read-only event sources.
2. **Instant Live Synchronization via PostgreSQL Triggers**:
   - Triggers on all three source tables execute `AFTER INSERT OR UPDATE OR DELETE`.
   - Any new or modified record in Google Sheets or Web Portal is instantly reflected in `public.core_walkin` in <10ms.
   - Decoupled: Requires zero modifications to Google Apps Script or FastAPI portal code.
3. **Event Log Fidelity (No Data Discarded)**:
   - Walk-in records are event logs. Multiple visits on the same day are valid events.
   - Every row is preserved with full provenance (`source_system`, `source_table`, and original primary key ID).
4. **Standardization Scope**:
   - **Functional Standardizations**:
     - `city`: Standardized to canonical hub names (`Bengaluru`, `Hyderabad`, `Mumbai`) for cross-table joins.
     - `phone_number`: Cleaned to standard 10-digit mobile numbers for relational joins.
     - `visiting_reason_category`: Categorized for high-level management reporting (`ONBOARDING`, `ENQUIRY`, `PAYOUT_HISAAB`, `VEHICLE_MAINTENANCE`, `MEETING_COMPLAINT`, `OTHER`).
   - **Verbatim Pass-Through**:
     - Person / partner names, remarks, and Aadhaar numbers are stored exactly as submitted by executives without automated modification.

---

## 3. Directory Contents

| File | Description |
| :--- | :--- |
| [`schema.sql`](./schema.sql) | PostgreSQL DDL for `public.core_walkin`, B-Tree indexes, and 3 real-time trigger functions. |
| [`data_issues.md`](./data_issues.md) | Comprehensive operational issues catalog (ISS-01 through ISS-06) documenting form-level anomalies and ops recommendations. |
| [`automation_script.py`](./automation_script.py) | Python automation engine for reconciliation audits, health checks, and full idempotent backfills. |
| [`README.md`](./README.md) | Exhaustive Knowledge Transfer (KT) runbook and architectural specifications. |

---

## 4. Live Trigger Mapping

| Source Table | Trigger Name | Execution Timing | Synchronization Target |
| :--- | :--- | :--- | :--- |
| `sheet_walkins` | `trg_sync_core_walkin_from_sheet` | `AFTER INSERT OR UPDATE OR DELETE` | Matched on `sheet_walkin_id` |
| `july_new_walkins` | `trg_sync_core_walkin_from_portal_new` | `AFTER INSERT OR UPDATE OR DELETE` | Matched on `portal_new_walkin_id` |
| `july_existing_walkins` | `trg_sync_core_walkin_from_portal_existing` | `AFTER INSERT OR UPDATE OR DELETE` | Matched on `portal_existing_walkin_id` |

---

## 5. CLI Automation & Reconciliation Commands

Run reconciliation health audit:
```bash
python automation_script.py --audit
```

Run full idempotent backfill:
```bash
python automation_script.py --backfill
```
