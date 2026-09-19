# Uber Final Table: Data Quality, Normalization & Remediation Catalog

This document details the data quality anomalies, edge cases, root causes, and production resolutions implemented for the Uber core transformation pipeline (`public.core_uber_daily` and `public.core_uber_weekly`).

---

### Issue Catalog

| Issue ID | Severity | Category | Symptom / Anomaly Description | Production Resolution |
| :--- | :---: | :--- | :--- | :--- |
| **UBR-01** | **Resolved** | Ingestion Schedule | Uber supplier feeds are retrieved asynchronously each morning. | Disentangled from raw tables; processed via `pg_cron` running every 30 minutes. |
| **UBR-02** | **Critical** | Missing Foreign Key | `uber_pipeline_order_transactions.vehicle_number` is 100% NULL from Uber Supplier API, and 27,057 rows have NULL `trip_uuid`. | Resolved via multi-tiered fallback cascade: `ot.trip_uuid -> t.car_no`, description plate regex `[A-Z]{2}[0-9]{1,2}[A-Z]{1,2}[0-9]{4}`, and driver-date active vehicle lookup. |
| **UBR-03** | **Critical** | Sign Inversion | `cash_collected` in raw order transactions is stored negative (min -₹7,023.62). Subtraction in SQL (`earnings - cash`) effectively added cash to earnings, inflating balances up to 100x. | Normalized via `ABS(cash_collected)` and correctly subtracted from earnings in `net_driver_day_balance`. |
| **UBR-04** | **Critical** | Case Sensitivity | Raw `trip_status` is lowercase `'completed'`, while previous SQL trigger checked uppercase `'COMPLETED'`. Over 95% of recent completed trips were zeroed out. | Normalized via `COUNT(*) FILTER (WHERE LOWER(trip_status) = 'completed')`. Restored 60,000+ completed trips. |
| **UBR-05** | **High** | Operational Cutoff | Documentation claimed 04:00 AM IST cutoff, but SQL code used `trip_date` (calendar date). Late-night rides (00:00 to 03:59:59) were misattributed to the next day. | Enforced in SQL: `((trip_request_time - INTERVAL '4 hours')::date) AS operational_date`, verified against Hisaab ground truth rows 244 vs 246. |
| **UBR-06** | **High** | Multi-Vendor Duplication | When a vehicle had multiple vendor codes in one settlement week, weekly milestone incentive from `uber_vehicle_incentives_raw` joined 1-to-many, doubling/tripling payouts. | Enforced ranking: `ROW_NUMBER() OVER (PARTITION BY vehicle_number, settlement_week ORDER BY trips DESC, active_days DESC) = 1`. Incentive credited strictly once per car. |
| **UBR-07** | **Critical** | Lock Contention & Triggers | Synchronous statement triggers on `uber_pipeline_trips` and `uber_pipeline_order_transactions` caused deadlocks, slow ingestion, and silent aborts. | **All triggers dropped from raw tables.** Zero overhead on raw ingestion. Processing migrated to background `pg_cron` job `sync-core-uber`. |
| **UBR-08** | **High** | Stalled Sync | Core table sync was frozen since September 16, 2026. September 17 and 18 were completely missing. | Stored procedure backfill executed for August 23 to current date; restored 17,000+ trips and all missing financial records. |
| **UBR-09** | **Medium** | Subscription Fee Parsing | `driver_subscription_charge` was hardcoded to `0.0` in live database function. | Restored regex and description parsing for Drive Pass, platform fees, and subscription charges. |
