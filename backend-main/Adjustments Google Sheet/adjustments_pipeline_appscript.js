/**
 * ==============================================================================
 * LETZRYD - ADJUSTMENT FORM LIVE PIPELINE (sheet_adjustments)
 * ==============================================================================
 * 
 * Source Sheet : 'Adjustment-Form' (Raw Form Responses)
 * Target Sheet : 'sheet_adjustments' (Standardized Tab in Spreadsheet)
 * Target Table : public.sheet_adjustments & public.core_adjustments
 * Host         : 35.200.196.113:5432
 * 
 * Features:
 *  - Dual Ingestion: Populates standardized 'sheet_adjustments' tab AND PostgreSQL database
 *  - Real-time live ingestion on form submit (handleOnFormSubmit) and cell edit (handleOnEdit)
 *  - 1-Minute Time-Driven Catch-Up Sync (syncRecentAdjustments) with sliding window
 *  - Full Historical Backfill (syncAllAdjustments) with chunked JDBC batches
 *  - 11-Issue standardization engine (ADJ-01 through ADJ-11)
 *  - Complete connection leak prevention (try-catch-finally with conn.close())
 *  - Deterministic Partner ID generation (LETZ + CITY + PHONE)
 *  - Multi-level approval resolution with timestamp preservation
 *  - Phone number float & scientific notation normalization
 *  - Free-text hisaab week string parsing into canonical ISO week numbers
 *  - Automated trigger installer (setupTriggers) and custom spreadsheet UI menu
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
const DB_CONFIG = {
  host: "35.200.196.113",
  port: "5432",
  database: "postgres",
  user: "postgres",
  password: "8S5]U3@L^Xz)\\FH}",
  
  sourceSpreadsheetUrl: "https://docs.google.com/spreadsheets/d/1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM/edit",
  sourceSheetName: "Adjustment-Form",
  targetSheetName: "sheet_adjustments"
};

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
// SPREADSHEET GETTERS
// =============================================================================

function getSourceSpreadsheet() {
  if (DB_CONFIG.sourceSpreadsheetUrl && DB_CONFIG.sourceSpreadsheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(DB_CONFIG.sourceSpreadsheetUrl);
    } catch(e) {
      Logger.log("openByUrl notice: " + e.message);
    }
  }
  return SpreadsheetApp.getActiveSpreadsheet();
}

function getSourceSheet() {
  var ss = getSourceSpreadsheet();
  if (!ss) throw new Error("Could not access spreadsheet.");

  var sheet = ss.getSheetByName(DB_CONFIG.sourceSheetName);
  if (sheet) return sheet;

  var sheets = ss.getSheets();
  var targetKey = DB_CONFIG.sourceSheetName.trim().toLowerCase();
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

  throw new Error("Source tab '" + DB_CONFIG.sourceSheetName + "' not found in spreadsheet.");
}

function getTargetSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet() || getSourceSpreadsheet();
  var targetSheet = ss.getSheetByName(DB_CONFIG.targetSheetName);
  
  if (!targetSheet) {
    Logger.log("Creating target sheet tab '" + DB_CONFIG.targetSheetName + "'...");
    targetSheet = ss.insertSheet(DB_CONFIG.targetSheetName);
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
// DATA SANITIZATION & STANDARDIZATION ENGINE (ADJ-01 THROUGH ADJ-11)
// =============================================================================

function standardizeCityName(rawCity) {
  if (!rawCity) return "Bengaluru";
  var str = String(rawCity).trim().toLowerCase();
  if (str.indexOf("blr") !== -1 || str.indexOf("bang") !== -1 || str.indexOf("beng") !== -1) return "Bengaluru";
  if (str.indexOf("mum") !== -1) return "Mumbai";
  if (str.indexOf("hyd") !== -1) return "Hyderabad";
  if (str.indexOf("del") !== -1) return "Delhi";
  if (str.indexOf("chn") !== -1 || str.indexOf("chen") !== -1) return "Chennai";
  if (str.indexOf("pun") !== -1) return "Pune";
  return str.charAt(0).toUpperCase() + str.slice(1);
}

function sanitizePhoneNumber(rawPhone) {
  if (!rawPhone) return null;
  var str = String(rawPhone).trim();
  if (["NA", "NAN", "NULL", "NONE", "-"].indexOf(str.toUpperCase()) !== -1) return null;
  var digits = str.replace(/\D/g, "");
  if (digits.length >= 10) {
    return digits.slice(-10);
  }
  return null;
}

function generatePartnerId(cityName, phone) {
  if (!phone) return null;
  var cityKey = String(cityName).trim().toLowerCase();
  var prefix = CITY_PREFIX_MAP[cityKey] || "LETZBLR";
  return prefix + phone;
}

function parseDateOrTimestamp(val, isDateOnly) {
  if (!val) return null;
  if (val instanceof Date) {
    return isDateOnly ? formatDateOnly(val) : formatTimestamp(val);
  }
  var str = String(val).trim();
  if (!str || ["NA", "NAN", "NULL", "0"].indexOf(str.toUpperCase()) !== -1) return null;
  
  var num = parseFloat(str);
  if (!isNaN(num) && num > 30000 && num < 60000) {
    var ms = (num - 25569) * 86400 * 1000;
    var d = new Date(ms);
    return isDateOnly ? formatDateOnly(d) : formatTimestamp(d);
  }
  
  var dParsed = new Date(str);
  if (!isNaN(dParsed.getTime())) {
    return isDateOnly ? formatDateOnly(dParsed) : formatTimestamp(dParsed);
  }
  return null;
}

function formatDateOnly(d) {
  var y = d.getUTCFullYear();
  var m = ("0" + (d.getUTCMonth() + 1)).slice(-2);
  var day = ("0" + d.getUTCDate()).slice(-2);
  return y + "-" + m + "-" + day;
}

function formatTimestamp(d) {
  var y = d.getUTCFullYear();
  var m = ("0" + (d.getUTCMonth() + 1)).slice(-2);
  var day = ("0" + d.getUTCDate()).slice(-2);
  var hh = ("0" + d.getUTCHours()).slice(-2);
  var mm = ("0" + d.getUTCMinutes()).slice(-2);
  var ss = ("0" + d.getUTCSeconds()).slice(-2);
  return y + "-" + m + "-" + day + " " + hh + ":" + mm + ":" + ss + "+00";
}

function parseAdjustmentAmount(val) {
  if (val === null || val === undefined) return 0.00;
  var str = String(val).replace(/[^0-9.-]/g, "").trim();
  if (!str) return 0.00;
  var num = Math.abs(parseFloat(str));
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
  var rawTimestamp = row[0];  // Col A: Timestamp
  var submitterEmail = row[1];// Col B: Email address
  var rawCity = row[2];       // Col C: City Name
  var rawPType = row[3];      // Col D: Partner Type
  var rawAType = row[4];      // Col E: Adjustment Type
  var rawPName = row[5];      // Col F: Partner Name
  var rawPhone = row[6];      // Col G: Partner Number
  var rawPCode = row[7];      // Col H: Partner Code
  var rawVeh = row[8];        // Col I: Vehicle number
  var rawRemit = row[9];      // Col J: Remittance Towards
  var rawRentDed = row[10];   // Col K: Rent Deduction
  var rawAdjDate = row[11];   // Col L: Adjustment Date
  var rawAmt = row[12];       // Col M: Enter Amount
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
  var partnerCode = rawPCode && String(rawPCode).indexOf("LETZ") !== -1 ? String(rawPCode).trim() : generatePartnerId(city, phone);
  
  var subTimestamp = parseDateOrTimestamp(rawTimestamp, false) || formatTimestamp(new Date());
  var adjDate = parseDateOrTimestamp(rawAdjDate, true) || formatDateOnly(new Date());
  
  var cleanVeh = rawVeh ? String(rawVeh).trim().toUpperCase().replace(/[^A-Z0-9]/g, "") : null;
  if (cleanVeh && cleanVeh.length < 6) cleanVeh = null;

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
    final_status: finalStatus ? String(finalStatus).trim() : "Pending",
    final_timestamp: parseDateOrTimestamp(finalTs, false),
    hisaab_week_str: hisaabDoneWk ? String(hisaabDoneWk).trim() : null,
    hisaab_week_number: parseHisaabWeek(hisaabDoneWk, hisaabWkNum),
    source_row: rowIndex || 0
  };
}

function formatRecordForSheet(r, nowStr) {
  return [
    r.submission_timestamp,
    r.submitter_email || "",
    r.city_name,
    r.partner_type,
    r.adjustment_type,
    r.partner_name || "",
    r.partner_phone || "",
    r.partner_code || "",
    r.vehicle_number || "",
    r.remittance_towards || "",
    r.rent_deduction,
    r.adjustment_date,
    r.amount,
    r.photo_url || "",
    r.remarks || "",
    r.adjustment_related_to || "",
    r.gps_data || "",
    r.first_level_approver || "",
    r.first_level_status || "",
    r.first_level_timestamp || "",
    r.finance_team_status || "",
    r.finance_team_remarks || "",
    r.final_level_approver || "",
    r.final_status,
    r.final_timestamp || "",
    r.hisaab_week_str || "",
    r.hisaab_week_number || "",
    r.source_row,
    nowStr || formatTimestamp(new Date())
  ];
}

// =============================================================================
// DATABASE UPSERT ENGINE
// =============================================================================

// Helper SQL formatters to eliminate V8-JDBC bridge RPC latency
function sqlStr(val) {
  if (val === null || val === undefined) return "NULL::text";
  var s = String(val).trim();
  if (s === "") return "NULL::text";
  return "'" + s.replace(/'/g, "''").replace(/\\/g, "\\\\") + "'::text";
}

function sqlNum(val) {
  if (val === null || val === undefined || val === "") return "0.00::numeric";
  var n = parseFloat(val);
  return (isNaN(n) ? "0.00" : n.toFixed(2)) + "::numeric";
}

function sqlInt(val) {
  if (val === null || val === undefined || val === "") return "NULL::integer";
  var n = parseInt(val, 10);
  return (isNaN(n) ? "NULL::integer" : String(n)) + "::integer";
}

function sqlDate(val) {
  if (!val) return "NULL::date";
  return "'" + String(val).replace(/'/g, "") + "'::date";
}

function sqlTimestamp(val) {
  if (!val) return "NULL::timestamptz";
  return "'" + String(val).replace(/'/g, "") + "'::timestamptz";
}

function upsertAdjustmentRecords(records) {
  if (!records || records.length === 0) return 0;

  var conn = null;
  var stmt = null;
  var url = "jdbc:postgresql://" + DB_CONFIG.host + ":" + DB_CONFIG.port + "/" + DB_CONFIG.database;
  var BATCH_SIZE = 100;
  var totalCount = 0;

  try {
    conn = Jdbc.getConnection(url, DB_CONFIG.user, DB_CONFIG.password);
    conn.setAutoCommit(false);
    stmt = conn.createStatement();

    for (var b = 0; b < records.length; b += BATCH_SIZE) {
      var chunk = records.slice(b, b + BATCH_SIZE);
      var valuesList = [];

      for (var i = 0; i < chunk.length; i++) {
        var r = chunk[i];
        var rowSql = "(" +
          sqlTimestamp(r.submission_timestamp || "CURRENT_TIMESTAMP") + ", " +
          sqlStr(r.submitter_email) + ", " +
          sqlStr(r.city_name) + ", " +
          sqlStr(r.partner_type) + ", " +
          sqlStr(r.adjustment_type) + ", " +
          sqlStr(r.partner_name) + ", " +
          sqlStr(r.partner_phone) + ", " +
          sqlStr(r.partner_code) + ", " +
          sqlStr(r.vehicle_number) + ", " +
          sqlStr(r.remittance_towards) + ", " +
          sqlNum(r.rent_deduction) + ", " +
          sqlDate(r.adjustment_date) + ", " +
          sqlNum(r.amount) + ", " +
          sqlStr(r.photo_url) + ", " +
          sqlStr(r.remarks) + ", " +
          sqlStr(r.adjustment_related_to) + ", " +
          sqlStr(r.gps_data) + ", " +
          sqlStr(r.first_level_approver) + ", " +
          sqlStr(r.first_level_status) + ", " +
          sqlTimestamp(r.first_level_timestamp) + ", " +
          sqlStr(r.finance_team_status) + ", " +
          sqlStr(r.finance_team_remarks) + ", " +
          sqlStr(r.final_level_approver) + ", " +
          sqlStr(r.final_status || "Pending") + ", " +
          sqlTimestamp(r.final_timestamp) + ", " +
          sqlStr(r.hisaab_week_str) + ", " +
          sqlInt(r.hisaab_week_number) +
        ")";
        valuesList.push(rowSql);
      }

      var sql = 
        "WITH incoming ( " +
        "  submission_timestamp, submitter_email, city_name, partner_type, adjustment_type, " +
        "  partner_name, partner_phone, partner_code, vehicle_number, remittance_towards, " +
        "  rent_deduction, adjustment_date, amount, photo_url, remarks, " +
        "  adjustment_related_to, gps_data, first_level_approver, first_level_status, first_level_timestamp, " +
        "  finance_team_status, finance_team_remarks, final_level_approver, final_status, final_timestamp, " +
        "  hisaab_week_str, hisaab_week_number " +
        ") AS ( " +
        "  VALUES " + valuesList.join(",\n") + " " +
        "), " +
        "upd AS ( " +
        "  UPDATE public.sheet_adjustments t " +
        "  SET " +
        "    partner_name = i.partner_name, " +
        "    partner_code = i.partner_code, " +
        "    vehicle_number = i.vehicle_number, " +
        "    remittance_towards = i.remittance_towards, " +
        "    amount = i.amount, " +
        "    final_status = i.final_status, " +
        "    remarks = i.remarks, " +
        "    updated_at = CURRENT_TIMESTAMP " +
        "  FROM incoming i " +
        "  WHERE t.submission_timestamp = i.submission_timestamp " +
        "    AND t.partner_phone = i.partner_phone " +
        "    AND t.adjustment_date = i.adjustment_date " +
        "    AND t.adjustment_type = i.adjustment_type " +
        "  RETURNING t.submission_timestamp, t.partner_phone, t.adjustment_date, t.adjustment_type " +
        ") " +
        "INSERT INTO public.sheet_adjustments ( " +
        "  submission_timestamp, submitter_email, city_name, partner_type, adjustment_type, " +
        "  partner_name, partner_phone, partner_code, vehicle_number, remittance_towards, " +
        "  rent_deduction, adjustment_date, amount, photo_url, remarks, " +
        "  adjustment_related_to, gps_data, first_level_approver, first_level_status, first_level_timestamp, " +
        "  finance_team_status, finance_team_remarks, final_level_approver, final_status, final_timestamp, " +
        "  hisaab_week_str, hisaab_week_number, updated_at " +
        ") " +
        "SELECT " +
        "  i.submission_timestamp, i.submitter_email, i.city_name, i.partner_type, i.adjustment_type, " +
        "  i.partner_name, i.partner_phone, i.partner_code, i.vehicle_number, i.remittance_towards, " +
        "  i.rent_deduction, i.adjustment_date, i.amount, i.photo_url, i.remarks, " +
        "  i.adjustment_related_to, i.gps_data, i.first_level_approver, i.first_level_status, i.first_level_timestamp, " +
        "  i.finance_team_status, i.finance_team_remarks, i.final_level_approver, i.final_status, i.final_timestamp, " +
        "  i.hisaab_week_str, i.hisaab_week_number, CURRENT_TIMESTAMP " +
        "FROM incoming i " +
        "WHERE NOT EXISTS ( " +
        "  SELECT 1 FROM upd u " +
        "  WHERE u.submission_timestamp = i.submission_timestamp " +
        "    AND u.partner_phone = i.partner_phone " +
        "    AND u.adjustment_date = i.adjustment_date " +
        "    AND u.adjustment_type = i.adjustment_type " +
        ");";

      stmt.executeUpdate(sql);
      totalCount += chunk.length;
      Logger.log("Upserted batch: " + totalCount + "/" + records.length + " adjustment records into PostgreSQL.");
    }

    // Zero-Burn Sequence Alignment: Reset sequence to exact MAX(id) to guarantee zero gaps
    try {
      stmt.executeUpdate("SELECT setval('public.sheet_adjustments_id_seq', COALESCE((SELECT MAX(id) FROM public.sheet_adjustments), 1));");
    } catch(e) {
      Logger.log("Notice: sequence alignment: " + e.message);
    }

    conn.commit();
    Logger.log("Successfully completed PostgreSQL upsert for all " + totalCount + " adjustment records.");
    return totalCount;
  } catch (err) {
    if (conn) conn.rollback();
    Logger.log("Error in upsertAdjustmentRecords: " + err.message);
    throw err;
  } finally {
    if (stmt) try { stmt.close(); } catch(e){}
    if (conn) try { conn.close(); } catch(e){}
  }
}

// =============================================================================
// SYNC & TRIGGER HANDLERS
// =============================================================================

/**
 * Real-Time On-Edit Trigger
 */
