from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List

from app.database import get_db
from app.models.app_models import AppNotifications
from app.schemas.app_schemas import NotificationResponse

router = APIRouter(prefix="/notifications", tags=["Push Notifications & Feed"])

@router.get("", response_model=List[NotificationResponse])
def get_notifications(target_id: int = 1, db: Session = Depends(get_db)):
    notifs = db.query(AppNotifications).filter(
        (AppNotifications.target_id == target_id) | (AppNotifications.target_type == 'all')
    ).order_by(AppNotifications.created_at.desc()).all()
    
    return [
        NotificationResponse(
            app_notif_id=n.app_notif_id,
            title=n.title,
            message=n.message,
            notif_type=n.notif_type,
            severity=n.severity,
            is_read=n.is_read,
            created_at=n.created_at
        ) for n in notifs
    ]

@router.put("/{notif_id}/read")
def mark_read(notif_id: int, db: Session = Depends(get_db)):
    notif = db.query(AppNotifications).filter(AppNotifications.app_notif_id == notif_id).first()
    if notif:
        notif.is_read = True
        db.commit()
    return {"success": True}
