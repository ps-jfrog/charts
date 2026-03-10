# Troubleshooting crawl audit log errors

This document covers common errors found in `crawl-audit-<authority>-<timestamp>.log` files and how to resolve them.

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

To check the true total for a prefix, query Artifactory directly:

```bash
tmp="$(mktemp)" && cat > "$tmp" <<'EOF'
items.find({"type": "file", "actual_sha1": {"$match": "f2*"}}).include("name").limit(1).offset(0)
EOF
jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" \
  -d @"$tmp" --server-id=<server-id> | jq '.range.total'
rm -f "$tmp"
```

Compare this total with the `items=` value in the crawl audit log for that prefix. If they differ, the crawl was incomplete.

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
