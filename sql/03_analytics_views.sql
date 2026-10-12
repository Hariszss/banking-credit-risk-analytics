/* =====================================================================
   03_analytics_views.sql
   Business-facing views on top of the core layer. Power BI connects here.

   vw_monthly_account         one row per customer per month, with labels and ratios
   vw_customer_profile        one row per customer, with bands and 6-month behaviour
   vw_segment_default_rates   default rate per segment, compared with the portfolio
   vw_monthly_portfolio_trend portfolio behaviour per month, defaulters vs non-defaulters
   vw_portfolio_kpis          single-row headline numbers

   Definitions
   - utilisation    = max(bill, 0) / credit limit. Above 1 means over the limit.
   - payment ratio  = amount paid this month / previous month's statement,
                      only where that statement was positive. 1 = paid in full.
   - delinquent     = repayment status of 1 month late or worse.
   Safe to re-run (CREATE OR ALTER).
   ===================================================================== */

USE CreditRiskDB;
GO

/* ---------------------------------------------------------------------
   1. Monthly account behaviour (180,000 rows)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW analytics.vw_monthly_account AS
WITH base AS (
    SELECT
        f.customer_id,
        m.statement_month,
        m.month_label,
        m.month_order,
        f.pay_status,
        ps.pay_status_label,
        ps.months_delayed,
        ps.is_delinquent,
        f.bill_amount,
        f.payment_amount,
        c.credit_limit,
        c.default_next_month,
        LAG(f.bill_amount) OVER (PARTITION BY f.customer_id ORDER BY m.month_order) AS prev_bill_amount
    FROM core.fact_monthly_account AS f
    JOIN core.dim_month      AS m  ON m.month_index = f.month_index
    JOIN core.dim_pay_status AS ps ON ps.pay_status = f.pay_status
    JOIN core.dim_customer   AS c  ON c.customer_id = f.customer_id
)
SELECT
    *,
    CAST(CASE WHEN bill_amount > 0 THEN bill_amount ELSE 0 END AS DECIMAL(18, 4))
        / credit_limit                                              AS utilisation,
    CASE WHEN bill_amount > credit_limit THEN 1 ELSE 0 END          AS is_over_limit,
    CASE WHEN prev_bill_amount > 0
         THEN CAST(payment_amount AS DECIMAL(18, 4)) / prev_bill_amount
    END                                                             AS payment_ratio
FROM base;
GO

/* ---------------------------------------------------------------------
   2. Customer profile (30,000 rows)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW analytics.vw_customer_profile AS
WITH behaviour AS (
    SELECT
        customer_id,
        COUNT(CASE WHEN is_delinquent = 1 THEN 1 END)           AS months_delinquent_6m,
        MAX(months_delayed)                                      AS max_months_delayed_6m,
        AVG(utilisation)                                         AS avg_utilisation_6m,
        SUM(is_over_limit)                                       AS months_over_limit_6m,
        SUM(bill_amount)                                         AS total_billed_6m,
        SUM(payment_amount)                                      AS total_paid_6m,
        AVG(CASE WHEN payment_ratio > 1 THEN 1 ELSE payment_ratio END) AS avg_payment_ratio_capped,
        MAX(CASE WHEN month_order = 6 THEN pay_status END)       AS latest_pay_status,
        MAX(CASE WHEN month_order = 6 THEN months_delayed END)   AS latest_months_delayed,
        MAX(CASE WHEN month_order = 6 THEN bill_amount END)      AS latest_bill_amount,
        MAX(CASE WHEN month_order = 6 THEN utilisation END)      AS latest_utilisation
    FROM analytics.vw_monthly_account
    GROUP BY customer_id
)
SELECT
    c.customer_id,
    c.age,
    CASE WHEN c.age < 30 THEN '21-29'
         WHEN c.age < 40 THEN '30-39'
         WHEN c.age < 50 THEN '40-49'
         WHEN c.age < 60 THEN '50-59'
         ELSE '60+' END                                          AS age_band,
    s.sex_label,
    e.education_group,
    ma.marriage_group,
    c.credit_limit,
    CASE WHEN c.credit_limit <  50000 THEN '1. < 50k'
         WHEN c.credit_limit < 100000 THEN '2. 50k-100k'
         WHEN c.credit_limit < 200000 THEN '3. 100k-200k'
         WHEN c.credit_limit < 500000 THEN '4. 200k-500k'
         ELSE '5. 500k+' END                                     AS credit_limit_band,
    b.latest_pay_status,
    ps.pay_status_label                                          AS latest_pay_status_label,
    b.latest_months_delayed,
    b.latest_bill_amount,
    b.latest_utilisation,
    CASE WHEN b.latest_utilisation <  0.30 THEN '1. < 30%'
         WHEN b.latest_utilisation <  0.70 THEN '2. 30-70%'
         WHEN b.latest_utilisation <= 1.00 THEN '3. 70-100%'
         ELSE '4. Over limit' END                                AS utilisation_band,
    b.avg_utilisation_6m,
    b.months_delinquent_6m,
    b.max_months_delayed_6m,
    b.months_over_limit_6m,
    b.total_billed_6m,
    b.total_paid_6m,
    b.avg_payment_ratio_capped,
    /* Transparent rule-based early-warning segment, built only from
       information available by end of Sep 2005 (no target leakage). */
    CASE WHEN b.latest_months_delayed >= 2 OR b.months_delinquent_6m >= 3 THEN '3. High'
         WHEN b.latest_months_delayed  = 1 OR b.months_delinquent_6m >= 1
              OR b.latest_utilisation > 0.90                              THEN '2. Medium'
         ELSE '1. Low' END                                       AS early_warning_segment,
    CAST(c.default_next_month AS INT)                            AS default_next_month
