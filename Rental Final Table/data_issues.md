# Rental Final Table: Edge Cases & Business Rules

Empirically audited edge cases handled in `core_rent` and `daily_rent_log`.

---

## 1. Grounded & Workshop Vehicles (Zero On-Road Days)
- Any vehicle with 0 on-road days in `core_daily_vehicle_status` receives **INR 0.00** daily rent and **INR 0.00** indemnity (`is_billable_day = FALSE`).

## 2. Non-Uber / All-Platform Drivers
- Drivers on Ola, Rapido, or All-Platform agreements incur the flat contractual daily rate of **INR 1,050.00/day** regardless of trip count.

## 3. Custom Operator Flat Deals
- Custom operator agreements override standard reducing slabs:
  - Shaik Kareem: INR 900.00/day rent, INR 0.00 indemnity
  - Siddiqul: INR 900.00/day rent, standard INR 30.00 indemnity
  - Khaja: INR 970.00/day rent, standard INR 30.00 indemnity
  - Nisamudeen: Standard reducing slabs, INR 15.00/day indemnity
