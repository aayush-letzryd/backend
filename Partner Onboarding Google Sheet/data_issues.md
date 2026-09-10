# LetzRyd Partner Onboarding Live Pipeline - Data Quality Audit & Issues Specification

This document provides a comprehensive audit of all 47 data quality anomalies (ISS-16 through ISS-62) identified during the analysis of the LetzRyd raw partner onboarding Google Sheet (`Onboarding form_V2`) in `Master_Issue_Standardization_Catalog.xlsx`, and details the exact standardization logic implemented in `partner_onboarding_pipeline_appscript.js` and `schema.sql`.

---

## Complete Issue Catalog (ISS-16 through ISS-62)

### 1. Partner Identifier Creation & Formula Breakdown (ISS-16 to ISS-21)

#### ISS-16: Formula Breakdown (`Invalid` String) in Partner ID
- **Affected Column**: `ID s Creations`
- **Raw Anomaly**: `=IF()` formulas in Google Sheets returned literal `"Invalid"` strings when referenced rows had formatting glitches or trailing decimals in phone columns.
- **Standardization Rule**:
  Deterministic ID generator generates valid IDs dynamically using city code and 10 clean phone digits: `LETZ` + `CITY_CODE` + `10_DIGIT_PHONE` (e.g. `LETZBLR9380465352`).

#### ISS-17: Missing / Blank Partner ID
- **Affected Column**: `ID s Creations`
- **Raw Anomaly**: Onboarding submissions through mobile sheets frequently lacked formula propagation, leaving the ID blank.
- **Standardization Rule**:
  `generatePartnerId(city, phone)` automatically constructs the standardized alphanumeric identifier on ingestion.

#### ISS-18: Manual Copy-Paste Typo in Sheet
- **Affected Column**: `ID s Creations`
- **Raw Anomaly**: Operators manually pasted IDs from other rows, causing ID-to-phone mismatch (e.g., driver phone `9985684872` had ID `LETZBLR9952531316`).
- **Standardization Rule**:
  Overwrites any erroneous copy-pasted string with the row's own validated mobile number and city prefix.

#### ISS-19: Duplicate ID on Re-onboarded Drivers
- **Affected Column**: `ID s Creations`
- **Raw Anomaly**: Drivers re-joining the fleet created duplicate IDs across multiple rows.
- **Standardization Rule**:
  `core_partner_onboarding` deduplicates on `phone_number`, updating profile metadata while maintaining historical record pointers in `sheet_driver_onboarding`.

#### ISS-20: Duplicate ID on Shared Phone Collision
- **Affected Column**: `ID s Creations` / `Driver Phone Number`
- **Raw Anomaly**: Two distinct drivers onboarded using the same phone number (family/operator shared phones).
- **Standardization Rule**:
  Sanitizer enforces 10-digit extraction and updates profile attributes while logging shared identity flags in the database.

#### ISS-21: Redundant Formula Helper Columns (`Duplicate Check`)
- **Affected Column**: `Duplicate Check`
- **Raw Anomaly**: Spreadsheet helper formulas (`=COUNTIF(...)`) created cell overhead and slowed sheet loading.
- **Standardization Rule**:
  Dropped during ETL ingestion. Deduplication is enforced natively by PostgreSQL `UNIQUE (submission_timestamp, driver_phone)` constraints.

---

### 2. Driver Demographics & Identity (ISS-22 to ISS-35)

#### ISS-22: Lowercase 'operator' Casing Typo
- **Affected Column**: `Onboarding Type`
- **Raw Anomaly**: Inconsistent entries such as `operator`, `OPERATOR`, `individual`, `driver`.
- **Standardization Rule**:
  Standardized to canonical Title Case (`'Operator'` or `'Individual'`).

