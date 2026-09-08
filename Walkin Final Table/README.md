# Master Walk-in Pipeline: Single Source of Truth (`public.core_walkin`)
**LetzRyd Engineering Blueprint & Table Replication Guide**

---

## 1. Executive Summary & Purpose

The **Master Walk-in Pipeline** unifies three independent, live operational walk-in intake systems into a single, high-performance, real-time Single Source of Truth (SSOT) table in PostgreSQL: **`public.core_walkin`**.

This document serves as both:
1. The **definitive technical specification** for the live Walk-in pipeline.
2. An **engineering replication guide** for teammates to clone and adapt this exact multi-table unification architecture for other business domains (such as Vehicle Allocations, Returns, Challans, and Inventory).

### Integrated Source Systems
1. **`public.sheet_walkins`**: Google Sheets form submissions captured at field hubs and synchronized in real time via Google Apps Script JDBC.
2. **`public.july_new_walkins`**: LetzRyd Web Portal candidate onboarding form (capturing Aadhaar, DL, KYC, referral channel, and photos).
3. **`public.july_existing_walkins`**: LetzRyd Web Portal returning partner visit logs (capturing operational visits for hisaab, maintenance, swaps, and complaints).

---

## 2. End-to-End System Architecture

```
+---------------------------------------------------------------------------------------------------+
|                                     OPERATIONAL INTAKE SOURCES                                    |
+------------------------------------+----------------------------------+---------------------------+
| 1. Google Sheets Form              | 2. Web Portal Candidate Form     | 3. Web Portal Visit Log   |
|    (Field Hub Executives)          |    (New Driver Onboarding)       |    (Returning Partners)   |
+------------------------------------+----------------------------------+---------------------------+
                  |                                   |                               |
                  | Google Apps Script JDBC           | FastAPI Backend               | FastAPI Backend
                  v                                   v                               v
+------------------------------------+----------------------------------+---------------------------+
| public.sheet_walkins               | public.july_new_walkins          | public.july_existing_walk |
+------------------------------------+----------------------------------+---------------------------+
                  |                                   |                               |
        AFTER INSERT/UPDATE/DELETE          AFTER INSERT/UPDATE/DELETE      AFTER INSERT/UPDATE/DELETE
        [trg_sync_core_walkin_from_sheet]   [trg_sync_core_walkin_from_portal] [trg_sync_core_walkin_from_ex]
                  |                                   |                               |
                  +-----------------------------------+-------------------------------+
                                                      |
                                                      v  (Transactional Advisory Lock: 777888999)
                                    +-----------------------------------+
                                    |        POSTGRESQL TRIGGER ENGINE  |
                                    |  * Gapless Sequence: MAX(id) + 1  |
                                    |  * Clean IST Timestamp Parsing    |
                                    |  * Canonical City & Phone Clean   |
                                    |  * Defensive String Bounding      |
                                    |  * Soft-Delete: is_deleted = TRUE |
                                    +-----------------------------------+
                                                      |
                                                      v  (<10ms Live Latency)
                                    +-----------------------------------+
                                    |        MASTER DESTINATION         |
                                    |        public.core_walkin         |
                                    |   (100% History & Full Audit)     |
                                    +-----------------------------------+
                                                      |
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

When designing an enterprise-grade Single Source of Truth across multiple disparate systems, this architecture enforces six non-negotiable guarantees:

1. **Zero Modifications to Source Systems**:
   - The source tables (`sheet_walkins`, `july_new_walkins`, `july_existing_walkins`) remain 100% untouched.
   - Zero modifications were required in Google Apps Script or the FastAPI portal code. Source systems remain decoupled.
2. **Instant Live Synchronization (<10ms)**:
   - Native PostgreSQL database triggers execute immediately `AFTER INSERT OR UPDATE OR DELETE`.
   - Any record typed into Google Sheets or submitted on the web portal appears in `core_walkin` in milliseconds without cron jobs or pollers.
3. **Gapless Sequential Primary Keys (`1, 2, 3... N`)**:
   - Normal PostgreSQL sequences (`BIGSERIAL`) experience sequence gaps when transactions abort or conflict.
   - To guarantee zero missed IDs, triggers acquire a transactional advisory lock (`pg_advisory_xact_lock(777888999)`) and assign `SELECT COALESCE(MAX(id), 0) + 1`. The ID range is guaranteed continuous with 0 missing integers.
4. **Permanent Archival & Soft Deletes (Zero Data Loss)**:
   - When a record is deleted in a source table, the trigger **refuses to delete the master row**.
   - Instead, it marks `is_deleted = TRUE` and `deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')`.
   - Downstream dashboards query `public.core_walkin WHERE is_deleted = FALSE`, while the complete history remains archived for recovery.
