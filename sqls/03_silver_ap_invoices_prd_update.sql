-- ============================================================================
-- SILVER_AP_INVOICES — PRD-driven update
-- Sources: SAP, Oracle, Baan (SRC-2025-003), Workday (SRC-2025-004)
-- Rules:   BR-001 (status normalization), BR-003 (Baan dedup),
--          BR-005 (payment terms — OQ-1 default: normalize at Silver),
--          BR-008 (drop system-specific columns)
-- ============================================================================
--
-- SOURCE MAPPING (Bronze → Silver)
-- ┌────────────┬───────────────────┬──────────────────┬────────────────────┬──────────────────────┐
-- │ Silver col │ SAP               │ Oracle           │ Baan               │ Workday              │
-- ├────────────┼───────────────────┼──────────────────┼────────────────────┼──────────────────────┤
-- │ SOURCE_ID  │ INVOICE_ID        │ INV_ID           │ BAN_INVOICE_ID     │ WD_INVOICE_ID        │
-- │ INV_NUMBER │ INVOICE_NUMBER    │ INV_NUM          │ BAN_INVOICE_REF    │ WD_INVOICE_NUM       │
-- │ VENDOR     │ VENDOR_NAME       │ SUPPLIER_NAME    │ BAN_VENDOR_DESC    │ WD_SUPPLIER_NAME     │
-- │ AMOUNT     │ INVOICE_AMOUNT    │ TOTAL_AMOUNT     │ BAN_AMOUNT         │ WD_AMOUNT            │
-- │ CURRENCY   │ CURRENCY_CODE     │ CURRENCY         │ BAN_CURR           │ WD_CURRENCY          │
-- │ STATUS     │ APPROVAL_STATUS   │ STATUS           │ BAN_STATUS         │ WD_APPROVAL_STATUS   │
-- │ PAY_TERMS  │ PAYMENT_TERMS     │ TERMS_CODE       │ BAN_PAY_TERMS      │ WD_PAY_TERMS         │
-- │ DESCRIPTION│ LINE_DESCRIPTION  │ DESCRIPTION      │ BAN_LINE_DESC      │ WD_MEMO              │
-- │ DROPPED    │ SAP_COMPANY_CODE  │ ORACLE_ORG_ID    │ BAN_COMPANY        │ WD_TENANT_ID         │
-- │            │ SAP_DOCUMENT_TYPE │ ORACLE_SOURCE    │                    │                      │
-- └────────────┴───────────────────┴──────────────────┴────────────────────┴──────────────────────┘
--
-- STATUS NORMALIZATION (BR-001)
--   SAP:     APPROVED→APPROVED, PENDING→PENDING
--   Oracle:  VALIDATED→APPROVED, APPROVED→APPROVED, PENDING→PENDING
--   Baan:    POSTED→APPROVED, APPROVED→APPROVED, PENDING→PENDING
--   Workday: Approved→APPROVED, In Review→PENDING
--
-- PAYMENT TERMS NORMALIZATION (BR-005, OQ-1 default: normalize at Silver)
--   NET30, N30, Net 30 → NET30
--   NET60, N60, Net 60 → NET60
--
-- ASSUMPTIONS (require engineering review)
--   OQ-1: Payment terms normalized at Silver (BR-005 decision still open)
--   OQ-2: Dedup scoped to SOURCE_SYSTEM + INVOICE_NUMBER (not global)
--   OQ-3: Column kept as SOURCE_INVOICE_ID (PRD says INVOICE_ID)
--   OQ-4: *_RAW audit columns retained (PRD is silent on these)
--   OQ-5: No downstream consumers of dropped SOURCE_ORG_CODE/SOURCE_DOC_TYPE
-- ============================================================================

CREATE OR REPLACE DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
  TARGET_LAG = '1 hour'
  WAREHOUSE = COCO_WORKSHOP_WH
  REFRESH_MODE = AUTO
  INITIALIZE = ON_CREATE
  COMMENT = 'Conformed AP invoices from SAP, Oracle, Baan, and Workday. Status normalized per BR-001. Baan dedup per BR-003. System-specific columns dropped per BR-008.'
