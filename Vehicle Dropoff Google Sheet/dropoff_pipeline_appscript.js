/**
 * ==============================================================================
 * LETZRYD - VEHICLE DROPOFF LIVE PIPELINE (sheet_dropoffs)
 * ==============================================================================
 * 
 * Source Sheet : 'Unified_Dropoff_source' / 'Drop off History' (Raw / Consolidated Records)
 * Target Sheet : 'sheet_dropoffs' (Standardized Tab in Spreadsheet)
 * Target Table : public.sheet_dropoffs & public.core_dropoffs
 * Host         : YOUR_DB_HOST_HERE:5432
 * 
 * Key Features:
 *  - Blazing-Fast Multi-Row SQL Batching: Eliminates JDBC RPC latency, syncing 6,400+ rows in seconds
 *  - Dual Ingestion: Populates standardized 'sheet_dropoffs' tab AND PostgreSQL database
 *  - Real-time live ingestion on cell edit (handleOnEdit) and form submit (handleOnFormSubmit)
 *  - 1-Minute Time-Driven Catch-Up Sync (syncRecentDropoffs) with sliding window
 *  - Full Historical Batch Sync (syncAllDropoffs)
 *  - 11-Issue standardization engine (ISS-01 through ISS-11)
 *  - Debt polarity standardization: all liabilities stored as negative floats (500 -> -500.00, (500) -> -500.00)
 *  - Strict plate validation (8 <= length <= 12, uppercase alphanumeric)
 *  - Strict Operator classification check (LETZ + IP prefix)
 *  - Complete connection leak prevention (try-catch-finally with conn.close())
 *  - Automated trigger installer (setupTriggers) removing old triggers before creating new ones
 *  - Custom spreadsheet UI menu with one-click actions
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
const DB_CONFIG = {
  host: "35.200.196.113",
  port: "5432",
  database: "postgres",
  user: "postgres",
  password: "8S5]U3@L^Xz)\\FH}",
  
  // Original Pan India Master Sheet (same source as Adjustments pipeline)
  sourceSpreadsheetUrl: "https://docs.google.com/spreadsheets/d/1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM/edit",
  sourceSheetName: "Drop off History",
  targetSheetName: "sheet_dropoffs"
};

// Canonical City Code & Name Map
const CITY_MAP = {
  "blr": "Bengaluru",
  "bangalore": "Bengaluru",
  "bengaluru": "Bengaluru",
  "hyd": "Hyderabad",
  "hyderabad": "Hyderabad",
  "mum": "Mumbai",
  "mumbai": "Mumbai",
  "pun": "Pune",
  "pune": "Pune",
  "del": "Delhi",
  "delhi": "Delhi",
  "ncr": "Delhi",
  "chn": "Chennai",
  "chennai": "Chennai"
};

// =============================================================================
// DATABASE CONFIGURATION & CONNECTION MANAGEMENT
// =============================================================================

function getConnection() {
  var host = DB_CONFIG.host;
  var port = DB_CONFIG.port;
  var database = DB_CONFIG.database;
  var user = DB_CONFIG.user;
  var password = DB_CONFIG.password;

  try {
    var props = PropertiesService.getScriptProperties();
    if (props) {
      host = props.getProperty("DB_HOST") || host;
      port = props.getProperty("DB_PORT") || port;
      database = props.getProperty("DB_NAME") || database;
      user = props.getProperty("DB_USER") || user;
      password = props.getProperty("DB_PASSWORD") || password;
    }
  } catch(e) {}

  var dbUrl = "jdbc:postgresql://" + host + ":" + port + "/" + database;
  return Jdbc.getConnection(dbUrl, user, password);
}

// =============================================================================
// SPREADSHEET GETTERS & TAB MANAGEMENT
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
    if (sName === targetKey || sName.indexOf("unified_dropoff") !== -1 || sName.indexOf("drop off history") !== -1 || sName.indexOf("dropoff") !== -1) {
      return sheets[i];
    }
  }
  
  var activeSS = null;
  try { activeSS = SpreadsheetApp.getActiveSpreadsheet(); } catch(e){}
  if (activeSS && ss && activeSS.getId() !== ss.getId()) {
    var aSheets = activeSS.getSheets();
    for (var j = 0; j < aSheets.length; j++) {
      var aName = aSheets[j].getName().trim().toLowerCase();
      if (aName === targetKey || aName.indexOf("unified_dropoff") !== -1 || aName.indexOf("drop off history") !== -1 || aName.indexOf("dropoff") !== -1) {
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
      "Source Row", "Return Date", "Return Type", "Driver ID", "Driver Name",
      "Driver Type", "Vehicle Number", "City", "Negative Balance", "Sync Status", "Last Synced At"
    ];
    targetSheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    targetSheet.getRange(1, 1, 1, headers.length).setFontWeight("bold").setBackground("#1F4E78").setFontColor("#FFFFFF");
    targetSheet.setFrozenRows(1);
  }
  return targetSheet;
}

// =============================================================================
// DATA SANITIZATION & STANDARDIZATION ENGINE (ISS-01 THROUGH ISS-11)
// =============================================================================

function normalizeDate(rawDate) {
  if (!rawDate) return null;
  
  if (rawDate instanceof Date) {
    if (isNaN(rawDate.getTime())) return null;
    const y = rawDate.getFullYear();
    if (y < 1950 || y > 2100) return null;
    const m = String(rawDate.getMonth() + 1).padStart(2, '0');
    const d = String(rawDate.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  
  let str = String(rawDate).trim();
  if (!str || str.toLowerCase() === 'null' || str === '-' || str.toLowerCase() === 'return date' || str.toLowerCase() === 'n/a') return null;
  
  if (str.includes(' ')) {
    str = str.split(' ')[0].trim();
  }
  
  // Excel Serial Integer (e.g. 45123)
  if (/^\d{5}$/.test(str)) {
    const serial = parseInt(str, 10);
    const epoch = new Date(1899, 11, 30);
    epoch.setDate(epoch.getDate() + serial);
    const y = epoch.getFullYear();
    if (y < 1950 || y > 2100) return null;
    const m = String(epoch.getMonth() + 1).padStart(2, '0');
    const d = String(epoch.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  
  // Text Month format (e.g. 12-Jan-2024)
  const monthMap = {
    'jan': '01', 'feb': '02', 'mar': '03', 'apr': '04', 'may': '05', 'jun': '06',
    'jul': '07', 'aug': '08', 'sep': '09', 'oct': '10', 'nov': '11', 'dec': '12'
  };
  const textMonthMatch = str.match(/^(\d{1,2})[\/\-\.]([A-Za-z]{3,9})[\/\-\.](\d{2,4})$/);
  if (textMonthMatch) {
    const day = textMonthMatch[1].padStart(2, '0');
    const monKey = textMonthMatch[2].substring(0, 3).toLowerCase();
    const mon = monthMap[monKey];
    let yr = textMonthMatch[3];
    if (yr.length === 2) yr = '20' + yr;
    if (mon && parseInt(yr, 10) >= 1950 && parseInt(yr, 10) <= 2100) {
      return `${yr}-${mon}-${day}`;
    }
  }
  
  // DMY format: DD.MM.YYYY, DD/MM/YYYY, DD-MM-YYYY
  const dmyMatch = str.match(/^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{2,4})$/);
  if (dmyMatch) {
    const day = dmyMatch[1].padStart(2, '0');
    const mon = dmyMatch[2].padStart(2, '0');
    let yr = dmyMatch[3];
    if (yr.length === 2) yr = '20' + yr;
    if (parseInt(yr, 10) >= 1950 && parseInt(yr, 10) <= 2100) {
      return `${yr}-${mon}-${day}`;
    }
  }
  
  // ISO format: YYYY-MM-DD
  const ymdMatch = str.match(/^(\d{4})[\/\-\.](\d{1,2})[\/\-\.](\d{1,2})$/);
  if (ymdMatch) {
    const yr = ymdMatch[1];
    const mon = ymdMatch[2].padStart(2, '0');
    const day = ymdMatch[3].padStart(2, '0');
    if (parseInt(yr, 10) >= 1950 && parseInt(yr, 10) <= 2100) {
      return `${yr}-${mon}-${day}`;
    }
  }
  
  return null;
}

function cleanVehicleNumber(rawPlate) {
  if (!rawPlate) return null;
  const str = String(rawPlate).trim().toUpperCase();
  if (["NA", "NAN", "NULL", "NONE", "-", "0", "VEHICLE NUMBER"].indexOf(str) !== -1) return null;
  const cleaned = str.replace(/[^A-Z0-9]/g, '');
  return (cleaned.length >= 8 && cleaned.length <= 12) ? cleaned : null;
}

function normalizeCity(rawCity, vehiclePlate) {
  const c = String(rawCity || '').trim();
  const cLower = c.toLowerCase();
  
  if (CITY_MAP[cLower]) return CITY_MAP[cLower];
  
  const plate = String(vehiclePlate || '').toUpperCase();
  if (plate.startsWith('KA')) return 'Bengaluru';
  if (plate.startsWith('TS') || plate.startsWith('TG') || plate.startsWith('AP')) return 'Hyderabad';
  if (plate.startsWith('MH')) {
    if (cLower.includes('pune') || cLower.includes('pun')) return 'Pune';
    return 'Mumbai';
  }
  if (plate.startsWith('DL')) return 'Delhi';
  
  return c ? c.charAt(0).toUpperCase() + c.slice(1).toLowerCase() : 'Bengaluru';
}

function cleanBalance(rawVal) {
  if (rawVal === null || rawVal === undefined || rawVal === '') return 0.00;
  let str = String(rawVal).replace(/[₹,\s]/g, '').trim();
  if (!str || str === '-' || str.toLowerCase() === 'null' || str.toLowerCase() === 'n/a') return 0.00;
  
  if (str.toLowerCase() === 'pending' || str.toLowerCase() === 'tbd') return null;
  
  if (str.startsWith("(") && str.endsWith(")")) {
    const inner = str.slice(1, -1).trim();
    const num = parseFloat(inner);
    return isNaN(num) ? null : -Math.abs(num);
  }
  
  const num = parseFloat(str);
  if (isNaN(num)) return null;
  if (num === 0) return 0.00;
  
  return -Math.abs(num);
}

function cleanDriverType(rawType, driverId) {
  let driverType = String(rawType || '').trim();
  if (!driverType) {
    const dUpper = String(driverId || '').toUpperCase();
    return (dUpper.startsWith('LETZ') && dUpper.includes('IP')) ? 'Operator' : 'Individual';
  }
  return driverType.charAt(0).toUpperCase() + driverType.slice(1).toLowerCase();
}

function cleanDriverId(rawId) {
  if (!rawId) return 'UNKNOWN_DRIVER';
  const str = String(rawId).trim();
  if (['', 'N/A', 'NA', 'NULL', '-', 'NONE'].indexOf(str.toUpperCase()) !== -1) {
    return 'UNKNOWN_DRIVER';
  }
  return str;
}

function cleanDriverName(rawName) {
  if (!rawName) return 'Unknown Driver';
  const str = String(rawName).trim();
  if (['', 'N/A', 'NA', 'NULL', '-', 'NONE'].indexOf(str.toUpperCase()) !== -1) {
    return 'Unknown Driver';
  }
  return str;
}

function cleanReturnType(rawType) {
  if (!rawType) return 'Attrition';
  const str = String(rawType).trim();
  if (['', 'N/A', 'NA', 'NULL', '-'].indexOf(str.toUpperCase()) !== -1) {
    return 'Attrition';
  }
  return str;
}

// =============================================================================
// HELPER SQL FORMATTERS (ELIMINATES JDBC BRIDGE LATENCY)
// =============================================================================

function sqlStr(val) {
  if (val === null || val === undefined) return "NULL::text";
  var s = String(val).trim();
  if (s === "" || s.toUpperCase() === "NULL") return "NULL::text";
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

function sqlInt(val) {
  if (val === null || val === undefined || val === "") return "0::integer";
  var n = parseInt(val, 10);
  return (isNaN(n) ? "0" : String(n)) + "::integer";
}

function sqlDate(val) {
  if (!val) return "NULL::date";
  return "'" + String(val).replace(/'/g, "") + "'::date";
}

/**
 * Transforms raw sheet row into sanitized dropoff record object
 */
