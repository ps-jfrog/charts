# Test: `--collect-stats-for-uris` — targeted stats/properties collection

This test verifies that `--collect-stats-for-uris` correctly collects stats and
properties for only the specified file URIs (and their derived parent folders),
without re-crawling the entire repository.

## Prerequisites

- `jf compare` plugin installed with `--collect-stats-for-uris` support (plugin Task 35)
- Shell wrapper scripts updated with `--collect-stats-for-uris` pass-through (script T30)
- JFrog CLI profiles `psazuse` and `psazuse1` configured
- Repos `npmjs-remote-cache` (source) and `sv-npmjs-remote-cache-copy1` (target) exist
- Target repo `sv-npmjs-remote-cache-copy1` is empty (or has fewer artifacts than source)

## Test scenario

Source repo `npmjs-remote-cache` has ~85 artifacts. Target repo
`sv-npmjs-remote-cache-copy1` is empty. The test runs a two-pass workflow:

1. **Pass 1:** Generate sync scripts (03/04) without stats/properties (fast).
2. **Run 03/04** to sync the missing artifacts to the target.
3. **Pass 2:** Collect stats/properties only for the ~85 URIs from 03/04 and
   their parent folders, then generate scripts 05–09.
4. **Run 05–09** to apply stats, properties, and folder metadata to the target.

This avoids the full `--collect-stats-properties` crawl which would scan the
entire repo. All data is already in `comparison.db` after Passes 1 and 2 — no
further crawl is needed to run the scripts.

## Steps

### Step 1: Run Pass 1 — generate sync scripts (no stats/properties)

