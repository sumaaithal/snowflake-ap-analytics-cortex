# Incremental Refresh Operators Reference

Understanding which SQL operators support incremental refresh in Snowflake Dynamic Tables.

> **Note:** This guide uses INFORMATION_SCHEMA functions. See [monitoring-functions.md](monitoring-functions.md) for critical usage requirements (named parameters, database context).

---

## Why This Matters

When a dynamic table uses `REFRESH_MODE = INCREMENTAL` or `AUTO`, Snowflake attempts to process only changed data. However, not all SQL operators support this optimization. If your query contains unsupported operators, Snowflake will fall back to full refresh.

**To check current refresh mode:**
```sql
SELECT name, refresh_mode, refresh_mode_reason
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(name=>'<dt_name>'));
```

---

## Operators That SUPPORT Incremental Refresh

These operators can process changes incrementally:

### Joins

| Operator | Incremental Support | Notes |
|----------|-------------------|-------|
| `INNER JOIN` | ✅ Yes | Fully supported |
| `LEFT OUTER JOIN` | ✅ Yes | See restrictions below |
| `RIGHT OUTER JOIN` | ✅ Yes | See restrictions below |
| `FULL OUTER JOIN` | ✅ Yes | See restrictions below |
| `CROSS JOIN` | ✅ Yes | Supported |
| `NATURAL JOIN` | ✅ Yes | Supported |

**Outer Join Restrictions** - These patterns force FULL refresh:
- Non-equality predicates in the join condition (e.g., `ON a.id > b.id`)

### Set Operations

| Operator | Incremental Support | Notes |
|----------|-------------------|-------|
| `UNION ALL` | ✅ Yes | Fully supported |
| `UNION` (distinct) | ⚠️ Partial | May require full refresh in some cases |

### Aggregations

| Operator | Incremental Support | Notes |
|----------|-------------------|-------|
| `SUM()` | ✅ Yes | Fully supported |
| `COUNT()` | ✅ Yes | Fully supported |
| `AVG()` | ✅ Yes | Supported |
| `MIN()` | ✅ Yes | Supported |
| `MAX()` | ✅ Yes | Supported |
| `GROUP BY` | ✅ Yes | Fully supported |

### Window Functions (Limited)

| Operator | Incremental Support | Notes |
|----------|-------------------|-------|
| `ROW_NUMBER()` | ⚠️ Limited | Depends on partition/order |
| `RANK()` | ⚠️ Limited | Depends on partition/order |
| `LEAD()`/`LAG()` | ⚠️ Limited | May trigger full refresh |

### Other Operations

| Operator | Incremental Support | Notes |
|----------|-------------------|-------|
| `WHERE` | ✅ Yes | Fully supported |
| `HAVING` | ✅ Yes | Fully supported |
| `CASE WHEN` | ✅ Yes | Fully supported |
| `COALESCE` | ✅ Yes | Fully supported |
| `DISTINCT` | ⚠️ Partial | May require full refresh |
| Subqueries (scalar) | ✅ Yes | Generally supported |

---

## Operators That REQUIRE Full Refresh

These operators **cannot** be processed incrementally:

### Outer Join Patterns

| Pattern | Why Not Supported |
|---------|-------------------|
| Outer join with non-equality predicate | ❌ e.g., `ON a.id > b.id` or `ON a.val <> b.val` |

### Set Operations

| Operator | Why Not Supported |
|----------|-------------------|
| `EXCEPT` | ❌ Requires comparing entire datasets |
| `INTERSECT` | ❌ Requires comparing entire datasets |
| `MINUS` | ❌ Same as EXCEPT |

### Table Functions

| Operator | Incremental Support | Notes |
|----------|-------------------|-------|
| `LATERAL FLATTEN` | ✅ Yes | Supported for semi-structured data |
| `LATERAL` (other) | ❌ No | Complex row generation not supported |
| `TABLE()` functions | ⚠️ Partial | Depends on function |

### Non-Deterministic Functions

| Function | Why Not Supported |
|----------|-------------------|
| `RANDOM()` | ❌ Different value on each refresh |
| `UUID_STRING()` | ❌ Generates new value each time |
| `SEQ*()` sequences | ❌ Not reproducible |

