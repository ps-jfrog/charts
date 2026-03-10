# Troubleshooting crawl audit log errors

This document covers common errors found in `crawl-audit-<authority>-<timestamp>.log` files and how to resolve them.

## Understanding the AQL queries behind sha1-prefix crawl

When running with `--aql-style sha1-prefix`, the plugin executes two phases of AQL queries. Understanding these helps diagnose why errors occur at specific offsets.

### Phase 1: sha1-prefix file crawl (256 prefixes: 00–ff)

One AQL query per SHA1 prefix (`00` through `ff`), paginated with `offset` / `limit`. For a single repo (e.g. `--repos=npmjs-remote-cache`) with `--aql-page-size=5000` and without `--collect-stats --collect-properties`:

**Page 1 (offset=0):**

```
items.find({"$and": [{"type": {"$eq": "file"}}, {"actual_sha1": {"$match": "f2*"}}, {"repo": "npmjs-remote-cache"}]}).include("name", "repo", "path", "size", "actual_sha1", "sha256", "actual_md5", "created", "created_by", "modified", "modified_by").sort({"$asc":["repo","path","name"]}).offset(0).limit(5000)
```

**Page 2 (offset=5000):**

```
items.find({"$and": [{"type": {"$eq": "file"}}, {"actual_sha1": {"$match": "f2*"}}, {"repo": "npmjs-remote-cache"}]}).include("name", "repo", "path", "size", "actual_sha1", "sha256", "actual_md5", "created", "created_by", "modified", "modified_by").sort({"$asc":["repo","path","name"]}).offset(5000).limit(5000)
```

Pagination continues until a page returns fewer than 5000 results, or an error occurs.

**Page 9 (offset=40000) — example of a failed page:**

```
items.find({"$and": [{"type": {"$eq": "file"}}, {"actual_sha1": {"$match": "f2*"}}, {"repo": "npmjs-remote-cache"}]}).include("name", "repo", "path", "size", "actual_sha1", "sha256", "actual_md5", "created", "created_by", "modified", "modified_by").sort({"$asc":["repo","path","name"]}).offset(40000).limit(5000)
```

The error `prefix=f2 offset=40000: EOF` means pages 0–35000 succeeded (8 pages, ~40,000 items fetched), but the 9th page at offset 40000 failed.

**With multiple repos** (e.g. `--repos=repo-a,repo-b`), the repo filter becomes `{"$or": [{"repo": "repo-a"}, {"repo": "repo-b"}]}`, combining items from both repos into a single query per prefix — which produces larger result sets and increases the chance of timeouts.

### Phase 2: sha1-prefix folder crawl (per-repo, per-prefix)

Folders are crawled **per-repo** with the sha256 name prefix split. With `--folder-parallel=16`, up to 16 of these run concurrently:

**Non-sha256 folders:**

```
items.find({"repo": {"$eq": "npmjs-remote-cache"}, "type": "folder", "name": {"$nmatch": "sha256:*"}}).include("name", "repo", "path", "size", "created", "created_by", "modified", "modified_by").sort({"$asc":["repo","path","name"]}).offset(0).limit(5000)
```

**sha256:0 folders:**

```
items.find({"repo": {"$eq": "npmjs-remote-cache"}, "type": "folder", "name": {"$match": "sha256:0*"}}).include("name", "repo", "path", "size", "created", "created_by", "modified", "modified_by").sort({"$asc":["repo","path","name"]}).offset(0).limit(5000)
```

Similarly for `sha256:1` through `sha256:f` — one query per hex prefix per repo, each paginated independently.

### With --collect-stats --collect-properties

When stats and properties collection is enabled (i.e. without `--skip-collect-stats-properties`), the `.include()` clause expands to also request `"stat.downloads"`, `"stat.downloaded"`, `"stat.downloaded_by"`, `"stat.remote_downloads"`, `"stat.remote_downloaded"`, `"stat.remote_downloaded_by"`, and `"property.*"`. This makes each query return significantly more data per item, increasing the chance of timeouts.

---

## Checking for errors

```bash
grep ERROR "$RECONCILE_BASE_DIR"/crawl-audit-*.log
```

## Common error types

### EOF (connection closed by server)

```
[sha1-prefix files]  ERROR  prefix=f2 offset=40000: Post "https://artifactory.example.com/artifactory/api/search/aql": EOF
```

The HTTP connection was unexpectedly closed by the server mid-response. Causes:

- Artifactory's reverse proxy (nginx/HAProxy) or ALB timed out the long-running AQL query
- Artifactory ran out of memory or resources processing a large result set
- A network device between the client and server dropped the connection

### TLS handshake timeout

```
[sha1-prefix files]  ERROR  prefix=fa offset=25000: Post "https://artifactory.example.com/artifactory/api/search/aql": net/http: TLS handshake timeout
```

The client couldn't establish a new TLS connection for the next page. Causes:

- Server under heavy load from too many concurrent connections (high `--folder-parallel` value)
- Network congestion or transient DNS/routing issues
- Firewall or load balancer connection limits reached

### HTTP 500 / AQL query execution timeout

