-- ==============================================================================
-- Rollback for Batch 6: Restore z_demo_* Tables back to demo_*
-- Safe Rollback: Run this if any system requires the original demo_* names.
-- ==============================================================================

BEGIN;

ALTER TABLE public.z_demo_gps_test RENAME TO demo_gps_test;
ALTER TABLE public.z_demo_uber_driver_payments_test RENAME TO demo_uber_driver_payments_test;
ALTER TABLE public.z_demo_uber_org_payments_test RENAME TO demo_uber_org_payments_test;
ALTER TABLE public.z_demo_uber_transaction_activity_test RENAME TO demo_uber_transaction_activity_test;
ALTER TABLE public.z_demo_uber_trips_test RENAME TO demo_uber_trips_test;

COMMIT;
