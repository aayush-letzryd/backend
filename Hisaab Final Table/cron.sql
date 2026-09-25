-- ============================================================================
-- LETZRYD HISAAB ENGINE - PG_CRON AUTOMATION SCHEDULER
-- Database: PostgreSQL 14+ (requires pg_cron extension)
-- Module: Automated Hisaab Synchronization
-- Architecture: Decoupled Scheduled Batch Execution (Zero Table Locks)
-- Cadence: Hourly Sync (Runs every hour at :45)
-- ============================================================================

-- Ensure pg_cron extension exists
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Remove legacy jobs if present
DO $$
BEGIN
    PERFORM cron.unschedule('hisaab-rent-sync');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

DO $$
BEGIN
    PERFORM cron.unschedule('hisaab-vehicle-weekly-sync');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

-- ----------------------------------------------------------------------------
-- Schedule: hisaab-rent-sync
-- Runs every day at 02:30 AM UTC (08:00 AM IST).
-- Synchronizes daily rent calculations into Hisaab daily ledger.
-- ----------------------------------------------------------------------------
SELECT cron.schedule(
    'hisaab-rent-sync',
    '30 2 * * *',
    'CALL public.sp_sync_rent_to_hisaab(NULL);'
);

-- ----------------------------------------------------------------------------
-- Schedule: hisaab-vehicle-weekly-sync
-- Runs every hour at minute 45 (45 * * * *).
-- Synchronizes active open settlement weeks with latest rent, Uber, Ola, and core_adjustments.
-- Runs 15 minutes before the hourly app broadcast (0 * * * *).
-- ----------------------------------------------------------------------------
SELECT cron.schedule(
    'hisaab-vehicle-weekly-sync',
    '45 * * * *',
    'CALL public.sp_sync_hisaab_vehicle_weekly(NULL);'
);

-- Verification query to inspect scheduled jobs
SELECT jobid, schedule, command, nodename, active, jobname 
FROM cron.job 
WHERE jobname IN ('hisaab-rent-sync', 'hisaab-vehicle-weekly-sync');