```
[sha1-prefix files]  ERROR  prefix=a8 offset=1500: HTTP 500: AQL query execution timeout
```

The Artifactory server-side query exceeded its internal execution time limit. Causes:

- Very large prefix buckets requiring extensive database scans
- Artifactory database under heavy concurrent load
- Database connection pool exhaustion

### Connection reset by peer

```
[sha1-prefix files]  ERROR  prefix=a8 offset=1500 read: connection reset by peer
```

The server forcibly closed the TCP connection. Often follows an HTTP 500 or occurs when:

- The server process handling the request crashed or was killed
- A load balancer health check determined the backend was unhealthy

## Impact of errors

When a crawl error occurs for a prefix, the crawl **stops paginating that prefix**. All artifacts beyond the last successful offset are missing from `comparison.db`.

Example: with `--aql-page-size 5000` and an error at `offset=40000`:

| Prefix | Last successful offset | Artifacts captured | Artifacts missed |
|--------|----------------------|-------------------|-----------------|
| `f2` | 35,000 | ~40,000 | unknown remainder |
| `f3` | 35,000 | ~40,000 | unknown remainder |
| `fa` | 20,000 | ~25,000 | unknown remainder |

This leads to:
- Fewer items in the `exclusion_summary` than actually exist
- Potentially fewer entries in `03_to_sync.sh` / `04_to_sync_delayed.sh`
- Count differences when comparing crawl audit logs between source and target

## Verifying actual counts via AQL

> **Note:** With `--aql-style sha1-prefix`, the file crawl queries **all repos at once** per prefix. The error `prefix=f2 offset=40000` means the combined result across all repos for that authority failed at that offset — it is not specific to a single repo. To identify which repo contributes the most items to a prefix, query each repo individually.

**Count for a specific repo and prefix:**

```bash
tmp="$(mktemp)" && cat > "$tmp" <<'EOF'
items.find({"type": "file", "actual_sha1": {"$match": "f2*"}, "repo": "<repo-name>"}).include("name").limit(1).offset(0)
EOF
jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" \
  -d @"$tmp" --server-id=<server-id> | jq '.range.total'
rm -f "$tmp"
```

**Count across all repos for a prefix (matches the crawl audit log entry):**

```bash
tmp="$(mktemp)" && cat > "$tmp" <<'EOF'
items.find({"type": "file", "actual_sha1": {"$match": "f2*"}}).include("name").limit(1).offset(0)
EOF
jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" \
  -d @"$tmp" --server-id=<server-id> | jq '.range.total'
rm -f "$tmp"
```

Compare these totals with the `items=` value in the crawl audit log for that prefix. If they differ, the crawl was incomplete. The per-repo query helps identify which repo has the largest contribution to the prefix and may be causing the timeout.

## How to mitigate

### 1. Reduce concurrency

Lower `--folder-parallel` (e.g. from 16 to 4 or 8) to reduce the number of concurrent AQL connections:

```bash
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 4 \
  --verification-csv --verification-no-limit
```

### 2. Reduce page size

Lower `--aql-page-size` (e.g. from 5000 to 2000) to make each individual AQL query lighter and less likely to time out:

```bash
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 2000 --folder-parallel 8 \
  --verification-csv --verification-no-limit
```

### 3. Re-run the crawl

These errors are transient. A second run may succeed for the previously failed prefixes since `jf compare list` repopulates `comparison.db`:

```bash
# Re-run with the same flags — the crawl will re-crawl all prefixes
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

Check the new crawl audit log to confirm the previously errored prefixes now have complete counts.

### 4. Use folder-based crawl instead of sha1-prefix

If `--aql-style sha1-prefix` consistently fails for certain prefixes due to very large buckets, try running **without** the `--aql-style` flag. This uses the default folder-based crawl, which paginates per-repo per-folder rather than by SHA1 prefix:

```bash
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache \
  --aql-page-size 5000 \
  --verification-csv --verification-no-limit
```

**Why this can help:**

- `sha1-prefix` aggregates artifacts from **all repos** into a single AQL query per prefix. A popular prefix (e.g. `f2`) may contain tens of thousands of items across multiple repos, producing very large result sets that stress the server.
- The default folder-based crawl queries **one repo at a time**, breaking the work into smaller, more manageable AQL queries. Each individual query is lighter, reducing the chance of timeouts and connection drops.

**Trade-off:** The folder-based crawl may be slower overall (more queries, each scoped to a single repo) but is more resilient to transient network errors because no single query returns an extremely large result set.

### 5. Check Artifactory server-side logs

On the Artifactory server, check for corresponding errors:

- `$JFROG_HOME/artifactory/var/log/artifactory-request.log` — look for 5xx responses on `/api/search/aql`
- `$JFROG_HOME/artifactory/var/log/artifactory-service.log` — look for database timeouts or memory issues
- If behind a reverse proxy (nginx/HAProxy), check its access and error logs for connection timeouts

## See also

- [identify_source_target_mismatch.md](identify_source_target_mismatch.md) — queries to drill into per-prefix artifact differences
- [find-truly-missing-uris.sh](find-truly-missing-uris.sh) — AQL-based script to compare repos without `comparison.db`