5. **Standardized Functional Keys vs. Verbatim Pass-Through**:
   - **Functional columns** used for joins and filtering (`city`, `phone_number`, `visiting_reason_category`) are normalized automatically.
   - **Verbatim columns** (`partner_name`, `remarks`, `aadhaar_number`) preserve raw human input exactly as entered.
   - **Defensive string bounding** (`LEFT(..., 255)`) protects against overflow exceptions if users paste large text blocks.
6. **Standardized Clean Timestamps (IST without `+05:30`)**:
   - All timestamp columns (`walkin_timestamp`, `created_at`, `updated_at`, `deleted_at`) are stored as `TIMESTAMP WITHOUT TIME ZONE` strictly in Indian Standard Time (Asia/Kolkata).
   - Prevents timezone offset confusion and ensures date arithmetic matches local operational calendars.

---

## 4. Engineering Replication Guide: How to Apply This Pattern to Other Tables

Follow this step-by-step blueprint whenever you need to merge multiple operational tables (e.g. `vehicle_allocations`, `returns`, `inventory`) into a unified master table.

### Step 1: Source Table Profiling & Field Mapping
- List all source tables and verify their primary keys and data types.
- Identify common domain keys (e.g., `vehicle_number`, `phone_number`, `event_date`).
- Classify fields into:
  * **Functional fields**: Require cleaning (strip phone non-digits, uppercase vehicle numbers, standardize cities).
  * **Verbatim fields**: Preserve raw text (driver names, notes, remarks).
  * **Provenance fields**: System name, source table name, original primary key ID.

### Step 2: Create the Master Destination Table (`core_xyz`)
Create the master table with:
- Dedicated columns for every distinct attribute across all sources (no data loss).
- Unique partial indexes on each source ID (`WHERE source_table_id IS NOT NULL`) to enforce 1-to-1 sync.
- Soft delete columns (`is_deleted BOOLEAN NOT NULL DEFAULT FALSE`, `deleted_at TIMESTAMP WITHOUT TIME ZONE`).
- Clean IST timestamp columns (`TIMESTAMP WITHOUT TIME ZONE`).

```sql
CREATE TABLE public.core_xyz (
    id BIGSERIAL PRIMARY KEY,
    source_system VARCHAR(50) NOT NULL,
    source_table VARCHAR(50) NOT NULL,
    source_a_id BIGINT,
    source_b_id INTEGER,
    event_date DATE NOT NULL,
    event_timestamp TIMESTAMP WITHOUT TIME ZONE,
    vehicle_number VARCHAR(20) NOT NULL,
    phone_number VARCHAR(20) NOT NULL,
    -- ... domain-specific columns ...
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMP WITHOUT TIME ZONE,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
);

-- Unique partial indexes per source table
CREATE UNIQUE INDEX uq_core_xyz_source_a ON public.core_xyz (source_a_id) WHERE source_a_id IS NOT NULL;
CREATE UNIQUE INDEX uq_core_xyz_source_b ON public.core_xyz (source_b_id) WHERE source_b_id IS NOT NULL;
```

