"""
populate_without_truncation.py — Safe Master Ingestion & Aggregation Pipeline
=============================================================================
This pipeline populates app tables from core tables WITHOUT TRUNCATING ANY TABLES:
1. Pulls data from Core tables (drivers, onboarding, partners, vehicles, rents) -> app_drivers & app_operators (Upsert on conflict phone).
2. Generates dummy trips & platform incentives into raw tables for newly loaded vehicles/drivers.
3. Runs Platform Aggregator to calculate Hisaab settlements -> app_hisaabs.
4. Updates weekly metrics in app_drivers and app_operators.
5. Preserves all existing test data, support tickets, notifications, payments, and sessions.
"""

import sys
import logging
from pathlib import Path
from sqlalchemy import text
from sqlalchemy.orm import Session

# Add root directory to sys.path
sys.path.append(str(Path(__file__).resolve().parent))

from app.database import SessionLocal
from app.services.app_populator import populate_app_drivers, populate_app_operators
from app.services.raw_dummy_generator import generate_raw_platform_dummy_data
from app.services.platform_aggregator import aggregate_raw_platform_data

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("safe_pipeline")

def run_safe_pipeline(db: Session = None):
    print("=" * 80)
    print("LETZRYD — SAFE DATA POPULATION & HISAAB PIPELINE (ZERO TRUNCATION)")
    print("=" * 80)

    should_close = False
    if db is None:
        db = SessionLocal()
        should_close = True

    try:
        # Step 1: Populate / Upsert Base Drivers & Operators from Core Tables
        print("\n[Step 1/3] Ingesting Core table records into app_drivers & app_operators (Safe Upsert)...")
        drivers_count = populate_app_drivers(db)
        db.commit()
        print(f" -> Processed {drivers_count} drivers into app_drivers.")

        operators_count = populate_app_operators(db)
        db.commit()
        print(f" -> Processed {operators_count} operators into app_operators.")

        # Step 2: Generate Realistic Platform Trip & Incentive Data in Raw Tables
        print("\n[Step 2/3] Generating raw platform trips & incentives for active vehicles...")
        generate_raw_platform_dummy_data(db, sample_size=None, week_number=28)
        db.commit()
        print(" -> Raw trip & incentive records generated successfully.")

        # Step 3: Run Platform Aggregator & Hisaab Calculation into app_hisaabs
        print("\n[Step 3/3] Aggregating raw trips, incentives & core deductions into app_hisaabs...")
        hisaabs_count = aggregate_raw_platform_data(db, week_number=28)
        db.commit()
        print(f" -> Processed {hisaabs_count} weekly Hisaab settlements in app_hisaabs.")
        print(" -> Updated current week & last week metrics in app_drivers and app_operators.")

        db.commit()

        # Print Execution Verification Summary
        app_drivers_total = db.execute(text("SELECT COUNT(*) FROM app_drivers;")).scalar()
        app_ops_total = db.execute(text("SELECT COUNT(*) FROM app_operators;")).scalar()
        app_hisaabs_total = db.execute(text("SELECT COUNT(*) FROM app_hisaabs;")).scalar()
        raw_uber_total = db.execute(text("SELECT COUNT(*) FROM raw_uber_data;")).scalar()
        raw_ola_total = db.execute(text("SELECT COUNT(*) FROM raw_ola_data;")).scalar()
        raw_rapido_total = db.execute(text("SELECT COUNT(*) FROM raw_rapido_data;")).scalar()

        print("\n" + "=" * 80)
        print("SAFE PIPELINE EXECUTION SUMMARY")
        print("=" * 80)
        print(f"  Total records in app_drivers:        {app_drivers_total}")
        print(f"  Total records in app_operators:      {app_ops_total}")
        print(f"  Total records in app_hisaabs:        {app_hisaabs_total}")
        print(f"  Total records in raw_uber_data:      {raw_uber_total}")
        print(f"  Total records in raw_ola_data:       {raw_ola_total}")
        print(f"  Total records in raw_rapido_data:    {raw_rapido_total}")
        print("=" * 80)
        print("Pipeline completed successfully! All test data and core data safely preserved.")

    except Exception as e:
        logger.error(f"Safe pipeline execution failed: {e}", exc_info=True)
        db.rollback()
        raise e
    finally:
        if should_close:
            db.close()

if __name__ == "__main__":
    run_safe_pipeline()
