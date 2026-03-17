# Targeted stats/properties collection (`--collect-stats-for-uris`)

When syncing large repositories (e.g. 7.5M artifacts), the full `--collect-stats --collect-properties` crawl takes ~5 hours per authority. If you only need stats and properties for the ~85–500 artifacts identified by `03_to_sync.sh` / `04_to_sync_delayed.sh`, use the targeted workflow below instead.

This guide covers the complete **generate → run → generate → run** cycle as a single end-to-end workflow.

---

## Prerequisites

- Same as [01-QUICKSTART.md](01-QUICKSTART.md): JFrog CLI with compare plugin, CLI profiles, `jq`.
- `jf compare` plugin with `--collect-stats-for-uris` support (plugin Task 35).
- Environment variables set (or a config file) — see [README.md](README.md).

---

## Workflow overview

| Phase | What happens | Time |
|-------|-------------|------|
| **Pass 1** — generate | Crawl source and target artifacts, generate sync scripts 03/04 (no stats/properties). | Minutes |
| **Run 03/04** | Sync missing artifacts to the target Artifactory. | Depends on artifact count |
| **Extract URIs** | Query `comparison.db` for the list of synced artifact paths. | Seconds |
| **Pass 2** — generate | Collect stats/properties only for those URIs + derived parent folders, generate scripts 05–06 in `b4_upload/` and 07–09 in `after_upload/`. | Minutes |
| **Run 05–09** | Apply stats, properties, and folder metadata to the target. | Depends on artifact count |

Total time: **minutes**, not the 10+ hours a full two-authority crawl would take.

---

## Step-by-step

### Step 1: Pass 1 — generate sync scripts (no stats/properties)