### Step 3: Create the Active View
Provide downstream BI tools and web applications with a clean view of non-deleted rows:
```sql
CREATE OR REPLACE VIEW public.active_core_xyz AS
SELECT * FROM public.core_xyz WHERE is_deleted = FALSE;
```

### Step 4: Implement the Transactional PostgreSQL Trigger Pattern
For each source table, create a trigger function that handles `INSERT`, `UPDATE`, and `DELETE`:

```sql
CREATE OR REPLACE FUNCTION public.fn_sync_core_xyz_from_source_a()
RETURNS TRIGGER AS $$
DECLARE
    v_next_id BIGINT;
BEGIN
    -- 1. Handle DELETE -> Soft Delete in Master
    IF TG_OP = 'DELETE' THEN
        UPDATE public.core_xyz
        SET is_deleted = TRUE,
            deleted_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE source_a_id = OLD.id;
        RETURN OLD;
    END IF;

    -- 2. Handle INSERT -> Transactional Gapless Allocation
    IF TG_OP = 'INSERT' THEN
        PERFORM pg_advisory_xact_lock(999111222); -- Unique lock ID for this table
        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM public.core_xyz;

        INSERT INTO public.core_xyz (
            id, source_system, source_table, source_a_id,
            event_date, vehicle_number, phone_number,
            is_deleted, created_at, updated_at
        ) VALUES (
            v_next_id, 'SYSTEM_A', 'source_a', NEW.id,
            NEW.event_date, UPPER(TRIM(NEW.vehicle_number)), RIGHT(REGEXP_REPLACE(NEW.phone, '\D', '', 'g'), 10),
            FALSE, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        );
        PERFORM setval('public.core_xyz_id_seq', v_next_id, true);

    -- 3. Handle UPDATE -> Synchronize in-place
    ELSIF TG_OP = 'UPDATE' THEN
        UPDATE public.core_xyz SET
            event_date = NEW.event_date,
            vehicle_number = UPPER(TRIM(NEW.vehicle_number)),
            phone_number = RIGHT(REGEXP_REPLACE(NEW.phone, '\D', '', 'g'), 10),
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        WHERE source_a_id = NEW.id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_core_xyz_from_source_a
AFTER INSERT OR UPDATE OR DELETE ON public.source_a
FOR EACH ROW EXECUTE FUNCTION fn_sync_core_xyz_from_source_a();
```

### Step 5: Build the Idempotent Python Automation & Reconciliation Script
Create an `automation_script.py` with two core modes:
- `--audit`: Compares source row counts vs. target count, verifies gapless primary key continuity (`generate_series`), and prints category distributions.
- `--backfill`: Idempotently populates the master table from historical rows if a database re-index is ever needed.

### Step 6: Allocate Domain-Specific Advisory Lock IDs
To prevent cross-domain lock contention where different tables block each other's inserts, each engineering domain must use a dedicated 64-bit advisory lock integer:

| Business Domain | Master Table Name | Dedicated Advisory Lock ID |
|:---|:---|:---|
| **Walk-in & Partner Visits** | `public.core_walkin` | `777888999` |
| **Vehicle Allocation** | `public.core_vehicle_allocation` | `777888001` |
| **Vehicle Dropoff / Returns** | `public.core_vehicle_dropoff` | `777888002` |
| **Traffic Challans** | `public.core_traffic_challans` | `777888003` |
| **Partner Onboarding** | `public.core_partner_onboarding` | `777888004` |
| **Financial Adjustments** | `public.core_adjustments` | `777888005` |
| **Vehicle Accidents** | `public.core_accidents` | `777888006` |

### Step 7: Enforce the 3-Tier Data Quality Policy
Whenever you build triggers and backfill logic, categorize every column into one of three tiers:
1. **Tier 1: Functional Standardization**:
   - Fields used in joins, foreign keys, or group-by reporting (e.g. `phone_number`, `vehicle_number`, `city`, `visiting_reason_category`).
   - Must be strictly sanitized (strip non-digits from phones, uppercase and format vehicle registration plates, canonicalize cities).
