import psycopg2
import time

DB_URI = "postgresql://postgres:8S5%5DU3%40L%5EXz)%5CFH%7D@35.200.196.113:5432/postgres"

def deploy():
    print("Connecting to PostgreSQL...")
    conn = psycopg2.connect(DB_URI)
    conn.autocommit = True
    cur = conn.cursor()

    with open(r"c:\Users\anura\RYD\backend\Hisaab Final Table\triggers.sql", "r", encoding="utf-8") as f:
        sql_content = f.read()

    print("Deploying triggers.sql...")
    start_time = time.time()
    cur.execute(sql_content)
    elapsed = time.time() - start_time
    print(f"triggers.sql successfully executed and deployed in {elapsed:.2f} seconds!")

    for notice in conn.notices:
        print(notice.strip())

    cur.close()
    conn.close()

if __name__ == "__main__":
    deploy()