```bash
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

This crawls source and target artifacts and generates scripts in `b4_upload/`. Scripts 03/04 will be populated; 05/06 will be empty (no stats collected yet).

**Verify:**

```bash
wc -l b4_upload/*.sh
```

- `03_to_sync.sh` should have lines (artifacts missing from target)
- `05_to_sync_stats.sh` and `06_to_sync_folder_props.sh` should be empty (0 lines)

### Step 2: Run 03/04 — sync missing artifacts to target

```bash
bash sync-target-from-source.sh --config <config> --run-only --skip-consolidation
```

This executes scripts 01–06 in order. Since 01/02 are skipped (`--skip-consolidation`) and 05/06 are empty, only 03 (and 04 if non-empty) actually run. Each line in `03_to_sync.sh` runs a `jf rt copy` (same-instance) or download+upload (cross-instance) command.

After completion, the missing artifacts exist on the target.

### Step 3: Extract URIs for targeted collection

```bash
jf compare query --csv --header=false \
  "SELECT DISTINCT path FROM reconcile_phase2_sync
   UNION
   SELECT DISTINCT path FROM reconcile_phase2_sync_delayed" \
  > "$RECONCILE_BASE_DIR/uris_to_collect.txt"

wc -l "$RECONCILE_BASE_DIR/uris_to_collect.txt"
```

This queries `comparison.db` (already populated from Pass 1) for the paths that were synced. The output file contains one URI per line. It is saved alongside `comparison.db` in `RECONCILE_BASE_DIR` (not `/tmp/`) so it persists with the rest of the run artifacts.

### Step 4: Pass 2 — collect targeted stats/properties and generate 05–09

```bash
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only \
  --include-remote-cache \
  --collect-stats-for-uris "$RECONCILE_BASE_DIR/uris_to_collect.txt"
```

Key behaviors:
- `init --clean` is **skipped** — preserves the existing `comparison.db` from Pass 1.
- The full `--collect-stats --collect-properties` crawl is **not** run — `--collect-stats-for-uris` replaces it.
- The plugin collects stats and properties only for the listed file URIs, then automatically derives and collects their **parent folders** (e.g. `/path/to/pkg/-/pkg-1.0.tgz` → folders `/path/to/pkg/-/`, `/path/to/pkg/`, etc.).
- Scripts 05–06 are generated in `b4_upload/` (before-upload views: file stats, folder properties).
- Scripts 07–09 are generated in `after_upload/` (after-upload views: download stats, file properties, folder stats as properties). The after-upload compare runs automatically when `--collect-stats-for-uris` is combined with `--generate-only`.

**Verify:**

```bash
wc -l b4_upload/*.sh after_upload/*.sh
```

- `b4_upload/05_to_sync_stats.sh` should now be populated (file stats)
- `b4_upload/06_to_sync_folder_props.sh` should now be populated (folder properties)
- `after_upload/08_to_sync_props.sh` should now be populated (file properties)
- `b4_upload/03_to_sync.sh` is unchanged from Pass 1

### Step 5: Run 05–09 — apply stats, properties, and folder metadata

```bash
bash sync-target-from-source.sh --config <config> --run-only --skip-consolidation
```

This re-runs all scripts in order. Scripts 03/04 are idempotent (safe to re-execute). Scripts 05–06 (in `b4_upload/`) and 07–09 (in `after_upload/`) apply stats, properties, and folder metadata to the target Artifactory via `jf rt` commands. No further crawl is needed — all data is already in `comparison.db`.

Alternatively, run scripts individually:

```bash
bash b4_upload/05_to_sync_stats.sh 2>&1 | tee 05_out.log
bash b4_upload/06_to_sync_folder_props.sh 2>&1 | tee 06_out.log
# bash after_upload/07_to_sync_download_stats.sh 2>&1 | tee 07_out.log
bash after_upload/08_to_sync_props.sh 2>&1 | tee 08_out.log
# bash after_upload/09_to_sync_folder_stats_as_properties.sh 2>&1 | tee 09_out.log
```

---

## Scoping to a single authority

If you only need to collect targeted stats on one authority (e.g. only the target), combine with `--sha1-resume-authority`:

```bash
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only \
  --include-remote-cache \
  --collect-stats-for-uris /tmp/uris_to_collect.txt \
  --sha1-resume-authority <target-authority>
```

The other authority is skipped entirely — its data is already in `comparison.db`.

---

## What the scripts do

| Script | Directory | Source view | What it applies |
|--------|-----------|-----------|-----------------|
| `05_to_sync_stats.sh` | `b4_upload/` | `reconcile_stats_actionable` | File-level stats (`created_by`, `modified_by`, etc.) |
| `06_to_sync_folder_props.sh` | `b4_upload/` | `properties_reconcile_phase2_sync_folders` | Folder properties |
| `07_to_sync_download_stats.sh` | `after_upload/` | `reconcile_download_stats` | Download counts |
| `08_to_sync_props.sh` | `after_upload/` | `properties_reconcile_phase2_sync` | File properties |
| `09_to_sync_folder_stats_as_properties.sh` | `after_upload/` | `reconcile_folder_stats` | Folder stats as properties |

Scripts 05–06 are generated from before-upload views and placed in `b4_upload/`. Scripts 07–09 are generated from after-upload views and placed in `after_upload/`. All views are populated from `comparison.db` after the targeted collection in Pass 2.

---

## One-command alternative: `sync-with-targeted-stats.sh`

Instead of running the five steps manually, use the orchestrator script that performs all of them in a single invocation:

```bash
bash sync-with-targeted-stats.sh \
  --config <config> \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

To resume a failed Pass 1 crawl and then continue with the targeted stats workflow:

```bash
bash sync-with-targeted-stats.sh \
  --config <config> \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 2000 --folder-parallel 16 \
  --verification-csv --verification-no-limit \
  --sha1-resume "f2:40000,f3:40000"
```

`--sha1-resume` applies to Pass 1 (the artifact crawl). It skips `init --clean` and resumes only the failed prefixes. After Pass 1 completes, the script continues with Run 03/04, URI extraction, Pass 2 (targeted stats), and Run 05–09 as usual.

Optionally, add `--sha1-resume-authority <id>` to scope the resume crawl to a single authority (e.g. when errors only occurred on the target side):

```bash
bash sync-with-targeted-stats.sh \
  --config <config> \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 2000 --folder-parallel 16 \
  --verification-csv --verification-no-limit \
  --sha1-resume "f2:40000,f3:40000" \
  --sha1-resume-authority psazuse1
```

When `--sha1-resume-authority` is set, only the named authority is re-crawled in Pass 1; the other is skipped entirely (its data is already in `comparison.db`). The same authority scoping also applies to Pass 2 (targeted stats collection).

This runs the full cycle automatically:

1. **Pass 1:** Calls `sync-target-from-source.sh --generate-only --skip-collect-stats-properties` to generate 03/04. If `--sha1-resume` is passed, resumes the crawl for the specified prefixes.
2. **Run 03/04:** Calls `sync-target-from-source.sh --run-only --skip-consolidation` to sync artifacts.
3. **Extract URIs:** Queries `comparison.db` and writes `uris_to_collect.txt` to `RECONCILE_BASE_DIR`.
4. **Pass 2:** Calls `sync-target-from-source.sh --generate-only --collect-stats-for-uris <uris_file>` to generate 05–06 in `b4_upload/` and 07–09 in `after_upload/`.
5. **Run 05–09:** Calls `sync-target-from-source.sh --run-only --skip-consolidation` to apply stats/properties.

If the URI list is empty (no artifacts to sync), it exits early after Run 03/04.

All options you pass (e.g. `--config`, `--include-remote-cache`, `--aql-style`, `--sha1-resume`, `--sha1-resume-authority`) are forwarded to each `sync-target-from-source.sh` invocation. The internally managed flags (`--generate-only`, `--run-only`, `--skip-collect-stats-properties`, `--skip-consolidation`, `--collect-stats-for-uris`) are added automatically.

Timing is reported for each phase and overall.

---

## Quick-reference (manual steps, copy-paste)

```bash
# --- Pass 1: Generate sync scripts ---
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16

# --- Run 03/04: Sync artifacts to target ---
bash sync-target-from-source.sh --config <config> --run-only --skip-consolidation

# --- Extract URIs ---
jf compare query --csv --header=false \
  "SELECT DISTINCT path FROM reconcile_phase2_sync
   UNION
   SELECT DISTINCT path FROM reconcile_phase2_sync_delayed" \
  > "$RECONCILE_BASE_DIR/uris_to_collect.txt"

# --- Pass 2: Collect targeted stats/properties, generate 05–06 + 07–09 ---
bash sync-target-from-source.sh \
  --config <config> \
  --generate-only \
  --include-remote-cache \
  --collect-stats-for-uris "$RECONCILE_BASE_DIR/uris_to_collect.txt"

# --- Run 05–09: Apply stats/properties/folder metadata ---
bash sync-target-from-source.sh --config <config> --run-only --skip-consolidation
```

---

## See also

- [sync-with-targeted-stats.sh](sync-with-targeted-stats.sh) — one-command orchestrator (runs the full workflow above)
- [README.md](README.md) — full options reference (including `--collect-stats-for-uris`)
- [03-README-troubleshooting-crawl-errors.md](03-README-troubleshooting-crawl-errors.md) — error recovery with `--sha1-resume`
- [testcases/targeted-stats-test/README.md](testcases/targeted-stats-test/README.md) — Docker delta sync test: initial sync, publish delta, targeted stats with `--skip-pass1`, single-directory production workflow
- [testcases/targeted-stats-test/test_npm-targeted-stats-collection.md](testcases/targeted-stats-test/test_npm-targeted-stats-collection.md) — low-level npm repo end-to-end test with verification queries
