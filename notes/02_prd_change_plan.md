# Implementation Plan: SILVER_AP_INVOICES

**Generated:** 2026-09-16
**PRD source:** `assets/sample_business_requirements_column_mapping.csv`
**Cross-referenced:** `assets/sample_business_requirements_business_rules.csv`, `assets/sample_business_requirements_source_onboarding.csv`
**Target:** `COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES`

---

## 1. Summary of Requested Changes

| Category | Count | Detail |
|----------|-------|--------|
| New sources to add | 2 | Baan IV (16 columns), Workday (16 columns) |
| Columns to drop | 2 | `SOURCE_ORG_CODE`, `SOURCE_DOC_TYPE` (per BR-008) |
| Columns to rename | 1 | `SOURCE_INVOICE_ID` → PRD calls it `INVOICE_ID` (naming mismatch) |
| Status mappings to add | 4 | Baan: POSTED→APPROVED, APPROVED→APPROVED, PENDING→PENDING. Workday: Approved→APPROVED, In Review→PENDING |
| Existing mapping to change | 1 | Oracle VALIDATED→APPROVED (per BR-001; currently preserved as VALIDATED) |
| Columns where PRD is silent | 2 | `PAYMENT_TERMS_RAW`, `APPROVAL_STATUS_RAW` (current DT has these; PRD doesn't mention them) |
| Open decisions | 2 | Payment terms normalization (BR-005), column rename (see OQ-3) |
| Out of scope (confirmed) | 3 | Currency conversion (BR-002), GL cross-reference (BR-006), high-value flagging (BR-004) |

**Current state:** 2 sources (SAP, Oracle), 30 rows, 20 columns, INCREMENTAL refresh, 1-hour lag.
**After implementation:** 4 sources, ~50 rows, 16–18 columns (depending on open decisions), INCREMENTAL refresh.

---

## 2. Source-to-Silver Column Mapping

### Baan IV → Silver

| Baan Column | Silver Column | Transform | Type Match | Status |
|-------------|---------------|-----------|------------|--------|
| `BAN_INVOICE_ID` | `SOURCE_INVOICE_ID` | Direct | VARCHAR(20) ✓ | Confirmed |
| `BAN_INVOICE_REF` | `INVOICE_NUMBER` | Direct | VARCHAR(30) ✓ | Confirmed |
| `BAN_VENDOR_CODE` | `VENDOR_ID` | Direct | VARCHAR(15) ✓ | Confirmed |
| `BAN_VENDOR_DESC` | `VENDOR_NAME` | Direct | VARCHAR(100) ✓ | Confirmed |
| `BAN_INV_DATE` | `INVOICE_DATE` | Direct | DATE ✓ | Confirmed |
| `BAN_PAY_DATE` | `DUE_DATE` | Direct | DATE ✓ | Confirmed |
| `BAN_AMOUNT` | `INVOICE_AMOUNT` | Direct | NUMBER(18,2) ✓ | Confirmed |
| `BAN_CURR` | `CURRENCY_CODE` | Direct | VARCHAR(3) ✓ | Confirmed |
| `BAN_PAY_TERMS` | `PAYMENT_TERMS` | See OQ-1 | VARCHAR(20) ✓ | **Open** |
| `BAN_PO_REF` | `PO_NUMBER` | Direct | VARCHAR(20) ✓ | Confirmed |
| `BAN_LINE_DESC` | `LINE_DESCRIPTION` | Direct | VARCHAR(200) ✓ | Confirmed |
| `BAN_GL_CODE` | `GL_ACCOUNT` | Direct | VARCHAR(20) ✓ | Confirmed |
| `BAN_COST_CTR` | `COST_CENTER` | Direct | VARCHAR(20) ✓ | Confirmed |
| `BAN_STATUS` | `APPROVAL_STATUS` | CASE map | VARCHAR(20) ✓ | Confirmed |
| `BAN_CREATED` | `CREATED_AT` | Direct | TIMESTAMP_NTZ ✓ | Confirmed |
| `BAN_COMPANY` | — | **DROP** | — | Confirmed |

### Workday → Silver

| Workday Column | Silver Column | Transform | Type Match | Status |
|----------------|---------------|-----------|------------|--------|
| `WD_INVOICE_ID` | `SOURCE_INVOICE_ID` | Direct | VARCHAR(20) ✓ | Confirmed |
| `WD_INVOICE_NUM` | `INVOICE_NUMBER` | Direct | VARCHAR(30) ✓ | Confirmed |
| `WD_SUPPLIER_ID` | `VENDOR_ID` | Direct | VARCHAR(15) ✓ | Confirmed |
| `WD_SUPPLIER_NAME` | `VENDOR_NAME` | Direct | VARCHAR(100) ✓ | Confirmed |
| `WD_INVOICE_DATE` | `INVOICE_DATE` | Direct | DATE ✓ | Confirmed |
| `WD_DUE_DATE` | `DUE_DATE` | Direct | DATE ✓ | Confirmed |
| `WD_AMOUNT` | `INVOICE_AMOUNT` | Direct | NUMBER(18,2) ✓ | Confirmed |
| `WD_CURRENCY` | `CURRENCY_CODE` | Direct | VARCHAR(3) ✓ | Confirmed |
| `WD_PAY_TERMS` | `PAYMENT_TERMS` | See OQ-1 | VARCHAR(20) ✓ | **Open** |
| `WD_PO_NUMBER` | `PO_NUMBER` | Direct | VARCHAR(20) ✓ | Confirmed |
| `WD_MEMO` | `LINE_DESCRIPTION` | Direct | VARCHAR(200) ✓ | Confirmed |
| `WD_LEDGER_ACCOUNT` | `GL_ACCOUNT` | Direct | VARCHAR(20) ✓ | Confirmed |
| `WD_COST_CENTER` | `COST_CENTER` | Direct | VARCHAR(20) ✓ | Confirmed |
| `WD_APPROVAL_STATUS` | `APPROVAL_STATUS` | CASE map | VARCHAR(20) ✓ | Confirmed |
| `WD_CREATED_DATE` | `CREATED_AT` | Direct | TIMESTAMP_NTZ ✓ | Confirmed |
| `WD_TENANT_ID` | — | **DROP** | — | Confirmed |

### Status Mapping (all 4 sources, post-implementation)

| Source | Raw Value | Silver Value | Rule |
|--------|-----------|--------------|------|
| SAP | `APPROVED` | `APPROVED` | Direct |
| SAP | `PENDING` | `PENDING` | Direct |
| Oracle | `VALIDATED` | `APPROVED` | BR-001 (**change from current**) |
| Oracle | `APPROVED` | `APPROVED` | Direct |
| Oracle | `PENDING` | `PENDING` | Direct |
| Baan | `POSTED` | `APPROVED` | BR-001, column mapping |
| Baan | `APPROVED` | `APPROVED` | Column mapping |
| Baan | `PENDING` | `PENDING` | Column mapping |
| Workday | `Approved` | `APPROVED` | BR-001, column mapping |
| Workday | `In Review` | `PENDING` | BR-001, column mapping |

---

## 3. Open Questions and Assumptions

### OQ-1: Payment terms — normalize at Silver or Gold? (BR-005, column mapping)

The current DT normalizes payment terms at Silver (`N30`→`NET30`, `Net 30`→`NET30`). The column mapping PRD marks Baan and Workday payment terms as "Open — needs decision." BR-005 from the business rules PRD says "NEEDS DECISION — current recommendation: leave as-is at Silver, normalize at Gold."

**Conflict with current implementation:** The SAP and Oracle branches already normalize. If the decision is "normalize at Gold," we need to *undo* existing SAP/Oracle normalization too, not just skip it for Baan/Workday.

**Default recommendation:** Normalize all four sources at Silver (keep current behavior, extend to Baan/Workday) because:
- SAP and Oracle already normalize; inconsistency would confuse consumers
- The `PAYMENT_TERMS_RAW` column preserves original values regardless

**If the decision is "normalize at Gold":** Remove the CASE expressions from all four branches and pass through raw values.

### OQ-2: Baan dedup scope (BR-003)

BR-003 says deduplicate Baan on `INVOICE_NUMBER` using `QUALIFY ROW_NUMBER() OVER (PARTITION BY INVOICE_NUMBER ORDER BY CREATED_AT DESC) = 1`. Applied globally after the `UNION ALL`, this could accidentally drop legitimate invoices from other systems if invoice numbers collide across sources.

**Default recommendation:** Scope dedup to Baan only by partitioning on `SOURCE_SYSTEM, INVOICE_NUMBER`:
```sql
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY SOURCE_SYSTEM, INVOICE_NUMBER
  ORDER BY CREATED_AT DESC
) = 1
```
This deduplicates within each source without cross-system collisions.

### OQ-3: Column naming — `SOURCE_INVOICE_ID` vs `INVOICE_ID`

The column mapping PRD uses `INVOICE_ID` as the Silver target column name. The current DT uses `SOURCE_INVOICE_ID` (chosen to distinguish from the source-system-specific ID column names). This is a naming convention difference.

**Default recommendation:** Keep `SOURCE_INVOICE_ID` to preserve backward compatibility for existing consumers. Flag for the data governance team to standardize naming conventions in the modeling guide.

### OQ-4: What happens to `PAYMENT_TERMS_RAW` and `APPROVAL_STATUS_RAW`?

The current DT carries `*_RAW` companion columns for auditability. The column mapping PRD does not include them. BR-008 says system-specific columns are dropped but is silent on these derived audit columns.

**Default recommendation:** Keep both `*_RAW` columns. They cost nothing (same VARCHAR type, no extra joins) and provide auditability that the PRD's own status-mapping rules implicitly depend on. Removing them would make it harder to verify BR-001 is working correctly.

### OQ-5: `SOURCE_ORG_CODE` / `SOURCE_DOC_TYPE` removal (BR-008)

BR-008 confirms these should be dropped. Column mapping confirms `BAN_COMPANY`→DROP, `WD_TENANT_ID`→DROP, and the existing SAP/Oracle equivalents are not in the target schema. This is confirmed but worth noting: any downstream report currently using `SOURCE_ORG_CODE` will break.

**Assumption:** No downstream consumers depend on these columns today (the DT was just created). Proceeding with removal.

---

## 4. DDL Delta Plan

### Pre-requisites

- [ ] Enable change tracking on `BRONZE_BAAN_AP_INVOICES`
- [ ] Enable change tracking on `BRONZE_WORKDAY_AP_INVOICES`
- [ ] Resolve OQ-1 (payment terms normalization layer)
- [ ] Confirm OQ-3 (column naming convention)

### Ordered Changes

**Change 1: Enable change tracking on new base tables**
- Rule(s): DT requirement (incremental refresh)
- Risk: **Low** — metadata-only ALTER, no data change

```sql
ALTER TABLE COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES SET CHANGE_TRACKING = TRUE;
ALTER TABLE COCO_WORKSHOP.SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES SET CHANGE_TRACKING = TRUE;
```

**Change 2: Recreate DT with 4 sources, updated schema**
- Rule(s): Column mapping, BR-001, BR-003, BR-007, BR-008
- Risk: **Medium** — `CREATE OR REPLACE` replaces the DT; downstream consumers see a brief reinitialize
- Key changes vs current DDL:
  - Add Baan UNION ALL branch with status mapping (POSTED→APPROVED)
  - Add Workday UNION ALL branch with status mapping (Approved→APPROVED, In Review→PENDING)
  - Update Oracle branch: VALIDATED→APPROVED (BR-001)
  - Drop `SOURCE_ORG_CODE`, `SOURCE_DOC_TYPE` columns (BR-008)
  - Add `QUALIFY` dedup scoped to SOURCE_SYSTEM + INVOICE_NUMBER (BR-003, using OQ-2 default)
  - Keep `PAYMENT_TERMS_RAW`, `APPROVAL_STATUS_RAW` (OQ-4 default)

```sql
CREATE OR REPLACE DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
  TARGET_LAG = '1 hour'
  WAREHOUSE = COCO_WORKSHOP_WH
  REFRESH_MODE = AUTO
  INITIALIZE = ON_CREATE
AS
WITH unioned AS (
  -- SAP
  SELECT 'SAP' AS SOURCE_SYSTEM,
    INVOICE_ID AS SOURCE_INVOICE_ID, INVOICE_NUMBER, VENDOR_ID, VENDOR_NAME,
    INVOICE_DATE, DUE_DATE, INVOICE_AMOUNT, CURRENCY_CODE,
    PAYMENT_TERMS AS PAYMENT_TERMS_RAW, PO_NUMBER, LINE_DESCRIPTION,
    GL_ACCOUNT, COST_CENTER, APPROVAL_STATUS AS APPROVAL_STATUS_RAW, CREATED_AT
  FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_SAP_AP_INVOICES

  UNION ALL
  -- Oracle
  SELECT 'ORACLE', INV_ID, INV_NUM, SUPPLIER_ID, SUPPLIER_NAME,
    INV_DATE, PAYMENT_DUE_DATE, TOTAL_AMOUNT, CURRENCY,
    TERMS_CODE, PURCHASE_ORDER, DESCRIPTION,
    ACCOUNT_CODE, DEPT_CODE, STATUS, CREATION_DATE
  FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES

  UNION ALL
  -- Baan
  SELECT 'BAAN', BAN_INVOICE_ID, BAN_INVOICE_REF, BAN_VENDOR_CODE, BAN_VENDOR_DESC,
    BAN_INV_DATE, BAN_PAY_DATE, BAN_AMOUNT, BAN_CURR,
    BAN_PAY_TERMS, BAN_PO_REF, BAN_LINE_DESC,
    BAN_GL_CODE, BAN_COST_CTR, BAN_STATUS, BAN_CREATED
  FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES

  UNION ALL
  -- Workday
  SELECT 'WORKDAY', WD_INVOICE_ID, WD_INVOICE_NUM, WD_SUPPLIER_ID, WD_SUPPLIER_NAME,
    WD_INVOICE_DATE, WD_DUE_DATE, WD_AMOUNT, WD_CURRENCY,
    WD_PAY_TERMS, WD_PO_NUMBER, WD_MEMO,
    WD_LEDGER_ACCOUNT, WD_COST_CENTER, WD_APPROVAL_STATUS, WD_CREATED_DATE
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
  -- Payment terms: normalize all sources (OQ-1 default)
  CASE UPPER(TRIM(PAYMENT_TERMS_RAW))
    WHEN 'NET30'  THEN 'NET30'
    WHEN 'NET60'  THEN 'NET60'
    WHEN 'N30'    THEN 'NET30'
    WHEN 'N60'    THEN 'NET60'
    WHEN 'NET 30' THEN 'NET30'
    WHEN 'NET 60' THEN 'NET60'
    ELSE UPPER(TRIM(PAYMENT_TERMS_RAW))
  END AS PAYMENT_TERMS,
  PAYMENT_TERMS_RAW,
  PO_NUMBER,
  LINE_DESCRIPTION,
  GL_ACCOUNT,
  COST_CENTER,
  -- Status normalization (BR-001)
  CASE
    WHEN UPPER(TRIM(APPROVAL_STATUS_RAW)) IN ('APPROVED','VALIDATED','POSTED') THEN 'APPROVED'
    WHEN UPPER(TRIM(APPROVAL_STATUS_RAW)) IN ('PENDING','IN REVIEW')           THEN 'PENDING'
    ELSE UPPER(TRIM(APPROVAL_STATUS_RAW))
  END AS APPROVAL_STATUS,
  APPROVAL_STATUS_RAW,
  CREATED_AT
FROM unioned
-- Dedup: Baan duplicate invoice refs (BR-003, scoped per OQ-2 default)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY SOURCE_SYSTEM, INVOICE_NUMBER
  ORDER BY CREATED_AT DESC
) = 1;
```

### Out of Scope (confirmed)

| Item | Deferred to | Rule |
|------|-------------|------|
| Currency conversion | Gold layer / Treasury FX table | BR-002 |
| GL account cross-reference | Gold layer / CoA mapping (Phase 2, Q4 2025) | BR-006 |
| High-value invoice flagging (>$500K) | DMF in Guardrails Pack | BR-004 |
| Data retention / time-series | Phase 2 backlog | BR-010 |
| TARGET_LAG = DOWNSTREAM | Deferred until Gold DT exists | BR-009 |

---

## 5. Validation Queries

Run these after implementation to verify correctness.

```sql
-- V1: Row count by source (expect: SAP=15, ORACLE=15, BAAN=10, WORKDAY=10 = 50 total)
SELECT SOURCE_SYSTEM, COUNT(*) AS ROW_COUNT
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
GROUP BY SOURCE_SYSTEM
ORDER BY SOURCE_SYSTEM;

-- V2: Approval status distribution (only APPROVED and PENDING should exist)
SELECT APPROVAL_STATUS, COUNT(*) AS CNT
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
GROUP BY APPROVAL_STATUS
ORDER BY APPROVAL_STATUS;

-- V3: Confirm Oracle VALIDATED is now mapped to APPROVED
SELECT APPROVAL_STATUS, APPROVAL_STATUS_RAW, COUNT(*) AS CNT
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
WHERE SOURCE_SYSTEM = 'ORACLE'
GROUP BY 1, 2 ORDER BY 1, 2;

-- V4: Payment terms normalization check
SELECT PAYMENT_TERMS, PAYMENT_TERMS_RAW, COUNT(*) AS CNT
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
GROUP BY 1, 2 ORDER BY 1, 2;

-- V5: Confirm system-specific columns are gone
-- (This should error with "invalid identifier" if columns are properly removed)
-- SELECT SOURCE_ORG_CODE FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES LIMIT 1;

-- V6: Confirm no Baan duplicates on INVOICE_NUMBER
SELECT SOURCE_SYSTEM, INVOICE_NUMBER, COUNT(*) AS DUPES
FROM COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
WHERE SOURCE_SYSTEM = 'BAAN'
GROUP BY 1, 2
HAVING COUNT(*) > 1;

-- V7: Confirm DT is still INCREMENTAL after rebuild
SHOW DYNAMIC TABLES LIKE 'SILVER_AP_INVOICES' IN SCHEMA COCO_WORKSHOP.PIPELINE_LAB;
-- Check: refresh_mode = INCREMENTAL, scheduling_state = ACTIVE
```
