# Hisaab Business Rules, Mathematical Formulas & Audit Reference

This document codifies the exact financial calculations, regulatory deductions, and audit findings derived directly from LetzRyd's production Hisaab workbooks across **Bengaluru (BLR)**, **Hyderabad (HYD)**, and **Mumbai (MUM)** for **Weeks 26 and 27**.

---

## 1. Operational Ingestion Architecture & Calendar Boundaries

1. **Next-Day Morning Automated Ingestion**:
   - Telemetry and platform feeds are automatically pulled the following morning for the previous calendar day:
     * **GPS Telematics**: Pulled at **04:00 AM IST** for yesterday (`record_date`).
     * **Uber Telemetry**: Pulled at **07:00 AM IST** for yesterday (`trip_date`, `trx_date`), with automated retries between 06:00 AM and 10:00 AM.
     * **Ola Telemetry**: Pulled at **07:00 AM IST** for yesterday (`service_date`), with automated retries between 06:00 AM and 10:00 AM.
   - Because each feed is already partitioned by the platform provider for "yesterday", no artificial 4-hour shift is applied. Each feed maps directly to its calendar date (`log_date`, `trip_date`, `service_date`, `record_date`).
2. **The Settlement Week Window**:
   - Runs from **Monday through Sunday** (7 calendar days: `week_start` Monday to `week_end` Sunday).
3. **The Monday 11:00 AM Lock Cutoff**:
   - The entire past week freezes at **Monday 11:00:00 AM IST** (`lock_cutoff_at`).
   - Once locked, statements become **immutable** (`is_locked = TRUE`), and late adjustments automatically divert into the upcoming open billing cycle.

---

## 2. Rental & Indemnity Rules

1. **Daily Net Lease Rent**:
   $$\text{Net Daily Rent} = \begin{cases} 
   0, & \text{if attendance is Maintenance, Breakdown, or RFD (Non-Billable)} \\
   \text{Daily Rent Applied} + \text{Daily Indemnity Fee}, & \text{if Active on road}
   \end{cases}$$
2. **City Indemnity Fee Exceptions**:
   - **Bengaluru (BLR)**: Standard is **₹30/day**.
     - Special deal: `LETZBLRIP9036461336` (Nisamudeen) $\to$ **₹15/day**.
     - Special deal: `LETZBLRIP9656907001` (Rishad) $\to$ **₹20/day**.
   - **Hyderabad (HYD)**: Standard is **₹30/day**.
     - Hyundai Xcent models $\to$ **₹0/day** indemnity.
     - Special deal: `LETZHYDIP9701685282` (Shaik Kareem Xcent) $\to$ **₹0/day**.
   - **Mumbai (MUM)**: Standard is **₹30/day** insurance/indemnity.

---

## 3. Platform Financial Formulations

### 3.1 Uber Net Balance (`uber_week_os`)
* **Gross Fares**: `net_fare_earnings` (positive).
* **Cash Collected**: Stored as a **negative number** in raw feeds (representing cash pocketed by the driver).
* **Formula**:
  $$\text{Uber Week Balance} = -(\text{Total Fare Earnings} + \text{Cash Collected [negative]} + \text{Tolls} - \text{Subscription Charges})$$
* **Interpretation**:
  - If a driver collected more cash than his fare earnings (e.g. earned ₹13,000, collected ₹14,200 cash), the sum inside the parenthesis is $-₹1,200$.
  - Taking the negative yields **$+₹1,200$** $\to$ Driver owes this excess cash back to LetzRyd.
  - If the driver collected less cash than digital earnings, the output is **negative** $\to$ Offsets and pays down his vehicle lease rent!

### 3.2 Ola Net Balance (`ola_week_os`)
* **Net Revenue**: Evaluated directly from `operator_bill_raw` (net of Ola commission).
* **Online Payment**: Cash deposited by the driver directly to Ola reduces driver dues.
* **GST (BLR Only)**: In Bengaluru, 5% GST is recognized on Ola net revenue (`ola_net_revenue * 0.05`).

### 3.3 Platform Weekly Milestone Incentives
* Target milestone bonuses (e.g., 70 trips $\to$ ₹1,500 bonus) are evaluated on a **full-week milestone basis**.
* In `hisaab_daily_ledger`, Monday through Saturday rows reflect **₹0**, while the Driver Mobile App displays a pacing meter.
* On **Sunday's row (`log_date = week_end`)**, the earned weekly incentive bonus is posted into `weekly_incentive_credit`, which immediately credits into the driver's weekly payout.

---

## 4. Statutory & Operational Deductions

### 4.1 Statutory TDS (Section 194C)
Under Indian Income Tax regulations:
* **Fleet Operators**: **₹0 TDS** deducted at the vehicle level (operators are corporate entities billed via commercial invoice).
* **Individual Drivers**: **1% TDS** on positive net driving revenue (gross platform earnings minus vehicle rental):
  $$\text{TDS} = \begin{cases}
  0, & \text{if Partner Type} = \text{'Operator'} \\
  0, & \text{if } (\text{Platform Earnings} - \text{Lease Rent}) \le 0 \\
  (\text{Platform Earnings} - \text{Lease Rent}) \times 0.01, & \text{if positive}
  \end{cases}$$

### 4.2 Dead Mile Telematics Penalty (GPS)
To prevent vehicle misuse:
1. $\text{Ideal GPS KM} = \text{Platform In-Trip KM} + (\text{Completed Trips} \times 3\text{ km}) + (\text{Active Days} \times 30\text{ km})$
2. $\text{Dead Mile KM} = \max(0, \text{Total Odometer GPS KM} - \text{Ideal GPS KM})$
3. **Charge**: Charged at **₹3 per dead km** for individual drivers (`Partner Type = 'Individual'`).

---

## 5. Audit Locking & Prior-Period Routing

1. **In-Week Window (Days 1 to 7)**:
   - Any adjustment, repair bill, or traffic fine occurring within the active week updates that specific day in `hisaab_daily_ledger` and `hisaab_vehicle_weekly`.
2. **Post-Monday 11:00 AM (Locked Week)**:
   - If an event from a past, locked week is submitted:
     - The past week's statement remains **100% immutable**.
     - The record is inserted into `hisaab_adjustments_ledger` with `is_prior_period = TRUE` and `settlement_week_id = CURRENT_ACTIVE_WEEK`.
     - It rolls into the upcoming week's `hisaab_partner_weekly` under `prior_period_adjustments`.
