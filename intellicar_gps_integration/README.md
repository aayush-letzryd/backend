# Intellicar GPS Data Integration

This folder contains the automated integration scripts for pulling daily vehicle distance data from the Intellicar API and storing it in the LetzRyd PostgreSQL database.

## Contents
- `intellicar_gps_pull.py`: The main Python automation script.

## Objective
To automatically fetch the total daily kilometers driven for all vehicles associated with the Intellicar account and maintain a historical ledger in the database for accurate tracking and gap analysis.

## Process Overview
1. **Database Setup**: The script ensures a destination table (`gps_test`) exists in the Postgres database with a strict Unique Constraint to prevent duplicates.
2. **Authentication**: Reaches out to the Intellicar API (`/gettoken`) with account credentials to generate a secure JSON Web Token (JWT). The token expires in 15 days, but since the script generates a fresh one on every run, it never expires in practice.
3. **Data Retrieval**: Using the JWT, the script queries the **Distance Bulk API**. It calculates the absolute start and end of the day in IST (00:00:00 to 23:59:59) and strictly converts it to Epoch Milliseconds (UTC) as required by the Intellicar platform. 
4. **Data Ingestion**: Parses the JSON response and strictly upserts (inserts or updates) the distance records into PostgreSQL using an optimized `execute_values` bulk insert.
5. **Automation**: A built-in scheduler handles backfilling data and then sleeps to automatically repeat the pull every day at **02:00 AM**.

## Prerequisites
Ensure the following Python packages are installed:
```bash
pip install requests psycopg2 schedule
```

## Running the Script
Run the script directly via Python:
```bash
python intellicar_gps_pull.py
```
*Note: If running on a server, it is recommended to run this within a `tmux` session or configure it as a standard system service (systemd) so the built-in schedule loop stays alive 24/7.*
