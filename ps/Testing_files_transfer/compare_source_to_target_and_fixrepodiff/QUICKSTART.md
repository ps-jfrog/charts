# Quickstart: Sync Target Artifactory to Match Source (Compare Plugin)

This guide walks you through using **compare-and-reconcile.sh** with the JFrog **compare plugin** to sync target Artifactory repositories so they match the source. The workflow has two phases: **before upload** (binaries, stats, folder props) and **after upload** (download stats, properties, folder stats as properties).

---

## Prerequisites

- **JFrog CLI** with the **compare plugin** (`jf compare`) installed and on your PATH.
- **CLI profiles** for source and target Artifactory (e.g. `app1` = source, `app2` = target).
- **jq** (required when using `--reconcile`).

### Optional: Build and install the compare plugin from source

If you need to build the plugin yourself:

```bash
# Build
go build -o compare main.go

# Clean plugin dirs (adjust paths to your JFrog CLI plugin location)
find ~/.jfrog/plugins/compare/resources -mindepth 1 -delete
find ~/.jfrog/plugins/compare/bin -mindepth 1 -delete

# Install
cp compare ~/.jfrog/plugins/compare/bin/
cp -R resources/* ~/.jfrog/plugins/compare/resources/

# Verify
jf compare -v
# Example output: compare version v2025.45.05
```

---

## Scenario: Artifactory SH (source) → Artifactory Cloud (or SH) (target)

- **Source** = Artifactory SH (`app1`).
- **Target** = Artifactory Cloud or SH (`app2`).
- **Goal:** One-way sync so the **target** matches the **source** (target-only reconciliation).

---

## Step 1: Set environment variables

From the **compare_source_to_target_and_fixrepodiff** directory (or set `RECONCILE_OUTPUT_DIR` to an absolute path), set the required variables. Adjust URLs and server IDs to your environment.

```bash
cd /path/to/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff

# Scenario: Artifactory SH as source, Artifactory Cloud (or SH) as target
export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="http://<source-host>/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export CLOUD_ARTIFACTORY_BASE_URL="http://<target-host>/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_aql"
export RECONCILE_OUTPUT_DIR="$(pwd)/test_reconcile_target_only_b4_upload"

# Optional: limit to specific repositories (comma-separated)
export SH_ARTIFACTORY_REPOS="sv-docker-local,example-repo-local"
export CLOUD_ARTIFACTORY_REPOS="sv-docker-local,example-repo-local"
```

---

## Step 2: Run compare-and-reconcile (before-upload mode)

Generate reconciliation scripts for the **before-upload** flow (sync binaries, delayed artifacts, stats, folder properties):

```bash
./compare-and-reconcile.sh --b4upload --collect-stats-properties --reconcile --target-only
```

- **--b4upload** — Use views for before-upload (sync, delayed, stats, folder props).
- **--collect-stats-properties** — Collect stats and properties on target (needed for reconciliation).
- **--reconcile** — Generate the `01_*` … `06_*` scripts.
- **--target-only** — Keep only commands that update the **target** (one-way sync).

Scripts are written to `RECONCILE_OUTPUT_DIR` (e.g. `test_reconcile_target_only_b4_upload/`).

---

## Step 3: Run the before-upload reconciliation scripts

Change into the output directory. From there, run the generated scripts using **runcommand_in_parallel_from_file.sh** from the parent directory (so use `../runcommand_in_parallel_from_file.sh`).

```bash
cd test_reconcile_target_only_b4_upload
```

**Sync binaries (download from source, upload to target):**

```bash
../runcommand_in_parallel_from_file.sh --log-success ./03_to_sync.sh ./03_to_sync_out.txt 10
```

**Skip Sync delayed binaries (e.g. manifest files):**

```bash
../runcommand_in_parallel_from_file.sh --log-success ./04_to_sync_delayed.sh ./04_to_sync_delayed_out.txt 10
```

You can skip `04_to_sync_delayed.sh` : delayed manifest files are often created when you run the stats sync below.

**Sync stats (file statistics); after this you typically see delayed manifest files in Docker repos:**

```bash
../runcommand_in_parallel_from_file.sh --log-success ./05_to_sync_stats.sh ./05_to_sync_stats_out.txt 10
```

**Sync folder properties:**

```bash
../runcommand_in_parallel_from_file.sh --log-success ./06_to_sync_folder_props.sh ./06_to_sync_folder_props_out.txt 10
```

Run `01_to_consolidate.sh` and `02_to_consolidate_props.sh` first if your scenario requires consolidation (see script comments and README).

---

## Step 4: Run compare-and-reconcile (after-upload mode)

After binaries and stats are uploaded, go back to the **compare_source_to_target_and_fixrepodiff** directory and run the script in **after-upload** mode to generate scripts for download stats, properties, and folder stats as properties:

```bash
cd /path/to/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff
export RECONCILE_OUTPUT_DIR="$(pwd)/test_reconcile_target_only_after_upload"

./compare-and-reconcile.sh --after-upload --collect-stats-properties --reconcile --target-only
```

---

## Step 5: Run the after-upload reconciliation scripts

```bash
cd test_reconcile_target_only_after_upload
```

**Sync download stats (downloadCount, lastDownloaded, etc.):**

```bash
../runcommand_in_parallel_from_file.sh --log-success ./07_to_sync_download_stats.sh ./07_to_sync_download_stats_out.txt 10
```

**Sync properties:**

