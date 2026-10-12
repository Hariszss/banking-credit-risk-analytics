/* =====================================================================
   02_load_data.sql
   Populates core tables from staging.credit_default_raw.
   Prerequisite: python src/load_to_sql.py
   Safe to re-run.
   ===================================================================== */

USE CreditRiskDB;
GO

SET XACT_ABORT ON;
BEGIN TRANSACTION;

DELETE FROM core.fact_monthly_account;
DELETE FROM core.dim_customer;
DELETE FROM core.dim_month;
DELETE FROM core.dim_pay_status;
DELETE FROM core.dim_education;
DELETE FROM core.dim_marriage;
DELETE FROM core.dim_sex;

/* ---------- lookups ---------- */
INSERT INTO core.dim_sex (sex_code, sex_label) VALUES
    (1, 'Male'),
    (2, 'Female');

INSERT INTO core.dim_education (education_code, education_label, education_group, is_documented) VALUES
    (0, 'Unknown (code 0)', 'Other/Unknown',   0),
    (1, 'Graduate school',  'Graduate school', 1),
    (2, 'University',       'University',      1),
    (3, 'High school',      'High school',     1),
    (4, 'Other',            'Other/Unknown',   1),
    (5, 'Unknown (code 5)', 'Other/Unknown',   0),
    (6, 'Unknown (code 6)', 'Other/Unknown',   0);

INSERT INTO core.dim_marriage (marriage_code, marriage_label, marriage_group, is_documented) VALUES
    (0, 'Unknown (code 0)', 'Other/Unknown', 0),
    (1, 'Married',          'Married',       1),
    (2, 'Single',           'Single',        1),
    (3, 'Other',            'Other/Unknown', 1);

INSERT INTO core.dim_pay_status (pay_status, pay_status_label, months_delayed, is_delinquent, is_documented) VALUES
    (-2, 'No consumption',          0, 0, 0),
    (-1, 'Paid in full',            0, 0, 1),
    ( 0, 'Revolving (minimum paid)',0, 0, 0),
    ( 1, '1 month late',            1, 1, 1),
    ( 2, '2 months late',           2, 1, 1),
    ( 3, '3 months late',           3, 1, 1),
    ( 4, '4 months late',           4, 1, 1),
    ( 5, '5 months late',           5, 1, 1),
    ( 6, '6 months late',           6, 1, 1),
    ( 7, '7 months late',           7, 1, 1),
    ( 8, '8 months late',           8, 1, 1),
    ( 9, '9+ months late',          9, 1, 1);

INSERT INTO core.dim_month (month_index, statement_month, month_label, month_order) VALUES
    (1, '2005-09-01', 'Sep 2005', 6),
    (2, '2005-08-01', 'Aug 2005', 5),
    (3, '2005-07-01', 'Jul 2005', 4),
    (4, '2005-06-01', 'Jun 2005', 3),
    (5, '2005-05-01', 'May 2005', 2),
    (6, '2005-04-01', 'Apr 2005', 1);

/* ---------- customers ---------- */
INSERT INTO core.dim_customer
    (customer_id, credit_limit, sex_code, education_code, marriage_code, age, default_next_month)
SELECT customer_id, LIMIT_BAL, SEX, EDUCATION, MARRIAGE, AGE, default_next_month
FROM staging.credit_default_raw;

/* ---------- monthly fact: unpivot the six wide column groups ----------
   Note the source naming: repayment status is PAY_0, PAY_2..PAY_6 (no PAY_1),
   while bills and payments are numbered 1..6. All three map to month_index 1..6. */
INSERT INTO core.fact_monthly_account (customer_id, month_index, pay_status, bill_amount, payment_amount)
SELECT r.customer_id, m.month_index, m.pay_status, m.bill_amount, m.payment_amount
FROM staging.credit_default_raw AS r
CROSS APPLY (VALUES
    (1, r.PAY_0, r.BILL_AMT1, r.PAY_AMT1),
    (2, r.PAY_2, r.BILL_AMT2, r.PAY_AMT2),
    (3, r.PAY_3, r.BILL_AMT3, r.PAY_AMT3),
    (4, r.PAY_4, r.BILL_AMT4, r.PAY_AMT4),
    (5, r.PAY_5, r.BILL_AMT5, r.PAY_AMT5),
    (6, r.PAY_6, r.BILL_AMT6, r.PAY_AMT6)
) AS m (month_index, pay_status, bill_amount, payment_amount);

COMMIT TRANSACTION;
GO

/* ---------- reconciliation checks: every row should say OK ---------- */
SELECT check_name, expected, actual,
       CASE WHEN expected = actual THEN 'OK' ELSE 'MISMATCH' END AS result
FROM (
    SELECT 'customers'        AS check_name, (SELECT COUNT(*) FROM staging.credit_default_raw) AS expected,
                                             (SELECT COUNT(*) FROM core.dim_customer)          AS actual
    UNION ALL
    SELECT 'monthly rows',    (SELECT COUNT(*) * 6 FROM staging.credit_default_raw),
                              (SELECT COUNT(*) FROM core.fact_monthly_account)
    UNION ALL
    SELECT 'defaults',        (SELECT SUM(CAST(default_next_month AS INT)) FROM staging.credit_default_raw),
                              (SELECT SUM(CAST(default_next_month AS INT)) FROM core.dim_customer)
    UNION ALL
    SELECT 'total Sep bills', (SELECT SUM(BILL_AMT1) FROM staging.credit_default_raw),
                              (SELECT SUM(bill_amount) FROM core.fact_monthly_account WHERE month_index = 1)
    UNION ALL
    SELECT 'total payments',  (SELECT SUM(PAY_AMT1 + PAY_AMT2 + PAY_AMT3 + PAY_AMT4 + PAY_AMT5 + PAY_AMT6)
                               FROM staging.credit_default_raw),
                              (SELECT SUM(payment_amount) FROM core.fact_monthly_account)
) AS c;
GO
