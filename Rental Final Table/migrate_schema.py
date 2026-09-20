"""
LetzRyd Unified Rental Architecture - Production Database Migration
===================================================================
1. Backs up existing rental tables.
2. Reconstructs rental tables with SERIAL PRIMARY KEYs (1, 2, 3...) and foreign keys.
3. Adds partner_id to rental_rate_slabs for custom operator trip tiers.
4. Adds default_daily_rent and default_daily_fee to core_rental_plans.
5. Populates rental_fee_rules with all waivers (Mumbai, Xcent, Shaik Kareem, Nisamudeen, Rishad).
6. Adds matched_plan_id, matched_slab_id, matched_custom_plan_id to daily_rent_log.
7. Deploys 100% data-driven, zero-hardcoded sp_calculate_daily_rent stored procedure.
"""

import os
import sys
import psycopg2
from psycopg2.extras import RealDictCursor

sys.stdout.reconfigure(encoding='utf-8')

DB_HOST = os.getenv('DB_HOST', '35.200.196.113')
DB_PORT = os.getenv('DB_PORT', '5432')
DB_NAME = os.getenv('DB_NAME', 'postgres')
DB_USER = os.getenv('DB_USER', 'postgres')
DB_PASS = os.getenv('DB_PASSWORD', r'8S5]U3@L^Xz)\FH}')

