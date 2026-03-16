# sync-target-from-source.sh — One-shot sync workflow

## Documentation index

| # | Document | Description |
|---|----------|-------------|
| — | [README.md](README.md) (this file) | Overview of `sync-target-from-source.sh`, options, config files, and end-to-end workflow |
| 1 | [01-QUICKSTART.md](01-QUICKSTART.md) | Step-by-step walkthrough: setup, first run, inspecting results |
| 2 | [02-identify_source_target_mismatch.md](02-identify_source_target_mismatch.md) | Post-sync verification and debugging: queries to find missing/mismatched artifacts |
| 3 | [03-README-troubleshooting-crawl-errors.md](03-README-troubleshooting-crawl-errors.md) | Crawl error recovery: diagnosing AQL failures, using `--sha1-resume` |

**Helper references:** [README-compare-and-reconcile.md](README-compare-and-reconcile.md) | [README-verify-comparison-db.md](README-verify-comparison-db.md) | [README-retarget-sync-scripts.md](README-retarget-sync-scripts.md) | [README-group_sync_by_sha1.md](README-group_sync_by_sha1.md) | [README-convert_dl_upload_to_rt_cp.md](README-convert_dl_upload_to_rt_cp.md) | [README-runcommand_in_parallel_from_file.md](README-runcommand_in_parallel_from_file.md)

---

This script automates **Steps 2 through 6** of [01-QUICKSTART.md](01-QUICKSTART.md): it runs the full compare-and-reconcile workflow (before-upload and after-upload), executes all generated reconciliation scripts, and runs post-sync verification queries so that the **target Artifactory matches the source** in one invocation.

**Step 1** (setting environment variables) is not automated: you must set the required env vars before running the script, or pass a config file with `--config <file>`.

---

## What the script does (mapping to QUICKSTART)

| Script step | QUICKSTART step | Action |
|-------------|-----------------|--------|
| (you set env) | **Step 1** | Set COMPARE_*, SH_ARTIFACTORY_*, CLOUD_ARTIFACTORY_*, etc. (or use `--config`) |
| Step 2 | **Step 2** | Run `compare-and-reconcile.sh --b4upload --collect-stats-properties --reconcile --target-only`; output in `b4_upload/`. Skipped with `--run-only`. With `--generate-only`, runs this step then exits. |
| Step 3 | **Step 3** | Run before-upload scripts 01–06 via `runcommand_in_parallel_from_file.sh`. 01/02 skippable (`--skip-consolidation`); 04 skipped by default (`--run-delayed` to include). For 03/04: same-URL uses `jf rt cp`; different-URL groups by SHA1. For 06: filters out sync-only lines via `filter_sync_only_folder_props.sh`, running `06a` instead. |
| Step 4 | **Step 4** | Run `compare-and-reconcile.sh --after-upload ...`; output in `after_upload/` |
| Step 5 | **Step 5** | Run after-upload scripts 07, 08 via `runcommand_in_parallel_from_file.sh`. Script 09 is skipped by default; use `--run-folder-stats` to include it. |
| Step 6 | *(new)* | Post-sync verification: runs [verify-comparison-db.sh](verify-comparison-db.sh) to query `comparison.db` via `jf compare query` — displays exclusion rules, repo mapping, reason-category counts, and a per-repo breakdown of missing files, delay files, and excluded files (each with count and listing). |

The script resolves its own directory so it can call `compare-and-reconcile.sh` and `runcommand_in_parallel_from_file.sh` correctly no matter where you run it from.

**Same Artifactory URL (source and target on one instance):** When `SH_ARTIFACTORY_BASE_URL` and `CLOUD_ARTIFACTORY_BASE_URL` are equal (e.g. app2 → app3 on the same host), Step 3 does **not** run `03_to_sync.sh` (download from source then upload to target). Instead it runs [convert_dl_upload_to_rt_cp.sh](convert_dl_upload_to_rt_cp.sh) to generate `03_to_sync_using_copy.sh` from `03_to_sync.sh`, then runs `03_to_sync_using_copy.sh`, which uses `jf rt cp` so artifacts are copied server-side. The same applies to `04_to_sync_delayed.sh` when `--run-delayed` is used. If the converter script is missing, it falls back to grouped dl+upload (see below). See [README-convert_dl_upload_to_rt_cp.md](README-convert_dl_upload_to_rt_cp.md).

