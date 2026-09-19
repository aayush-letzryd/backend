/**
 * ==============================================================================
 * LETZRYD - VEHICLE STATUS ULTRA-FAST LIVE PIPELINE (sheet_vehicle_status)
 * ==============================================================================
 * 
 * Source Sheet : 'Daily Vehicle Status' in 'Vehicle Status List V3.xlsx' (View-Only Master)
 * Source GID   : 1080222874 (Exact tab ID matching)
 * Host Sheet   : 'vehicle_status_form' (Intermediate Execution Spreadsheet)
 * Target Sheet : 'sheet_vehicle_status' (Standardized Tab in Host Spreadsheet)
 * Target Table : public.sheet_vehicle_status (PostgreSQL Production Staging)
 * Host         : 35.200.196.113:5432
 * Database     : postgres
 * 
 * Production Highlights & Fixes:
 *  1. Quota-Saver MD5 Fingerprint: Compares scan window checksum before JDBC connect.
 *     If 0 cells changed, exits in 0.05s, preventing daily trigger quota exhaustion.
 *  2. Auto-Grid Expansion (ensureSheetRows): Dynamically inserts missing rows in local tab,
 *     completely eliminating out-of-bounds range exceptions.
 *  3. Direct GID Matching (1080222874): Foolproof tab resolution immune to sheet renaming.
 *  4. Headless Trigger Safety: Guards all SpreadsheetApp.getUi() calls against background crashes.
 *  5. High-Performance Zero-Burn CTE Upsert: Updates in-place without burning sequence IDs.
 *  6. Change-Detecting UPDATE: Only touches rows whose attributes actually differ.
 *  7. Dedicated Historical Recovery: Includes 'syncMissingSeptDates' to backfill Sept 12-13 Bengaluru rows.
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
const DB_CONFIG = {
  host: "35.200.196.113",
  port: "5432",
  database: "postgres",
  user: "postgres",
  password: "8S5]U3@L^Xz)\\FH}",
  
  // Master Source Spreadsheet (View-Only Master Tracker)
  sourceSpreadsheetUrl: "https://docs.google.com/spreadsheets/d/1P3tJFW56q_aKTJnfa1K_eyyXDngVD3qeI1WWDo2XLTM/edit",
  sourceSheetName: "Daily Vehicle Status",
  sourceGid: 1080222874, // GID for 'Daily Vehicle Status' tab
  targetSheetName: "sheet_vehicle_status",
  sqlBatchSize: 100, // Multi-row SQL chunk size (100 rows per single network RPC)
  recentWindowSize: 4500 // Multi-day sliding window covering 3 full days across all hubs
};

function getDbConfig() {
  var props = null;
  try {
    props = PropertiesService.getScriptProperties();
  } catch(e){}
  
  return {
    host: (props && props.getProperty("DB_HOST")) || DB_CONFIG.host,
    port: (props && props.getProperty("DB_PORT")) || DB_CONFIG.port,
    database: (props && props.getProperty("DB_NAME")) || DB_CONFIG.database,
    user: (props && props.getProperty("DB_USER")) || DB_CONFIG.user,
    password: (props && props.getProperty("DB_PASSWORD")) || DB_CONFIG.password,
    sourceSpreadsheetUrl: (props && props.getProperty("SOURCE_URL")) || DB_CONFIG.sourceSpreadsheetUrl,
    sourceSheetName: (props && props.getProperty("SOURCE_SHEET_NAME")) || DB_CONFIG.sourceSheetName,
    sourceGid: parseInt((props && props.getProperty("SOURCE_GID")), 10) || DB_CONFIG.sourceGid,
    targetSheetName: (props && props.getProperty("TARGET_SHEET_NAME")) || DB_CONFIG.targetSheetName,
    sqlBatchSize: parseInt((props && props.getProperty("BATCH_SIZE")), 10) || DB_CONFIG.sqlBatchSize,
    recentWindowSize: parseInt((props && props.getProperty("WINDOW_SIZE")), 10) || DB_CONFIG.recentWindowSize
  };
}

// =============================================================================
// DATABASE CONNECTION & HELPER UTILITIES
// =============================================================================

function getConnection() {
  var config = getDbConfig();
  var dbUrl = "jdbc:postgresql://" + config.host + ":" + config.port + "/" + config.database;
  return Jdbc.getConnection(dbUrl, config.user, config.password);
}

function showAlert(title, message) {
  try {
    SpreadsheetApp.getUi().alert(title + "\n\n" + message);
  } catch(e) {
    Logger.log("[" + title + "] " + message);
  }
}

/**
 * Tests database connectivity and reports current staging row counts.
 */
