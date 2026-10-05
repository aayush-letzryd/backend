-- ==============================================================================
-- Batch 4: Quarantine Legacy Week 15 Shards (*_15) to z_*_15
-- Executed on: 2026-10-05
-- Safe Quarantine: Renames views and tables so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

-- 1. Views
ALTER VIEW public.uber_ola_final_hisaab_15 RENAME TO z_uber_ola_final_hisaab_15;
ALTER VIEW public.hisaab_summary_15 RENAME TO z_hisaab_summary_15;
ALTER VIEW public.weekly_hisaab_summary_15 RENAME TO z_weekly_hisaab_summary_15;

-- 2. Tables
ALTER TABLE public.accident_penalty_15 RENAME TO z_accident_penalty_15;
ALTER TABLE public.adjustment_15 RENAME TO z_adjustment_15;
ALTER TABLE public.allocation_master_15 RENAME TO z_allocation_master_15;
ALTER TABLE public.challan_15 RENAME TO z_challan_15;
ALTER TABLE public.daily_vehicle_status_15 RENAME TO z_daily_vehicle_status_15;
ALTER TABLE public.gps_raw_15 RENAME TO z_gps_raw_15;
ALTER TABLE public.ola_incentive_15 RENAME TO z_ola_incentive_15;
ALTER TABLE public.ola_raw_15 RENAME TO z_ola_raw_15;
ALTER TABLE public.online_payment_15 RENAME TO z_online_payment_15;
ALTER TABLE public.rapido_raw_15 RENAME TO z_rapido_raw_15;
ALTER TABLE public.uber_incentive_15 RENAME TO z_uber_incentive_15;
ALTER TABLE public.uber_payment_organisation_15 RENAME TO z_uber_payment_organisation_15;
ALTER TABLE public.uber_raw_15 RENAME TO z_uber_raw_15;
ALTER TABLE public.vendor_ledger_15 RENAME TO z_vendor_ledger_15;

COMMIT;
