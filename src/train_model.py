"""Milestone 4: predict which customers default next month (Oct 2005).

Reads features from the SQL Server analytics layer, compares three approaches
on the same cross-validation folds, evaluates the chosen one on a held-out
test set, and writes an out-of-fold probability of default (PD) for every
customer to analytics.customer_risk_score (Power BI reads it from there).

Run after sql/04_risk_score_table.sql:
    python src/train_model.py

Decision rules (fixed before looking at results):
- Gradient boosting replaces logistic regression only if it beats it by at
  least 0.01 AUC in cross-validation. Otherwise the simpler, explainable model wins.
- Sex and marital status are only kept if they add at least 0.005 AUC.
  Using them would need a fairness justification a bank is unlikely to accept.
"""
import json
import os
from datetime import datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.calibration import calibration_curve
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.inspection import permutation_importance
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score, roc_curve
from sklearn.model_selection import StratifiedKFold, cross_val_predict, cross_val_score, train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

ROOT = Path(__file__).resolve().parents[1]
FIGURES = ROOT / "reports" / "figures"
METRICS = ROOT / "reports" / "model_metrics.json"
SCORES_CSV = ROOT / "data" / "processed" / "customer_risk_scores.csv"
FIGURES.mkdir(parents=True, exist_ok=True)

SEED = 42
SERVER = os.getenv("SQL_SERVER", r"localhost\SQLEXPRESS")
DATABASE = os.getenv("SQL_DATABASE", "CreditRiskDB")

# Reference palette (light): blue, orange, aqua; muted gray for the random line
BLUE, ORANGE, AQUA, GRAY = "#2a78d6", "#eb6834", "#1baf7a", "#8a8984"
INK, INK_2 = "#0b0b0b", "#52514e"

# Probability-of-default bands used in the dashboard and the summary
BAND_EDGES = [0, 0.10, 0.25, 0.50, 1.0001]
BAND_LABELS = ["1. Low (<10%)", "2. Medium (10-25%)", "3. High (25-50%)", "4. Very high (50%+)"]

engine = create_engine(
    URL.create(
        "mssql+pyodbc",
        host=SERVER,
        database=DATABASE,
        query={
            "driver": "ODBC Driver 18 for SQL Server",
            "trusted_connection": "yes",
            "TrustServerCertificate": "yes",
        },
    )
)

# ---------------------------------------------------------------------------
# 1. Data: engineered behaviour from the SQL view + monthly detail from staging
# ---------------------------------------------------------------------------
QUERY = """
SELECT p.customer_id, p.age, p.sex_label, p.education_group, p.marriage_group,
       p.credit_limit, p.latest_pay_status, p.latest_utilisation, p.avg_utilisation_6m,
       p.months_delinquent_6m, p.max_months_delayed_6m, p.months_over_limit_6m,
       p.total_billed_6m, p.total_paid_6m, p.avg_payment_ratio_capped,
       p.early_warning_segment, p.default_next_month,
       r.PAY_0, r.PAY_2, r.PAY_3, r.PAY_4, r.PAY_5, r.PAY_6,
       r.BILL_AMT6, r.PAY_AMT1
FROM analytics.vw_customer_profile AS p
JOIN staging.credit_default_raw    AS r ON r.customer_id = p.customer_id
ORDER BY p.customer_id
"""
with engine.connect() as conn:
    df = pd.read_sql(text(QUERY), conn)
assert len(df) == 30_000
for col in ["latest_utilisation", "avg_utilisation_6m", "avg_payment_ratio_capped"]:
    df[col] = df[col].astype(float)

# Months delayed per month. -2/-1/0 all mean "not late" -> 0.
for i, col in enumerate(["PAY_0", "PAY_2", "PAY_3", "PAY_4", "PAY_5", "PAY_6"], start=1):
    df[f"delay_m{i}"] = df[col].clip(lower=0)  # m1 = Sep ... m6 = Apr

status_map = {-2: "No consumption", -1: "Paid in full", 0: "Revolving"}
df["latest_status_group"] = df["latest_pay_status"].map(status_map).fillna("Late")

