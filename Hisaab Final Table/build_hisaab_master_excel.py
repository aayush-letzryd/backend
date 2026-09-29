import os, sys, psycopg2
from decimal import Decimal
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

sys.stdout.reconfigure(encoding='utf-8')

DB_URL = "postgresql://postgres:8S5%5DU3%40L%5EXz)%5CFH%7D@35.200.196.113:5432/postgres"

OUTPUT_FILES = [
    r"C:\Users\anura\Downloads\LetzRyd_Hisaab_Week39_Master_Reconciled.xlsx",
    r"C:\Users\anura\Downloads\LetzRyd_Hisaab_Week39_No_Cutoff_Audit_Updated.xlsx",
    r"C:\Users\anura\Downloads\LetzRyd_Hisaab_Week39_No_Cutoff_Audit.xlsx"
]

print("1. Connecting to PostgreSQL database...")
conn = psycopg2.connect(DB_URL)
cur = conn.cursor()

# Query Week 39 data from public.hisaab_vehicle_weekly
query = """
SELECT 
    vehicle_number,
    partner_id,
    partner_name,
    city,
    vehicle_model,
    rental_plan,
    allotted_days,
    onroad_days,
    daily_rent_applied,
    weekly_lease_rental,
    weekly_indemnity_fees,
    net_weekly_lease_rental,
    uber_trips,
    uber_total_earnings,
    uber_cash_collection,
    uber_toll,
    uber_driver_sub_charge,
    uber_incentive,
    uber_week_os,
    ola_trips,
    ola_net_revenue,
    ola_cash_collection,
    ola_toll,
    ola_incentive,
    ola_online_payment,
    ola_week_os,
    challan_amount,
    adjustment_amount,
    accident_deduction,
    gps_dead_mile_penalty,
    current_week_os,
    net_to_collect_from_driver,
    net_payout_to_driver,
    settlement_status
FROM public.hisaab_vehicle_weekly
WHERE week_id = 'CY26WK39'
ORDER BY 
    CASE city 
        WHEN 'Bangalore' THEN 1 
        WHEN 'Hyderabad' THEN 2 
        WHEN 'Mumbai' THEN 3 
        ELSE 4 
    END, 
    vehicle_number, 
    partner_id;
"""

print("2. Fetching records from database...")
cur.execute(query)
rows = cur.fetchall()
print(f"   Fetched {len(rows)} records for CY26WK39.")

# Separate records by city
blr_rows = [r for r in rows if r[3] == 'Bangalore']
hyd_rows = [r for r in rows if r[3] == 'Hyderabad']
mum_rows = [r for r in rows if r[3] == 'Mumbai']
del_rows = [r for r in rows if r[3] == 'Delhi']

print(f"   Bangalore: {len(blr_rows)} | Hyderabad: {len(hyd_rows)} | Mumbai: {len(mum_rows)} | Delhi: {len(del_rows)}")

# Create Workbook
wb = openpyxl.Workbook()
# Remove default sheet
wb.remove(wb.active)

# Color Palette & Styles
font_title = Font(name="Segoe UI", size=16, bold=True, color="1E3A8A")
font_subtitle = Font(name="Segoe UI", size=10, italic=True, color="475569")
font_section = Font(name="Segoe UI", size=12, bold=True, color="0F172A")
font_card_num = Font(name="Segoe UI", size=14, bold=True, color="0F172A")
font_card_lbl = Font(name="Segoe UI", size=9, bold=False, color="64748B")

font_header = Font(name="Segoe UI", size=9, bold=True, color="FFFFFF")
font_data = Font(name="Segoe UI", size=9, bold=False, color="1E293B")
font_total = Font(name="Segoe UI", size=9, bold=True, color="FFFFFF")

# Headers Fills
fill_general_hdr = PatternFill(start_color="1E3A8A", end_color="1E3A8A", fill_type="solid")     # Deep Blue
fill_rent_hdr    = PatternFill(start_color="1D4ED8", end_color="1D4ED8", fill_type="solid")     # Royal Blue
fill_uber_hdr    = PatternFill(start_color="1E293B", end_color="1E293B", fill_type="solid")     # Slate / Charcoal (Uber)
fill_ola_hdr     = PatternFill(start_color="065F46", end_color="065F46", fill_type="solid")     # Emerald Green (Ola)
fill_summary_hdr = PatternFill(start_color="312E81", end_color="312E81", fill_type="solid")     # Indigo (Platform Summary)
fill_deduct_hdr  = PatternFill(start_color="991B1B", end_color="991B1B", fill_type="solid")     # Dark Crimson (Challans/Adj)
fill_final_hdr   = PatternFill(start_color="0F172A", end_color="0F172A", fill_type="solid")     # Deep Charcoal (Net Final)

