/**
 * ==============================================================================
 * LETZRYD MAINTENANCE ENGINE - GOOGLE APPS SCRIPT LIVE PIPELINE
 * ==============================================================================
 * Target Table  : public.sheet_maintenance
 * Secondary     : public.sheet_vehicle_status (attendance log sync)
 * Master Target : public.core_maintenance
 * Host          : YOUR_DB_HOST_HERE:5432
 *
 * Key Capabilities:
 *  - Real-time event extraction on cell edit (handleOnEdit) and form submit (handleOnFormSubmit)
 *  - Automated sliding window synchronization (syncRecentMaintenance)
 *  - Full historical batch ingestion (syncAllMaintenance)
 *  - Comprehensive standardization engine:
 *      * Vehicle registration regex normalization and validation
 *      * Placeholder stripping for workshop names ('-', 'NA', 'Local Workshop', etc.)
 *      * Job card sanitization and nullification of placeholder markers
 *      * Driver retention preservation for IP operator fleets
 *      * Multi-format date parsing (DD/MM/YYYY, ISO, Excel serial floats)
 *      * Canonical city normalization with state license plate fallback
 *  - High-throughput parameterized JDBC batching with transaction rollback protection
 *  - Dual ingestion: populates PostgreSQL and local standardized spreadsheet tab
 *  - Complete connection leak prevention (try-catch-finally with conn.close())
 *  - Automated trigger management (setupTriggers, removeTriggers)
 *  - Custom spreadsheet UI menu with operational controls
 * ==============================================================================
 */

// ------------------------------------------------------------------------------
// 1. CONFIGURATION & SCRIPT PROPERTIES
// ------------------------------------------------------------------------------
var CONFIG = {
  db: {
    host: "YOUR_DB_HOST_HERE",
    port: "5432",
    name: "postgres",
    user: "postgres",
    password: "YOUR_DB_PASSWORD_HERE"
  },
  sheets: {
    sourceSpreadsheetUrl: "", // Leave blank to bind to active spreadsheet
    sourceSheetName: "Daily Status", // Upstream vehicle tracker sheet tab
    targetSheetName: "sheet_maintenance" // Local standardized mirror tab
  },
  batchSize: 200,
  recentWindowRows: 300
};

var CITY_MAPPINGS = {
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
  "chennai": "Chennai",
  "kol": "Kolkata",
  "kolkata": "Kolkata"
};

var WORKSHOP_PLACEHOLDERS = [
  "", "-", "--", "---", "NA", "N/A", "NONE", "NULL", "NIL", "LOCAL",
  "LOCAL WORKSHOP", "TBD", ".", "..", "UNKNOWN", "NO", "NOT APPLICABLE",
  "YARD", "IN YARD", "HUB", "PARKING"
];

var JOBCARD_PLACEHOLDERS = [
  "", "-", "--", "---", "NA", "N/A", "NONE", "NULL", "NIL", "PENDING",
  "TBD", ".", "..", "NO", "NOT GENERATED", "AWAITING", "UNKNOWN"
];

var STATUS_MAINTENANCE_VALUES = [
  "MAINTENANCE", "WORKSHOP", "ACCIDENTAL", "BD", "BREAKDOWN",
  "UNDER REPAIR", "REPAIR", "SERVICE"
];

// ------------------------------------------------------------------------------
// 2. DATABASE CONNECTION & SCRIPT PROPERTIES
// ------------------------------------------------------------------------------
function getDbConnection() {
  var host = CONFIG.db.host;
  var port = CONFIG.db.port;
  var name = CONFIG.db.name;
  var user = CONFIG.db.user;
  var password = CONFIG.db.password;

  try {
    var props = PropertiesService.getScriptProperties();
    if (props) {
      host = props.getProperty("DB_HOST") || host;
      port = props.getProperty("DB_PORT") || port;
      name = props.getProperty("DB_NAME") || name;
      user = props.getProperty("DB_USER") || user;
      password = props.getProperty("DB_PASSWORD") || password;
    }
  } catch (err) {
    Logger.log("[WARN] Could not retrieve Script Properties: " + err.message);
  }

  var jdbcUrl = "jdbc:postgresql://" + host + ":" + port + "/" + name;
  return Jdbc.getConnection(jdbcUrl, user, password);
}

