# Artifact Index: SILVER_AP_INVOICES PRD Update

**Date:** 2026-09-16
**Author:** SUMA (via Cortex Code)
**Target:** `COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES`

---

## PRD Inputs

These are the requirements documents that drove the change. Read all three to understand the full scope.

| File | What it contains |
|------|------------------|
| `assets/sample_business_requirements_source_onboarding.csv` | 2 source onboarding requests (Baan IV, Workday) with contacts, timelines, blockers |
| `assets/sample_business_requirements_column_mapping.csv` | 32-row column mapping: Baan (16) and Workday (16) source columns → Silver target columns with types, transforms, and status |
| `assets/sample_business_requirements_business_rules.csv` | 10 business rules (BR-001 through BR-010): status normalization, dedup, currency handling, GL cross-ref, payment terms, retention |

---

## Planning Artifacts

| File | What it contains |
|------|------------------|
| `plans/SILVER_AP_INVOICES_plan_20260916.md` | Full implementation plan: gap analysis, ordered changes, DDL sketch, 5 open questions with defaults, out-of-scope items, and 7 validation queries |

---

## Implementation Artifacts

| File | What it contains |
|------|------------------|
| `sql/03_silver_ap_invoices_prd_update.sql` | The executed `CREATE OR REPLACE DYNAMIC TABLE` DDL with all 4 sources, BR-001 status mapping, BR-003 dedup, BR-008 column drops |
| `sql/02_silver_ap_invoices_proof.sql` | Proof query (row counts by `SOURCE_SYSTEM`) — quick rerun after any change |

---

## Setup / Bootstrap

| File | What it contains |
|------|------------------|
| `assets/00_snowday_setup.sql` | Creates database, schemas, warehouse, role, tags. Run once. |
| `assets/00_sample_data.sql` | Loads all 4 bronze tables + eval question set into `SOURCE_DATA`. Run once after setup. |

---

## Skills (reusable)

| Skill | Location | Purpose |
|-------|----------|---------|
| `prd-to-pipeline` | `.cortex/skills/prd-to-pipeline/SKILL.md` | **The PRD Evaluator.** Reads an XLSX (or CSV) PRD + a target DT, produces a gap analysis, implementation plan, open questions, and validation queries. Invoke with `/prd-to-pipeline`. |
| `dynamic-tables` | `.snowflake/cortex/skills/dynamic-tables/SKILL.md` | Dynamic table operations: create, monitor, troubleshoot, optimize, alerting, permissions, task-to-DT, custom incrementalization, dbt-to-DT, pipeline diagnostics. Invoke with `/dynamic-tables`. |

---

## How to reuse this workflow

1. **Place your PRD** (XLSX or CSV) in `assets/`.
2. **Invoke the skill:**
   ```
   /prd-to-pipeline @assets/your_requirements.xlsx
   target: DB.SCHEMA.YOUR_DYNAMIC_TABLE
   ```
3. **Review** the plan it generates (written to `plans/`).
4. **Resolve open questions**, then ask CoCo to implement.
5. **Run validation queries** from the plan to confirm.

---

## Open questions still unresolved

These were flagged during planning and implemented with default recommendations. They should be reviewed before production release.

| ID | Question | Default used | Decision owner |
|----|----------|--------------|----------------|
| OQ-1 | Normalize payment terms at Silver or Gold? (BR-005) | Normalize at Silver | Sarah Chen / David Kim |
| OQ-2 | Baan dedup: global or scoped to SOURCE_SYSTEM? (BR-003) | Scoped to SOURCE_SYSTEM | Engineering |
| OQ-3 | Column name: `SOURCE_INVOICE_ID` vs `INVOICE_ID` | Keep `SOURCE_INVOICE_ID` | Data modeling team |
| OQ-4 | Keep `*_RAW` audit columns? | Keep both | Data modeling team |
| OQ-5 | Confirm no downstream consumers of `SOURCE_ORG_CODE` | Assumed none exist | Engineering |