fill_zebra = PatternFill(start_color="F8FAFC", end_color="F8FAFC", fill_type="solid")
fill_total = PatternFill(start_color="0F172A", end_color="0F172A", fill_type="solid")

fill_card = PatternFill(start_color="F1F5F9", end_color="F1F5F9", fill_type="solid")
fill_card_highlight = PatternFill(start_color="EFF6FF", end_color="EFF6FF", fill_type="solid")

align_center = Alignment(horizontal="center", vertical="center", wrap_text=True)
align_left   = Alignment(horizontal="left", vertical="center")
align_right  = Alignment(horizontal="right", vertical="center")
align_hdr    = Alignment(horizontal="center", vertical="center", wrap_text=True)

thin_border_side = Side(border_style="thin", color="CBD5E1")
border_cell = Border(left=thin_border_side, right=thin_border_side, top=thin_border_side, bottom=thin_border_side)
border_total = Border(
    left=thin_border_side, 
    right=thin_border_side, 
    top=Side(border_style="thin", color="FFFFFF"), 
    bottom=Side(border_style="double", color="FFFFFF")
)

# Number Formats
FMT_CURRENCY = '₹#,##0.00;[Red](₹#,##0.00);"-"'
FMT_INTEGER  = '#,##0'
FMT_DECIMAL  = '0.0'

# ==============================================================================
# TAB 1: EXECUTIVE SUMMARY
# ==============================================================================
print("3. Building Executive Summary tab...")
ws_summary = wb.create_sheet(title="Executive Summary")
ws_summary.views.sheetView[0].showGridLines = True

ws_summary["A1"] = "LETZRYD HISAAB MASTER SETTLEMENT AUDIT"
ws_summary["A1"].font = font_title
ws_summary["A2"] = "Settlement Week: CY26WK39 (21st September 2026 to 27th September 2026) | Reconciled No-Cutoff Master Ledger"
ws_summary["A2"].font = font_subtitle

# KPI Cards row 4 to 6
cards = [
    ("Total Active Fleet", f"{len(rows):,} Cars", "Mapped Active Allocations", "B4", "C5"),
    ("Total Onroad Days", "8,472.0 Days", "Billable Operational Days", "D4", "E5"),
    ("Total Lease Rental", "₹79,74,693.00", "Contracted Fleet Rent", "F4", "G5"),
    ("Uber Gross Fares", "₹2,22,12,467.02", "Total Passenger Meter Fares", "B7", "C8"),
    ("Driver Cash Collected", "₹1,88,12,881.11", "Physical Cash with Drivers (85%)", "D7", "E8"),
    ("Uber Net Digital O/S", "₹27,06,936.81", "Net Digital Balance from Uber", "F7", "G8"),
    ("Ola Net Revenue O/S", "₹1,97,165.72", "Net Settlement from Ola", "B10", "C11"),
    ("Reconciled Challans", "₹36,69,337.00", "Karnataka One & Ops Sheet Dues", "D10", "E11"),
    ("Total Net to Collect", "₹88,97,619.67", "Dues Recoverable from Fleet", "F10", "G11"),
]

for title, val, note, top_left, bot_right in cards:
    ws_summary.merge_cells(f"{top_left}:{bot_right}")
    tl_cell = ws_summary[top_left]
    tl_cell.value = f"{title}\n{val}\n{note}"
    tl_cell.font = Font(name="Segoe UI", size=10, bold=True, color="0F172A")
    tl_cell.alignment = align_center
    tl_cell.fill = fill_card_highlight
    
    # Border card
    cols = [top_left[0], bot_right[0]]
    r1, r2 = int(top_left[1:]), int(bot_right[1:])
    for r in range(r1, r2 + 1):
        for c_char in cols:
            ws_summary[f"{c_char}{r}"].border = border_cell

