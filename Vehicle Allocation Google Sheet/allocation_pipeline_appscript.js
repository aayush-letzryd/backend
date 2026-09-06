/**
 * ==============================================================================
 * LETZRYD - VEHICLE ALLOCATION DIRECT MASTER SHEET TO POSTGRES LIVE PIPELINE
 * ==============================================================================
 * 
 * Container Sheet: allocation_form (New Control Spreadsheet)
 * Source Data    : Pan India Master Sheet -> "Vehicle Allocation" Tab (Direct openById)
 * Target Table   : public.sheet_vehicle_allocations (PostgreSQL)
 * 
 * Key Features:
 *  1. Direct background read from Master Sheet (No IMPORTRANGE needed, no cell limits)
 *  2. Zero-Burn Sequence ID CTE Query (prevents ID counter gaps on existing rows)
 *  3. LockService concurrency guard (prevents concurrent trigger runs)
 *  4. Dynamic Header Indexing (immune to column insertions/reordering)
 *  5. Leak-proof JDBC connection management (try-finally on all statements)
 *  6. Transaction rollback on batch errors (conn.rollback())
 *  7. Multi-format date, phone, odometer, and financial number sanitization
 *  8. Zero emojis across code, logs, and menus
 * ==============================================================================
 */

// --- CONFIGURATION & DATABASE CREDENTIALS ---
const CONFIG = {
  // Master Fleet Spreadsheet (Read directly in background):
  masterSpreadsheetId: "YOUR_MASTER_SPREADSHEET_ID_HERE",
  masterTabName: "Vehicle Allocation",

  // PostgreSQL Database Credentials:
  dbHost: "YOUR_DB_HOST_HERE",
  dbPort: "5432",
  dbName: "postgres",
  dbUser: "postgres",
  dbPassword: "YOUR_DB_PASSWORD_HERE"
};

// Standard JDBC SQL Type Codes (Apps Script does not expose java.sql.Types)
const SQL_TYPES = {
  VARCHAR: 12,
  DATE: 91,
  TIMESTAMP: 93,
  INTEGER: 4,
  NUMERIC: 2,
  NULL: 0
};

/**
 * Custom UI Menu added to your Google Sheet on open.
 */
function onOpen() {
  try {
    SpreadsheetApp.getUi().createMenu("LetzRyd Allocation Sync")
      .addItem("1. Test Database Connection", "testDbConnection")
      .addSeparator()
      .addItem("2. Sync Recent 100 Allocations", "syncRecentAllocations")
      .addSeparator()
      .addItem("3. Install Automated 1-Min Trigger", "setupTriggers")
      .addItem("4. Remove Automated Triggers", "deleteAllTriggers")
      .addToUi();
  } catch (e) {
    Logger.log("onOpen menu init: " + e.message);
  }
}

/**
 * Opens and returns the Master Sheet tab directly via openById.
 */
function getMasterSheet() {
  const ss = SpreadsheetApp.openById(CONFIG.masterSpreadsheetId);
  const sheet = ss.getSheetByName(CONFIG.masterTabName);
  if (!sheet) {
    throw new Error("Tab '" + CONFIG.masterTabName + "' not found in Master Spreadsheet.");
  }
  return sheet;
}

/**
 * Establishes a JDBC connection to PostgreSQL.
 */
function getDbConnection() {
  const url = "jdbc:postgresql://" + CONFIG.dbHost + ":" + CONFIG.dbPort + "/" + CONFIG.dbName;
  return Jdbc.getConnection(url, CONFIG.dbUser, CONFIG.dbPassword);
}

/**
 * Test connectivity to PostgreSQL.
 */
function testDbConnection() {
  let conn = null;
  let stmt = null;
  let rs = null;
  const ui = SpreadsheetApp.getUi();
  try {
    conn = getDbConnection();
    stmt = conn.createStatement();
    rs = stmt.executeQuery("SELECT COUNT(*), COALESCE(MAX(id), 0) FROM public.sheet_vehicle_allocations;");
    if (rs.next()) {
      const count = rs.getInt(1);
      const maxId = rs.getInt(2);
      ui.alert("Database Connection Successful! Table public.sheet_vehicle_allocations currently has " + count + " rows. Max ID: " + maxId);
    }
  } catch (err) {
    ui.alert("Database Connection Failed: " + err.message);
  } finally {
    if (rs) { try { rs.close(); } catch (e) {} }
    if (stmt) { try { stmt.close(); } catch (e) {} }
    if (conn) { try { conn.close(); } catch (e) {} }
  }
}

