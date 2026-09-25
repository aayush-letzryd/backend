# Master Traffic Challan Pipeline: Single Source of Truth (`public.core_challans`)
**LetzRyd Engineering Blueprint & Master Replication Guide**

---

## 1. Executive Summary & Purpose

The **Master Traffic Challan Pipeline** unifies LetzRyd's multi-source traffic fine tracking into a single, high-performance, real-time Single Source of Truth (SSOT) table in PostgreSQL: **`public.core_challans`**.

### Integrated Source Systems
1. **`public.vehicle_challans`**: Automated portal scraping pipeline capturing official traffic violations from the Karnataka One Challan Portal for Bangalore vehicles (authoritative primary source for Bangalore).
2. **`public.sheet_challans`**: Manual operational logs maintained across 38 weekly cycles in Google Sheets (authoritative primary source for Mumbai and Hyderabad; historical fallback for Bangalore).

### Master Table Status & Live Metrics
- **Total Master Violations**: 6,078 authentic, discrete infractions (consolidated down from 61,773 bloated/duplicate rows).
- **Duplicate Violations Prevented**: 1,002 duplicate Bangalore fines eliminated through multi-source reconciliation.
- **Missing Violation Dates Recovered**: 251 fines recovered via fallback dates (`COALESCE(violation_date, notice_date, audit_date)`).
- **Zero Routine Audit Bloat**: 54,680 weekly zero-fine balance checks filtered out from the core table.
- **City Distribution**:
  - **Bangalore**: 4,304 records | ₹28,33,800.00 total fines | ₹21,30,100.00 technically pending dues
  - **Mumbai**: 1,180 records | ₹11,47,200.00 total fines | ₹15,57,000.00 technically pending dues
  - **Hyderabad**: 594 records | ₹3,12,235.00 total fines | ₹3,07,555.00 technically pending dues

---

## 2. End-to-End System Architecture

```
+---------------------------------------------------------------------------------------------------+
|                                  OPERATIONAL INTAKE SOURCES                                       |
+-------------------------------------------------+-------------------------------------------------+
| 1. Google Sheets Operations Ledger              | 2. Karnataka One Traffic Portal Scraper         |
|    (38 Weekly Cycles - Blr/Hyd/Mum)             |    (Playwright Automation - Bangalore)          |
+-------------------------------------------------+-------------------------------------------------+
                         |                                                 |
                         | Google Apps Script JDBC                         | Automated Playwright Scraper
                         v                                                 v
+-------------------------------------------------+-------------------------------------------------+
| public.sheet_challans                           | public.vehicle_challans                         |
| (STRICTLY READ-ONLY - NEVER MODIFIED/LOCKED)    | (STRICTLY READ-ONLY - NEVER MODIFIED/LOCKED)    |
+-------------------------------------------------+-------------------------------------------------+
                         \                                                 /
                          \                                               /
                           +----------------------+----------------------+
                                                  |
                                                  v  (Scheduled via pg_cron: 20 * * * *)
                               +-------------------------------------+
                               |      BATCH SYNCHRONIZATION ENGINE   |
                               |      public.sp_sync_core_challans() |
                               |  * No database triggers / locks     |
                               |  * Bangalore Scraper Priority       |
                               |  * Sheet Metadata Enrichment        |
                               |  * Fallback Date Recovery           |
                               |  * Exclusion of Balance Snapshots   |
                               +-------------------------------------+
                                                  |
                                                  v  (Execution time: ~0.6 seconds)
                               +-------------------------------------+
                               |         MASTER DESTINATION          |
                               |        public.core_challans         |
                               |     (6,078 Master Challan SSOT)     |
                               +-------------------------------------+
                                                  |
                                  +---------------+---------------+
                                  |                               |
                                  v                               v
                 +---------------------------------+  +-------------------------------+
                 |    Operational BI & Recovery    |  |     Downstream Hisaab         |
                 |   v_weekly_vehicle_pending...   |  |   Settlement Calculations     |
                 |   v_vehicle_pending_challans... |  |   (Driver Custody via Date)   |
                 +---------------------------------+  +-------------------------------+
```

