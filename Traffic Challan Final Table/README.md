# Master Traffic Challan Pipeline: Single Source of Truth (`public.core_challans`)
**LetzRyd Engineering Blueprint & Master Replication Guide**

---

## 1. Executive Summary & Purpose

The **Master Traffic Challan Pipeline** unifies LetzRyd's multi-source traffic fine tracking into a single, high-performance, real-time Single Source of Truth (SSOT) table in PostgreSQL: **`public.core_challans`**.

### Integrated Source Systems
1. **`public.sheet_challans`**: Manual operational logs maintained across 38 weekly tabs in the unified Google Sheet (`LetzRyd_Sheet_Challans_Master`), ingested via Google Apps Script JDBC pipeline (36,239 records).
2. **`public.vehicle_challans`**: Automated portal scraping pipeline capturing direct Bangalore traffic violations from the Karnataka One Challan Portal (594 records total, 222 active fine records).

---

## 2. End-to-End System Architecture

```
+---------------------------------------------------------------------------------------------------+
|                                  OPERATIONAL INTAKE SOURCES                                       |
+-------------------------------------------------+-------------------------------------------------+
| 1. Google Sheets Operations Ledger              | 2. Karnataka One Traffic Portal Scraper         |
|    (38 Weekly Audit Cycles - Blr/Hyd/Mum)       |    (Automated Direct Scraper - Bangalore)       |
+-------------------------------------------------+-------------------------------------------------+
                         |                                                 |
                         | Google Apps Script JDBC                         | Python Selenium Scraper
                         v                                                 v
+-------------------------------------------------+-------------------------------------------------+
| public.sheet_challans                           | public.vehicle_challans                         |
+-------------------------------------------------+-------------------------------------------------+
                         |                                                 |
               AFTER INSERT/UPDATE/DELETE                        AFTER INSERT/UPDATE/DELETE
             [trg_sync_core_challan_from_sheet]                [trg_sync_core_challan_from_automation]
                         |                                                 |
                         +------------------------+------------------------+
                                                  |
                                                  v  (Transactional Advisory Lock: 888999222)
                               +-------------------------------------+
                               |      POSTGRESQL TRIGGER ENGINE      |
                               |  * Gapless Sequence: MAX(id) + 1    |
                               |  * Standardized Plate Clean         |
                               |  * Flexible Date & Time Parser      |
                               |  * Deterministic Scraper Priority   |
                               |  * Sheet Financial Enrichment       |
                               |  * Soft-Delete: is_deleted = TRUE   |
                               +-------------------------------------+
                                                  |
                                                  v  (<10ms Live Latency)
                               +-------------------------------------+
                               |         MASTER DESTINATION          |
                               |        public.core_challans         |
                               |     (36,461 Master Challan SSOT)    |
                               +-------------------------------------+
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
   - Upstream tables (`public.sheet_challans`, `public.vehicle_challans`) and their respective feeder pipelines remain 100% untouched.
2. **Instant Live Synchronization (<10ms)**:
   - Native PostgreSQL triggers (`trg_sync_core_challan_from_sheet`, `trg_sync_core_challan_from_automation`) execute immediately `AFTER INSERT OR UPDATE OR DELETE`.
3. **Deterministic Conflict Priority & Financial Enrichment**:
   - Natural Key Match = Standardized Vehicle Plate (`vehicle_reg_no`) + Notice Number (`notice_no`).
   - When a violation appears in both sources, the **Automated Scraper (`vehicle_challans`) takes precedence** for legal fine amount, violation date/time, offence description, and police station point.
   - Non-conflicting ledger metrics from Google Sheets (`previous_balance`, `sticker_fine`, driver `amount_paid`, `week_cycle`, `remarks`) enrich the master record without overwriting scraper legal data.
4. **Gapless Sequential Primary Keys (`1, 2, 3... N`)**:
   - Enforced via transactional advisory locking (`pg_advisory_xact_lock(888999222)`) computing `SELECT COALESCE(MAX(id), 0) + 1` atomically on inserts, eliminating sequence jumps caused by rolled-back transactions or duplicate checks.
5. **Permanent Archival & Soft Deletes (Zero Data Loss)**:
   - Source deletions trigger `is_deleted = TRUE` and record `deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.
   - Historical audits and finance records are preserved indefinitely.
6. **Standardized Clean Timestamps (IST without `+05:30`)**:
   - All datetime fields use `TIMESTAMP WITHOUT TIME ZONE` stored cleanly in Indian Standard Time (`Asia/Kolkata`).

---

## 4. Master Schema Data Dictionary (`public.core_challans`)

