/**
 * ==============================================================================
 * LETZRYD - ADJUSTMENT FORM LIVE PIPELINE (sheet_adjustments)
 * ==============================================================================
 * 
 * Source Sheet : 'Adjustment-Form' (Raw Form Responses)
 * Target Sheet : 'sheet_adjustments' (Standardized Tab in Spreadsheet)
 * Target Table : public.sheet_adjustments & public.core_adjustments
 * 
 * Key Features & Audit Fixes:
 *  - Fix 1: Parameterized JDBC PreparedStatement CTE Upsert (Zero Sequence Burning)
 *  - Fix 2: Elimination of SQL Injection & raw string concatenation
 *  - Fix 3: Concurrency script locking with 3-attempt exponential backoff
 *  - Fix 4: Strict IST timezone date/timestamp extraction (+05:30) preventing 1-day backward shift
 *  - Fix 5: Empty-row validator in transformAdjustmentRow preventing ghost records
 *  - Fix 6: API optimization avoiding openByUrl cross-service RPC overhead
 *  - Fix 7: PropertiesService credential management with automated self-healing
 *  - Fix 8: Comprehensive testDbConnection and custom spreadsheet UI menu
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
function getDbConfig() {
  var props = null;
  try {
    props = PropertiesService.getScriptProperties();
  } catch(e){}
  
  var host = (props && props.getProperty("DB_HOST")) || "YOUR_DB_HOST";
  var port = (props && props.getProperty("DB_PORT")) || "5432";
  var database = (props && props.getProperty("DB_NAME")) || "postgres";
  var user = (props && props.getProperty("DB_USER")) || "postgres";
  var password = (props && props.getProperty("DB_PASSWORD")) || "YOUR_DB_PASSWORD";

  // Self-heal corrupted or unescaped password in Script Properties
  if (!password || password.indexOf("YOUR_") !== -1 || password === "8S5]U3@L^Xz)FH}") {
    password = "YOUR_DB_PASSWORD";
  }
  if (!host || host.indexOf("YOUR_") !== -1) {
    host = "YOUR_DB_HOST";
  }

  return {
    host: host,
    port: port,
    database: database,
    user: user,
    password: password,
    sourceSpreadsheetUrl: (props && props.getProperty("SOURCE_SPREADSHEET_URL")) || "https://docs.google.com/spreadsheets/d/1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM/edit",
    sourceSheetName: (props && props.getProperty("SOURCE_SHEET_NAME")) || "Adjustment-Form",
    targetSheetName: (props && props.getProperty("TARGET_SHEET_NAME")) || "sheet_adjustments"
  };
}

/**
 * Run once manually to store credentials securely in Script Properties.
 */
function setupScriptProperties() {
  var props = PropertiesService.getScriptProperties();
  props.setProperties({
    "DB_HOST": "YOUR_DB_HOST",
    "DB_PORT": "5432",
    "DB_NAME": "postgres",
    "DB_USER": "postgres",
    "DB_PASSWORD": "YOUR_DB_PASSWORD",
    "SOURCE_SPREADSHEET_URL": "https://docs.google.com/spreadsheets/d/1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM/edit",
    "SOURCE_SHEET_NAME": "Adjustment-Form",
    "TARGET_SHEET_NAME": "sheet_adjustments"
  });
  Logger.log("Script properties configured successfully.");
}

// Standard JDBC SQL Type Codes
const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  TIMESTAMP: 93,
  NUMERIC: 2,
  INTEGER: 4,
  NULL: 0
};

const CITY_PREFIX_MAP = {
  "bengaluru": "LETZBLR",
  "bangalore": "LETZBLR",
  "blr": "LETZBLR",
  "hyderabad": "LETZHYD",
  "hyd": "LETZHYD",
  "mumbai": "LETZMUM",
  "mum": "LETZMUM",
  "delhi": "LETZDEL",
  "del": "LETZDEL",
  "chennai": "LETZCHN",
  "chn": "LETZCHN",
  "pune": "LETZPUN",
  "pun": "LETZPUN"
};

// =============================================================================
// DATABASE CONNECTION & VERIFICATION
// =============================================================================

function getDbConnection() {
  var cfg = getDbConfig();
  var url = "jdbc:postgresql://" + cfg.host + ":" + cfg.port + "/" + cfg.database;
  return Jdbc.getConnection(url, cfg.user, cfg.password);
}

/**
 * Test DB Connection utility with leak-proof cleanup.
 */
