/**
 * ==============================================================================
 * LETZRYD - PARTNER ONBOARDING PIPELINE (PAN INDIA MASTER SYNC)
 * ==============================================================================
 * 
 * Master Source Sheet : 'Pan India Master Sheet' (View-Only Access)
 *   URL : https://docs.google.com/spreadsheets/d/1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM/edit
 *   Tab : 'Onboarding form_V2' (GID: 1460662046)
 * 
 * Destination Sheet   : 'partner_onboarding_form' (Your Editable Google Sheet)
 *   URL : https://docs.google.com/spreadsheets/d/1IcuCT5S5mDwFEcV1-HRCdG2l5K5pbHkQ8FaDVGT9MxY/edit
 *   Tab : 'sheet_driver_onboarding' (or first active tab)
 * 
 * Destination Database: PostgreSQL
 *   Host : 35.200.196.113:5432
 *   Table: public.sheet_driver_onboarding
 * 
 * KEY DESIGN FOR VIEWER-ONLY SOURCE:
 * - Since your account has View-Only access to the Master Sheet, onEdit/onFormSubmit
 *   triggers cannot be installed on the Master Sheet.
 * - Instead, this pipeline uses an automated 1-minute time-driven trigger that
 *   reads the Master Sheet via openByUrl (which Viewer permission fully allows),
 *   standardizes all rows, writes to your editable sheet, and upserts to PostgreSQL.
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
function getDbConfig() {
  let props = null;
  try {
    props = PropertiesService.getScriptProperties();
  } catch(e) {}

  let host = (props && props.getProperty("DB_HOST")) || "35.200.196.113";
  let port = (props && props.getProperty("DB_PORT")) || "5432";
  let database = (props && props.getProperty("DB_NAME")) || "postgres";
  let user = (props && props.getProperty("DB_USER")) || "postgres";
  let password = (props && props.getProperty("DB_PASSWORD")) || "8S5]U3@L^Xz)\\FH}";

  if (!password || password.indexOf("YOUR_") !== -1) {
    password = "8S5]U3@L^Xz)\\FH}";
  }
  if (!host || host.indexOf("YOUR_") !== -1) {
    host = "35.200.196.113";
  }

  return {
    host: host,
    port: port,
    database: database,
    user: user,
    password: password,
    
    // Master Source Sheet (Pan India Master Sheet - Read Only Viewer Access)
    sourceSpreadsheetUrl: (props && props.getProperty("SOURCE_SPREADSHEET_URL")) || "https://docs.google.com/spreadsheets/d/1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM/edit",
    sourceSheetName: (props && props.getProperty("SOURCE_SHEET_NAME")) || "Onboarding form_V2",
    
    // Destination Sheet (Your Editable Working Sheet)
    targetSpreadsheetUrl: (props && props.getProperty("TARGET_SPREADSHEET_URL")) || "https://docs.google.com/spreadsheets/d/1IcuCT5S5mDwFEcV1-HRCdG2l5K5pbHkQ8FaDVGT9MxY/edit",
    targetSheetName: (props && props.getProperty("TARGET_SHEET_NAME")) || "sheet_driver_onboarding",

    // Error logging tab for invalid records
    errorSheetName: (props && props.getProperty("ERROR_SHEET_NAME")) || "onboarding_sync_errors"
  };
}

const DB_CONFIG = getDbConfig();

const CITY_PREFIX_MAP = {
  "bengaluru": "LETZBLR",
  "bangalore": "LETZBLR",
  "hyderabad": "LETZHYD",
  "mumbai": "LETZMUM",
  "delhi": "LETZDEL",
  "chennai": "LETZCHN",
  "pune": "LETZPUN"
};

const HOMOGLYPH_MAP = {
  '\u0391': 'A', '\u0392': 'B', '\u0395': 'E', '\u0396': 'Z', '\u0397': 'H',
  '\u0399': 'I', '\u039A': 'K', '\u039C': 'M', '\u039D': 'N', '\u039F': 'O',
  '\u03A1': 'P', '\u03A4': 'T', '\u03A5': 'Y', '\u03A7': 'X',
  '\u0410': 'A', '\u0412': 'B', '\u0415': 'E', '\u041A': 'K', '\u041C': 'M',
  '\u041D': 'H', '\u041E': 'O', '\u0420': 'P', '\u0421': 'C', '\u0422': 'T',
  '\u0425': 'X'
};

// =============================================================================
// SPREADSHEET GETTERS (FIXED: Never Null In Time Triggers)
// =============================================================================

function getSourceSpreadsheet() {
  const cfg = getDbConfig();
  if (cfg.sourceSpreadsheetUrl && cfg.sourceSpreadsheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(cfg.sourceSpreadsheetUrl);
    } catch(e) {
      Logger.log("openByUrl error for master source sheet: " + e.message);
    }
  }
  return null;
}

function getTargetSpreadsheet() {
  const cfg = getDbConfig();
  if (cfg.targetSpreadsheetUrl && cfg.targetSpreadsheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(cfg.targetSpreadsheetUrl);
    } catch(e) {
      Logger.log("openByUrl error for target sheet: " + e.message);
    }
  }
  return SpreadsheetApp.getActiveSpreadsheet();
}

function getTargetSheet(targetSs) {
  if (!targetSs) return null;
  const cfg = getDbConfig();
  let sheet = targetSs.getSheetByName(cfg.targetSheetName);
  if (!sheet) {
    // If specific tab doesn't exist, use the first tab
    sheet = targetSs.getSheets()[0];
  }
  return sheet;
}

// =============================================================================
// DATA SANITIZATION AND STANDARDIZATION ENGINE
// =============================================================================

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

function sanitizeOnboardingType(val) {
  let text = sanitizeText(val);
  if (!text) return "Individual";
  let lower = text.toLowerCase();
  if (lower.indexOf("oper") !== -1) return "Operator";
  return "Individual";
}

function sanitizePhone(val) {
  if (val === null || val === undefined) return null;
  let str = String(val).trim();
  if (str === "" || str === "-" || str.toLowerCase() === "na" || str.toLowerCase() === "null") return null;
  
  if (str.toUpperCase().indexOf("E+") !== -1 || str.indexOf("e+") !== -1) {
    let num = Number(str);
    if (!isNaN(num)) {
      str = num.toLocaleString('fullwide', {useGrouping: false});
    }
  }
  
  str = str.replace(/\.0+$/, "");
  let digits = str.replace(/\D/g, "");
  if (!digits || digits.length < 10) return null;
  
  if (digits.length === 12 && digits.startsWith("91")) {
    digits = digits.substring(2);
  } else if (digits.length === 11 && digits.startsWith("0")) {
    digits = digits.substring(1);
  }
  return digits.length >= 10 ? digits.slice(-10) : digits;
}

function sanitizePAN(val) {
  let text = sanitizeText(val);
  if (!text) return null;
  let cleaned = text.toUpperCase().replace(/[^A-Z0-9]/g, "");
  return cleaned.length > 0 ? cleaned : null;
}

function isPANValid(pan) {
  if (!pan) return false;
  return /^[A-Z]{5}[0-9]{4}[A-Z]$/.test(pan);
}

function sanitizeAadhaar(val) {
  if (val === null || val === undefined) return null;
  let str = String(val).trim().replace(/\.0+$/, "");
  let digits = str.replace(/\D/g, "");
  return digits || null;
}

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

function sanitizeDL(val) {
  if (!val) return null;
  if (isDateValue(val)) return null;
  let text = sanitizeText(val);
  if (!text) return null;
  let cleaned = text.toUpperCase().replace(/[\s\-\/\.#_]/g, "");
  if (cleaned === "NA" || cleaned === "NIL" || cleaned === "NONE" || cleaned === "NULL" || /^0+$/.test(cleaned)) {
    return null;
  }
  if (cleaned.indexOf("GMT") !== -1 || cleaned.indexOf("INDIASTANDARDTIME") !== -1) {
    return null;
  }
  return cleaned.length >= 4 ? cleaned : null;
}

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

function sanitizeIFSC(val) {
  let text = sanitizeText(val);
  if (!text) return null;
  let cleaned = text.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (cleaned.length === 10 && cleaned.charAt(4) !== '0') {
    cleaned = cleaned.substring(0, 4) + "0" + cleaned.substring(4);
  }
  return (cleaned.length === 11 && !/^0+$/.test(cleaned)) ? cleaned : null;
}

function sanitizeUPI(val) {
  let text = sanitizeText(val);
  if (!text) return null;
  let match = text.match(/[a-zA-Z0-9\.\-_]+@[a-zA-Z0-9]+/);
  return match ? match[0].toLowerCase() : (text.indexOf("@") !== -1 ? text.toLowerCase() : null);
}

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

function resolveTwoDigitYear(yy, isDob) {
  let currentYear = new Date().getFullYear();
  if (isDob) {
    let minDobYear = currentYear - 75;
    let maxDobYear = currentYear - 18;
    let opt1 = 1900 + yy;
    let opt2 = 2000 + yy;
    if (opt2 >= minDobYear && opt2 <= maxDobYear) return opt2;
    if (opt1 >= minDobYear && opt1 <= maxDobYear) return opt1;
    return opt1;
  }
  return (yy > 50) ? 1900 + yy : 2000 + yy;
}

function parseDateTime(val, isDob, minYear, maxYear) {
  if (!val) return null;
  const currentYear = new Date().getFullYear();
  const lowerBound = minYear || (isDob ? (currentYear - 75) : 1990);
  const upperBound = maxYear || (isDob ? (currentYear - 18) : 2060);

  function clampDate(dt) {
    if (!dt || isNaN(dt.getTime())) return null;
    let y = dt.getFullYear();
    if (y < lowerBound || y > upperBound) {
      return null;
    }
    return dt;
  }

  if (val instanceof Date) {
    if (isNaN(val.getTime())) return null;
    let y = val.getFullYear();
    if (y < 100) {
      val.setFullYear(resolveTwoDigitYear(y, isDob));
    }
    return clampDate(val);
  }

  if (typeof val === "number") {
    if (val < 1 || val > 75000) return null;
    let dt = new Date(Math.round((val - 25569) * 86400 * 1000));
    if (isNaN(dt.getTime())) return null;
    let y = dt.getFullYear();
    if (y < 100) dt.setFullYear(resolveTwoDigitYear(y, isDob));
    return clampDate(dt);
  }

  let str = String(val).trim();
  if (!str || str === "-" || str.toLowerCase() === "na" || str.toLowerCase() === "null") return null;

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

  let yyMdMatch = str.match(/^(\d{2})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (yyMdMatch) {
    let yy = parseInt(yyMdMatch[1], 10);
    let year = resolveTwoDigitYear(yy, isDob);
    let month = parseInt(yyMdMatch[2], 10) - 1;
    let day = parseInt(yyMdMatch[3], 10);
    let dt = new Date(Date.UTC(year, month, day, 12, 0, 0) - (5.5 * 3600 * 1000));
    return clampDate(dt);
  }

  let parsed = new Date(str);
  if (!isNaN(parsed.getTime())) {
    let y = parsed.getFullYear();
    if (y < 100) parsed.setFullYear(resolveTwoDigitYear(y, isDob));
    return clampDate(parsed);
  }

  return null;
}

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

function sanitizeDocUrl(val) {
  let text = sanitizeText(val);
  if (!text || text === "-" || text.toLowerCase() === "na") return null;
  return text.startsWith("http") ? text : null;
}

function generatePartnerId(city, phone) {
  let cleanCity = (city || "bengaluru").toLowerCase();
  let prefix = CITY_PREFIX_MAP[cleanCity] || "LETZBLR";
  let cleanPhone = sanitizePhone(phone);
  return cleanPhone ? (prefix + cleanPhone) : null;
}

// =============================================================================
// ROW OBJECT PARSER (INDEX 0 TO 38 FROM PAN INDIA MASTER SHEET)
// =============================================================================

function parseRow(row, rowIndex) {
  if (!row || row.length === 0) return null;
  
  let rawTs = row[0];
  let submissionTs = parseDateTime(rawTs, false, 2020, 2030);
  if (!submissionTs) return null;
  
  let email = sanitizeText(row[1]);
  if (email && email.toLowerCase() === "old data") email = null;
  let city = sanitizeCity(row[2]);
  let onboardingType = sanitizeOnboardingType(row[3]);
  let leadSource = sanitizeText(row[4]);
  let driverPlan = sanitizeText(row[5]);
  let driverName = sanitizeText(row[6]) ? String(sanitizeText(row[6])).toUpperCase() : null;
  let rawPhone = row[7];
  let driverPhone = sanitizePhone(rawPhone);
  
  if (!driverPhone || !/^[0-9]{10}$/.test(driverPhone)) {
    let failureReason = !rawPhone || String(rawPhone).trim() === "" 
      ? "Blank / Missing Phone Number" 
      : "Invalid Phone Number Format: '" + String(rawPhone) + "' (Must be 10 digits)";
    logOnboardingError(rowIndex, rawPhone, driverName, failureReason, row);
    return null;
  }
  
  let whatsappPhone = sanitizePhone(row[8]) || driverPhone;
  let emergencyName = sanitizeText(row[9]);
  let emergencyPhone = sanitizePhone(row[10]);
  let refName = sanitizeText(row[11]);
  let refPhone = sanitizePhone(row[12]);
  let fatherName = sanitizeText(row[13]);
  let dob = parseDateTime(row[14], true);
  let aadhaarAddress = sanitizeText(row[15]);
  let presentAddress = sanitizeText(row[16]) || aadhaarAddress;
  let panNumber = sanitizePAN(row[17]);
  let aadhaarNumber = sanitizeAadhaar(row[18]);
  
  let rawCol19 = row[19];
  let rawCol20 = row[20];
  let dlNumber = null;
  let dlExpiry = null;

  let col19IsDate = isDateValue(rawCol19);
  let col20IsDate = isDateValue(rawCol20);

  if (col19IsDate && !col20IsDate) {
    dlExpiry = parseDateTime(rawCol19, false, 1990, 2060);
    dlNumber = sanitizeDL(rawCol20);
  } else {
    dlNumber = sanitizeDL(rawCol19);
    dlExpiry = parseDateTime(rawCol20, false, 1990, 2060);
    if (!dlExpiry && col19IsDate) {
      dlExpiry = parseDateTime(rawCol19, false, 1990, 2060);
    }
  }

  let upiFromAccount = sanitizeUPI(row[21]);
  let panAadhaarLinked = sanitizeText(row[22]);
  
  let dlFront = sanitizeDocUrl(row[23]);
  let dlBack = sanitizeDocUrl(row[24]);
  let aadhaarFront = sanitizeDocUrl(row[25]);
  let aadhaarBack = sanitizeDocUrl(row[26]);
  let panCard = sanitizeDocUrl(row[27]);
  let localAddressProof = sanitizeDocUrl(row[28]);
  let selfiePhoto = sanitizeDocUrl(row[29]);
  let panAadhaarPhoto = sanitizeDocUrl(row[30]);
  let bankDetailsDoc = sanitizeDocUrl(row[31]);
  
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
// DATABASE JDBC PIPELINE (ZERO-BURN POSTGRESQL UPSERT)
// =============================================================================

function getDbConnection() {
  const cfg = getDbConfig();
  const url = "jdbc:postgresql://" + cfg.host + ":" + cfg.port + "/" + cfg.database;
  return Jdbc.getConnection(url, cfg.user, cfg.password);
}

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
    Logger.log("Connection Successful! Rows in sheet_driver_onboarding: " + count);
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

function sqlEscapeStr(val) {
  if (val === null || val === undefined) return "NULL::text";
  let s = String(val).replace(/'/g, "''").replace(/\\/g, "\\\\");
  if (s.length > 1500) {
    s = s.substring(0, 1500);
  }
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
 * Executes an atomic micro-batch CTE upsert into public.sheet_driver_onboarding.
 * Micro-batching ensures SQL statement character length stays well below Apps Script's JDBC limit.
 */
