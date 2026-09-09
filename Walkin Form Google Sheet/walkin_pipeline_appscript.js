/**
 * ==============================================================================
 * LETZRYD - GOOGLE SHEET TO POSTGRES LIVE PIPELINE (sheet_walkins)
 * ==============================================================================
 * 
 * Target Table : public.sheet_walkins
 * Host         : YOUR_DB_HOST_HERE:5432
 * Features:
 *  - Real-time live updates on cell edit (handleOnEdit) and form submit (handleOnFormSubmit)
 *  - Multi-row paste resilience (processes all pasted rows in a single batch)
 *  - Time-Driven Catch-Up Sync (syncRecentWalkins & syncAllWalkins)
 *  - Complete connection leak prevention (try-catch-finally on all statements/connections)
 *  - Transaction rollback on batch errors (conn.rollback())
 *  - Standard SQL CAST (? AS timestamptz / CAST(? AS date)) compatible with Postgres JDBC
 *  - Native Apps Script JDBC Types dictionary (bypassing missing java.sql.Types)
 *  - Multi-format Date/Timestamp parser (handles JS Date, serial numbers, DD/MM/YYYY, ISO)
 *  - Phone number float & scientific notation normalization
 *  - Greek homoglyph replacement (Greek Kappa/Alpha to ASCII K/A)
 *  - Filter & Sort Immunity (Keyed on composite submission_timestamp + partner_number)
 *  - Clean UI and logs with zero emojis
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
const DB_CONFIG = {
  host: "YOUR_DB_HOST_HERE",
  port: "5432",
  database: "postgres",
  user: "postgres",
  password: "YOUR_DB_PASSWORD_HERE",
  
  // Optional URL if running in a standalone script bound to another file:
  sheetUrl: "YOUR_SPREADSHEET_URL_HERE",
  
  // Target tab name:
  sheetName: "walkin_form"
};

// Standard JDBC SQL Type Codes (Apps Script does not expose java.sql.Types)
const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  TIMESTAMP: 93,
  INTEGER: 4,
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
 * Returns the target Sheet instance, with graceful fallback.
 */
function getTargetSheet(ss) {
  if (!ss) return null;
  if (DB_CONFIG.sheetName && DB_CONFIG.sheetName.trim() !== "") {
    const sheet = ss.getSheetByName(DB_CONFIG.sheetName);
    if (sheet) return sheet;
  }
  return ss.getSheets()[0];
}

/**
 * Creates custom UI menu in Google Sheets on load.
 */
