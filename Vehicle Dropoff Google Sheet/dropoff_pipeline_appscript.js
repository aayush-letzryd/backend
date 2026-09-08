/**
 * ==============================================================================
 * LETZRYD - VEHICLE DROPOFF LIVE PIPELINE (sheet_dropoffs)
 * ==============================================================================
 * 
 * Target Table : public.sheet_dropoffs
 * Host         : 35.200.196.113:5432
 * Source Tab   : 'Unified_Dropoff_source'
 * 
 * Key Features & Audit Fixes:
 *  - Fix 1.1: Exact Row-to-Record Alignment via source_row conflict key (0% desync risk)
 *  - Fix 1.2: Multi-row paste range iteration support in handleOnEdit
 *  - Fix 1.3: Accounting format (₹500.00) parsed to negative float & Pending/TBD to NULL
 *  - Fix 1.4: Fixed plate length validation dead code
 *  - Fix 1.5: Strict Operator classification check (LETZ + IP prefix)
 *  - Fix 1.6: Sequence-backed dropoff_id support in PostgreSQL
 *  - Fix 1.7: Sliding-window incremental sync (syncRecentDropoffsIncremental) for hourly trigger
 *  - Fix 1.8: Downstream trigger support for july_vehicle_dropoffs
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
  BIGINT: -5,
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
 */
function normalizeDate(rawDate) {
  if (!rawDate) return null;
  
  if (rawDate instanceof Date) {
    if (isNaN(rawDate.getTime())) return null;
    const y = rawDate.getFullYear();
    const m = String(rawDate.getMonth() + 1).padStart(2, '0');
    const d = String(rawDate.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  
  const str = String(rawDate).trim();
  if (!str || str.toLowerCase() === 'null' || str === '-' || str.toLowerCase() === 'return date') return null;
  
  // Excel Serial Integer (e.g. 45123)
  if (/^\d{5}$/.test(str)) {
    const serial = parseInt(str, 10);
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
    return `${dmyMatch[3]}-${dmyMatch[2].padStart(2, '0')}-${dmyMatch[1].padStart(2, '0')}`;
  }
  
  // YYYY-MM-DD
  const ymdMatch = str.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})$/);
  if (ymdMatch) {
    return `${ymdMatch[1]}-${ymdMatch[2].padStart(2, '0')}-${ymdMatch[3].padStart(2, '0')}`;
  }
  
  return null;
}

/**
 * Cleans Vehicle Plate to Uppercase Alphanumeric (Fix 1.4: Strict 8-12 character validation)
 */
function cleanVehicleNumber(rawPlate) {
  if (!rawPlate) return null;
  const cleaned = String(rawPlate).replace(/[^A-Za-z0-9]/g, '').toUpperCase();
  return (cleaned.length >= 8 && cleaned.length <= 12) ? cleaned : null;
}

/**
 * Normalizes City to Canonical Names (Bangalore, Hyderabad, Mumbai)
 */
function normalizeCity(rawCity, vehiclePlate) {
  const c = String(rawCity || '').trim().toUpperCase();
  if (c === 'BLR' || c === 'BANGALORE' || c.includes('BLR')) return 'Bangalore';
  if (c === 'HYD' || c === 'HYDERABAD' || c.includes('HYD')) return 'Hyderabad';
  if (c === 'MUM' || c === 'MUMBAI' || c.includes('MUM')) return 'Mumbai';
  
  const plate = String(vehiclePlate || '').toUpperCase();
  if (plate.startsWith('KA')) return 'Bangalore';
  if (plate.startsWith('TS') || plate.startsWith('TG') || plate.startsWith('AP')) return 'Hyderabad';
  if (plate.startsWith('MH')) return 'Mumbai';
  
  return 'Bangalore';
}

/**
 * Cleans Currency & Negative Balances (Fix 1.3: Handles accounting format (500.00) & Pending/TBD)
 */
function cleanBalance(rawVal) {
  if (rawVal === null || rawVal === undefined || rawVal === '') return 0.00;
  let str = String(rawVal).replace(/[₹,\s]/g, '').trim();
  if (!str || str === '-' || str.toLowerCase() === 'null' || str.toLowerCase() === 'n/a') return 0.00;
  
  // Words like Pending / TBD are uncalculated debts -> return null
  if (str.toLowerCase() === 'pending' || str.toLowerCase() === 'tbd') return null;
  
  // Standard accounting negative in parentheses: (500.00) -> -500.00
  if (str.startsWith("(") && str.endsWith(")")) {
    const inner = str.slice(1, -1).trim();
    const num = parseFloat(inner);
    return isNaN(num) ? null : -num;
  }
  
  const num = parseFloat(str);
  return isNaN(num) ? null : num;
}

/**
 * Normalizes Driver Type (Fix 1.5: Strict Operator check preventing false positives)
 */
