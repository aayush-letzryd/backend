/**
 * ==============================================================================
 * LETZRYD - TRAFFIC CHALLAN LIVE PIPELINE (sheet_challans)
 * ==============================================================================
 * 
 * Target Table : public.sheet_challans
 * Host         : 35.200.196.113:5432
 * Source Sheet : 'Traffic Challan details' (38 Weekly & Monthly Tabs)
 * 
 * Key Features & Audit Fixes:
 *  - Fix 3.1: Unique composite synthetic notice numbers (NOT-{plate}-{date}-{time}-{row})
 *  - Fix 3.2: Programmatic active week tab resolver in headless background triggers
 *  - Fix 3.3: 12-Hour AM/PM time parser with 24-hour ISO conversion (HH:mm:ss)
 *  - Fix 3.4: Shifted fine amount extraction from leaked city columns
 *  - Fix 3.5: Multi-tab checkpointing via PropertiesService to prevent 6-min quota timeouts
 *  - Fix 3.6: Multi-row paste range iteration support in handleOnEdit
 *  - Fix 3.7: Safe trigger cleanup filtering specifically by handler function name
 *  - Fix 3.8: Sequence preservation on conflict upserts
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
  
  // Master Spreadsheet URL:
  sheetUrl: "https://docs.google.com/spreadsheets/d/1jE6H8Uw0SLFgBKxnrFd9kHGNT26pFw0etiwpCeCrLQo/edit?usp=sharing"
};

// Standard JDBC SQL Type Codes (Apps Script does not expose java.sql.Types)
const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  TIME: 92,
  TIMESTAMP: 93,
  INTEGER: 4,
  NUMERIC: 2,
  NULL: 0
};

/**
 * Returns the target Spreadsheet instance.
 */
function getTargetSpreadsheet() {
  if (DB_CONFIG.sheetUrl && DB_CONFIG.sheetUrl.trim() !== "") {
    try {
      return SpreadsheetApp.openByUrl(DB_CONFIG.sheetUrl);
    } catch(e) {
      Logger.log("openByUrl error, falling back to active spreadsheet: " + e.message);
    }
  }
  return SpreadsheetApp.getActiveSpreadsheet();
}

/**
 * Creates custom UI menu in Google Sheets on load.
 */
function onOpen() {
  try {
    SpreadsheetApp.getUi().createMenu("LetzRyd Challan Pipeline")
      .addItem("Sync Master Tab to Postgres (Unified Source)", "syncUnifiedChallansMasterToPostgres")
      .addItem("Sync All Weekly Tabs from Raw Source", "syncAllChallanTabs")
      .addItem("Sync Current Active Tab", "syncCurrentWeekTab")
      .addSeparator()
      .addItem("Test Database Connection", "testDbConnection")
      .addSeparator()
      .addItem("Install Automated Triggers", "setupTriggers")
      .addItem("Remove Automated Triggers", "deleteAllTriggers")
      .addToUi();
  } catch(e) {
    Logger.log("Menu creation skipped (running in background trigger).");
  }
}

/**
 * Returns an active JDBC PostgreSQL connection.
 */
function getDbConnection() {
  const url = "jdbc:postgresql://" + DB_CONFIG.host + ":" + DB_CONFIG.port + "/" + DB_CONFIG.database;
  return Jdbc.getConnection(url, DB_CONFIG.user, DB_CONFIG.password);
}

/**
 * Test DB Connection utility with leak-proof cleanup.
 */