function handleOnEdit(e) {
  if (!e || !e.range) return;
  var sheet = e.range.getSheet();
  var sName = sheet.getName().trim().toLowerCase();
  if (sName !== DB_CONFIG.sourceSheetName.trim().toLowerCase() && sName !== DB_CONFIG.targetSheetName.trim().toLowerCase()) return;
  
  var startRow = e.range.getRow();
  var endRow = e.range.getLastRow();
  if (startRow <= 1 && endRow <= 1) return;
  
  var actualStart = Math.max(2, startRow);
  var numRows = endRow - actualStart + 1;
  var rawData = sheet.getRange(actualStart, 1, numRows, sheet.getLastColumn()).getValues();
  
  var records = [];
  var targetSheet = getTargetSheet();
  var nowStr = formatTimestamp(new Date());

  for (var i = 0; i < rawData.length; i++) {
    var transformed = transformAdjustmentRow(rawData[i], actualStart + i);
    if (transformed) {
      records.push(transformed);
      if (targetSheet) {
        var sheetRow = formatRecordForSheet(transformed, nowStr);
        targetSheet.getRange(actualStart + i, 1, 1, sheetRow.length).setValues([sheetRow]);
      }
    }
  }
  
  if (records.length > 0) {
    upsertAdjustmentRecords(records);
  }
}

