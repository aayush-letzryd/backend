-- ==============================================================================
-- ROLLBACK BATCH 11: RESTORE LEGACY UN-PREFIXED TABLES (16 Tables)
-- ==============================================================================
-- Purpose: Instant 1-second rollback script to restore legacy un-prefixed tables
-- from 'z_' prefix back to their original names if ever needed.
-- ==============================================================================

BEGIN;

ALTER TABLE IF EXISTS public."z_accidents_registry" RENAME TO "accidents_registry";
ALTER TABLE IF EXISTS public."z_operating_cities" RENAME TO "operating_cities";
ALTER TABLE IF EXISTS public."z_hubs_and_parking" RENAME TO "hubs_and_parking";
ALTER TABLE IF EXISTS public."z_partner_adjustment" RENAME TO "partner_adjustment";
ALTER TABLE IF EXISTS public."z_partner_expenses" RENAME TO "partner_expenses";
ALTER TABLE IF EXISTS public."z_traffic_challans" RENAME TO "traffic_challans";
ALTER TABLE IF EXISTS public."z_maintenance_registry" RENAME TO "maintenance_registry";
ALTER TABLE IF EXISTS public."z_workshop_vendors" RENAME TO "workshop_vendors";
ALTER TABLE IF EXISTS public."z_walkin_form_links" RENAME TO "walkin_form_links";
ALTER TABLE IF EXISTS public."z_vehicle_states" RENAME TO "vehicle_states";
ALTER TABLE IF EXISTS public."z_user_roles" RENAME TO "user_roles";
ALTER TABLE IF EXISTS public."z_pdi_logs" RENAME TO "pdi_logs";
ALTER TABLE IF EXISTS public."z_media_attachments" RENAME TO "media_attachments";
ALTER TABLE IF EXISTS public."z_maintenance_summary" RENAME TO "maintenance_summary";
ALTER TABLE IF EXISTS public."z_insurance_claims" RENAME TO "insurance_claims";
ALTER TABLE IF EXISTS public."z_walkin_onboarding_links" RENAME TO "walkin_onboarding_links";

COMMIT;
