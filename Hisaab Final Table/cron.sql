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

-- ----------------------------------------------------------------------------
-- Schedule: hisaab-vehicle-payout-sync
-- Runs every hour at minute 50 (50 * * * *).
-- Synchronizes operational payout table (public.hisaab_vehicle_payout_weekly)
-- enforcing Monday 11:00 AM IST cutoff freeze and rolling late challans/adjustments forward.
-- Runs 5 minutes after audit table sync (:45) and 10 minutes before app broadcast (:00).
-- ----------------------------------------------------------------------------
SELECT cron.schedule(
    'hisaab-vehicle-payout-sync',
    '50 * * * *',
    'CALL public.sp_sync_hisaab_vehicle_payout_weekly(NULL);'
);

-- ----------------------------------------------------------------------------
-- Schedule: ensure-active-settlement-week
-- Runs every Monday at 00:01 UTC.
-- Creates the active ISO calendar week in hisaab_settlement_weeks so ongoing data syncs.
-- ----------------------------------------------------------------------------
SELECT cron.schedule(
    'ensure-active-settlement-week',
    '1 0 * * 1',
    'CALL public.sp_ensure_active_settlement_week();'
);

-- Verification query to inspect scheduled jobs
SELECT jobid, schedule, command, nodename, active, jobname 
FROM cron.job 
WHERE jobname IN ('hisaab-rent-sync', 'hisaab-vehicle-weekly-sync', 'hisaab-vehicle-payout-sync', 'ensure-active-settlement-week');

