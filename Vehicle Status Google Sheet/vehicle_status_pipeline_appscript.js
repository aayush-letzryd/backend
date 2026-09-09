/**
 * ==============================================================================
 * LETZRYD - VEHICLE STATUS DIRECT MASTER SHEET TO POSTGRES LIVE PIPELINE
 * ==============================================================================
 * Target Table   : public.sheet_vehicle_status (PostgreSQL 14+)
 * Source Data    : Vehicle Status List V3 / Master Sheet -> "Daily Vehicle Status"
 * Natural Key    : (status_date, vehicle_number)
 * 
 * Pipeline Features:
 *  1. JDBC Batch Processing (200-row chunks for high throughput and memory efficiency)
 *  2. Concurrency Protection (LockService script lock prevents race conditions)
 *  3. PropertiesService Secret Management (DB credentials safely stored in Script Properties)
 *  4. Zero-Burn Sequence ID CTE Query (prevents sequence ID gaps on updates)
 *  5. Leak-proof JDBC Connection lifecycle (try-catch-finally closing RS, Stmt, Conn)
 *  6. Transaction integrity with conn.rollback() on batch failures
 *  7. Multi-format date sanitization (Excel serial dates, Date objects, string dates)
 *  8. Robust partner ID and status sanitization (unallocated vehicle detection)
 *  9. Dynamic Header Indexing (column position agnostic)
 * 10. Zero emojis across code, logs, and menus
 * ==============================================================================
 */

// Default configuration constants (can be overridden via PropertiesService)
const DEFAULT_CONFIG = {
  dbHost: "YOUR_DB_HOST_HERE",
  dbPort: "5432",
  dbName: "postgres",
  dbUser: "postgres",
  dbPassword: "YOUR_DB_PASSWORD_HERE",
  tabName: "Daily Vehicle Status",
  batchSize: 200
};

// Standard JDBC SQL Type Codes (Apps Script JDBC does not expose java.sql.Types)
const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  TIMESTAMP: 93,
  INTEGER: 4,
  NUMERIC: 2,
  NULL: 0
};

/**
 * Retrieves configuration values from PropertiesService with fallback to DEFAULT_CONFIG.
 * Set script properties via Project Settings -> Script Properties in Apps Script.
 */
function getAppConfig() {
  const props = PropertiesService.getScriptProperties();
  return {
    dbHost: props.getProperty("DB_HOST") || DEFAULT_CONFIG.dbHost,
    dbPort: props.getProperty("DB_PORT") || DEFAULT_CONFIG.dbPort,
    dbName: props.getProperty("DB_NAME") || DEFAULT_CONFIG.dbName,
    dbUser: props.getProperty("DB_USER") || DEFAULT_CONFIG.dbUser,
    dbPassword: props.getProperty("DB_PASSWORD") || DEFAULT_CONFIG.dbPassword,
    tabName: props.getProperty("TAB_NAME") || DEFAULT_CONFIG.tabName,
    batchSize: parseInt(props.getProperty("BATCH_SIZE"), 10) || DEFAULT_CONFIG.batchSize
  };
}

/**
 * Builds custom UI Menu when spreadsheet is opened.
 */
function onOpen() {
  try {
    SpreadsheetApp.getUi().createMenu("LetzRyd Vehicle Status Sync")
      .addItem("1. Test Database Connection", "testDbConnection")
      .addSeparator()
      .addItem("2. Sync Recent Status Rows (500)", "syncRecentVehicleStatus")
      .addItem("3. Sync Entire Sheet (Batch 200)", "syncFullVehicleStatus")
      .addSeparator()
      .addItem("4. Install Automated 5-Min Trigger", "setupTriggers")
      .addItem("5. Remove Automated Triggers", "deleteAllTriggers")
      .addToUi();
  } catch (e) {
    Logger.log("onOpen UI init exception: " + e.message);
  }
}

/**
 * Establishes an authenticated JDBC connection to PostgreSQL.
 */
function getDbConnection() {
  const config = getAppConfig();
  const url = "jdbc:postgresql://" + config.dbHost + ":" + config.dbPort + "/" + config.dbName;
  return Jdbc.getConnection(url, config.dbUser, config.dbPassword);
}

/**
 * Tests database connectivity and reports row counts.
 */
