from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List, Optional

from app.database import get_db
from app.models.app_models import AppHisaabs
from app.schemas.app_schemas import HisaabBreakdownResponse
from app.services.platform_aggregator import aggregate_raw_platform_data

router = APIRouter(prefix="/hisaabs", tags=["Hisaabs Ledger"])

@router.get("/driver/{driver_id}")
def get_driver_hisaabs(driver_id: int, db: Session = Depends(get_db)):
    hisaabs = db.query(AppHisaabs).filter(AppHisaabs.app_driver_id == driver_id).all()
    return {"driver_id": driver_id, "count": len(hisaabs), "data": hisaabs}

@router.get("/operator/{operator_id}")
def get_operator_hisaabs(operator_id: int, db: Session = Depends(get_db)):
    hisaabs = db.query(AppHisaabs).filter(AppHisaabs.app_operator_id == operator_id).all()
    return {"operator_id": operator_id, "count": len(hisaabs), "data": hisaabs}

@router.get("/{hisaab_id}", response_model=HisaabBreakdownResponse)
def get_hisaab_by_id(hisaab_id: int, db: Session = Depends(get_db)):
    hisaab = db.query(AppHisaabs).filter(AppHisaabs.app_hisaab_id == hisaab_id).first()
    if not hisaab:
        hisaab = db.query(AppHisaabs).first()
        if not hisaab:
            raise HTTPException(status_code=404, detail="Hisaab record not found")

    return HisaabBreakdownResponse(
        app_hisaab_id=hisaab.app_hisaab_id,
        hisaab_number=hisaab.hisaab_number,
        week_number=hisaab.week_number,
        period_start=hisaab.period_start,
        period_end=hisaab.period_end,
        days_count=hisaab.days_count,
        status=hisaab.status,
        uber_trips=hisaab.uber_trips,
        uber_revenue=float(hisaab.uber_revenue or 0),
        uber_cash=float(hisaab.uber_cash or 0),
        uber_incentive=float(hisaab.uber_incentive or 0),
        ola_trips=hisaab.ola_trips,
        ola_revenue=float(hisaab.ola_revenue or 0),
        ola_cash=float(hisaab.ola_cash or 0),
        ola_incentive=float(hisaab.ola_incentive or 0),
        rapido_trips=hisaab.rapido_trips,
        rapido_revenue=float(hisaab.rapido_revenue or 0),
        rapido_cash=float(hisaab.rapido_cash or 0),
        rapido_incentive=float(hisaab.rapido_incentive or 0),
        vehicle_rent=float(hisaab.vehicle_rent or 0),
        maintenance_charge=float(hisaab.maintenance_charge or 0),
        tds_amount=float(hisaab.tds_amount or 0),
        challan_amount=float(hisaab.challan_amount or 0),
        accident_charge=float(hisaab.accident_charge or 0),
        other_adjustment=float(hisaab.other_adjustment or 0),
        gps_dead_penalty=float(hisaab.gps_dead_penalty or 0),
        total_gross_earnings=float(hisaab.total_gross_earnings or 0),
        total_deductions=float(hisaab.total_deductions or 0),
        current_period_os=float(hisaab.current_period_os or 0),
        to_collect=float(hisaab.to_collect or 0),
        to_pay=float(hisaab.to_pay or 0)
    )

@router.post("/recalculate")
def trigger_raw_recalculation(week_number: int = 30, db: Session = Depends(get_db)):
    processed = aggregate_raw_platform_data(db, week_number)
    return {"success": True, "message": f"Processed raw platform data for {processed} vehicles"}