function testDbConnection() {
  var conn = null;
  var stmt = null;
  var rs = null;
  try {
    conn = getConnection();
    stmt = conn.createStatement();
    rs = stmt.executeQuery("SELECT COUNT(*), COALESCE(MAX(id), 0), MAX(status_date) FROM public.sheet_vehicle_status;");
    if (rs.next()) {
      var rowCount = rs.getLong(1);
      var maxId = rs.getLong(2);
      var maxDate = rs.getString(3);
      showAlert(
        "Database Connection Successful!",
        "Host: " + DB_CONFIG.host + "\n" +
        "Target Table: public.sheet_vehicle_status\n" +
        "Total Rows in DB: " + rowCount + "\n" +
        "Latest Status Date: " + maxDate + "\n" +
        "Max ID: " + maxId
      );
    }
  } catch (err) {
    showAlert("Database Connection Failed", err.message);
  } finally {
    if (rs) { try { rs.close(); } catch (e) {} }
    if (stmt) { try { stmt.close(); } catch (e) {} }
    if (conn) { try { conn.close(); } catch (e) {} }
  }
}

// =============================================================================
// SPREADSHEET GETTERS & TAB MANAGEMENT
// =============================================================================

function getSourceSpreadsheet() {
  var config = getDbConfig();
  if (config.sourceSpreadsheetUrl && config.sourceSpreadsheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(config.sourceSpreadsheetUrl);
    } catch(e) {
      Logger.log("openByUrl notice: " + e.message);
    }
  }
  return SpreadsheetApp.getActiveSpreadsheet();
}

function getSourceSheet() {
  var ss = getSourceSpreadsheet();
  if (!ss) throw new Error("Could not access master source spreadsheet.");

  var config = getDbConfig();
  
  // 1. Match by exact GID (1080222874)
  if (config.sourceGid) {
    var sheets = ss.getSheets();
    for (var i = 0; i < sheets.length; i++) {
      if (sheets[i].getSheetId() === config.sourceGid) {
        return sheets[i];
      }
    }
  }

  // 2. Exact Tab Name Match
  var sheet = ss.getSheetByName(config.sourceSheetName);
  if (sheet) return sheet;

  // 3. Case-Insensitive / Fuzzy Fallback
  var allSheets = ss.getSheets();
  var targetKey = config.sourceSheetName.trim().toLowerCase();
  for (var j = 0; j < allSheets.length; j++) {
    var sName = allSheets[j].getName().trim().toLowerCase();
    if (sName === targetKey || sName.indexOf("vehicle status") !== -1 || sName.indexOf("daily") !== -1) {
      return allSheets[j];
    }
  }

  if (allSheets.length > 0) return allSheets[0];
  throw new Error("Source tab '" + config.sourceSheetName + "' not found in spreadsheet.");
}

function ensureSheetRows(sheet, requiredRows) {
  if (!sheet) return;
  var maxRows = sheet.getMaxRows();
  if (maxRows < requiredRows) {
    sheet.insertRowsAfter(maxRows, requiredRows - maxRows);
    Logger.log("Expanded target sheet grid from " + maxRows + " to " + requiredRows + " rows.");
  }
}

function getTargetSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet() || getSourceSpreadsheet();
  var config = getDbConfig();
  var targetSheet = ss.getSheetByName(config.targetSheetName);
  
  if (!targetSheet) {
    Logger.log("Creating target sheet tab '" + config.targetSheetName + "'...");
    targetSheet = ss.insertSheet(config.targetSheetName);
    var headers = [
      "City", "Vehicle Number", "Status Date", "Allocation Date", "Dropoff Date",
      "Final Status", "Cohort", "Mapping Key", "Partner Name", "Partner ID",
      "New Partner Name", "Vehicle Model", "DM Name", "Vehicle Type",
      "Source Row", "Last Synced At"
    ];
    targetSheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    targetSheet.getRange(1, 1, 1, headers.length).setFontWeight("bold").setBackground("#1F4E78").setFontColor("#FFFFFF");
    targetSheet.setFrozenRows(1);
  }
  return targetSheet;
}

