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
- **Description**: High-speed production ingestion and fleet intelligence pipeline synchronizing daily operational status and attendance records from Google Sheets (`Daily Vehicle Status` in `Vehicle Status List V3.xlsx`) into PostgreSQL staging (`public.sheet_vehicle_status`), continuous daily attendance ledger (`public.core_daily_vehicle_status`), mathematical trip intervals (`public.v_vehicle_trip_intervals`), and real-time live fleet status (`public.v_current_live_fleet_status`).
- **Key Files**:
  - [`vehicle_status_pipeline_appscript.js`](./Vehicle%20Status%20Google%20Sheet/vehicle_status_pipeline_appscript.js): High-throughput production Google Apps Script engine featuring multi-row SQL statement batching (100 rows/statement), direct DB credentials, dual-target ingestion (`sheet_vehicle_status` tab + PostgreSQL), concurrency locking (`LockService`), and 1-minute automated time-driven triggers.
  - [`schema.sql`](./Vehicle%20Status%20Google%20Sheet/schema.sql): PostgreSQL DDL for `public.sheet_vehicle_status`, `public.core_daily_vehicle_status`, views `v_vehicle_trip_intervals` and `v_current_live_fleet_status`, stored procedure `sp_generate_daily_vehicle_status(target_date)`, and real-time trigger `trg_sync_core_daily_status_from_sheet`.
  - [`data_issues.md`](./Vehicle%20Status%20Google%20Sheet/data_issues.md): Comprehensive data hygiene audit cataloging 11 standardized operational anomalies (`ISS-01` through `ISS-11`) including status normalization, scientific notation partner ID repair, and OCR plate fixes.
  - [`README.md`](./Vehicle%20Status%20Google%20Sheet/README.md): Exhaustive Knowledge Transfer (KT) runbook covering the consolidated architecture, trigger setup, 11-issue standardizations, data dictionary, and operational SQL queries.
- **Target Tables & Views**: `public.sheet_vehicle_status` $\to$ `public.core_daily_vehicle_status` (Daily Attendance Ledger), `public.v_vehicle_trip_intervals`, `public.v_current_live_fleet_status` (Live View)
- **Primary Features**:
  - High-performance multi-row SQL batching processing 46,000+ records in ~2 minutes without hitting Apps Script execution limits.
  - Dual-target sync writing both locally to the spreadsheet and to PostgreSQL.
  - Automatic IST date normalization (`yyyy-MM-dd`) handling Excel serial floats, dates, and timestamp strings.
  - Live PostgreSQL trigger cascading sheet updates directly to `core_daily_vehicle_status`.
  - Continuous gapless attendance ledger and instantaneous live fleet operational snapshot.

---

### 14. [Uber Final Table](./Uber%20Final%20Table/)
- **Description**: Production data pipeline and financial ledger engine aggregating raw Uber trips (`uber_pipeline_trips`), order payment transactions (`uber_pipeline_order_transactions`), and target milestones (`uber_vehicle_incentives_raw`) into standardized core daily and weekly tables.
- **Key Files**:
  - [`schema.sql`](./Uber%20Final%20Table/schema.sql): PostgreSQL DDL for `public.core_uber_daily` and `public.core_uber_weekly` with unique constraints, B-Tree indexes, and financial audit columns.
  - [`automation_script.py`](./Uber%20Final%20Table/automation_script.py): Production Python ETL engine implementing 04:00 AM IST shift cutoff, plate normalization, driver cash separation, and ON CONFLICT DO UPDATE upserts.
  - [`README.md`](./Uber%20Final%20Table/README.md): Architecture documentation, column dictionaries, 04:00 AM shift rule, and operational runbook.
- **Target Tables**: `public.core_uber_daily`, `public.core_uber_weekly` (PostgreSQL)

---

### 15. [Ola Final Table](./Ola%20Final%20Table/)
- **Description**: Production data pipeline and financial ledger engine aggregating raw Ola trip telemetry (`ola_raw_crns`) and financial transactions (`ola_raw_transactions`) into standardized core daily and weekly tables.
- **Key Files**:
  - [`schema.sql`](./Ola%20Final%20Table/schema.sql): PostgreSQL DDL for `public.core_ola_daily` and `public.core_ola_weekly` with unique constraints, B-Tree indexes, and Hisaab reconciliation columns.
  - [`automation_script.py`](./Ola%20Final%20Table/automation_script.py): Production Python ETL engine implementing net revenue calculation (`operator_bill_raw`), driver cash deductions, and debit/credit ledger resolution.
  - [`README.md`](./Ola%20Final%20Table/README.md): Architecture documentation, column dictionaries, and operational runbook.
- **Target Tables**: `public.core_ola_daily`, `public.core_ola_weekly` (PostgreSQL)

---

