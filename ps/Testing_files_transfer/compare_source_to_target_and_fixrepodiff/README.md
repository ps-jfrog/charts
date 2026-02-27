# sync-target-from-source.sh — One-shot sync workflow

This script automates **Steps 2 through 6** of [QUICKSTART.md](QUICKSTART.md): it runs the full compare-and-reconcile workflow (before-upload and after-upload), executes all generated reconciliation scripts, and runs post-sync verification queries so that the **target Artifactory matches the source** in one invocation.

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

- Same as [QUICKSTART.md](QUICKSTART.md): JFrog CLI with compare plugin, CLI profiles for source and target (e.g. `app1`, `app2`), `jq`.
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
| `--max-parallel <N>` | Max concurrent commands when running reconciliation scripts (default: 10). |
| `--aql-style <style>` | AQL crawl style for `jf compare list` (e.g. `sha1-prefix`). Passed to `compare-and-reconcile.sh`. Also settable via env `COMPARE_AQL_STYLE`. |
| `--aql-page-size <N>` | AQL page size for `jf compare list` (default 500). Larger values (e.g. 5000) reduce round trips for large repos. Passed to `compare-and-reconcile.sh`. Also settable via env `COMPARE_AQL_PAGE_SIZE`. |
| `--folder-parallel <N>` | Parallel workers for folder crawl in `sha1-prefix` mode (default 4). Useful for large Docker repos with many `sha256:` folders. Passed to `compare-and-reconcile.sh`. Also settable via env `COMPARE_FOLDER_PARALLEL`. |
| `--include-remote-cache` | Include remote-cache repos (e.g. `npmjs-remote-cache`) in the crawl. Required when repos are remote-cache type; without it they are silently excluded. Passed to `compare-and-reconcile.sh`. Also settable via env `COMPARE_INCLUDE_REMOTE_CACHE=1`. |
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
- Verify from the target (e.g. **QUICKSTART.md Step 6**): Docker insecure registries, `docker login`, `docker pull` from the target.
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

## Relation to manual QUICKSTART

- **Manual:** You run Steps 1–5 yourself (set env, run compare-and-reconcile twice, run each generated script with `runcommand_in_parallel_from_file.sh`).
- **Two-pass:** Use `--generate-only` to generate scripts, review them, then `--run-only` to execute.
- **One-shot:** You set env (or `--config`) once and run `./sync-target-from-source.sh`; it performs Steps 2–6 for you.

For more control (e.g. running only some scripts or changing order), use the manual flow in [QUICKSTART.md](QUICKSTART.md).