function testDbConnection() {
  let conn = null;
  let stmt = null;
  let rs = null;
  const ui = SpreadsheetApp.getUi();
  try {
    conn = getDbConnection();
    stmt = conn.createStatement();
    rs = stmt.executeQuery("SELECT COUNT(*), COALESCE(MAX(id), 0) FROM public.sheet_vehicle_status;");
    if (rs.next()) {
      const count = rs.getInt(1);
      const maxId = rs.getInt(2);
      ui.alert("Database Connection Successful!\n\nTable: public.sheet_vehicle_status\nTotal Rows: " + count + "\nMax ID: " + maxId);
    }
  } catch (err) {
    ui.alert("Database Connection Failed:\n\n" + err.message);
  } finally {
    if (rs) { try { rs.close(); } catch (e) {} }
    if (stmt) { try { stmt.close(); } catch (e) {} }
    if (conn) { try { conn.close(); } catch (e) {} }
  }
}

// ==============================================================================
// DATA SANITIZATION & NORMALIZATION UTILITIES
// ==============================================================================

/**
 * Basic string trimmer and null placeholder converter.
 */
function cleanStr(val) {
  if (val === null || val === undefined) return null;
  const s = String(val).trim();
  return s !== "" ? s : null;
}

/**
 * Filters out common operational placeholder strings.
 */
function cleanPlaceholder(val) {
  const s = cleanStr(val);
  if (!s) return null;
  const placeholders = ["-", "--", "na", "n/a", "none", "nil", "null", "nan"];
  if (placeholders.indexOf(s.toLowerCase()) !== -1) return null;
  return s;
}

/**
 * Normalizes city strings to standard codes or title case.
 */
function cleanCity(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  const upper = s.toUpperCase();
  if (upper === "BLR" || upper.indexOf("BENG") !== -1 || upper.indexOf("BANG") !== -1) return "BLR";
  if (upper === "MUM" || upper.indexOf("MUMB") !== -1 || upper.indexOf("BOMB") !== -1) return "MUM";
  if (upper === "HYD" || upper.indexOf("HYDE") !== -1) return "HYD";
  return s;
}

/**
 * Normalizes vehicle registration numbers.
 * Cleans whitespace, hyphens, and replaces OCR letter 'O' with digit '0'.
 */
function cleanVehicleNumber(val) {
  const s = cleanStr(val);
  if (!s) return null;
  let cleaned = s.toUpperCase().replace(/[\s\-_]/g, "");
  cleaned = cleaned.replace(/^([A-Z]{2})O([0-9])/, "$10$2");
  return cleaned;
}

/**
 * Normalizes date values from diverse spreadsheet formats:
 * - Date objects
 * - Excel serial date numbers (e.g. 46146 -> 2026-05-04)
 * - String date formats (YYYY-MM-DD, DD-MM-YYYY, DD/MM/YYYY)
 */
function cleanDate(val) {
  if (val === null || val === undefined) return null;
  
  if (val instanceof Date && !isNaN(val.getTime())) {
    return Utilities.formatDate(val, "Asia/Kolkata", "yyyy-MM-dd");
  }
  
  if (typeof val === "number" || (!isNaN(Number(val)) && Number(val) > 20000 && Number(val) < 80000)) {
    const num = Number(val);
    const d = new Date(Math.round((num - 25569) * 86400 * 1000));
    if (!isNaN(d.getTime())) {
      return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
    }
  }
  
  const s = String(val).trim();
  if (!s) return null;
  const placeholders = ["-", "--", "na", "n/a", "none", "nil", "null"];
  if (placeholders.indexOf(s.toLowerCase()) !== -1) return null;
  
  // Pattern: DD-MM-YYYY or DD/MM/YYYY
  const dmyMatch = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})/);
  if (dmyMatch) {
    const d = new Date(parseInt(dmyMatch[3], 10), parseInt(dmyMatch[2], 10) - 1, parseInt(dmyMatch[1], 10));
    if (!isNaN(d.getTime())) {
      return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
    }
  }
  
  // Pattern: YYYY-MM-DD
  const ymdMatch = s.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (ymdMatch) {
    const d = new Date(parseInt(ymdMatch[1], 10), parseInt(ymdMatch[2], 10) - 1, parseInt(ymdMatch[3], 10));
    if (!isNaN(d.getTime())) {
      return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
    }
  }
  
  const parsed = new Date(s);
  return isNaN(parsed.getTime()) ? null : Utilities.formatDate(parsed, "Asia/Kolkata", "yyyy-MM-dd");
}

/**
 * Standardizes operational status strings.
 */
