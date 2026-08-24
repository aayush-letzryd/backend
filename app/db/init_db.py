import os
import sys
import psycopg2
from pathlib import Path

# Add backend directory to path
sys.path.append(str(Path(__file__).resolve().parent.parent.parent))
from app.config import settings

def run_migrations():
    print(f"Connecting to Cloud SQL PostgreSQL at {settings.DB_HOST}:{settings.DB_PORT}/{settings.DB_NAME}...")
    conn = psycopg2.connect(
        host=settings.DB_HOST,
        port=settings.DB_PORT,
        user=settings.DB_USER,
        password=settings.DB_PASS,
        dbname=settings.DB_NAME
    )
    conn.autocommit = True
    cur = conn.cursor()

    schema_file = Path(__file__).parent / "schema.sql"
    if not schema_file.exists():
        raise FileNotFoundError(f"Schema file not found at {schema_file}")

    print(f"Reading schema DDL from {schema_file}...")
    with open(schema_file, 'r', encoding='utf-8') as f:
        sql_script = f.read()

    print("Executing database DDL migration...")
    cur.execute(sql_script)
    print("DB Migration completed successfully!")

    # Verify target tables
    target_tables = [
        'app_drivers', 'app_operators', 'app_hisaabs', 'app_payments',
        'app_support_tickets', 'app_sessions', 'app_notifications',
        'app_referral_leads', 'app_audit_logs',
        'raw_uber_data', 'raw_ola_data', 'raw_rapido_data',
        'raw_uber_incentives', 'raw_ola_incentives', 'raw_rapido_incentives'
    ]

    print("\n=== VERIFYING CREATED TABLES ===")
    for tbl in target_tables:
        cur.execute("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema='public' AND table_name=%s);", (tbl,))
        exists = cur.fetchone()[0]
        status = "OK [EXISTS]" if exists else "ERROR [MISSING]"
        print(f"Table '{tbl:<25}': {status}")

    conn.close()

if __name__ == "__main__":
    run_migrations()
