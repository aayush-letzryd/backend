-- ============================================================================
-- MODULE: City Audit Logs
-- TABLE:  public.core_city_logs
-- DESCRIPTION: Immutable audit log table recording all lifecycle events (CREATE, UPDATE, DELETE)
--              for public.core_cities.
-- ============================================================================

-- 1. Create Audit Log Table
CREATE TABLE IF NOT EXISTS public.core_city_logs (
    log_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_id INTEGER NOT NULL,
    action VARCHAR(20) NOT NULL CHECK (action IN ('CREATE', 'UPDATE', 'DELETE')),
    old_data JSONB NULL,
    new_data JSONB NULL,
    action_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    action_by INTEGER NULL,
    CONSTRAINT fk_core_city_logs_city
        FOREIGN KEY (city_id)
        REFERENCES public.core_cities(city_id)
        ON DELETE RESTRICT
);

-- Comments on table and columns
COMMENT ON TABLE public.core_city_logs IS 'Immutable audit history of all changes to core_cities.';
COMMENT ON COLUMN public.core_city_logs.log_id IS 'Unique sequential identifier for the audit record.';
COMMENT ON COLUMN public.core_city_logs.city_id IS 'Foreign key referencing the affected city in core_cities.';
COMMENT ON COLUMN public.core_city_logs.action IS 'Type of operation performed: CREATE, UPDATE, or DELETE (soft-deactivation).';
COMMENT ON COLUMN public.core_city_logs.old_data IS 'JSONB snapshot of the city record before the change (NULL for CREATE).';
COMMENT ON COLUMN public.core_city_logs.new_data IS 'JSONB snapshot of the city record after the change.';
COMMENT ON COLUMN public.core_city_logs.action_at IS 'Precise timestamp when the action occurred.';
COMMENT ON COLUMN public.core_city_logs.action_by IS 'Identifier of the portal user who triggered the action (FK to core_portal_users in future).';

-- 2. Index for City Log Lookups & Timeline Queries
CREATE INDEX IF NOT EXISTS idx_core_city_logs_city_action_at
ON public.core_city_logs (
    city_id,
    action_at DESC
);

-- 3. City Audit Trigger Function
CREATE OR REPLACE FUNCTION public.core_log_city_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_action VARCHAR(20);
BEGIN
    -- ------------------------------------------------------------------------
    -- INSERT EVENT -> Log as 'CREATE'
    -- ------------------------------------------------------------------------
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.core_city_logs (
            city_id,
            action,
            old_data,
            new_data,
            action_by
        ) VALUES (
            NEW.city_id,
            'CREATE',
            NULL,
            TO_JSONB(NEW),
            NEW.created_by
        );
        RETURN NEW;

    -- ------------------------------------------------------------------------
    -- UPDATE EVENT -> Determine if regular UPDATE or soft DELETE
    -- ------------------------------------------------------------------------
    ELSIF TG_OP = 'UPDATE' THEN
        -- If city changes from active to inactive, classify as DELETE for business audit
        IF OLD.is_active = TRUE AND NEW.is_active = FALSE THEN
            v_action := 'DELETE';
        ELSE
            v_action := 'UPDATE';
        END IF;

        INSERT INTO public.core_city_logs (
            city_id,
            action,
            old_data,
            new_data,
            action_by
        ) VALUES (
            NEW.city_id,
            v_action,
            TO_JSONB(OLD),
            TO_JSONB(NEW),
            NEW.updated_by
        );
        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

-- 4. Attach Audit Trigger to core_cities
DROP TRIGGER IF EXISTS trg_core_cities_audit ON public.core_cities;
CREATE TRIGGER trg_core_cities_audit
AFTER INSERT OR UPDATE ON public.core_cities
FOR EACH ROW
EXECUTE FUNCTION public.core_log_city_changes();
