-- ==============================================================================
-- Rollback for Batch 8: Restore z_test_* Tables back to original names
-- Safe Rollback: Run this if any system requires the original test_* names.
-- ==============================================================================

BEGIN;

ALTER TABLE public.z_test_uber_driver_payments_raw RENAME TO test_uber_driver_payments_raw;
ALTER TABLE public.z_test_uber_org_payments_raw RENAME TO test_uber_org_payments_raw;
ALTER TABLE public.z_test_uber_etl_state RENAME TO test_uber_etl_state;

COMMIT;
