from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from datetime import datetime, timedelta
import jwt

from app.database import get_db
from app.config import settings
from app.models.app_models import AppDrivers, AppOperators, AppSessions, AppAuditLogs
from app.schemas.app_schemas import OTPRequest, OTPVerify, PasswordLogin, TokenResponse

router = APIRouter(prefix="/auth", tags=["Authentication"])

@router.post("/otp/request")
def request_otp(req: OTPRequest, db: Session = Depends(get_db)):
    phone = req.phone.strip()
    
    user_id = None
    if req.user_type == 'driver':
        user = db.query(AppDrivers).filter(AppDrivers.phone == phone).first()
        if user:
            user_id = user.app_driver_id
    else:
        user = db.query(AppOperators).filter(AppOperators.phone == phone).first()
        if user:
            user_id = user.app_operator_id
            
    if not user_id:
        user_id = 1
        
    session = AppSessions(
        user_type=req.user_type,
        user_ref_id=user_id,
        phone=phone,
        otp_hash="hashed_1234",
        is_verified=False,
        expires_at=datetime.utcnow() + timedelta(minutes=10)
    )
    db.add(session)
    
    audit = AppAuditLogs(
        user_type=req.user_type,
        user_ref_id=user_id,
        event_type="OTP_REQUEST",
        phone=phone
    )
    db.add(audit)
    db.commit()
    
    return {"success": True, "message": "OTP sent successfully to " + phone, "demo_otp": "1234"}


@router.post("/otp/verify", response_model=TokenResponse)
def verify_otp(req: OTPVerify, db: Session = Depends(get_db)):
    phone = req.phone.strip()
    
    user_name = "Partner User"
    user_id = 1
    
    if req.user_type == 'driver':
        driver = db.query(AppDrivers).filter(AppDrivers.phone == phone).first()
        if driver:
            user_name = driver.full_name
            user_id = driver.app_driver_id
    else:
        operator = db.query(AppOperators).filter(AppOperators.phone == phone).first()
        if operator:
            user_name = operator.company_name
            user_id = operator.app_operator_id

    payload = {
        "sub": phone,
        "user_type": req.user_type,
        "user_id": user_id,
        "exp": datetime.utcnow() + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    }
    token = jwt.encode(payload, settings.SECRET_KEY, algorithm=settings.JWT_ALGORITHM)
    
    audit = AppAuditLogs(
        user_type=req.user_type,
        user_ref_id=user_id,
        event_type="LOGIN_SUCCESS",
        phone=phone
    )
    db.add(audit)
    db.commit()

    return TokenResponse(
        access_token=token,
        token_type="bearer",
        user_type=req.user_type,
        user_id=user_id,
        name=user_name
    )
