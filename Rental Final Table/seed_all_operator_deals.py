"""
Seed All Operator Tiered Deals & Validate Slabs
===============================================
Seeds all custom operator tiered plans from the canonical LetzRyd sheet:
  1. Subhan Khan M N (TBS)
  2. Rishan R / Muhammed Sarbas A T (EBS)
  3. Rishad P V (TBS & EBS)
  4. Mohamed Ramees A (EBS)
  5. Hamza Moidu (TBS)
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

def seed_all_operator_deals():
    print("=" * 70)
    print("   SEEDING COMPLETE OPERATOR CUSTOM SLABS & CONTRACTS")
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

    # 1. Insert plans into core_rental_plans
    plans = [
        (14, 'BLR_OP_HAMZA', 'Bangalore', 'Hamza Moidu Custom TBS Slabs', 'CUSTOM', 'SLAB_TIERED', 870.00, 30.00, 'Hamza Moidu (<55=870, 55+=840, 65+=790, 75+=770)'),
        (15, 'BLR_OP_SUBHAN', 'Bangalore', 'Subhan Khan M N Custom TBS Slabs', 'CUSTOM', 'SLAB_TIERED', 850.00, 30.00, 'Subhan Khan M N (<55=850, 55+=810, 65+=790, 75+=770)'),
        (16, 'BLR_OP_RISHAN_SARBAS', 'Bangalore', 'Rishan R & Sarbas Custom EBS Slabs', 'CUSTOM', 'SLAB_TIERED', 900.00, 30.00, 'Rishan R & Sarbas (<90=900, 90+=600, 110+=450, 130+=300)'),
        (17, 'BLR_OP_RISHAD_TBS', 'Bangalore', 'Rishad P V Custom TBS Slabs', 'CUSTOM', 'SLAB_TIERED', 800.00, 20.00, 'Rishad P V TBS (<55=800, 55+=760, 65+=740, 75+=720)'),
        (18, 'BLR_OP_RISHAD_EBS', 'Bangalore', 'Rishad P V Custom EBS Slabs', 'CUSTOM', 'SLAB_TIERED', 800.00, 20.00, 'Rishad P V EBS (<90=800, 90+=550, 110+=410, 130+=270)'),
        (19, 'BLR_OP_RAMEES', 'Bangalore', 'Mohamed Ramees A Custom EBS Slabs', 'CUSTOM', 'SLAB_TIERED', 900.00, 30.00, 'Mohamed Ramees A (<90=900, 90+=615, 110+=465, 130+=320)')
    ]

    cur.executemany("""
        INSERT INTO public.core_rental_plans 
        (plan_id, plan_code, city, plan_name, plan_category, calculation_type, default_daily_rent, default_daily_fee, description)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (plan_id) DO UPDATE SET
            plan_code = EXCLUDED.plan_code,
            city = EXCLUDED.city,
            plan_name = EXCLUDED.plan_name,
            plan_category = EXCLUDED.plan_category,
            calculation_type = EXCLUDED.calculation_type,
            default_daily_rent = EXCLUDED.default_daily_rent,
            default_daily_fee = EXCLUDED.default_daily_fee,
            description = EXCLUDED.description;
    """, plans)
    cur.execute("SELECT setval('public.core_rental_plans_plan_id_seq', (SELECT MAX(plan_id) FROM public.core_rental_plans));")
    print("   [OK] Core rental plans seeded (Plans #14 to #19).")

    # 2. Insert all custom operator slabs into rental_rate_slabs
    # Format: (plan_id, partner_id, city, customer_type, vehicle_model, source_plan_code, metric_type, condition_rule, trip_min, trip_max, base_daily_rent, default_daily_fee, valid_from, valid_to, evidence_reference)
    operator_slabs = [
        # Subhan Khan M N (LETZBLRIP7026684292)
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'UBER_TRIPS', 'NONE', 0, 54, 850.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Subhan Khan TBS <55=850'),
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'UBER_TRIPS', 'NONE', 55, 64, 810.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Subhan Khan TBS 55+=810'),
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'UBER_TRIPS', 'NONE', 65, 74, 790.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Subhan Khan TBS 65+=790'),
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'UBER_TRIPS', 'NONE', 75, 9999, 770.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Subhan Khan TBS 75+=770'),

        # Rishan R (LETZBLRIP7356813050)
        (16, 'LETZBLRIP7356813050', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 0, 89, 900.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Rishan R EBS <90=900'),
        (16, 'LETZBLRIP7356813050', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 90, 109, 600.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Rishan R EBS 90+=600'),
        (16, 'LETZBLRIP7356813050', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 110, 129, 450.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Rishan R EBS 110+=450'),
        (16, 'LETZBLRIP7356813050', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 130, 9999, 300.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Rishan R EBS 130+=300'),

        # Muhammed Sarbas A T (LETZBLRIP7306249935)
        (16, 'LETZBLRIP7306249935', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 0, 89, 900.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Sarbas EBS <90=900'),
        (16, 'LETZBLRIP7306249935', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 90, 109, 600.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Sarbas EBS 90+=600'),
        (16, 'LETZBLRIP7306249935', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 110, 129, 450.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Sarbas EBS 110+=450'),
        (16, 'LETZBLRIP7306249935', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 130, 9999, 300.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Sarbas EBS 130+=300'),

        # Mohamed Ramees A (LETZBLRIP8075280208)
        (19, 'LETZBLRIP8075280208', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RAMEES', 'UBER_TRIPS', 'NONE', 0, 89, 900.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Ramees EBS <90=900'),
        (19, 'LETZBLRIP8075280208', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RAMEES', 'UBER_TRIPS', 'NONE', 90, 109, 615.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Ramees EBS 90+=615'),
        (19, 'LETZBLRIP8075280208', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RAMEES', 'UBER_TRIPS', 'NONE', 110, 129, 465.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Ramees EBS 110+=465'),
        (19, 'LETZBLRIP8075280208', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RAMEES', 'UBER_TRIPS', 'NONE', 130, 9999, 320.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Ramees EBS 130+=320'),

        # Hamza Moidu (LETZBLRIP7025077468)
        (14, 'LETZBLRIP7025077468', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 0, 54, 870.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Hamza TBS <55=870'),
        (14, 'LETZBLRIP7025077468', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 55, 64, 840.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Hamza TBS 55+=840'),
        (14, 'LETZBLRIP7025077468', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 65, 74, 790.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Hamza TBS 65+=790'),
        (14, 'LETZBLRIP7025077468', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 75, 9999, 770.00, 30.00, '2026-01-01', '9999-12-31', 'BLR Slabs: Hamza TBS 75+=770')
    ]

    cur.executemany("""
        INSERT INTO public.rental_rate_slabs (
            plan_id, partner_id, city, customer_type, vehicle_model, source_plan_code,
            metric_type, condition_rule, trip_min, trip_max, base_daily_rent, default_daily_fee,
            valid_from, valid_to, evidence_reference
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::date, %s::date, %s)
        ON CONFLICT (plan_id, partner_id, customer_type, vehicle_model, condition_rule, trip_min, valid_from) DO UPDATE SET
            trip_max = EXCLUDED.trip_max,
            base_daily_rent = EXCLUDED.base_daily_rent,
            default_daily_fee = EXCLUDED.default_daily_fee;
    """, operator_slabs)
    print(f"   [OK] Seeded {len(operator_slabs)} custom operator slab tiers.")

    cur.close()
    conn.close()
    print("=" * 70)

if __name__ == '__main__':
    seed_all_operator_deals()
