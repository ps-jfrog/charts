# Identifying source vs target artifact mismatches per SHA1 prefix

After running a crawl with `--aql-style sha1-prefix`, the crawl audit logs (`crawl-audit-<authority>-<timestamp>.log`) show per-prefix item counts. If the source and target logs show different counts for the same prefix, use the queries below to identify exactly which artifacts differ.

## Prerequisites

- A populated `comparison.db` (from a `--generate-only` or full sync run)
- The source and target authority names and repo names from your config (e.g. `psazuse` / `npmjs-remote-cache` and `psazuse1` / `sv-npmjs-remote-cache-copy`)

Replace `<source>`, `<target>`, `<source-repo>`, `<target-repo>`, and `<prefix>` (e.g. `00`) in the queries below with your actual values.

---

## 1. Count artifacts per side for a specific SHA1 prefix

Confirm the per-prefix totals match the crawl audit log:

```bash
jf compare query "SELECT source, repository_name, COUNT(*) AS cnt FROM artifacts WHERE sha1 LIKE '<prefix>%' GROUP BY source, repository_name"
```

**Example:**

```bash
jf compare query "SELECT source, repository_name, COUNT(*) AS cnt FROM artifacts WHERE sha1 LIKE '00%' GROUP BY source, repository_name"
```

---

## 2. Find artifacts in the target but not in the source

Artifacts whose SHA1 exists in the target but not in the source for a given prefix. Note that the same URI (path + filename) may exist on both sides — these results indicate the *content* (SHA1) differs, not necessarily that the file path is absent from the source:

```bash
jf compare query "SELECT a.source, a.repository_name, a.uri, a.sha1, a.size FROM artifacts a WHERE a.source = '<target>' AND a.sha1 LIKE '<prefix>%' AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<source>' AND b.sha1 = a.sha1) ORDER BY a.uri"
```

**Example:**

```bash
jf compare query "SELECT a.source, a.repository_name, a.uri, a.sha1, a.size FROM artifacts a WHERE a.source = 'psazuse1' AND a.sha1 LIKE '00%' AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse' AND b.sha1 = a.sha1) ORDER BY a.uri"
```

---

## 3. Find artifacts in the source but not in the target

Artifacts whose SHA1 exists in the source but not in the target for a given prefix. As with section 2, the same URI may exist on the other side with a different SHA1 — the mismatch is based on content (SHA1), not path:

```bash
jf compare query "SELECT a.source, a.repository_name, a.uri, a.sha1, a.size FROM artifacts a WHERE a.source = '<source>' AND a.sha1 LIKE '<prefix>%' AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.sha1 = a.sha1) ORDER BY a.uri"
```

**Example:**

```bash
jf compare query "SELECT a.source, a.repository_name, a.uri, a.sha1, a.size FROM artifacts a WHERE a.source = 'psazuse' AND a.sha1 LIKE '00%' AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse1' AND b.sha1 = a.sha1) ORDER BY a.uri"
```

---

## 4. URI-based presence check: are the source files actually missing from the target?

Sections 2 and 3 match artifacts by SHA1 (content hash). However, the same file path (URI) may exist on both sides with a *different* SHA1 — for example, after a re-publish, a cache refresh, or a metadata-only change that alters the checksum. In such cases the artifact is not truly missing from the target; it just has different content.

This section helps you separate two distinct situations:

- **Truly missing** — the URI does not exist in the target at all
- **Present but with different content** — the URI exists on both sides but the SHA1 differs

Run these queries *before* section 3 to understand whether the SHA1-based differences are genuine missing files or just content mismatches.

### 4a. Source URIs completely absent from the target (truly missing)

These are artifacts in the source (for a given prefix) whose path does not appear in the target at all — the file is genuinely missing:

```bash
jf compare query "SELECT a.source, a.repository_name, a.uri, a.sha1, a.size FROM artifacts a WHERE a.source = '<source>' AND a.sha1 LIKE '<prefix>%' AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.uri = a.uri) ORDER BY a.uri"
```

**Example:**

```bash
jf compare query "SELECT a.source, a.repository_name, a.uri, a.sha1, a.size FROM artifacts a WHERE a.source = 'psazuse' AND a.sha1 LIKE '00%' AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse1' AND b.uri = a.uri) ORDER BY a.uri"
```