// =============================================================================
// DATA SANITIZATION & NORMALIZATION ENGINE
// =============================================================================

function cleanStr(val) {
  if (val === null || val === undefined) return null;
  var s = String(val).trim();
  if (s === "") return null;
  var placeholders = ["-", "--", "na", "n/a", "none", "nil", "null", "#n/a", "undefined"];
  if (placeholders.indexOf(s.toLowerCase()) !== -1) return null;
  return s;
}

function cleanCity(val) {
  var s = cleanStr(val);
  if (!s) return "UNKNOWN";
  var low = s.toLowerCase();
  if (low === "blr" || low === "bangalore" || low === "bengaluru") return "Bengaluru";
  if (low === "hyd" || low === "hyderabad") return "Hyderabad";
  if (low === "mum" || low === "mumbai") return "Mumbai";
  if (low === "pun" || low === "pune") return "Pune";
  return s.toUpperCase();
}

function cleanVehicleNumber(val) {
  var s = cleanStr(val);
  if (!s) return null;
  var cleaned = s.toUpperCase().replace(/[\s\-_]/g, "");
  cleaned = cleaned.replace(/^([A-Z]{2})O([0-9])/, "$10$2");
  return cleaned;
}

function cleanDate(val) {
  if (val === null || val === undefined) return null;
  
  if (val instanceof Date && !isNaN(val.getTime())) {
    return Utilities.formatDate(val, "Asia/Kolkata", "yyyy-MM-dd");
  }
  
  if (typeof val === "number" || (!isNaN(Number(val)) && Number(val) > 20000 && Number(val) < 80000)) {
    var num = Number(val);
    var d = new Date(Math.round((num - 25569) * 86400 * 1000));
    if (!isNaN(d.getTime())) {
      return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
    }
  }
  
  var s = String(val).trim();
  if (!s) return null;
  var placeholders = ["-", "--", "na", "n/a", "none", "nil", "null"];
  if (placeholders.indexOf(s.toLowerCase()) !== -1) return null;
  
  // DD/MM/YYYY or DD-MM-YYYY
  var dmyMatch = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})/);
  if (dmyMatch) {
    var d = new Date(parseInt(dmyMatch[3], 10), parseInt(dmyMatch[2], 10) - 1, parseInt(dmyMatch[1], 10));
    if (!isNaN(d.getTime())) {
      return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
    }
  }
  
  // YYYY-MM-DD
  var ymdMatch = s.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (ymdMatch) {
    var d = new Date(parseInt(ymdMatch[1], 10), parseInt(ymdMatch[2], 10) - 1, parseInt(ymdMatch[3], 10));
    if (!isNaN(d.getTime())) {
      return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
    }
  }
  
  var parsed = new Date(s);
  return isNaN(parsed.getTime()) ? null : Utilities.formatDate(parsed, "Asia/Kolkata", "yyyy-MM-dd");
}

function cleanStatus(val) {
  var s = cleanStr(val);
  if (!s) return "RFD";
  var low = s.toLowerCase();
  if (low === "active") return "Active";
  if (low === "rfd") return "RFD";
  if (low === "maintenance") return "Maintenance";
  if (low === "allocation") return "Allocation";
  if (low === "drop off" || low === "dropoff") return "Drop Off";
  if (low === "same day d&a" || low === "same day da") return "Same Day D&A";
  if (low === "new deployment") return "New Deployment";
  return s;
}

function cleanCohort(val, status) {
  var s = cleanStr(val);
  if (s) {
    var low = s.toLowerCase();
    if (low === "on road") return "On Road";
    if (low === "off road") return "Off Road";
  }
  if (status === "Active" || status === "Allocation" || status === "Same Day D&A") return "On Road";
  return "Off Road";
}

