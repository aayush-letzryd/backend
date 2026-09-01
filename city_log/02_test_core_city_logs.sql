-- ============================================================================
-- MODULE: City Audit Log Testing & Verification
-- SCRIPT: Comprehensive Test Suite for public.core_city_logs
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. INSPECT ALL RECORDED AUDIT LOGS
-- ----------------------------------------------------------------------------
SELECT
    log_id,
    city_id,
    action,
    old_data,
    new_data,
    action_at,
    action_by
FROM public.core_city_logs
ORDER BY log_id ASC;


-- ----------------------------------------------------------------------------
-- 2. VERIFY FOREIGN KEYS & INDEXES
-- ----------------------------------------------------------------------------
SELECT
    tc.constraint_name,
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS foreign_table_name,
    ccu.column_name AS foreign_column_name
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
  ON tc.constraint_name = kcu.constraint_name
  AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage AS ccu
  ON ccu.constraint_name = tc.constraint_name
  AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_name = 'core_city_logs';

-- Check index
SELECT
    indexname,
    indexdef
FROM pg_indexes
WHERE tablename = 'core_city_logs';


-- ----------------------------------------------------------------------------
-- 3. COMPREHENSIVE FUNCTIONAL AUDIT TEST (Transaction with Rollback)
-- ----------------------------------------------------------------------------
BEGIN;

-- A. Test CREATE Action
INSERT INTO public.core_cities (city_code, city_name, state, country, created_by)
VALUES ('DEL', 'Delhi', 'Delhi', 'India', 99)
RETURNING city_id;

-- Verify CREATE audit entry
SELECT log_id, city_id, action, old_data, new_data, action_by
FROM public.core_city_logs
WHERE city_id = (SELECT city_id FROM public.core_cities WHERE city_code = 'DEL')
ORDER BY log_id DESC;

-- B. Test UPDATE Action
UPDATE public.core_cities
SET city_name = 'New Delhi', updated_by = 101
WHERE city_code = 'DEL';

-- Verify UPDATE audit entry
SELECT log_id, city_id, action, 
       old_data->>'city_name' AS old_name, 
       new_data->>'city_name' AS new_name,
       action_by
FROM public.core_city_logs
WHERE city_id = (SELECT city_id FROM public.core_cities WHERE city_code = 'DEL')
ORDER BY log_id DESC;

-- C. Test Soft-Delete (is_active TRUE -> FALSE) -> Logged as DELETE
UPDATE public.core_cities
SET is_active = FALSE, updated_by = 102
WHERE city_code = 'DEL';

-- Verify DELETE audit entry
SELECT log_id, city_id, action, 
       old_data->>'is_active' AS old_active, 
       new_data->>'is_active' AS new_active,
       action_by
FROM public.core_city_logs
WHERE city_id = (SELECT city_id FROM public.core_cities WHERE city_code = 'DEL')
ORDER BY log_id DESC;

-- D. Verify complete timeline of the test city
SELECT
    log_id,
    action,
    action_at,
    action_by,
    new_data->>'city_name' AS city_name,
    new_data->>'is_active' AS is_active
FROM public.core_city_logs
WHERE city_id = (SELECT city_id FROM public.core_cities WHERE city_code = 'DEL')
ORDER BY action_at ASC;

ROLLBACK;
