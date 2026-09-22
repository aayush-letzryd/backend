# LetzRyd Standardized Unified Rental Architecture

Production schema, stored procedures, and orchestration engine for the LetzRyd multi-city rental system (Bangalore, Hyderabad, Mumbai).

---

## 1. Architectural Highlights: 100% Data-Driven & Independent

1. **Zero Hardcoded Numbers**: All base rates, trip slabs, model baselines, indemnity fees, and waiver rules reside strictly in physical database tables. The stored procedure contains zero magic numbers.
2. **Numeric Serial Primary Keys**: Every table uses an auto-incrementing integer `SERIAL PRIMARY KEY` (`1, 2, 3...`). Plan codes (`BLR_ALL_PLATFORM`, `HYD_UBER_TBS`) are preserved in unique `plan_code` columns for clean human reference.
3. **Custom Operator Tiered Slabs**: `public.rental_rate_slabs` includes a `partner_id` column (`DEFAULT 'ALL'`). Operator deals with trip milestones (e.g. Hamza Moidu `<55=870, 55+=840, 65+=790, 75+=770`) are stored natively in the slabs table and resolved automatically.
4. **Transparent Lineage in `daily_rent_log`**: Every calculated row stores foreign keys linking back to the exact rule:
   - `matched_plan_id INT REFERENCES core_rental_plans(plan_id)`
   - `matched_slab_id INT REFERENCES rental_rate_slabs(slab_id)`
   - `matched_custom_plan_id INT REFERENCES rental_custom_partner_plans(custom_plan_id)`

---

## 2. Unified Schema Structure (7 Tables)

```
[ core_daily_vehicle_status ] + [ core_uber_daily ] + [ core_ola_daily ]
                                  │
                                  ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │               5-TIER NATIVE DATABASE WATERFALL                          │
 │                                                                         │
 │  1. rental_exceptions            (Audit-grade concessions - 0 rows)     │
 │  2. rental_custom_partner_plans  (233 negotiated flat agreements)       │
 │  3. rental_rate_slabs            (51 trip slabs: City + Operator Deals) │
 │  4. rental_model_baselines       (21 vehicle model rate fallbacks)      │
 │  5. core_rental_plans            (14 master plans with default rates)   │
 │  +  rental_fee_rules             (7 indemnity fee policies & waivers)   │
 └────────────────────────────────┬────────────────────────────────────────┘
                                  │
                                  ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                         daily_rent_log                                  │
 │        Grain: UNIQUE (log_date, vehicle_number, partner_id)             │
 │        Lineage: matched_plan_id, matched_slab_id, matched_custom_plan_id│
 └────────────────────────────────┬────────────────────────────────────────┘
                                  │
                       02:30 UTC  │ sp_sync_rent_to_hisaab
                                  ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                      hisaab_daily_ledger                                │
 │                              │                                          │
 │                              ▼                                          │
 │                     hisaab_vehicle_weekly                               │
 └─────────────────────────────────────────────────────────────────────────┘
```

### Table Definitions & Roles
1. **`public.core_rental_plans`**: Master catalogue of standard and custom plans across Bangalore, Hyderabad, and Mumbai with table-defined default daily rents and fees.
2. **`public.rental_rate_slabs`**: Dynamic reducing trip slabs, supporting standard city slabs (`partner_id = 'ALL'`) and operator custom trip brackets (`partner_id = 'LETZBLR_HAMZA'`).
3. **`public.rental_custom_partner_plans`**: Long-term negotiated partner flat agreements (233 active rate cards).
4. **`public.rental_exceptions`**: Governance container (0 rows) for temporary, management-approved concessions.
5. **`public.rental_fee_rules`**: Indemnity fee policies and waiver rules (standard ₹30/day, Mumbai ₹0 waiver, Xcent ₹0 waiver, Shaik Kareem ₹0, etc.).
6. **`public.rental_model_baselines`**: Model rate fallbacks (e.g. Mumbai Dzire ₹1,100, Hyderabad eC3 ₹1,400, WagonR ₹989).
7. **`public.daily_rent_log`**: Daily ledger recording applied rent, indemnity fee, billable status, and explicit lineage identifiers.

---

## 3. Automation & Concurrency Safety

* **Zero Row-Level Triggers**: Operational tables (`core_daily_vehicle_status`, Uber/Ola sync) are 100% free from locking contention.
* **Batch Stored Procedures**:
  * `CALL public.sp_calculate_daily_rent(p_start_date, p_end_date);` (~0.5s for 2,200+ vehicles)
  * `CALL public.sp_sync_rent_to_hisaab(p_week_id);` (~3.9s for full weekly rollup)
* **pg_cron Nightly Schedule**:
  * `02:00 UTC`: `CALL public.sp_calculate_daily_rent(CURRENT_DATE - 1, CURRENT_DATE);`
  * `02:30 UTC`: `CALL public.sp_sync_rent_to_hisaab(NULL);`

---

## 4. CLI Execution & Verification

```bash
# Run full database health audit (checks integer PKs, counts, triggers, and cron schedules)
python automation_script.py --audit

# Calculate daily rent for a specific date range
python automation_script.py --calculate-rent --start-date 2026-09-07 --end-date 2026-09-13

# Sync daily rent into Hisaab weekly settlements
python automation_script.py --sync-hisaab --week-id CY26WK37

# Run test suite verifying operator custom slabs & audit lineage
python test_rental_system.py

# Run master reconciliation parity proof against weekly Hisaab workbooks
python verify_hisaabs.py

# Create or verify the portal staging table (public.portal_rental_plans)
python create_staging_table.py

# Promote approved portal staged configurations into production canonical tables
python sync_portal_to_rental_tables.py
```

---

## 5. Portal Intake Staging Architecture (`public.portal_rental_plans`)

To allow portal operations (plan creation, overrides, partner assignments, dynamic slabs, model baselines, fee waivers) without touching live production tables, a single staging intake table is utilized:

1. **Intake Table**: `public.portal_rental_plans` (DDL in `unified_staging_schema.sql`).
2. **Promotion Pipeline**: `sync_portal_to_rental_tables.py` reads approved records from `portal_rental_plans` and upserts them into:
   - `public.rental_exceptions` (for `EXCEPTION_OVERRIDE`)
   - `public.rental_custom_partner_plans` (for `PARTNER_DEAL`)
   - `public.rental_rate_slabs` (for `RATE_SLAB`)
   - `public.rental_model_baselines` (for `MODEL_BASELINE`)
   - `public.rental_fee_rules` (for `FEE_WAIVER`)
   - `public.core_rental_plans` (for `CORE_PLAN`)

