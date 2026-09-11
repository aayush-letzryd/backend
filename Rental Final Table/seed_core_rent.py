"""
LetzRyd - Rental Final Table Master Seeding Script
===================================================
Seeds `public.core_rent` and `public.core_rent_logs` with active fleet agreements
across Bangalore, Mumbai, and Hyderabad.

Key Operational Rules Applied:
1. Slabs are strictly for Uber performance reducing rent plans.
2. Custom operator deals and All Platform drivers use `custom_daily_rent`.
3. City-specific indemnity rules:
   - Bangalore: Standard 30.00, Nisamudeen (LETZBLRIP9036461336) = 15.00, Rishad (LETZBLRIP9656907001) = 20.00
   - Hyderabad: Standard 30.00, Hyundai Xcent = 0.00, Shaik Kareem (LETZHYDIP9701685282) = 0.00
   - Mumbai: Standard 30.00 (Insurance amount added to daily active days)
"""

import os
import sys
import psycopg2
from psycopg2.extras import RealDictCursor, Json
from datetime import date

# Force UTF-8 stdout
sys.stdout.reconfigure(encoding='utf-8')

DB_HOST = os.getenv("DB_HOST", "35.200.196.113")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASS = os.getenv("DB_PASSWORD", r"8S5]U3@L^Xz)\FH}")

def get_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )

def seed_core_rent():
    conn = get_connection()
    conn.autocommit = False
    cur = conn.cursor(cursor_factory=RealDictCursor)

    print("=================================================================")
    print("         SEEDING PUBLIC.CORE_RENT & PUBLIC.CORE_RENT_LOGS       ")
    print("=================================================================\n")

    print("1. Reading partner registry from sheet_rental_partners...")
    cur.execute("""
        SELECT vendor_code, vendor_name, city, plan_type_hisaab, custom_daily_rent, custom_daily_indemnity 
        FROM sheet_rental_partners;
    """)
    partner_map = {p['vendor_code']: p for p in cur.fetchall()}
    print(f"   Loaded {len(partner_map)} registered partners.\n")

    print("2. Reading latest vehicle allocations from sheet_vehicle_allocations...")
    cur.execute("""
        SELECT DISTINCT ON (vehicle_number)
            vehicle_number, operator_driver_id AS partner_id, city, car_model AS vehicle_model,
            driver_plan, type_of_plan, partner_type, allocation_date
        FROM sheet_vehicle_allocations
        WHERE vehicle_number IS NOT NULL AND vehicle_number != ''
        ORDER BY vehicle_number, submission_timestamp DESC NULLS LAST;
    """)
    allocations = cur.fetchall()
    print(f"   Found {len(allocations)} allocated vehicles in database.\n")

    seeded_count = 0
    updated_count = 0

    for alloc in allocations:
        veh_num = alloc['vehicle_number'].strip()
        partner_id = alloc['partner_id'].strip() if alloc['partner_id'] else f"PARTNER_{veh_num}"
        city = alloc['city'].strip() if alloc['city'] else "Bengaluru"
        model = alloc['vehicle_model'].strip() if alloc['vehicle_model'] else "Maruti Wagonr Tour H3 CNG"
        eff_from = alloc['allocation_date'] if alloc['allocation_date'] else date(2026, 1, 1)

        # Plan scheme & custom daily rent resolution
        custom_rent = None
        plan_scheme = 'Uber Reducing Rent'

        # Check partner agreement registry
        if partner_id in partner_map:
            p_info = partner_map[partner_id]
            if p_info['custom_daily_rent'] is not None:
                custom_rent = float(p_info['custom_daily_rent'])
                plan_scheme = 'All Platform Flat' if p_info['plan_type_hisaab'] == 'All Platform' else 'Operator Custom Flat'

        # Check driver allocation tags
        driver_plan = (alloc['driver_plan'] or '').upper()
        type_of_plan = (alloc['type_of_plan'] or '').upper()
        if 'ALL PLATFORM' in driver_plan or 'ALL PLATFORM' in type_of_plan:
            custom_rent = 1050.00
            plan_scheme = 'All Platform Flat'
        elif 'TBS' in driver_plan or 'TBS' in type_of_plan:
            plan_scheme = 'Uber TBS'

        # Indemnity determination
        city_lower = city.lower()
        if 'bengaluru' in city_lower or 'bangalore' in city_lower:
            if partner_id == "LETZBLRIP9036461336":
                indemnity = 15.00 # Nisamudeen K P negotiated rate
            elif partner_id == "LETZBLRIP9656907001":
                indemnity = 20.00 # Rishad P V negotiated rate
            else:
                indemnity = 30.00 # Standard BLR rate
        elif 'hyderabad' in city_lower:
            if 'xcent' in model.lower() or partner_id == "LETZHYDIP9701685282":
                indemnity = 0.00  # Retired Xcents & Shaik Kareem: 0 indemnity
            else:
                indemnity = 30.00 # Standard HYD rate
        elif 'mumbai' in city_lower:
            indemnity = 30.00     # Mumbai Insurance amount
        else:
            indemnity = 30.00

        # Upsert into core_rent
        cur.execute("""
            INSERT INTO core_rent (
                vehicle_number, partner_id, city, vehicle_model, plan_scheme,
                custom_daily_rent, custom_daily_indemnity, enable_age_discount,
                enable_volume_discount, effective_from, effective_to, is_active
            ) VALUES (
                %s, %s, %s, %s, %s, %s, %s, FALSE, FALSE, %s, '9999-12-31', TRUE
            )
            ON CONFLICT (vehicle_number, effective_from) DO UPDATE SET
                partner_id = EXCLUDED.partner_id,
                city = EXCLUDED.city,
                vehicle_model = EXCLUDED.vehicle_model,
                plan_scheme = EXCLUDED.plan_scheme,
                custom_daily_rent = EXCLUDED.custom_daily_rent,
                custom_daily_indemnity = EXCLUDED.custom_daily_indemnity,
                updated_at = CURRENT_TIMESTAMP
            RETURNING id, (xmax = 0) AS is_inserted;
        """, (
            veh_num, partner_id, city, model, plan_scheme,
            custom_rent, indemnity, eff_from
        ))
        res = cur.fetchone()
        core_rent_id = res['id']
        is_inserted = res['is_inserted']

        if is_inserted:
            seeded_count += 1
            action = 'INITIAL_SEED'
        else:
            updated_count += 1
            action = 'UPDATED'

        # Write audit log
        cur.execute("""
            INSERT INTO core_rent_logs (
                core_rent_id, vehicle_number, partner_id, action,
                new_values, reason, changed_by
            ) VALUES (
                %s, %s, %s, %s, %s, %s, 'system_seeder'
            );
        """, (
            core_rent_id, veh_num, partner_id, action,
            Json({
                'city': city,
                'model': model,
                'plan_scheme': plan_scheme,
                'custom_daily_rent': custom_rent,
                'custom_daily_indemnity': indemnity
            }),
            'Master fleet agreement initialization'
        ))

    conn.commit()
    conn.close()

    print("=================================================================")
    print("SEEDED PUBLIC.CORE_RENT SUCCESSFULLY:")
    print(f"  - Newly Seeded Agreements: {seeded_count}")
    print(f"  - Updated Agreements:      {updated_count}")
    print(f"  - Total Active Vehicles:   {seeded_count + updated_count}")
    print("=================================================================\n")

if __name__ == "__main__":
    seed_core_rent()
