"""
sheet_config.py — Google Sheets URL Configuration for LetzRyd Backend
======================================================================
Central configuration file containing hardcoded Google Sheet URLs, Sheet tab names,
and local CSV fallback file paths used by load_google_sheets_to_core.py.
"""

SHEET_CONFIG = {
    # 1. Driver Onboarding KYC (Onboarding form_V2)
    "driver_onboarding": {
        "url": "https://docs.google.com/spreadsheets/d/1ix6iKa9nEh4li44ZRcpkAvEMLo4r94mT4VbwRCfNZIM/export?format=csv&gid=1460662046",
        "sheet_tab": "Onboarding form_V2",
        "description": "Driver KYC, Aadhaar, Driving License, emergency contacts, banking, and deposit paid."
    },

    # 2. Driver Profile Master (Walk In Form)
    "drivers": {
        "url": "https://docs.google.com/spreadsheets/d/1ix6iKa9nEh4li44ZRcpkAvEMLo4r94mT4VbwRCfNZIM/export?format=csv&gid=2075911242",
        "sheet_tab": "Walk In Form",
        "description": "Master driver registry, profile status, and walk-in lead IDs."
    },

    # 3. Fleet Operator / Partner Master (Operator Details)
    "partners": {
        "url": "https://docs.google.com/spreadsheets/d/17Q7ReT4BxOmSrBXToF4Y7eihwRehWFyP/edit",
        "export_xlsx_url": "https://docs.google.com/spreadsheets/d/17Q7ReT4BxOmSrBXToF4Y7eihwRehWFyP/export?format=xlsx",
        "sheet_tab": "One time Onborading details",
        "description": "Fleet operators, business names, partner codes, phone, and security deposits."
    },

    # 4. Fleet Vehicle Inventory (Vehicle Master — 3 City Tabs: BLR, HYD, MUM)
    "vehicles": {
        "url": "https://docs.google.com/spreadsheets/d/1hfV8f_r_si-_De8jzeTj8PWOZqmZL8H1/edit",
        "export_xlsx_url": "https://docs.google.com/spreadsheets/d/1hfV8f_r_si-_De8jzeTj8PWOZqmZL8H1/export?format=xlsx",
        "sheet_tab": "BLR, HYD, MUM (3 City Tabs)",
        "city_tabs": ["BLR", "HYD", "MUM"],
        "description": "Vehicle master: Make, Model, VIN, Chassis No, RC status across Bangalore, Hyderabad, and Mumbai."
    },

    # 5. Driver-to-Vehicle Allocations (Live Allocation Sheet)
    "vehicle_assignments": {
        "url": "https://docs.google.com/spreadsheets/d/17Q7ReT4BxOmSrBXToF4Y7eihwRehWFyP/edit",
        "export_xlsx_url": "https://docs.google.com/spreadsheets/d/17Q7ReT4BxOmSrBXToF4Y7eihwRehWFyP/export?format=xlsx",
        "sheet_tab": "Vehicle wise Allocation data",
        "description": "Driver-to-vehicle live allocations, assignment dates, plan types, and vehicle links."
    },

    # 6. Daily Rent Tariffs (3 City Rental Sheets: BLR, HYD, MUM)
    "rents": {
        "url": "https://docs.google.com/spreadsheets/d/105mqBq3XVux4DjCbZMbPG3sQfJ8fLTwiox7kMhtq4QQ/edit?gid=1748671540",
        "city_urls": {
            "HYD": "https://docs.google.com/spreadsheets/d/105mqBq3XVux4DjCbZMbPG3sQfJ8fLTwiox7kMhtq4QQ/export?format=xlsx",
            "MUM": "https://docs.google.com/spreadsheets/d/1H6dmsq7rZTCZJNe8jRziNtR8A5Y2yXa7/export?format=xlsx",
            "BLR": "https://docs.google.com/spreadsheets/d/1rtJD9mVyGrEeHUHqVCq_Af1daE69cP1lnNGZe57qMaQ/export?format=xlsx"
        },
        "sheet_tab": "Multi-City Rental Sheets (BLR, HYD, MUM)",
        "description": "Daily rental rates and reducing rent slabs per vehicle model across cities."
    },

    # 7. Traffic Violations (Challan Sheet)
    "challan_logs": {
        "url": "https://docs.google.com/spreadsheets/d/1QZV0lV_71w68LjVpo_EdWfXYPcwcRcZa/export?format=csv&gid=689133930",
        "export_xlsx_url": "https://docs.google.com/spreadsheets/d/1QZV0lV_71w68LjVpo_EdWfXYPcwcRcZa/export?format=xlsx",
        "sheet_tab": "Challan",
        "description": "Traffic violation fines, challan numbers, dates, and amounts."
    },

    # 8. Accidents and Repairs (Daily Vehicle Status V2)
    "accidents": {
        "url": "https://docs.google.com/spreadsheets/d/1ARYLDpvIrzKLVB48Xx9WUauIGGCc4_K4Zg56BCoZsXw/export?format=xlsx",
        "export_xlsx_url": "https://docs.google.com/spreadsheets/d/1ARYLDpvIrzKLVB48Xx9WUauIGGCc4_K4Zg56BCoZsXw/export?format=xlsx",
        "sheet_tab": "Daily Vehicle Status V2",
        "description": "Accident repair estimate amounts and penalty deductions."
    },

    # 9. Operational & Finance Adjustments (Adjustment-Form)
    "adjustment_logs": {
        "url": "https://docs.google.com/spreadsheets/d/18Fbk-T2_yIS_hz7xkqvREQPLdOH8TXbFgo_dbMSS_d4/export?format=xlsx",
        "export_xlsx_url": "https://docs.google.com/spreadsheets/d/18Fbk-T2_yIS_hz7xkqvREQPLdOH8TXbFgo_dbMSS_d4/export?format=xlsx",
        "sheet_tab": "Adjustment Response",
        "description": "Manual rent-offs, bonus incentives, and adjustments."
    }
}