**Exception:** `CURRENT_TIMESTAMP()`, `CURRENT_DATE()`, `SYSDATE()` are supported in incremental mode **only when used in filters (WHERE clause)**. Using them in projections (SELECT list) forces FULL refresh because the value changes on every refresh, making rows non-reproducible.

---

## Common refresh_mode_reason Values

When Snowflake cannot use incremental refresh, the `refresh_mode_reason` column explains why:

| Reason | Meaning | Fix |
|--------|---------|-----|
| `QUERY_NOT_SUPPORTED_FOR_INCREMENTAL` | Query uses unsupported constructs | Restructure query or use FULL |
| `USER_SPECIFIED_FULL_REFRESH` | Created with REFRESH_MODE = FULL | Recreate with AUTO or INCREMENTAL |
| `UPSTREAM_USES_FULL_REFRESH` | Upstream DT uses FULL mode | Fix upstream DT first |
| `CHANGE_TRACKING_NOT_ENABLED` | Base table missing change tracking | Enable change tracking |
| `NO_INCREMENTAL_MAINTENANCE_SUPPORT` | Internal limitation | Use FULL refresh |

---

## Converting Full to Incremental

### FULL OUTER JOIN → Alternative Pattern

**Before (requires FULL refresh):**
```sql
SELECT COALESCE(a.id, b.id) as id, a.val1, b.val2
FROM table_a a
FULL OUTER JOIN table_b b ON a.id = b.id
```

**After (supports INCREMENTAL):**
```sql
SELECT a.id, a.val1, b.val2
FROM table_a a
LEFT JOIN table_b b ON a.id = b.id
UNION ALL
SELECT b.id, NULL as val1, b.val2
FROM table_b b
WHERE NOT EXISTS (SELECT 1 FROM table_a a WHERE a.id = b.id)
```

### EXCEPT → LEFT ANTI JOIN

**Before:**
```sql
SELECT id FROM table_a
EXCEPT
SELECT id FROM table_b
```

**After:**
```sql
SELECT a.id
FROM table_a a
LEFT JOIN table_b b ON a.id = b.id
WHERE b.id IS NULL
```

### Complex Window Functions → Intermediate DT

**Before (single complex DT):**
```sql
CREATE DYNAMIC TABLE final AS
SELECT *,
  LEAD(amount) OVER (PARTITION BY customer ORDER BY date) as next_amount,
  LAG(amount) OVER (PARTITION BY customer ORDER BY date) as prev_amount
FROM orders
```

**After (decomposed):**
```sql
-- Intermediate DT with base data
CREATE DYNAMIC TABLE staging.orders_enriched
  TARGET_LAG = DOWNSTREAM
  AS SELECT * FROM orders;

-- Final DT with window functions
CREATE DYNAMIC TABLE final
  TARGET_LAG = '5 minutes'
  REFRESH_MODE = FULL  -- Accept FULL for complex window functions
  AS SELECT *,
    LEAD(amount) OVER (...) as next_amount,
    LAG(amount) OVER (...) as prev_amount
  FROM staging.orders_enriched;
```

---

## Checking If Your Query Supports Incremental

1. **Create with AUTO mode first:**
   ```sql
   CREATE DYNAMIC TABLE test_dt
     TARGET_LAG = '10 minutes'
     WAREHOUSE = compute_wh
     REFRESH_MODE = AUTO  -- Let Snowflake decide
     AS <your_query>;
   ```

2. **Check what Snowflake chose:**
   ```sql
   SELECT refresh_mode, refresh_mode_reason
   FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(name=>'test_dt'));
   ```

3. **If FULL, check reason and optimize query**

---

## Best Practices

1. **Start with AUTO** - Let Snowflake choose, then review
2. **Check refresh_mode_reason** - Understand why FULL is being used
3. **Avoid unsupported constructs** - Restructure if incremental is important
4. **Decompose complex queries** - Split into intermediate DTs
5. **Accept FULL when appropriate** - Some queries genuinely need full refresh
6. **Use DOWNSTREAM** for intermediates - Let pipeline optimize itself

