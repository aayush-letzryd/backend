-- ==============================================================================
-- Rollback for Batch 1: Restore z_lr_* Tables back to lr_*
-- Safe Rollback: Run this if any system requires the original lr_* names.
-- ==============================================================================

BEGIN;

ALTER TABLE public.z_lr_allocation_master RENAME TO lr_allocation_master;
ALTER TABLE public.z_lr_audit_logs RENAME TO lr_audit_logs;
ALTER TABLE public.z_lr_drivers RENAME TO lr_drivers;
ALTER TABLE public.z_lr_gps_mileage_logs RENAME TO lr_gps_mileage_logs;
ALTER TABLE public.z_lr_hisaab_platform_earnings RENAME TO lr_hisaab_platform_earnings;
ALTER TABLE public.z_lr_notifications RENAME TO lr_notifications;
ALTER TABLE public.z_lr_operators RENAME TO lr_operators;
ALTER TABLE public.z_lr_platform_weekly_earnings RENAME TO lr_platform_weekly_earnings;
ALTER TABLE public.z_lr_portal_users RENAME TO lr_portal_users;
ALTER TABLE public.z_lr_referrals RENAME TO lr_referrals;
ALTER TABLE public.z_lr_sos_alerts RENAME TO lr_sos_alerts;
ALTER TABLE public.z_lr_tickets RENAME TO lr_tickets;
ALTER TABLE public.z_lr_user_audit_logs RENAME TO lr_user_audit_logs;
ALTER TABLE public.z_lr_vehicle_allocations RENAME TO lr_vehicle_allocations;
ALTER TABLE public.z_lr_vehicle_platform_authorizations RENAME TO lr_vehicle_platform_authorizations;
ALTER TABLE public.z_lr_vehicles RENAME TO lr_vehicles;
ALTER TABLE public.z_lr_weekly_hisaabs RENAME TO lr_weekly_hisaabs;
ALTER TABLE public.z_lr_weekly_incentive_goals RENAME TO lr_weekly_incentive_goals;

COMMIT;
