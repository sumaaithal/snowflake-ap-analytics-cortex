# AP Analytics Dynamic Table & Cortex Assistant

An end-to-end Snowflake data engineering and AI analytics workflow for **Accounts Payable (AP) invoice analytics**.

This project demonstrates how to take business requirements and source-system mappings, extend a conformed Silver-layer dynamic table across multiple ERP systems, validate the resulting data model, and expose the curated dataset through a **Cortex Analyst-powered AP analytics assistant**.

## Overview

The pipeline consolidates AP invoice data from four ERP source systems:

- **SAP**
- **Oracle**
- **Baan IV**
- **Workday**

The conformed Silver layer provides invoice-level analytics for vendor spend, invoice volume, approval backlogs, payment terms, overdue exposure, cost-center analysis, and source-system comparisons.

The project also includes:

- A Snowflake semantic view for the conformed AP dataset
- A Cortex Analyst agent for natural-language analytics
- PRD-to-pipeline planning artifacts
- Dynamic table implementation SQL
- Proof/validation SQL
- Reusable Cortex skills and workflow documentation
- A project configuration/bootstrap definition

## Architecture

```text
Business Requirements / PRD
          │
          ▼
   PRD-to-Pipeline Review
          │
          ├── Gap Analysis
          ├── Column Mapping
          ├── Business Rules
          ├── Open Questions
          └── Validation Plan
          │
          ▼
     Bronze Source Tables
 ┌────────┬────────┬────────┬─────────┐
 │  SAP   │ Oracle │  Baan  │ Workday │
 └────────┴────────┴────────┴─────────┘
          │
          │ UNION ALL + normalization
          ▼
┌─────────────────────────────────────────────┐
│ SILVER_AP_INVOICES                          │
│                                             │
│ • Conformed invoice grain                   │
│ • Status normalization                      │
│ • Payment-term normalization                │
│ • Source-scoped deduplication               │
│ • Raw values retained for auditability      │
└─────────────────────────────────────────────┘
          │
          ▼
    SV_AP_ANALYTICS
          │
          ▼
   Cortex Analyst Agent
          │
          ▼
 Natural-language AP analytics
```

## Data Model

The Silver table is maintained at **one row per unique invoice per source system**.

Key dimensions include:

- `SOURCE_SYSTEM`
- `SOURCE_INVOICE_ID`
- `INVOICE_NUMBER`
- `VENDOR_ID`
- `VENDOR_NAME`
- `CURRENCY_CODE`
- `PAYMENT_TERMS`
- `PAYMENT_TERMS_RAW`
- `PO_NUMBER`
- `LINE_DESCRIPTION`
- `GL_ACCOUNT`
- `COST_CENTER`
- `APPROVAL_STATUS`
- `APPROVAL_STATUS_RAW`

Time dimensions:

- `INVOICE_DATE`
- `DUE_DATE`
- `CREATED_AT`

Primary fact:

- `INVOICE_AMOUNT`

`SOURCE_SYSTEM + INVOICE_NUMBER` is the unique key defined for the semantic model.

## Source Integration

### SAP

Existing SAP invoice records are conformed into the Silver schema.

### Oracle

Oracle invoice records are conformed into the same model, including the business-rule change that maps the source status `VALIDATED` to the normalized Silver status `APPROVED`.

### Baan IV

Baan IV is added as a new source. Its source-specific fields are mapped into the common Silver schema, with `POSTED` mapped to `APPROVED`.

Baan duplicate invoice references are deduplicated within the Baan source using the latest `CREATED_AT`.

### Workday

Workday is added as a new source. `Approved` maps to `APPROVED`, while `In Review` maps to `PENDING`.

## Transformation Rules

### Approval Status

The conformed dataset exposes only the normalized statuses:

```text
APPROVED
PENDING
```

Source-specific values are retained in `APPROVAL_STATUS_RAW` for auditability.