function testDbConnection() {
  var cfg = getDbConfig();
  var conn = null;
  var stmt = null;
  var rs = null;
  try {
    conn = getDbConnection();
    stmt = conn.createStatement();
    rs = stmt.executeQuery("SELECT count(*) FROM public.sheet_adjustments;");
    rs.next();
    var count = rs.getInt(1);
    
    Logger.log("Connection Successful. Current rows in sheet_adjustments: " + count);
    try {
      SpreadsheetApp.getUi().alert(
        "Connection Successful",
        "Connected to PostgreSQL on " + cfg.host + ".\nCurrent rows in sheet_adjustments: " + count,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
    } catch(e) {}
  } catch (err) {
    Logger.log("Connection Failed: " + err.message);
    try {
      SpreadsheetApp.getUi().alert(
        "Connection Failed",
        "Error: " + err.message,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
    } catch(e) {}
  } finally {
    if (rs) { try { rs.close(); } catch(e) {} }
    if (stmt) { try { stmt.close(); } catch(e) {} }
    if (conn) { try { conn.close(); } catch(e) {} }
  }
}

// =============================================================================
// SPREADSHEET GETTERS
// =============================================================================

function getSourceSpreadsheet() {
  try {
    var active = SpreadsheetApp.getActiveSpreadsheet();
    if (active) return active;
  } catch(e) {}

  var cfg = getDbConfig();
  if (cfg.sourceSpreadsheetUrl && cfg.sourceSpreadsheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(cfg.sourceSpreadsheetUrl);
    } catch(e) {
      Logger.log("openByUrl notice: " + e.message);
    }
  }
  return SpreadsheetApp.getActiveSpreadsheet();
}

function getSourceSheet() {
  var cfg = getDbConfig();
  var ss = getSourceSpreadsheet();
  if (!ss) throw new Error("Could not access spreadsheet.");

  var sheet = ss.getSheetByName(cfg.sourceSheetName);
  if (sheet) return sheet;

  var sheets = ss.getSheets();
  var targetKey = cfg.sourceSheetName.trim().toLowerCase();
  for (var i = 0; i < sheets.length; i++) {
    var sName = sheets[i].getName().trim().toLowerCase();
    if (sName === targetKey || sName.indexOf("adjustment") !== -1) {
      return sheets[i];
    }
  }

  var activeSS = null;
  try { activeSS = SpreadsheetApp.getActiveSpreadsheet(); } catch(e){}
  if (activeSS && ss && activeSS.getId() !== ss.getId()) {
    var aSheets = activeSS.getSheets();
    for (var j = 0; j < aSheets.length; j++) {
      var aName = aSheets[j].getName().trim().toLowerCase();
      if (aName === targetKey || aName.indexOf("adjustment") !== -1) {
        return aSheets[j];
      }
    }
  }

  throw new Error("Source tab '" + cfg.sourceSheetName + "' not found in spreadsheet.");
}

function getTargetSheet() {
  var cfg = getDbConfig();
  var ss = SpreadsheetApp.getActiveSpreadsheet() || getSourceSpreadsheet();
  var targetSheet = ss.getSheetByName(cfg.targetSheetName);
  
  if (!targetSheet) {
    Logger.log("Creating target sheet tab '" + cfg.targetSheetName + "'...");
    targetSheet = ss.insertSheet(cfg.targetSheetName);
    var headers = [
      "Submission Timestamp", "Submitter Email", "City Name", "Partner Type", "Adjustment Type",
      "Partner Name", "Partner Phone", "Partner Code", "Vehicle Number", "Remittance Towards",
      "Rent Deduction", "Adjustment Date", "Amount", "Photo URL", "Remarks", "Adjustment Related To",
      "GPS Data", "First Level Approver", "First Level Status", "First Level Timestamp",
      "Finance Team Status", "Finance Team Remarks", "Final Level Approver", "Final Status",
      "Final Timestamp", "Hisaab Week Str", "Hisaab Week Number", "Source Row", "Last Synced At"
    ];
    targetSheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    targetSheet.getRange(1, 1, 1, headers.length).setFontWeight("bold").setBackground("#1F4E78").setFontColor("#FFFFFF");
    targetSheet.setFrozenRows(1);
  }
  return targetSheet;
}

// =============================================================================
// STANDARDIZATION & CLEANING HELPERS
// =============================================================================

function standardizeCityName(val) {
  if (!val) return "Bengaluru";
  var s = String(val).trim().toLowerCase();
  if (s.indexOf("bengaluru") !== -1 || s.indexOf("bangalore") !== -1 || s === "blr") return "Bengaluru";
  if (s.indexOf("hyderabad") !== -1 || s === "hyd") return "Hyderabad";
  if (s.indexOf("mumbai") !== -1 || s === "mum") return "Mumbai";
  if (s.indexOf("delhi") !== -1 || s === "del") return "Delhi";
  if (s.indexOf("chennai") !== -1 || s === "chn") return "Chennai";
  if (s.indexOf("pune") !== -1 || s === "pun") return "Pune";
  return val.trim();
}

function sanitizePhoneNumber(val) {
  if (val === null || val === undefined) return null;
  var s = String(val).trim();
  if (!s || s.toLowerCase() === "null" || s.toLowerCase() === "nan") return null;

  var cleaned = s.replace(/[^0-9]/g, "");
  if (cleaned.length === 12 && cleaned.indexOf("91") === 0) {
    cleaned = cleaned.substring(2);
  }
  if (cleaned.length > 10) {
    cleaned = cleaned.slice(-10);
  }
  if (cleaned.length === 10 && /^[6-9]/.test(cleaned)) {
    return cleaned;
  }
  return null;
}

function generatePartnerId(city, phone) {
  var prefix = "LETZBLR";
  if (city) {
    var c = city.trim().toLowerCase();
    if (CITY_PREFIX_MAP[c]) prefix = CITY_PREFIX_MAP[c];
  }
  var cleanPhone = phone ? String(phone).replace(/[^0-9]/g, "").slice(-10) : "";
  if (cleanPhone.length < 10) cleanPhone = "0000000000";
  return prefix + cleanPhone;
}

function parseDateOrTimestamp(val, isDateOnly) {
  if (!val) return null;
  if (val instanceof Date) {
    return isDateOnly ? formatDateOnly(val) : formatTimestamp(val);
  }
  var num = Number(val);
  if (!isNaN(num) && num > 30000 && num < 60000) {
    var ms = Math.round((num - 25569) * 86400 * 1000);
    var d = new Date(ms);
    return isDateOnly ? formatDateOnly(d) : formatTimestamp(d);
  }

  var str = String(val).trim();
  if (!str || str.toLowerCase() === "null" || str === "-") return null;

  // DD/MM/YYYY or DD-MM-YYYY
  var dmy = str.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?/);
  if (dmy) {
    var day = parseInt(dmy[1], 10);
    var month = parseInt(dmy[2], 10) - 1;
    var year = parseInt(dmy[3], 10);
    if (year < 100) year += (year > 50 ? 1900 : 2000);
    var hh = dmy[4] ? parseInt(dmy[4], 10) : 0;
    var mm = dmy[5] ? parseInt(dmy[5], 10) : 0;
    var ss = dmy[6] ? parseInt(dmy[6], 10) : 0;
    var d = new Date(year, month, day, hh, mm, ss);
    return isDateOnly ? formatDateOnly(d) : formatTimestamp(d);
  }

  // YYYY-MM-DD or YYYY/MM/DD
  var ymd = str.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?/);
  if (ymd) {
    var year = parseInt(ymd[1], 10);
    var month = parseInt(ymd[2], 10) - 1;
    var day = parseInt(ymd[3], 10);
    var hh = ymd[4] ? parseInt(ymd[4], 10) : 0;
    var mm = ymd[5] ? parseInt(ymd[5], 10) : 0;
    var ss = ymd[6] ? parseInt(ymd[6], 10) : 0;
    var d = new Date(year, month, day, hh, mm, ss);
    return isDateOnly ? formatDateOnly(d) : formatTimestamp(d);
  }
  
  var dParsed = new Date(str);
  if (!isNaN(dParsed.getTime())) {
    return isDateOnly ? formatDateOnly(dParsed) : formatTimestamp(dParsed);
  }
  return null;
}

