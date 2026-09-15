import psycopg2
import sys

def main():
    conn = psycopg2.connect(
        host="35.200.196.113",
        port=5432,
        dbname="postgres",
        user="postgres",
        password="8S5]U3@L^Xz)\\FH}"
    )
    cur = conn.cursor()

    print("--- 1. Schema & Column Inventory ---")
    def print_schema(table_name):
        cur.execute("""
            SELECT column_name, data_type 
            FROM information_schema.columns 
            WHERE table_schema = 'public' AND table_name = %s
        """, (table_name,))
        cols = cur.fetchall()
        print(f"Table: {table_name}")
        for c in cols:
            print(f"  {c[0]}: {c[1]}")
            
    print_schema('core_gps')
    print_schema('sheet_gps_telematics')
    print_schema('core_uber_daily')
    print_schema('core_ola_daily')
    
    print("\n--- 2. Data Volume & Temporal Coverage ---")
    cur.execute("""
        SELECT COUNT(*), MIN(record_date), MAX(record_date), COUNT(DISTINCT record_date) 
        FROM public.core_gps
    """)
    res = cur.fetchone()
    print(f"Total Rows: {res[0]}, Min Date: {res[1]}, Max Date: {res[2]}, Distinct Days: {res[3]}")
    
    weeks = [
        ('Week 26', '2026-06-22', '2026-06-28'),
        ('Week 27', '2026-06-29', '2026-07-05'),
        ('Week 36', '2026-08-31', '2026-09-06'),
        ('Week 37', '2026-09-07', '2026-09-13'),
        ('Week 38', '2026-09-14', '2026-09-20')
    ]
    for w_name, w_start, w_end in weeks:
        cur.execute("""
            SELECT COUNT(*), COUNT(DISTINCT record_date) 
            FROM public.core_gps 
            WHERE record_date >= %s AND record_date <= %s
        """, (w_start, w_end))
        res2 = cur.fetchone()
        print(f"{w_name} ({w_start} to {w_end}): {res2[0]} rows, {res2[1]} distinct days")
        
    print("\n--- 3. Vehicle Registration Matching & Normalization ---")
    cur.execute("SELECT COUNT(DISTINCT vehicle_number) FROM public.core_gps")
    print(f"Distinct vehicles in core_gps: {cur.fetchone()[0]}")
    
    cur.execute("""
        SELECT COUNT(DISTINCT g.vehicle_number) 
        FROM public.core_gps g
        JOIN public.core_vehicle_onboarding v ON g.vehicle_number = v.registration_no
    """)
    matched_cvo = cur.fetchone()[0]
    print(f"Vehicles matched in core_vehicle_onboarding: {matched_cvo}")
    
    # Let's see some unmatched vehicles
    cur.execute("""
        SELECT DISTINCT vehicle_number 
        FROM public.core_gps 
        WHERE vehicle_number NOT IN (SELECT registration_no FROM public.core_vehicle_onboarding WHERE registration_no IS NOT NULL)
        LIMIT 10
    """)
    unmatched = cur.fetchall()
    print(f"Sample unmatched vehicles: {[x[0] for x in unmatched]}")

    print("\n--- 4. Telematics Distance Distribution ---")
    cur.execute("""
        SELECT 
            MIN(distance_km), 
            MAX(distance_km), 
            AVG(distance_km),
            SUM(CASE WHEN distance_km = 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
            SUM(CASE WHEN distance_km < 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
            SUM(CASE WHEN distance_km > 600 THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
            SUM(CASE WHEN is_idle_movement_alert = TRUE THEN 1 ELSE 0 END)
        FROM public.core_gps
    """)
    d_res = cur.fetchone()
    print(f"Min: {d_res[0]}, Max: {d_res[1]}, Avg: {d_res[2]}")
    print(f"0 km %: {d_res[3]:.2f}%, Negative %: {d_res[4]:.2f}%, > 600 km %: {d_res[5]:.2f}%")
    print(f"Idle Movement Alerts: {d_res[6]}")

    cur.close()
    conn.close()

if __name__ == '__main__':
    main()
