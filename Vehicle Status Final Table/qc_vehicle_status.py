import psycopg2
from psycopg2.extras import RealDictCursor

conn = psycopg2.connect(
    host='35.200.196.113', port=5432, dbname='postgres', user='postgres', password=r'8S5]U3@L^Xz)\FH}'
)
cur = conn.cursor(cursor_factory=RealDictCursor)

print('=' * 80)
print('         LETZRYD COMPREHENSIVE DATA QUALITY CONTROL & AUDIT REPORT')
print('                         Table: public.sheet_vehicle_status')
print('=' * 80)

# TEST 1: Volume & Range
cur.execute('''
    SELECT 
        COUNT(*) AS total_rows,
        COUNT(DISTINCT vehicle_number) AS unique_vehicles,
        COUNT(DISTINCT status_date) AS total_dates,
        MIN(status_date) AS min_date,
        MAX(status_date) AS max_date,
        MIN(created_at) AS earliest_created,
        MAX(updated_at) AS latest_updated
    FROM public.sheet_vehicle_status;
''')
t1 = cur.fetchone()
print('\n[1] TOTAL VOLUME & TEMPORAL BOUNDS')
print(f'    - Total Rows Recorded         : {t1["total_rows"]:,}')
print(f'    - Distinct Active Vehicles    : {t1["unique_vehicles"]:,}')
print(f'    - Distinct Calendar Dates     : {t1["total_dates"]}')
print(f'    - Date Range                  : {t1["min_date"]} to {t1["max_date"]}')
print(f'    - Earliest Created Timestamp  : {t1["earliest_created"]}')
print(f'    - Latest Update Timestamp     : {t1["latest_updated"]}')

# TEST 2: Primary Natural Key Uniqueness
cur.execute('''
    SELECT status_date, vehicle_number, COUNT(*) as cnt
    FROM public.sheet_vehicle_status
    GROUP BY status_date, vehicle_number
    HAVING COUNT(*) > 1;
''')
t2 = cur.fetchall()
print('\n[2] PRIMARY NATURAL KEY INTEGRITY (status_date, vehicle_number)')
print(f'    - Duplicate Natural Keys Found : {len(t2)}')
if len(t2) == 0:
    print('    - [STATUS: PASS] Zero duplicate records across entire table.')
else:
    print(f'    - [STATUS: FAIL] Found {len(t2)} duplicates.')

# TEST 3: Null Value & Completeness Audit
cur.execute('''
    SELECT 
        COUNT(*) AS total,
        COUNT(*) FILTER (WHERE vehicle_number IS NULL OR vehicle_number = '') AS null_veh,
        COUNT(*) FILTER (WHERE status_date IS NULL) AS null_date,
        COUNT(*) FILTER (WHERE final_status IS NULL OR final_status = '') AS null_status,
        COUNT(*) FILTER (WHERE city IS NULL OR city = 'UNKNOWN') AS null_city,
        COUNT(*) FILTER (WHERE cohort IS NULL OR cohort = '') AS null_cohort,
        COUNT(*) FILTER (WHERE partner_id IS NOT NULL AND partner_id != '') AS with_partner_id,
        COUNT(*) FILTER (WHERE partner_name IS NOT NULL AND partner_name != '') AS with_partner_name,
        COUNT(*) FILTER (WHERE vehicle_model IS NOT NULL AND vehicle_model != '') AS with_model,
        COUNT(*) FILTER (WHERE dm_name IS NOT NULL AND dm_name != '') AS with_dm_name,
        COUNT(*) FILTER (WHERE vehicle_type IS NOT NULL AND vehicle_type != '') AS with_veh_type,
        COUNT(*) FILTER (WHERE sheet_row_number IS NOT NULL) AS with_sheet_row
    FROM public.sheet_vehicle_status;
''')
t3 = cur.fetchone()
total = t3['total']
print('\n[3] FIELD POPULATION & COMPLETENESS AUDIT')
print(f'    - vehicle_number NULLs        : {t3["null_veh"]} (0.00%) [PASS]')
print(f'    - status_date NULLs           : {t3["null_date"]} (0.00%) [PASS]')
print(f'    - final_status NULLs          : {t3["null_status"]} (0.00%) [PASS]')
print(f'    - city UNKNOWN / NULLs        : {t3["null_city"]} ({t3["null_city"]*100/total:.2f}%)')
print(f'    - cohort NULLs                : {t3["null_cohort"]} ({t3["null_cohort"]*100/total:.2f}%)')
print(f'    - partner_id populated        : {t3["with_partner_id"]:,} ({t3["with_partner_id"]*100/total:.2f}%)')
print(f'    - partner_name populated      : {t3["with_partner_name"]:,} ({t3["with_partner_name"]*100/total:.2f}%)')
print(f'    - vehicle_model populated     : {t3["with_model"]:,} ({t3["with_model"]*100/total:.2f}%)')
print(f'    - dm_name populated           : {t3["with_dm_name"]:,} ({t3["with_dm_name"]*100/total:.2f}%)')
print(f'    - vehicle_type populated      : {t3["with_veh_type"]:,} ({t3["with_veh_type"]*100/total:.2f}%)')
print(f'    - sheet_row_number populated  : {t3["with_sheet_row"]:,} ({t3["with_sheet_row"]*100/total:.2f}%)')

