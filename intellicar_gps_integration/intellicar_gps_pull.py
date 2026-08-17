import requests
import psycopg2
from psycopg2.extras import execute_values
import datetime
import schedule
import time
import logging

# ==========================================
# 1. LOGGING CONFIGURATION
# ==========================================
# We configure the built-in logging module to display timestamped messages.
# This helps in tracking the script's progress, debugging issues, and checking
# whether the scheduled jobs ran successfully at 2:00 AM.
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# ==========================================
# 2. CREDENTIALS AND CONFIGURATION
# ==========================================
# Database credentials for PostgreSQL where the GPS data will be stored.
DB_HOST = "35.200.196.113"
DB_PORT = "5432"
DB_NAME = "postgres"
DB_USER = "postgres"
DB_PASS = r"8S5]U3@L^Xz)\FH}"

# Intellicar account credentials used to generate the JWT token.
INTELLICAR_USER = "komala@letzryd.com"
INTELLICAR_PASS = "O0gixnQf6L"

# Base URL and endpoints as per Intellicar's Standard APIs Documentation.
BASE_URL = "https://apiplatform.intellicar.in/api/standard"
LOGIN_URL = f"{BASE_URL}/gettoken"
DISTANCE_URL = f"{BASE_URL}/getdistancebulk"

# ==========================================
# 3. DATABASE CONNECTION & SETUP
# ==========================================
def get_db_connection():
    """
    Establishes and returns a connection to the PostgreSQL database.
    """
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )

def setup_database():
    """
    Ensures the target table ('gps_test') exists.
    """
    create_table_query = """
    CREATE TABLE IF NOT EXISTS gps_test (
        id SERIAL PRIMARY KEY,
        vehicle_id VARCHAR(100) NOT NULL,
        record_date DATE NOT NULL,
        distance_km NUMERIC(10, 2),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (vehicle_id, record_date)
    );
    """
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(create_table_query)
        conn.commit()
        cur.close()
        conn.close()
        logging.info("Database setup complete. Table 'gps_test' is ready.")
    except Exception as e:
        logging.error(f"Error setting up database: {e}")

# ==========================================
# 4. INTELLICAR API COMMUNICATION
# ==========================================
def get_token():
    """
    Authenticates with Intellicar using the username/password.
    Returns a fresh JSON Web Token (JWT). The token usually expires in 15 days, 
    but since we generate a new one on every run, we never face expiration issues.
    """
    payload = {
        "username": INTELLICAR_USER,
        "password": INTELLICAR_PASS
    }
    
    try:
        response = requests.post(LOGIN_URL, json=payload)
        response.raise_for_status()
        data = response.json()
        if data.get("status") == "SUCCESS":
            return data["data"]["token"]
        else:
            logging.error(f"Login failed: {data.get('err')} - {data.get('msg')}")
            return None
    except Exception as e:
        logging.error(f"Error getting token: {e}")
        return None

def fetch_gps_data(token, target_date):
    """
    Fetches the total distance traveled for ALL vehicles on a given target_date.
    The Intellicar API expects 'starttime' and 'endtime' in UTC Epoch milliseconds.
    Since LetzRyd operates in India, we calculate the start (00:00:00) and end 
    (23:59:59) of the day in IST (UTC+5:30), and convert that precisely to Epoch ms.
    """
    ist_timezone = datetime.timezone(datetime.timedelta(hours=5, minutes=30))
    start_dt_ist = datetime.datetime.combine(target_date, datetime.time.min, tzinfo=ist_timezone)
    end_dt_ist = datetime.datetime.combine(target_date, datetime.time.max, tzinfo=ist_timezone)
    
    start_epoch_ms = int(start_dt_ist.timestamp() * 1000)
    end_epoch_ms = int(end_dt_ist.timestamp() * 1000)
    
    date_str = target_date.strftime("%Y-%m-%d")
    logging.info(f"Fetching data for {date_str} (Epoch MS: {start_epoch_ms} to {end_epoch_ms})")
    
    payload = {
        "token": token,
        "starttime": start_epoch_ms,
        "endtime": end_epoch_ms
    }
    
    try:
        response = requests.post(DISTANCE_URL, json=payload)
        response.raise_for_status()
        data = response.json()
        
        records = []
        if data.get("status") == "SUCCESS" and data.get("data"):
            for item in data["data"]:
                try:
                    dist = float(item.get("distance", 0))
                except (TypeError, ValueError):
                    dist = 0.0
                    
                records.append({
                    "vehicle_id": str(item.get("vehicleno")),
                    "record_date": target_date,
                    "distance_km": dist
                })
        else:
            logging.error(f"Failed to fetch data: {data.get('err')} - {data.get('msg')}")
            
        return records
    except Exception as e:
        logging.error(f"Error fetching GPS data for {date_str}: {e}")
        return []

# ==========================================
# 5. DATA INGESTION
# ==========================================
def insert_data(records):
    """
    Takes the cleaned records from the API and bulk-inserts them into Postgres.
    Uses ON CONFLICT DO UPDATE to ensure if the script runs twice for the same day,
    the distance simply gets updated to the latest value instead of duplicating.
    """
    if not records:
        logging.info("No records to insert.")
        return
        
    insert_query = """
    INSERT INTO gps_test (vehicle_id, record_date, distance_km)
    VALUES %s
    ON CONFLICT (vehicle_id, record_date) 
    DO UPDATE SET distance_km = EXCLUDED.distance_km;
    """
    
    values = [(r['vehicle_id'], r['record_date'], r['distance_km']) for r in records]
    
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        # execute_values is highly optimized for bulk inserting thousands of rows quickly
        execute_values(cur, insert_query, values)
        conn.commit()
        cur.close()
        conn.close()
        logging.info(f"Successfully inserted/updated {len(records)} records.")
    except Exception as e:
        logging.error(f"Error inserting data: {e}")

# ==========================================
# 6. JOB SCHEDULING AND ORCHESTRATION
# ==========================================
def run_daily_job(target_date=None):
    """
    The main orchestrator function. Grabs a token, fetches the data for the given date,
    and saves it to the database. If no date is passed, it defaults to 'yesterday'.
    """
    if not target_date:
        target_date = datetime.date.today() - datetime.timedelta(days=1)
        
    logging.info(f"Starting job for date: {target_date}")
    
    token = get_token()
    if not token:
        logging.error("Could not obtain token. Aborting job.")
        return
        
    records = fetch_gps_data(token, target_date)
    insert_data(records)
    logging.info(f"Job completed for date: {target_date}")

def backfill_data(days=7):
    """
    Loops backward through time to backfill missing data for a specific number of days.
    """
    logging.info(f"Starting backfill for the last {days} days...")
    for i in range(days, 0, -1):
        target_date = datetime.date.today() - datetime.timedelta(days=i)
        run_daily_job(target_date)
    logging.info("Backfill complete.")

# ==========================================
# 7. MAIN ENTRY POINT
# ==========================================
if __name__ == "__main__":
    setup_database()
    
    # ---------------------------------------------------------
    # ACTION: Pull data explicitly for April 15, 2026
    # ---------------------------------------------------------
    logging.info("Pulling requested data for April 15, 2026...")
    april_15_date = datetime.date(2026, 4, 15)
    run_daily_job(april_15_date)
    
    # (Optional) Schedule the daily job to run automatically every day at 02:00 AM
    # logging.info("Scheduling daily job to run at 02:00 AM...")
    # schedule.every().day.at("02:00").do(run_daily_job)
    
    # (Optional) Infinite loop to keep the script running
    # while True:
    #     schedule.run_pending()
    #     time.sleep(60)