### 4b. Source URIs present in the target but with a different SHA1 (content mismatch)

These are artifacts where the file path exists on both sides but the content differs — the file is present, just not identical:

```bash
jf compare query "SELECT a.uri, a.sha1 AS source_sha1, b.sha1 AS target_sha1, a.size FROM artifacts a JOIN artifacts b ON a.uri = b.uri AND b.source = '<target>' WHERE a.source = '<source>' AND a.sha1 LIKE '<prefix>%' AND a.sha1 != b.sha1 ORDER BY a.uri"
```

**Example:**

```bash
jf compare query "SELECT a.uri, a.sha1 AS source_sha1, b.sha1 AS target_sha1, a.size FROM artifacts a JOIN artifacts b ON a.uri = b.uri AND b.source = 'psazuse1' WHERE a.source = 'psazuse' AND a.sha1 LIKE '00%' AND a.sha1 != b.sha1 ORDER BY a.uri"
```

### Recommended workflow

1. Run **4a** to see how many source URIs are truly absent from the target.
2. Run **4b** to see how many source URIs exist in the target with different content.
3. If 4a returns zero rows, all source files for that prefix are present in the target — the SHA1 differences from section 3 are content mismatches only, not missing files.
4. If 4a returns rows, those are the files that need to be synced. Use section 3 to get the full SHA1-based list for the sync scripts.

---

## 5. URI-based presence check across all prefixes (entire repo)

Section 4 focuses on a single SHA1 prefix. The queries below remove the prefix filter to give you a full-repo view of truly missing URIs vs content mismatches between source and target.

### 5a. Summary counts: truly missing vs content mismatch vs matched

A single query that classifies every source file artifact into one of three categories (the `sha1 IS NOT NULL` filter excludes folder entries):

```bash
jf compare query "
SELECT 'truly-missing' AS status, COUNT(*) AS cnt
FROM artifacts a
WHERE a.source = '<source>' AND a.sha1 IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.uri = a.uri)
UNION ALL
SELECT 'content-mismatch', COUNT(*)
FROM artifacts a
WHERE a.source = '<source>' AND a.sha1 IS NOT NULL
  AND EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.uri = a.uri AND b.sha1 != a.sha1)
UNION ALL
SELECT 'matched', COUNT(*)
FROM artifacts a
WHERE a.source = '<source>' AND a.sha1 IS NOT NULL
  AND EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.uri = a.uri AND b.sha1 = a.sha1)
"
```

**Example:**

```bash
jf compare query "
SELECT 'truly-missing' AS status, COUNT(*) AS cnt
FROM artifacts a
WHERE a.source = 'psazuse' AND a.sha1 IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse1' AND b.uri = a.uri)
UNION ALL
SELECT 'content-mismatch', COUNT(*)
FROM artifacts a
WHERE a.source = 'psazuse' AND a.sha1 IS NOT NULL
  AND EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse1' AND b.uri = a.uri AND b.sha1 != a.sha1)
UNION ALL
SELECT 'matched', COUNT(*)
FROM artifacts a
WHERE a.source = 'psazuse' AND a.sha1 IS NOT NULL
  AND EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse1' AND b.uri = a.uri AND b.sha1 = a.sha1)
"
```

### 5b. List all source URIs completely absent from the target

```bash
jf compare query "SELECT a.repository_name, a.uri, a.sha1, a.size FROM artifacts a WHERE a.source = '<source>' AND a.sha1 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.uri = a.uri) ORDER BY a.repository_name, a.uri"
```

**Example:**

```bash
jf compare query "SELECT a.repository_name, a.uri, a.sha1, a.size FROM artifacts a WHERE a.source = 'psazuse' AND a.sha1 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse1' AND b.uri = a.uri) ORDER BY a.repository_name, a.uri"
```

