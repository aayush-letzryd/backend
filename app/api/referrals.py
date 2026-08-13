from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.database import get_db
from app.models.app_models import AppReferralLeads
from app.schemas.app_schemas import SubmitReferralRequest, ReferralResponse

router = APIRouter(prefix="/referrals", tags=["Referrals"])

@router.get("")
def list_referrals(driver_id: int = 1, db: Session = Depends(get_db)):
    referrals = db.query(AppReferralLeads).filter(AppReferralLeads.referred_by_driver_id == driver_id).all()
    return {"driver_id": driver_id, "count": len(referrals), "data": referrals}

@router.post("", response_model=ReferralResponse)
def submit_referral(req: SubmitReferralRequest, db: Session = Depends(get_db)):
    lead = AppReferralLeads(
        referred_by_type=req.referred_by_type,
        referred_by_driver_id=req.referred_by_id if req.referred_by_type == 'driver' else None,
        referred_by_op_id=req.referred_by_id if req.referred_by_type == 'operator' else None,
        lead_name=req.lead_name,
        lead_phone=req.lead_phone,
        status="submitted",
        reward_amount=1000.00,
        reward_credited=False
    )
    db.add(lead)
    db.commit()
    db.refresh(lead)
    
    return ReferralResponse(
        app_referral_id=lead.app_referral_id,
        lead_name=lead.lead_name,
        lead_phone=lead.lead_phone,
        status=lead.status,
        reward_amount=float(lead.reward_amount),
        reward_credited=lead.reward_credited
    )