#### ISS-23: Driver Name Whitespace & Formatting Variations
- **Affected Column**: `Driver Name`
- **Raw Anomaly**: Leading/trailing whitespace, stray quotes, double spaces, and diacritics.
- **Standardization Rule**:
  Unicode NFKD normalization strips accents (`.normalize("NFKD")`), collapses spaces, and formats text to uppercase.

#### ISS-24: Missing Father Name
- **Affected Column**: `Driver Father Name`
- **Raw Anomaly**: Blank cells on initial form entries.
- **Standardization Rule**:
  Stored as SQL `NULL` and flagged for back-office extraction from Aadhaar scans.

#### ISS-25: Missing WhatsApp Number
- **Affected Column**: `WhatsApp Phone Number`
- **Raw Anomaly**: Blank WhatsApp field when drivers operate single mobile numbers.
- **Standardization Rule**:
  Defaults automatically to the primary validated `Driver Phone Number`.

#### ISS-26: Self-Referencing Emergency Number
- **Affected Column**: `Emergency Phone number`
- **Raw Anomaly**: Drivers entered their own mobile number as their emergency contact.
- **Standardization Rule**:
  Sanitizer cleans number to 10 digits; flagged in database if identical to primary phone.

#### ISS-27: Missing Emergency Name
- **Affected Column**: `Emergency Name`
- **Raw Anomaly**: Blank emergency contact name.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-28: Self-Referencing Reference Number
- **Affected Column**: `Reference Number`
- **Raw Anomaly**: Drivers listed their own phone as guarantor reference.
- **Standardization Rule**:
  Extracted as clean 10 digits; flagged if matching driver phone.

#### ISS-29: Missing / Placeholder 'Na' Reference Name
- **Affected Column**: `Reference Name`
- **Raw Anomaly**: Placeholders like `Na`, `NA`, `None`, `-`.
- **Standardization Rule**:
  Transformed to SQL `NULL`.

#### ISS-30: Missing Date of Birth
- **Affected Column**: `Driver Date of Birth (dd/mmm/yy)`
- **Raw Anomaly**: Blank DOB cells.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-31: Unparseable Text Dates
- **Affected Column**: `Driver Date of Birth (dd/mmm/yy)`
- **Raw Anomaly**: Mixed formats including `15-Aug-1994`, `15/08/1994`, `1994-08-15`, and serial integers.
- **Standardization Rule**:
  `parseDateTime()` handles DD/MM/YYYY, DD-MMM-YY, ISO timestamps, and Excel serial date numbers into standard SQL `DATE`.

#### ISS-32: Future Birth Dates (Birth Year Typo)
- **Affected Column**: `Driver Date of Birth (dd/mmm/yy)`
- **Raw Anomaly**: Typo entering current year (e.g. `2024` instead of `1994`).
- **Standardization Rule**:
  Parser detects 2-digit years and applies century offsets (>50 -> 1900s, <=50 -> 2000s).

#### ISS-33: Underage Drivers (<18 Years Old)
- **Affected Column**: `Driver Date of Birth (dd/mmm/yy)`
- **Raw Anomaly**: Calculated driver age below 18 years.
- **Standardization Rule**:
  Flagged in database compliance checks (`is_documents_verified = FALSE`).

#### ISS-34: Missing Permanent Address
- **Affected Column**: `Driver Address As per Aadhar`
- **Raw Anomaly**: Blank permanent address text.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-35: Missing Local Present Address
- **Affected Column**: `Driver Present Address`
- **Raw Anomaly**: Driver did not enter a separate local residence.
- **Standardization Rule**:
  Defaults automatically to the permanent `Aadhaar Address`.

---

### 3. Government ID & Document Compliance (ISS-36 to ISS-48)

#### ISS-36: Missing PAN Number
- **Affected Column**: `Driver PAN Number`
- **Raw Anomaly**: Blank PAN field.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-37: Invalid PAN Regex Format
- **Affected Column**: `Driver PAN Number`
- **Raw Anomaly**: Minor typos, lowercase letters, stray spaces.
- **Standardization Rule**:
  Converts to uppercase and validates against standard regex `^[A-Z]{5}[0-9]{4}[A-Z]$`.