FROM core.dim_customer   AS c
JOIN behaviour           AS b  ON b.customer_id = c.customer_id
JOIN core.dim_sex        AS s  ON s.sex_code = c.sex_code
JOIN core.dim_education  AS e  ON e.education_code = c.education_code
JOIN core.dim_marriage   AS ma ON ma.marriage_code = c.marriage_code
JOIN core.dim_pay_status AS ps ON ps.pay_status = b.latest_pay_status;
GO

/* ---------------------------------------------------------------------
   3. Default rate per segment, long format so Power BI can slice by type
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW analytics.vw_segment_default_rates AS
WITH segments AS (
    SELECT 'Age band'              AS segment_type, age_band              AS segment_value, default_next_month FROM analytics.vw_customer_profile
    UNION ALL SELECT 'Sex',                   sex_label,             default_next_month FROM analytics.vw_customer_profile
    UNION ALL SELECT 'Education',             education_group,       default_next_month FROM analytics.vw_customer_profile
    UNION ALL SELECT 'Marital status',        marriage_group,        default_next_month FROM analytics.vw_customer_profile
    UNION ALL SELECT 'Credit limit band',     credit_limit_band,     default_next_month FROM analytics.vw_customer_profile
    UNION ALL SELECT 'Utilisation band (Sep)',utilisation_band,      default_next_month FROM analytics.vw_customer_profile
    UNION ALL SELECT 'Repayment status (Sep)',latest_pay_status_label, default_next_month FROM analytics.vw_customer_profile
    UNION ALL SELECT 'Early-warning segment', early_warning_segment, default_next_month FROM analytics.vw_customer_profile
),
portfolio AS (
    SELECT AVG(CAST(default_next_month AS DECIMAL(10, 6))) AS portfolio_default_rate,
           COUNT(*)                                        AS portfolio_customers
    FROM analytics.vw_customer_profile
)
SELECT
    s.segment_type,
    s.segment_value,
    COUNT(*)                                                     AS customers,
    SUM(s.default_next_month)                                    AS defaults,
    AVG(CAST(s.default_next_month AS DECIMAL(10, 6)))            AS default_rate,
    CAST(COUNT(*) AS DECIMAL(10, 6)) / p.portfolio_customers     AS share_of_customers,
    -- lift > 1: segment defaults more often than the portfolio average
    AVG(CAST(s.default_next_month AS DECIMAL(10, 6))) / p.portfolio_default_rate AS default_rate_lift
FROM segments AS s
CROSS JOIN portfolio AS p
GROUP BY s.segment_type, s.segment_value, p.portfolio_default_rate, p.portfolio_customers;
GO

/* ---------------------------------------------------------------------
   4. Portfolio trend per month, split by next-month outcome
      Shows how the behaviour of future defaulters diverges over time.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW analytics.vw_monthly_portfolio_trend AS
SELECT
    statement_month,
    month_label,
    month_order,
    CASE default_next_month WHEN 1 THEN 'Defaulted in Oct' ELSE 'Did not default' END AS outcome_group,
    COUNT(*)                                                     AS customers,
    SUM(CAST(is_delinquent AS INT))                              AS delinquent_customers,
    AVG(CAST(is_delinquent AS DECIMAL(10, 6)))                   AS delinquency_rate,
    AVG(utilisation)                                             AS avg_utilisation,
    AVG(CAST(is_over_limit AS DECIMAL(10, 6)))                   AS over_limit_rate,
    SUM(bill_amount)                                             AS total_billed,
    SUM(payment_amount)                                          AS total_paid
FROM analytics.vw_monthly_account
GROUP BY statement_month, month_label, month_order, default_next_month;
GO

/* ---------------------------------------------------------------------
   5. Headline KPIs (one row)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW analytics.vw_portfolio_kpis AS
SELECT
    COUNT(*)                                                     AS customers,
    SUM(default_next_month)                                      AS defaults,
    AVG(CAST(default_next_month AS DECIMAL(10, 6)))              AS default_rate,
    SUM(credit_limit)                                            AS total_credit_limit,
    SUM(CASE WHEN latest_bill_amount > 0 THEN latest_bill_amount ELSE 0 END) AS total_outstanding_sep,
    AVG(latest_utilisation)                                      AS avg_utilisation_sep,
    AVG(CASE WHEN latest_months_delayed >= 1 THEN 1.0 ELSE 0 END) AS delinquency_rate_sep,
    AVG(CASE WHEN early_warning_segment = '3. High' THEN 1.0 ELSE 0 END) AS share_high_risk
FROM analytics.vw_customer_profile;
GO

PRINT 'Analytics views created.';
