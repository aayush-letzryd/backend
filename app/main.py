from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.config import settings

from app.api.auth import router as auth_router
from app.api.drivers import router as drivers_router
from app.api.operators import router as operators_router
from app.api.hisaabs import router as hisaabs_router
from app.api.payments import router as payments_router
from app.api.tickets import router as tickets_router
from app.api.notifications import router as notifications_router
from app.api.referrals import router as referrals_router
from app.api.audit import router as audit_router

app = FastAPI(
    title=settings.PROJECT_NAME,
    version=settings.VERSION,
    description="Complete Backend API for LetzRyd Partner App (Drivers, Operators, Hisaabs, Payments, Tickets, Notifications, Referrals, Audit Logs)"
)

# CORS Setup
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include Routers under /api
api_prefix = settings.API_V1_STR
app.include_router(auth_router, prefix=api_prefix)
app.include_router(drivers_router, prefix=api_prefix)
app.include_router(operators_router, prefix=api_prefix)
app.include_router(hisaabs_router, prefix=api_prefix)
app.include_router(payments_router, prefix=api_prefix)
app.include_router(tickets_router, prefix=api_prefix)
app.include_router(notifications_router, prefix=api_prefix)
app.include_router(referrals_router, prefix=api_prefix)
app.include_router(audit_router, prefix=api_prefix)

@app.get("/api/health")
def health_check():
    return {
        "status": "healthy",
        "app": settings.PROJECT_NAME,
        "version": settings.VERSION
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
