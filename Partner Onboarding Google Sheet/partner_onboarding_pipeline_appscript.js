/**
 * ==============================================================================
 * LETZRYD - PARTNER ONBOARDING LIVE PIPELINE & GOOGLE SHEET STANDARDIZATION
 * ==============================================================================
 * 
 * Source Sheet : 'Onboarding form_V2' (Raw Driver KYC & Onboarding Form)
 * Target Sheet : 'sheet_driver_onboarding' (Clean Standardized Sheet Tab)
 * Target Table : public.sheet_driver_onboarding & public.core_partner_onboarding
 * 
 * Features:
 *  - Direct cross-sheet ingestion without IMPORTRANGE (prevents record limits & cell-freeze)
 *  - Full 47-issue standardization engine (ISS-16 through ISS-62)
 *  - Secure credential retrieval via PropertiesService.getScriptProperties()
 *  - Strict Concurrency Control using LockService.getScriptLock()
 *  - Zero-burn PostgreSQL upsert logic preventing sequence gap creation
 *  - Automatic column swap detection and date-to-DL recovery
 *  - Strict calendar boundary clamping for DOB ([18, 75] yrs) and DL Expiry ([1990, 2060])
 *  - Deterministic IST timestamp contract (YYYY-MM-DD HH:mm:ss without millisecond drift)
 *  - Batched Google Sheets RPC writes preventing quota depletion
 *  - Complete connection leak prevention (try-catch-finally with conn.close())
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
function getDbConfig() {
  let props = null;
  try {
    props = PropertiesService.getScriptProperties();
  } catch(e) {}

  return {
    host: (props && props.getProperty("DB_HOST")) || "YOUR_DB_HOST",
    port: (props && props.getProperty("DB_PORT")) || "5432",
    database: (props && props.getProperty("DB_NAME")) || "postgres",
    user: (props && props.getProperty("DB_USER")) || "postgres",
    password: (props && props.getProperty("DB_PASSWORD")) || "YOUR_DB_PASSWORD",
    
    // Source Spreadsheet with raw form responses ('Onboarding form_V2')
    sourceSpreadsheetUrl: (props && props.getProperty("SOURCE_SPREADSHEET_URL")) || "https://docs.google.com/spreadsheets/d/1ix6iKa9nEh4li44ZRcpkAvEMLo4r94mT4VbwRCfNZIM/edit",
    sourceSheetName: (props && props.getProperty("SOURCE_SHEET_NAME")) || "Onboarding form_V2",
    
    // Destination Spreadsheet tab where standardized data is stored
    targetSheetName: (props && props.getProperty("TARGET_SHEET_NAME")) || "sheet_driver_onboarding",

    // Error logging tab for invalid/failed records
    errorSheetName: (props && props.getProperty("ERROR_SHEET_NAME")) || "onboarding_sync_errors"
  };
}

const DB_CONFIG = getDbConfig();

// Standard JDBC SQL Type Codes (Apps Script does not expose java.sql.Types)
const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  TIMESTAMP: 93,
  INTEGER: 4,
  BIGINT: -5,
  DOUBLE: 8,
  BOOLEAN: 16,
  NULL: 0
};

// Canonical City to Prefix Map for deterministic Partner ID generation (ISS-16 to ISS-18)
const CITY_PREFIX_MAP = {
  "bengaluru": "LETZBLR",
  "bangalore": "LETZBLR",
  "hyderabad": "LETZHYD",
  "mumbai": "LETZMUM",
  "delhi": "LETZDEL",
  "chennai": "LETZCHN",
  "pune": "LETZPUN"
};

// Canonical Greek and Cyrillic Homoglyphs map (ISS-44)
const HOMOGLYPH_MAP = {
  '\u0391': 'A', '\u0392': 'B', '\u0395': 'E', '\u0396': 'Z', '\u0397': 'H',
  '\u0399': 'I', '\u039A': 'K', '\u039C': 'M', '\u039D': 'N', '\u039F': 'O',
  '\u03A1': 'P', '\u03A4': 'T', '\u03A5': 'Y', '\u03A7': 'X',
  '\u0410': 'A', '\u0412': 'B', '\u0415': 'E', '\u041A': 'K', '\u041C': 'M',
  '\u041D': 'H', '\u041E': 'O', '\u0420': 'P', '\u0421': 'C', '\u0422': 'T',
  '\u0425': 'X'
};

// =============================================================================
// SPREADSHEET GETTERS
// =============================================================================

function getSourceSpreadsheet() {
  const cfg = getDbConfig();
  if (cfg.sourceSpreadsheetUrl && cfg.sourceSpreadsheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(cfg.sourceSpreadsheetUrl);
    } catch(e) {
      Logger.log("openByUrl error for source sheet, falling back to active spreadsheet: " + e.message);
    }
  }
  return SpreadsheetApp.getActiveSpreadsheet();
}

function getTargetSpreadsheet() {
  return SpreadsheetApp.getActiveSpreadsheet();
}

// =============================================================================
// DATA SANITIZATION AND STANDARDIZATION ENGINE (ISS-16 THROUGH ISS-62)
// =============================================================================

/**
 * Strips accents, homoglyphs, and normalize text to uppercase (ISS-23, ISS-44).
 */
function sanitizeText(val) {
  if (val === null || val === undefined) return null;
  let str = String(val).trim();
  if (str === "" || str === "-" || str.toLowerCase() === "null" || str.toLowerCase() === "nan" || str.toLowerCase() === "na") {
    return null;
  }
  for (let char in HOMOGLYPH_MAP) {
    if (str.indexOf(char) !== -1) {
      str = str.split(char).join(HOMOGLYPH_MAP[char]);
    }
  }
  return str.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/\s+/g, " ");
}

/**
 * Standardizes City names into title case / canonical form.
 */
function sanitizeCity(val) {
  let text = sanitizeText(val);
  if (!text) return null;
  let lower = text.toLowerCase();
  if (lower.indexOf("blr") !== -1 || lower.indexOf("bangalore") !== -1 || lower.indexOf("bengaluru") !== -1) return "Bengaluru";
  if (lower.indexOf("hyd") !== -1 || lower.indexOf("hyderabad") !== -1) return "Hyderabad";
  if (lower.indexOf("mum") !== -1 || lower.indexOf("mumbai") !== -1) return "Mumbai";
  if (lower.indexOf("del") !== -1 || lower.indexOf("delhi") !== -1) return "Delhi";
  if (lower.indexOf("chn") !== -1 || lower.indexOf("chennai") !== -1) return "Chennai";
  if (lower.indexOf("pun") !== -1 || lower.indexOf("pune") !== -1) return "Pune";
  return text.charAt(0).toUpperCase() + text.slice(1).toLowerCase();
}

/**
 * Standardizes Onboarding Type (ISS-22).
 */
