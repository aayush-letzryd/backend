"""
hisaab_calculator.py — Settlement Engine for LetzRyd Partner App
================================================================
Implements exact formulas defined in LetzRyd Hisaab — Settlement Guide.docx:

1. Gross Platform Earnings = Uber Revenue + Ola Revenue + Rapido Revenue
2. Platform Incentives = Uber Incentives + Ola Incentives + Rapido Incentives
3. Net Rent = (Days Driven x Daily Rent Rate) + Maintenance Charge
4. TDS Amount = 1% of Gross Platform Earnings (if PAN linked/Individual driver)
5. Dead Mile Penalty = Max(0, GPS KM - Trip KM - Free Allowance KM) x Penalty Rate
6. Total Deductions = Net Rent + Maintenance + TDS + Challans + Accidents + Dead Mile Penalty - Adjustments
7. Net Outstanding (Current Week O/S) = Total Deductions - Uber Cash - Ola Cash - Rapido Cash - Incentives
8. To Collect = Max(0, Net OS + Previous Outstanding)
9. To Pay = Max(0, -(Net OS + Previous Outstanding))
"""

from typing import Dict, Any

def calculate_hisaab_breakdown(data: Dict[str, Any]) -> Dict[str, Any]:
    # Extract Platform Inputs
    uber_rev = float(data.get("uber_revenue", 0.0))
    uber_cash = float(data.get("uber_cash", 0.0))
    uber_inc = float(data.get("uber_incentive", 0.0))
    uber_km = float(data.get("uber_km", 0.0))
    
    ola_rev = float(data.get("ola_revenue", 0.0))
    ola_cash = float(data.get("ola_cash", 0.0))
    ola_inc = float(data.get("ola_incentive", 0.0))
    ola_km = float(data.get("ola_km", 0.0))
    
    rapido_rev = float(data.get("rapido_revenue", 0.0))
    rapido_cash = float(data.get("rapido_cash", 0.0))
    rapido_inc = float(data.get("rapido_incentive", 0.0))
    rapido_km = float(data.get("rapido_km", 0.0))
    
    days_count = int(data.get("days_count", 7))
    daily_rate = float(data.get("vehicle_daily_rate", 1100.0))
    maint_rate = float(data.get("maintenance_daily_rate", 30.0))
    
    # Rental Charges
    vehicle_rent = round(days_count * daily_rate, 2)
    maintenance_charge = round(days_count * maint_rate, 2)
    
    # Gross Earnings
    total_gross = round(uber_rev + ola_rev + rapido_rev, 2)
    total_incentives = round(uber_inc + ola_inc + rapido_inc, 2)
    total_cash_collected = round(uber_cash + ola_cash + rapido_cash, 2)
    total_trip_km = round(uber_km + ola_km + rapido_km, 2)
    
    # TDS (1% of Gross Earnings for Individual Drivers)
    pan_linked = data.get("is_pan_linked", True)
    driver_type = data.get("driver_type", "Individual")
    
    tds_amount = 0.0
    if driver_type != "Operator" and pan_linked:
        tds_amount = round(total_gross * 0.01, 2)
        
    # Additional Penalties & Deductions
    challan_amount = float(data.get("challan_amount", 0.0))
    accident_charge = float(data.get("accident_charge", 0.0))
    other_adjustment = float(data.get("other_adjustment", 0.0))  # Rent-offs reduce deductions
    prev_os = float(data.get("previous_outstanding", 0.0))
    
    # Dead Mile Calculation
    gps_total_km = float(data.get("gps_total_km", 0.0))
    free_allowance_pct = float(data.get("gps_free_dead_pct", 0.20))  # 20% free dead miles allowance
    penalty_rate = float(data.get("gps_penalty_rate", 3.0))  # ₹3 per excess dead KM
    
    ideal_allowance = round(total_trip_km * (1.0 + free_allowance_pct), 2)
    dead_km = max(0.0, round(gps_total_km - ideal_allowance, 2))
    dead_penalty = round(dead_km * penalty_rate, 2)
    
    # Summary Totals
    total_deductions = round(vehicle_rent + maintenance_charge + tds_amount + challan_amount + accident_charge + dead_penalty - other_adjustment, 2)
    
    # Net Outstanding Balance Calculation
    current_period_os = round(total_deductions + total_cash_collected - total_incentives, 2)
    total_due = round(current_period_os + prev_os, 2)
    
    to_collect = max(0.0, total_due)
    to_pay = max(0.0, -total_due)
    
    return {
        "days_count": days_count,
        "vehicle_rent": vehicle_rent,
        "maintenance_charge": maintenance_charge,
        "total_gross_earnings": total_gross,
        "total_incentives": total_incentives,
        "total_cash_collected": total_cash_collected,
        "tds_amount": tds_amount,
        "challan_amount": challan_amount,
        "accident_charge": accident_charge,
        "other_adjustment": other_adjustment,
        "gps_total_km": gps_total_km,
        "gps_dead_km": dead_km,
        "gps_dead_penalty": dead_penalty,
        "total_deductions": total_deductions,
        "current_period_os": current_period_os,
        "previous_outstanding": prev_os,
        "total_due": total_due,
        "to_collect": to_collect,
        "to_pay": to_pay,
        "status": "to_collect" if to_collect > 0 else "settled_pay"
    }
