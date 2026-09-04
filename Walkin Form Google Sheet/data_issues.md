# LetzRyd Walkin Form Live Pipeline - Data Quality Audit & Issues Specification

This document provides a comprehensive audit of all 24 data quality anomalies (ISS-01 through ISS-24) identified during the analysis of the LetzRyd walk-in Google Sheet (`walkin_form`) and details the precise standardization rules implemented in `walkin_pipeline_appscript.js`.

---

## Issue Catalog (ISS-01 through ISS-24)

### ISS-01: Attending Executive Typo & Casing Inconsistencies
- **Affected Column**: Column D (`Attending Executive`)
- **Raw Anomaly**: Executive names were entered with erratic casing, misspellings, and inverted name sequences (e.g. `shaikbdulla`, `abdullashaik`, `shaikadulla`, `psradhakrishna`, `radhakirshna`, `radha`).
- **Standardization Rule**:
  A canonical lookup map resolves known variants to the correct full employee identity:
  - `shaikabdulla`, `abdullashaik`, `shaikadulla`, `shaikbdulla` -> `Shaik Abdulla`
  - `radhakrishna`, `psradhakrishna`, `radhakirshna`, `radha` -> `Radha Krishna`
  For any executive not present in the map, whitespace is trimmed and words are formatted in standard Title Case (`word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()`).

### ISS-02: Attending Executive Trailing Whitespace & Stray Backticks
- **Affected Column**: Column D (`Attending Executive`)
- **Raw Anomaly**: Names contained accidental backticks, quotes, double spaces, and trailing carriage returns (e.g., `` `Shaik Abdulla ` `` or `'Kiran '`).
- **Standardization Rule**:
  Sanitizer applies `.replace(/[`'"]/g, "").trim().replace(/\s+/g, " ")` before lookup and title casing.

### ISS-03: Email Address Case Mismatches & Personal Accounts
- **Affected Column**: Column B (`Email Address`)
- **Raw Anomaly**: Mixed personal domains (`@gmail.com`) and corporate accounts (`@letzryd.com`) with inconsistent uppercase/lowercase characters.
- **Standardization Rule**:
  Emails are converted to lowercase and whitespace-trimmed. Empty strings and whitespace-only cells are converted to SQL `NULL`.

### ISS-04: Partner Name Whitespace, Accents & Casing
- **Affected Column**: Column E (`Partner Name`)
- **Raw Anomaly**: Partner names entered in mixed case, often with accents, leading spaces, or placeholder tokens like `NA`.
- **Standardization Rule**:
  Unicode NFKD normalization strips combining diacritical marks (`.normalize("NFKD").replace(/[\u0300-\u036f]/g, "")`), collapses multiple spaces, and converts to uppercase. Placeholder strings such as `NA` are strictly preserved to maintain full parity with the sheet and avoid row dropping.

### ISS-05: Partner Phone Floating-Point String Artifacts
- **Affected Column**: Column F (`Partner Number`)
- **Raw Anomaly**: Google Sheets formatting numeric phone columns as numbers exported values with trailing floating-point decimals, such as `"9845261331.0"` or `"9845261331.00"`.
- **Standardization Rule**:
  The sanitizer applies `.replace(/\.0+$/, "")` to strip trailing decimal zeros before non-digit stripping, ensuring the true phone digits are not offset or corrupted.

### ISS-06: Missing Driver License on Inquiry Visits
- **Affected Column**: Column G (`DL Number`)
- **Raw Anomaly**: Partner inquiries or initial visits often occur before driver license verification, resulting in blank cells.
- **Standardization Rule**:
  Column is marked nullable in PostgreSQL. Missing or empty license cells are bound as SQL `NULL` using `stmt.setNull(7, SQL_TYPES.VARCHAR)`.

### ISS-07: Driver License Formatting, Hyphens, Spaces & Accents
- **Affected Column**: Column G (`DL Number`)
- **Raw Anomaly**: Valid driving licenses contained arbitrary separators such as spaces, hyphens, and slashes (e.g. `AP 28 TE 1234`, `TS-09-2023-0001234`).
- **Standardization Rule**:
  All punctuation, hyphens, underscores, and spaces are removed (`.replace(/[\s\-_]/g, "")`), diacritics are stripped via NFKD, and text is converted to uppercase.

### ISS-08: Visiting Reasons Free-Text Diversity
- **Affected Column**: Column H (`Visiting Reasons`)
- **Raw Anomaly**: Visiting reasons encompass diverse business operations (e.g., `New Joining`, `Enquiry`, `Hisaab`, `Re-Joining`, `Drop Off`, `Car Swap Or Vehicle Maintenance`).
- **Standardization Rule**:
  Stored verbatim as entered (with whitespace trimming) in a PostgreSQL `TEXT` column. No restrictive ENUM is forced, guaranteeing future operational reasons will never throw a database constraint violation.

