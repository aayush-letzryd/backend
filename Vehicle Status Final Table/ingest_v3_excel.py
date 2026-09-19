import re
import datetime
import openpyxl
import psycopg2
from psycopg2.extras import execute_values

EXCEL_PATH = r'c:\Users\anura\Downloads\Vehicle Status List_V3.xlsx'
TAB_NAME = 'Daily Vehicle Status'

DB_CONFIG = {
    'host': '35.200.196.113',
    'port': 5432,
    'dbname': 'postgres',
    'user': 'postgres',
    'password': r'8S5]U3@L^Xz)\FH}'
}

def clean_str(val):
    if val is None:
        return None
    s = str(val).strip()
    if not s:
        return None
    placeholders = {'-', '--', 'na', 'n/a', 'none', 'nil', 'null', '#n/a', 'undefined'}
    if s.lower() in placeholders:
        return None
    return s

def clean_city(val):
    s = clean_str(val)
    if not s:
        return 'UNKNOWN'
    low = s.lower()
    if low in ('blr', 'bangalore', 'bengaluru'):
        return 'Bengaluru'
    if low in ('hyd', 'hyderabad'):
        return 'Hyderabad'
    if low in ('mum', 'mumbai'):
        return 'Mumbai'
    if low in ('pun', 'pune'):
        return 'Pune'
    return s.upper()

def clean_vehicle_number(val):
    s = clean_str(val)
    if not s:
        return None
    cleaned = re.sub(r'[\s\-_]', '', s.upper())
    cleaned = re.sub(r'^([A-Z]{2})O([0-9])', r'\g<1>0\g<2>', cleaned)
    return cleaned if len(cleaned) >= 5 else None

def clean_date(val):
    if val is None:
        return None
    if isinstance(val, (datetime.datetime, datetime.date)):
        return val.strftime('%Y-%m-%d')
    if isinstance(val, (int, float)) and 20000 < val < 80000:
        d = datetime.datetime(1899, 12, 30) + datetime.timedelta(days=val)
        return d.strftime('%Y-%m-%d')
    s = str(val).strip()
    if not s or s.lower() in {'-', '--', 'na', 'n/a', 'none', 'nil', 'null'}:
        return None
    m = re.match(r'^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})', s)
    if m:
        return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
    m = re.match(r'^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})', s)
    if m:
        return f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
    try:
        parsed = datetime.datetime.fromisoformat(s)
        return parsed.strftime('%Y-%m-%d')
    except Exception:
        return None

def clean_status(val):
    s = clean_str(val)
    if not s:
        return 'RFD'
    low = s.lower()
    if low == 'active': return 'Active'
    if low == 'rfd': return 'RFD'
    if low == 'maintenance': return 'Maintenance'
    if low == 'allocation': return 'Allocation'
    if low in ('drop off', 'dropoff'): return 'Drop Off'
    if low in ('same day d&a', 'same day da'): return 'Same Day D&A'
    if low == 'new deployment': return 'New Deployment'
    return s

def clean_cohort(val, status):
    s = clean_str(val)
    if s:
        low = s.lower()
        if low == 'on road': return 'On Road'
        if low == 'off road': return 'Off Road'
        if low == 'in yard': return 'In Yard'
    if status in ('Active', 'Allocation', 'Same Day D&A'):
        return 'On Road'
    if status in ('Maintenance', 'Drop Off'):
        return 'Off Road'
    return 'In Yard'

def clean_partner_id(val):
    s = clean_str(val)
    if not s:
        return None
    low = s.lower()
    if low in ('maintenance', 'rfd', 'new deployment', 'allocation', 'drop off'):
        return None
    return re.sub(r'\s+', '', s.upper())