function sanitizeOnboardingType(val) {
  let text = sanitizeText(val);
  if (!text) return "Individual";
  let lower = text.toLowerCase();
  if (lower.indexOf("oper") !== -1) return "Operator";
  return "Individual";
}

/**
 * Standardizes Phone Numbers (ISS-20, ISS-25, ISS-26, ISS-28).
 * Strips non-digits, leading zeroes, country code (+91), scientific notation floats (.0).
 */
function sanitizePhone(val) {
  if (val === null || val === undefined) return null;
  let str = String(val).trim();
  if (str === "" || str === "-" || str.toLowerCase() === "na" || str.toLowerCase() === "null") return null;
  
  // Handle scientific notation float (e.g. 9.88601E+09)
  if (str.toUpperCase().indexOf("E+") !== -1 || str.indexOf("e+") !== -1) {
    let num = Number(str);
    if (!isNaN(num)) {
      str = num.toLocaleString('fullwide', {useGrouping: false});
    }
  }
  
  // Strip trailing float decimals like .0
  str = str.replace(/\.0+$/, "");
  
  let digits = str.replace(/\D/g, "");
  if (!digits || digits.length < 10) return null;
  
  // Strip leading 91 or 0 if string is > 10 digits
  if (digits.length === 12 && digits.startsWith("91")) {
    digits = digits.substring(2);
  } else if (digits.length === 11 && digits.startsWith("0")) {
    digits = digits.substring(1);
  }
  return digits.length >= 10 ? digits.slice(-10) : digits;
}

/**
 * Standardizes PAN Number (ISS-36, ISS-37).
 * Uppercase, alphanumeric, checks 10-character regex ^[A-Z]{5}[0-9]{4}[A-Z]$.
 */
function sanitizePAN(val) {
  let text = sanitizeText(val);
  if (!text) return null;
  let cleaned = text.toUpperCase().replace(/[^A-Z0-9]/g, "");
  return cleaned.length > 0 ? cleaned : null;
}

/**
 * Validates PAN structure.
 */
function isPANValid(pan) {
  if (!pan) return false;
  return /^[A-Z]{5}[0-9]{4}[A-Z]$/.test(pan);
}

/**
 * Standardizes Aadhaar Number (ISS-39, ISS-40).
 * Cleans spaces, hyphens, and decimal tails to extract 12 digits.
 */
function sanitizeAadhaar(val) {
  if (val === null || val === undefined) return null;
  let str = String(val).trim().replace(/\.0+$/, "");
  let digits = str.replace(/\D/g, "");
  if (!digits) return null;
  return digits;
}

/**
 * Checks whether an input value represents a Date object or Date string.
 */
function isDateValue(val) {
  if (!val) return false;
  if (val instanceof Date) return true;
  if (typeof val === "string") {
    let s = val.trim();
    if (s.indexOf("GMT") !== -1 || s.indexOf("UTC") !== -1 || s.indexOf("T00:00:00") !== -1) return true;
    if (/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{4}/i.test(s)) return true;
    if (/^\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}/.test(s)) return true;
    if (/^\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}/.test(s)) return true;
    if (/^\d{1,2}[\/\-][A-Za-z]{3}[\/\-]\d{2,4}/.test(s)) return true;
  }
  return false;
}

/**
 * Standardizes Driving License Number (ISS-42, ISS-44, ISS-45).
 * Rejects Date objects / strings to prevent SATSEP... date corruption.
 */
