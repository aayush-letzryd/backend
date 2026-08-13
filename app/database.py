import psycopg2
from psycopg2 import pool
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from app.config import settings

# SQLAlchemy Engine & Session
engine = create_engine(
    settings.DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# psycopg2 Connection Pool for high-performance direct SQL
psycopg_pool = pool.SimpleConnectionPool(
    1, 20,
    host=settings.DB_HOST,
    port=settings.DB_PORT,
    user=settings.DB_USER,
    password=settings.DB_PASS,
    dbname=settings.DB_NAME
)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def get_raw_db_conn():
    conn = psycopg_pool.getconn()
    try:
        yield conn
    finally:
        psycopg_pool.putconn(conn)
