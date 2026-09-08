# Walk-in Master Single Source of Truth (`public.core_walkin`)

## Overview
`public.core_walkin` is the unified single source of truth (SSOT) for all driver and partner walk-in records at LetzRyd. It aggregates records from three production pipelines:
1. `public.sheet_walkins` (Google Sheet submissions synchronized via Google Apps Script)
2. `public.july_new_walkins` (Web portal onboarding form for new candidates)
3. `public.july_existing_walkins` (Web portal visit logs for active partners)

---

## Architectural Principles

1. **Non-Destructive Integration**:
   - Source tables (`sheet_walkins`, `july_new_walkins`, `july_existing_walkins`) remain 100% untouched.
   - They are strictly treated as read-only event sources.
2. **Zero-Latency Live Synchronization**:
   - PostgreSQL database triggers (`AFTER INSERT OR UPDATE OR DELETE`) on all three source tables automatically mirror and standardize incoming records into `core_walkin` in <10ms.
   - No code changes are required in Google Apps Script or the web portal backend.
3. **Event Log Fidelity**:
   - Walk-in events are preserved as individual event records.
   - No rows are dropped or forcibly merged.
4. **Data Standardization**:
   - Cities standardized to `Bengaluru`, `Hyderabad`, and `Mumbai`.
   - Phone numbers cleaned to 10-digit format.
   - Accidentally pasted email strings in name fields are automatically sanitized.
   - Visiting reasons are preserved verbatim while also classified into a canonical category (`visiting_reason_category`).

---

## Directory Contents

- `schema.sql`: Contains the complete DDL for `public.core_walkin`, indexes, and the three trigger functions.
- `sync_core_walkin.py`: Python script for initial backfill, health auditing, and reconciliation.
- `data_reconciliation_report.md`: Detailed audit of data anomalies and recommendations for source form improvements.
- `README.md`: This architecture document.

---

## Live Sync Trigger Mapping

| Source Table | Trigger Name | Action | Target in `core_walkin` |
| :--- | :--- | :--- | :--- |
| `sheet_walkins` | `trg_sync_core_walkin_from_sheet` | `AFTER INSERT OR UPDATE OR DELETE` | Matched on `sheet_walkin_id` |
| `july_new_walkins` | `trg_sync_core_walkin_from_portal_new` | `AFTER INSERT OR UPDATE OR DELETE` | Matched on `portal_new_walkin_id` |
| `july_existing_walkins` | `trg_sync_core_walkin_from_portal_existing` | `AFTER INSERT OR UPDATE OR DELETE` | Matched on `portal_existing_walkin_id` |

---

## Audit & Reconciliation Commands

Run reconciliation health audit:
```bash
python sync_core_walkin.py --audit
```

Run full idempotent backfill:
```bash
python sync_core_walkin.py --backfill
```
