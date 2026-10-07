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

### Batch 6: Demo Testing Tables (`demo_*` -> `z_demo_*`)
- **Execution Date:** 2026-10-05
- **Status:** ✅ Executed & Verified
- **Object Count:** 5 tables
- **Total Rows:** 98,433 rows (pipeline tests from August 2026)
- **Total Size:** ~46 MB
- **SQL Script:** [`06_archive_demo_tables.sql`](./06_archive_demo_tables.sql)
- **Rollback Script:** [`06_rollback_demo_tables.sql`](./06_rollback_demo_tables.sql)

| Original Object | Quarantined Name | Rows | Size | Recorded Date Span |
| :--- | :--- | :--- | :--- | :--- |
| `demo_uber_transaction_activity_test` | `z_demo_uber_transaction_activity_test` | 63,362 | 26 MB | August 2026 |
| `demo_uber_trips_test` | `z_demo_uber_trips_test` | 31,311 | 19 MB | 2026-08-16 to 2026-08-25 |
| `demo_uber_driver_payments_test` | `z_demo_uber_driver_payments_test` | 2,012 | 920 kB | August 2026 |
| `demo_gps_test` | `z_demo_gps_test` | 1,728 | 312 kB | 2026-08-24 |
| `demo_uber_org_payments_test` | `z_demo_uber_org_payments_test` | 20 | 48 kB | August 2026 |

---

### Batch 7: Legacy Week 1 Shards (`*_1` -> `z_*_1`)
- **Execution Date:** 2026-10-05
- **Status:** ✅ Executed & Verified
- **Object Count:** 18 objects (15 tables + 3 views)
- **Total Rows:** 254,583 rows (historical data from Dec 2025 – March 2026)
- **Total Size:** ~19 MB
- **SQL Script:** [`07_archive_shards_1.sql`](./07_archive_shards_1.sql)
- **Rollback Script:** [`07_rollback_shards_1.sql`](./07_rollback_shards_1.sql)

| Original Object | Quarantined Name | Type | Rows | Size |
| :--- | :--- | :--- | :--- | :--- |
| `hisaab_summary_1` | `z_hisaab_summary_1` | VIEW | N/A | 0 bytes |
| `uber_ola_final_hisaab_1` | `z_uber_ola_final_hisaab_1` | VIEW | N/A | 0 bytes |
| `weekly_hisaab_summary_1` | `z_weekly_hisaab_summary_1` | VIEW | N/A | 0 bytes |
| `uber_raw_1` | `z_uber_raw_1` | TABLE | 139,680 | 10 MB |
| `uber_payment_organisation_1` | `z_uber_payment_organisation_1` | TABLE | 107,464 | 7.5 MB |
| `gps_raw_1` | `z_gps_raw_1` | TABLE | 5,845 | 744 kB |
| `uber_incentive_1` | `z_uber_incentive_1` | TABLE | 1,204 | 104 kB |
| `allocation_master_1` | `z_allocation_master_1` | TABLE | 367 | 120 kB |
| `vendor_ledger_1` | `z_vendor_ledger_1` | TABLE | 11 | 32 kB |
| `challan_1` | `z_challan_1` | TABLE | 3 | 32 kB |
| `accident_penalty_1` | `z_accident_penalty_1` | TABLE | 2 | 32 kB |
| `adjustment_1` | `z_adjustment_1` | TABLE | 2 | 32 kB |
| `july_vehicle_onboarding_1` | `z_july_vehicle_onboarding_1` | TABLE | 2 | 32 kB |
| `july_vehicle_onboarding_1_logs`| `z_july_vehicle_onboarding_1_logs` | TABLE | 3 | 32 kB |
| `ola_incentive_1` | `z_ola_incentive_1` | TABLE | 0 | 16 kB |
| `ola_raw_1` | `z_ola_raw_1` | TABLE | 0 | 16 kB |
| `online_payment_1` | `z_online_payment_1` | TABLE | 0 | 16 kB |
| `rapido_raw_1` | `z_rapido_raw_1` | TABLE | 0 | 16 kB |

---

### Batch 8: Test Sandbox Tables (`test_*` -> `z_test_*`)
- **Execution Date:** 2026-10-07
- **Status:** ✅ Executed & Verified
- **Object Count:** 3 tables
- **Total Rows:** 1,698,581 rows (Uber ETL test dumps)
- **Total Size:** ~797 MB
- **SQL Script:** [`08_archive_test_tables.sql`](./08_archive_test_tables.sql)
- **Rollback Script:** [`08_rollback_test_tables.sql`](./08_rollback_test_tables.sql)