function setupScriptProperties(host, port, dbName, user, password) {
  var props = PropertiesService.getScriptProperties();
  props.setProperties({
    "DB_HOST": host || CONFIG.db.host,
    "DB_PORT": port || CONFIG.db.port,
    "DB_NAME": dbName || CONFIG.db.name,
    "DB_USER": user || CONFIG.db.user,
    "DB_PASSWORD": password || CONFIG.db.password
  });
  Logger.log("[SUCCESS] Script Properties configured successfully.");
}

function testDatabaseConnection() {
  var conn = null;
  try {
    conn = getDbConnection();
    var stmt = conn.createStatement();
    var rs = stmt.executeQuery("SELECT version();");
    if (rs.next()) {
      var ver = rs.getString(1);
      Logger.log("[SUCCESS] PostgreSQL Connected: " + ver);
      if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getActiveSpreadsheet()) {
        SpreadsheetApp.getUi().alert("Database Connected Successfully!\n\n" + ver);
      }
    }
    rs.close();
    stmt.close();
  } catch (err) {
    Logger.log("[ERROR] Connection failed: " + err.message);
    if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getActiveSpreadsheet()) {
      SpreadsheetApp.getUi().alert("Database Connection Failed:\n\n" + err.message);
    }
  } finally {
    if (conn) {
      try { conn.close(); } catch (e) {}
    }
  }
}

// ------------------------------------------------------------------------------
// 3. DATA NORMALIZATION & STANDARDIZATION FUNCTIONS
// ------------------------------------------------------------------------------

/**
 * Normalizes Indian vehicle registration plates (e.g. 'ka-01-ab-1234' -> 'KA01AB1234')
 */
function cleanVehicleNumber(reg) {
  if (!reg) return null;
  var str = String(reg).toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (str.length < 6 || str.length > 15) {
    return null;
  }
  return str;
}

/**
 * Normalizes city names with state plate fallback
 */
function cleanCity(rawCity, vehicleNumber) {
  if (rawCity) {
    var key = String(rawCity).trim().toLowerCase();
    if (CITY_MAPPINGS[key]) {
      return CITY_MAPPINGS[key];
    }
    if (key.length > 1 && !WORKSHOP_PLACEHOLDERS.includes(key.toUpperCase())) {
      return key.charAt(0).toUpperCase() + key.slice(1);
    }
  }

  // Registration prefix heuristic fallback
  if (vehicleNumber) {
    var v = vehicleNumber.toUpperCase();
    if (v.indexOf("KA") === 0) return "Bengaluru";
    if (v.indexOf("TS") === 0 || v.indexOf("TG") === 0) return "Hyderabad";
    if (v.indexOf("MH") === 0) return "Mumbai";
    if (v.indexOf("DL") === 0) return "Delhi";
    if (v.indexOf("TN") === 0) return "Chennai";
    if (v.indexOf("WB") === 0) return "Kolkata";
  }

  return "Unknown";
}

/**
 * Parses multiple date representations: Date objects, ISO strings, DD/MM/YYYY, and Excel serial floats
 */
