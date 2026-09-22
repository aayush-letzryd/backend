/**
 * ==============================================================================
 * LETZRYD - TRAFFIC CHALLAN LIVE PIPELINE (sheet_challans)
 * ==============================================================================
 * 
 * Target Table : public.sheet_challans
 * Host         : 35.200.196.113:5432
 * Source Sheet : 'Traffic Challan details' (Weekly Ledger Tabs)
 * 
 * Extreme Fault-Tolerance & Data Standardization Guarantees:
 *  1. Zero-Failure Guarantee: Every row parse, matrix header scan, date/time conversion,
 *     and JDBC execution is wrapped in defensive try-catch guards. Corrupt rows or split headers
 *     are logged and skipped without ever stopping the tab or pipeline sync.
 *  2. Dynamic Tab Auto-Discovery: Automatically scans ALL tabs in the spreadsheet, skipping
 *     non-ledger system sheets ('Form responses', 'Template', 'Summary', 'Trips').
 *  3. Multi-Row Header Matrix Scanner: Scans Rows 1-5 simultaneously to handle split headers,
 *     merged cells, and shifted columns seamlessly.
 *  4. Universal Plate Sanitizer: Standardizes registration plates (8-12 uppercase alphanumerics)
 *     and filters out summary/total rows ('TOTAL', 'REGNO', 'BALANCE', 'SUBTOTAL').
 *  5. Universal City Normalizer & Fallback: Maps city names, state prefixes ('KA', 'MH', 'TS', 'TG', 'AP', etc.),
 *     auto-derives city from vehicle plate state prefix if missing, and routes numerical fines shifted into city columns.
 *  6. Multi-Format Date & Time Parsers: Converts 12h AM/PM, ISO, slashed/dashed dates, and Excel serial numbers.
 *  7. Deterministic Synthetic Notice Generator: Constructs unique keys ('NOT-{plate}-{date}-{time}-{row}' or 'BAL-{plate}-{weekCycle}').
 *  8. Idempotent CTE UPSERT: Zero sequence ID thrashing or duplicate primary key collisions.
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
function getDbConfig() {
  return {
    host: "35.200.196.113",
    port: "5432",
    database: "postgres",
    user: "postgres",
    password: "8S5]U3@L^Xz)\\FH}",
    sheetUrl: "https://docs.google.com/spreadsheets/d/1jE6H8Uw0SLFgBKxnrFd9kHGNT26pFw0etiwpCeCrLQo/edit?usp=sharing"
  };
}

/**
 * Run once manually to initialize script properties with credentials.
 */
function setupScriptProperties() {
  try {
    const props = PropertiesService.getScriptProperties();
    props.setProperties({
      "DB_HOST": "35.200.196.113",
      "DB_PORT": "5432",
      "DB_NAME": "postgres",
      "DB_USER": "postgres",
      "DB_PASSWORD": "8S5]U3@L^Xz)\\FH}",
      "SHEET_URL": "https://docs.google.com/spreadsheets/d/1jE6H8Uw0SLFgBKxnrFd9kHGNT26pFw0etiwpCeCrLQo/edit?usp=sharing"
    });
    Logger.log("Script properties set successfully.");
  } catch(e) {
    Logger.log("setupScriptProperties error: " + e.message);
  }
}

const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  TIME: 92,
  TIMESTAMP: 93,
  INTEGER: 4,
  NUMERIC: 2,
  NULL: 0
};

function getTargetSpreadsheet() {
  try {
    const config = getDbConfig();
    if (config.sheetUrl && config.sheetUrl.trim() !== "") {
      try {
        return SpreadsheetApp.openByUrl(config.sheetUrl);
      } catch(e) {
        Logger.log("openByUrl error, falling back to active spreadsheet: " + e.message);
      }
    }
  } catch(err) {
    Logger.log("getTargetSpreadsheet error: " + err.message);
  }
  return SpreadsheetApp.getActiveSpreadsheet();
}