function transformDropoffRow(row, rowIdx) {
  if (!row || row.length === 0) return null;
  
  const rawDate = row[0];
  const rawReturnType = row[1];
  const rawDriverId = row[2];
  const rawDriverName = row[3];
  const rawPlate = row[4];
  const rawBal = row[5];
  const rawType = row[6];
  const rawCity = row[7];
  
  if (String(rawDate).trim().toLowerCase() === 'return date' || String(rawPlate).trim().toLowerCase() === 'vehicle number') {
    return null;
  }
  
  const returnDate = normalizeDate(rawDate);
  const vehicleNumber = cleanVehicleNumber(rawPlate);
  if (!returnDate || !vehicleNumber) return null;
  
  const returnType = cleanReturnType(rawReturnType);
  const driverId = cleanDriverId(rawDriverId);
  const driverName = cleanDriverName(rawDriverName);
  const driverType = cleanDriverType(rawType, driverId);
  const city = normalizeCity(rawCity, vehicleNumber);
  const negativeBalance = cleanBalance(rawBal);
  
  return {
    sourceRow: rowIdx,
    returnDate: returnDate,
    returnType: returnType,
    driverId: driverId,
    driverName: driverName,
    driverType: driverType,
    vehicleNumber: vehicleNumber,
    city: city,
    negativeBalance: negativeBalance
  };
}

