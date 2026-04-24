# Troubleshooting: script hung at `properties_reconcile_phase2_sync_folders`

## Symptom

After running:

```bash
bash sync-target-from-source.sh \
  --config config_env_examples/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

The console output progresses through all six reconciliation views and then **stops responding**
after printing the last line:

```
=== Generating comparison report ===
Report generated: report-artifactory-sh-to-cloud-20260422-131234.csv
Filtering: target-only (one-way sync to saas)
Filtering: only repos in TARGET_REPOS (e.g. CLOUD_ARTIFACTORY_REPOS)
=== Generating reconciliation scripts in /path/to/tmp/b4_upload (mode: b4upload) ===
jf compare report --jsonl reconcile_phase1_consolidate
  01_to_consolidate.sh
  → Run: /path/to/tmp/b4_upload/01_to_consolidate.sh (or from /path/to/tmp/b4_upload: ./01_to_consolidate.sh)
jf compare report --jsonl properties_reconcile_phase1_consolidate
  02_to_consolidate_props.sh
  → Run: /path/to/tmp/b4_upload/02_to_consolidate_props.sh (or from /path/to/tmp/b4_upload: ./02_to_consolidate_props.sh)
jf compare report --jsonl reconcile_phase2_sync
  03_to_sync.sh
  → Run: /path/to/tmp/b4_upload/03_to_sync.sh (or from /path/to/tmp/b4_upload: ./03_to_sync.sh)
jf compare report --jsonl reconcile_phase2_sync_delayed
  04_to_sync_delayed.sh
  → Run: /path/to/tmp/b4_upload/04_to_sync_delayed.sh (or from /path/to/tmp/b4_upload: ./04_to_sync_delayed.sh)
jf compare report --jsonl reconcile_stats_actionable
  05_to_sync_stats.sh
  → Run: /path/to/tmp/b4_upload/05_to_sync_stats.sh (or from /path/to/tmp/b4_upload: ./05_to_sync_stats.sh)
jf compare report --jsonl properties_reconcile_phase2_sync_folders
```

This is the **final `jf compare report` call** in the `b4upload` reconciliation sequence. It queries
`comparison.db` to generate `06_to_sync_folder_props.sh`. It can take a long time (or appear to
stall) when there are a very large number of folder property records to process.

## Key takeaway: `comparison.db` is already fully populated

By the time you see this line, the following have **already completed successfully**:

| Step | Output |
|------|--------|
| Source and target crawl | `comparison.db` populated with all artifact data |
| CSV comparison report | `report-artifactory-<source>-to-<target>-<timestamp>.csv` |
| `01_to_consolidate.sh` | Generated |
| `02_to_consolidate_props.sh` | Generated |
| `03_to_sync.sh` | Generated — **the list of missing artifacts to sync** |
| `04_to_sync_delayed.sh` | Generated — Docker manifests deferred to a second pass |
| `05_to_sync_stats.sh` | Generated |

The script is only stuck trying to produce `06_to_sync_folder_props.sh`. All artifact-level sync
data (missing files, delayed files, stats) is already available in `comparison.db`.

## What to do right now

### Step 1 — Interrupt the hung process (safe)

Press **Ctrl-C** in the terminal, or `kill <pid>`. Stopping the process at this point does **not**
corrupt `comparison.db`. All crawl data and the five scripts above are already written to disk.

### Step 2 — Change to the working directory

The `comparison.db` file lives in `RECONCILE_BASE_DIR` (the `tmp/b4_upload` directory shown in the
script's output). `cd` into it:

```bash
cd /path/to/tmp/b4_upload    # replace with the actual path printed by the script
```

### Step 3 — Identify your source and target authority names

```bash
sqlite3 comparison.db "SELECT DISTINCT source, repository_name FROM artifacts;"
# No sqlite3? Use:
jf compare query "SELECT DISTINCT source, repository_name FROM artifacts"
```

Note the `source` values — you will need them in the queries below (e.g. `psazuse`, `cloud`).

---

## Querying the missing artifacts

All queries below work with either `sqlite3` (if installed) or `jf compare query` (no extra
install needed — uses the `jf` CLI plugin directly against `comparison.db`).

### Count of artifacts missing on the target, grouped by repo

```bash
sqlite3 -header -column comparison.db \
  "SELECT repo, src, dest, type, count FROM mismatch_summary;"

# Or:
jf compare query "SELECT repo, src, dest, type, count FROM mismatch_summary"
```

Example output:

```
repo                    src    dest   type     count
----------------------  -----  -----  -------  -----
__infra_local_docker    app2   app3   missing  136
```

> **Note:** Files marked for `delay` (e.g. Docker manifests) are excluded from this count. They
> appear in `04_to_sync_delayed.sh`.

### List of artifacts missing on the target (first 20)

```bash
sqlite3 -header -column comparison.db \
  "SELECT source_repo, path, sha1_source, size_source
   FROM missing
   WHERE source = '<source-authority>'
   LIMIT 20;"

