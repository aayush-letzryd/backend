"""
LetzRyd Unified Rental Architecture - Master Seeding Pipeline
============================================================
Seeds canonical standard plans, dynamic rate slabs, model baselines,
indemnity fee rules, and confirmed partner custom agreements into PostgreSQL.

Features:
  - Clean Integer Primary Keys (plan_id: 1, 2, 3...)
  - 100% Data-Driven: All base rates, fallbacks, and fee waivers stored in tables
  - Custom Operator Slabs: Supports partner_id in rental_rate_slabs
  - Zero Row-Level Triggers: Trigger-free, set-based batch architecture

Target Tables:
  1. public.core_rental_plans
  2. public.rental_fee_rules
  3. public.rental_model_baselines
  4. public.rental_rate_slabs
  5. public.rental_custom_partner_plans
  6. public.rental_exceptions (kept empty at 0 rows for audit governance)
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

def run_seed():
    print("=" * 70)
    print("     LETZRYD MASTER RENTAL SEEDING PIPELINE")
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

    # 1. core_rental_plans
    print("1. Seeding core_rental_plans with integer primary keys...")
    plans = [
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
    print(f"   [OK] {len(plans)} plans synced.")

    # 2. rental_fee_rules
    print("2. Seeding rental_fee_rules...")
    fee_rules = [
        ('ALL', 'ALL', 'ALL', 30.00, False, 'Standard daily indemnity across all cities', '2026-01-01', '9999-12-31'),
        ('Mumbai', 'ALL', 'ALL', 0.00, True, 'Mumbai city indemnity fee waiver policy (all vehicles ₹0 fee)', '2026-01-01', '9999-12-31'),
        ('Hyderabad', 'ALL', 'Hyundai Xcent', 0.00, True, 'Hyundai Xcent retired fleet indemnity waiver', '2026-01-01', '9999-12-31'),
        ('Hyderabad', 'ALL', 'Xcent', 0.00, True, 'Hyundai Xcent / Prime T BSIV retired fleet indemnity waiver', '2026-01-01', '9999-12-31'),
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
    print(f"   [OK] {len(fee_rules)} fee rules synced.")

    # 3. rental_model_baselines
    print("3. Seeding rental_model_baselines...")
    baselines = [
        ('Bangalore', 'ALL', 1050.00, 30.00, 1050.00),
        ('Bangalore', 'WagonR', 929.00, 30.00, 1050.00),
        ('Bangalore', 'Dzire', 1100.00, 30.00, 1200.00),
        ('Bangalore', 'Aura', 1100.00, 30.00, 1200.00),
        ('Bangalore', 'Tigor EV', 1300.00, 30.00, 1300.00),
        ('Bangalore', 'Tata Nexon EV', 1500.00, 30.00, 1500.00),
        ('Bangalore', 'Toyota Etios', 1150.00, 30.00, 1200.00),
        ('Bangalore', 'EC3', 1400.00, 30.00, 1400.00),
        ('Bangalore', 'Mahindra e-Verito', 1100.00, 30.00, 1100.00),
        ('Bangalore', 'Xcent', 900.00, 0.00, 900.00),

        ('Hyderabad', 'ALL', 1050.00, 30.00, 1050.00),
        ('Hyderabad', 'WagonR', 989.00, 30.00, 1050.00),
        ('Hyderabad', 'Dzire', 1100.00, 30.00, 1200.00),
        ('Hyderabad', 'EC3', 1400.00, 30.00, 1400.00),
        ('Hyderabad', 'Hyundai Aura', 1100.00, 30.00, 1200.00),
        ('Hyderabad', 'Hyundai Xcent', 900.00, 0.00, 900.00),
        ('Hyderabad', 'Xcent', 900.00, 0.00, 900.00),
        ('Hyderabad', 'Tigor EV', 1300.00, 30.00, 1300.00),
        ('Hyderabad', 'Tata Nexon EV', 1500.00, 30.00, 1500.00),
        ('Hyderabad', 'Mahindra e-Verito', 1100.00, 30.00, 1100.00),
        ('Hyderabad', 'Toyota Etios', 1150.00, 30.00, 1200.00),

        ('Mumbai', 'ALL', 970.00, 0.00, 1050.00),
        ('Mumbai', 'WagonR', 970.00, 0.00, 1050.00),
        ('Mumbai', 'Dzire', 1100.00, 0.00, 1200.00),
        ('Mumbai', 'Aura', 1100.00, 0.00, 1200.00),
        ('Mumbai', 'Tigor EV', 1300.00, 0.00, 1300.00),
        ('Mumbai', 'Tata Nexon EV', 1500.00, 0.00, 1500.00),
        ('Mumbai', 'EC3', 1400.00, 0.00, 1400.00),
        ('Mumbai', 'Toyota Etios', 1150.00, 0.00, 1200.00),
        ('Mumbai', 'Mahindra e-Verito', 1100.00, 0.00, 1100.00),
        ('Mumbai', 'Xcent', 900.00, 0.00, 900.00)
    ]
    cur.executemany("""
        INSERT INTO public.rental_model_baselines (city, vehicle_model, default_base_rent, default_daily_indemnity, all_platform_flat_rent)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (city, vehicle_model) DO UPDATE SET
            default_base_rent = EXCLUDED.default_base_rent,
            default_daily_indemnity = EXCLUDED.default_daily_indemnity,
            all_platform_flat_rent = EXCLUDED.all_platform_flat_rent;
    """, baselines)
    print(f"   [OK] {len(baselines)} model baselines synced.")

    # 4. Custom Operator Slabs (Hamza Moidu, Subhan Khan, Sarbas, Rishan, Rishad, Ramees)
    print("4. Seeding custom operator slabs...")
    operator_slabs = [
        # Hamza Moidu (LETZBLR_HAMZA and LETZBLRIP7025077468)
        (14, 'LETZBLR_HAMZA', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 0, 54, 870.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Hamza TBS <55=870'),
        (14, 'LETZBLR_HAMZA', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 55, 64, 840.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Hamza TBS 55+=840'),
        (14, 'LETZBLR_HAMZA', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 65, 74, 790.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Hamza TBS 65+=790'),
        (14, 'LETZBLR_HAMZA', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 75, 9999, 770.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Hamza TBS 75+=770'),

        (14, 'LETZBLRIP7025077468', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 0, 54, 870.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Hamza TBS <55=870'),
        (14, 'LETZBLRIP7025077468', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 55, 64, 840.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Hamza TBS 55+=840'),
        (14, 'LETZBLRIP7025077468', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 65, 74, 790.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Hamza TBS 65+=790'),
        (14, 'LETZBLRIP7025077468', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_HAMZA', 'UBER_TRIPS', 'NONE', 75, 9999, 770.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Hamza TBS 75+=770'),

        # Subhan Khan (LETZBLRIP7026684292)
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'UBER_TRIPS', 'NONE', 0, 54, 850.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Subhan Khan TBS <55=850'),
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'UBER_TRIPS', 'NONE', 55, 64, 810.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Subhan Khan TBS 55+=810'),
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'UBER_TRIPS', 'NONE', 65, 74, 790.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Subhan Khan TBS 65+=790'),
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'UBER_TRIPS', 'NONE', 75, 9999, 770.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Subhan Khan TBS 75+=770'),
        (15, 'LETZBLRIP7026684292', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_SUBHAN', 'OLA_TRIPS', 'OLA_GE_1', 1, 9999, 1050.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Subhan Khan Ola flat 1050'),

        # Sarbas & Rishan group (LETZBLRIP7306249935, LETZBLRIP7356813050, LETZBLRIP7034607989)
        (16, 'LETZBLRIP7306249935', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 0, 89, 900.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Sarbas EBS <90=900'),
        (16, 'LETZBLRIP7306249935', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 90, 109, 600.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Sarbas EBS 90+=600'),
        (16, 'LETZBLRIP7306249935', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 110, 129, 450.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Sarbas EBS 110+=450'),
        (16, 'LETZBLRIP7306249935', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 130, 9999, 300.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Sarbas EBS 130+=300'),

        (16, 'LETZBLRIP7356813050', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 0, 89, 900.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishan EBS <90=900'),
        (16, 'LETZBLRIP7356813050', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 90, 109, 600.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishan EBS 90+=600'),
        (16, 'LETZBLRIP7356813050', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 110, 129, 450.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishan EBS 110+=450'),
        (16, 'LETZBLRIP7356813050', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 130, 9999, 300.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishan EBS 130+=300'),

        (16, 'LETZBLRIP7034607989', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 0, 89, 900.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Partner 7034607989 EBS <90=900'),
        (16, 'LETZBLRIP7034607989', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 90, 109, 600.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Partner 7034607989 EBS 90+=600'),
        (16, 'LETZBLRIP7034607989', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 110, 129, 450.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Partner 7034607989 EBS 110+=450'),
        (16, 'LETZBLRIP7034607989', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAN_SARBAS', 'UBER_TRIPS', 'NONE', 130, 9999, 300.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Partner 7034607989 EBS 130+=300'),

        # Mohamed Ramees A (LETZBLRIP8075280208)
        (19, 'LETZBLRIP8075280208', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RAMEES', 'UBER_TRIPS', 'NONE', 0, 89, 900.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Ramees EBS <90=900'),
        (19, 'LETZBLRIP8075280208', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RAMEES', 'UBER_TRIPS', 'NONE', 90, 109, 615.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Ramees EBS 90+=615'),
        (19, 'LETZBLRIP8075280208', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RAMEES', 'UBER_TRIPS', 'NONE', 110, 129, 465.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Ramees EBS 110+=465'),
        (19, 'LETZBLRIP8075280208', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RAMEES', 'UBER_TRIPS', 'NONE', 130, 9999, 320.00, 30.00, '2026-01-01', '9999-12-31', 'Operator Deal: Ramees EBS 130+=320'),

        # Rishad P V (LETZBLRIP9656907001)
        (18, 'LETZBLRIP9656907001', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAD_EBS', 'UBER_TRIPS', 'NONE', 0, 89, 800.00, 20.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishad EBS <90=800'),
        (18, 'LETZBLRIP9656907001', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAD_EBS', 'UBER_TRIPS', 'NONE', 90, 109, 550.00, 20.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishad EBS 90+=550'),
        (18, 'LETZBLRIP9656907001', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAD_EBS', 'UBER_TRIPS', 'NONE', 110, 129, 410.00, 20.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishad EBS 110+=410'),
        (18, 'LETZBLRIP9656907001', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAD_EBS', 'UBER_TRIPS', 'NONE', 130, 9999, 270.00, 20.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishad EBS 130+=270'),
        (18, 'LETZBLRIP9656907001', 'Bangalore', 'Operator', 'ALL', 'BLR_OP_RISHAD_EBS', 'OLA_TRIPS', 'OLA_GE_1', 1, 9999, 1050.00, 20.00, '2026-01-01', '9999-12-31', 'Operator Deal: Rishad Ola flat 1050')
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
    print(f"   [OK] {len(operator_slabs)} custom operator slabs synced.")

    cur.close()
    conn.close()
    print("\n" + "=" * 70)
    print("MASTER SEEDING PIPELINE COMPLETED SUCCESSFULLY!")
    print("=" * 70)

if __name__ == '__main__':
    run_seed()
