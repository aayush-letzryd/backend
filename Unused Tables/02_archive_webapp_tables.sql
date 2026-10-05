-- ==============================================================================
-- Batch 2: Quarantine Legacy webapp_* Tables to z_webapp_*
-- Executed on: 2026-10-05
-- Safe Quarantine: Renames tables so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

ALTER TABLE public.webapp_hisaab_weeks RENAME TO z_webapp_hisaab_weeks;
ALTER TABLE public.webapp_tickets RENAME TO z_webapp_tickets;
ALTER TABLE public.webapp_users RENAME TO z_webapp_users;
ALTER TABLE public.webapp_vehicles RENAME TO z_webapp_vehicles;

COMMIT;
