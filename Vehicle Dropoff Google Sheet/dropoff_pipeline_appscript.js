/**
 * ==============================================================================
 * LETZRYD - VEHICLE DROPOFF GOOGLE SHEET LIVE PIPELINE & BACKFILL (sheet_dropoffs)
 * ==============================================================================
 * 
 * Target Database    : public.sheet_dropoffs (PostgreSQL Staging Table)
 * Host               : 35.200.196.113:5432
 * Database Name      : postgres
 * Source Sheet (Data): 1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM (View-Only Master)
 * Source GID (Tab)   : 1354101119 (Guarantees opening exact source tab)
 * Execution Sheet    : 1lb2BArHkQynUSA2hs_GAhCdjhOlwGIFIVjqA32Jw5M8 (Your Automated Sheet)
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
const DB_CONFIG = {
  host: "35.200.196.113",
  port: "5432",
  database: "postgres",
  user: "postgres",
  password: "8S5]U3@L^Xz)\\FH}",
  
  // Master Source Spreadsheet (View-Only)
  sourceSpreadsheetId: "1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM",
  sourceSpreadsheetUrl: "https://docs.google.com/spreadsheets/d/1Lww1a0MaYtjhn1qG5w7luzrqOidDzdTyPDK7bGk4ULM/edit",
  sourceGid: 1354101119, // Direct Tab GID matching
  sourceTabName: "Drop off History",
  localTabName: "sheet_dropoffs"
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

const SQL_TYPES = {
  VARCHAR: 12,
  INTEGER: 4,
  NUMERIC: 2,
  DATE: 91,
  NULL: 0
};

// =============================================================================
// DATABASE CONNECTION & CREDENTIAL STORE
// =============================================================================

function setupScriptProperties() {
  PropertiesService.getScriptProperties().setProperties({
    "DB_HOST": DB_CONFIG.host,
    "DB_PORT": DB_CONFIG.port,
    "DB_NAME": DB_CONFIG.database,
    "DB_USER": DB_CONFIG.user,
    "DB_PASSWORD": DB_CONFIG.password
  });
  Logger.log("Database script properties configured successfully.");
}

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
  } catch(e) {
    Logger.log("PropertiesService lookup notice: " + e.message);
  }

  var dbUrl = "jdbc:postgresql://" + host + ":" + port + "/" + database;
  return Jdbc.getConnection(dbUrl, user, password);
}

// =============================================================================
// SPREADSHEET GETTERS
// =============================================================================

function getSourceSpreadsheet() {
  if (DB_CONFIG.sourceSpreadsheetId && DB_CONFIG.sourceSpreadsheetId.trim() !== "") {
    try {
      var ss = SpreadsheetApp.openById(DB_CONFIG.sourceSpreadsheetId);
      if (ss) return ss;
    } catch(e) {
      Logger.log("openById notice for Source Sheet: " + e.message);
    }
  }
  return null;
}

function getSourceDropoffSheet() {
  var ss = getSourceSpreadsheet();
  if (!ss) throw new Error("Could not open Master Source Spreadsheet (" + DB_CONFIG.sourceSpreadsheetId + ").");

  // 1. Exact GID lookup (1354101119 - Foolproof tab resolution)
  if (DB_CONFIG.sourceGid) {
    var sheets = ss.getSheets();
    for (var i = 0; i < sheets.length; i++) {
      if (sheets[i].getSheetId() === DB_CONFIG.sourceGid) {
        return sheets[i];
      }
    }
  }

  // 2. Tab name fallback
  var sheet = ss.getSheetByName(DB_CONFIG.sourceTabName);
  if (sheet) return sheet;

  // 3. Header fallback
  var sheets = ss.getSheets();
  for (var i = 0; i < sheets.length; i++) {
    var s = sheets[i];
    if (s.getLastRow() >= 1 && s.getLastColumn() >= 3) {
      var topVals = s.getRange(1, 1, 1, Math.min(s.getLastColumn(), 15)).getValues()[0];
      var headerStr = topVals.join(" ").toLowerCase();
      if (headerStr.includes("return date") || headerStr.includes("vehicle number") || headerStr.includes("driver id")) {
        return s;
      }
    }
  }
  return sheets[0];
}

function getLocalExecutionSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!ss) return null;
  var sheet = ss.getSheetByName(DB_CONFIG.localTabName) || ss.getSheetByName("Sheet1") || ss.getSheets()[0];
  return sheet;
}

function ensureSheetRows(sheet, requiredRows) {
  if (!sheet) return;
  var maxRows = sheet.getMaxRows();
  if (maxRows < requiredRows) {
    sheet.insertRowsAfter(maxRows, requiredRows - maxRows);
    Logger.log("Expanded execution sheet grid from " + maxRows + " to " + requiredRows + " rows.");
  }
}

// =============================================================================
// DYNAMIC HEADER MAPPING
// =============================================================================

function getHeaderIndexMap(headers) {
  const map = {
    sourceRow: -1,
    returnDate: -1,
    returnType: -1,
    driverId: -1,
    driverName: -1,
    driverType: -1,
    vehicleNumber: -1,
    city: -1,
    negativeBalance: -1
  };

  if (!headers || headers.length === 0) return map;

  for (let c = 0; c < headers.length; c++) {
    const raw = String(headers[c] || "").trim().toLowerCase();
    if (!raw) continue;

    if (/source.*row|^row$/i.test(raw)) {
      map.sourceRow = c;
    } else if (/return.*date|drop.*off.*date|date.*return/i.test(raw)) {
      map.returnDate = c;
    } else if (/return.*type|reason.*return|drop.*off.*reason|reason/i.test(raw)) {
      map.returnType = c;
    } else if (/operator.*driver.*id|driver.*id|partner.*id|operator.*id/i.test(raw)) {
      map.driverId = c;
    } else if (/driver.*name|partner.*name/i.test(raw)) {
      map.driverName = c;
    } else if (/driver.*type|partner.*type|category|^type$/i.test(raw)) {
      map.driverType = c;
    } else if (/vehicle.*number|vehicle.*num|car.*number|plate.*number/i.test(raw)) {
      map.vehicleNumber = c;
    } else if (/^city$|^hub$|location/i.test(raw)) {
      map.city = c;
    } else if (/negative.*balance|balance.*amount|ola.*negative|closing.*balance|balance/i.test(raw)) {
      map.negativeBalance = c;
    }
  }

  if (map.returnDate === -1) map.returnDate = map.sourceRow === 0 ? 1 : 0;
  if (map.returnType === -1) map.returnType = map.sourceRow === 0 ? 2 : 1;
  if (map.driverId === -1) map.driverId = map.sourceRow === 0 ? 3 : 2;
  if (map.driverName === -1) map.driverName = map.sourceRow === 0 ? 4 : 3;
  if (map.vehicleNumber === -1) map.vehicleNumber = map.sourceRow === 0 ? 6 : 4;
  if (map.negativeBalance === -1) map.negativeBalance = map.sourceRow === 0 ? 8 : 5;
  if (map.driverType === -1) map.driverType = map.sourceRow === 0 ? 5 : 6;
  if (map.city === -1) map.city = map.sourceRow === 0 ? 7 : 7;

  return map;
}

// =============================================================================
// DATA SANITIZATION ENGINE
// =============================================================================

function normalizeDate(rawDate) {
  if (!rawDate) return null;
  if (rawDate instanceof Date) {
    if (isNaN(rawDate.getTime())) return null;
    const y = rawDate.getFullYear();
    if (y < 1950 || y > 2100) return null;
    return Utilities.formatDate(rawDate, "Asia/Kolkata", "yyyy-MM-dd");
  }
  
  let str = String(rawDate).trim();
  if (!str || str.toLowerCase() === 'null' || str === '-' || str.toLowerCase() === 'return date' || str.toLowerCase() === 'n/a') {
    return null;
  }
  
  if (/^\d{5}$/.test(str)) {
    const serial = parseInt(str, 10);
    const epoch = new Date(1899, 11, 30);
    epoch.setDate(epoch.getDate() + serial);
    const y = epoch.getFullYear();
    if (y < 1950 || y > 2100) return null;
    return Utilities.formatDate(epoch, "Asia/Kolkata", "yyyy-MM-dd");
  }
  
  const monthMap = {
    'jan': '01', 'feb': '02', 'mar': '03', 'apr': '04', 'may': '05', 'jun': '06',
    'jul': '07', 'aug': '08', 'sep': '09', 'oct': '10', 'nov': '11', 'dec': '12'
  };
  const textMonthMatch = str.match(/^(\d{1,2})[\/\-\.\s]([A-Za-z]{3,9})[\/\-\.\s](\d{2,4})$/);
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
  
  const dmyMatch = str.match(/^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{2,4})/);
  if (dmyMatch) {
    const day = dmyMatch[1].padStart(2, '0');
    const mon = dmyMatch[2].padStart(2, '0');
    let yr = dmyMatch[3];
    if (yr.length === 2) yr = '20' + yr;
    if (parseInt(yr, 10) >= 1950 && parseInt(yr, 10) <= 2100) {
      return `${yr}-${mon}-${day}`;
    }
  }
  
  const ymdMatch = str.match(/^(\d{4})[\/\-\.](\d{1,2})[\/\-\.](\d{1,2})/);
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
  if (["NA", "NAN", "NULL", "NONE", "-", "0", "VEHICLE NUMBER"].indexOf(str) !== -1) {
    return null;
  }
  const cleaned = str.replace(/[^A-Z0-9]/g, '');
  if (cleaned.length < 8 || cleaned.length > 12) return null;
  return /^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$/.test(cleaned) ? cleaned : null;
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
  let str = String(rawVal).replace(/[₹$,\s]/g, '').trim();
  if (!str || str === '-' || str.toLowerCase() === 'null' || str.toLowerCase() === 'n/a') return 0.00;
  if (str.toLowerCase() === 'pending' || str.toLowerCase() === 'tbd') return null;
  
  if (str.startsWith("(") && str.endsWith(")")) {
    const inner = str.slice(1, -1).replace(/[₹$,\s]/g, '').trim();
    const num = parseFloat(inner);
    return isNaN(num) ? null : -Math.abs(num);
  }
  
  const num = parseFloat(str);
  if (isNaN(num)) return null;
  return num;
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

function transformDropoffRow(row, rowIdx, hMap) {
  if (!row || row.length === 0) return null;
  
  function getVal(idx) {
    return idx !== undefined && idx >= 0 && idx < row.length ? row[idx] : null;
  }
  
  const rawDate = hMap ? getVal(hMap.returnDate) : row[0];
  const rawReturnType = hMap ? getVal(hMap.returnType) : row[1];
  const rawDriverId = hMap ? getVal(hMap.driverId) : row[2];
  const rawDriverName = hMap ? getVal(hMap.driverName) : row[3];
  const rawPlate = hMap ? getVal(hMap.vehicleNumber) : row[4];
  const rawBal = hMap ? getVal(hMap.negativeBalance) : row[5];
  const rawType = hMap ? getVal(hMap.driverType) : row[6];
  const rawCity = hMap ? getVal(hMap.city) : null;
  
  if (String(rawDate).trim().toLowerCase() === 'return date' || String(rawPlate).trim().toLowerCase() === 'vehicle number') {
    return null;
  }
  
  const returnDate = normalizeDate(rawDate);
  const vehicleNumber = cleanVehicleNumber(rawPlate);
  if (!returnDate || !vehicleNumber) return null;
  
  let sourceRow = rowIdx;
  if (hMap && hMap.sourceRow >= 0) {
    const parsedRow = parseInt(getVal(hMap.sourceRow), 10);
    if (!isNaN(parsedRow) && parsedRow > 0) {
      sourceRow = parsedRow;
    }
  }
  
  const returnType = cleanReturnType(rawReturnType);
  const driverId = cleanDriverId(rawDriverId);
  const driverName = cleanDriverName(rawDriverName);
  const driverType = cleanDriverType(rawType, driverId);
  const city = normalizeCity(rawCity, vehicleNumber);
  const negativeBalance = cleanBalance(rawBal);
  
  return {
    sourceRow: sourceRow,
    sheetRowIndex: rowIdx,
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

// =============================================================================
// DATABASE UPSERT ENGINE
// =============================================================================

function upsertDropoffRecords(records) {
  if (!records || records.length === 0) return 0;
  
  var conn = null;
  var BATCH_SIZE = 100;
  var totalCount = 0;
  
  try {
    conn = getConnection();
    conn.setAutoCommit(false);
    
    for (var b = 0; b < records.length; b += BATCH_SIZE) {
      var chunk = records.slice(b, b + BATCH_SIZE);
      
      var placeholders = [];
      for (var p = 0; p < chunk.length; p++) {
        placeholders.push("(CAST(? AS integer), CAST(? AS date), CAST(? AS varchar), CAST(? AS varchar), CAST(? AS varchar), CAST(? AS varchar), CAST(? AS varchar), CAST(? AS varchar), CAST(? AS numeric))");
      }
      
      var sql = "WITH incoming (src_row, ret_date, ret_type, drv_id, drv_name, drv_type, veh_num, city_name, neg_bal) AS (\n" +
                "  VALUES " + placeholders.join(",") + "\n" +
                "),\n" +
                "upd AS (\n" +
                "    UPDATE public.sheet_dropoffs s\n" +
                "    SET \n" +
                "        return_date = i.ret_date,\n" +
                "        return_type = i.ret_type,\n" +
                "        driver_id = i.drv_id,\n" +
                "        driver_name = i.drv_name,\n" +
                "        driver_type = i.drv_type,\n" +
                "        vehicle_number = i.veh_num,\n" +
                "        city = i.city_name,\n" +
                "        negative_balance = i.neg_bal,\n" +
                "        sync_status = 'SYNCED',\n" +
                "        updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')\n" +
                "    FROM incoming i\n" +
                "    WHERE s.source_row = i.src_row\n" +
                "    RETURNING s.dropoff_id, s.source_row\n" +
                ")\n" +
                "INSERT INTO public.sheet_dropoffs (\n" +
                "    source_row, return_date, return_type, driver_id, driver_name,\n" +
                "    driver_type, vehicle_number, city, negative_balance, sync_status,\n" +
                "    created_at, updated_at\n" +
                ")\n" +
                "SELECT \n" +
                "    i.src_row, i.ret_date, i.ret_type, i.drv_id, i.drv_name,\n" +
                "    i.drv_type, i.veh_num, i.city_name, i.neg_bal, 'SYNCED',\n" +
                "    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),\n" +
                "    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')\n" +
                "FROM incoming i\n" +
                "WHERE NOT EXISTS (SELECT 1 FROM upd WHERE upd.source_row = i.src_row);";
                
      var stmt = conn.prepareStatement(sql);
      
      var paramIdx = 1;
      for (var i = 0; i < chunk.length; i++) {
        var d = chunk[i];
        stmt.setInt(paramIdx++, d.sourceRow);
        stmt.setString(paramIdx++, d.returnDate);
        stmt.setString(paramIdx++, d.returnType);
        d.driverId ? stmt.setString(paramIdx++, d.driverId) : stmt.setNull(paramIdx++, SQL_TYPES.VARCHAR);
        d.driverName ? stmt.setString(paramIdx++, d.driverName) : stmt.setNull(paramIdx++, SQL_TYPES.VARCHAR);
        stmt.setString(paramIdx++, d.driverType);
        stmt.setString(paramIdx++, d.vehicleNumber);
        stmt.setString(paramIdx++, d.city);
        d.negativeBalance !== null ? stmt.setDouble(paramIdx++, d.negativeBalance) : stmt.setNull(paramIdx++, SQL_TYPES.NUMERIC);
      }
      
      stmt.executeUpdate();
      stmt.close();
      conn.commit();
      totalCount += chunk.length;
      Logger.log("Upserted bulk batch: " + totalCount + "/" + records.length + " dropoff records into public.sheet_dropoffs.");
    }
    
    Logger.log("Successfully completed PostgreSQL multi-row CTE bulk upsert for all " + totalCount + " records.");
    return totalCount;
  } catch (err) {
    if (conn) {
      try { conn.rollback(); } catch(e){}
    }
    Logger.log("Error in upsertDropoffRecords: " + err.message);
    throw err;
  } finally {
    if (conn) {
      try { conn.close(); } catch(e){}
    }
  }
}

// =============================================================================
// LOCAL EXECUTION SHEET BACKFILL & FORMATTED MIRRORING ENGINE
// =============================================================================

function updateLocalExecutionSheet(records) {
  if (!records || records.length === 0) return;
  try {
    var localSheet = getLocalExecutionSheet();
    if (!localSheet) return;
    
    var nowStr = Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss");
    
    var maxSheetRow = 2;
    for (var r = 0; r < records.length; r++) {
      if (records[r].sheetRowIndex > maxSheetRow) {
        maxSheetRow = records[r].sheetRowIndex;
      }
    }
    ensureSheetRows(localSheet, maxSheetRow);
    
    for (var i = 0; i < records.length; i++) {
      var rec = records[i];
      var formattedRow = [[
        rec.sourceRow,
        rec.returnDate,
        rec.returnType,
        rec.driverId,
        rec.driverName,
        rec.driverType,
        rec.vehicleNumber,
        rec.city,
        rec.negativeBalance,
        "SYNCED",
        nowStr
      ]];
      localSheet.getRange(rec.sheetRowIndex, 1, 1, 11).setValues(formattedRow);
    }
    Logger.log("Successfully updated " + records.length + " formatted 11-column rows in local Execution Sheet.");
  } catch(e) {
    Logger.log("Notice on local sheet update: " + e.message);
  }
}

// =============================================================================
// CORE WINDOW SYNC ENGINE
// =============================================================================

function syncWindowDropoffs(windowSize) {
  const sourceSheet = getSourceDropoffSheet();
  const lastRow = sourceSheet.getLastRow();
  Logger.log("Master Source Sheet tab '" + sourceSheet.getName() + "' (GID: " + sourceSheet.getSheetId() + ") last row: " + lastRow);
  if (lastRow <= 1) return 0;
  
  const startRow = Math.max(2, lastRow - windowSize + 1);
  const numRows = lastRow - startRow + 1;
  
  const headerVals = sourceSheet.getRange(1, 1, 1, sourceSheet.getLastColumn()).getValues()[0];
  const hMap = getHeaderIndexMap(headerVals);
  const windowData = sourceSheet.getRange(startRow, 1, numRows, sourceSheet.getLastColumn()).getValues();
  const records = [];

  for (let i = 0; i < windowData.length; i++) {
    const transformed = transformDropoffRow(windowData[i], startRow + i, hMap);
    if (transformed) {
      records.push(transformed);
    }
  }
  
  Logger.log("Window scan (" + windowSize + " rows) found " + records.length + " valid dropoff records.");
  if (records.length > 0) {
    upsertDropoffRecords(records);
    updateLocalExecutionSheet(records);
  }
  return records.length;
}

function syncRecentDropoffs() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("syncRecentDropoffs: Lock timeout (30s). Skipping.");
    return;
  }
  try {
    const count = syncWindowDropoffs(500);
    try {
      SpreadsheetApp.getActiveSpreadsheet().toast("Synced " + count + " dropoffs to DB & updated local sheet!", "Sync Complete", 5);
    } catch(e){}
  } finally {
    lock.releaseLock();
  }
}

function syncTriggeredDropoffs() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("syncTriggeredDropoffs: Lock timeout (30s). Skipping.");
    return;
  }
  try {
    syncWindowDropoffs(100);
  } finally {
    lock.releaseLock();
  }
}

// =============================================================================
// UI MENU & AUTOMATED TRIGGER SETUP
// =============================================================================

function onOpen() {
  try {
    SpreadsheetApp.getUi()
      .createMenu("LetzRyd Dropoffs")
      .addItem("Sync Recent Records (500 Rows - Manual Catch-Up)", "syncRecentDropoffs")
      .addItem("Sync Latest Records (100 Rows)", "syncTriggeredDropoffs")
      .addSeparator()
      .addItem("Setup Automated 1-Min Background Sync", "setupTriggers")
      .addToUi();
  } catch(e) {}
}

function setupTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
  }
  
  ScriptApp.newTrigger("syncTriggeredDropoffs")
    .timeBased()
    .everyMinutes(1)
    .create();
    
  Logger.log("Automated 1-minute time trigger installed successfully for syncTriggeredDropoffs (100 rows).");
  try {
    SpreadsheetApp.getUi().alert(
      "Automated 1-Minute Sync Activated",
      "The script will now automatically check tab GID 1354101119 every 1 minute (100-row window), push new entries to PostgreSQL DB, and mirror them into this sheet.",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  } catch(e){}
}