df["log_credit_limit"] = np.log(df["credit_limit"])
df["payment_ratio_missing"] = df["avg_payment_ratio_capped"].isna().astype(int)
df["avg_payment_ratio_capped"] = df["avg_payment_ratio_capped"].fillna(0)
df["paid_to_billed_6m"] = np.where(
    df["total_billed_6m"] > 0, (df["total_paid_6m"] / df["total_billed_6m"]).clip(upper=2), 2
)
df["latest_payment_to_limit"] = df["PAY_AMT1"] / df["credit_limit"]
df["utilisation_trend"] = df["latest_utilisation"] - (df["BILL_AMT6"].clip(lower=0) / df["credit_limit"])
df["inactive_6m"] = (df["total_billed_6m"] <= 0).astype(int)

BEHAVIOUR_NUM = [
    "log_credit_limit",
    *[f"delay_m{i}" for i in range(1, 7)],
    "months_delinquent_6m", "max_months_delayed_6m",
    "latest_utilisation", "avg_utilisation_6m", "months_over_limit_6m", "utilisation_trend",
    "avg_payment_ratio_capped", "payment_ratio_missing", "paid_to_billed_6m",
    "latest_payment_to_limit", "inactive_6m",
]
BEHAVIOUR_CAT = ["latest_status_group"]
DEMO_NUM = ["age"]
DEMO_CAT = ["education_group"]
SENSITIVE_CAT = ["sex_label", "marriage_group"]

y = df["default_next_month"].astype(int)


def make_preprocessor(num, cat):
    return ColumnTransformer([
        ("num", StandardScaler(), num),
        ("cat", OneHotEncoder(handle_unknown="ignore", drop="first"), cat),
    ])


def make_model(kind, num, cat):
    if kind == "logistic":
        est = LogisticRegression(max_iter=2000, C=1.0)
    else:
        est = HistGradientBoostingClassifier(
            learning_rate=0.05, max_iter=300, max_leaf_nodes=15,
            min_samples_leaf=50, l2_regularization=1.0, random_state=SEED,
        )
    return Pipeline([("prep", make_preprocessor(num, cat)), ("model", est)])


def ks_statistic(y_true, score):
    fpr, tpr, _ = roc_curve(y_true, score)
    return float(np.max(tpr - fpr))


def capture_at(y_true, score, share):
    """Share of all defaulters found when contacting the top `share` of customers."""
    n = int(round(len(score) * share))
    top = np.argsort(-np.asarray(score), kind="stable")[:n]
    return float(np.asarray(y_true)[top].sum() / np.asarray(y_true).sum())


def evaluate(y_true, score):
    auc = roc_auc_score(y_true, score)
    return {
        "auc": round(auc, 4),
        "gini": round(2 * auc - 1, 4),
        "ks": round(ks_statistic(y_true, score), 4),
        "average_precision": round(average_precision_score(y_true, score), 4),
        "capture_top_10pct": round(capture_at(y_true, score, 0.10), 4),
        "capture_top_20pct": round(capture_at(y_true, score, 0.20), 4),
    }


# ---------------------------------------------------------------------------
# 2. Hold out 25% as a test set, touched once at the end
# ---------------------------------------------------------------------------
idx_train, idx_test = train_test_split(df.index, test_size=0.25, stratify=y, random_state=SEED)
X_train, X_test = df.loc[idx_train], df.loc[idx_test]
y_train, y_test = y.loc[idx_train], y.loc[idx_test]
cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=SEED)

# Rule-based benchmark from SQL: 1 = Low, 2 = Medium, 3 = High
rule_score = df["early_warning_segment"].str[0].astype(int)


def cv_auc(kind, num, cat):
    scores = cross_val_score(make_model(kind, num, cat), X_train, y_train, cv=cv, scoring="roc_auc")
    return round(float(scores.mean()), 4), round(float(scores.std()), 4)


base_num, base_cat = BEHAVIOUR_NUM + DEMO_NUM, BEHAVIOUR_CAT + DEMO_CAT
cv_results = {
    "rule_based_segment": {"auc_mean": round(roc_auc_score(y_train, rule_score.loc[idx_train]), 4), "auc_std": None},
    "logistic_regression": dict(zip(["auc_mean", "auc_std"], cv_auc("logistic", base_num, base_cat))),
    "gradient_boosting": dict(zip(["auc_mean", "auc_std"], cv_auc("boosting", base_num, base_cat))),
}
print("Cross-validated AUC on training set:")
for name, r in cv_results.items():
    print(f"  {name:22s} {r['auc_mean']:.4f}" + (f" +/- {r['auc_std']:.4f}" if r["auc_std"] else ""))