2. **Tier 2: Verbatim Pass-Through with Defensive String Bounding**:
   - Fields containing human-entered text (e.g. `full_name`, `remarks`, `visit_notes`, `lead_channel_details`).
   - Store exactly what the user typed without altering spelling.
   - **Crucial**: Always wrap with `LEFT(val, max_column_length)` to protect against SQL character overflow exceptions (`SQLSTATE 22001`).
3. **Tier 3: Zero Source Table Mutability**:
   - Source systems (`sheet_walkins`, `july_new_walkins`, Google Sheets) must remain strictly read-only to the pipeline.
   - Never run DDL modifications, column drops, or updates against source tables.

---

## 5. Complete 42-Column Master Field Dictionary (`public.core_walkin`)

| # | Column Name | SQL Type | Nullable | Source in `sheet_walkins` | Source in `july_new_walkins` | Source in `july_existing_walkins` | Transformation / Business Logic |
|:---|:---|:---|:---|:---|:---|:---|:---|
| 1 | `id` | `BIGINT` | NO | Generated | Generated | Generated | Gapless sequential integer (`1..N`) via `pg_advisory_xact_lock`. |
| 2 | `source_system` | `VARCHAR(50)` | NO | `'GOOGLE_SHEET'` | `'PORTAL_NEW'` | `'PORTAL_EXISTING'` | Originating ingestion pipeline. |
| 3 | `source_table` | `VARCHAR(50)` | NO | `'sheet_walkins'` | `'july_new_walkins'` | `'july_existing_walkins'` | Source table name. |
| 4 | `sheet_walkin_id` | `BIGINT` | YES | `id` | `NULL` | `NULL` | Foreign reference to `sheet_walkins.id`. |
| 5 | `portal_new_walkin_id` | `INTEGER` | YES | `NULL` | `id` | `NULL` | Foreign reference to `july_new_walkins.id`. |
| 6 | `portal_existing_walkin_id` | `INTEGER` | YES | `NULL` | `NULL` | `id` | Foreign reference to `july_existing_walkins.id`. |
| 7 | `walkin_type` | `VARCHAR(50)` | NO | Reason-derived | `'NEW_CANDIDATE'` | `'EXISTING_PARTNER'` | Distinguishes candidate onboarding from partner visits. |
| 8 | `walkin_date` | `DATE` | NO | Derived from timestamp | `event_date` | `event_date` | Calendar date (`YYYY-MM-DD`) in IST. |
| 9 | `walkin_time` | `VARCHAR(20)` | YES | `HH24:MI` from timestamp | `enquiry_time` | `enquiry_time` | Time of day string. |
| 10 | `walkin_timestamp` | `TIMESTAMP` | YES | `submission_timestamp` (IST) | Synthesized date + time (IST) | Synthesized date + time (IST) | Full timestamp without timezone offset. |
| 11 | `city` | `VARCHAR(100)` | NO | `city` | `city` | `city` | Canonical hub: `Bengaluru`, `Hyderabad`, `Mumbai`. |
| 12 | `operating_place` | `VARCHAR(150)` | YES | `NULL` | `operating_place` | `NULL` | Specific operating hub/depot location. |
| 13 | `full_name` | `VARCHAR(255)` | NO | `partner_name` | `person_name` | `person_name` | Full name preserved verbatim (bounded to 255 chars). |
| 14 | `first_name` | `VARCHAR(100)` | YES | Token 1 of name | `first_name` | `first_name` | First name token. |
| 15 | `last_name` | `VARCHAR(100)` | YES | Token 2+ of name | `last_name` | `last_name` | Surname or remaining tokens. |
| 16 | `phone_number` | `VARCHAR(20)` | NO | `partner_number` | `person_number` | `person_number` | Standardized 10-digit mobile number. |
| 17 | `partner_role` | `VARCHAR(100)` | YES | `NULL` | `interested_position` | `partner_type` | `Driver`, `Operator`, or `Individual`. |
| 18 | `dl_number` | `VARCHAR(50)` | YES | `dl_number` | `dl_number` | `NULL` | Uppercase driving license; `NA`/`None` set to `NULL`. |
| 19 | `aadhaar_number` | `VARCHAR(50)` | YES | `NULL` | `aadhaar_number` | `NULL` | 12-digit Aadhaar number from portal onboarding. |
| 20 | `dl_image_url` | `TEXT` | YES | `NULL` | `dl_image` | `NULL` | Cloud/S3 storage URL for driving license scan. |
| 21 | `aadhaar_image_url` | `TEXT` | YES | `NULL` | `aadhaar_image` | `NULL` | Cloud/S3 storage URL for Aadhaar card scan. |
| 22 | `visiting_reason` | `TEXT` | YES | `visiting_reason` | `visiting_reason` | `visiting_reason` | Verbatim reason text entered by submitter. |
| 23 | `visiting_reason_category` | `VARCHAR(100)` | YES | Categorized | Categorized | Categorized | `ONBOARDING`, `ENQUIRY`, `PAYOUT_HISAAB`, `VEHICLE_MAINTENANCE`, `MEETING_COMPLAINT`, `OTHER`. |
| 24 | `joined_status` | `VARCHAR(100)` | YES | `joined_status` | `joined_status` | `NULL` | Raw conversion status string. |
| 25 | `is_joined` | `BOOLEAN` | YES | Evaluated boolean | Evaluated boolean | `NULL` | Standard boolean conversion indicator. |
| 26 | `joined_date` | `DATE` | YES | `joined_date` | `NULL` | `NULL` | Date candidate formally joined fleet. |
| 27 | `submission_status` | `VARCHAR(50)` | YES | `'Submitted'` | `submission_status` | `'Submitted'` | Form workflow status (`Draft`, `Submitted`). |
| 28 | `lead_channel` | `VARCHAR(100)` | YES | `NULL` | `lead_channel` | `NULL` | Marketing channel (`Direct Walk-in`, `Referral`, etc.). |
| 29 | `lead_channel_details`| `VARCHAR(255)` | YES | `NULL` | `lead_channel_details`| `NULL` | Specific marketing campaign or location. |
| 30 | `referred_by_name` | `VARCHAR(255)` | YES | `NULL` | `referred_by_name` | `NULL` | Referring partner or employee name. |
| 31 | `referred_by_phone` | `VARCHAR(50)` | YES | `NULL` | `referred_by_phone`| `NULL` | Referring partner contact number. |
| 32 | `attending_executive` | `VARCHAR(150)` | YES | `attending_executive` | Resolved employee name | Resolved employee name | Employee name who handled the visit. |
| 33 | `attending_executive_id`| `INTEGER` | YES | `NULL` | `created_by` / `exec_id` | `created_by` / `exec_id` | Portal user ID of attending executive. |
| 34 | `submitter_email` | `VARCHAR(255)` | YES | `submitter_email` | Resolved employee email| Resolved employee email| Email address of person submitting record. |
| 35 | `remarks` | `TEXT` | YES | `remarks` | `remarks` | `NULL` | Verbatim notes entered during intake. |
| 36 | `visit_notes` | `TEXT` | YES | `NULL` | `NULL` | `visit_notes` | Specific resolution notes for partner visits. |
| 37 | `sheet_row_number` | `INTEGER` | YES | `sheet_row_number` | `NULL` | `NULL` | Original row index in Google Sheet. |
| 38 | `created_at` | `TIMESTAMP` | YES | Submission time (IST) | Creation time (IST) | Creation time (IST) | Record creation timestamp in IST. |
| 39 | `updated_at` | `TIMESTAMP` | YES | Update time (IST) | Update time (IST) | Update time (IST) | Record modification timestamp in IST. |
| 40 | `is_deleted` | `BOOLEAN` | NO | Soft-delete flag | Soft-delete flag | Soft-delete flag | `FALSE` for active rows, `TRUE` when deleted in source. |
| 41 | `deleted_at` | `TIMESTAMP` | YES | Deletion time (IST) | Deletion time (IST) | Deletion time (IST) | Timestamp when row was deleted in source table. |
| 42 | `extra_attributes` | `JSONB` | YES | `'{}'::jsonb` | `'{}'::jsonb` | `'{}'::jsonb` | Flexible JSON storage for future unmapped fields. |

