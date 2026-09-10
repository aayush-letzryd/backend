/**
 * ==============================================================================
 * LETZRYD - POPULATE MASTER ISSUE CATALOG (sheet_maintenance Tab)
 * ==============================================================================
 * Target Spreadsheet: 'Master_Issue_Standardization_Catalog'
 * Link: https://docs.google.com/spreadsheets/d/17uSnoSRwX3jYCImi8NmlF7KCApMICprO11loDk2Iwg8/edit?usp=sharing
 * 
 * Safety Guarantee:
 *  - Only creates/updates the tab 'sheet_maintenance'
 *  - Leaves all existing tabs (walkin_form, accidents, dropoffs, etc.) 100% untouched
 * ==============================================================================
 */

function populateMaintenanceCatalogTab() {
  const spreadsheetId = "17uSnoSRwX3jYCImi8NmlF7KCApMICprO11loDk2Iwg8";
  const targetTabName = "sheet_maintenance";
  
  let ss;
  try {
    ss = SpreadsheetApp.openById(spreadsheetId);
  } catch (e) {
    // If run directly from inside the spreadsheet's script editor
    ss = SpreadsheetApp.getActiveSpreadsheet();
  }

  // 1. Get or Create Sheet
  let sheet = ss.getSheetByName(targetTabName);
  if (!sheet) {
    sheet = ss.insertSheet(targetTabName);
  } else {
    sheet.clear(); // Clears ONLY this tab
  }

  // 2. Define the 13 Exact Headers
  const headers = [
    "Issue ID",
    "Sheet / Tab",
    "Variable / Column",
    "Issue Name & Category",
    "MY INPUT",
    "Proposed Code Standardization Rule",
    "Detailed Error Description & Root Cause",
    "Affected Rows",
    "% Dataset",
    "Severity",
    "Standardization Capability",
    "Why Custom Input Needed (If Applicable)",
    "Action Required by User / Ops Team"
  ];

  // 3. Define the 14 Issue Rows
  const issues = [
    [
      "MAIN-01",
      "Unified_Maintenance_source",
      "Vehicle Number",
      "Primary Key Formatting & Truncation Handling",
      "True natural primary key. Strip all spaces, hyphens, and apostrophes. Enforce standard 9-10 char plate format. Flag truncated plates (e.g. '037, .../664).",
      "UPPER(TRIM(REGEXP_REPLACE(vehicle_number, '[^A-Za-z0-9]', '', 'g'))). Flag if length < 8 or length > 12.",
      "Manual spreadsheet copy-pasting introduced truncated numbers, leading single quotes, and punctuation variations.",
      "~15",
      "1.50%",
      "CRITICAL",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "Ops review needed only for unrecoverable truncated strings.",
      "None"
    ],
    [
      "MAIN-02",
      "Unified_Maintenance_source",
      "City",
      "City Code Abbreviation Normalization",
      "Standardize 3-letter city abbreviations (BLR, HYD, MUM, DEL) to canonical city names. If missing, auto-infer from vehicle plate prefix (KA -> Bangalore, TS/TG -> Hyderabad, MH -> Mumbai, DL -> Delhi).",
      "CASE WHEN UPPER(TRIM(city)) LIKE 'BLR%' THEN 'Bangalore' WHEN UPPER(TRIM(city)) LIKE 'HYD%' THEN 'Hyderabad' WHEN UPPER(TRIM(city)) LIKE 'MUM%' THEN 'Mumbai' WHEN UPPER(TRIM(city)) LIKE 'DEL%' THEN 'Delhi' ELSE INITCAP(TRIM(city)) END",
      "City names are entered as short codes (BLR, HYD, MUM) or mixed case instead of standardized city entities.",
      "100%",
      "100.00%",
      "LOW",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None (Plate prefix fallback automatically resolves city)",
      "None"
    ],
    [
      "MAIN-03",
      "Unified_Maintenance_source",
      "Date",
      "Audit Status Date Format & ISO Parsing",
      "Standardize daily status date into native PostgreSQL DATE (YYYY-MM-DD). Parse both DD/MM/YYYY and raw date serials.",
      "Parse regex DD/MM/YYYY into YYYY-MM-DD. Store valid ISO DATE in database.",
      "Dates entered across tabs using varied date representations and text formats.",
      "100%",
      "100.00%",
      "HIGH",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None (Multi-pattern date parser normalizes DD/MM/YYYY and serial dates)",
      "None"
    ],
    [
      "MAIN-04",
      "Unified_Maintenance_source",
      "Allocation Date",
      "Allocation Date Nullability & Blank Handling",
      "Convert valid dates to DATE, convert empty strings, spaces, and hyphens (\"-\") to SQL NULL.",
      "If allocation_date is blank, empty, or '-', store as SQL NULL; else parse DD/MM/YYYY to DATE.",
      "Maintenance vehicles may not have active allocations while in workshop, leaving cells blank or hyphenated.",
      "~85%",
      "85.00%",
      "MEDIUM",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None (Valid operational NULL for vehicles undergoing repairs)",
      "None"
    ],
    [
      "MAIN-05",
      "Unified_Maintenance_source",
      "Drop Off Date",
      "Workshop Return Date Extraction",
      "Convert workshop drop-off timestamp to DATE; store SQL NULL for empty or hyphenated cells.",
      "If drop_off_date is blank, empty, or '-', store as SQL NULL; else parse DD/MM/YYYY to DATE.",
      "Vehicles checked into workshop record return/drop-off date; un-dropped inventory remains blank.",
      "~70%",
      "70.00%",
      "MEDIUM",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None (Valid operational NULL for ongoing workshop inventory)",
      "None"
    ],
    [
      "MAIN-06",
      "Unified_Maintenance_source",
      "Final Status",
      "Strict Maintenance Ingestion Filter",
      "Enforce strict staging filter: final_status = 'Maintenance'. If status changes to Active or RFD in source, mark is_deleted = TRUE.",
      "Filter WHERE TRIM(final_status) = 'Maintenance'. Propagate soft delete is_deleted = TRUE when status leaves Maintenance.",
      "Operational filter isolating workshop repair records from active on-road deployments.",
      "100%",
      "100.00%",
      "CRITICAL",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None (Automated filter and soft-delete handler)",
      "None"
    ],
    [
      "MAIN-07",
      "Unified_Maintenance_source",
      "Cohort",
      "Off Road Deployment Cohort Standardization",
      "Standardize cohort strictly to 'Off Road' for all workshop maintenance records.",
      "COALESCE(NULLIF(TRIM(cohort), ''), 'Off Road').",
      "Workshop vehicles must always be classified as Off Road to pause rental billing in Hisaab engine.",
      "100%",
      "100.00%",
      "LOW",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None",
      "None"
    ],
    [
      "MAIN-08",
      "Unified_Maintenance_source",
      "Mapping",
      "Compound Asset Mapping String Sanitization",
      "Clean mapping string preserving plate + serial identifier. Strip trailing hyphens and semicolons.",
      "REGEXP_REPLACE(TRIM(mapping), '[:;\\-\\s]+$', '').",
      "Compound text string combines registration plate and internal vehicle asset serial number with trailing punctuation.",
      "100%",
      "100.00%",
      "LOW",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None",
      "None"
    ],
    [
      "MAIN-09",
      "Unified_Maintenance_source",
      "partner Name",
      "Driver Name Hyphen & Null Normalization",
      "Convert hyphen \"-\" placeholders and blank strings to SQL NULL. Preserve clean text names.",
      "NULLIF(TRIM(partner_name), '-').",
      "Unassigned maintenance vehicles use hyphens \"-\" instead of empty cells in manual spreadsheet logs.",
      "~65%",
      "65.00%",
      "LOW",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None",
      "None"
    ],
    [
      "MAIN-10",
      "Unified_Maintenance_source",
      "partner IDs",
      "Driver Code vs Workshop Status Literal Isolation",
      "Preserve raw partner ID string; map literal \"Maintenance\" / \"RFD\" / \"-\" to SQL NULL.",
      "CASE WHEN UPPER(TRIM(partner_ids)) IN ('MAINTENANCE', 'RFD', '-', '') THEN NULL ELSE TRIM(partner_ids) END.",
      "Spreadsheet fills driver ID column with the word \"Maintenance\" when vehicle has no assigned driver.",
      "~80%",
      "80.00%",
      "HIGH",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None (Separates driver ID entity from workshop state)",
      "None"
    ],
    [
      "MAIN-11",
      "Unified_Maintenance_source",
      "New partner Name [ Default ]",
      "Alternate Partner Name Placeholder Normalization",
      "Trim whitespace and convert hyphens \"-\" and blank strings to SQL NULL.",
      "NULLIF(TRIM(new_partner_name_default), '-').",
      "Secondary driver field containing mostly blank or default hyphen placeholder strings.",
      "~95%",
      "95.00%",
      "LOW",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None",
      "None"
    ],
    [
      "MAIN-12",
      "Unified_Maintenance_source",
      "Vehicle Model",
      "OEM Model Description Normalization",
      "Trim whitespace and standardize OEM model descriptions (Maruti Wagonr Tour H3 CNG).",
      "TRIM(vehicle_model).",
      "Minor spacing differences across manual model entries (e.g. Wagonr vs Wagon R).",
      "100%",
      "100.00%",
      "LOW",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None",
      "None"
    ],
    [
      "MAIN-13",
      "Unified_Maintenance_source",
      "DM Name",
      "Fleet Duty Manager Name Standardization",
      "Convert hyphens \"-\" to SQL NULL, trim whitespace, and standardize DM names.",
      "NULLIF(TRIM(dm_name), '-').",
      "Fleet manager assigned to hub; unassigned entries contain hyphens.",
      "~40%",
      "40.00%",
      "LOW",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None",
      "None"
    ],
    [
      "MAIN-14",
      "Unified_Maintenance_source",
      "Type",
      "Partner Engagement Type Classification",
      "Normalize partner classification (Individual, Operator). Map hyphens to SQL NULL.",
      "CASE WHEN UPPER(TRIM(type)) = 'INDIVIDUAL' THEN 'Individual' WHEN UPPER(TRIM(type)) = 'OPERATOR' THEN 'Operator' ELSE NULL END.",
      "Unassigned maintenance cars contain hyphen \"-\" in type column.",
      "~60%",
      "60.00%",
      "LOW",
      "CAN BE FIXED BY STANDARDIZATION (CODE)",
      "None",
      "None"
    ]
  ];

  // 4. Write Data to Sheet
  const allRows = [headers, ...issues];
  const numRows = allRows.length;
  const numCols = headers.length;

  const range = sheet.getRange(1, 1, numRows, numCols);
  range.setValues(allRows);

  // 5. Apply Enterprise Styling
  // Header Style (Navy Blue background, White text, Bold)
  const headerRange = sheet.getRange(1, 1, 1, numCols);
  headerRange
    .setBackground("#1a365d")
    .setFontColor("#ffffff")
    .setFontWeight("bold")
    .setFontSize(10)
    .setHorizontalAlignment("center")
    .setVerticalAlignment("middle");
  sheet.setRowHeight(1, 40);

  // Data Rows Style
  const dataRange = sheet.getRange(2, 1, issues.length, numCols);
  dataRange
    .setFontSize(9)
    .setVerticalAlignment("middle")
    .setWrapStrategy(SpreadsheetApp.WrapStrategy.WRAP);

  // Center align specific columns (Issue ID, Sheet/Tab, Affected Rows, % Dataset, Severity)
  sheet.getRange(2, 1, issues.length, 1).setHorizontalAlignment("center").setFontWeight("bold"); // Issue ID
  sheet.getRange(2, 2, issues.length, 1).setHorizontalAlignment("center"); // Sheet/Tab
  sheet.getRange(2, 8, issues.length, 1).setHorizontalAlignment("center"); // Affected Rows
  sheet.getRange(2, 9, issues.length, 1).setHorizontalAlignment("center"); // % Dataset
  sheet.getRange(2, 10, issues.length, 1).setHorizontalAlignment("center").setFontWeight("bold"); // Severity

  // Alternating row background for readability
  for (let r = 2; r <= numRows; r++) {
    sheet.setRowHeight(r, 45);
    if (r % 2 === 1) {
      sheet.getRange(r, 1, 1, numCols).setBackground("#f8fafc");
    }
  }

  // Border formatting
  range.setBorder(true, true, true, true, true, true, "#cbd5e1", SpreadsheetApp.BorderStyle.SOLID);

  // Column Widths
  const colWidths = [
    85,   // Issue ID
    160,  // Sheet / Tab
    130,  // Variable / Column
    180,  // Issue Name & Category
    240,  // MY INPUT
    260,  // Proposed Code Standardization Rule
    260,  // Detailed Error Description & Root Cause
    95,   // Affected Rows
    85,   // % Dataset
    95,   // Severity
    200,  // Standardization Capability
    180,  // Why Custom Input Needed
    180   // Action Required
  ];

  for (let c = 0; c < colWidths.length; c++) {
    sheet.setColumnWidth(c + 1, colWidths[c]);
  }

  // Freeze Header Row
  sheet.setFrozenRows(1);

  Logger.log("Successfully created and styled tab 'sheet_maintenance' in Master_Issue_Standardization_Catalog!");
}