| Column Name | Data Type | Description | Sample Value |
|---|---|---|---|
| `id` | `BIGINT PRIMARY KEY` | Gapless sequential master ID | `1` |
| `source_system` | `VARCHAR(50)` | Provenance tag (`GOOGLE_SHEET`, `KARNATAKA_ONE_SCRAPER`, `MERGED_AUTOMATION_SHEET`) | `MERGED_AUTOMATION_SHEET` |
| `source_table` | `VARCHAR(100)` | Primary originating staging table | `vehicle_challans` |
| `sheet_challan_id` | `BIGINT` | Foreign reference to `public.sheet_challans(id)` | `36741` |
| `automated_challan_id` | `BIGINT` | Foreign reference to `public.vehicle_challans(id)` | `32415` |
| `vehicle_reg_no` | `VARCHAR(50) NOT NULL` | Standardized alphanumeric vehicle registration number | `KA01AB1234` |
| `rc_holder_name` | `VARCHAR(255)` | Registered RC owner name | `ANURAG SHARMA` |
| `notice_no` | `VARCHAR(100)` | Official traffic police notice / challan number | `KA0100234567` |
| `city` | `VARCHAR(100)` | Canonical operating city (`Bangalore`, `Hyderabad`, `Mumbai`) | `Bangalore` |
| `week_cycle` | `VARCHAR(100)` | Operating audit cycle identifier | `Week 38` |
| `violation_date` | `DATE` | Actual date of traffic offence | `2026-08-15` |
| `violation_time` | `TIME WITHOUT TIME ZONE` | Actual time of traffic offence | `14:30:00` |
| `notice_date` | `DATE` | Official notice generation date | `2026-08-16` |
| `audit_date` | `DATE` | Operational sheet audit date | `2026-08-20` |
| `violation_description`| `TEXT` | Specific offence description (e.g. Defective Number Plate, Red Light Jump) | `RIDING WITHOUT HELMET` |
| `police_station` | `VARCHAR(255)` | Jurisdiction police station / traffic unit | `Cubbon Park Traffic BCP` |
| `violation_location` | `VARCHAR(255)` | Landmark / intersection point of violation | `MG Road Junction` |
| `liability_type` | `VARCHAR(50)` | Categorization (`TRAFFIC_FINE`, `STICKER_FINE`, `ROLLING_BALANCE`) | `TRAFFIC_FINE` |
| `challan_amount` | `NUMERIC(12,2)` | Legal traffic fine assessed by authorities | `500.00` |
| `sticker_fine` | `NUMERIC(12,2)` | Internal company branding / sticker fine | `0.00` |
| `previous_balance` | `NUMERIC(12,2)` | Carried forward liability from preceding cycle | `100.00` |
| `amount_paid` | `NUMERIC(12,2)` | Total recovered / settled amount from driver | `200.00` |
| `total_pending` | `NUMERIC(12,2)` | Outstanding liability balance (`previous_balance + fine - amount_paid`) | `400.00` |
| `payment_status` | `VARCHAR(50)` | Settlement state (`PENDING`, `PARTIALLY_PAID`, `PAID`) | `PARTIALLY_PAID` |
| `remarks` | `TEXT` | Operations team field comments | `Recovered via weekly payout` |
| `source_tab` | `VARCHAR(150)` | Originating Google Sheet tab name | `Unified_Traffic_Challan_source` |
| `sheet_row_number` | `INTEGER` | Physical row index in source Google Sheet | `1542` |
| `scraped_at` | `TIMESTAMP WITHOUT TIME ZONE` | Scraper ingestion timestamp (IST) | `2026-09-08 11:20:00` |
| `is_deleted` | `BOOLEAN NOT NULL` | Soft-delete flag (Zero hard data destruction) | `FALSE` |
| `deleted_at` | `TIMESTAMP WITHOUT TIME ZONE` | Timestamp of deletion (IST) | `NULL` |
| `extra_attributes` | `JSONB` | Flexible extensibility JSON payload | `{}` |
| `created_at` | `TIMESTAMP WITHOUT TIME ZONE` | Initial creation timestamp (IST) | `2026-09-08 19:30:00` |
| `updated_at` | `TIMESTAMP WITHOUT TIME ZONE` | Last modification timestamp (IST) | `2026-09-08 19:30:00` |

---

## 5. Operations & Verification Commands

All automation and audit routines can be run directly from the command line:

```bash
# 1. Run Master Health & Reconciliation Audit
python automation_script.py --audit

# 2. Deploy Schema, Functions, Triggers & Perform Full Backfill
python automation_script.py --backfill

# 3. Execute Real-Time Trigger Lifecycle Verification
python ../../verify_core_challans_triggers.py
```

---

## 6. Live Database Baseline Metrics

- **Total Consolidated Records**: **36,461**
- **Active Operational Records (`is_deleted = FALSE`)**: **36,461**
- **Sequence Integrity**: Strictly continuous IDs `1` through `36,461` (Zero Gaps).
- **Source Breakdown**:
  - `GOOGLE_SHEET`: 36,239 records
  - `KARNATAKA_ONE_SCRAPER`: 222 records
- **Geographic Breakdown**:
  - Bangalore: 22,067 records
  - Hyderabad: 7,380 records
  - Mumbai: 7,014 records