# Or:
jf compare query \
  "SELECT source_repo, path, sha1_source, size_source FROM missing WHERE source = '<source-authority>' LIMIT 20"
```

Replace `<source-authority>` with the value from Step 3 (e.g. `app2`).

### Export the full missing-artifacts list to CSV

```bash
sqlite3 comparison.db \
  "SELECT source, source_repo, target, target_repo, path, sha1_source, size_source
   FROM missing;" \
  --csv > missing_artifacts.csv

wc -l missing_artifacts.csv
```

### Summary: truly missing vs checksum mismatch vs matched

This distinguishes artifacts whose **path is absent from the target** (truly missing) from
artifacts that exist on both sides but with a **different checksum** (content mismatch):

```bash
jf compare query "
SELECT 'truly-missing'    AS status, COUNT(*) AS cnt
FROM artifacts a
WHERE a.source = '<source-authority>' AND a.sha1 IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM artifacts b
        WHERE b.source = '<target-authority>' AND b.uri = a.uri)
UNION ALL
SELECT 'content-mismatch', COUNT(*)
FROM artifacts a
JOIN artifacts b ON a.uri = b.uri
WHERE a.source = '<source-authority>' AND b.source = '<target-authority>'
  AND a.sha1 != b.sha1
UNION ALL
SELECT 'matched', COUNT(*)
FROM artifacts a
JOIN artifacts b ON a.uri = b.uri
WHERE a.source = '<source-authority>' AND b.source = '<target-authority>'
  AND a.sha1 = b.sha1"
```

Replace `<source-authority>` and `<target-authority>` with the values from Step 3.

### View the raw mismatch table (all mismatches, first 10 rows)

```bash
sqlite3 -header -column comparison.db \
  "SELECT repo, src, dest, path, type, sha1_src, sha1_dest
   FROM mismatch LIMIT 10;"

# Or:
jf compare query \
  "SELECT repo, src, dest, path, type, sha1_src, sha1_dest FROM mismatch LIMIT 10"
```

The `type` column is `missing` when the artifact is absent on the target side; `sha1 mismatch`
when it exists but with a different checksum.

---

## The generated sync scripts are already usable

Scripts `03_to_sync.sh` and `04_to_sync_delayed.sh` were generated before the hang. You can
proceed with the sync without waiting for `06_to_sync_folder_props.sh`:

```bash
# From the b4_upload directory:
./03_to_sync.sh          # upload artifacts missing on the target
./04_to_sync_delayed.sh  # upload deferred artifacts (e.g. Docker manifests)
./05_to_sync_stats.sh    # sync download stats
```

`06_to_sync_folder_props.sh` only handles **folder-level properties** — skipping it will not
prevent artifact-level files from being synced.

---

## Regenerating `06_to_sync_folder_props.sh` later

Once the sync is complete (or at any time), you can regenerate only the folder-props script by
re-running `compare-and-reconcile.sh` with `--sha1-resume` to skip the crawl and jump directly
to script generation:

```bash
bash sync-target-from-source.sh \
  --config config_env_examples/<your-config>.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit \
  --sha1-resume ""    # empty string skips crawl, reuses comparison.db
```

> **Note:** If `--sha1-resume` with an empty string is not supported by your plugin version,
> run `compare-and-reconcile.sh` directly with `--b4upload --reconcile --target-only` from the
> `RECONCILE_BASE_DIR` directory (where `comparison.db` lives) — this skips `init --clean` when
> `comparison.db` already exists.

---

## Quick reference: key views in `comparison.db`

| View / Table | What it contains |
|---|---|
| `missing` | Source artifacts absent from the target (alias for `sync_missing`) |
| `sync_missing` | Drives `03_to_sync.sh` |
| `sync_normalized_pending_delayed` | Drives `04_to_sync_delayed.sh` (Docker manifests etc.) |
| `mismatch` | All mismatches: missing + checksum differences |
| `mismatch_summary` | Aggregated counts by repo pair and type |
| `sync_diff` | Union of missing + checksum mismatches |
| `sync_diff_summary` | Per-repo counts of missing vs mismatched artifacts |
| `artifacts` | Raw crawled artifact records for both source and target |

See [01-QUICKSTART.md §Inspecting comparison.db](01-QUICKSTART.md#inspecting-comparisondb) for
the full set of queries, and [02-identify_source_target_mismatch.md](02-identify_source_target_mismatch.md)
for per-SHA1-prefix drill-down queries.