### ISS-09: Remarks Header Punctuation & Missing Notes
- **Affected Column**: Column I (`Remarks` / `Remark's`)
- **Raw Anomaly**: Sheet header contained an unescaped single quote (`Remark's`), and most rows had blank notes.
- **Standardization Rule**:
  Standardized in PostgreSQL as clean `remarks TEXT`. Empty strings and whitespace-only entries are mapped to SQL `NULL`.

### ISS-10: Joined Status Mixed Types & Boolean Representations
- **Affected Column**: Column K (`Joined Status`)
- **Raw Anomaly**: Contains string values (`Joined`, `joined`), boolean strings (`false`, `False`), and occasional custom operational notes.
- **Standardization Rule**:
  Standardizes capitalization (`joined` -> `Joined`, `false` -> `False`). Preserves operational context without forcing lossy 3-state boolean collapsing.

### ISS-11: Joined Date Formatting & Missing Dates for Inquiries
- **Affected Column**: Column J (`Joined Date`)
- **Raw Anomaly**: Formats include JavaScript Date objects, Google Sheets day serial numbers (e.g. `45376`), Indian `DD/MM/YYYY`, and ISO `YYYY-MM-DD`. Rows without a join date contain blank cells or placeholders like `NA`.
- **Standardization Rule**:
  Parsed into a standard ISO `YYYY-MM-DD` date string using `cleanDate()`. Placeholder strings (`na`, `none`, `nil`, `-`) and non-convertible strings map to SQL `NULL`.

### ISS-12: Absence of Explicit Partner ID Foreign Key
- **Affected Column**: Partner Entity Reference
- **Raw Anomaly**: Walk-in sheets do not possess an internal system `partner_id` foreign key.
- **Standardization Rule**:
  `sheet_walkins` deliberately avoids enforcing a strict foreign key to `partners.id`. Instead, the normalized 10-digit mobile number and standardized driving license serve as dual join keys for downstream reconciliation jobs.

### ISS-13: Ghost Blank Columns in Sheet
- **Affected Column**: Column 11 (Column L / `Unnamed: 11`)
- **Raw Anomaly**: Stray formatting in Google Sheets created empty trailing columns with null headers.
- **Standardization Rule**:
  Ingestion boundary strictly isolates columns 1 through 11 (A to K). Any columns beyond column 11 are excluded from data extraction.

### ISS-14: Dropdown Validation Dump Columns
- **Affected Column**: Column 12 (Column M / `Unnamed: 12`)
- **Raw Anomaly**: An operational dropdown source list was pasted into column M for in-sheet data validation.
- **Standardization Rule**:
  Filtered out during range fetching (`sheet.getRange(startRow, 1, numRows, 11)`), preventing operational metadata from leaking into the database.

### ISS-15: City Name Normalization & Hub Keywords
- **Affected Column**: Column C (`City`)
- **Raw Anomaly**: Cities entered as informal abbreviations or mixed casing (e.g., `hyd`, `HYDERABAD`, `blr`, `Bangalore`, `mumbai`).
- **Standardization Rule**:
  Keyword-based normalization:
  - Substring `hyd` -> `Hyderabad`
  - Substring `mum` -> `Mumbai`
  - Substring `blr`, `bang`, or `beng` -> `Bengaluru`
  - Other inputs formatted in standard Title Case.

### ISS-16: Primary Key Vulnerability to Sheet Sorting and Filtering
- **Affected Column**: Entire Record / Row Level
- **Raw Anomaly**: Sync mechanisms that rely on spreadsheet row numbers (`sheet_row_number`) corrupt database records when users sort or filter the sheet, as row numbers swap positions across records.
- **Standardization Rule**:
  The primary event identity is established as the composite key:
  `(submission_timestamp, partner_number)`
  This unique constraint guarantees 100% immunity against user sorting, column filtering, and row deletions in the spreadsheet.

### ISS-17: Temporal Paradox (`Joined Date` < `Visit Timestamp`)
- **Affected Column**: Column A (`Timestamp`) and Column J (`Joined Date`)
- **Raw Anomaly**: In several records, `Joined Date` is recorded prior to the visit `Timestamp` (e.g. partner visited on 2025-03-25, but their joined date is 2025-03-03 because they were an existing driver visiting for administrative reasons).
- **Standardization Rule**:
  Both dates are ingested accurately as recorded. The pipeline does not reject or modify the dates, preserving historical operational reality.

### ISS-18: Dummy & Test Records in Production Sheet
- **Affected Column**: Column E (`Partner Name`) & Column F (`Partner Number`)
- **Raw Anomaly**: Entries like Partner Name `Na` with phone `1234567890`.
- **Standardization Rule**:
  Records are sanitized and ingested without dropping. Preserving all records maintains identical row parity with the sheet while allowing downstream analytics queries to filter test patterns.

### ISS-19: Explicit String Placeholders in Driver License
- **Affected Column**: Column G (`DL Number`)
- **Raw Anomaly**: Field executives entered textual dummy placeholders such as `NA`, `NAA`, `N/A`, `NONE`, `NIL`, `NULL`, `-`, and `--`.
- **Standardization Rule**:
  `cleanDL()` evaluates against a placeholder blacklist:
  `["", "NA", "NAA", "N/A", "NONE", "NIL", "NULL", "-", "--"]`
  All matching tokens are converted to SQL `NULL`.