function sanitizeDL(val) {
  if (!val) return null;
  if (isDateValue(val)) return null; // Reject dates accidentally passed into DL column
  let text = sanitizeText(val);
  if (!text) return null;
  let cleaned = text.toUpperCase().replace(/[\s\-\/\.#_]/g, "");
  // Explicitly reject dummy placeholders
  if (cleaned === "NA" || cleaned === "NIL" || cleaned === "NONE" || cleaned === "NULL" || /^0+$/.test(cleaned)) {
    return null;
  }
  // If string contains date markers like GMT or standard date representation, reject it
  if (cleaned.indexOf("GMT") !== -1 || cleaned.indexOf("INDIASTANDARDTIME") !== -1) {
    return null;
  }
  return cleaned.length >= 4 ? cleaned : null;
}

/**
 * Standardizes Bank Account Number (ISS-53, ISS-54).
 * Strips scientific notation float and formats as clean digits.
 */
function sanitizeAccountNumber(val) {
  if (val === null || val === undefined) return null;
  let str = String(val).trim();
  if (str === "" || str === "-" || str.toLowerCase() === "na" || str.toLowerCase() === "null") return null;
  if (str.toUpperCase().indexOf("E+") !== -1 || str.indexOf("e+") !== -1) {
    let num = Number(str);
    if (!isNaN(num)) {
      str = num.toLocaleString('fullwide', {useGrouping: false});
    }
  }
  let digits = str.replace(/\.0+$/, "").replace(/[^0-9]/g, "");
  return digits.length > 0 ? digits : null;
}

/**
 * Standardizes Bank IFSC Code (ISS-49, ISS-50, ISS-51, ISS-52).
 * Formats uppercase, validates 11 characters, auto-repairs missing 5th zero if 10 characters.
 */
function sanitizeIFSC(val) {
  let text = sanitizeText(val);
  if (!text) return null;
  let cleaned = text.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (cleaned.length === 10 && cleaned.charAt(4) !== '0') {
    cleaned = cleaned.substring(0, 4) + "0" + cleaned.substring(4);
  }
  return (cleaned.length === 11 && !/^0+$/.test(cleaned)) ? cleaned : null;
}

/**
 * Standardizes UPI ID (ISS-56).
 * Extracts handle (@ybl, @okaxis, @paytm, @upi, @icici, etc.).
 */
function sanitizeUPI(val) {
  let text = sanitizeText(val);
  if (!text) return null;
  let match = text.match(/[a-zA-Z0-9\.\-_]+@[a-zA-Z0-9]+/);
  return match ? match[0].toLowerCase() : (text.indexOf("@") !== -1 ? text.toLowerCase() : null);
}

/**
 * Parses Deposit & Joining fees (ISS-57).
 * Handles currency symbols ('₹', 'Rs', ','), arithmetic strings ('11000 + 3500' -> 14500.0).
 */
function parseDepositAmount(val) {
  if (val === null || val === undefined) return 0.0;
  let str = String(val).trim().replace(/[₹,\s]/g, "").replace(/Rs\.?/gi, "");
  if (str === "" || str === "-" || str.toLowerCase() === "na") return 0.0;
  if (str.indexOf("+") !== -1) {
    let parts = str.split("+");
    let sum = 0.0;
    for (let i = 0; i < parts.length; i++) {
      let num = parseFloat(parts[i].trim());
      if (!isNaN(num)) sum += num;
    }
    return sum;
  }
  let parsed = parseFloat(str);
  return isNaN(parsed) ? 0.0 : parsed;
}

/**
 * Parses Referral String (ISS-58).
 * Example: '6300711880 (KABIR)' -> { phone: '6300711880', name: 'KABIR' }
 */
function parseReferral(val) {
  let text = sanitizeText(val);
  if (!text) return { phone: null, name: null };
  let match = text.match(/([0-9]{10})\s*(?:\((.*?)\))?/);
  if (match) {
    return {
      phone: match[1],
      name: match[2] ? match[2].trim().toUpperCase() : null
    };
  }
  let phone = sanitizePhone(text);
  return {
    phone: phone,
    name: phone ? null : text.toUpperCase()
  };
}

/**
 * Resolves 2-digit years with commercial driver boundary validation.
 */
function resolveTwoDigitYear(yy, isDob) {
  let currentYear = new Date().getFullYear();
  if (isDob) {
    // Commercial driver age threshold: 18 to 75 years old
    let minDobYear = currentYear - 75;
    let maxDobYear = currentYear - 18;
    let opt1 = 1900 + yy;
    let opt2 = 2000 + yy;
    if (opt2 >= minDobYear && opt2 <= maxDobYear) return opt2;
    if (opt1 >= minDobYear && opt1 <= maxDobYear) return opt1;
    return opt1;
  }
  // For licenses and other dates
  return (yy > 50) ? 1900 + yy : 2000 + yy;
}

/**
 * Multi-format Date / Timestamp Parser with Strict Boundary Clamping (ISS-30, ISS-31, ISS-32, ISS-46).
 * @param {*} val Input cell value
 * @param {boolean} isDob Whether this date represents Date of Birth
 * @param {number} minYear Lower calendar boundary (defaults: DOB -> currentYear - 75; other -> 1990)
 * @param {number} maxYear Upper calendar boundary (defaults: DOB -> currentYear - 18; other -> 2060)
 */
function parseDateTime(val, isDob, minYear, maxYear) {
  if (!val) return null;
  const currentYear = new Date().getFullYear();
  const lowerBound = minYear || (isDob ? (currentYear - 75) : 1990);
  const upperBound = maxYear || (isDob ? (currentYear - 18) : 2060);

  function clampDate(dt) {
    if (!dt || isNaN(dt.getTime())) return null;
    let y = dt.getFullYear();
    // Guard against astronomical overflow years or toddler/ancient corrupted years
    if (y < lowerBound || y > upperBound) {
      return null;
    }
    return dt;
  }

  // Handle native Date objects
  if (val instanceof Date) {
    if (isNaN(val.getTime())) return null;
    let y = val.getFullYear();
    if (y < 100) {
      val.setFullYear(resolveTwoDigitYear(y, isDob));
    }
    return clampDate(val);
  }

  // Handle numeric Excel/Sheets serial numbers
  if (typeof val === "number") {
    // Reject massive numbers (like phone numbers typed into date column e.g. 9886012345)
    if (val < 1 || val > 75000) return null;
    let dt = new Date(Math.round((val - 25569) * 86400 * 1000));
    if (isNaN(dt.getTime())) return null;
    let y = dt.getFullYear();
    if (y < 100) dt.setFullYear(resolveTwoDigitYear(y, isDob));
    return clampDate(dt);
  }

  let str = String(val).trim();
  if (!str || str === "-" || str.toLowerCase() === "na" || str.toLowerCase() === "null") return null;

  // 1. YYYY-MM-DD or YYYY/MM/DD
  let ymdMatch = str.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?/);
  if (ymdMatch) {
    let year = parseInt(ymdMatch[1], 10);
    let month = parseInt(ymdMatch[2], 10) - 1;
    let day = parseInt(ymdMatch[3], 10);
    let hour = ymdMatch[4] ? parseInt(ymdMatch[4], 10) : 12;
    let min = ymdMatch[5] ? parseInt(ymdMatch[5], 10) : 0;
    let sec = ymdMatch[6] ? parseInt(ymdMatch[6], 10) : 0;
    let dt = new Date(Date.UTC(year, month, day, hour, min, sec) - (5.5 * 3600 * 1000));
    return clampDate(dt);
  }
  
  // 2. DD/MM/YYYY or DD-MM-YYYY or DD/MM/YY or DD-MM-YY
  let dmyMatch = str.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?/);
  if (dmyMatch) {
    let day = parseInt(dmyMatch[1], 10);
    let month = parseInt(dmyMatch[2], 10) - 1;
    let year = parseInt(dmyMatch[3], 10);
    if (year < 100) {
      year = resolveTwoDigitYear(year, isDob);
    }
    let hour = dmyMatch[4] ? parseInt(dmyMatch[4], 10) : 12;
    let min = dmyMatch[5] ? parseInt(dmyMatch[5], 10) : 0;
    let sec = dmyMatch[6] ? parseInt(dmyMatch[6], 10) : 0;
    let dt = new Date(Date.UTC(year, month, day, hour, min, sec) - (5.5 * 3600 * 1000));
    return clampDate(dt);
  }
  
  // 3. DD-MMM-YY e.g. 15-Aug-94 or 15-Aug-2024
  let dMmmYMatch = str.match(/^(\d{1,2})[\/\-]([A-Za-z]{3})[\/\-](\d{2,4})/);
  if (dMmmYMatch) {
    let day = parseInt(dMmmYMatch[1], 10);
    let monthStr = dMmmYMatch[2].toLowerCase();
    let months = ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"];
    let month = months.indexOf(monthStr);
    let year = parseInt(dMmmYMatch[3], 10);
    if (year < 100) year = resolveTwoDigitYear(year, isDob);
    if (month !== -1) {
      let dt = new Date(Date.UTC(year, month, day, 12, 0, 0) - (5.5 * 3600 * 1000));
      return clampDate(dt);
    }
  }

  // 4. YY-MM-DD (e.g. 37-05-08 -> 2037-05-08)
  let yyMdMatch = str.match(/^(\d{2})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (yyMdMatch) {
    let yy = parseInt(yyMdMatch[1], 10);
    let year = resolveTwoDigitYear(yy, isDob);
    let month = parseInt(yyMdMatch[2], 10) - 1;
    let day = parseInt(yyMdMatch[3], 10);
    let dt = new Date(Date.UTC(year, month, day, 12, 0, 0) - (5.5 * 3600 * 1000));
    return clampDate(dt);
  }

  // 5. JavaScript Date String (e.g. 'Sat Sep 11 2027 00:00:00 GMT+0530')
  let parsed = new Date(str);
  if (!isNaN(parsed.getTime())) {
    let y = parsed.getFullYear();
    if (y < 100) parsed.setFullYear(resolveTwoDigitYear(y, isDob));
    return clampDate(parsed);
  }

  return null;
}

/**
 * Formats standard date only string: YYYY-MM-DD.
 */
function formatDateOnly(dt) {
  if (!dt || isNaN(dt.getTime())) return null;
  if (typeof Utilities !== "undefined" && Utilities.formatDate) {
    return Utilities.formatDate(dt, "Asia/Kolkata", "yyyy-MM-dd");
  }
  let y = dt.getFullYear();
  let yStr = ("0000" + y).slice(-4);
  let m = ("0" + (dt.getMonth() + 1)).slice(-2);
  let d = ("0" + dt.getDate()).slice(-2);
  return yStr + "-" + m + "-" + d;
}

/**
 * Formats standard deterministic timestamp in IST without milliseconds.
 * Eliminates duplicate key generation due to millisecond discrepancies.
 */
function formatTimestamp(dt) {
  if (!dt || isNaN(dt.getTime())) return null;
  if (typeof Utilities !== "undefined" && Utilities.formatDate) {
    return Utilities.formatDate(dt, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss");
  }
  let y = dt.getFullYear();
  let m = ("0" + (dt.getMonth() + 1)).slice(-2);
  let d = ("0" + dt.getDate()).slice(-2);
  let h = ("0" + dt.getHours()).slice(-2);
  let min = ("0" + dt.getMinutes()).slice(-2);
  let s = ("0" + dt.getSeconds()).slice(-2);
  return y + "-" + m + "-" + d + " " + h + ":" + min + ":" + s;
}

/**
 * Standardizes Document URLs (ISS-59, ISS-60).
 */
function sanitizeDocUrl(val) {
  let text = sanitizeText(val);
  if (!text || text === "-" || text.toLowerCase() === "na") return null;
  return text.startsWith("http") ? text : null;
}

/**
 * Deterministically generates standard Partner ID (ISS-16, ISS-17, ISS-18).
 * Format: LETZ + <CITY_CODE> + <10_DIGIT_PHONE>
 */
function generatePartnerId(city, phone) {
  let cleanCity = (city || "bengaluru").toLowerCase();
  let prefix = CITY_PREFIX_MAP[cleanCity] || "LETZBLR";
  let cleanPhone = sanitizePhone(phone);
  return cleanPhone ? (prefix + cleanPhone) : null;
}

// =============================================================================
// ROW OBJECT PARSER (WITH INTELLIGENT COLUMN SWAP RECOVERY)
// =============================================================================

function parseRow(row, rowIndex) {
  if (!row || row.length === 0) return null;
  
  let rawTs = row[0];
  let submissionTs = parseDateTime(rawTs, false, 2020, 2030);
  if (!submissionTs) return null; // Skip non-data / unparseable header rows
  
  let email = sanitizeText(row[1]);
  if (email && email.toLowerCase() === "old data") email = null;
  let city = sanitizeCity(row[2]);
  let onboardingType = sanitizeOnboardingType(row[3]);
  let leadSource = sanitizeText(row[4]);
  let driverPlan = sanitizeText(row[5]);
  let driverName = sanitizeText(row[6]) ? String(sanitizeText(row[6])).toUpperCase() : null;
  let rawPhone = row[7];
  let driverPhone = sanitizePhone(rawPhone);
  
  // A valid 10-digit driver phone is mandatory for onboarding.
  if (!driverPhone || !/^[0-9]{10}$/.test(driverPhone)) {
    let failureReason = !rawPhone || String(rawPhone).trim() === "" 
      ? "Blank / Missing Phone Number" 
      : "Invalid Phone Number Format: '" + String(rawPhone) + "' (Must be 10 digits)";
    logOnboardingError(rowIndex, rawPhone, driverName, failureReason, row);
    Logger.log("Row " + rowIndex + " failed validation (" + failureReason + ") -> Logged to " + getDbConfig().errorSheetName);
    return null;
  }
  
  let whatsappPhone = sanitizePhone(row[8]) || driverPhone; // ISS-25: fallback to driver phone
  let emergencyName = sanitizeText(row[9]);
  let emergencyPhone = sanitizePhone(row[10]);
  let refName = sanitizeText(row[11]);
  let refPhone = sanitizePhone(row[12]);
  let fatherName = sanitizeText(row[13]);
  let dob = parseDateTime(row[14], true);
  let aadhaarAddress = sanitizeText(row[15]);
  let presentAddress = sanitizeText(row[16]) || aadhaarAddress; // ISS-35: fallback to Aadhaar address
  let panNumber = sanitizePAN(row[17]);
  let aadhaarNumber = sanitizeAadhaar(row[18]);
  
  // Driving License & Expiry Resolution (Column 19 = DL Number, Column 20 = DL Expiry Date)
  // Implements intelligent cross-detection to automatically recover swapped/shifted form entries
  let rawCol19 = row[19];
  let rawCol20 = row[20];
  let dlNumber = null;
  let dlExpiry = null;

  let col19IsDate = isDateValue(rawCol19);
  let col20IsDate = isDateValue(rawCol20);

  if (col19IsDate && !col20IsDate) {
    // Columns were inverted: Col 19 has Expiry Date, Col 20 has DL Number
    dlExpiry = parseDateTime(rawCol19, false, 1990, 2060);
    dlNumber = sanitizeDL(rawCol20);
  } else {
    // Canonical mapping: Col 19 is DL Number, Col 20 is DL Expiry Date
    dlNumber = sanitizeDL(rawCol19);
    dlExpiry = parseDateTime(rawCol20, false, 1990, 2060);
    // If DL number was empty or unparseable but col19 had date, attempt extraction
    if (!dlExpiry && col19IsDate) {
      dlExpiry = parseDateTime(rawCol19, false, 1990, 2060);
    }
  }

  let upiFromAccount = sanitizeUPI(row[21]);
  let panAadhaarLinked = sanitizeText(row[22]);
  
  // Documents
  let dlFront = sanitizeDocUrl(row[23]);
  let dlBack = sanitizeDocUrl(row[24]);
  let aadhaarFront = sanitizeDocUrl(row[25]);
  let aadhaarBack = sanitizeDocUrl(row[26]);
  let panCard = sanitizeDocUrl(row[27]);
  let localAddressProof = sanitizeDocUrl(row[28]);
  let selfiePhoto = sanitizeDocUrl(row[29]);
  let panAadhaarPhoto = sanitizeDocUrl(row[30]);
  let bankDetailsDoc = sanitizeDocUrl(row[31]);
  
  // Banking & Referrals
  let referral = parseReferral(row[32]);
  let accountName = sanitizeText(row[33]);
  let accountNumber = sanitizeAccountNumber(row[34]);
  let ifscCode = sanitizeIFSC(row[35]);
  let depositAmount = parseDepositAmount(row[38]);
  
  let partnerId = generatePartnerId(city, driverPhone);
  let isPANFmtValid = isPANValid(panNumber);
  let isAadhaarLenValid = (aadhaarNumber && aadhaarNumber.length === 12);
  let isNameMatched = (accountName && driverName) ? (driverName.indexOf(accountName) !== -1 || accountName.indexOf(driverName) !== -1) : true;

  return {
    submissionTimestamp: submissionTs,
    email: email,
    city: city,
    onboardingType: onboardingType,
    leadSource: leadSource,
    driverPlan: driverPlan,
    driverName: driverName,
    driverPhone: driverPhone,
    whatsappPhone: whatsappPhone,
    emergencyName: emergencyName,
    emergencyPhone: emergencyPhone,
    refName: refName,
    refPhone: refPhone,
    fatherName: fatherName,
    dob: dob,
    aadhaarAddress: aadhaarAddress,
    presentAddress: presentAddress,
    panNumber: panNumber,
    aadhaarNumber: aadhaarNumber,
    dlExpiry: dlExpiry,
    dlNumber: dlNumber,
    upiId: upiFromAccount,
    panAadhaarLinked: panAadhaarLinked,
    dlFront: dlFront,
    dlBack: dlBack,
    aadhaarFront: aadhaarFront,
    aadhaarBack: aadhaarBack,
    panCard: panCard,
    localAddressProof: localAddressProof,
    selfiePhoto: selfiePhoto,
    panAadhaarPhoto: panAadhaarPhoto,
    bankDetailsDoc: bankDetailsDoc,
    referralPhone: referral.phone,
    referralName: referral.name,
    accountName: accountName,
    accountNumber: accountNumber,
    ifscCode: ifscCode,
    depositAmount: depositAmount,
    partnerId: partnerId,
    isPanValid: isPANFmtValid,
    isAadhaarValid: isAadhaarLenValid,
    isNameMatched: isNameMatched,
    sheetRowNumber: rowIndex
  };
}

// =============================================================================
// DATABASE JDBC PIPELINE (ZERO-BURN UPSERT)
// =============================================================================

function getDbConnection() {
  const cfg = getDbConfig();
  const url = "jdbc:postgresql://" + cfg.host + ":" + cfg.port + "/" + cfg.database;
  return Jdbc.getConnection(url, cfg.user, cfg.password);
}

/**
 * Tests database connectivity.
 */
function testConnection() {
  let conn = null;
  let stmt = null;
  let rs = null;
  const cfg = getDbConfig();
  try {
    conn = getDbConnection();
    stmt = conn.createStatement();
    rs = stmt.executeQuery("SELECT count(*) FROM sheet_driver_onboarding;");
    let count = 0;
    if (rs.next()) {
      count = rs.getInt(1);
    }
    Logger.log("Connection Successful. Current rows in sheet_driver_onboarding: " + count);
    if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getUi) {
      SpreadsheetApp.getUi().alert(
        "Database Connection Successful",
        "Connected to PostgreSQL on " + cfg.host + ".\nCurrent rows in sheet_driver_onboarding: " + count,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
    }
  } catch (e) {
    Logger.log("Connection Failed: " + e.message);
    if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getUi) {
      SpreadsheetApp.getUi().alert(
        "Database Connection Error",
        "Failed to connect to PostgreSQL: " + e.message,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
    }
  } finally {
    if (rs) { try { rs.close(); } catch(e){} }
    if (stmt) { try { stmt.close(); } catch(e){} }
    if (conn) { try { conn.close(); } catch(e){} }
  }
}

/**
 * SQL Helper: Escapes string values for SQL literals.
 */
function sqlEscapeStr(val) {
  if (val === null || val === undefined) return "NULL::text";
  let s = String(val).replace(/'/g, "''").replace(/\\/g, "\\\\");
  return "'" + s + "'::text";
}

function sqlEscapeDate(dt) {
  let s = formatDateOnly(dt);
  return s ? ("'" + s + "'::date") : "NULL::date";
}

function sqlEscapeTimestamp(dt) {
  let s = formatTimestamp(dt);
  return s ? ("'" + s + "+05:30'::timestamp with time zone") : "NULL::timestamp with time zone";
}

function sqlEscapeNum(val) {
  if (val === null || val === undefined || val === "") return "0.00::numeric";
  let n = parseFloat(val);
  return (isNaN(n) ? "0.00" : n.toFixed(2)) + "::numeric";
}

function sqlEscapeInt(val) {
  if (val === null || val === undefined || val === "") return "0::integer";
  let n = parseInt(val, 10);
  return (isNaN(n) ? "0" : String(n)) + "::integer";
}

/**
 * Upserts a batch of standardized records into PostgreSQL using CTE Zero-Burn query.
 * Evaluates nextval() ONLY for brand-new rows; existing rows generate 0 sequence increments.
 */
function upsertRecordsToDatabase(records, skipCoreMerge) {
  if (!records || records.length === 0) return 0;
  
  let conn = null;
  let stmt = null;
  const BATCH_SIZE = 25; // 25 rows per CTE statement optimizes throughput while safely staying well below Google Apps Script JDBC SQL size limit
  let totalCount = 0;
  
  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    stmt = conn.createStatement();
    
    for (let i = 0; i < records.length; i += BATCH_SIZE) {
      let chunk = records.slice(i, i + BATCH_SIZE);
      let valueClauses = [];
      
      for (let k = 0; k < chunk.length; k++) {
        let r = chunk[k];
        valueClauses.push("(" +
          sqlEscapeTimestamp(r.submissionTimestamp) + ", " +
          sqlEscapeStr(r.email) + ", " +
          sqlEscapeStr(r.city) + ", " +
          sqlEscapeStr(r.onboardingType) + ", " +
          sqlEscapeStr(r.leadSource) + ", " +
          sqlEscapeStr(r.driverPlan) + ", " +
          sqlEscapeStr(r.driverName) + ", " +
          sqlEscapeStr(r.driverPhone) + ", " +
          sqlEscapeStr(r.whatsappPhone) + ", " +
          sqlEscapeStr(r.emergencyName) + ", " +
          sqlEscapeStr(r.emergencyPhone) + ", " +
          sqlEscapeStr(r.refName) + ", " +
          sqlEscapeStr(r.refPhone) + ", " +
          sqlEscapeStr(r.fatherName) + ", " +
          sqlEscapeDate(r.dob) + ", " +
          sqlEscapeStr(r.aadhaarAddress) + ", " +
          sqlEscapeStr(r.presentAddress) + ", " +
          sqlEscapeStr(r.panNumber) + ", " +
          sqlEscapeStr(r.aadhaarNumber) + ", " +
          sqlEscapeDate(r.dlExpiry) + ", " +
          sqlEscapeStr(r.dlNumber) + ", " +
          sqlEscapeStr(r.upiId) + ", " +
          sqlEscapeStr(r.panAadhaarLinked) + ", " +
          sqlEscapeStr(r.dlFront) + ", " +
          sqlEscapeStr(r.dlBack) + ", " +
          sqlEscapeStr(r.aadhaarFront) + ", " +
          sqlEscapeStr(r.aadhaarBack) + ", " +
          sqlEscapeStr(r.panCard) + ", " +
          sqlEscapeStr(r.localAddressProof) + ", " +
          sqlEscapeStr(r.selfiePhoto) + ", " +
          sqlEscapeStr(r.panAadhaarPhoto) + ", " +
          sqlEscapeStr(r.bankDetailsDoc) + ", " +
          sqlEscapeStr(r.referralPhone) + ", " +
          sqlEscapeStr(r.referralName) + ", " +
          sqlEscapeStr(r.accountName) + ", " +
          sqlEscapeStr(r.accountNumber) + ", " +
          sqlEscapeStr(r.ifscCode) + ", " +
          sqlEscapeNum(r.depositAmount) + ", " +
          sqlEscapeStr(r.partnerId) + ", " +
          sqlEscapeInt(r.sheetRowNumber) +
        ")");
      }
      
      let sql = "WITH incoming ( " +
        "    submission_timestamp, submitter_email, city, onboarding_type, " +
        "    lead_source, driver_plan, driver_name, driver_phone, whatsapp_phone, " +
        "    emergency_name, emergency_phone, reference_name, reference_phone, " +
        "    father_name, dob, aadhaar_address, present_address, pan_number, " +
        "    aadhaar_number, dl_expiry, dl_number, upi_id, pan_aadhaar_linked, " +
        "    dl_front, dl_back, aadhaar_front, aadhaar_back, pan_card, " +
        "    local_address_proof, selfie_photo, pan_aadhaar_photo, bank_details_doc, " +
        "    referral_phone, referral_name, account_name, account_number, ifsc_code, " +
        "    deposit_amount, partner_id, sheet_row_number " +
        ") AS ( " +
        "    VALUES " + valueClauses.join(", ") + " " +
        "), " +
        "incoming_deduped AS ( " +
        "    SELECT DISTINCT ON (submission_timestamp, driver_phone) * " +
        "    FROM incoming " +
        "), " +
        "upd AS ( " +
        "    UPDATE public.sheet_driver_onboarding t " +
        "    SET " +
        "        submitter_email = i.submitter_email, " +
        "        city = i.city, " +
        "        onboarding_type = i.onboarding_type, " +
        "        lead_source = i.lead_source, " +
        "        driver_plan = i.driver_plan, " +
        "        driver_name = i.driver_name, " +
        "        whatsapp_phone = i.whatsapp_phone, " +
        "        emergency_name = i.emergency_name, " +
        "        emergency_phone = i.emergency_phone, " +
        "        reference_name = i.reference_name, " +
        "        reference_phone = i.reference_phone, " +
        "        father_name = i.father_name, " +
        "        dob = i.dob, " +
        "        aadhaar_address = i.aadhaar_address, " +
        "        present_address = i.present_address, " +
        "        pan_number = i.pan_number, " +
        "        aadhaar_number = i.aadhaar_number, " +
        "        dl_expiry = i.dl_expiry, " +
        "        dl_number = i.dl_number, " +
        "        upi_id = i.upi_id, " +
        "        pan_aadhaar_linked = i.pan_aadhaar_linked, " +
        "        dl_front = i.dl_front, " +
        "        dl_back = i.dl_back, " +
        "        aadhaar_front = i.aadhaar_front, " +
        "        aadhaar_back = i.aadhaar_back, " +
        "        pan_card = i.pan_card, " +
        "        local_address_proof = i.local_address_proof, " +
        "        selfie_photo = i.selfie_photo, " +
        "        pan_aadhaar_photo = i.pan_aadhaar_photo, " +
        "        bank_details_doc = i.bank_details_doc, " +
        "        referral_phone = i.referral_phone, " +
        "        referral_name = i.referral_name, " +
        "        account_name = i.account_name, " +
        "        account_number = i.account_number, " +
        "        ifsc_code = i.ifsc_code, " +
        "        deposit_amount = i.deposit_amount, " +
        "        partner_id = i.partner_id, " +
        "        sheet_row_number = i.sheet_row_number, " +
        "        updated_at = CURRENT_TIMESTAMP " +
        "    FROM incoming_deduped i " +
        "    WHERE t.submission_timestamp = i.submission_timestamp " +
        "      AND t.driver_phone = i.driver_phone " +
        "    RETURNING t.submission_timestamp, t.driver_phone " +
        ") " +
        "INSERT INTO public.sheet_driver_onboarding ( " +
        "    submission_timestamp, submitter_email, city, onboarding_type, " +
        "    lead_source, driver_plan, driver_name, driver_phone, whatsapp_phone, " +
        "    emergency_name, emergency_phone, reference_name, reference_phone, " +
        "    father_name, dob, aadhaar_address, present_address, pan_number, " +
        "    aadhaar_number, dl_expiry, dl_number, upi_id, pan_aadhaar_linked, " +
        "    dl_front, dl_back, aadhaar_front, aadhaar_back, pan_card, " +
        "    local_address_proof, selfie_photo, pan_aadhaar_photo, bank_details_doc, " +
        "    referral_phone, referral_name, account_name, account_number, ifsc_code, " +
        "    deposit_amount, partner_id, sheet_row_number, created_at, updated_at " +
        ") " +
        "SELECT " +
        "    i.submission_timestamp, i.submitter_email, i.city, i.onboarding_type, " +
        "    i.lead_source, i.driver_plan, i.driver_name, i.driver_phone, i.whatsapp_phone, " +
        "    i.emergency_name, i.emergency_phone, i.reference_name, i.reference_phone, " +
        "    i.father_name, i.dob, i.aadhaar_address, i.present_address, i.pan_number, " +
        "    i.aadhaar_number, i.dl_expiry, i.dl_number, i.upi_id, i.pan_aadhaar_linked, " +
        "    i.dl_front, i.dl_back, i.aadhaar_front, i.aadhaar_back, i.pan_card, " +
        "    i.local_address_proof, i.selfie_photo, i.pan_aadhaar_photo, i.bank_details_doc, " +
        "    i.referral_phone, i.referral_name, i.account_name, i.account_number, i.ifsc_code, " +
        "    i.deposit_amount, i.partner_id, i.sheet_row_number, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP " +
        "FROM incoming_deduped i " +
        "WHERE NOT EXISTS ( " +
        "    SELECT 1 FROM upd u " +
        "    WHERE u.submission_timestamp = i.submission_timestamp " +
        "      AND u.driver_phone = i.driver_phone " +
        ");";
  
      stmt.executeUpdate(sql);
      conn.commit();
      totalCount += chunk.length;
      Logger.log("Upserted batch: " + totalCount + "/" + records.length + " onboarding records into PostgreSQL.");
    }
    
    Logger.log("Successfully completed PostgreSQL upsert for all " + totalCount + " records.");
    return totalCount;
  } catch(e) {
    if (conn) {
      try { conn.rollback(); } catch(err){}
    }
    Logger.log("Database upsert error: " + e.message);
    throw e;
  } finally {
    if (stmt) { try { stmt.close(); } catch(e){} }
    if (conn) { try { conn.close(); } catch(e){} }
  }
}

// =============================================================================
// CROSS-SHEET PULL & STANDARDIZATION (NO IMPORTRANGE)
// =============================================================================

/**
 * Full synchronization function for Partner Onboarding.
 * Pulls all records from 'Onboarding form_V2', standardizes every column,
 * populates the target spreadsheet tab, and syncs to PostgreSQL in batches.
 */
function syncAllOnboardings() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("syncAllOnboardings skipped: another process holds the script lock.");
    return;
  }
  try {
    syncFromSourceSheetToTargetSheet();
  } finally {
    lock.releaseLock();
  }
}