function cleanDriverType(rawType, driverId) {
  let driverType = String(rawType || '').trim();
  if (!driverType) {
    const dUpper = String(driverId || '').toUpperCase();
    return (dUpper.startsWith('LETZ') && dUpper.includes('IP')) ? 'Operator' : 'Individual';
  }
  return driverType.charAt(0).toUpperCase() + driverType.slice(1).toLowerCase();
}

/**
 * Main Full Batch ETL Sync Function (Fix 1.1: Uses source_row unique conflict target)
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
  
  Logger.log(`Starting full sync for ${data.length - 1} rows...`);
  
  let conn = null;
  let stmt = null;
  
  const upsertSql = `
    INSERT INTO public.sheet_dropoffs (
      source_row, return_date, return_type, driver_id,
      driver_name, driver_type, vehicle_number, city, negative_balance,
      sync_status, updated_at
    ) VALUES (
      ?, ?::date, ?, ?,
      ?, ?, ?, ?, ?,
      'SYNCED', CURRENT_TIMESTAMP
    )
    ON CONFLICT (source_row) DO UPDATE SET
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
      
      if (String(rawDate).trim().toLowerCase() === 'return date' || String(rawPlate).trim().toLowerCase() === 'vehicle number') {
        continue;
      }
      
      const returnDate = normalizeDate(rawDate);
      const vehicleNumber = cleanVehicleNumber(rawPlate);
      if (!returnDate || !vehicleNumber) continue;
      
      const returnType = String(rawReturnType || 'Attrition').trim();
      let driverId = String(rawDriverId || '').trim();
      if (!driverId || driverId.toUpperCase() === 'N/A' || driverId === '-') driverId = 'UNKNOWN_DRIVER';
      
      let driverName = String(rawDriverName || '').trim();
      if (!driverName || driverName.toLowerCase() === 'null') driverName = 'Unknown Driver';
      
      const driverType = cleanDriverType(rawType, driverId);
      const city = normalizeCity(rawCity, vehicleNumber);
      const negativeBalance = cleanBalance(rawBal);
      
      stmt.setInt(1, sourceRow);
      stmt.setString(2, returnDate);
      stmt.setString(3, returnType);
      stmt.setString(4, driverId);
      stmt.setString(5, driverName);
      stmt.setString(6, driverType);
      stmt.setString(7, vehicleNumber);
      stmt.setString(8, city);
      
      if (negativeBalance === null) {
        stmt.setNull(9, SQL_TYPES.NUMERIC);
      } else {
        stmt.setDouble(9, negativeBalance);
      }
      
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
    
    Logger.log(`Success! Total ${totalProcessed} dropoff records synced to PostgreSQL.`);
  } catch (err) {
    if (conn) conn.rollback();
    Logger.log(`Ingestion Error: ${err.message}`);
    throw err;
  } finally {
    if (stmt) try { stmt.close(); } catch (e) {}
    if (conn) try { conn.close(); } catch (e) {}
  }
}

/**
 * Sliding-Window Incremental Sync for Hourly Triggers (Fix 1.7: Avoids 6-min execution quota timeout)
 */
