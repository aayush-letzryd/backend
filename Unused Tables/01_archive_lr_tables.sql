-- ==============================================================================
-- Batch 1: Quarantine Legacy lr_* Tables to z_lr_*
-- Executed on: 2026-10-05
-- Safe Quarantine: Renames tables so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

ALTER TABLE public.lr_allocation_master RENAME TO z_lr_allocation_master;
ALTER TABLE public.lr_audit_logs RENAME TO z_lr_audit_logs;
ALTER TABLE public.lr_drivers RENAME TO z_lr_drivers;
ALTER TABLE public.lr_gps_mileage_logs RENAME TO z_lr_gps_mileage_logs;
ALTER TABLE public.lr_hisaab_platform_earnings RENAME TO z_lr_hisaab_platform_earnings;
ALTER TABLE public.lr_notifications RENAME TO z_lr_notifications;
ALTER TABLE public.lr_operators RENAME TO z_lr_operators;
ALTER TABLE public.lr_platform_weekly_earnings RENAME TO z_lr_platform_weekly_earnings;
ALTER TABLE public.lr_portal_users RENAME TO z_lr_portal_users;
ALTER TABLE public.lr_referrals RENAME TO z_lr_referrals;
ALTER TABLE public.lr_sos_alerts RENAME TO z_lr_sos_alerts;
ALTER TABLE public.lr_tickets RENAME TO z_lr_tickets;
ALTER TABLE public.lr_user_audit_logs RENAME TO z_lr_user_audit_logs;
ALTER TABLE public.lr_vehicle_allocations RENAME TO z_lr_vehicle_allocations;
ALTER TABLE public.lr_vehicle_platform_authorizations RENAME TO z_lr_vehicle_platform_authorizations;
ALTER TABLE public.lr_vehicles RENAME TO z_lr_vehicles;
ALTER TABLE public.lr_weekly_hisaabs RENAME TO z_lr_weekly_hisaabs;
ALTER TABLE public.lr_weekly_incentive_goals RENAME TO z_lr_weekly_incentive_goals;

COMMIT;
