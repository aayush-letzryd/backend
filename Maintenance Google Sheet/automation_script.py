import sys
import argparse
import urllib.request
import csv
import io
import re
from datetime import datetime
import psycopg2
from psycopg2.extras import RealDictCursor, execute_batch

DB_CONFIG = {
    "host": "35.200.196.113",
    "port": 5432,
    "dbname": "postgres",
    "user": "postgres",
    "password": r"8S5]U3@L^Xz)\FH}"
}

SHEET_EXPORT_URL = "https://docs.google.com/spreadsheets/d/1abVaYzryxv27i5nnFVWzbFtuurj6r2BrZglbhPYnPKc/export?format=csv&sheet=Unified_Maintenance_source"

def get_connection():
    return psycopg2.connect(**DB_CONFIG)

def clean_plate(raw):
    if not raw:
        return None
    s = re.sub(r'[^A-Za-z0-9]', '', str(raw).strip()).upper()
    if len(s) < 6 or len(s) > 15:
        return None
    if s in ['TOTAL', 'REGNO', 'BALANCE', 'SUBTOTAL', 'UNKNOWN']:
        return None
    return s

def clean_city(city, plate):
    if city:
        u = str(city).strip().upper()
        if u.startswith("BLR") or u.startswith("BANG") or u.startswith("BENG"):
            return "Bangalore"
        if u.startswith("HYD"):
            return "Hyderabad"
        if u.startswith("MUM"):
            return "Mumbai"
        if u.startswith("DEL"):
            return "Delhi"
    if plate:
        p = str(plate).upper()
        if p.startswith("KA"):
            return "Bangalore"
        if p.startswith("TS") or p.startswith("TG") or p.startswith("AP"):
            return "Hyderabad"
        if p.startswith("MH"):
            return "Mumbai"
        if p.startswith("DL"):
            return "Delhi"
    return "Bangalore"

def parse_date(val):
    if not val:
        return None
    s = str(val).strip()
    if not s or s == '-' or s.lower() in ['null', 'nan']:
        return None
    
    # DD/MM/YYYY or DD-MM-YYYY
    m = re.match(r'^(\d{1,2})[/\-\.](\d{1,2})[/\-\.](\d{4})', s)
    if m:
        try:
            return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
        except:
            pass

    # YYYY-MM-DD
    m = re.match(r'^(\d{4})[/\-](\d{1,2})[/\-](\d{1,2})', s)
    if m:
        try:
            return f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
        except:
            pass

    return None

def clean_str(val):
    if not val:
        return None
    s = str(val).strip().replace("'", "").replace('"', '')
    if not s or s == '-' or s.lower() in ['null', 'nan']:
        return None
    return s