function formatDateOnly(d) {
  if (!d || isNaN(d.getTime())) return null;
  if (typeof Utilities !== "undefined" && Utilities.formatDate) {
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
  }
  var istTime = new Date(d.getTime() + (330 * 60 * 1000));
  var y = istTime.getUTCFullYear();
  var m = ("0" + (istTime.getUTCMonth() + 1)).slice(-2);
  var day = ("0" + istTime.getUTCDate()).slice(-2);
  return y + "-" + m + "-" + day;
}

function formatTimestamp(d) {
  if (!d || isNaN(d.getTime())) return null;
  if (typeof Utilities !== "undefined" && Utilities.formatDate) {
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ssXXX");
  }
  var istTime = new Date(d.getTime() + (330 * 60 * 1000));
  var y = istTime.getUTCFullYear();
  var m = ("0" + (istTime.getUTCMonth() + 1)).slice(-2);
  var day = ("0" + istTime.getUTCDate()).slice(-2);
  var hh = ("0" + istTime.getUTCHours()).slice(-2);
  var mm = ("0" + istTime.getUTCMinutes()).slice(-2);
  var ss = ("0" + istTime.getUTCSeconds()).slice(-2);
  return y + "-" + m + "-" + day + " " + hh + ":" + mm + ":" + ss + "+05:30";
}

function parseAdjustmentAmount(val) {
  if (val === null || val === undefined) return 0.00;
  var str = String(val).replace(/[^0-9.-]/g, "").trim();
  if (!str) return 0.00;
  var num = parseFloat(str);
  return isNaN(num) ? 0.00 : num;
}

