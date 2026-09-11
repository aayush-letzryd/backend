# Resolved Rental Engine Data Issues & Edge Cases

### 1. Elimination of "0-99999 Trips"
* **Issue**: Earlier iterations introduced synthetic `0-99999` trip ranges for flat plans.
* **Resolution**: Completely eliminated. Flat / All-Platform plans have `min_trips = 0, max_trips = NULL, trip_slab_label = 'Flat / All Platform'`.

### 2. Side-Table Operator Agreements
* **Issue**: All-Platform and Fixed-Rent operators in side tables were missed by column A–E readers.
* **Resolution**: Ingestion now scans all side tables across HYD (Cols G–J, L–Q), MUM (Cols D–F, H–N), and BLR (Cols F–H, J–M). All 511 partners are stored in `sheet_rental_partners`.

### 3. Indemnity Storage Policy
* **Issue**: Indemnity was incorrectly forced into rate-card slabs.
* **Resolution**: Rate cards have `daily_indemnity = 0.00`. Indemnity is stored per agreement in `core_rent.custom_daily_indemnity`:
  - BLR: Standard ₹30, Nisamudeen ₹15, Rishad ₹20.
  - HYD: Standard ₹30, Hyundai Xcent ₹0, Shaik Kareem ₹0.
  - MUM: ₹30 Insurance Amount.
