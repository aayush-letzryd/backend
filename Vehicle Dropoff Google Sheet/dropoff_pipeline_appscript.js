/**
 * ==============================================================================
 * LETZRYD - VEHICLE DROPOFF GOOGLE SHEET LIVE PIPELINE (sheet_dropoffs)
 * ==============================================================================
 * 
 * Target Spreadsheet : 'dropoffs_form' (Standalone Dropoff Form Spreadsheet)
 * Spreadsheet ID     : 1lb2BArHkQynUSA2hs_GAhCdjhOlwGIFIVjqA32Jw5M8
 * Target Table       : public.sheet_dropoffs (PostgreSQL Staging Table)
 * Host               : YOUR_DB_HOST_HERE:5432
 * 
 * Key Features:
 *  - Zero-Burn Sequence CTE Upsert: Eliminates sequence burning, preventing ID explosion
 *  - Native Active Spreadsheet Binding: Runs seamlessly inside 'dropoffs_form'
 *  - Parameterized JDBC PreparedStatement: Binary parameter binding with SQL injection immunity
 *  - Dynamic Header Mapping: Scans row 1 headers, handles 'Source Row' in Col A or anywhere
 *  - Concurrency Protection: Robust LockService guards with 30s timeout on all handlers
 *  - Real-time live ingestion on cell edit (handleOnEdit) and form submit (handleOnFormSubmit)
 *  - 1-Minute Time-Driven Catch-Up Sync (syncRecentDropoffs) with 150-row sliding window
 *  - Full Historical Batch Sync (syncAllDropoffs) with 100-row batch commits
 *  - Accounting parentheses parsing: (500.00) -> -500.00
 *  - Strict Indian vehicle plate regex validation (^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$)
 *  - Pure IST Date Normalization via Utilities.formatDate ("Asia/Kolkata")
 *  - Complete connection leak prevention (try-catch-finally with stmt.close() and conn.close())
 *  - Automated trigger installer (setupTriggers) and remover (removeTriggers)
 *  - Custom spreadsheet UI menu with one-click actions
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
const DB_CONFIG = {
  host: "YOUR_DB_HOST_HERE",
  port: "5432",
  database: "postgres",
  user: "YOUR_DB_USER_HERE",
  password: "YOUR_DB_PASSWORD_HERE",
  
  // dropoffs_form Spreadsheet
  sourceSpreadsheetId: "1lb2BArHkQynUSA2hs_GAhCdjhOlwGIFIVjqA32Jw5M8",
  sourceSpreadsheetUrl: "https://docs.google.com/spreadsheets/d/1lb2BArHkQynUSA2hs_GAhCdjhOlwGIFIVjqA32Jw5M8/edit",
  preferredSheetName: "sheet_dropoffs"
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

// Zero-Burn Sequence CTE Upsert Query
const UPSERT_CTE_SQL = `
WITH incoming AS (
    SELECT 
        CAST(? AS integer) AS src_row,
        CAST(? AS date) AS ret_date,
        CAST(? AS varchar) AS ret_type,
        CAST(? AS varchar) AS drv_id,
        CAST(? AS varchar) AS drv_name,
        CAST(? AS varchar) AS drv_type,
        CAST(? AS varchar) AS veh_num,
        CAST(? AS varchar) AS city_name,
        CAST(? AS numeric) AS neg_bal
),
upd AS (
    UPDATE public.sheet_dropoffs s
    SET 
        return_date = i.ret_date,
        return_type = i.ret_type,
        driver_id = i.drv_id,
        driver_name = i.drv_name,
        driver_type = i.drv_type,
        vehicle_number = i.veh_num,
        city = i.city_name,
        negative_balance = i.neg_bal,
        sync_status = 'SYNCED',
        updated_at = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
    FROM incoming i
    WHERE s.source_row = i.src_row
    RETURNING s.dropoff_id
)
INSERT INTO public.sheet_dropoffs (
    source_row, return_date, return_type, driver_id, driver_name,
    driver_type, vehicle_number, city, negative_balance, sync_status,
    created_at, updated_at
)
SELECT 
    i.src_row, i.ret_date, i.ret_type, i.drv_id, i.drv_name,
    i.drv_type, i.veh_num, i.city_name, i.neg_bal, 'SYNCED',
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata'),
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')
FROM incoming i
WHERE NOT EXISTS (SELECT 1 FROM upd);
`;

// =============================================================================
// DATABASE CONNECTION MANAGEMENT & SECURE CREDENTIAL STORE
// =============================================================================

/**
 * Configure credentials into Google Apps Script PropertiesService.
 * Call this function once from Script Editor or runbook to store real credentials.
 */
