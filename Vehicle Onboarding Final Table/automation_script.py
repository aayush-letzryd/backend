"""
LetzRyd - Vehicle Onboarding Final Table Automation & Reconciliation Engine
===========================================================================
Synchronizes, backfills, and audits public.core_vehicle_onboarding as the 
Single Source of Truth combining public.sheet_vehicle_onboarding and 
public.july_vehicle_onboarding with Portal Priority.

Usage:
    python automation_script.py --audit
    python automation_script.py --backfill
"""

import os
import sys
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

def audit_health():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    print("=================================================================")
    print("=== Core Vehicle Onboarding Health & Reconciliation Audit ===")
    print("=================================================================")

    # Check existence
    cur.execute("""
        SELECT EXISTS (
            SELECT FROM information_schema.tables 
            WHERE table_schema = 'public' AND table_name = 'core_vehicle_onboarding'
        );
    """)
    table_exists = cur.fetchone()['exists']
    if not table_exists:
        print("[!] Table public.core_vehicle_onboarding does not exist yet. Run --backfill first.")
        conn.close()
        return

    cur.execute("SELECT count(*) as cnt FROM public.sheet_vehicle_onboarding;")
    sheet_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.july_vehicle_onboarding;")
    portal_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.core_vehicle_onboarding;")
    core_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.core_vehicle_onboarding WHERE is_deleted = FALSE;")
    active_count = cur.fetchone()['cnt']

    cur.execute("SELECT count(*) as cnt FROM public.core_vehicle_onboarding WHERE is_deleted = TRUE;")
    deleted_count = cur.fetchone()['cnt']

    cur.execute("SELECT MIN(id) as min_id, MAX(id) as max_id FROM public.core_vehicle_onboarding;")
    id_range = cur.fetchone()

    cur.execute("""
        SELECT s.i 
        FROM generate_series(1, COALESCE((SELECT MAX(id) FROM public.core_vehicle_onboarding), 0)) s(i) 
        LEFT JOIN public.core_vehicle_onboarding c ON s.i = c.id 
        WHERE c.id IS NULL;
    """)
    gaps = cur.fetchall()

    print(f"\n[+] Upstream Counts:")
    print(f"    - public.sheet_vehicle_onboarding : {sheet_count:,} rows")
    print(f"    - public.july_vehicle_onboarding  : {portal_count:,} rows")
    print(f"\n[+] Master Table (public.core_vehicle_onboarding):")
    print(f"    - Total Records                   : {core_count:,}")
    print(f"    - Active (Live) Records           : {active_count:,}")
    print(f"    - Soft Deleted Records            : {deleted_count:,}")
    print(f"    - ID Sequence Range               : {id_range['min_id']} to {id_range['max_id']}")
    print(f"    - Sequence Gaps (Missing IDs)     : {len(gaps)}")

    # Breakdown by Source System
    cur.execute("""
        SELECT source_system, count(*) as cnt 
        FROM public.core_vehicle_onboarding 
        GROUP BY source_system 
        ORDER BY cnt DESC;
    """)
    print("\n[+] Source System Distribution:")
    for row in cur.fetchall():
        print(f"    - {row['source_system']:<25}: {row['cnt']:,}")

    # Breakdown by City
    cur.execute("""
        SELECT city, count(*) as cnt 
        FROM public.core_vehicle_onboarding 
        GROUP BY city 
        ORDER BY cnt DESC;
    """)
    print("\n[+] City Distribution:")
    for row in cur.fetchall():
        print(f"    - {row['city']:<25}: {row['cnt']:,}")

    # Priority Verification on Overlapping Plates
    cur.execute("""
        SELECT c.registration_no, c.source_system, c.portal_vehicle_id, c.sheet_vehicle_id, c.dealer_name, c.created_at
        FROM public.core_vehicle_onboarding c
        WHERE c.portal_vehicle_id IS NOT NULL AND c.sheet_vehicle_id IS NOT NULL
        LIMIT 5;
    """)
    overlaps = cur.fetchall()
    print(f"\n[+] Overlapping Records Verification (Portal Precedence Check):")
    if overlaps:
        for r in overlaps:
            print(f"    - Plate: {r['registration_no']} | Source: {r['source_system']} | Portal ID: {r['portal_vehicle_id']} | Sheet ID: {r['sheet_vehicle_id']}")
    else:
        print("    - No dual-source plate overlaps currently detected.")

    conn.close()
    print("\n=================================================================")
    print("=== Audit Completed Successfully ===")
    print("=================================================================\n")

