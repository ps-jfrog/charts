# Test: `--sha1-resume` — resume failed sha1-prefix crawl

This test verifies that `--sha1-resume` correctly resumes a partially failed
sha1-prefix crawl for only the failed prefixes, without re-running the full crawl.

## Prerequisites

- `jf compare` plugin installed with `--sha1-resume` support (plugin Task 33)
- JFrog CLI profiles `psazuse` and `psazuse1` configured
- Repos `npmjs-remote-cache` (source) and `sv-npmjs-remote-cache-copy1` (target) exist

## Test scenario

The provided `crawl-audit-psazuse-20260126-100000.log` simulates a crawl where
prefixes `00` and `01` failed at offset 10 (EOF and TLS handshake timeout).
All other prefixes (`02`–`0f`) completed successfully.

## Steps

### Step 1: Run the initial full crawl

This populates `comparison.db` with all prefixes. Prefixes `00` and `01`
will be partially crawled (items before the error offset are captured).

```bash
cd /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/testcases/sha1-resume-test

# export RECONCILE_BASE_DIR="$(pwd)"

bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --config /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/testcases/sha1-resume-test/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 10 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

**Expected outcome:**
- `comparison.db` is created in the current directory
- A `crawl-audit-psazuse-*.log` is generated (real this time, replacing the simulated one)
- Check for errors:

```bash
grep ERROR crawl-audit-psazuse-*.log
```

If there are no real errors (the test repo is small), you can still proceed to
Step 2 using the simulated log to test the `--sha1-resume` flag parsing and
passthrough.

### Step 2: Extract failed prefix:offset pairs

```bash
RESUME=$(grep ERROR crawl-audit-psazuse-20260126-100000.log | \
  sed -n 's/.*prefix=\([a-f0-9]*\) offset=\([0-9]*\).*/\1:\2/p' | \
  paste -sd, -)
echo "RESUME=$RESUME"
```

**Expected output:**
```
RESUME=00:10,01:10
```

### Step 3: Resume only the failed prefixes

```bash
bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --config /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/testcases/sha1-resume-test/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5 --folder-parallel 16 \
  --verification-csv --verification-no-limit \
  --sha1-resume "$RESUME"
```

**Expected outcome:**
- `init --clean` is **skipped** (log should show: `Resume mode: skipping 'init --clean' to preserve existing comparison.db`)
- The `jf compare list` commands include `--sha1-resume=00:10,01:10`
- Only prefixes `00` and `01` are crawled, starting from offset 10
- The folder pass is skipped (already completed in Step 1)
- A new `crawl-audit-psazuse-*.log` is created for this resume run
- `comparison.db` is updated with the additional items from prefixes `00` and `01`

### Step 4: Verify the resume crawl completed without errors

```bash
# Check the LATEST audit log (not the simulated one)
ls -t crawl-audit-psazuse-*.log | head -1
# Then check it for errors:
grep ERROR "$(ls -t crawl-audit-psazuse-*.log | head -1)"
```

**Expected output:**
No ERROR lines (or if the repo truly has more items at those offsets, the
resume crawl should have fetched them with the smaller page size).

### Step 5 (optional): Repeat if errors persist

If Step 4 still shows errors, reduce `--aql-page-size` further and repeat:

```bash
RESUME=$(grep ERROR "$(ls -t crawl-audit-psazuse-*.log | head -1)" | \
  sed -n 's/.*prefix=\([a-f0-9]*\) offset=\([0-9]*\).*/\1:\2/p' | \
  paste -sd, -)

bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --config /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/testcases/sha1-resume-test/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 2 --folder-parallel 16 \
  --sha1-resume "$RESUME"
```

## What to verify

| Check | How | Expected |
|-------|-----|----------|
| `init --clean` skipped | Look for "Resume mode" in output | Present when `--sha1-resume` is used |
| `--sha1-resume` passed to plugin | Check `compare-and-reconcile-command-audit-*.log` | `jf compare list` commands include `--sha1-resume=00:10,01:10` |
| Only failed prefixes crawled | Check new `crawl-audit-*.log` | Only entries for prefixes `00` and `01` (no other prefixes) |
| Folder pass skipped | Check new `crawl-audit-*.log` | No `[folders]` section |
| DB updated | `jf compare query "SELECT COUNT(*) FROM artifacts WHERE source='psazuse' AND sha1 LIKE '00%'"` | Count >= items from Step 1 |
| Idempotent | Run Step 3 again | Same result, no duplicate rows |

## Cleanup

```bash
rm -rf b4_upload/ after_upload/ comparison.db *.csv *.log
```
