# compare-and-reconcile.sh

Compare artifacts between Nexus / Artifactory SH / Artifactory Cloud, optionally collect stats and properties, and generate **phased reconciliation scripts** for binaries, properties, and statistics. Uses `jf compare` (jfrog-cli-plugin-compare).

## Prerequisites

- **JFrog CLI** with the compare plugin (`jf compare`).
- **CLI profiles** for Artifactory (e.g. `app1`, `app2`) configured.
- For Nexus source: `NEXUS_ADMIN_TOKEN` or `NEXUS_ADMIN_USERNAME` / `NEXUS_ADMIN_PASSWORD`; if using a repo list file, `NEXUS_RUN_ID`.
- **sqlite3** (optional): for CSV mismatch report.
- **jq** (required if using `--reconcile`): to generate reconciliation shell scripts.

## Quick start

1. Set scenario and required env vars (same as [compare-artifacts.sh](../compare_source_to_target/compare-artifacts.sh)).
2. Optionally set `ARTIFACTORY_REPOS="repo1,repo2"` (or `CLOUD_ARTIFACTORY_REPOS` / `SH_ARTIFACTORY_REPOS` for the target side).
3. Run compare only:
   ```bash
   ./compare-and-reconcile.sh
   ```
4. Or compare + collect stats/properties + generate reconcile scripts (one-way to target only):
   ```bash
   ./compare-and-reconcile.sh --collect-stats-properties --reconcile --target-only
   ```

## Minimal command checklist

1. Set scenario env vars (Case a/b/c), plus optional `ARTIFACTORY_REPOS`.
2. For binaries + properties + statistics reconciliation:
   ```bash
   export ARTIFACTORY_DISCOVERY_METHOD="artifactory_aql"
   ./compare-and-reconcile.sh --collect-stats-properties --reconcile --target-only
   ```
3. Run **before-upload** compare, then run scripts 01–06 (see [QUICKSTART.md](QUICKSTART.md) for full steps):
   ```bash
   ./compare-and-reconcile.sh --b4upload --collect-stats-properties --reconcile --target-only
   # Then run 01–02 if consolidation needed; then 03, 04 (optional), 05, 06
   ./03_to_sync.sh             # binaries: sync to target
   ./04_to_sync_delayed.sh     # optional: delayed binaries (e.g. manifest.json)
   ./05_to_sync_stats.sh       # file stats (checksum deploy)
   ./06_to_sync_folder_props.sh
   ```
4. Run **after-upload** compare, then run scripts 07–09:
   ```bash
   ./compare-and-reconcile.sh --after-upload --collect-stats-properties --reconcile --target-only
   ./07_to_sync_download_stats.sh
   ./08_to_sync_props.sh
   ./09_to_sync_folder_stats_as_properties.sh
   ```

## Options

| Option | Description |
|--------|-------------|
| `--collect-stats-properties` | After compare, run `jf compare list` with `--collect-stats --collect-properties` on the target. In Case a (SH→Cloud), also runs `jf compare list` with `--collect-properties` on the source (SH) so property sync views use source=SH, target=Cloud and scripts 06/08 can be non-empty. **Only valid when `ARTIFACTORY_DISCOVERY_METHOD=artifactory_aql`.** |
| `--reconcile` | After compare (and optional collect), generate the phased reconciliation scripts (`01_to_consolidate.sh` … `09_to_sync_folder_stats_as_properties.sh`) in the current directory (or `RECONCILE_OUTPUT_DIR`). Scripts are numbered in run order. **Before-upload** (`--b4upload`): 01–06. **After-upload** (`--after-upload`): 07–09 (and 01–02 for consistency). |
| `--target-only` | With `--reconcile`: keep only commands that update the **target** instance (e.g. app2). One-way sync so that target matches source; commands that would update the source are dropped. When `CLOUD_ARTIFACTORY_REPOS` or `ARTIFACTORY_REPOS` is set, generated scripts are also restricted to those repos only. |
| `--aql-style <style>` | AQL crawl style for `jf compare list` (e.g. `sha1-prefix`). If not set, uses the default repo-based crawl. Useful for large repos. Also settable via env `COMPARE_AQL_STYLE`. |
| `--aql-page-size <N>` | AQL page size for `jf compare list` (default 500). Larger values (e.g. 5000) reduce round trips for large repos. Also settable via env `COMPARE_AQL_PAGE_SIZE`. |
| `--folder-parallel <N>` | Parallel workers for folder crawl in `sha1-prefix` mode (default 4). Useful for large Docker repos with many `sha256:` folders. Also settable via env `COMPARE_FOLDER_PARALLEL`. |
| `--include-remote-cache` | Include remote-cache repos (e.g. `npmjs-remote-cache`) in the crawl. Required when `--repos` names a remote-cache repo; without it the plugin's repo-type filter silently excludes them. Also settable via env `COMPARE_INCLUDE_REMOTE_CACHE=1`. |
| `-h`, `--help` | Show help. |

