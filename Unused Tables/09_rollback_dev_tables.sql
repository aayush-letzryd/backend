-- ==============================================================================
-- Rollback for Batch 9: Restore z_dev_* Tables back to original names
-- Safe Rollback: Run this if any system requires the original dev_* names.
-- ==============================================================================

BEGIN;

ALTER TABLE public.z_dev_employees RENAME TO dev_employees;
ALTER TABLE public.z_dev_modules RENAME TO dev_modules;
ALTER TABLE public.z_dev_role_permissions RENAME TO dev_role_permissions;
ALTER TABLE public.z_dev_roles RENAME TO dev_roles;
ALTER TABLE public.z_dev_sessions RENAME TO dev_sessions;
ALTER TABLE public.z_dev_users RENAME TO dev_users;

COMMIT;
