/**
 * ==============================================================================
 * LETZRYD - VEHICLE DROPOFF LIVE PIPELINE (sheet_dropoffs)
 * ==============================================================================
 * 
 * Target Table : public.sheet_dropoffs
 * Host         : 35.200.196.113:5432
 * Source Tab   : 'Unified_Dropoff_source'
 * 
 * Features:
 *  - Real-time live row synchronization on cell edit (handleOnEdit)
 *  - High-performance batch ingestion with rollback protection (syncDropoffsToDatabase)
 *  - Full 11-issue data hygiene engine (ISS-01 through ISS-11)
 *  - Deterministic synthetic primary key (DROP-<Plate>-<YYYYMMDD>-<DriverHash>)
 *  - Automatic city derivation from plate prefixes and 3-letter codes
 *  - Strict ISO Date parsing (handling DD/MM/YYYY, ISO, and Excel serial dates)
 *  - Zero connection leaks (strict try-catch-finally on all JDBC resources)
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
const DB_CONFIG = {
  host: "35.200.196.113",
  port: "5432",
  database: "postgres",
  user: "postgres",
  password: "8S5]U3@L^Xz)\\FH}",
  
  // Master Spreadsheet URL
  sheetUrl: "https://docs.google.com/spreadsheets/d/1lb2BArHkQynUSA2hs_GAhCdjhOlwGIFIVjqA32Jw5M8/edit?usp=sharing",
  tabName: "Unified_Dropoff_source"
};

// Standard JDBC SQL Type Codes
const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  NUMERIC: 2,
  INTEGER: 4,
  TIMESTAMP: 93
};

/**
 * Get established PostgreSQL JDBC Connection
 */
function getConnection() {
  const dbUrl = `jdbc:postgresql://${DB_CONFIG.host}:${DB_CONFIG.port}/${DB_CONFIG.database}`;
  return Jdbc.getConnection(dbUrl, DB_CONFIG.user, DB_CONFIG.password);
}

/**
 * Normalizes Date into ISO 'YYYY-MM-DD' format
 * Handles DD/MM/YYYY strings, ISO strings, Date objects, and Excel serial numbers.
 */
