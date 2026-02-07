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
3. Run Phase 1, then Phase 2 (binaries: sync + delayed):
   ```bash
   ./01_to_consolidate.sh
   ./02_to_consolidate_props.sh
   ./03_to_sync.sh             # binaries: sync to target
   ./05_to_sync_delayed.sh     # delayed binaries
   ```
4. **Rerun compare** so Phase 2b and Statistics scripts (04, 06–09) are regenerated from the updated target state:
   ```bash
   ./compare-and-reconcile.sh --collect-stats-properties --reconcile --target-only
   ```
5. Run Phase 2b (properties), then Statistics (07–09):
   ```bash
   ./04_to_sync_props.sh       # properties: sync to target
   ./06_to_sync_delayed_props.sh   # delayed properties
   ./07_to_sync_stats.sh
   ./08_to_sync_download_stats.sh
   ./09_to_sync_folder_stats.sh
   ```

## Options

| Option | Description |
|--------|-------------|
| `--collect-stats-properties` | After compare, run `jf compare list` with `--collect-stats --collect-properties` on the target. In Case a (SH→Cloud), also runs `jf compare list` with `--collect-properties` on the source (SH) so property sync views use source=SH, target=Cloud and 04/06 scripts can be non-empty. **Only valid when `ARTIFACTORY_DISCOVERY_METHOD=artifactory_aql`.** |
| `--reconcile` | After compare (and optional collect), generate the phased reconciliation scripts (`01_to_consolidate.sh` … `09_to_sync_folder_stats.sh`) in the current directory (or `RECONCILE_OUTPUT_DIR`). Scripts are numbered in run order. |
| `--target-only` | With `--reconcile`: keep only commands that update the **target** instance (e.g. app2). One-way sync so that target matches source; commands that would update the source are dropped. When `CLOUD_ARTIFACTORY_REPOS` or `ARTIFACTORY_REPOS` is set, generated scripts are also restricted to those repos only. |
| `-h`, `--help` | Show help. |

**Environment:**  
`COLLECT_STATS_PROPERTIES=1` and `RECONCILE=1` are equivalent to the flags above.  
`RECONCILE_TARGET_ONLY=1` is equivalent to `--target-only`.  
`RECONCILE_OUTPUT_DIR=<dir>` sets where `to_*.sh` are written (default: current directory).

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

Leave these unset to compare and reconcile **all** repositories.

### Step 3: Use AQL discovery for stats/properties and reconciliation

For **properties** and **statistics** reconciliation you need stats and properties collected on the target. That is only supported with AQL discovery:

```bash
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_aql"
```

Use `artifactory_filelist` only if you need a fast compare for binaries and do **not** need `--collect-stats-properties` or full stats/properties reconciliation.

### Step 4: Run compare and generate reconciliation scripts

Run the script with **collect-stats/properties** and **reconcile** so that:

1. Source and target are crawled and compared (binaries).
2. Stats and properties are collected on the **target** (required for properties and statistics reconciliation).
3. All phased reconciliation scripts are generated.

```bash
./compare-and-reconcile.sh --collect-stats-properties --reconcile --target-only
```

Outputs:

- **Report:** `report-<scenario>-<timestamp>.csv` (mismatches from `comparison.db`).
- **Scripts** (in current directory or `RECONCILE_OUTPUT_DIR`), numbered in run order:
  - `01_to_consolidate.sh` — Phase 1: consolidate abnormal repos to normalized repos (same instance).
  - `02_to_consolidate_props.sh` — Phase 1: properties consolidation.
  - `03_to_sync.sh` — Phase 2: sync normalized repos to target instance (binaries, non-delayed only).
  - `04_to_sync_props.sh` — Phase 2: properties sync.
  - `05_to_sync_delayed.sh` — Phase 2b: sync delayed artifacts (e.g. list.manifest.json, manifest.json) after regular binaries.
  - `06_to_sync_delayed_props.sh` — Phase 2b: properties sync for delayed artifacts.
  - `07_to_sync_stats.sh` — File statistics (X-Artifactory headers / checksum deploy); excludes download_count-only.
  - `08_to_sync_download_stats.sh` — Download stats (downloadCount, lastDownloaded, lastDownloadedBy) via `:statistics` endpoint.
  - `09_to_sync_folder_stats.sh` — Folder statistics via sync.* custom properties.

