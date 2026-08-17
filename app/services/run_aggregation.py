"""
run_aggregation.py — CLI Runner for Platform Data Aggregation Pipeline
======================================================================
Executes raw trip & incentive aggregation and hisaab calculation across all platforms.
"""

import sys
import logging
from app.database import SessionLocal
from app.services.platform_aggregator import aggregate_raw_platform_data

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("run_aggregation")

def run():
    logger.info("Starting Platform Data Aggregation Pipeline...")
    db = SessionLocal()
    try:
        count = aggregate_raw_platform_data(db)
        logger.info(f"Aggregation complete. Processed {count} vehicle records.")
    except Exception as e:
        logger.error(f"Pipeline execution failed: {e}", exc_info=True)
        db.rollback()
    finally:
        db.close()

if __name__ == "__main__":
    run()
