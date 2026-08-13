import os
from pathlib import Path
from urllib.parse import quote_plus

# Load .env file
env_path = Path(__file__).resolve().parent.parent / ".env"
if env_path.exists():
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

class Settings:
    PROJECT_NAME: str = "LetzRyd Partner App Backend"
    VERSION: str = "1.0.0"
    API_V1_STR: str = "/api"
    
    DB_HOST: str = os.getenv("DB_HOST", "35.200.196.113")
    DB_PORT: str = os.getenv("DB_PORT", "5432")
    DB_NAME: str = os.getenv("DB_NAME", "postgres")
    DB_USER: str = os.getenv("DB_USER", "postgres")
    DB_PASS: str = os.getenv("DB_PASS", "8S5]U3@L^Xz)\\FH}")
    DATABASE_URL: str = os.getenv(
        "DATABASE_URL", 
        f"postgresql://{DB_USER}:{quote_plus(DB_PASS)}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
    )

    SECRET_KEY: str = os.getenv("SECRET_KEY", "letzryd_secret_key_partner_app_2026")
    JWT_ALGORITHM: str = os.getenv("JWT_ALGORITHM", "HS256")
    ACCESS_TOKEN_EXPIRE_MINUTES: int = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "43200"))

settings = Settings()