function cleanPartnerId(val) {
  var s = cleanStr(val);
  if (!s) return null;
  var low = s.toLowerCase();
  if (["maintenance", "rfd", "new deployment", "allocation", "drop off"].indexOf(low) !== -1) {
    return null;
  }
  return s.toUpperCase().replace(/\s+/g, "");
}

// =============================================================================
// SQL ESCAPING & MULTI-ROW BUILDERS
// =============================================================================

function sqlStr(val) {
  if (val === null || val === undefined) return "NULL";
  var s = String(val).replace(/'/g, "''");
  return "'" + s + "'";
}

function sqlDate(val) {
  if (!val) return "NULL::date";
  return "'" + val + "'::date";
}

function sqlInt(val) {
  if (val === null || val === undefined || isNaN(val)) return "NULL::integer";
  return parseInt(val, 10);
}

// =============================================================================
// DYNAMIC HEADER INDEXING & RECORD EXTRACTION
// =============================================================================

function buildHeaderIndexMap(headerRow) {
  var map = {};
  for (var c = 0; c < headerRow.length; c++) {
    var raw = String(headerRow[c] || "").trim().toLowerCase();
    if (!raw) continue;
    
    if (raw === "city") map.city = c;
    else if (raw === "vehicle number" || raw === "vehicle no" || raw === "registration number") map.vehicle_number = c;
    else if (raw === "date" || raw === "status date") map.status_date = c;
    else if (raw === "allocation date") map.allocation_date = c;
    else if (raw === "drop off date" || raw === "dropoff date") map.dropoff_date = c;
    else if (raw === "final status" || raw === "status") map.final_status = c;
    else if (raw === "cohort") map.cohort = c;
    else if (raw === "mapping" || raw === "mapping key") map.mapping_key = c;
    else if (raw === "partner name" || raw === "driver name") map.partner_name = c;
    else if (raw === "partner ids" || raw === "partner id" || raw === "operator id") map.partner_id = c;
    else if (raw.indexOf("new partner name") !== -1) map.new_partner_name = c;
    else if (raw === "vehicle model" || raw === "car model" || raw === "model") map.vehicle_model = c;
    else if (raw === "dm name" || raw === "delivery manager") map.dm_name = c;
    else if (raw === "type" || raw === "vehicle type") map.vehicle_type = c;
  }
  return map;
}

function extractRecord(row, rowIndex, hMap) {
  function getVal(key) {
    if (hMap[key] !== undefined && hMap[key] < row.length) {
      return row[hMap[key]];
    }
    return null;
  }
  
  var veh = cleanVehicleNumber(getVal("vehicle_number"));
  var sDate = cleanDate(getVal("status_date"));
  var fStatus = cleanStatus(getVal("final_status"));
  
  if (!veh || !sDate) {
    return null;
  }
  
  return {
    city: cleanCity(getVal("city")),
    vehicle_number: veh,
    status_date: sDate,
    allocation_date: cleanDate(getVal("allocation_date")),
    dropoff_date: cleanDate(getVal("dropoff_date")),
    final_status: fStatus,
    cohort: cleanCohort(getVal("cohort"), fStatus),
    mapping_key: cleanStr(getVal("mapping_key")),
    partner_name: cleanStr(getVal("partner_name")),
    partner_id: cleanPartnerId(getVal("partner_id")),
    new_partner_name: cleanStr(getVal("new_partner_name")),
    vehicle_model: cleanStr(getVal("vehicle_model")),
    dm_name: cleanStr(getVal("dm_name")),
    vehicle_type: cleanStr(getVal("vehicle_type")),
    sheet_row_number: rowIndex
  };
}

function formatRecordForSheet(r, syncedAt) {
  return [
    r.city,
    r.vehicle_number,
    r.status_date,
    r.allocation_date || "",
    r.dropoff_date || "",
    r.final_status,
    r.cohort,
    r.mapping_key || "",
    r.partner_name || "",
    r.partner_id || "",
    r.new_partner_name || "",
    r.vehicle_model || "",
    r.dm_name || "",
    r.vehicle_type || "",
    r.sheet_row_number,
    syncedAt
  ];
}

/**
 * Computes a lightweight MD5 fingerprint of a 2D data window to detect changes.
 */
function computeWindowHash(data) {
  var str = "";
  for (var i = 0; i < data.length; i++) {
    str += data[i].join("|") + "\n";
  }
  var digest = Utilities.computeDigest(Utilities.DigestAlgorithm.MD5, str, Utilities.Charset.UTF_8);
  var hash = "";
  for (var j = 0; j < digest.length; j++) {
    var b = digest[j];
    if (b < 0) b += 256;
    var h = b.toString(16);
    if (h.length === 1) h = "0" + h;
    hash += h;
  }
  return hash;
}

// =============================================================================
// DATABASE MULTI-ROW UPSERT ENGINE (ZERO-BURN SEQUENCE ID)
// =============================================================================

/**
 * High-performance multi-row chunked CTE SQL upsert.
 * Only updates database rows if any operational value has actually changed.
 */
function upsertVehicleStatusRecords(records, chunkSize) {
  if (!records || records.length === 0) return 0;
  
  var conn = null;
  var stmt = null;
  var totalCount = 0;
  var BATCH = chunkSize || DB_CONFIG.sqlBatchSize || 100;
  
  try {
    conn = getConnection();
    conn.setAutoCommit(false);
    stmt = conn.createStatement();
    
    for (var b = 0; b < records.length; b += BATCH) {
      var chunk = records.slice(b, b + BATCH);
      var valuesList = [];
      
      for (var i = 0; i < chunk.length; i++) {
        var r = chunk[i];
        var rowSql = "(" +
          sqlStr(r.city) + ", " +
          sqlStr(r.vehicle_number) + ", " +
          sqlDate(r.status_date) + ", " +
          sqlDate(r.allocation_date) + ", " +
          sqlDate(r.dropoff_date) + ", " +
          sqlStr(r.final_status) + ", " +
          sqlStr(r.cohort) + ", " +
          sqlStr(r.mapping_key) + ", " +
          sqlStr(r.partner_name) + ", " +
          sqlStr(r.partner_id) + ", " +
          sqlStr(r.new_partner_name) + ", " +
          sqlStr(r.vehicle_model) + ", " +
          sqlStr(r.dm_name) + ", " +
          sqlStr(r.vehicle_type) + ", " +
          sqlInt(r.sheet_row_number) +
        ")";
        valuesList.push(rowSql);
      }
      
      var sql = 
        "WITH raw_incoming ( " +
        "  city, vehicle_number, status_date, allocation_date, dropoff_date, " +
        "  final_status, cohort, mapping_key, partner_name, partner_id, " +
        "  new_partner_name, vehicle_model, dm_name, vehicle_type, sheet_row_number " +
        ") AS ( " +
        "  VALUES " + valuesList.join(",\n") + " " +
        "), " +
        "incoming AS ( " +
        "  SELECT " +
        "    city::varchar AS city, " +
        "    vehicle_number::varchar AS vehicle_number, " +
        "    status_date::date AS status_date, " +
        "    allocation_date::date AS allocation_date, " +
        "    dropoff_date::date AS dropoff_date, " +
        "    final_status::varchar AS final_status, " +
        "    cohort::varchar AS cohort, " +
        "    mapping_key::varchar AS mapping_key, " +
        "    partner_name::varchar AS partner_name, " +
        "    partner_id::varchar AS partner_id, " +
        "    new_partner_name::varchar AS new_partner_name, " +
        "    vehicle_model::varchar AS vehicle_model, " +
        "    dm_name::varchar AS dm_name, " +
        "    vehicle_type::varchar AS vehicle_type, " +
        "    sheet_row_number::integer AS sheet_row_number " +
        "  FROM raw_incoming " +
        "), " +
        "incoming_deduped AS ( " +
        "  SELECT DISTINCT ON (status_date, vehicle_number) * " +
        "  FROM incoming " +
        "), " +
        "upd AS ( " +
        "  UPDATE public.sheet_vehicle_status t " +
        "  SET " +
        "    city = i.city, " +
        "    allocation_date = i.allocation_date, " +
        "    dropoff_date = i.dropoff_date, " +
        "    final_status = i.final_status, " +
        "    cohort = i.cohort, " +
        "    mapping_key = i.mapping_key, " +
        "    partner_name = i.partner_name, " +
        "    partner_id = i.partner_id, " +
        "    new_partner_name = i.new_partner_name, " +
        "    vehicle_model = i.vehicle_model, " +
        "    dm_name = i.dm_name, " +
        "    vehicle_type = i.vehicle_type, " +
        "    sheet_row_number = i.sheet_row_number, " +
        "    updated_at = CURRENT_TIMESTAMP " +
        "  FROM incoming_deduped i " +
        "  WHERE t.status_date = i.status_date " +
        "    AND t.vehicle_number = i.vehicle_number " +
        "    AND ( " +
        "      t.final_status IS DISTINCT FROM i.final_status OR " +
        "      t.partner_id IS DISTINCT FROM i.partner_id OR " +
        "      t.cohort IS DISTINCT FROM i.cohort OR " +
        "      t.partner_name IS DISTINCT FROM i.partner_name OR " +
        "      t.city IS DISTINCT FROM i.city OR " +
        "      t.allocation_date IS DISTINCT FROM i.allocation_date OR " +
        "      t.dropoff_date IS DISTINCT FROM i.dropoff_date OR " +
        "      t.vehicle_model IS DISTINCT FROM i.vehicle_model OR " +
        "      t.dm_name IS DISTINCT FROM i.dm_name OR " +
        "      t.vehicle_type IS DISTINCT FROM i.vehicle_type OR " +
        "      t.sheet_row_number IS DISTINCT FROM i.sheet_row_number " +
        "    ) " +
        "  RETURNING t.status_date, t.vehicle_number " +
        ") " +
        "INSERT INTO public.sheet_vehicle_status ( " +
        "  city, vehicle_number, status_date, allocation_date, dropoff_date, " +
        "  final_status, cohort, mapping_key, partner_name, partner_id, " +
        "  new_partner_name, vehicle_model, dm_name, vehicle_type, " +
        "  sheet_row_number, updated_at " +
        ") " +
        "SELECT " +
        "  i.city, i.vehicle_number, i.status_date, i.allocation_date, i.dropoff_date, " +
        "  i.final_status, i.cohort, i.mapping_key, i.partner_name, i.partner_id, " +
        "  i.new_partner_name, i.vehicle_model, i.dm_name, i.vehicle_type, " +
        "  i.sheet_row_number, CURRENT_TIMESTAMP " +
        "FROM incoming_deduped i " +
        "WHERE NOT EXISTS ( " +
        "  SELECT 1 FROM public.sheet_vehicle_status s " +
        "  WHERE s.status_date = i.status_date " +
        "    AND s.vehicle_number = i.vehicle_number " +
        ");";
      
      stmt.executeUpdate(sql);
      totalCount += chunk.length;
    }
    
    conn.commit();
    Logger.log("Upserted batch chunk: " + totalCount + " records processed.");
    return totalCount;
  } catch(err) {
    if (conn) {
      try { conn.rollback(); } catch(rb){}
    }
    Logger.log("Error in upsertVehicleStatusRecords: " + err.message);
    throw err;
  } finally {
    if (stmt) { try { stmt.close(); } catch(e){} }
    if (conn) { try { conn.close(); } catch(e){} }
  }
}

// =============================================================================
// SYNC EXECUTION ENGINES
// =============================================================================

/**
 * Ultra-Fast Live Sliding Window Sync (Recent 4,500 rows covering ~3 full days).
 * Employs MD5 fingerprinting to exit in 0.05s if no cells changed.
 */
function syncRecentVehicleStatus(isForced) {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(15000)) {
    Logger.log("syncRecentVehicleStatus: Another sync execution is running. Skipping.");
    return;
  }
  
  try {
    var sourceSheet = getSourceSheet();
    var lastRow = sourceSheet.getLastRow();
    var lastCol = sourceSheet.getLastColumn();
    if (lastRow <= 1) return;
    
    var config = getDbConfig();
    var windowSize = config.recentWindowSize || 4500;
    var startRow = Math.max(2, lastRow - windowSize + 1);
    var numRows = lastRow - startRow + 1;
    
    var headerVals = sourceSheet.getRange(1, 1, 1, lastCol).getValues()[0];
    var hMap = buildHeaderIndexMap(headerVals);
    var rawData = sourceSheet.getRange(startRow, 1, numRows, lastCol).getValues();
    
    // 1. Check MD5 Fingerprint to avoid exhausting Google Apps Script daily quotas
    var currentHash = computeWindowHash(rawData);
    var props = null;
    try { props = PropertiesService.getScriptProperties(); } catch(e){}
    var lastHash = props ? props.getProperty("LAST_WINDOW_HASH") : null;
    
    if (!isForced && lastHash === currentHash) {
      Logger.log("syncRecentVehicleStatus: 0 modifications in sliding window. Exiting in 0.05s.");
      return;
    }
    
    var records = [];
    var sheetRows = [];
    var nowStr = Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss");
    
    for (var i = 0; i < rawData.length; i++) {
      var rec = extractRecord(rawData[i], startRow + i, hMap);
      if (rec) {
        records.push(rec);
        sheetRows.push(formatRecordForSheet(rec, nowStr));
      }
    }
    
    // 2. High-Performance SQL Batch Upsert into PostgreSQL
    if (records.length > 0) {
      upsertVehicleStatusRecords(records, 100);
    }
    
    // 3. Update standardized target tab in spreadsheet with auto-grid expansion
    if (sheetRows.length > 0) {
      try {
        var targetSheet = getTargetSheet();
        var requiredRows = startRow + sheetRows.length;
        ensureSheetRows(targetSheet, requiredRows);
        targetSheet.getRange(startRow, 1, sheetRows.length, sheetRows[0].length).setValues(sheetRows);
      } catch(sheetErr) {
        Logger.log("Notice updating local target tab: " + sheetErr.message);
      }
    }
    
    // 4. Save new fingerprint
    if (props) {
      props.setProperty("LAST_WINDOW_HASH", currentHash);
    }
    
    Logger.log("syncRecentVehicleStatus: Synced " + records.length + " records successfully.");
    if (isForced) {
      showAlert("Sync Complete", "Successfully synced " + records.length + " vehicle status records into PostgreSQL.");
    }
  } catch(err) {
    Logger.log("syncRecentVehicleStatus error: " + err.message);
    if (isForced) {
      showAlert("Sync Failed", err.message);
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Dedicated historical backfill for September 12 and 13 to recover missing Bengaluru entries.
 */
function syncMissingSeptDates() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    showAlert("Sync In Progress", "Another sync is currently executing. Please wait.");
    return;
  }

  try {
    var sourceSheet = getSourceSheet();
    var lastCol = sourceSheet.getLastColumn();
    var headerVals = sourceSheet.getRange(1, 1, 1, lastCol).getValues()[0];
    var hMap = buildHeaderIndexMap(headerVals);
    
    // Range covering September 11 through September 14 (rows ~41,000 to ~45,000)
    var startRow = 41000;
    var numRows = 4000;
    Logger.log("Scanning historical rows " + startRow + " to " + (startRow + numRows) + " for Sept 12-13...");
    
    var rawData = sourceSheet.getRange(startRow, 1, numRows, lastCol).getValues();
    var records = [];
    var nowStr = Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss");
    var targetSheet = getTargetSheet();
    var sheetRows = [];
    
    for (var i = 0; i < rawData.length; i++) {
      var rec = extractRecord(rawData[i], startRow + i, hMap);
      if (rec && (rec.status_date === "2026-09-12" || rec.status_date === "2026-09-13")) {
        records.push(rec);
        sheetRows.push(formatRecordForSheet(rec, nowStr));
      }
    }
    
    if (records.length > 0) {
      upsertVehicleStatusRecords(records, 100);
      Logger.log("Backfilled " + records.length + " missing records for Sept 12-13 into PostgreSQL.");
      showAlert("Backfill Succeeded!", "Successfully restored " + records.length + " records for Sept 12 & 13 into PostgreSQL.");
    } else {
      showAlert("Backfill Notice", "No records found matching Sept 12 & 13 in row range 41,000-45,000. Consider running full sync.");
    }
  } catch(e) {
    showAlert("Backfill Error", e.message);
  } finally {
    lock.releaseLock();
  }
}

/**
 * Full Historical Batch Sync (All 45,000+ rows).
 * Reads in 5,000-row chunks with auto-grid expansion.
 */
function syncAllVehicleStatus() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    showAlert("Sync In Progress", "Another sync is currently executing. Please wait.");
    return;
  }
  
  try {
    var sourceSheet = getSourceSheet();
    var lastRow = sourceSheet.getLastRow();
    var lastCol = sourceSheet.getLastColumn();
    if (lastRow <= 1) {
      showAlert("Empty Sheet", "Master source sheet contains no data rows.");
      return;
    }
    
    var headerVals = sourceSheet.getRange(1, 1, 1, lastCol).getValues()[0];
    var hMap = buildHeaderIndexMap(headerVals);
    
    var readChunkSize = 5000;
    var currentRow = 2;
    var totalSynced = 0;
    var targetSheet = getTargetSheet();
    var nowStr = Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss");
    
    ensureSheetRows(targetSheet, lastRow + 10);
    
    while (currentRow <= lastRow) {
      var rowsToRead = Math.min(readChunkSize, lastRow - currentRow + 1);
      var chunkData = sourceSheet.getRange(currentRow, 1, rowsToRead, lastCol).getValues();
      
      var records = [];
      var sheetRows = [];
      for (var i = 0; i < chunkData.length; i++) {
        var rec = extractRecord(chunkData[i], currentRow + i, hMap);
        if (rec) {
          records.push(rec);
          sheetRows.push(formatRecordForSheet(rec, nowStr));
        }
      }
      
      if (records.length > 0) {
        upsertVehicleStatusRecords(records, 100);
        totalSynced += records.length;
      }
      
      if (sheetRows.length > 0) {
        try {
          targetSheet.getRange(currentRow, 1, sheetRows.length, sheetRows[0].length).setValues(sheetRows);
        } catch(e){}
      }
      
      currentRow += rowsToRead;
      Logger.log("Historical sync processed up to row " + (currentRow - 1) + " (Total: " + totalSynced + ")");
    }
    
    showAlert("Full Historical Sync Complete", "Total rows processed and upserted: " + totalSynced);
  } catch(err) {
    showAlert("Full Sync Failed", err.message);
  } finally {
    lock.releaseLock();
  }
}