function parseHisaabWeek(weekStr, weekNumVal) {
  if (weekNumVal) {
    var n = parseInt(weekNumVal, 10);
    if (!isNaN(n)) return n;
  }
  if (weekStr) {
    var m = String(weekStr).match(/(?:WK|Week\s*|^\s*)(\d{1,2})/i);
    if (m) return parseInt(m[1], 10);
  }
  return null;
}

function transformAdjustmentRow(row, rowIndex) {
  if (!row || row.length === 0) return null;
  
  // Empty-row guard to prevent phantom ghost records
  var hasContent = row.some(function(cell) { return cell !== "" && cell !== null && cell !== undefined; });
  if (!hasContent) return null;

  var rawPhone = row[6];
  var rawVeh = row[8];
  var rawPName = row[5];
  var rawAmt = row[12];
  if (!rawPhone && !rawVeh && !rawPName && !rawAmt) return null;

  var rawTimestamp = row[0];  // Col A: Timestamp
  var submitterEmail = row[1];// Col B: Email address
  var rawCity = row[2];       // Col C: City Name
  var rawPType = row[3];      // Col D: Partner Type
  var rawAType = row[4];      // Col E: Adjustment Type
  var rawPCode = row[7];      // Col H: Partner Code
  var rawRemit = row[9];      // Col J: Remittance Towards
  var rawRentDed = row[10];   // Col K: Rent Deduction
  var rawAdjDate = row[11];   // Col L: Adjustment Date
  var photoUrl = row[13];     // Col N: Photo
  var remarks = row[14];      // Col O: Remarks
  var adjRelated = row[15];   // Col P: Adjustment Related to
  var gpsData = row[17];      // Col R: GPS Data
  var firstApprover = row[18];// Col S: First Level Approval by
  var firstStatus = row[19];  // Col T: Status
  var firstTs = row[20];      // Col U: Timestamp
  var finStatus = row[21];    // Col V: Finance Team Status
  var finRemarks = row[22];   // Col W: Finance Team Remarks
  var finalApprover = row[23];// Col X: Final Level Approval by
  var finalStatus = row[24];  // Col Y: Status
  var finalTs = row[25];      // Col Z: Timestamp
  var hisaabDoneWk = row[28]; // Col AC: Adjustment Done Week
  var hisaabWkNum = row[29];  // Col AD: Hisaab Week Number

  var city = standardizeCityName(rawCity);
  var phone = sanitizePhoneNumber(rawPhone);
  
  // Recover phone from partner code if rawPhone was missing
  if (!phone && rawPCode && /^[A-Z]+(?:IP)?[0-9]{10}$/.test(String(rawPCode).trim())) {
    phone = String(rawPCode).trim().slice(-10);
  }

  var partnerCode = rawPCode && /^LETZ(BLR|HYD|MUM|DEL|CHN|PUN)[0-9]{10}$/.test(String(rawPCode).trim()) 
    ? String(rawPCode).trim() 
    : generatePartnerId(city, phone);
  
  var subTimestamp = parseDateOrTimestamp(rawTimestamp, false) || formatTimestamp(new Date());
  var adjDate = parseDateOrTimestamp(rawAdjDate, true) || formatDateOnly(new Date());
  
  var cleanVeh = rawVeh ? String(rawVeh).trim().toUpperCase().replace(/[^A-Z0-9]/g, "") : null;
  if (cleanVeh && cleanVeh.length < 6) cleanVeh = null;

  var resolvedFinalStatus = finalStatus ? String(finalStatus).trim() : null;
  if (!resolvedFinalStatus) {
    resolvedFinalStatus = (firstStatus === "Rejected") ? "Rejected" : "Pending";
  }

  return {
    submission_timestamp: subTimestamp,
    submitter_email: submitterEmail ? String(submitterEmail).trim() : null,
    city_name: city,
    partner_type: rawPType ? String(rawPType).trim() : "Individual",
    adjustment_type: rawAType ? String(rawAType).trim() : "Credit",
    partner_name: rawPName ? String(rawPName).trim().toUpperCase() : null,
    partner_phone: phone,
    partner_code: partnerCode,
    vehicle_number: cleanVeh,
    remittance_towards: rawRemit ? String(rawRemit).trim() : null,
    rent_deduction: parseAdjustmentAmount(rawRentDed),
    adjustment_date: adjDate,
    amount: parseAdjustmentAmount(rawAmt),
    photo_url: photoUrl ? String(photoUrl).trim() : null,
    remarks: remarks ? String(remarks).trim() : null,
    adjustment_related_to: adjRelated ? String(adjRelated).trim() : null,
    gps_data: gpsData ? String(gpsData).trim() : null,
    first_level_approver: firstApprover ? String(firstApprover).trim() : null,
    first_level_status: firstStatus ? String(firstStatus).trim() : null,
    first_level_timestamp: parseDateOrTimestamp(firstTs, false),
    finance_team_status: finStatus ? String(finStatus).trim() : null,
    finance_team_remarks: finRemarks ? String(finRemarks).trim() : null,
    final_level_approver: finalApprover ? String(finalApprover).trim() : null,
    final_status: resolvedFinalStatus,
    final_timestamp: parseDateOrTimestamp(finalTs, false),
    hisaab_week_str: hisaabDoneWk ? String(hisaabDoneWk).trim() : null,
    hisaab_week_number: parseHisaabWeek(hisaabDoneWk, hisaabWkNum),
    source_row: rowIndex || 0
  };
}

