-- ==============================================================================
-- Rollback for Batch 7: Restore z_*_1 Objects back to original names
-- Safe Rollback: Run this if any system requires the original _1 names.
-- ==============================================================================

BEGIN;

-- 1. Views
ALTER VIEW public.z_hisaab_summary_1 RENAME TO hisaab_summary_1;
ALTER VIEW public.z_uber_ola_final_hisaab_1 RENAME TO uber_ola_final_hisaab_1;
ALTER VIEW public.z_weekly_hisaab_summary_1 RENAME TO weekly_hisaab_summary_1;

-- 2. Tables
ALTER TABLE public.z_accident_penalty_1 RENAME TO accident_penalty_1;
ALTER TABLE public.z_adjustment_1 RENAME TO adjustment_1;
ALTER TABLE public.z_allocation_master_1 RENAME TO allocation_master_1;
ALTER TABLE public.z_challan_1 RENAME TO challan_1;
ALTER TABLE public.z_gps_raw_1 RENAME TO gps_raw_1;
ALTER TABLE public.z_july_vehicle_onboarding_1 RENAME TO july_vehicle_onboarding_1;
ALTER TABLE public.z_july_vehicle_onboarding_1_logs RENAME TO july_vehicle_onboarding_1_logs;
ALTER TABLE public.z_ola_incentive_1 RENAME TO ola_incentive_1;
ALTER TABLE public.z_ola_raw_1 RENAME TO ola_raw_1;
ALTER TABLE public.z_online_payment_1 RENAME TO online_payment_1;
ALTER TABLE public.z_rapido_raw_1 RENAME TO rapido_raw_1;
ALTER TABLE public.z_uber_incentive_1 RENAME TO uber_incentive_1;
ALTER TABLE public.z_uber_payment_organisation_1 RENAME TO uber_payment_organisation_1;
ALTER TABLE public.z_uber_raw_1 RENAME TO uber_raw_1;
ALTER TABLE public.z_vendor_ledger_1 RENAME TO vendor_ledger_1;

COMMIT;