```bash
cd /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/testcases/targeted-stats-test

bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --config ./env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 10 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

**Expected outcome:**
- `comparison.db` is created
- `b4_upload/03_to_sync.sh` has ~85 lines (all source artifacts missing from empty target)
- `b4_upload/04_to_sync_delayed.sh` is empty (npm repo has no delayed patterns)
- `b4_upload/05_to_sync_stats.sh` is empty (no stats collected yet)
- `b4_upload/06_to_sync_folder_props.sh` is empty (no folder properties collected yet)

### Step 2: Verify 03_to_sync.sh is populated and 05/06 are empty

```bash
wc -l b4_upload/*.sh
```

**Expected output:**
```
  85 b4_upload/03_to_sync.sh     (non-zero — artifacts to sync)
   0 b4_upload/04_to_sync_delayed.sh
   0 b4_upload/05_to_sync_stats.sh
   0 b4_upload/06_to_sync_folder_props.sh
```

### Step 3: Run 03/04 — sync missing artifacts to target

```bash
bash b4_upload/03_to_sync.sh 2>&1 | tee 03_out.log
# bash b4_upload/04_to_sync_delayed.sh 2>&1 | tee 04_out.log  # skip if empty
```

**Expected outcome:**
- Each line in `03_to_sync.sh` runs a `jf rt copy` (or similar) command to sync the artifact to the target
- No re-crawl occurs — these are direct `jf rt` commands against live Artifactory
- After completion, the ~85 artifacts exist on the target repo `sv-npmjs-remote-cache-copy1`

**Verify:**
```bash
grep -c "SUCCESS\|success\|ok" 03_out.log
grep -c "ERROR\|error" 03_out.log
```

### Step 4: Extract URIs from sync scripts

```bash
jf compare query --csv --header=false \
  "SELECT DISTINCT path FROM reconcile_phase2_sync
   UNION
   SELECT DISTINCT path FROM reconcile_phase2_sync_delayed" \
  > /tmp/uris_to_collect.txt

wc -l /tmp/uris_to_collect.txt
cat /tmp/uris_to_collect.txt | head -5
```

**Expected output:**
- ~85 URIs (one per line)
- Each line is a path like `/@anthropic-ai/sdk/-/@anthropic-ai/sdk-0.36.3.tgz`

### Step 5: Run Pass 2 — collect targeted stats/properties

```bash
bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --config ./env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only \
  --include-remote-cache \
  --collect-stats-for-uris /tmp/uris_to_collect.txt
```

**Expected outcome:**
- `init --clean` is **skipped** (preserves existing `comparison.db`)
- `jf compare list` commands include `--collect-stats-for-uris=/tmp/uris_to_collect.txt`
- Only the ~85 URIs (+ derived parent folders) are queried via AQL — **not** the full repo
- `comparison.db` is updated with stats and properties for those URIs and folders

### Step 6: Verify all scripts 05–09 are now populated

```bash
wc -l b4_upload/*.sh
```

**Expected output:**
```
   0 b4_upload/01_to_consolidate.sh
   0 b4_upload/02_to_consolidate_props.sh
  85 b4_upload/03_to_sync.sh          (unchanged from Pass 1)
   0 b4_upload/04_to_sync_delayed.sh  (no delayed artifacts in npm repo)
  85 b4_upload/05_to_sync_stats.sh    (NOW POPULATED — file stats)
  >0 b4_upload/06_to_sync_folder_props.sh  (NOW POPULATED — folder properties)
```

### Step 7: Run 05–09 — apply stats, properties, and folder metadata

```bash
bash b4_upload/05_to_sync_stats.sh 2>&1 | tee 05_out.log
bash b4_upload/06_to_sync_folder_props.sh 2>&1 | tee 06_out.log
# Run the remaining scripts if they are populated:
# bash b4_upload/07_to_sync_download_stats.sh 2>&1 | tee 07_out.log
# bash b4_upload/08_to_sync_props.sh 2>&1 | tee 08_out.log
# bash b4_upload/09_to_sync_folder_stats_as_properties.sh 2>&1 | tee 09_out.log
```

**Expected outcome:**
- Each script runs `jf rt` commands to set stats/properties on the target Artifactory
- No crawl or `jf compare list` is invoked — only `jf rt` commands
- All data comes from `comparison.db` which was populated in Passes 1 and 2

**Verify:**
```bash
grep -c "SUCCESS\|success\|ok" 05_out.log 06_out.log
grep -c "ERROR\|error" 05_out.log 06_out.log
```

### Step 8: Verify stats were collected only for targeted URIs

```bash
# Count artifacts with stats_collected_at set (should be ~85, not 7.5M)
jf compare query "SELECT COUNT(*) FROM artifacts WHERE source='psazuse' AND stats_collected_at IS NOT NULL"

# Count artifact_properties rows (should be non-zero, scoped to targeted artifacts)
jf compare query "SELECT COUNT(*) FROM artifact_properties"

# Verify node_statistics only has rows for targeted URIs
jf compare query "SELECT COUNT(*) FROM node_statistics WHERE source='psazuse'"
```

**Expected output:**
- `stats_collected_at` count ≈ 85 (file URIs only, or slightly more if folders also set it)
- `artifact_properties` count > 0 (properties for files + folders)
- `node_statistics` count ≈ number of targeted files + folders (not the full repo)

### Step 9: Verify folder data was collected

```bash
# Count folder nodes in artifacts table (derived from file URIs)
jf compare query "SELECT COUNT(*) FROM artifacts WHERE source='psazuse' AND sha1 IS NULL AND sha2 IS NULL AND md5 IS NULL AND uri != '/'"

# Check properties_sync_mismatch_folders has rows
jf compare query "SELECT COUNT(*) FROM properties_sync_mismatch_folders"

# Check reconcile_folder_stats has rows (if source has folder metadata)
jf compare query "SELECT COUNT(*) FROM reconcile_folder_stats"
```

**Expected output:**
- Folder count > 0 (parent folders derived from file URIs)
- `properties_sync_mismatch_folders` count >= 0 (depends on whether source folders have properties)
- `reconcile_folder_stats` count >= 0 (depends on whether source folders have `created_by`/`modified_by`)

### Step 10 (optional): Compare with full crawl

To verify the targeted collection matches a full crawl for the same URIs:

```bash
# Save targeted results
jf compare query --csv "SELECT * FROM reconcile_stats_actionable ORDER BY path" > /tmp/targeted_stats.csv
jf compare query --csv "SELECT * FROM properties_reconcile_phase2_sync ORDER BY path" > /tmp/targeted_props.csv

# Now run the full crawl (slow — only do this for verification)
bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --config ./env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 10 --folder-parallel 16

# Save full-crawl results
jf compare query --csv "SELECT * FROM reconcile_stats_actionable ORDER BY path" > /tmp/full_stats.csv
jf compare query --csv "SELECT * FROM properties_reconcile_phase2_sync ORDER BY path" > /tmp/full_props.csv

# Compare — targeted should be a subset of (or equal to) full
diff /tmp/targeted_stats.csv /tmp/full_stats.csv
diff /tmp/targeted_props.csv /tmp/full_props.csv
```

## What to verify

| Check | How | Expected |
|-------|-----|----------|
| 03/04 scripts run successfully | `grep -c SUCCESS 03_out.log` | All copy commands succeed, artifacts exist on target |
| `init --clean` skipped in Pass 2 | Look for "Resume mode" or skip message in output | Present when `--collect-stats-for-uris` is used |
| `--collect-stats-for-uris` passed to plugin | Check `compare-and-reconcile-command-audit-*.log` | `jf compare list` commands include `--collect-stats-for-uris=...` |
| Only targeted URIs queried | Check `crawl-audit-*.log` | Small number of items (~85 files + derived folders), not full repo |
| 05_to_sync_stats.sh populated | `wc -l b4_upload/05_to_sync_stats.sh` | ~85 lines |
| 06_to_sync_folder_props.sh populated | `wc -l b4_upload/06_to_sync_folder_props.sh` | > 0 lines (folder properties) |
| 05–09 scripts run successfully | `grep -c SUCCESS 05_out.log 06_out.log` | Stats/properties applied to target, no errors |
| Properties collected | `jf compare query "SELECT COUNT(*) FROM artifact_properties"` | > 0 |
| Folders derived from URIs | `jf compare query "SELECT COUNT(*) FROM artifacts WHERE sha1 IS NULL AND uri != '/'"` | > 0 |
| `--sha1-resume-authority` compatible | Add `--sha1-resume-authority psazuse1` to Pass 2 | Only target authority is queried |

## Cleanup

```bash
rm -rf b4_upload/ after_upload/ comparison.db *.csv *.log /tmp/uris_to_collect.txt
```