gain = cv_results["gradient_boosting"]["auc_mean"] - cv_results["logistic_regression"]["auc_mean"]
chosen_kind = "boosting" if gain >= 0.01 else "logistic"
chosen_name = {"boosting": "gradient_boosting", "logistic": "logistic_regression"}[chosen_kind]
print(f"Boosting vs logistic: {gain:+.4f} AUC -> chosen: {chosen_name}")

# Do sex / marital status add anything?
with_sensitive = cv_auc(chosen_kind, base_num, base_cat + SENSITIVE_CAT)[0]
sensitive_gain = with_sensitive - cv_results[chosen_name]["auc_mean"]
use_sensitive = sensitive_gain >= 0.005
print(f"Adding sex + marital status: {sensitive_gain:+.4f} AUC -> {'kept' if use_sensitive else 'excluded'}")
final_num = base_num
final_cat = base_cat + (SENSITIVE_CAT if use_sensitive else [])

# ---------------------------------------------------------------------------
# 3. Fit on train, evaluate once on the held-out test set
# ---------------------------------------------------------------------------
final_model = make_model(chosen_kind, final_num, final_cat).fit(X_train, y_train)
p_test = final_model.predict_proba(X_test)[:, 1]

# Logistic regression is the transparent reference even when not chosen
lr_model = make_model("logistic", final_num, final_cat).fit(X_train, y_train)
p_test_lr = lr_model.predict_proba(X_test)[:, 1]
alt_model = make_model("boosting" if chosen_kind == "logistic" else "logistic", final_num, final_cat).fit(X_train, y_train)
p_test_alt = alt_model.predict_proba(X_test)[:, 1]
rule_test = rule_score.loc[idx_test].to_numpy()

test_results = {
    chosen_name: {**evaluate(y_test, p_test), "brier": round(brier_score_loss(y_test, p_test), 4)},
    ("logistic_regression" if chosen_kind == "boosting" else "gradient_boosting"): evaluate(y_test, p_test_alt),
    "rule_based_segment": evaluate(y_test, rule_test),
}

# Like-for-like with the rule: flag the same number of customers the rule calls "High"
high_share = float((rule_test == 3).mean())
flag = p_test >= np.quantile(p_test, 1 - high_share)
same_volume = {
    "flagged_share": round(high_share, 4),
    "rule_precision": round(float(y_test[rule_test == 3].mean()), 4),
    "rule_recall": round(float(y_test[rule_test == 3].sum() / y_test.sum()), 4),
    "model_precision": round(float(y_test[flag].mean()), 4),
    "model_recall": round(float(y_test[flag].sum() / y_test.sum()), 4),
}

# Fairness check on the test set: leaving sex out does not guarantee equal
# outcomes (other features can act as proxies), so compare the groups directly
test_frame = X_test.assign(pd_score=p_test, actual=y_test)
fairness = (
    test_frame.groupby("sex_label")
    .agg(customers=("actual", "size"), actual_rate=("actual", "mean"), predicted_rate=("pd_score", "mean"),
         flagged_rate=("pd_score", lambda s: float((s >= 0.5).mean())))
    .round(4).reset_index().to_dict(orient="records")
)

print("\nHeld-out test set:")
for name, r in test_results.items():
    print(f"  {name:22s} AUC {r['auc']:.4f}  Gini {r['gini']:.4f}  KS {r['ks']:.4f}  top-20% capture {r['capture_top_20pct']:.3f}")
print("  Same flag volume as rule 'High':", same_volume)
print("  By sex:", fairness)

# ---------------------------------------------------------------------------
# 4. What drives the predictions (permutation importance on the test set)
# ---------------------------------------------------------------------------
raw_features = final_num + final_cat
perm = permutation_importance(
    final_model, X_test[raw_features], y_test, scoring="roc_auc", n_repeats=5, random_state=SEED, n_jobs=-1
)
importance = (
    pd.DataFrame({"feature": raw_features, "auc_drop": perm.importances_mean})
    .sort_values("auc_drop", ascending=False)
    .reset_index(drop=True)
)
print("\nTop drivers (AUC drop when shuffled):")
print(importance.head(10).to_string(index=False))

