# Master Traffic Challan Pipeline: Single Source of Truth (`public.core_challans`)
**LetzRyd Engineering Blueprint & Master Replication Guide**

---

## 1. Executive Summary & Purpose

The **Master Traffic Challan Pipeline** unifies LetzRyd's multi-source traffic fine tracking into a single, high-performance, real-time Single Source of Truth (SSOT) table in PostgreSQL: **`public.core_challans`**.

### Integrated Source Systems
1. **`public.sheet_challans`**: Manual operational logs maintained across 38 weekly tabs in the unified Google Sheet (`LetzRyd_Sheet_Challans_Master`), ingested via Google Apps Script JDBC pipeline (37,948 upstream records supplying 37,999 active core records across Bangalore, Hyderabad, and Mumbai).
2. **`public.vehicle_challans`**: Automated portal scraping pipeline capturing official traffic violations from the Karnataka One Challan Portal (1,129 upstream records supplying 711 active fine records totaling Rs. 464,500 in pending fines).

### Master Table Status & Live Metrics
- **Total Master Records**: 38,710
- **Active Operational Records**: 38,659
- **Soft Deleted Records**: 51
- **Primary Key Continuity**: Gapless sequential IDs from 1 to 38,710 (0 gaps, 0 sequence burning)
- **Source Breakdown**:
  - `GOOGLE_SHEET`: 37,999 records | Rs. 87,946,839.00 pending liability
  - `KARNATAKA_ONE_SCRAPER`: 711 records | Rs. 464,500.00 pending liability
- **City Breakdown**:
  - Bangalore: 23,610 records | Rs. 25,280,100.00 pending liability
  - Hyderabad: 7,738 records | Rs. 19,001,895.00 pending liability
  - Mumbai: 7,362 records | Rs. 44,129,344.00 pending liability

---

## 2. End-to-End System Architecture

```
+---------------------------------------------------------------------------------------------------+
|                                  OPERATIONAL INTAKE SOURCES                                       |
+-------------------------------------------------+-------------------------------------------------+
| 1. Google Sheets Operations Ledger              | 2. Karnataka One Traffic Portal Scraper         |
|    (38 Weekly Audit Cycles - Blr/Hyd/Mum)       |    (Node.js Playwright Pipeline - Bangalore)     |
+-------------------------------------------------+-------------------------------------------------+
                         |                                                 |
                         | Google Apps Script JDBC                         | Automated Playwright / Cloud Runner
                         v                                                 v
+-------------------------------------------------+-------------------------------------------------+
| public.sheet_challans                           | public.vehicle_challans                         |
| (37,948 Rows)                                   | (1,129 Rows)                                    |
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
                               |  * Scraper Precedence for Bangalore |
                               |  * Sheet Financial Enrichment       |
                               |  * Soft-Delete: is_deleted = TRUE   |
                               +-------------------------------------+
                                                  |
                                                  v  (<10ms Live Latency)
                               +-------------------------------------+
                               |         MASTER DESTINATION          |
                               |        public.core_challans         |
                               |     (38,710 Master Challan SSOT)    |
                               +-------------------------------------+
                                                  |
                                  +---------------+---------------+
                                  |                               |
                                  v                               v
                 +---------------------------------+  +-------------------------------+
                 |      Live Operations / BI       |  |  Audit & Compliance History   |
                 |   (WHERE is_deleted = FALSE)    |  |  (WHERE is_deleted = TRUE)    |
                 |         38,659 Records          |  |           51 Records          |
                 +---------------------------------+  +-------------------------------+
```

---

## 3. Scraper Precedence & Multi-Source Policy

Per LetzRyd master data policy:
1. **Natural Business Key**: `(vehicle_reg_no, notice_no, week_cycle)`.
2. **Karnataka One Scraper Priority**:
   - For Karnataka / Bangalore violations, official government fine amounts, violation descriptions, police station jurisdictions, and notice generation dates sourced from `public.vehicle_challans` take unconditional precedence over manual Google Sheet logs.
3. **Google Sheet Enrichment**:
   - Google Sheet records supply all non-Karnataka records (Hyderabad, Mumbai) and enrich historical rolling balances (`previous_balance`), LetzRyd sticker fines (`sticker_fine`), driver salary deductions (`amount_paid`), and internal ops remarks.
4. **Soft Deletions**:
   - Deletions from upstream sources flag `is_deleted = TRUE` and record `deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`, preserving complete auditability.

---

## 4. Automation & Verification Commands

To verify table health and sequence continuity, run:

```bash
python "Traffic Challan Final Table/automation_script.py"
```

To run full schema synchronization or re-create views and triggers:

```bash
psql -h 35.200.196.113 -U postgres -d postgres -f "Traffic Challan Final Table/schema.sql"
```
