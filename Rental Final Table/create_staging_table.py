"""
Deploy Single Staging Table: public.portal_rental_plans
======================================================
Safely creates the staging intake table without affecting live production tables.
"""

import os
import sys
import psycopg2

sys.stdout.reconfigure(encoding='utf-8')

DB_HOST = os.getenv('DB_HOST', '35.200.196.113')
DB_PORT = os.getenv('DB_PORT', '5432')
DB_NAME = os.getenv('DB_NAME', 'postgres')
DB_USER = os.getenv('DB_USER', 'postgres')
DB_PASS = os.getenv('DB_PASSWORD', r'8S5]U3@L^Xz)\FH}')

def deploy_staging_table():
    print("Connecting to database...")
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASS
        )
        conn.autocommit = True
        cur = conn.cursor()

        cur.execute("""
            CREATE TABLE IF NOT EXISTS public.portal_rental_plans (
                id SERIAL PRIMARY KEY,
                config_type VARCHAR(32) NOT NULL,
                city VARCHAR(32) NOT NULL DEFAULT 'Bangalore',
                plan_id INT,
                plan_code VARCHAR(64),
                plan_name VARCHAR(128),
                plan_category VARCHAR(32) DEFAULT 'STANDARD',
                calculation_type VARCHAR(32) DEFAULT 'SLAB_TIERED',
                partner_id VARCHAR(64),
                partner_name VARCHAR(128),
                customer_type VARCHAR(32) DEFAULT 'ALL',
                vehicle_manufacturer VARCHAR(64),
                vehicle_model VARCHAR(64) DEFAULT 'ALL',
                vehicle_number VARCHAR(32),
                vehicle_age VARCHAR(32),
                metric_type VARCHAR(32) DEFAULT 'UBER_TRIPS',
                condition_rule VARCHAR(128) DEFAULT 'NONE',
                trip_min INT DEFAULT 0,
                trip_max INT,
                daily_rent NUMERIC(10,2) NOT NULL,
                daily_fee NUMERIC(10,2) NOT NULL DEFAULT 30.00,
                is_fee_waiver BOOLEAN NOT NULL DEFAULT FALSE,
                all_platform_flat_rent NUMERIC(10,2),
                valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
                valid_to DATE NOT NULL DEFAULT '9999-12-31',
                reason_or_notes TEXT,
                evidence_source VARCHAR(128),
                approved_by VARCHAR(64) DEFAULT 'Operations Head',
                created_by VARCHAR(64),
                status VARCHAR(32) NOT NULL DEFAULT 'Active',
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_type ON public.portal_rental_plans(config_type);
            CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_city ON public.portal_rental_plans(city);
            CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_partner ON public.portal_rental_plans(partner_id);
            CREATE INDEX IF NOT EXISTS idx_portal_rental_plans_veh ON public.portal_rental_plans(vehicle_number);
        """)
        print("[OK] public.portal_rental_plans created successfully.")

        # Check existing count
        cur.execute("SELECT COUNT(*) FROM public.portal_rental_plans;")
        count = cur.fetchone()[0]
        print(f"Current portal rental plans count: {count}")

        cur.close()
        conn.close()
    except Exception as e:
        print(f"[ERROR] Failed to deploy staging table: {e}")

if __name__ == '__main__':
    deploy_staging_table()
