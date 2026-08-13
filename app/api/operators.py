from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.database import get_db
from app.models.app_models import AppOperators, AppDrivers, AppHisaabs

router = APIRouter(prefix="/operators", tags=["Operators"])

@router.get("/me")
def get_current_operator(phone: str = "9848012345", db: Session = Depends(get_db)):
    operator = db.query(AppOperators).filter(AppOperators.phone == phone).first()
    if not operator:
        operator = db.query(AppOperators).first()
        if not operator:
            raise HTTPException(status_code=404, detail="Operator not found")
    return operator

@router.get("/{operator_id}/fleet")
def get_operator_fleet(operator_id: int, db: Session = Depends(get_db)):
    hisaabs = db.query(AppHisaabs).filter(AppHisaabs.app_operator_id == operator_id).all()
    return {"operator_id": operator_id, "fleet_count": len(hisaabs), "hisaabs": hisaabs}