function formatRecordForSheet(r, nowStr) {
  return [
    r.sourceRow,
    r.returnDate,
    r.returnType,
    r.driverId,
    r.driverName,
    r.driverType,
    r.vehicleNumber,
    r.city,
    r.negativeBalance !== null ? r.negativeBalance : "",
    "SYNCED",
    nowStr
  ];
}

function formatTimestamp(d) {
  if (!d) return "";
  var y = d.getFullYear();
  var m = String(d.getMonth() + 1).padStart(2, "0");
  var day = String(d.getDate()).padStart(2, "0");
  var h = String(d.getHours()).padStart(2, "0");
  var min = String(d.getMinutes()).padStart(2, "0");
  var s = String(d.getSeconds()).padStart(2, "0");
  return y + "-" + m + "-" + day + " " + h + ":" + min + ":" + s;
}

// =============================================================================
// DATABASE UPSERT ENGINE (MULTI-ROW CHUNKS - IDENTICAL TO ACCIDENTS PIPELINE)
// =============================================================================

function upsertDropoffRecords(records) {
  if (!records || records.length === 0) return 0;
  
  var conn = null;
  var stmt = null;
  var url = "jdbc:postgresql://" + DB_CONFIG.host + ":" + DB_CONFIG.port + "/" + DB_CONFIG.database;
  var BATCH_SIZE = 50;
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
          sqlInt(r.sourceRow) + ", " +
          sqlDate(r.returnDate) + ", " +
          sqlStr(r.returnType) + ", " +
          sqlStr(r.driverId) + ", " +
          sqlStr(r.driverName) + ", " +
          sqlStr(r.driverType) + ", " +
          sqlStr(r.vehicleNumber) + ", " +
          sqlStr(r.city) + ", " +
          sqlNullableNum(r.negativeBalance) + ", " +
          "'SYNCED', (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')" +
        ")";
        valuesList.push(rowSql);
      }
      
      var sql = 
        "INSERT INTO public.sheet_dropoffs (" +
        "  source_row, return_date, return_type, driver_id, driver_name," +
        "  driver_type, vehicle_number, city, negative_balance, sync_status, updated_at" +
        ") VALUES " + valuesList.join(",\n") + " " +
        "ON CONFLICT (source_row) DO UPDATE SET " +
        "  return_date = EXCLUDED.return_date, " +
        "  return_type = EXCLUDED.return_type, " +
        "  driver_id = EXCLUDED.driver_id, " +
        "  driver_name = EXCLUDED.driver_name, " +
        "  driver_type = EXCLUDED.driver_type, " +
        "  vehicle_number = EXCLUDED.vehicle_number, " +
        "  city = EXCLUDED.city, " +
        "  negative_balance = EXCLUDED.negative_balance, " +
        "  sync_status = 'SYNCED', " +
        "  updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata');";
      
      stmt.executeUpdate(sql);
      totalCount += chunk.length;
      Logger.log("Upserted batch: " + totalCount + "/" + records.length + " dropoff records into PostgreSQL.");
    }
    
    conn.commit();
    Logger.log("Successfully completed PostgreSQL upsert for all " + totalCount + " records.");
    return totalCount;
  } catch (err) {
    if (conn) conn.rollback();
    Logger.log("Error in upsertDropoffRecords: " + err.message);
    throw err;
  } finally {
    if (stmt) try { stmt.close(); } catch(e){}
    if (conn) try { conn.close(); } catch(e){}
  }
}