function formatRecordForSheet(r, nowStr) {
  return [
    r.submission_timestamp,
    r.submitter_email,
    r.city_name,
    r.partner_type,
    r.adjustment_type,
    r.partner_name,
    r.partner_phone,
    r.partner_code,
    r.vehicle_number,
    r.remittance_towards,
    r.rent_deduction,
    r.adjustment_date,
    r.amount,
    r.photo_url,
    r.remarks,
    r.adjustment_related_to,
    r.gps_data,
    r.first_level_approver,
    r.first_level_status,
    r.first_level_timestamp,
    r.finance_team_status,
    r.finance_team_remarks,
    r.final_level_approver,
    r.final_status,
    r.final_timestamp,
    r.hisaab_week_str,
    r.hisaab_week_number,
    r.source_row,
    nowStr || formatTimestamp(new Date())
  ];
}

// =============================================================================
// DATABASE CTE UPSERT ENGINE (ZERO SEQUENCE BURNING)
// =============================================================================

const UPSERT_SQL = `
WITH upd AS (
  UPDATE public.sheet_adjustments
  SET submitter_email = ?,
      city_name = ?,
      partner_type = ?,
      partner_name = ?,
      partner_code = ?,
      vehicle_number = ?,
      remittance_towards = ?,
      rent_deduction = ?,
      amount = ?,
      photo_url = ?,
      remarks = ?,
      adjustment_related_to = ?,
      gps_data = ?,
      first_level_approver = ?,
      first_level_status = ?,
      first_level_timestamp = CAST(? AS timestamptz),
      finance_team_status = ?,
      finance_team_remarks = ?,
      final_level_approver = ?,
      final_status = ?,
      final_timestamp = CAST(? AS timestamptz),
      hisaab_week_str = ?,
      hisaab_week_number = ?,
      updated_at = CURRENT_TIMESTAMP
  WHERE submission_timestamp = CAST(? AS timestamptz)
    AND partner_phone IS NOT DISTINCT FROM ?
    AND adjustment_date = CAST(? AS date)
    AND adjustment_type = ?
  RETURNING 1
)
INSERT INTO public.sheet_adjustments (
  submission_timestamp, submitter_email, city_name, partner_type, adjustment_type,
  partner_name, partner_phone, partner_code, vehicle_number, remittance_towards,
  rent_deduction, adjustment_date, amount, photo_url, remarks,
  adjustment_related_to, gps_data, first_level_approver, first_level_status, first_level_timestamp,
  finance_team_status, finance_team_remarks, final_level_approver, final_status, final_timestamp,
  hisaab_week_str, hisaab_week_number, ingested_at, updated_at
)
SELECT CAST(? AS timestamptz), ?, ?, ?, ?,
       ?, ?, ?, ?, ?,
       ?, CAST(? AS date), ?, ?, ?,
       ?, ?, ?, ?, CAST(? AS timestamptz),
       ?, ?, ?, ?, CAST(? AS timestamptz),
       ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
WHERE NOT EXISTS (SELECT 1 FROM upd);
`;

