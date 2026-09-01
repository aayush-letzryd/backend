# LetzRyd Core Platform Backend

Core platform database definitions, master schemas, audit logs, and migration scripts.

## Module Structure

- **[`city/`](./city/)**: City Master Module (`public.core_cities`)
  - `01_create_core_cities.sql`: DDL, automatic `updated_at` trigger, physical deletion guardrails.
  - `02_seed_core_cities.sql`: Seed data for initial operational hubs (BLR, HYD, MUM).
  - `03_test_core_cities.sql`: Test suites for constraint checks, trigger verification, and deletion prevention.
  - `README.md`: Knowledge transfer documentation, API contracts, portal UI workflows, and future schema references.

- **[`city_log/`](./city_log/)**: City Audit Log Module (`public.core_city_logs`)
  - `01_create_core_city_logs.sql`: DDL, foreign key, index, audit trigger function (`CREATE`, `UPDATE`, `DELETE`).
  - `02_test_core_city_logs.sql`: End-to-end transactional testing for lifecycle audit tracking.
  - `README.md`: Knowledge transfer documentation for immutable audit logs, JSONB schema, and portal timeline queries.

---

## Migration Execution Order

When applying migrations to a database instance, run scripts in the following exact sequence:

1. **`city/01_create_core_cities.sql`**: Creates master table and updated_at / delete-prevention triggers.
2. **`city_log/01_create_core_city_logs.sql`**: Creates audit log table, index, and attaches audit trigger to `core_cities`.
3. **`city/02_seed_core_cities.sql`**: Populates initial cities (BLR, HYD, MUM). The attached trigger automatically logs `CREATE` audit records.
4. **Verification**: Run `city/03_test_core_cities.sql` and `city_log/02_test_core_city_logs.sql`.
