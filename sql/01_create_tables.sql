/* =====================================================================
   01_create_tables.sql
   Creates the CreditRiskDB database, schemas and tables.

   staging   raw copy of the CSV, loaded by src/load_to_sql.py
   core      cleaned star schema (dimensions + monthly fact)
   analytics views for Power BI and reporting (03_analytics_views.sql)

   Run: sqlcmd -S .\SQLEXPRESS -E -i sql\01_create_tables.sql
   Safe to re-run: drops and recreates the tables.
   ===================================================================== */

IF DB_ID('CreditRiskDB') IS NULL
    CREATE DATABASE CreditRiskDB;
GO

USE CreditRiskDB;
GO

IF SCHEMA_ID('staging')   IS NULL EXEC('CREATE SCHEMA staging');
IF SCHEMA_ID('core')      IS NULL EXEC('CREATE SCHEMA core');
IF SCHEMA_ID('analytics') IS NULL EXEC('CREATE SCHEMA analytics');
GO

-- Drop in dependency order
DROP TABLE IF EXISTS core.fact_monthly_account;
DROP TABLE IF EXISTS core.dim_customer;
DROP TABLE IF EXISTS core.dim_month;
DROP TABLE IF EXISTS core.dim_pay_status;
DROP TABLE IF EXISTS core.dim_education;
DROP TABLE IF EXISTS core.dim_marriage;
DROP TABLE IF EXISTS core.dim_sex;
DROP TABLE IF EXISTS staging.credit_default_raw;
GO

/* ---------- staging: same columns as data/processed/credit_default_validated.csv ---------- */
CREATE TABLE staging.credit_default_raw (
    customer_id         INT     NOT NULL,
    LIMIT_BAL           BIGINT  NOT NULL,
    SEX                 TINYINT NOT NULL,
    EDUCATION           TINYINT NOT NULL,
    MARRIAGE            TINYINT NOT NULL,
    AGE                 TINYINT NOT NULL,
    PAY_0 SMALLINT NOT NULL, PAY_2 SMALLINT NOT NULL, PAY_3 SMALLINT NOT NULL,
    PAY_4 SMALLINT NOT NULL, PAY_5 SMALLINT NOT NULL, PAY_6 SMALLINT NOT NULL,
    BILL_AMT1 BIGINT NOT NULL, BILL_AMT2 BIGINT NOT NULL, BILL_AMT3 BIGINT NOT NULL,
    BILL_AMT4 BIGINT NOT NULL, BILL_AMT5 BIGINT NOT NULL, BILL_AMT6 BIGINT NOT NULL,
    PAY_AMT1  BIGINT NOT NULL, PAY_AMT2  BIGINT NOT NULL, PAY_AMT3  BIGINT NOT NULL,
    PAY_AMT4  BIGINT NOT NULL, PAY_AMT5  BIGINT NOT NULL, PAY_AMT6  BIGINT NOT NULL,
    default_next_month  TINYINT NOT NULL
);
GO

/* ---------- lookup dimensions ---------- */
CREATE TABLE core.dim_sex (
    sex_code    TINYINT      NOT NULL PRIMARY KEY,
    sex_label   VARCHAR(20)  NOT NULL
);

-- Undocumented codes (0, 5, 6) are kept as their own rows but grouped as 'Other/Unknown'
CREATE TABLE core.dim_education (
    education_code   TINYINT      NOT NULL PRIMARY KEY,
    education_label  VARCHAR(30)  NOT NULL,
    education_group  VARCHAR(30)  NOT NULL,
    is_documented    BIT          NOT NULL
);

CREATE TABLE core.dim_marriage (
    marriage_code    TINYINT      NOT NULL PRIMARY KEY,
    marriage_label   VARCHAR(30)  NOT NULL,
    marriage_group   VARCHAR(30)  NOT NULL,
    is_documented    BIT          NOT NULL
);

-- Repayment status. -2 and 0 are undocumented by UCI; labels follow the common interpretation.
CREATE TABLE core.dim_pay_status (
    pay_status        SMALLINT     NOT NULL PRIMARY KEY,
    pay_status_label  VARCHAR(40)  NOT NULL,
    months_delayed    TINYINT      NOT NULL,   -- 0 for -2/-1/0
    is_delinquent     BIT          NOT NULL,   -- 1 when payment is at least 1 month late
    is_documented     BIT          NOT NULL
);

-- month_index follows the source column suffix: 1 = Sep 2005 ... 6 = Apr 2005
CREATE TABLE core.dim_month (
    month_index      TINYINT      NOT NULL PRIMARY KEY,
    statement_month  DATE         NOT NULL,
    month_label      VARCHAR(10)  NOT NULL,
    month_order      TINYINT      NOT NULL     -- 1 = Apr (oldest) ... 6 = Sep (latest), for charts
);
GO

/* ---------- customer dimension ---------- */
CREATE TABLE core.dim_customer (
    customer_id         INT      NOT NULL PRIMARY KEY,
    credit_limit        BIGINT   NOT NULL,     -- LIMIT_BAL: a credit limit, NOT exposure at default
    sex_code            TINYINT  NOT NULL REFERENCES core.dim_sex (sex_code),
    education_code      TINYINT  NOT NULL REFERENCES core.dim_education (education_code),
    marriage_code       TINYINT  NOT NULL REFERENCES core.dim_marriage (marriage_code),
    age                 TINYINT  NOT NULL,
    default_next_month  BIT      NOT NULL,     -- target: default in Oct 2005
    CONSTRAINT ck_customer_limit CHECK (credit_limit > 0),
    CONSTRAINT ck_customer_age   CHECK (age BETWEEN 18 AND 100)
);
GO

/* ---------- monthly fact: one row per customer per month (30,000 x 6) ---------- */
CREATE TABLE core.fact_monthly_account (
    customer_id     INT       NOT NULL REFERENCES core.dim_customer (customer_id),
    month_index     TINYINT   NOT NULL REFERENCES core.dim_month (month_index),
    pay_status      SMALLINT  NOT NULL REFERENCES core.dim_pay_status (pay_status),
    bill_amount     BIGINT    NOT NULL,        -- statement balance; negative = credit balance
    payment_amount  BIGINT    NOT NULL,        -- amount paid during the month
    CONSTRAINT pk_fact_monthly_account PRIMARY KEY (customer_id, month_index),
    CONSTRAINT ck_payment_nonneg CHECK (payment_amount >= 0)
);
GO

PRINT 'CreditRiskDB tables created.';
