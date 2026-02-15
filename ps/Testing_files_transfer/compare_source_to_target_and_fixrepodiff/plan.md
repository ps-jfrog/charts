# Plan: Compare and Reconcile Script

Script location: `ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/`

This document defines implementation tasks and a step-by-step workflow for a new script that extends the compare flow in `compare_source_to_target/compare-artifacts.sh` with optional **collect-stats/collect-properties** and **phased reconciliation** (generating executable shell scripts from `jf compare report --jsonl`).

---

## 1. Implementation Tasks

### 1.1 Core comparison (reuse from compare-artifacts.sh)

- [ ] **T1** Reuse or source the same configuration and validation as `compare-artifacts.sh`:
  - Environment variables for the three scenarios (Case a: SH→Cloud, Case b: Nexus→Cloud, Case c: Nexus→SH).
  - `ARTIFACTORY_DISCOVERY_METHOD` (default `artifactory_aql`), `COMMAND_NAME`, and optional `SH_ARTIFACTORY_REPOS` / `CLOUD_ARTIFACTORY_REPOS`.
  - Validation of required vars per scenario and `show_help` documentation.
- [ ] **T2** Implement the same comparison flow:
  - `jf compare init --clean`
  - Authority-add and credentials-add for source (Nexus if enabled) and Artifactory target(s) as in compare-artifacts.sh.
  - List source (Nexus repos from file or single list; Artifactory SH list when Case a).
  - List target Artifactory (SH for Case c, Cloud for Case a/b) with optional `--repos=...` when `SH_ARTIFACTORY_REPOS` or `CLOUD_ARTIFACTORY_REPOS` is set.
- [ ] **T3** Derive a single **target Artifactory repos** value for the rest of the script:
  - If Case a or b: `TARGET_REPOS = CLOUD_ARTIFACTORY_REPOS` (or empty = all repos).
  - If Case c: `TARGET_REPOS = SH_ARTIFACTORY_REPOS` (or empty = all repos).
  - Use this wherever “specific Artifactory repositories” is needed (e.g. `--repos="$REPOSITORIES"`).

### 1.2 Optional: collect-stats and collect-properties

- [ ] **T4** Add an option (e.g. `--collect-stats-properties` or env `COLLECT_STATS_PROPERTIES=1`) to run on the **target** Artifactory:
  - Command: `jf compare list <TARGET_AUTHORITY> --collect-stats --collect-properties --repos="$REPOSITORIES"`.
  - **Constraint:** Only run this when `ARTIFACTORY_DISCOVERY_METHOD=artifactory_aql`. If `artifactory_filelist` is set, skip and optionally print a note that `--collect-stats` and `--collect-properties` are only supported with `--discovery=artifactory_aql`.
- [ ] **T5** Use the same repo list as in T3: if `TARGET_REPOS` is set, pass `--repos="$TARGET_REPOS"`; otherwise omit (all repos).

### 1.3 Phased reconciliation (report → shell scripts)

- [ ] **T6** Add a mode or subcommand/flag to generate reconciliation scripts **after** the compare and optional collect step. For each of the following, run `jf compare report --jsonl <view> | jq -r '.cmd' | sort -u > <outfile>`:

  | View name                             | Output script               | Purpose |
  |---------------------------------------|-----------------------------|--------|
  | `reconcile_phase1_consolidate`        | `01_to_consolidate.sh`      | Phase 1: Consolidate abnormal repos to normalized repos (same instance) |
  | `properties_reconcile_phase1_consolidate` | `02_to_consolidate_props.sh` | Phase 1: Properties consolidation |
  | `reconcile_phase2_sync`               | `03_to_sync.sh`             | Phase 2: Sync normalized repos to target instance (non-delayed artifacts only) |
  | `properties_reconcile_phase2_sync`    | `04_to_sync_props.sh`       | Phase 2: Properties sync |
  | `reconcile_phase2_sync_delayed`       | `05_to_sync_delayed.sh`     | Phase 2b: Sync delayed artifacts (e.g. list.manifest.json, manifest.json) after regular binaries |
  | `properties_reconcile_phase2_sync_delayed` | `06_to_sync_delayed_props.sh` | Phase 2b: Properties sync for delayed artifacts |
  | `reconcile_stats_actionable`         | `07_to_sync_stats.sh`       | File stats (X-Artifactory headers / checksum deploy); excludes download_count-only |
  | `reconcile_download_stats`            | `08_to_sync_download_stats.sh` | Download stats: downloadCount, lastDownloaded, lastDownloadedBy (:statistics endpoint) |
  | `reconcile_folder_stats`             | `09_to_sync_folder_stats.sh` | Folder stats via sync.* custom properties |

