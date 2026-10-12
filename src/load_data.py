"""Download the UCI Default of Credit Card Clients dataset (id=350) to data/raw."""
from pathlib import Path

import pandas as pd
from ucimlrepo import fetch_ucirepo

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "data" / "raw" / "credit_default.csv"
OUTPUT.parent.mkdir(parents=True, exist_ok=True)

dataset = fetch_ucirepo(id=350)

X = dataset.data.features.copy()
y = dataset.data.targets.copy()

# ucimlrepo returns anonymous names (X1..X23, Y). Map them to the original
# column names from the dataset documentation so the rest of the project
# (SQL, Power BI) uses readable names.
variables = dataset.variables
name_map = dict(zip(variables["name"], variables["description"]))
X = X.rename(columns=lambda c: name_map.get(c, c))
y.columns = ["default_next_month"]

df = pd.concat([X.reset_index(drop=True), y.reset_index(drop=True)], axis=1)

assert len(df) == 30_000
assert df["default_next_month"].isin([0, 1]).all()

df.to_csv(OUTPUT, index=False)

print("Rows:", len(df))
print("Columns:", df.shape[1])
print("Column names:", list(df.columns))
print("Default rate:", round(df["default_next_month"].mean(), 4))
print("Missing cells:", int(df.isna().sum().sum()))
print("Saved to:", OUTPUT)