function parseDate(dateVal) {
  if (!dateVal) return null;

  if (dateVal instanceof Date) {
    if (isNaN(dateVal.getTime())) return null;
    return Utilities.formatDate(dateVal, "Asia/Kolkata", "yyyy-MM-dd");
  }

  var str = String(dateVal).trim();
  if (!str) return null;

  // Numeric Excel serial date (e.g. 45658)
  if (/^\d+(\.\d+)?$/.test(str)) {
    var serial = parseFloat(str);
    if (serial > 30000 && serial < 60000) {
      var epoch = new Date(Date.UTC(1899, 11, 30));
      var ms = Math.round(serial * 86400000);
      var d = new Date(epoch.getTime() + ms);
      return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
    }
  }

  // ISO format: YYYY-MM-DD
  if (/^\d{4}-\d{2}-\d{2}/.test(str)) {
    return str.substring(0, 10);
  }

  // Indian format: DD/MM/YYYY or DD-MM-YYYY
  var parts = str.split(/[\/\-\.]/);
  if (parts.length >= 3) {
    var p0 = parseInt(parts[0], 10);
    var p1 = parseInt(parts[1], 10);
    var p2 = parseInt(parts[2], 10);

    if (p2 < 100) p2 += 2000;

    // Check if DD/MM/YYYY or YYYY/MM/DD
    if (p0 > 1900 && p1 >= 1 && p1 <= 12 && p2 >= 1 && p2 <= 31) {
      var yyyy = String(p0);
      var mm = p1 < 10 ? "0" + p1 : String(p1);
      var dd = p2 < 10 ? "0" + p2 : String(p2);
      return yyyy + "-" + mm + "-" + dd;
    } else if (p2 > 1900 && p1 >= 1 && p1 <= 12 && p0 >= 1 && p0 <= 31) {
      var yyyy = String(p2);
      var mm = p1 < 10 ? "0" + p1 : String(p1);
      var dd = p0 < 10 ? "0" + p0 : String(p0);
      return yyyy + "-" + mm + "-" + dd;
    }
  }

  var fallback = new Date(str);
  if (!isNaN(fallback.getTime())) {
    return Utilities.formatDate(fallback, "Asia/Kolkata", "yyyy-MM-dd");
  }

  return null;
}

/**
 * Strips placeholder strings from workshop names
 */
function cleanWorkshopName(rawWorkshop) {
  if (!rawWorkshop) return null;
  var str = String(rawWorkshop).trim();
  var upper = str.toUpperCase();
  if (WORKSHOP_PLACEHOLDERS.indexOf(upper) !== -1) {
    return null;
  }
  return str.length > 150 ? str.substring(0, 150) : str;
}

/**
 * Strips placeholders from job card numbers
 */
function cleanJobCardNumber(rawJobCard) {
  if (!rawJobCard) return null;
  var str = String(rawJobCard).trim();
  var upper = str.toUpperCase();
  if (JOBCARD_PLACEHOLDERS.indexOf(upper) !== -1) {
    return null;
  }
  return str.length > 100 ? str.substring(0, 100) : str;
}

/**
 * Cleans maintenance description / remarks
 */
function cleanMaintenanceReason(rawReason) {
  if (!rawReason) return null;
  var str = String(rawReason).trim();
  if (WORKSHOP_PLACEHOLDERS.indexOf(str.toUpperCase()) !== -1) {
    return null;
  }
  return str.replace(/\s+/g, " ");
}

/**
 * Sanitizes Partner ID. Preserves IP operator IDs while nullifying individual driver placeholders
 */
function cleanPartnerId(rawPartnerId) {
  if (!rawPartnerId) return null;
  var str = String(rawPartnerId).trim().toUpperCase();
  if (WORKSHOP_PLACEHOLDERS.indexOf(str) !== -1) {
    return null;
  }
  return str.length > 50 ? str.substring(0, 50) : str;
}

/**
 * Sanitizes Duty Manager / Fleet Manager POC name
 */
function cleanDmName(rawDm) {
  if (!rawDm) return null;
  var str = String(rawDm).trim();
  if (WORKSHOP_PLACEHOLDERS.indexOf(str.toUpperCase()) !== -1) {
    return null;
  }
  return str.length > 100 ? str.substring(0, 100) : str;
}

/**
 * Standardizes vehicle model name
 */
function cleanVehicleModel(rawModel) {
  if (!rawModel) return null;
  var str = String(rawModel).trim();
  if (WORKSHOP_PLACEHOLDERS.indexOf(str.toUpperCase()) !== -1) {
    return null;
  }
  return str.length > 100 ? str.substring(0, 100) : str;
}

/**
 * Evaluates whether a sheet row qualifies as maintenance downtime
 */