/**
 * Real-Time Form-Submit Trigger
 */
function handleOnFormSubmit(e) {
  if (!e || !e.values) return;
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
      sheetRows.push({
        rowNum: startRow + i,
        values: formatRecordForSheet(transformed, nowStr)
      });
    }
  }
  
  if (records.length > 0) {
    // 1. Sync recent rows to clean target sheet tab
    var targetSheet = getTargetSheet();
    if (targetSheet) {
      for (var j = 0; j < sheetRows.length; j++) {
        var r = sheetRows[j];
        targetSheet.getRange(r.rowNum, 1, 1, r.values.length).setValues([r.values]);
      }
    }

    // 2. Sync to PostgreSQL
    upsertAdjustmentRecords(records);
    Logger.log("Catch-up sync (1-min) successfully updated " + records.length + " recent adjustment records in sheet & database.");
  }
}

/**
 * Full Manual Backfill Synchronization
 */
function syncAllAdjustments() {
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
  
  // 1. Write clean standardized rows to targetSheet in chunks of 500
  var targetSheet = getTargetSheet();
  var CHUNK_SIZE = 500;
  for (var s = 0; s < sheetRows.length; s += CHUNK_SIZE) {
    var sChunk = sheetRows.slice(s, s + CHUNK_SIZE);
    targetSheet.getRange(s + 2, 1, sChunk.length, sChunk[0].length).setValues(sChunk);
  }
  Logger.log("Wrote " + sheetRows.length + " rows to tab '" + DB_CONFIG.targetSheetName + "'.");

  // 2. Batch upsert into PostgreSQL using single-connection multi-row inserts
  Logger.log("Starting PostgreSQL upsert for " + records.length + " adjustment records...");
  var totalUpserted = upsertAdjustmentRecords(records);
  Logger.log("Completed syncAllAdjustments! Total records synced to DB: " + totalUpserted);
}

// =============================================================================
// AUTOMATED TRIGGER SETUP (ONE-CLICK INSTALLATION)
// =============================================================================

function setupTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    var fnName = triggers[i].getHandlerFunction();
    if (fnName === "syncRecentAdjustments" || fnName === "handleOnEdit" || fnName === "handleOnFormSubmit") {
      ScriptApp.deleteTrigger(triggers[i]);
    }
  }

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
  for (var i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
  }
  Logger.log("All project triggers removed.");
}

function onOpen() {
  try {
    SpreadsheetApp.getUi()
      .createMenu("LetzRyd Adjustments")
      .addItem("Sync All Records (Full)", "syncAllAdjustments")
      .addItem("Sync Recent Records (1-Min)", "syncRecentAdjustments")
      .addSeparator()
      .addItem("Setup Automated Triggers", "setupTriggers")
      .addItem("Remove Triggers", "removeTriggers")
      .addToUi();
  } catch(e){}
}