### 16. [Hisaab Final Table](./Hisaab%20Final%20Table/)
- **Description**: The definitive financial settlement and payout engine for LetzRyd. Consolidates multi-platform ride revenues (Uber, Ola, Rapido), daily vehicle attendance & rentals, G-form adjustments, and traffic challans into a 3-tier multi-grain ledger (Daily App Feed $\to$ Vehicle Breakdown $\to$ Consolidated Partner Bank Payout).
- **Key Files**:
  - [`schema.sql`](./Hisaab%20Final%20Table/schema.sql): PostgreSQL DDL for all 5 dedicated Hisaab tables (`hisaab_settlement_weeks`, `hisaab_adjustments_ledger`, `hisaab_daily_ledger`, `hisaab_vehicle_weekly`, `hisaab_partner_weekly`) with unique composite keys and lock triggers.
  - [`automation_script.py`](./Hisaab%20Final%20Table/automation_script.py): Production Python ETL pipeline handling daily continuous upserts, Sunday milestone incentive credits, weekly roll-up, partner payout consolidation, and Monday 11:00 AM lock enforcement.
  - [`audit_rules.md`](./Hisaab%20Final%20Table/audit_rules.md): Codified mathematical formulas, indemnity city exceptions, 1% Section 194C TDS logic, and dead mile GPS telematics rules audited from production Hisaab workbooks (BLR, HYD, MUM).
  - [`README.md`](./Hisaab%20Final%20Table/README.md): Full architectural runbook, data flow diagrams, schema specifications, and automation CLI instructions.
- **Target Tables**: `public.hisaab_settlement_weeks`, `public.hisaab_adjustments_ledger`, `public.hisaab_daily_ledger`, `public.hisaab_vehicle_weekly`, `public.hisaab_partner_weekly` (PostgreSQL)

---

---

### 17. [Traffic Challan Final Table](./Traffic%20Challan%20Final%20Table/)
- **Description**: Real-time unified master Single Source of Truth (`public.core_challans`) consolidating traffic violation events and rolling fine balances across manual Google Sheets (`sheet_challans`, 37,948 rows) and the automated Karnataka One traffic portal scraper (`vehicle_challans`, 1,129 rows).
- **Key Files**:
  - [`schema.sql`](./Traffic%20Challan%20Final%20Table/schema.sql): PostgreSQL DDL for `public.core_challans`, B-Tree indexes, plate and date parsers, and real-time triggers (`trg_sync_core_challan_from_sheet`, `trg_sync_core_challan_from_automation`).
  - [`automation_script.py`](./Traffic%20Challan%20Final%20Table/automation_script.py): Production Python health check and audit engine verifying sequence continuity (1..38,710), gapless IDs, scraper priority, and liability breakdowns.
  - [`data_issues.md`](./Traffic%20Challan%20Final%20Table/data_issues.md): Comprehensive catalog of 8 operational data anomalies (ISS-01 to ISS-08) including scraper precedence, rolling balances, and soft delete mechanics.
  - [`README.md`](./Traffic%20Challan%20Final%20Table/README.md): Master replication guide, end-to-end architecture diagram, data dictionaries, and operational runbook.
- **Target Table**: `public.core_challans` (PostgreSQL)
- **Primary Features**:
  - Deterministic Scraper Priority: Karnataka One government scraper takes precedence for Bangalore violations (711 active fines, Rs. 464,500).
  - Multi-city Google Sheet sourcing: Hyderabad (7,738 rows), Mumbai (7,362 rows), and remaining manual logs (37,999 total active records).
  - Gapless sequential primary key (`id` allocated via advisory lock `pg_advisory_xact_lock(888999222)` guaranteeing 0 sequence gaps).
  - Non-destructive soft delete preservation (`is_deleted = TRUE`).

---

### 18. [GPS Final Table](./GPS%20Final%20Table/)
- **Description**: Enterprise fleet telematics Single Source of Truth (`public.core_gps`) unifying daily distance tracking from the Intellicar API, performing intelligent device-suffix (`-A`/`-B`) and chassis VIN-to-registration resolution, enriching telematics with driver attribution from `core_daily_vehicle_status`, and raising instant alerts for unauthorized idle movement.
- **Key Files**:
  - [`schema.sql`](./GPS%20Final%20Table/schema.sql): PostgreSQL DDL for `public.core_gps`, 6 B-Tree performance indexes, plate cleaning function `fn_clean_gps_vehicle_number()`, and real-time trigger `trg_sync_core_gps_from_telematics`.
  - [`automation_script.py`](./GPS%20Final%20Table/automation_script.py): Production Python health check engine verifying 15 columns, sequence continuity (1..37,548), geographic coverage, status distribution, and idle movement alerts.
  - [`data_issues.md`](./GPS%20Final%20Table/data_issues.md): Comprehensive telematics engineering audit detailing device suffix collisions, pre-registration VIN tracking, concurrent multi-stream overwrites, and idle movement thresholds.
  - [`README.md`](./GPS%20Final%20Table/README.md): Architecture flowcharts, column data dictionary, trigger installation guide, and operational SQL queries.
- **Target Table**: `public.core_gps` (PostgreSQL)
- **Primary Features**:
  - Automated plate and VIN resolution: Strips hardware suffixes (`-A`, `-B`) and maps 189 pre-registration chassis VINs (`MA3...`) to active registration plates.
  - Real-time driver and custody enrichment: Ingestion triggers dynamically stamp `partner_id`, `partner_name`, `driver_phone`, `vehicle_status`, and `cohort` from `core_daily_vehicle_status`.
  - Unauthorized idle movement alert: Instant flags for vehicles clocking > 5.0 km while in yard (`RFD`) or workshop (`Maintenance`).
  - Zero-burn continuous sequence: 37,548 gapless records spanning 6,281,304.58 total fleet kilometers.

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
