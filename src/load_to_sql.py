"""Load data/processed/credit_default_validated.csv into staging.credit_default_raw.

Run sql/01_create_tables.sql first. Afterwards run sql/02_load_data.sql to
populate the core tables from staging.

Connection defaults to a local SQL Server Express instance with Windows auth;
override with the SQL_SERVER / SQL_DATABASE environment variables.
"""
import os
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

ROOT = Path(__file__).resolve().parents[1]
INPUT = ROOT / "data" / "processed" / "credit_default_validated.csv"

SERVER = os.getenv("SQL_SERVER", r"localhost\SQLEXPRESS")
DATABASE = os.getenv("SQL_DATABASE", "CreditRiskDB")

url = URL.create(
    "mssql+pyodbc",
    host=SERVER,
    database=DATABASE,
    query={
        "driver": "ODBC Driver 18 for SQL Server",
        "trusted_connection": "yes",
        "TrustServerCertificate": "yes",  # local dev instance uses a self-signed cert
    },
)
engine = create_engine(url, fast_executemany=True)

df = pd.read_csv(INPUT)
assert len(df) == 30_000, f"expected 30,000 rows, got {len(df)}"

with engine.begin() as conn:
    conn.execute(text("TRUNCATE TABLE staging.credit_default_raw"))
    df.to_sql(
        "credit_default_raw",
        conn,
        schema="staging",
        if_exists="append",
        index=False,
        chunksize=5_000,
    )
    loaded = conn.execute(text("SELECT COUNT(*) FROM staging.credit_default_raw")).scalar()

print(f"Loaded {loaded:,} rows into {DATABASE}.staging.credit_default_raw on {SERVER}")
assert loaded == len(df)
