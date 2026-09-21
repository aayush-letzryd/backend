-- ============================================================================
-- LETZRYD HISAAB ENGINE - PG_CRON AUTOMATION SCHEDULER
-- Database: PostgreSQL 14+ (requires pg_cron extension)
-- Module: Automated Hisaab Synchronization
-- Architecture: Decoupled Scheduled Batch Execution (Zero Table Locks)
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
-- Schedule: hisaab-vehicle-weekly-sync
-- Runs every day at 03:00 AM UTC (08:30 AM IST).
-- This runs after rental-daily-calculation (02:00 AM UTC) and telemetry syncs.
-- Synchronizes all active/open settlement weeks automatically.
-- ----------------------------------------------------------------------------
SELECT cron.schedule(
    'hisaab-vehicle-weekly-sync',
    '0 3 * * *',
    'CALL public.sp_sync_hisaab_vehicle_weekly(NULL);'
);

-- Verification query to inspect scheduled job
SELECT jobid, schedule, command, nodename, active, jobname 
FROM cron.job 
WHERE jobname = 'hisaab-vehicle-weekly-sync';
