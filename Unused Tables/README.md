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

### Batch 4: Legacy Week 15 Shards (`*_15` -> `z_*_15`)
- **Execution Date:** 2026-10-05
- **Status:** ✅ Executed & Verified
- **Object Count:** 17 objects (14 tables + 3 views)
- **Total Rows:** 56,457 rows (historical data from Week of June 29 - July 5, 2026)
- **Total Size:** ~6.6 MB
- **SQL Script:** [`04_archive_shards_15.sql`](./04_archive_shards_15.sql)
- **Rollback Script:** [`04_rollback_shards_15.sql`](./04_rollback_shards_15.sql)

| Original Object | Quarantined Name | Type | Rows | Size |
| :--- | :--- | :--- | :--- | :--- |
| `uber_ola_final_hisaab_15` | `z_uber_ola_final_hisaab_15` | VIEW | N/A | 0 bytes |
| `hisaab_summary_15` | `z_hisaab_summary_15` | VIEW | N/A | 0 bytes |
| `weekly_hisaab_summary_15` | `z_weekly_hisaab_summary_15` | VIEW | N/A | 0 bytes |
| `uber_raw_15` | `z_uber_raw_15` | TABLE | 38,489 | ~3.8 MB |
| `gps_raw_15` | `z_gps_raw_15` | TABLE | 4,578 | 808 kB |
| `ola_raw_15` | `z_ola_raw_15` | TABLE | 4,741 | 568 kB |
| `rapido_raw_15` | `z_rapido_raw_15` | TABLE | 3,656 | 528 kB |
| `uber_payment_organisation_15` | `z_uber_payment_organisation_15` | TABLE | 1,236 | 192 kB |
| `vendor_ledger_15` | `z_vendor_ledger_15` | TABLE | 1,125 | 192 kB |
| `allocation_master_15` | `z_allocation_master_15` | TABLE | 644 | 160 kB |
| `daily_vehicle_status_15` | `z_daily_vehicle_status_15` | TABLE | 634 | 104 kB |
| `uber_incentive_15` | `z_uber_incentive_15` | TABLE | 610 | 104 kB |
| `ola_incentive_15` | `z_ola_incentive_15` | TABLE | 610 | 96 kB |
| `online_payment_15` | `z_online_payment_15` | TABLE | 102 | 32 kB |
| `accident_penalty_15` | `z_accident_penalty_15` | TABLE | 32 | 32 kB |
| `adjustment_15` | `z_adjustment_15` | TABLE | 0 | 16 kB |
| `challan_15` | `z_challan_15` | TABLE | 0 | 16 kB |

---

### Batch 5: Legacy Week 16 Shards (`*_16` -> `z_*_16`)
- **Execution Date:** 2026-10-05
- **Status:** ✅ Executed & Verified
- **Object Count:** 18 objects (15 tables + 3 views)
- **Total Rows:** 15,352 rows (historical data from Week of June 29 - July 5, 2026)
- **Total Size:** ~2.5 MB
- **SQL Script:** [`05_archive_shards_16.sql`](./05_archive_shards_16.sql)
- **Rollback Script:** [`05_rollback_shards_16.sql`](./05_rollback_shards_16.sql)

| Original Object | Quarantined Name | Type | Rows | Size |
| :--- | :--- | :--- | :--- | :--- |
| `hisaab_summary_16` | `z_hisaab_summary_16` | VIEW | N/A | 0 bytes |
| `uber_ola_final_hisaab_16` | `z_uber_ola_final_hisaab_16` | VIEW | N/A | 0 bytes |
| `weekly_hisaab_summary_16` | `z_weekly_hisaab_summary_16` | VIEW | N/A | 0 bytes |
| `uber_raw_16` | `z_uber_raw_16` | TABLE | 5,847 | 736 kB |
| `uber_payment_organisation_16` | `z_uber_payment_organisation_16` | TABLE | 5,285 | 672 kB |
| `rapido_raw_16` | `z_rapido_raw_16` | TABLE | 1,893 | 304 kB |
| `gps_raw_16` | `z_gps_raw_16` | TABLE | 968 | 224 kB |
| `vendor_ledger_16` | `z_vendor_ledger_16` | TABLE | 374 | 96 kB |
| `allocation_master_16` | `z_allocation_master_16` | TABLE | 254 | 88 kB |
| `uber_incentive_16` | `z_uber_incentive_16` | TABLE | 201 | 64 kB |
| `ola_incentive_16` | `z_ola_incentive_16` | TABLE | 201 | 64 kB |
| `daily_vehicle_status_16` | `z_daily_vehicle_status_16` | TABLE | 144 | 24 kB |
| `rapido_incentive_16` | `z_rapido_incentive_16` | TABLE | 76 | 32 kB |
| `adjustment_16` | `z_adjustment_16` | TABLE | 57 | 72 kB |
| `challan_16` | `z_challan_16` | TABLE | 41 | 32 kB |
| `ola_raw_16` | `z_ola_raw_16` | TABLE | 10 | 32 kB |
| `accident_penalty_16` | `z_accident_penalty_16` | TABLE | 1 | 32 kB |
| `online_payment_16` | `z_online_payment_16` | TABLE | 0 | 16 kB |

---

## 3. Pending Quarantine Groups Roadmap

| Group | Candidate Count | Estimated Size | Description |
| :--- | :--- | :--- | :--- |
| **Batch 6: Legacy Bangalore Shards (`_1`)** | 18 objects | ~19 MB | Week 1 historical shard (March 2026). |
| **Batch 7: Test & Demo Tables (`test_*` / `demo_*`)** | 8 tables | **~843 MB** | Pure test dumps (`test_uber_driver_payments_raw` 788 MB). |
| **Batch 8: Discarded Sheet Staging Mirrors (`sheet_*`)** | 89 tables | ~255 MB | Old sheet replicas no longer receiving sync. |