**Different Artifactory URLs (SHA1 deduplication):** When source and target are on different instances, Step 3 groups `03_to_sync.sh` (and `04_to_sync_delayed.sh` when `--run-delayed` is used) by SHA1 via [group_sync_by_sha1.sh](group_sync_by_sha1.sh) before running. Docker repos often share layers across tags, so the same blob may appear in many lines. Grouping downloads each unique SHA1 **once** and uploads it to all destinations, then cleans up — eliminating redundant downloads (typically 60–80% reduction) and preventing parallel-task race conditions on shared `/tmp` files. See [README-group_sync_by_sha1.md](README-group_sync_by_sha1.md).

**Folder properties filtering (T19):** Before running `06_to_sync_folder_props.sh`, the script filters it through [filter_sync_only_folder_props.sh](filter_sync_only_folder_props.sh) to exclude lines that set **only** `sync.*` properties (e.g. `sync.created`, `sync.modifiedBy`). The filtered output is `06a_lines_other_than_only_sync_folder_props.sh`, which is then executed instead. Lines with at least one user-defined property (e.g. `folder-color=red`) are kept. This avoids running no-op sync-metadata commands on repos with thousands of folders. If `filter_sync_only_folder_props.sh` is not found, the script falls back to running `06` as-is.

**Timing:** The script reports elapsed time for each generated script, each step (Steps 2–5), and the overall run. Timing lines appear as `[timing] <name> completed in Xm Ys`.

---

## Prerequisites

- Same as [01-QUICKSTART.md](01-QUICKSTART.md): JFrog CLI with compare plugin, CLI profiles for source and target (e.g. `app1`, `app2`), `jq`.
- **Supported scenario:** Case a (Artifactory SH → Artifactory Cloud). Other scenarios are not yet supported by this one-shot script.

---

## Usage

### Step 1: Set environment variables

Set the same variables as in QUICKSTART Step 1. Example for Artifactory SH → Cloud:

```bash
# Optional: enable debug logging for jf compare (shows AQL queries, HTTP requests, pagination details)
export JFROG_CLI_LOG_LEVEL=DEBUG

export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="http://<source-host>/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export CLOUD_ARTIFACTORY_BASE_URL="http://<target-host>/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_aql"

# Optional: limit to specific repos
export SH_ARTIFACTORY_REPOS="sv-docker-local,example-repo-local"
export CLOUD_ARTIFACTORY_REPOS="sv-docker-local,example-repo-local"

# Optional: where to put b4_upload/ and after_upload/ (default: script directory)
export RECONCILE_BASE_DIR="/path/to/my/output"
```

> **`JFROG_CLI_LOG_LEVEL=DEBUG`** enables verbose logging from `jf compare` commands, including the full AQL queries sent to Artifactory, HTTP request/response details, pagination offsets, and artifact counts per repo. This is useful for diagnosing crawl issues (e.g. verifying which repos are being queried, how many results each AQL page returns, or why certain artifacts are missing). Note: even if you do not set this variable, `compare-and-reconcile.sh` defaults it to `DEBUG` (see `export JFROG_CLI_LOG_LEVEL="${JFROG_CLI_LOG_LEVEL:-DEBUG}"`). Set it to `INFO` explicitly to override that default for quieter output in production runs.

> **Recommendation:** Use an **absolute path** for `RECONCILE_BASE_DIR` to avoid ambiguity, especially in the two-pass workflow (`--generate-only` then `--run-only`). If you use a relative path, make sure you run both passes from the same working directory.

### Run the script

