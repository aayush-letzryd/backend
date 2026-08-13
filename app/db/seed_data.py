"""
seed_data.py — Master Seed Data Script for LetzRyd Backend
===========================================================
Populates 5 Operators and 15 Drivers (3 Drivers per Operator), with full
relational linkage, profile metadata, raw platform trip data, deductions, deposits,
and triggers the raw platform data aggregation engine to generate app_hisaabs and calculate
weekly fleet/driver metrics with ZERO NULL values.
"""

import sys
from pathlib import Path
from datetime import date, datetime

sys.path.append(str(Path(__file__).resolve().parent.parent.parent))

from app.database import SessionLocal, engine
from app.models.app_models import AppDrivers, AppOperators, AppHisaabs, Base
from app.services.platform_aggregator import aggregate_raw_platform_data
from sqlalchemy import text

def seed_database():
    db = SessionLocal()
    print("=== SEEDING DEVELOPMENT MASTER DEMO DATA (ZERO NULLS) ===")

    try:
        # Clear existing table data to allow clean re-seeding
        print("Clearing old demo data...")
        db.execute(text("DELETE FROM app_hisaabs;"))
        db.execute(text("DELETE FROM app_drivers;"))
        db.execute(text("DELETE FROM app_operators;"))
        db.execute(text("DELETE FROM raw_uber_data;"))
        db.execute(text("DELETE FROM raw_ola_data;"))
        db.execute(text("DELETE FROM raw_rapido_data;"))
        db.execute(text("DELETE FROM raw_uber_incentives;"))
        db.execute(text("DELETE FROM raw_ola_incentives;"))
        db.execute(text("DELETE FROM raw_rapido_incentives;"))
        db.execute(text("DELETE FROM raw_traffic_challans;"))
        db.execute(text("DELETE FROM raw_accidents_registry;"))
        db.execute(text("DELETE FROM raw_partner_adjustments;"))
        db.execute(text("DELETE FROM raw_gps_logs;"))
        db.commit()

        now = datetime(2026, 8, 13, 10, 0, 0)
        today = date(2026, 8, 13)

        # 1. Create 5 Operators with complete profile metadata (No NULLs)
        operators_data = [
            {
                "operator_id": 201, "app_driver_id": 0, "operator_code": "OPR-HYD-001", "operator_type": "fleet_owner",
                "phone": "9848011111", "company_name": "Venkateswara Fleet Operators", "contact_person_name": "Venkateswara Rao",
                "initials": "VF", "total_vehicles": 3, "active_vehicles": 3, "idle_vehicles": 0, "total_drivers": 3,
                "deposit_total_req": 30000.00, "deposit_paid": 25000.00, "deposit_pending": 5000.00,
                "assigned_manager_name": "Kiran Kumar", "assigned_manager_phone": "9988776655", "referral_code": "VENKAT2026",
                "referral_reward_amt": 1000.00, "upi_id": "venkateswara@upi", "bank_account_last4": "1122",
                "preferred_language": "te", "is_active": True,
                "address": "Plot 42, Hitech City Main Rd, Madhapur, Hyderabad, Telangana 500081",
                "contract_terms_url": "https://cdn.letzryd.com/agreements/OPR-HYD-001.pdf",
                "password_hash": "pbkdf2_sha256$260000$oprhash201", "fcm_token": "fcm_token_opr_201_xyz1",
                "created_at": now, "last_login_at": now, "last_synced_at": now,
                "cw_fleet_uber_trips": 0, "cw_fleet_uber_revenue": 0.0, "cw_fleet_uber_cash": 0.0, "cw_fleet_uber_incentive": 0.0, "cw_fleet_uber_km": 0.0,
                "cw_fleet_ola_trips": 0, "cw_fleet_ola_revenue": 0.0, "cw_fleet_ola_cash": 0.0, "cw_fleet_ola_incentive": 0.0, "cw_fleet_ola_km": 0.0,
                "cw_fleet_rapido_trips": 0, "cw_fleet_rapido_revenue": 0.0, "cw_fleet_rapido_cash": 0.0, "cw_fleet_rapido_incentive": 0.0, "cw_fleet_rapido_km": 0.0,
                "cw_fleet_rent": 0.0, "cw_fleet_maintenance": 0.0, "cw_fleet_tds": 0.0, "cw_fleet_challans": 0.0, "cw_fleet_gps_dead_km": 0.0, "cw_fleet_gps_dead_penalty": 0.0,
                "cw_fleet_trips": 0, "cw_fleet_km": 0.0, "cw_fleet_gross_earnings": 0.0, "cw_fleet_net_os": 0.0, "cw_to_collect": 0.0, "cw_to_pay": 0.0,
                "cw_active_vehicles": 3, "cw_active_drivers": 3, "lw_fleet_gross_earnings": 31500.0, "lw_fleet_net_os": 29400.0,
                "lw_fleet_trips": 36, "lw_fleet_km": 450.0, "lw_week_number": 27, "lw_hisaab_number": "HIS-2026-027-FLEET1", "lw_status": "settled", "growth_pct": 8.5
            },
            {
                "operator_id": 202, "app_driver_id": 0, "operator_code": "OPR-HYD-002", "operator_type": "fleet_owner",
                "phone": "9848022222", "company_name": "Sri Sai Cabs & Logistics", "contact_person_name": "Satyanarayana Murthy",
                "initials": "SS", "total_vehicles": 3, "active_vehicles": 3, "idle_vehicles": 0, "total_drivers": 3,
                "deposit_total_req": 30000.00, "deposit_paid": 30000.00, "deposit_pending": 0.00,
                "assigned_manager_name": "Rajesh Varma", "assigned_manager_phone": "9988776644", "referral_code": "SAICABS26",
                "referral_reward_amt": 1000.00, "upi_id": "saisaicabs@upi", "bank_account_last4": "3344",
                "preferred_language": "en", "is_active": True,
                "address": "Suite 104, Cyber Towers, Hitech City, Hyderabad, Telangana 500081",
                "contract_terms_url": "https://cdn.letzryd.com/agreements/OPR-HYD-002.pdf",
                "password_hash": "pbkdf2_sha256$260000$oprhash202", "fcm_token": "fcm_token_opr_202_xyz2",
                "created_at": now, "last_login_at": now, "last_synced_at": now,
                "cw_fleet_uber_trips": 0, "cw_fleet_uber_revenue": 0.0, "cw_fleet_uber_cash": 0.0, "cw_fleet_uber_incentive": 0.0, "cw_fleet_uber_km": 0.0,
                "cw_fleet_ola_trips": 0, "cw_fleet_ola_revenue": 0.0, "cw_fleet_ola_cash": 0.0, "cw_fleet_ola_incentive": 0.0, "cw_fleet_ola_km": 0.0,
                "cw_fleet_rapido_trips": 0, "cw_fleet_rapido_revenue": 0.0, "cw_fleet_rapido_cash": 0.0, "cw_fleet_rapido_incentive": 0.0, "cw_fleet_rapido_km": 0.0,
                "cw_fleet_rent": 0.0, "cw_fleet_maintenance": 0.0, "cw_fleet_tds": 0.0, "cw_fleet_challans": 0.0, "cw_fleet_gps_dead_km": 0.0, "cw_fleet_gps_dead_penalty": 0.0,
                "cw_fleet_trips": 0, "cw_fleet_km": 0.0, "cw_fleet_gross_earnings": 0.0, "cw_fleet_net_os": 0.0, "cw_to_collect": 0.0, "cw_to_pay": 0.0,
                "cw_active_vehicles": 3, "cw_active_drivers": 3, "lw_fleet_gross_earnings": 31500.0, "lw_fleet_net_os": 29400.0,
                "lw_fleet_trips": 36, "lw_fleet_km": 450.0, "lw_week_number": 27, "lw_hisaab_number": "HIS-2026-027-FLEET2", "lw_status": "settled", "growth_pct": 8.5
            },
            {
                "operator_id": 203, "app_driver_id": 0, "operator_code": "OPR-HYD-003", "operator_type": "fleet_owner",
                "phone": "9848033333", "company_name": "Kakatiya Urban Mobility", "contact_person_name": "Ramesh Reddy",
                "initials": "KU", "total_vehicles": 3, "active_vehicles": 3, "idle_vehicles": 0, "total_drivers": 3,
                "deposit_total_req": 30000.00, "deposit_paid": 20000.00, "deposit_pending": 10000.00,
                "assigned_manager_name": "Kiran Kumar", "assigned_manager_phone": "9988776655", "referral_code": "KAKATIYA26",
                "referral_reward_amt": 1000.00, "upi_id": "kakatiya@upi", "bank_account_last4": "5566",
                "preferred_language": "te", "is_active": True,
                "address": "Door 12-3-88, Financial District, Nanakramguda, Hyderabad, Telangana 500032",
                "contract_terms_url": "https://cdn.letzryd.com/agreements/OPR-HYD-003.pdf",
                "password_hash": "pbkdf2_sha256$260000$oprhash203", "fcm_token": "fcm_token_opr_203_xyz3",
                "created_at": now, "last_login_at": now, "last_synced_at": now,
                "cw_fleet_uber_trips": 0, "cw_fleet_uber_revenue": 0.0, "cw_fleet_uber_cash": 0.0, "cw_fleet_uber_incentive": 0.0, "cw_fleet_uber_km": 0.0,
                "cw_fleet_ola_trips": 0, "cw_fleet_ola_revenue": 0.0, "cw_fleet_ola_cash": 0.0, "cw_fleet_ola_incentive": 0.0, "cw_fleet_ola_km": 0.0,
                "cw_fleet_rapido_trips": 0, "cw_fleet_rapido_revenue": 0.0, "cw_fleet_rapido_cash": 0.0, "cw_fleet_rapido_incentive": 0.0, "cw_fleet_rapido_km": 0.0,
                "cw_fleet_rent": 0.0, "cw_fleet_maintenance": 0.0, "cw_fleet_tds": 0.0, "cw_fleet_challans": 0.0, "cw_fleet_gps_dead_km": 0.0, "cw_fleet_gps_dead_penalty": 0.0,
                "cw_fleet_trips": 0, "cw_fleet_km": 0.0, "cw_fleet_gross_earnings": 0.0, "cw_fleet_net_os": 0.0, "cw_to_collect": 0.0, "cw_to_pay": 0.0,
                "cw_active_vehicles": 3, "cw_active_drivers": 3, "lw_fleet_gross_earnings": 31500.0, "lw_fleet_net_os": 29400.0,
                "lw_fleet_trips": 36, "lw_fleet_km": 450.0, "lw_week_number": 27, "lw_hisaab_number": "HIS-2026-027-FLEET3", "lw_status": "settled", "growth_pct": 8.5
            },
            {
                "operator_id": 204, "app_driver_id": 0, "operator_code": "OPR-HYD-004", "operator_type": "fleet_owner",
                "phone": "9848044444", "company_name": "Deccan Roadways Fleet", "contact_person_name": "Syed Ahmed",
                "initials": "DR", "total_vehicles": 3, "active_vehicles": 3, "idle_vehicles": 0, "total_drivers": 3,
                "deposit_total_req": 30000.00, "deposit_paid": 28000.00, "deposit_pending": 2000.00,
                "assigned_manager_name": "Mohammed Ali", "assigned_manager_phone": "9988776633", "referral_code": "DECCAN2026",
                "referral_reward_amt": 1000.00, "upi_id": "deccanfleet@upi", "bank_account_last4": "7788",
                "preferred_language": "hi", "is_active": True,
                "address": "Banjara Hills Road No 12, Hyderabad, Telangana 500034",
                "contract_terms_url": "https://cdn.letzryd.com/agreements/OPR-HYD-004.pdf",
                "password_hash": "pbkdf2_sha256$260000$oprhash204", "fcm_token": "fcm_token_opr_204_xyz4",
                "created_at": now, "last_login_at": now, "last_synced_at": now,
                "cw_fleet_uber_trips": 0, "cw_fleet_uber_revenue": 0.0, "cw_fleet_uber_cash": 0.0, "cw_fleet_uber_incentive": 0.0, "cw_fleet_uber_km": 0.0,
                "cw_fleet_ola_trips": 0, "cw_fleet_ola_revenue": 0.0, "cw_fleet_ola_cash": 0.0, "cw_fleet_ola_incentive": 0.0, "cw_fleet_ola_km": 0.0,
                "cw_fleet_rapido_trips": 0, "cw_fleet_rapido_revenue": 0.0, "cw_fleet_rapido_cash": 0.0, "cw_fleet_rapido_incentive": 0.0, "cw_fleet_rapido_km": 0.0,
                "cw_fleet_rent": 0.0, "cw_fleet_maintenance": 0.0, "cw_fleet_tds": 0.0, "cw_fleet_challans": 0.0, "cw_fleet_gps_dead_km": 0.0, "cw_fleet_gps_dead_penalty": 0.0,
                "cw_fleet_trips": 0, "cw_fleet_km": 0.0, "cw_fleet_gross_earnings": 0.0, "cw_fleet_net_os": 0.0, "cw_to_collect": 0.0, "cw_to_pay": 0.0,
                "cw_active_vehicles": 3, "cw_active_drivers": 3, "lw_fleet_gross_earnings": 31500.0, "lw_fleet_net_os": 29400.0,
                "lw_fleet_trips": 36, "lw_fleet_km": 450.0, "lw_week_number": 27, "lw_hisaab_number": "HIS-2026-027-FLEET4", "lw_status": "settled", "growth_pct": 8.5
            },
            {
                "operator_id": 205, "app_driver_id": 0, "operator_code": "OPR-HYD-005", "operator_type": "fleet_owner",
                "phone": "9848055555", "company_name": "Telangana Smart Fleet", "contact_person_name": "Srinivas Goud",
                "initials": "TS", "total_vehicles": 3, "active_vehicles": 3, "idle_vehicles": 0, "total_drivers": 3,
                "deposit_total_req": 30000.00, "deposit_paid": 30000.00, "deposit_pending": 0.00,
                "assigned_manager_name": "Rajesh Varma", "assigned_manager_phone": "9988776644", "referral_code": "TSMART2026",
                "referral_reward_amt": 1000.00, "upi_id": "tsmartfleet@upi", "bank_account_last4": "9900",
                "preferred_language": "te", "is_active": True,
                "address": "Kukatpally Housing Board Colony, Phase 3, Hyderabad, Telangana 500072",
                "contract_terms_url": "https://cdn.letzryd.com/agreements/OPR-HYD-005.pdf",
                "password_hash": "pbkdf2_sha256$260000$oprhash205", "fcm_token": "fcm_token_opr_205_xyz5",
                "created_at": now, "last_login_at": now, "last_synced_at": now,
                "cw_fleet_uber_trips": 0, "cw_fleet_uber_revenue": 0.0, "cw_fleet_uber_cash": 0.0, "cw_fleet_uber_incentive": 0.0, "cw_fleet_uber_km": 0.0,
                "cw_fleet_ola_trips": 0, "cw_fleet_ola_revenue": 0.0, "cw_fleet_ola_cash": 0.0, "cw_fleet_ola_incentive": 0.0, "cw_fleet_ola_km": 0.0,
                "cw_fleet_rapido_trips": 0, "cw_fleet_rapido_revenue": 0.0, "cw_fleet_rapido_cash": 0.0, "cw_fleet_rapido_incentive": 0.0, "cw_fleet_rapido_km": 0.0,
                "cw_fleet_rent": 0.0, "cw_fleet_maintenance": 0.0, "cw_fleet_tds": 0.0, "cw_fleet_challans": 0.0, "cw_fleet_gps_dead_km": 0.0, "cw_fleet_gps_dead_penalty": 0.0,
                "cw_fleet_trips": 0, "cw_fleet_km": 0.0, "cw_fleet_gross_earnings": 0.0, "cw_fleet_net_os": 0.0, "cw_to_collect": 0.0, "cw_to_pay": 0.0,
                "cw_active_vehicles": 3, "cw_active_drivers": 3, "lw_fleet_gross_earnings": 31500.0, "lw_fleet_net_os": 29400.0,
                "lw_fleet_trips": 36, "lw_fleet_km": 450.0, "lw_week_number": 27, "lw_hisaab_number": "HIS-2026-027-FLEET5", "lw_status": "settled", "growth_pct": 8.5
            }
        ]

        op_objs = []
        for op in operators_data:
            op_obj = AppOperators(**op)
            db.add(op_obj)
            op_objs.append(op_obj)
        db.commit()
        print(f"Created {len(op_objs)} Operators successfully.")

        # Helper to generate full driver dictionary without NULLs
        def make_driver_dict(d_id, op_id, d_code, phone, name, v_reg, v_model, dep_req, dep_paid, dep_pend, mgr, mgr_ph, ref):
            idx = d_id - 100
            return {
                "driver_id": d_id, "operator_id": op_id, "driver_code": d_code, "phone": phone, "full_name": name,
                "vehicle_reg_number": v_reg, "vehicle_model": v_model, "deposit_total_req": dep_req, "deposit_paid": dep_paid,
                "deposit_pending": dep_pend, "assigned_manager_name": mgr, "assigned_manager_phone": mgr_ph,
                "referral_code": ref, "is_active": True,
                "profile_photo_url": f"https://cdn.letzryd.com/drivers/photos/{d_code}.jpg",
                "initials": "".join([part[0] for part in name.split()[:2]]),
                "aadhar_number": f"7483-9201-48{idx:02d}",
                "blood_group": "O+" if idx % 2 == 0 else "B+",
                "dob": date(1992, (idx % 12) + 1, (idx % 25) + 1),
                "address": f"H.No {idx}-5-102, Gachibowli, Hyderabad, Telangana 500032",
                "joined_date": date(2025, 11, 1),
                "emergency_name": f"{name.split()[0]} Sr.",
                "emergency_relation": "Father",
                "emergency_phone": f"98490998{idx:02d}",
                "dl_number": f"TS00920210048{idx:02d}",
                "dl_expiry": date(2031, 5, 14),
                "current_vehicle_id": d_id,
                "current_allocation_id": 500 + idx,
                "vehicle_make": "Maruti Suzuki" if "Maruti" in v_model else ("Hyundai" if "Hyundai" in v_model else "Tata"),
                "vehicle_variant": "CNG Tour H3" if "Tour" in v_model else "Standard Fleet Edition",
                "vehicle_year": 2023,
                "vehicle_color": "Arctic White",
                "vehicle_fuel_type": "EV" if "EV" in v_model else "CNG",
                "vehicle_odometer_km": 45000 + (idx * 1200),
                "vehicle_allocated_from": date(2026, 1, 1),
                "vehicle_daily_rate": 1100.00,
                "rc_number": f"RC-{v_reg}-HYD",
                "rc_expiry": date(2038, 3, 10),
                "insurance_number": f"INS-POLICY-7748{idx:02d}",
                "insurance_expiry": date(2027, 4, 15),
                "permit_type": "State Contract Carriage",
                "permit_number": f"PER-TG-2024-884{idx:02d}",
                "permit_expiry": date(2029, 6, 30),
                "fitness_number": f"FIT-TG07-992{idx:02d}",
                "fitness_expiry": date(2027, 8, 20),
                "puc_expiry": date(2026, 12, 31),
                "doc_last_updated": date(2026, 7, 1),
                "deposit_next_due": date(2026, 8, 1),
                "joining_fee_agreed": 1000.00,
                "joining_fee_paid": 1000.00,
                "cumulative_owed": 0.00,
                "incentive_trips_target": 30,
                "incentive_reward_amt": 1500.00,
                "referral_reward_amt": 1000.00,
                "contract_terms_url": f"https://cdn.letzryd.com/agreements/{d_code}.pdf",
                "upi_id": f"{name.split()[0].lower()}@upi",
                "bank_account_last4": f"48{idx:02d}",
                "password_hash": f"pbkdf2_sha256$260000$drvhash{d_id}",
                "fcm_token": f"fcm_token_drv_{d_id}_xyz{idx}",
                "preferred_language": "te",
                "created_at": now, "last_login_at": now, "last_synced_at": now,

                # Initial dummy placeholders for aggregation columns (Will be overwritten by aggregator)
                "cw_uber_trips": 0, "cw_uber_revenue": 0.0, "cw_uber_cash": 0.0, "cw_uber_toll": 0.0, "cw_uber_incentive": 0.0, "cw_uber_subscription": 0.0, "cw_uber_km": 0.0,
                "cw_ola_trips": 0, "cw_ola_revenue": 0.0, "cw_ola_cash": 0.0, "cw_ola_toll": 0.0, "cw_ola_incentive": 0.0, "cw_ola_subscription": 0.0, "cw_ola_km": 0.0,
                "cw_rapido_trips": 0, "cw_rapido_revenue": 0.0, "cw_rapido_cash": 0.0, "cw_rapido_toll": 0.0, "cw_rapido_incentive": 0.0, "cw_rapido_subscription": 0.0, "cw_rapido_km": 0.0,
                "cw_vehicle_rent": 0.0, "cw_maintenance_charge": 0.0, "cw_active_days": 7, "cw_tds": 0.0, "cw_challans": 0.0, "cw_accident_charge": 0.0, "cw_other_adjustment": 0.0, "cw_previous_outstanding": 0.0,
                "cw_gps_total_km": 0.0, "cw_gps_ideal_km": 0.0, "cw_gps_dead_km": 0.0, "cw_gps_dead_pct": 0.0, "cw_gps_dead_penalty": 0.0,
                "cw_trips": 0, "cw_total_km": 0.0, "cw_gross_earnings": 0.0, "cw_total_deductions": 0.0, "cw_total_penalties": 0.0, "cw_os": 0.0, "cw_to_collect": 0.0, "cw_to_pay": 0.0,
                "lw_trips": 12, "lw_gross_earnings": 10500.00, "lw_os": 9800.00, "lw_status": "paid", "lw_week_number": 27, "lw_hisaab_number": f"HIS-2026-027-{v_reg}", "growth_pct": 12.5, "cw_incentive_trips_done": 5
            }

        # 2. Create 15 Drivers (3 Drivers per Operator)
        drivers_data = [
            # Operator 201 Drivers
            make_driver_dict(101, 201, "LR-HYD-0001", "9866941379", "Varaprasad Srinivasa Rao", "TG07V0580", "Maruti Tour H3 CNG", 6000.0, 5000.0, 1000.0, "Kiran Kumar", "9988776655", "VARA100"),
            make_driver_dict(102, 201, "LR-HYD-0002", "7386089621", "Anand Pandu", "TG10T0365", "Hyundai Aura Tour CNG", 6000.0, 6000.0, 0.0, "Kiran Kumar", "9988776655", "ANAND200"),
            make_driver_dict(103, 201, "LR-HYD-0003", "9849012341", "Kameshwar Rao", "TG09A1001", "Maruti Dzire CNG", 6000.0, 4000.0, 2000.0, "Kiran Kumar", "9988776655", "KAMESH300"),
            
            # Operator 202 Drivers
            make_driver_dict(104, 202, "LR-HYD-0004", "9849012342", "Chaitanya Varma", "TG09A1002", "Hyundai Aura CNG", 6000.0, 6000.0, 0.0, "Rajesh Varma", "9988776644", "CHAITU400"),
            make_driver_dict(105, 202, "LR-HYD-0005", "9849012343", "Mahesh Babu K", "TG09A1003", "Maruti Tour H3 CNG", 6000.0, 5500.0, 500.0, "Rajesh Varma", "9988776644", "MAHESH500"),
            make_driver_dict(106, 202, "LR-HYD-0006", "9849012344", "Narendra Kumar", "TG09A1004", "Tata Tigor EV", 6000.0, 6000.0, 0.0, "Rajesh Varma", "9988776644", "NAREN600"),
            
            # Operator 203 Drivers
            make_driver_dict(107, 203, "LR-HYD-0007", "9849012345", "Siva Krishna", "TG09A1005", "Hyundai Aura CNG", 6000.0, 5000.0, 1000.0, "Kiran Kumar", "9988776655", "SIVA700"),
            make_driver_dict(108, 203, "LR-HYD-0008", "9849012346", "Praveen Raju", "TG09A1006", "Maruti Dzire CNG", 6000.0, 4500.0, 1500.0, "Kiran Kumar", "9988776655", "PRAVEEN800"),
            make_driver_dict(109, 203, "LR-HYD-0009", "9849012347", "Ganesh Naik", "TG09A1007", "Maruti Tour H3 CNG", 6000.0, 6000.0, 0.0, "Kiran Kumar", "9988776655", "GANESH900"),

            # Operator 204 Drivers
            make_driver_dict(110, 204, "LR-HYD-0010", "9849012348", "Mohd Imran", "TG09A1008", "Hyundai Aura CNG", 6000.0, 6000.0, 0.0, "Mohammed Ali", "9988776633", "IMRAN101"),
            make_driver_dict(111, 204, "LR-HYD-0011", "9849012349", "Tariq Hussain", "TG09A1009", "Maruti Tour H3 CNG", 6000.0, 5000.0, 1000.0, "Mohammed Ali", "9988776633", "TARIQ102"),
            make_driver_dict(112, 204, "LR-HYD-0012", "9849012350", "Aslam Khan", "TG09A1010", "Maruti Dzire CNG", 6000.0, 6000.0, 0.0, "Mohammed Ali", "9988776633", "ASLAM103"),

            # Operator 205 Drivers
            make_driver_dict(113, 205, "LR-HYD-0013", "9849012351", "Ravi Teja", "TG09A1011", "Hyundai Aura CNG", 6000.0, 6000.0, 0.0, "Rajesh Varma", "9988776644", "RAVI104"),
            make_driver_dict(114, 205, "LR-HYD-0014", "9849012352", "Bhanu Prakash", "TG09A1012", "Maruti Tour H3 CNG", 6000.0, 5000.0, 1000.0, "Rajesh Varma", "9988776644", "BHANU105"),
            make_driver_dict(115, 205, "LR-HYD-0015", "9849012353", "Venkatesh Naik", "TG09A1013", "Tata Tigor EV", 6000.0, 6000.0, 0.0, "Rajesh Varma", "9988776644", "VENKY106")
        ]

        driver_objs = []
        for drv in drivers_data:
            drv_obj = AppDrivers(**drv)
            db.add(drv_obj)
            driver_objs.append(drv_obj)
        db.commit()
        print(f"Created {len(driver_objs)} Drivers successfully.")

        # 3. Seed Raw Platform Trip Data (raw_uber_data, raw_ola_data, raw_rapido_data)
        print("Seeding raw trip data for all vehicles...")
        for drv in drivers_data:
            v = drv["vehicle_reg_number"]
            name = drv["full_name"]
            
            # Seed 2 Uber trips per driver
            db.execute(text("""
                INSERT INTO raw_uber_data (
                    vehicle_number, driver_name, week_start, week_end, trip_id, trip_date,
                    net_revenue, cash_collected, tolls, incentives, distance_km
                ) VALUES 
                (:v, :name, '2026-07-06', '2026-07-12', :t1, '2026-07-07', 2250.00, 500.00, 100.00, 200.00, 45.00),
                (:v, :name, '2026-07-06', '2026-07-12', :t2, '2026-07-08', 2250.00, 400.00, 50.00, 150.00, 40.00);
            """), {"v": v, "name": name, "t1": f"UBER-{v}-1", "t2": f"UBER-{v}-2"})

            # Seed 2 Ola trips per driver
            db.execute(text("""
                INSERT INTO raw_ola_data (
                    vehicle_number, driver_name, week_start, week_end, crn, trip_date,
                    net_revenue, cash_collected, tolls, incentives, actual_kms
                ) VALUES 
                (:v, :name, '2026-07-06', '2026-07-12', :c1, '2026-07-07', 2500.00, 600.00, 80.00, 180.00, 50.00),
                (:v, :name, '2026-07-06', '2026-07-12', :c2, '2026-07-08', 2500.00, 550.00, 70.00, 170.00, 48.00);
            """), {"v": v, "name": name, "c1": f"OLA-{v}-1", "c2": f"OLA-{v}-2"})

            # Seed 1 Rapido trip per driver
            db.execute(text("""
                INSERT INTO raw_rapido_data (
                    vehicle_number, driver_name, week_start, week_end, trip_id, trip_date,
                    net_revenue, cash_collected, tolls, incentives, distance_kms
                ) VALUES 
                (:v, :name, '2026-07-06', '2026-07-12', :r1, '2026-07-08', 3100.00, 800.00, 0.00, 200.00, 60.00);
            """), {"v": v, "name": name, "r1": f"RAP-{v}-1"})

            # Raw Deductions & GPS Logs
            db.execute(text("""
                INSERT INTO raw_traffic_challans (vehicle_number, challan_number, driver_name, violation_date, violation_location, challan_amount)
                VALUES (:v, :ch, :name, '2026-07-08', 'HITEC City Junction', 500.00);
            """), {"v": v, "name": name, "ch": f"CHAL-{v}-1"})

            db.execute(text("""
                INSERT INTO raw_gps_logs (vehicle_number, gps_date, km_driven)
                VALUES 
                (:v, '2026-07-07', 150.00),
                (:v, '2026-07-08', 140.00);
            """), {"v": v})

        db.commit()
        db.close()
        print("Raw platform trip records seeded for all 15 drivers.")

        # 4. Trigger Raw Data Aggregation Engine with fresh session
        print("\nTriggering raw data aggregation engine into app_hisaabs, app_drivers, and app_operators...")
        db = SessionLocal()
        processed_count = aggregate_raw_platform_data(db)
        print(f"Aggregation complete! Processed {processed_count} vehicle records into app_hisaabs, app_drivers, and app_operators.")

        # 5. Print Summary Verification
        op_count = db.query(AppOperators).count()
        drv_count = db.query(AppDrivers).count()
        his_count = db.query(AppHisaabs).count()
        print(f"\n=== DATABASE SEEDING VERIFICATION ===")
        print(f"App Operators Count: {op_count}")
        print(f"App Drivers Count:   {drv_count}")
        print(f"App Hisaabs Count:   {his_count}")

    except Exception as e:
        db.rollback()
        print(f"Error during seeding: {e}")
        raise e
    finally:
        db.close()

if __name__ == "__main__":
    seed_database()