| Source | Raw status | Silver status |
|---|---|---|
| SAP | `APPROVED` | `APPROVED` |
| SAP | `PENDING` | `PENDING` |
| Oracle | `VALIDATED` | `APPROVED` |
| Oracle | `APPROVED` | `APPROVED` |
| Oracle | `PENDING` | `PENDING` |
| Baan | `POSTED` | `APPROVED` |
| Baan | `APPROVED` | `APPROVED` |
| Baan | `PENDING` | `PENDING` |
| Workday | `Approved` | `APPROVED` |
| Workday | `In Review` | `PENDING` |

### Payment Terms

The implementation normalizes common source representations such as:

```text
N30      → NET30
N60      → NET60
NET 30   → NET30
NET 60   → NET60
```

The original source value remains available through `PAYMENT_TERMS_RAW`.

### Currency Guardrail

Invoice amounts remain in their **original transaction currency** (`USD`, `EUR`, or `GBP`).

The semantic model explicitly prevents consumers from treating amounts in different currencies as directly additive. Spend must therefore be grouped or filtered by `CURRENCY_CODE`.

FX conversion is intentionally outside the current scope and is deferred to a downstream Gold/Treasury layer.

## Dynamic Table

The target object is:

```text
COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
```

The implementation uses:

- `TARGET_LAG = '1 hour'`
- `WAREHOUSE = COCO_WORKSHOP_WH`
- `REFRESH_MODE = AUTO`
- `INITIALIZE = ON_CREATE`

The planned post-change dataset contains approximately:

```text
SAP       15 rows
ORACLE    15 rows
BAAN      10 rows
WORKDAY   10 rows
------------------
TOTAL     50 rows
```

The validation SQL should be used to confirm the actual row counts after implementation.

## Semantic Layer

`SV_AP_ANALYTICS` exposes the conformed Silver table for AP analytics.

It is designed for:

- AP managers
- Finance controllers
- Procurement leads

Supported analysis includes:

- Vendor spend
- Invoice volumes
- Approval backlogs
- Payment-term mix
- Overdue exposure
- Cost-center breakdowns
- Source-system comparisons

The semantic view also contains verified query examples for common AP questions, including vendor spend, monthly invoice counts, overdue amounts, pending approvals, and spend by source system and currency.

## Cortex Analyst Assistant

The project includes an AP analytics assistant named:

```text
AP_ANALYTICS_ASSISTANT
```

The assistant uses a Cortex Analyst text-to-SQL tool backed by:

```text
COCO_WORKSHOP.PIPELINE_LAB.SV_AP_ANALYTICS
```

Its response contract requires three sections:

1. **Answer** — the direct result, using tables where appropriate
2. **SQL** — the exact SQL used to produce the result
3. **Assumptions** — relevant grain, time, currency, or status assumptions

The assistant also includes guardrails for:

- Cross-currency aggregation
- Ambiguous time periods or metrics
- Normalized approval-status terminology
- Source-system cost-center differences

## PRD-to-Pipeline Workflow

This repository captures a repeatable workflow for translating business requirements into an executable data-pipeline change.

```text
1. Place PRD / requirements in assets/
2. Run PRD-to-pipeline analysis
3. Review gap analysis and implementation plan
4. Resolve open questions
5. Implement the Dynamic Table changes
6. Run proof and validation queries
7. Review semantic model
8. Expose the dataset through Cortex Analyst
```

The workflow is intended to be reusable for future source onboarding and pipeline changes.

## Repository Structure

```text
.
├── assets/
│   ├── 00_snowday_setup.sql
│   ├── 00_sample_data.sql
│   └── sample_business_requirements_*.csv
│
├── plans/
│   └── SILVER_AP_INVOICES_plan_20260916.md
│
├── sql/
│   ├── 02_silver_ap_invoices_proof.sql
│   └── 03_silver_ap_invoices_prd_update.sql
│
├── .cortex/
│   └── skills/
│       └── prd-to-pipeline/
│
├── .snowflake/
│   └── cortex/
│       └── skills/
│           └── dynamic-tables/
│
├── SV_AP_ANALYTICS.sv.yaml
├── AP_ANALYTICS_ASSISTANT.agent.yaml
├── cortex-project.yaml
├── 02_prd_change_plan.md
└── 03_prd_workflow_handoff.md
```