---

## 6. Directory Contents & Repository Structure

```
Walkin Final Table/
├── README.md               # This architectural specification and replication blueprint
├── schema.sql              # Complete PostgreSQL DDL, indexes, and 3 live trigger functions
├── automation_script.py    # CLI engine for reconciliation health audits and backfilling
└── data_issues.md          # Operational data quality anomalies catalog (ISS-01 to ISS-06)
```

---

## 7. Operational Runbook & CLI Commands

### 7.1 Running Health & Reconciliation Audit
To verify live counts, ID continuity, and city/reason distributions:
```bash
# Pass DB credentials via environment variables:
export DB_HOST="YOUR_DB_HOST_HERE"
export DB_PASSWORD="YOUR_DB_PASSWORD_HERE"

python automation_script.py --audit
```

**Expected Healthy Output:**
```
=== Core Walkin Health & Reconciliation Audit ===
Source: sheet_walkins         : 889 rows
Source: july_new_walkins      : 82 rows
Source: july_existing_walkins : 8 rows
Target: core_walkin (Total)   : 979 rows (Active: 979, Soft-Deleted: 0)
Primary Key Range             : ID 1 to ID 979
Gapless ID Integrity          : PASSED (0 missing IDs)
Reconciliation Status         : MATCHED
```

### 7.2 Running an Idempotent Backfill
If the table is ever re-created from scratch or needs an initial backfill:
```bash
python automation_script.py --backfill
```