function onOpen() {
  try {
    SpreadsheetApp.getUi().createMenu("LetzRyd Pipeline")
      .addItem("Sync Entire Sheet to Postgres", "syncAllWalkins")
      .addItem("Sync Recent 50 Rows", "syncRecentWalkins")
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
    rs = stmt.executeQuery("SELECT count(*) FROM sheet_walkins;");
    rs.next();
    const count = rs.getInt(1);
    
    Logger.log("Connection Successful. Current rows in sheet_walkins: " + count);
    try {
      SpreadsheetApp.getUi().alert(
        "Connection Successful",
        "Connected to PostgreSQL on " + DB_CONFIG.host + ".\nCurrent rows in sheet_walkins: " + count,
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

// --- UNIVERSAL CLEANING & STANDARDIZATION FUNCTIONS ---

function cleanStr(val) {
  if (val === null || val === undefined) return null;
  const s = String(val).replace(/[`'"]/g, "").trim().replace(/\s+/g, " ");
  return (s === "" || s.toLowerCase() === "nan") ? null : s;
}

// Universal accented character & Greek homoglyph normalization
function unaccent(val) {
  if (!val) return val;
  let s = String(val);
  // Replace Greek homoglyphs (Greek Kappa and Alpha)
  s = s.replace(/\u039A/g, 'K').replace(/\u0391/g, 'A').replace(/\u03BA/g, 'k').replace(/\u03B1/g, 'a');
  return s.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
}

function cleanCity(val) {
  const s = cleanStr(val);
  if (!s) return null;
  const low = s.toLowerCase();
  if (low.includes("hyd")) return "Hyderabad";
  if (low.includes("mum")) return "Mumbai";
  if (low.includes("blr") || low.includes("bang") || low.includes("beng")) return "Bengaluru";
  return s.split(" ").map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(" ");
}

// Attending Executive: Clean whitespace, fix casing and known typos without merging distinct staff
function cleanExecutive(val) {
  const raw = cleanStr(val);
  if (!raw) return "Unknown";
  
  const norm = raw.toLowerCase().replace(/[^a-z]/g, "");
  const canonicalMap = {
    "shaikabdulla": "Shaik Abdulla",
    "abdullashaik": "Shaik Abdulla",
    "shaikadulla": "Shaik Abdulla",
    "shaikbdulla": "Shaik Abdulla",
    "radhakrishna": "Radha Krishna",
    "psradhakrishna": "Radha Krishna",
    "radhakirshna": "Radha Krishna",
    "radha": "Radha Krishna"
  };
  
  if (canonicalMap[norm]) {
    return canonicalMap[norm];
  }
  return raw.split(" ").map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(" ");
}

// Partner Name: Uppercase, unaccented, trim spaces. Preserves all names (including 'NA').
function cleanPartnerName(val) {
  const s = cleanStr(val);
  if (!s) return "UNKNOWN";
  return unaccent(s).toUpperCase();
}

// Partner Number: Handles float strings, scientific notation, extracts 10 digits
function cleanPhone(val) {
  if (val === null || val === undefined) return "0000000000";
  let s = String(val).trim();
  // Strip trailing float zeros (e.g. "9845261331.0" or "9845261331.00")
  s = s.replace(/\.0+$/, "");
  // Handle scientific notation (e.g. 9.84526E+09)
  if (/^\d+(\.\d+)?e\+\d+$/i.test(s)) {
    s = Number(s).toFixed(0);
  }
  const digits = s.replace(/\D/g, "");
  return digits.length >= 10 ? digits.slice(-10) : digits.padStart(10, "0");
}

// DL Number: Unaccented, uppercase, strips hyphens/spaces. Converts placeholders to NULL.
function cleanDL(val) {
  const s = cleanStr(val);
  if (!s) return null;
  const cleaned = unaccent(s).replace(/[\s\-_]/g, "").toUpperCase();
  const placeholders = ["", "NA", "NAA", "N/A", "NONE", "NIL", "NULL", "-", "--"];
  if (placeholders.includes(cleaned)) return null;
  return cleaned;
}

function cleanReason(val) {
  return cleanStr(val);
}

function cleanStatus(val) {
  const s = cleanStr(val);
  if (!s) return null;
  const low = s.toLowerCase();
  if (low === "joined") return "Joined";
  if (low === "false") return "False";
  return s.charAt(0).toUpperCase() + s.slice(1);
}

// Joined Date: Handles Date objects, Google Sheets serial numbers, DD/MM/YYYY, and YYYY-MM-DD
function cleanDate(val) {
  if (val === null || val === undefined) return null;
  if (val instanceof Date && !isNaN(val.getTime())) {
    return Utilities.formatDate(val, "Asia/Kolkata", "yyyy-MM-dd");
  }
  // Check if Google Sheets numeric date serial
  if (typeof val === "number" || (!isNaN(Number(val)) && Number(val) > 30000 && Number(val) < 60000)) {
    const num = Number(val);
    const d = new Date(Math.round((num - 25569) * 86400 * 1000));
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
  }
  const s = String(val).trim();
  if (["", "-", "--", "na", "n/a", "none", "nan", "nat", "nil", "null"].includes(s.toLowerCase())) {
    return null;
  }
  // Check DD/MM/YYYY or DD-MM-YYYY
  const dmyMatch = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/);
  if (dmyMatch) {
    const day = parseInt(dmyMatch[1], 10);
    const month = parseInt(dmyMatch[2], 10) - 1;
    const year = parseInt(dmyMatch[3], 10);
    const d = new Date(year, month, day);
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
  }
  // Check YYYY-MM-DD
  const ymdMatch = s.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})$/);
  if (ymdMatch) {
    const year = parseInt(ymdMatch[1], 10);
    const month = parseInt(ymdMatch[2], 10) - 1;
    const day = parseInt(ymdMatch[3], 10);
    const d = new Date(year, month, day);
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
  }
  const parsed = new Date(s);
  return isNaN(parsed.getTime()) ? null : Utilities.formatDate(parsed, "Asia/Kolkata", "yyyy-MM-dd");
}

// Timestamp: Handles Date objects, serial numbers, Indian DD/MM/YYYY HH:mm:ss, and ISO strings
function cleanTimestamp(val) {
  if (val === null || val === undefined || val === "") {
    return Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  if (val instanceof Date && !isNaN(val.getTime())) {
    return Utilities.formatDate(val, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  // Check if Google Sheets numeric timestamp serial
  if (typeof val === "number" || (!isNaN(Number(val)) && Number(val) > 30000 && Number(val) < 60000)) {
    const num = Number(val);
    const d = new Date(Math.round((num - 25569) * 86400 * 1000));
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  const s = String(val).trim();
  // Check DD/MM/YYYY HH:mm[:ss]
  const dmyTsMatch = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$/);
  if (dmyTsMatch) {
    const day = parseInt(dmyTsMatch[1], 10);
    const month = parseInt(dmyTsMatch[2], 10) - 1;
    const year = parseInt(dmyTsMatch[3], 10);
    const hours = dmyTsMatch[4] ? parseInt(dmyTsMatch[4], 10) : 0;
    const minutes = dmyTsMatch[5] ? parseInt(dmyTsMatch[5], 10) : 0;
    const seconds = dmyTsMatch[6] ? parseInt(dmyTsMatch[6], 10) : 0;
    const d = new Date(year, month, day, hours, minutes, seconds);
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  // Check YYYY-MM-DD HH:mm[:ss]
  const ymdTsMatch = s.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$/);
  if (ymdTsMatch) {
    const year = parseInt(ymdTsMatch[1], 10);
    const month = parseInt(ymdTsMatch[2], 10) - 1;
    const day = parseInt(ymdTsMatch[3], 10);
    const hours = ymdTsMatch[4] ? parseInt(ymdTsMatch[4], 10) : 0;
    const minutes = ymdTsMatch[5] ? parseInt(ymdTsMatch[5], 10) : 0;
    const seconds = ymdTsMatch[6] ? parseInt(ymdTsMatch[6], 10) : 0;
    const d = new Date(year, month, day, hours, minutes, seconds);
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  const parsed = new Date(s);
  if (!isNaN(parsed.getTime())) {
    return Utilities.formatDate(parsed, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  Logger.log("Warning: Unrecognized timestamp format '" + s + "', falling back to current time.");
  return Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
}

// --- DATABASE UPSERT SQL (ZERO-BURN CTE SYNTAX: ELIMINATES SEQUENCE GAPS) ---
const UPSERT_SQL = `
WITH incoming AS (
    SELECT 
        CAST(? AS timestamptz) AS ts,
        CAST(? AS varchar) AS email,
        CAST(? AS varchar) AS city,
        CAST(? AS varchar) AS exec,
        CAST(? AS varchar) AS name,
        CAST(? AS varchar) AS phone,
        CAST(? AS varchar) AS dl,
        CAST(? AS text) AS reason,
        CAST(? AS text) AS remarks,
        CAST(? AS date) AS jDate,
        CAST(? AS varchar) AS jStatus,
        CAST(? AS integer) AS sheetRow
),
upd AS (
    UPDATE sheet_walkins w
    SET 
        submitter_email = i.email,
        city = i.city,
        attending_executive = i.exec,
        partner_name = i.name,
        dl_number = i.dl,
        visiting_reason = i.reason,
        remarks = i.remarks,
        joined_date = i.jDate,
        joined_status = i.jStatus,
        sheet_row_number = i.sheetRow,
        updated_at = CURRENT_TIMESTAMP
    FROM incoming i
    WHERE w.submission_timestamp = i.ts 
      AND w.partner_number = i.phone
    RETURNING w.id
)
INSERT INTO sheet_walkins (
    id, submission_timestamp, submitter_email, city, attending_executive,
    partner_name, partner_number, dl_number, visiting_reason, remarks,
    joined_date, joined_status, sheet_row_number, updated_at
)
SELECT 
    nextval('sheet_walkins_id_seq'),
    i.ts, i.email, i.city, i.exec,
    i.name, i.phone, i.dl, i.reason, i.remarks,
    i.jDate, i.jStatus, i.sheetRow, CURRENT_TIMESTAMP
FROM incoming i
WHERE NOT EXISTS (SELECT 1 FROM upd);
`;

function transformRow(row, rowIndex) {
  return {
    ts: cleanTimestamp(row[0]),
    email: cleanStr(row[1]) ? cleanStr(row[1]).toLowerCase() : null,
    city: cleanCity(row[2]),
    exec: cleanExecutive(row[3]),
    name: cleanPartnerName(row[4]),
    phone: cleanPhone(row[5]),
    dl: cleanDL(row[6]),
    reason: cleanReason(row[7]),
    remarks: cleanStr(row[8]),
    jDate: cleanDate(row[9]),
    jStatus: cleanStatus(row[10]),
    sheetRow: rowIndex
  };
}

function bindParams(stmt, d) {
  stmt.setString(1, d.ts);
  d.email ? stmt.setString(2, d.email) : stmt.setNull(2, SQL_TYPES.VARCHAR);
  d.city ? stmt.setString(3, d.city) : stmt.setNull(3, SQL_TYPES.VARCHAR);
  stmt.setString(4, d.exec);
  stmt.setString(5, d.name);
  stmt.setString(6, d.phone);
  d.dl ? stmt.setString(7, d.dl) : stmt.setNull(7, SQL_TYPES.VARCHAR);
  d.reason ? stmt.setString(8, d.reason) : stmt.setNull(8, SQL_TYPES.VARCHAR);
  d.remarks ? stmt.setString(9, d.remarks) : stmt.setNull(9, SQL_TYPES.VARCHAR);
  d.jDate ? stmt.setString(10, d.jDate) : stmt.setNull(10, SQL_TYPES.DATE);
  d.jStatus ? stmt.setString(11, d.jStatus) : stmt.setNull(11, SQL_TYPES.VARCHAR);
  stmt.setInt(12, d.sheetRow);
}

// --- LIVE REAL-TIME EVENT HANDLER ---

/**
 * Triggered on cell edits. Supports multi-row pastes and isolates target tab/columns.
 * Immune to sheet filtering and sorting because records are keyed on (submission_timestamp, partner_number).
 */
function handleOnEdit(e) {
  let conn = null;
  let stmt = null;
  try {
    if (!e || !e.range) return;
    
    // Ignore edits completely outside data columns A:K (columns 1 to 11)
    if (e.range.getLastColumn() < 1 || e.range.getColumn() > 11) return;
    
    const sheet = e.range.getSheet();
    // Tab isolation check: always return early if editing a different tab
    if (DB_CONFIG.sheetName && sheet.getName() !== DB_CONFIG.sheetName) {
      return;
    }
    
    const startRow = Math.max(2, e.range.getRow()); // Skip header
    const endRow = e.range.getLastRow();
    if (startRow > endRow) return;
    
    const numRows = endRow - startRow + 1;
    const data = sheet.getRange(startRow, 1, numRows, 11).getValues();
    
    conn = getDbConnection();
    conn.setAutoCommit(false);
    stmt = conn.prepareStatement(UPSERT_SQL);
    
    let batchCount = 0;
    for (let i = 0; i < data.length; i++) {
      const row = data[i];
      if (!row[0] && !row[5]) continue; // Skip blank rows
      const d = transformRow(row, startRow + i);
      bindParams(stmt, d);
      stmt.addBatch();
      batchCount++;
    }
    
    if (batchCount > 0) {
      stmt.executeBatch();
      conn.commit();
      Logger.log("Successfully synced " + batchCount + " edited row(s) to Postgres.");
    }
  } catch (err) {
    if (conn) {
      try { conn.rollback(); } catch (rbErr) {}
    }
    Logger.log("handleOnEdit error: " + err.message);
  } finally {
    if (stmt) { try { stmt.close(); } catch (e) {} }
    if (conn) { try { conn.close(); } catch (e) {} }
  }
}

function handleOnFormSubmit(e) {
  try {
    if (!e || !e.range) return;
    handleOnEdit(e);
  } catch (err) {
    Logger.log("handleOnFormSubmit error: " + err.message);
  }
}

// --- FULL AND INCREMENTAL SYNC ---

function syncAllWalkins() {
  SpreadsheetApp.flush();
  const ss = getTargetSpreadsheet();
  if (!ss) {
    Logger.log("Could not access spreadsheet.");
    return;
  }
  const sheet = getTargetSheet(ss);
  if (!sheet) {
    Logger.log("syncAllWalkins: Target sheet not found. Aborting.");
    return;
  }
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) {
    Logger.log("No data rows found.");
    return;
  }

  // Scan backwards up to 500 rows to find true last populated row (immune to trailing formula blanks)
  const scanStart = Math.max(1, lastRow - 500);
  const scanCount = lastRow - scanStart + 1;
  const checkRange = sheet.getRange(scanStart, 1, scanCount, 6).getValues();
  let trueLastRow = lastRow;
  for (let r = checkRange.length - 1; r >= 0; r--) {
    const row = checkRange[r];
    if ((row[0] && String(row[0]).trim() !== "") || (row[5] && String(row[5]).trim() !== "")) {
      trueLastRow = scanStart + r;
      break;
    }
  }
  if (trueLastRow <= 1) {
    Logger.log("No data rows found.");
    return;
  }

  const data = sheet.getRange(2, 1, trueLastRow - 1, 11).getValues();
  let conn = null;
  let stmt = null;
  let synced = 0;
  let uncommitted = 0;

  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    stmt = conn.prepareStatement(UPSERT_SQL);

    for (let i = 0; i < data.length; i++) {
      const row = data[i];
      if (!row[0] && !row[5]) continue;
      const d = transformRow(row, i + 2);
      bindParams(stmt, d);
      stmt.addBatch();
      synced++;
      uncommitted++;

      if (uncommitted >= 200) {
        stmt.executeBatch();
        conn.commit();
        uncommitted = 0;
      }
    }

    if (uncommitted > 0) {
      stmt.executeBatch();
      conn.commit();
      uncommitted = 0;
    }

    Logger.log("Full sync complete. Synced " + synced + " records.");
  } catch (err) {
    if (conn) {
      try { conn.rollback(); } catch (rbErr) {}
    }
    Logger.log("syncAllWalkins error: " + err.message);
    throw err;
  } finally {
    if (stmt) { try { stmt.close(); } catch (e) {} }
    if (conn) { try { conn.close(); } catch (e) {} }
  }
}

function syncRecentWalkins() {
  // Prevent concurrent executions if 1-min trigger overlaps a slow run (wait up to 15s)
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(15000)) {
    Logger.log("syncRecentWalkins: Another sync is currently running or lock busy. Skipping this cycle.");
    return;
  }
  try {
    SpreadsheetApp.flush(); // Force recalculation of IMPORTRANGE formulas
    const ss = getTargetSpreadsheet();
    if (!ss) {
      Logger.log("Could not access spreadsheet.");
      return;
    }
    const sheet = getTargetSheet(ss);
    if (!sheet) {
      Logger.log("syncRecentWalkins: Target sheet not found. Aborting.");
      return;
    }
    const lastRow = sheet.getLastRow();
    if (lastRow <= 1) return;

    // Scan backwards up to 500 rows to find true last populated row (immune to trailing formula blanks)
    const scanStart = Math.max(1, lastRow - 500);
    const scanCount = lastRow - scanStart + 1;
    const checkRange = sheet.getRange(scanStart, 1, scanCount, 6).getValues();
    let trueLastRow = 0;
    for (let r = checkRange.length - 1; r >= 0; r--) {
      const row = checkRange[r];
      if ((row[0] && String(row[0]).trim() !== "") || (row[5] && String(row[5]).trim() !== "")) {
        trueLastRow = scanStart + r;
        break;
      }
    }
    if (trueLastRow <= 1) return;

    const startRow = Math.max(2, trueLastRow - 60);
    const numRows = trueLastRow - startRow + 1;
    const data = sheet.getRange(startRow, 1, numRows, 11).getValues();

    let conn = null;
    let stmt = null;
    let batchCount = 0;

    try {
      conn = getDbConnection();
      conn.setAutoCommit(false);
      stmt = conn.prepareStatement(UPSERT_SQL);

      for (let i = 0; i < data.length; i++) {
        const row = data[i];
        if (!row[0] && !row[5]) continue;
        bindParams(stmt, transformRow(row, startRow + i));
        stmt.addBatch();
        batchCount++;
      }

      if (batchCount > 0) {
        stmt.executeBatch();
        conn.commit();
      }
      Logger.log("Synced recent " + batchCount + " rows to Postgres.");
    } catch (err) {
      if (conn) {
        try { conn.rollback(); } catch (rbErr) {}
      }
      Logger.log("syncRecentWalkins error: " + err.message);
      throw err;
    } finally {
      if (stmt) { try { stmt.close(); } catch (e) {} }
      if (conn) { try { conn.close(); } catch (e) {} }
    }
  } finally {
    lock.releaseLock();
  }
}

// --- AUTOMATED TRIGGER SETUP & MANAGEMENT ---

/**
 * Automatically creates all required triggers programmatically:
 * 1. onEdit (for manual cell edits)
 * 2. onFormSubmit (for live Google Form submissions)
 * 3. Time-driven (every 1 minute catch-up daemon)
 */
function setupTriggers() {
  const ss = getTargetSpreadsheet();
  if (!ss) {
    Logger.log("setupTriggers error: Could not access spreadsheet.");
    return;
  }

  // Remove existing triggers for these functions to avoid duplicates
  deleteAllTriggers();

  // 1. Create Real-Time On-Edit Trigger (for manual typing/pasting)
  ScriptApp.newTrigger("handleOnEdit")
    .forSpreadsheet(ss)
    .onEdit()
    .create();

  // 2. Create Real-Time On-Form-Submit Trigger (for Google Form responses)
  try {
    ScriptApp.newTrigger("handleOnFormSubmit")
      .forSpreadsheet(ss)
      .onFormSubmit()
      .create();
    Logger.log("Created onFormSubmit trigger.");
  } catch (formErr) {
    Logger.log("Note on onFormSubmit: " + formErr.message);
  }

  // 3. Create 1-Minute Time-Driven Catch-Up Trigger
  ScriptApp.newTrigger("syncRecentWalkins")
    .timeBased()
    .everyMinutes(1)
    .create();

  Logger.log("Automated triggers successfully created and activated!");
}

/**
 * Removes all triggers associated with this pipeline.
 */
function deleteAllTriggers() {
  const triggers = ScriptApp.getProjectTriggers();
  let count = 0;
  for (let i = 0; i < triggers.length; i++) {
    const fn = triggers[i].getHandlerFunction();
    if (fn === "handleOnEdit" || fn === "syncRecentWalkins" || fn === "handleOnFormSubmit") {
      ScriptApp.deleteTrigger(triggers[i]);
      count++;
    }
  }
  Logger.log("Removed " + count + " existing trigger(s).");
}
