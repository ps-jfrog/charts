# retarget-sync-scripts.sh

Copy generated before-upload scripts (03–06) from a previous `--generate-only` run and rewrite them to upload artifacts to a **different target repository**, without re-running the full compare workflow. After rewriting, the script prints step-by-step guidance for executing the scripts and completing the after-upload phase (07–09).

## When to use

After running `sync-target-from-source.sh --generate-only` to produce scripts that sync source repo A → target repo B, you discover you need to sync the same artifacts to target repo C instead (or in addition). Rather than re-running the entire compare workflow, `retarget-sync-scripts.sh` rewrites the existing scripts.

## Usage

```
retarget-sync-scripts.sh [OPTIONS]
```

### Required options

| Option | Description |
|--------|-------------|
| `--source-dir <dir>` | Path to the original `RECONCILE_BASE_DIR` containing `b4_upload/` with generated scripts (03–06). |
| `--target-dir <dir>` | Path to the new `RECONCILE_BASE_DIR` for the retargeted run. Created if it doesn't exist. |
| `--old-repo <name>` | Target repo name to replace (e.g. `npmjs-remote-cache`). |
| `--new-repo <name>` | New target repo name (e.g. `my-other-repo`). |

### Optional options

| Option | Description |
|--------|-------------|
| `--old-server-id <id>` | Current target Artifactory server-id to replace. Must be paired with `--new-server-id`. |
| `--new-server-id <id>` | New target Artifactory server-id. Must be paired with `--old-server-id`. |
| `-h`, `--help` | Show usage help. |

## What it does

1. **Copies** `03_to_sync.sh`, `04_to_sync_delayed.sh`, `05_to_sync_stats.sh`, and `06_to_sync_folder_props.sh` from `<source-dir>/b4_upload/` to `<target-dir>/b4_upload/`.
2. **Rewrites the target repository name** using `sed`, with patterns tailored to each script type:
   - **03/04** (`jf rt dl`+`jf rt u` or `jf rt cp`): replaces `"OLD_REPO/` → `"NEW_REPO/` (matches the upload target path).
   - **05** (`jf rt curl -X PUT`): replaces `"/OLD_REPO/` → `"/NEW_REPO/` (matches the curl API path with leading `/`).
   - **06** (`jf rt sp`): replaces `"OLD_REPO/` → `"NEW_REPO/` (matches the property target path).
3. **Rewrites the server-id** (if `--old-server-id` / `--new-server-id` are provided):
   - For **03/04**: only replaces after `&&` (the upload side), leaving the download/source server-id unchanged.
   - For **05/06**: global replace (single server-id per line).
4. **Prints a summary** showing how many lines were copied and modified in each script.
5. **Prints next-steps guidance** explaining how to create a config file and run `sync-target-from-source.sh --run-only` to complete the workflow.

## Examples

### Basic retarget (same Artifactory, different repo)

```bash
bash retarget-sync-scripts.sh \
  --source-dir /tmp/reconcile-run1 \
  --target-dir /tmp/reconcile-retarget \
  --old-repo npmjs-remote-cache \
  --new-repo my-other-repo
```

### Retarget with server-id change

```bash
bash retarget-sync-scripts.sh \
  --source-dir /tmp/reconcile-run1 \
  --target-dir /tmp/reconcile-retarget \
  --old-repo npmjs-remote-cache \
  --new-repo my-other-repo \
  --old-server-id psazuse1 \
  --new-server-id psazuse2
```

## Sample output

```
=== Retarget: copy and rewrite before-upload scripts (03–06) ===

  Source:     /tmp/reconcile-run1/b4_upload
  Target:     /tmp/reconcile-retarget/b4_upload
  Repo:       npmjs-remote-cache → my-other-repo

  03_to_sync.sh: 247 lines, 247 repo substitutions
  04_to_sync_delayed.sh: 12 lines, 12 repo substitutions
  05_to_sync_stats.sh: 10983 lines, 10983 repo substitutions
  06_to_sync_folder_props.sh: 27 lines, 27 repo substitutions

=== Rewrite complete: 4 scripts, 11269 total repo substitutions ===

Review the rewritten scripts in:
  /tmp/reconcile-retarget/b4_upload

=== Next steps ===

1. Create a config file (e.g. env_retarget.sh) based on your original config
   but with the updated target repo and output directory:

     # Copy from your original config, then change these lines:
     export CLOUD_ARTIFACTORY_REPOS="my-other-repo"
     export RECONCILE_BASE_DIR="/tmp/reconcile-retarget"
     # Keep all other env vars (SH_ARTIFACTORY_*, COMPARE_*, etc.) the same.

2. Run sync-target-from-source.sh with --run-only to execute the rewritten
   scripts (03–06) and then generate/run the after-upload scripts (07–09):

     bash .../sync-target-from-source.sh \
       --config env_retarget.sh \
       --run-only --skip-consolidation --run-delayed --run-folder-stats \
       --verification-csv --verification-no-limit

   --run-only skips Step 2 (before-upload compare) since the rewritten scripts
   already exist in b4_upload/. It proceeds with:
     Step 3: Execute before-upload scripts (03–06) from b4_upload/
     Step 4: After-upload compare (against my-other-repo)
     Step 5: Execute after-upload scripts (07–09)
     Step 6: Post-sync verification
```

## Complete workflow

```bash
# 1. Original run: generate scripts for source → target-A
bash sync-target-from-source.sh \
  --config env_original.sh \
  --generate-only --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16

# 2. Retarget: rewrite scripts to upload to target-B instead
bash retarget-sync-scripts.sh \
  --source-dir /path/to/original/reconcile-dir \
  --target-dir /path/to/retarget/reconcile-dir \
  --old-repo target-A-repo \
  --new-repo target-B-repo

# 3. Create env_retarget.sh (copy env_original.sh, change CLOUD_ARTIFACTORY_REPOS
#    and RECONCILE_BASE_DIR as shown in the retarget script's output)

# 4. Execute retargeted scripts + after-upload phase
bash sync-target-from-source.sh \
  --config env_retarget.sh \
  --run-only --skip-consolidation --run-delayed --run-folder-stats \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

## Important notes

- **Download source is unchanged.** The retarget script only modifies the upload/target side of the commands. Artifacts are still downloaded from the original source repository using the original source server-id.
- **Scripts 01/02 are not copied.** Consolidation scripts operate on the comparison database and are not related to the target repo. Use `--skip-consolidation` when running `--run-only`.
- **Derived scripts are regenerated.** Files like `03_to_sync_grouped.sh`, `03_to_sync_using_copy.sh`, and `06a_lines_other_than_only_sync_folder_props.sh` are regenerated by `sync-target-from-source.sh` during Step 3 execution — they don't need to be copied.
- **After-upload phase works normally.** Step 4 (`--after-upload` compare) runs a fresh crawl of the new target repo, and Step 5 generates 07–09 scripts based on the remaining differences.
- **The `--old-repo` must match the target repo name** as it appears in the generated scripts. Check a few lines of `03_to_sync.sh` to confirm the exact name.
