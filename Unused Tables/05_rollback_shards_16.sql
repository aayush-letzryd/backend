-- ==============================================================================
-- Rollback for Batch 5: Restore z_*_16 Objects back to original names
-- Safe Rollback: Run this if any system requires the original _16 names.
-- ==============================================================================

BEGIN;

-- 1. Views
ALTER VIEW public.z_hisaab_summary_16 RENAME TO hisaab_summary_16;
ALTER VIEW public.z_uber_ola_final_hisaab_16 RENAME TO uber_ola_final_hisaab_16;
ALTER VIEW public.z_weekly_hisaab_summary_16 RENAME TO weekly_hisaab_summary_16;

-- 2. Tables
ALTER TABLE public.z_accident_penalty_16 RENAME TO accident_penalty_16;
ALTER TABLE public.z_adjustment_16 RENAME TO adjustment_16;
ALTER TABLE public.z_allocation_master_16 RENAME TO allocation_master_16;
ALTER TABLE public.z_challan_16 RENAME TO challan_16;
ALTER TABLE public.z_daily_vehicle_status_16 RENAME TO daily_vehicle_status_16;
ALTER TABLE public.z_gps_raw_16 RENAME TO gps_raw_16;
ALTER TABLE public.z_ola_incentive_16 RENAME TO ola_incentive_16;
ALTER TABLE public.z_ola_raw_16 RENAME TO ola_raw_16;
ALTER TABLE public.z_online_payment_16 RENAME TO online_payment_16;
ALTER TABLE public.z_rapido_incentive_16 RENAME TO rapido_incentive_16;
ALTER TABLE public.z_rapido_raw_16 RENAME TO rapido_raw_16;
ALTER TABLE public.z_uber_incentive_16 RENAME TO uber_incentive_16;
ALTER TABLE public.z_uber_payment_organisation_16 RENAME TO uber_payment_organisation_16;
ALTER TABLE public.z_uber_raw_16 RENAME TO uber_raw_16;
ALTER TABLE public.z_vendor_ledger_16 RENAME TO vendor_ledger_16;

COMMIT;