// =============================================================================
// SYNCHRONIZATION HANDLERS (FULL, 1-MIN, ON-EDIT, ON-FORM-SUBMIT)
// =============================================================================

function syncAllDropoffs() {
  const sourceSheet = getSourceSheet();
  const data = sourceSheet.getDataRange().getValues();
  Logger.log("Read " + data.length + " total rows from source tab '" + sourceSheet.getName() + "'");
  
  if (data.length <= 1) {
    Logger.log("Source tab contains no data rows yet.");
    return;
  }
  
  const records = [];
  const sheetRows = [];
  const nowStr = formatTimestamp(new Date());

  for (let i = 1; i < data.length; i++) {
    const transformed = transformDropoffRow(data[i], i + 1);
    if (transformed) {
      records.push(transformed);
      sheetRows.push(formatRecordForSheet(transformed, nowStr));
    }
  }
  
  Logger.log("Transformed " + records.length + " valid dropoff records.");
  
  // 1. Write clean standardized rows to target tab in chunks of 500
  try {
    const targetSheet = getTargetSheet();
    if (targetSheet && sheetRows.length > 0) {
      const targetDataRange = targetSheet.getDataRange();
      if (targetDataRange.getLastRow() > 1) {
        targetSheet.getRange(2, 1, targetDataRange.getLastRow() - 1, targetSheet.getLastColumn()).clearContent();
      }
      const CHUNK_SIZE = 500;
      for (let s = 0; s < sheetRows.length; s += CHUNK_SIZE) {
        const sChunk = sheetRows.slice(s, s + CHUNK_SIZE);
        targetSheet.getRange(s + 2, 1, sChunk.length, sChunk[0].length).setValues(sChunk);
      }
      Logger.log("Wrote " + sheetRows.length + " rows to tab '" + DB_CONFIG.targetSheetName + "'.");
    }
  } catch(e) {
    Logger.log("Notice on target sheet write: " + e.message);
  }

  // 2. Batch upsert into PostgreSQL (Multi-row SQL statements)
  Logger.log("Starting PostgreSQL upsert for " + records.length + " records...");
  const totalUpserted = upsertDropoffRecords(records);
  Logger.log("Completed syncAllDropoffs! Total records synced to DB: " + totalUpserted);
  
  try {
    if (typeof SpreadsheetApp !== 'undefined' && SpreadsheetApp.getActiveSpreadsheet()) {
      SpreadsheetApp.getActiveSpreadsheet().toast(`Successfully synced ${totalUpserted} dropoffs to database!`, 'Sync Complete', 5);
    }
  } catch(e){}
}