function bindAdjustmentRow(pstmt, r) {
  var p = 1;

  // --- UPDATE SET (23 parameters) ---
  if (r.submitter_email) pstmt.setString(p++, r.submitter_email); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 1
  pstmt.setString(p++, r.city_name); // 2
  pstmt.setString(p++, r.partner_type); // 3
  if (r.partner_name) pstmt.setString(p++, r.partner_name); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 4
  if (r.partner_code) pstmt.setString(p++, r.partner_code); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 5
  if (r.vehicle_number) pstmt.setString(p++, r.vehicle_number); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 6
  if (r.remittance_towards) pstmt.setString(p++, r.remittance_towards); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 7
  pstmt.setDouble(p++, r.rent_deduction || 0.0); // 8
  pstmt.setDouble(p++, r.amount || 0.0); // 9
  if (r.photo_url) pstmt.setString(p++, r.photo_url); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 10
  if (r.remarks) pstmt.setString(p++, r.remarks); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 11
  if (r.adjustment_related_to) pstmt.setString(p++, r.adjustment_related_to); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 12
  if (r.gps_data) pstmt.setString(p++, r.gps_data); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 13
  if (r.first_level_approver) pstmt.setString(p++, r.first_level_approver); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 14
  if (r.first_level_status) pstmt.setString(p++, r.first_level_status); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 15
  if (r.first_level_timestamp) pstmt.setString(p++, r.first_level_timestamp); else pstmt.setNull(p++, SQL_TYPES.TIMESTAMP); // 16
  if (r.finance_team_status) pstmt.setString(p++, r.finance_team_status); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 17
  if (r.finance_team_remarks) pstmt.setString(p++, r.finance_team_remarks); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 18
  if (r.final_level_approver) pstmt.setString(p++, r.final_level_approver); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 19
  if (r.final_status) pstmt.setString(p++, r.final_status); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 20
  if (r.final_timestamp) pstmt.setString(p++, r.final_timestamp); else pstmt.setNull(p++, SQL_TYPES.TIMESTAMP); // 21
  if (r.hisaab_week_str) pstmt.setString(p++, r.hisaab_week_str); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 22
  if (r.hisaab_week_number !== null && r.hisaab_week_number !== undefined) pstmt.setInt(p++, r.hisaab_week_number); else pstmt.setNull(p++, SQL_TYPES.INTEGER); // 23

  // --- UPDATE WHERE (4 parameters) ---
  pstmt.setString(p++, r.submission_timestamp); // 24
  if (r.partner_phone) pstmt.setString(p++, r.partner_phone); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 25
  pstmt.setString(p++, r.adjustment_date); // 26
  pstmt.setString(p++, r.adjustment_type); // 27

  // --- INSERT SELECT (27 parameters) ---
  pstmt.setString(p++, r.submission_timestamp); // 28
  if (r.submitter_email) pstmt.setString(p++, r.submitter_email); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 29
  pstmt.setString(p++, r.city_name); // 30
  pstmt.setString(p++, r.partner_type); // 31
  pstmt.setString(p++, r.adjustment_type); // 32
  if (r.partner_name) pstmt.setString(p++, r.partner_name); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 33
  if (r.partner_phone) pstmt.setString(p++, r.partner_phone); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 34
  if (r.partner_code) pstmt.setString(p++, r.partner_code); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 35
  if (r.vehicle_number) pstmt.setString(p++, r.vehicle_number); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 36
  if (r.remittance_towards) pstmt.setString(p++, r.remittance_towards); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 37
  pstmt.setDouble(p++, r.rent_deduction || 0.0); // 38
  pstmt.setString(p++, r.adjustment_date); // 39
  pstmt.setDouble(p++, r.amount || 0.0); // 40
  if (r.photo_url) pstmt.setString(p++, r.photo_url); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 41
  if (r.remarks) pstmt.setString(p++, r.remarks); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 42
  if (r.adjustment_related_to) pstmt.setString(p++, r.adjustment_related_to); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 43
  if (r.gps_data) pstmt.setString(p++, r.gps_data); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 44
  if (r.first_level_approver) pstmt.setString(p++, r.first_level_approver); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 45
  if (r.first_level_status) pstmt.setString(p++, r.first_level_status); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 46
  if (r.first_level_timestamp) pstmt.setString(p++, r.first_level_timestamp); else pstmt.setNull(p++, SQL_TYPES.TIMESTAMP); // 47
  if (r.finance_team_status) pstmt.setString(p++, r.finance_team_status); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 48
  if (r.finance_team_remarks) pstmt.setString(p++, r.finance_team_remarks); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 49
  if (r.final_level_approver) pstmt.setString(p++, r.final_level_approver); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 50
  if (r.final_status) pstmt.setString(p++, r.final_status); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 51
  if (r.final_timestamp) pstmt.setString(p++, r.final_timestamp); else pstmt.setNull(p++, SQL_TYPES.TIMESTAMP); // 52
  if (r.hisaab_week_str) pstmt.setString(p++, r.hisaab_week_str); else pstmt.setNull(p++, SQL_TYPES.VARCHAR); // 53
  if (r.hisaab_week_number !== null && r.hisaab_week_number !== undefined) pstmt.setInt(p++, r.hisaab_week_number); else pstmt.setNull(p++, SQL_TYPES.INTEGER); // 54
}

function upsertAdjustmentRecords(records) {
  if (!records || records.length === 0) return 0;

  var conn = null;
  var pstmt = null;
  var BATCH_SIZE = 200;
  var totalCount = 0;

  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    pstmt = conn.prepareStatement(UPSERT_SQL);

    var pendingInBatch = 0;
    for (var i = 0; i < records.length; i++) {
      bindAdjustmentRow(pstmt, records[i]);
      pstmt.addBatch();
      pendingInBatch++;
      totalCount++;

      if (pendingInBatch >= BATCH_SIZE) {
        pstmt.executeBatch();
        conn.commit();
        pendingInBatch = 0;
        Logger.log("Upserted batch: " + totalCount + "/" + records.length + " adjustment records into PostgreSQL.");
      }
    }

    if (pendingInBatch > 0) {
      pstmt.executeBatch();
      conn.commit();
    }

    Logger.log("Successfully completed PostgreSQL upsert for all " + totalCount + " adjustment records.");
    return totalCount;
  } catch (err) {
    if (conn) { try { conn.rollback(); } catch(e){} }
    Logger.log("Error in upsertAdjustmentRecords: " + err.message);
    throw err;
  } finally {
    if (pstmt) { try { pstmt.close(); } catch(e){} }
    if (conn) { try { conn.close(); } catch(e){} }
  }
}

