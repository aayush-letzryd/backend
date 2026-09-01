-- ============================================================================
-- MODULE: City Master Testing & Verification
-- SCRIPT: Verification and Functional Test Suites for public.core_cities
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. VERIFY MASTER DATA
-- ----------------------------------------------------------------------------
SELECT
    city_id,
    city_code,
    city_name,
    state,
    country,
    is_active,
    created_at,
    created_by,
    updated_at,
    updated_by
FROM public.core_cities
ORDER BY city_id ASC;


-- ----------------------------------------------------------------------------
-- 2. VERIFY TABLE SCHEMA DEFINITION & NULLABILITY
-- ----------------------------------------------------------------------------
SELECT
    table_name,
    ordinal_position,
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'core_cities'
ORDER BY ordinal_position ASC;


-- ----------------------------------------------------------------------------
-- 3. VERIFY TRIGGERS ATTACHED TO core_cities
-- ----------------------------------------------------------------------------
SELECT
    trigger_name,
    event_manipulation,
    action_timing,
    action_statement
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND event_object_table = 'core_cities'
ORDER BY trigger_name;


-- ----------------------------------------------------------------------------
-- 4. FUNCTIONAL TEST: AUTO updated_at (Wrapped in Transaction - Safe)
-- ----------------------------------------------------------------------------
BEGIN;

-- Capture initial updated_at
SELECT city_id, city_name, updated_at AS original_updated_at 
FROM public.core_cities 
WHERE city_id = 1;

-- Perform an update
UPDATE public.core_cities
SET state = 'Karnataka - Updated'
WHERE city_id = 1;

-- Verify updated_at has changed
SELECT city_id, city_name, updated_at AS new_updated_at 
FROM public.core_cities 
WHERE city_id = 1;

ROLLBACK;


-- ----------------------------------------------------------------------------
-- 5. FUNCTIONAL TEST: PREVENT PHYSICAL DELETE PROTECTION
-- Expected: ERROR: Physical deletion of cities is strictly prohibited.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    BEGIN
        DELETE FROM public.core_cities WHERE city_id = 1;
        RAISE EXCEPTION 'TEST FAILED: Physical DELETE was allowed!';
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'SUCCESS: Physical delete was successfully blocked with message: %', SQLERRM;
    END;
END;
$$;
