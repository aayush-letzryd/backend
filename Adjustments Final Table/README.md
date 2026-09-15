# LetzRyd Adjustments Master Architecture & Runbook

This directory contains the production schema, real-time synchronization triggers, consolidation procedures, and verification engine for **`public.core_adjustments`**.

---

## 1. System Architecture Overview

`public.core_adjustments` is the Single Source of Truth (SSOT) consolidating all financial debits, credits, pass fees, penalties, and deposit conversions for partners across both intake channels:

```
[ Google Sheet: Adjustment-Form ]
              │
              ▼ (Apps Script JDBC Batch Sync)
  [ public.sheet_adjustments ] (14,909 rows)
              │
              ▼ (trg_sheet_adjustments_sync / Advisory Lock 777333444)
  ┌────────────────────────────────────────────────────────┐
  │              public.core_adjustments                   │
  │     (Single Source of Truth - 14,476 clean rows)       │
  └────────────────────────────────────────────────────────┘
              ▲ (trg_july_partner_adjustment_sync)
              │
  [ public.july_partner_adjustment ] (15 rows)
              ▲
              │
   [ Web Portal: Adjustments Form ]
```

---

## 2. Key Technical Innovations & Guarantees

1. **Dual-Source Auto-Merging**:
   - Matches incoming records across Sheet and Portal on `(partner_phone, vehicle_number, adjustment_date, amount, adjustment_type)` or exact source reference IDs.
   - When matching records exist in both channels, updates `data_source = 'MERGED'` and aggregates source references (`source_reference_id = 'ADJ-PORTAL-1,ADJ-SHT-105'`).
2. **Gapless 1..N ID Continuity**:
   - Zero sequence burning via transactional advisory lock `pg_advisory_xact_lock(777333444)` and manual counter initialization.
   - Preserves contiguous IDs (1..14,476) with 0 gaps.
3. **Pure IST Timestamps**:
   - All timestamps (`created_at`, `updated_at`, `deleted_at`) use `TIMESTAMP WITHOUT TIME ZONE` stored in Indian Standard Time (UTC+05:30) with zero timezone offset drift.
4. **Soft-Delete Architecture**:
   - Trigger deletions mark `is_deleted = TRUE` and record `deleted_at`, preserving historical auditability.
   - View `public.active_core_adjustments` filters exclusively for active adjustments (`is_deleted = FALSE`).

---

## 3. Data Dictionary (`public.core_adjustments`)

- **`id`** (`BIGINT PRIMARY KEY`): Gapless contiguous sequence identifier.
- **`adjustment_id`** (`VARCHAR(100) UNIQUE NOT NULL`): Natural business key (e.g. `ADJ-SHT-14900` or `ADJ-PORTAL-5`).
- **`partner_id`** (`VARCHAR(100)`): Standardized partner code (e.g. `LETZBLR9876543210`).
- **`partner_name`** (`VARCHAR(255)`): Full name of driver or fleet operator.
- **`partner_phone`** (`VARCHAR(100)`): Clean 10-digit mobile number.
- **`partner_type`** (`VARCHAR(100)`): Entity classification (`Individual`, `Operator`, `Fleet`).
- **`vehicle_number`** (`TEXT`): Vehicle registration plate or batch list.
- **`city_name`** (`VARCHAR(100) NOT NULL`): Operating hub (`Bengaluru`, `Mumbai`, `Hyderabad`).
- **`adjustment_type`** (`VARCHAR(100) NOT NULL`): Direction of adjustment (`Credit`, `Debit`, `Deposit Conversion`).
- **`adjustment_nature`** (`VARCHAR(100)`): Nature of adjustment (`Monetary`, `Non-Monetary`).
- **`adjustment_level`** (`VARCHAR(100)`): Operational target (`Driver`, `Operator`).
- **`adjustment_date`** (`DATE NOT NULL`): Accounting service date the adjustment applies to.
- **`amount`** (`NUMERIC(12,2) NOT NULL`): Absolute monetary amount in INR.
- **`remittance_towards`** (`VARCHAR(255)`): Category (e.g. `Rent`, `Challan`, `Fastag`, `Maintenance`).
- **`adjustment_related_to`** (`VARCHAR(255)`): Contextual reason for adjustment.
- **`hisaab_number`** (`VARCHAR(100)`): Settlement period tag (e.g. `CY25WK21`).
- **`hisaab_week_number`** (`INTEGER`): Numeric week index (e.g. `21`).
- **`contested_line_items`** (`JSONB`): Contested items metadata from web portal.
- **`severity_level`** (`VARCHAR(100)`): Priority (`Low`, `Medium`, `High`).
- **`cost_level`** (`VARCHAR(100)`): Cost allocation (`Direct`, `Indirect`).
- **`remarks`** (`TEXT`): Operational commentary and auditor notes.
- **`approval_status`** (`VARCHAR(100)`): Current state (`Pending`, `Approved`, `Rejected`).
- **`first_level_approver`** (`VARCHAR(255)`): Name/email of initial reviewer.
- **`final_level_approver`** (`VARCHAR(255)`): Name/email of final authority.
- **`current_approver_id`** (`VARCHAR(100)`): Portal approver user ID.
- **`approved_by`** (`VARCHAR(255)`): Name of approving manager.
- **`photo_url`** (`TEXT`): Link to proof document or screenshot.
- **`data_source`** (`VARCHAR(100) NOT NULL`): Intake channel (`GOOGLE_SHEET`, `PORTAL_FORM`, `MERGED`).
- **`source_reference_id`** (`TEXT`): Upstream primary key tracking reference.
- **`is_deleted`** (`BOOLEAN NOT NULL DEFAULT FALSE`): Soft delete flag.
- **`deleted_at`** (`TIMESTAMP WITHOUT TIME ZONE`): Soft deletion timestamp.
- **`created_at`** (`TIMESTAMP WITHOUT TIME ZONE`): Row creation timestamp in IST.
- **`updated_at`** (`TIMESTAMP WITHOUT TIME ZONE`): Row update timestamp in IST.

---

## 4. Operational Runbook

### Running Full Health Audit
```bash
python automation_script.py --audit
```
Verifies upstream count parity, gapless IDs, zero phantom date-shifted duplicates, timestamp datatypes, and non-negative constraints.

### Executing On-Demand Refresh / Backfill
```bash
python automation_script.py --backfill
```
Calls `SELECT public.refresh_core_adjustments();` under transactional advisory lock `777333444` to synchronize all upstream records into `core_adjustments`.

### Verifying Synchronization Triggers
```bash
python automation_script.py --verify-triggers
```
Validates that `trg_sheet_adjustments_sync` and `trg_july_partner_adjustment_sync` are active.