**Environment:**  
`COLLECT_STATS_PROPERTIES=1` and `RECONCILE=1` are equivalent to the flags above.  
`RECONCILE_TARGET_ONLY=1` is equivalent to `--target-only`.  
`RECONCILE_OUTPUT_DIR=<dir>` sets where `to_*.sh` are written (default: current directory).  
`COMPARE_AQL_STYLE=<style>` is equivalent to `--aql-style` (e.g. `sha1-prefix`).  
`COMPARE_AQL_PAGE_SIZE=<N>` is equivalent to `--aql-page-size` (e.g. `5000`).  
`COMPARE_FOLDER_PARALLEL=<N>` is equivalent to `--folder-parallel` (e.g. `16`). Only applies in `sha1-prefix` mode.  
`COMPARE_INCLUDE_REMOTE_CACHE=1` is equivalent to `--include-remote-cache`.

## Scenarios and repository scope

- **Case a)** Artifactory SH → Artifactory Cloud: set `COMPARE_SOURCE_NEXUS=0`, `COMPARE_TARGET_ARTIFACTORY_SH=1`, `COMPARE_TARGET_ARTIFACTORY_CLOUD=1` and the four Artifactory URL/authority vars. Target for reconcile = Cloud.
- **Case b)** Nexus → Artifactory Cloud: set `COMPARE_SOURCE_NEXUS=1`, `COMPARE_TARGET_ARTIFACTORY_SH=0`, `COMPARE_TARGET_ARTIFACTORY_CLOUD=1` and Nexus + Cloud vars. Target = Cloud.
- **Case c)** Nexus → Artifactory SH: set `COMPARE_SOURCE_NEXUS=1`, `COMPARE_TARGET_ARTIFACTORY_SH=1`, `COMPARE_TARGET_ARTIFACTORY_CLOUD=0` and Nexus + SH vars. Target = SH.

**Repositories:**  
- Use **`ARTIFACTORY_REPOS`** to limit the **target** side (and, in Case a, both SH and Cloud when you want the same list).  
- Or use **`SH_ARTIFACTORY_REPOS`** / **`CLOUD_ARTIFACTORY_REPOS`** to limit per instance (e.g. different lists for SH vs Cloud in Case a).  
- If none are set, **all** repositories are compared and reconciled.

## Step-by-step: full binaries, properties, and statistics reconciliation

Follow this workflow to compare, then reconcile **binaries**, **properties**, and **statistics** for specific repos or all repos.

### Step 1: Set scenario and credentials

Choose Case a, b, or c and set the required environment variables (see [compare_source_to_target/README.md](../compare_source_to_target/README.md) or `./compare-and-reconcile.sh --help`).

Example for **Case a** (Artifactory SH → Cloud):

```bash
export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="http://source.example.com/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export CLOUD_ARTIFACTORY_BASE_URL="http://target.example.com/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"
```

### Step 2: (Optional) Restrict to specific repositories

To reconcile only certain repos on the **target**:

```bash
export ARTIFACTORY_REPOS="docker-local,maven-releases"
```

Or, for Case a, you can set different lists per side:

```bash
export SH_ARTIFACTORY_REPOS="repo-a,repo-b"
export CLOUD_ARTIFACTORY_REPOS="repo-a,repo-b"
```

**Different source and target repo names (Case a):** When source and target repos have different names (e.g. source `sv-docker-local`, target `sv-docker-local-copy`), set both `SH_ARTIFACTORY_REPOS` and `CLOUD_ARTIFACTORY_REPOS` with the **same number** of comma-separated repos; they are paired by order (first source with first target, etc.). The script runs `jf compare sync-add` for each pair so Phase 2 reports and reconciliation scripts use the correct mapping. Optional: `COMPARE_SYNC_TYPE` (default `other`) sets the sync type. See [phased-reconciliation-guide.md](../../../../jfrog-cli-plugin-compare/docs/phased-reconciliation-guide.md) section "Different source and target repo names".

Leave these unset to compare and reconcile **all** repositories.

### Step 3: Use AQL discovery for stats/properties and reconciliation

For **properties** and **statistics** reconciliation you need stats and properties collected on the target. That is only supported with AQL discovery:

```bash
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_aql"
```

Use `artifactory_filelist` only if you need a fast compare for binaries and do **not** need `--collect-stats-properties` or full stats/properties reconciliation.

### Step 4: Run compare and generate reconciliation scripts

Run the script with **`--b4upload`** or **`--after-upload`**, plus **collect-stats/properties** and **reconcile**:

1. Source and target are crawled and compared (binaries).
2. Stats and properties are collected on the **target** (required for properties and statistics reconciliation).
3. The corresponding set of reconciliation scripts is generated (01–06 for before-upload, 07–09 for after-upload).

**Before-upload** (sync binaries, stats, folder props):

