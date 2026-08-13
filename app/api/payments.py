from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session
from datetime import datetime
import uuid

from app.database import get_db
from app.models.app_models import AppPayments
from app.schemas.app_schemas import InitiatePaymentRequest, PaymentResponse

router = APIRouter(prefix="/payments", tags=["Payments & Cashfree"])

@router.post("/initiate", response_model=PaymentResponse)
def initiate_payment(req: InitiatePaymentRequest, db: Session = Depends(get_db)):
    cf_order_id = f"ORDER_LR_{uuid.uuid4().hex[:10].upper()}"
    
    payment = AppPayments(
        payment_type="collection",
        payer_type=req.payer_type,
        payer_id=req.payer_id,
        payee_type="letzryd",
        app_hisaab_id=req.app_hisaab_id,
        amount=req.amount,
        payment_mode=req.payment_mode,
        status="INITIATED",
        cf_order_id=cf_order_id
    )
    db.add(payment)
    db.commit()
    db.refresh(payment)
    
    return PaymentResponse(
        app_payment_id=payment.app_payment_id,
        amount=float(payment.amount),
        payment_mode=payment.payment_mode,
        status=payment.status,
        cf_order_id=payment.cf_order_id
    )

@router.get("/history")
def get_payment_history(payer_id: int = 1, db: Session = Depends(get_db)):
    payments = db.query(AppPayments).filter(AppPayments.payer_id == payer_id).all()
    return {"payer_id": payer_id, "count": len(payments), "data": payments}

@router.post("/webhook/cashfree")
async def cashfree_webhook(request: Request, db: Session = Depends(get_db)):
    payload = await request.json()
    order_id = payload.get("order", {}).get("order_id")
    
    if order_id:
        payment = db.query(AppPayments).filter(AppPayments.cf_order_id == order_id).first()
        if payment:
            payment.status = "SUCCESS"
            payment.completed_at = datetime.utcnow()
            payment.raw_response = payload
            db.commit()
            
    return {"status": "OK"}
