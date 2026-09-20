"""
LetzRyd Unified Rental Architecture - Master Seeding Pipeline
============================================================
Seeds canonical standard plans, dynamic rate slabs, model baselines,
indemnity fee rules, and confirmed partner custom agreements into PostgreSQL.

Active Target Tables:
  1. public.core_rental_plans
  2. public.rental_model_baselines
  3. public.rental_fee_rules
  4. public.rental_rate_slabs
  5. public.rental_custom_partner_plans
  6. public.rental_exceptions (kept empty at 0 rows for governance)
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

conn = psycopg2.connect(
    host=DB_HOST,
    port=DB_PORT,
    dbname=DB_NAME,
    user=DB_USER,
    password=DB_PASS,
    connect_timeout=15
)
conn.autocommit = True
cur = conn.cursor()

print("1. Seeding core_rental_plans...")
plans = [
    # Hyderabad
    ('HYD_UBER_TBS', 'Hyderabad', 'Hyderabad Uber TBS', 'STANDARD', 'SLAB_TIERED', 'Standard TBS trip reducing slabs for WagonR, Dzire, EC3'),
    ('HYD_UBER_EBS', 'Hyderabad', 'Hyderabad Uber EBS', 'STANDARD', 'SLAB_TIERED', 'Standard EBS trip reducing slabs for WagonR, Dzire, EC3'),
    ('HYD_ALL_PLATFORM', 'Hyderabad', 'Hyderabad All Platform Flat', 'STANDARD', 'FLAT_RATE', 'Flat rent for multi-platform vehicles'),
    ('HYD_FALLBACK', 'Hyderabad', 'Hyderabad Model Fallback', 'STANDARD', 'MODEL_FALLBACK', 'Fallback rate by vehicle model'),

    # Mumbai
    ('MUM_UBER_REDUCING', 'Mumbai', 'Mumbai Uber Reducing Rent', 'STANDARD', 'SLAB_TIERED', 'Standard 6-tier reducing rent slabs for WagonR'),
    ('MUM_DZIRE_STD', 'Mumbai', 'Mumbai Dzire Standard', 'STANDARD', 'FLAT_RATE', 'Standard Dzire base rent ₹1,100/day'),
    ('MUM_ALL_PLATFORM', 'Mumbai', 'Mumbai All Platform Flat', 'STANDARD', 'FLAT_RATE', 'Flat rent ₹1,050/day for multi-platform vehicles'),
    ('MUM_FALLBACK', 'Mumbai', 'Mumbai Model Fallback', 'STANDARD', 'MODEL_FALLBACK', 'Fallback rate by vehicle model'),

    # Bangalore
    ('BLR_MASTER_IND', 'Bangalore', 'Bangalore Master Individual', 'STANDARD', 'PLATFORM_SPLIT', 'Individual reducing slabs; Ola trips >= 1 applies flat ₹1,050/day'),
    ('BLR_MASTER_OP', 'Bangalore', 'Bangalore Master Operator', 'STANDARD', 'PLATFORM_SPLIT', 'Operator reducing slabs; Ola only applies flat ₹1,050/day'),
    ('BLR_UBER_TBS', 'Bangalore', 'Bangalore Uber TBS', 'STANDARD', 'SLAB_TIERED', 'Bangalore Uber TBS 4-tier reducing slabs'),
    ('BLR_ALL_PLATFORM', 'Bangalore', 'Bangalore All Platform Flat', 'STANDARD', 'FLAT_RATE', 'Flat rent ₹1,050/day for multi-platform vehicles'),
    ('BLR_FALLBACK', 'Bangalore', 'Bangalore Model Fallback', 'STANDARD', 'MODEL_FALLBACK', 'Fallback rate by vehicle model')
]

cur.executemany("""
    INSERT INTO public.core_rental_plans (plan_id, city, plan_name, plan_category, calculation_type, description)
    VALUES (%s, %s, %s, %s, %s, %s)
    ON CONFLICT (plan_id) DO UPDATE SET
        plan_name = EXCLUDED.plan_name,
        plan_category = EXCLUDED.plan_category,
        calculation_type = EXCLUDED.calculation_type,
        description = EXCLUDED.description;