// =============================================================================
// SYNC & TRIGGER HANDLERS
// =============================================================================

/**
 * Real-Time On-Edit Trigger with exponential backoff
 */
function handleOnEdit(e) {
  if (!e || !e.range) return;
  var sheet = e.range.getSheet();
  var sName = sheet.getName().trim().toLowerCase();
  var cfg = getDbConfig();
  if (sName !== cfg.sourceSheetName.trim().toLowerCase()) return;
  
  var lock = LockService.getScriptLock();
  var acquired = false;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (lock.tryLock(10000)) {
      acquired = true;
      break;
    }
    Utilities.sleep(1000 * Math.pow(2, attempt));
  }
  if (!acquired) {
    Logger.log("handleOnEdit skipped: Lock busy.");
    return;
  }

  try {
    var startRow = e.range.getRow();
    var endRow = e.range.getLastRow();
    if (startRow <= 1 && endRow <= 1) return;
    
    var actualStart = Math.max(2, startRow);
    var numRows = endRow - actualStart + 1;
    var rawData = sheet.getRange(actualStart, 1, numRows, sheet.getLastColumn()).getValues();
    
    var records = [];
    var sheetRows = [];
    var targetSheet = getTargetSheet();
    var nowStr = formatTimestamp(new Date());

    for (var i = 0; i < rawData.length; i++) {
      var transformed = transformAdjustmentRow(rawData[i], actualStart + i);
      if (transformed) {
        records.push(transformed);
        sheetRows.push(formatRecordForSheet(transformed, nowStr));
      }
    }
    
    if (sheetRows.length > 0 && targetSheet) {
      targetSheet.getRange(actualStart, 1, sheetRows.length, sheetRows[0].length).setValues(sheetRows);
    }
    
    if (records.length > 0) {
      upsertAdjustmentRecords(records);
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Real-Time Form-Submit Trigger with exponential backoff
 */
function handleOnFormSubmit(e) {
  if (!e || !e.values) return;
  var lock = LockService.getScriptLock();
  var acquired = false;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (lock.tryLock(10000)) {
      acquired = true;
      break;
    }
    Utilities.sleep(1000 * Math.pow(2, attempt));
  }
  if (!acquired) {
    Logger.log("handleOnFormSubmit skipped: Lock busy.");
    return;
  }

  try {
    var rowIdx = e.range ? e.range.getRow() : 0;
    var transformed = transformAdjustmentRow(e.values, rowIdx);
    if (transformed) {
      var targetSheet = getTargetSheet();
      if (targetSheet && rowIdx > 1) {
        var sheetRow = formatRecordForSheet(transformed, formatTimestamp(new Date()));
        targetSheet.getRange(rowIdx, 1, 1, sheetRow.length).setValues([sheetRow]);
      }
      upsertAdjustmentRecords([transformed]);
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Helper to find the actual last non-empty row (ignoring blank formatted rows at sheet bottom)
 */
function getTrueLastRow(sheet) {
  if (!sheet) return 0;
  var lastRow = sheet.getLastRow();
  if (lastRow <= 1) return lastRow;
  
  var colA = sheet.getRange(1, 1, lastRow, 1).getValues();
  for (var i = colA.length - 1; i >= 0; i--) {
    var val = colA[i][0];
    if (val !== "" && val !== null && val !== undefined) {
      return i + 1;
    }
  }
  return 1;
}

/**
 * 1-Minute Time-Driven Catch-Up Sync for Recent Submissions
 */
function syncRecentAdjustments() {
  var lock = LockService.getScriptLock();
  var acquired = false;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (lock.tryLock(10000)) {
      acquired = true;
      break;
    }
    Utilities.sleep(1000 * Math.pow(2, attempt));
  }
  if (!acquired) {
    Logger.log("Another sync is currently in progress. Skipping 1-min catch-up.");
    return;
  }

  try {
    var sourceSheet = getSourceSheet();
    var trueLastRow = getTrueLastRow(sourceSheet);
    if (trueLastRow <= 1) return;
    
    var WINDOW_SIZE = 100;
    var startRow = Math.max(2, trueLastRow - WINDOW_SIZE + 1);
    var numRows = trueLastRow - startRow + 1;
    
    var data = sourceSheet.getRange(startRow, 1, numRows, sourceSheet.getLastColumn()).getValues();
    var records = [];
    var sheetRows = [];
    var nowStr = formatTimestamp(new Date());

    for (var i = 0; i < data.length; i++) {
      var transformed = transformAdjustmentRow(data[i], startRow + i);
      if (transformed) {
        records.push(transformed);
        sheetRows.push(formatRecordForSheet(transformed, nowStr));
      }
    }
    
    if (records.length > 0) {
      var targetSheet = getTargetSheet();
      if (targetSheet && sheetRows.length > 0) {
        targetSheet.getRange(startRow, 1, sheetRows.length, sheetRows[0].length).setValues(sheetRows);
      }
      upsertAdjustmentRecords(records);
      Logger.log("Catch-up sync (1-min) successfully updated " + records.length + " recent adjustment records.");
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Full Manual Backfill Synchronization
 */
function syncAllAdjustments() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("Another sync is already running. Please wait.");
    return;
  }
  try {
    var sourceSheet = getSourceSheet();
    var data = sourceSheet.getDataRange().getValues();
    Logger.log("Read " + data.length + " total rows from source tab '" + sourceSheet.getName() + "'");
    
    if (data.length <= 1) {
      Logger.log("Source tab contains no data rows yet.");
      return;
    }
    
    var records = [];
    var sheetRows = [];
    var nowStr = formatTimestamp(new Date());

    for (var i = 1; i < data.length; i++) {
      var transformed = transformAdjustmentRow(data[i], i + 1);
      if (transformed) {
        records.push(transformed);
        sheetRows.push(formatRecordForSheet(transformed, nowStr));
      }
    }
    
    Logger.log("Transformed " + records.length + " valid adjustment records.");
    
    // Write clean standardized rows to targetSheet in chunks of 500
    var targetSheet = getTargetSheet();
    var CHUNK_SIZE = 500;
    for (var s = 0; s < sheetRows.length; s += CHUNK_SIZE) {
      var sChunk = sheetRows.slice(s, s + CHUNK_SIZE);
      targetSheet.getRange(s + 2, 1, sChunk.length, sChunk[0].length).setValues(sChunk);
    }
    Logger.log("Wrote " + sheetRows.length + " rows to tab '" + getDbConfig().targetSheetName + "'.");

    // Parameterized batch upsert into PostgreSQL
    Logger.log("Starting PostgreSQL upsert for " + records.length + " adjustment records...");
    var totalUpserted = upsertAdjustmentRecords(records);
    Logger.log("Completed syncAllAdjustments! Total records synced to DB: " + totalUpserted);
  } finally {
    lock.releaseLock();
  }
}

// =============================================================================
// AUTOMATED TRIGGER SETUP (ONE-CLICK INSTALLATION)
// =============================================================================

function setupTriggers() {
  removeTriggers();

  ScriptApp.newTrigger("syncRecentAdjustments")
    .timeBased()
    .everyMinutes(1)
    .create();

  try {
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    if (ss) {
      ScriptApp.newTrigger("handleOnEdit")
        .forSpreadsheet(ss)
        .onEdit()
        .create();

      ScriptApp.newTrigger("handleOnFormSubmit")
        .forSpreadsheet(ss)
        .onFormSubmit()
        .create();
    }
  } catch(e) {
    Logger.log("Notice: Spreadsheet-bound trigger: " + e.message);
  }

  Logger.log("All automated triggers installed successfully!");
  try {
    SpreadsheetApp.getUi().alert(
      "Triggers Installed Successfully",
      "1-minute catch-up sync (syncRecentAdjustments) and real-time triggers are now active!",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  } catch(e){}
}

function removeTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  var adjustmentHandlers = [
    "handleOnEdit",
    "handleOnFormSubmit",
    "syncRecentAdjustments",
    "syncAllAdjustments"
  ];

  for (var i = 0; i < triggers.length; i++) {
    var handler = triggers[i].getHandlerFunction();
    if (adjustmentHandlers.indexOf(handler) !== -1) {
      ScriptApp.deleteTrigger(triggers[i]);
    }
  }
  Logger.log("Adjustment pipeline triggers cleanly removed.");
}

function onOpen() {
  try {
    SpreadsheetApp.getUi()
      .createMenu("LetzRyd Adjustments")
      .addItem("Sync Recent Records (1-Min)", "syncRecentAdjustments")
      .addItem("Sync All Records (Full)", "syncAllAdjustments")
      .addSeparator()
      .addItem("Test Database Connection", "testDbConnection")
      .addItem("Initialize Script Properties", "setupScriptProperties")
      .addSeparator()
      .addItem("Setup Automated Triggers", "setupTriggers")
      .addItem("Remove Triggers", "removeTriggers")
      .addToUi();
  } catch(e){}
}