- [ ] **T6c** Number the generated script filenames so run order is obvious (e.g. `01_to_consolidate.sh`, `02_to_consolidate_props.sh`, … `09_to_sync_folder_stats.sh`). Document in README and script help that scripts are prefixed with run order.
- [ ] **T6b** Keep a single run; do not add a flag to gate Phase 2b. Generate `to_sync_delayed.sh` and `to_sync_delayed_props.sh` whenever `--reconcile` is used (same as other scripts). If the plugin does not yet expose `reconcile_phase2_sync_delayed` / `properties_reconcile_phase2_sync_delayed`, the script should handle missing views gracefully (e.g. empty file or continue). Do not add `--include-delayed` or `INCLUDE_DELAYED=1` for older plugins.
- [ ] **T7** Make reconciliation script generation optional (e.g. `--reconcile` or `RECONCILE=1` or a subcommand like `reconcile`) so the script can be used for “compare only” or “compare + generate reconcile scripts.”
- [ ] **T8** Ensure generated scripts are executable or document that the user should `chmod +x to_*.sh` before running.
- [ ] **T9** Add brief help text and README section documenting that these views/options depend on `jf compare` behavior from the jfrog-cli-plugin-compare plugin (e.g. view names and when each is applicable).

### 1.4 Reporting and UX

- [ ] **T10** Keep or adapt the existing CSV report generation (e.g. from `comparison.db` mismatch table) and timestamped report filename as in compare-artifacts.sh.
- [ ] **T11** Document in script help and README:
  - That reconciliation is for “specific Artifactory repositories” when `CLOUD_ARTIFACTORY_REPOS` or `SH_ARTIFACTORY_REPOS` is set (depending on scenario), and for all repositories when those are unset.
  - The order of operations: compare (and optionally collect-stats/collect-properties) first, then generate reconciliation scripts.
  - **Run order for generated scripts:** Scripts are numbered 01–09 in run order. Phase 1 (01_, 02_) → Phase 2 (03_, 04_) → Phase 2b delayed (05_, 06_) → statistics (07_, 08_, 09_). State this explicitly in the README and in script help.

### 1.5 One-shot sync script (QUICKSTART automation)

- [x] **T12** Create a new **single script** that automates **Step 1 through Step 5** of [QUICKSTART.md](QUICKSTART.md) (i.e. from "Set environment variables" through "Run the after-upload reconciliation scripts"), so that one invocation runs the full sync workflow end-to-end without manual step execution. Scope:
  - **Step 1:** Set (or accept) environment variables: scenario (e.g. Artifactory SH → Cloud), source/target URLs and authorities, `ARTIFACTORY_DISCOVERY_METHOD`, `RECONCILE_OUTPUT_DIR` for both b4-upload and after-upload output dirs, and optional repo filters (`SH_ARTIFACTORY_REPOS`, `CLOUD_ARTIFACTORY_REPOS`). The script may accept these as arguments, env vars, or a config file; design to be decided at implementation.
  - **Step 2:** Run `compare-and-reconcile.sh --b4upload --collect-stats-properties --reconcile --target-only` with the b4-upload output dir.
  - **Step 3:** Run the before-upload reconciliation scripts in order: optionally 01/02 if consolidation is needed; then 03 (sync binaries), optionally 04 (sync delayed), 05 (sync stats), 06 (sync folder props), using `runcommand_in_parallel_from_file.sh` with appropriate concurrency and log paths (e.g. `--log-success`, failure log per script).
  - **Step 4:** Run `compare-and-reconcile.sh --after-upload --collect-stats-properties --reconcile --target-only` with the after-upload output dir (script must `cd` back to script dir or use absolute paths).
  - **Step 5:** Run the after-upload reconciliation scripts in order: 07 (download stats), 08 (sync props), 09 (folder stats as properties), using `runcommand_in_parallel_from_file.sh` as in Step 3.
  - The script must resolve its own directory so it can invoke `compare-and-reconcile.sh` and `runcommand_in_parallel_from_file.sh` correctly regardless of the user's current working directory when invoked.
  - Document in plan and (when implemented) in README/QUICKSTART how to run this one-shot script and how it maps to the manual Steps 1–5. No code changes beyond adding this task until implementation.