# Logistic coefficients (standardised, so they are comparable): sign = direction
lr_names = lr_model.named_steps["prep"].get_feature_names_out()
lr_coefs = (
    pd.DataFrame({"feature": lr_names, "coefficient": lr_model.named_steps["model"].coef_[0]})
    .assign(abs_coef=lambda d: d["coefficient"].abs())
    .sort_values("abs_coef", ascending=False)
    .drop(columns="abs_coef")
)

# ---------------------------------------------------------------------------
# 5. Score every customer out-of-fold and write to SQL Server
# ---------------------------------------------------------------------------
X_all = df[raw_features]
oof = cross_val_predict(
    make_model(chosen_kind, final_num, final_cat), X_all, y,
    cv=StratifiedKFold(n_splits=5, shuffle=True, random_state=SEED), method="predict_proba",
)[:, 1]

scores = pd.DataFrame({
    "customer_id": df["customer_id"],
    "pd_score": oof.round(6),
    "risk_decile": pd.qcut(pd.Series(oof).rank(method="first"), 10, labels=range(1, 11)).astype(int),
    "risk_band": pd.cut(oof, BAND_EDGES, labels=BAND_LABELS, right=False).astype(str),
    "model_name": chosen_name,
    "scored_at": datetime.now().replace(microsecond=0),
})
band_summary = (
    scores.assign(actual=y.values)
    .groupby("risk_band")
    .agg(customers=("actual", "size"), predicted_pd=("pd_score", "mean"), actual_rate=("actual", "mean"))
    .round(4).reset_index().to_dict(orient="records")
)
print("\nOut-of-fold risk bands:", band_summary)

with engine.begin() as conn:
    conn.execute(text("DELETE FROM analytics.customer_risk_score"))
    scores.to_sql("customer_risk_score", conn, schema="analytics", if_exists="append", index=False, chunksize=5_000)
    written = conn.execute(text("SELECT COUNT(*) FROM analytics.customer_risk_score")).scalar()
assert written == len(scores)
SCORES_CSV.parent.mkdir(parents=True, exist_ok=True)
scores.to_csv(SCORES_CSV, index=False)
print(f"Wrote {written:,} scores to analytics.customer_risk_score and {SCORES_CSV.name}")

# ---------------------------------------------------------------------------
# 6. Figures
# ---------------------------------------------------------------------------
plt.rcParams.update({
    "font.size": 10, "axes.edgecolor": INK_2, "axes.labelcolor": INK, "text.color": INK,
    "xtick.color": INK_2, "ytick.color": INK_2, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": "#e6e5e0", "grid.linewidth": 0.8, "lines.linewidth": 2,
    "figure.dpi": 150, "savefig.bbox": "tight",
})
model_label = {"logistic_regression": "Logistic regression", "gradient_boosting": "Gradient boosting"}
alt_name = [k for k in test_results if k not in (chosen_name, "rule_based_segment")][0]
curves = [
    (model_label[chosen_name] + " (chosen)", p_test, BLUE),
    (model_label[alt_name], p_test_alt, AQUA),
    ("Rule-based segment", rule_test, ORANGE),
]

# ROC
fig, ax = plt.subplots(figsize=(5.5, 5))
for label, s, c in curves:
    fpr, tpr, _ = roc_curve(y_test, s)
    ax.plot(fpr, tpr, color=c, label=f"{label}  AUC {roc_auc_score(y_test, s):.3f}")
ax.plot([0, 1], [0, 1], color=GRAY, linewidth=1, linestyle="--", label="Random")
ax.set(xlabel="False positive rate", ylabel="True positive rate (share of defaulters caught)",
       title="ROC curve, held-out test set", xlim=(0, 1), ylim=(0, 1))
ax.legend(loc="lower right", frameon=False)
fig.savefig(FIGURES / "roc_curve.png")
plt.close(fig)

