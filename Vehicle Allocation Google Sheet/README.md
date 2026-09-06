# Vehicle Allocation Live Pipeline: Google Sheet to PostgreSQL

Production automated synchronization pipeline connecting the Google Sheet `Vehicle Allocation` dataset to the centralized PostgreSQL database table `public.sheet_vehicle_allocations`.

---

## 1. System Architecture

```
+------------------------------------+
|  Pan India Master Spreadsheet      |
|  Tab: "Vehicle Allocation"         |
|  (View-Only Fleet Master Sheet)    |
+-----------------+------------------+
                  |
                  | Direct in-memory read (openById)
                  v
+------------------------------------+
|  Google Apps Script Engine         |
|  Spreadsheet: allocation_form      |
|  - Dynamic Header Mapping          |
|  - 24 Standardization Rules        |
|  - Zero-Burn CTE Upsert            |
|  - LockService Concurrency Guard   |
+-----------------+------------------+
                  |
                  | JDBC SSL Connection (Port 5432)
                  v
+------------------------------------+
|  PostgreSQL Database Server        |
|  Host: YOUR_DB_HOST_HERE           |
|  Table: sheet_vehicle_allocations  |
+------------------------------------+
```

---

## 2. Key Technical Innovations

1. **Direct Background Read (Bypassing IMPORTRANGE)**:
   - Because the master sheet contains over 7,000 rows and 35 columns, formula-based `=IMPORTRANGE()` approaches suffer from calculation freezes, cell limit errors, and stale cache.
   - The script runs from a separate container spreadsheet (`allocation_form`) and reads the master sheet directly in memory using `SpreadsheetApp.openById("MASTER_ID").getSheetByName("Vehicle Allocation")`.
   - This keeps the user's sheet lightweight while allowing real-time access to live fleet allocation records.

2. **Zero-Burn Sequence ID CTE Query**:
   - Standard PostgreSQL `INSERT ... ON CONFLICT DO UPDATE` evaluates `nextval()` before conflict detection, which burns auto-increment IDs on every scheduled check.
   - We utilize a Common Table Expression (CTE) upsert:
     ```sql
     WITH incoming AS (...),
     upd AS (
         UPDATE sheet_vehicle_allocations a
         SET ...
         FROM incoming i
         WHERE a.allocation_date = i.alloc_date 
           AND a.vehicle_number = i.veh_num 
           AND a.driver_phone = i.driver_phone
         RETURNING a.id
     )
     INSERT INTO sheet_vehicle_allocations (...)
     SELECT nextval('sheet_vehicle_allocations_id_seq'), ...
     FROM incoming i
     WHERE NOT EXISTS (SELECT 1 FROM upd);
     ```
   - Existing records are updated in place with **0 sequence numbers consumed**, ensuring an unbroken, continuous sequence (`1, 2, 3, ...`) with zero gaps.

3. **Sliding Window Catch-Up Daemon**:
   - The automated 1-minute time-driven trigger (`syncRecentAllocations`) scans the bottom 100 physical rows of the Master Sheet.
   - Execution latency is under 3 seconds, staying well clear of Google Apps Script quota limits.

---

## 3. Database Schema Overview

The complete DDL is documented in [`schema.sql`](./schema.sql).

- **Table**: `public.sheet_vehicle_allocations`
- **Columns**: 39 columns total (35 operational columns + `id`, `sheet_row_number`, `created_at`, `updated_at`).
- **Conflict Key**: `(allocation_date, vehicle_number, driver_phone)`.
- **Deduplication Policy**: **Keep Latest by Timestamp**. When multiple submissions match the unique conflict key, the row is updated in place with the latest media links, lease agreements, and odometer readings.

---

## 4. Deployment Runbook

1. Open your control spreadsheet (**`allocation_form`**).
2. Navigate to **Extensions -> Apps Script**.
3. Paste the contents of [`allocation_pipeline_appscript.js`](./allocation_pipeline_appscript.js) into `Code.gs`.
4. Update `CONFIG` with your production database credentials:
   ```javascript
   const CONFIG = {
     masterSpreadsheetId: "YOUR_MASTER_SPREADSHEET_ID",
     masterTabName: "Vehicle Allocation",
     dbHost: "YOUR_DB_HOST",
     dbPort: "5432",
     dbName: "postgres",
     dbUser: "postgres",
     dbPassword: "YOUR_DB_PASSWORD"
   };
   ```
5. Save the script and refresh the Google Sheet.
6. Use the **`LetzRyd Allocation Sync`** menu:
   - **1. Test Database Connection**: Confirms JDBC reachability.
   - **2. Sync Recent 100 Allocations**: Performs an instant catch-up sync.
   - **3. Install Automated 1-Min Trigger**: Registers the background time-driven trigger.

---

## 5. Standardization Issues Catalog

All 24 data quality issues identified during dataset profiling and their resolution rules are cataloged in [`data_issues.md`](./data_issues.md).