**Flow:** Run 01–02, then Phase 2 (03, 05). **Rerun** `./compare-and-reconcile.sh --collect-stats-properties --reconcile --target-only` so that 04, 06–09 are regenerated; then run Phase 2b (04, 06) and Statistics (07–09).

### Step 5: Run reconciliation in order (Phase 1 → Phase 2 → rerun compare → Phase 2b → statistics)

Execute the generated scripts in this order so that structure and metadata are fixed before syncing and before stats.

**Phase 1 – Consolidate (same instance)**  
Fixes abnormal repo layout on the **source/target** side before cross-instance sync.

```bash
./01_to_consolidate.sh      # binaries: consolidate repos on same instance
./02_to_consolidate_props.sh # properties: consolidate
```

**Phase 2 – Sync binaries to target**  
Syncs binaries from source to target: first non-delayed (03), then delayed artifacts (05, e.g. list.manifest.json, manifest.json).

```bash
./03_to_sync.sh             # binaries: sync to target instance
./05_to_sync_delayed.sh     # delayed binaries
```

**Between Phase 2 and Phase 2b – Rerun compare and regenerate scripts**  
After Phase 2, the target has new binaries. Rerun compare with collect-stats/properties and reconcile so that property and statistics scripts (04, 06–09) are regenerated from the updated state:

```bash
./compare-and-reconcile.sh --collect-stats-properties --reconcile --target-only
```

Then continue with Phase 2b and Statistics using the newly generated `04_*`, `06_*`–`09_*` scripts.

**Phase 2b – Sync properties to target**  
Syncs properties from source to target (sync and delayed). Run after Phase 2 and the rerun above.

```bash
./04_to_sync_props.sh       # properties: sync to target
./06_to_sync_delayed_props.sh   # delayed properties
```

**Statistics reconciliation**  
Syncs file stats, download stats, and folder stats. Run after Phase 2b so that artifacts and properties are in place.

```bash
./07_to_sync_stats.sh           # file stats (checksum deploy / X-Artifactory headers)
./08_to_sync_download_stats.sh   # downloadCount, lastDownloaded, lastDownloadedBy
./09_to_sync_folder_stats.sh    # folder stats (sync.* custom properties)
```

If any script is empty (no commands), there is nothing to reconcile for that phase.

### Step 6: (Optional) Inspect the CSV report

Open the timestamped CSV report to see which paths had mismatches and confirm that the reconciled scope matches your chosen repositories (specific repos or all).

---

## Summary: what each phase reconciles

| Phase | Scripts | What is reconciled |
|-------|---------|---------------------|
| **Phase 1** | `01_to_consolidate.sh`, `02_to_consolidate_props.sh` | Binaries and properties that need to be consolidated from abnormal to normalized repos on the **same** instance. |
| **Phase 2** | `03_to_sync.sh`, `05_to_sync_delayed.sh` | Binaries that need to be **synced to the target** (non-delayed and delayed, e.g. list.manifest.json, manifest.json). |
| **Phase 2b** | `04_to_sync_props.sh`, `06_to_sync_delayed_props.sh` | Properties that need to be **synced to the target** (sync and delayed). Run after Phase 2 and rerun compare. |
| **Statistics** | `07_to_sync_stats.sh`, `08_to_sync_download_stats.sh`, `09_to_sync_folder_stats.sh` | File stats (artifact metadata), download statistics (count, last downloaded, by whom), and folder-level stats (via custom properties). |

The exact behavior of each view and command comes from the **jfrog-cli-plugin-compare** plugin. For view names and details, refer to that plugin’s documentation.

## See also

- [plan.md](plan.md) — Implementation tasks and workflow reference.
- [compare_source_to_target/compare-artifacts.sh](../compare_source_to_target/compare-artifacts.sh) — Compare-only script and env var reference.
- **jfrog-cli-plugin-compare** — Source for `jf compare` report views and reconciliation commands.