function isMaintenanceDowntime(finalStatus, cohort) {
  var statusUpper = finalStatus ? String(finalStatus).trim().toUpperCase() : "";
  var cohortUpper = cohort ? String(cohort).trim().toUpperCase() : "";

  for (var i = 0; i < STATUS_MAINTENANCE_VALUES.length; i++) {
    if (statusUpper === STATUS_MAINTENANCE_VALUES[i]) {
      return true;
    }
  }

  if (cohortUpper === "OFF ROAD") {
    return true;
  }

  return false;
}

// ------------------------------------------------------------------------------
// 4. DATABASE INGESTION & BATCH UPSERT ENGINE
// ------------------------------------------------------------------------------

/**
 * Standardizes a raw sheet row into a structured maintenance record object
 */
function transformRowToMaintenanceRecord(row, headerMap, rowNumber) {
  var finalStatus = headerMap.final_status !== undefined ? row[headerMap.final_status] : "";
  var cohort = headerMap.cohort !== undefined ? row[headerMap.cohort] : "";

  if (!isMaintenanceDowntime(finalStatus, cohort)) {
    return null;
  }

  var rawVehicle = headerMap.vehicle_number !== undefined ? row[headerMap.vehicle_number] : "";
  var cleanVeh = cleanVehicleNumber(rawVehicle);
  if (!cleanVeh) {
    return null;
  }

  var rawDate = headerMap.date !== undefined ? row[headerMap.date] : "";
  var maintDate = parseDate(rawDate);
  if (!maintDate) {
    return null;
  }

  var rawCity = headerMap.city !== undefined ? row[headerMap.city] : "";
  var city = cleanCity(rawCity, cleanVeh);

  var rawWorkshop = headerMap.workshop_name !== undefined ? row[headerMap.workshop_name] : "";
  var workshop = cleanWorkshopName(rawWorkshop);

  var rawJobCard = headerMap.job_card_number !== undefined ? row[headerMap.job_card_number] : "";
  var jobCard = cleanJobCardNumber(rawJobCard);

  var rawReason = headerMap.maintenance_reason !== undefined ? row[headerMap.maintenance_reason] : "";
  var reason = cleanMaintenanceReason(rawReason);

  var rawPartner = headerMap.partner_id !== undefined ? row[headerMap.partner_id] : "";
  var partnerId = cleanPartnerId(rawPartner);

  var rawDm = headerMap.dm_name !== undefined ? row[headerMap.dm_name] : "";
  var dm = cleanDmName(rawDm);

  var rawModel = headerMap.vehicle_model !== undefined ? row[headerMap.vehicle_model] : "";
  var model = cleanVehicleModel(rawModel);

  var sheetStatusId = headerMap.sheet_status_id !== undefined && row[headerMap.sheet_status_id] 
    ? parseInt(row[headerMap.sheet_status_id], 10) 
    : null;

  return {
    vehicle_number: cleanVeh,
    city: city,
    maintenance_date: maintDate,
    workshop_name: workshop,
    job_card_number: jobCard,
    maintenance_reason: reason,
    cohort: "Off Road",
    partner_id: partnerId,
    dm_name: dm,
    vehicle_model: model,
    sheet_status_id: isNaN(sheetStatusId) ? null : sheetStatusId,
    sheet_row_number: rowNumber
  };
}

/**
 * Builds header index lookup map from header row
 */