function syncFromSourceSheetToTargetSheet() {
  Logger.log("Starting direct cross-sheet pull and standardization...");
  const cfg = getDbConfig();
  const sourceSs = getSourceSpreadsheet();
  const sourceSheet = sourceSs.getSheetByName(cfg.sourceSheetName);
  if (!sourceSheet) {
    throw new Error("Source sheet tab '" + cfg.sourceSheetName + "' not found in spreadsheet!");
  }
  
  const data = sourceSheet.getDataRange().getValues();
  if (data.length <= 1) {
    Logger.log("No data rows found in source sheet.");
    return;
  }
  
  Logger.log("Read " + (data.length - 1) + " raw rows from " + cfg.sourceSheetName);
  
  // Headers for target sheet
  const headers = [
    "Timestamp", "Email Address", "City", "Onboarding Type", "Lead Source", "Driver Plan",
    "Driver Name", "Driver Phone", "WhatsApp Phone", "Emergency Name", "Emergency Phone",
    "Reference Name", "Reference Phone", "Father Name", "Date of Birth", "Aadhaar Address",
    "Present Address", "PAN Number", "Aadhaar Number", "DL Expiry Date", "DL Number",
    "UPI ID", "PAN-Aadhaar Link", "DL Front URL", "DL Back URL", "Aadhaar Front URL",
    "Aadhaar Back URL", "PAN Card URL", "Address Proof URL", "Selfie Photo URL",
    "PAN-Aadhaar Photo URL", "Bank Proof URL", "Referral Phone", "Referral Name",
    "Account Holder Name", "Account Number", "IFSC Code", "Deposit Amount", "Partner ID",
    "Sheet Row Number", "Synced At"
  ];
  
  const targetSs = getTargetSpreadsheet();
  let targetSheet = targetSs.getSheetByName(cfg.targetSheetName);
  if (!targetSheet) {
    targetSheet = targetSs.insertSheet(cfg.targetSheetName);
  }
  
  targetSheet.clear();
  targetSheet.appendRow(headers);
  targetSheet.getRange(1, 1, 1, headers.length).setFontWeight("bold").setBackground("#f3f3f3");
  
  const parsedRecords = [];
  const sheetRows = [];
  const nowStr = formatTimestamp(new Date());
  
  for (let i = 1; i < data.length; i++) {
    let parsed = parseRow(data[i], i + 1);
    if (parsed) {
      parsedRecords.push(parsed);
      sheetRows.push(formatRecordForSheet(parsed, nowStr));
    }
  }
  
  // Write to Target Sheet in chunks of 500 rows to optimize execution time
  const CHUNK_SIZE = 500;
  for (let j = 0; j < sheetRows.length; j += CHUNK_SIZE) {
    let chunk = sheetRows.slice(j, j + CHUNK_SIZE);
    targetSheet.getRange(j + 2, 1, chunk.length, headers.length).setValues(chunk);
  }
  
  Logger.log("Wrote " + sheetRows.length + " clean standardized rows to tab '" + cfg.targetSheetName + "'.");
  
  // Sync all records to PostgreSQL using persistent single-connection multi-row inserts
  Logger.log("Starting PostgreSQL upsert for all " + parsedRecords.length + " onboarding records...");
  let syncedDbCount = upsertRecordsToDatabase(parsedRecords, false);
  Logger.log("Complete! Successfully synchronized " + syncedDbCount + " records to PostgreSQL database.");
}