""", plans)

print("2. Seeding rental_model_baselines...")
baselines = [
    ('Hyderabad', 'WagonR', 989.00, 30.00, 1050.00),
    ('Hyderabad', 'Dzire', 1100.00, 30.00, 1200.00),
    ('Hyderabad', 'EC3', 1400.00, 30.00, 1400.00),
    ('Hyderabad', 'Hyundai Xcent', 900.00, 0.00, 900.00),
    ('Hyderabad', 'Tigor EV', 1300.00, 30.00, 1300.00),
    ('Hyderabad', 'Tata Nexon EV', 1500.00, 30.00, 1500.00),
    ('Hyderabad', 'Mahindra e-Verito', 1100.00, 30.00, 1100.00),
    ('Mumbai', 'WagonR', 970.00, 30.00, 1050.00),
    ('Mumbai', 'Dzire', 1100.00, 30.00, 1200.00),
    ('Mumbai', 'Aura', 1100.00, 30.00, 1200.00),
    ('Mumbai', 'Tigor EV', 1300.00, 30.00, 1300.00),
    ('Bangalore', 'WagonR', 929.00, 30.00, 1050.00),
    ('Bangalore', 'Dzire', 1100.00, 30.00, 1200.00),
    ('Bangalore', 'Aura', 1100.00, 30.00, 1200.00),
    ('Bangalore', 'Tigor EV', 1300.00, 30.00, 1300.00),
    ('Bangalore', 'Toyota Etios', 1150.00, 30.00, 1200.00)
]

cur.executemany("""
    INSERT INTO public.rental_model_baselines (city, vehicle_model, default_base_rent, default_daily_indemnity, all_platform_flat_rent)
    VALUES (%s, %s, %s, %s, %s)
    ON CONFLICT (city, vehicle_model) DO UPDATE SET
        default_base_rent = EXCLUDED.default_base_rent,
        default_daily_indemnity = EXCLUDED.default_daily_indemnity,
        all_platform_flat_rent = EXCLUDED.all_platform_flat_rent;
""", baselines)

print("3. Seeding rental_fee_rules...")
fee_rules = [
    ('ALL', 'ALL', 'ALL', 30.00, False, 'Standard daily indemnity across all cities', '2026-01-01', '9999-12-31'),
    ('Hyderabad', 'ALL', 'Hyundai Xcent', 0.00, True, 'Hyundai Xcent retired fleet indemnity waiver', '2026-01-01', '9999-12-31'),
    ('Hyderabad', 'LETZHYDIP9701685282', 'ALL', 0.00, True, 'Shaik Kareem indemnity waiver', '2026-01-01', '9999-12-31'),
    ('Hyderabad', 'LETZHYDIP9885838038', 'ALL', 0.00, True, 'Shaik Kareem indemnity waiver', '2026-01-01', '9999-12-31'),
    ('Bangalore', 'LETZBLRIP9036461336', 'ALL', 15.00, False, 'Nisamudeen K P negotiated indemnity rate ₹15/day', '2026-01-01', '9999-12-31'),
    ('Bangalore', 'LETZBLRIP9656907001', 'ALL', 20.00, False, 'Rishad P V negotiated indemnity rate ₹20/day', '2026-01-01', '9999-12-31')
]

cur.executemany("""
    INSERT INTO public.rental_fee_rules (city, partner_id, vehicle_model, fee_amount, is_waiver, reason, valid_from, valid_to)
    VALUES (%s, %s, %s, %s, %s, %s, %s::date, %s::date)
    ON CONFLICT DO NOTHING;
""", fee_rules)

print("Master seeding script ready.")
cur.close()
conn.close()