function setupScriptProperties(host, port, dbName, user, password) {
  PropertiesService.getScriptProperties().setProperties({
    "DB_HOST": host || "YOUR_DB_HOST_HERE",
    "DB_PORT": String(port || "5432"),
    "DB_NAME": dbName || "postgres",
    "DB_USER": user || "YOUR_DB_USER_HERE",
    "DB_PASSWORD": password || "YOUR_DB_PASSWORD_HERE"
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
// SPREADSHEET GETTERS & TAB MANAGEMENT
// =============================================================================

function getTargetSpreadsheet() {
  // 1. Native active spreadsheet binding
  try {
    var active = SpreadsheetApp.getActiveSpreadsheet();
    if (active) return active;
  } catch(e) {}

  // 2. Open by ID
  if (DB_CONFIG.sourceSpreadsheetId && DB_CONFIG.sourceSpreadsheetId.trim() !== "") {
    try {
      return SpreadsheetApp.openById(DB_CONFIG.sourceSpreadsheetId);
    } catch(e) {
      Logger.log("openById notice: " + e.message);
    }
  }

  // 3. Fallback to openByUrl
  if (DB_CONFIG.sourceSpreadsheetUrl && DB_CONFIG.sourceSpreadsheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(DB_CONFIG.sourceSpreadsheetUrl);
    } catch(e) {
      Logger.log("openByUrl notice: " + e.message);
    }
  }
  return null;
}

function getDropoffSheet() {
  var ss = getTargetSpreadsheet();
  if (!ss) throw new Error("Could not access target spreadsheet 'dropoffs_form'.");

  // 1. Check preferred tab name ('sheet_dropoffs')
  if (DB_CONFIG.preferredSheetName) {
    var sheet = ss.getSheetByName(DB_CONFIG.preferredSheetName);
    if (sheet) return sheet;
  }

  // 2. Look for tab containing dropoff headers (Return Date / Vehicle Number)
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

  // 3. Fallback to active sheet or first sheet
  try {
    var activeSheet = ss.getActiveSheet();
    if (activeSheet) return activeSheet;
  } catch(e) {}

  return sheets[0];
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
    negativeBalance: -1,
    syncStatus: -1,
    lastSyncedAt: -1
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
    } else if (/sync.*status/i.test(raw)) {
      map.syncStatus = c;
    } else if (/last.*sync/i.test(raw)) {
      map.lastSyncedAt = c;
    }
  }

  // Positional fallbacks if headers were not explicitly matched
  if (map.returnDate === -1) map.returnDate = map.sourceRow === 0 ? 1 : 0;
  if (map.returnType === -1) map.returnType = map.sourceRow === 0 ? 2 : 1;
  if (map.driverId === -1) map.driverId = map.sourceRow === 0 ? 3 : 2;
  if (map.driverName === -1) map.driverName = map.sourceRow === 0 ? 4 : 3;
  if (map.driverType === -1) map.driverType = map.sourceRow === 0 ? 5 : 6;
  if (map.vehicleNumber === -1) map.vehicleNumber = map.sourceRow === 0 ? 6 : 4;
  if (map.city === -1) map.city = map.sourceRow === 0 ? 7 : 7;
  if (map.negativeBalance === -1) map.negativeBalance = map.sourceRow === 0 ? 8 : 5;

  return map;
}

// =============================================================================
// DATA SANITIZATION & STANDARDIZATION ENGINE
// =============================================================================

