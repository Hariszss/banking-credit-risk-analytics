/* =====================================================================
   04_risk_score_table.sql
   Table that receives the model output from src/train_model.py, and a
   view that joins it to the customer profile for Power BI and reporting.

   pd_score is an out-of-fold prediction: every customer is scored by a
   model that did not see that customer during training, so scores of
   the 30,000 known customers are not optimistically biased.

   Safe to re-run: recreates the table (the model script refills it).
   ===================================================================== */

USE CreditRiskDB;
GO

DROP TABLE IF EXISTS analytics.customer_risk_score;
GO

CREATE TABLE analytics.customer_risk_score (
    customer_id   INT           NOT NULL PRIMARY KEY REFERENCES core.dim_customer (customer_id),
    pd_score      DECIMAL(9, 6) NOT NULL,   -- predicted probability of default in Oct 2005
    risk_decile   TINYINT       NOT NULL,   -- 10 = highest predicted risk
    risk_band     VARCHAR(20)   NOT NULL,
    model_name    VARCHAR(50)   NOT NULL,
    scored_at     DATETIME2(0)  NOT NULL,
    CONSTRAINT ck_pd_score   CHECK (pd_score BETWEEN 0 AND 1),
    CONSTRAINT ck_risk_decile CHECK (risk_decile BETWEEN 1 AND 10)
);
GO

CREATE OR ALTER VIEW analytics.vw_customer_risk AS
SELECT
    p.*,
    s.pd_score,
    s.risk_decile,
    s.risk_band,
    s.model_name
FROM analytics.vw_customer_profile      AS p
JOIN analytics.customer_risk_score      AS s ON s.customer_id = p.customer_id;
GO

PRINT 'Risk score table and view created.';
