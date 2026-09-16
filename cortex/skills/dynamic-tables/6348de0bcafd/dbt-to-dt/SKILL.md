---
name: dbt-to-dt
description: "Convert dbt table models to Snowflake Dynamic Tables while keeping dbt as the orchestrator. Use when: convert dbt to DT, migrate dbt models to dynamic tables, add DT support to dbt project, dbt materialized dynamic_table, replace dbt table with dynamic table, make dbt pipeline incremental with DT, dbt dynamic table conversion, convert dbt pipeline to DT, dbt to dynamic table."
parent_skill: dynamic-tables
---

# Convert dbt Models to Dynamic Tables

Convert dbt `materialized='table'` models to Dynamic Tables while keeping dbt as the orchestrator via `scheduler='disable'`.

## When to Use

- User has a dbt project targeting Snowflake and wants DT benefits (incremental refresh, NO_DATA detection, reduced rebuild cost)
- User wants to reduce dbt run times without leaving dbt as orchestrator
- User asks about `materialized='dynamic_table'` in dbt-snowflake

## Key Concept: dbt-Orchestrated Dynamic Tables

When `SCHEDULER = DISABLE` is set on a Dynamic Table (Snowflake behavior):
- The DT is **not** automatically refreshed — it can only be refreshed with `ALTER DYNAMIC TABLE ... REFRESH`
- Manual refreshes do **not** cascade to upstream or downstream dynamic tables
- If `SCHEDULER` is not set (or set to `ENABLE`), the DT is managed by Snowflake's scheduler using `TARGET_LAG` as usual

How this pattern works with dbt (adapter behavior):
- The dbt-snowflake adapter issues `ALTER DYNAMIC TABLE ... REFRESH` for each DT model during `dbt run`
- Because manual refreshes don't cascade, dbt controls exactly which DTs are refreshed on each run
- Each DT uses either `refresh_mode='incremental'` (for simple query shapes) or `refresh_mode='full'` (for complex ones). Never `refresh_mode='auto'`.

```sql
{{ config(materialized='dynamic_table', snowflake_warehouse='<warehouse>', scheduler='disable', refresh_mode='incremental') }}
```

Reference: https://docs.snowflake.com/en/release-notes/2026/other/2026-03-26-dynamic-table-scheduler-attribute

**Alternative (Snowflake-orchestrated):** Omit `scheduler` or set `scheduler='enable'` and configure `target_lag` if you want Snowflake's scheduler to fully orchestrate refreshes instead of dbt.

## Prerequisites