function buildHeaderMap(headers) {
  var map = {};
  for (var i = 0; i < headers.length; i++) {
    var h = String(headers[i] || "").trim().toLowerCase().replace(/[\s\_\-\.]/g, "");
    
    if (h.indexOf("vehicleno") !== -1 || h.indexOf("vehiclenum") !== -1 || h === "regno" || h === "vehicle") {
      map.vehicle_number = i;
    } else if (h === "date" || h === "statusdate" || h === "maintenancedate" || h === "timestamp") {
      map.date = i;
    } else if (h === "city" || h === "location" || h === "hubcity") {
      map.city = i;
    } else if (h === "finalstatus" || h === "status" || h === "operationalstatus") {
      map.final_status = i;
    } else if (h === "cohort") {
      map.cohort = i;
    } else if (h.indexOf("workshop") !== -1 || h.indexOf("vendor") !== -1 || h === "garage") {
      map.workshop_name = i;
    } else if (h.indexOf("jobcard") !== -1 || h.indexOf("jcnumber") !== -1 || h === "jc") {
      map.job_card_number = i;
    } else if (h.indexOf("reason") !== -1 || h.indexOf("remarks") !== -1 || h.indexOf("issue") !== -1 || h.indexOf("workdone") !== -1) {
      map.maintenance_reason = i;
    } else if (h.indexOf("partnerid") !== -1 || h.indexOf("driverid") !== -1 || h === "driverlid") {
      map.partner_id = i;
    } else if (h.indexOf("dm") !== -1 || h.indexOf("dutymanager") !== -1 || h.indexOf("manager") !== -1 || h === "poc") {
      map.dm_name = i;
    } else if (h.indexOf("model") !== -1 || h.indexOf("carmodel") !== -1) {
      map.vehicle_model = i;
    } else if (h === "id" || h === "sheetstatusid") {
      map.sheet_status_id = i;
    }
  }
  return map;
}

/**
 * Executes high-performance parameterized JDBC batch upsert into public.sheet_maintenance
 */
function upsertMaintenanceBatch(conn, records) {
  if (!records || records.length === 0) return 0;

  var sql = 
    "INSERT INTO public.sheet_maintenance (" +
    "  vehicle_number, city, maintenance_date, workshop_name, job_card_number, " +
    "  maintenance_reason, cohort, partner_id, dm_name, vehicle_model, " +
    "  sheet_status_id, sheet_row_number, created_at, updated_at" +
    ") VALUES (?, ?, ?::DATE, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) " +
    "ON CONFLICT (maintenance_date, vehicle_number) DO UPDATE SET " +
    "  city = EXCLUDED.city, " +
    "  workshop_name = COALESCE(EXCLUDED.workshop_name, public.sheet_maintenance.workshop_name), " +
    "  job_card_number = COALESCE(EXCLUDED.job_card_number, public.sheet_maintenance.job_card_number), " +
    "  maintenance_reason = COALESCE(EXCLUDED.maintenance_reason, public.sheet_maintenance.maintenance_reason), " +
    "  cohort = EXCLUDED.cohort, " +
    "  partner_id = EXCLUDED.partner_id, " +
    "  dm_name = COALESCE(EXCLUDED.dm_name, public.sheet_maintenance.dm_name), " +
    "  vehicle_model = COALESCE(EXCLUDED.vehicle_model, public.sheet_maintenance.vehicle_model), " +
    "  sheet_status_id = EXCLUDED.sheet_status_id, " +
    "  sheet_row_number = EXCLUDED.sheet_row_number, " +
    "  updated_at = CURRENT_TIMESTAMP;";

  var ps = conn.prepareStatement(sql);

  for (var i = 0; i < records.length; i++) {
    var r = records[i];
    ps.setString(1, r.vehicle_number);
    ps.setString(2, r.city);
    ps.setString(3, r.maintenance_date);

    if (r.workshop_name) ps.setString(4, r.workshop_name);
    else ps.setNull(4, java.sql.Types.VARCHAR);

    if (r.job_card_number) ps.setString(5, r.job_card_number);
    else ps.setNull(5, java.sql.Types.VARCHAR);

    if (r.maintenance_reason) ps.setString(6, r.maintenance_reason);
    else ps.setNull(6, java.sql.Types.VARCHAR);

    ps.setString(7, r.cohort);

    if (r.partner_id) ps.setString(8, r.partner_id);
    else ps.setNull(8, java.sql.Types.VARCHAR);

    if (r.dm_name) ps.setString(9, r.dm_name);
    else ps.setNull(9, java.sql.Types.VARCHAR);

    if (r.vehicle_model) ps.setString(10, r.vehicle_model);
    else ps.setNull(10, java.sql.Types.VARCHAR);

    if (r.sheet_status_id !== null) ps.setLong(11, r.sheet_status_id);
    else ps.setNull(11, java.sql.Types.BIGINT);

    if (r.sheet_row_number !== null) ps.setInt(12, r.sheet_row_number);
    else ps.setNull(12, java.sql.Types.INTEGER);

    ps.addBatch();
  }

  var results = ps.executeBatch();
  ps.close();
  return results.length;
}