def main():
    print("=" * 70)
    print("  LETZRYD - MASTER VEHICLE STATUS V3 EXCEL TO POSTGRESQL INGESTION")
    print("=" * 70)

    # 1. Connect to PostgreSQL
    print("\nConnecting to PostgreSQL host 35.200.196.113...")
    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor()
    
    cur.execute("SELECT COUNT(*), MIN(status_date), MAX(status_date) FROM public.sheet_vehicle_status;")
    pre_count, min_d, max_d = cur.fetchone()
    print(f"Current rows in sheet_vehicle_status: {pre_count} (Date range: {min_d} to {max_d})")

    # 2. Read Excel File
    print(f"\nOpening Excel file: {EXCEL_PATH} ...")
    wb = openpyxl.load_workbook(EXCEL_PATH, read_only=True, data_only=True)
    sheet = wb[TAB_NAME]

    records = []
    skipped = 0
    
    print("Parsing rows from 'Daily Vehicle Status'...")
    for idx, row in enumerate(sheet.iter_rows(min_row=2, values_only=True), start=2):
        city = clean_city(row[0])
        veh = clean_vehicle_number(row[1])
        s_date = clean_date(row[2])
        alloc_date = clean_date(row[3])
        drop_date = clean_date(row[4])
        f_status = clean_status(row[5])
        cohort = clean_cohort(row[6], f_status)
        mapping = clean_str(row[7])
        p_name = clean_str(row[8])
        p_id = clean_partner_id(row[9])
        new_p_name = clean_str(row[10])
        v_model = clean_str(row[11])
        dm_name = clean_str(row[12])
        v_type = clean_str(row[13]) if len(row) > 13 else None

        if not veh or not s_date:
            skipped += 1
            continue

        records.append((
            city,
            veh,
            s_date,
            alloc_date,
            drop_date,
            f_status,
            cohort,
            mapping,
            p_name,
            p_id,
            new_p_name,
            v_model,
            dm_name,
            v_type,
            idx
        ))

    print(f"Parsed {len(records)} valid records from Excel ({skipped} skipped/blank).")

    # 3. Deduplicate in memory keeping latest row index per (status_date, vehicle_number)
    deduped = {}
    for r in records:
        key = (r[2], r[1]) # (status_date, vehicle_number)
        deduped[key] = r

    unique_records = list(deduped.values())
    print(f"Unique (status_date, vehicle_number) records to upsert: {len(unique_records)}")

    # 4. Bulk Upsert into PostgreSQL in chunks of 1000
    upsert_sql = """
        INSERT INTO public.sheet_vehicle_status (
            city, vehicle_number, status_date, allocation_date, dropoff_date,
            final_status, cohort, mapping_key, partner_name, partner_id,
            new_partner_name, vehicle_model, dm_name, vehicle_type,
            sheet_row_number, updated_at
        ) VALUES %s
        ON CONFLICT (status_date, vehicle_number)
        DO UPDATE SET
            city = EXCLUDED.city,
            allocation_date = EXCLUDED.allocation_date,
            dropoff_date = EXCLUDED.dropoff_date,
            final_status = EXCLUDED.final_status,
            cohort = EXCLUDED.cohort,
            mapping_key = EXCLUDED.mapping_key,
            partner_name = EXCLUDED.partner_name,
            partner_id = EXCLUDED.partner_id,
            new_partner_name = EXCLUDED.new_partner_name,
            vehicle_model = EXCLUDED.vehicle_model,
            dm_name = EXCLUDED.dm_name,
            vehicle_type = EXCLUDED.vehicle_type,
            sheet_row_number = EXCLUDED.sheet_row_number,
            updated_at = CURRENT_TIMESTAMP;
    """

    print("\nExecuting bulk upsert into PostgreSQL...")
    batch_size = 1000
    for i in range(0, len(unique_records), batch_size):
        chunk = unique_records[i:i + batch_size]
        # format chunk for execute_values: add CURRENT_TIMESTAMP placeholder
        val_rows = [
            (
                r[0], r[1], r[2], r[3], r[4],
                r[5], r[6], r[7], r[8], r[9],
                r[10], r[11], r[12], r[13], r[14]
            )
            for r in chunk
        ]
        template = "(%s, %s, %s::date, %s::date, %s::date, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP)"
        execute_values(cur, upsert_sql, val_rows, template=template)
        print(f"  Processed {min(i + batch_size, len(unique_records))} / {len(unique_records)} rows...")

    conn.commit()
    print("Database transaction committed successfully!")

    # 5. Verification
    cur.execute("SELECT COUNT(*), MIN(status_date), MAX(status_date) FROM public.sheet_vehicle_status;")
    post_count, post_min, post_max = cur.fetchone()
    print("\n" + "=" * 70)
    print("                        POST-INGESTION AUDIT")
    print("=" * 70)
    print(f"Total rows in sheet_vehicle_status : {post_count} (Added/Updated: {post_count - pre_count} new rows)")
    print(f"Date range                         : {post_min} to {post_max}")

    # Check Sept 11 through 19
    cur.execute("""
        SELECT 
            status_date,
            COUNT(*) as total,
            COUNT(*) FILTER (WHERE city = 'Bengaluru') as blr,
            COUNT(*) FILTER (WHERE city = 'Hyderabad') as hyd,
            COUNT(*) FILTER (WHERE city = 'Mumbai') as mum
        FROM public.sheet_vehicle_status
        WHERE status_date >= '2026-09-11'
        GROUP BY status_date
        ORDER BY status_date ASC;
    """)
    print("\nSeptember 11-19 Verification:")
    print("status_date | Total | BLR | HYD | MUM")
    print("-" * 45)
    for row in cur.fetchall():
        print(f"{row[0]} | {row[1]:5d} | {row[2]:3d} | {row[3]:3d} | {row[4]:3d}")

    # Check sheet_maintenance
    cur.execute("SELECT COUNT(*) FROM public.sheet_maintenance;")
    maint_count = cur.fetchone()[0]
    print(f"\nDownstream sheet_maintenance rows : {maint_count}")

    conn.close()
    print("\nIngestion and verification completed perfectly!")

if __name__ == '__main__':
    main()