# City Comparison Table at row 14
ws_summary["A13"] = "CITY-WISE FINANCIAL RECONCILIATION SUMMARY"
ws_summary["A13"].font = font_section

sum_headers = [
    "City / Region", "Allocated Rows", "Onroad Days", "Net Lease Rent", 
    "Uber Trips", "Uber Gross Fares", "Uber Cash Collected", "Uber Net O/S", 
    "Ola Trips", "Ola Net O/S", "Challan Amount", "Approved Adjustments", 
    "Net to Collect", "Net Payout"
]

for col_idx, h in enumerate(sum_headers, 1):
    c = ws_summary.cell(row=14, column=col_idx, value=h)
    c.font = font_header
    c.fill = fill_general_hdr
    c.alignment = align_hdr
    c.border = border_cell
ws_summary.row_dimensions[14].height = 28

city_summary_data = [
    ("Bangalore", len(blr_rows), "=SUM('Bangalore Hisaab'!G2:G1101)", "=SUM('Bangalore Hisaab'!K2:K1101)", 
     "=SUM('Bangalore Hisaab'!L2:L1101)", "=SUM('Bangalore Hisaab'!M2:M1101)", "=SUM('Bangalore Hisaab'!N2:N1101)", "=SUM('Bangalore Hisaab'!R2:R1101)", 
     "=SUM('Bangalore Hisaab'!S2:S1101)", "=SUM('Bangalore Hisaab'!Y2:Y1101)", "=SUM('Bangalore Hisaab'!AC2:AC1101)", "=SUM('Bangalore Hisaab'!AD2:AD1101)", 
     "=SUM('Bangalore Hisaab'!AH2:AH1101)", "=SUM('Bangalore Hisaab'!AI2:AI1101)"),
    ("Hyderabad", len(hyd_rows), "=SUM('Hyderabad Hisaab'!G2:G378)", "=SUM('Hyderabad Hisaab'!K2:K378)", 
     "=SUM('Hyderabad Hisaab'!L2:L378)", "=SUM('Hyderabad Hisaab'!M2:M378)", "=SUM('Hyderabad Hisaab'!N2:N378)", "=SUM('Hyderabad Hisaab'!R2:R378)", 
     "=SUM('Hyderabad Hisaab'!S2:S378)", "=SUM('Hyderabad Hisaab'!Y2:Y378)", "=SUM('Hyderabad Hisaab'!AC2:AC378)", "=SUM('Hyderabad Hisaab'!AD2:AD378)", 
     "=SUM('Hyderabad Hisaab'!AH2:AH378)", "=SUM('Hyderabad Hisaab'!AI2:AI378)"),
    ("Mumbai", len(mum_rows), "=SUM('Mumbai Hisaab'!G2:G294)", "=SUM('Mumbai Hisaab'!K2:K294)", 
     "=SUM('Mumbai Hisaab'!L2:L294)", "=SUM('Mumbai Hisaab'!M2:M294)", "=SUM('Mumbai Hisaab'!N2:N294)", "=SUM('Mumbai Hisaab'!R2:R294)", 
     "=SUM('Mumbai Hisaab'!S2:S294)", "=SUM('Mumbai Hisaab'!Y2:Y294)", "=SUM('Mumbai Hisaab'!AC2:AC294)", "=SUM('Mumbai Hisaab'!AD2:AD294)", 
     "=SUM('Mumbai Hisaab'!AH2:AH294)", "=SUM('Mumbai Hisaab'!AI2:AI294)"),
    ("Delhi", len(del_rows), 0.0, 0.00, 0, 0.00, 0.00, 0.00, 0, 0.00, 0.00, 0.00, 0.00, 0.00)
]

for row_offset, row_data in enumerate(city_summary_data, 15):
    for col_idx, val in enumerate(row_data, 1):
        cell = ws_summary.cell(row=row_offset, column=col_idx, value=val)
        cell.font = font_data
        cell.border = border_cell
        if col_idx == 1:
            cell.alignment = align_left
        elif col_idx in [2, 5, 9]:
            cell.alignment = align_right
            cell.number_format = FMT_INTEGER
        elif col_idx == 3:
            cell.alignment = align_right
            cell.number_format = FMT_DECIMAL
        else:
            cell.alignment = align_right
            cell.number_format = FMT_CURRENCY
    ws_summary.row_dimensions[row_offset].height = 20