function executeUpsertBatch(stmt, records) {
  let valueClauses = [];
  
  for (let k = 0; k < records.length; k++) {
    let r = records[k];
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
}

function upsertRecordsToDatabase(records) {
  if (!records || records.length === 0) return 0;
  
  let conn = null;
  let stmt = null;
  // Micro-batch size of 5 stays safely below Google Apps Script JDBC query string length limit (~32KB)
  const BATCH_SIZE = 5;
  let totalCount = 0;
  
  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    stmt = conn.createStatement();
    
    for (let i = 0; i < records.length; i += BATCH_SIZE) {
      let chunk = records.slice(i, i + BATCH_SIZE);
      try {
        executeUpsertBatch(stmt, chunk);
        conn.commit();
        totalCount += chunk.length;
      } catch (batchErr) {
        Logger.log("Micro-batch failed (" + batchErr.message + "). Retrying row-by-row fallback...");
        if (conn) { try { conn.rollback(); } catch(rb){} }
        
        // Single row fallback: ensures oversized individual cells never block the whole sync
        for (let j = 0; j < chunk.length; j++) {
          try {
            executeUpsertBatch(stmt, [chunk[j]]);
            conn.commit();
            totalCount++;
          } catch (singleErr) {
            if (conn) { try { conn.rollback(); } catch(rb){} }
            Logger.log("Row-level error on row " + chunk[j].sheetRowNumber + ": " + singleErr.message);
          }
        }
      }
      Logger.log("Upserted: " + totalCount + "/" + records.length + " onboarding records into PostgreSQL.");
    }
    
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
// SHEET POPULATION & BACKFILL HANDLERS
// =============================================================================

/**
 * Fast Sheet Backfill (Recommended):
 * Reads all 2,400+ rows directly from the View-Only Pan India Master Sheet,
 * standardizes every field, and writes them straight into your local sheet in ~5 seconds.
 * Does not hit database JDBC (PostgreSQL already has all historical rows backfilled).
 */
function populateSheetOnly() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(60000)) {
    Logger.log("populateSheetOnly skipped: another process holds the script lock.");
    return;
  }
  try {
    Logger.log("Starting sheet-only population from Pan India Master Sheet...");
    const cfg = getDbConfig();
    const sourceSs = getSourceSpreadsheet();
    if (!sourceSs) {
      throw new Error("Could not open Master Sheet via URL. Verify your account has Viewer access!");
    }
    const sourceSheet = sourceSs.getSheetByName(cfg.sourceSheetName);
    if (!sourceSheet) {
      throw new Error("Source sheet tab '" + cfg.sourceSheetName + "' not found in Master Sheet!");
    }
    
    const data = sourceSheet.getDataRange().getValues();
    if (data.length <= 1) {
      Logger.log("No data rows found in master source sheet.");
      return;
    }
    
    Logger.log("Read " + (data.length - 1) + " raw rows from Master Sheet (" + cfg.sourceSheetName + ")");
    
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
    let targetSheet = getTargetSheet(targetSs);
    if (!targetSheet) {
      targetSheet = targetSs.insertSheet(cfg.targetSheetName);
    }
    
    targetSheet.clear();
    targetSheet.appendRow(headers);
    targetSheet.getRange(1, 1, 1, headers.length).setFontWeight("bold").setBackground("#f3f3f3");
    
    const sheetRows = [];
    const nowStr = formatTimestamp(new Date());
    
    for (let i = 1; i < data.length; i++) {
      let parsed = parseRow(data[i], i + 1);
      if (parsed) {
        sheetRows.push(formatRecordForSheet(parsed, nowStr));
      }
    }
    
    const neededRows = sheetRows.length + 1;
    if (targetSheet.getMaxRows() < neededRows) {
      targetSheet.insertRowsAfter(targetSheet.getMaxRows(), neededRows - targetSheet.getMaxRows());
    }

    const CHUNK_SIZE = 500;
    for (let j = 0; j < sheetRows.length; j += CHUNK_SIZE) {
      let chunk = sheetRows.slice(j, j + CHUNK_SIZE);
      targetSheet.getRange(j + 2, 1, chunk.length, headers.length).setValues(chunk);
    }
    
    Logger.log("Wrote " + sheetRows.length + " clean standardized rows to destination sheet.");
    
    if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getUi) {
      SpreadsheetApp.getUi().alert(
        "Sheet Population Complete",
        "Successfully populated your destination sheet with " + sheetRows.length + " standardized rows from the Pan India Master Sheet!\n(PostgreSQL database is already fully synced).",
        SpreadsheetApp.getUi().ButtonSet.OK
      );
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Full Sync: Standardizes all rows to local sheet, and verifies/upserts the latest 200 records to PostgreSQL.
 */
function syncAllOnboardings() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(60000)) {
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
  Logger.log("Starting full sync from Pan India Master Sheet...");
  const cfg = getDbConfig();
  const sourceSs = getSourceSpreadsheet();
  if (!sourceSs) {
    throw new Error("Could not open Master Sheet via URL. Verify your account has Viewer access!");
  }
  const sourceSheet = sourceSs.getSheetByName(cfg.sourceSheetName);
  if (!sourceSheet) {
    throw new Error("Source sheet tab '" + cfg.sourceSheetName + "' not found in Master Sheet!");
  }
  
  const data = sourceSheet.getDataRange().getValues();
  if (data.length <= 1) {
    Logger.log("No data rows found in master source sheet.");
    return;
  }
  
  Logger.log("Read " + (data.length - 1) + " raw rows from Master Sheet (" + cfg.sourceSheetName + ")");
  
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
  let targetSheet = getTargetSheet(targetSs);
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
  
  // Ensure destination sheet has enough rows
  const neededRows = sheetRows.length + 1;
  if (targetSheet.getMaxRows() < neededRows) {
    targetSheet.insertRowsAfter(targetSheet.getMaxRows(), neededRows - targetSheet.getMaxRows());
  }

  // Batch write 500 rows at a time to stay within quotas
  const CHUNK_SIZE = 500;
  for (let j = 0; j < sheetRows.length; j += CHUNK_SIZE) {
    let chunk = sheetRows.slice(j, j + CHUNK_SIZE);
    targetSheet.getRange(j + 2, 1, chunk.length, headers.length).setValues(chunk);
  }
  
  Logger.log("Wrote " + sheetRows.length + " clean standardized rows to destination sheet.");
  Logger.log("Upserting latest 200 records into PostgreSQL database...");
  
  // Upsert the most recent 200 records to ensure DB is fresh without risking a 6-minute Apps Script timeout
  const dbBatch = parsedRecords.slice(-200);
  let syncedDbCount = upsertRecordsToDatabase(dbBatch);
  Logger.log("Complete! Successfully synchronized " + syncedDbCount + " records to database.");
  
  if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getUi) {
    SpreadsheetApp.getUi().alert(
      "Full Backfill Complete",
      "Successfully synchronized " + sheetRows.length + " rows to your Google Sheet and verified latest " + syncedDbCount + " records in PostgreSQL database.\n(All historical records are already safely in PostgreSQL).",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  }
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
// LATEST 100 SYNC & TIME TRIGGER HANDLER (VIEW-ONLY SOURCE SAFE)
// =============================================================================

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
 * Syncs the latest 100 records from Pan India Master Sheet into PostgreSQL & Local Sheet.
 */
function syncLatest100Records() {
  return syncRecentOnboardings(100);
}

/**
 * Live Sync Handler (called by 1-minute automated trigger or manually).
 * Inspects the latest records from the read-only master sheet, updates local sheet, and upserts to PostgreSQL.
 */
function syncRecentOnboardings(count) {
  // Validate count: background time triggers pass an Event Object instead of a number
  const WINDOW_SIZE = (typeof count === "number" && count > 0) ? count : 25;
  const cfg = getDbConfig();
  const sourceSs = getSourceSpreadsheet();
  if (!sourceSs) {
    Logger.log("syncRecentOnboardings: Master source spreadsheet could not be opened.");
    return 0;
  }
  const sourceSheet = sourceSs.getSheetByName(cfg.sourceSheetName);
  if (!sourceSheet) return 0;
  
  const trueLastRow = getTrueLastRow(sourceSheet);
  if (trueLastRow <= 1) return 0;
  
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) {
    Logger.log("syncRecentOnboardings skipped: Lock contention.");
    return 0;
  }
  
  let totalCount = 0;
  try {
    const startRow = Math.max(2, trueLastRow - WINDOW_SIZE + 1);
    const numRows = trueLastRow - startRow + 1;
    
    // Read directly from read-only master sheet
    const data = sourceSheet.getRange(startRow, 1, numRows, sourceSheet.getLastColumn()).getValues();
    const records = [];
    const nowStr = formatTimestamp(new Date());

    const targetSs = getTargetSpreadsheet();
    const targetSheet = getTargetSheet(targetSs);

    for (let i = 0; i < data.length; i++) {
      let currentRowNum = startRow + i;
      let parsed = parseRow(data[i], currentRowNum);
      if (parsed) {
        records.push(parsed);
        
        // Write to destination sheet
        if (targetSheet) {
          if (targetSheet.getMaxRows() < currentRowNum) {
            targetSheet.insertRowsAfter(targetSheet.getMaxRows(), currentRowNum - targetSheet.getMaxRows());
          }
          let sheetRow = formatRecordForSheet(parsed, nowStr);
          targetSheet.getRange(currentRowNum, 1, 1, sheetRow.length).setValues([sheetRow]);
        }
      }
    }
    
    if (records.length > 0) {
      totalCount = upsertRecordsToDatabase(records);
      Logger.log("Sync updated " + totalCount + " recent records in database & destination sheet.");
      
      // Only show UI popup if manually triggered by user from spreadsheet menu
      if (typeof count === "number" && typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getUi) {
        SpreadsheetApp.getUi().alert(
          "Sync Complete",
          "Successfully synced latest " + totalCount + " records into database and sheet.",
          SpreadsheetApp.getUi().ButtonSet.OK
        );
      }
    }
  } catch(err) {
    Logger.log("syncRecentOnboardings error caught: " + err.message);
  } finally {
    lock.releaseLock();
  }
  return totalCount;
}

function logOnboardingError(rowIndex, rawPhone, driverName, failureReason, rawRow) {
  try {
    const cfg = getDbConfig();
    const targetSs = getTargetSpreadsheet();
    if (!targetSs) return;
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
// TRIGGER MANAGEMENT & SETUP (TIME-DRIVEN AUTOMATION)
// =============================================================================

function setupTriggers() {
  deleteAllTriggers();
  
  // Install 1-Minute Automated Catch-Up Sync
  // Since you have Viewer access to the master sheet, this time-driven trigger
  // is the 100% reliable method to ingest new entries in real time without permission errors.
  ScriptApp.newTrigger("syncRecentOnboardings")
    .timeBased()
    .everyMinutes(1)
    .create();
    
  Logger.log("Automated 1-Minute Sync Trigger created successfully!");
  if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getUi) {
    SpreadsheetApp.getUi().alert(
      "Live Automation Active",
      "Automated 1-Minute Trigger installed successfully! The script will now pull new rows from the Pan India Master Sheet into PostgreSQL and your sheet automatically every 1 minute.",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  }
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

function onOpen() {
  if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getUi) {
    SpreadsheetApp.getUi()
      .createMenu("🚀 LetzRyd Pipeline")
      .addItem("1. Test Database Connection", "testConnection")
      .addItem("2. Setup 1-Min Live Sync Trigger", "setupTriggers")
      .addSeparator()
      .addItem("3. Populate All Sheet Rows (Fast Backfill)", "populateSheetOnly")
      .addItem("4. Sync Latest 100 Records (DB + Sheet)", "syncLatest100Records")
      .addItem("5. Full Sync (Sheet + DB)", "syncAllOnboardings")
      .addSeparator()
      .addItem("6. Remove All Triggers", "deleteAllTriggers")
      .addToUi();
  }
}