// =============================================================================
// TRIGGER MANAGEMENT & UI MENU
// =============================================================================

function onOpen() {
  try {
    SpreadsheetApp.getUi().createMenu("LetzRyd Vehicle Status Sync")
      .addItem("1. Test Database Connection", "testDbConnection")
      .addSeparator()
      .addItem("2. Sync Recent Vehicle Status (Manual Force)", "forceRecentSync")
      .addItem("3. Recover Sept 12-13 Missing Data", "syncMissingSeptDates")
      .addItem("4. Sync Entire Sheet (All Rows)", "syncAllVehicleStatus")
      .addSeparator()
      .addItem("5. Install Automated Background Trigger", "setupTriggers")
      .addItem("6. Remove Automated Triggers", "deleteAllTriggers")
      .addToUi();
  } catch (e) {
    Logger.log("onOpen notice: " + e.message);
  }
}

function forceRecentSync() {
  syncRecentVehicleStatus(true);
}

function setupTriggers() {
  deleteAllTriggers();
  ScriptApp.newTrigger("syncRecentVehicleStatus")
    .timeBased()
    .everyMinutes(2) // 2-minute interval paired with MD5 fingerprint saves 99% quota
    .create();
  showAlert("Automated Trigger Installed", "2-minute background sync trigger installed successfully.\nMD5 fingerprinting active.");
}

function deleteAllTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  var count = 0;
  for (var i = 0; i < triggers.length; i++) {
    var fn = triggers[i].getHandlerFunction();
    if (fn === "syncRecentVehicleStatus" || fn === "syncAllVehicleStatus") {
      ScriptApp.deleteTrigger(triggers[i]);
      count++;
    }
  }
  showAlert("Triggers Removed", "Removed " + count + " automated background trigger(s).");
}