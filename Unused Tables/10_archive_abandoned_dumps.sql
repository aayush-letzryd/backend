-- ==============================================================================
-- Batch 10: Quarantine Abandoned Scraper & Staging Dumps to z_*
-- Executed on: 2026-10-07
-- Safe Quarantine: Renames abandoned dumps so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

ALTER TABLE public.ola_driver_bookings_cancellations RENAME TO z_ola_driver_bookings_cancellations;
ALTER TABLE public.uber_trips_raw RENAME TO z_uber_trips_raw;
ALTER TABLE public.ola_report_blr_hisaab RENAME TO z_ola_report_blr_hisaab;
ALTER TABLE public.ola_driver_performance RENAME TO z_ola_driver_performance;
ALTER TABLE public.ola_car_performance RENAME TO z_ola_car_performance;
ALTER TABLE public.ola_incentive_payments RENAME TO z_ola_incentive_payments;
ALTER TABLE public.staging_ola_uber_rapido_raw RENAME TO z_staging_ola_uber_rapido_raw;
ALTER TABLE public.processed_emails RENAME TO z_processed_emails;

COMMIT;
