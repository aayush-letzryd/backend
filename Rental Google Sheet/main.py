import os
import io
import requests
import openpyxl
import psycopg2
import functions_framework

def get_db_connection():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "35.200.196.113"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME", "postgres"),
        user=os.getenv("DB_USER", "postgres"),
        password=os.getenv("DB_PASSWORD", r"8S5]U3@L^Xz)\FH}")
    )

def ensure_tables(cur):
    ddl = """
    CREATE TABLE IF NOT EXISTS sheet_rental_slabs (
        id SERIAL PRIMARY KEY,
        city VARCHAR(32) NOT NULL,
        vehicle_model VARCHAR(64) NOT NULL,
        uber_type VARCHAR(32) DEFAULT 'TBS',
        plan_scheme VARCHAR(64) NOT NULL DEFAULT 'Uber Reducing Rent',
        driver_type VARCHAR(32) NOT NULL DEFAULT 'All',
        trip_slab_label VARCHAR(64) NOT NULL,
        min_trips INT NOT NULL DEFAULT 0,
        max_trips INT NOT NULL DEFAULT 9999,
        daily_rent NUMERIC(10,2) NOT NULL,
        daily_indemnity NUMERIC(10,2) NOT NULL DEFAULT 0.00,
        platform VARCHAR(64) DEFAULT 'Uber',
        pass_on_incentive VARCHAR(16) DEFAULT 'yes',
        last_synced_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT uq_sheet_rental_slabs UNIQUE (city, vehicle_model, uber_type, plan_scheme, driver_type, min_trips)
    );

    CREATE INDEX IF NOT EXISTS idx_sheet_rental_slabs_lookup 
    ON sheet_rental_slabs (city, vehicle_model, driver_type, min_trips, max_trips);

    CREATE TABLE IF NOT EXISTS sheet_rental_partners (
        vendor_code VARCHAR(64) PRIMARY KEY,
        vendor_name VARCHAR(128),
        city VARCHAR(32) NOT NULL,
        vendor_type VARCHAR(32),
        plan_name VARCHAR(64),
        platform VARCHAR(64),
        plan_type_hisaab VARCHAR(64),
        custom_daily_rent NUMERIC(10,2) NULL,
        custom_daily_indemnity NUMERIC(10,2) NULL,
        last_synced_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
    );

    CREATE INDEX IF NOT EXISTS idx_sheet_rental_partners_city 
    ON sheet_rental_partners (city);
    """
    cur.execute(ddl)

