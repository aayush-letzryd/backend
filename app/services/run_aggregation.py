"""
run_aggregation.py — Production Raw Data Aggregator Script
===========================================================
Executes the aggregation engine against live raw platform tables
(raw_uber_data, raw_ola_data, raw_rapido_data, etc.) populated by automation.
Does NOT insert any dummy or test rows.
"""

import sys
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent.parent.parent))

from app.database import SessionLocal
from app.services.platform_aggregator import aggregate_raw_platform_data

def run_live_aggregation(week_number=None):
    db = SessionLocal()
    target_desc = f"ISO Week {week_number}" if week_number else "ALL weeks present in raw tables"
    print(f"Running live raw data aggregation pipeline for {target_desc}...")
    try:
        count = aggregate_raw_platform_data(db, week_number=week_number)
        print(f"Successfully processed raw table records for {count} vehicle-week records into app_hisaabs, app_drivers, and app_operators!")
    except Exception as e:
        print(f"Error during raw data aggregation: {e}")
    finally:
        db.close()

if __name__ == "__main__":
    week_num = None
    if len(sys.argv) > 1:
        try:
            week_num = int(sys.argv[1])
        except ValueError:
            pass
    run_live_aggregation(week_number=week_num)
