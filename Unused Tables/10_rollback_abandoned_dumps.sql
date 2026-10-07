-- ==============================================================================
-- Rollback for Batch 10: Restore z_* Abandoned Dumps back to original names
-- Safe Rollback: Run this if any system requires the original names.
-- ==============================================================================

BEGIN;

ALTER TABLE public.z_ola_driver_bookings_cancellations RENAME TO ola_driver_bookings_cancellations;
ALTER TABLE public.z_uber_trips_raw RENAME TO uber_trips_raw;
ALTER TABLE public.z_ola_report_blr_hisaab RENAME TO ola_report_blr_hisaab;
ALTER TABLE public.z_ola_driver_performance RENAME TO ola_driver_performance;
ALTER TABLE public.z_ola_car_performance RENAME TO ola_car_performance;
ALTER TABLE public.z_ola_incentive_payments RENAME TO ola_incentive_payments;
ALTER TABLE public.z_staging_ola_uber_rapido_raw RENAME TO staging_ola_uber_rapido_raw;
ALTER TABLE public.z_processed_emails RENAME TO processed_emails;

COMMIT;
