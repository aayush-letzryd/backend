# Vehicle Allocation Dataset: Standardization Rules & Issue Catalog

This document catalogs all 24 data anomalies identified in the Google Sheets `Vehicle Allocation` dataset and records the exact standardization rules implemented in PostgreSQL (`public.sheet_vehicle_allocations`) and the Google Apps Script ingestion pipeline.

---

## 1. Issue Catalog & Resolution Matrix

| Issue ID | Variable / Column | Issue Category | Operational Decision | Code Standardization Implementation |
|---|---|---|---|---|
| **ISS-01** | Sheet Structure | Embedded Duplicate Header Rows | Filter duplicate headers | Exclude any row where `str(Timestamp).strip().lower() == 'timestamp'` or `Date Of Allocation == 'Date Of Allocation'`. |
| **ISS-02** | Unnamed: 34 (Col AI) | Unheadered Google Form field for driver rental plans | Rename to `rental_plan` | Renamed column to `rental_plan`. Stripped strings, converted `'-'` and whitespace to `NULL`. |
| **ISS-03** | Columns AJ to AL | Ghost columns with formatting but no data | Exclude trailing ghost columns | Sliced dataset to columns A through AI (35 columns). Dropped all phantom columns beyond AI. |
| **ISS-04** | Driver Phone number | Stored as numeric float (e.g. `9845261331.0`) | Normalize to 10-digit text | Stripped `.0`, extracted all digits, formatted rightmost 10 digits as string `VARCHAR(20)`. |
| **ISS-05** | Multiple Columns | Legacy 'Old Data' rows with `'-'` placeholders | Keep 'Old Data', convert `'-'` to NULL | Retained email as `'Old Data'`; converted `'-'` across numeric, media, and checklist columns to `NULL`. |
| **ISS-06** | Operator ID vs Phone | 40 rows where embedded phone differs from Driver Phone | Fix typos (Group A), keep Operator accounts (Group B) | **Group A**: Corrected 6 rows with 1-digit typos (rows 112, 1386, 1452, 3110, 3443, 3495) to match verified phone. **Group B**: Preserved as-is (legitimate operator-driver fleet arrangements). |
| **ISS-07** | Operator/Driver ID | Non-conforming syntax (`LETZMUM967686669` and `LETZOWNMUM`) | Standardize syntax | Repaired 9-digit ID to 10 digits (`LETZMUM9967686669`); converted `LETZOWNMUM` prefix to standard `LETZMUMOP`. |
| **ISS-08** | Vehicle Number | Typographical letter 'O' substituted for numeral '0' | Auto-correct transcription typo | Standardized `TGO7X9865` to `TG07X9865` using regex replacement `^([A-Z]{2})O([0-9])` -> `\g<1>0\2`. |
| **ISS-09** | Vehicle Number | Mixed and lowercase vehicle registration numbers | Standardize to uppercase | Stripped whitespace and hyphens, converted all registration numbers to uppercase alphanumeric. |
| **ISS-10** | Driver Name | Operator ID pasted into driver name field (`LETZMUMIP9004200105`) | Correct to canonical name | Backfilled driver name to canonical fleet entity name `Gaadylo Enterprises`. |
| **ISS-11** | Driver Name | City hub code prefix (`MUM_`, `BLR_`, `HYD_`) | Strip city prefixes | Applied regex `re.sub(r'^(?:MUM|BLR|HYD)_\s*', '', name, flags=re.I)`. |
| **ISS-12** | Driver Name | Embedded tab characters and excessive spaces | Normalize whitespace | Replaced `\t` and multiple spaces with a single space, trimmed edges. |
| **ISS-13** | Driver Name | Inconsistent casing across rows | Standardize to Title Case | Converted all driver names to Title Case (`Name.title()`). |
| **ISS-14** | Driver Name | Punctuation anomalies (double dots `..`) | Clean punctuation | Replaced `..` with single dot `.`. |
| **ISS-15** | Type (Partner Type) | Lowercase `operator` and missing values | Standardize casing | Standardized `operator` to `Operator`. Missing values retained as `NULL`. |
| **ISS-16** | OLA Negative Amount | 738 positive balances alongside 2,298 negative balances | Keep positive and negative balances | Stored as `NUMERIC(12, 2)` preserving the recorded sign (both positive credits and negative debts). |
| **ISS-17** | OLA Negative Amount | String `'-'` placeholders for missing balances | Convert `'-'` to NULL | Coerced string placeholders `'-'` to SQL `NULL`. |
| **ISS-18** | Photos & Agreements | Missing inspection photos and lease agreements | Allow NULL for missing media | Valid URLs preserved; missing or `'-'` placeholders converted to `NULL`. |
| **ISS-19** | Tool Checklists | `'-'` placeholders across 9 handover checklist items | Convert `'-'` to NULL | Converted `'-'` to `NULL`; values stored as `VARCHAR(50)`. |
| **ISS-20** | Kms Reading | Negative odometer readings and phone numbers entered in odometer | Standardize odometer logic | Negative numbers set to `0`; values > 500,000 km set to `NULL`; `'-'` converted to `NULL`. Stored as `INTEGER`. |
| **ISS-21** | Primary Key Duplicates | 26 duplicate groups matching `(Date Of Allocation, Vehicle Number, Driver Phone)` | Keep Latest by Timestamp | Deduplicated using **Keep Latest by Timestamp**: latest submission updates earlier record in place via PostgreSQL UPSERT. |
| **ISS-22** | Driver Plan vs Type | Cross-column plan taxonomy variations (`LIP` vs `Fixed`/`Uber - TBS`) | Preserve as-is | Stored raw values as entered per operational direction. |
| **ISS-23** | Date vs Timestamp | Allocations dated after form submission timestamp | Preserve as-is | Retained as valid forward-dated allocations. |
| **ISS-24** | Email address | Personal employee Gmail accounts and `'Old Data'` | Preserve as-is | Retained as-is for historical operational tracking. |
| **ISS-25** | Allocation Type | Drop-Off records entered into Allocation dataset | Filter Drop-Off records | Exclude any row where `LOWER(TRIM(allocation_type)) == 'drop-off'` (`return null;`) so only legitimate allocations enter `sheet_vehicle_allocations`. |