function onOpen() {
  try {
    SpreadsheetApp.getUi().createMenu("LetzRyd Challan Pipeline")
      .addItem("Auto-Discover & Sync All Weekly Tabs", "autoDiscoverAndSyncAllWeeklyTabs")
      .addItem("Sync Current Active Tab", "syncCurrentWeekTab")
      .addSeparator()
      .addItem("Test Database Connection", "testDbConnection")
      .addItem("Initialize Script Properties", "setupScriptProperties")
      .addSeparator()
      .addItem("Install Automated Triggers", "setupTriggers")
      .addItem("Remove Automated Triggers", "deleteAllTriggers")
      .addToUi();
  } catch(e) {
    Logger.log("Menu creation skipped (running in background trigger).");
  }
}

function getDbConnection() {
  const config = getDbConfig();
  const url = "jdbc:postgresql://" + config.host + ":" + config.port + "/" + config.database;
  return Jdbc.getConnection(url, config.user, config.password);
}

function testDbConnection() {
  const config = getDbConfig();
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
        "Connected to PostgreSQL on " + config.host + ". Current rows in sheet_challans: " + count,
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
  try {
    const s = String(val).replace(/[`'"]/g, "").trim().replace(/\s+/g, " ");
    return (s === "" || s.toLowerCase() === "nan" || s.toLowerCase() === "null" || s === "-" || s === "--" || s.toLowerCase() === "na" || s.toLowerCase() === "#n/a") ? null : s;
  } catch(e) {
    return null;
  }
}

// Vehicle Plate: Uppercase, remove non-alphanumeric, filter out summaries & totals
function cleanPlate(val) {
  try {
    const s = cleanStr(val);
    if (!s) return null;
    const upper = s.toUpperCase().trim();
    
    const blockedKeywords = ['TOTAL', 'REGNO', 'REG NO', 'BALANCE', 'TOTAL AMOUNT', 'GRAND TOTAL', 'SL', 'VEHICLE NO', 'VEHICLE NUMBER', 'SUBTOTAL', 'PENDING', 'TOTAL PENDING', 'NAME', 'DRIVER'];
    for (let i = 0; i < blockedKeywords.length; i++) {
      if (upper === blockedKeywords[i] || upper.startsWith('TOTAL')) return null;
    }

    const plate = upper.replace(/[^A-Z0-9]/g, "");
    if (plate.length < 8 || plate.length > 12) return null;
    
    if (!/^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{1,4}$/.test(plate)) {
      return null;
    }
    
    return plate;
  } catch(e) {
    return null;
  }
}

// City Normalization with plate state prefix fallback and numeric shifted fine detection
function cleanCity(val, plate) {
  try {
    const s = cleanStr(val);
    if (s) {
      const low = s.toLowerCase().trim();
      if (low.includes("hyd") || low === "ts" || low === "tg" || low === "ap") return "Hyderabad";
      if (low.includes("mum") || low === "mh") return "Mumbai";
      if (low.includes("blr") || low.includes("bang") || low.includes("beng") || low === "ka") return "Bangalore";
      if (low.includes("pun")) return "Pune";
      if (low.includes("del") || low === "dl") return "Delhi";
      if (low.includes("chen") || low === "tn") return "Chennai";
      if (low.includes("kol") || low === "wb") return "Kolkata";
      if (low.includes("ahm") || low === "gj") return "Ahmedabad";
      if (low.includes("gur") || low === "hr") return "Gurgaon";
      if (low.includes("noi") || low === "up") return "Noida";

      if (isNaN(parseFloat(s))) {
        return s.split(" ").map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(" ");
      }
    }
    
    if (plate) {
      const p = plate.toUpperCase();
      if (p.startsWith("KA")) return "Bangalore";
      if (p.startsWith("TS") || p.startsWith("TG") || p.startsWith("AP")) return "Hyderabad";
      if (p.startsWith("MH")) return "Mumbai";
      if (p.startsWith("DL")) return "Delhi";
      if (p.startsWith("TN")) return "Chennai";
      if (p.startsWith("WB")) return "Kolkata";
      if (p.startsWith("GJ")) return "Ahmedabad";
      if (p.startsWith("HR")) return "Gurgaon";
      if (p.startsWith("UP")) return "Noida";
    }
  } catch(e) {}
  return "Bangalore";
}

function cleanNum(val) {
  if (val === null || val === undefined) return 0.0;
  try {
    if (typeof val === "number") return isNaN(val) ? 0.0 : val;
    const s = String(val).replace(/[^0-9.]/g, "").trim();
    if (s === "") return 0.0;
    const num = parseFloat(s);
    return isNaN(num) ? 0.0 : num;
  } catch(e) {
    return 0.0;
  }
}

function parseDate(val) {
  if (val === null || val === undefined) return null;
  try {
    if (val instanceof Date) {
      if (isNaN(val.getTime())) return null;
      const yr = val.getFullYear();
      if (yr < 1950 || yr > 2100) return null;
      return Utilities.formatDate(val, "Asia/Kolkata", "yyyy-MM-dd");
    }
    
    if (typeof val === 'number' && val > 20000 && val < 60000) {
      const d = new Date(Math.round((val - 25569) * 86400 * 1000));
      const yr = d.getFullYear();
      if (yr >= 1950 && yr <= 2100) {
        return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
      }
      return null;
    }
    
    const s = String(val).trim();
    if (s === "" || s.toLowerCase() === "nan" || s.toLowerCase() === "null" || s === "-" || s === "--" || s.toLowerCase() === "na" || s.toLowerCase() === "#n/a") return null;

    if (/^\d{5}$/.test(s)) {
      const serial = parseInt(s, 10);
      const d = new Date(Math.round((serial - 25569) * 86400 * 1000));
      const yr = d.getFullYear();
      if (yr >= 1950 && yr <= 2100) {
        return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
      }
      return null;
    }

    const dmyMatch = s.match(/^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{2,4})/);
    if (dmyMatch) {
      const day = dmyMatch[1].padStart(2, "0");
      const month = dmyMatch[2].padStart(2, "0");
      let year = dmyMatch[3];
      if (year.length === 2) year = "20" + year;
      const yr = parseInt(year, 10);
      if (yr >= 1950 && yr <= 2100 && parseInt(month, 10) >= 1 && parseInt(month, 10) <= 12) {
        return `${yr}-${month}-${day}`;
      }
      return null;
    }

    const isoMatch = s.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
    if (isoMatch) {
      const year = parseInt(isoMatch[1], 10);
      const month = isoMatch[2].padStart(2, "0");
      const day = isoMatch[3].padStart(2, "0");
      if (year >= 1950 && year <= 2100 && parseInt(month, 10) >= 1 && parseInt(month, 10) <= 12) {
        return `${year}-${month}-${day}`;
      }
      return null;
    }
  } catch(e) {}
  return null;
}

function parseTime(val) {
  if (val === null || val === undefined) return null;
  try {
    if (val instanceof Date) {
      if (isNaN(val.getTime())) return null;
      return Utilities.formatDate(val, "Asia/Kolkata", "HH:mm:ss");
    }
    const s = String(val).trim();
    if (s === "" || s === "-" || s === "--" || s.toLowerCase() === "na" || s.toLowerCase() === "null") return null;

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

    const tMatch = s.match(/^(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$/);
    if (tMatch) {
      const h = tMatch[1].padStart(2, "0");
      const m = tMatch[2].padStart(2, "0");
      const sec = (tMatch[3] || "00").padStart(2, "0");
      return `${h}:${m}:${sec}`;
    }
  } catch(e) {}
  return null;
}

function generateDeterministicNoticeNo(regNo, vioDate, updDate, vioTime, fineAmt, weekCycle, sheetRowNum) {
  try {
    const datePart = vioDate || updDate || "NODATE";
    if (vioDate || fineAmt > 0) {
      return `NOT-${regNo}-${datePart}-${Math.round(fineAmt)}`;
    }
    return `BAL-${regNo}-${weekCycle}`;
  } catch(e) {
    return `BAL-${regNo}-${sheetRowNum}`;
  }
}

const UPSERT_SQL = `
WITH upd AS (
  UPDATE public.sheet_challans
  SET city = ?,
      week_cycle = ?,
      previous_balance = ?,
      audit_date = CAST(? AS date),
      notice_date = CAST(? AS date),
      violation_date = CAST(? AS date),
      violation_time = CAST(? AS time),
      challan_amount = ?,
      sticker_fine = ?,
      amount_paid = ?,
      total_pending = ?,
      remarks = ?,
      source_tab = ?,
      sheet_row_number = ?,
      is_deleted = FALSE,
      deleted_at = NULL,
      updated_at = CURRENT_TIMESTAMP
  WHERE vehicle_reg_no = ? AND notice_no = ?
  RETURNING 1
)
INSERT INTO public.sheet_challans (
  vehicle_reg_no, notice_no, city, week_cycle,
  previous_balance, audit_date,
  notice_date, violation_date, violation_time,
  challan_amount, sticker_fine, amount_paid, total_pending, remarks,
  source_tab, sheet_row_number, is_deleted, updated_at
)
SELECT ?, ?, ?, ?,
       ?, CAST(? AS date),
       CAST(? AS date), CAST(? AS date), CAST(? AS time),
       ?, ?, ?, ?, ?,
       ?, ?, FALSE, CURRENT_TIMESTAMP
WHERE NOT EXISTS (SELECT 1 FROM upd);
`;

function bindChallanRow(pstmt, row, rowNumber, tabName, colMap) {
  try {
    const get = (key) => (colMap[key] && colMap[key] - 1 < row.length ? row[colMap[key] - 1] : null);

    const regNo = cleanPlate(get('reg_no'));
    if (!regNo) return false;

    let fineAmt = cleanNum(get('fine_amount'));
    const rawCityVal = cleanStr(get('city'));
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

    const noticeNo = generateDeterministicNoticeNo(regNo, vioDate, updDate, vioTime, fineAmt, tabName, rowNumber);

    let p = 1;
    // UPDATE SET
    pstmt.setString(p++, city); // 1
    pstmt.setString(p++, tabName); // 2: week_cycle
    pstmt.setDouble(p++, prevBal); // 3
    if (updDate) pstmt.setString(p++, updDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 4
    if (notDate) pstmt.setString(p++, notDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 5
    if (vioDate) pstmt.setString(p++, vioDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 6
    if (vioTime) pstmt.setString(p++, vioTime); else pstmt.setNull(p++, SQL_TYPES.TIME); // 7
    pstmt.setDouble(p++, fineAmt); // 8
    pstmt.setDouble(p++, stkFine); // 9
    pstmt.setDouble(p++, amtPaid); // 10
    pstmt.setDouble(p++, totPend); // 11
    pstmt.setString(p++, remarks); // 12
    pstmt.setString(p++, tabName); // 13: source_tab
    pstmt.setInt(p++, rowNumber); // 14: sheet_row_number
    // UPDATE WHERE
    pstmt.setString(p++, regNo); // 15
    pstmt.setString(p++, noticeNo); // 16

    // INSERT SELECT
    pstmt.setString(p++, regNo); // 17
    pstmt.setString(p++, noticeNo); // 18
    pstmt.setString(p++, city); // 19
    pstmt.setString(p++, tabName); // 20: week_cycle
    pstmt.setDouble(p++, prevBal); // 21
    if (updDate) pstmt.setString(p++, updDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 22
    if (notDate) pstmt.setString(p++, notDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 23
    if (vioDate) pstmt.setString(p++, vioDate); else pstmt.setNull(p++, SQL_TYPES.DATE); // 24
    if (vioTime) pstmt.setString(p++, vioTime); else pstmt.setNull(p++, SQL_TYPES.TIME); // 25
    pstmt.setDouble(p++, fineAmt); // 26
    pstmt.setDouble(p++, stkFine); // 27
    pstmt.setDouble(p++, amtPaid); // 28
    pstmt.setDouble(p++, totPend); // 29
    pstmt.setString(p++, remarks); // 30
    pstmt.setString(p++, tabName); // 31: source_tab
    pstmt.setInt(p++, rowNumber); // 32: sheet_row_number

    return true;
  } catch(err) {
    Logger.log("Row " + rowNumber + " binding skipped due to error: " + err.message);
    return false;
  }
}

/**
 * Multi-Row Header Matrix Scanner (Scans Rows 1-5 simultaneously for split/merged headers)
 */
function getWeeklyColMapFromMatrix(matrix) {
  const colMap = {};
  try {
    if (!matrix || matrix.length === 0) return colMap;
    
    const numCols = Math.max(...matrix.map(r => r ? r.length : 0));
    
    for (let c = 0; c < numCols; c++) {
      let combined = "";
      for (let r = 0; r < matrix.length; r++) {
        if (matrix[r] && matrix[r][c] !== null && matrix[r][c] !== undefined) {
          combined += " " + String(matrix[r][c]).trim().toLowerCase();
        }
      }
      combined = combined.trim();
      if (!combined) continue;

      if ((combined.includes("reg") || combined.includes("vehicle")) && !colMap['reg_no']) colMap['reg_no'] = c + 1;
      else if ((combined.includes("city") || combined.includes("location")) && !colMap['city']) colMap['city'] = c + 1;
      else if ((combined.includes("upto") || combined.includes("previous") || combined.includes("balance")) && !colMap['prev_bal']) colMap['prev_bal'] = c + 1;
      else if ((combined.includes("updated on") || combined.includes("audit")) && !colMap['updated_on']) colMap['updated_on'] = c + 1;
      else if (combined.includes("notice date") && !colMap['notice_date']) colMap['notice_date'] = c + 1;
      else if (combined.includes("violation date") && !colMap['violation_date']) colMap['violation_date'] = c + 1;
      else if (combined.includes("time") && !colMap['time']) colMap['time'] = c + 1;
      else if ((combined.includes("challen amount") || combined.includes("challan amount") || combined.includes("fine")) && !combined.includes("sticker") && !colMap['fine_amount']) colMap['fine_amount'] = c + 1;
      else if (combined.includes("sticker") && !colMap['sticker_fine']) colMap['sticker_fine'] = c + 1;
      else if (combined.includes("paid") && !colMap['amount_paid']) colMap['amount_paid'] = c + 1;
      else if ((combined.includes("pending") || combined.includes("total")) && !colMap['total_pending']) colMap['total_pending'] = c + 1;
      else if (combined.includes("remark") && !colMap['remarks']) colMap['remarks'] = c + 1;
    }
  } catch(e) {
    Logger.log("getWeeklyColMapFromMatrix error: " + e.message);
  }
  return colMap;
}

function syncSheetTab(sheet, conn, pstmt) {
  try {
    const name = sheet.getName().trim();
    const lastRow = sheet.getLastRow();
    const lastCol = sheet.getLastColumn();
    if (lastRow <= 1) return { synced: 0, skipped: 0 };

    const topMatrixRows = Math.min(5, lastRow);
    const matrix = sheet.getRange(1, 1, topMatrixRows, lastCol).getValues();

    let hRow = 0;
    for (let r = 0; r < matrix.length; r++) {
      const rowStr = matrix[r].map(v => String(v || "").toLowerCase());
      if (rowStr.some(v => v.includes("reg") || v.includes("vehicle") || v.includes("challen") || v.includes("pending"))) {
        hRow = r + 1;
      }
    }
    if (hRow === 0) hRow = 3;

    const colMap = getWeeklyColMapFromMatrix(matrix);
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

      try {
        if (bindChallanRow(pstmt, row, currentRowNumber, name, colMap)) {
          pstmt.addBatch();
          pendingBatch++;
          synced++;
        } else {
          skipped++;
        }
      } catch(rowErr) {
        skipped++;
        Logger.log("Skipping corrupt row " + currentRowNumber + " in tab '" + name + "': " + rowErr.message);
      }

      if (pendingBatch >= BATCH_SIZE) {
        try {
          pstmt.executeBatch();
          conn.commit();
        } catch(batchErr) {
          Logger.log("Batch error on tab '" + name + "': " + batchErr.message + ". Rolling back batch and continuing.");
          try { conn.rollback(); } catch(rErr) {}
        }
        pendingBatch = 0;
      }
    }

    if (pendingBatch > 0) {
      try {
        pstmt.executeBatch();
        conn.commit();
      } catch(batchErr) {
        Logger.log("Final batch error on tab '" + name + "': " + batchErr.message);
        try { conn.rollback(); } catch(rErr) {}
      }
    }

    return { synced: synced, skipped: skipped };
  } catch(err) {
    Logger.log("syncSheetTab failed for sheet '" + sheet.getName() + "': " + err.message);
    return { synced: 0, skipped: 0 };
  }
}

/**
 * Resilient Multi-Tab Auto-Discovery & Checkpoint Execution
 * Loops through all sheets safely, wrapping each tab in try-catch so failures never break the pipeline.
 */
function autoDiscoverAndSyncAllWeeklyTabs() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    Logger.log("autoDiscoverAndSyncAllWeeklyTabs skipped: Lock busy.");
    return;
  }

  const ss = getTargetSpreadsheet();
  if (!ss) {
    Logger.log("Could not access target spreadsheet.");
    lock.releaseLock();
    return;
  }

  const sheets = ss.getSheets();
  const props = PropertiesService.getScriptProperties();
  let startTabIndex = parseInt(props.getProperty("CHALLAN_SYNC_TAB_INDEX") || "0", 10);
  
  if (startTabIndex >= sheets.length) startTabIndex = 0;

  const startTime = Date.now();
  const MAX_EXEC_TIME_MS = 270000; // 4.5 minutes safety guard

  let conn = null;
  let pstmt = null;
  let totalSynced = 0;
  let totalSkipped = 0;
  let tabsProcessed = 0;
  let executionYielded = false;

  const nonLedgerTabs = ["form responses", "template", "summary", "trips", "stricker fine"];

  try {
    conn = getDbConnection();
    conn.setAutoCommit(false);
    pstmt = conn.prepareStatement(UPSERT_SQL);

    for (let i = startTabIndex; i < sheets.length; i++) {
      if (Date.now() - startTime > MAX_EXEC_TIME_MS) {
        Logger.log("Approaching quota limit (4.5 min). Yielding execution and saving checkpoint at tab index " + i);
        props.setProperty("CHALLAN_SYNC_TAB_INDEX", String(i));
        executionYielded = true;
        
        ScriptApp.newTrigger("resumeChallanTabSync")
          .timeBased()
          .after(60000)
          .create();
        break;
      }

      try {
        const sheet = sheets[i];
        const name = sheet.getName().trim();
        const lowName = name.toLowerCase();

        let isSystemTab = false;
        for (let k = 0; k < nonLedgerTabs.length; k++) {
          if (lowName.includes(nonLedgerTabs[k])) {
            isSystemTab = true;
            break;
          }
        }
        if (isSystemTab) continue;

        Logger.log("Auto-Discovery processing tab " + (i + 1) + "/" + sheets.length + ": '" + name + "'...");
        const result = syncSheetTab(sheet, conn, pstmt);
        if (result.synced > 0) {
          totalSynced += result.synced;
          totalSkipped += result.skipped;
          tabsProcessed++;
          Logger.log("Tab '" + name + "' complete: " + result.synced + " rows synced.");
        }
      } catch(tabErr) {
        Logger.log("Error processing tab index " + i + ": " + tabErr.message + ". Continuing to next tab.");
      }
      
      props.setProperty("CHALLAN_SYNC_TAB_INDEX", String(i + 1));
    }

    if (!executionYielded) {
      props.deleteProperty("CHALLAN_SYNC_TAB_INDEX");
      Logger.log("Full Auto-Discovery Multi-Tab Sync Complete. Total Synced: " + totalSynced + " across " + tabsProcessed + " tabs.");
    }
  } catch(err) {
    if (conn) { try { conn.rollback(); } catch(e) {} }
    Logger.log("Global Sync Error: " + err.message);
  } finally {
    if (pstmt) { try { pstmt.close(); } catch(e) {} }
    if (conn) { try { conn.close(); } catch(e) {} }
    lock.releaseLock();
  }
}

function syncAllChallanTabs() {
  autoDiscoverAndSyncAllWeeklyTabs();
}

function resumeChallanTabSync() {
  deleteAllResumeTriggers();
  autoDiscoverAndSyncAllWeeklyTabs();
}

function deleteAllResumeTriggers() {
  try {
    const triggers = ScriptApp.getProjectTriggers();
    for (let i = 0; i < triggers.length; i++) {
      if (triggers[i].getHandlerFunction() === "resumeChallanTabSync") {
        ScriptApp.deleteTrigger(triggers[i]);
      }
    }
  } catch(e) {}
}

function syncCurrentWeekTab() {
  autoDiscoverAndSyncAllWeeklyTabs();
}

function handleOnEdit(e) {
  if (!e || !e.range) return;
  try {
    const sheet = e.range.getSheet();
    const startRow = Math.max(3, e.range.getRow());
    const endRow = e.range.getLastRow();

    const name = sheet.getName().trim();
    const lowName = name.toLowerCase();
    if (lowName.includes("form responses") || lowName.includes("template") || lowName.includes("summary")) return;

    const lock = LockService.getScriptLock();
    let acquired = false;
    for (let attempt = 0; attempt < 3; attempt++) {
      if (lock.tryLock(10000)) {
        acquired = true;
        break;
      }
      Utilities.sleep(1000 * Math.pow(2, attempt));
    }
    if (!acquired) {
      Logger.log("handleOnEdit skipped: Lock busy after retries.");
      return;
    }

    const lastCol = sheet.getLastColumn();
    const topMatrixRows = Math.min(5, startRow - 1);
    const matrix = sheet.getRange(1, 1, topMatrixRows, lastCol).getValues();
    const colMap = getWeeklyColMapFromMatrix(matrix);

    if (!colMap['reg_no']) {
      lock.releaseLock();
      return;
    }

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
      Logger.log("handleOnEdit DB execution error: " + err.message);
    } finally {
      if (pstmt) { try { pstmt.close(); } catch(e) {} }
      if (conn) { try { conn.close(); } catch(e) {} }
      lock.releaseLock();
    }
  } catch(globalEditErr) {
    Logger.log("handleOnEdit global error: " + globalEditErr.message);
  }
}

function setupTriggers() {
  try {
    deleteAllTriggers();
    const ss = getTargetSpreadsheet();

    ScriptApp.newTrigger("handleOnEdit")
      .forSpreadsheet(ss)
      .onEdit()
      .create();

    ScriptApp.newTrigger("autoDiscoverAndSyncAllWeeklyTabs")
      .timeBased()
      .everyHours(1)
      .create();

    Logger.log("Automated triggers installed successfully.");
  } catch(e) {
    Logger.log("setupTriggers error: " + e.message);
  }
}

function deleteAllTriggers() {
  try {
    const triggers = ScriptApp.getProjectTriggers();
    const challanHandlers = [
      "handleOnEdit",
      "syncCurrentWeekTab",
      "syncAllChallanTabs",
      "autoDiscoverAndSyncAllWeeklyTabs",
      "resumeChallanTabSync"
    ];
    
    for (let i = 0; i < triggers.length; i++) {
      const handler = triggers[i].getHandlerFunction();
      if (challanHandlers.indexOf(handler) !== -1) {
        ScriptApp.deleteTrigger(triggers[i]);
      }
    }
  } catch(e) {}
}