# Gains: share of defaulters caught vs share of customers contacted
fig, ax = plt.subplots(figsize=(6, 4.5))
shares = np.linspace(0, 1, 101)
for label, s, c in curves[:1] + curves[2:]:
    ax.plot(shares * 100, [capture_at(y_test, s, q) * 100 if q > 0 else 0 for q in shares], color=c, label=label)
ax.plot([0, 100], [0, 100], color=GRAY, linewidth=1, linestyle="--", label="Random")
top20 = capture_at(y_test, p_test, 0.20) * 100
ax.annotate(f"Top 20% of customers\n= {top20:.0f}% of defaulters", xy=(20, top20), xytext=(35, top20 - 22),
            color=INK, arrowprops={"arrowstyle": "-", "color": INK_2})
ax.set(xlabel="Customers contacted, highest risk first (%)", ylabel="Defaulters caught (%)",
       title="Cumulative gains, held-out test set", xlim=(0, 100), ylim=(0, 100))
ax.legend(loc="lower right", frameon=False)
fig.savefig(FIGURES / "gains_chart.png")
plt.close(fig)

# Calibration: are predicted probabilities honest?
fig, ax = plt.subplots(figsize=(5.5, 5))
frac_pos, mean_pred = calibration_curve(y_test, p_test, n_bins=10, strategy="quantile")
ax.plot([0, 1], [0, 1], color=GRAY, linewidth=1, linestyle="--", label="Perfect calibration")
ax.plot(mean_pred, frac_pos, color=BLUE, marker="o", markersize=6, label=model_label[chosen_name])
ax.set(xlabel="Predicted probability of default (decile average)", ylabel="Actual default rate",
       title="Calibration, held-out test set", xlim=(0, 1), ylim=(0, 1))
ax.legend(loc="upper left", frameon=False)
fig.savefig(FIGURES / "calibration.png")
plt.close(fig)

# Drivers
readable = {
    "months_delinquent_6m": "Months late (last 6)", "log_credit_limit": "Credit limit",
    "delay_m1": "Months late in Sep", "avg_utilisation_6m": "Avg utilisation (6m)",
    "latest_utilisation": "Utilisation in Sep", "avg_payment_ratio_capped": "Avg payment ratio",
    "max_months_delayed_6m": "Worst delay (6m)", "latest_payment_to_limit": "Sep payment / limit",
    "latest_status_group": "Sep repayment status", "education_group": "Education",
    "paid_to_billed_6m": "Paid / billed (6m)", "utilisation_trend": "Utilisation trend",
    "age": "Age", "months_over_limit_6m": "Months over limit",
}
top = importance.head(10).iloc[::-1]
fig, ax = plt.subplots(figsize=(6.5, 4.5))
ax.barh(top["feature"].map(lambda f: readable.get(f, f)), top["auc_drop"], color=BLUE, height=0.6)
ax.set(xlabel="Drop in AUC when the feature is shuffled", title="What drives the prediction")
ax.grid(axis="y", visible=False)
fig.savefig(FIGURES / "feature_importance.png")
plt.close(fig)

# ---------------------------------------------------------------------------
# 7. Metrics file (quoted in the management summary)
# ---------------------------------------------------------------------------
metrics = {
    "run_at": datetime.now().isoformat(timespec="seconds"),
    "rows": {"train": int(len(idx_train)), "test": int(len(idx_test))},
    "default_rate": {"train": round(float(y_train.mean()), 4), "test": round(float(y_test.mean()), 4)},
    "cross_validation_auc": cv_results,
    "decision": {
        "boosting_minus_logistic_auc": round(gain, 4),
        "chosen_model": chosen_name,
        "sensitive_attributes_auc_gain": round(sensitive_gain, 4),
        "sensitive_attributes_used": use_sensitive,
        "features": raw_features,
    },
    "test_set": test_results,
    "same_flag_volume_as_rule_high": same_volume,
    "fairness_by_sex_test_set": fairness,
    "permutation_importance_top10": importance.head(10).round(4).to_dict(orient="records"),
    "logistic_coefficients_top10": lr_coefs.head(10).round(4).to_dict(orient="records"),
    "risk_bands_out_of_fold": band_summary,
}
METRICS.write_text(json.dumps(metrics, indent=2, default=str), encoding="utf-8")
print(f"Saved {METRICS.relative_to(ROOT)} and figures in {FIGURES.relative_to(ROOT)}")
