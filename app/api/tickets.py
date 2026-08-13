from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
import datetime

from app.database import get_db
from app.models.app_models import AppSupportTickets
from app.schemas.app_schemas import CreateTicketRequest, TicketResponse

router = APIRouter(prefix="/tickets", tags=["Support Tickets"])

@router.get("")
def list_tickets(creator_id: int = 1, db: Session = Depends(get_db)):
    tickets = db.query(AppSupportTickets).filter(AppSupportTickets.creator_id == creator_id).all()
    return {"creator_id": creator_id, "count": len(tickets), "data": tickets}

@router.post("", response_model=TicketResponse)
def create_ticket(req: CreateTicketRequest, db: Session = Depends(get_db)):
    ticket_no = f"TKT-2026-{datetime.datetime.utcnow().strftime('%M%S')}"
    
    ticket = AppSupportTickets(
        ticket_number=ticket_no,
        creator_type=req.creator_type,
        creator_id=req.creator_id,
        category=req.category,
        subject=req.subject,
        description=req.description,
        priority=req.priority,
        status="open"
    )
    db.add(ticket)
    db.commit()
    db.refresh(ticket)
    
    return TicketResponse(
        app_ticket_id=ticket.app_ticket_id,
        ticket_number=ticket.ticket_number,
        category=ticket.category,
        subject=ticket.subject,
        status=ticket.status,
        created_at=ticket.created_at
    )
