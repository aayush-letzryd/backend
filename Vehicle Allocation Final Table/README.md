# Vehicle Allocation Final Table Pipeline Architecture

## 1. System Overview

The **Vehicle Allocation Pipeline** unifies vehicle allocation and driver handover records across two independent live production sources into a single, high-performance master table: `public.core_vehicle_allocation`.

### Upstream Source Systems
1. **Google Sheets Pipeline (`public.sheet_vehicle_allocations`):**
   * Historical and live form submissions from fleet operations executives across Bangalore, Hyderabad, and Mumbai.
   * Current row count: ~7,132 rows (39 columns).
2. **Web Portal Pipeline (`public.july_allocation_form`):**
   * Live digital vehicle allocation and handover workflow with photo audits, FASTag balance checks, and approval signatures.
   * Current row count: ~303 rows (76 columns).

---

## 2. Architecture & Synchronization Engine

The pipeline uses **Native PostgreSQL Row-Level Triggers** with strict transactional isolation, replicating the architecture established in `Walkin Final Table`:

```
┌──────────────────────────────────────┐     ┌───────────────────────────────────┐
│ public.sheet_vehicle_allocations     │     │ public.july_allocation_form       │
│ (7,132 rows - Google Sheets)         │     │ (303 rows - Web Portal)           │
└──────────────────┬───────────────────┘     └─────────────────┬─────────────────┘
                   │                                           │
                   │ AFTER INSERT OR UPDATE                    │ AFTER INSERT OR UPDATE
                   │ OR DELETE (Row-level)                     │ OR DELETE (Row-level)
                   ▼                                           ▼
       ┌───────────────────────────────────────────────────────────┐
       │   PostgreSQL Trigger Functions (Advisory Lock Protected)  │
       │   - trg_sync_core_allocation_from_sheet                   │
       │   - trg_sync_core_allocation_from_portal                  │
       └─────────────────────────────┬─────────────────────────────┘
                                     │
                                     ▼
       ┌───────────────────────────────────────────────────────────┐
       │             public.core_vehicle_allocation                │
       │   - Gapless 1..N ID Sequence (Zero ID burning)            │
       │   - Soft Delete Protection (is_deleted, deleted_at)       │
       │   - Clean IST Timestamps (TIMESTAMP WITHOUT TIME ZONE)    │
       │   - Single Source of Truth for Hisaab & Vehicle Status    │
       └───────────────────────────────────────────────────────────┘
```

---

## 3. Core Architectural Guarantees

### 1. Dual-Source Automatic Merging
* If an allocation is entered in Google Sheets $\rightarrow$ Syncs instantly to core.
* If an allocation is entered on Web Portal $\rightarrow$ Syncs instantly to core.
* If both sources submit for the same `(vehicle_number, allocation_date)` $\rightarrow$ Merged into a single record with `source_origin = 'MERGED'`, combining rich portal inspection data with verified sheet metadata.

### 2. Zero Sequence Burning (Gapless ID Guarantee)
* To prevent sequence counter thrashing (which ruined Dhanush's core tables with millions of burned IDs), `core_vehicle_allocation` uses **Transactional Advisory Locks (`pg_advisory_xact_lock`)** and explicit `MAX(id) + 1` continuous numbering.
* Result: Exactly continuous `1..N` IDs with zero gaps.

### 3. Soft Delete Protection
* Deleting an entry in Google Sheets or Web Portal sets `is_deleted = TRUE` and records `deleted_at = CURRENT_TIMESTAMP`.
* The row is preserved in the database to protect financial audit trails and Hisaab historical records.

### 4. Zero Timezone Shift (Pure IST Timestamps)
* All timestamps use `TIMESTAMP WITHOUT TIME ZONE` normalized to Indian Standard Time (IST).
* Prevents the 1-day backward shift bugs that corrupted 40%+ of historical records in Dhanush's tables.
