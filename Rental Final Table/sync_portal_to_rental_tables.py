"""
LetzRyd Backend Pipeline: Sync Portal Plans to Production Tables
==============================================================
Reads approved / active records from public.portal_rental_plans
and promotes them into the 6 canonical production tables:
  1. EXCEPTION_OVERRIDE -> public.rental_exceptions
  2. PARTNER_DEAL       -> public.rental_custom_partner_plans
  3. RATE_SLAB          -> public.rental_rate_slabs
  4. MODEL_BASELINE     -> public.rental_model_baselines
  5. FEE_WAIVER         -> public.rental_fee_rules
  6. CORE_PLAN          -> public.core_rental_plans

Ensures full audit isolation while keeping live tables synchronized.
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

def sync_portal_plans():
    print("=" * 70)
    print("  SYNCING PORTAL STAGING PLANS -> CANONICAL PRODUCTION TABLES")
    print("=" * 70)

    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )
    conn.autocommit = True
    cur = conn.cursor(cursor_factory=RealDictCursor)

    cur.execute("""
        SELECT * FROM public.portal_rental_plans 
        WHERE status IN ('Active', 'Approved')
        ORDER BY id ASC;
    """)
    records = cur.fetchall()
    print(f"Found {len(records)} active portal rental configuration(s) to process.\n")

    synced_counts = {
        'EXCEPTION_OVERRIDE': 0,
        'PARTNER_DEAL': 0,
        'RATE_SLAB': 0,
        'MODEL_BASELINE': 0,
        'FEE_WAIVER': 0,
        'CORE_PLAN': 0
    }

    for r in records:
        ctype = r['config_type']
        
        # 1. EXCEPTION_OVERRIDE -> public.rental_exceptions
        if ctype == 'EXCEPTION_OVERRIDE':
            cur.execute("""
                INSERT INTO public.rental_exceptions (
                    override_type, vehicle_number, partner_id, city, vehicle_model, override_daily_rent, override_fee,
                    reason, approved_by, valid_from, valid_to, status
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);
            """, (
                'MANAGEMENT_CONCESSION', r['vehicle_number'], r['partner_id'], r['city'], r['vehicle_model'] or 'ALL',
                r['daily_rent'], r['daily_fee'],
                r['reason_or_notes'] or 'Portal approved exception', r['approved_by'] or 'Operations Head',
                r['valid_from'], r['valid_to'], 'APPROVED'
            ))
            synced_counts['EXCEPTION_OVERRIDE'] += 1

        # 2. PARTNER_DEAL -> public.rental_custom_partner_plans
        elif ctype == 'PARTNER_DEAL':
            cur.execute("""
                INSERT INTO public.rental_custom_partner_plans (
                    partner_id, partner_name, city, vehicle_model, vehicle_number,
                    plan_id, custom_daily_rent, custom_daily_fee, plan_label,
                    evidence_source, approved_by, valid_from, valid_to, is_active
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, TRUE)
                ON CONFLICT DO NOTHING;
            """, (
                r['partner_id'], r['partner_name'], r['city'], r['vehicle_model'], r['vehicle_number'],
                r['plan_id'], r['daily_rent'], r['daily_fee'], r['plan_name'] or 'Custom Agreement',
                r['evidence_source'] or 'Portal Staged Deal', r['approved_by'] or 'Operations Head',
                r['valid_from'], r['valid_to']
            ))
            synced_counts['PARTNER_DEAL'] += 1

        # 3. RATE_SLAB -> public.rental_rate_slabs
        elif ctype == 'RATE_SLAB':
            plan_id = r['plan_id']
            if not plan_id:
                # Find default plan for city
                cur.execute("SELECT plan_id FROM public.core_rental_plans WHERE city = %s LIMIT 1;", (r['city'],))
                prow = cur.fetchone()
                plan_id = prow['plan_id'] if prow else 1

            cur.execute("""
                INSERT INTO public.rental_rate_slabs (
                    plan_id, partner_id, city, customer_type, vehicle_model, source_plan_code,
                    metric_type, condition_rule, trip_min, trip_max, base_daily_rent, default_daily_fee,
                    valid_from, valid_to, evidence_reference
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (plan_id, partner_id, customer_type, vehicle_model, condition_rule, trip_min, valid_from) 
                DO UPDATE SET
                    trip_max = EXCLUDED.trip_max,
                    base_daily_rent = EXCLUDED.base_daily_rent,
                    default_daily_fee = EXCLUDED.default_daily_fee;
            """, (
                plan_id, r['partner_id'] or 'ALL', r['city'], r['customer_type'] or 'ALL',
                r['vehicle_model'] or 'ALL', r['plan_code'] or 'PORTAL_SLAB',
                r['metric_type'] or 'UBER_TRIPS', r['condition_rule'] or 'NONE',
                r['trip_min'] or 0, r['trip_max'], r['daily_rent'], r['daily_fee'],
                r['valid_from'], r['valid_to'], r['reason_or_notes'] or 'Portal Sync'
            ))
            synced_counts['RATE_SLAB'] += 1

        # 4. MODEL_BASELINE -> public.rental_model_baselines
        elif ctype == 'MODEL_BASELINE':
            cur.execute("""
                INSERT INTO public.rental_model_baselines (
                    city, vehicle_model, default_base_rent, default_daily_indemnity, all_platform_flat_rent, is_active
                ) VALUES (%s, %s, %s, %s, %s, TRUE)
                ON CONFLICT (city, vehicle_model) DO UPDATE SET
                    default_base_rent = EXCLUDED.default_base_rent,
                    default_daily_indemnity = EXCLUDED.default_daily_indemnity,
                    all_platform_flat_rent = EXCLUDED.all_platform_flat_rent;
            """, (
                r['city'], r['vehicle_model'], r['daily_rent'], r['daily_fee'],
                r['all_platform_flat_rent'] or 1050.00
            ))
            synced_counts['MODEL_BASELINE'] += 1

        # 5. FEE_WAIVER -> public.rental_fee_rules
        elif ctype == 'FEE_WAIVER':
            cur.execute("""
                INSERT INTO public.rental_fee_rules (
                    city, partner_id, vehicle_model, fee_amount, is_waiver, reason, valid_from, valid_to
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT DO NOTHING;
            """, (
                r['city'] or 'ALL', r['partner_id'] or 'ALL', r['vehicle_model'] or 'ALL',
                r['daily_fee'], r['is_fee_waiver'], r['reason_or_notes'] or 'Portal Policy Waiver',
                r['valid_from'], r['valid_to']
            ))
            synced_counts['FEE_WAIVER'] += 1

        # 6. CORE_PLAN -> public.core_rental_plans
        elif ctype == 'CORE_PLAN':
            p_code = r['plan_code'] or f"{r['city'].upper()}_PLAN_{r['id']}"
            cur.execute("""
                INSERT INTO public.core_rental_plans (
                    plan_code, city, plan_name, plan_category, calculation_type,
                    default_daily_rent, default_daily_fee, description, is_active
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, TRUE)
                ON CONFLICT (plan_code) DO UPDATE SET
                    plan_name = EXCLUDED.plan_name,
                    default_daily_rent = EXCLUDED.default_daily_rent,
                    default_daily_fee = EXCLUDED.default_daily_fee;
            """, (
                p_code, r['city'], r['plan_name'] or p_code, r['plan_category'] or 'STANDARD',
                r['calculation_type'] or 'SLAB_TIERED', r['daily_rent'], r['daily_fee'],
                r['reason_or_notes'] or 'Master Plan from Portal'
            ))
            synced_counts['CORE_PLAN'] += 1

    cur.close()
    conn.close()

    print("[SYNC SUMMARY]")
    for k, v in synced_counts.items():
        print(f"  • {k:<20}: {v} row(s) promoted")
    print("\nPromotion complete. Staging data safely synchronized to production tables.")

if __name__ == '__main__':
    sync_portal_plans()