### 7.3 How to Add New Columns in the Future
If a source system introduces a new form field (for example, `driving_experience_years`):
1. **Add column to master table**:
   ```sql
   ALTER TABLE public.core_walkin ADD COLUMN IF NOT EXISTS driving_experience_years INTEGER;
   ```
2. **Update the corresponding trigger function** in `schema.sql`:
   - Add `NEW.driving_experience_years` to the `INSERT` column and value lists.
   - Add `driving_experience_years = NEW.driving_experience_years` to the `UPDATE` list.
   - Re-run `schema.sql` (trigger functions replace seamlessly without table locks or downtime).

### 7.4 Standard Operational Queries

**Query Active Walk-Ins for Live Dashboards:**
```sql
SELECT id, walkin_date, walkin_time, city, full_name, phone_number, visiting_reason_category, source_system
FROM public.core_walkin
WHERE is_deleted = FALSE
ORDER BY walkin_date DESC, id DESC
LIMIT 50;
```

**Audit Deleted Rows:**
```sql
SELECT id, source_system, source_table, full_name, phone_number, deleted_at
FROM public.core_walkin
WHERE is_deleted = TRUE
ORDER BY deleted_at DESC;
```

**City Conversion Funnel:**
```sql
SELECT 
    city,
    count(*) AS total_walkins,
    count(CASE WHEN is_joined = TRUE THEN 1 END) AS joined_count,
    round(count(CASE WHEN is_joined = TRUE THEN 1 END) * 100.0 / count(*), 1) AS conversion_rate_pct
FROM public.core_walkin
WHERE is_deleted = FALSE
GROUP BY city
ORDER BY total_walkins DESC;
```