// ------------------------------------------------------------------------------
// 5. SYNCHRONIZATION RUNNERS: HISTORICAL BATCH & RECENT WINDOW
// ------------------------------------------------------------------------------

/**
 * Full historical extraction from source sheet into public.sheet_maintenance
 */
function syncAllMaintenance() {
  var ss = getSourceSpreadsheet();
  var sheet = getSourceSheet(ss);
  if (!sheet) {
    Logger.log("[ERROR] Source sheet not found.");
    return;
  }

  var data = sheet.getDataRange().getValues();
  if (data.length < 2) {
    Logger.log("[WARN] Sheet is empty or contains only headers.");
    return;
  }

  var headers = data[0];
  var headerMap = buildHeaderMap(headers);
  Logger.log("[INFO] Header mapping: " + JSON.stringify(headerMap));

  var records = [];
  for (var r = 1; r < data.length; r++) {
    var rec = transformRowToMaintenanceRecord(data[r], headerMap, r + 1);
    if (rec) {
      records.push(rec);
    }
  }

  Logger.log("[INFO] Total qualifying maintenance records found: " + records.length);
  if (records.length === 0) {
    Logger.log("[INFO] No maintenance records to ingest.");
    return;
  }

  var conn = null;
  var totalUpserted = 0;

  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);

    var batch = [];
    for (var i = 0; i < records.length; i++) {
      batch.push(records[i]);
      if (batch.length >= CONFIG.batchSize || i === records.length - 1) {
        var count = upsertMaintenanceBatch(conn, batch);
        totalUpserted += count;
        batch = [];
      }
    }

    conn.commit();
    Logger.log("[SUCCESS] syncAllMaintenance committed: " + totalUpserted + " records upserted.");

    // Update local standardized mirror tab if enabled
    mirrorToTargetSheet(ss, records);

    if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getActiveSpreadsheet()) {
      SpreadsheetApp.getActiveSpreadsheet().toast(
        "Successfully synced " + totalUpserted + " maintenance records to PostgreSQL.",
        "Maintenance Sync Complete",
        5
      );
    }
  } catch (err) {
    if (conn) {
      try { conn.rollback(); } catch (e) {}
    }
    Logger.log("[ERROR] syncAllMaintenance failed: " + err.message);
    throw err;
  } finally {
    if (conn) {
      try { conn.close(); } catch (e) {}
    }
  }
}

/**
 * Sliding window catch-up sync (scans latest N rows for fast periodic execution)
 */
function syncRecentMaintenance() {
  var ss = getSourceSpreadsheet();
  var sheet = getSourceSheet(ss);
  if (!sheet) return;

  var lastRow = sheet.getLastRow();
  if (lastRow < 2) return;

  var numRows = Math.min(CONFIG.recentWindowRows, lastRow - 1);
  var startRow = lastRow - numRows + 1;

  var headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var headerMap = buildHeaderMap(headers);
  var data = sheet.getRange(startRow, 1, numRows, sheet.getLastColumn()).getValues();

  var records = [];
  for (var i = 0; i < data.length; i++) {
    var rowNumber = startRow + i;
    var rec = transformRowToMaintenanceRecord(data[i], headerMap, rowNumber);
    if (rec) {
      records.push(rec);
    }
  }

  if (records.length === 0) {
    Logger.log("[INFO] syncRecentMaintenance: No qualifying records in recent window.");
    return;
  }

  var conn = null;
  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    var count = upsertMaintenanceBatch(conn, records);
    conn.commit();
    Logger.log("[SUCCESS] syncRecentMaintenance committed: " + count + " records.");
  } catch (err) {
    if (conn) {
      try { conn.rollback(); } catch (e) {}
    }
    Logger.log("[ERROR] syncRecentMaintenance failed: " + err.message);
  } finally {
    if (conn) {
      try { conn.close(); } catch (e) {}
    }
  }
}