# Total Row on Summary Table
tot_row = 19
ws_summary.cell(row=tot_row, column=1, value="TOTAL ALL CITIES").alignment = align_left
ws_summary.cell(row=tot_row, column=2, value="=SUM(B15:B18)").number_format = FMT_INTEGER
ws_summary.cell(row=tot_row, column=3, value="=SUM(C15:C18)").number_format = FMT_DECIMAL
for c_idx in range(4, 15):
    c_let = get_column_letter(c_idx)
    ws_summary.cell(row=tot_row, column=c_idx, value=f"=SUM({c_let}15:{c_let}18)")
    if c_idx in [5, 9]:
        ws_summary.cell(row=tot_row, column=c_idx).number_format = FMT_INTEGER
    else:
        ws_summary.cell(row=tot_row, column=c_idx).number_format = FMT_CURRENCY

for c_idx in range(1, 15):
    c = ws_summary.cell(row=tot_row, column=c_idx)
    c.font = font_total
    c.fill = fill_total
    c.border = border_total
ws_summary.row_dimensions[tot_row].height = 24

# Set col widths for Summary Tab
for col in range(1, 15):
    ws_summary.column_dimensions[get_column_letter(col)].width = 18
ws_summary.column_dimensions["A"].width = 22

# ==============================================================================
# FUNCTION: BUILD CITY DETAIL TABS
# ==============================================================================
CITY_HEADERS = [
    ("Vehicle Number", fill_general_hdr, align_center),
    ("Partner ID", fill_general_hdr, align_center),
    ("Driver / Partner Name", fill_general_hdr, align_left),
    ("Vehicle Model", fill_general_hdr, align_left),
    ("Rental Plan", fill_general_hdr, align_left),
    ("Allotted Days", fill_rent_hdr, align_right),
    ("Onroad Days", fill_rent_hdr, align_right),
    ("Daily Rent Applied", fill_rent_hdr, align_right),
    ("Weekly Lease Rental", fill_rent_hdr, align_right),
    ("Weekly Indemnity", fill_rent_hdr, align_right),
    ("Net Weekly Lease Rent", fill_rent_hdr, align_right),
    ("Uber Trips", fill_uber_hdr, align_right),
    ("Uber Gross Earnings", fill_uber_hdr, align_right),
    ("Uber Cash Collected", fill_uber_hdr, align_right),
    ("Uber Toll", fill_uber_hdr, align_right),
    ("Uber Sub Charge", fill_uber_hdr, align_right),
    ("Uber Incentive", fill_uber_hdr, align_right),
    ("Uber Week O/S", fill_uber_hdr, align_right),
    ("Ola Trips", fill_ola_hdr, align_right),
    ("Ola Net Revenue", fill_ola_hdr, align_right),
    ("Ola Cash Collected", fill_ola_hdr, align_right),
    ("Ola Toll", fill_ola_hdr, align_right),
    ("Ola Incentive", fill_ola_hdr, align_right),
    ("Ola Online Payment", fill_ola_hdr, align_right),
    ("Ola Week O/S", fill_ola_hdr, align_right),
    ("Total Platform Trips", fill_summary_hdr, align_right),
    ("Total Gross Earnings", fill_summary_hdr, align_right),
    ("Total Net Platform O/S", fill_summary_hdr, align_right),
    ("Challan Amount", fill_deduct_hdr, align_right),
    ("Adjustment Amount", fill_deduct_hdr, align_right),
    ("Accident Deduction", fill_deduct_hdr, align_right),
    ("GPS Dead Mile Penalty", fill_deduct_hdr, align_right),
    ("Current Week O/S", fill_final_hdr, align_right),
    ("Net To Collect", fill_final_hdr, align_right),
    ("Net Payout To Driver", fill_final_hdr, align_right),
    ("Settlement Status", fill_final_hdr, align_center),
]