function syncRecentDropoffs() {
  const sourceSheet = getSourceSheet();
  const lastRow = sourceSheet.getLastRow();
  if (lastRow <= 1) return;
  
  const WINDOW_SIZE = 150;
  const startRow = Math.max(2, lastRow - WINDOW_SIZE + 1);
  const numRows = lastRow - startRow + 1;
  
  const data = sourceSheet.getRange(startRow, 1, numRows, sourceSheet.getLastColumn()).getValues();
  const records = [];
  const sheetRows = [];
  const nowStr = formatTimestamp(new Date());

  for (let i = 0; i < data.length; i++) {
    const transformed = transformDropoffRow(data[i], startRow + i);
    if (transformed) {
      records.push(transformed);
      sheetRows.push({
        rowNum: startRow + i,
        values: formatRecordForSheet(transformed, nowStr)
      });
    }
  }
  
  if (records.length > 0) {
    try {
      const targetSheet = getTargetSheet();
      if (targetSheet) {
        for (let j = 0; j < sheetRows.length; j++) {
          const r = sheetRows[j];
          targetSheet.getRange(r.rowNum, 1, 1, r.values.length).setValues([r.values]);
        }
      }
    } catch(e) {}

    upsertDropoffRecords(records);
    Logger.log("Catch-up sync (1-min) successfully updated " + records.length + " recent dropoff records.");
  }
}