#### ISS-38: Duplicate PAN Across Multiple Records
- **Affected Column**: `Driver PAN Number`
- **Raw Anomaly**: Fleet operators or re-joining drivers sharing PAN numbers.
- **Standardization Rule**:
  Deduplicated in `core_partner_onboarding` with relational index on `pan_number`.

#### ISS-39: Missing Aadhaar Number
- **Affected Column**: `Driver Aadhaar Number`
- **Raw Anomaly**: Blank Aadhaar field.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-40: Invalid Aadhaar Length (Not 12 Digits)
- **Affected Column**: `Driver Aadhaar Number`
- **Raw Anomaly**: Spaces, hyphens, and trailing decimal `.0`.
- **Standardization Rule**:
  Strips all non-digits and `.0+` decimals to extract 12 clean digits.

#### ISS-41: Duplicate Aadhaar Numbers
- **Affected Column**: `Driver Aadhaar Number`
- **Raw Anomaly**: Duplicate entries for same driver.
- **Standardization Rule**:
  Unified under the master partner record.

#### ISS-42: Missing Driving License Number
- **Affected Column**: `Driving License Number`
- **Raw Anomaly**: Blank DL field on inquiry stage.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-43: Duplicate DL Numbers Across Records
- **Affected Column**: `Driving License Number`
- **Raw Anomaly**: Multiple entries for re-onboarded drivers.
- **Standardization Rule**:
  Indexed and consolidated in master core table.

#### ISS-44: Special Greek Character Typo (Homoglyphs)
- **Affected Column**: `Driving License Number`
- **Raw Anomaly**: Greek lookalike characters (e.g. Greek `\u039A` Kappa instead of ASCII `K`).
- **Standardization Rule**:
  Automatic homoglyph transliteration replaces non-Latin lookalikes with standard ASCII characters.

#### ISS-45: Expiry Date Entered in DL Number Column / Column Inversion
- **Affected Column**: `Driving License Number` / `Driving License Expiry Date`
- **Raw Anomaly**: Date strings or Date objects entered into DL column, or index inversion between Column 19 (DL Number) and Column 20 (DL Expiry Date).
- **Standardization Rule**:
  `sanitizeDL()` rejects Date objects and date-like strings (e.g. `SATSEP...`, `GMT`). `parseRow()` performs intelligent cross-column auto-detection: if Column 19 contains a Date and Column 20 contains an alphanumeric string, the pipeline automatically routes Column 19 to `dl_expiry` and Column 20 to `dl_number`. Expired or out-of-range dates outside `[1990, 2060]` are clamped to SQL `NULL`.

#### ISS-46: Missing DL Expiry Date
- **Affected Column**: `Driving License Expiry Date`
- **Raw Anomaly**: Blank expiry date.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-47: Expired Driving Licenses
- **Affected Column**: `Driving License Expiry Date`
- **Raw Anomaly**: Expiry date in the past.
- **Standardization Rule**:
  Parsed into SQL `DATE` for automated expiry tracking queries.

#### ISS-48: Missing PAN <> Aadhaar Link Status
- **Affected Column**: `Pan <> Aadhar Card link Status`
- **Raw Anomaly**: Blank link status.
- **Standardization Rule**:
  Defaults to `'Pending'` / SQL `NULL`.

---

### 4. Banking, Payouts & Referrals (ISS-49 to ISS-58)

#### ISS-49: Physical Address Text in IFSC Column
- **Affected Column**: `IFSC Code`
- **Raw Anomaly**: Branch street address entered into IFSC field.
- **Standardization Rule**:
  Sanitizer validates 11-char alphanumeric code; invalid text stored as NULL.

