# Database Deprecation & Archival Tracker (`z_` Quarantine Pattern)

This directory tracks the audit, migration, and phased deprecation of legacy, obsolete, dev/test, and shard tables in the LetzRyd PostgreSQL production database.

---

## 1. Safety Strategy: The `z_` Quarantine Pattern

Rather than running immediate, irreversible `DROP TABLE` operations in production, all candidate tables undergo a multi-stage quarantine:

1. **Quarantine Rename (`z_<table_name>`):**
   - Tables are renamed with a `z_` prefix.
   - Pushes obsolete tables to the very bottom in GUI clients (pgAdmin, DBeaver, TablePlus) and CLI lists (`\dt`).
   - Prevents table names from exceeding the PostgreSQL 63-character identifier limit.
   - Breaks any unauthorized/forgotten external dependency immediately so it can be identified.
2. **Instant Rollback Availability:**
   - Any table can be instantly restored in <1 second with `ALTER TABLE public.z_<tbl> RENAME TO <tbl>;`.
   - Zero data loss, zero restore downtime.
3. **Cooling Period (7–14 Days):**
   - Tables sit safely in quarantine over regular operational and weekly hisaab settlement cycles.
4. **Final Purge (`DROP TABLE`):**
   - After confirming zero impact or dependencies, disk space is permanently reclaimed.

---

## 2. Completed Migration Batches

### Batch 1: Early Architecture Tables (`lr_*` -> `z_lr_*`)
- **Execution Date:** 2026-10-05
- **Status:** ✅ Executed & Verified
- **Object Count:** 18 tables
- **Total Rows:** 48 rows (seed/prototype records from August 2026)
- **Total Size:** ~800 kB
- **SQL Script:** [`01_archive_lr_tables.sql`](./01_archive_lr_tables.sql)
- **Rollback Script:** [`01_rollback_lr_tables.sql`](./01_rollback_lr_tables.sql)

| Original Table | Quarantined Name | Rows | Last Recorded Update |
| :--- | :--- | :--- | :--- |
| `lr_allocation_master` | `z_lr_allocation_master` | 0 | None (Empty) |
| `lr_audit_logs` | `z_lr_audit_logs` | 0 | None (Empty) |
| `lr_drivers` | `z_lr_drivers` | 5 | 2026-08-07 |
| `lr_gps_mileage_logs` | `z_lr_gps_mileage_logs` | 0 | None (Empty) |
| `lr_hisaab_platform_earnings` | `z_lr_hisaab_platform_earnings` | 6 | 2026-08-07 |
| `lr_notifications` | `z_lr_notifications` | 0 | None (Empty) |
| `lr_operators` | `z_lr_operators` | 2 | 2026-08-07 |
| `lr_platform_weekly_earnings` | `z_lr_platform_weekly_earnings` | 0 | None (Empty) |
| `lr_portal_users` | `z_lr_portal_users` | 5 | 2026-08-07 |
| `lr_referrals` | `z_lr_referrals` | 1 | 2026-08-07 |
| `lr_sos_alerts` | `z_lr_sos_alerts` | 0 | None (Empty) |
| `lr_tickets` | `z_lr_tickets` | 1 | 2026-08-07 |
| `lr_user_audit_logs` | `z_lr_user_audit_logs` | 25 | 2026-08-10 |
| `lr_vehicle_allocations` | `z_lr_vehicle_allocations` | 0 | None (Empty) |
| `lr_vehicle_platform_authorizations` | `z_lr_vehicle_platform_authorizations` | 0 | None (Empty) |
| `lr_vehicles` | `z_lr_vehicles` | 1 | 2026-08-07 |
| `lr_weekly_hisaabs` | `z_lr_weekly_hisaabs` | 3 | 2026-08-07 |
| `lr_weekly_incentive_goals` | `z_lr_weekly_incentive_goals` | 0 | None (Empty) |

---