> The exact folder contents depend on the project ZIP and the artifacts included in the working repository.

## Setup

### Prerequisites

You need a Snowflake environment with the objects and capabilities required by the project, including:

- A Snowflake database and schemas
- A warehouse
- Bronze AP source tables
- Dynamic Tables
- Cortex Analyst capabilities available in your account
- Appropriate permissions for creating and replacing the target objects

### 1. Bootstrap the environment

Run the project setup script:

```sql
@assets/00_snowday_setup.sql
```

This initializes the database, schemas, warehouse, role, and tags required by the workshop/project environment.

### 2. Load sample data

Load the four AP source datasets and evaluation data:

```sql
@assets/00_sample_data.sql
```

### 3. Apply the Dynamic Table implementation

Execute:

```sql
@sql/03_silver_ap_invoices_prd_update.sql
```

The implementation:

- Adds Baan and Workday
- Normalizes approval statuses
- Normalizes payment terms
- Retains raw source values
- Applies source-scoped invoice deduplication
- Removes system-specific fields that are out of the target model

### 4. Run the proof query

Execute:

```sql
@sql/02_silver_ap_invoices_proof.sql
```

Use this as a quick post-change sanity check.

### 5. Run validation queries

The implementation plan contains seven validation queries covering:

- Row counts by source
- Approval-status distribution
- Oracle status mapping
- Payment-term normalization
- Removed system-specific columns
- Baan duplicate detection
- Dynamic Table refresh configuration

## Example Analytics Questions

Once the semantic view and Cortex Analyst assistant are configured, the model is designed to answer questions such as:

```text
What is the total AP spend by vendor?

What is the invoice count by month and business unit?

Which vendors have the highest overdue invoice amounts?

How many invoices are pending approval by source system?

What is the spend breakdown by source system and currency?
```

Because invoice amounts are stored in original transaction currency, cross-currency totals should not be interpreted as a single monetary total without an FX conversion layer.

## Open Questions

The implementation plan identifies five open questions that were implemented using default recommendations and should be reviewed before production release:

| ID | Question | Default used |
|---|---|---|
| OQ-1 | Normalize payment terms at Silver or Gold? | Normalize at Silver |
| OQ-2 | Baan dedup globally or by source system? | Scope to `SOURCE_SYSTEM` |
| OQ-3 | `SOURCE_INVOICE_ID` vs `INVOICE_ID`? | Keep `SOURCE_INVOICE_ID` |
| OQ-4 | Keep raw audit columns? | Keep both `*_RAW` columns |
| OQ-5 | Are there downstream consumers of removed source-specific columns? | Assumed none |

These are implementation decisions rather than immutable business requirements and should be reviewed by the relevant owners before productionization.

## Out of Scope

The current implementation deliberately does not include:

- FX/currency conversion
- GL-account cross-referencing
- High-value invoice flagging above `$500K`
- Data retention/time-series management
- `TARGET_LAG = DOWNSTREAM` before a Gold Dynamic Table exists

These are identified as downstream or future-phase concerns in the implementation plan.

## Key Engineering Concepts Demonstrated

This project showcases several practical data-engineering patterns:

- Multi-source data consolidation
- Conformed Silver-layer modeling
- Dynamic Tables
- Incremental refresh design
- Source-specific normalization
- Window-function-based deduplication
- Audit-column preservation
- Semantic modeling
- Text-to-SQL analytics
- AI-assisted data exploration
- PRD-to-pipeline translation
- Data-quality validation
- Explicit data-governance decisions
- Currency-aware analytical guardrails

## Why This Project Matters

The project demonstrates the complete path from **business requirement → implementation plan → data pipeline → semantic layer → natural-language analytics** rather than treating SQL development as an isolated task.

It also preserves the reasoning behind pipeline changes through planning artifacts, open questions, business-rule mappings, and validation queries. That makes the implementation easier to review, reproduce, and extend.

## Author

**Suma Aithal**

Data Engineering / Analytics Engineering project focused on Snowflake data pipelines, semantic modeling, and AI-assisted analytics.
