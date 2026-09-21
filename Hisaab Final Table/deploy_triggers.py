import os
import psycopg2
import time

DB_URI = "postgresql://postgres:8S5%5DU3%40L%5EXz)%5CFH%7D@35.200.196.113:5432/postgres"

def deploy():
    print("Connecting to PostgreSQL...")
    conn = psycopg2.connect(DB_URI)
    conn.autocommit = True
    cur = conn.cursor()

    base_dir = os.path.dirname(__file__)

    for fname in ["schema.sql", "procedures.sql", "cron.sql"]:
        fpath = os.path.join(base_dir, fname)
        if not os.path.exists(fpath):
            continue
        print(f"Deploying {fname}...")
        start_time = time.time()
        with open(fpath, "r", encoding="utf-8") as f:
            sql_content = f.read()
        cur.execute(sql_content)
        elapsed = time.time() - start_time
        print(f"  {fname} deployed successfully in {elapsed:.2f}s")

    for notice in conn.notices:
        print(notice.strip())

    cur.close()
    conn.close()
    print("Deployment complete.")

if __name__ == "__main__":
    deploy()
