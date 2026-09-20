# Ola Final Table: Data Quality & Normalization Catalog

This document details the data quality anomalies, edge cases, and automated business resolutions implemented for the Ola core transformation pipeline (`core_ola_daily` and `core_ola_weekly`).

---

### Issue Catalog

| Issue ID | Severity | Category | Symptom / Anomaly Description | Production Resolution |
| :--- | :---: | :--- | :--- | :--- |
| **OLA-01** | **Critical** | Financial Metric | `customer_bill_raw` includes Ola's commission and does not reflect LetzRyd earnings. | Standardized on `operator_bill_raw` + cancellation compensation fees, which exactly matches the production Hisaab `OLA Net Revenue` formula to the penny. |
| **OLA-02** | **High** | Sign Convention | `cash_collected_by_driver_raw` is stored as a negative float in raw tables (e.g. `-552.00`). | Captured strictly as an unsigned positive magnitude (`ABS(...)`) in daily/weekly summaries, and treated as an asset recovery deduction in settlement balance calculations. |
| **OLA-03** | **High** | Financial Direction | `ola_raw_transactions.amount_raw` is always an unsigned positive number. | Financial effect is strictly resolved using `payment_type`: `credit` (+ money to driver) vs `debit` (- money from driver). |
| **OLA-04** | **Medium** | Reversals & Duplicates | Certain transactions have `transaction_status = 'Reversed'` or represent failed transfer refunds. | Filtered out using `transaction_status <> 'Reversed'` and excluding `failed_ondemand_account_transfer`. |
| **OLA-05** | **Medium** | Date Partitioning (Txns) | `stmt_date` represents the settlement posting date, whereas `date_for` is the actual service date. | Daily transactions are aggregated on `COALESCE(date_for, stmt_date)` to guarantee temporal alignment with operational rides. |
| **OLA-06** | **Low** | City Distribution | Hyderabad Hisaab shows 0 Ola rides for Week 26; Mumbai has 0 Ola rides across all periods. | Validated that Mumbai is 100% Uber fleet, and Hyderabad fleet operated primarily on Uber & Rapido; Ola operations active in Bengaluru (99.7% of trips). |
| **OLA-07** | **Critical** | Truncation Bug | Rolling-window sync (`v_start - 7 days`) sliced through Week 37, overwriting full-week totals with a 2-day partial window and losing ₹4,30,674.57 (1,761 trips). | Weekly aggregation now dynamically snaps to full calendar Monday (`DATE_TRUNC('week', v_start)`) through Sunday (`+ INTERVAL '6 days'`). Never overwrites partial weeks. |
| **OLA-08** | **High** | Midnight 12:00 AM Rule | Ola daily settlement cutoff operates strictly at calendar midnight (12:00 AM / 00:00:00). | In Ola's platform, any trip completed before 12:00 AM midnight is counted towards the previous calendar day, while any trip at or after 12:00 AM belongs to the current/next day. `stmt_date` in `ola_raw_crns` natively enforces this 00:00:00 - 23:59:59 window. |
| **OLA-09** | **Medium** | Vendor Attribution | Joining `core_daily_vehicle_status` on `week_start = status_date` (Monday only) yielded up to 24% NULL `vendor_code`s if a vehicle was off-road on Monday. | Replaced with weekly mode: resolves the dominant `partner_id` across the entire 7-day billing week, falling back to `core_rent.partner_id`. Reduces NULLs to <1.6%. |
| **OLA-10** | **Critical** | Pipeline Contention | Attaching synchronous DML triggers on high-volume raw ingestion tables (`ola_raw_crns`, `ola_raw_transactions`) created lock contention, latency, and ingestion failures. | Replaced with asynchronous `pg_cron` execution (`sync_core_ola_30m`, runs every 30 minutes). Zero triggers exist on raw tables; ingestion runs fully isolated and unblocked. |
| **OLA-11** | **High** | Unmapped Transactions | Transactions with `transaction_type = 'collection'` (online passenger collections & subscription offsets totaling ₹2.08L) were ignored. | Explicitly mapped `collection` (`sub_category = 'online_payment'`) into online deductions and `collection` (`sub_category = 'subscription_fee'`) as an offset against subscription debits. |