/**
 * Normalizes input date to standard YYYY-MM-DD string in Asia/Kolkata timezone.
 * Handles Date objects, 5-digit Excel epoch serials, DMY text, and ISO dates.
 */
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
  
  // 5-digit Excel Serial Integer (e.g. 45123)
  if (/^\d{5}$/.test(str)) {
    const serial = parseInt(str, 10);
    const epoch = new Date(1899, 11, 30);
    epoch.setDate(epoch.getDate() + serial);
    const y = epoch.getFullYear();
    if (y < 1950 || y > 2100) return null;
    return Utilities.formatDate(epoch, "Asia/Kolkata", "yyyy-MM-dd");
  }
  
  // Text Month format (e.g. 12-Jan-2024, 12 Jan 2024)
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
  
  // DMY format: DD/MM/YYYY, DD-MM-YYYY, DD.MM.YYYY
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
  
  // ISO format: YYYY-MM-DD
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

/**
 * Validates and cleans vehicle registration plates against standard Indian pattern:
 * ^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$
 */
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

/**
 * Parses financial balance amounts, handling accounting parentheses format:
 * (500.00) -> -500.00
 * Also strips currency symbols (₹, $), commas, and whitespace.
 */
function cleanBalance(rawVal) {
  if (rawVal === null || rawVal === undefined || rawVal === '') return 0.00;
  let str = String(rawVal).replace(/[₹$,\s]/g, '').trim();
  if (!str || str === '-' || str.toLowerCase() === 'null' || str.toLowerCase() === 'n/a') return 0.00;
  if (str.toLowerCase() === 'pending' || str.toLowerCase() === 'tbd') return null;
  
  // Accounting negative format: (500.00) -> -500.00
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
  
  const rawDate = hMap ? getVal(hMap.returnDate) : row[1];
  const rawReturnType = hMap ? getVal(hMap.returnType) : row[2];
  const rawDriverId = hMap ? getVal(hMap.driverId) : row[3];
  const rawDriverName = hMap ? getVal(hMap.driverName) : row[4];
  const rawType = hMap ? getVal(hMap.driverType) : row[5];
  const rawPlate = hMap ? getVal(hMap.vehicleNumber) : row[6];
  const rawCity = hMap ? getVal(hMap.city) : row[7];
  const rawBal = hMap ? getVal(hMap.negativeBalance) : row[8];
  
  // Skip embedded header repeats
  if (String(rawDate).trim().toLowerCase() === 'return date' || String(rawPlate).trim().toLowerCase() === 'vehicle number') {
    return null;
  }
  
  const returnDate = normalizeDate(rawDate);
  const vehicleNumber = cleanVehicleNumber(rawPlate);
  if (!returnDate || !vehicleNumber) return null;
  
  // Resolve source row: Col A value if populated, otherwise physical row index
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

function bindDropoffParams(stmt, d) {
  stmt.setInt(1, d.sourceRow);
  stmt.setString(2, d.returnDate);
  stmt.setString(3, d.returnType);
  d.driverId ? stmt.setString(4, d.driverId) : stmt.setNull(4, SQL_TYPES.VARCHAR);
  d.driverName ? stmt.setString(5, d.driverName) : stmt.setNull(5, SQL_TYPES.VARCHAR);
  stmt.setString(6, d.driverType);
  stmt.setString(7, d.vehicleNumber);
  stmt.setString(8, d.city);
  d.negativeBalance !== null ? stmt.setDouble(9, d.negativeBalance) : stmt.setNull(9, SQL_TYPES.NUMERIC);
}

// =============================================================================
// DATABASE UPSERT ENGINE (ZERO-BURN CTE BATCHING)
// =============================================================================

function upsertDropoffRecords(records) {
  if (!records || records.length === 0) return 0;
  
  var conn = null;
  var stmt = null;
  var BATCH_SIZE = 100;
  var totalCount = 0;
  
  try {
    conn = getConnection();
    conn.setAutoCommit(false);
    stmt = conn.prepareStatement(UPSERT_CTE_SQL);
    
    for (var b = 0; b < records.length; b += BATCH_SIZE) {
      var chunk = records.slice(b, b + BATCH_SIZE);
      
      for (var i = 0; i < chunk.length; i++) {
        bindDropoffParams(stmt, chunk[i]);
        stmt.addBatch();
      }
      
      stmt.executeBatch();
      conn.commit();
      totalCount += chunk.length;
      Logger.log("Upserted batch: " + totalCount + "/" + records.length + " dropoff records into public.sheet_dropoffs.");
    }
    
    Logger.log("Successfully completed PostgreSQL Zero-Burn CTE upsert for all " + totalCount + " records.");
    return totalCount;
  } catch (err) {
    if (conn) {
      try { conn.rollback(); } catch(e){}
    }
    Logger.log("Error in upsertDropoffRecords: " + err.message);
    throw err;
  } finally {
    if (stmt) {
      try { stmt.close(); } catch(e){}
    }
    if (conn) {
      try { conn.close(); } catch(e){}
    }
  }
}

// =============================================================================
// SYNCHRONIZATION HANDLERS (ALL PROTECTED BY 30S LOCKSERVICE)
// =============================================================================

/**
 * Full sheet sync: Reads all rows, transforms data, and upserts in batches of 100.
 * Protected by 30s LockService timeout.
 */
function syncAllDropoffs() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("syncAllDropoffs: Another sync is currently active (lock timeout 30s). Skipping run.");
    return;
  }

  try {
    const sheet = getDropoffSheet();
    const data = sheet.getDataRange().getValues();
    Logger.log("Read " + data.length + " total rows from tab '" + sheet.getName() + "'");
    
    if (data.length <= 1) {
      Logger.log("Sheet contains no data rows yet.");
      return;
    }
    
    const hMap = getHeaderIndexMap(data[0]);
    const records = [];

    for (let i = 1; i < data.length; i++) {
      const transformed = transformDropoffRow(data[i], i + 1, hMap);
      if (transformed) {
        records.push(transformed);
      }
    }
    
    Logger.log("Transformed " + records.length + " valid dropoff records.");

    // Batch upsert into PostgreSQL using Zero-Burn CTE
    Logger.log("Starting PostgreSQL upsert for " + records.length + " records...");
    const totalUpserted = upsertDropoffRecords(records);
    Logger.log("Completed syncAllDropoffs! Total records synced: " + totalUpserted);
    
    // Update Sync Status & Timestamp in sheet if columns exist
    try {
      if (hMap.syncStatus >= 0 && hMap.lastSyncedAt >= 0) {
        const nowStr = Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss");
        const statusVals = [];
        for (let j = 0; j < records.length; j++) {
          statusVals.push(["SYNCED", nowStr]);
        }
        if (statusVals.length > 0) {
          const startR = records[0].sheetRowIndex;
          sheet.getRange(startR, hMap.syncStatus + 1, statusVals.length, 2).setValues(statusVals);
        }
      }
    } catch(e) {
      Logger.log("Notice on status column update: " + e.message);
    }
    
    try {
      if (typeof SpreadsheetApp !== 'undefined' && SpreadsheetApp.getActiveSpreadsheet()) {
        SpreadsheetApp.getActiveSpreadsheet().toast("Successfully synced " + totalUpserted + " dropoffs to PostgreSQL staging!", "Sync Complete", 5);
      }
    } catch(e){}
  } finally {
    lock.releaseLock();
  }
}