From the **compare_source_to_target_and_fixrepodiff** directory (or anywhere, as long as env vars are set):

```bash
./sync-target-from-source.sh
```

Or with a config file that exports the variables above:

```bash
./sync-target-from-source.sh --config /path/to/env.sh
```

**Example config files** in `config_env_examples/`:

| File | Use case |
|------|----------|
| `env_app1_app2_diff_jpds_same_repo_names.sh` | Different Artifactory instances (app1 → app2); **same repo names** on both sides. |
| `env_app1_app2_diff_jpds_diff_repos.sh` | Different instances (app1 → app2); **different repo names** (e.g. `sv-docker-local` → `sv-docker-local-copy`). |
| `env_app2_app3_same_jpd_different_repos.sh` | Same instance (app2 → app3); **different repo names** per pair. |
| `env_app2_app3_same_jpd_different_repos_test_underscore.sh` | Same instance; target repos use `_` prefix naming convention. |
| `env_app2_app3_same_jpd_different_repos_test_one_underscore.sh` | Same instance; target repos use single `_` prefix naming convention. |
| `env_app2_app3_same_jpd_different_repos_npm_folder-crawl.sh` | Same instance; **npm remote-cache** repos, default (folder) crawl. Use with `--include-remote-cache`. |
| `env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh` | Same instance; **npm remote-cache** repos, sha1-prefix crawl. Use with `--include-remote-cache --aql-style sha1-prefix`. |

Copy one as a template, edit URLs, authorities, and repo lists, then run with `--config <your-file>.sh`.

### Recommended workflow: two-pass with verification

The recommended usage is the **two-pass** approach — generate scripts, review them, then execute — followed by a verification run into a separate output directory to confirm convergence:

```bash
# Optional: fast generate-only for artifact sync scripts only (03/04),
# skipping the expensive stats/properties folder crawl (no 05/06):
bash sync-target-from-source.sh \
  --config config_env_examples/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit

# Pass 1: generate before-upload scripts (01–06) for review
bash sync-target-from-source.sh \
  --config config_env_examples/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit

# Pass 2: execute generated scripts, run after-upload compare, and run 07–09
bash sync-target-from-source.sh \
  --config config_env_examples/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --run-only --include-remote-cache --run-folder-stats --run-delayed  --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit

# Verification: re-run into a separate output dir to confirm convergence
# (use a config with a different RECONCILE_BASE_DIR, e.g. pointing to a run2 directory)
bash sync-target-from-source.sh \
  --config test/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit

```

After the verification run, the generated scripts (`03_to_sync.sh`, `05_to_sync_stats.sh`, etc.) should have zero or near-zero lines, confirming that source and target are in sync.

### One-shot run (single command)

If you don't need to review the generated scripts before execution, you can run everything end-to-end in a single command by omitting both `--generate-only` and `--run-only`:

