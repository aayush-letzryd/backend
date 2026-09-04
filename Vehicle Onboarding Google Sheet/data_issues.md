# Vehicle Onboarding Data Issues & Standardization Catalog

This document details all **29 operational abnormalities and data hygiene issues** identified in the unified 73-column master dataset (`Unified_Vehicle_onboarding_source`), covering the combined records of **Asset List - Pan India**, **Master Document Sheet**, and **Letzryd PDI New Vehicle** (1,619 total records).

---

## Catalog Summary Statistics
* **Total Merged Records Scanned**: 1,619
* **Total Columns Tracked**: 73
* **Primary Key**: `registration_no` (100% unique alphanumeric anchor)
* **Total Issues Documented**: 29
* **Zero Data Loss Rule**: 100% of vehicles and raw data points are preserved with appropriate nullable flags and child relationships.

---

## Master Issue Registry (`VEH-01` to `VEH-29`)

| Issue ID | Variable / Column | Issue Name & Category | MY INPUT | Proposed Code Standardization Rule | Affected Rows | % Dataset | Severity | Standardization Capability |
| :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: | :---: |
| **VEH-01** | `Sl` | Serial Number Data Type Variance | Spreadsheet sequence index. System creates auto-incrementing BIGSERIAL PK in Postgres. | Ignore source serial during ingestion and generate auto-incrementing `id BIGSERIAL PRIMARY KEY`. | 1618 | 99.9% | `LOW` | `FULLY AUTOMATED (CODE)` |
| **VEH-02** | `City` | City Name Standardization | Standardize 3 operating hubs (Bangalore, Mumbai, Hyderabad). Flag unmapped. | Apply `UPPER(TRIM(city))` and map to canonical city names. | 0 | 0.0% | `LOW` | `FULLY AUTOMATED (CODE)` |
| **VEH-03** | `Registered Owner Name` | Lessor Entity Standardization | 3 authorized leasing partners (Samvreeddhi, MBSI, Dbest). Normalize via lookup. | Map registered entity names to canonical lessor dimension. | 0 | 0.0% | `LOW` | `FULLY AUTOMATED (CODE)` |
| **VEH-04** | `Registration No` | Primary Key Format Sanitization | True primary key. Strip all spaces, hyphens, and convert to standard uppercase 10-char plate. | Apply `UPPER(TRIM(REGEXP_REPLACE(reg_no, r"[^A-Za-z0-9]", "")))`. Enforce UNIQUE constraint. | 0 | 0.0% | `CRITICAL` | `FULLY AUTOMATED (CODE)` |
| **VEH-05** | `Chassis No` | Chassis Number Length Validation | Sanitize special characters. If length != 17, route to quarantine. Never guess or drop car. | Validate `LENGTH(chassis_no) == 17`. Flag exceptions for ops RC smart card review. | 101 | 6.2% | `HIGH` | `HYBRID (CODE + OPS REVIEW)` |
| **VEH-06** | `Engine No` | Engine Number Whitespace Discrepancies | Remove internal whitespace to create clean continuous alphanumeric serial. | Apply `UPPER(TRIM(REGEXP_REPLACE(engine_no, r"\s+", "")))`. | 23 | 1.4% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-07** | `HP` | Hypothecation & Nil Normalization | "Nil" / "SAM-Nil" mapped to NULL. Standardize bank acronyms (MMFSL, AUSBL, Mufin). | If `hp IN ('NIL', 'SAM-NIL', 'NONE', '-')` THEN `NULL` ELSE map to financier lookup. | 430 | 26.6% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-08** | `Dealer` | Dealership Name Normalization | Map regional dealership variations to authorized OEM dealer master. | Apply `UPPER(TRIM(dealer))` and map to authorized dealership lookup. | 0 | 0.0% | `LOW` | `FULLY AUTOMATED (CODE)` |
| **VEH-09** | `Model` | Symmetric Model & Trim Decomposition | Decompose into 6 symmetric attributes: Make, Model, Trim, Fuel, Body, Segment. | Decompose model string symmetrically (e.g. Maruti Suzuki WagonR Tour H3 CNG). | 0 | 0.0% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-10** | `Vehicle Status` | Lifecycle Status Standardization | Standardize operational lifecycle states: DELIVERED, TOTAL_LOSS, RFD_NEW, SOLD. | Map to standard lifecycle status vocabulary. | 0 | 0.0% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-11** | `Delivery date` | Delivery Date Consistency | Valid NULL for Underregistration / RFD - New. Flag blank dates on Delivered status. | Cast to `DATE`. Log data quality warning if `status='Delivered'` and `delivery_date IS NULL`. | 47 | 2.9% | `MEDIUM` | `HYBRID (CODE + OPS REVIEW)` |
| **VEH-12** | `GPS` | Dual GPS Hardware Bundling | Dual devices (tracker + immobilizer) parsed into distinct device tracking records. | Split on `+` or `/`, trim vendor strings, map primary vs secondary tracking units. | 69 | 4.3% | `HIGH` | `HYBRID (CODE + OPS REVIEW)` |
| **VEH-13** | `Mfg MM/YY` | Manufacturing Date Formatting | Normalize month-year strings and timestamps into standard `YYYY-MM-01` date. | Parse mixed datetime serials and strings into `YYYY-MM-01`. Allow NULL for blanks. | 515 | 31.8% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-14** | `Financier & Ownership` | Lease Type Categorization | Classify into OPERATING_LEASE, BANK_FINANCE, OWNED and link financier ID. | Map Ownership to enum vocabulary and link financier entity. | 0 | 0.0% | `LOW` | `FULLY AUTOMATED (CODE)` |
| **VEH-15** | `Validity Dates (Cols 17-23)` | Statutory Validity & Expiry | Statutory validity dates cast to DATE; compute dynamic compliance status. | Cast valid dates to `DATE`; compute `compliance_status` (VALID, EXPIRING_SOON, EXPIRED). | 102 | 6.3% | `HIGH` | `HYBRID (CODE + OPS REVIEW)` |
| **VEH-16** | `LetzRyd Serial Number` | Duplicate Fleet Serial Collisions | Internal serials must be unique. Ingest using RegNo PK and flag serial collisions. | Ingest vehicle using `registration_no` as PK; log collision for ops re-tagging. | 62 | 3.8% | `CRITICAL` | `HYBRID (CODE + OPS REVIEW)` |
| **VEH-17** | `Registration Certificate` | RC Document URL Storage | Trim whitespace and validate Google Drive URLs. Store in document repository. | Trim whitespace, validate URL scheme (`https://drive.google.com/...`). | 98 | 6.1% | `HIGH` | `HYBRID (CODE + OPS REVIEW)` |
| **VEH-18** | `Fitness & Pollution (MDS)` | Brand New OEM Exemption | Brand new OEM vehicles have initial 1-2 yr validity built into RC. Null URLs valid at inception. | Set document URL to NULL; populate statutory validity from Asset List registration date. | 1511 | 93.3% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-19** | `Insurance Endorsement` | Optional Endorsement Null Handling | Endorsements only occur during midterm policy transfer. Null rate is normal and expected. | Design `insurance_endorsement` column as nullable without mandatory constraint. | 1618 | 99.9% | `LOW` | `FULLY AUTOMATED (CODE)` |
| **VEH-20** | `Invoice Copy` | Historical Invoice Backfill | Store available invoice URLs. Set `is_invoice_available = FALSE` for missing records. | Store valid URLs; finance team backfills OEM invoices for GST audits. | 1225 | 75.7% | `MEDIUM` | `HYBRID (CODE + OPS REVIEW)` |
| **VEH-21** | `Comments (MDS)` | Free-Text Operational Flags | Parse operational keywords ("Deleted", "Total Loss", "Sold") into structured audit tags. | Regex parse action keywords into structured audit entries. | 9 | 0.6% | `LOW` | `FULLY AUTOMATED (CODE)` |
| **VEH-22** | `PDI Columns (Cols 41-73)` | Legacy Fleet Pre-PDI Exemption | Vehicles onboarded before digital PDI rollout are legitimately exempt. | Set `is_pdi_completed=FALSE` and `pdi_status='NOT_APPLICABLE'` for legacy fleet. | 304 | 18.8% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-23** | `Kms Reading` | Odometer Unit Suffix Removal | Strip "km" strings and whitespace to extract clean numeric reading. | Apply `CAST(REGEXP_REPLACE(kms_reading, r"[^0-9.]", "") AS NUMERIC(10,2))`. | 31 | 1.9% | `HIGH` | `FULLY AUTOMATED (CODE)` |
| **VEH-24** | `Key Quantity` | Key Drive Photo URL Pasted | Extract Google Drive photo URL and default key count to 2 for new vehicles. | If starts with 'http', route to photo storage and assign default integer key count = 2. | 1315 | 81.2% | `HIGH` | `FULLY AUTOMATED (CODE)` |
| **VEH-25** | `Tyre Brand & Sl No` | Comma-Separated Multi-URLs | Split comma-separated tyre inspection photos into individual photo records. | Execute string split by comma, trim URLs, and store in tyre photo repository. | 822 | 50.8% | `HIGH` | `FULLY AUTOMATED (CODE)` |
| **VEH-26** | `Inventory Checklist` | Equipment Checklist Booleans | Standardize equipment items (Jack, Rod, Spanner, Triangle, Fire Extinguisher) to booleans. | Map "Yes"/"Y"/"1" -> TRUE, "No"/"N"/"0" -> FALSE, NULL -> FALSE. | 0 | 0.0% | `LOW` | `FULLY AUTOMATED (CODE)` |
| **VEH-27** | `Tracking Device Vendor` | PDI GPS Vendor String Literals | Parse compound vendor names ("WheelsEye+GOMYGPS") and map "Not Available" to NULL. | Parse compound vendors using regex; map "Not Available" to NULL. | 69 | 4.3% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-28** | `PDI Unique Vehicle no` | Floating Point Serial Numbers | Convert bare floating point serial numbers (621.0 -> "621") into clean serials. | Convert float to integer string; cross-reference with Master Docs serial. | 894 | 55.2% | `MEDIUM` | `FULLY AUTOMATED (CODE)` |
| **VEH-29** | `CNG Plate & Date` | CNG Cylinder Hydro-Test Compliance | Non-CNG models legitimately NULL. Flag missing CNG plate details on CNG models. | If `Model LIKE '%CNG%'` and `cng_plate IS NULL`, flag pending compliance status. | 1004 | 62.0% | `HIGH` | `HYBRID (CODE + OPS REVIEW)` |

---

## Architectural Principles Enforced in Pipeline

1. **Zero Data Loss**:
   - Every single vehicle in `Unified_Vehicle_onboarding_source` is loaded into `public.sheet_vehicle_onboarding`.
   - Records with missing PDI data or invoice URLs are preserved with clean nullable columns and appropriate status flags.
2. **Symmetric Model Taxonomy**:
   - Vehicle models are systematically decomposed into `Make`, `Model`, `Trim`, and `Fuel Type`.
3. **Primary Key Integrity**:
   - `registration_no` is sanitized using regex and used as the unique conflict target for upserts (`ON CONFLICT (registration_no) DO UPDATE`).