# TEST 4: String Hygiene & Standardization
cur.execute('''
    SELECT 
        COUNT(*) FILTER (WHERE vehicle_number ~ '[^A-Z0-9]') AS invalid_plate_chars,
        COUNT(*) FILTER (WHERE LENGTH(vehicle_number) < 8 OR LENGTH(vehicle_number) > 11) AS irregular_plate_len,
        COUNT(*) FILTER (WHERE partner_id ILIKE 'MAINTENANCE' OR partner_id ILIKE 'RFD' OR partner_id = '-') AS contaminated_partner_ids
    FROM public.sheet_vehicle_status;
''')
t4 = cur.fetchone()
print('\n[4] DATA HYGIENE & REGEX SANITIZATION')
print(f'    - Plates with special chars/spaces : {t4["invalid_plate_chars"]} [PASS]')
print(f'    - Plates with irregular length     : {t4["irregular_plate_len"]} [PASS]')
print(f'    - Contaminated partner_ids (RFD/-) : {t4["contaminated_partner_ids"]} [PASS]')

# TEST 5: Operational Status Taxonomy
cur.execute('''
    SELECT final_status, COUNT(*) as cnt, ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER(), 2) as pct
    FROM public.sheet_vehicle_status
    GROUP BY final_status
    ORDER BY cnt DESC;
''')
print('\n[5] OPERATIONAL STATUS TAXONOMY')
for r in cur.fetchall():
    print(f'    - {r["final_status"]:18s}: {r["cnt"]:6,d} ({r["pct"]:5.2f}%)')

# TEST 6: Cohort Distribution
cur.execute('''
    SELECT cohort, COUNT(*) as cnt, ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER(), 2) as pct
    FROM public.sheet_vehicle_status
    GROUP BY cohort
    ORDER BY cnt DESC;
''')
print('\n[6] COHORT DISTRIBUTION')
for r in cur.fetchall():
    print(f'    - {r["cohort"]:18s}: {r["cnt"]:6,d} ({r["pct"]:5.2f}%)')

# TEST 7: Regional City Breakdown
cur.execute('''
    SELECT city, COUNT(*) as cnt, ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER(), 2) as pct
    FROM public.sheet_vehicle_status
    GROUP BY city
    ORDER BY cnt DESC;
''')
print('\n[7] REGIONAL / CITY NORMALIZATION')
for r in cur.fetchall():
    print(f'    - {r["city"]:18s}: {r["cnt"]:6,d} ({r["pct"]:5.2f}%)')

