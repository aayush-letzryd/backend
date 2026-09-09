# LetzRyd Backend Knowledge Base & Pipelines

Welcome to the central backend engineering and knowledge transfer repository for LetzRyd.

This repository hosts production scripts, architecture specifications, database definitions, and knowledge transfer (KT) runbooks for LetzRyd core backend services and ingestion pipelines.

---

## Repository Directory Index

### 1. [Walkin Form Google Sheet](./Walkin%20Form%20Google%20Sheet/)
- **Description**: Real-time production data pipeline synchronizing driver-partner walk-in records from Google Sheets into the centralized PostgreSQL database.
- **Key Files**:
  - [`walkin_pipeline_appscript.js`](./Walkin%20Form%20Google%20Sheet/walkin_pipeline_appscript.js): Google Apps Script production code featuring dual-trigger synchronization, JDBC batching, and multi-format data normalization.
  - [`README.md`](./Walkin%20Form%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) document detailing architecture, working processes, schema DDL, the 12 audit bug fixes, deployment runbook, and operational SQL queries.
  - [`schema.sql`](./Walkin%20Form%20Google%20Sheet/schema.sql): PostgreSQL Data Definition Language (DDL) for `public.sheet_walkins`, composite unique constraints, B-Tree performance indexes, and sample operational queries.
  - [`data_issues.md`](./Walkin%20Form%20Google%20Sheet/data_issues.md): Comprehensive data quality audit documenting all 24 identified anomalies (ISS-01 through ISS-24) and their exact standardization implementations.
- **Target Table**: `public.sheet_walkins` $\to$ `public.core_walkin`

---

### 2. [Partner Onboarding Google Sheet](./Partner%20Onboarding%20Google%20Sheet/)
- **Description**: Direct real-time data pipeline and cross-sheet extraction without IMPORTRANGE, synchronizing driver KYC onboarding records (`Onboarding form_V2`) and portal submissions (`july_form_onboarding`) into `public.core_partner_onboarding`.
- **Key Files**:
  - [`partner_onboarding_pipeline_appscript.js`](./Partner%20Onboarding%20Google%20Sheet/partner_onboarding_pipeline_appscript.js): Google Apps Script engine for cross-sheet pulling, 47-issue standardization, and PostgreSQL zero-burn upserts.
  - [`schema.sql`](./Partner%20Onboarding%20Google%20Sheet/schema.sql): PostgreSQL DDL for `sheet_driver_onboarding`, `core_partner_onboarding`, and the automated consolidation procedure `refresh_core_partner_onboarding()`.
  - [`data_issues.md`](./Partner%20Onboarding%20Google%20Sheet/data_issues.md): Comprehensive data quality audit documenting all 47 identified anomalies (ISS-16 through ISS-62) from `Master_Issue_Standardization_Catalog.xlsx`.
  - [`README.md`](./Partner%20Onboarding%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) document and operational runbook.
- **Target Tables**: `public.sheet_driver_onboarding` + `public.july_form_onboarding` $\to$ `public.core_partner_onboarding`

---