**dbt-snowflake adapter:** Using `scheduler='disable'` via dbt config requires `dbt-snowflake >= 1.11.5`. See the [dbt-snowflake changelog](https://github.com/dbt-labs/dbt-adapters/blob/stable/dbt-snowflake/CHANGELOG.md) for details.

## Workflow Overview

```
Step 1: Understand the project (read dbt_project.yml, count models, identify DAG)
Step 2: Triage (surface trade-offs to user, get confirmation to proceed)
Step 3: Pattern Classification — per-model, local (load references, classify → SKIP / INCREMENTAL / FULL with reason)
Step 4: Pipeline Shape Resolution — DAG-aware, global (cascade rule, primary key-based change tracking, keep-as-table option)
Step 5: Audit Config Compatibility (hooks, params, unknown keys)
Step 6: Verify Change Tracking (source tables must have it ON — cross-team ownership may block)
   ── MANDATORY CHECKPOINT: present plan, get user approval ──
Step 7: Convert (config block only — SQL body unchanged)
Step 8: Deploy and Validate (ask user for their test/deploy workflow, verify results)
```

## Workflow

### Step 1: Understand the dbt Project

**Actions:**
1. Read `dbt_project.yml` — identify materializations, model paths, schema mappings
2. Count models by materialization type (table, incremental, view, ephemeral)
3. Identify which `materialized='table'` models are candidates for DT conversion (incremental, view, ephemeral already have their own strategies — see Step 2)
4. Identify DAG structure (flat vs deep, model-to-model dependencies via `ref()`)

### Step 2: Triage — Inform the User About Trade-offs

Before converting, surface any considerations the user should be aware of:

| Signal | What to tell the user |
|--------|----------------------|
| Models use known DDL blockers (UUID_STRING, RANDOM, WITH RECURSIVE, UNPIVOT, SAMPLE) | "These models use constructs that prevent DT creation. They'll stay as `materialized='table'`." |
| Models are `materialized='incremental'` | "Already has its own refresh strategy (merge/upsert). No conversion needed." |
| Models are `materialized='view'` | "No materialization cost — already lightweight. Only relevant if it creates a DT→View→DT conflict (see Step 7)." |
| Models are already `materialized='dynamic_table'` | "Already a dynamic table. No action needed." |

Present these findings to the user and wait for confirmation before continuing to Step 3.

### Step 3: Pattern Classification (per-model)

**Load:** [../references/incremental-operators.md](../references/incremental-operators.md) and [../references/supported-queries.md](../references/supported-queries.md)

For each `materialized='table'` model, inspect its SQL and classify independently (any order). Consult the loaded references to determine which operators support incremental refresh and which do not.

**SKIP (do not convert):**
- Query uses constructs listed as "Not Supported" in `supported-queries.md` that fail DT creation entirely (non-deterministic functions, etc.)

**INCREMENTAL (eligible for `refresh_mode='incremental'`):**
- Query uses ONLY operators marked ✅ Yes in `incremental-operators.md`

**FULL (reason: ...):**
- Query uses operators listed under "Operators That REQUIRE Full Refresh" (reason: the specific operator)
- Reference marks an operator as ⚠️ Partial or ❌ No for incremental support (reason: operator not fully supported)
- Query uses operators not clearly covered in the reference (reason: unsure about pattern)
- If unsure whether a pattern supports incremental (reason: defaulting to FULL for safety)

Always record the reason — it goes into the assessment output so the user understands WHY a model is FULL.

Never use `refresh_mode='auto'`. Always set an explicit mode.

**Additionally, note primary keys for pipeline shape decisions:**

For models classified as FULL, check whether the model has a primary key (used in Step 4 for primary key-based change tracking):

**Derived primary key (from query shape):**
- `GROUP BY col1, col2` (basic columns only) → the GROUP BY columns form a derived PK
- `QUALIFY ROW_NUMBER() OVER (PARTITION BY pk_col ...) = 1` → the partition column is a derived PK

**Declared primary key (from base table):**
- Passthrough from a base table with `PRIMARY KEY ... RELY` → PK propagates (check via `DESCRIBE TABLE <source>` or `SHOW PRIMARY KEYS IN TABLE <source>`)

**NOT a valid primary key:** `GROUP BY ROLLUP(...)`, `GROUP BY CUBE(...)`, `GROUP BY GROUPING SETS(...)` — these inject subtotal rows with NULL grouping columns, breaking uniqueness.

Record this as metadata (e.g., `has_pk: true, pk_type: 'derived', pk_columns: [col1, col2]`). This is used in Step 4 for pipeline shape decisions.

### Step 4: Pipeline Shape Resolution (DAG-aware)

After classifying all models, resolve the final refresh mode by walking the DAG. Use `dbt list --output json --resource-type model` or `target/manifest.json` (after `dbt compile`) to get the dependency graph — do not manually trace `ref()` calls across files.

**Walk the DAG topologically (roots first):**

1. For each INCREMENTAL model, check its upstream `ref()` targets
2. If all upstream DTs have been resolved as INCREMENTAL in this pass (or are regular tables with `change_tracking = ON`) → confirm as `refresh_mode='incremental'`
3. If any upstream DT has been resolved as FULL:
   - Check if **every** FULL upstream DT has a primary key (derived or declared, from Step 3 metadata)
   - If ALL FULL upstreams have PKs: downstream may still support INCREMENTAL via primary key-based change tracking. Attempt `refresh_mode='incremental'` — if creation fails, fall back to FULL.
   - If ANY FULL upstream lacks a PK: this model must be downgraded to `refresh_mode='full'`

**Pipeline shape considerations:**

A `materialized='table'` with `change_tracking = ON` is a valid INCREMENTAL-compatible upstream. If a FULL model has many downstream INCREMENTAL models, consider these options:

1. **Keep as table (safest):** Don't convert the FULL model to DT — keeps downstream INCREMENTAL-eligible
2. **Convert with primary key-based change tracking (if available):** If the FULL model has a derived or declared primary key, downstream INCREMENTAL may still work
3. **Accept cascade:** Convert to FULL DT and accept that downstream models also become FULL

When presenting options, use diagrams that show ALL affected models per option:
```
⚠️ Pipeline shape decision needed for fct_revenue_summary:

   Option 1 (keep as table):
     source ──→ stg_orders [DT, INC] ──→ fct_revenue_summary [TABLE] ──→ fct_downstream_a [DT, INC]
                                                                       ──→ fct_downstream_b [DT, INC]

   Option 2 (convert with PK-based change tracking):
     source ──→ stg_orders [DT, INC] ──→ fct_revenue_summary [DT, FULL, has PK] ──→ fct_downstream_a [DT, INC ⚠️ verify]
                                                                                  ──→ fct_downstream_b [DT, INC ⚠️ verify]

   Option 3 (accept cascade):
     source ──→ stg_orders [DT, INC] ──→ fct_revenue_summary [DT, FULL] ──→ fct_downstream_a [DT, FULL]
                                                                          ──→ fct_downstream_b [DT, FULL]

Recommended: Option 1 if you prefer no DDL retries. Option 2 if downstream
count is high and you want to leverage primary key-based change tracking.
```

**Output of this step:** Final per-model decision — one of:
- DT with `refresh_mode='incremental'`
- DT with `refresh_mode='full'`
- Keep as `materialized='table'` (DDL blocker, pipeline shape decision, or change tracking constraint)

### Step 5: Audit dbt Config Compatibility

For each model being converted, audit the full `{{ config(...) }}` block. Every parameter beyond `materialized` was written assuming the model is a table — classify each one:

**Carries over safely (no change needed):**
- `schema`, `database`, `tags`, `alias`

**New params to add:**
- `snowflake_warehouse` (required)
- `scheduler='disable'`
- `refresh_mode` — set to `'incremental'` or `'full'` per Step 4 resolution

**Not supported — flag to user:**
- `on_schema_change` — no DT equivalent exists. Inform user this behavior will not carry over.
- `unique_key`, `incremental_strategy` — these are incremental-specific params. If present on a table model, exclude it from conversion and let the user decide how to handle.

**Requires user review — `post_hook` / `pre_hook`:**
- Hooks can contain arbitrary SQL or macro calls that were written for tables
- Macros may internally execute operations not compatible with DTs (e.g., `ALTER TABLE`, grants, masking policies)
- For each hook, try to read the macro source and reason about whether it is compatible with Dynamic Tables. Present your findings with a recommendation, then let the user decide

**Unknown params:**
- Any config parameter not listed above — flag to the user for review rather than silently carrying it over

**STOP:** Present conversion summary to the user. Follow these presentation rules:

1. **Use full model names consistently** — never abbreviate or group models with shorthand like "a/b/c_fact". Always write out each model name in full.
2. **Include a confidence indicator** per model — ✅ High (pattern clearly supported), ⚠️ Verify (partial support, may downgrade after creation), ❓ Uncertain (defaulting to FULL for safety).
3. **Show ALL models in the DAG diagram** — every model mentioned in the assessment must appear in the diagram, including those staying as table or view.
4. **When presenting options** (e.g., topology conflict), show a separate diagram per option so the user can visually compare.

```
Convertible: X models (table → dynamic_table)
  - Incremental: N models
  - Full: M models (reason per model)
Already handled: A models (incremental — own refresh strategy, no conversion needed)
Blocked: Y models (DDL blocker — stays as table)
Note: If other models fail during creation, they'll be reverted to table.

Per-model classification:
| Model                          | Decision     | Confidence | Reason                    |
|--------------------------------|--------------|------------|---------------------------|
| stg_orders                     | INCREMENTAL  | ✅ High    | Simple passthrough        |
| account_day_fact               | INCREMENTAL  | ⚠️ Verify  | FULL OUTER JOIN (equi) — may downgrade |
| blocked_accounts               | FULL         | ✅ High    | LISTAGG + scalar subquery |
| fct_tracking                   | SKIP         | ✅ High    | UUID_STRING (DDL blocker) |

DAG:
  source_a ──→ stg_orders [DT, INC ✅] ──→ int_view [view, keep] ──→ fct_revenue [table, keep: DT→View→DT]
  source_b ──→ stg_customers [DT, INC ✅] ──→ fct_rollup [table, keep: FULL would cascade]
                                                └──→ fct_downstream_a [DT, INC ✅]
  source_c ──→ stg_events [DT, INC ✅] ──→ fct_tracking [table, BLOCKED: UUID_STRING]
```

### Step 6: Verify Change Tracking on Source Tables

Before converting, verify that the source tables referenced in `sources.yml` have change tracking enabled:
```sql
SHOW TABLES LIKE '<source_table>' IN SCHEMA <database>.<schema>;
-- Check the "change_tracking" column — must be "ON" for each source table
```

Only check tables listed in the dbt project's `sources.yml` — these are the base tables that DTs will read from.

If any source table has `change_tracking = OFF`:
- If the user owns the table → suggest enabling it: `ALTER TABLE <source_table> SET CHANGE_TRACKING = TRUE;`
- If the table is owned by another team → the model reading from it should stay as `materialized='table'` (DT creation will fail without MODIFY privileges on the source)

**To persist change tracking across rebuilds, suggest one of:**

1. **`post_hook` on dbt-managed table models** (upstream tables that are also dbt models):
```sql
{{ config(materialized='table', post_hook="ALTER TABLE {{ this }} SET CHANGE_TRACKING = TRUE") }}
```

2. **`on-run-start` for external source tables** (not managed by dbt):
```yaml
# In dbt_project.yml
on-run-start:
  - "ALTER TABLE {{ source('raw', 'orders') }} SET CHANGE_TRACKING = TRUE"
```

**STOP — MANDATORY CHECKPOINT:** Present the conversion plan and ask: "Do you approve these changes? (Yes/No/Modify)" Wait for explicit approval. Do NOT write any files without user confirmation.

### Step 7: Convert Eligible Models

**Only convert `materialized='table'` models.** Do NOT convert `materialized='incremental'` models — incremental-to-DT conversion has different semantics and is not supported by this skill.

**For `materialized='table'` models (config change only):**
```sql
-- Before
{{ config(materialized='table') }}
SELECT ... FROM {{ ref('upstream') }}

-- After (incremental-safe pattern)
{{ config(materialized='dynamic_table', snowflake_warehouse='<WH>', scheduler='disable', refresh_mode='incremental') }}
SELECT ... FROM {{ ref('upstream') }}

-- After (complex pattern or unsure)
{{ config(materialized='dynamic_table', snowflake_warehouse='<WH>', scheduler='disable', refresh_mode='full') }}
SELECT ... FROM {{ ref('upstream') }}
```

SQL body is **unchanged**. Only the config block changes. Every converted model MUST include an explicit `refresh_mode` — either `'incremental'` or `'full'`. Never use `'auto'`.

**Leave unchanged:**
- `materialized='incremental'` → already has its own refresh strategy, no conversion needed
- `materialized='ephemeral'` → stays as ephemeral (inlined CTE)
- Models with known DDL blockers (see supported-queries.md) → skip upfront
- Models whose source tables lack change tracking and require cross-team grants → keep as table
- Any model that fails DT creation during `dbt run` → revert to `materialized='table'` and inform the user which model failed and why

**Views — DT→View→DT is not supported:**
- If a `materialized='view'` model sits between two models being converted to DTs, the downstream DT creation will fail.
- **Detection:** Check if any view has both an upstream AND downstream model being converted to DT.
- **Resolution:** Do not convert both sides. `DT → View → table` and `table → View → DT` both work. Present the conflict to the user and let them decide which side to convert.

### Step 8: Deploy and Validate

**Ask the user** how they typically test and deploy model changes. Common dbt patterns:

- **`dbt run --full-refresh`** — creates DTs and populates initial state. Required for first run after materialization change.
- **`dbt test`** — run existing data tests (unique, not_null, relationships) to verify DTs produce correct results
- **`--defer --state`** — Slim CI: run only modified models against production upstream (useful for large projects)
- **Separate dev/prod targets** — test in dev schema before promoting to production

After DTs are created, verify refresh modes match what was set:
```sql
SHOW DYNAMIC TABLES IN SCHEMA <database>.<schema>;
-- Check: refresh_mode, refresh_mode_reason for each DT
```

If any DT's `refresh_mode` doesn't match what was configured (e.g., you set INCREMENTAL but it shows FULL), check `refresh_mode_reason` and surface the finding to the user. This can happen when Snowflake determines the query cannot be incrementally maintained.

**If relying on primary key-based change tracking for cascade resolution**, verify keys exist:
```sql
SHOW UNIQUE KEYS IN <upstream_dt>;
```
If the expected unique key is not present, downstream INCREMENTAL will fail at refresh time — fall back to FULL. Common cause: masking policies on PK columns prevent Snowflake from using those keys for change tracking.

**STOP:** Ask the user if they want to proceed with in-place changes or if they have a staging/CI workflow to validate first.

## Important Constraints

1. **`SELECT *` breaks on schema change** — always use explicit column lists in DT models
2. **`on_schema_change` has no DT equivalent** — if source columns change, DT refresh fails
3. **Source table rebuilds may reset change tracking** — if you rebuild a source table with `CREATE OR REPLACE TABLE`, the new object may not have `CHANGE_TRACKING` enabled by default. Re-enable change tracking after source rebuilds:
   ```sql
   ALTER TABLE <source_table> SET CHANGE_TRACKING = TRUE;
   ```
4. **`--full-refresh` on DT project recreates DTs** — `CREATE OR REPLACE DYNAMIC TABLE` drops and recreates the DT, triggering full reinitialization. Use only for initial setup or when changing the DT query definition.

## Stopping Points

- After triage (Step 2): before scanning SQL patterns
- After pipeline resolution (Step 4) + config audit (Step 5): before modifying any files
- After change tracking verification (Step 6): MANDATORY CHECKPOINT before writing changes

## Output

- Converted dbt project with eligible `materialized='table'` models using `materialized='dynamic_table'`
- Summary of what was converted, what was skipped (and why)
- Actual refresh modes confirmed via `SHOW DYNAMIC TABLES` after creation
