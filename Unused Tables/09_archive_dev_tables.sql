-- ==============================================================================
-- Batch 9: Quarantine Dev Sandbox Tables (dev_*) to z_dev_*
-- Executed on: 2026-10-07
-- Safe Quarantine: Renames abandoned dev tables so they sort to bottom and are easily rollbacked.
-- NOTE: dev_city is intentionally EXCLUDED because portaljuly/main.py still touches it.
-- ==============================================================================

BEGIN;

ALTER TABLE public.dev_employees RENAME TO z_dev_employees;
ALTER TABLE public.dev_modules RENAME TO z_dev_modules;
ALTER TABLE public.dev_role_permissions RENAME TO z_dev_role_permissions;
ALTER TABLE public.dev_roles RENAME TO z_dev_roles;
ALTER TABLE public.dev_sessions RENAME TO z_dev_sessions;
ALTER TABLE public.dev_users RENAME TO z_dev_users;

COMMIT;
