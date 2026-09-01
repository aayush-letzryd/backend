-- ============================================================================
-- MODULE: City Master
-- SCRIPT: Seed Initial Operational Cities
-- TARGET: public.core_cities
-- ============================================================================

-- Insert initial cities (BLR, HYD, MUM)
INSERT INTO public.core_cities (
    city_id,
    city_code,
    city_name,
    state,
    country,
    is_active,
    created_at,
    updated_at
)
VALUES
    (1, 'BLR', 'Bangalore', 'Karnataka', 'India', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    (2, 'HYD', 'Hyderabad', 'Telangana', 'India', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    (3, 'MUM', 'Mumbai', 'Maharashtra', 'India', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT (city_code) DO NOTHING;

-- Synchronize identity sequence so next auto-generated city_id starts at 4
SELECT setval(
    pg_get_serial_sequence('public.core_cities', 'city_id'),
    COALESCE((SELECT MAX(city_id) FROM public.core_cities), 1),
    TRUE
);