> **Note — relationship to `sync_missing` and `sync_normalized_pending_delayed` views:**
>
> The plugin has two built-in views that perform similar URI-based checks with additional filtering:
>
> **`sync_missing`** (generates `03_to_sync.sh`):
> - Respects the **repo mapping** (`cross_instance_mapping`) — only compares mapped source→target repo pairs
> - **Includes only non-excluded artifacts** — `reason IS NULL` from the `exclusions` view (passed all exclusion rules)
> - **Excludes folder entries** — requires at least one non-null checksum (sha1, sha2, or md5)
>
> ```bash
> jf compare query "SELECT source, source_repo, path, sha1_source, size_source FROM sync_missing ORDER BY source_repo, path"
> ```
>
> **`sync_normalized_pending_delayed`** (generates `04_to_sync_delayed.sh`):
> - Same repo mapping and folder exclusion logic as `sync_missing`
> - **Includes only delayed artifacts** — `reason LIKE 'delay:%'` (e.g. Docker manifests with `delay: docker`)
>
> ```bash
> jf compare query "SELECT source, source_repo, path, sha1 FROM sync_normalized_pending_delayed ORDER BY source_repo, path"
> ```
>
> The `missing` view is a **backward-compatibility alias** for `sync_missing` — querying `SELECT * FROM missing` returns exactly the same rows as `SELECT * FROM sync_missing`.
>
> | View | Alias for | Generates | Filters by |
> |------|-----------|-----------|------------|
> | `missing` | `sync_missing` | (same as `sync_missing`) | (same as `sync_missing`) |
> | `sync_missing` | — | `03_to_sync.sh` | `reason IS NULL` (non-excluded) |
> | `sync_normalized_pending_delayed` | — | `04_to_sync_delayed.sh` | `reason LIKE 'delay:%'` (delayed) |
>
> Together, `sync_missing` + `sync_normalized_pending_delayed` cover all artifacts that need syncing (non-excluded + delayed). If your repo mappings are clean and no exclusion rules are triggered, their combined results should match the 5b results. The 5b query above is a raw, unfiltered check against the `artifacts` table — useful for independent verification without exclusion/mapping logic.

### 5b-aql. Verify truly missing URIs directly via Artifactory AQL

You can cross-check the 5b results by querying Artifactory directly. For each URI returned by 5b, search the target repo to confirm it does not exist. To check all truly-missing URIs at once, export them from 5b and search the target:

**Step 1 — Export the truly-missing URIs from the comparison.db to a file:**

```bash
jf compare query "SELECT a.uri FROM artifacts a WHERE a.source = '<source>' AND a.sha1 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.uri = a.uri) ORDER BY a.uri" > /tmp/truly_missing_uris.txt
```

**Step 2 — For each URI, search the target repo via AQL to confirm it is absent:**

```bash
while IFS= read -r uri; do
  # strip leading/trailing whitespace and skip header/empty lines
  uri="$(echo "$uri" | xargs)"
  [[ -z "$uri" || "$uri" == "uri" || "$uri" == *"---"* ]] && continue
  tmp="$(mktemp)" && cat > "$tmp" <<EOF
items.find({"type": "file", "repo": "<target-repo>", "\$or": [{"path": {"\$match": "$(dirname "$uri")"},"name": "$(basename "$uri")"}]}).include("repo","path","name","actual_sha1","size")
EOF
  result=$(jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" -d @"$tmp" --server-id=<target-server-id> | jq '.range.total')
  rm -f "$tmp"
  echo "$uri -> target matches: $result"
done < /tmp/truly_missing_uris.txt
```

**Alternatively, search the entire target repo for a single URI to spot-check:**

```bash
tmp="$(mktemp)" && cat > "$tmp" <<'EOF'
items.find({"type": "file", "repo": "sv-npmjs-remote-cache-copy", "path": {"$match": "path/to/parent"}, "name": "filename.ext"}).include("repo","path","name","actual_sha1","size")
EOF
jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" -d @"$tmp" --server-id=psazuse1
rm -f "$tmp"
```

If AQL returns zero results for a URI, it confirms the file is genuinely absent from the target — not a crawl artifact.

### 5b-aql-diff. Find truly missing URIs via AQL + diff (without comparison.db)

AQL does not support JOINs or subqueries, so you cannot compare two repos in a single AQL query. The helper script [`find-truly-missing-uris.sh`](find-truly-missing-uris.sh) crawls both repos via paginated AQL, diffs the URI lists, and reports truly missing, target-only, and shared files. This is useful when you want to verify results independently of the `jf compare` plugin, or when you don't have a `comparison.db` at all.

**Usage:**

```bash
bash find-truly-missing-uris.sh \
  --source-repo <repo>   --source-server-id <server-id> \
  --target-repo <repo>   --target-server-id <server-id> \
  [--page-size <n>]      [--output-dir <dir>]
```

