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
- **Target Table**: `public.sheet_walkins` $\to$ `public.core_walkins`

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

## Infrastructure Overview

- **Primary Database Host**: `35.200.196.113:5432`
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