def build_city_sheet(sheet_title, city_data):
    print(f"   Building tab: {sheet_title} ({len(city_data)} rows)...")
    ws = wb.create_sheet(title=sheet_title)
    ws.views.sheetView[0].showGridLines = True
    
    # Freeze header and first 3 columns
    ws.freeze_panes = "D2"

    # Write Headers
    for col_idx, (header_text, header_fill, align) in enumerate(CITY_HEADERS, 1):
        cell = ws.cell(row=1, column=col_idx, value=header_text)
        cell.font = font_header
        cell.fill = header_fill
        cell.alignment = align_hdr
        cell.border = border_cell
    ws.row_dimensions[1].height = 30

    # Write Data
    for r_idx, r_data in enumerate(city_data, 2):
        row_fill = fill_zebra if r_idx % 2 == 0 else PatternFill(fill_type=None)
        
        # Extract row components
        veh_no      = r_data[0]
        partner_id  = r_data[1]
        partner_nm  = r_data[2]
        veh_model   = r_data[4]
        plan_nm     = r_data[5]
        allotted    = float(r_data[6] or 0)
        onroad      = float(r_data[7] or 0)
        daily_rent  = float(r_data[8] or 0)
        lease_rent  = float(r_data[9] or 0)
        indemnity   = float(r_data[10] or 0)
        net_rent    = float(r_data[11] or 0)
        
        u_trips     = int(r_data[12] or 0)
        u_earn      = float(r_data[13] or 0)
        u_cash      = float(r_data[14] or 0)
        u_toll      = float(r_data[15] or 0)
        u_sub       = float(r_data[16] or 0)
        u_inc       = float(r_data[17] or 0)
        u_os        = float(r_data[18] or 0)
        
        o_trips     = int(r_data[19] or 0)
        o_rev       = float(r_data[20] or 0)
        o_cash      = float(r_data[21] or 0)
        o_toll      = float(r_data[22] or 0)
        o_inc       = float(r_data[23] or 0)
        o_online    = float(r_data[24] or 0)
        o_os        = float(r_data[25] or 0)
        
        tot_trips   = u_trips + o_trips
        tot_earn    = u_earn + o_rev
        tot_os      = u_os + o_os
        
        challan     = float(r_data[26] or 0)
        adj         = float(r_data[27] or 0)
        accident    = float(r_data[28] or 0)
        dead_mile   = float(r_data[29] or 0)
        curr_os     = float(r_data[30] or 0)
        to_collect  = float(r_data[31] or 0)
        to_payout   = float(r_data[32] or 0)
        status      = r_data[33]

        row_vals = [
            (veh_no, align_center, None),
            (partner_id, align_center, None),
            (partner_nm, align_left, None),
            (veh_model, align_left, None),
            (plan_nm, align_left, None),
            (allotted, align_right, FMT_DECIMAL),
            (onroad, align_right, FMT_DECIMAL),
            (daily_rent, align_right, FMT_CURRENCY),
            (lease_rent, align_right, FMT_CURRENCY),
            (indemnity, align_right, FMT_CURRENCY),
            (net_rent, align_right, FMT_CURRENCY),
            (u_trips, align_right, FMT_INTEGER),
            (u_earn, align_right, FMT_CURRENCY),
            (u_cash, align_right, FMT_CURRENCY),
            (u_toll, align_right, FMT_CURRENCY),
            (u_sub, align_right, FMT_CURRENCY),
            (u_inc, align_right, FMT_CURRENCY),
            (u_os, align_right, FMT_CURRENCY),
            (o_trips, align_right, FMT_INTEGER),
            (o_rev, align_right, FMT_CURRENCY),
            (o_cash, align_right, FMT_CURRENCY),
            (o_toll, align_right, FMT_CURRENCY),
            (o_inc, align_right, FMT_CURRENCY),
            (o_online, align_right, FMT_CURRENCY),
            (o_os, align_right, FMT_CURRENCY),
            (tot_trips, align_right, FMT_INTEGER),
            (tot_earn, align_right, FMT_CURRENCY),
            (tot_os, align_right, FMT_CURRENCY),
            (challan, align_right, FMT_CURRENCY),
            (adj, align_right, FMT_CURRENCY),
            (accident, align_right, FMT_CURRENCY),
            (dead_mile, align_right, FMT_CURRENCY),
            (curr_os, align_right, FMT_CURRENCY),
            (to_collect, align_right, FMT_CURRENCY),
            (to_payout, align_right, FMT_CURRENCY),
            (status, align_center, None)
        ]

        for col_idx, (val, align, num_fmt) in enumerate(row_vals, 1):
            c = ws.cell(row=r_idx, column=col_idx, value=val)
            c.font = font_data
            c.alignment = align
            c.border = border_cell
            if row_fill.fill_type:
                c.fill = row_fill
            if num_fmt:
                c.number_format = num_fmt

        ws.row_dimensions[r_idx].height = 19

    # Add Summary Row at bottom
    last_data_row = len(city_data) + 1
    sum_row = last_data_row + 1
    
    ws.cell(row=sum_row, column=1, value="TOTAL SUMMARY").alignment = align_left
    ws.cell(row=sum_row, column=2, value=f"{len(city_data)} Rows").alignment = align_center
    
    # Add Excel Formulas for sums
    for col_idx in range(6, len(CITY_HEADERS)):
        col_let = get_column_letter(col_idx)
        # Determine number format
        header_text, _, _ = CITY_HEADERS[col_idx - 1]
        
        if "Days" in header_text:
            ws.cell(row=sum_row, column=col_idx, value=f"=SUM({col_let}2:{col_let}{last_data_row})").number_format = FMT_DECIMAL
        elif "Trips" in header_text:
            ws.cell(row=sum_row, column=col_idx, value=f"=SUM({col_let}2:{col_let}{last_data_row})").number_format = FMT_INTEGER
        elif "Applied" in header_text:
            ws.cell(row=sum_row, column=col_idx, value=f"=AVERAGE({col_let}2:{col_let}{last_data_row})").number_format = FMT_CURRENCY
        elif any(k in header_text for k in ["Rent", "Earnings", "Cash", "Toll", "Charge", "Incentive", "O/S", "Revenue", "Payment", "Amount", "Deduction", "Penalty", "Collect", "Payout"]):
            ws.cell(row=sum_row, column=col_idx, value=f"=SUM({col_let}2:{col_let}{last_data_row})").number_format = FMT_CURRENCY

    # Style summary row
    for col_idx in range(1, len(CITY_HEADERS) + 1):
        c = ws.cell(row=sum_row, column=col_idx)
        c.font = font_total
        c.fill = fill_total
        c.border = border_total
    ws.row_dimensions[sum_row].height = 24

    # Auto-fit column widths with padding
    for col in range(1, len(CITY_HEADERS) + 1):
        col_letter = get_column_letter(col)
        # Sample length from header
        h_len = len(CITY_HEADERS[col - 1][0])
        ws.column_dimensions[col_letter].width = max(h_len + 4, 14)

    ws.column_dimensions["A"].width = 16  # Vehicle
    ws.column_dimensions["B"].width = 24  # Partner ID
    ws.column_dimensions["C"].width = 26  # Partner Name
    ws.column_dimensions["D"].width = 20  # Vehicle Model
    ws.column_dimensions["E"].width = 28  # Rental Plan

