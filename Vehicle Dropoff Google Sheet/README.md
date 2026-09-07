# Vehicle Dropoff Data Pipeline (`sheet_dropoffs`)

**Assigned POC**: Sushant  
**Target Table**: `public.sheet_dropoffs`  
**Master Source Sheet**: `Pan India Master Sheet` (Tab: `Drop off History`)  
**Target Master Sheet**: `LetzRyd_Sheet_Dropoffs_Master` (Tab: `Unified_Dropoff_source`)  
**Downstream Target**: Feeds `dropoff_final` (Driver Hisaab Engine)  

---

## 1. Architecture & Pipeline Overview

The **Vehicle Dropoff Pipeline** ingests historical and active vehicle return logs across Pan-India operations (Bangalore, Hyderabad, Mumbai).

```mermaid
flowchart LR
    A[Pan India Master Sheet - Drop off History] -->|Import/Sync| B[LetzRyd_Sheet_Dropoffs_Master]
    B -->|handleOnEdit / Batch Ingestion| C[PostgreSQL public.sheet_dropoffs]
    C -->|Downstream ETL| D[public.dropoff_final - Driver Hisaab Engine]
```

---

## 2. Table Schema (`public.sheet_dropoffs`)

| Column Name | Data Type | Constraint | Description |
| :--- | :--- | :--- | :--- |
| `dropoff_id` | `VARCHAR(100)` | `PRIMARY KEY` | Deterministic synthetic primary key (`DROP-<Plate>-<YYYYMMDD>-<DriverHash>`). |
| `source_row` | `INTEGER` | | Source row index in master sheet for audit traceability. |
| `return_date` | `DATE` | `NOT NULL` | Standardized ISO return date (`YYYY-MM-DD`). |
| `return_type` | `VARCHAR(50)` | `NOT NULL` | Reason category (`Attrition`, `Repair and Maintenance`, `Force Recovery`). |
| `driver_id` | `VARCHAR(50)` | | Driver / Operator ID (`LETZBLR...`, `LETZHYD...`, `LETZMUM...`). |
| `driver_name` | `VARCHAR(100)` | | Cleaned driver name. |
| `driver_type` | `VARCHAR(30)` | | Driver classification (`Individual`, `Operator`). |
| `vehicle_number` | `VARCHAR(20)` | `NOT NULL` | Standardized uppercase alphanumeric plate (`KA05AP6040`). |
| `city` | `VARCHAR(50)` | `NOT NULL` | Canonical city name (`Bangalore`, `Hyderabad`, `Mumbai`). |
| `negative_balance` | `NUMERIC(12,2)`| | Ola negative wallet liability balance. |
| `sync_status` | `VARCHAR(20)` | | Status token (`SYNCED`). |
| `created_at` | `TIMESTAMPTZ` | | Record insertion timestamp. |
| `updated_at` | `TIMESTAMPTZ` | | Record modification timestamp. |

---

## 3. Data Transformation & Hygiene Rules

1. **Repeated Header Stripping (`ISS-01`)**: Drops embedded header copy-paste rows (`Return Date = 'Return Date'`).
2. **Multi-Format Date Normalization (`ISS-02`)**: Converts `DD/MM/YYYY`, Excel serial integers (`46272`), and ISO formats into `YYYY-MM-DD`.
3. **Driver ID & Name Coalescing (`ISS-03`, `ISS-04`)**: Unifies missing/null drivers to `'UNKNOWN_DRIVER'` and `'Unknown Driver'`.
4. **Plate Sanitization (`ISS-05`)**: Strips spaces, hyphens, and lowercase characters.
5. **Ola Negative Balance Cleaning (`ISS-06`)**: Cleans currency symbols, commas, and negative signs into signed `NUMERIC(12,2)`.
6. **Driver Classification Casing & Fallback (`ISS-07`, `ISS-08`)**: Title-cases driver types and infers missing types from `LETZ%IP%` ID prefixes.
7. **Canonical City Mapping (`ISS-09`)**: Normalizes `BLR`, `HYD`, `MUM` to `Bangalore`, `Hyderabad`, `Mumbai`.
8. **Deterministic Key Generation (`ISS-11`)**: Generates collision-proof composite keys for multiple returns on the same calendar day.

---

## 4. Live Apps Script Deployment

1. Open [LetzRyd_Sheet_Dropoffs_Master](https://docs.google.com/spreadsheets/d/1lb2BArHkQynUSA2hs_GAhCdjhOlwGIFIVjqA32Jw5M8/edit?usp=sharing).
2. Go to **Extensions $\to$ Apps Script**.
3. Paste the contents of `dropoff_pipeline_appscript.js`.
4. Run `setupTriggers()` to activate real-time `handleOnEdit` event streaming.