#### ISS-50: Dummy Placeholder Zeros in IFSC
- **Affected Column**: `IFSC Code`
- **Raw Anomaly**: Dummy values like `00000000000`.
- **Standardization Rule**:
  Rejected and set to SQL `NULL`.

#### ISS-51: Missing 5th Zero in IFSC Code
- **Affected Column**: `IFSC Code`
- **Raw Anomaly**: 10-character IFSC codes missing the required 5th zero (e.g. `SBIN123456`).
- **Standardization Rule**:
  Auto-repairs known bank patterns by inserting `'0'` at index 4 (`SBIN0123456`).

#### ISS-52: Missing Bank Details (Null IFSC)
- **Affected Column**: `IFSC Code`
- **Raw Anomaly**: Blank IFSC.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-53: Missing Bank Account Number
- **Affected Column**: `Account No`
- **Raw Anomaly**: Blank account number.
- **Standardization Rule**:
  Stored as SQL `NULL`.

#### ISS-54: Scientific Notation Export Formatting in Account No
- **Affected Column**: `Account No`
- **Raw Anomaly**: Google Sheets exported big integer bank accounts in scientific notation (`6.73738E+10`).
- **Standardization Rule**:
  `sanitizeAccountNumber()` converts scientific notation floats into full un-truncated integer strings.

#### ISS-55: Third-Party Bank Account Discrepancies
- **Affected Column**: `As per Account Name`
- **Raw Anomaly**: Account holder name differs from driver name (spouse/operator account).
- **Standardization Rule**:
  Stored in `account_name` alongside `driver_name` for audit reconciliation.

#### ISS-56: Mixed UPI Handles & Unstructured Text
- **Affected Column**: `Account Details of the Driver / UPI Id`
- **Raw Anomaly**: Free-form text mixed with UPI IDs.
- **Standardization Rule**:
  Regex extracts valid handle (`@ybl`, `@okaxis`, `@paytm`, `@upi`, `@icici`).

#### ISS-57: Mixed String / Currency Formatting in Deposit Amount
- **Affected Column**: `Deposit Paid + Joining fees`
- **Raw Anomaly**: Values like `₹14,500`, `22500`, `11000 + 3500`.
- **Standardization Rule**:
  `parseDepositAmount()` strips currency symbols and computes arithmetic sums (`11000 + 3500` -> `14500.00`).

#### ISS-58: Composite Referral Strings
- **Affected Column**: `Referral Refer ID`
- **Raw Anomaly**: Composite text strings like `'6300711880 (KABIR)'`.
- **Standardization Rule**:
  `parseReferral()` separates phone (`'6300711880'`) and name (`'KABIR'`) into distinct columns.

---

### 5. Document Links & Sheet Structure (ISS-59 to ISS-62)

#### ISS-59: Legacy '-' Placeholders Instead of URLs
- **Affected Columns**: Columns 23-31 (Document links)
- **Raw Anomaly**: Historical records filled with `'-'`.
- **Standardization Rule**:
  `sanitizeDocUrl()` converts `'-'` and `'na'` into SQL `NULL`.

#### ISS-60: Folder URLs vs Direct File URLs
- **Affected Columns**: Columns 23-31 (Document links)
- **Raw Anomaly**: Drive folder links vs direct image links.
- **Standardization Rule**:
  Valid HTTP/HTTPS links are preserved cleanly.

#### ISS-61: Form Pre-Fill Formulas
- **Affected Columns**: `Collection Form`, `Vehicle Allocation Form`, `Adjustment-Form`, `Drop Off Form`
- **Raw Anomaly**: Spreadsheet helper pre-fill formulas.
- **Standardization Rule**:
  Dropped from database schema (handled dynamically by portal).

#### ISS-62: Ghost & Formula Columns
- **Affected Columns**: `Unnamed: 43-46`, `Mapping`, `Logic`, `Code`
- **Raw Anomaly**: Empty export columns and local lookup tables.
- **Standardization Rule**:
  Dropped during ETL ingestion.
