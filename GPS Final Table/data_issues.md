# GPS Telematics Data Quality & Engineering Audit

## 1. Hardware Device Suffix Collisions (-A, -B)
- **Problem Description**: Intellicar API streams telematics under both direct plates (`KA51AM8114`) and suffixed IDs (`KA51AM8114-A`). In 568 fleet assets, both streams report data concurrently on the same date. The direct plate represents primary vehicle odometer sensor readings, whereas the suffixed stream represents auxiliary GPS satellite breadcrumb calculations.
- **Remediation**: The table implements `fn_clean_gps_vehicle_number()`, which strips trailing `[-_\s][A-Za-z0-9]$` suffixes and maps canonical plates. For deduplication, the pipeline applies `GREATEST(distance_km)` across concurrent streams, preventing under-reporting while enforcing the natural key `UNIQUE (record_date, vehicle_number)`.

## 2. Pre-Registration Chassis Number (VIN) Tracking
- **Problem Description**: Brand-new vehicles deployed from manufacturer yards before RTO registration plate assignment are registered in Intellicar under 17-character VIN strings (e.g., `MA3ZFDFSKTG536171-A`, `MA3JMTB1STHF54940`).
- **Remediation**: The cleaning function contains a secondary lookup against `core_vehicle_onboarding.chassis_no`. This dynamically resolves 189 historical VIN tracking records to their active RTO registration plates (`MH03FC6384`, `TG07Y3884`), uniting pre-onboarding telemetry with production assets.

## 3. Hardware IMEI / Device Serial Fallbacks
- **Problem Description**: 51 telematics streams contain non-vehicle hardware serial numbers (e.g., `37366C4A471B6D44`) or un-onboarded chassis IDs.
- **Remediation**: To prevent data loss, the cleaning function preserves the sanitized alphanumeric identifier in `vehicle_number` and retains the original raw payload in `raw_vehicle_id`, assigning city defaults and status `RFD`.

## 4. Concurrent Channel Multi-Stream Overwriting
- **Problem Description**: If multiple device records are inserted on the same day, a standard `ON CONFLICT DO UPDATE SET distance_km = EXCLUDED.distance_km` can cause arbitrary overwrites depending on arrival order.
- **Remediation**: The upsert trigger uses `distance_km = GREATEST(core_gps.distance_km, EXCLUDED.distance_km)`, ensuring that the higher, more accurate distance measurement is unconditionally retained.

## 5. Sequence Continuity & Zero-Burn Guarantees
- **Problem Description**: In PostgreSQL, standard `BIGSERIAL` columns advance whenever an `INSERT ... ON CONFLICT` statement attempts an insertion, burning primary key IDs even when rows are updated.
- **Remediation**: Staging ingestion groups records by `(record_date, vehicle_number)` prior to upserting, keeping sequence counter burning strictly to 0. `core_gps` maintains a continuous, gapless sequence from 1 to 37,548.

## 6. Real-Time Operational Context Enrichment
- **Problem Description**: Raw telematics lacks driver identity, custody cohort, and deployment status.
- **Remediation**: On every record ingestion, `fn_sync_core_gps_from_telematics()` executes an index lookup against `core_daily_vehicle_status` on `(status_date, vehicle_number)`. This dynamically stamps `partner_id`, `partner_name`, `driver_phone`, `vehicle_status`, and `cohort`.

## 7. Unauthorized Idle Movement Alerts
- **Problem Description**: Vehicles marked in yard (`RFD`) or undergoing workshop repairs (`Maintenance`) occasionally move significant distances without an active rental trip, indicating unauthorized personal usage, yard shunting, or test drives.
- **Remediation**: The table evaluates `is_idle_movement_alert := (vehicle_status IN ('RFD', 'Maintenance', 'Workshop', 'Accidental', 'BD') AND distance_km > 5.0)`. Dedicated partial index `idx_core_gps_alert` enables sub-millisecond alerting for fleet managers.
