"""Data-quality checks on the raw credit default file (Milestone 1, step D).

Prints a report and writes data/processed/credit_default_validated.csv with a
customer_id column added. Nothing is recoded here: we only document what we
find, cleaning decisions go into build_features.py / SQL.
"""
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw" / "credit_default.csv"
OUTPUT = ROOT / "data" / "processed" / "credit_default_validated.csv"

PAY_STATUS = ["PAY_0", "PAY_2", "PAY_3", "PAY_4", "PAY_5", "PAY_6"]
BILL_AMT = [f"BILL_AMT{i}" for i in range(1, 7)]
PAY_AMT = [f"PAY_AMT{i}" for i in range(1, 7)]

# Codes documented by UCI. Anything else is "undocumented".
DOCUMENTED = {
    "SEX": {1, 2},
    "EDUCATION": {1, 2, 3, 4},  # 1=grad school, 2=university, 3=high school, 4=others
    "MARRIAGE": {1, 2, 3},      # 1=married, 2=single, 3=others
}
# Repayment status: -1 = paid duly, 1..9 = months of delay.
# -2 and 0 appear in the data but are not in the official description.
PAY_DOCUMENTED = {-1, 1, 2, 3, 4, 5, 6, 7, 8, 9}


def section(title):
    print(f"\n=== {title} ===")


df = pd.read_csv(RAW)
df.insert(0, "customer_id", range(1, len(df) + 1))

section("Shape and missingness")
print(df.shape, "| missing cells:", int(df.isna().sum().sum()))

section("Duplicates")
print("Duplicate customer_id:", df["customer_id"].duplicated().sum())
feature_cols = [c for c in df.columns if c != "customer_id"]
print("Fully duplicated rows (excl. id):", df.duplicated(subset=feature_cols).sum())

section("Target distribution")
print(df["default_next_month"].value_counts().rename({0: "no default", 1: "default"}))
print("Default rate:", round(df["default_next_month"].mean(), 4))

section("Categorical codes")
for col, valid in DOCUMENTED.items():
    counts = df[col].value_counts().sort_index()
    bad = counts[~counts.index.isin(valid)]
    print(f"{col}: {counts.to_dict()}")
    if len(bad):
        print(f"  -> undocumented codes {bad.to_dict()} ({bad.sum()} rows)")

section("Repayment status codes (PAY_*)")
pay_counts = pd.DataFrame({c: df[c].value_counts() for c in PAY_STATUS}).fillna(0).astype(int).sort_index()
print(pay_counts)
undoc = sorted(set(pay_counts.index) - PAY_DOCUMENTED)
print("Undocumented codes present:", undoc)

section("Amounts")
print("LIMIT_BAL range:", df["LIMIT_BAL"].min(), "-", df["LIMIT_BAL"].max())
print("AGE range:", df["AGE"].min(), "-", df["AGE"].max())
for col in BILL_AMT:
    neg = (df[col] < 0).sum()
    over = (df[col] > df["LIMIT_BAL"]).sum()
    print(f"{col}: negative={neg:5d}  above limit={over:5d}  min={df[col].min():>10}  max={df[col].max():>10}")
print("Negative PAY_AMT values:", int((df[PAY_AMT] < 0).sum().sum()))
print("Customers with all-zero bills:", int((df[BILL_AMT] == 0).all(axis=1).sum()))

section("Time alignment (leakage check)")
print(
    "Column suffix -> month: PAY_0/BILL_AMT1/PAY_AMT1 = Sep 2005 ... PAY_6/BILL_AMT6/PAY_AMT6 = Apr 2005.\n"
    "Target = default in Oct 2005. All features are observed by end of Sep 2005,\n"
    "so none of them leak the outcome month."
)

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
df.to_csv(OUTPUT, index=False)
print("\nSaved:", OUTPUT)