function cleanStatus(val) {
  const s = cleanPlaceholder(val);
  if (!s) return "Unknown";
  const low = s.toLowerCase();
  if (low === "active") return "Active";
  if (low === "rfd") return "RFD";
  if (low === "maintenance") return "Maintenance";
  if (low === "allocation") return "Allocation";
  if (low === "drop off" || low === "dropoff") return "Drop Off";
  if (low === "same day d&a" || low === "same day da") return "Same Day D&A";
  if (low === "new deployment") return "New Deployment";
  return s;
}

/**
 * Standardizes cohort classification.
 */
function cleanCohort(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  const low = s.toLowerCase();
  if (low === "on road") return "On Road";
  if (low === "off road") return "Off Road";
  return s;
}

/**
 * Sanitizes Partner ID.
 * Identifies unallocated vehicles where operators wrote 'Maintenance', 'RFD', or '-'.
 * Removes internal spaces in codes like 'LETZ BLR 8861214022' -> 'LETZBLR8861214022'.
 */
function cleanPartnerId(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  const low = s.toLowerCase();
  if (["maintenance", "rfd", "new deployment", "allocation", "drop off"].indexOf(low) !== -1) {
    return null;
  }
  let cleaned = s.toUpperCase().replace(/\s+/g, "");
  return cleaned;
}

/**
 * Cleans partner name, stripping placeholder dashes and extra whitespace.
 */
function cleanPartnerName(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  return s.replace(/\s+/g, " ").trim();
}

/**
 * Cleans delivery manager name.
 */
function cleanDmName(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  return s.replace(/\s+/g, " ").trim();
}

/**
 * Cleans vehicle operational contract type.
 */
function cleanVehicleType(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  const low = s.toLowerCase();
  if (low === "operator") return "Operator";
  if (low === "individual") return "Individual";
  return s;
}

// ==============================================================================
// DYNAMIC HEADER INDEXING
// ==============================================================================

/**
 * Scans header row to map known logical column names to 0-based column indexes.
 * Ensures pipeline resilience against column additions, deletions, and shifts.
 */
