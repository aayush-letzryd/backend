-- ==============================================================================
-- Batch 8: Quarantine Test Sandbox Tables (test_*) to z_test_*
-- Executed on: 2026-10-07
-- Safe Quarantine: Renames tables so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

ALTER TABLE public.test_uber_driver_payments_raw RENAME TO z_test_uber_driver_payments_raw;
ALTER TABLE public.test_uber_org_payments_raw RENAME TO z_test_uber_org_payments_raw;
ALTER TABLE public.test_uber_etl_state RENAME TO z_test_uber_etl_state;

COMMIT;
