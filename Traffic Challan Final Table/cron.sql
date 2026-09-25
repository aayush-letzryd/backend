-- ============================================================================
-- LETZRYD MASTER TRAFFIC CHALLANS - PG_CRON HOURLY SCHEDULER
-- Database: PostgreSQL 14+ (requires pg_cron extension)
-- Target: public.core_challans
-- Architecture: Decoupled Scheduled Batch Execution (Zero Table Locks)
-- Cadence: Hourly Sync (Runs every hour at minute :20)
-- ============================================================================

-- Ensure pg_cron extension exists
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Remove legacy jobs if present
DO $$
BEGIN
    PERFORM cron.unschedule('sync-core-challans-hourly');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

-- ----------------------------------------------------------------------------
-- Schedule: sync-core-challans-hourly
-- Runs every hour at minute 20 (20 * * * *).
-- Synchronizes active violations from vehicle_challans (Bangalore scraper)
-- and sheet_challans (all cities) into public.core_challans.
-- Runs 25 minutes before the hourly Hisaab calculation (at :45).
-- Execution time: ~0.6 seconds.
-- ----------------------------------------------------------------------------
SELECT cron.schedule(
    'sync-core-challans-hourly',
    '20 * * * *',
    'CALL public.sp_sync_core_challans();'
);

-- Verification query to inspect scheduled jobs
SELECT jobid, schedule, command, nodename, active, jobname 
FROM cron.job 
WHERE jobname = 'sync-core-challans-hourly';