def run_backfill(clean_reset=False):
    print("=" * 80)
    print("      FAST PYTHON BATCH INGESTION: Unified_Maintenance_source -> PostgreSQL")
    print("=" * 80)
    
    # 1. Fetch data from Google Sheet CSV Export
    print(f"Fetching live CSV from: {SHEET_EXPORT_URL}...")
    req = urllib.request.Request(SHEET_EXPORT_URL, headers={'User-Agent': 'Mozilla/5.0'})
    try:
        with urllib.request.urlopen(req) as resp:
            content = resp.read().decode('utf-8', errors='ignore')
    except Exception as e:
        print(f"Error downloading CSV: {e}")
        return

    reader = csv.reader(io.StringIO(content))
    rows = list(reader)
    if len(rows) <= 1:
        print("No data rows found in Google Sheet.")
        return

    headers = rows[0]
    data_rows = rows[1:]
    print(f"Downloaded {len(data_rows):,} rows with {len(headers)} columns.")

    # 2. Transform & Clean Records
    records_to_insert = []
    skipped = 0

    for idx, row in enumerate(data_rows):
        sheet_row_num = idx + 2
        raw_city = row[0] if len(row) > 0 else None
        raw_plate = row[1] if len(row) > 1 else None
        raw_date = row[2] if len(row) > 2 else None
        raw_alloc_date = row[3] if len(row) > 3 else None
        raw_drop_date = row[4] if len(row) > 4 else None
        raw_final_status = row[5] if len(row) > 5 else None
        raw_cohort = row[6] if len(row) > 6 else None
        raw_mapping = row[7] if len(row) > 7 else None
        raw_partner_name = row[8] if len(row) > 8 else None
        raw_partner_ids = row[9] if len(row) > 9 else None
        raw_new_partner = row[10] if len(row) > 10 else None
        raw_model = row[11] if len(row) > 11 else None
        raw_dm_name = row[12] if len(row) > 12 else None
        raw_type = row[13] if len(row) > 13 else None

        plate = clean_plate(raw_plate)
        status_date = parse_date(raw_date)

        if not plate or not status_date:
            skipped += 1
            continue

        city = clean_city(raw_city, plate)
        alloc_date = parse_date(raw_alloc_date)
        drop_date = parse_date(raw_drop_date)
        final_status = clean_str(raw_final_status) or "Maintenance"
        cohort = clean_str(raw_cohort) or "Off Road"
        mapping = clean_str(raw_mapping)
        partner_name = clean_str(raw_partner_name)
        
        partner_ids = clean_str(raw_partner_ids)
        if partner_ids and partner_ids.upper() == "MAINTENANCE":
            partner_ids = None

        new_partner = clean_str(raw_new_partner)
        model = clean_str(raw_model)
        dm_name = clean_str(raw_dm_name)
        type_val = clean_str(raw_type)

        records_to_insert.append((
            city, plate, status_date, alloc_date, drop_date,
            final_status, cohort, mapping, partner_name, partner_ids,
            new_partner, model, dm_name, type_val,
            sheet_row_num, 'Daily Vehicle Status', False
        ))

    print(f"Validated {len(records_to_insert):,} clean records ({skipped} skipped due to invalid plate/date).")

    # 3. High-Speed Database Upsert via psycopg2 execute_batch
    conn = get_connection()
    cur = conn.cursor()

    if clean_reset:
        print("Performing CLEAN RESET: TRUNCATE public.sheet_maintenance RESTART IDENTITY...")
        cur.execute("TRUNCATE TABLE public.sheet_maintenance RESTART IDENTITY;")
        conn.commit()

    upsert_sql = """
        INSERT INTO public.sheet_maintenance (
            city, vehicle_number, date, allocation_date, drop_off_date,
            final_status, cohort, mapping, partner_name, partner_ids,
            new_partner_name_default, vehicle_model, dm_name, type,
            sheet_row_number, source_tab, is_deleted,
            created_at, updated_at
        ) VALUES (
            %s, %s, %s, %s, %s,
            %s, %s, %s, %s, %s,
            %s, %s, %s, %s,
            %s, %s, %s,
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
        )
        ON CONFLICT (vehicle_number, date) DO UPDATE SET
            city = EXCLUDED.city,
            allocation_date = EXCLUDED.allocation_date,
            drop_off_date = EXCLUDED.drop_off_date,
            final_status = EXCLUDED.final_status,
            cohort = EXCLUDED.cohort,
            mapping = EXCLUDED.mapping,
            partner_name = EXCLUDED.partner_name,
            partner_ids = EXCLUDED.partner_ids,
            new_partner_name_default = EXCLUDED.new_partner_name_default,
            vehicle_model = EXCLUDED.vehicle_model,
            dm_name = EXCLUDED.dm_name,
            type = EXCLUDED.type,
            sheet_row_number = EXCLUDED.sheet_row_number,
            is_deleted = FALSE,
            deleted_at = NULL,
            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata');
    """

    print("Executing batch insert to PostgreSQL...")
    start_time = datetime.now()
    execute_batch(cur, upsert_sql, records_to_insert, page_size=500)
    conn.commit()
    elapsed = (datetime.now() - start_time).total_seconds()
    print(f"Successfully inserted {len(records_to_insert):,} records in {elapsed:.2f} seconds!")

    conn.close()

    # 4. Run Audit
    run_audit()

