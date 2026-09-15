# Ola Final Table: Data Quality & Normalization Catalog

This document details the data quality anomalies, edge cases, and automated business resolutions implemented for the Ola core transformation pipeline (`core_ola_daily` and `core_ola_weekly`).

---

### Issue Catalog

| Issue ID | Severity | Category | Symptom / Anomaly Description | Production Resolution |
| :--- | :---: | :--- | :--- | :--- |
| **OLA-01** | **Critical** | Financial Metric | `customer_bill_raw` includes Ola's commission and does not reflect LetzRyd earnings. | Standardized on `operator_bill_raw`, which exactly matches the production Hisaab `OLA Net Revenue` formula to the penny. |
| **OLA-02** | **High** | Sign Convention | `cash_collected_by_driver_raw` is stored as a negative float in raw tables (e.g. `-552.00`). | Captured as an unsigned positive magnitude in daily/weekly summaries, and treated as an asset recovery deduction in settlement. |
| **OLA-03** | **High** | Financial Direction | `ola_raw_transactions.amount_raw` is always an unsigned positive number. | Financial effect is strictly resolved using `payment_type`: `credit` (+ to driver) vs `debit` (- from driver). |
| **OLA-04** | **Medium** | Reversals & Duplicates | Certain transactions have `transaction_status = 'Reversed'` or represent failed transfer refunds. | Filtered out using `transaction_status <> 'Reversed'` and excluding `failed_ondemand_account_transfer`. |
| **OLA-05** | **Medium** | Date Partitioning | `stmt_date` represents the settlement posting date, whereas `date_for` is the actual service date. | Daily transactions are aggregated on `date_for` to guarantee temporal alignment with operational rides. |
| **OLA-06** | **Low** | City Distribution | Hyderabad Hisaab shows 0 Ola rides for Week 26. | Validated that Hyderabad fleet operated on Uber & Rapido; Ola operations active in Bengaluru (99.7% of trips). |