### ISS-20: Greek & Non-ASCII Homoglyphs in Driver License
- **Affected Column**: Column G (`DL Number`)
- **Raw Anomaly**: OCR scanning or keyboard layouts produced Greek uppercase characters (`\u039A` for Greek Kappa and `\u0391` for Greek Alpha) that visually mimic Latin `K` and `A` but fail database equality searches.
- **Standardization Rule**:
  Pre-processing homoglyph substitution:
  `.replace(/\u039A/g, 'K').replace(/\u0391/g, 'A').replace(/\u03BA/g, 'k').replace(/\u03B1/g, 'a')`
  followed by NFKD diacritic removal.

### ISS-21: Executive Disambiguation (`Sai Kiran` vs `Kiran` vs `Kedar`)
- **Affected Column**: Column D (`Attending Executive`)
- **Raw Anomaly**: Risk of over-aggressive deduplication accidentally merging distinct physical staff members (such as `Sai Kiran` and `Kiran`, or `Kedar`).
- **Standardization Rule**:
  The canonical alias mapping only resolves genuine typos of the same person (`shaikbdulla` -> `Shaik Abdulla`; `radhakirshna` -> `Radha Krishna`). Distinct names like `Sai Kiran`, `Kiran`, and `Kedar` are kept strictly separate.

### ISS-22: Single Mumbai Outlier Entry
- **Affected Column**: Column C (`City`)
- **Raw Anomaly**: The walk-in dataset predominantly covers Hyderabad and Bengaluru, with a single record for Mumbai.
- **Standardization Rule**:
  City validation explicitly supports `Mumbai` without flagging or dropping outlier branches.

### ISS-23: Repeat Partner Visits Over Time
- **Affected Column**: Column F (`Partner Number`)
- **Raw Anomaly**: Individual driver-partners visit hub locations multiple times across months for different reasons (e.g. initial inquiry, followed by hisaab, followed by maintenance).
- **Standardization Rule**:
  The database does NOT enforce uniqueness on `partner_number` alone. A driver may appear multiple times with distinct `submission_timestamp` values.

### ISS-24: Scientific Notation in Numeric Phone Cells
- **Affected Column**: Column F (`Partner Number`)
- **Raw Anomaly**: Spreadsheets formatted large numbers in exponential notation (e.g. `9.84526E+09`), which simple digit extractors read as truncated strings like `984526`.
- **Standardization Rule**:
  `cleanPhone()` checks for exponential format via regex `/^\d+(\.\d+)?e\+\d+$/i` and expands it via `Number(s).toFixed(0)` before digit extraction.

### ISS-25: PostgreSQL Sequence Gaps on Upsert (Gapless ID Numbering)
- **Affected Column**: Database `id` (Primary Key Sequence)
- **Raw Anomaly**: Default `INSERT ... ON CONFLICT DO UPDATE` increments PostgreSQL's `BIGSERIAL` sequence (`nextval()`) for every row checked before evaluating conflict. In a 1-minute catch-up daemon scanning 60 rows, 58 unchanged rows burned 58 sequence numbers per minute, causing new IDs to skip from 877 to 940.
- **Standardization Rule**:
  Redesigned `UPSERT_SQL` into a Zero-Burn Common Table Expression (CTE):
  Updates existing rows in-place without touching `sheet_walkins_id_seq`. Only calls `nextval()` when a row is genuinely new (`WHERE NOT EXISTS (SELECT 1 FROM upd)`), guaranteeing continuous, gapless sequential IDs (878, 879, 880...).

### ISS-26: IMPORTRANGE Formula Caching & Distributed Lock Latency
- **Affected Column**: Pipeline Trigger Layer (`syncRecentWalkins`)
- **Raw Anomaly**: `=IMPORTRANGE()` updates silently in the background without firing spreadsheet `onEdit` or `onFormSubmit` events. Furthermore, Google Apps Script's `LockService.tryLock(0)` failed on distributed cloud latency, silently skipping sync cycles.
- **Standardization Rule**:
  1. Increased `lock.tryLock()` timeout to 15,000 ms (15 seconds).
  2. Added `SpreadsheetApp.flush()` to force Google Sheets to resolve all cross-sheet formulas before reading data ranges.

### ISS-27: Trailing Empty Formula Blanks (Reverse trueLastRow Scanner)
- **Affected Column**: Physical Spreadsheet Row Bounds
- **Raw Anomaly**: Google Sheets with array formulas or template rows count blank cells down to row 1,000 as part of `sheet.getLastRow()`. Blindly subtracting 50 scanned empty rows 950-1000, missing real data sitting at row 879.
- **Standardization Rule**:
  Implemented reverse scanner (`trueLastRow`) that checks backwards for non-empty timestamps or phone numbers in columns A and F, ensuring the scan window (`trueLastRow - 60`) always captures true live records.