function testDbConnection() {
  let conn = null;
  let stmt = null;
  let rs = null;
  try {
    conn = getDbConnection();
    stmt = conn.createStatement();
    rs = stmt.executeQuery("SELECT count(*) FROM sheet_challans;");
    rs.next();
    const count = rs.getInt(1);
    
    Logger.log("Connection Successful. Current rows in sheet_challans: " + count);
    try {
      SpreadsheetApp.getUi().alert(
        "Connection Successful",
        "Connected to PostgreSQL on " + DB_CONFIG.host + ".\nCurrent rows in sheet_challans: " + count,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
    } catch(e) {}
  } catch (err) {
    Logger.log("Connection Failed: " + err.message);
    try {
      SpreadsheetApp.getUi().alert(
        "Connection Failed",
        "Error: " + err.message,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
    } catch(e) {}
  } finally {
    if (rs) { try { rs.close(); } catch(e) {} }
    if (stmt) { try { stmt.close(); } catch(e) {} }
    if (conn) { try { conn.close(); } catch(e) {} }
  }
}

// --- UNIVERSAL DATA CLEANING & HYGIENE FUNCTIONS ---

function cleanStr(val) {
  if (val === null || val === undefined) return null;
  const s = String(val).replace(/[`'"]/g, "").trim().replace(/\s+/g, " ");
  return (s === "" || s.toLowerCase() === "nan" || s.toLowerCase() === "null" || s === "-" || s === "--" || s.toLowerCase() === "na" || s.toLowerCase() === "#n/a") ? null : s;
}

// Vehicle Plate: Uppercase, remove non-alphanumeric
function cleanPlate(val) {
  const s = cleanStr(val);
  if (!s) return null;
  const plate = s.toUpperCase().replace(/[^A-Z0-9]/g, "");
  return (plate.length >= 8 && plate.length <= 12) ? plate : (plate.length >= 4 ? plate : null);
}

// City Normalization with plate prefix fallback (Fix 3.4: Shifted fine numbers detection)
function cleanCity(val, plate) {
  const s = cleanStr(val);
  if (s) {
    const low = s.toLowerCase();
    if (low.includes("hyd")) return "Hyderabad";
    if (low.includes("mum")) return "Mumbai";
    if (low.includes("blr") || low.includes("bang") || low.includes("beng")) return "Bangalore";
    // Check if numerical string leaked into city
    if (!isNaN(parseFloat(s))) {
      // Leaked number -> fallback to vehicle plate prefix
    } else {
      return s.split(" ").map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(" ");
    }
  }
  // Auto-derive from vehicle plate prefix
  if (plate) {
    const p = plate.toUpperCase();
    if (p.startsWith("KA")) return "Bangalore";
    if (p.startsWith("TS") || p.startsWith("TG") || p.startsWith("AP")) return "Hyderabad";
    if (p.startsWith("MH")) return "Mumbai";
  }
  return "Bangalore";
}

// Numeric Cleaner (strips currency symbols and commas)
function cleanNum(val) {
  if (val === null || val === undefined) return 0.0;
  if (typeof val === "number") return isNaN(val) ? 0.0 : val;
  const s = String(val).replace(/[^0-9.]/g, "").trim();
  if (s === "") return 0.0;
  const num = parseFloat(s);
  return isNaN(num) ? 0.0 : num;
}

// Multi-Format Date Parser -> Returns YYYY-MM-DD or null
function parseDate(val) {
  if (val === null || val === undefined) return null;
  if (val instanceof Date) {
    if (isNaN(val.getTime())) return null;
    return Utilities.formatDate(val, "Asia/Kolkata", "yyyy-MM-dd");
  }
  
  if (typeof val === 'number' && val > 20000 && val < 60000) {
    const d = new Date(Math.round((val - 25569) * 86400 * 1000));
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
  }
  
  const s = String(val).trim();
  if (s === "" || s.toLowerCase() === "nan" || s === "-" || s === "--" || s.toLowerCase() === "na" || s.toLowerCase() === "#n/a") return null;

  if (/^\d{5}$/.test(s)) {
    const serial = parseInt(s, 10);
    const d = new Date(Math.round((serial - 25569) * 86400 * 1000));
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
  }

  // DD/MM/YYYY or DD-MM-YYYY
  const dmyMatch = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})/);
  if (dmyMatch) {
    const day = dmyMatch[1].padStart(2, "0");
    const month = dmyMatch[2].padStart(2, "0");
    let year = dmyMatch[3];
    if (year.length === 2) year = "20" + year;
    return `${year}-${month}-${day}`;
  }

  // YYYY-MM-DD
  const isoMatch = s.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (isoMatch) {
    const year = isoMatch[1];
    const month = isoMatch[2].padStart(2, "0");
    const day = isoMatch[3].padStart(2, "0");
    return `${year}-${month}-${day}`;
  }

  return null;
}

/**
 * Multi-Format Time Parser -> Returns 24-hour HH:mm:ss or null
 * (Fix 3.3: 12-hour AM/PM format support converted to 24-hour time)
 */
function parseTime(val) {
  if (val === null || val === undefined) return null;
  if (val instanceof Date) {
    if (isNaN(val.getTime())) return null;
    return Utilities.formatDate(val, "Asia/Kolkata", "HH:mm:ss");
  }
  const s = String(val).trim();
  if (s === "" || s === "-" || s === "--" || s.toLowerCase() === "na" || s.toLowerCase() === "null") return null;

  // 12-hour AM/PM format (e.g. "10:30 PM", "02:15 AM", "11:45:00 AM")
  const ampmMatch = s.match(/^(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?\s*(AM|PM)$/i);
  if (ampmMatch) {
    let h = parseInt(ampmMatch[1], 10);
    const m = ampmMatch[2].padStart(2, "0");
    const sec = (ampmMatch[3] || "00").padStart(2, "0");
    const meridiem = ampmMatch[4].toUpperCase();
    if (meridiem === 'PM' && h < 12) h += 12;
    if (meridiem === 'AM' && h === 12) h = 0;
    return `${String(h).padStart(2, "0")}:${m}:${sec}`;
  }

  // 24-hour HH:MM or HH:MM:SS
  const tMatch = s.match(/^(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$/);
  if (tMatch) {
    const h = tMatch[1].padStart(2, "0");
    const m = tMatch[2].padStart(2, "0");
    const sec = (tMatch[3] || "00").padStart(2, "0");
    return `${h}:${m}:${sec}`;
  }

  return null;
}

// --- DATABASE UPSERT SQL ---
const UPSERT_SQL = `
INSERT INTO public.sheet_challans (
  vehicle_reg_no, notice_no, city, week_cycle,
  previous_balance, audit_date,
  notice_date, violation_date, violation_time,
  challan_amount, sticker_fine, amount_paid, total_pending, remarks,
  source_tab, sheet_row_number, updated_at
) VALUES (
  ?, ?, ?, ?,
  ?, CAST(? AS date),
  CAST(? AS date), CAST(? AS date), CAST(? AS time),
  ?, ?, ?, ?, ?,
  ?, ?, CURRENT_TIMESTAMP
)
ON CONFLICT (vehicle_reg_no, notice_no, week_cycle) DO UPDATE SET
  city = EXCLUDED.city,
  previous_balance = EXCLUDED.previous_balance,
  audit_date = EXCLUDED.audit_date,
  notice_date = EXCLUDED.notice_date,
  violation_date = EXCLUDED.violation_date,
  violation_time = EXCLUDED.violation_time,
  challan_amount = EXCLUDED.challan_amount,
  sticker_fine = EXCLUDED.sticker_fine,
  amount_paid = EXCLUDED.amount_paid,
  total_pending = EXCLUDED.total_pending,
  remarks = EXCLUDED.remarks,
  sheet_row_number = EXCLUDED.sheet_row_number,
  updated_at = CURRENT_TIMESTAMP;
`;

/**
 * Binds row parameters to prepared statement.
 * (Fix 3.1: Unique synthetic notice identifier including violation time and sheet row number)
 * (Fix 3.4: Shifted fine amount extraction from city column)
 */
function bindChallanRow(pstmt, row, rowNumber, tabName, colMap) {
  const get = (key) => (colMap[key] && colMap[key] - 1 < row.length ? row[colMap[key] - 1] : null);

  const regNo = cleanPlate(get('reg_no'));
  if (!regNo) return false;

  let fineAmt = cleanNum(get('fine_amount'));
  const rawCityVal = cleanStr(get('city'));
  // Fix 3.4: If fine amount is 0 and a number was entered in city, extract it
  if (fineAmt === 0 && rawCityVal && !isNaN(parseFloat(rawCityVal))) {
    fineAmt = cleanNum(rawCityVal);
  }

  const stkFine = cleanNum(get('sticker_fine'));
  const amtPaid = cleanNum(get('amount_paid'));
  const prevBal = cleanNum(get('prev_bal'));
  const totPend = cleanNum(get('total_pending'));

  const updDate = parseDate(get('updated_on'));
  const notDate = parseDate(get('notice_date'));
  const vioDate = parseDate(get('violation_date'));
  const vioTime = parseTime(get('time'));

  const city = cleanCity(get('city'), regNo);
  const remarks = cleanStr(get('remarks'));

  // Fix 3.1: Guaranteed unique synthetic notice identifier preventing collisions
  const timeSuffix = vioTime ? vioTime.replace(/:/g, "") : "0000";
  const noticeNo = (vioDate || fineAmt > 0) 
    ? `NOT-${regNo}-${vioDate || updDate || tabName}-${timeSuffix}-${rowNumber}`
    : `BAL-${regNo}-${tabName}-${rowNumber}`;

  let p = 1;
  pstmt.setString(p++, regNo); // 1. vehicle_reg_no
  pstmt.setString(p++, noticeNo); // 2. notice_no
  pstmt.setString(p++, city); // 3. city
  pstmt.setString(p++, tabName); // 4. week_cycle

  pstmt.setDouble(p++, prevBal); // 5. previous_balance
  if (updDate) pstmt.setString(p++, updDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 6. audit_date

  if (notDate) pstmt.setString(p++, notDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 7. notice_date
  if (vioDate) pstmt.setString(p++, vioDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 8. violation_date
  if (vioTime) pstmt.setString(p++, vioTime); else pstmt.setNull(p++, SQL_TYPES.TIME); // 9. violation_time

  pstmt.setDouble(p++, fineAmt); // 10. challan_amount
  pstmt.setDouble(p++, stkFine); // 11. sticker_fine
  pstmt.setDouble(p++, amtPaid); // 12. amount_paid
  pstmt.setDouble(p++, totPend); // 13. total_pending
  pstmt.setString(p++, remarks); // 14. remarks

  pstmt.setString(p++, tabName); // 15. source_tab
  pstmt.setInt(p++, rowNumber); // 16. sheet_row_number

  return true;
}

/**
 * Detects column mapping for any weekly tab.
 */
function getWeeklyColMap(headers) {
  const colMap = {};
  for (let i = 0; i < headers.length; i++) {
    const h = String(headers[i] || "").trim().toLowerCase();
    if (h.includes("reg") || h.includes("vehicle")) colMap['reg_no'] = i + 1;
    else if (h.includes("city") || h.includes("location")) colMap['city'] = i + 1;
    else if (h.includes("upto") || h.includes("previous") || h.includes("balance")) colMap['prev_bal'] = i + 1;
    else if (h.includes("updated on") || h.includes("audit")) colMap['updated_on'] = i + 1;
    else if (h.includes("notice date")) colMap['notice_date'] = i + 1;
    else if (h.includes("violation date")) colMap['violation_date'] = i + 1;
    else if (h.includes("time")) colMap['time'] = i + 1;
    else if (h.includes("challen amount") || h.includes("challan amount") || h.includes("fine")) colMap['fine_amount'] = i + 1;
    else if (h.includes("sticker")) colMap['sticker_fine'] = i + 1;
    else if (h.includes("paid")) colMap['amount_paid'] = i + 1;
    else if (h.includes("pending") || h.includes("total")) colMap['total_pending'] = i + 1;
    else if (h.includes("remark")) colMap['remarks'] = i + 1;
  }
  return colMap;
}

/**
 * Ingests a specific sheet tab into PostgreSQL.
 */
function syncSheetTab(sheet, conn, pstmt) {
  const name = sheet.getName();
  const lastRow = sheet.getLastRow();
  const lastCol = sheet.getLastColumn();
  if (lastRow <= 1) return { synced: 0, skipped: 0 };

  const headerSearchRange = sheet.getRange(1, 1, Math.min(5, lastRow), lastCol).getValues();
  let hRow = null;
  let headers = null;
  for (let r = 0; r < headerSearchRange.length; r++) {
    const strVals = headerSearchRange[r].map(v => String(v || "").toLowerCase());
    if (strVals.some(v => v.includes("reg") || v.includes("vehicle"))) {
      hRow = r + 1;
      headers = headerSearchRange[r];
      break;
    }
  }

  if (!hRow || !headers) return { synced: 0, skipped: 0 };

  const colMap = getWeeklyColMap(headers);
  if (!colMap['reg_no']) return { synced: 0, skipped: 0 };

  const totalDataRows = lastRow - hRow;
  if (totalDataRows <= 0) return { synced: 0, skipped: 0 };

  const data = sheet.getRange(hRow + 1, 1, totalDataRows, lastCol).getValues();
  let synced = 0;
  let skipped = 0;
  const BATCH_SIZE = 250;
  let pendingBatch = 0;

  for (let i = 0; i < data.length; i++) {
    const row = data[i];
    const currentRowNumber = hRow + 1 + i;

    if (bindChallanRow(pstmt, row, currentRowNumber, name, colMap)) {
      pstmt.addBatch();
      pendingBatch++;
      synced++;
    } else {
      skipped++;
    }

    if (pendingBatch >= BATCH_SIZE) {
      pstmt.executeBatch();
      conn.commit();
      pendingBatch = 0;
    }
  }

  if (pendingBatch > 0) {
    pstmt.executeBatch();
    conn.commit();
  }

  return { synced: synced, skipped: skipped };
}

/**
 * Syncs all weekly tabs across the entire spreadsheet.
 * (Fix 3.5: State Checkpointing via PropertiesService to prevent 6-minute execution quota timeouts)
 */
function syncAllChallanTabs() {
  const ss = getTargetSpreadsheet();
  const sheets = ss.getSheets();
  const props = PropertiesService.getScriptProperties();
  let startTabIndex = parseInt(props.getProperty("CHALLAN_SYNC_TAB_INDEX") || "0", 10);
  
  if (startTabIndex >= sheets.length) startTabIndex = 0;

  let conn = null;
  let pstmt = null;
  let totalSynced = 0;
  let totalSkipped = 0;
  let tabsProcessed = 0;

  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    pstmt = conn.prepareStatement(UPSERT_SQL);

    for (let i = startTabIndex; i < sheets.length; i++) {
      const sheet = sheets[i];
      const name = sheet.getName();
      if (name.toLowerCase().includes("form responses")) continue;

      Logger.log("Processing tab " + (i + 1) + "/" + sheets.length + ": " + name + "...");
      const result = syncSheetTab(sheet, conn, pstmt);
      if (result.synced > 0) {
        totalSynced += result.synced;
        totalSkipped += result.skipped;
        tabsProcessed++;
        Logger.log("Tab " + name + " complete: " + result.synced + " rows synced.");
      }
      
      // Save checkpoint after each completed tab
      props.setProperty("CHALLAN_SYNC_TAB_INDEX", String(i + 1));
    }

    // Reset checkpoint after completing all tabs
    props.deleteProperty("CHALLAN_SYNC_TAB_INDEX");
    Logger.log("Full Multi-Tab Sync Complete. Total Synced: " + totalSynced + " across " + tabsProcessed + " tabs.");
  } catch(err) {
    if (conn) { try { conn.rollback(); } catch(e) {} }
    Logger.log("Sync Error: " + err.message);
  } finally {
    if (pstmt) { try { pstmt.close(); } catch(e) {} }
    if (conn) { try { conn.close(); } catch(e) {} }
  }
}

/**
 * Programmatically resolves the active week tab.
 * (Fix 3.2: Never defaults to January 2025 in headless time-driven background triggers)
 */
function resolveActiveWeekTab(ss) {
  const unified = ss.getSheetByName("Unified_Traffic_Challan_source");
  if (unified) return unified;

  const sheets = ss.getSheets();
  for (let i = sheets.length - 1; i >= 0; i--) {
    const name = sheets[i].getName();
    if (!name.toLowerCase().includes("form responses") && !name.toLowerCase().includes("template") && !name.toLowerCase().includes("summary")) {
      return sheets[i];
    }
  }
  return sheets[0];
}

/**
 * Syncs active/current open tab.
 * (Fix 3.2: Programmatic active week tab resolution in headless execution)
 */
function syncCurrentWeekTab() {
  const ss = getTargetSpreadsheet();
  const sheet = resolveActiveWeekTab(ss);
  if (!sheet) return;

  Logger.log("Resolved target sync tab: " + sheet.getName());

  let conn = null;
  let pstmt = null;
  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    pstmt = conn.prepareStatement(UPSERT_SQL);

    const result = syncSheetTab(sheet, conn, pstmt);
    Logger.log("Tab " + sheet.getName() + " synced: " + result.synced + " rows.");
  } catch(err) {
    if (conn) { try { conn.rollback(); } catch(e) {} }
    Logger.log("Sync Error: " + err.message);
  } finally {
    if (pstmt) { try { pstmt.close(); } catch(e) {} }
    if (conn) { try { conn.close(); } catch(e) {} }
  }
}

/**
 * Live single-row and multi-row edit handler on active tab.
 * (Fix 3.6: Loops from e.range.getRow() to e.range.getLastRow() for multi-row copy pastes)
 */
function handleOnEdit(e) {
  if (!e || !e.range) return;
  const sheet = e.range.getSheet();
  const startRow = Math.max(3, e.range.getRow());
  const endRow = e.range.getLastRow();

  const name = sheet.getName();
  const lastCol = sheet.getLastColumn();
  const headers = sheet.getRange(1, 1, Math.min(4, startRow - 1), lastCol).getValues();

  // Find header
  let hRow = null;
  let headerVals = null;
  for (let r = 0; r < headers.length; r++) {
    const strVals = headers[r].map(v => String(v || "").toLowerCase());
    if (strVals.some(v => v.includes("reg") || v.includes("vehicle"))) {
      hRow = r + 1;
      headerVals = headers[r];
      break;
    }
  }
  if (!hRow || !headerVals) return;

  const colMap = getWeeklyColMap(headerVals);
  if (!colMap['reg_no']) return;

  let conn = null;
  let pstmt = null;
  try {
    conn = getDbConnection();
    pstmt = conn.prepareStatement(UPSERT_SQL);
    for (let r = startRow; r <= endRow; r++) {
      const rowValues = sheet.getRange(r, 1, 1, lastCol).getValues()[0];
      if (bindChallanRow(pstmt, rowValues, r, name, colMap)) {
        pstmt.executeUpdate();
      }
    }
    Logger.log("Successfully synced edited rows " + startRow + " to " + endRow + " from tab " + name);
  } catch(err) {
    Logger.log("handleOnEdit error: " + err.message);
  } finally {
    if (pstmt) { try { pstmt.close(); } catch(e) {} }
    if (conn) { try { conn.close(); } catch(e) {} }
  }
}

/**
 * High-performance batch synchronization directly from 'Unified_Traffic_Challan_source'.
 */
function syncUnifiedChallansMasterToPostgres() {
  const ss = getTargetSpreadsheet();
  const sheet = ss.getSheetByName("Unified_Traffic_Challan_source") || resolveActiveWeekTab(ss);
  const lastRow = sheet.getLastRow();
  const lastCol = sheet.getLastColumn();
  
  if (lastRow <= 1) {
    Logger.log("No data rows found in " + sheet.getName());
    return;
  }
  
  Logger.log("Starting batch sync from " + sheet.getName() + " (" + (lastRow - 1) + " rows)...");
  
  let conn = null;
  let pstmt = null;
  let totalSynced = 0;
  const BATCH_SIZE = 500;
  
  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    pstmt = conn.prepareStatement(UPSERT_SQL);
    
    const CHUNK_SIZE = 5000;
    const totalDataRows = lastRow - 1;
    
    for (let offset = 0; offset < totalDataRows; offset += CHUNK_SIZE) {
      const rowsToFetch = Math.min(CHUNK_SIZE, totalDataRows - offset);
      const startRow = offset + 2;
      const data = sheet.getRange(startRow, 1, rowsToFetch, lastCol).getValues();
      
      let pendingBatch = 0;
      for (let i = 0; i < data.length; i++) {
        const row = data[i];
        const currentRowNum = startRow + i;
        
        const sourceTab = cleanStr(row[0]) || "Unified_Traffic_Challan_source";
        const sourceRow = parseInt(row[1]) || currentRowNum;
        const regNo = cleanPlate(row[2]);
        if (!regNo) continue;
        
        let noticeNo = cleanStr(row[3]);
        const city = cleanCity(row[4], regNo);
        const weekCycle = cleanStr(row[5]) || sourceTab;
        
        const prevBal = cleanNum(row[6]);
        const auditDate = parseDate(row[7]);
        const noticeDate = parseDate(row[8]);
        const vioDate = parseDate(row[9]);
        const vioTime = parseTime(row[10]);
        
        let fineAmt = cleanNum(row[11]);
        const rawCityVal = cleanStr(row[4]);
        if (fineAmt === 0 && rawCityVal && !isNaN(parseFloat(rawCityVal))) {
          fineAmt = cleanNum(rawCityVal);
        }

        const stkFine = cleanNum(row[12]);
        const amtPaid = cleanNum(row[13]);
        const totPend = cleanNum(row[14]);
        const remarks = cleanStr(row[15]);
        
        const timeSuffix = vioTime ? vioTime.replace(/:/g, "") : "0000";
        if (!noticeNo) {
          noticeNo = (vioDate || fineAmt > 0)
            ? `NOT-${regNo}-${vioDate || auditDate || weekCycle}-${timeSuffix}-${sourceRow}`
            : `BAL-${regNo}-${weekCycle}-${sourceRow}`;
        }
        
        let p = 1;
        pstmt.setString(p++, regNo); // 1. vehicle_reg_no
        pstmt.setString(p++, noticeNo); // 2. notice_no
        pstmt.setString(p++, city); // 3. city
        pstmt.setString(p++, weekCycle); // 4. week_cycle
        
        pstmt.setDouble(p++, prevBal); // 5. previous_balance
        if (auditDate) pstmt.setString(p++, auditDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 6. audit_date
        
        if (noticeDate) pstmt.setString(p++, noticeDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 7. notice_date
        if (vioDate) pstmt.setString(p++, vioDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 8. violation_date
        if (vioTime) pstmt.setString(p++, vioTime); else pstmt.setNull(p++, SQL_TYPES.TIME); // 9. violation_time
        
        pstmt.setDouble(p++, fineAmt); // 10. challan_amount
        pstmt.setDouble(p++, stkFine); // 11. sticker_fine
        pstmt.setDouble(p++, amtPaid); // 12. amount_paid
        pstmt.setDouble(p++, totPend); // 13. total_pending
        pstmt.setString(p++, remarks); // 14. remarks
        
        pstmt.setString(p++, sourceTab); // 15. source_tab
        pstmt.setInt(p++, sourceRow); // 16. sheet_row_number
        
        pstmt.addBatch();
        pendingBatch++;
        totalSynced++;
        
        if (pendingBatch >= BATCH_SIZE) {
          pstmt.executeBatch();
          conn.commit();
          pendingBatch = 0;
          Logger.log("Synced " + totalSynced + " / " + totalDataRows + " rows...");
        }
      }
      
      if (pendingBatch > 0) {
        pstmt.executeBatch();
        conn.commit();
      }
    }
    
    Logger.log("Consolidated Ingestion Complete! Total Synced: " + totalSynced);
  } catch(err) {
    if (conn) { try { conn.rollback(); } catch(e) {} }
    Logger.log("Ingestion Failed: " + err.message);
  } finally {
    if (pstmt) { try { pstmt.close(); } catch(e) {} }
    if (conn) { try { conn.close(); } catch(e) {} }
  }
}

/**
 * Installs automated triggers.
 */
function setupTriggers() {
  deleteAllTriggers();
  const ss = getTargetSpreadsheet();

  ScriptApp.newTrigger("handleOnEdit")
    .forSpreadsheet(ss)
    .onEdit()
    .create();

  ScriptApp.newTrigger("syncCurrentWeekTab")
    .timeBased()
    .everyHours(1)
    .create();

  Logger.log("Automated triggers installed.");
}

/**
 * Cleanly removes only challan pipeline triggers.
 * (Fix 3.7: Protects other project triggers from accidental deletion)
 */
function deleteAllTriggers() {
  const triggers = ScriptApp.getProjectTriggers();
  const challanHandlers = [
    "handleOnEdit",
    "syncCurrentWeekTab",
    "syncAllChallanTabs",
    "syncUnifiedChallansMasterToPostgres"
  ];
  
  for (let i = 0; i < triggers.length; i++) {
    const handler = triggers[i].getHandlerFunction();
    if (challanHandlers.indexOf(handler) !== -1) {
      ScriptApp.deleteTrigger(triggers[i]);
    }
  }
}
