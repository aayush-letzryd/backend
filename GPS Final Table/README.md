# GPS Telematics Final Table Architecture

## Executive Summary
The `public.core_gps` table serves as the Single Source of Truth (SSOT) for vehicle telematics across the LetzRyd fleet. It unifies daily distance tracking from the Intellicar API, performs intelligent device-suffix and VIN-to-registration resolution, enriches telematics with operational driver attribution, raises instant alerts for unauthorized idle vehicle movement, and powers daily & weekly **Dead Mile Penalty** calculations in the downstream Hisaab Settlement Engine.

The pipeline utilizes a **Decoupled ELT Architecture with `pg_cron`**:
- **Extract & Load (Raw Ingestion)**: External GCP Cloud Run scheduler ingests pure telemetry into `public.sheet_gps_telematics`. This step is completely isolated with zero dependencies on other tables.
- **Transform & Sync (Batch ELT via `pg_cron`)**: Stored procedure `public.sp_sync_core_gps` runs automatically on a scheduled `pg_cron` job. It cleans, resolves, and enriches data into `public.core_gps`.
- **Downstream Hisaab Integration**: Telematics in `core_gps` is joined into `hisaab_daily_ledger` and weekly hisaab procedures (`sp_sync_rent_to_hisaab`, `sp_sync_hisaab_vehicle_weekly`, `sp_sync_hisaab_vehicle_payout_weekly`) to enforce Dead Mile Penalties for Individual/D2R partners.
- **Fault-Tolerant Isolation**: Any downstream enrichment or schema changes will never impact or roll back the external API ingestion scheduler.

## System Architecture

```
                      +-----------------------------+
                      |   Intellicar Telematics     |
                      |   Cloud REST API (/bulk)    |
                      +--------------+--------------+
                                     |
                                     v (GCP Cloud Run / Python Scheduler)
                      +-----------------------------+
                      | public.sheet_gps_telematics |
                      |    (Raw Staging Buffer)     |
                      +--------------+--------------+
                                     |
                                     v (Decoupled Batch ELT via pg_cron)
                      +-----------------------------+
                      |  public.sp_sync_core_gps()  |
                      |   (Hourly & Morning Deep)   |
                      +--------------+--------------+
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
                      +--------------+--------------+
                                     |
                                     v (Downstream Hisaab Integration)
                      +-----------------------------+
                      |  hisaab_daily_ledger / SPs  |
                      |  - Daily Dead KM Calc       |
                      |  - Daily Dead Mile Penalty  |
                      |  - Weekly Partner Settlement|
                      +-----------------------------+
```

## Dead Mile Calculation Rules in Hisaab

- **Weekly Aggregated Rule (`hisaab_vehicle_weekly`, `hisaab_partner_weekly`, `hisaab_vehicle_payout_weekly`)**:
$$\text{Weekly Ideal KM} = \sum \text{In-Trip KM (Uber+Ola+Rapido)} + \left(\sum \text{Completed Trips} \times 3.0\text{ km}\right) + (\text{Onroad Days} \times 30.0\text{ km})$$
$$\text{Weekly Dead KM} = \max\left(0, \sum \text{GPS KM} - \text{Weekly Ideal KM}\right)$$
$$\text{Weekly Dead Mile Penalty} = \begin{cases} \text{Weekly Dead KM} \times ₹3.00 & \text{if Partner Type} = \text{'Individual' } \land \text{City} \in \{\text{'BLR'}, \text{'BENGALURU'}\} \\ 0.00 & \text{for Fleet Operators (multi-car / OP / IP) or HYD/MUM} \end{cases}$$

- **Daily Ledger Rule (`hisaab_daily_ledger`)**:
$$\text{Daily Ideal KM} = \text{Daily In-Trip KM} + (\text{Daily Completed Trips} \times 3.0\text{ km}) + (\text{Is Billable Day} \times 30.0\text{ km})$$
$$\text{Daily Dead KM} = \max\left(0, \text{Daily GPS KM} - \text{Daily Ideal KM}\right)$$
$$\text{Daily Dead Mile Penalty} = \begin{cases} \text{Daily Dead KM} \times ₹3.00 & \text{if Partner Type} = \text{'Individual' } \land \text{City} \in \{\text{'BLR'}, \text{'BENGALURU'}\} \\ 0.00 & \text{otherwise} \end{cases}$$

## Data Dictionary: public.core_gps

- **id**: `BIGSERIAL PRIMARY KEY` - Monotonically increasing primary key.
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

## Scheduled pg_cron Jobs

| Job Name | Schedule | Target Procedure | Purpose |
| :--- | :--- | :--- | :--- |
| `sync-core-gps-hourly` | `25 * * * *` (Hourly at :25) | `CALL public.sp_sync_core_gps(3);` | Continuous rolling 3-day sync and midday updates |
| `sync-core-gps-morning-deep` | `0 3 * * *` (08:30 AM IST) | `CALL public.sp_sync_core_gps(7);` | Comprehensive morning 7-day deep reconciliation post-API run |

## Deployment & Setup

Deploy the updated schema and register the `pg_cron` jobs:

```bash
psql -h 35.200.196.113 -U postgres -d postgres -f "GPS Final Table/schema.sql"
```

## Automated Verification

Run the Python verification suite:

```bash
python "GPS Final Table/automation_script.py"
```

## Key Verification Queries

- Review active `pg_cron` jobs:
```sql
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname LIKE '%gps%';
```

- Check execution history in `pg_cron`:
```sql
SELECT jobid, runid, command, status, return_message, start_time, end_time 
FROM cron.job_run_details 
WHERE command LIKE '%sp_sync_core_gps%' 
ORDER BY start_time DESC 
LIMIT 5;
```

- Review active idle movement alerts:
```sql
SELECT record_date, vehicle_number, city, vehicle_status, distance_km, raw_vehicle_id 
FROM public.core_gps 
WHERE is_idle_movement_alert = TRUE 
ORDER BY record_date DESC, distance_km DESC;
```