| Flag | Description | Default |
|------|-------------|---------|
| `--source-repo` | Source repository name | (required) |
| `--source-server-id` | JFrog CLI server ID for the source | (required) |
| `--target-repo` | Target repository name | (required) |
| `--target-server-id` | JFrog CLI server ID for the target | (required) |
| `--page-size` | AQL pagination size | `1000` |
| `--output-dir` | Directory for output files | current directory |

**Output files** (written to `--output-dir`):

| File | Contents |
|------|----------|
| `source_uris.txt` | Sorted list of all file URIs in the source repo |
| `target_uris.txt` | Sorted list of all file URIs in the target repo |
| `truly_missing_uris.txt` | URIs in source but not in target |
| `target_only_uris.txt` | URIs in target but not in source |
| `shared_uris.txt` | URIs present on both sides |

**Example — same Artifactory instance, two repos:**

```bash
bash find-truly-missing-uris.sh \
  --source-repo npmjs-remote-cache --source-server-id psazuse \
  --target-repo sv-npmjs-remote-cache-copy --target-server-id psazuse \
  --output-dir /tmp/compare-results
```

**Example — different instances, custom page size:**

```bash
bash find-truly-missing-uris.sh \
  --source-repo my-maven-local --source-server-id prod \
  --target-repo my-maven-local --target-server-id dr \
  --page-size 5000 --output-dir /tmp/compare-results
```

**Sample output:**

```
Crawling npmjs-remote-cache (server: psazuse, page size: 1000) ...
  offset=0  fetched=1000
  offset=1000  fetched=1000
  offset=2000  fetched=743
  Total URIs: 2743 -> /tmp/compare-results/source_uris.txt

Crawling sv-npmjs-remote-cache-copy (server: psazuse, page size: 1000) ...
  offset=0  fetched=1000
  offset=1000  fetched=1000
  offset=2000  fetched=689
  Total URIs: 2689 -> /tmp/compare-results/target_uris.txt

=== Results ===
Source URIs:        2743
Target URIs:        2689
Truly missing:      58  -> /tmp/compare-results/truly_missing_uris.txt
Target-only:        4  -> /tmp/compare-results/target_only_uris.txt
Shared:             2685  -> /tmp/compare-results/shared_uris.txt
```

### 5c. List all source URIs present in the target with a different SHA1

```bash
jf compare query "SELECT a.repository_name, a.uri, a.sha1 AS source_sha1, b.sha1 AS target_sha1, a.size FROM artifacts a JOIN artifacts b ON a.uri = b.uri AND b.source = '<target>' WHERE a.source = '<source>' AND a.sha1 IS NOT NULL AND a.sha1 != b.sha1 ORDER BY a.repository_name, a.uri"
```

**Example:**

```bash
jf compare query "SELECT a.repository_name, a.uri, a.sha1 AS source_sha1, b.sha1 AS target_sha1, a.size FROM artifacts a JOIN artifacts b ON a.uri = b.uri AND b.source = 'psazuse1' WHERE a.source = 'psazuse' AND a.sha1 IS NOT NULL AND a.sha1 != b.sha1 ORDER BY a.repository_name, a.uri"
```

### How to interpret the results

- **truly-missing = 0** — every source URI exists in the target. The SHA1 differences from sections 2/3 are all content mismatches (same path, different checksum). This is common for remote-cache repos where artifacts may be re-cached at different times.
- **truly-missing > 0** — those URIs need to be synced. The generated `03_to_sync.sh` and `04_to_sync_delayed.sh` scripts will handle them.
- **content-mismatch > 0** — the files exist on both sides but with different content. Depending on your use case, you may or may not need to overwrite the target versions.

---

## 6. Full breakdown by SHA1: source-only, target-only, and shared (for a prefix)

```bash
jf compare query "
SELECT 'source-only' AS side, COUNT(*) AS cnt FROM artifacts a
  WHERE a.source = '<source>' AND a.sha1 LIKE '<prefix>%'
  AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.sha1 = a.sha1)
UNION ALL
SELECT 'target-only', COUNT(*) FROM artifacts a
  WHERE a.source = '<target>' AND a.sha1 LIKE '<prefix>%'
  AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<source>' AND b.sha1 = a.sha1)
UNION ALL
SELECT 'both', COUNT(*) FROM artifacts a
  WHERE a.source = '<source>' AND a.sha1 LIKE '<prefix>%'
  AND EXISTS (SELECT 1 FROM artifacts b WHERE b.source = '<target>' AND b.sha1 = a.sha1)
"
```