function formatRecordForSheet(parsed, nowStr) {
  return [
    formatTimestamp(parsed.submissionTimestamp),
    parsed.email || "",
    parsed.city || "",
    parsed.onboardingType || "",
    parsed.leadSource || "",
    parsed.driverPlan || "",
    parsed.driverName || "",
    parsed.driverPhone || "",
    parsed.whatsappPhone || "",
    parsed.emergencyName || "",
    parsed.emergencyPhone || "",
    parsed.refName || "",
    parsed.refPhone || "",
    parsed.fatherName || "",
    formatDateOnly(parsed.dob) || "",
    parsed.aadhaarAddress || "",
    parsed.presentAddress || "",
    parsed.panNumber || "",
    parsed.aadhaarNumber || "",
    formatDateOnly(parsed.dlExpiry) || "",
    parsed.dlNumber || "",
    parsed.upiId || "",
    parsed.panAadhaarLinked || "",
    parsed.dlFront || "",
    parsed.dlBack || "",
    parsed.aadhaarFront || "",
    parsed.aadhaarBack || "",
    parsed.panCard || "",
    parsed.localAddressProof || "",
    parsed.selfiePhoto || "",
    parsed.panAadhaarPhoto || "",
    parsed.bankDetailsDoc || "",
    parsed.referralPhone || "",
    parsed.referralName || "",
    parsed.accountName || "",
    parsed.accountNumber || "",
    parsed.ifscCode || "",
    parsed.depositAmount || 0,
    parsed.partnerId || "",
    parsed.sheetRowNumber,
    nowStr || formatTimestamp(new Date())
  ];
}

