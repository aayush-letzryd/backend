# LetzRyd Rental Final Tables & Calculation Engine

This directory contains the production schema, master seeding pipeline, and automation calculation engine for the LetzRyd Rental Engine.

---

## 1. System Architecture (5 Tables)

```
[ Google Sheet: 1xnGg3qhb1AnCP2Qv6e2gmd0zCi5j-bNbx9yDc7etzf4 ]
                             │ (30-min sync)
                             ▼
               ┌───────────────────────────────┐
               │     sheet_rental_slabs        │ (Live rate cards from sheet)
               │    sheet_rental_partners      │ (511 active partner agreements)
               └──────────────┬────────────────┘
                              │
                              ▼
               ┌───────────────────────────────┐
               │          core_rent            │ (Master vehicle-partner contract)
               │       core_rent_logs          │ (Immutable audit trail of changes)
               └──────────────┬────────────────┘
                              │ + Daily Attendance (sheet_vehicle_status)
                              │ + Weekly Trips (Uber / Ola)
                              ▼
               ┌───────────────────────────────┐
               │        daily_rent_log         │ (Daily ledger & hisaab settlement)
               └───────────────────────────────┘
```

---

## 2. Mathematical Formula

For every active vehicle on any billable day:
$$\text{net\_daily\_rent} = \text{applied\_daily\_rent} + \text{applied\_daily\_indemnity}$$

At weekly hisaab settlement:
$$\text{Net Weekly Rent} = (\text{Daily Rent} \times \text{On-road Days}) + (\text{Daily Indemnity} \times \text{On-road Days})$$

### City-Specific Indemnity Policies:
* **Bangalore**: Standard ₹30.00/day. Special negotiated deals: Nisamudeen K P = ₹15.00/day; Rishad P V = ₹20.00/day.
* **Hyderabad**: Standard ₹30.00/day. Retired fleet: Hyundai Xcents = ₹0.00/day; Shaik Kareem = ₹0.00/day.
* **Mumbai**: ₹30.00/day (integrated into daily revenue share as "Insurance").

---

## 3. Scripts & Execution

1. **Apply Schema**:
   ```bash
   psql -h 35.200.196.113 -U postgres -d postgres -f schema.sql
   ```

2. **Seed Master Contracts**:
   ```bash
   python seed_core_rent.py
   ```

3. **Run Health & Integrity Audit**:
   ```bash
   python automation_script.py --audit
   ```

4. **Verify Historical Parity**:
   ```bash
   python verify_hisaabs.py
   ```