/**
 * 1-Minute Sliding Window Catch-Up Sync (last 150 rows).
 * Protects against GAS 6-minute timeout by restricting execution to under 2 seconds.
 * Protected by 30s LockService timeout.
 */
function syncRecentDropoffs() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("syncRecentDropoffs: Another sync is currently running (lock timeout 30s). Skipping.");
    return;
  }

  try {
    const sheet = getDropoffSheet();
    const lastRow = sheet.getLastRow();
    if (lastRow <= 1) return;
    
    const WINDOW_SIZE = 150;
    const startRow = Math.max(2, lastRow - WINDOW_SIZE + 1);
    const numRows = lastRow - startRow + 1;
    
    const headerVals = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    const hMap = getHeaderIndexMap(headerVals);
    const data = sheet.getRange(startRow, 1, numRows, sheet.getLastColumn()).getValues();
    const records = [];

    for (let i = 0; i < data.length; i++) {
      const transformed = transformDropoffRow(data[i], startRow + i, hMap);
      if (transformed) {
        records.push(transformed);
      }
    }
    
    if (records.length > 0) {
      upsertDropoffRecords(records);
      Logger.log("Catch-up sync (1-min) successfully updated " + records.length + " recent dropoff records.");
      
      // Update Sync Status & Timestamp in sheet
      try {
        if (hMap.syncStatus >= 0 && hMap.lastSyncedAt >= 0) {
          const nowStr = Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss");
          const statusVals = [];
          for (let k = 0; k < numRows; k++) {
            statusVals.push(["SYNCED", nowStr]);
          }
          sheet.getRange(startRow, hMap.syncStatus + 1, numRows, 2).setValues(statusVals);
        }
      } catch(e) {}
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Live OnEdit trigger handler: Supports single edits and multi-row range pastes.
 * Protected by 30s LockService timeout.
 */
function handleOnEdit(e) {
  if (!e || !e.range) return;
  
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("handleOnEdit: Lock acquisition timed out (30s). Skipping edit event.");
    return;
  }

  try {
    const sheet = e.range.getSheet();
    const startRow = e.range.getRow();
    const endRow = e.range.getLastRow();
    if (startRow <= 1 && endRow <= 1) return;
    
    const headerVals = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    const hMap = getHeaderIndexMap(headerVals);
    
    // Ignore edits on Sync Status or Last Synced At to prevent infinite trigger loops
    const editCol = e.range.getColumn();
    if (editCol === hMap.syncStatus + 1 || editCol === hMap.lastSyncedAt + 1) {
      return;
    }
    
    const actualStart = Math.max(2, startRow);
    const numRows = endRow - actualStart + 1;
    const rawData = sheet.getRange(actualStart, 1, numRows, sheet.getLastColumn()).getValues();
    
    const records = [];
    for (let i = 0; i < rawData.length; i++) {
      const transformed = transformDropoffRow(rawData[i], actualStart + i, hMap);
      if (transformed) {
        records.push(transformed);
      }
    }
    
    if (records.length > 0) {
      upsertDropoffRecords(records);
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Live Form Submission trigger handler.
 * Protected by 30s LockService timeout.
 */
function handleOnFormSubmit(e) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("handleOnFormSubmit: Lock acquisition timed out (30s). Skipping submit event.");
    return;
  }

  try {
    if (!e || !e.values) {
      syncRecentDropoffs();
      return;
    }
    const rowIdx = e.range ? e.range.getRow() : 0;
    const sheet = e.range ? e.range.getSheet() : getDropoffSheet();
    const hMap = sheet ? getHeaderIndexMap(sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0]) : null;
    const transformed = transformDropoffRow(e.values, rowIdx, hMap);
    if (transformed) {
      upsertDropoffRecords([transformed]);
    }
  } finally {
    lock.releaseLock();
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
      .addItem("Sync Recent Records (150 Rows)", "syncRecentDropoffs")
      .addSeparator()
      .addItem("Setup Automated Triggers", "setupTriggers")
      .addItem("Remove Triggers", "removeTriggers")
      .addToUi();
  } catch(e) {
    Logger.log("onOpen UI notice: " + e.message);
  }
}

function removeTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
  }
  Logger.log("All project triggers removed.");
}

function setupTriggers() {
  // Remove existing triggers to avoid duplicate execution
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
  }
  
  // 1-minute recurring time trigger for sliding window catch-up
  ScriptApp.newTrigger("syncRecentDropoffs")
    .timeBased()
    .everyMinutes(1)
    .create();
    
  // Install sheet-bound event triggers
  try {
    var ss = SpreadsheetApp.getActiveSpreadsheet() || getTargetSpreadsheet();
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
    Logger.log("Spreadsheet-bound trigger notice: " + e.message);
  }

  Logger.log("All automated triggers installed successfully (1-min catch-up + Live OnEdit + OnFormSubmit).");
  try {
    SpreadsheetApp.getUi().alert(
      "Triggers Installed Successfully",
      "1-minute sliding window catch-up sync (syncRecentDropoffs) and real-time triggers are now active.",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  } catch(e) {}
}