### Batch 2: Early WebApp Prototype (`webapp_*` -> `z_webapp_*`)
- **Execution Date:** 2026-10-05
- **Status:** ✅ Executed & Verified
- **Object Count:** 4 tables
- **Total Rows:** 13 rows (mock records from June 2026)
- **Total Size:** ~144 kB
- **SQL Script:** [`02_archive_webapp_tables.sql`](./02_archive_webapp_tables.sql)
- **Rollback Script:** [`02_rollback_webapp_tables.sql`](./02_rollback_webapp_tables.sql)

| Original Table | Quarantined Name | Rows | Last Recorded Update |
| :--- | :--- | :--- | :--- |
| `webapp_hisaab_weeks` | `z_webapp_hisaab_weeks` | 5 | 2026-06-22 |
| `webapp_tickets` | `z_webapp_tickets` | 3 | 2026-06-24 |
| `webapp_users` | `z_webapp_users` | 3 | Early Mock |
| `webapp_vehicles` | `z_webapp_vehicles` | 2 | Early Mock |

---

### Batch 3: Dev Snapshot Tables (`copy_*` -> `z_copy_*`)
- **Execution Date:** 2026-10-05
- **Status:** ✅ Executed & Verified
- **Object Count:** 16 tables
- **Total Rows:** 324 rows (snapshots from July/August 2026)
- **Total Size:** ~504 kB
- **SQL Script:** [`03_archive_copy_tables.sql`](./03_archive_copy_tables.sql)
- **Rollback Script:** [`03_rollback_copy_tables.sql`](./03_rollback_copy_tables.sql)

| Original Table | Quarantined Name | Rows | Last Recorded Update |
| :--- | :--- | :--- | :--- |
| `copy_accidents_registry` | `z_copy_accidents_registry` | 5 | 2026-07-02 |
| `copy_app_sessions` | `z_copy_app_sessions` | 211 | 2026-07-06 |
| `copy_app_users` | `z_copy_app_users` | 10 | 2026-07-06 |
| `copy_cities` | `z_copy_cities` | 3 | Static |
| `copy_hubs_parking` | `z_copy_hubs_parking` | 3 | 2026-08-03 |
| `copy_inspections` | `z_copy_inspections` | 9 | 2026-07-02 |
| `copy_maintenance_registry` | `z_copy_maintenance_registry` | 5 | 2026-07-03 |
| `copy_operating_cities` | `z_copy_operating_cities` | 3 | 2026-07-02 |
| `copy_partner_adjustment` | `z_copy_partner_adjustment` | 10 | 2026-07-01 |
| `copy_partner_expenses` | `z_copy_partner_expenses` | 10 | 2026-07-01 |
| `copy_tickets` | `z_copy_tickets` | 0 | None (Empty) |
| `copy_traffic_challans` | `z_copy_traffic_challans` | 7 | 2026-07-03 |
| `copy_users` | `z_copy_users` | 26 | 2026-07-01 |
| `copy_vehicle_allocation` | `z_copy_vehicle_allocation` | 13 | 2026-07-01 |
| `copy_vehicle_models` | `z_copy_vehicle_models` | 6 | 2026-07-02 |
| `copy_workshop_vendors` | `z_copy_workshop_vendors` | 3 | 2026-08-03 |

---

## 3. Pending Quarantine Groups Roadmap

| Group | Candidate Count | Estimated Size | Description |
| :--- | :--- | :--- | :--- |
| **Batch 4: Test & Demo Tables (`test_*` / `demo_*`)** | 8 tables | **~843 MB** | Pure test dumps (`test_uber_driver_payments_raw` 788 MB). |
| **Batch 5: Legacy City Shards (`_1`, `_15`, `_16`)** | 53 objects | ~28 MB | Superseded by unified multi-city tables. |
| **Batch 6: Discarded Sheet Staging Mirrors (`sheet_*`)** | 89 tables | ~255 MB | Old sheet replicas no longer receiving sync. |