def sync_rental_data():
    sheet_id = os.getenv("SPREADSHEET_ID", "1xnGg3qhb1AnCP2Qv6e2gmd0zCi5j-bNbx9yDc7etzf4")
    export_url = f"https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=xlsx"
    
    resp = requests.get(export_url, headers={"User-Agent": "Mozilla/5.0"}, timeout=45)
    resp.raise_for_status()
    wb = openpyxl.load_workbook(io.BytesIO(resp.content), data_only=True)
    
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        ensure_tables(cur)
        
        # --- 1. sheet_rental_partners (Driver platform tabs + Fixed Rent Drivers side tables) ---
        partners = {}
        
        def add_partner(code, name, city, vtype, plan, plat, ptype, rent, indem):
            c = str(code).strip()
            if not c or c.lower() == 'none': return
            partners[c] = (c, str(name).strip() if name else '', city, str(vtype).strip() if vtype else 'Individual',
                           str(plan).strip() if plan else '', str(plat).strip() if plat else 'Uber',
                           str(ptype).strip() if ptype else '', rent, indem)

        # HYD - Driver platform
        if "HYD - Driver platform" in wb.sheetnames:
            ws = wb["HYD - Driver platform"]
            for r in list(ws.iter_rows(values_only=True))[1:]:
                if not r or not r[1]: continue
                vname, vcode = str(r[0]).strip() if r[0] else '', str(r[1]).strip()
                vtype = str(r[2]).strip() if len(r) > 2 and r[2] else 'Operator'
                plan = str(r[3]).strip() if len(r) > 3 and r[3] else ''
                plat = str(r[4]).strip() if len(r) > 4 and r[4] else ''
                ptype = str(r[5]).strip() if len(r) > 5 and r[5] else ''
                
                rent, indem = None, None
                if 'All Platform' in ptype or 'All Platform' in plat: rent = 1050.00
                if "900" in vname or "900" in plan: rent = 900.00
                if "970" in vname or "970" in plan: rent = 970.00
                if vcode == 'LETZHYDIP9885838038': rent, indem = 900.00, 0.00
                elif vcode == 'LETZHYDIP9848529242': rent = 900.00
                elif vcode == 'LETZHYDIP7396655106': rent = 970.00
                add_partner(vcode, vname, 'Hyderabad', vtype, plan, plat, ptype, rent, indem)

        # MUM - Driver platform
        if "MUM - Driver platform" in wb.sheetnames:
            ws = wb["MUM - Driver platform"]
            for r in list(ws.iter_rows(values_only=True))[1:]:
                if not r or not r[1]: continue
                vname, vcode = str(r[0]).strip() if r[0] else '', str(r[1]).strip()
                plan = str(r[2]).strip() if len(r) > 2 and r[2] else ''
                ptype = str(r[3]).strip() if len(r) > 3 and r[3] else ''
                rent = 1050.00 if ('All Platform' in ptype or 'All Platform' in plan) else None
                add_partner(vcode, vname, 'Mumbai', 'Operator', plan, 'Uber', ptype, rent, None)

        # BLR - Driver platform
        if "BLR - Driver platform" in wb.sheetnames:
            ws = wb["BLR - Driver platform"]
            for r in list(ws.iter_rows(values_only=True))[1:]:
                if not r or not r[1]: continue
                vname, vcode = str(r[0]).strip() if r[0] else '', str(r[1]).strip()
                vtype = str(r[2]).strip() if len(r) > 2 and r[2] else 'Individual'
                ptype = str(r[3]).strip() if len(r) > 3 and r[3] else ''
                rent = 1050.00 if ('All Platform' in ptype) else None
                indem = 15.00 if vcode == 'LETZBLRIP9036461336' else None
                add_partner(vcode, vname, 'Bengaluru', vtype, '', 'Uber', ptype, rent, indem)

        # Side table in HYD - Rental Slab (Columns L to Q: Fixed Rent Drivers)
        if "HYD - Rental Slab" in wb.sheetnames:
            ws_hyd_s = wb["HYD - Rental Slab"]
            for r in list(ws_hyd_s.iter_rows(values_only=True))[1:]:
                if len(r) > 15 and r[14]:
                    vcode = str(r[14]).strip()
                    vname = str(r[13]).strip() if r[13] else ''
                    try: frent = float(r[15])
                    except: frent = None
                    add_partner(vcode, vname, 'Hyderabad', 'Operator', 'Fixed Rent Driver', 'Uber', 'Fixed', frent, None)

        # Side table in MUM - Rental Slab (Columns H to N: Fixed Rent Drivers)
        if "MUM - Rental Slab" in wb.sheetnames:
            ws_mum_s = wb["MUM - Rental Slab"]
            for r in list(ws_mum_s.iter_rows(values_only=True))[1:]:
                if len(r) > 9 and r[9]:
                    vcode = str(r[9]).strip()
                    vname = str(r[8]).strip() if r[8] else ''
                    vtype = str(r[11]).strip() if len(r) > 11 and r[11] else 'Operator'
                    try: frent = float(r[10]) if len(r) > 10 else None
                    except: frent = None
                    add_partner(vcode, vname, 'Mumbai', vtype, 'Fixed Rent Driver', 'Uber', 'Fixed', frent, None)

        upsert_partner_sql = """
        INSERT INTO sheet_rental_partners (
            vendor_code, vendor_name, city, vendor_type, plan_name, platform, plan_type_hisaab, custom_daily_rent, custom_daily_indemnity, last_synced_at
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP)
        ON CONFLICT (vendor_code) DO UPDATE SET
            vendor_name = EXCLUDED.vendor_name,
            city = EXCLUDED.city,
            vendor_type = EXCLUDED.vendor_type,
            plan_name = EXCLUDED.plan_name,
            platform = EXCLUDED.platform,
            plan_type_hisaab = EXCLUDED.plan_type_hisaab,
            custom_daily_rent = EXCLUDED.custom_daily_rent,
            custom_daily_indemnity = EXCLUDED.custom_daily_indemnity,
            last_synced_at = CURRENT_TIMESTAMP;
        """
        for p in partners.values():
            cur.execute(upsert_partner_sql, p)

        # --- 2. sheet_rental_slabs (Uber Reducing + All Platform) ---
        slabs = []
        def add_slab(city, model, utype, scheme, dtype, label, min_t, max_t, rent, plat='Uber', pass_inc='yes'):
            slabs.append((city, model, utype, scheme, dtype, label, int(min_t), int(max_t), float(rent), 0.00, plat, pass_inc))

        # HYD Slabs
        if "HYD - Rental Slab" in wb.sheetnames:
            ws_hyd_s = wb["HYD - Rental Slab"]
            hyd_groups = {}
            for r in list(ws_hyd_s.iter_rows(values_only=True))[1:]:
                if not r or not r[0] or r[3] is None: continue
                model = str(r[0]).strip()
                try: min_t = int(float(r[1]))
                except: min_t = 0
                try: rent = float(r[3])
                except: continue
                utype = str(r[4]).strip() if len(r) > 4 and r[4] else 'TBS'
                key = (model, utype)
                if key not in hyd_groups: hyd_groups[key] = []
                hyd_groups[key].append((min_t, rent))

            for (model, utype), tier_list in hyd_groups.items():
                tier_list.sort(key=lambda x: x[0])
                for i in range(len(tier_list)):
                    curr_min, curr_rent = tier_list[i]
                    next_min = tier_list[i+1][0] if i + 1 < len(tier_list) else 10000
                    curr_max = (next_min - 1) if next_min < 10000 else 9999
                    label = f"{curr_min}-{curr_max}" if curr_max < 9999 else f"{curr_min}+"
                    add_slab('Hyderabad', model, utype, 'Uber Reducing Rent', 'All', label, curr_min, curr_max, curr_rent)

            # HYD All Platform (Columns G to J)
            for r in list(ws_hyd_s.iter_rows(values_only=True))[1:4]:
                if len(r) > 8 and r[6] and r[8] is not None:
                    model = str(r[6]).strip()
                    try:
                        rent = float(r[8])
                        add_slab('Hyderabad', model, 'TBS', 'All Platform', 'All', '0+', 0, 9999, rent, 'All Platform', 'yes')
                    except: pass

        # MUM Slabs
        if "MUM - Rental Slab" in wb.sheetnames:
            ws_mum_s = wb["MUM - Rental Slab"]
            mum_tiers = []
            for r in list(ws_mum_s.iter_rows(values_only=True))[1:7]:
                if not r or r[0] is None or r[1] is None: continue
                try: mum_tiers.append((int(float(r[0])), float(r[1])))
                except: pass
            mum_tiers.sort(key=lambda x: x[0])
            for i in range(len(mum_tiers)):
                curr_min, curr_rent = mum_tiers[i]
                next_min = mum_tiers[i+1][0] if i + 1 < len(mum_tiers) else 10000
                curr_max = (next_min - 1) if next_min < 10000 else 9999
                label = f"{curr_min}-{curr_max}" if curr_max < 9999 else f"{curr_min}+"
                add_slab('Mumbai', 'Maruti Wagonr Tour H3 CNG', 'TBS', 'Uber Reducing Rent', 'All', label, curr_min, curr_max, curr_rent)

            # MUM All Platform (Columns D to F)
            for r in list(ws_mum_s.iter_rows(values_only=True))[1:2]:
                if len(r) > 4 and r[4] is not None:
                    try:
                        rent = float(r[4])
                        add_slab('Mumbai', 'Maruti Wagonr Tour H3 CNG', 'TBS', 'All Platform', 'All', '0+', 0, 9999, rent, 'All Platform', 'yes')
                    except: pass

        # BLR Slabs
        if "BLR- Rental Slab" in wb.sheetnames:
            ws_blr_s = wb["BLR- Rental Slab"]
            blr_groups = {}
            for r in list(ws_blr_s.iter_rows(values_only=True))[1:18]:
                if not r or not r[0] or r[2] is None: continue
                utype = str(r[0]).strip()
                raw_label = str(r[1]).strip()
                try: rent = float(r[2])
                except: continue
                dtype = str(r[3]).strip() if len(r) > 3 and r[3] else 'Individual'
                
                if '<55' in raw_label or '<90' in raw_label: min_t = 0
                elif '55+' in raw_label: min_t = 55
                elif '65+' in raw_label: min_t = 65
                elif '70+' in raw_label: min_t = 70
                elif '75+' in raw_label: min_t = 75
                elif '90+' in raw_label: min_t = 90
                elif '110+' in raw_label: min_t = 110
                elif '130+' in raw_label: min_t = 130
                else: min_t = 0
                
                key = ('Maruti Wagonr Tour H3 CNG', utype, dtype)
                if key not in blr_groups: blr_groups[key] = []
                blr_groups[key].append((min_t, rent))

            for (model, utype, dtype), tier_list in blr_groups.items():
                tier_list.sort(key=lambda x: x[0])
                for i in range(len(tier_list)):
                    curr_min, curr_rent = tier_list[i]
                    next_min = tier_list[i+1][0] if i + 1 < len(tier_list) else 10000
                    curr_max = (next_min - 1) if next_min < 10000 else 9999
                    label = f"{curr_min}-{curr_max}" if curr_max < 9999 else f"{curr_min}+"
                    add_slab('Bengaluru', model, utype, 'Uber Reducing Rent', dtype, label, curr_min, curr_max, curr_rent)

            # BLR All Platform (Columns F to H)
            for r in list(ws_blr_s.iter_rows(values_only=True))[1:2]:
                if len(r) > 6 and r[6] is not None:
                    try:
                        rent = float(r[6])
                        add_slab('Bengaluru', 'Maruti Wagonr Tour H3 CNG', 'TBS', 'All Platform', 'All', '0+', 0, 9999, rent, 'All Platform', 'yes')
                    except: pass

        upsert_slab_sql = """
        INSERT INTO sheet_rental_slabs (
            city, vehicle_model, uber_type, plan_scheme, driver_type, trip_slab_label, min_trips, max_trips, daily_rent, daily_indemnity, platform, pass_on_incentive, last_synced_at
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP)
        ON CONFLICT (city, vehicle_model, uber_type, plan_scheme, driver_type, min_trips) DO UPDATE SET
            trip_slab_label = EXCLUDED.trip_slab_label,
            max_trips = EXCLUDED.max_trips,
            daily_rent = EXCLUDED.daily_rent,
            daily_indemnity = EXCLUDED.daily_indemnity,
            platform = EXCLUDED.platform,
            pass_on_incentive = EXCLUDED.pass_on_incentive,
            last_synced_at = CURRENT_TIMESTAMP;
        """
        for s in slabs:
            cur.execute(upsert_slab_sql, s)

        conn.commit()
        cur.close()
        return {
            "status": "success",
            "partners_synced": len(partners),
            "slabs_synced": len(slabs)
        }
    finally:
        conn.close()

@functions_framework.http
def sync_rental_sheets_http(request):
    try:
        res = sync_rental_data()
        return res, 200
    except Exception as e:
        return {"status": "error", "message": str(e)}, 500

if __name__ == "__main__":
    print("Running local synchronization test...")
    res = sync_rental_data()
    print("Sync result:", res)