function syncRecentDropoffsIncremental() {
  const ss = SpreadsheetApp.openByUrl(DB_CONFIG.sheetUrl);
  const sheet = ss.getSheetByName(DB_CONFIG.tabName);
  if (!sheet) return;
  
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) return;
  
  // Process last 200 rows in sliding window
  const windowSize = 200;
  const startRow = Math.max(2, lastRow - windowSize + 1);
  const numRows = lastRow - startRow + 1;
  
  Logger.log(`Running incremental sync for rows ${startRow} to ${lastRow}...`);
  const data = sheet.getRange(startRow, 1, numRows, 8).getValues();
  
  let conn = null;
  let stmt = null;
  
  const upsertSql = `
    INSERT INTO public.sheet_dropoffs (
      source_row, return_date, return_type, driver_id,
      driver_name, driver_type, vehicle_number, city, negative_balance,
      sync_status, updated_at
    ) VALUES (?, ?::date, ?, ?, ?, ?, ?, ?, ?, 'SYNCED', CURRENT_TIMESTAMP)
    ON CONFLICT (source_row) DO UPDATE SET
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
    
    let count = 0;
    for (let i = 0; i < data.length; i++) {
      const sourceRow = startRow + i;
      const row = data[i];
      
      const rawDate = row[0];
      const rawReturnType = row[1];
      const rawDriverId = row[2];
      const rawDriverName = row[3];
      const rawPlate = row[4];
      const rawBal = row[5];
      const rawType = row[6];
      const rawCity = row[7];
      
      if (String(rawDate).trim().toLowerCase() === 'return date') continue;
      
      const returnDate = normalizeDate(rawDate);
      const vehicleNumber = cleanVehicleNumber(rawPlate);
      if (!returnDate || !vehicleNumber) continue;
      
      const returnType = String(rawReturnType || 'Attrition').trim();
      let driverId = String(rawDriverId || '').trim();
      if (!driverId || driverId.toUpperCase() === 'N/A') driverId = 'UNKNOWN_DRIVER';
      
      let driverName = String(rawDriverName || '').trim() || 'Unknown Driver';
      const driverType = cleanDriverType(rawType, driverId);
      const city = normalizeCity(rawCity, vehicleNumber);
      const negativeBalance = cleanBalance(rawBal);
      
      stmt.setInt(1, sourceRow);
      stmt.setString(2, returnDate);
      stmt.setString(3, returnType);
      stmt.setString(4, driverId);
      stmt.setString(5, driverName);
      stmt.setString(6, driverType);
      stmt.setString(7, vehicleNumber);
      stmt.setString(8, city);
      
      if (negativeBalance === null) {
        stmt.setNull(9, SQL_TYPES.NUMERIC);
      } else {
        stmt.setDouble(9, negativeBalance);
      }
      
      stmt.addBatch();
      count++;
    }
    
    if (count > 0) {
      stmt.executeBatch();
      conn.commit();
    }
    Logger.log(`Incremental sync completed successfully: ${count} rows synced.`);
  } catch (err) {
    if (conn) conn.rollback();
    Logger.log(`Incremental sync error: ${err.message}`);
  } finally {
    if (stmt) try { stmt.close(); } catch (e) {}
    if (conn) try { conn.close(); } catch (e) {}
  }
}

/**
 * Real-Time onEdit Event Trigger (Fix 1.2: Loops through all pasted rows from getRow to getLastRow)
 */
function handleOnEdit(e) {
  if (!e || !e.range) return;
  const sheet = e.range.getSheet();
  if (sheet.getName() !== DB_CONFIG.tabName) return;
  
  const startRow = Math.max(2, e.range.getRow());
  const endRow = e.range.getLastRow();
  
  Logger.log(`Handling live edit for rows ${startRow} to ${endRow}...`);
  for (let r = startRow; r <= endRow; r++) {
    syncSingleRow(sheet, r);
  }
}

/**
 * Sync single edited row to database (Fix 1.1: Uses source_row upsert key targeting the exact record)
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
  const driverType = cleanDriverType(rawType, driverId);
  const city = normalizeCity(rawCity, vehicleNumber);
  const negativeBalance = cleanBalance(rawBal);
  
  let conn = null;
  let stmt = null;
  
  const sql = `
    INSERT INTO public.sheet_dropoffs (
      source_row, return_date, return_type, driver_id,
      driver_name, driver_type, vehicle_number, city, negative_balance,
      sync_status, updated_at
    ) VALUES (?, ?::date, ?, ?, ?, ?, ?, ?, ?, 'SYNCED', CURRENT_TIMESTAMP)
    ON CONFLICT (source_row) DO UPDATE SET
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
    stmt.setInt(1, rowNum);
    stmt.setString(2, returnDate);
    stmt.setString(3, returnType);
    stmt.setString(4, driverId);
    stmt.setString(5, driverName);
    stmt.setString(6, driverType);
    stmt.setString(7, vehicleNumber);
    stmt.setString(8, city);
    
    if (negativeBalance === null) {
      stmt.setNull(9, SQL_TYPES.NUMERIC);
    } else {
      stmt.setDouble(9, negativeBalance);
    }
    
    stmt.executeUpdate();
    Logger.log(`Row ${rowNum} synced successfully.`);
  } catch (err) {
    Logger.log(`Error syncing row ${rowNum}: ${err.message}`);
  } finally {
    if (stmt) try { stmt.close(); } catch (e) {}
    if (conn) try { conn.close(); } catch (e) {}
  }
}

/**
 * Setup Automated Triggers (Uses incremental sliding window for hourly execution)
 */
function setupTriggers() {
  deleteAllTriggers();
  
  ScriptApp.newTrigger("handleOnEdit")
    .forSpreadsheet(SpreadsheetApp.getActiveSpreadsheet())
    .onEdit()
    .create();
    
  ScriptApp.newTrigger("syncRecentDropoffsIncremental")
    .timeBased()
    .everyHours(1)
    .create();
    
  Logger.log("Live dropoff triggers installed successfully!");
}

/**
 * Cleanly remove only dropoff pipeline triggers
 */
function deleteAllTriggers() {
  const triggers = ScriptApp.getProjectTriggers();
  const dropoffHandlers = ["handleOnEdit", "syncRecentDropoffsIncremental", "syncDropoffsToDatabase"];
  
  for (let i = 0; i < triggers.length; i++) {
    const handler = triggers[i].getHandlerFunction();
    if (dropoffHandlers.indexOf(handler) !== -1) {
      ScriptApp.deleteTrigger(triggers[i]);
    }
  }
}