// =============================================================================
// TRIGGER HANDLERS (WITH LOCKSERVICE AND BATCHING)
// =============================================================================

/**
 * Real-Time On-Edit Trigger
 */
function handleOnEdit(e) {
  if (!e || !e.range) return;
  const cfg = getDbConfig();
  const sheet = e.range.getSheet();
  if (sheet.getName() !== cfg.sourceSheetName) return;
  
  const startRow = e.range.getRow();
  const endRow = e.range.getLastRow();
  if (startRow <= 1 && endRow <= 1) return; // Header row
  
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) {
    Logger.log("handleOnEdit skipped: Lock contention.");
    return;
  }
  
  try {
    const actualStart = Math.max(2, startRow);
    const numRows = endRow - actualStart + 1;
    const rawData = sheet.getRange(actualStart, 1, numRows, sheet.getLastColumn()).getValues();
    
    const records = [];
    const targetRows = [];
    const nowStr = formatTimestamp(new Date());
    const targetSs = getTargetSpreadsheet();
    const targetSheet = targetSs.getSheetByName(cfg.targetSheetName);

    for (let i = 0; i < rawData.length; i++) {
      let parsed = parseRow(rawData[i], actualStart + i);
      if (parsed) {
        records.push(parsed);
        if (targetSheet) {
          targetRows.push(formatRecordForSheet(parsed, nowStr));
        }
      }
    }
    
    // Batched single RPC write to target sheet
    if (targetSheet && targetRows.length > 0) {
      targetSheet.getRange(actualStart, 1, targetRows.length, targetRows[0].length).setValues(targetRows);
    }
    
    if (records.length > 0) {
      upsertRecordsToDatabase(records);
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Real-Time Form-Submit Trigger
 */
function handleOnFormSubmit(e) {
  if (!e || !e.values) return;
  const cfg = getDbConfig();
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) {
    Logger.log("handleOnFormSubmit skipped: Lock contention.");
    return;
  }
  try {
    let parsed = parseRow(e.values, e.range ? e.range.getRow() : 0);
    if (parsed) {
      const targetSs = getTargetSpreadsheet();
      const targetSheet = targetSs.getSheetByName(cfg.targetSheetName);
      if (targetSheet && parsed.sheetRowNumber > 1) {
        let sheetRow = formatRecordForSheet(parsed, formatTimestamp(new Date()));
        targetSheet.getRange(parsed.sheetRowNumber, 1, 1, sheetRow.length).setValues([sheetRow]);
      }
      upsertRecordsToDatabase([parsed]);
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Helper to find the actual last non-empty row
 */
function getTrueLastRow(sheet) {
  if (!sheet) return 0;
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) return lastRow;
  
  const colA = sheet.getRange(1, 1, lastRow, 1).getValues();
  for (let i = colA.length - 1; i >= 0; i--) {
    let val = colA[i][0];
    if (val !== "" && val !== null && val !== undefined) {
      return i + 1;
    }
  }
  return 1;
}

/**
 * 1-Minute Time-Driven Catch-Up Sync for Recent Submissions
 */
function syncRecentOnboardings() {
  const cfg = getDbConfig();
  const sourceSs = getSourceSpreadsheet();
  const sourceSheet = sourceSs.getSheetByName(cfg.sourceSheetName);
  if (!sourceSheet) return;
  
  const trueLastRow = getTrueLastRow(sourceSheet);
  if (trueLastRow <= 1) return;
  
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) {
    Logger.log("syncRecentOnboardings skipped: Lock contention.");
    return;
  }
  
  try {
    const WINDOW_SIZE = 100;
    const startRow = Math.max(2, trueLastRow - WINDOW_SIZE + 1);
    const numRows = trueLastRow - startRow + 1;
    
    const data = sourceSheet.getRange(startRow, 1, numRows, sourceSheet.getLastColumn()).getValues();
    const records = [];
    const sheetRows = [];
    const nowStr = formatTimestamp(new Date());

    for (let i = 0; i < data.length; i++) {
      let parsed = parseRow(data[i], startRow + i);
      if (parsed) {
        records.push(parsed);
        sheetRows.push({
          rowNum: startRow + i,
          values: formatRecordForSheet(parsed, nowStr)
        });
      }
    }
    
    if (records.length > 0) {
      const targetSs = getTargetSpreadsheet();
      const targetSheet = targetSs.getSheetByName(cfg.targetSheetName);
      if (targetSheet) {
        // Write to target sheet
        for (let j = 0; j < sheetRows.length; j++) {
          let r = sheetRows[j];
          targetSheet.getRange(r.rowNum, 1, 1, r.values.length).setValues([r.values]);
        }
      }

      upsertRecordsToDatabase(records);
      Logger.log("Catch-up sync (1-min) successfully updated " + records.length + " recent records in sheet & database.");
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Logs invalid onboarding submissions to a dedicated 'onboarding_sync_errors' tab.
 */
function logOnboardingError(rowIndex, rawPhone, driverName, failureReason, rawRow) {
  try {
    const cfg = getDbConfig();
    const targetSs = getTargetSpreadsheet();
    let errSheet = targetSs.getSheetByName(cfg.errorSheetName);
    const errHeaders = ["Logged At", "Source Row Index", "Driver Name", "Raw Phone", "Failure Reason", "Raw Data Summary"];
    
    if (!errSheet) {
      errSheet = targetSs.insertSheet(cfg.errorSheetName);
      errSheet.appendRow(errHeaders);
      errSheet.getRange(1, 1, 1, errHeaders.length).setFontWeight("bold").setBackground("#fee2e2");
    }
    
    let nowStr = formatTimestamp(new Date());
    let rawSummary = rawRow ? JSON.stringify(rawRow.slice(0, 8)) : "";
    errSheet.appendRow([nowStr, rowIndex, driverName || "UNKNOWN", String(rawPhone || ""), failureReason, rawSummary]);
  } catch (e) {
    Logger.log("Error writing to error sheet: " + e.message);
  }
}

// =============================================================================
// TRIGGER MANAGEMENT & INITIAL SETUP
// =============================================================================

/**
 * Installs event-driven and lightweight hourly reconciliation triggers.
 */
function setupTriggers() {
  deleteAllTriggers();
  
  // 1. Live On-Edit Trigger on Google Sheet
  ScriptApp.newTrigger("handleOnEdit")
    .forSpreadsheet(SpreadsheetApp.getActiveSpreadsheet())
    .onEdit()
    .create();

  // 2. Real-time Form Submit Trigger (if linked to Google Form)
  try {
    ScriptApp.newTrigger("handleOnFormSubmit")
      .forSpreadsheet(SpreadsheetApp.getActiveSpreadsheet())
      .onFormSubmit()
      .create();
  } catch (e) {
    Logger.log("Form submit trigger notice: " + e.message);
  }
    
  // 3. Time-Driven Catch-Up Sync (Runs every 1 minute)
  ScriptApp.newTrigger("syncRecentOnboardings")
    .timeBased()
    .everyMinutes(1)
    .create();
    
  Logger.log("Automated triggers created successfully! (Event-driven + 1-Minute Catch-Up Sync)");
}

function deleteAllTriggers() {
  const triggers = ScriptApp.getProjectTriggers();
  let count = 0;
  for (let i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
    count++;
  }
  Logger.log("Removed " + count + " existing trigger(s).");
}

// =============================================================================
// GOOGLE SHEETS CUSTOM MENU (ONE-CLICK UI)
// =============================================================================

/**
 * Creates a custom menu in the Google Sheets interface upon opening.
 */
function onOpen() {
  if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getUi) {
    SpreadsheetApp.getUi()
      .createMenu("🚀 LetzRyd Pipeline")
      .addItem("1. Test Database Connection", "testConnection")
      .addItem("2. Setup Live Triggers", "setupTriggers")
      .addSeparator()
      .addItem("3. Sync All Onboardings (Full Refresh)", "syncAllOnboardings")
      .addItem("4. Catch-Up Sync Recent Rows", "syncRecentOnboardings")
      .addToUi();
  }
}