// --- DATA CLEANING & STANDARDIZATION HELPERS ---

function cleanStr(val) {
  if (val === null || val === undefined) return null;
  const s = String(val).trim();
  return s !== "" ? s : null;
}

function cleanPlaceholder(val) {
  const s = cleanStr(val);
  if (!s) return null;
  const placeholders = ["-", "--", "na", "n/a", "none", "nil", "null", "nan"];
  if (placeholders.includes(s.toLowerCase())) return null;
  return s;
}

function cleanCity(val) {
  const s = cleanStr(val);
  if (!s) return null;
  const low = s.toLowerCase();
  if (low.indexOf("beng") !== -1 || low.indexOf("bang") !== -1 || low.indexOf("blr") !== -1) return "Bengaluru";
  if (low.indexOf("hyd") !== -1) return "Hyderabad";
  if (low.indexOf("mum") !== -1 || low.indexOf("bombay") !== -1) return "Mumbai";
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function cleanOpId(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  let cleaned = s.toUpperCase().replace(/\s+/g, "");
  // ISS-07: Malformed syntax fixes
  if (cleaned === "LETZMUM967686669") return "LETZMUM9967686669";
  if (cleaned.indexOf("LETZOWNMUM") === 0) return "LETZMUMOP" + cleaned.slice(10);
  return cleaned;
}

function cleanDriverName(val, excelRow) {
  const s = cleanStr(val);
  if (!s) return "Unknown";
  // ISS-10: Operator ID in driver name field
  if (s === "LETZMUMIP9004200105" || (excelRow === 2789 && s.indexOf("9004200105") !== -1)) {
    return "Gaadylo Enterprises";
  }
  // ISS-11: Strip MUM_, BLR_, HYD_ prefixes
  let cleaned = s.replace(/^(?:MUM|BLR|HYD)_\s*/i, "");
  // ISS-12 & ISS-14: Clean tabs, duplicate spaces, double dots
  cleaned = cleaned.replace(/\t/g, " ").replace(/\s+/g, " ").replace(/\.\./g, ".").trim();
  // ISS-13: Title Case
  return cleaned.split(" ").map(function(w) {
    return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase();
  }).join(" ");
}

function cleanPhone(val, excelRow) {
  if (val === null || val === undefined) return "0000000000";
  let s = String(val).trim().replace(/\.0+$/, "");
  const digits = s.replace(/\D/g, "");
  const phone = digits.length >= 10 ? digits.slice(-10) : digits.padStart(10, "0");
  
  // ISS-06 Group A: 1-digit typo fixes
  if (excelRow === 112) return "8812944940";
  if (excelRow === 1386 || excelRow === 1452) return "6301998819";
  if (excelRow === 3110 || excelRow === 3443 || excelRow === 3495) return "9650838363";
  return phone;
}

function cleanVehicleNumber(val) {
  const s = cleanStr(val);
  if (!s) return "UNKNOWN";
  let cleaned = s.toUpperCase().replace(/\s+/g, "").replace(/-/g, "");
  // ISS-08: Replace letter 'O' with digit '0'
  cleaned = cleaned.replace("TGO7X9865", "TG07X9865");
  cleaned = cleaned.replace(/^([A-Z]{2})O([0-9])/, "$10$2");
  return cleaned;
}

function cleanPartnerType(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
}

function cleanAmount(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  const numStr = s.replace(/,/g, "").replace(/₹/g, "").trim();
  const num = parseFloat(numStr);
  return isNaN(num) ? null : num;
}

function cleanOdometer(val) {
  const s = cleanPlaceholder(val);
  if (!s) return null;
  const numStr = s.replace(/,/g, "").trim();
  const num = parseFloat(numStr);
  if (isNaN(num)) return null;
  if (num < 0) return 0;
  if (num > 500000) return null;
  return Math.round(num);
}

function cleanDate(val) {
  if (val === null || val === undefined) return null;
  if (val instanceof Date && !isNaN(val.getTime())) {
    return Utilities.formatDate(val, "Asia/Kolkata", "yyyy-MM-dd");
  }
  if (typeof val === "number" || (!isNaN(Number(val)) && Number(val) > 30000 && Number(val) < 60000)) {
    const d = new Date(Math.round((Number(val) - 25569) * 86400 * 1000));
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
  }
  const s = String(val).trim();
  if (["", "-", "--", "na", "n/a", "none", "nil", "null"].includes(s.toLowerCase())) return null;
  const dmyMatch = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/);
  if (dmyMatch) {
    const d = new Date(parseInt(dmyMatch[3], 10), parseInt(dmyMatch[2], 10) - 1, parseInt(dmyMatch[1], 10));
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd");
  }
  const parsed = new Date(s);
  return isNaN(parsed.getTime()) ? null : Utilities.formatDate(parsed, "Asia/Kolkata", "yyyy-MM-dd");
}