---

## 3. Scraper Precedence & Multi-Source Policy

Per LetzRyd master data policy:
1. **Natural Business Key**: `(vehicle_reg_no, notice_no)`. A vehicle can never have the same police notice number twice.
2. **Bangalore Source Hierarchy**:
   - Official government notice numbers, violation descriptions, police station junctions, fine amounts, and payment statuses sourced from `public.vehicle_challans` take unconditional precedence over manual Google Sheet logs.
   - Matching Bangalore records from `public.sheet_challans` are merged on `(vehicle_reg_no, violation_date, challan_amount)` to enrich sheet remarks and row index without duplicating the fine.
   - Unmatched historical Bangalore records from the sheet are preserved as fallbacks (`source_priority = 'SHEET_FALLBACK'`).
3. **Mumbai & Hyderabad Hierarchy**:
   - `public.sheet_challans` is the primary source (`source_priority = 'SHEET_PRIMARY'`).
4. **Zero-Fine Routine Audits**:
   - 54,680 weekly balance snapshots (`challan_amount = 0` and `sticker_fine = 0`) are filtered out. They remain untouched in `sheet_challans` for ledger auditability.

---

## 4. Operational Queries: Pending Challans by Vehicle & Date

### Query 1: Unpaid Challans for a Specific Vehicle & Date Range
```sql
SELECT 
    vehicle_reg_no,
    violation_date,
    violation_time,
    notice_no,
    offence_description,
    police_station,
    challan_amount,
    sticker_fine,
    net_pending_amount,
    payment_status,
    source_system
FROM public.core_challans
WHERE vehicle_reg_no = 'KA05AP6034'
  AND violation_date BETWEEN '2026-07-01' AND '2026-08-31'
  AND payment_status = 'UNPAID'
ORDER BY violation_date ASC;
```

### Query 2: All Vehicles with Pending Challans (Rollup View)
```sql
SELECT 
    vehicle_reg_no,
    city,
    pending_challans_count,
    total_pending_amount,
    earliest_pending_date,
    latest_pending_date
FROM public.v_vehicle_pending_challans_summary
WHERE pending_challans_count > 0
ORDER BY total_pending_amount DESC;
```

### Query 3: Weekly Pending Dues per Vehicle (for Hisaab & Operations)
```sql
SELECT 
    settlement_week,
    vehicle_reg_no,
    city,
    pending_count,
    week_pending_amount,
    notice_numbers
FROM public.v_weekly_vehicle_pending_challans
WHERE settlement_week = 'CY26WK37' AND pending_count > 0
ORDER BY week_pending_amount DESC;
```

---

## 5. Driver Custody Reference for Hisaab

While driver custody logic is intentionally separated from `core_challans`, downstream Hisaab can correlate any violation to the active driver who held the vehicle on the `violation_date` using the following reference query:

```sql
SELECT 
    c.id AS challan_id,
    c.vehicle_reg_no,
    c.violation_date,
    c.notice_no,
    c.net_pending_amount,
    a.partner_id,
    a.driver_name,
    a.driver_phone,
    a.allocation_date
FROM public.core_challans c
JOIN public.core_vehicle_allocation a
  ON c.vehicle_reg_no = UPPER(REGEXP_REPLACE(a.vehicle_number, '[^A-Za-z0-9]', '', 'g'))
 AND c.violation_date >= a.allocation_date
 AND c.violation_date < COALESCE(
     (SELECT MIN(d.return_date) FROM public.core_dropoffs d 
      WHERE d.vehicle_number = a.vehicle_number AND d.return_date >= a.allocation_date),
     CURRENT_DATE + INTERVAL '1 day'
 )
WHERE c.payment_status = 'UNPAID';
```

---

## 6. Automation & Operational Runbook

### Running Manual Sync
```bash
python automation_script.py --sync
```

### Running Table Audit
```bash
python automation_script.py --audit
```

### Querying Specific Vehicle
```bash
python automation_script.py --vehicle KA05AP6034
```

### Querying Weekly Hisaab Cycle
```bash
python automation_script.py --weekly CY26WK37
```