```bash
../runcommand_in_parallel_from_file.sh --log-success ./08_to_sync_props.sh ./08_to_sync_props_out.txt 10
```

**Sync folder stats as folder-level properties** (sync.* properties applied only to the folder, not recursively):

```bash
../runcommand_in_parallel_from_file.sh --log-success ./09_to_sync_folder_stats_as_properties.sh ./09_to_sync_folder_stats_as_properties_out.txt 10
```

---

## Step 6: Verify from target Artifactory

**Docker: insecure registries (if target is HTTP)**

If the target Artifactory Docker registry is insecure, add it to Docker’s `insecure-registries` (e.g. in `~/.docker/daemon.json` on macOS or `/etc/docker/daemon.json`):

```json
{
  "insecure-registries": [
    "http://<target-host>:80",
    "http://<source-host>:80"
  ]
}
```

Restart the Docker daemon, then log in:

```bash
docker login <target-host>:80
```

**List and pull from target**

```bash
# List Docker repos on target
jf rt curl "/api/docker/sv-docker-local/v2/_catalog" --server-id=app2

# Pull an image from the target
docker pull <target-host>:80/sv-docker-local/<repo>:<tag>
```

If sync completed successfully, pulls from the target should match what you had on the source.

---

## Command audit logs

**compare-and-reconcile.sh** writes a **command-audit log** (e.g. `compare-and-reconcile-command-audit-YYYYMMDD-HHMMSS.log`) for each run, listing every `jf compare` command it executes: init, authority-add, credentials-add, list (per side), optional sync-add (when source and target repo names differ), and report. Use these logs to verify the sequence or to debug.

**Example audit log directories** in this repo (reference only):

| Directory | Scenario | What the audit shows |
|-----------|----------|----------------------|
| **compare-and-reconcile-command-audit-diff_jpds_same_repo_names/** | Different instances (app1 → app2), **same repo names** | init, authority-add, list for app1 and app2 with the same `--repos=...`, then report. No `sync-add`. |
| **compare-and-reconcile-command-audit-same_jpd_diff_repo_names/** | Same instance (app2 → app3), **different repo names** | init, authority-add, list per side with their own repo lists, then **sync-add** for each source→target repo pair, then report. |

---

## Script reference

| Script | Purpose |
|--------|--------|
| **compare-and-reconcile.sh** | Compare source vs target and generate reconciliation scripts. Requires **--b4upload** or **--after-upload**. |
| **runcommand_in_parallel_from_file.sh** | Run commands from a file in parallel; `--log-success` logs successful commands; args: `<command_file> <failure_log_file> <max_parallel>`. |
| **sync-target-from-source.sh** | One-shot: run Steps 2–5 for you (compare b4-upload → run 01–06 → compare after-upload → run 07–09). Set env vars (Step 1) then run; see [README-sync-target-from-source.md](README-sync-target-from-source.md). |

---

## One-shot option

To run the full sync without executing each step manually, set the required environment variables (Step 1) and then:

```bash
./sync-target-from-source.sh
```

Or with a config file: `./sync-target-from-source.sh --config env.sh`. See [README-sync-target-from-source.md](README-sync-target-from-source.md) for options (`--skip-consolidation`, `--run-delayed`, `--max-parallel`, `--aql-style`) and output directories.

### Example one-shot runs with config files

Example environment config files are in [`config_env_examples/`](config_env_examples/). Each file sets source/target URLs, authorities, repo lists, and discovery method for a specific scenario.

**Default AQL style (repo-based crawl):**

```bash
# Different JPDs, same repo names
bash sync-target-from-source.sh --config config_env_examples/env_app1_app2_diff_jpds_same_repo_names.sh

# Different JPDs, different repo names (target uses underscore repos)
bash sync-target-from-source.sh --config config_env_examples/env_app1_app2_diff_jpds_diff_repos.sh

# Same JPD, different repo names (underscore target repos)
bash sync-target-from-source.sh --config config_env_examples/env_app2_app3_same_jpd_different_repos_test_underscore.sh
```

**AQL style `sha1-prefix` (SHA1-prefix crawl):**

```bash
bash sync-target-from-source.sh --config config_env_examples/env_app1_app2_diff_jpds_same_repo_names.sh --aql-style sha1-prefix

bash sync-target-from-source.sh --config config_env_examples/env_app1_app2_diff_jpds_diff_repos.sh --aql-style sha1-prefix

bash sync-target-from-source.sh --config config_env_examples/env_app2_app3_same_jpd_different_repos_test_underscore.sh --aql-style sha1-prefix
```

> **Note:** `--run-delayed` is optional and usually not needed. `05_to_sync_stats.sh` creates Docker manifests via checksum-deploy, which implicitly creates parent folders. Use `--run-delayed` only if you want to explicitly run `04_to_sync_delayed.sh` before the stats sync.

---

## Summary flow

1. Set env vars (source/target URLs, authorities, repos).
2. **Before upload:** `./compare-and-reconcile.sh --b4upload --collect-stats-properties --reconcile --target-only` → run 03, 04 (optional), 05, 06 (and 01, 02 if needed).
3. **After upload:** Set `RECONCILE_OUTPUT_DIR` to a new dir; `./compare-and-reconcile.sh --after-upload --collect-stats-properties --reconcile --target-only` → run 07, 08, 09.
4. Verify with `docker pull` or other clients against the target.

For more options and environment variables, run:

```bash
./compare-and-reconcile.sh --help
```