| Original Object | Quarantined Name | Rows | Size | Recorded Date Span |
| :--- | :--- | :--- | :--- | :--- |
| `test_uber_driver_payments_raw` | `z_test_uber_driver_payments_raw` | 1,678,873 | **788 MB** | Pure test ingestion |
| `test_uber_org_payments_raw` | `z_test_uber_org_payments_raw` | 19,708 | **9.7 MB** | Pure test ingestion |
| `test_uber_etl_state` | `z_test_uber_etl_state` | 0 | 16 kB | State marker |

---

### Batch 9: Dev Sandbox Tables (`dev_*` -> `z_dev_*`)
- **Execution Date:** 2026-10-07
- **Status:** ✅ Executed & Verified
- **Object Count:** 6 tables (excluding `dev_city` which is still referenced in `portaljuly/main.py`)
- **Total Rows:** 93 rows (early prototype schema from July 2026)
- **Total Size:** ~232 kB
- **SQL Script:** [`09_archive_dev_tables.sql`](./09_archive_dev_tables.sql)
- **Rollback Script:** [`09_rollback_dev_tables.sql`](./09_rollback_dev_tables.sql)

| Original Object | Quarantined Name | Rows | Size | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `dev_role_permissions` | `z_dev_role_permissions` | 60 | 40 kB | Superseded by `july_role_permissions` |
| `dev_modules` | `z_dev_modules` | 20 | 40 kB | Superseded by `july_permissions` |
| `dev_users` | `z_dev_users` | 5 | 48 kB | Superseded by `july_portal_users` |
| `dev_employees` | `z_dev_employees` | 5 | 48 kB | Superseded by `july_employees` |
| `dev_roles` | `z_dev_roles` | 3 | 48 kB | Superseded by `july_roles` |
| `dev_sessions` | `z_dev_sessions` | 0 | 8 kB | Superseded by `july_app_sessions` |

*(Note: `dev_city` is preserved as active because `portaljuly/main.py` routes touch it).*

---

### Batch 10: Abandoned Scraper & Staging Dumps (`*` -> `z_*`)
- **Execution Date:** 2026-10-07
- **Status:** ✅ Executed & Verified
- **Object Count:** 8 tables
- **Total Rows:** 118,915 rows (old scraper/test dumps from July/August 2026)
- **Total Size:** ~64 MB
- **SQL Script:** [`10_archive_abandoned_dumps.sql`](./10_archive_abandoned_dumps.sql)
- **Rollback Script:** [`10_rollback_abandoned_dumps.sql`](./10_rollback_abandoned_dumps.sql)

| Original Object | Quarantined Name | Rows | Size | Last Recorded Date |
| :--- | :--- | :--- | :--- | :--- |
| `ola_driver_bookings_cancellations` | `z_ola_driver_bookings_cancellations` | 80,581 | **42 MB** | 2026-07-01 |
| `uber_trips_raw` | `z_uber_trips_raw` | 20,280 | **13 MB** | 2026-08-25 |
| `ola_report_blr_hisaab` | `z_ola_report_blr_hisaab` | 4,741 | **3.3 MB** | 2026-07-05 |
| `ola_driver_performance` | `z_ola_driver_performance` | 7,094 | **2.9 MB** | Early July 2026 |
| `ola_car_performance` | `z_ola_car_performance` | 5,079 | **1.9 MB** | 2026-07-01 |
| `ola_incentive_payments` | `z_ola_incentive_payments` | 1,930 | **1.0 MB** | 2026-07-01 |
| `staging_ola_uber_rapido_raw` | `z_staging_ola_uber_rapido_raw` | 0 | 24 kB | Empty |
| `processed_emails` | `z_processed_emails` | 10 | 32 kB | Test emails |

---

### Batch 11: Legacy Un-prefixed Orphan & Prototype Tables (`*` -> `z_*`)
- **Execution Date:** 2026-10-07
- **Status:** ✅ Executed & Verified
- **Object Count:** 16 tables
- **Total Rows:** 48 rows (early schema prototypes from June/July 2026)
- **Total Size:** ~256 kB
- **SQL Script:** [`11_archive_legacy_unprefixed_tables.sql`](./11_archive_legacy_unprefixed_tables.sql)
- **Rollback Script:** [`11_rollback_legacy_unprefixed_tables.sql`](./11_rollback_legacy_unprefixed_tables.sql)

