-- ==============================================================================
-- Rollback for Batch 3: Restore z_copy_* Tables back to copy_*
-- Safe Rollback: Run this if any system requires the original copy_* names.
-- ==============================================================================

BEGIN;

ALTER TABLE public.z_copy_accidents_registry RENAME TO copy_accidents_registry;
ALTER TABLE public.z_copy_app_sessions RENAME TO copy_app_sessions;
ALTER TABLE public.z_copy_app_users RENAME TO copy_app_users;
ALTER TABLE public.z_copy_cities RENAME TO copy_cities;
ALTER TABLE public.z_copy_hubs_parking RENAME TO copy_hubs_parking;
ALTER TABLE public.z_copy_inspections RENAME TO copy_inspections;
ALTER TABLE public.z_copy_maintenance_registry RENAME TO copy_maintenance_registry;
ALTER TABLE public.z_copy_operating_cities RENAME TO copy_operating_cities;
ALTER TABLE public.z_copy_partner_adjustment RENAME TO copy_partner_adjustment;
ALTER TABLE public.z_copy_partner_expenses RENAME TO copy_partner_expenses;
ALTER TABLE public.z_copy_tickets RENAME TO copy_tickets;
ALTER TABLE public.z_copy_traffic_challans RENAME TO copy_traffic_challans;
ALTER TABLE public.z_copy_users RENAME TO copy_users;
ALTER TABLE public.z_copy_vehicle_allocation RENAME TO copy_vehicle_allocation;
ALTER TABLE public.z_copy_vehicle_models RENAME TO copy_vehicle_models;
ALTER TABLE public.z_copy_workshop_vendors RENAME TO copy_workshop_vendors;

COMMIT;
