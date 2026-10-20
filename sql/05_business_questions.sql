/* =====================================================================
   05_business_questions.sql
   Read-only queries that answer the three project questions directly
   from the analytics layer. Results are quoted in reports/management_summary.md.
   Run after src/train_model.py so the Q3c watch list has scores.

   Q1  Which customer segments carry more credit risk?
   Q2  How does repayment behaviour change over time?
   Q3  Which customers are likely to default next month?

   Run: sqlcmd -S <server> -E -C -i sql\04_business_questions.sql
   ===================================================================== */

USE CreditRiskDB;
GO
SET NOCOUNT ON;

/* ---------------------------------------------------------------------
   Q1a. Segments ranked by default-rate lift.
        Only segments with at least 1% of customers, so tiny groups
        (e.g. "7 months late", 9 customers) don't top the list by chance.
   --------------------------------------------------------------------- */
SELECT
    segment_type,
    segment_value,
    customers,
    CAST(share_of_customers AS DECIMAL(5, 3)) AS share_of_customers,
    CAST(default_rate       AS DECIMAL(5, 3)) AS default_rate,
    CAST(default_rate_lift  AS DECIMAL(5, 2)) AS lift
FROM analytics.vw_segment_default_rates
WHERE share_of_customers >= 0.01
ORDER BY default_rate_lift DESC;

/* ---------------------------------------------------------------------
   Q1b. Behaviour vs demographics: spread of default rates within each
        segment type. A wide spread means the dimension separates risk well.
   --------------------------------------------------------------------- */
SELECT
    segment_type,
    CAST(MIN(default_rate) AS DECIMAL(5, 3))                     AS lowest_rate,
    CAST(MAX(default_rate) AS DECIMAL(5, 3))                     AS highest_rate,
    CAST(MAX(default_rate) - MIN(default_rate) AS DECIMAL(5, 3)) AS spread
FROM analytics.vw_segment_default_rates
WHERE share_of_customers >= 0.01
GROUP BY segment_type
ORDER BY spread DESC;

/* ---------------------------------------------------------------------
   Q1c. Credit limit x utilisation. Low limits are risky at any
        utilisation; high limits only become risky when they are maxed out.
   --------------------------------------------------------------------- */
SELECT
    credit_limit_band,
    utilisation_band,
    COUNT(*)                                                     AS customers,
    CAST(AVG(CAST(default_next_month AS DECIMAL(10, 6))) AS DECIMAL(5, 3)) AS default_rate
FROM analytics.vw_customer_profile
GROUP BY credit_limit_band, utilisation_band
ORDER BY credit_limit_band, utilisation_band;

/* ---------------------------------------------------------------------
   Q2a. Delinquency trend (2+ months late, comparable Apr-Aug).
        Future defaulters drift away from the rest months before default.
   --------------------------------------------------------------------- */
SELECT
    month_label,
    outcome_group,
    CAST(delinquency_2plus_rate AS DECIMAL(5, 3))                AS delinquency_2plus_rate,
    CAST(avg_utilisation        AS DECIMAL(5, 3))                AS avg_utilisation,
    CAST(CAST(total_paid AS DECIMAL(18, 4)) / NULLIF(total_billed, 0) AS DECIMAL(5, 3)) AS paid_to_billed
FROM analytics.vw_monthly_portfolio_trend
ORDER BY month_order, outcome_group;

/* ---------------------------------------------------------------------
   Q2b. Roll-rate matrix: once a customer is behind, how often do they cure?
   --------------------------------------------------------------------- */
SELECT
    from_bucket,
    CAST(SUM(CASE WHEN to_bucket = '1. Up to date'     THEN roll_rate ELSE 0 END) AS DECIMAL(5, 3)) AS to_up_to_date,
    CAST(SUM(CASE WHEN to_bucket = '2. 1-2 months late' THEN roll_rate ELSE 0 END) AS DECIMAL(5, 3)) AS to_1_2_months,
    CAST(SUM(CASE WHEN to_bucket = '3. 3+ months late' THEN roll_rate ELSE 0 END) AS DECIMAL(5, 3)) AS to_3plus_months,
    SUM(transitions)                                             AS transitions
FROM analytics.vw_roll_rates
GROUP BY from_bucket
ORDER BY from_bucket;

/* ---------------------------------------------------------------------
   Q3a. How good is the transparent rule-based early-warning segment?
        capture_rate = share of all defaulters that fall in the segment
        precision    = share of the segment that defaults
   --------------------------------------------------------------------- */
SELECT
    early_warning_segment,
    COUNT(*)                                                     AS customers,
    SUM(default_next_month)                                      AS defaults,
    CAST(AVG(CAST(default_next_month AS DECIMAL(10, 6))) AS DECIMAL(5, 3)) AS precision,
    CAST(CAST(SUM(default_next_month) AS DECIMAL(10, 6))
         / SUM(SUM(default_next_month)) OVER () AS DECIMAL(5, 3)) AS capture_rate
FROM analytics.vw_customer_profile
GROUP BY early_warning_segment
ORDER BY early_warning_segment;

/* ---------------------------------------------------------------------
   Q3b. Data caveat: cards with no bills in 6 months still "default".
        Known quirk of this dataset; flagged in the summary, not modelled away.
   --------------------------------------------------------------------- */
SELECT
    CASE WHEN total_billed_6m <= 0 THEN 'No bills in 6 months' ELSE 'Active' END AS activity,
    COUNT(*)                                                     AS customers,
    CAST(AVG(CAST(default_next_month AS DECIMAL(10, 6))) AS DECIMAL(5, 3)) AS default_rate
FROM analytics.vw_customer_profile
GROUP BY CASE WHEN total_billed_6m <= 0 THEN 'No bills in 6 months' ELSE 'Active' END;

/* ---------------------------------------------------------------------
   Q3c. Model-based view: default rate and capture per risk band, and the
        top of the watch list (highest predicted probability of default).
   --------------------------------------------------------------------- */
SELECT
    risk_band,
    COUNT(*)                                                     AS customers,
    CAST(AVG(pd_score) AS DECIMAL(5, 3))                         AS avg_predicted_pd,
    CAST(AVG(CAST(default_next_month AS DECIMAL(10, 6))) AS DECIMAL(5, 3)) AS actual_default_rate,
    CAST(CAST(SUM(default_next_month) AS DECIMAL(10, 6))
         / SUM(SUM(default_next_month)) OVER () AS DECIMAL(5, 3)) AS capture_rate
FROM analytics.vw_customer_risk
GROUP BY risk_band
ORDER BY risk_band;

SELECT TOP (20)
    customer_id,
    CAST(pd_score AS DECIMAL(5, 3))                              AS pd_score,
    risk_band,
    latest_pay_status_label,
    months_delinquent_6m,
    CAST(latest_utilisation AS DECIMAL(5, 2))                    AS latest_utilisation,
    credit_limit
FROM analytics.vw_customer_risk
ORDER BY pd_score DESC;
GO