| Original Object | Quarantined Name | Rows | Size | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `accidents_registry` | `z_accidents_registry` | 5 | 16 kB | Superseded by `sheet_accidents` & `core_accidents` |
| `operating_cities` | `z_operating_cities` | 3 | 16 kB | Superseded by `july_cities` |
| `hubs_and_parking` | `z_hubs_and_parking` | 8 | 16 kB | Superseded by `sheet_hubs_and_parking` & `core_hubs` |
| `partner_adjustment` | `z_partner_adjustment` | 3 | 16 kB | Superseded by `sheet_adjustments` & `core_adjustments` |
| `partner_expenses` | `z_partner_expenses` | 10 | 16 kB | Superseded by `core_expenses` & `hisaab_daily_ledger` |
| `traffic_challans` | `z_traffic_challans` | 7 | 16 kB | Superseded by `vehicle_challans` & `core_challans` |
| `maintenance_registry` | `z_maintenance_registry` | 5 | 16 kB | Superseded by `sheet_maintenance` & `core_maintenance` |
| `workshop_vendors` | `z_workshop_vendors` | 3 | 16 kB | Superseded by `workshops` |
| `walkin_form_links` | `z_walkin_form_links` | 4 | 16 kB | Abandoned temporary test links |
| `vehicle_states` | `z_vehicle_states` | 0 | 16 kB | Empty prototype |
| `user_roles` | `z_user_roles` | 0 | 16 kB | Superseded by `app_roles` / `app_role_permissions` |
| `pdi_logs` | `z_pdi_logs` | 0 | 16 kB | Empty prototype |
| `media_attachments` | `z_media_attachments` | 0 | 16 kB | Empty prototype |
| `maintenance_summary` | `z_maintenance_summary` | 0 | 16 kB | Empty prototype |
| `insurance_claims` | `z_insurance_claims` | 0 | 16 kB | Empty prototype |
| `walkin_onboarding_links` | `z_walkin_onboarding_links` | 0 | 16 kB | Empty prototype |

*(Note: `vehicle_challans` (2,283 rows), `accidents` (6,538 rows), `vehicles` (1,164 rows), `trips` (120k rows), `workshops` (288 rows), `hubs_parking`, and `users` are strictly preserved as active).*

---

## 3. Cumulative Summary: 129 Quarantined Objects (~935 MB)

| Batch | Description | Tables | Reclaimed / Quarantined Size |
| :--- | :--- | :--- | :--- |
| Batch 1 | `lr_*` Early Architecture Tables | 18 | ~800 kB |
| Batch 2 | `webapp_*` Early WebApp Prototype | 4 | ~144 kB |
| Batch 3 | `copy_*` Dev Snapshot Tables | 16 | ~504 kB |
| Batch 4 | Week 15 Shards (`*_15`) | 17 | ~22 MB |
| Batch 5 | Week 16 Shards (`*_16`) | 18 | ~50 MB |
| Batch 6 | `demo_*` Staging Tables | 5 | ~46 MB |
| Batch 7 | Week 1 Shards (`*_1`) | 18 | ~19 MB |
| Batch 8 | Large Test Payment Dumps (`test_*`) | 3 | **~797 MB** |
| Batch 9 | `dev_*` Tables | 6 | ~232 kB |
| Batch 10 | Abandoned Scraper & Staging Dumps | 8 | **~64 MB** |
| Batch 11 | Legacy Un-prefixed Orphan Tables | 16 | ~256 kB |
| **TOTAL** | **11 Batches Successfully Quarantined** | **129 Tables** | **~999 MB** |

---

## 4. STRICTLY PROTECTED TABLES (DO NOT TOUCH)

> [!CAUTION]
> **All `sheet_*` tables are LIVE PRODUCTION Google Sheet ingestion source tables** connected directly via Google Apps Script JDBC pipelines across all operational Google Sheets (`sheet_accidents`, `sheet_adjustments`, `sheet_maintenance`, `sheet_driver_onboarding`, `sheet_challans`, `sheet_vehicle_allocations`, `sheet_dropoffs`, `sheet_vehicle_onboarding`, `sheet_walkins`, `sheet_gps_telematics`, etc.).
> 
> **THEY MUST NEVER BE RENAMED, ARCHIVED, OR DROPPED.**
>
> **Also Protected:**
> - `vehicle_challans` (Scraped by Karnataka One automation in `Challan_Fine_Automation_Pipeline`)
> - `trips` (Core trip sync & Hisaab routines)
> - `vehicles`, `vehicle_assignments`, `accidents` (Core operational & management MIS views)