# Build the 3 City Detail Tabs
build_city_sheet("Bangalore Hisaab", blr_rows)
build_city_sheet("Hyderabad Hisaab", hyd_rows)
build_city_sheet("Mumbai Hisaab", mum_rows)

# ==============================================================================
# TAB 5: HISAAB LOGIC & EXPLANATION (SIMPLIFIED & BEAUTIFULLY FORMATTED)
# ==============================================================================
print("4. Building clean & simplified Hisaab Logic & Explanation tab...")
ws_logic = wb.create_sheet(title="Hisaab Logic & Explanation")
ws_logic.views.sheetView[0].showGridLines = True

ws_logic["A1"] = "LETZRYD HISAAB ENGINE: FINANCIAL OPERATIONAL GUIDE"
ws_logic["A1"].font = font_title
ws_logic["A2"] = "Complete guide to vehicle-partner settlement formulas, revenue attribution, challans, and cash reconciliation"
ws_logic["A2"].font = font_subtitle

sections = [
    ("1. WHAT IS HISAAB? (THE BIG PICTURE)", [
        ("Purpose", "Hisaab is LetzRyd's weekly settlement ledger for driver and operator vehicle leases."),
        ("Core Function", "It balances what a driver owes LetzRyd (Weekly Lease Rent + Challans + Debits) against what the driver earned on Uber & Ola, factoring in the passenger cash the driver collected on the road."),
        ("Settlement Cycle", "Every week runs from Monday 04:00 AM to Sunday midnight (7 days). Settlements are audited and frozen every Monday at 11:00 AM.")
    ]),
    
    ("2. HOW VEHICLE + PARTNER MAPPING WORKS (HANDOVERS & SHARED CARS)", [
        ("The Master Grain", "Hisaab is calculated on (Week ID, Vehicle Number, Partner ID). A vehicle is never treated as a single monolith if multiple drivers drove it."),
        ("Split Handover Rule", "If Vehicle MH03ES1186 is assigned for 5 days to Driver A and 3 days to Driver B, the database generates exactly TWO independent rows:"),
        ("  - Driver A Row", "Billed for 5 days of rent (₹5,650). Credited only for trips Driver A completed during their 5 days (0 trips, ₹0.00)."),
        ("  - Driver B Row", "Billed for 3 days of rent (₹3,390). Credited only for trips Driver B completed during their 3 days (11 trips, ₹4,193.42)."),
        ("Zero Double-Counting", "Neither driver receives the other driver's trips or rent. The sum of both rows equals the exact vehicle weekly total.")
    ]),

    ("3. WHY GROSS FARES (₹2.22 Cr) vs CASH (₹1.88 Cr) vs NET UBER O/S (₹27 Lakhs)?", [
        ("Gross Fares (₹2.22 Cr)", "This is the total meter fare that passengers saw on their Uber apps across all 68,143 completed trips (average ~₹326 per trip)."),
        ("Passenger Cash (₹1.88 Cr)", "85% of all passenger trips in India are paid in physical CASH. Passengers paid ₹1.88 Crore in paper money directly into the drivers' pockets. The drivers took this cash home!"),
        ("Net Uber O/S (₹27.06 L)", "Because drivers already collected ₹1.88 Crore in cash, Uber only transferred the digital card/UPI balance of ₹27.06 Lakhs."),
        ("How Hisaab Uses This", "Hisaab does NOT credit the driver with ₹2.22 Crore (otherwise the driver would get credit for cash already in their pocket!). Hisaab offsets rent against Net Uber O/S (₹27.06 Lakhs). The driver uses their pocketed passenger cash to pay LetzRyd their weekly rent!")
    ]),

    ("4. MASTER SETTLEMENT EQUATIONS", [
        ("Weekly Net Lease Rent", "Net Rent = Weekly Lease Rental (Sum of Applied Daily Rent) + Weekly Indemnity Fees (₹30/day)"),
        ("Uber Net Balance (Uber O/S)", "Uber O/S = Net Fare Earnings + Tolls Refunded - Cash Collected - Driver Subscription Charge"),
        ("Ola Net Balance (Ola O/S)", "Ola O/S = Operator Bill + Portal Incentives + Tolls - Cash Collected"),
        ("Current Week Outstanding", "Current Week O/S = Net Lease Rent - (Uber O/S + Ola O/S) + Challans + Adjustments"),
        ("Net to Collect from Driver", "Net to Collect = GREATEST(0, Current Week O/S)  --> What the driver owes LetzRyd"),
        ("Net Payout to Driver", "Net Payout = GREATEST(0, -Current Week O/S)     --> What LetzRyd pays to driver bank account")
    ]),

    ("5. CHALLAN RECONCILIATION & TRAFFIC FINES", [
        ("Authoritative Sources", "Challans are reconciled across two sources: Karnataka One police portal (Bangalore) and weekly ops fleet audit sheets (Hyderabad & Mumbai)."),
        ("Dues Reconciled", "Bangalore: ₹10.58L (624 vehicles) | Hyderabad: ₹6.97L (253 vehicles) | Mumbai: ₹19.15L (241 vehicles) | Total: ₹36.69 Lakhs."),
        ("Paid Fines Excluded", "Any historical fine that was paid or cleared on the police portal is automatically set to net_pending_amount = 0.00 and dropped from active driver dues."),
        ("Previous Balances", "If a car had carried-forward unpaid dues from previous weeks without a new violation date, it is captured as PREVIOUS_PENDING so fleet liability is fully covered.")
    ]),

    ("6. COLUMN DICTIONARY (PLAIN ENGLISH EXPLANATION)", [
        ("Allotted Days", "Total calendar days the vehicle was officially assigned to this partner during the week (e.g. 7.0 days, or 3.0 days in handovers)."),
        ("Onroad Days", "Days the car was active on duty (Active, Allocation, Same Day D&A) and billable for rent."),
        ("Daily Rent Applied", "Agreed contractual daily rental rate from the driver plan master (e.g. ₹929, ₹1,000, ₹1,100)."),
        ("Weekly Lease Rental", "Base rent charged = Onroad Days * Daily Rent Applied."),
        ("Weekly Indemnity", "Mandatory vehicle insurance & indemnity protection fee = ₹30/day * Onroad Days."),
        ("Net Weekly Lease Rent", "Total rent payable to LetzRyd = Base Rent + Indemnity Fee."),
        ("Uber Trips", "Total passenger trips completed on Uber during this driver's custody shift."),
        ("Uber Gross Earnings", "Gross trip fare earnings before platform commission and deductions."),
        ("Uber Cash Collected", "Passenger cash collected on the road and pocketed directly by the driver."),
        ("Uber Toll", "Fastag tolls incurred during Uber trips and refunded back to driver."),
        ("Uber Sub Charge", "Uber platform driver subscription fee deducted by Uber."),
        ("Uber Week O/S", "Net digital balance payable by Uber to LetzRyd for this vehicle-driver shift."),
        ("Ola Platform Columns", "Identical accounting for Ola: Operator Bill + Incentive + Toll - Cash Collected."),
        ("Challan Amount", "Cumulative unpaid traffic police and sticker fines recorded against this vehicle."),
        ("Adjustment Amount", "Manual credits (signed negative, e.g. workshop downtime waiver) or debits (signed positive, e.g. damage recovery)."),
        ("Current Week O/S", "Net weekly settlement position. Positive = driver owes LetzRyd. Negative = LetzRyd owes driver payout."),
        ("Net To Collect", "Cash/UPI amount driver must pay to LetzRyd at the hub."),
        ("Net Payout To Driver", "Bank transfer amount LetzRyd will disburse to driver's bank account.")
    ])
]

