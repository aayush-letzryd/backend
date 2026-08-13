from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from app.database import get_db
from app.models.app_models import AppAuditLogs

router = APIRouter(prefix="/audit", tags=["Security Audit Logs"])

@router.get("")
def list_audit_logs(limit: int = 50, db: Session = Depends(get_db)):
    logs = db.query(AppAuditLogs).order_by(AppAuditLogs.created_at.desc()).limit(limit).all()
    return {"count": len(logs), "logs": logs}