// ------------------------------------------------------------------------------
// 6. REAL-TIME EVENT HANDLERS: ON-EDIT & FORM-SUBMIT
// ------------------------------------------------------------------------------

/**
 * Triggered on cell edits. If edited row matches maintenance criteria, upserts immediately.
 */
function handleOnEdit(e) {
  if (!e || !e.range) return;

  var sheet = e.range.getSheet();
  if (sheet.getName() !== CONFIG.sheets.sourceSheetName) return;

  var rowNumber = e.range.getRow();
  if (rowNumber < 2) return; // Ignore header edits

  var headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var headerMap = buildHeaderMap(headers);
  var rowData = sheet.getRange(rowNumber, 1, 1, sheet.getLastColumn()).getValues()[0];

  var rec = transformRowToMaintenanceRecord(rowData, headerMap, rowNumber);

  var conn = null;
  try {
    conn = getDbConnection();
    conn.setAutoCommit(true);

    if (rec) {
      // Upsert maintenance record
      upsertMaintenanceBatch(conn, [rec]);
      Logger.log("[SUCCESS] handleOnEdit upserted row " + rowNumber + " (" + rec.vehicle_number + ")");
    } else {
      // Row edited away from maintenance: check if a previous maintenance record exists to clean up
      var rawVeh = headerMap.vehicle_number !== undefined ? rowData[headerMap.vehicle_number] : "";
      var cleanVeh = cleanVehicleNumber(rawVeh);
      var rawDate = headerMap.date !== undefined ? rowData[headerMap.date] : "";
      var maintDate = parseDate(rawDate);

      if (cleanVeh && maintDate) {
        var delSql = "DELETE FROM public.sheet_maintenance WHERE vehicle_number = ? AND maintenance_date = ?::DATE;";
        var ps = conn.prepareStatement(delSql);
        ps.setString(1, cleanVeh);
        ps.setString(2, maintDate);
        ps.executeUpdate();
        ps.close();
        Logger.log("[INFO] handleOnEdit removed non-maintenance row " + rowNumber + " (" + cleanVeh + ")");
      }
    }
  } catch (err) {
    Logger.log("[ERROR] handleOnEdit failed on row " + rowNumber + ": " + err.message);
  } finally {
    if (conn) {
      try { conn.close(); } catch (e) {}
    }
  }
}

/**
 * Triggered on form submissions
 */
function handleOnFormSubmit(e) {
  if (!e || !e.range) {
    syncRecentMaintenance();
    return;
  }
  handleOnEdit(e);
}

// ------------------------------------------------------------------------------
// 7. SPREADSHEET GETTERS & LOCAL MIRROR MANAGEMENT
// ------------------------------------------------------------------------------
function getSourceSpreadsheet() {
  if (CONFIG.sheets.sourceSpreadsheetUrl && CONFIG.sheets.sourceSpreadsheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(CONFIG.sheets.sourceSpreadsheetUrl);
    } catch (e) {
      Logger.log("[WARN] openByUrl failed, falling back to active sheet: " + e.message);
    }
  }
  return SpreadsheetApp.getActiveSpreadsheet();
}

function getSourceSheet(ss) {
  if (!ss) return null;
  var sheet = ss.getSheetByName(CONFIG.sheets.sourceSheetName);
  if (!sheet) {
    // Fallback: search for first sheet with matching headers
    var sheets = ss.getSheets();
    for (var i = 0; i < sheets.length; i++) {
      var s = sheets[i];
      if (s.getLastRow() > 0) {
        var h = s.getRange(1, 1, 1, Math.min(s.getLastColumn(), 20)).getValues()[0];
        var map = buildHeaderMap(h);
        if (map.vehicle_number !== undefined && map.final_status !== undefined) {
          return s;
        }
      }
    }
    return ss.getSheets()[0];
  }
  return sheet;
}