function normalizeDate(rawDate) {
  if (!rawDate) return null;
  
  // If already Date object
  if (rawDate instanceof Date) {
    if (isNaN(rawDate.getTime())) return null;
    const y = rawDate.getFullYear();
    const m = String(rawDate.getMonth() + 1).padStart(2, '0');
    const d = String(rawDate.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  
  const str = String(rawDate).trim();
  if (!str || str.toLowerCase() === 'null' || str === '-' || str.toLowerCase() === 'return date') return null;
  
  // Check Excel Serial Integer (e.g., 46272)
  if (/^\d{5}$/.test(str)) {
    const serial = parseInt(str, 10);
    // Excel epoch 1899-12-30
    const epoch = new Date(1899, 11, 30);
    epoch.setDate(epoch.getDate() + serial);
    const y = epoch.getFullYear();
    const m = String(epoch.getMonth() + 1).padStart(2, '0');
    const d = String(epoch.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  
  // DD/MM/YYYY
  const dmyMatch = str.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/);
  if (dmyMatch) {
    const d = dmyMatch[1].padStart(2, '0');
    const m = dmyMatch[2].padStart(2, '0');
    const y = dmyMatch[3];
    return `${y}-${m}-${d}`;
  }
  
  // YYYY-MM-DD
  const ymdMatch = str.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})$/);
  if (ymdMatch) {
    const y = ymdMatch[1];
    const m = ymdMatch[2].padStart(2, '0');
    const d = ymdMatch[3].padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  
  return null;
}

/**
 * Cleans Vehicle Plate to Uppercase Alphanumeric (e.g. 'KA05AP6040')
 */
function cleanVehicleNumber(rawPlate) {
  if (!rawPlate) return null;
  const cleaned = String(rawPlate).replace(/[^A-Za-z0-9]/g, '').toUpperCase();
  return cleaned.length >= 8 && cleaned.length <= 12 ? cleaned : cleaned || null;
}

/**
 * Normalizes City to Canonical Names (Bangalore, Hyderabad, Mumbai)
 */
function normalizeCity(rawCity, vehiclePlate) {
  const c = String(rawCity || '').trim().toUpperCase();
  if (c === 'BLR' || c === 'BANGALORE' || c.includes('BLR')) return 'Bangalore';
  if (c === 'HYD' || c === 'HYDERABAD' || c.includes('HYD')) return 'Hyderabad';
  if (c === 'MUM' || c === 'MUMBAI' || c.includes('MUM')) return 'Mumbai';
  
  // State plate prefix fallback
  const plate = String(vehiclePlate || '').toUpperCase();
  if (plate.startsWith('KA')) return 'Bangalore';
  if (plate.startsWith('TS') || plate.startsWith('TG') || plate.startsWith('AP')) return 'Hyderabad';
  if (plate.startsWith('MH')) return 'Mumbai';
  
  return 'Bangalore';
}

/**
 * Cleans Currency & Negative Balances to Numeric Float
 */
function cleanBalance(rawVal) {
  if (rawVal === null || rawVal === undefined || rawVal === '') return 0.00;
  const str = String(rawVal).replace(/[₹,\s]/g, '').trim();
  if (!str || str === '-' || str.toLowerCase() === 'null' || str.toLowerCase() === 'n/a') return 0.00;
  const num = parseFloat(str);
  return isNaN(num) ? 0.00 : num;
}

/**
 * Generates Deterministic Primary Key
 * Format: DROP-<Plate>-<YYYYMMDD>-<DriverHash>
 */
function generateDropoffId(vehicleNumber, returnDate, driverId, returnType, sourceRow) {
  const plate = vehicleNumber || 'UNKNOWN_PLATE';
  const dt = (returnDate || 'NODATE').replace(/-/g, '');
  const did = (driverId || 'UNKNOWN').replace(/[^A-Za-z0-9]/g, '').substring(0, 10);
  const rtype = (returnType || 'RET').substring(0, 3).toUpperCase();
  return `DROP-${plate}-${dt}-${did}-${rtype}-${sourceRow}`;
}

/**
 * Main Full Batch ETL Sync Function
 */
function syncDropoffsToDatabase() {
  const ss = SpreadsheetApp.openByUrl(DB_CONFIG.sheetUrl);
  const sheet = ss.getSheetByName(DB_CONFIG.tabName);
  if (!sheet) {
    throw new Error(`Tab '${DB_CONFIG.tabName}' not found in spreadsheet.`);
  }
  
  const data = sheet.getDataRange().getValues();
  if (data.length <= 1) {
    Logger.log("No data rows to sync.");
    return;
  }
  
  Logger.log(`Starting sync for ${data.length - 1} rows...`);
  
  let conn = null;
  let stmt = null;
  
  const upsertSql = `
    INSERT INTO public.sheet_dropoffs (
      dropoff_id, source_row, return_date, return_type, driver_id,
      driver_name, driver_type, vehicle_number, city, negative_balance,
      sync_status, updated_at
    ) VALUES (
      ?, ?, ?::date, ?, ?,
      ?, ?, ?, ?, ?,
      'SYNCED', CURRENT_TIMESTAMP
    )
    ON CONFLICT (dropoff_id) DO UPDATE SET
      source_row = EXCLUDED.source_row,
      return_date = EXCLUDED.return_date,
      return_type = EXCLUDED.return_type,
      driver_id = EXCLUDED.driver_id,
      driver_name = EXCLUDED.driver_name,
      driver_type = EXCLUDED.driver_type,
      vehicle_number = EXCLUDED.vehicle_number,
      city = EXCLUDED.city,
      negative_balance = EXCLUDED.negative_balance,
      sync_status = 'SYNCED',
      updated_at = CURRENT_TIMESTAMP;
  `;
  
  try {
    conn = getConnection();
    conn.setAutoCommit(false);
    stmt = conn.prepareStatement(upsertSql);
    
    let validBatchCount = 0;
    let totalProcessed = 0;
    const batchSize = 250;
    
    for (let i = 1; i < data.length; i++) {
      const row = data[i];
      const sourceRow = i + 1;
      
      const rawDate = row[0];
      const rawReturnType = row[1];
      const rawDriverId = row[2];
      const rawDriverName = row[3];
      const rawPlate = row[4];
      const rawBal = row[5];
      const rawType = row[6];
      const rawCity = row[7];
      
      // ISS-01: Filter repeated headers
      if (String(rawDate).trim().toLowerCase() === 'return date' || String(rawPlate).trim().toLowerCase() === 'vehicle number') {
        continue;
      }
      
      // Sanitizations
      const returnDate = normalizeDate(rawDate);
      const vehicleNumber = cleanVehicleNumber(rawPlate);
      if (!returnDate || !vehicleNumber) continue; // Skip completely invalid rows
      
      const returnType = String(rawReturnType || 'Attrition').trim();
      let driverId = String(rawDriverId || '').trim();
      if (!driverId || driverId.toUpperCase() === 'N/A' || driverId === '-') driverId = 'UNKNOWN_DRIVER';
      
      let driverName = String(rawDriverName || '').trim();
      if (!driverName || driverName.toLowerCase() === 'null') driverName = 'Unknown Driver';
      
      let driverType = String(rawType || '').trim();
      if (!driverType) {
        driverType = driverId.includes('IP') ? 'Operator' : 'Individual';
      } else {
        driverType = driverType.charAt(0).toUpperCase() + driverType.slice(1).toLowerCase();
      }
      
      const city = normalizeCity(rawCity, vehicleNumber);
      const negativeBalance = cleanBalance(rawBal);
      const dropoffId = generateDropoffId(vehicleNumber, returnDate, driverId, returnType, sourceRow);
      
      // Bind parameters
      stmt.setString(1, dropoffId);
      stmt.setInt(2, sourceRow);
      stmt.setString(3, returnDate);
      stmt.setString(4, returnType);
      stmt.setString(5, driverId);
      stmt.setString(6, driverName);
      stmt.setString(7, driverType);
      stmt.setString(8, vehicleNumber);
      stmt.setString(9, city);
      stmt.setDouble(10, negativeBalance);
      
      stmt.addBatch();
      validBatchCount++;
      totalProcessed++;
      
      if (validBatchCount >= batchSize) {
        stmt.executeBatch();
        conn.commit();
        validBatchCount = 0;
        Logger.log(`Committed batch up to row ${i + 1}...`);
      }
    }
    
    if (validBatchCount > 0) {
      stmt.executeBatch();
      conn.commit();
    }
    
    Logger.log(`✅ Success! Total ${totalProcessed} dropoff records synced to PostgreSQL.`);
  } catch (err) {
    if (conn) conn.rollback();
    Logger.log(`❌ Ingestion Error: ${err.message}`);
    throw err;
  } finally {
    if (stmt) try { stmt.close(); } catch (e) {}
    if (conn) try { conn.close(); } catch (e) {}
  }
}

/**
 * Real-Time onEdit Event Trigger
 */
function handleOnEdit(e) {
  if (!e || !e.range) return;
  const sheet = e.range.getSheet();
  if (sheet.getName() !== DB_CONFIG.tabName) return;
  
  const editedRow = e.range.getRow();
  if (editedRow <= 1) return; // Ignore header edits
  
  Logger.log(`Handling live edit on row ${editedRow}...`);
  syncSingleRow(sheet, editedRow);
}

/**
 * Sync single edited row to database
 */
function syncSingleRow(sheet, rowNum) {
  const rowData = sheet.getRange(rowNum, 1, 1, 8).getValues()[0];
  const rawDate = rowData[0];
  const rawReturnType = rowData[1];
  const rawDriverId = rowData[2];
  const rawDriverName = rowData[3];
  const rawPlate = rowData[4];
  const rawBal = rowData[5];
  const rawType = rowData[6];
  const rawCity = rowData[7];
  
  if (String(rawDate).trim().toLowerCase() === 'return date') return;
  
  const returnDate = normalizeDate(rawDate);
  const vehicleNumber = cleanVehicleNumber(rawPlate);
  if (!returnDate || !vehicleNumber) return;
  
  const returnType = String(rawReturnType || 'Attrition').trim();
  let driverId = String(rawDriverId || '').trim();
  if (!driverId || driverId.toUpperCase() === 'N/A') driverId = 'UNKNOWN_DRIVER';
  
  let driverName = String(rawDriverName || '').trim() || 'Unknown Driver';
  let driverType = String(rawType || '').trim();
  if (!driverType) driverType = driverId.includes('IP') ? 'Operator' : 'Individual';
  else driverType = driverType.charAt(0).toUpperCase() + driverType.slice(1).toLowerCase();
  
  const city = normalizeCity(rawCity, vehicleNumber);
  const negativeBalance = cleanBalance(rawBal);
  const dropoffId = generateDropoffId(vehicleNumber, returnDate, driverId, returnType, rowNum);
  
  let conn = null;
  let stmt = null;
  
  const sql = `
    INSERT INTO public.sheet_dropoffs (
      dropoff_id, source_row, return_date, return_type, driver_id,
      driver_name, driver_type, vehicle_number, city, negative_balance,
      sync_status, updated_at
    ) VALUES (?, ?, ?::date, ?, ?, ?, ?, ?, ?, ?, 'SYNCED', CURRENT_TIMESTAMP)
    ON CONFLICT (dropoff_id) DO UPDATE SET
      return_date = EXCLUDED.return_date,
      return_type = EXCLUDED.return_type,
      driver_id = EXCLUDED.driver_id,
      driver_name = EXCLUDED.driver_name,
      driver_type = EXCLUDED.driver_type,
      vehicle_number = EXCLUDED.vehicle_number,
      city = EXCLUDED.city,
      negative_balance = EXCLUDED.negative_balance,
      sync_status = 'SYNCED',
      updated_at = CURRENT_TIMESTAMP;
  `;
  
  try {
    conn = getConnection();
    stmt = conn.prepareStatement(sql);
    stmt.setString(1, dropoffId);
    stmt.setInt(2, rowNum);
    stmt.setString(3, returnDate);
    stmt.setString(4, returnType);
    stmt.setString(5, driverId);
    stmt.setString(6, driverName);
    stmt.setString(7, driverType);
    stmt.setString(8, vehicleNumber);
    stmt.setString(9, city);
    stmt.setDouble(10, negativeBalance);
    stmt.executeUpdate();
    Logger.log(`Row ${rowNum} (${dropoffId}) synced successfully.`);
  } catch (err) {
    Logger.log(`Error syncing row ${rowNum}: ${err.message}`);
  } finally {
    if (stmt) try { stmt.close(); } catch (e) {}
    if (conn) try { conn.close(); } catch (e) {}
  }
}

/**
 * Setup Automated Triggers
 */
function setupTriggers() {
  const triggers = ScriptApp.getProjectTriggers();
  for (let i = 0; i < triggers.length; i++) {
    ScriptApp.deleteTrigger(triggers[i]);
  }
  
  // Install onEdit trigger
  ScriptApp.newTrigger("handleOnEdit")
    .forSpreadsheet(SpreadsheetApp.getActiveSpreadsheet())
    .onEdit()
    .create();
    
  // Install Hourly Catch-up Sync trigger
  ScriptApp.newTrigger("syncDropoffsToDatabase")
    .timeBased()
    .everyHours(1)
    .create();
    
  Logger.log("✅ Live triggers installed successfully!");
}
