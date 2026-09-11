# Rental Google Sheet: Data Issues & Normalization Notes

Known quirks, column discrepancies, and normalization logic applied during synchronization from Google Sheet `1xnGg3qhb1AnCP2Qv6e2gmd0zCi5j-bNbx9yDc7etzf4`.

---

## 1. Column Naming Inconsistencies Across City Tabs

| Tab Name | Vendor Name Column | Vendor Code Column | Plan Column | Platform Column | Plan Type Column |
|---|---|---|---|---|---|
| `HYD - Driver platform` | `Vendor Name` | `Vendor Code` | `Plan` | `Platform` | `Plan Type as per HISAAB` |
| `MUM - Driver platform` | `Vendor Name` | `Vendor Code` | `Plan` | *(Missing / Implicit Uber)* | `Plan Type as per HISAAB` |
| `BLR - Driver platform` | `Vendor Name` | `Vendor Code` | *(Implicit Individual)* | *(Implicit Uber)* | `Plan Type as per HISAAB` |

---

## 2. Custom Operator Deals & Flat Rate Rules

- **Shaik Kareem (`LETZHYDIP9885838038`)**: Flat INR 900/day rent, INR 0/day indemnity (retired Hyundai Xcent fleet).
- **Siddiqul (`LETZHYDIP9848529242`)**: Flat INR 900/day rent.
- **Khaja (`LETZHYDIP7396655106`)**: Flat INR 970/day rent.
- **Nisamudeen (`LETZBLRIP9035252877`)**: Standard rental with reduced INR 15/day indemnity.
- **All Platform Drivers (`All Platform` in plan)**: Flat contractual rate of INR 1,050/day across all cities.
