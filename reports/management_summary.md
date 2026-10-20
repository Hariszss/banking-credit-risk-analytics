# Credit risk: management summary

**Portfolio:** 30,000 credit card customers, statements Apr–Sep 2005, default measured in Oct 2005.
**Question:** where does the risk sit, how does it build up, and can we see defaults coming?

## Key findings

1. **Repayment behaviour predicts default; demographics barely do.** Customers 2 months late in September default at **69%**, against **22%** for the portfolio. Sex, marital status and age move the default rate by 3–8 percentage points at most.
2. **Low credit limits are the riskiest product segment.** Limits under 50k default at **36%** (1.6× the average), whatever their utilisation. High-limit customers only become risky when they max out their card.
3. **Risk builds up months in advance.** Among customers who default in October, the share 2+ months late rises from **24% in April to 37% in August**. For customers who don't default it stays around **6–8%**. Future defaulters also run higher utilisation (49% vs 39%) and repay a smaller share of their bill every month.
4. **Arrears are sticky.** Once a customer is 2 months late, only **30%** are back up to date the next month. 64% stay 1–2 months behind and 6% fall further behind. (Apr–Aug transitions; "1 month late" is almost never coded in those months, so this bucket is effectively "2 months late".)
5. **A model ranks customers better than the current rule.** The early-warning model reaches a Gini of **0.56** on unseen customers, against **0.45** for the rule-based Low/Medium/High segmentation. Contacting the riskiest **20%** of customers reaches **51%** of next month's defaulters.

## Recommendations

| # | Action | Why |
|---|---|---|
| 1 | Contact the model's **Very high** band (PD 50%+, 12% of customers, 37% of all defaulters) before the next statement | 68% of this group defaults. Early contact is cheaper than collections |
| 2 | Treat a first **2-month delay** as a trigger, not a warning | Only 30% cure on their own |
| 3 | Review **limit increases** and pricing for the under-50k segment | 36% default rate at every utilisation level |
| 4 | Keep the **rule-based segment** as a transparent fallback, and use the model for ranking and PD estimates | Both catch the same customers at the very top. The model adds value in the middle of the book and gives calibrated probabilities |
| 5 | Validate on recent, local data before any use in decisions | See limitations |

## The early-warning model in one table

Scores are out-of-fold: no customer was scored by a model that had seen them in training.

| Risk band | Customers | Predicted PD | Actual default rate | Share of all defaulters |
|---|---:|---:|---:|---:|
| Low (<10%) | 8,879 | 6.8% | 6.6% | 9% |
| Medium (10–25%) | 13,311 | 16.0% | 15.9% | 32% |
| High (25–50%) | 4,245 | 35.1% | 35.6% | 23% |
| Very high (50%+) | 3,565 | 67.5% | 68.1% | 37% |

Predicted and actual default rates match in every band. The model is **calibrated**, so its probabilities can be used as probabilities (e.g. expected defaults = 6,625 vs 6,636 actual) and not only as a ranking.

**Honest caveat:** if the model flags the same 16% of customers the rule calls "High", both catch the same 44% of defaulters at 60% precision. The rule already works well for the obvious cases. The model's gain comes from ranking everyone else, from the bands below "High", and from producing a probability instead of a label.

## What drives the prediction

Months late in the last six months, credit limit, the September delay and utilisation (average and latest), in that order ([figure](figures/feature_importance.png)). Sex and marital status were tested and add nothing (−0.0001 AUC), so they are **not used**. Predicted default rates by sex follow the actual rates (women 22.0% predicted vs 21.2% actual, men 22.9% vs 23.5%).

## Limitations

- **Data is from Taiwan in 2005**, not a Dutch portfolio today. Patterns (e.g. limit levels, cure rates) won't transfer directly. This is a method demonstration.
- **Six months of history and a single outcome month.** There's no out-of-time validation, which a production model would need.
- **No loss data.** `LIMIT_BAL` is a credit limit, not exposure at default, and there is no recovery data. So this gives PD only, no expected loss (PD × LGD × EAD).
- **Coding issues in the source:** repayment status "1 month late" only appears in September, and undocumented codes (-2, 0) were interpreted using the common convention. Trend charts use "2+ months late" to stay comparable.
- 1,071 cards with no bills in six months still show a 34% default rate. This is a known oddity of the dataset and is reported, not modelled away.

## Where to find things

- Dashboard: `powerbi/CreditRisk.pbip` (Power BI Desktop) – Portfolio overview, Risk segments, Behaviour over time, Early warning
- SQL answers to each question: `sql/05_business_questions.sql`
- Model and metrics: `src/train_model.py`, `reports/model_metrics.json`, `reports/figures/`