```bash
bash sync-target-from-source.sh \
  --config config_env_examples/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --include-remote-cache --run-folder-stats --run-delayed --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

This runs all steps in sequence:
1. **Step 2:** Compare source and target (generates scripts `01`–`06`)
2. **Step 3:** Execute before-upload scripts (`01`–`06`, including `04` when `--run-delayed` is used)
3. **Step 4:** After-upload compare (generates scripts `07`–`09`)
4. **Step 5:** Execute after-upload scripts (`07`–`09`, including `09` when `--run-folder-stats` is used)
5. **Step 6:** Post-sync verification — runs `verify-comparison-db.sh` to query `comparison.db` and display exclusion rules, repo mapping, reason-category counts, and a per-repo breakdown of missing files, delay files, and excluded files

> **Tip:** `--include-remote-cache` is harmless for non-remote repos (LOCAL, FEDERATED) — the flag is only checked for REMOTE-type repos and silently ignored otherwise. You can include it consistently across all your commands.

> **Logging:** To capture the full output of `sync-target-from-source.sh` (including debug AQL queries and timing) to a log file while still seeing it on screen, append `2>&1 | tee <logfile>`:
>
> ```bash
> bash sync-target-from-source.sh --config myenv.sh --generate-only 2>&1 | tee sync-output.log
> ```

---

## Options

| Option | Description |
|--------|-------------|
| `--config <file>` | Source `<file>` before running (e.g. a script that exports COMPARE_* and repo vars). |
| `--generate-only` | Run before-upload compare (Step 2) to generate scripts 01–06 but do **not** execute any of them. Prints a summary and exits. Use `--run-only` later to execute. Mutually exclusive with `--run-only`. |
| `--run-only` | Skip before-upload compare (Step 2); execute previously generated scripts (Steps 3–5). The output directory must already contain scripts from a prior `--generate-only` run. Mutually exclusive with `--generate-only`. |
| `--skip-consolidation` | Do not run `01_to_consolidate.sh` or `02_to_consolidate_props.sh`. |
| `--run-delayed` | Run `04_to_sync_delayed.sh`. By default it is skipped (delayed manifests are often created by the stats sync). |
| `--run-folder-stats` | Run `09_to_sync_folder_stats_as_properties.sh` in the after-upload phase (default: skip). |
| `--skip-collect-stats-properties` | Skip the `jf compare list --collect-stats --collect-properties` crawl in Steps 2 and 4. Only scripts 03/04 are generated; 05/06 (and 07–09) are skipped. Useful with `--generate-only` when you only need the artifact sync scripts and want to avoid the expensive folder crawl. |
| `--max-parallel <N>` | Max concurrent commands when running reconciliation scripts (default: 10). |
| `--aql-style <style>` | AQL crawl style for `jf compare list` (e.g. `sha1-prefix`). Passed to `compare-and-reconcile.sh`. Also settable via env `COMPARE_AQL_STYLE`. |
| `--aql-page-size <N>` | AQL page size for `jf compare list` (default 500). Larger values (e.g. 5000) reduce round trips for large repos. Passed to `compare-and-reconcile.sh`. Also settable via env `COMPARE_AQL_PAGE_SIZE`. |
| `--folder-parallel <N>` | Parallel workers for folder crawl in `sha1-prefix` mode (default 4). Useful for large Docker repos with many `sha256:` folders. Passed to `compare-and-reconcile.sh`. Also settable via env `COMPARE_FOLDER_PARALLEL`. |
| `--include-remote-cache` | Include remote-cache repos (e.g. `npmjs-remote-cache`) in the crawl. Required when repos are remote-cache type; without it they are silently excluded. Passed to `compare-and-reconcile.sh`. Also settable via env `COMPARE_INCLUDE_REMOTE_CACHE=1`. |
| `--sha1-resume <pairs>` | Resume a failed sha1-prefix crawl. `<pairs>` is comma-separated `prefix:offset` (e.g. `f2:40000,f3:40000`). Skips `init --clean` to preserve existing `comparison.db`. See [03-README-troubleshooting-crawl-errors.md](03-README-troubleshooting-crawl-errors.md). Also settable via env `COMPARE_SHA1_RESUME`. |
| `--sha1-resume-authority <id>` | Scope `--sha1-resume` to a single authority. Only the named authority is re-crawled; the other is skipped entirely (its data is already in `comparison.db`). When omitted, `--sha1-resume` applies to all authorities. Also settable via env `COMPARE_SHA1_RESUME_AUTHORITY`. |
| `--collect-stats-for-uris <file>` | Collect stats and properties only for the URIs listed in `<file>` (one per line) and their derived parent folders, instead of a full repo re-crawl. Skips `init --clean` to preserve existing `comparison.db`. Use after a `--generate-only` pass to collect targeted stats for scripts 05–09. Can be combined with `--sha1-resume-authority` to scope to a single authority. Also settable via env `COMPARE_COLLECT_STATS_FOR_URIS`. |
| `--verification-csv [dir]` | Write CSV report files during Step 6 verification (one file per section per repo). If `<dir>` is omitted, defaults to `RECONCILE_BASE_DIR`. CSV files always contain the full data (no row limit). Passed to `verify-comparison-db.sh --csv`. |
| `--verification-no-limit` | Show all files in verification output (Step 6) instead of the default first 20 per section. Passed to `verify-comparison-db.sh --no-limit`. |
| `-h`, `--help` | Show usage and exit. |

---

## Output directories

By default, both before-upload and after-upload outputs live under the **script’s directory**:

- **`b4_upload/`** — Before-upload scripts (01–06) and their success/failure logs.
- **`after_upload/`** — After-upload scripts (07–09) and their logs.

To use a different base directory (e.g. your project folder):

```bash
export RECONCILE_BASE_DIR="/path/to/my/project"
./sync-target-from-source.sh
```

Then scripts and logs are under `/path/to/my/project/b4_upload/` and `/path/to/my/project/after_upload/`.

---

## Command audit logs

Each run of **compare-and-reconcile.sh** writes a **command-audit log** (e.g. `compare-and-reconcile-command-audit-YYYYMMDD-HHMMSS.log`) listing every `jf compare` command executed: init, authority-add, credentials-add, list (per side), optional sync-add (when source and target repo names differ), and report. Use these logs to verify the sequence and to replay or debug.

**Example audit log directories** in this repo (for reference only; paths and timestamps will differ when you run locally):

| Directory | Scenario | What the audit shows |
|-----------|----------|----------------------|
| **compare-and-reconcile-command-audit-diff_jpds_same_repo_names/** | Different Artifactory instances (app1 → app2), **same repo names** on both sides | init, authority-add and list for app1 and app2 with the same `--repos=...`, then report commands. No `sync-add` because repo names match. |
| **compare-and-reconcile-command-audit-same_jpd_diff_repo_names/** | Same Artifactory instance (app2 → app3), **different repo names** (e.g. `sv-docker-local` → `sv-docker-local-copy`) | init, authority-add, list for each side with their own repo lists, then **sync-add** for each source→target repo pair, then report commands. |

When using **sync-target-from-source.sh**, the before-upload run writes its audit log under your output base (e.g. `b4_upload/` or `RECONCILE_BASE_DIR/b4_upload/`); the after-upload run writes a separate audit log (e.g. under `after_upload/`). Log file names are printed at the start of each compare-and-reconcile run.

---

## After the script finishes

- Inspect failure logs in `b4_upload/*_out.txt` and `after_upload/*_out.txt` for any failed commands.
- Verify from the target (e.g. **01-QUICKSTART.md Step 6**): Docker insecure registries, `docker login`, `docker pull` from the target.
- **Re-run verification queries** at any time using the standalone script (no need to re-run the full sync):

```bash
bash verify-comparison-db.sh --source app2 --repos "__infra_local_docker,example-repo-local"
```

Or if the env vars are already set from your config file:

```bash
source config_env_examples/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh
bash verify-comparison-db.sh --source "$SH_ARTIFACTORY_AUTHORITY" --repos "$SH_ARTIFACTORY_REPOS"
```

By default, listings show the first 20 rows per section. To generate a **full report** with all files listed, add `--no-limit`:

```bash
bash verify-comparison-db.sh --source app2 --repos "__infra_local_docker,example-repo-local" --no-limit
```

To also export **CSV files** (one per section per repo, always full data), add `--csv <dir>`:

```bash
bash verify-comparison-db.sh --source app2 --repos "__infra_local_docker,example-repo-local" --no-limit --csv verification_csv
```

These flags can also be passed through `sync-target-from-source.sh` via `--verification-no-limit` and `--verification-csv [dir]` (defaults to `RECONCILE_BASE_DIR` when dir is omitted).

See [README-verify-comparison-db.md](README-verify-comparison-db.md) for full options and examples.

---

## Diagnosing missing file types with --generate-only

The `--generate-only` flag is useful not only for reviewing scripts before execution, but also for **diagnosing why artifacts failed to transfer** via `jf rt transfer-files` or Artifactory push replication. The generated `03_to_sync.sh` (missing files) and `04_to_sync_delayed.sh` (delayed files), along with the CSV report, show exactly which artifacts are in the source but not in the target.

To determine the **file extensions** of the missing artifacts:

```bash
grep -oE '\.[A-Za-z0-9]+\" \"/tmp/' b4_upload/03_to_sync.sh \
  | sed 's/" "\/tmp\///' \
  | sort \
  | uniq -c \
  | sort -nr
```

For example, if the source repository is a Maven repository and the output shows:

```
12130 .nupkg
  367 .zip
   69 .h
    2 .lib
    2 .dll
    1 .exe
    1 .cnf
    1 .c
```

This reveals that the missing artifacts are **not Maven artifacts** (e.g. `.nupkg`, `.dll`, `.exe`). This is a common reason why `jf rt transfer-files` or Artifactory push replication could not transfer them — the target Maven repository may reject artifacts with non-Maven extensions. The same command can be applied to `04_to_sync_delayed.sh` to inspect delayed files.

If after reviewing the generated scripts and CSV reports you decide you **do want to transfer these files**, proceed with:

- **Two-pass approach:** `bash sync-target-from-source.sh --config <file> --run-only --include-remote-cache --run-folder-stats --run-delayed ...`
- **One-shot approach:** `bash sync-target-from-source.sh --config <file> --include-remote-cache --run-folder-stats --run-delayed ...`

The `--run-delayed` flag ensures `04_to_sync_delayed.sh` is executed, and `--run-folder-stats` includes folder stats reconciliation.

---

## Verifying that missing artifacts exist in the source

If `03_to_sync.sh` lists artifacts and someone claims those files do not exist in the source repository, you can prove they exist by querying `comparison.db`. The `artifacts` table is populated by AQL queries against the Artifactory instance — if a row exists with the source authority, Artifactory's AQL API returned it during the crawl.

**Check if a specific artifact exists in the source crawl:**

```bash
jf compare query "SELECT source, repository_name, uri, sha1, sha2, size, row_created_at, created, modified FROM artifacts WHERE source = '<source-authority>' AND repository_name = '<repo>' AND uri LIKE '%<filename>'"
```

Or with `sqlite3`:

```bash
sqlite3 -header -column comparison.db "
SELECT source, repository_name, uri, sha1, sha2, size , row_created_at, created, modified
FROM artifacts
WHERE source = '<source-authority>'
  AND repository_name = '<repo>'
  AND uri LIKE '%<filename>';
"
```
Note: In the Jfrog UI Tree view the “Created” and “Last Modified” time for an artifact is in `YYYYMMDD HH:MM:SS UTC`
The row_created_at in the sqlite DB is also  in the same format.

**Verify it is in the `missing` view (source has it, target does not):**

```bash
jf compare query "SELECT source, source_repo, target, target_repo, path, sha1_source, size_source FROM missing WHERE source = '<source-authority>' AND path LIKE '%<filename>'"
```

**Count all files with a specific extension in the source crawl:**

```bash
sqlite3 -header -column comparison.db "
SELECT COUNT(*) AS nupkg_count
FROM artifacts
WHERE source = '<source-authority>'
  AND repository_name = '<repo>'
  AND uri LIKE '%.nupkg';
"
```

**Verify directly via the Artifactory API:**

```bash
jf rt curl "/api/storage/<repo>/<path-to-file>" --server-id=<source-authority>
```

> **Tip:** You can also search for artifacts using AQL via `jf rt s`. For example, to check if there are any artifacts under a specific path:
>
> ```bash
> tmp="$(mktemp)" && cat > "$tmp" <<'EOF'
> {
>   "files": [
>     {
>       "pattern": "claims-maven-dev-custom/repositories/**/*",
>       "type": "file"
>     }
>   ]
> }
> EOF
> jf rt s --spec "$tmp" --server-id=source-server; rm -f "$tmp"
> ```
>
> If the artifacts are not found, check whether they were deleted and moved to the **trashcan**:
>
> ```bash
> tmp="$(mktemp)" && cat > "$tmp" <<'EOF'
> {
>   "files": [
>     {
>       "pattern": "auto-trashcan/**/Commercial.AccountInfo.Process.Models.1.0.53-beta.61859.nupkg",
>       "type": "file"
>     }
>   ]
> }
> EOF
> jf rt s --spec "$tmp" --server-id=source-server; rm -f "$tmp"
> ```
>
> Replace the pattern and `--server-id` with your actual repo path and authority name.

---

## Diagnosing artifact count discrepancies with the crawl audit log

Each `jf compare list` invocation produces a **crawl audit log** (e.g. `crawl-audit-<authority>-<timestamp>.log`) in the `RECONCILE_BASE_DIR` alongside `comparison.db`. This log captures per-prefix file/folder summaries, AQL errors, and an overall crawl summary.

**Quick check for errors:**

```bash
grep ERROR "$RECONCILE_BASE_DIR"/crawl-audit-*.log
```

Common errors include `EOF` (connection closed by server), `TLS handshake timeout`, `HTTP 500`, and `connection reset by peer`. These are transient network/server errors that cause the crawl to stop paginating a specific SHA1 prefix, silently dropping artifacts from `comparison.db`.

**Mitigation options:**

1. **Reduce concurrency** — lower `--folder-parallel` (e.g. 16 → 4)
2. **Reduce page size** — lower `--aql-page-size` (e.g. 5000 → 2000)
3. **Re-run the crawl** — transient errors often don't recur
4. **Use folder-based crawl** — omit `--aql-style sha1-prefix` to crawl per-repo per-folder instead of by SHA1 prefix, which produces smaller per-query result sets and is more resilient to timeouts

For detailed error explanations, impact analysis, verification queries, and mitigation examples, see [03-README-troubleshooting-crawl-errors.md](03-README-troubleshooting-crawl-errors.md).

**Comparing runs:** see the crawl audit log header (`collect_stats`, `collect_props`) and diff commands in the [troubleshooting guide](03-README-troubleshooting-crawl-errors.md).

**Example crawl audit log** (`crawl-audit-app3-20260225-143012.log`):
The sv-docker-local repo contains 4,500 files and 5,199 folders. The crawl audit log shows 5,200 folders because it includes the root folder (/) in the count.

```
=== Crawl Audit Log ===
authority:        app3
style:            sha1-prefix
repos:            [sv-docker-local]
page_size:        500
collect_stats:    true
collect_props:    true
sha1_prefix_len:  2
sha1_parallel:    16
folder_parallel:  4
started_at:       2026-02-25T14:30:12-05:00
[sha1-prefix files]  prefix=00  items=12  pages=1  final_offset=12
[sha1-prefix files]  prefix=01  items=0  pages=0  final_offset=0
..
[sha1-prefix files]  ERROR  prefix=a8 offset=1500: HTTP 500: AQL query execution timeout
[sha1-prefix files]  ERROR  prefix=a8 offset=1500 read: connection reset by peer
...
[sha1-prefix files]  SUMMARY  items=4500  pages=45  final_offset=18000  prefix_range=00..ff
[sha1-prefix folders]  repo=sv-docker-local prefix=sha256:0  items=325  pages=3  final_offset=1300
...
[sha1-prefix folders]  SUMMARY  items=5200  pages=52  final_offset=20800  repos=1  workers=4
=== Crawl Complete ===
elapsed:  3m 42.15s
errors:   2
```

**Key observations for multi-repo crawls:**

- **sha1-prefix files** — entries are per-prefix, not per-repo. The AQL query scans all repos at once, so each prefix (e.g. `prefix=00`) shows the combined item count across both repos.
- **sha1-prefix folders** — entries are per-repo per-prefix, sorted alphabetically by repo, then by prefix.
- **Diffing two runs** — the sorted order is deterministic regardless of worker parallelism.

For a full multi-repo example, see the [troubleshooting guide](03-README-troubleshooting-crawl-errors.md).

---

## Retargeting sync scripts to a different repository

After running `--generate-only` to produce before-upload scripts (03–06) for source → target-A, you may want to sync the same artifacts to a **different target repo** (target-B) without re-running the full compare workflow. The `retarget-sync-scripts.sh` helper copies and rewrites the generated scripts so they upload to the new target, then prints step-by-step guidance for completing the after-upload phase (07–09).

**Step 1 — Rewrite scripts:**

```bash
bash retarget-sync-scripts.sh \
  --source-dir "$RECONCILE_BASE_DIR" \
  --target-dir /path/to/new/reconcile-dir \
  --old-repo "$CLOUD_ARTIFACTORY_REPOS" \
  --new-repo my-other-repo
