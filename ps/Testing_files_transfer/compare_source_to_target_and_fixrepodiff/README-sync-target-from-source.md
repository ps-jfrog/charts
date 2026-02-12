# sync-target-from-source.sh — One-shot sync workflow

This script automates **Steps 2 through 5** of [QUICKSTART.md](QUICKSTART.md): it runs the full compare-and-reconcile workflow (before-upload and after-upload) and executes all generated reconciliation scripts so that the **target Artifactory matches the source** in one invocation.

**Step 1** (setting environment variables) is not automated: you must set the required env vars before running the script, or pass a config file with `--config <file>`.

---

## What the script does (mapping to QUICKSTART)

| Script step | QUICKSTART step | Action |
|-------------|-----------------|--------|
| (you set env) | **Step 1** | Set COMPARE_*, SH_ARTIFACTORY_*, CLOUD_ARTIFACTORY_*, etc. (or use `--config`) |
| Step 2 | **Step 2** | Run `compare-and-reconcile.sh --b4upload --collect-stats-properties --reconcile --target-only`; output in `b4_upload/` |
| Step 3 | **Step 3** | Run before-upload scripts 01–06 (optionally skip 01/02; 04 is skipped by default, use `--run-delayed` to run it) via `runcommand_in_parallel_from_file.sh` |
| Step 4 | **Step 4** | Run `compare-and-reconcile.sh --after-upload ...`; output in `after_upload/` |
| Step 5 | **Step 5** | Run after-upload scripts 07, 08, 09 via `runcommand_in_parallel_from_file.sh` |

The script resolves its own directory so it can call `compare-and-reconcile.sh` and `runcommand_in_parallel_from_file.sh` correctly no matter where you run it from.

---

## Prerequisites

- Same as [QUICKSTART.md](QUICKSTART.md): JFrog CLI with compare plugin, CLI profiles for source and target (e.g. `app1`, `app2`), `jq`.
- **Supported scenario:** Case a (Artifactory SH → Artifactory Cloud). Other scenarios are not yet supported by this one-shot script.

---

## Usage

### Step 1: Set environment variables

Set the same variables as in QUICKSTART Step 1. Example for Artifactory SH → Cloud:

```bash
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
```

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
| `env_app1_app2.sh` | Source and target on **different** Artifactory instances (e.g. app1 → app2); **same repo names** on both sides. |
| `env_app1_app2_diff_jpds_diff_repos.sh` | Different instances (app1 → app2) and **different repo names** (e.g. source `sv-docker-local`, target `sv-docker-local-copy`). |
| `env_app2_app3_same_jpd_different_repos.sh` | Source and target on the **same** Artifactory instance (different CLI profiles app2 → app3); **different repo names** per pair. |

Copy one as a template, edit URLs, authorities, and repo lists, then run with `--config <your-file>.sh`.

---

## Options

| Option | Description |
|--------|-------------|
| `--config <file>` | Source `<file>` before running (e.g. a script that exports COMPARE_* and repo vars). |
| `--skip-consolidation` | Do not run `01_to_consolidate.sh` or `02_to_consolidate_props.sh`. |
| `--run-delayed` | Run `04_to_sync_delayed.sh`. By default it is skipped (delayed manifests are often created by the stats sync). |
| `--max-parallel <N>` | Max concurrent commands when running reconciliation scripts (default: 10). |
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

---

## Relation to manual QUICKSTART

- **Manual:** You run Steps 1–5 yourself (set env, run compare-and-reconcile twice, run each generated script with `runcommand_in_parallel_from_file.sh`).
- **One-shot:** You set env (or `--config`) once and run `./sync-target-from-source.sh`; it performs Steps 2–5 for you.

For more control (e.g. running only some scripts or changing order), use the manual flow in [QUICKSTART.md](QUICKSTART.md).
