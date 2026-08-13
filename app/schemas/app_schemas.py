from pydantic import BaseModel, Field
from typing import Optional, List, Any
from datetime import date, datetime

# Auth Schemas
class OTPRequest(BaseModel):
    phone: str
    user_type: str = "driver"  # 'driver' or 'operator'

class OTPVerify(BaseModel):
    phone: str
    otp: str
    user_type: str = "driver"
    fcm_token: Optional[str] = None

class PasswordLogin(BaseModel):
    phone: str
    password: str
    user_type: str = "driver"

class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_type: str
    user_id: int
    name: str

# Driver Schemas
class DriverProfileResponse(BaseModel):
    app_driver_id: int
    driver_code: str
    phone: str
    name: str
    assigned_vehicle_reg: Optional[str] = None
    deposit_total_req: float
    deposit_paid: float
    deposit_pending: float
    cw_gross_earnings: float
    cw_os: float
    cw_to_pay: float
    cw_to_collect: float
    lw_os: float
    lw_status: str

# Hisaab Schemas
class HisaabBreakdownResponse(BaseModel):
    app_hisaab_id: int
    hisaab_number: str
    week_number: int
    period_start: date
    period_end: date
    days_count: int
    status: Optional[str] = "to_collect"
    uber_trips: int
    uber_revenue: float
    uber_cash: float
    uber_incentive: float
    ola_trips: int
    ola_revenue: float
    ola_cash: float
    ola_incentive: float
    rapido_trips: int
    rapido_revenue: float
    rapido_cash: float
    rapido_incentive: float
    vehicle_rent: float
    maintenance_charge: float
    tds_amount: float
    challan_amount: float
    accident_charge: float
    other_adjustment: float
    gps_dead_penalty: float
    total_gross_earnings: float
    total_deductions: float
    current_period_os: float
    to_collect: float
    to_pay: float

# Payment Schemas
class InitiatePaymentRequest(BaseModel):
    amount: float
    payment_mode: str = "cashfree_upi"
    app_hisaab_id: Optional[int] = None
    payer_type: str = "driver"
    payer_id: int

class PaymentResponse(BaseModel):
    app_payment_id: int
    amount: float
    payment_mode: str
    status: str
    cf_order_id: Optional[str] = None

# Support Ticket Schemas
class CreateTicketRequest(BaseModel):
    creator_type: str = "driver"
    creator_id: int
    category: str
    subject: str
    description: str
    priority: str = "medium"

class TicketResponse(BaseModel):
    app_ticket_id: int
    ticket_number: str
    category: str
    subject: str
    status: str
    created_at: datetime

# Notification Schemas
class NotificationResponse(BaseModel):
    app_notif_id: int
    title: str
    message: str
    notif_type: str
    severity: Optional[str] = "info"
    is_read: Optional[bool] = False
    created_at: Optional[datetime] = None

# Referral Schemas
class SubmitReferralRequest(BaseModel):
    referred_by_type: str = "driver"
    referred_by_id: int
    lead_name: str
    lead_phone: str

class ReferralResponse(BaseModel):
    app_referral_id: int
    lead_name: str
    lead_phone: str
    status: str
    reward_amount: float
    reward_credited: bool