def run_migration():
    print("=" * 70)
    print("      STARTING ZERO-HARDCODED RENTAL SCHEMA MIGRATION")
    print("=" * 70)
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )
    conn.autocommit = True
    cur = conn.cursor()

    # Step 1: Backup existing data safely
    print("\n1. Backing up existing rental tables...")
    cur.execute("DROP TABLE IF EXISTS public.bkp_core_rental_plans CASCADE;")
    cur.execute("CREATE TABLE public.bkp_core_rental_plans AS SELECT * FROM public.core_rental_plans;")
    print("   [OK] bkp_core_rental_plans created.")

    cur.execute("DROP TABLE IF EXISTS public.bkp_rental_rate_slabs CASCADE;")
    cur.execute("CREATE TABLE public.bkp_rental_rate_slabs AS SELECT * FROM public.rental_rate_slabs;")
    print("   [OK] bkp_rental_rate_slabs created.")

    cur.execute("DROP TABLE IF EXISTS public.bkp_rental_custom_partner_plans CASCADE;")
    cur.execute("CREATE TABLE public.bkp_rental_custom_partner_plans AS SELECT * FROM public.rental_custom_partner_plans;")
    print("   [OK] bkp_rental_custom_partner_plans created.")

    cur.execute("DROP TABLE IF EXISTS public.bkp_rental_fee_rules CASCADE;")
    cur.execute("CREATE TABLE public.bkp_rental_fee_rules AS SELECT * FROM public.rental_fee_rules;")
    print("   [OK] bkp_rental_fee_rules created.")

    cur.execute("DROP TABLE IF EXISTS public.bkp_rental_model_baselines CASCADE;")
    cur.execute("CREATE TABLE public.bkp_rental_model_baselines AS SELECT * FROM public.rental_model_baselines;")
    print("   [OK] bkp_rental_model_baselines created.")

    # Step 2: Drop old tables with cascade
    print("\n2. Recreating tables with clean integer SERIAL PRIMARY KEY (1, 2, 3...)...")
    cur.execute("DROP TABLE IF EXISTS public.rental_rate_slabs CASCADE;")
    cur.execute("DROP TABLE IF EXISTS public.core_rental_plans CASCADE;")
    cur.execute("DROP TABLE IF EXISTS public.rental_custom_partner_plans CASCADE;")
    cur.execute("DROP TABLE IF EXISTS public.rental_fee_rules CASCADE;")
    cur.execute("DROP TABLE IF EXISTS public.rental_model_baselines CASCADE;")
    cur.execute("DROP TABLE IF EXISTS public.rental_exceptions CASCADE;")

    # Table 1: core_rental_plans
    cur.execute("""
        CREATE TABLE public.core_rental_plans (
            plan_id SERIAL PRIMARY KEY,
            plan_code VARCHAR(64) UNIQUE NOT NULL,
            city VARCHAR(32) NOT NULL,
            plan_name VARCHAR(128) NOT NULL,
            plan_category VARCHAR(32) NOT NULL,
            calculation_type VARCHAR(32) NOT NULL,
            default_daily_rent NUMERIC(10,2) NOT NULL,
            default_daily_fee NUMERIC(10,2) NOT NULL DEFAULT 30.00,
            description TEXT,
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX idx_core_rental_plans_city ON public.core_rental_plans(city, is_active);
    """)
    print("   [OK] core_rental_plans created with SERIAL PRIMARY KEY.")

    # Table 2: rental_rate_slabs
    cur.execute("""
        CREATE TABLE public.rental_rate_slabs (
            slab_id SERIAL PRIMARY KEY,
            plan_id INT NOT NULL REFERENCES public.core_rental_plans(plan_id) ON DELETE CASCADE,
            partner_id VARCHAR(64) NOT NULL DEFAULT 'ALL',
            city VARCHAR(32) NOT NULL,
            customer_type VARCHAR(32) NOT NULL DEFAULT 'ALL',
            vehicle_model VARCHAR(64) NOT NULL DEFAULT 'ALL',
            source_plan_code VARCHAR(64),
            metric_type VARCHAR(32) NOT NULL DEFAULT 'UBER_TRIPS',
            condition_rule VARCHAR(128) NOT NULL DEFAULT 'NONE',
            trip_min INT NOT NULL,
            trip_max INT,
            base_daily_rent NUMERIC(10,2) NOT NULL,
            default_daily_fee NUMERIC(10,2) NOT NULL DEFAULT 30.00,
            valid_from DATE NOT NULL DEFAULT '2026-01-01',
            valid_to DATE NOT NULL DEFAULT '9999-12-31',
            evidence_reference VARCHAR(128),
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT uq_rental_rate_slabs UNIQUE (plan_id, partner_id, customer_type, vehicle_model, condition_rule, trip_min, valid_from)
        );
        CREATE INDEX idx_rental_rate_slabs_lookup ON public.rental_rate_slabs(city, partner_id, customer_type, vehicle_model, trip_min, trip_max);
    """)
    print("   [OK] rental_rate_slabs created with partner_id and SERIAL PRIMARY KEY.")

    # Table 3: rental_custom_partner_plans
    cur.execute("""
        CREATE TABLE public.rental_custom_partner_plans (
            custom_plan_id SERIAL PRIMARY KEY,
            partner_id VARCHAR(64) NOT NULL,
            partner_name VARCHAR(128),
            city VARCHAR(32) NOT NULL,
            vehicle_model VARCHAR(64),
            vehicle_number VARCHAR(32),
            plan_id INT REFERENCES public.core_rental_plans(plan_id) ON DELETE SET NULL,
            custom_daily_rent NUMERIC(10,2),
            custom_daily_fee NUMERIC(10,2) NOT NULL DEFAULT 30.00,
            plan_label VARCHAR(128),
            evidence_source VARCHAR(128),
            approved_by VARCHAR(64) DEFAULT 'Operations Head',
            valid_from DATE NOT NULL DEFAULT '2026-01-01',
            valid_to DATE NOT NULL DEFAULT '9999-12-31',
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX idx_rental_custom_partner_lookup ON public.rental_custom_partner_plans(partner_id, is_active, valid_from, valid_to);
    """)
    print("   [OK] rental_custom_partner_plans created with SERIAL PRIMARY KEY.")

    # Table 4: rental_model_baselines
    cur.execute("""
        CREATE TABLE public.rental_model_baselines (
            baseline_id SERIAL PRIMARY KEY,
            city VARCHAR(32) NOT NULL,
            vehicle_model VARCHAR(64) NOT NULL,
            default_base_rent NUMERIC(10,2) NOT NULL,
            default_daily_indemnity NUMERIC(10,2) NOT NULL DEFAULT 30.00,
            all_platform_flat_rent NUMERIC(10,2) NOT NULL DEFAULT 1050.00,
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT uq_rental_model_baselines UNIQUE (city, vehicle_model)
        );
        CREATE INDEX idx_rental_model_baselines_lookup ON public.rental_model_baselines(city, vehicle_model);
    """)
    print("   [OK] rental_model_baselines created with SERIAL PRIMARY KEY.")

    # Table 5: rental_fee_rules
    cur.execute("""
        CREATE TABLE public.rental_fee_rules (
            fee_rule_id SERIAL PRIMARY KEY,
            city VARCHAR(32) NOT NULL DEFAULT 'ALL',
            partner_id VARCHAR(64) NOT NULL DEFAULT 'ALL',
            vehicle_model VARCHAR(64) NOT NULL DEFAULT 'ALL',
            fee_amount NUMERIC(10,2) NOT NULL,
            is_waiver BOOLEAN NOT NULL DEFAULT FALSE,
            reason VARCHAR(255) NOT NULL,
            valid_from DATE NOT NULL DEFAULT '2026-01-01',
            valid_to DATE NOT NULL DEFAULT '9999-12-31',
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX idx_rental_fee_rules_lookup ON public.rental_fee_rules(city, partner_id, vehicle_model, valid_from, valid_to);
    """)
    print("   [OK] rental_fee_rules created with SERIAL PRIMARY KEY.")

    # Table 6: rental_exceptions
    cur.execute("""
        CREATE TABLE public.rental_exceptions (
            exception_id SERIAL PRIMARY KEY,
            override_type VARCHAR(64) NOT NULL,
            city VARCHAR(32) NOT NULL,
            partner_id VARCHAR(64),
            vehicle_number VARCHAR(32),
            vehicle_model VARCHAR(64),
            override_daily_rent NUMERIC(10,2) NOT NULL,
            override_fee NUMERIC(10,2),
            canonical_expected_rent NUMERIC(10,2),
            variance NUMERIC(10,2),
            reason TEXT NOT NULL,
            status VARCHAR(32) NOT NULL DEFAULT 'APPROVED',
            approved_by VARCHAR(64) DEFAULT 'System Migration',
            approval_date DATE DEFAULT CURRENT_DATE,
            valid_from DATE NOT NULL,
            valid_to DATE NOT NULL,
            source_file VARCHAR(255),
            source_row INT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX idx_rental_exceptions_lookup ON public.rental_exceptions(partner_id, vehicle_number, valid_from, valid_to, status);
    """)
    print("   [OK] rental_exceptions created with SERIAL PRIMARY KEY.")

    # Step 3: Ensure daily_rent_log has lineage tracking columns
    print("\n3. Enforcing lineage columns in daily_rent_log...")
    cur.execute("""
        ALTER TABLE public.daily_rent_log 
        ADD COLUMN IF NOT EXISTS matched_plan_id INT REFERENCES public.core_rental_plans(plan_id) ON DELETE SET NULL,
        ADD COLUMN IF NOT EXISTS matched_slab_id INT REFERENCES public.rental_rate_slabs(slab_id) ON DELETE SET NULL,
        ADD COLUMN IF NOT EXISTS matched_custom_plan_id INT REFERENCES public.rental_custom_partner_plans(custom_plan_id) ON DELETE SET NULL;
    """)
    print("   [OK] Lineage foreign keys added to daily_rent_log.")

    # Step 4: Seed Canonical Plans with Integer IDs
    print("\n4. Seeding core_rental_plans with integer primary keys...")
    plans = [
        # (plan_id, plan_code, city, plan_name, plan_category, calculation_type, default_daily_rent, default_daily_fee, description)
        (1, 'BLR_MASTER_IND', 'Bangalore', 'Bangalore Master Individual', 'STANDARD', 'PLATFORM_SPLIT', 929.00, 30.00, 'Individual reducing slabs; Ola trips >= 1 applies flat ₹1,050/day from slab'),
        (2, 'BLR_MASTER_OP', 'Bangalore', 'Bangalore Master Operator', 'STANDARD', 'PLATFORM_SPLIT', 900.00, 30.00, 'Operator reducing slabs; Ola only applies flat ₹1,050/day from slab'),
        (3, 'BLR_UBER_TBS', 'Bangalore', 'Bangalore Uber TBS', 'STANDARD', 'SLAB_TIERED', 929.00, 30.00, 'Bangalore Uber TBS 4-tier reducing slabs'),
        (4, 'BLR_ALL_PLATFORM', 'Bangalore', 'Bangalore All Platform Flat', 'STANDARD', 'FLAT_RATE', 1050.00, 30.00, 'Flat rent ₹1,050/day for multi-platform vehicles'),
        (5, 'BLR_FALLBACK', 'Bangalore', 'Bangalore Model Fallback', 'STANDARD', 'MODEL_FALLBACK', 929.00, 30.00, 'Fallback baseline rate for Bangalore'),
        
        (6, 'HYD_UBER_TBS', 'Hyderabad', 'Hyderabad Uber TBS', 'STANDARD', 'SLAB_TIERED', 989.00, 30.00, 'Standard TBS trip reducing slabs for WagonR, Dzire, EC3'),
        (7, 'HYD_UBER_EBS', 'Hyderabad', 'Hyderabad Uber EBS', 'STANDARD', 'SLAB_TIERED', 989.00, 30.00, 'Standard EBS trip reducing slabs for WagonR, Dzire, EC3'),
        (8, 'HYD_ALL_PLATFORM', 'Hyderabad', 'Hyderabad All Platform Flat', 'STANDARD', 'FLAT_RATE', 1050.00, 30.00, 'Flat rent for multi-platform vehicles'),
        (9, 'HYD_FALLBACK', 'Hyderabad', 'Hyderabad Model Fallback', 'STANDARD', 'MODEL_FALLBACK', 989.00, 30.00, 'Fallback baseline rate for Hyderabad'),

        (10, 'MUM_UBER_REDUCING', 'Mumbai', 'Mumbai Uber Reducing Rent', 'STANDARD', 'SLAB_TIERED', 970.00, 0.00, 'Standard 6-tier reducing rent slabs for WagonR'),
        (11, 'MUM_DZIRE_STD', 'Mumbai', 'Mumbai Dzire Standard', 'STANDARD', 'FLAT_RATE', 1100.00, 0.00, 'Standard Dzire base rent ₹1,100/day'),
        (12, 'MUM_ALL_PLATFORM', 'Mumbai', 'Mumbai All Platform Flat', 'STANDARD', 'FLAT_RATE', 1050.00, 0.00, 'Flat rent ₹1,050/day for multi-platform vehicles'),
        (13, 'MUM_FALLBACK', 'Mumbai', 'Mumbai Model Fallback', 'STANDARD', 'MODEL_FALLBACK', 970.00, 0.00, 'Fallback baseline rate for Mumbai'),

        (14, 'BLR_OP_HAMZA', 'Bangalore', 'Hamza Moidu Custom Operator Slabs', 'CUSTOM', 'SLAB_TIERED', 870.00, 30.00, 'Custom operator reducing slabs for Hamza Moidu (<55=870, 55+=840, 65+=790, 75+=770)')
    ]
    cur.executemany("""
        INSERT INTO public.core_rental_plans 
        (plan_id, plan_code, city, plan_name, plan_category, calculation_type, default_daily_rent, default_daily_fee, description)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s);
    """, plans)
    cur.execute("SELECT setval('public.core_rental_plans_plan_id_seq', (SELECT MAX(plan_id) FROM public.core_rental_plans));")
    print(f"   [OK] Seeded {len(plans)} core plans with integer primary keys.")

    # Step 5: Seed Fee Rules (100% data-driven, ZERO hardcoded waivers)
    print("\n5. Seeding rental_fee_rules (Mumbai waiver, Xcent waiver, partner waivers)...")
    fee_rules = [
        # (city, partner_id, vehicle_model, fee_amount, is_waiver, reason, valid_from, valid_to)
        ('ALL', 'ALL', 'ALL', 30.00, False, 'Standard daily indemnity across all cities', '2026-01-01', '9999-12-31'),
        ('Mumbai', 'ALL', 'ALL', 0.00, True, 'Mumbai city indemnity fee waiver policy (all vehicles ₹0 fee)', '2026-01-01', '9999-12-31'),
        ('Hyderabad', 'ALL', 'Hyundai Xcent', 0.00, True, 'Hyundai Xcent retired fleet indemnity waiver', '2026-01-01', '9999-12-31'),
        ('Hyderabad', 'LETZHYDIP9701685282', 'ALL', 0.00, True, 'Shaik Kareem indemnity waiver', '2026-01-01', '9999-12-31'),
        ('Hyderabad', 'LETZHYDIP9885838038', 'ALL', 0.00, True, 'Shaik Kareem indemnity waiver', '2026-01-01', '9999-12-31'),
        ('Bangalore', 'LETZBLRIP9036461336', 'ALL', 15.00, False, 'Nisamudeen K P negotiated indemnity rate ₹15/day', '2026-01-01', '9999-12-31'),
        ('Bangalore', 'LETZBLRIP9656907001', 'ALL', 20.00, False, 'Rishad P V negotiated indemnity rate ₹20/day', '2026-01-01', '9999-12-31')
    ]
    cur.executemany("""
        INSERT INTO public.rental_fee_rules (city, partner_id, vehicle_model, fee_amount, is_waiver, reason, valid_from, valid_to)
        VALUES (%s, %s, %s, %s, %s, %s, %s::date, %s::date);
    """, fee_rules)
    print(f"   [OK] Seeded {len(fee_rules)} fee rules.")

    # Step 6: Seed Model Baselines
    print("\n6. Seeding rental_model_baselines...")
    baselines = [
        ('Bangalore', 'ALL', 1050.00, 30.00, 1050.00),
        ('Bangalore', 'WagonR', 929.00, 30.00, 1050.00),
        ('Bangalore', 'Dzire', 1100.00, 30.00, 1200.00),
        ('Bangalore', 'Aura', 1100.00, 30.00, 1200.00),
        ('Bangalore', 'Tigor EV', 1300.00, 30.00, 1300.00),
        ('Bangalore', 'Tata Nexon EV', 1500.00, 30.00, 1500.00),
        ('Bangalore', 'Toyota Etios', 1150.00, 30.00, 1200.00),

        ('Hyderabad', 'ALL', 1050.00, 30.00, 1050.00),
        ('Hyderabad', 'WagonR', 989.00, 30.00, 1050.00),
        ('Hyderabad', 'Dzire', 1100.00, 30.00, 1200.00),
        ('Hyderabad', 'EC3', 1400.00, 30.00, 1400.00),
        ('Hyderabad', 'Hyundai Aura', 1100.00, 30.00, 1200.00),
        ('Hyderabad', 'Hyundai Xcent', 900.00, 0.00, 900.00),
        ('Hyderabad', 'Tigor EV', 1300.00, 30.00, 1300.00),
        ('Hyderabad', 'Tata Nexon EV', 1500.00, 30.00, 1500.00),
        ('Hyderabad', 'Mahindra e-Verito', 1100.00, 30.00, 1100.00),

        ('Mumbai', 'ALL', 970.00, 0.00, 1050.00),
        ('Mumbai', 'WagonR', 970.00, 0.00, 1050.00),
        ('Mumbai', 'Dzire', 1100.00, 0.00, 1200.00),
        ('Mumbai', 'Aura', 1100.00, 0.00, 1200.00),
        ('Mumbai', 'Tigor EV', 1300.00, 0.00, 1300.00)
    ]
    cur.executemany("""
        INSERT INTO public.rental_model_baselines (city, vehicle_model, default_base_rent, default_daily_indemnity, all_platform_flat_rent)
        VALUES (%s, %s, %s, %s, %s);
    """, baselines)
    print(f"   [OK] Seeded {len(baselines)} model baselines.")

    # Step 7: Seed Slabs from Backup with integer plan_id + Custom Operator Slabs
    print("\n7. Migrating slabs to integer plan_id and seeding custom operator slabs...")
    cur.execute("""
        INSERT INTO public.rental_rate_slabs (
            plan_id, partner_id, city, customer_type, vehicle_model, source_plan_code,
            metric_type, condition_rule, trip_min, trip_max, base_daily_rent, default_daily_fee,
            valid_from, valid_to, evidence_reference
        )
        SELECT 
            p.plan_id,
            'ALL' AS partner_id,
            b.city,
            b.customer_type,
            b.vehicle_model,
            b.source_plan_code,
            b.metric_type,
            b.condition_rule,
            b.trip_min,
            b.trip_max,
            b.base_daily_rent,
            b.default_daily_fee,
            b.valid_from,
            b.valid_to,
            b.evidence_reference
        FROM public.bkp_rental_rate_slabs b
        JOIN public.core_rental_plans p ON p.plan_code = b.plan_id;
    """)
    print("   [OK] Standard slabs migrated with integer plan_id.")

    # Seed Hamza Moidu's Custom Operator Slabs directly into rental_rate_slabs!
    hamza_slabs = [
        # (plan_id, partner_id, city, customer_type, vehicle_model, source_plan_code, metric_type, condition_rule, trip_min, trip_max, base_daily_rent, default_daily_fee, valid_from, valid_to, evidence_reference)
        (14, 'LETZBLR_HAMZA', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 0, 54, 870.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal Side Table: <55 trips = 870/day'),
        (14, 'LETZBLR_HAMZA', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 55, 64, 840.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal Side Table: 55-64 trips = 840/day'),
        (14, 'LETZBLR_HAMZA', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 65, 74, 790.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal Side Table: 65-74 trips = 790/day'),
        (14, 'LETZBLR_HAMZA', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 75, 9999, 770.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal Side Table: 75+ trips = 770/day')
    ]
    cur.executemany("""
        INSERT INTO public.rental_rate_slabs (
            plan_id, partner_id, city, customer_type, vehicle_model, source_plan_code,
            metric_type, condition_rule, trip_min, trip_max, base_daily_rent, default_daily_fee,
            valid_from, valid_to, evidence_reference
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::date, %s::date, %s);
    """, hamza_slabs)
    print(f"   [OK] Seeded {len(hamza_slabs)} custom operator slabs for Hamza Moidu.")

    # Step 8: Restore Custom Partner Agreements
    print("\n8. Restoring rental_custom_partner_plans from backup...")
    cur.execute("""
        INSERT INTO public.rental_custom_partner_plans (
            partner_id, partner_name, city, vehicle_model, vehicle_number,
            custom_daily_rent, custom_daily_fee, plan_label, evidence_source,
            approved_by, valid_from, valid_to, is_active, created_at
        )
        SELECT 
            partner_id, partner_name, city, vehicle_model, vehicle_number,
            custom_daily_rent, custom_daily_fee, plan_label, evidence_source,
            approved_by, valid_from, valid_to, is_active, created_at
        FROM public.bkp_rental_custom_partner_plans
        WHERE partner_id <> 'LETZBLR_HAMZA';
    """)
    print("   [OK] Partner agreements restored.")

    # Step 9: Deploy 100% Data-Driven sp_calculate_daily_rent
    print("\n9. Deploying 100% Data-Driven sp_calculate_daily_rent...")
    cur.execute("""
CREATE OR REPLACE PROCEDURE public.sp_calculate_daily_rent(
    IN p_start_date DATE DEFAULT NULL,
    IN p_end_date DATE DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_start_date DATE;
    v_end_date DATE;
    v_curr_date DATE;
BEGIN
    v_start_date := COALESCE(p_start_date, CURRENT_DATE - 1);
    v_end_date := COALESCE(p_end_date, v_start_date);

    FOR v_curr_date IN 
        SELECT generate_series(v_start_date, v_end_date, '1 day'::interval)::DATE
    LOOP
        WITH raw_status AS (
            SELECT 
                s.status_date AS log_date,
                UPPER(REPLACE(s.vehicle_number, ' ', '')) AS vehicle_number,
                COALESCE(NULLIF(TRIM(s.partner_id), ''), 'SYSTEM_ONBOARDED') AS partner_id,
                CASE 
                    WHEN s.city ILIKE 'blr%' OR s.city ILIKE 'bengalur%' OR s.city ILIKE 'bangal%' THEN 'Bangalore'
                    WHEN s.city ILIKE 'hyd%' THEN 'Hyderabad'
                    WHEN s.city ILIKE 'mum%' OR s.city ILIKE 'bombay%' THEN 'Mumbai'
                    ELSE COALESCE(s.city, 'Hyderabad')
                END AS city,
                COALESCE(s.car_model, 'Unknown') AS vehicle_model,
                COALESCE(s.final_status, 'Active') AS attendance_status,
                s.billable_rent_day,
                COALESCE(
                    hw.week_id,
                    'CY' || TO_CHAR(s.status_date, 'YY') || 'WK' || LPAD(TO_CHAR(s.status_date, 'IW'), 2, '0')
                ) AS week_id,
                COALESCE(hw.week_start, s.status_date - (EXTRACT(ISODOW FROM s.status_date)::INT - 1)) AS week_start,
                COALESCE(hw.week_end, s.status_date + (7 - EXTRACT(ISODOW FROM s.status_date)::INT)) AS week_end
            FROM public.core_daily_vehicle_status s
            LEFT JOIN public.hisaab_settlement_weeks hw 
                ON s.status_date BETWEEN hw.week_start AND hw.week_end
            WHERE s.status_date = v_curr_date
        ),
        daily_trips AS (
            SELECT 
                u.vehicle_number,
                COALESCE(SUM(ub.completed_trips), 0) + COALESCE(SUM(ol.completed_trips), 0) AS week_trips,
                COALESCE(SUM(ol.completed_trips), 0) AS week_ola_trips
            FROM (SELECT DISTINCT vehicle_number, week_start, week_end FROM raw_status) u
            LEFT JOIN public.core_uber_daily ub 
                ON UPPER(REPLACE(ub.vehicle_number, ' ', '')) = u.vehicle_number
                AND ub.operational_date BETWEEN u.week_start AND u.week_end
            LEFT JOIN public.core_ola_daily ol 
                ON UPPER(REPLACE(ol.vehicle_number, ' ', '')) = u.vehicle_number
                AND ol.service_date BETWEEN u.week_start AND u.week_end
            GROUP BY u.vehicle_number
        ),
        status_with_billability AS (
            SELECT 
                rs.log_date,
                rs.week_id,
                rs.vehicle_number,
                rs.partner_id,
                rs.city,
                rs.vehicle_model,
                CASE 
                    WHEN COALESCE(dt.week_trips, 0) > 0 AND rs.attendance_status IN ('Drop Off', 'Drop-off', 'RFD', 'Unassigned', 'Maintenance', 'Breakdown', 'Accident') THEN 'Active'
                    ELSE rs.attendance_status
                END AS attendance_status,
                CASE 
                    WHEN COALESCE(dt.week_trips, 0) > 0 THEN TRUE
                    WHEN rs.attendance_status IN ('Drop Off', 'Drop-off', 'RFD', 'Unassigned') THEN FALSE
                    WHEN rs.attendance_status IN ('Maintenance', 'Breakdown', 'Accident') AND NOT rs.billable_rent_day THEN FALSE
                    ELSE TRUE
                END AS is_billable_day,
                COALESCE(dt.week_trips, 0)::INT AS weekly_completed_trips,
                COALESCE(dt.week_ola_trips, 0)::INT AS weekly_ola_trips,
                CASE 
                    WHEN rs.partner_id ILIKE '%OP%' OR rs.partner_id ILIKE '%FLEET%' OR rs.partner_id ILIKE '%IP%' THEN 'Operator'
                    ELSE 'Individual'
                END AS customer_type
            FROM raw_status rs
            LEFT JOIN daily_trips dt ON dt.vehicle_number = rs.vehicle_number
        ),
        waterfall AS (
            SELECT 
                swb.log_date,
                swb.week_id,
                swb.vehicle_number,
                swb.partner_id,
                swb.city,
                swb.vehicle_model,
                swb.attendance_status,
                swb.is_billable_day,
                swb.weekly_completed_trips,

                -- Data-Driven Rent Selection (Zero hardcoded rates)
                CASE 
                    WHEN NOT swb.is_billable_day OR swb.partner_id = '' OR swb.partner_id = 'SYSTEM_ONBOARDED' THEN 0.00
                    WHEN ex.override_daily_rent IS NOT NULL THEN ex.override_daily_rent
                    WHEN cp.custom_daily_rent IS NOT NULL THEN cp.custom_daily_rent
                    WHEN slab.base_daily_rent IS NOT NULL THEN slab.base_daily_rent
                    WHEN mb.default_base_rent IS NOT NULL THEN mb.default_base_rent
                    WHEN p.default_daily_rent IS NOT NULL THEN p.default_daily_rent
                    ELSE 0.00
                END AS applied_daily_rent,

                -- Data-Driven Indemnity Selection (Zero hardcoded fees or waivers)
                CASE 
                    WHEN NOT swb.is_billable_day OR swb.partner_id = '' OR swb.partner_id = 'SYSTEM_ONBOARDED' THEN 0.00
                    WHEN ex.override_fee IS NOT NULL THEN ex.override_fee
                    WHEN cp.custom_daily_fee IS NOT NULL AND cp.custom_daily_rent IS NOT NULL THEN cp.custom_daily_fee
                    WHEN fee.is_waiver = TRUE THEN 0.00
                    WHEN fee.fee_amount IS NOT NULL THEN fee.fee_amount
                    WHEN slab.default_daily_fee IS NOT NULL THEN slab.default_daily_fee
                    WHEN mb.default_daily_indemnity IS NOT NULL THEN mb.default_daily_indemnity
                    WHEN p.default_daily_fee IS NOT NULL THEN p.default_daily_fee
                    ELSE 0.00
                END AS applied_daily_indemnity,

                -- Lineage Identifiers linking back to table records
                COALESCE(slab.plan_id, p.plan_id) AS matched_plan_id,
                slab.slab_id AS matched_slab_id,
                cp.custom_plan_id AS matched_custom_plan_id,

                -- Transparent Calculation Trace
                CASE 
                    WHEN NOT swb.is_billable_day THEN 'Non-billable status: ' || swb.attendance_status
                    WHEN swb.partner_id = '' OR swb.partner_id = 'SYSTEM_ONBOARDED' THEN 'Unallocated / Yard'
                    WHEN ex.override_daily_rent IS NOT NULL THEN 'Priority 1: Approved Exception (ID #' || ex.exception_id || ')'
                    WHEN cp.custom_daily_rent IS NOT NULL THEN 'Priority 2: Custom Partner Deal (Card #' || cp.custom_plan_id || ': ' || COALESCE(cp.plan_label, 'Flat') || ')'
                    WHEN slab.base_daily_rent IS NOT NULL THEN 'Priority 3: Dynamic Slab (Plan #' || slab.plan_id || ': ' || slab.plan_code || ', Slab #' || slab.slab_id || ', Partner: ' || slab.partner_id || ')'
                    WHEN mb.default_base_rent IS NOT NULL THEN 'Priority 4: Model Baseline (Baseline #' || mb.baseline_id || ': ' || mb.vehicle_model || ')'
                    WHEN p.default_daily_rent IS NOT NULL THEN 'Priority 5: Master City Default (Plan #' || p.plan_id || ': ' || p.plan_code || ')'
                    ELSE 'Priority 5: Fallback Zero'
                END AS calculation_rule

            FROM status_with_billability swb

            -- Priority 1: rental_exceptions
            LEFT JOIN LATERAL (
                SELECT exception_id, override_daily_rent, override_fee, reason
                FROM public.rental_exceptions
                WHERE status IN ('APPROVED', 'PENDING_CONFIRMATION')
                  AND swb.log_date BETWEEN valid_from AND valid_to
                  AND (
                      (partner_id = swb.partner_id AND vehicle_number = swb.vehicle_number)
                      OR (vehicle_number = swb.vehicle_number AND partner_id IS NULL)
                      OR (partner_id = swb.partner_id AND vehicle_number IS NULL)
                  )
                ORDER BY 
                    CASE WHEN partner_id IS NOT NULL AND vehicle_number IS NOT NULL THEN 1
                         WHEN vehicle_number IS NOT NULL THEN 2
                         ELSE 3 END
                LIMIT 1
            ) ex ON TRUE

            -- Priority 2: rental_custom_partner_plans
            LEFT JOIN LATERAL (
                SELECT custom_plan_id, custom_daily_rent, custom_daily_fee, plan_label
                FROM public.rental_custom_partner_plans
                WHERE partner_id = swb.partner_id 
                  AND is_active = TRUE
                  AND swb.log_date BETWEEN valid_from AND valid_to
                  AND (vehicle_number = swb.vehicle_number OR vehicle_number IS NULL)
                  AND (vehicle_model IS NULL 
                       OR REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') || '%'
                       OR REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%')
                ORDER BY vehicle_number NULLS LAST, vehicle_model NULLS LAST
                LIMIT 1
            ) cp ON TRUE

            -- Priority 3: rental_rate_slabs (Custom Operator Slabs match first, then City Slabs)
            LEFT JOIN LATERAL (
                SELECT s.slab_id, s.plan_id, s.base_daily_rent, s.default_daily_fee, s.partner_id, p.plan_code
                FROM public.rental_rate_slabs s
                JOIN public.core_rental_plans p ON p.plan_id = s.plan_id
                WHERE s.city = swb.city
                  AND (s.partner_id = swb.partner_id OR s.partner_id = 'ALL')
                  AND (s.customer_type = 'ALL' OR s.customer_type = swb.customer_type)
                  AND (s.vehicle_model = 'ALL' 
                       OR REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(s.vehicle_model), '-', ''), ' ', '') || '%'
                       OR REPLACE(REPLACE(LOWER(s.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%')
                  AND (
                      (s.condition_rule = 'OLA_GE_1' AND swb.weekly_ola_trips >= 1)
                      OR
                      (s.condition_rule = 'OLA_GE_1_UBER_ZERO' AND swb.weekly_ola_trips >= 1 AND (swb.weekly_completed_trips - swb.weekly_ola_trips) = 0)
                      OR
                      (s.condition_rule = 'OLA_ZERO' AND swb.weekly_ola_trips = 0 
                       AND s.trip_min <= swb.weekly_completed_trips AND (s.trip_max IS NULL OR swb.weekly_completed_trips <= s.trip_max))
                      OR
                      (s.condition_rule = 'NONE' 
                       AND s.trip_min <= swb.weekly_completed_trips AND (s.trip_max IS NULL OR swb.weekly_completed_trips <= s.trip_max))
                  )
                  AND swb.log_date BETWEEN s.valid_from AND s.valid_to
                ORDER BY 
                    CASE WHEN s.partner_id <> 'ALL' THEN 1 ELSE 2 END,                     -- Operator custom slabs win first!
                    CASE WHEN s.condition_rule IN ('OLA_GE_1', 'OLA_GE_1_UBER_ZERO') THEN 1 ELSE 2 END, -- Specific conditions
                    CASE WHEN s.vehicle_model <> 'ALL' THEN 1 ELSE 2 END,                  -- Model specific
                    CASE WHEN s.customer_type <> 'ALL' THEN 1 ELSE 2 END,                  -- Customer type
                    s.trip_min DESC
                LIMIT 1
            ) slab ON TRUE

            -- Priority 4: rental_model_baselines
            LEFT JOIN LATERAL (
                SELECT baseline_id, default_base_rent, default_daily_indemnity, vehicle_model
                FROM public.rental_model_baselines
                WHERE city = swb.city
                  AND is_active = TRUE
                  AND (REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') || '%'
                       OR REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%')
                ORDER BY CASE WHEN vehicle_model <> 'ALL' THEN 1 ELSE 2 END
                LIMIT 1
            ) mb ON TRUE

            -- Priority 5: core_rental_plans (City Master Fallback)
            LEFT JOIN LATERAL (
                SELECT plan_id, plan_code, default_daily_rent, default_daily_fee
                FROM public.core_rental_plans
                WHERE city = swb.city AND calculation_type = 'MODEL_FALLBACK' AND is_active = TRUE
                LIMIT 1
            ) p ON TRUE

            -- Indemnity Rules lookup from rental_fee_rules
            LEFT JOIN LATERAL (
                SELECT fee_rule_id, fee_amount, is_waiver
                FROM public.rental_fee_rules
                WHERE (city = 'ALL' OR city = swb.city)
                  AND (partner_id = 'ALL' OR partner_id = swb.partner_id)
                  AND (vehicle_model = 'ALL' 
                       OR REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') || '%'
                       OR REPLACE(REPLACE(LOWER(vehicle_model), '-', ''), ' ', '') LIKE '%' || REPLACE(REPLACE(LOWER(swb.vehicle_model), '-', ''), ' ', '') || '%')
                  AND swb.log_date BETWEEN valid_from AND valid_to
                ORDER BY 
                    CASE WHEN partner_id <> 'ALL' THEN 1 ELSE 2 END,
                    CASE WHEN vehicle_model <> 'ALL' THEN 1 ELSE 2 END,
                    CASE WHEN city <> 'ALL' THEN 1 ELSE 2 END
                LIMIT 1
            ) fee ON TRUE
        )
        INSERT INTO public.daily_rent_log (
            log_date, week_id, vehicle_number, partner_id, city, vehicle_model,
            attendance_status, is_billable_day, weekly_completed_trips,
            applied_daily_rent, applied_daily_indemnity, net_daily_rent,
            matched_plan_id, matched_slab_id, matched_custom_plan_id,
            calculation_rule, created_at
        )
        SELECT 
            w.log_date,
            w.week_id,
            w.vehicle_number,
            w.partner_id,
            w.city,
            w.vehicle_model,
            w.attendance_status,
            w.is_billable_day,
            w.weekly_completed_trips,
            w.applied_daily_rent,
            w.applied_daily_indemnity,
            (w.applied_daily_rent + w.applied_daily_indemnity) AS net_daily_rent,
            w.matched_plan_id,
            w.matched_slab_id,
            w.matched_custom_plan_id,
            w.calculation_rule,
            CURRENT_TIMESTAMP
        FROM waterfall w
        ON CONFLICT (log_date, vehicle_number, partner_id) DO UPDATE SET
            week_id = EXCLUDED.week_id,
            city = EXCLUDED.city,
            vehicle_model = EXCLUDED.vehicle_model,
            attendance_status = EXCLUDED.attendance_status,
            is_billable_day = EXCLUDED.is_billable_day,
            weekly_completed_trips = EXCLUDED.weekly_completed_trips,
            applied_daily_rent = EXCLUDED.applied_daily_rent,
            applied_daily_indemnity = EXCLUDED.applied_daily_indemnity,
            net_daily_rent = EXCLUDED.net_daily_rent,
            matched_plan_id = EXCLUDED.matched_plan_id,
            matched_slab_id = EXCLUDED.matched_slab_id,
            matched_custom_plan_id = EXCLUDED.matched_custom_plan_id,
            calculation_rule = EXCLUDED.calculation_rule;
    END LOOP;
END;
$procedure$;
    """)
    print("   [OK] Stored procedure sp_calculate_daily_rent updated successfully.")

    cur.close()
    conn.close()
    print("\n" + "=" * 70)
    print("MIGRATION COMPLETED SUCCESSFULLY!")
    print("=" * 70)

if __name__ == '__main__':
    run_migration()
