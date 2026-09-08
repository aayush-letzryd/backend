/**
 * ==============================================================================
 * LETZRYD - ACCIDENT VEHICLE REPORT LIVE PIPELINE (sheet_accidents)
 * ==============================================================================
 * 
 * Source Sheet : 'Accident vehicle report' (Raw Form Responses)
 * Target Sheet : 'sheet_accidents' (Standardized Tab in Spreadsheet)
 * Target Table : public.sheet_accidents & public.core_accidents
 * Host         : YOUR_DB_HOST_HERE:5432
 * 
 * Features:
 *  - Dual Ingestion: Populates standardized 'sheet_accidents' tab AND PostgreSQL database
 *  - Real-time live ingestion on form submit (handleOnFormSubmit) and cell edit (handleOnEdit)
 *  - 1-Minute Time-Driven Catch-Up Sync (syncRecentAccidents) with sliding window
 *  - Full Historical Backfill (syncAllAccidents) with chunked JDBC batches
 *  - 10-Issue standardization engine (ACC-01 through ACC-10)
 *  - Complete connection leak prevention (try-catch-finally with conn.close())
 *  - Zero-burn PostgreSQL upserts
 *  - Multi-column police acknowledgement consolidation into canonical BOOLEAN
 *  - Robust Excel serial date/timestamp float conversion to ISO-8601
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
  
  sourceSpreadsheetUrl: "https://docs.google.com/spreadsheets/d/1Qp_JL4gbTgUXMLuEQaGaaYwHWTNwNnrIP4lNzKsWl50/edit",
  sourceSheetName: "Accident vehicle report",
  targetSheetName: "sheet_accidents"
};

// Standard JDBC SQL Type Codes
const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  TIMESTAMP: 93,
  NUMERIC: 2,
  BOOLEAN: 16,
  NULL: 0
};

// Canonical City Code Dictionary
const CITY_CODE_MAP = {
  "bengaluru": "BLR",
  "bangalore": "BLR",
  "blr": "BLR",
  "hyderabad": "HYD",
  "hyd": "HYD",
  "mumbai": "MUM",
  "mum": "MUM",
  "delhi": "DEL",
  "del": "DEL",
  "chennai": "CHN",
  "chn": "CHN",
  "pune": "PUN",
  "pun": "PUN"
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

  // Case & space-insensitive search
  var sheets = ss.getSheets();
  var targetKey = DB_CONFIG.sourceSheetName.trim().toLowerCase();
  for (var i = 0; i < sheets.length; i++) {
    var sName = sheets[i].getName().trim().toLowerCase();
    if (sName === targetKey || sName.indexOf("accident vehicle report") !== -1 || sName.indexOf("accident") !== -1) {
      return sheets[i];
    }
  }
  
  // Check active spreadsheet if different
  var activeSS = null;
  try { activeSS = SpreadsheetApp.getActiveSpreadsheet(); } catch(e){}
  if (activeSS && ss && activeSS.getId() !== ss.getId()) {
    var aSheets = activeSS.getSheets();
    for (var j = 0; j < aSheets.length; j++) {
      var aName = aSheets[j].getName().trim().toLowerCase();
      if (aName === targetKey || aName.indexOf("accident vehicle report") !== -1 || aName.indexOf("accident") !== -1) {
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
      "Submission Timestamp", "Submitter Email", "Vehicle Number", "City Code", "Accident Date",
      "Police Acknowledgement", "Estimate Amount", "LetzRyd Payable Amount", "Driver Name",
      "Driver Partner ID", "Vehicle RFD Date", "Total Invoice", "Liability Amount",
      "LetzRyd Share", "Accident Photos Link", "Invoice Letter Link", "Incident Remarks",
      "Workshop Name", "Workshop Status", "Mode of Repair", "Type of Payment", "Source Row", "Last Synced At"
    ];
    targetSheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    targetSheet.getRange(1, 1, 1, headers.length).setFontWeight("bold").setBackground("#1F4E78").setFontColor("#FFFFFF");
    targetSheet.setFrozenRows(1);
  }
  return targetSheet;
}

// =============================================================================
// DATA SANITIZATION & STANDARDIZATION ENGINE (ACC-01 THROUGH ACC-10)
// =============================================================================

function cleanVehicleNumber(rawReg) {
  if (!rawReg) return null;
  var str = String(rawReg).trim().toUpperCase();
  if (["NA", "NAN", "NULL", "NONE", "-", "0"].indexOf(str) !== -1) return null;
  var cleaned = str.replace(/[^A-Z0-9]/g, "");
  return cleaned.length >= 6 ? cleaned : null;
}

function standardizeCityCode(rawLoc) {
  if (!rawLoc) return "BLR";
  var locStr = String(rawLoc).trim().toLowerCase();
  return CITY_CODE_MAP[locStr] || "BLR";
}

function parseDateOrTimestamp(val, isDateOnly) {
  if (!val) return null;
  if (val instanceof Date) {
    return isDateOnly ? formatDateOnly(val) : formatTimestamp(val);
  }
  var str = String(val).trim();
  if (!str || ["NA", "NAN", "NULL", "0", "#N/A", "#VALUE!", "#REF!"].indexOf(str.toUpperCase()) !== -1) return null;
  
  var num = parseFloat(str);
  if (!isNaN(num) && num > 30000 && num < 60000 && /^\d+(\.\d+)?$/.test(str)) {
    var ms = Math.round((num - 25569) * 86400 * 1000);
    var d = new Date(ms);
    return isDateOnly ? formatDateOnly(d) : formatTimestamp(d);
  }

  // DD/MM/YYYY or DD-MM-YYYY (prevents Google Apps Script V8 date swapping)
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
  var y = d.getFullYear();
  var m = ("0" + (d.getMonth() + 1)).slice(-2);
  var day = ("0" + d.getDate()).slice(-2);
  return y + "-" + m + "-" + day;
}

function formatTimestamp(d) {
  if (!d || isNaN(d.getTime())) return null;
  if (typeof Utilities !== "undefined" && Utilities.formatDate) {
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ssXXX");
  }
  var y = d.getFullYear();
  var m = ("0" + (d.getMonth() + 1)).slice(-2);
  var day = ("0" + d.getDate()).slice(-2);
  var hh = ("0" + d.getHours()).slice(-2);
  var mm = ("0" + d.getMinutes()).slice(-2);
  var ss = ("0" + d.getSeconds()).slice(-2);
  return y + "-" + m + "-" + day + " " + hh + ":" + mm + ":" + ss + "+05:30";
}

function consolidatePoliceAck(colYes, colNo, colAck) {
  if (colYes && String(colYes).trim() !== "") return true;
  if (colAck) {
    var str = String(colAck).trim().toLowerCase();
    if (str === "yes" || str === "true" || str === "column 1") return true;
    if (str === "no" || str === "false") return false;
  }
  if (colNo && String(colNo).trim() !== "") return false;
  return false;
}

function parseNumericAmount(val) {
  if (val === null || val === undefined) return 0.00;
  var str = String(val).replace(/[^0-9.-]/g, "").trim();
  if (!str) return 0.00;
  var num = parseFloat(str);
  return isNaN(num) ? 0.00 : num;
}

function parseNullableNumericAmount(val) {
  if (val === null || val === undefined) return null;
  var str = String(val).replace(/[^0-9.-]/g, "").trim();
  if (!str) return null;
  var num = parseFloat(str);
  return isNaN(num) ? null : num;
}

function transformAccidentRow(row, rowIndex) {
  var rawTimestamp = row[0];   // Col A: Timestamp
  var submitterEmail = row[1]; // Col B: Email address
  var rawReg = row[2];         // Col C: Reg No
  var rawLoc = row[3];         // Col D: Location
  var rawAccDate = row[4];     // Col E: Accident Date
  var polYes = row[5];         // Col F: Police Acknowledgement [Yes]
  var polNo = row[6];          // Col G: Police Acknowledgement [NO]
  var remarks = row[7];        // Col H: Remarks
  var estAmt = row[8];         // Col I: Estimate Amount
  var photosLink = row[9];     // Col J: Photos
  var lrPayable = row[10];     // Col K: Letzryd payable amount
  var polAck = row[11];        // Col L: Police Acknowledgement
  var drvNameM = row[12];      // Col M: Driver/Operator Name
  var drvNameN = row[13];      // Col N: Driver/Operator Name
  var rfdDate = row[15];       // Col P: Vehicle RFD date
  var totInv = row[16];        // Col Q: Total Invoice
  var liability = row[17];     // Col R: Liability
  var lrShare = row[18];       // Col S: LetzRyd Share of Invoice
  var invLink = row[19];       // Col T: Invoice link
  var drvLid = row[29];        // Col AD: Driver LID

  var cleanReg = cleanVehicleNumber(rawReg);
  if (!cleanReg) return null;

  var accDate = parseDateOrTimestamp(rawAccDate, true);
  if (!accDate) accDate = formatDateOnly(new Date());

  var subTimestamp = parseDateOrTimestamp(rawTimestamp, false);
  if (!subTimestamp) subTimestamp = formatTimestamp(new Date());

  var cityCode = standardizeCityCode(rawLoc);
  var policeAck = consolidatePoliceAck(polYes, polNo, polAck);
  var driverName = (drvNameN || drvNameM || "").toString().trim().toUpperCase() || null;
  if (driverName && (/^#N\/A/i.test(driverName) || driverName === "NA" || driverName === "NULL")) {
    driverName = null;
  }

  return {
    submission_timestamp: subTimestamp,
    submitter_email: submitterEmail ? String(submitterEmail).trim() : null,
    vehicle_number: cleanReg,
    city_code: cityCode,
    accident_date: accDate,
    police_acknowledgement: policeAck,
    estimate_amount: parseNumericAmount(estAmt),
    accident_photos_link: photosLink ? String(photosLink).trim() : null,
    letzryd_payable_amount: parseNumericAmount(lrPayable),
    driver_name: driverName,
    driver_partner_id: drvLid && String(drvLid).indexOf("LETZ") !== -1 ? String(drvLid).trim() : null,
    vehicle_rfd_date: parseDateOrTimestamp(rfdDate, true),
    total_invoice: parseNullableNumericAmount(totInv),
    liability_amount: parseNullableNumericAmount(liability),
    letzryd_share: parseNullableNumericAmount(lrShare),
    invoice_letter_link: invLink ? String(invLink).trim() : null,
    incident_remarks: remarks ? String(remarks).trim() : null,
    workshop_name: row[14] ? String(row[14]).trim() : null,
    workshop_status: "Reported",
    mode_of_repair: "Accident",
    type_of_payment: "Insurance",
    source_row: rowIndex || 0
  };
}

function formatRecordForSheet(r, nowStr) {
  return [
    r.submission_timestamp,
    r.submitter_email || "",
    r.vehicle_number,
    r.city_code,
    r.accident_date,
    r.police_acknowledgement ? "Yes" : "No",
    r.estimate_amount,
    r.letzryd_payable_amount,
    r.driver_name || "",
    r.driver_partner_id || "",
    r.vehicle_rfd_date || "",
    r.total_invoice !== null && r.total_invoice !== undefined ? r.total_invoice : "",
    r.liability_amount !== null && r.liability_amount !== undefined ? r.liability_amount : "",
    r.letzryd_share !== null && r.letzryd_share !== undefined ? r.letzryd_share : "",
    r.accident_photos_link || "",
    r.invoice_letter_link || "",
    r.incident_remarks || "",
    r.workshop_name || "",
    r.workshop_status,
    r.mode_of_repair,
    r.type_of_payment,
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

function sqlNullableNum(val) {
  if (val === null || val === undefined || val === "") return "NULL::numeric";
  var n = parseFloat(val);
  return (isNaN(n) ? "NULL::numeric" : n.toFixed(2)) + "::numeric";
}

function sqlBool(val) {
  return val ? "TRUE::boolean" : "FALSE::boolean";
}

function sqlDate(val) {
  if (!val) return "NULL::date";
  return "'" + String(val).replace(/'/g, "") + "'::date";
}

function sqlTimestamp(val) {
  if (!val) return "CURRENT_TIMESTAMP";
  return "'" + String(val).replace(/'/g, "") + "'::timestamptz";
}

function upsertAccidentRecords(records) {
  if (!records || records.length === 0) return 0;
  
  var conn = null;
  var stmt = null;
  var url = "jdbc:postgresql://" + DB_CONFIG.host + ":" + DB_CONFIG.port + "/" + DB_CONFIG.database;
  var BATCH_SIZE = 25;
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
          sqlTimestamp(r.submission_timestamp) + ", " +
          sqlStr(r.submitter_email) + ", " +
          sqlStr(r.vehicle_number) + ", " +
          sqlStr(r.city_code) + ", " +
          sqlDate(r.accident_date) + ", " +
          sqlBool(r.police_acknowledgement) + ", " +
          sqlNum(r.estimate_amount) + ", " +
          sqlStr(r.accident_photos_link) + ", " +
          sqlNum(r.letzryd_payable_amount) + ", " +
          sqlStr(r.driver_name) + ", " +
          sqlStr(r.driver_partner_id) + ", " +
          sqlDate(r.vehicle_rfd_date) + ", " +
          sqlNullableNum(r.total_invoice) + ", " +
          sqlNullableNum(r.liability_amount) + ", " +
          sqlNullableNum(r.letzryd_share) + ", " +
          sqlStr(r.invoice_letter_link) + ", " +
          sqlStr(r.incident_remarks) + ", " +
          sqlStr(r.workshop_name) + ", " +
          sqlStr(r.workshop_status || "Reported") + ", " +
          sqlStr(r.mode_of_repair || "Accident") + ", " +
          sqlStr(r.type_of_payment || "Insurance") +
        ")";
        valuesList.push(rowSql);
      }

      var sql = 
        "WITH incoming ( " +
        "  submission_timestamp, submitter_email, vehicle_number, city_code, accident_date, " +
        "  police_acknowledgement, estimate_amount, accident_photos_link, letzryd_payable_amount, " +
        "  driver_name, driver_partner_id, vehicle_rfd_date, total_invoice, liability_amount, " +
        "  letzryd_share, invoice_letter_link, incident_remarks, workshop_name, workshop_status, " +
        "  mode_of_repair, type_of_payment " +
        ") AS ( " +
        "  VALUES " + valuesList.join(",\n") + " " +
        "), " +
        "incoming_deduped AS ( " +
        "  SELECT DISTINCT ON (submission_timestamp, vehicle_number, accident_date) * " +
        "  FROM incoming " +
        "), " +
        "upd AS ( " +
        "  UPDATE public.sheet_accidents t " +
        "  SET " +
        "    submitter_email = i.submitter_email, " +
        "    city_code = i.city_code, " +
        "    police_acknowledgement = i.police_acknowledgement, " +
        "    estimate_amount = i.estimate_amount, " +
        "    accident_photos_link = i.accident_photos_link, " +
        "    letzryd_payable_amount = i.letzryd_payable_amount, " +
        "    driver_name = i.driver_name, " +
        "    driver_partner_id = COALESCE(i.driver_partner_id, t.driver_partner_id), " +
        "    vehicle_rfd_date = i.vehicle_rfd_date, " +
        "    total_invoice = i.total_invoice, " +
        "    liability_amount = i.liability_amount, " +
        "    letzryd_share = i.letzryd_share, " +
        "    invoice_letter_link = i.invoice_letter_link, " +
        "    incident_remarks = i.incident_remarks, " +
        "    workshop_name = i.workshop_name, " +
        "    workshop_status = i.workshop_status, " +
        "    mode_of_repair = i.mode_of_repair, " +
        "    type_of_payment = i.type_of_payment, " +
        "    updated_at = CURRENT_TIMESTAMP " +
        "  FROM incoming_deduped i " +
        "  WHERE t.submission_timestamp = i.submission_timestamp " +
        "    AND t.vehicle_number = i.vehicle_number " +
        "    AND t.accident_date = i.accident_date " +
        "  RETURNING t.submission_timestamp, t.vehicle_number, t.accident_date " +
        ") " +
        "INSERT INTO public.sheet_accidents ( " +
        "  submission_timestamp, submitter_email, vehicle_number, city_code, accident_date, " +
        "  police_acknowledgement, estimate_amount, accident_photos_link, letzryd_payable_amount, " +
        "  driver_name, driver_partner_id, vehicle_rfd_date, total_invoice, liability_amount, " +
        "  letzryd_share, invoice_letter_link, incident_remarks, workshop_name, workshop_status, " +
        "  mode_of_repair, type_of_payment, updated_at " +
        ") " +
        "SELECT " +
        "  i.submission_timestamp, i.submitter_email, i.vehicle_number, i.city_code, i.accident_date, " +
        "  i.police_acknowledgement, i.estimate_amount, i.accident_photos_link, i.letzryd_payable_amount, " +
        "  i.driver_name, i.driver_partner_id, i.vehicle_rfd_date, i.total_invoice, i.liability_amount, " +
        "  i.letzryd_share, i.invoice_letter_link, i.incident_remarks, i.workshop_name, i.workshop_status, " +
        "  i.mode_of_repair, i.type_of_payment, CURRENT_TIMESTAMP " +
        "FROM incoming_deduped i " +
        "WHERE NOT EXISTS ( " +
        "  SELECT 1 FROM upd u " +
        "  WHERE u.submission_timestamp = i.submission_timestamp " +
        "    AND u.vehicle_number = i.vehicle_number " +
        "    AND u.accident_date = i.accident_date " +
        ");";

      stmt.executeUpdate(sql);
      totalCount += chunk.length;
      Logger.log("Upserted batch: " + totalCount + "/" + records.length + " records into PostgreSQL.");
    }

    conn.commit();
    Logger.log("Successfully completed PostgreSQL upsert for all " + totalCount + " records.");
    return totalCount;
  } catch (err) {
    if (conn) conn.rollback();
    Logger.log("Error in upsertAccidentRecords: " + err.message);
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
  // Restrict live edit handling strictly to raw source form tab. Never process edits on target sheet_accidents tab.
  if (sName !== DB_CONFIG.sourceSheetName.trim().toLowerCase()) return;
  
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
    var transformed = transformAccidentRow(rawData[i], actualStart + i);
    if (transformed) {
      records.push(transformed);
      if (targetSheet) {
        var sheetRow = formatRecordForSheet(transformed, nowStr);
        targetSheet.getRange(actualStart + i, 1, 1, sheetRow.length).setValues([sheetRow]);
      }
    }
  }
  
  if (records.length > 0) {
    upsertAccidentRecords(records);
  }
}

/**
 * Real-Time Form-Submit Trigger
 */