```bash
./compare-and-reconcile.sh --b4upload --collect-stats-properties --reconcile --target-only
```

**After-upload** (download stats, properties, folder stats as properties) — run after binaries are on the target:

```bash
./compare-and-reconcile.sh --after-upload --collect-stats-properties --reconcile --target-only
```

Outputs:

- **Report:** `report-<scenario>-<timestamp>.csv` (mismatches from `comparison.db`).
- **Scripts** (in current directory or `RECONCILE_OUTPUT_DIR`), numbered in run order. You must use **`--b4upload`** or **`--after-upload`** so the correct set is generated; see [QUICKSTART.md](QUICKSTART.md).

  **Before-upload** (`--b4upload`): 01–06  
  - `01_to_consolidate.sh` — Phase 1: consolidate abnormal repos to normalized repos (same instance).  
  - `02_to_consolidate_props.sh` — Phase 1: properties consolidation.  
  - `03_to_sync.sh` — Phase 2: sync binaries to target (non-delayed only).  
  - `04_to_sync_delayed.sh` — Phase 2: sync delayed artifacts (e.g. list.manifest.json, manifest.json).  
  - `05_to_sync_stats.sh` — File statistics (X-Artifactory headers / checksum deploy).  
  - `06_to_sync_folder_props.sh` — Folder properties sync to target.

  **After-upload** (`--after-upload`): 07–09 (and 01–02 for consistency, often empty)  
  - `07_to_sync_download_stats.sh` — Download stats (downloadCount, lastDownloaded, lastDownloadedBy) via `:statistics` endpoint.  
  - `08_to_sync_props.sh` — Properties sync to target.  
  - `09_to_sync_folder_stats_as_properties.sh` — Folder stats as sync.* custom properties on folders.

**Flow:** Run compare with `--b4upload` → run 01–06. After uploading, run compare with `--after-upload` → run 07–09. See [QUICKSTART.md](QUICKSTART.md).

### Step 5: Run reconciliation in order (before-upload → after-upload)

Execute the generated scripts in numeric order. Use **two compare runs**: first **before-upload** (generates 01–06), then after binaries/stats are on the target, **after-upload** (generates 07–09). See [QUICKSTART.md](QUICKSTART.md) for the full flow.

**Before-upload run** — Generate and run 01–06:

```bash
./compare-and-reconcile.sh --b4upload --collect-stats-properties --reconcile --target-only
```

**Phase 1 – Consolidate (if needed)**  
Fixes abnormal repo layout on the same instance before cross-instance sync.

```bash
./01_to_consolidate.sh
./02_to_consolidate_props.sh
```

**Phase 2 – Sync binaries, delayed, stats, folder props**  
Run in output dir (e.g. `b4_upload/`) with `runcommand_in_parallel_from_file.sh` or directly:

```bash
./03_to_sync.sh             # binaries: sync to target
./04_to_sync_delayed.sh     # optional: delayed artifacts (e.g. manifest.json)
./05_to_sync_stats.sh       # file stats (checksum deploy)
./06_to_sync_folder_props.sh
```

**After-upload run** — Generate and run 07–09:

```bash
./compare-and-reconcile.sh --after-upload --collect-stats-properties --reconcile --target-only
```

Then in the after-upload output dir:

```bash
./07_to_sync_download_stats.sh
./08_to_sync_props.sh
./09_to_sync_folder_stats_as_properties.sh
```

If any script is empty (no commands), there is nothing to reconcile for that phase.

### Step 6: (Optional) Inspect the CSV report

Open the timestamped CSV report to see which paths had mismatches and confirm that the reconciled scope matches your chosen repositories (specific repos or all).

---

## Summary: what each phase reconciles

| Phase | Scripts | What is reconciled |
|-------|---------|---------------------|
| **Phase 1** | `01_to_consolidate.sh`, `02_to_consolidate_props.sh` | Binaries and properties that need to be consolidated from abnormal to normalized repos on the **same** instance. |
| **Phase 2 (before-upload)** | `03_to_sync.sh`, `04_to_sync_delayed.sh`, `05_to_sync_stats.sh`, `06_to_sync_folder_props.sh` | Binaries synced to target (03, 04), file stats / checksum deploy (05), folder properties (06). Generated with `--b4upload`. |
| **After-upload** | `07_to_sync_download_stats.sh`, `08_to_sync_props.sh`, `09_to_sync_folder_stats_as_properties.sh` | Download stats, properties sync, folder stats as properties. Generated with `--after-upload`. |

The exact behavior of each view and command comes from the **jfrog-cli-plugin-compare** plugin. For view names and details, refer to that plugin’s documentation.

## See also

- [plan.md](plan.md) — Implementation tasks and workflow reference.
- [compare_source_to_target/compare-artifacts.sh](../compare_source_to_target/compare-artifacts.sh) — Compare-only script and env var reference.
- **jfrog-cli-plugin-compare** — Source for `jf compare` report views and reconciliation commands.
