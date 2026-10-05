-- ==============================================================================
-- Batch 6: Quarantine Demo Tables (demo_*) to z_demo_*
-- Executed on: 2026-10-05
-- Safe Quarantine: Renames tables so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

ALTER TABLE public.demo_gps_test RENAME TO z_demo_gps_test;
ALTER TABLE public.demo_uber_driver_payments_test RENAME TO z_demo_uber_driver_payments_test;
ALTER TABLE public.demo_uber_org_payments_test RENAME TO z_demo_uber_org_payments_test;
ALTER TABLE public.demo_uber_transaction_activity_test RENAME TO z_demo_uber_transaction_activity_test;
ALTER TABLE public.demo_uber_trips_test RENAME TO z_demo_uber_trips_test;

COMMIT;
