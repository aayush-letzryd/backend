# LetzRyd Adjustments Master Architecture & Runbook

This directory contains the production schema, real-time synchronization triggers, consolidation procedures, and verification engine for **`public.core_adjustments`**.

---

## 1. System Architecture Overview

`public.core_adjustments` is the Single Source of Truth (SSOT) consolidating all financial debits, credits, pass fees, penalties, and deposit conversions for partners across both intake channels:

```
[ Google Sheet: Adjustment-Form ]
              │
              ▼ (Apps Script JDBC Batch Sync - 1 Min)
  [ public.sheet_adjustments ] (15,820 rows)
              │
              ▼ (trg_sheet_adjustments_sync / Advisory Lock 777333444)
  ┌────────────────────────────────────────────────────────┐
  │              public.core_adjustments                   │
  │     (Single Source of Truth - 15,835 clean rows)       │
  └────────────────────────────────────────────────────────┘
              ▲ (trg_july_partner_adjustment_sync)
              │
  [ public.july_partner_adjustment ] (15 rows)
              ▲
              │
    [ Web Portal: Adjustments Form ]
```

### Downstream Hisaab Flow:
```
  ┌────────────────────────────────────────────────────────┐
  │              public.core_adjustments                   │
  └───────────────────────────┬────────────────────────────┘
                              │ (trg_core_to_hisaab_adjustments - Approved Rows Only)
                              ▼
  ┌────────────────────────────────────────────────────────┐
  │          public.hisaab_adjustments_ledger              │
  └───────────────────────────┬────────────────────────────┘
                              ▼
  ┌────────────────────────────────────────────────────────┐
  │                Weekly Hisaab Engine                    │
  │ (hisaab_daily_ledger -> partner / vehicle weekly)      │
  └────────────────────────────────────────────────────────┘
```

---

## 2. Key Technical Guarantees

1. **1-to-1 Canonical Stacking (Zero Data Loss & Zero Overwrites)**:
   - Every row in `sheet_adjustments` maps to `ADJ-SHT-<id>` (15,820 rows).
   - Every row in `july_partner_adjustment` maps to `ADJ-PORTAL-<id>` (15 rows).
   - Distinct same-day adjustments for the same driver (e.g. ₹500 car wash and ₹500 AC repair) are **never merged or overwritten**.
2. **Gapless 1..N ID Continuity**:
   - Zero sequence burning via transactional advisory lock `pg_advisory_xact_lock(777333444)` and manual counter initialization.
   - Contiguous IDs (1..15,835) with 0 gaps.
3. **Pure IST Timestamps**:
   - All timestamps (`created_at`, `updated_at`, `deleted_at`) use `TIMESTAMP WITHOUT TIME ZONE` stored in Indian Standard Time (UTC+05:30) with zero timezone offset drift.
4. **Approval Status Authority**:
   - Status priority: `final_status` $\to$ `first_level_status` $\to$ `'Pending'`.
   - All historical timestamp-shifted rows cleanly standardized to `'Approved'`.
5. **Downstream Hisaab Automatic Propagation**:
   - Trigger `trg_core_to_hisaab_adjustments` synchronizes active `Approved` adjustments directly into `hisaab_adjustments_ledger`.
   - Prior-period adjustments route dynamically to active open settlement weeks.
6. **Automated `pg_cron` Reconciliation**:
   - `pg_cron` job running `SELECT public.refresh_core_adjustments();` every 15 minutes (`*/15 * * * *`).

---

## 3. Operational Runbook

### Running Full Health Audit
```bash
python automation_script.py --audit
```
Verifies upstream count parity, gapless IDs, zero timestamp status strings, reference ID cleanliness, and active pg_cron schedules.

### Executing On-Demand Refresh / Backfill
```bash
python automation_script.py --backfill
```
Calls `SELECT public.refresh_core_adjustments();` under transactional advisory lock `777333444` to synchronize all upstream records into `core_adjustments`.

### Verifying Synchronization Triggers
```bash
python automation_script.py --verify-triggers
```
Validates that `trg_sheet_adjustments_sync`, `trg_july_partner_adjustment_sync`, and `trg_core_to_hisaab_adjustments` are active.
