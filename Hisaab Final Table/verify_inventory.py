import psycopg2

DB_URI = "postgresql://postgres:8S5%5DU3%40L%5EXz)%5CFH%7D@35.200.196.113:5432/postgres"

def verify():
    conn = psycopg2.connect(DB_URI)
    cur = conn.cursor()

    print("=== PROCEDURES & FUNCTIONS (proname ILIKE '%hisaab%') ===")
    cur.execute("""
        SELECT proname, prokind, proargtypes
        FROM pg_proc
        JOIN pg_namespace ON pg_proc.pronamespace = pg_namespace.oid
        WHERE nspname = 'public' AND proname ILIKE '%hisaab%'
        ORDER BY proname;
    """)
    procs = cur.fetchall()
    for p in procs:
        kind = "Procedure" if p[1] == 'p' else "Function"
        print(f" - {p[0]} ({kind})")

    print("\n=== TRIGGERS (trigger_name ILIKE '%hisaab%') ===")
    cur.execute("""
        SELECT trigger_name, event_object_table, action_timing, event_manipulation
        FROM information_schema.triggers
        WHERE trigger_schema = 'public' AND trigger_name ILIKE '%hisaab%'
        ORDER BY event_object_table, trigger_name;
    """)
    trgs = cur.fetchall()
    for t in trgs:
        print(f" - {t[0]} on {t[1]} ({t[2]} {t[3]})")

    cur.close()
    conn.close()

if __name__ == "__main__":
    verify()