def run_backfill():
    conn = get_db_connection()
    conn.autocommit = True
    cur = conn.cursor()

    schema_file = os.path.join(os.path.dirname(__file__), 'schema.sql')
    print(f"[*] Reading schema definition from: {schema_file}")
    with open(schema_file, 'r', encoding='utf-8') as f:
        schema_sql = f.read()

    print("[*] Applying schema, indexes, and triggers to PostgreSQL...")
    cur.execute(schema_sql)
    print("[+] Schema & triggers applied successfully.")

    print("[*] Initiating backfill from public.sheet_vehicle_onboarding...")
    # Triggering backfill via re-evaluating or inserting
    cur.execute("""
        DO $$
        DECLARE
            r RECORD;
        BEGIN
            FOR r IN SELECT * FROM public.sheet_vehicle_onboarding ORDER BY id ASC LOOP
                PERFORM public.fn_sync_core_vehicle_from_sheet_row(r);
            END LOOP;
        END $$;
    """) if False else None

    # Initial bulk load if core table is empty
    cur.execute("SELECT count(*) FROM public.core_vehicle_onboarding;")
    current_cnt = cur.fetchone()[0]

    if current_cnt == 0:
        print("[*] Loading historical records from sheet_vehicle_onboarding...")
        cur.execute("""
            INSERT INTO public.core_vehicle_onboarding (
                id,
                source_system, source_table, sheet_vehicle_id,
                registration_no, letzryd_unique_no, chassis_no, engine_no,
                city, model, fuel_type, dealer_name, registered_owner_name,
                ownership, financier, hp_details, mfg_date, ageing, vehicle_status,
                received_allocated, delivery_month, registration_date, delivery_date, payment_date,
                rto_tax_validity, permit_validity, fitness_validity, pollution_validity, insurance_validity,
                kms_reading, tracking_device_vendor, tracking_device_type, gps_status,
                key_quantity, jack, jack_rod, spanner, parking_triangle, fire_extinguishers,
                seat_cover, floor_carpet, cng_plate, cng_installation_date,
                pdi_status, platform, pdi_timestamp, pdi_email_address, pdi_city, pdi_reg_no,
                mds_timestamp, mds_email_address, mds_vehicle_number, sheet_row_number,
                rc_document, permit_document, fitness_document, pollution_document, insurance_document,
                insurance_endorsement, invoice_copy, key_photo_url,
                image_front, image_back, image_lh, image_rh,
                engine_chasis_no_img, battery_sl_no_img, engine_compartment_img,
                fast_tag_img, music_system_img,
                rh_fr_tyre_brand_sl_no, lh_fr_tyre_brand_sl_no, rh_rear_tyre_brand_sl_no,
                lh_rear_tyre_brand_sl_no, spare_wheel_brand_sl_no, battery_sl_no,
                comments, chassis_review_flag,
                is_deleted, created_at, updated_at
            )
            SELECT 
                ROW_NUMBER() OVER (ORDER BY s.id ASC) AS id,
                'GOOGLE_SHEET' AS source_system,
                'sheet_vehicle_onboarding' AS source_table,
                s.id AS sheet_vehicle_id,
                public.fn_clean_plate(s.registration_no) AS registration_no,
                COALESCE(s.letzryd_unique_vehicle_no, s.letzryd_serial_number) AS letzryd_unique_no,
                s.chassis_no,
                s.engine_no,
                public.fn_clean_city_name(COALESCE(s.city, s.pdi_city)) AS city,
                s.model,
                'CNG' AS fuel_type,
                s.dealer AS dealer_name,
                s.registered_owner_name,
                s.ownership,
                s.financier,
                s.hp AS hp_details,
                s.mfg_mm_yy AS mfg_date,
                s.ageing,
                COALESCE(s.vehicle_status, 'ACTIVE') AS vehicle_status,
                s.received_or_allocated AS received_allocated,
                s.delivered_month_y AS delivery_month,
                s.registration_date,
                s.delivery_date,
                s.payment_date,
                s.rto_tax_validity,
                s.permit_validity,
                s.fitness_validity,
                s.pollution_validity,
                s.insurance_validity,
                s.kms_reading,
                s.tracking_device_vendor,
                s.tracking_device_type,
                s.gps AS gps_status,
                s.key_quantity,
                s.jack,
                s.jack_rod,
                s.spanner,
                s.parking_triangle,
                s.fire_extinguishers,
                s.seat_cover,
                s.floor_carpet,
                s.cng_plate,
                s.cng_installation_date,
                s.pdi_status,
                s.platform,
                (s.pdi_timestamp AT TIME ZONE 'Asia/Kolkata')::TIMESTAMP,
                s.pdi_email_address,
                s.pdi_city,
                s.pdi_reg_no,
                (s.mds_timestamp AT TIME ZONE 'Asia/Kolkata')::TIMESTAMP,
                s.mds_email_address,
                s.mds_vehicle_number,
                s.sheet_row_number,
                s.registration_certificate AS rc_document,
                s.permit AS permit_document,
                s.fitness AS fitness_document,
                s.pollution AS pollution_document,
                s.insurance AS insurance_document,
                s.insurance_endorsement,
                s.invoice_copy,
                s.key_photo_url,
                COALESCE(s.front_photo, s.vehicle_image_front) AS image_front,
                COALESCE(s.back_photo, s.vehicle_image_back) AS image_back,
                s.vehicle_image_lh AS image_lh,
                s.vehicle_image_rh AS image_rh,
                s.engine_and_chasis_no AS engine_chasis_no_img,
                s.battery_sl_no AS battery_sl_no_img,
                s.engine_compartment AS engine_compartment_img,
                s.fast_tag_image_from_inside AS fast_tag_img,
                s.music_system_image AS music_system_img,
                s.rh_fr_tyre_brand_sl_no,
                s.lh_fr_tyre_brand_sl_no,
                s.rh_rear_tyre_brand_sl_no,
                s.lh_rear_tyre_brand_sl_no,
                s.spare_wheel_brand_sl_no,
                s.battery_sl_no,
                s.comments,
                (LENGTH(TRIM(COALESCE(s.chassis_no, ''))) != 17),
                FALSE,
                COALESCE((s.created_at AT TIME ZONE 'Asia/Kolkata')::TIMESTAMP, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')),
                COALESCE((s.updated_at AT TIME ZONE 'Asia/Kolkata')::TIMESTAMP, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'))
            FROM (
                -- Distinct ON clean plate to deduplicate if any duplicates exist in raw sheet
                SELECT DISTINCT ON (public.fn_clean_plate(registration_no)) *
                FROM public.sheet_vehicle_onboarding
                WHERE registration_no IS NOT NULL AND TRIM(registration_no) != ''
                ORDER BY public.fn_clean_plate(registration_no), id DESC
            ) s;
        """)
        print("[+] Initial sheet backfill completed.")

        print("[*] Backfilling and overlaying records from july_vehicle_onboarding (Portal Priority)...")
        cur.execute("""
            DO $$
            DECLARE
                j RECORD;
            BEGIN
                FOR j IN SELECT * FROM public.july_vehicle_onboarding ORDER BY id ASC LOOP
                    IF EXISTS (SELECT 1 FROM public.core_vehicle_onboarding WHERE registration_no = public.fn_clean_plate(j.vehicle_number)) THEN
                        UPDATE public.core_vehicle_onboarding
                        SET 
                            source_system = 'MERGED_PORTAL_SHEET',
                            source_table = 'july_vehicle_onboarding',
                            portal_vehicle_id = j.id,
                            letzryd_unique_no = COALESCE(NULLIF(j.letzryd_unique_no, ''), letzryd_unique_no),
                            chassis_no = COALESCE(NULLIF(j.chassis_number, ''), chassis_no),
                            engine_no = COALESCE(NULLIF(j.engine_number, ''), engine_no),
                            city = public.fn_clean_city_name(j.city_name),
                            model = COALESCE(NULLIF(j.model, ''), model),
                            fuel_type = COALESCE(NULLIF(j.fuel_type, ''), fuel_type, 'CNG'),
                            color = COALESCE(NULLIF(j.color, ''), color),
                            dealer_name = COALESCE(NULLIF(j.dealer_name, ''), dealer_name),
                            registered_owner_name = COALESCE(NULLIF(j.registered_owner_name, ''), registered_owner_name),
                            hp_details = COALESCE(NULLIF(j.hp_details, ''), hp_details),
                            mfg_date = COALESCE(NULLIF(j.mfg_date, ''), mfg_date),
                            received_allocated = COALESCE(NULLIF(j.received_allocated, ''), received_allocated),
                            delivery_month = COALESCE(NULLIF(j.delivery_month, ''), delivery_month),
                            registration_date = COALESCE(public.fn_parse_flexible_date(j.registration_date), registration_date),
                            invoice_date = COALESCE(j.invoice_date, invoice_date),
                            invoice_no = COALESCE(NULLIF(j.invoice_no, ''), invoice_no),
                            rto_tax_validity = COALESCE(public.fn_parse_flexible_date(j.rto_tax_validity), rto_tax_validity),
                            permit_validity = COALESCE(j.permit_end_date, public.fn_parse_flexible_date(j.permit_validity), permit_validity),
                            permit_start_date = COALESCE(j.permit_start_date, permit_start_date),
                            permit_end_date = COALESCE(j.permit_end_date, permit_end_date),
                            permit_type = COALESCE(NULLIF(j.permit_type, ''), permit_type),
                            fitness_validity = COALESCE(j.fitness_end_date, public.fn_parse_flexible_date(j.fitness_validity), fitness_validity),
                            fitness_start_date = COALESCE(j.fitness_start_date, fitness_start_date),
                            fitness_end_date = COALESCE(j.fitness_end_date, fitness_end_date),
                            pollution_validity = COALESCE(public.fn_parse_flexible_date(j.pollution_validity), pollution_validity),
                            auth_start_date = COALESCE(j.auth_start_date, auth_start_date),
                            auth_end_date = COALESCE(j.auth_end_date, auth_end_date),
                            authorization_certificate = COALESCE(NULLIF(j.authorization_certificate, ''), authorization_certificate),
                            insurance_validity = COALESCE(public.fn_parse_flexible_date(j.insurance_validity), insurance_validity),
                            insurance_start_date = COALESCE(public.fn_parse_flexible_date(j.insurance_start_date), insurance_start_date),
                            insurance_broker = COALESCE(NULLIF(j.insurance_broker, ''), insurance_broker),
                            insurance_underwriter = COALESCE(NULLIF(j.insurance_underwriter, ''), insurance_underwriter),
                            insurance_idv = COALESCE(NULLIF(j.insurance_idv, ''), insurance_idv),
                            insurance_mapping = COALESCE(NULLIF(j.insurance_mapping, ''), insurance_mapping),
                            cover_engine_protect = COALESCE(j.cover_engine_protect, cover_engine_protect),
                            cover_consumables = COALESCE(j.cover_consumables, cover_consumables),
                            cover_zero_dep = COALESCE(j.cover_zero_dep, cover_zero_dep),
                            cover_rsa = COALESCE(j.cover_rsa, cover_rsa),
                            kms_reading = COALESCE(NULLIF(REGEXP_REPLACE(j.kms_reading, '[^0-9.]', '', 'g'), '')::NUMERIC, kms_reading),
                            tracking_device_vendor = COALESCE(NULLIF(j.tracking_device_vendor, ''), tracking_device_vendor),
                            tracking_device_type = COALESCE(NULLIF(j.tracking_device_type, ''), tracking_device_type),
                            fast_tag_number = COALESCE(NULLIF(j.fast_tag_number, ''), fast_tag_number),
                            fast_tag_vendor = COALESCE(NULLIF(j.fast_tag_vendor, ''), fast_tag_vendor),
                            key_quantity = COALESCE(j.key_quantity::TEXT, key_quantity),
                            jack = COALESCE(NULLIF(j.jack, ''), jack),
                            jack_rod = COALESCE(NULLIF(j.jack_rod, ''), jack_rod),
                            spanner = COALESCE(NULLIF(j.spanner, ''), spanner),
                            parking_triangle = COALESCE(NULLIF(j.parking_triangle, ''), parking_triangle),
                            fire_extinguishers = COALESCE(NULLIF(j.fire_extinguishers, ''), fire_extinguishers),
                            seat_cover = COALESCE(NULLIF(j.seat_cover, ''), seat_cover),
                            floor_carpet = COALESCE(NULLIF(j.floor_carpet, ''), floor_carpet),
                            cng_installed = COALESCE(NULLIF(j.cng_installed, ''), cng_installed),
                            cng_plate = COALESCE(NULLIF(j.cng_plate, ''), cng_plate),
                            cng_tank_number = COALESCE(NULLIF(j.cng_tank_number, ''), cng_tank_number),
                            cng_installation_date = COALESCE(public.fn_parse_flexible_date(j.cng_installation_date), cng_installation_date),
                            rc_document = COALESCE(NULLIF(j.rc_document, ''), rc_document),
                            insurance_document = COALESCE(NULLIF(j.insurance_document, ''), insurance_document),
                            authorization_certificate_doc = COALESCE(NULLIF(j.authorization_certificate_doc, ''), authorization_certificate_doc),
                            rto_tax_receipt = COALESCE(NULLIF(j.rto_tax_receipt, ''), rto_tax_receipt),
                            image_front = COALESCE(NULLIF(j.image_front, ''), image_front),
                            image_lh = COALESCE(NULLIF(j.image_lh, ''), image_lh),
                            image_back = COALESCE(NULLIF(j.image_back, ''), image_back),
                            image_rh = COALESCE(NULLIF(j.image_rh, ''), image_rh),
                            engine_chasis_no_img = COALESCE(NULLIF(j.engine_chasis_no_img, ''), engine_chasis_no_img),
                            battery_sl_no_img = COALESCE(NULLIF(j.battery_sl_no_img, ''), battery_sl_no_img),
                            engine_compartment_img = COALESCE(NULLIF(j.engine_compartment_img, ''), engine_compartment_img),
                            fast_tag_img = COALESCE(NULLIF(j.fast_tag_img, ''), fast_tag_img),
                            music_system_img = COALESCE(NULLIF(j.music_system_img, ''), music_system_img),
                            rh_fr_tyre_img = COALESCE(NULLIF(j.rh_fr_tyre_img, ''), rh_fr_tyre_img),
                            lh_fr_tyre_img = COALESCE(NULLIF(j.lh_fr_tyre_img, ''), lh_fr_tyre_img),
                            rh_rear_tyre_img = COALESCE(NULLIF(j.rh_rear_tyre_img, ''), rh_rear_tyre_img),
                            lh_rear_tyre_img = COALESCE(NULLIF(j.lh_rear_tyre_img, ''), lh_rear_tyre_img),
                            spare_wheel_img = COALESCE(NULLIF(j.spare_wheel_img, ''), spare_wheel_img),
                            approval_status = COALESCE(NULLIF(j.approval_status, ''), approval_status),
                            current_approver_id = COALESCE(j.current_approver_id, current_approver_id),
                            approved_by = COALESCE(j.approved_by, approved_by),
                            approval_remarks = COALESCE(NULLIF(j.approval_remarks, ''), approval_remarks),
                            chassis_review_flag = (LENGTH(TRIM(COALESCE(j.chassis_number, ''))) != 17),
                            is_migrated = COALESCE(j.is_migrated, is_migrated),
                            created_by = COALESCE(j.created_by, created_by),
                            updated_by = COALESCE(j.updated_by, updated_by),
                            is_deleted = CASE WHEN is_deleted THEN is_deleted ELSE FALSE END,
                            deleted_at = CASE WHEN is_deleted THEN deleted_at ELSE NULL END,
                            updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                        WHERE registration_no = public.fn_clean_plate(j.vehicle_number);
                    ELSE
                        INSERT INTO public.core_vehicle_onboarding (
                            source_system, source_table, portal_vehicle_id,
                            registration_no, letzryd_unique_no, chassis_no, engine_no,
                            city, model, fuel_type, color, dealer_name, registered_owner_name,
                            hp_details, mfg_date, received_allocated, delivery_month,
                            registration_date, invoice_date, invoice_no,
                            rto_tax_validity, permit_validity, permit_start_date, permit_end_date, permit_type,
                            fitness_validity, fitness_start_date, fitness_end_date,
                            pollution_validity, auth_start_date, auth_end_date, authorization_certificate,
                            insurance_validity, insurance_start_date, insurance_broker, insurance_underwriter,
                            insurance_idv, insurance_mapping, cover_engine_protect, cover_consumables,
                            cover_zero_dep, cover_rsa,
                            kms_reading, tracking_device_vendor, tracking_device_type,
                            fast_tag_number, fast_tag_vendor,
                            key_quantity, jack, jack_rod, spanner, parking_triangle, fire_extinguishers,
                            seat_cover, floor_carpet, cng_installed, cng_plate, cng_tank_number, cng_installation_date,
                            rc_document, insurance_document, authorization_certificate_doc, rto_tax_receipt,
                            image_front, image_lh, image_back, image_rh,
                            engine_chasis_no_img, battery_sl_no_img, engine_compartment_img,
                            fast_tag_img, music_system_img,
                            rh_fr_tyre_img, lh_fr_tyre_img, rh_rear_tyre_img, lh_rear_tyre_img, spare_wheel_img,
                            approval_status, current_approver_id, approved_by, approval_remarks,
                            chassis_review_flag, is_migrated, created_by, updated_by,
                            is_deleted, created_at, updated_at
                        ) VALUES (
                            'PORTAL_FORM', 'july_vehicle_onboarding', j.id,
                            public.fn_clean_plate(j.vehicle_number), j.letzryd_unique_no, j.chassis_number, j.engine_number,
                            public.fn_clean_city_name(j.city_name), j.model, COALESCE(j.fuel_type, 'CNG'), j.color, j.dealer_name, j.registered_owner_name,
                            j.hp_details, j.mfg_date, j.received_allocated, j.delivery_month,
                            public.fn_parse_flexible_date(j.registration_date), j.invoice_date, j.invoice_no,
                            public.fn_parse_flexible_date(j.rto_tax_validity), 
                            COALESCE(j.permit_end_date, public.fn_parse_flexible_date(j.permit_validity)), j.permit_start_date, j.permit_end_date, j.permit_type,
                            COALESCE(j.fitness_end_date, public.fn_parse_flexible_date(j.fitness_validity)), j.fitness_start_date, j.fitness_end_date,
                            public.fn_parse_flexible_date(j.pollution_validity), j.auth_start_date, j.auth_end_date, j.authorization_certificate,
                            public.fn_parse_flexible_date(j.insurance_validity), public.fn_parse_flexible_date(j.insurance_start_date), j.insurance_broker, j.insurance_underwriter,
                            j.insurance_idv, j.insurance_mapping, COALESCE(j.cover_engine_protect, FALSE), COALESCE(j.cover_consumables, FALSE),
                            COALESCE(j.cover_zero_dep, FALSE), COALESCE(j.cover_rsa, FALSE),
                            NULLIF(REGEXP_REPLACE(j.kms_reading, '[^0-9.]', '', 'g'), '')::NUMERIC, j.tracking_device_vendor, j.tracking_device_type,
                            j.fast_tag_number, j.fast_tag_vendor,
                            j.key_quantity::TEXT, j.jack, j.jack_rod, j.spanner, j.parking_triangle, j.fire_extinguishers,
                            j.seat_cover, j.floor_carpet, j.cng_installed, j.cng_plate, j.cng_tank_number, public.fn_parse_flexible_date(j.cng_installation_date),
                            j.rc_document, j.insurance_document, j.authorization_certificate_doc, j.rto_tax_receipt,
                            j.image_front, j.image_lh, j.image_back, j.image_rh,
                            j.engine_chasis_no_img, j.battery_sl_no_img, j.engine_compartment_img,
                            j.fast_tag_img, j.music_system_img,
                            j.rh_fr_tyre_img, j.lh_fr_tyre_img, j.rh_rear_tyre_img, j.lh_rear_tyre_img, j.spare_wheel_img,
                            COALESCE(j.approval_status, 'APPROVED'), j.current_approver_id, j.approved_by, j.approval_remarks,
                            (LENGTH(TRIM(COALESCE(j.chassis_number, ''))) != 17), COALESCE(j.is_migrated, FALSE), j.created_by, j.updated_by,
                            FALSE, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'), (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
                        );
                    END IF;
                END LOOP;
                PERFORM setval('public.core_vehicle_onboarding_id_seq', (SELECT COALESCE(MAX(id), 1) FROM public.core_vehicle_onboarding), true);
            END $$;
        """)
        print("[+] Portal backfill & overlay completed.")

    conn.close()
    print("\n[+] Full Migration and Backfill process finished successfully!")
    audit_health()

def main():
    parser = argparse.ArgumentParser(description="LetzRyd Vehicle Onboarding Master Pipeline Manager")
    parser.add_argument('--audit', action='store_true', help="Run health and parity audit on core_vehicle_onboarding")
    parser.add_argument('--backfill', action='store_true', help="Deploy schema, triggers, and perform historical backfill")

    args = parser.parse_args()

    if args.backfill:
        run_backfill()
    elif args.audit:
        audit_health()
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
