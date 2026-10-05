-- ==============================================================================
-- Rollback for Batch 4: Restore z_*_15 Objects back to original names
-- Safe Rollback: Run this if any system requires the original _15 names.
-- ==============================================================================

BEGIN;

-- 1. Views
ALTER VIEW public.z_uber_ola_final_hisaab_15 RENAME TO uber_ola_final_hisaab_15;
ALTER VIEW public.z_hisaab_summary_15 RENAME TO hisaab_summary_15;
ALTER VIEW public.z_weekly_hisaab_summary_15 RENAME TO weekly_hisaab_summary_15;

-- 2. Tables
ALTER TABLE public.z_accident_penalty_15 RENAME TO accident_penalty_15;
ALTER TABLE public.z_adjustment_15 RENAME TO adjustment_15;
ALTER TABLE public.z_allocation_master_15 RENAME TO allocation_master_15;
ALTER TABLE public.z_challan_15 RENAME TO challan_15;
ALTER TABLE public.z_daily_vehicle_status_15 RENAME TO daily_vehicle_status_15;
ALTER TABLE public.z_gps_raw_15 RENAME TO gps_raw_15;
ALTER TABLE public.z_ola_incentive_15 RENAME TO ola_incentive_15;
ALTER TABLE public.z_ola_raw_15 RENAME TO ola_raw_15;
ALTER TABLE public.z_online_payment_15 RENAME TO online_payment_15;
ALTER TABLE public.z_rapido_raw_15 RENAME TO rapido_raw_15;
ALTER TABLE public.z_uber_incentive_15 RENAME TO uber_incentive_15;
ALTER TABLE public.z_uber_payment_organisation_15 RENAME TO uber_payment_organisation_15;
ALTER TABLE public.z_uber_raw_15 RENAME TO uber_raw_15;
ALTER TABLE public.z_vendor_ledger_15 RENAME TO vendor_ledger_15;

COMMIT;
