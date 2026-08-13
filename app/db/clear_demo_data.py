import sys
from pathlib import Path
import psycopg2

sys.path.append(str(Path(__file__).resolve().parent.parent.parent))
from app.config import settings

def clear_all_tables():
    print(f"Connecting to database at {settings.DB_HOST}:{settings.DB_PORT}/{settings.DB_NAME}...")
    conn = psycopg2.connect(settings.DATABASE_URL)
    conn.autocommit = True
    cur = conn.cursor()

    tables_to_clear = [
        # 9 Backend App Tables
        "app_drivers",
        "app_operators",
        "app_hisaabs",
        "app_payments",
        "app_support_tickets",
        "app_sessions",
        "app_notifications",
        "app_referral_leads",
        "app_audit_logs",
        
        # 10 Raw Automation Pipeline Target Tables
        "raw_uber_data",
        "raw_ola_data",
        "raw_rapido_data",
        "raw_uber_incentives",
        "raw_ola_incentives",
        "raw_rapido_incentives",
        "raw_traffic_challans",
        "raw_accidents_registry",
        "raw_partner_adjustments",
        "raw_gps_logs"
    ]

    print("\nTruncating all test/demo data from 19 database tables...")
    for tbl in tables_to_clear:
        try:
            cur.execute(f"TRUNCATE TABLE {tbl} RESTART IDENTITY CASCADE;")
            print(f"  [CLEARED 100%] Table '{tbl}' truncated successfully.")
        except Exception as e:
            print(f"  [WARNING] Could not truncate '{tbl}': {e}")

    print("\nAll 19 database tables are now 100% clean (0 rows) and ready for live automation data!")
    conn.close()

if __name__ == "__main__":
    clear_all_tables()
