# Rental Final Table Calculation & Master Engine

Production rental calculation engine maintaining master vehicle rental agreements (`core_rent`), audit logs (`core_rent_logs`), and attendance-driven daily rent settlements (`daily_rent_log`).

---

## 1. System Architecture

```
+-----------------------------+       +-----------------------------+
|    sheet_rental_slabs       |       |   sheet_rental_partners     |
| (Trip-based pricing menu)   |       |  (Partner deals & overrides)|
+--------------+--------------+       +--------------+--------------+
               |                                     |
               +----------------+--------------------+
                                |
                                v
               +-------------------------------------+
               |              core_rent              |
               | (Master Vehicle-Partner Agreement)  |
               +----------------+--------------------+
                                |
        +-----------------------+-----------------------+
        |                                               |
        v                                               v
+-----------------------------+       +-------------------------------+
|  core_daily_vehicle_status  |       | Uber/Ola Completed Trips      |
|  (On-road vs Grounded/Maint)|       | (Weekly trips Monday-Sunday)  |
+--------------+--------------+       +---------------+---------------+
               |                                      |
               +-------------------+------------------+
                                   |
                                   v
               +-------------------------------------+
               |           daily_rent_log            |
               |  (Day-by-Day Rent & Indemnity Log)  |
               +-------------------------------------+
```

---

## 2. Reconciled Accuracy Benchmark

This engine was empirically validated across all **1,249 fleet vehicles** for settlement week `CY26WK26`:
- **Hyderabad**: 258/258 vehicles (100.0% match)
- **Mumbai**: 183/184 vehicles (99.5% match)
- **Bangalore**: 803/807 vehicles (99.5% match)
- **Pan-India Match Rate**: **99.6%**
