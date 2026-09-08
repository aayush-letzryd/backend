"""
LetzRyd - Walk-in Final Table Automation & Reconciliation Engine
================================================================
Synchronizes and audits public.core_walkin as the Single Source of Truth
combining public.sheet_walkins, public.july_new_walkins, and public.july_existing_walkins.

Usage:
    python automation_script.py --audit
    python automation_script.py --backfill
"""

import os
import re
import argparse
import psycopg2
from psycopg2.extras import RealDictCursor

DB_HOST = os.getenv('DB_HOST', 'YOUR_DB_HOST_HERE')
DB_PORT = int(os.getenv('DB_PORT', '5432'))
DB_NAME = os.getenv('DB_NAME', 'postgres')
DB_USER = os.getenv('DB_USER', 'postgres')
DB_PASSWORD = os.getenv('DB_PASSWORD', 'YOUR_DB_PASSWORD_HERE')

def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )

def clean_phone(p):
    if not p:
        return ''
    s = re.sub(r'\D', '', str(p))
    return s[-10:] if len(s) >= 10 else s

def clean_city(c):
    if not c:
        return 'Unknown'
    c_str = str(c).strip()
    if c_str.lower() in ['bangalore', 'bengaluru', 'blr']:
        return 'Bengaluru'
    if c_str.lower() in ['hyderabad', 'hyd']:
        return 'Hyderabad'
    if c_str.lower() in ['mumbai', 'mum']:
        return 'Mumbai'
    return c_str.title()

def categorize_reason(r):
    if not r:
        return 'OTHER'
    r_lower = str(r).lower()
    if any(k in r_lower for k in ['new joining', 'onboarding', 're-joining', 'adding new vehicle']):
        return 'ONBOARDING'
    if any(k in r_lower for k in ['enquiry', 'inquiry']):
        return 'ENQUIRY'
    if any(k in r_lower for k in ['hisaab', 'payout', 'earnings']):
        return 'PAYOUT_HISAAB'
    if any(k in r_lower for k in ['maintenance', 'tyre', 'swap', 'drop off']):
        return 'VEHICLE_MAINTENANCE'
    if any(k in r_lower for k in ['meet', 'manager', 'dm']):
        return 'MEETING_COMPLAINT'
    return 'OTHER'

def audit_health():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    print("=== Core Walkin Health & Reconciliation Audit ===")

    cur.execute("SELECT count(*) FROM public.sheet_walkins;")
    sheet_count = cur.fetchone()['count']

    cur.execute("SELECT count(*) FROM public.july_new_walkins;")
    portal_new_count = cur.fetchone()['count']

    cur.execute("SELECT count(*) FROM public.july_existing_walkins;")
    portal_ex_count = cur.fetchone()['count']

    cur.execute("SELECT count(*) FROM public.core_walkin;")
    core_count = cur.fetchone()['count']

    print(f"Source: sheet_walkins         : {sheet_count} rows")
    print(f"Source: july_new_walkins      : {portal_new_count} rows")
    print(f"Source: july_existing_walkins : {portal_ex_count} rows")
    print(f"Target: core_walkin           : {core_count} rows")
    print(f"Reconciliation Status         : {'MATCHED' if core_count == (sheet_count + portal_new_count + portal_ex_count) else 'DELTA DETECTED'}")

    print("\n--- Distribution by Source System ---")
    cur.execute("SELECT source_system, count(*) FROM public.core_walkin GROUP BY source_system ORDER BY count(*) DESC;")
    for r in cur.fetchall():
        print(f"  {r['source_system']:20}: {r['count']}")

    print("\n--- Distribution by City ---")
    cur.execute("SELECT city, count(*) FROM public.core_walkin GROUP BY city ORDER BY count(*) DESC;")
    for r in cur.fetchall():
        print(f"  {r['city']:20}: {r['count']}")

    print("\n--- Distribution by Visiting Reason Category ---")
    cur.execute("SELECT visiting_reason_category, count(*) FROM public.core_walkin GROUP BY visiting_reason_category ORDER BY count(*) DESC;")
    for r in cur.fetchall():
        print(f"  {r['visiting_reason_category']:25}: {r['count']}")

    conn.close()