function buildHeaderIndexMap(headerRow) {
  const map = {};
  for (let c = 0; c < headerRow.length; c++) {
    const raw = String(headerRow[c] || "").trim().toLowerCase();
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

/**
 * Extracts and sanitizes a single row of spreadsheet data into a typed record object.
 */
function extractRecord(row, rowIndex, hMap) {
  function getVal(key) {
    if (hMap[key] !== undefined && hMap[key] < row.length) {
      return row[hMap[key]];
    }
    return null;
  }
  
  const veh = cleanVehicleNumber(getVal("vehicle_number"));
  const sDate = cleanDate(getVal("status_date"));
  const fStatus = cleanStatus(getVal("final_status"));
  
  // Mandatory composite natural key validation
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
    cohort: cleanCohort(getVal("cohort")),
    mapping_key: cleanPlaceholder(getVal("mapping_key")),
    partner_name: cleanPartnerName(getVal("partner_name")),
    partner_id: cleanPartnerId(getVal("partner_id")),
    new_partner_name: cleanPlaceholder(getVal("new_partner_name")),
    vehicle_model: cleanPlaceholder(getVal("vehicle_model")),
    dm_name: cleanDmName(getVal("dm_name")),
    vehicle_type: cleanVehicleType(getVal("vehicle_type")),
    sheet_row_number: rowIndex
  };
}

// ==============================================================================
// DATABASE UPSERT SQL (ZERO-BURN CTE SYNTAX)
// ==============================================================================

const UPSERT_SQL = `
WITH incoming AS (
    SELECT 
        CAST(? AS varchar) AS city,
        CAST(? AS varchar) AS vehicle_number,
        CAST(? AS date) AS status_date,
        CAST(? AS date) AS allocation_date,
        CAST(? AS date) AS dropoff_date,
        CAST(? AS varchar) AS final_status,
        CAST(? AS varchar) AS cohort,
        CAST(? AS varchar) AS mapping_key,
        CAST(? AS varchar) AS partner_name,
        CAST(? AS varchar) AS partner_id,
        CAST(? AS varchar) AS new_partner_name,
        CAST(? AS varchar) AS vehicle_model,
        CAST(? AS varchar) AS dm_name,
        CAST(? AS varchar) AS vehicle_type,
        CAST(? AS integer) AS sheet_row_number
),
upd AS (
    UPDATE public.sheet_vehicle_status a
    SET 
        city = i.city,
        allocation_date = i.allocation_date,
        dropoff_date = i.dropoff_date,
        final_status = i.final_status,
        cohort = i.cohort,
        mapping_key = i.mapping_key,
        partner_name = i.partner_name,
        partner_id = i.partner_id,
        new_partner_name = i.new_partner_name,
        vehicle_model = i.vehicle_model,
        dm_name = i.dm_name,
        vehicle_type = i.vehicle_type,
        sheet_row_number = i.sheet_row_number,
        updated_at = CURRENT_TIMESTAMP
    FROM incoming i
    WHERE a.status_date = i.status_date 
      AND a.vehicle_number = i.vehicle_number
    RETURNING a.id
)
INSERT INTO public.sheet_vehicle_status (
    id, city, vehicle_number, status_date, allocation_date, dropoff_date,
    final_status, cohort, mapping_key, partner_name, partner_id,
    new_partner_name, vehicle_model, dm_name, vehicle_type, sheet_row_number,
    created_at, updated_at
)
SELECT 
    nextval('sheet_vehicle_status_id_seq'),
    i.city, i.vehicle_number, i.status_date, i.allocation_date, i.dropoff_date,
    i.final_status, i.cohort, i.mapping_key, i.partner_name, i.partner_id,
    i.new_partner_name, i.vehicle_model, i.dm_name, i.vehicle_type, i.sheet_row_number,
    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
FROM incoming i
WHERE NOT EXISTS (SELECT 1 FROM upd);
`;

/**
 * Binds typed parameters to the PreparedStatement.
 */
function bindVehicleStatusParams(stmt, d) {
  let idx = 1;
  d.city ? stmt.setString(idx++, d.city) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  stmt.setString(idx++, d.vehicle_number);
  stmt.setString(idx++, d.status_date);
  d.allocation_date ? stmt.setString(idx++, d.allocation_date) : stmt.setNull(idx++, SQL_TYPES.DATE);
  d.dropoff_date ? stmt.setString(idx++, d.dropoff_date) : stmt.setNull(idx++, SQL_TYPES.DATE);
  stmt.setString(idx++, d.final_status);
  d.cohort ? stmt.setString(idx++, d.cohort) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.mapping_key ? stmt.setString(idx++, d.mapping_key) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.partner_name ? stmt.setString(idx++, d.partner_name) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.partner_id ? stmt.setString(idx++, d.partner_id) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.new_partner_name ? stmt.setString(idx++, d.new_partner_name) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.vehicle_model ? stmt.setString(idx++, d.vehicle_model) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.dm_name ? stmt.setString(idx++, d.dm_name) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.vehicle_type ? stmt.setString(idx++, d.vehicle_type) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  stmt.setInt(idx++, d.sheet_row_number);
}

// ==============================================================================
// SYNC EXECUTION ENGINES
// ==============================================================================

/**
 * Incremental sync reading the recent 500 rows.
 * Ideal for high-frequency execution via 5-minute automated triggers.
 */
function syncRecentVehicleStatus() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) {
    Logger.log("syncRecentVehicleStatus: Another sync is running. Skipping execution.");
    return;
  }
  
  const config = getAppConfig();
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const sheet = ss.getSheetByName(config.tabName);
    if (!sheet) {
      throw new Error("Tab '" + config.tabName + "' not found in active spreadsheet.");
    }
    
    const lastRow = sheet.getLastRow();
    if (lastRow <= 1) return;
    
    const windowSize = 500;
    const startRow = Math.max(2, lastRow - windowSize + 1);
    const numRows = lastRow - startRow + 1;
    
    const headerVals = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    const hMap = buildHeaderIndexMap(headerVals);
    const dataVals = sheet.getRange(startRow, 1, numRows, sheet.getLastColumn()).getValues();
    
    let conn = null;
    let stmt = null;
    let syncedCount = 0;
    
    try {
      conn = getDbConnection();
      conn.setAutoCommit(false);
      stmt = conn.prepareStatement(UPSERT_SQL);
      
      let batchCount = 0;
      for (let i = 0; i < dataVals.length; i++) {
        const record = extractRecord(dataVals[i], startRow + i, hMap);
        if (!record) continue;
        
        bindVehicleStatusParams(stmt, record);
        stmt.addBatch();
        batchCount++;
        syncedCount++;
        
        if (batchCount >= config.batchSize) {
          stmt.executeBatch();
          conn.commit();
          batchCount = 0;
        }
      }
      
      if (batchCount > 0) {
        stmt.executeBatch();
        conn.commit();
      }
      
      Logger.log("syncRecentVehicleStatus: Successfully processed and committed " + syncedCount + " rows.");
      try {
        SpreadsheetApp.getUi().alert("Recent sync complete! Checked and synced " + syncedCount + " rows to PostgreSQL.");
      } catch (e) {}
    } catch (dbErr) {
      if (conn) {
        try { conn.rollback(); } catch (rbErr) {}
      }
      Logger.log("syncRecentVehicleStatus DB error: " + dbErr.message);
      try {
        SpreadsheetApp.getUi().alert("Sync Failed: " + dbErr.message);
      } catch (e) {}
    } finally {
      if (stmt) { try { stmt.close(); } catch (e) {} }
      if (conn) { try { conn.close(); } catch (e) {} }
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Full sheet backfill engine reading all data rows in 200-row transactional batches.
 */
function syncFullVehicleStatus() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("syncFullVehicleStatus: Another sync operation is running. Aborting.");
    return;
  }
  
  const config = getAppConfig();
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const sheet = ss.getSheetByName(config.tabName);
    if (!sheet) {
      throw new Error("Tab '" + config.tabName + "' not found.");
    }
    
    const lastRow = sheet.getLastRow();
    const lastCol = sheet.getLastColumn();
    if (lastRow <= 1) return;
    
    const headerVals = sheet.getRange(1, 1, 1, lastCol).getValues()[0];
    const hMap = buildHeaderIndexMap(headerVals);
    
    let conn = null;
    let stmt = null;
    let totalSynced = 0;
    
    try {
      conn = getDbConnection();
      conn.setAutoCommit(false);
      stmt = conn.prepareStatement(UPSERT_SQL);
      
      const chunkSize = 1000;
      let currentRow = 2;
      
      while (currentRow <= lastRow) {
        const rowsToRead = Math.min(chunkSize, lastRow - currentRow + 1);
        const chunkData = sheet.getRange(currentRow, 1, rowsToRead, lastCol).getValues();
        
        let batchCount = 0;
        for (let i = 0; i < chunkData.length; i++) {
          const record = extractRecord(chunkData[i], currentRow + i, hMap);
          if (!record) continue;
          
          bindVehicleStatusParams(stmt, record);
          stmt.addBatch();
          batchCount++;
          totalSynced++;
          
          if (batchCount >= config.batchSize) {
            stmt.executeBatch();
            conn.commit();
            batchCount = 0;
          }
        }
        
        if (batchCount > 0) {
          stmt.executeBatch();
          conn.commit();
        }
        
        Logger.log("Processed up to row " + (currentRow + rowsToRead - 1) + " of " + lastRow);
        currentRow += rowsToRead;
      }
      
      Logger.log("syncFullVehicleStatus complete: Total synced = " + totalSynced);
      try {
        SpreadsheetApp.getUi().alert("Full sync complete!\n\nTotal rows processed: " + totalSynced);
      } catch (e) {}
    } catch (err) {
      if (conn) {
        try { conn.rollback(); } catch (rb) {}
      }
      Logger.log("syncFullVehicleStatus failure: " + err.message);
      try {
        SpreadsheetApp.getUi().alert("Full sync failed: " + err.message);
      } catch (e) {}
    } finally {
      if (stmt) { try { stmt.close(); } catch (e) {} }
      if (conn) { try { conn.close(); } catch (e) {} }
    }
  } finally {
    lock.releaseLock();
  }
}

// ==============================================================================
// TRIGGER MANAGEMENT
// ==============================================================================

/**
 * Installs a recurring 5-minute automated trigger for syncRecentVehicleStatus.
 */
function setupTriggers() {
  deleteAllTriggers();
  ScriptApp.newTrigger("syncRecentVehicleStatus")
    .timeBased()
    .everyMinutes(5)
    .create();
  try {
    SpreadsheetApp.getUi().alert("Automated 5-minute sync trigger installed successfully.");
  } catch (e) {
    Logger.log("Installed 5-minute sync trigger.");
  }
}

/**
 * Removes all project triggers associated with this pipeline.
 */
function deleteAllTriggers() {
  const triggers = ScriptApp.getProjectTriggers();
  let count = 0;
  for (let i = 0; i < triggers.length; i++) {
    const fn = triggers[i].getHandlerFunction();
    if (fn === "syncRecentVehicleStatus" || fn === "syncFullVehicleStatus") {
      ScriptApp.deleteTrigger(triggers[i]);
      count++;
    }
  }
  try {
    SpreadsheetApp.getUi().alert("Removed " + count + " automated trigger(s).");
  } catch (e) {
    Logger.log("Removed " + count + " automated trigger(s).");
  }
}