**Implemented:** Script [sync-target-from-source.sh](sync-target-from-source.sh) and [README-sync-target-from-source.md](README-sync-target-from-source.md). Step 1 is via env vars or `--config <file>`; output dirs default to `<script_dir>/b4_upload` and `<script_dir>/after_upload` (override with `RECONCILE_BASE_DIR`). Options: `--skip-consolidation`, `--skip-delayed`, `--max-parallel N`. Currently supports Case a (Artifactory SH → Cloud) only.

### 1.6 Different source and target repo names (same or cross-instance)

- [x] **T13** Support comparing repos with **different names** (e.g. source `sv-docker-local`, target `sv-docker-local-copy`) on the same or different Artifactory instance, per [jfrog-cli-plugin-compare/docs/phased-reconciliation-guide.md](../../../../jfrog-cli-plugin-compare/docs/phased-reconciliation-guide.md) section "Different source and target repo names". Implementation:
  - **List both sides:** Ensure both source (SH) and target (Cloud) are listed with their respective `--repos=` when `SH_ARTIFACTORY_REPOS` and `CLOUD_ARTIFACTORY_REPOS` are set (Case a). Uncomment or restore the Artifactory SH and Cloud list steps so each side is crawled with its own repo list.
  - **Sync-add after list:** After both sides are listed, when in Case a and both `SH_ARTIFACTORY_REPOS` and `CLOUD_ARTIFACTORY_REPOS` are set, run `jf compare sync-add <source_authority> <source_repo> <target_authority> <target_repo> other` for each pair. Pair by index (first source repo with first target repo). Require equal list lengths or document pairing. Optional: support `SYNC_REPO_PAIRS` env (e.g. `source1:target1,source2:target2`) for explicit mapping.
  - **Placement:** Run sync-add after the collect-stats/properties block and before generating reconciliation scripts (and before CSV report if report depends on comparison state).
  - **Documentation:** Document in script help and README that when source and target repo names differ, set both repo lists and the script will add explicit sync mappings; reference the phased-reconciliation-guide.

**Implemented:** Restored SH and Cloud list steps (list with `--repos=` and optional `--collect-stats --aql-style=sha1`). After collect-stats block, when Case a and both repo lists set: parse comma-separated lists, require equal count, run `sync-add SOURCE_AUTHORITY src_repo TARGET_AUTHORITY tgt_repo SYNC_TYPE` for each pair. Sync type from `COMPARE_SYNC_TYPE` (default `other`). Help text updated.

### 1.7 AQL style for list commands (sha1-prefix)

- [x] **T14** Support `--aql-style <style>` (e.g. `sha1-prefix`) on `jf compare list` commands for efficient crawling of large repos. Implementation:
  - **compare-and-reconcile.sh:** Accept `--aql-style <style>` CLI option; also read from env `COMPARE_AQL_STYLE`. Build `AQL_STYLE_FLAG` and append to all active `jf compare list` calls (collect-stats-properties block). If not set, no flag is passed (default repo-based style).
  - **sync-target-from-source.sh:** Accept `--aql-style <style>` CLI option; pass through to `compare-and-reconcile.sh` via env `COMPARE_AQL_STYLE` or CLI arg.
  - **Config env files:** Optionally set `COMPARE_AQL_STYLE="sha1-prefix"`.
  - **Documentation:** Update help text, README, and QUICKSTART with `--aql-style` option and `COMPARE_AQL_STYLE` env var.

**Implemented:** CLI `--aql-style <style>` on both scripts; env `COMPARE_AQL_STYLE`; appended `$AQL_STYLE_FLAG` to all 4 active list calls in compare-and-reconcile.sh; help text updated in both scripts.

---

## 2. Step-by-step workflow: Reconcile differences in specific (or all) Artifactory repos

Use this workflow to run compare and then reconcile differences, either for a fixed set of repos or for all repos.

### Prerequisites

- JFrog CLI with `jf compare` (jfrog-cli-plugin-compare) available.
- CLI profiles configured for Artifactory (e.g. `app1`, `app2`).
- For Nexus source: token or username/password and (if used) `repos.txt` and `NEXUS_RUN_ID`.
- Optional: `sqlite3` for CSV report; `jq` for generating reconciliation scripts.

### Step 1: Set scenario and required env vars

Choose one scenario and set the same variables as in `compare-artifacts.sh`:

- **Case a) Artifactory SH → Artifactory Cloud**  
  `COMPARE_SOURCE_NEXUS=0`, `COMPARE_TARGET_ARTIFACTORY_SH=1`, `COMPARE_TARGET_ARTIFACTORY_CLOUD=1`, plus `SH_ARTIFACTORY_BASE_URL`, `SH_ARTIFACTORY_AUTHORITY`, `CLOUD_ARTIFACTORY_BASE_URL`, `CLOUD_ARTIFACTORY_AUTHORITY`.