def backfill():
    conn = get_db_connection()
    conn.autocommit = False
    cur = conn.cursor(cursor_factory=RealDictCursor)

    try:
        print("Starting full idempotent backfill of public.core_walkin...")
        cur.execute("TRUNCATE TABLE public.core_walkin RESTART IDENTITY;")

        cur.execute("""
            SELECT 
                pu.portal_user_id,
                pu.username,
                pu.email,
                COALESCE(NULLIF(TRIM(CONCAT(e.first_name, ' ', e.last_name)), ''), pu.username, 'Executive') AS exec_name
            FROM july_portal_users pu
            LEFT JOIN july_employees e ON e.employee_id = pu.employee_id;
        """)
        exec_map = {r['portal_user_id']: {'name': r['exec_name'], 'email': r['email'] or r['username']} for r in cur.fetchall()}

        # 1. Sheet Walkins
        cur.execute("SELECT * FROM public.sheet_walkins ORDER BY submission_timestamp ASC;")
        for r in cur.fetchall():
            full = (r['partner_name'] or 'UNKNOWN').strip()
            f_name = full.split(' ')[0].title() if full else 'UNKNOWN'
            l_name = ' '.join(full.split(' ')[1:]).title() if len(full.split(' ')) > 1 else None
            city = clean_city(r['city'])
            phone = clean_phone(r['partner_number'])
            v_reason = r['visiting_reason']
            v_cat = categorize_reason(v_reason)
            j_status = r['joined_status']
            is_j = True if (j_status and 'joined' in j_status.lower() and 'not' not in j_status.lower() and 'false' not in j_status.lower()) else False
            w_type = 'EXISTING_PARTNER' if v_cat in ['PAYOUT_HISAAB', 'VEHICLE_MAINTENANCE'] else 'NEW_CANDIDATE'

            cur.execute("""
                INSERT INTO public.core_walkin (
                    source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
                    walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
                    full_name, first_name, last_name, phone_number, partner_role,
                    dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
                    visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
                    lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
                    attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
                    sheet_row_number, created_at, updated_at
                ) VALUES (
                    'GOOGLE_SHEET', 'sheet_walkins', %s, NULL, NULL,
                    %s, %s, %s, %s, %s, NULL,
                    %s, %s, %s, %s, 'Driver',
                    %s, NULL, NULL, NULL,
                    %s, %s, %s, %s, %s, 'Submitted',
                    NULL, NULL, NULL, NULL,
                    %s, NULL, %s, %s, NULL,
                    %s, %s, %s
                );
            """, (
                r['id'], w_type, r['submission_timestamp'].date(), r['submission_timestamp'].strftime('%H:%M'), r['submission_timestamp'], city,
                full, f_name, l_name, phone, r['dl_number'],
                v_reason, v_cat, j_status, is_j, r['joined_date'],
                r['attending_executive'], r['submitter_email'], r['remarks'],
                r['sheet_row_number'], r['created_at'], r['updated_at']
            ))

        # 2. Portal New
        cur.execute("SELECT * FROM public.july_new_walkins ORDER BY id ASC;")
        for r in cur.fetchall():
            full = (r['person_name'] or f"{r['first_name'] or ''} {r['last_name'] or ''}").strip()
            f_name = r['first_name'] or (full.split(' ')[0].title() if full else 'UNKNOWN')
            l_name = r['last_name'] or (' '.join(full.split(' ')[1:]).title() if len(full.split(' ')) > 1 else None)
            city = clean_city(r['city'])
            phone = clean_phone(r['person_number'])
            v_reason = r['visiting_reason']
            v_cat = categorize_reason(v_reason)
            j_status = r['joined_status']
            is_j = True if (j_status and 'joined' in j_status.lower() and 'not' not in j_status.lower() and 'false' not in j_status.lower()) else False
            w_date = r['event_date'] or (r['created_at'].date() if r['created_at'] else None)
            w_time = r['enquiry_time'] or (r['created_at'].strftime('%H:%M') if r['created_at'] else '10:30')
            exec_id = r['executive_id'] or r['created_by']
            exec_info = exec_map.get(exec_id, {})

            cur.execute("""
                INSERT INTO public.core_walkin (
                    source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
                    walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
                    full_name, first_name, last_name, phone_number, partner_role,
                    dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
                    visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
                    lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
                    attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
                    sheet_row_number, created_at, updated_at
                ) VALUES (
                    'PORTAL_NEW', 'july_new_walkins', NULL, %s, NULL,
                    'NEW_CANDIDATE', %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s,
                    %s, %s, %s, %s,
                    %s, %s, %s, %s, NULL, %s,
                    %s, %s, %s, %s,
                    %s, %s, %s, %s, NULL,
                    NULL, %s, %s
                );
            """, (
                r['id'], w_date, w_time, r['created_at'], city, r['operating_place'],
                full, f_name, l_name, phone, r['interested_position'] or 'Driver',
                r['dl_number'], r['aadhaar_number'], r['dl_image'], r['aadhaar_image'],
                v_reason, v_cat, j_status, is_j, r['submission_status'] or 'Submitted',
                r['lead_channel'], r['lead_channel_details'], r['referred_by_name'], r['referred_by_phone'],
                exec_info.get('name', 'Executive'), exec_id, exec_info.get('email', ''), r['remarks'],
                r['created_at'], r['updated_at']
            ))

        # 3. Portal Existing
        cur.execute("SELECT * FROM public.july_existing_walkins ORDER BY id ASC;")
        for r in cur.fetchall():
            full = (r['person_name'] or f"{r['first_name'] or ''} {r['last_name'] or ''}").strip()
            f_name = r['first_name'] or (full.split(' ')[0].title() if full else 'UNKNOWN')
            l_name = r['last_name'] or (' '.join(full.split(' ')[1:]).title() if len(full.split(' ')) > 1 else None)
            city = clean_city(r['city'])
            phone = clean_phone(r['person_number'])
            v_reason = r['visiting_reason']
            v_cat = categorize_reason(v_reason)
            w_date = r['event_date'] or (r['created_at'].date() if r['created_at'] else None)
            w_time = r['enquiry_time'] or (r['created_at'].strftime('%H:%M') if r['created_at'] else '10:30')
            exec_id = r['executive_id'] or r['created_by']
            exec_info = exec_map.get(exec_id, {})

            cur.execute("""
                INSERT INTO public.core_walkin (
                    source_system, source_table, sheet_walkin_id, portal_new_walkin_id, portal_existing_walkin_id,
                    walkin_type, walkin_date, walkin_time, walkin_timestamp, city, operating_place,
                    full_name, first_name, last_name, phone_number, partner_role,
                    dl_number, aadhaar_number, dl_image_url, aadhaar_image_url,
                    visiting_reason, visiting_reason_category, joined_status, is_joined, joined_date, submission_status,
                    lead_channel, lead_channel_details, referred_by_name, referred_by_phone,
                    attending_executive, attending_executive_id, submitter_email, remarks, visit_notes,
                    sheet_row_number, created_at, updated_at
                ) VALUES (
                    'PORTAL_EXISTING', 'july_existing_walkins', NULL, NULL, %s,
                    'EXISTING_PARTNER', %s, %s, %s, %s, NULL,
                    %s, %s, %s, %s, %s,
                    NULL, NULL, NULL, NULL,
                    %s, %s, 'Partner Visit', FALSE, NULL, %s,
                    NULL, NULL, NULL, NULL,
                    %s, %s, %s, NULL, %s,
                    NULL, %s, %s
                );
            """, (
                r['id'], w_date, w_time, r['created_at'], city,
                full, f_name, l_name, phone, r['partner_type'] or 'Driver',
                v_reason, v_cat, r['submission_status'] or 'Submitted',
                exec_info.get('name', 'Executive'), exec_id, exec_info.get('email', ''), r['visit_notes'],
                r['created_at'], r['updated_at']
            ))

        conn.commit()
        print("Backfill completed successfully.")
        audit_health()

    except Exception as e:
        conn.rollback()
        print(f"Error during backfill: {e}")
        raise e
    finally:
        conn.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Walkin Final Table Automation & Reconciliation Engine")
    parser.add_argument('--audit', action='store_true', help="Run health and row count audit")
    parser.add_argument('--backfill', action='store_true', help="Run full idempotent backfill")
    args = parser.parse_args()

    if args.backfill:
        backfill()
    else:
        audit_health()
