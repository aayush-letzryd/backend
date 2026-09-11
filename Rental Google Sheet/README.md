# Rental Google Sheet Synchronization Engine

Production automated synchronization pipeline connecting the Pan-India Live Rental Master Google Sheet (`1xnGg3qhb1AnCP2Qv6e2gmd0zCi5j-bNbx9yDc7etzf4`) to PostgreSQL staging tables.

---

## 1. System Architecture

```
+--------------------------------------------------------------+
|             Pan-India Live Rental Master Google Sheet        |
|   Spreadsheet ID: 1xnGg3qhb1AnCP2Qv6e2gmd0zCi5j-bNbx9yDc7etzf4 |
|                                                              |
|   Tabs:                                                      |
|   - HYD - Rental Slab        - HYD - Driver platform         |
|   - MUM - Rental Slab        - MUM - Driver platform         |
|   - BLR- Rental Slab         - BLR - Driver platform         |
+------------------------------+-------------------------------+
                               |
                               | HTTPS 30-Minute Trigger
                               v
+--------------------------------------------------------------+
|            Google Cloud Function (Gen 2)                     |
|            sync-rental-sheets-live (Python 3.11)             |
|            Source: GitHub (Rental Google Sheet/)             |
|                                                              |
|   - In-memory XLSX streaming & parsing (openpyxl)            |
|   - Platform agreement classification & custom rates         |
|   - Multi-city slab normalization (min_trips, max_trips)     |
|   - Idempotent Zero-Burn ON CONFLICT upsert                  |
+------------------------------+-------------------------------+
                               |
                               | Port 5432 (Cloud SQL)
                               v
+--------------------------------------------------------------+
|            PostgreSQL Staging Tables                         |
|                                                              |
|   1. public.sheet_rental_slabs                               |
|      (Pricing menu per city, model, Uber tier, min_trips)    |
|                                                              |
|   2. public.sheet_rental_partners                            |
|      (Operator agreements, flat rates, indemnity overrides)  |
+--------------------------------------------------------------+
```

---

## 2. Deployment from GitHub

All code is maintained directly in this GitHub repository.

### Option A: One-Command Deployment from Cloud Shell
```bash
# 1. Pull the latest repository updates
git pull origin main

# 2. Deploy directly from the checked-out folder
cd "Rental Google Sheet"
chmod +x deploy.sh
./deploy.sh
```

### Option B: Automatic CI/CD via Cloud Run / Cloud Build
1. In GCP Console under **Cloud Run** > Click **Connect repo** (shown on your screen).
2. Select GitHub repository `aayush-letzryd/backend` and branch `main`.
3. Set the build context / subdirectory to `Rental Google Sheet`.
4. Any future commit pushed to GitHub will automatically trigger Cloud Build and deploy the updated function without any manual terminal commands.
