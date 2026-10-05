-- ==============================================================================
-- Rollback for Batch 2: Restore z_webapp_* Tables back to webapp_*
-- Safe Rollback: Run this if any system requires the original webapp_* names.
-- ==============================================================================

BEGIN;

ALTER TABLE public.z_webapp_hisaab_weeks RENAME TO webapp_hisaab_weeks;
ALTER TABLE public.z_webapp_tickets RENAME TO webapp_tickets;
ALTER TABLE public.z_webapp_users RENAME TO webapp_users;
ALTER TABLE public.z_webapp_vehicles RENAME TO webapp_vehicles;

COMMIT;