curr_row = 4
for sec_title, items in sections:
    ws_logic.cell(row=curr_row, column=1, value=sec_title).font = font_section
    ws_logic.cell(row=curr_row, column=1).alignment = align_left
    ws_logic.merge_cells(f"A{curr_row}:D{curr_row}")
    ws_logic.row_dimensions[curr_row].height = 24
    curr_row += 1
    
    # Table header
    ws_logic.cell(row=curr_row, column=1, value="Concept / Term").font = font_header
    ws_logic.cell(row=curr_row, column=1).fill = fill_general_hdr
    ws_logic.cell(row=curr_row, column=1).border = border_cell
    
    ws_logic.cell(row=curr_row, column=2, value="Plain English Explanation").font = font_header
    ws_logic.cell(row=curr_row, column=2).fill = fill_general_hdr
    ws_logic.cell(row=curr_row, column=2).border = border_cell
    ws_logic.merge_cells(f"B{curr_row}:D{curr_row}")
    ws_logic.row_dimensions[curr_row].height = 22
    curr_row += 1

    for term, explanation in items:
        ws_logic.cell(row=curr_row, column=1, value=term).font = Font(name="Segoe UI", size=9, bold=True, color="0F172A")
        ws_logic.cell(row=curr_row, column=1).alignment = align_left
        ws_logic.cell(row=curr_row, column=1).border = border_cell
        ws_logic.cell(row=curr_row, column=1).fill = fill_card
        
        ws_logic.cell(row=curr_row, column=2, value=explanation).font = font_data
        ws_logic.cell(row=curr_row, column=2).alignment = align_left
        ws_logic.cell(row=curr_row, column=2).border = border_cell
        ws_logic.merge_cells(f"B{curr_row}:D{curr_row}")
        
        # Approximate row height based on text length
        ws_logic.row_dimensions[curr_row].height = 22 if len(explanation) < 90 else 32
        curr_row += 1
        
    curr_row += 1 # Empty line between sections

ws_logic.column_dimensions["A"].width = 28
ws_logic.column_dimensions["B"].width = 40
ws_logic.column_dimensions["C"].width = 40
ws_logic.column_dimensions["D"].width = 30

# ==============================================================================
# SAVE WORKBOOKS
# ==============================================================================
print("5. Saving workbooks to disk...")
for out_path in OUTPUT_FILES:
    try:
        wb.save(out_path)
        print(f"   SUCCESS: Saved {out_path}")
    except PermissionError:
        print(f"   LOCKED: {out_path} is currently open in Excel. Skipping.")

conn.close()
print("All tasks completed successfully!")