```

This copies `03_to_sync.sh`, `04_to_sync_delayed.sh`, `05_to_sync_stats.sh`, and `06_to_sync_folder_props.sh` from `<source-dir>/b4_upload/` to `<target-dir>/b4_upload/`, replacing every occurrence of the old target repo name with the new one. If the target Artifactory authority also changes, add `--old-server-id` and `--new-server-id` (only the upload-side server-id is replaced in 03/04; the download/source side is left untouched).

**Step 2 — Create a new config file** (e.g. `env_retarget.sh`):

```bash
# Copy from your original config, then change these lines:
export CLOUD_ARTIFACTORY_REPOS="my-other-repo"
export RECONCILE_BASE_DIR="/path/to/new/reconcile-dir"
# Keep all other env vars (SH_ARTIFACTORY_*, COMPARE_*, etc.) the same.
```

**Step 3 — Run with `--run-only`:**

```bash
bash sync-target-from-source.sh \
  --config env_retarget.sh \
  --run-only --skip-consolidation \
  --include-remote-cache  --run-delayed --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \ 
  --verification-csv --verification-no-limit
```

`--run-only` skips Step 2 (before-upload compare) since the rewritten scripts already exist in `b4_upload/`. It proceeds with:

- **Step 3:** Execute before-upload scripts (03–06) — uploads to `my-other-repo`
- **Step 4:** After-upload compare against `my-other-repo`
- **Step 5:** Generate and execute after-upload scripts (07–09)
- **Step 6:** Post-sync verification

Use `--aql-style`, `--aql-page-size`, `--folder-parallel`, `--include-remote-cache` as needed (same values as your original run).
Do not use the  `--run-folder-stats` as it may be huge. Review the generated `after_upload/09_to_sync_folder_stats_as_properties.sh` and run it separately if necessary using below steps:
```
cd /path/to/your/RECONCILE_BASE_DIR/after_upload

bash /path/to/runcommand_in_parallel_from_file.sh \
  --log-success \
  ./09_to_sync_folder_stats_as_properties.sh \
  ./09_to_sync_folder_stats_as_properties_out.txt \
  16
```

> **Note:** `--skip-consolidation` is recommended because the retargeted `b4_upload/` does not contain 01/02 consolidation scripts. `--run-delayed` ensures `04_to_sync_delayed.sh` is executed.

See [README-retarget-sync-scripts.md](README-retarget-sync-scripts.md) for full documentation.

---

## Relation to manual QUICKSTART

- **Manual:** You run Steps 1–5 yourself (set env, run compare-and-reconcile twice, run each generated script with `runcommand_in_parallel_from_file.sh`).
- **Two-pass:** Use `--generate-only` to generate scripts, review them, then `--run-only` to execute.
- **One-shot:** You set env (or `--config`) once and run `./sync-target-from-source.sh`; it performs Steps 2–6 for you.

For more control (e.g. running only some scripts or changing order), use the manual flow in [01-QUICKSTART.md](01-QUICKSTART.md).