/**
 * Populates / refreshes the local mirror tab in the Google Spreadsheet
 */
function mirrorToTargetSheet(ss, records) {
  if (!ss || !CONFIG.sheets.targetSheetName || records.length === 0) return;

  var targetSheet = ss.getSheetByName(CONFIG.sheets.targetSheetName);
  if (!targetSheet) {
    targetSheet = ss.insertSheet(CONFIG.sheets.targetSheetName);
  }

  var headerRow = [
    "Vehicle Number", "City", "Maintenance Date", "Workshop Name",
    "Job Card Number", "Maintenance Reason", "Cohort", "Partner ID",
    "DM Name", "Vehicle Model", "Sheet Status ID", "Sheet Row Number",
    "Last Synced At"
  ];

  targetSheet.clear();
  targetSheet.getRange(1, 1, 1, headerRow.length).setValues([headerRow]);
  targetSheet.getRange(1, 1, 1, headerRow.length).setFontWeight("bold");

  var rows = [];
  var nowStr = Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss");

  for (var i = 0; i < records.length; i++) {
    var r = records[i];
    rows.push([
      r.vehicle_number,
      r.city,
      r.maintenance_date,
      r.workshop_name || "",
      r.job_card_number || "",
      r.maintenance_reason || "",
      r.cohort,
      r.partner_id || "",
      r.dm_name || "",
      r.vehicle_model || "",
      r.sheet_status_id || "",
      r.sheet_row_number || "",
      nowStr
    ]);
  }

  if (rows.length > 0) {
    targetSheet.getRange(2, 1, rows.length, headerRow.length).setValues(rows);
  }
}

// ------------------------------------------------------------------------------
// 8. TRIGGER MANAGEMENT & SPREADSHEET UI MENU
// ------------------------------------------------------------------------------
function setupTriggers() {
  removeTriggers();

  var ss = SpreadsheetApp.getActiveSpreadsheet();

  // Install onEdit trigger
  ScriptApp.newTrigger("handleOnEdit")
    .forSpreadsheet(ss)
    .onEdit()
    .create();

  // Install onFormSubmit trigger
  ScriptApp.newTrigger("handleOnFormSubmit")
    .forSpreadsheet(ss)
    .onFormSubmit()
    .create();

  // Install 5-minute periodic catch-up sync
  ScriptApp.newTrigger("syncRecentMaintenance")
    .timeBased()
    .everyMinutes(5)
    .create();

  Logger.log("[SUCCESS] Installed 3 automated triggers for LetzRyd Maintenance.");
  if (typeof SpreadsheetApp !== "undefined" && SpreadsheetApp.getActiveSpreadsheet()) {
    SpreadsheetApp.getUi().alert("Triggers installed successfully:\n- Real-time onEdit\n- Form submit\n- 5-Minute catch-up sync");
  }
}

function removeTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  var count = 0;
  for (var i = 0; i < triggers.length; i++) {
    var fn = triggers[i].getHandlerFunction();
    if (fn === "handleOnEdit" || fn === "handleOnFormSubmit" || fn === "syncRecentMaintenance" || fn === "syncAllMaintenance") {
      ScriptApp.deleteTrigger(triggers[i]);
      count++;
    }
  }
  Logger.log("[INFO] Removed " + count + " existing maintenance triggers.");
}

function onOpen() {
  var ui = SpreadsheetApp.getUi();
  ui.createMenu("LetzRyd Maintenance")
    .addItem("Sync All Maintenance (Full Batch)", "syncAllMaintenance")
    .addItem("Sync Recent Maintenance (Sliding Window)", "syncRecentMaintenance")
    .addSeparator()
    .addItem("Test Database Connection", "testDatabaseConnection")
    .addItem("Setup Automated Triggers", "setupTriggers")
    .addItem("Remove Automated Triggers", "removeTriggers")
    .addToUi();
}
