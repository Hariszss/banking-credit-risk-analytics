# Data dictionary

Source: UCI dataset id 350. One row = one credit card customer. Amounts are in NT dollars.

| Column | Description | Notes |
|---|---|---|
| customer_id | Row id, 1–30000 | Added by `validate_data.py` (ucimlrepo drops the original ID; order matches the original file) |
| LIMIT_BAL | Credit limit (individual + family/supplementary) | Not exposure at default |
| SEX | 1 = male, 2 = female | |
| EDUCATION | 1 = graduate school, 2 = university, 3 = high school, 4 = others | 0, 5, 6 also appear (345 rows), undocumented |
| MARRIAGE | 1 = married, 2 = single, 3 = others | 0 appears (54 rows), undocumented |
| AGE | Age in years | 21–79 |
| PAY_0, PAY_2 … PAY_6 | Repayment status Sep, Aug, Jul, Jun, May, Apr 2005 | -1 = paid duly, 1–9 = months delayed. -2 and 0 also appear, undocumented (see below). No PAY_1 column |
| BILL_AMT1 … BILL_AMT6 | Statement balance Sep … Apr 2005 | Can be negative (overpayment/credit balance) |
| PAY_AMT1 … PAY_AMT6 | Amount paid Sep … Apr 2005 | |
| default_next_month | 1 = defaulted in Oct 2005 | Target |

## Data-quality findings (from `src/validate_data.py`)

- 30,000 rows, no missing values, no duplicate ids.
- 35 rows are exact duplicates on every feature. Probably different customers with identical profiles (often all-zero activity); kept for now.
- Default rate 22.12% (6,636 defaults).
- **EDUCATION** 0/5/6 and **MARRIAGE** 0 are not documented. Plan: group into "other/unknown" in the analytics layer.
- **PAY_\*** -2 and 0 are not in the official description. The common interpretation is -2 = no consumption/no balance, 0 = revolving credit (minimum paid). We keep them as separate categories rather than treating them as "on time".
- PAY_2–PAY_6 almost never contain 1 (e.g. 28 rows in PAY_2 vs 3,688 in PAY_0), so the coding probably changed between months. Something to be careful with when building delinquency trends.
- No status 9 appears anywhere; max is 8.
- 590–688 customers per month have a **negative bill** (credit balance).
- 800–2,100 customers per month have a **bill above their limit**, so over-limit usage exists.
- 866 customers have zero bills in all six months (inactive cards).

## Time alignment

Index 1 = Sep 2005 and index 6 = Apr 2005 for BILL_AMT/PAY_AMT. PAY_0 = Sep. The target month is Oct 2005, so every feature is known before the outcome and there's no leakage.
