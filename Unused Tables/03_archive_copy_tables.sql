-- ==============================================================================
-- Batch 3: Quarantine Legacy copy_* Tables to z_copy_*
-- Executed on: 2026-10-05
-- Safe Quarantine: Renames tables so they sort to bottom and are easily rollbacked.
-- ==============================================================================

BEGIN;

ALTER TABLE public.copy_accidents_registry RENAME TO z_copy_accidents_registry;
ALTER TABLE public.copy_app_sessions RENAME TO z_copy_app_sessions;
ALTER TABLE public.copy_app_users RENAME TO z_copy_app_users;
ALTER TABLE public.copy_cities RENAME TO z_copy_cities;
ALTER TABLE public.copy_hubs_parking RENAME TO z_copy_hubs_parking;
ALTER TABLE public.copy_inspections RENAME TO z_copy_inspections;
ALTER TABLE public.copy_maintenance_registry RENAME TO z_copy_maintenance_registry;
ALTER TABLE public.copy_operating_cities RENAME TO z_copy_operating_cities;
ALTER TABLE public.copy_partner_adjustment RENAME TO z_copy_partner_adjustment;
ALTER TABLE public.copy_partner_expenses RENAME TO z_copy_partner_expenses;
ALTER TABLE public.copy_tickets RENAME TO z_copy_tickets;
ALTER TABLE public.copy_traffic_challans RENAME TO z_copy_traffic_challans;
ALTER TABLE public.copy_users RENAME TO z_copy_users;
ALTER TABLE public.copy_vehicle_allocation RENAME TO z_copy_vehicle_allocation;
ALTER TABLE public.copy_vehicle_models RENAME TO z_copy_vehicle_models;
ALTER TABLE public.copy_workshop_vendors RENAME TO z_copy_workshop_vendors;

COMMIT;
