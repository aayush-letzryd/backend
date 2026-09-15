# GPS Telematics Final Table Architecture

## Executive Summary
The `public.core_gps` table serves as the Single Source of Truth (SSOT) for vehicle telematics across the LetzRyd fleet. It unifies daily distance tracking from the Intellicar API, performs intelligent device-suffix and VIN-to-registration resolution, enriches telematics with real-time operational driver attribution, and raises instant alerts for unauthorized idle vehicle movement.

## System Architecture

```
                      +-----------------------------+
                      |   Intellicar Telematics     |
                      |   Cloud REST API (/bulk)    |
                      +--------------+--------------+
                                     |
                                     v
                      +-----------------------------+
                      | public.sheet_gps_telematics |
                      |    (Raw Staging Buffer)     |
                      +--------------+--------------+
                                     |
                                     v
                       trg_sync_core_gps_from_telematics
                                     |
         +---------------------------+---------------------------+
         |                                                       |
         v                                                       v
  fn_clean_gps_vehicle_number()                    core_daily_vehicle_status
  - Strips -A/-B hardware tokens                   - Driver phone & partner ID
  - Maps 17-char VINs to plates                    - Allocation & status cohort
         |                                                       |
         +---------------------------+---------------------------+
                                     |
                                     v
                      +-----------------------------+
                      |       public.core_gps       |
                      | (SSOT Master Fleet Distance)|
                      +-----------------------------+
```

## Data Dictionary: public.core_gps

- **id**: `BIGSERIAL PRIMARY KEY` - Monotonically increasing primary key. Gapless 1 to 37,548.
- **record_date**: `DATE NOT NULL` - Calendar date of telematics recording (IST).
- **vehicle_number**: `VARCHAR(20) NOT NULL` - Cleaned Indian registration plate or resolved vehicle asset ID.
- **distance_km**: `NUMERIC(10,2) DEFAULT 0.00` - Daily distance traveled in kilometers.
- **city**: `VARCHAR(20)` - Operating hub city (Bangalore, Hyderabad, Mumbai, Pune).
- **partner_id**: `VARCHAR(50)` - Allocated driver/partner identification code.
- **partner_name**: `VARCHAR(150)` - Full legal name of operating driver.
- **driver_phone**: `VARCHAR(20)` - Registered contact phone number.
- **vehicle_status**: `VARCHAR(30) DEFAULT 'RFD'` - Operational status on record date (Active, RFD, Maintenance).
- **cohort**: `VARCHAR(20) DEFAULT 'In Yard'` - Custody cohort (Active Trip, In Yard, Off Road).
- **source_provider**: `VARCHAR(50) DEFAULT 'INTELLICAR'` - Originating telematics provider.
- **raw_vehicle_id**: `VARCHAR(100)` - Original uncleaned identifier string from provider API.
- **is_idle_movement_alert**: `BOOLEAN DEFAULT FALSE` - Flag indicating distance > 5km while in yard or maintenance.
- **created_at**: `TIMESTAMP WITHOUT TIME ZONE` - Timestamp of initial record creation.
- **updated_at**: `TIMESTAMP WITHOUT TIME ZONE` - Timestamp of most recent telemetry sync.

## Installation & Trigger Setup

To deploy the schema and activate automated real-time synchronization, execute:

```bash
psql -h 35.200.196.113 -U postgres -d postgres -f "GPS Final Table/schema.sql"
```

## Automated Verification

Run the Python verification suite:

```bash
python "GPS Final Table/automation_script.py"
```

## Key Verification Queries

- Check total row count and sequence integrity:
```sql
SELECT MIN(id), MAX(id), COUNT(*), (SELECT last_value FROM pg_sequences WHERE sequencename = 'core_gps_id_seq') AS seq_last_val FROM public.core_gps;
```

- Review active idle movement alerts:
```sql
SELECT record_date, vehicle_number, city, vehicle_status, distance_km, raw_vehicle_id 
FROM public.core_gps 
WHERE is_idle_movement_alert = TRUE 
ORDER BY record_date DESC, distance_km DESC;
```