function handleOnFormSubmit(e) {
  if (!e || !e.values) return;
  var rowIdx = e.range ? e.range.getRow() : 0;
  var transformed = transformAccidentRow(e.values, rowIdx);
  if (transformed) {
    var targetSheet = getTargetSheet();
    if (targetSheet && rowIdx > 1) {
      var sheetRow = formatRecordForSheet(transformed, formatTimestamp(new Date()));
      targetSheet.getRange(rowIdx, 1, 1, sheetRow.length).setValues([sheetRow]);
    }
    upsertAccidentRecords([transformed]);
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
function syncRecentAccidents() {
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
    var transformed = transformAccidentRow(data[i], startRow + i);
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
    upsertAccidentRecords(records);
    Logger.log("Catch-up sync (1-min) successfully updated " + records.length + " recent accident records in sheet & database.");
  }
}

/**
 * Full Manual Backfill Synchronization
 */
function syncAllAccidents() {
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
    var transformed = transformAccidentRow(data[i], i + 1);
    if (transformed) {
      records.push(transformed);
      sheetRows.push(formatRecordForSheet(transformed, nowStr));
    }
  }
  
  Logger.log("Transformed " + records.length + " valid accident records.");
  
  // 1. Write clean standardized rows to targetSheet in chunks of 500
  var targetSheet = getTargetSheet();
  var CHUNK_SIZE = 500;
  for (var s = 0; s < sheetRows.length; s += CHUNK_SIZE) {
    var sChunk = sheetRows.slice(s, s + CHUNK_SIZE);
    targetSheet.getRange(s + 2, 1, sChunk.length, sChunk[0].length).setValues(sChunk);
  }
  Logger.log("Wrote " + sheetRows.length + " rows to tab '" + DB_CONFIG.targetSheetName + "'.");

  // 2. Batch upsert into PostgreSQL using single-connection multi-row inserts
  Logger.log("Starting PostgreSQL upsert for " + records.length + " records...");
  var totalUpserted = upsertAccidentRecords(records);
  Logger.log("Completed syncAllAccidents! Total records synced to DB: " + totalUpserted);
}

// =============================================================================
// AUTOMATED TRIGGER SETUP (ONE-CLICK INSTALLATION)
// =============================================================================

function setupTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
  }

  ScriptApp.newTrigger("syncRecentAccidents")
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
      "1-minute catch-up sync (syncRecentAccidents) and real-time triggers are now active!",
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
      .createMenu("LetzRyd Accidents")
      .addItem("Sync All Records (Full)", "syncAllAccidents")
      .addItem("Sync Recent Records (1-Min)", "syncRecentAccidents")
      .addSeparator()
      .addItem("Setup Automated Triggers", "setupTriggers")
      .addItem("Remove Triggers", "removeTriggers")
      .addToUi();
  } catch(e){}
}
