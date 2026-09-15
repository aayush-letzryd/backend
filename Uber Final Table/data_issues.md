# Uber Final Table: Data Quality & Normalization Catalog

This document details the data quality anomalies, edge cases, and automated business resolutions implemented for the Uber core transformation pipeline (`core_uber_daily` and `core_uber_weekly`).

---

### Issue Catalog

| Issue ID | Severity | Category | Symptom / Anomaly Description | Production Resolution |
| :--- | :---: | :--- | :--- | :--- |
| **UBR-01** | **High** | Temporal Shift | Trips between `00:00:00` and `03:59:59` belong to the night shift of the previous calendar day. | Evaluated with `(timestamp AT TIME ZONE 'Asia/Kolkata' - INTERVAL '4 hours')::date`. |
| **UBR-02** | **Critical** | Missing Foreign Key | `uber_pipeline_order_transactions.vehicle_number` is 100% NULL from Uber Supplier API. | Enriched by joining `trip_uuid` to `uber_pipeline_trips` (89.7% match) and regex license plate extraction from transaction `description` for promotions. |
| **UBR-03** | **Critical** | Financial Metric | `paid_to_you` is net of rider cash kept by drivers and bank disbursements. Summing it yields ~₹0. | Separated into distinct components: `net_fare_earnings` (gross fares), `cash_collected` (driver cash kept), `tolls_refunded`, and `driver_subscription_charge`. |
| **UBR-04** | **Medium** | Incentive Granularity | `uber_vehicle_incentives_raw` evaluates target milestones on a weekly cycle (`start_date` to `end_date`). | Maintained strictly at the weekly settlement grain in `core_uber_weekly`. |
| **UBR-05** | **Medium** | Plate Formatting | Plates contain mixed spacing and lowercase characters (e.g. `ka 05 an 9208`). | Standardized via `UPPER(REPLACE(car_no, ' ', ''))`. |
| **UBR-06** | **High** | Multi-Driver Allocation | Mid-week driver reassignment where two drivers drive the same car in one billing week. | Partitioned by `(settlement_year, settlement_week, vehicle_number, vendor_code)` using `core_daily_vehicle_status` partner attribution. |
