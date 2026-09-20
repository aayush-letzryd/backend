# Resolved Rental Engine Architectural & Data Issues

### 1. Decommissioning of External Google Sheet Sync
* **Issue**: Rate logic was split between external Google Sheets and database staging tables (`sheet_rental_slabs` and `sheet_rental_partners`), creating out-of-sync discrepancies and API dependency failures.
* **Resolution**: Completely eliminated. All standard plan definitions, dynamic trip slabs, and partner custom agreements are now maintained directly in PostgreSQL (`core_rental_plans`, `rental_rate_slabs`, and `rental_custom_partner_plans`).

### 2. Elimination of Vehicle-Marriage Anti-Pattern (`core_rent`)
* **Issue**: The legacy `core_rent` table had `UNIQUE (vehicle_number, effective_from)`. In fleet management, contracts belong to Partners, whereas vehicles are dynamically swapped and re-allocated. Tying contracts to vehicles caused false contract expirations and data corruption.
* **Resolution**: Replaced by `rental_custom_partner_plans` keyed by `(partner_id, vehicle_model, valid_from)`. Vehicle allocations are looked up dynamically from operational status.

### 3. Driver Handover Data Loss Fixed in `daily_rent_log`
* **Issue**: `daily_rent_log` previously enforced `UNIQUE (log_date, vehicle_number)`. During mid-week driver handovers or same-day vehicle handovers, Driver B's calculation completely overwrote Driver A's record, erasing revenue and trip attribution.
* **Resolution**: Changed grain to `CONSTRAINT uq_daily_rent_log_grain UNIQUE (log_date, vehicle_number, partner_id)`. Both drivers' daily rent and trips are preserved cleanly and independently.

### 4. Elimination of Cascading Row-Level Triggers
* **Issue**: `trg_sync_hisaab_from_rent` on `daily_rent_log` and `trg_cascade_daily_to_weekly` on `hisaab_daily_ledger` fired row-by-row cascades into weekly settlement tables on every single row write, causing heavy lock contention and transaction deadlocks during operational telemetry ingestion.
* **Resolution**: All triggers dropped. Calculations and Hisaab settlement rollups run as high-performance, atomic set-based batch stored procedures (`sp_calculate_daily_rent` and `sp_sync_rent_to_hisaab`) orchestrated safely by `pg_cron`.

### 5. Clean Governance Container (Zero Assumed Exceptions)
* **Issue**: Historical Hisaab workbooks had 31 ad-hoc manual cell edits (e.g. typing 970 over formula 1070). Grandfathering these as active rules risks baking human typos into permanent policy.
* **Resolution**: Pure canonical calculations run from standard slabs and confirmed partner contracts. `rental_exceptions` is maintained as a clean, empty container (0 rows) ready to receive explicit, management-approved concessions with full audit metadata.