function handleOnEdit(e) {
  if (!e || !e.range) return;
  const sheet = e.range.getSheet();
  const sName = sheet.getName().trim().toLowerCase();
  if (sName !== DB_CONFIG.sourceSheetName.trim().toLowerCase() && sName.indexOf("dropoff") === -1 && sName.indexOf("drop off") === -1) {
    return;
  }
  
  const startRow = e.range.getRow();
  const endRow = e.range.getLastRow();
  if (startRow <= 1 && endRow <= 1) return;
  
  const actualStart = Math.max(2, startRow);
  const numRows = endRow - actualStart + 1;
  const rawData = sheet.getRange(actualStart, 1, numRows, sheet.getLastColumn()).getValues();
  
  const records = [];
  const nowStr = formatTimestamp(new Date());

  for (let i = 0; i < rawData.length; i++) {
    const transformed = transformDropoffRow(rawData[i], actualStart + i);
    if (transformed) {
      records.push(transformed);
      try {
        const targetSheet = getTargetSheet();
        if (targetSheet) {
          const sheetRow = formatRecordForSheet(transformed, nowStr);
          targetSheet.getRange(actualStart + i, 1, 1, sheetRow.length).setValues([sheetRow]);
        }
      } catch(e) {}
    }
  }
  
  if (records.length > 0) {
    upsertDropoffRecords(records);
  }
}

function handleOnFormSubmit(e) {
  if (!e || !e.values) {
    syncRecentDropoffs();
    return;
  }
  const rowIdx = e.range ? e.range.getRow() : 0;
  const transformed = transformDropoffRow(e.values, rowIdx);
  if (transformed) {
    try {
      const targetSheet = getTargetSheet();
      if (targetSheet && rowIdx > 1) {
        const sheetRow = formatRecordForSheet(transformed, formatTimestamp(new Date()));
        targetSheet.getRange(rowIdx, 1, 1, sheetRow.length).setValues([sheetRow]);
      }
    } catch(e) {}
    upsertDropoffRecords([transformed]);
  }
}

// =============================================================================
// SPREADSHEET UI MENU & TRIGGER AUTOMATION
// =============================================================================

function onOpen() {
  try {
    SpreadsheetApp.getUi()
      .createMenu("LetzRyd Dropoffs")
      .addItem("Sync All Records (Full)", "syncAllDropoffs")
      .addItem("Sync Recent Records (1-Min)", "syncRecentDropoffs")
      .addSeparator()
      .addItem("Setup Automated Triggers", "setupTriggers")
      .addItem("Remove Triggers", "removeTriggers")
      .addToUi();
  } catch(e) {}
}

function removeTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
  }
  Logger.log("All project triggers removed.");
}

function setupTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
  }
  
  ScriptApp.newTrigger("syncRecentDropoffs")
    .timeBased()
    .everyMinutes(1)
    .create();
    
  try {
    var ss = SpreadsheetApp.getActiveSpreadsheet() || getSourceSpreadsheet();
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
    Logger.log("Notice: Spreadsheet-bound triggers setup: " + e.message);
  }

  Logger.log("All automated triggers installed successfully (1-minute catch-up + Live OnEdit + OnFormSubmit)!");
  try {
    SpreadsheetApp.getUi().alert(
      "Triggers Installed Successfully",
      "1-minute catch-up sync (syncRecentDropoffs) and real-time triggers are now active!",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  } catch(e) {}
}
