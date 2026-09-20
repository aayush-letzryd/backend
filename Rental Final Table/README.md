# LetzRyd Standardized Unified Rental Architecture

Production schema, stored procedures, and orchestration engine for the LetzRyd multi-city rental system (Bangalore, Hyderabad, Mumbai).

---

## 1. Architectural Evolution: Old vs New

### What Happened to the Old Tables?
| Legacy Table | Status | Reason & Replacement |
| :--- | :--- | :--- |
| **`sheet_rental_slabs`** | **DEPRECATED** | External Google Sheet sync is decommissioned. Replaced by native PostgreSQL tables: `public.core_rental_plans` (master catalogue) and `public.rental_rate_slabs` (dynamic reducing slabs). |
| **`sheet_rental_partners`** | **DEPRECATED** | External Google Sheet sync is decommissioned. Replaced by `public.rental_custom_partner_plans` (233 active partner rate cards). |
| **`core_rent`** | **REPLACED** | Had a flawed vehicle-marriage constraint `UNIQUE (vehicle_number, effective_from)`. Replaced by `public.rental_custom_partner_plans` which binds contracts to **Partner + Model**, decoupling dynamic vehicle allocations. |
| **`core_rent_logs`** | **REPLACED** | Replaced by native audit trails in `rental_exceptions` and `rental_custom_partner_plans` (`approved_by`, `valid_from`, `valid_to`, `reason`). |
| **`daily_rent_log`** | **UPGRADED** | **Kept as Core Daily Output Ledger**, but upgraded: (1) Constraint changed to `UNIQUE (log_date, vehicle_number, partner_id)` eliminating driver handover data loss; (2) Cascading triggers dropped to eliminate DB locks. |

---

## 2. Current Unified Schema (7 Tables)

```
[ core_daily_vehicle_status ] + [ core_uber_daily ] + [ core_ola_daily ]
                                  │
                                  ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │               5-TIER NATIVE DATABASE WATERFALL                          │
 │                                                                         │
 │  1. rental_exceptions            (Audit-grade concessions - 0 rows)     │
 │  2. rental_custom_partner_plans  (233 negotiated partner agreements)    │
 │  3. rental_rate_slabs            (51 trip-performance reducing slabs)   │
 │  4. rental_model_baselines       (16 vehicle model rate fallbacks)      │
 │  5. core_rental_plans            (20 city default base plans)           │
 │  +  rental_fee_rules             (6 city/partner indemnity fee rules)   │
 └────────────────────────────────┬────────────────────────────────────────┘
                                  │
                                  ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                         daily_rent_log                                  │
 │        Grain: UNIQUE (log_date, vehicle_number, partner_id)             │
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
1. **`public.core_rental_plans`**: Master catalogue of standard and custom plans across Bangalore, Hyderabad, and Mumbai.
2. **`public.rental_rate_slabs`**: Dynamic reducing trip slabs (e.g. Hyderabad TBS, Mumbai Reducing, Bangalore Master).
3. **`public.rental_custom_partner_plans`**: Long-term negotiated partner agreements (flat rates, custom slabs, model-specific rates).
4. **`public.rental_exceptions`**: Governance container (starts with 0 rows) for temporary, management-approved concessions.
5. **`public.rental_fee_rules`**: Indemnity fee policies and waiver rules (standard ₹30/day, Xcent ₹0, Shaik Kareem ₹0).
6. **`public.rental_model_baselines`**: Model rate fallbacks (e.g. Mumbai Dzire ₹1,100, Hyderabad eC3 ₹1,400, WagonR ₹989).
7. **`public.daily_rent_log`**: Daily ledger recording applied rent, indemnity fee, billable status, and the winning rule.

---

## 3. Automation & Concurrency Safety

* **Zero Row-Level Triggers**: All cascading triggers on `daily_rent_log` and `hisaab_daily_ledger` have been dropped. Operational tables (`core_daily_vehicle_status`, Uber/Ola sync) are 100% free from locking contention.
* **Batch Stored Procedures**:
  * `CALL public.sp_calculate_daily_rent(p_start_date, p_end_date);` (Runs 2,200+ vehicles in ~0.54s)
  * `CALL public.sp_sync_rent_to_hisaab(p_week_id);` (Updates daily ledger and rolls up weekly settlements in ~3.9s)
* **pg_cron Nightly Schedule**:
  * `02:00 UTC`: `CALL public.sp_calculate_daily_rent(CURRENT_DATE - 1, CURRENT_DATE);`
  * `02:30 UTC`: `CALL public.sp_sync_rent_to_hisaab(NULL);`

---

## 4. CLI Execution & Health Audit

```bash
# Run full database health audit (checks counts, triggers, and cron schedules)
python automation_script.py --audit

# Calculate daily rent for a specific date range
python automation_script.py --calculate-rent --start-date 2026-09-07 --end-date 2026-09-13

# Sync daily rent into Hisaab weekly settlements
python automation_script.py --sync-hisaab --week-id CY26WK37
```
