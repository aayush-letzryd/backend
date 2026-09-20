"""
LetzRyd Unified Rental Architecture - Test & Audit Suite
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

conn = psycopg2.connect(
    host=DB_HOST,
    port=DB_PORT,
    dbname=DB_NAME,
    user=DB_USER,
    password=DB_PASS
)
conn.autocommit = True
cur = conn.cursor(cursor_factory=RealDictCursor)

tables = [
    'core_rental_plans',
    'rental_rate_slabs',
    'rental_custom_partner_plans',
    'rental_model_baselines',
    'rental_fee_rules',
    'rental_exceptions',
    'daily_rent_log'
]

print("=" * 60)
print("RENTAL TABLES RECORD AUDIT:")
print("=" * 60)
for t in tables:
    cur.execute(f"SELECT count(*) as cnt FROM public.{t};")
    print(f"{t:<30}: {cur.fetchone()['cnt']:>8} rows")

print("\n--- core_rental_plans sample ---")
cur.execute("SELECT plan_id, plan_code, plan_name, default_daily_rent, default_daily_fee FROM public.core_rental_plans ORDER BY plan_id LIMIT 6;")
for r in cur.fetchall():
    print(dict(r))

print("\n--- Custom Operator Slabs (Hamza Moidu: LETZBLR_HAMZA) ---")
cur.execute("SELECT slab_id, plan_id, partner_id, customer_type, trip_min, trip_max, base_daily_rent FROM public.rental_rate_slabs WHERE partner_id = 'LETZBLR_HAMZA' ORDER BY trip_min;")
for r in cur.fetchall():
    print(dict(r))

print("\n--- rental_fee_rules sample ---")
cur.execute("SELECT fee_rule_id, city, partner_id, vehicle_model, fee_amount, is_waiver, reason FROM public.rental_fee_rules ORDER BY fee_rule_id LIMIT 7;")
for r in cur.fetchall():
    print(dict(r))

print("\n--- Testing sp_calculate_daily_rent on sample date ---")
cur.execute("CALL public.sp_calculate_daily_rent('2026-09-20'::date, '2026-09-20'::date);")
print("[OK] Procedure executed cleanly.")

cur.execute("""
    SELECT 
        log_date, vehicle_number, partner_id, city, vehicle_model,
        attendance_status, weekly_completed_trips,
        applied_daily_rent, applied_daily_indemnity, net_daily_rent,
        matched_plan_id, matched_slab_id, matched_custom_plan_id,
        calculation_rule
    FROM public.daily_rent_log 
    WHERE log_date = '2026-09-20'
    ORDER BY id DESC
    LIMIT 5;
""")
print("\n--- Testing Custom Operator Slab Resolution (Hamza Moidu: LETZBLR_HAMZA) ---")
for trips in [40, 60, 70, 80]:
    cur.execute("""
        SELECT s.slab_id, s.plan_id, s.base_daily_rent, s.default_daily_fee, s.partner_id, p.plan_code
        FROM public.rental_rate_slabs s
        JOIN public.core_rental_plans p ON p.plan_id = s.plan_id
        WHERE s.city = 'Bangalore'
          AND (s.partner_id = 'LETZBLR_HAMZA' OR s.partner_id = 'ALL')
          AND (s.customer_type = 'ALL' OR s.customer_type = 'Operator')
          AND s.trip_min <= %s AND (s.trip_max IS NULL OR %s <= s.trip_max)
        ORDER BY 
            CASE WHEN s.partner_id <> 'ALL' THEN 1 ELSE 2 END,
            s.trip_min DESC
        LIMIT 1;
    """, (trips, trips))
    res = cur.fetchone()
    print(f"Trips: {trips:2d} -> Plan #{res['plan_id']} ({res['plan_code']}), Slab #{res['slab_id']}, Partner: {res['partner_id']}, Rent: Rs {res['base_daily_rent']}/day")

print("\n--- daily_rent_log Output with Full Lineage ---")
for r in cur.fetchall():
    print(dict(r))

cur.close()
conn.close()
