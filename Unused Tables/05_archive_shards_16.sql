-- ==============================================================================
-- Batch 5: Quarantine Legacy Week 16 Shards (*_16) to z_*_16
-- Executed on: 2026-10-05
-- Safe Quarantine: Renames views and tables so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

-- 1. Views
ALTER VIEW public.hisaab_summary_16 RENAME TO z_hisaab_summary_16;
ALTER VIEW public.uber_ola_final_hisaab_16 RENAME TO z_uber_ola_final_hisaab_16;
ALTER VIEW public.weekly_hisaab_summary_16 RENAME TO z_weekly_hisaab_summary_16;

-- 2. Tables
ALTER TABLE public.accident_penalty_16 RENAME TO z_accident_penalty_16;
ALTER TABLE public.adjustment_16 RENAME TO z_adjustment_16;
ALTER TABLE public.allocation_master_16 RENAME TO z_allocation_master_16;
ALTER TABLE public.challan_16 RENAME TO z_challan_16;
ALTER TABLE public.daily_vehicle_status_16 RENAME TO z_daily_vehicle_status_16;
ALTER TABLE public.gps_raw_16 RENAME TO z_gps_raw_16;
ALTER TABLE public.ola_incentive_16 RENAME TO z_ola_incentive_16;
ALTER TABLE public.ola_raw_16 RENAME TO z_ola_raw_16;
ALTER TABLE public.online_payment_16 RENAME TO z_online_payment_16;
ALTER TABLE public.rapido_incentive_16 RENAME TO z_rapido_incentive_16;
ALTER TABLE public.rapido_raw_16 RENAME TO z_rapido_raw_16;
ALTER TABLE public.uber_incentive_16 RENAME TO z_uber_incentive_16;
ALTER TABLE public.uber_payment_organisation_16 RENAME TO z_uber_payment_organisation_16;
ALTER TABLE public.uber_raw_16 RENAME TO z_uber_raw_16;
ALTER TABLE public.vendor_ledger_16 RENAME TO z_vendor_ledger_16;

COMMIT;