**Example:**

```bash
jf compare query "
SELECT 'source-only' AS side, COUNT(*) AS cnt FROM artifacts a
  WHERE a.source = 'psazuse' AND a.sha1 LIKE '00%'
  AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse1' AND b.sha1 = a.sha1)
UNION ALL
SELECT 'target-only', COUNT(*) FROM artifacts a
  WHERE a.source = 'psazuse1' AND a.sha1 LIKE '00%'
  AND NOT EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse' AND b.sha1 = a.sha1)
UNION ALL
SELECT 'both', COUNT(*) FROM artifacts a
  WHERE a.source = 'psazuse' AND a.sha1 LIKE '00%'
  AND EXISTS (SELECT 1 FROM artifacts b WHERE b.source = 'psazuse1' AND b.sha1 = a.sha1)
"
```

### Alternative: FULL OUTER JOIN approach

A single `FULL OUTER JOIN` query that classifies every distinct SHA1 as source-only, target-only, or shared:

```bash
jf compare query "
SELECT
  CASE
    WHEN s.sha1 IS NOT NULL AND t.sha1 IS NOT NULL THEN 'both'
    WHEN s.sha1 IS NOT NULL THEN 'source-only'
    ELSE 'target-only'
  END AS side,
  COUNT(*) AS cnt
FROM
  (SELECT DISTINCT sha1 FROM artifacts WHERE source = '<source>' AND sha1 LIKE '<prefix>%') s
  FULL OUTER JOIN
  (SELECT DISTINCT sha1 FROM artifacts WHERE source = '<target>' AND sha1 LIKE '<prefix>%') t
  ON s.sha1 = t.sha1
GROUP BY side
"
```

**Example:**

```bash
jf compare query "SELECT CASE WHEN s.sha1 IS NOT NULL AND t.sha1 IS NOT NULL THEN 'both' WHEN s.sha1 IS NOT NULL THEN 'source-only' ELSE 'target-only' END AS side, COUNT(*) AS cnt FROM (SELECT DISTINCT sha1 FROM artifacts WHERE source = 'psazuse' AND sha1 LIKE '00%') s FULL OUTER JOIN (SELECT DISTINCT sha1 FROM artifacts WHERE source = 'psazuse1' AND sha1 LIKE '00%') t ON s.sha1 = t.sha1 GROUP BY side"
```

---

## 7. Verify directly via Artifactory AQL

To confirm the raw Artifactory data outside the plugin, query the AQL API directly for a specific prefix:

**Source repo:**

```bash
tmp="$(mktemp)" && cat > "$tmp" <<'EOF'
items.find({"$and": [{"type": "file"}, {"actual_sha1": {"$match": "00*"}}, {"repo": "npmjs-remote-cache"}]}).include("name","repo","path","actual_sha1","size").sort({"$asc":["path","name"]})
EOF
jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" -d @"$tmp" --server-id=psazuse | jq '.results | length'
rm -f "$tmp"
```

**Target repo:**

```bash
tmp="$(mktemp)" && cat > "$tmp" <<'EOF'
items.find({"$and": [{"type": "file"}, {"actual_sha1": {"$match": "00*"}}, {"repo": "sv-npmjs-remote-cache-copy"}]}).include("name","repo","path","actual_sha1","size").sort({"$asc":["path","name"]})
EOF
jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" -d @"$tmp" --server-id=psazuse1 | jq '.results | length'
rm -f "$tmp"
```

If the AQL counts match the crawl audit log counts, the crawl was accurate and the repos genuinely have different content for that prefix.

---

## When to use these queries

- **After a `--generate-only` run** where the crawl audit logs show per-prefix count differences between source and target
- **To prove the crawl is accurate** — if the AQL counts match the crawl audit log, the difference is real content variation, not a crawl bug
- **To investigate large discrepancies** — if the customer's `exclusion_summary` shows a significant artifact gap, drill into specific prefixes to understand whether the gap is from transient AQL errors (check `grep ERROR crawl-audit-*.log`) or genuine content differences