AS
WITH unioned AS (
  -- SAP
  SELECT
    'SAP'              AS SOURCE_SYSTEM,
    INVOICE_ID         AS SOURCE_INVOICE_ID,
    INVOICE_NUMBER,
    VENDOR_ID,
    VENDOR_NAME,
    INVOICE_DATE,
    DUE_DATE,
    INVOICE_AMOUNT,
    CURRENCY_CODE,
    PAYMENT_TERMS      AS PAYMENT_TERMS_RAW,
    PO_NUMBER,
    LINE_DESCRIPTION,
    GL_ACCOUNT,
    COST_CENTER,
    APPROVAL_STATUS    AS APPROVAL_STATUS_RAW,
    CREATED_AT
  FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_SAP_AP_INVOICES

  UNION ALL

  -- Oracle
  SELECT
    'ORACLE',
    INV_ID,
    INV_NUM,
    SUPPLIER_ID,
    SUPPLIER_NAME,
    INV_DATE,
    PAYMENT_DUE_DATE,
    TOTAL_AMOUNT,
    CURRENCY,
    TERMS_CODE,
    PURCHASE_ORDER,
    DESCRIPTION,
    ACCOUNT_CODE,
    DEPT_CODE,
    STATUS,
    CREATION_DATE
  FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES

  UNION ALL

  -- Baan
  SELECT
    'BAAN',
    BAN_INVOICE_ID,
    BAN_INVOICE_REF,
    BAN_VENDOR_CODE,
    BAN_VENDOR_DESC,
    BAN_INV_DATE,
    BAN_PAY_DATE,
    BAN_AMOUNT,
    BAN_CURR,
    BAN_PAY_TERMS,
    BAN_PO_REF,
    BAN_LINE_DESC,
    BAN_GL_CODE,
    BAN_COST_CTR,
    BAN_STATUS,
    BAN_CREATED
  FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES

  UNION ALL

  -- Workday
  SELECT
    'WORKDAY',
    WD_INVOICE_ID,
    WD_INVOICE_NUM,
    WD_SUPPLIER_ID,
    WD_SUPPLIER_NAME,
    WD_INVOICE_DATE,
    WD_DUE_DATE,
    WD_AMOUNT,
    WD_CURRENCY,
    WD_PAY_TERMS,
    WD_PO_NUMBER,
    WD_MEMO,
    WD_LEDGER_ACCOUNT,
    WD_COST_CENTER,
    WD_APPROVAL_STATUS,
    WD_CREATED_DATE
  FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES
)
SELECT
  SOURCE_SYSTEM,
  SOURCE_INVOICE_ID,
  INVOICE_NUMBER,
  VENDOR_ID,
  VENDOR_NAME,
  INVOICE_DATE,
  DUE_DATE,
  INVOICE_AMOUNT,
  CURRENCY_CODE,
  -- Payment terms: normalize all sources (OQ-1 default — extend existing behavior)
  CASE UPPER(TRIM(PAYMENT_TERMS_RAW))
    WHEN 'NET30'  THEN 'NET30'
    WHEN 'NET60'  THEN 'NET60'
    WHEN 'N30'    THEN 'NET30'
    WHEN 'N60'    THEN 'NET60'
    WHEN 'NET 30' THEN 'NET30'
    WHEN 'NET 60' THEN 'NET60'
    ELSE UPPER(TRIM(PAYMENT_TERMS_RAW))
  END                AS PAYMENT_TERMS,
  PAYMENT_TERMS_RAW,
  PO_NUMBER,
  LINE_DESCRIPTION,
  GL_ACCOUNT,
  COST_CENTER,
  -- Status normalization (BR-001: all variants → APPROVED or PENDING)
  CASE
    WHEN UPPER(TRIM(APPROVAL_STATUS_RAW)) IN ('APPROVED', 'VALIDATED', 'POSTED') THEN 'APPROVED'
    WHEN UPPER(TRIM(APPROVAL_STATUS_RAW)) IN ('PENDING', 'IN REVIEW')            THEN 'PENDING'
    ELSE UPPER(TRIM(APPROVAL_STATUS_RAW))
  END                AS APPROVAL_STATUS,
  APPROVAL_STATUS_RAW,
  CREATED_AT
FROM unioned
-- Dedup: scoped per source to avoid cross-system collisions (BR-003, OQ-2 default)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY SOURCE_SYSTEM, INVOICE_NUMBER
  ORDER BY CREATED_AT DESC
) = 1;

-- ============================================================================
-- VALIDATION QUERIES — run after CREATE OR REPLACE to verify correctness
-- ============================================================================

-- V1: Row count by source (expect SAP=15, ORACLE=15, BAAN=10, WORKDAY=10)
SELECT SOURCE_SYSTEM, COUNT(*) AS ROW_COUNT
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
GROUP BY SOURCE_SYSTEM
ORDER BY SOURCE_SYSTEM;

-- V2: Approval status (expect only APPROVED and PENDING)
SELECT APPROVAL_STATUS, COUNT(*) AS CNT
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
GROUP BY APPROVAL_STATUS
ORDER BY APPROVAL_STATUS;

-- V3: Oracle VALIDATED now maps to APPROVED
SELECT APPROVAL_STATUS, APPROVAL_STATUS_RAW, COUNT(*) AS CNT
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
WHERE SOURCE_SYSTEM = 'ORACLE'
GROUP BY 1, 2 ORDER BY 1, 2;

-- V4: Payment terms normalization (all variants → NET30 or NET60)
SELECT PAYMENT_TERMS, PAYMENT_TERMS_RAW, COUNT(*) AS CNT
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
GROUP BY 1, 2 ORDER BY 1, 2;

-- V5: Confirm no Baan duplicates on INVOICE_NUMBER (expect 0 rows)
SELECT SOURCE_SYSTEM, INVOICE_NUMBER, COUNT(*) AS DUPES
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
WHERE SOURCE_SYSTEM = 'BAAN'
GROUP BY 1, 2 HAVING COUNT(*) > 1;

-- V6: Confirm dropped columns are gone (expect 18 columns, no SOURCE_ORG_CODE)
DESC DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES;

-- V7: Confirm DT is INCREMENTAL and ACTIVE
SHOW DYNAMIC TABLES LIKE 'SILVER_AP_INVOICES' IN SCHEMA COCO_WORKSHOP.PIPELINE_LAB;