def run_audit():
    print("\n" + "=" * 80)
    print("       LETZRYD MAINTENANCE PIPELINE AUDIT REPORT (public.sheet_maintenance)")
    print("=" * 80)
    
    conn = get_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    # 1. Total Counts & Sequence Stats
    print("\n[1] Record Count & Sequence Health:")
    cur.execute("""
        SELECT 
            count(*) as total_records,
            count(*) FILTER (WHERE is_deleted = FALSE) as active_records,
            count(*) FILTER (WHERE is_deleted = TRUE) as deleted_records,
            count(DISTINCT vehicle_number) as unique_vehicles,
            min(id) as min_id,
            max(id) as max_id
        FROM public.sheet_maintenance;
    """)
    r = cur.fetchone()
    total = r['total_records']
    min_id = r['min_id']
    max_id = r['max_id']
    gaps = (max_id - min_id + 1 - total) if (total and min_id and max_id) else 0
    
    print(f"  * Total Records   : {total:,}")
    print(f"  * Active Records  : {r['active_records']:,}")
    print(f"  * Deleted Records : {r['deleted_records']:,}")
    print(f"  * Unique Vehicles : {r['unique_vehicles']:,}")
    print(f"  * ID Range        : {min_id} to {max_id}")
    print(f"  * Sequence Gaps   : {gaps}")
    
    # 2. City Breakdown
    print("\n[2] Operational Hub Distribution:")
    cur.execute("""
        SELECT city, count(*) as cnt
        FROM public.sheet_maintenance
        GROUP BY city
        ORDER BY cnt DESC;
    """)
    for row in cur.fetchall():
        print(f"  * {row['city']}: {row['cnt']:,} records")
        
    # 3. Status & Cohort Verification
    print("\n[3] Operational Status & Cohort Verification:")
    cur.execute("""
        SELECT final_status, cohort, count(*) as cnt
        FROM public.sheet_maintenance
        GROUP BY final_status, cohort
        ORDER BY cnt DESC;
    """)
    for row in cur.fetchall():
        print(f"  * Status: {row['final_status']} | Cohort: {row['cohort']} -> {row['cnt']:,} records")

    # 4. Critical Column Null Checks
    print("\n[4] Data Quality & Integrity Checks:")
    cur.execute("""
        SELECT 
            count(*) FILTER (WHERE vehicle_number IS NULL OR length(vehicle_number) < 6) as invalid_plates,
            count(*) FILTER (WHERE date IS NULL) as null_dates,
            count(*) FILTER (WHERE final_status != 'Maintenance') as non_maintenance_rows
        FROM public.sheet_maintenance;
    """)
    dq = cur.fetchone()
    print(f"  * Invalid / Malformed Plates : {dq['invalid_plates']}")
    print(f"  * NULL Status Dates          : {dq['null_dates']}")
    print(f"  * Non-Maintenance Rows       : {dq['non_maintenance_rows']}")
    
    print("\n" + "=" * 80)
    if total > 0 and gaps == 0 and dq['invalid_plates'] == 0:
        print(">> [STATUS: 100% HEALTHY] public.sheet_maintenance is fully synchronized.")
    elif total == 0:
        print(">> [STATUS: READY] Table deployed with id BIGSERIAL PK. Awaiting live Apps Script sync.")
    else:
        print(">> [ATTENTION] Review flagged anomalies above.")
    print("=" * 80)
    
    conn.close()

def deploy_schema():
    print("Deploying public.sheet_maintenance schema to PostgreSQL...")
    conn = get_connection()
    cur = conn.cursor()
    with open('repo_backend/Maintenance Google Sheet/schema.sql', 'r') as f:
        sql = f.read()
    cur.execute(sql)
    conn.commit()
    print("Schema deployed successfully.")
    conn.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="LetzRyd Maintenance Staging Automation Engine")
    parser.add_argument("--backfill", action="store_true", help="Run fast batch backfill from Google Sheet")
    parser.add_argument("--clean", action="store_true", help="Perform clean reset before backfill")
    parser.add_argument("--audit", action="store_true", help="Run live health audit")
    parser.add_argument("--deploy", action="store_true", help="Deploy schema to database")
    args = parser.parse_args()
    
    if args.backfill:
        run_backfill(clean_reset=args.clean)
    elif args.audit:
        run_audit()
    elif args.deploy:
        deploy_schema()
    else:
        run_audit()