### 3. [Vehicle Onboarding Google Sheet](./Vehicle%20Onboarding%20Google%20Sheet/)
- **Description**: Real-time production data pipeline synchronizing master vehicle fleet onboarding records (Asset List, Master Document Sheet, and PDI inspections) across 73 columns from Google Sheets into the centralized PostgreSQL database.
- **Key Files**:
  - [`vehicle_onboarding_pipeline_appscript.js`](./Vehicle%20Onboarding%20Google%20Sheet/vehicle_onboarding_pipeline_appscript.js): Production Google Apps Script engine featuring 73-column JDBC mapping, batch resilience (250-row chunks), regex sanitization, rollback protection, and dual real-time triggers.
  - [`schema.sql`](./Vehicle%20Onboarding%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_vehicle_onboarding` with 73 columns, Primary Key on `registration_no`, 7 B-Tree performance indexes, and verification queries.
  - [`data_issues.md`](./Vehicle%20Onboarding%20Google%20Sheet/data_issues.md): Comprehensive data hygiene catalog documenting all 29 identified abnormalities (VEH-01 through VEH-29) and their automated standardization rules.
  - [`README.md`](./Vehicle%20Onboarding%20Google%20Sheet/README.md): Architecture documentation, setup guide, trigger installation runbook, and verification queries.
- **Target Table**: `public.sheet_vehicle_onboarding`

---

### 4. [Vehicle Allocation Google Sheet](./Vehicle%20Allocation%20Google%20Sheet/)
- **Description**: Real-time production ingestion pipeline synchronizing vehicle fleet allocations directly from the Pan India Master Sheet into PostgreSQL.
- **Key Files**:
  - [`allocation_pipeline_appscript.js`](./Vehicle%20Allocation%20Google%20Sheet/allocation_pipeline_appscript.js): Production Google Apps Script engine featuring direct background Master Sheet reads (`openById`), Zero-Burn CTE Upsert, and 24 standardized data cleaning rules.
  - [`README.md`](./Vehicle%20Allocation%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) documentation covering system architecture, table column dictionaries, deployment runbooks, and operational queries.
  - [`schema.sql`](./Vehicle%20Allocation%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_vehicle_allocations` with B-Tree indexes and composite unique constraint `(allocation_date, vehicle_number, driver_phone)`.
  - [`data_issues.md`](./Vehicle%20Allocation%20Google%20Sheet/data_issues.md): Comprehensive issue catalog documenting all 24 standardized data quality anomalies (ISS-01 through ISS-24).
- **Target Table**: `public.sheet_vehicle_allocations` (PostgreSQL)

---

### 5. [Traffic Challan Google Sheet](./Traffic%20Challan%20Google%20Sheet/)
- **Description**: Real-time production data pipeline synchronizing master vehicle traffic challan violation events and weekly rolling balance ledgers across 38 tabs (36,039 records across 1,602 unique fleet vehicles) into `public.sheet_challans`.
- **Key Files**:
  - [`challan_pipeline_appscript.js`](./Traffic%20Challan%20Google%20Sheet/challan_pipeline_appscript.js): Production Google Apps Script engine featuring 38-tab consolidation, 15-issue data hygiene engine (ISS-01 through ISS-15), JDBC batching, rollback protection, and live `handleOnEdit` triggers.
  - [`schema.sql`](./Traffic%20Challan%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_challans` with 19 columns, composite unique key on `(vehicle_reg_no, notice_no, week_cycle)`, 6 B-Tree indexes, and verification audit queries.
  - [`data_issues.md`](./Traffic%20Challan%20Google%20Sheet/data_issues.md): Comprehensive 13-column data hygiene catalog documenting all 15 operational anomalies (`ISS-01` to `ISS-15`) and automated standardization rules.
  - [`README.md`](./Traffic%20Challan%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) runbook, architectural specifications, trigger setup, and post-migration verification queries.
- **Target Table**: `public.sheet_challans` $\to$ `public.challans_final`

---

### 6. [Vehicle Dropoff Google Sheet](./Vehicle%20Dropoff%20Google%20Sheet/)
- **Description**: Real-time and batch synchronization engine bridging vehicle dropoff / return reports from Google Sheets (`Drop off History` in `Pan India Master Sheet.xlsx`) and web portal submissions (`public.july_vehicle_dropoffs`) into the centralized production PostgreSQL database (`public.core_dropoffs`).
- **Key Files**:
  - [`dropoff_pipeline_appscript.js`](./Vehicle%20Dropoff%20Google%20Sheet/dropoff_pipeline_appscript.js): Google Apps Script production engine featuring dual ingestion (standardized `sheet_dropoffs` tab + PostgreSQL), live `handleOnEdit` & `handleOnFormSubmit` triggers, sliding-window incremental sync, full batch synchronization, 11-issue standardization engine (ISS-01 to ISS-11), signed debt polarity calculation, custom spreadsheet UI menu, and JDBC batch resilience.
  - [`schema.sql`](./Vehicle%20Dropoff%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_dropoffs` (staging), `public.core_dropoffs` (consolidated master), `public.active_core_dropoffs` view, transactional advisory lock (`777444555`), dual real-time triggers, and the automated consolidation procedure `refresh_core_dropoffs()`.
  - [`data_issues.md`](./Vehicle%20Dropoff%20Google%20Sheet/data_issues.md): Comprehensive 13-column data quality audit documenting all 11 operational anomalies (`ISS-01` through `ISS-11`), category breakdown, and team lead audit resolution logs.
  - [`README.md`](./Vehicle%20Dropoff%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) document covering architecture diagrams, standardizations catalog, database schema DDL, and operational runbook.
- **Target Tables**: `public.sheet_dropoffs` + `public.july_vehicle_dropoffs` $\to$ `public.core_dropoffs` (Active View: `public.active_core_dropoffs`)

---

### 7. [Accidents Google Sheet](./Accidents%20Google%20Sheet/)
- **Description**: Real-time and batch synchronization engine bridging vehicle accident reports from Google Sheets (`Accident vehicle report` in `WIP- Pan India.xlsx`) and web portal submissions (`public.july_accidents_registry`) into the centralized production PostgreSQL database (`public.core_accidents`).
- **Key Files**:
  - [`accidents_pipeline_appscript.js`](./Accidents%20Google%20Sheet/accidents_pipeline_appscript.js): Google Apps Script production engine featuring live form submission triggers (`handleOnFormSubmit`), 1-minute catch-up sync (`syncRecentAccidents`), full batch synchronization (`syncAllAccidents`), 10-issue standardization (ACC-01 to ACC-10), vehicle registration regex sanitization, canonical 3-letter city codes, Excel serial date parsing, police acknowledgement boolean consolidation, financial numeric sanitization, and CTE zero-burn upserts.
  - [`schema.sql`](./Accidents%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_accidents` (21 columns), `public.core_accidents` (16 columns), composite unique constraints, B-Tree performance indexes, and the automated consolidation procedure `refresh_core_accidents()`.
  - [`data_issues.md`](./Accidents%20Google%20Sheet/data_issues.md): Comprehensive data quality audit documenting all 10 identified operational anomalies (ACC-01 through ACC-10) and automated standardization rules.
  - [`README.md`](./Accidents%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) document covering architecture diagrams, standardizations catalog, database schema, and trigger setup instructions.
- **Target Tables**: `public.sheet_accidents` + `public.july_accidents_registry` $\to$ `public.core_accidents`

---

### 8. [Adjustments Google Sheet](./Adjustments%20Google%20Sheet/)
- **Description**: Real-time production ingestion pipeline bridging partner adjustment submissions from Google Sheets (`Adjustment-Form` in `Pan India Master Sheet.xlsx`) and portal entries (`public.july_partner_adjustment`) into the centralized production PostgreSQL database (`public.core_adjustments`).
- **Key Files**:
  - [`adjustments_pipeline_appscript.js`](./Adjustments%20Google%20Sheet/adjustments_pipeline_appscript.js): Google Apps Script production engine featuring live form submit triggers (`handleOnFormSubmit`), 1-minute catch-up sync (`syncRecentAdjustments`), full batch sync (`syncAllAdjustments`), 11-issue standardization (ADJ-01 to ADJ-11), deterministic Partner ID generation (`LETZ<CITY><PHONE>`), phone scientific notation/float sanitization, multi-level approval state hierarchy resolution (Final Level > Level 1 > Pending), Hisaab week parsing, and CTE zero-burn upserts.
  - [`schema.sql`](./Adjustments%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_adjustments` (28 columns), `public.core_adjustments` (17 columns), composite unique constraints, B-Tree indexes, and the automated consolidation procedure `refresh_core_adjustments()`.
  - [`data_issues.md`](./Adjustments%20Google%20Sheet/data_issues.md): Comprehensive data hygiene catalog documenting all 11 identified data quality anomalies (ADJ-01 through ADJ-11) and automated normalization specifications.
  - [`README.md`](./Adjustments%20Google%20Sheet/README.md): Architecture documentation, multi-level approval hierarchy rules, table column dictionaries, and deployment runbooks.
- **Target Tables**: `public.sheet_adjustments` + `public.july_partner_adjustment` $\to$ `public.core_adjustments`

---

### 9. [Walkin Final Table](./Walkin%20Final%20Table/)
- **Description**: Real-time unified master single source of truth (`public.core_walkin`) combining driver and partner walk-in event records from Google Sheets (`sheet_walkins`) and web portal systems (`july_new_walkins` and `july_existing_walkins`).
- **Key Files**:
  - [`schema.sql`](./Walkin%20Final%20Table/schema.sql): PostgreSQL DDL for `public.core_walkin`, indexes, and 3 automated PostgreSQL triggers for real-time synchronization (<10ms).
  - [`automation_script.py`](./Walkin%20Final%20Table/automation_script.py): Parameterized Python engine for initial idempotent backfill, health auditing, and reconciliation.
  - [`data_issues.md`](./Walkin%20Final%20Table/data_issues.md): Comprehensive data quality catalog (ISS-01 to ISS-06) documenting form-level anomalies and ops recommendations.
  - [`README.md`](./Walkin%20Final%20Table/README.md): Exhaustive architecture documentation, trigger mapping matrix, and operational commands.
- **Target Table**: `public.core_walkin` (PostgreSQL)
- **Primary Features**:
  - Zero changes to source tables (`sheet_walkins`, `july_new_walkins`, `july_existing_walkins` remain untouched)
  - Native PostgreSQL triggers providing instant live synchronization (<10ms)
  - Gapless sequential primary key (`id` allocated via transactional advisory lock `pg_advisory_xact_lock` guaranteeing continuous 1..N IDs without sequence jumps)
  - Non-destructive soft deletes (`is_deleted = TRUE`, `deleted_at = CURRENT_TIMESTAMP` upon source deletions, maintaining gapless IDs and audit history)
  - 100% event log preservation (all walk-in records preserved with full fidelity and source attribution)
  - Functional standardization of cities (`Bengaluru`, `Hyderabad`, `Mumbai`) and 10-digit mobile numbers
  - Verbatim pass-through of names, remarks, and Aadhaar numbers without altering raw inputs
  - Future-proof schema evolution guide and semi-structured metadata storage via `extra_attributes JSONB`

---

### 10. [Vehicle Onboarding Final Table](./Vehicle%20Onboarding%20Final%20Table/)
- **Description**: Real-time unified master Single Source of Truth (`public.core_vehicle_onboarding`) merging Google Sheets fleet onboarding (`sheet_vehicle_onboarding`) and LetzRyd Web Portal Intake Form (`july_vehicle_onboarding`) with deterministic Portal Priority.
- **Key Files**:
  - [`schema.sql`](./Vehicle%20Onboarding%20Final%20Table/schema.sql): PostgreSQL DDL for `public.core_vehicle_onboarding`, indexes, and dual triggers for live bi-directional sync (<10ms).
  - [`automation_script.py`](./Vehicle%20Onboarding%20Final%20Table/automation_script.py): Parameterized Python engine for initial backfill, reconciliation, and automated health audits.
  - [`data_issues.md`](./Vehicle%20Onboarding%20Final%20Table/data_issues.md): Comprehensive data quality catalog (ISS-01 to ISS-05) documenting plate formatting, VIN lengths, city variants, and ops recommendations.
  - [`README.md`](./Vehicle%20Onboarding%20Final%20Table/README.md): Exhaustive engineering blueprint, architecture diagram, and operational runbook.
- **Target Table**: `public.core_vehicle_onboarding` (PostgreSQL)
- **Primary Features**:
  - Single Source of Truth on `registration_no` (Standardized vehicle plate)
  - Deterministic Portal Priority: Portal submissions take precedence for core vehicle data while Google Sheet records enrich non-conflicting operational fields
  - Gapless sequential primary key (`id` allocated via advisory lock `pg_advisory_xact_lock(777999111)`)
  - Permanent Archival & Non-destructive soft deletes (`is_deleted = TRUE`, `deleted_at = NOW()`)
  - Clean IST timestamps without `+05:30` offset confusion
  - Partial unique indexes and performance query indexes

---

### 11. [Maintenance Google Sheet](./Maintenance%20Google%20Sheet/)
- **Description**: Real-time and batch extraction engine isolating vehicle workshop and breakdown downtime records from `sheet_vehicle_status` into dedicated staging (`public.sheet_maintenance`) and master (`public.core_maintenance`) tables.
- **Key Files**:
  - [`schema.sql`](./Maintenance%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_maintenance`, composite unique constraint `(maintenance_date, vehicle_number)`, automated extraction trigger `trg_extract_maintenance_from_sheet_status`, and batch backfill procedure `sp_extract_all_sheet_maintenance()`.
  - [`maintenance_pipeline_appscript.js`](./Maintenance%20Google%20Sheet/maintenance_pipeline_appscript.js): Production Google Apps Script engine featuring parameterized JDBC batching, live `handleOnEdit` trigger, 5-minute sliding window sync, placeholder stripping, and IP operator driver retention logic.
  - [`data_issues.md`](./Maintenance%20Google%20Sheet/data_issues.md): Comprehensive data quality catalog (MAINT-01 through MAINT-10) documenting placeholder workshop names, missing job cards, duplicate daily entries, and status taxonomy drift.
  - [`README.md`](./Maintenance%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) document detailing decoupling rationale, trigger mechanics, data dictionary, and operational runbook.
- **Target Tables**: `public.sheet_vehicle_status` -> `public.sheet_maintenance` -> `public.core_maintenance`

---

### 12. [Maintenance Final Table](./Maintenance%20Final%20Table/)
- **Description**: Real-time unified master Single Source of Truth (`public.core_maintenance`) consolidating fleet workshop downtime and repair intervals across Google Sheets (`sheet_maintenance`) and the Web Portal (`july_maintenance_in` + `july_maintenance_out`).
- **Key Files**:
  - [`schema.sql`](./Maintenance%20Final%20Table/schema.sql): PostgreSQL DDL for `public.core_maintenance`, indexes, inward-outward interval pairing, and real-time triggers (`sync_core_maintenance_from_sheet`, `sync_core_maintenance_from_portal`).
  - [`automation_script.py`](./Maintenance%20Final%20Table/automation_script.py): Production Python health check, verification, backfill, and interval repair engine (`--audit`, `--backfill`, `--verify-triggers`, `--repair-intervals`).
  - [`data_issues.md`](./Maintenance%20Final%20Table/data_issues.md): Comprehensive data reconciliation catalog detailing open maintenance intervals, negative/inverted durations, multi-day gap resolution, and workshop cost discrepancies.
  - [`README.md`](./Maintenance%20Final%20Table/README.md): Exhaustive Knowledge Transfer (KT) manual covering architecture, temporal calculation rules, trigger specifications, and operational runbook.
- **Target Table**: `public.core_maintenance` (PostgreSQL)
- **Primary Features**:
  - Temporal interval pairing: couples inward vehicle entry with outward release into unified `[start_date, end_date]` intervals.
  - Zero negative duration enforcement: strictly guarantees `end_date >= start_date`.
  - Native real-time PostgreSQL triggers: bidirectional sync (<10ms) with soft-delete protection.
  - Financial auditing: tracks estimated vs actual invoice costs and LetzRyd payable liabilities.

---

### 13. [Vehicle Status Google Sheet](./Vehicle%20Status%20Google%20Sheet/)
- **Description**: Production ingestion pipeline synchronizing daily fleet operational status and attendance records directly from Google Sheets (`Daily Vehicle Status` in `Vehicle Status List V3.xlsx`) into PostgreSQL staging table `public.sheet_vehicle_status`.
- **Key Files**:
  - [`schema.sql`](./Vehicle%20Status%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_vehicle_status`, natural unique constraint `(status_date, vehicle_number)`, 6 B-Tree performance indexes, and verification queries.
  - [`vehicle_status_pipeline_appscript.js`](./Vehicle%20Status%20Google%20Sheet/vehicle_status_pipeline_appscript.js): Production Google Apps Script pipeline with chunked JDBC batching (200 rows), `LockService` concurrency locking, `PropertiesService` secrets, and zero-burn CTE upserts.
  - [`data_issues.md`](./Vehicle%20Status%20Google%20Sheet/data_issues.md): Comprehensive data hygiene audit cataloging date format shifts, status casing variations, unallocated partner ID overloading, and OCR plate fixes.
  - [`README.md`](./Vehicle%20Status%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) runbook covering 3-layer architecture, pipeline flow, column data dictionary, trigger installation, and operational queries.
- **Target Table**: `public.sheet_vehicle_status` (PostgreSQL)

---

### 14. [Vehicle Status Final Table](./Vehicle%20Status%20Final%20Table/)
- **Description**: Master operational fleet status architecture delivering the continuous daily attendance ledger (`public.core_daily_vehicle_status`), real-time live fleet snapshot (`public.v_current_live_fleet_status`), and mathematical interval pairing view (`public.v_vehicle_trip_intervals`).
- **Key Files**:
  - [`schema.sql`](./Vehicle%20Status%20Final%20Table/schema.sql): PostgreSQL DDL for `public.core_daily_vehicle_status`, views `v_vehicle_trip_intervals` and `v_current_live_fleet_status`, and stored procedure `sp_generate_daily_vehicle_status(target_date)`.
  - [`automation_script.py`](./Vehicle%20Status%20Final%20Table/automation_script.py): Production Python health check and verification CLI (`--audit`, `--live`, `--generate-date`, `--backfill`).
  - [`data_issues.md`](./Vehicle%20Status%20Final%20Table/data_issues.md): Technical catalog documenting all 10 real-world edge cases (Pristine RFD 139 cars, Same-day trips 1,094, Consecutive allocations 170, Orphan dropoffs 8, IP operator custody).
  - [`README.md`](./Vehicle%20Status%20Final%20Table/README.md): Complete Knowledge Transfer (KT) runbook, mathematical pairing formalization, priority precedence rules, and nightly cron setup.
- **Target Table**: `public.core_daily_vehicle_status` (Daily Ledger) & `public.v_current_live_fleet_status` (Live View)

---

## Infrastructure Overview

- **Primary Database Host**: `YOUR_DB_HOST_HERE:5432`
- **Database Engine**: PostgreSQL 14+
- **Default Database**: `postgres`
- **Architecture**: Decoupled ingestion layers utilizing Google Apps Script JDBC, FastAPI microservices, and PostgreSQL persistence.

---

## Maintenance and Governance

All code, configurations, and documentation in this repository adhere to standard production guidelines:
- Zero data loss tolerance on partner onboarding records.
- Standard SQL ANSI syntax compatible across relational database tools.
- Leak-proof JDBC connection and statement resource management.
- Comprehensive operational runbooks for seamless knowledge transfer.