function cleanTimestamp(val) {
  if (val === null || val === undefined || val === "") {
    return Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  if (val instanceof Date && !isNaN(val.getTime())) {
    return Utilities.formatDate(val, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  if (typeof val === "number" || (!isNaN(Number(val)) && Number(val) > 30000 && Number(val) < 60000)) {
    const d = new Date(Math.round((Number(val) - 25569) * 86400 * 1000));
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  const s = String(val).trim();
  const dmyTsMatch = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$/);
  if (dmyTsMatch) {
    const d = new Date(
      parseInt(dmyTsMatch[3], 10),
      parseInt(dmyTsMatch[2], 10) - 1,
      parseInt(dmyTsMatch[1], 10),
      dmyTsMatch[4] ? parseInt(dmyTsMatch[4], 10) : 0,
      dmyTsMatch[5] ? parseInt(dmyTsMatch[5], 10) : 0,
      dmyTsMatch[6] ? parseInt(dmyTsMatch[6], 10) : 0
    );
    return Utilities.formatDate(d, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  const parsed = new Date(s);
  if (!isNaN(parsed.getTime())) {
    return Utilities.formatDate(parsed, "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
  }
  return Utilities.formatDate(new Date(), "Asia/Kolkata", "yyyy-MM-dd HH:mm:ss.SSS+05:30");
}

// --- DATABASE UPSERT SQL (ZERO-BURN CTE SYNTAX) ---
const UPSERT_SQL = `
WITH incoming AS (
    SELECT 
        CAST(? AS timestamptz) AS ts,
        CAST(? AS varchar) AS email,
        CAST(? AS varchar) AS city,
        CAST(? AS varchar) AS reason,
        CAST(? AS date) AS alloc_date,
        CAST(? AS varchar) AS op_id,
        CAST(? AS varchar) AS alloc_type,
        CAST(? AS varchar) AS driver_name,
        CAST(? AS varchar) AS driver_phone,
        CAST(? AS varchar) AS veh_num,
        CAST(? AS varchar) AS car_model,
        CAST(? AS varchar) AS driver_plan,
        CAST(? AS varchar) AS type_of_plan,
        CAST(? AS varchar) AS rental_plan,
        CAST(? AS varchar) AS partner_type,
        CAST(? AS numeric) AS ola_amount,
        CAST(? AS integer) AS odometer,
        CAST(? AS text) AS agreement,
        CAST(? AS text) AS ola_ss,
        CAST(? AS text) AS photo_driver,
        CAST(? AS text) AS photo_front,
        CAST(? AS text) AS photo_lh,
        CAST(? AS text) AS photo_rh,
        CAST(? AS text) AS photo_back,
        CAST(? AS text) AS photo_battery,
        CAST(? AS varchar) AS stepney,
        CAST(? AS varchar) AS spanner,
        CAST(? AS varchar) AS jack,
        CAST(? AS varchar) AS tommy,
        CAST(? AS varchar) AS triangle,
        CAST(? AS varchar) AS fire_ext,
        CAST(? AS varchar) AS carpet,
        CAST(? AS varchar) AS seat_cover,
        CAST(? AS varchar) AS music_sys,
        CAST(? AS varchar) AS poc,
        CAST(? AS integer) AS sheet_row
),
upd AS (
    UPDATE sheet_vehicle_allocations a
    SET 
        submission_timestamp = i.ts,
        submitter_email = i.email,
        city = i.city,
        reason_to_visit = i.reason,
        operator_driver_id = i.op_id,
        allocation_type = i.alloc_type,
        driver_name = i.driver_name,
        car_model = i.car_model,
        driver_plan = i.driver_plan,
        type_of_plan = i.type_of_plan,
        rental_plan = i.rental_plan,
        partner_type = i.partner_type,
        ola_negative_amount = i.ola_amount,
        odometer_reading = i.odometer,
        upload_agreement = i.agreement,
        ola_negative_amount_ss = i.ola_ss,
        driver_with_car_photo = i.photo_driver,
        front_car_photo = i.photo_front,
        lh_car_photo = i.photo_lh,
        rh_car_photo = i.photo_rh,
        back_car_photo = i.photo_back,
        battery_photo = i.photo_battery,
        stepney_tyre = i.stepney,
        spanner_pana = i.spanner,
        jack = i.jack,
        jack_rod_tommy = i.tommy,
        parking_triangle = i.triangle,
        fire_extinguishers = i.fire_ext,
        floor_carpet = i.carpet,
        seat_cover = i.seat_cover,
        music_system = i.music_sys,
        vehicle_manager_poc = i.poc,
        sheet_row_number = i.sheet_row,
        updated_at = CURRENT_TIMESTAMP
    FROM incoming i
    WHERE a.allocation_date = i.alloc_date 
      AND a.vehicle_number = i.veh_num 
      AND a.driver_phone = i.driver_phone
    RETURNING a.id
)
INSERT INTO sheet_vehicle_allocations (
    id, submission_timestamp, submitter_email, city, reason_to_visit,
    allocation_date, operator_driver_id, allocation_type, driver_name,
    driver_phone, vehicle_number, car_model, driver_plan, type_of_plan,
    rental_plan, partner_type, ola_negative_amount, odometer_reading,
    upload_agreement, ola_negative_amount_ss, driver_with_car_photo,
    front_car_photo, lh_car_photo, rh_car_photo, back_car_photo,
    battery_photo, stepney_tyre, spanner_pana, jack, jack_rod_tommy,
    parking_triangle, fire_extinguishers, floor_carpet, seat_cover,
    music_system, vehicle_manager_poc, sheet_row_number, created_at, updated_at
)
SELECT 
    nextval('sheet_vehicle_allocations_id_seq'),
    i.ts, i.email, i.city, i.reason,
    i.alloc_date, i.op_id, i.alloc_type, i.driver_name,
    i.driver_phone, i.veh_num, i.car_model, i.driver_plan, i.type_of_plan,
    i.rental_plan, i.partner_type, i.ola_amount, i.odometer,
    i.agreement, i.ola_ss, i.photo_driver,
    i.photo_front, i.photo_lh, i.photo_rh, i.photo_back,
    i.photo_battery, i.stepney, i.spanner, i.jack, i.tommy,
    i.triangle, i.fire_ext, i.carpet, i.seat_cover,
    i.music_sys, i.poc, i.sheet_row, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
FROM incoming i
WHERE NOT EXISTS (SELECT 1 FROM upd);
`;

/**
 * Builds dynamic header map from row 1.
 */
function getHeaderIndexMap(headers) {
  const map = {};
  for (let c = 0; c < headers.length; c++) {
    const raw = String(headers[c] || "").trim().toLowerCase();
    if (!raw) continue;
    map[raw] = c;
  }
  return map;
}

/**
 * Extracts and cleans a row into a structured record.
 */
function extractRecord(row, excelRow, hMap) {
  function get(key, fallbackIdx) {
    if (hMap && hMap[key.toLowerCase()] !== undefined) {
      return row[hMap[key.toLowerCase()]];
    }
    return fallbackIdx !== undefined && fallbackIdx < row.length ? row[fallbackIdx] : null;
  }

  const tsRaw = get("Timestamp", 0);
  const dateRaw = get("Date Of Allocation", 4);
  const phoneRaw = get("Driver Phone number", 8);
  const vehRaw = get("Vehicle Number", 13);

  // Skip header rows or rows with completely missing key fields
  if (String(tsRaw).trim().toLowerCase() === "timestamp") return null;
  if (!dateRaw && !phoneRaw && !vehRaw) return null;

  const dateClean = cleanDate(dateRaw);
  const vehClean = cleanVehicleNumber(vehRaw);
  const phoneClean = cleanPhone(phoneRaw, excelRow);

  if (!dateClean || vehClean === "UNKNOWN") return null;

  return {
    ts: cleanTimestamp(tsRaw),
    email: cleanStr(get("Email address", 1)),
    city: cleanCity(get("City", 2)),
    reason: cleanStr(get("Reason to Visit", 3)),
    alloc_date: dateClean,
    op_id: cleanOpId(get("Operator/Driver ID", 5)),
    alloc_type: cleanPlaceholder(get("Allocation Type", 6)),
    driver_name: cleanDriverName(get("Driver Name", 7), excelRow),
    driver_phone: phoneClean,
    veh_num: vehClean,
    car_model: cleanPlaceholder(get("Car Model", 11)),
    driver_plan: cleanPlaceholder(get("Driver Plan", 9)),
    type_of_plan: cleanPlaceholder(get("Type Of Plan", 10)),
    rental_plan: cleanPlaceholder(get("Rental Plan", 34)),
    partner_type: cleanPartnerType(get("Type", 33)),
    ola_amount: cleanAmount(get("OLA Negative Amount", 14)),
    odometer: cleanOdometer(get("Kms Reading", 22)),
    agreement: cleanPlaceholder(get("Upload Agreement", 12)),
    ola_ss: cleanPlaceholder(get("OLA Negative Amount SS", 15)),
    photo_driver: cleanPlaceholder(get("Driver With Car Photo", 16)),
    photo_front: cleanPlaceholder(get("Front Car Photo", 17)),
    photo_lh: cleanPlaceholder(get("LH Car Photo", 18)),
    photo_rh: cleanPlaceholder(get("RH Car Photo", 19)),
    photo_back: cleanPlaceholder(get("Back Car Photo", 20)),
    photo_battery: cleanPlaceholder(get("Battery Photo", 21)),
    stepney: cleanPlaceholder(get("Stepney Tyre", 23)),
    spanner: cleanPlaceholder(get("Spanner (Pana)", 24)),
    jack: cleanPlaceholder(get("Jack", 25)),
    tommy: cleanPlaceholder(get("Jack Rod (Tommy)", 26)),
    triangle: cleanPlaceholder(get("Parking Triangle", 27)),
    fire_ext: cleanPlaceholder(get("Fire Extinguishers", 28)),
    carpet: cleanPlaceholder(get("Floor Carpet", 29)),
    seat_cover: cleanPlaceholder(get("Seat Cover", 30)),
    music_sys: cleanPlaceholder(get("Music System", 31)),
    poc: cleanPlaceholder(get("Vehicle Manager ( POC )", 32)),
    sheet_row: excelRow
  };
}

/**
 * Binds parameters to the Prepared Statement.
 */
function bindParams(stmt, d) {
  let idx = 1;
  stmt.setString(idx++, d.ts);
  d.email ? stmt.setString(idx++, d.email) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.city ? stmt.setString(idx++, d.city) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.reason ? stmt.setString(idx++, d.reason) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  stmt.setString(idx++, d.alloc_date);
  d.op_id ? stmt.setString(idx++, d.op_id) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.alloc_type ? stmt.setString(idx++, d.alloc_type) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  stmt.setString(idx++, d.driver_name);
  stmt.setString(idx++, d.driver_phone);
  stmt.setString(idx++, d.veh_num);
  d.car_model ? stmt.setString(idx++, d.car_model) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.driver_plan ? stmt.setString(idx++, d.driver_plan) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.type_of_plan ? stmt.setString(idx++, d.type_of_plan) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.rental_plan ? stmt.setString(idx++, d.rental_plan) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.partner_type ? stmt.setString(idx++, d.partner_type) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.ola_amount !== null ? stmt.setDouble(idx++, d.ola_amount) : stmt.setNull(idx++, SQL_TYPES.NULL);
  d.odometer !== null ? stmt.setInt(idx++, d.odometer) : stmt.setNull(idx++, SQL_TYPES.NULL);
  d.agreement ? stmt.setString(idx++, d.agreement) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.ola_ss ? stmt.setString(idx++, d.ola_ss) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.photo_driver ? stmt.setString(idx++, d.photo_driver) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.photo_front ? stmt.setString(idx++, d.photo_front) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.photo_lh ? stmt.setString(idx++, d.photo_lh) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.photo_rh ? stmt.setString(idx++, d.photo_rh) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.photo_back ? stmt.setString(idx++, d.photo_back) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.photo_battery ? stmt.setString(idx++, d.photo_battery) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.stepney ? stmt.setString(idx++, d.stepney) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.spanner ? stmt.setString(idx++, d.spanner) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.jack ? stmt.setString(idx++, d.jack) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.tommy ? stmt.setString(idx++, d.tommy) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.triangle ? stmt.setString(idx++, d.triangle) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.fire_ext ? stmt.setString(idx++, d.fire_ext) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.carpet ? stmt.setString(idx++, d.carpet) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.seat_cover ? stmt.setString(idx++, d.seat_cover) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.music_sys ? stmt.setString(idx++, d.music_sys) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  d.poc ? stmt.setString(idx++, d.poc) : stmt.setNull(idx++, SQL_TYPES.VARCHAR);
  stmt.setInt(idx++, d.sheet_row);
}

/**
 * Sync Recent 100 Allocations (Reads bottom 100 rows directly from Master Sheet).
 * Completes in 2-3 seconds.
 */
function syncRecentAllocations() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(15000)) {
    Logger.log("syncRecentAllocations: Another sync is currently running. Skipping.");
    return;
  }
  try {
    const sheet = getMasterSheet();
    if (!sheet) return;

    const lastRow = sheet.getLastRow();
    if (lastRow <= 1) return;

    // Scan backwards up to 500 rows to find true last populated row
    const scanStart = Math.max(1, lastRow - 500);
    const scanCount = lastRow - scanStart + 1;
    const checkVals = sheet.getRange(scanStart, 1, scanCount, 5).getValues();
    let trueLastRow = 0;
    for (let r = checkVals.length - 1; r >= 0; r--) {
      if (checkVals[r][0] && String(checkVals[r][0]).trim() !== "") {
        trueLastRow = scanStart + r;
        break;
      }
    }
    if (trueLastRow <= 1) return;

    const startRow = Math.max(2, trueLastRow - 100);
    const numRows = trueLastRow - startRow + 1;
    const headerVals = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    const hMap = getHeaderIndexMap(headerVals);
    const data = sheet.getRange(startRow, 1, numRows, sheet.getLastColumn()).getValues();

    let conn = null;
    let stmt = null;
    let count = 0;

    try {
      conn = getDbConnection();
      conn.setAutoCommit(false);
      stmt = conn.prepareStatement(UPSERT_SQL);

      for (let i = 0; i < data.length; i++) {
        const d = extractRecord(data[i], startRow + i, hMap);
        if (!d) continue;
        bindParams(stmt, d);
        stmt.addBatch();
        count++;
      }

      if (count > 0) {
        stmt.executeBatch();
        conn.commit();
      }
      Logger.log("syncRecentAllocations: Synced " + count + " rows successfully.");
      try {
        SpreadsheetApp.getUi().alert("Recent sync complete! Checked and synced " + count + " rows to PostgreSQL.");
      } catch (uiErr) {}
    } catch (err) {
      if (conn) {
        try { conn.rollback(); } catch (rb) {}
      }
      Logger.log("syncRecentAllocations error: " + err.message);
      try {
        SpreadsheetApp.getUi().alert("Sync error: " + err.message);
      } catch (uiErr) {}
    } finally {
      if (stmt) { try { stmt.close(); } catch (e) {} }
      if (conn) { try { conn.close(); } catch (e) {} }
    }
  } finally {
    lock.releaseLock();
  }
}

/**
 * Installs the 1-minute automated trigger.
 */
function setupTriggers() {
  deleteAllTriggers();
  ScriptApp.newTrigger("syncRecentAllocations")
    .timeBased()
    .everyMinutes(1)
    .create();
  SpreadsheetApp.getUi().alert("Installed 1-minute time-driven trigger for syncRecentAllocations.");
}

/**
 * Removes existing triggers for this project.
 */
function deleteAllTriggers() {
  const triggers = ScriptApp.getProjectTriggers();
  for (let i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === "syncRecentAllocations") {
      ScriptApp.deleteTrigger(triggers[i]);
    }
  }
  SpreadsheetApp.getUi().alert("Automated triggers removed.");
}
