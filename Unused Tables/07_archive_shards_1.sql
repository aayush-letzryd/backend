-- ==============================================================================
-- Batch 7: Quarantine Legacy Week 1 Shards (*_1) to z_*_1
-- Executed on: 2026-10-05
-- Safe Quarantine: Renames views and tables so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

-- 1. Views
ALTER VIEW public.hisaab_summary_1 RENAME TO z_hisaab_summary_1;
ALTER VIEW public.uber_ola_final_hisaab_1 RENAME TO z_uber_ola_final_hisaab_1;
ALTER VIEW public.weekly_hisaab_summary_1 RENAME TO z_weekly_hisaab_summary_1;

-- 2. Tables
ALTER TABLE public.accident_penalty_1 RENAME TO z_accident_penalty_1;
ALTER TABLE public.adjustment_1 RENAME TO z_adjustment_1;
ALTER TABLE public.allocation_master_1 RENAME TO z_allocation_master_1;
ALTER TABLE public.challan_1 RENAME TO z_challan_1;
ALTER TABLE public.gps_raw_1 RENAME TO z_gps_raw_1;
ALTER TABLE public.july_vehicle_onboarding_1 RENAME TO z_july_vehicle_onboarding_1;
ALTER TABLE public.july_vehicle_onboarding_1_logs RENAME TO z_july_vehicle_onboarding_1_logs;
ALTER TABLE public.ola_incentive_1 RENAME TO z_ola_incentive_1;
ALTER TABLE public.ola_raw_1 RENAME TO z_ola_raw_1;
ALTER TABLE public.online_payment_1 RENAME TO z_online_payment_1;
ALTER TABLE public.rapido_raw_1 RENAME TO z_rapido_raw_1;
ALTER TABLE public.uber_incentive_1 RENAME TO z_uber_incentive_1;
ALTER TABLE public.uber_payment_organisation_1 RENAME TO z_uber_payment_organisation_1;
ALTER TABLE public.uber_raw_1 RENAME TO z_uber_raw_1;
ALTER TABLE public.vendor_ledger_1 RENAME TO z_vendor_ledger_1;

COMMIT;
