# City Audit Logs (`public.core_city_logs`) — Knowledge Transfer & Technical Specification

## 1. Overview & Audit Architecture

`public.core_city_logs` is an immutable, append-only ledger that captures every lifecycle event and state mutation occurring in `public.core_cities`. 

It answers critical compliance and operational questions:
- **What action occurred?** (`CREATE`, `UPDATE`, `DELETE`)
- **What was the exact previous state?** (`old_data` JSONB)
- **What is the new state?** (`new_data` JSONB)
- **When did it occur?** (`action_at` TIMESTAMPTZ)
- **Who executed the change?** (`action_by` INTEGER)

---

## 2. Table Schema Definition

```sql
CREATE TABLE public.core_city_logs (
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

CREATE INDEX idx_core_city_logs_city_action_at
ON public.core_city_logs (city_id, action_at DESC);
```

### Data Dictionary

| Column Name | Data Type | Nullable | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `log_id` | `BIGINT` | **No** | Identity (1, 2, ...) | Primary key, monotonically increasing log entry ID. |
| `city_id` | `INTEGER` | **No** | *None* | Foreign key referencing `public.core_cities.city_id`. |
| `action` | `VARCHAR(20)` | **No** | *None* | Constrained to `'CREATE'`, `'UPDATE'`, or `'DELETE'`. |
| `old_data` | `JSONB` | **Yes** | `NULL` | Full JSONB snapshot of the record prior to modification (`NULL` for `CREATE`). |
| `new_data` | `JSONB` | **Yes** | `NULL` | Full JSONB snapshot of the record after modification. |
| `action_at` | `TIMESTAMPTZ` | **No** | `CURRENT_TIMESTAMP` | Precise system timestamp when the event was recorded. |
| `action_by` | `INTEGER` | **Yes** | `NULL` | Portal user ID responsible for triggering the action. |

---

## 3. Action State Machine & Trigger Logic

The table is populated automatically via PostgreSQL trigger `trg_core_cities_audit` executing `public.core_log_city_changes()`.

```mermaid
flowchart TD
    A[City Modification Event on core_cities] --> B{Operation Type?}
    B -->|INSERT| C[Action = 'CREATE'<br/>old_data = NULL<br/>new_data = TO_JSONB(NEW)<br/>action_by = NEW.created_by]
    B -->|UPDATE| D{OLD.is_active = TRUE<br/>AND NEW.is_active = FALSE?}
    D -->|Yes| E[Action = 'DELETE'<br/>old_data = TO_JSONB(OLD)<br/>new_data = TO_JSONB(NEW)<br/>action_by = NEW.updated_by]
    D -->|No| F[Action = 'UPDATE'<br/>old_data = TO_JSONB(OLD)<br/>new_data = TO_JSONB(NEW)<br/>action_by = NEW.updated_by]
    C --> G[Insert Into core_city_logs]
    E --> G
    F --> G
```

### Supported Actions:
1. **`CREATE`**: Triggered on `INSERT INTO core_cities`. `old_data` is `NULL`, `new_data` captures all initial columns.
2. **`UPDATE`**: Triggered on normal updates (e.g., changing city name or state). Captures full before and after states.
3. **`DELETE`**: Triggered when a city is deactivated (`is_active` flipped from `TRUE` to `FALSE`). This allows the portal to reflect a soft deletion in the audit timeline.

---

## 4. Querying Audit History for Portal UI

### 4.1. City History Timeline View
To display the change history of a city in the portal:

```sql
SELECT
    log_id,
    action,
    action_at,
    action_by,
    old_data,
    new_data
FROM public.core_city_logs
WHERE city_id = :selected_city_id
ORDER BY action_at DESC;
```

### 4.2. Field-Level Change Inspection (Diff)
To inspect exact field-level differences between old and new values:

```sql
SELECT
    log_id,
    action,
    action_at,
    old_data->>'city_name' AS previous_city_name,
    new_data->>'city_name' AS current_city_name,
    old_data->>'is_active' AS previous_status,
    new_data->>'is_active' AS current_status
FROM public.core_city_logs
WHERE city_id = :selected_city_id
ORDER BY log_id DESC;
```

---

## 5. Future Schema Extensions (Foreign Keys)

Once `core_portal_users` is deployed, attach the audit user reference:

```sql
ALTER TABLE public.core_city_logs
    ADD CONSTRAINT fk_core_city_logs_action_by
    FOREIGN KEY (action_by)
    REFERENCES public.core_portal_users(portal_user_id);
```

---

## 6. Execution & Testing Files

- `01_create_core_city_logs.sql`: Table DDL, index, foreign key, and audit trigger function.
- `02_test_core_city_logs.sql`: End-to-end verification script testing `CREATE`, `UPDATE`, and `DELETE` log capture inside safe rollback transactions.