- **Case b) Nexus → Artifactory Cloud**  
  `COMPARE_SOURCE_NEXUS=1`, `COMPARE_TARGET_ARTIFACTORY_SH=0`, `COMPARE_TARGET_ARTIFACTORY_CLOUD=1`, plus Nexus URL/authority, Cloud Artifactory URL/authority, and Nexus credentials.

- **Case c) Nexus → Artifactory SH**  
  `COMPARE_SOURCE_NEXUS=1`, `COMPARE_TARGET_ARTIFACTORY_SH=1`, `COMPARE_TARGET_ARTIFACTORY_CLOUD=0`, plus Nexus and SH Artifactory URL/authority and Nexus credentials.

### Step 2: (Optional) Restrict to specific repositories

- For **Case a or b** (target = Cloud):  
  `export CLOUD_ARTIFACTORY_REPOS="repo1,repo2,repo3"`
- For **Case c** (target = SH):  
  `export SH_ARTIFACTORY_REPOS="repo1,repo2,repo3"`
- Leave unset to compare (and later reconcile) **all** repositories.

### Step 3: Choose discovery method

- `export ARTIFACTORY_DISCOVERY_METHOD=artifactory_aql`  
  Use for larger instances; required if you want collect-stats/collect-properties and full reconciliation views.
- `export ARTIFACTORY_DISCOVERY_METHOD=artifactory_filelist`  
  Use for &lt; 100K artifacts; script must skip `--collect-stats` and `--collect-properties` (and document that limitation).

### Step 4: Run compare (and optional collect-stats/collect-properties)

- Run the new script so it:
  1. Runs `jf compare init --clean`, adds authorities and credentials, lists source and target (with `--repos=...` when Step 2 is set).
  2. If option is enabled and discovery is `artifactory_aql`: runs  
     `jf compare list <TARGET_AUTHORITY> --collect-stats --collect-properties --repos="$REPOSITORIES"`  
     (with `REPOSITORIES` derived from `CLOUD_ARTIFACTORY_REPOS` or `SH_ARTIFACTORY_REPOS` per scenario).
- After this, `comparison.db` is populated and (if enabled) stats/properties are collected for the target.

### Step 5: Generate reconciliation scripts (optional)

- Run the script with the reconciliation option (or separate “reconcile” step) so it generates, in the current directory (or a chosen output dir):
  - `01_to_consolidate.sh` / `02_to_consolidate_props.sh` (Phase 1)
  - `03_to_sync.sh` / `04_to_sync_props.sh` (Phase 2)
  - `05_to_sync_delayed.sh` / `06_to_sync_delayed_props.sh` (Phase 2b: delayed artifacts)
  - `07_to_sync_stats.sh`, `08_to_sync_download_stats.sh`, `09_to_sync_folder_stats.sh`
- Each file is produced with:  
  `jf compare report --jsonl <view> | jq -r '.cmd' | sort -u > <outfile>`

### Step 6: Review and run reconciliation scripts

- Review generated `to_*.sh` scripts.
- **Run order:** Run scripts in numeric order (01 → 09). Phase 1 (01_, 02_) → Phase 2 (03_, 04_) → Phase 2b (05_, 06_) → statistics (07_, 08_, 09_). Follow jfrog-cli-plugin-compare guidance for stats order if any.
- Ensure scripts are executable: `chmod +x to_*.sh` if needed.

### Step 7: (Optional) Inspect CSV report

- Use the timestamped CSV report (from `comparison.db`) to inspect mismatches and confirm scope of reconciled repos (same “specific Artifactory repositories” or all repos as in Step 2).

---

## 3. Reference: compare-artifacts.sh behavior

- Repo filtering: `SH_ARTIFACTORY_REPOS` and `CLOUD_ARTIFACTORY_REPOS` (comma-separated).
- Target for “list” in Artifactory-only compare (Case a): both SH and Cloud are listed; the “target” for reconciliation is typically the Cloud instance (Phase 2 sync “to target”).
- The new script should use the same notion of “target” authority and “target repos” (T3) for `--repos` and for reconciliation so that “specific Artifactory repositories” aligns with `CLOUD_ARTIFACTORY_REPOS` or `SH_ARTIFACTORY_REPOS` when set.

---

## 4. References

- Compare script: `ps/Testing_files_transfer/compare_source_to_target/compare-artifacts.sh`
- Compare options and report views: **jfrog-cli-plugin-compare** (e.g. view names, `reconcile_*`, `properties_reconcile_*`, and when to use each phase).
