"""
populate_app_data.py — Master Data Population & Platform Aggregation Pipeline
=============================================================================
Orchestrates:
1. Truncating old dummy & app data with RESTART IDENTITY (resets IDs to 1).
2. Populating app_drivers & app_operators from Google Sheets Core tables.
3. Populating realistic dummy trips & incentives into raw platform tables.
4. Aggregating raw platform trips into app_hisaabs and updating weekly metrics in app_drivers & app_operators.
"""

import sys
import logging
from sqlalchemy import text
from sqlalchemy.orm import Session
from app.database import SessionLocal
from app.services.app_populator import populate_app_drivers, populate_app_operators
from app.services.raw_dummy_generator import generate_raw_platform_dummy_data
from app.services.platform_aggregator import aggregate_raw_platform_data

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("populate_pipeline")

def run_full_pipeline(db: Session = None, truncate_first: bool = True):
    print("=" * 70)
    print("LETZRYD PARTNER APP — MASTER DATA POPULATION & AGGREGATION PIPELINE")
    print("=" * 70)

    should_close = False
    if db is None:
        db = SessionLocal()
        should_close = True
    try:
        # Step 1: Truncate old data and reset auto-increment IDs to 1
        if truncate_first:
            print("\n[Step 1/4] Truncating old app and raw staging tables with RESTART IDENTITY...")
            db.execute(text("""
                TRUNCATE TABLE 
                    app_hisaabs, 
                    app_drivers, 
                    app_operators,
                    raw_uber_data, 
                    raw_ola_data, 
                    raw_rapido_data,
                    raw_uber_incentives, 
                    raw_ola_incentives, 
                    raw_rapido_incentives
                RESTART IDENTITY CASCADE;
            """))
            db.commit()
            print(" -> Truncated tables and reset sequences (app_driver_id and app_operator_id will start from 1).")

        # Step 2: Populate Base Drivers & Operators from Core Tables
        print("\n[Step 2/4] Populating app_drivers and app_operators from Google Sheets Core tables...")
        drivers_count = populate_app_drivers(db)
        db.commit()
        print(f" -> Populated {drivers_count} drivers in app_drivers.")

        operators_count = populate_app_operators(db)
        db.commit()
        print(f" -> Populated {operators_count} operators in app_operators (with linked app_driver_id).")

        # Step 3: Populate Realistic Dummy Raw Platform Data
        print("\n[Step 3/4] Generating realistic platform trip & incentive data in raw tables...")
        generate_raw_platform_dummy_data(db, sample_size=None, week_number=28)
        db.commit()
        print(" -> Populated raw_uber_data, raw_ola_data, raw_rapido_data, and incentive tables.")

        # Step 4: Run Platform Aggregator & Hisaab Calculation
        print("\n[Step 4/4] Aggregating raw platform trips, incentives & deductions into app_hisaabs...")
        hisaabs_count = aggregate_raw_platform_data(db, week_number=28)
        db.commit()
        print(f" -> Processed {hisaabs_count} weekly Hisaab settlements in app_hisaabs.")
        print(" -> Updated current week & last week metrics in app_drivers and app_operators.")

        # Final commit to ensure all records persist permanently in PostgreSQL
        db.commit()

        # Stats Summary
        app_drivers_total = db.execute(text("SELECT COUNT(*) FROM app_drivers;")).scalar()
        app_ops_total = db.execute(text("SELECT COUNT(*) FROM app_operators;")).scalar()
        app_hisaabs_total = db.execute(text("SELECT COUNT(*) FROM app_hisaabs;")).scalar()
        raw_uber_total = db.execute(text("SELECT COUNT(*) FROM raw_uber_data;")).scalar()
        raw_ola_total = db.execute(text("SELECT COUNT(*) FROM raw_ola_data;")).scalar()
        raw_rapido_total = db.execute(text("SELECT COUNT(*) FROM raw_rapido_data;")).scalar()
        min_max_drv = db.execute(text("SELECT MIN(app_driver_id), MAX(app_driver_id) FROM app_drivers;")).fetchone()
        min_max_ops = db.execute(text("SELECT MIN(app_operator_id), MAX(app_operator_id) FROM app_operators;")).fetchone()

        print("\n" + "=" * 70)
        print("PIPELINE EXECUTION SUMMARY")
        print("=" * 70)
        print(f"  Total records in app_drivers:        {app_drivers_total} (ID range: {min_max_drv[0]} to {min_max_drv[1]})")
        print(f"  Total records in app_operators:      {app_ops_total} (ID range: {min_max_ops[0]} to {min_max_ops[1]})")
        print(f"  Total records in app_hisaabs:        {app_hisaabs_total}")
        print(f"  Total records in raw_uber_data:      {raw_uber_total}")
        print(f"  Total records in raw_ola_data:       {raw_ola_total}")
        print(f"  Total records in raw_rapido_data:    {raw_rapido_total}")
        print("=" * 70)
        print("Pipeline completed successfully with ZERO critical errors!")

    except Exception as e:
        logger.error(f"Pipeline failed: {e}", exc_info=True)
        db.rollback()
    finally:
        if should_close:
            db.close()

if __name__ == "__main__":
    run_full_pipeline(truncate_first=True)
