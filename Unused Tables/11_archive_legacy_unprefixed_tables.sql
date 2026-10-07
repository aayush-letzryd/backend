-- ==============================================================================
-- BATCH 11: LEGACY UN-PREFIXED ORPHAN & PROTOTYPE TABLES (16 Tables)
-- ==============================================================================
-- Target: Quarantine obsolete, detached prototype tables to 'z_' prefix.
-- Pre-conditions Verified:
--   - 0 references across all 10 production repositories
--   - 0 view dependencies
--   - 0 routine / trigger dependencies
--   - 0 foreign key constraints
--   - Active production tables (vehicle_challans, core_challans, sheet_challans,
--     vehicles, accidents, hubs_parking, workshops) strictly preserved.
-- Rollback: See 11_rollback_legacy_unprefixed_tables.sql
-- ==============================================================================

BEGIN;

ALTER TABLE IF EXISTS public."accidents_registry" RENAME TO "z_accidents_registry";
ALTER TABLE IF EXISTS public."operating_cities" RENAME TO "z_operating_cities";
ALTER TABLE IF EXISTS public."hubs_and_parking" RENAME TO "z_hubs_and_parking";
ALTER TABLE IF EXISTS public."partner_adjustment" RENAME TO "z_partner_adjustment";
ALTER TABLE IF EXISTS public."partner_expenses" RENAME TO "z_partner_expenses";
ALTER TABLE IF EXISTS public."traffic_challans" RENAME TO "z_traffic_challans";
ALTER TABLE IF EXISTS public."maintenance_registry" RENAME TO "z_maintenance_registry";
ALTER TABLE IF EXISTS public."workshop_vendors" RENAME TO "z_workshop_vendors";
ALTER TABLE IF EXISTS public."walkin_form_links" RENAME TO "z_walkin_form_links";
ALTER TABLE IF EXISTS public."vehicle_states" RENAME TO "z_vehicle_states";
ALTER TABLE IF EXISTS public."user_roles" RENAME TO "z_user_roles";
ALTER TABLE IF EXISTS public."pdi_logs" RENAME TO "z_pdi_logs";
ALTER TABLE IF EXISTS public."media_attachments" RENAME TO "z_media_attachments";
ALTER TABLE IF EXISTS public."maintenance_summary" RENAME TO "z_maintenance_summary";
ALTER TABLE IF EXISTS public."insurance_claims" RENAME TO "z_insurance_claims";
ALTER TABLE IF EXISTS public."walkin_onboarding_links" RENAME TO "z_walkin_onboarding_links";

COMMIT;