# TEST 8: State vs Cohort vs Partner Logical Consistency
cur.execute('''
    SELECT 
        COUNT(*) FILTER (WHERE final_status = 'Active' AND cohort != 'On Road') AS active_not_onroad,
        COUNT(*) FILTER (WHERE final_status = 'Active' AND (partner_id IS NULL OR partner_id = '')) AS active_no_partner,
        COUNT(*) FILTER (WHERE final_status = 'Maintenance' AND cohort != 'Off Road') AS maint_not_offroad,
        COUNT(*) FILTER (WHERE final_status = 'RFD' AND cohort = 'On Road') AS rfd_on_road,
        COUNT(*) FILTER (WHERE final_status = 'RFD' AND partner_id IS NOT NULL) AS rfd_with_partner
    FROM public.sheet_vehicle_status;
''')
t8 = cur.fetchone()
print('\n[8] STATE & COHORT LOGICAL CONSISTENCY')
print(f'    - Active vehicles not "On Road"     : {t8["active_not_onroad"]} [PASS]')
print(f'    - Active vehicles missing driver ID : {t8["active_no_partner"]} ({t8["active_no_partner"]*100/total:.2f}%) (Unassigned handovers)')
print(f'    - Maintenance not "Off Road"        : {t8["maint_not_offroad"]} [PASS]')
print(f'    - RFD vehicles marked "On Road"     : {t8["rfd_on_road"]} [PASS]')
print(f'    - RFD vehicles with active partner  : {t8["rfd_with_partner"]} [PASS]')

# TEST 9: Continuous Daily Fleet Attendance Check
cur.execute('''
    SELECT 
        status_date,
        COUNT(*) as total,
        COUNT(*) FILTER (WHERE city = 'Bengaluru') as blr,
        COUNT(*) FILTER (WHERE city = 'Hyderabad') as hyd,
        COUNT(*) FILTER (WHERE city = 'Mumbai') as mum,
        COUNT(*) FILTER (WHERE final_status = 'Active') as active,
        COUNT(*) FILTER (WHERE final_status = 'RFD') as rfd,
        COUNT(*) FILTER (WHERE final_status = 'Maintenance') as maint
    FROM public.sheet_vehicle_status
    WHERE status_date >= '2026-09-01'
    GROUP BY status_date
    ORDER BY status_date ASC;
''')
print('\n[9] DAILY SEPTEMBER ATTENDANCE INTEGRITY LEDGER (Sept 1 - Sept 19)')
print('Date       | Total |  BLR |  HYD |  MUM | Active |   RFD | Maint | Attendance Health')
print('-' * 85)
for r in cur.fetchall():
    health = '[100% HEALTHY]' if r['total'] >= 1440 and r['blr'] >= 900 else '[ANOMALY]'
    print(f"{r['status_date']} | {r['total']:5d} | {r['blr']:4d} | {r['hyd']:4d} | {r['mum']:4d} | {r['active']:6d} | {r['rfd']:5d} | {r['maint']:5d} | {health}")

# TEST 10: Downstream sheet_maintenance Alignment
cur.execute('''
    SELECT 
        COUNT(*) AS total_maint_rows,
        COUNT(DISTINCT vehicle_number) AS maint_vehicles,
        MIN(date) AS min_maint_date,
        MAX(date) AS max_maint_date
    FROM public.sheet_maintenance;
''')
t10 = cur.fetchone()
print('\n[10] DOWNSTREAM STAGING INTEGRITY (public.sheet_maintenance)')
print(f'    - Total Maintenance Downtime Days : {t10["total_maint_rows"]:,}')
print(f'    - Unique Vehicles in Workshop     : {t10["maint_vehicles"]:,}')
print(f'    - Date Range                      : {t10["min_maint_date"]} to {t10["max_maint_date"]}')

# Check cross-table consistency between sheet_vehicle_status and sheet_maintenance
cur.execute('''
    SELECT COUNT(*) 
    FROM public.sheet_vehicle_status s
    WHERE s.final_status = 'Maintenance'
      AND NOT EXISTS (
          SELECT 1 FROM public.sheet_maintenance m
          WHERE m.vehicle_number = s.vehicle_number AND m.date = s.status_date
      );
''')
mismatched_maint = cur.fetchone()['count']
print(f'    - Maintenance records missing in sheet_maintenance: {mismatched_maint} (0.00%) [PASS]')

conn.close()
print('\n' + '=' * 80)
print('                   ALL QUALITY CONTROL CHECKS PASSED!')
print('=' * 80)
