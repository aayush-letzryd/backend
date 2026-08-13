from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.database import get_db
from app.models.app_models import AppDrivers
from app.schemas.app_schemas import DriverProfileResponse

router = APIRouter(prefix="/drivers", tags=["Drivers"])

@router.get("/me", response_model=DriverProfileResponse)
def get_current_driver(phone: str = "9866941379", db: Session = Depends(get_db)):
    driver = db.query(AppDrivers).filter(AppDrivers.phone == phone).first()
    if not driver:
        driver = db.query(AppDrivers).first()
        if not driver:
            raise HTTPException(status_code=404, detail="Driver profile not found")
            
    return DriverProfileResponse(
        app_driver_id=driver.app_driver_id,
        driver_code=driver.driver_code,
        phone=driver.phone,
        name=driver.full_name or "Driver",
        assigned_vehicle_reg=driver.vehicle_reg_number,
        deposit_total_req=float(driver.deposit_total_req or 6000),
        deposit_paid=float(driver.deposit_paid or 5000),
        deposit_pending=float(driver.deposit_pending or 1000),
        cw_gross_earnings=float(driver.cw_gross_earnings or 0),
        cw_os=float(driver.cw_os or 0),
        cw_to_pay=float(driver.cw_to_pay or 0),
        cw_to_collect=float(driver.cw_to_collect or 0),
        lw_os=float(driver.lw_os or 0),
        lw_status=driver.lw_status or "unpaid"
    )

@router.get("/{driver_id}")
def get_driver_by_id(driver_id: int, db: Session = Depends(get_db)):
    driver = db.query(AppDrivers).filter(AppDrivers.app_driver_id == driver_id).first()
    if not driver:
        raise HTTPException(status_code=404, detail="Driver not found")
    return driver
