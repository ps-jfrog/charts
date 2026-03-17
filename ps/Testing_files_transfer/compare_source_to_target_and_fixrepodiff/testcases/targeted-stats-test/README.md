# Targeted Stats Collection with SHA1-Resume Test Case

This test validates the end-to-end workflow for syncing Docker images between two
Artifactory instances, including a targeted delta sync that avoids a full repo re-crawl.

---

## 1. Prerequisites — Set Docker credentials

```
export DOCKER_USERNAME="svenkate"
CLI_CONFIG=$(jf c export psazuse | base64 -d)
ARTIFACTORY_URL=$(echo "$CLI_CONFIG" | jq -r '.url')
ARTIFACTORY_URL="${ARTIFACTORY_URL%/}"
MYTOKEN=$(echo "$CLI_CONFIG" | jq -r '.accessToken')

export DOCKER_PASSWORD="$MYTOKEN"
```

---

## 2. Publish initial Docker images to the source repository

Publish 4 Docker images (tags) to `sv-docker-local`:

```
python /Users/sureshv/mycode/ps-jfrog/charts/ps/publish_to_artifactory/docker_publish/docker_image_generator.py \
    --image-count 4 \
    --image-size-mb 10 \
    --layers 3 \
    --threads 4 \
    --registry "${ARTIFACTORY_URL#*//}" \
    --artifactory-repo "sv-docker-local"
```

After publishing, add properties on some of the tag folders in `sv-docker-local`.

---

## 3. Initial full sync (one-shot)

Set environment variables and run the full sync:

```
export JFROG_CLI_LOG_LEVEL=DEBUG

export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="https://psazuse/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="psazuse"
export CLOUD_ARTIFACTORY_BASE_URL="https://psazuse/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="psazuse1"
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_aql"

export SH_ARTIFACTORY_REPOS="sv-docker-local"
export CLOUD_ARTIFACTORY_REPOS="docker-trivy-repo"

export RECONCILE_BASE_DIR="/Users/sureshv/From_Customer/smartsheet/compare_and_reconcile_tests/one-shot-test"

bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --include-remote-cache --run-folder-stats --run-delayed --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

**Expected result:** All files, properties, and folder properties are synced successfully.

---

## 4. Publish a delta of new Docker images

Publish 4 more Docker images (tags) to the source repository:

```
python /Users/sureshv/mycode/ps-jfrog/charts/ps/publish_to_artifactory/docker_publish/docker_image_generator.py \
    --image-count 4 \
    --image-size-mb 10 \
    --layers 3 \
    --threads 4 \
    --registry "${ARTIFACTORY_URL#*//}" \
    --artifactory-repo "sv-docker-local"
```

After publishing, add properties on some of the folders for the new Docker tags that
you want to sync as a delta.

---

## 5. Crawl the delta and update comparison.db

> **Disk space note:** Steps 5–6 below show two approaches. The **test approach**
> (5a → 6a) copies `comparison.db` to separate directories for each phase, which
> preserves intermediate states for debugging but requires multiple copies of the
> database. For large repos (e.g. 7.5M artifacts where `comparison.db` can be
> several GB), use the **production approach** (5b → 6b) which reuses a single
> directory and avoids copying the database entirely.

### 5a. Test approach — separate directory per phase

Copy the existing `comparison.db` to a new working directory and run
`--generate-only --skip-collect-stats-properties` to crawl the delta without collecting
stats (fast crawl):

```
export RECONCILE_BASE_DIR_OLD="$RECONCILE_BASE_DIR"
export RECONCILE_BASE_DIR="/Users/sureshv/From_Customer/smartsheet/compare_and_reconcile_tests/one-shot-targeted-stats-for-remianing-tags"
mkdir -p "$RECONCILE_BASE_DIR"
cp "$RECONCILE_BASE_DIR_OLD/comparison.db" "$RECONCILE_BASE_DIR/"

bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

### 5b. Production approach — reuse the same directory

Run the crawl in the same `RECONCILE_BASE_DIR` used in step 3. The
`--generate-only` flag triggers `init --clean`, which wipes the old `comparison.db`
and does a fresh crawl. This is safe because the initial sync (step 3) already
completed — the old database is no longer needed.

```
bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --generate-only --skip-collect-stats-properties \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```

**Expected result (both approaches):** `comparison.db` is updated with the delta.
Scripts `03_to_sync.sh` / `04_to_sync_delayed.sh` are generated in `b4_upload/` but
not executed.

---

## 6. Run targeted sync with `--skip-pass1`

Since step 5 already crawled the delta, use `--skip-pass1` to skip the redundant crawl.

**Edge case:** If step 5 was run with an older plugin (before Task 38) but this step
uses a newer plugin, the `targeted_uris` table won't exist in the DB. In that case,
uncomment the `jf compare init` line below to create the table schema without wiping
existing data — see [Section 8](#8-troubleshooting--older-comparisondb-missing-targeted_uris).

### 6a. Test approach — separate directory per phase

Copy the updated `comparison.db` to a new working directory:

```
export RECONCILE_BASE_DIR_OLD="$RECONCILE_BASE_DIR"
export RECONCILE_BASE_DIR="/Users/sureshv/From_Customer/smartsheet/compare_and_reconcile_tests/one-shot-targeted-stats-with-skip-pass1"
mkdir -p "$RECONCILE_BASE_DIR"
cp "$RECONCILE_BASE_DIR_OLD/comparison.db" "$RECONCILE_BASE_DIR/"

# Only needed if comparison.db was created with a plugin version before Task 38:
# cd "$RECONCILE_BASE_DIR" && jf compare init

bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-with-targeted-stats.sh \
  --skip-pass1 \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --run-folder-stats --run-delayed \
  --verification-csv --verification-no-limit
```

### 6b. Production approach — reuse the same directory

Run directly in the same `RECONCILE_BASE_DIR` from step 5. No copy needed — the
orchestrator enriches `comparison.db` with targeted stats/properties (via
`--collect-stats-for-uris`) and uses `--skip-compare` internally to prevent
`init --clean` from wiping the database.

```
# Only needed if comparison.db was created with a plugin version before Task 38:
# cd "$RECONCILE_BASE_DIR" && jf compare init

bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-with-targeted-stats.sh \
  --skip-pass1 \
  --include-remote-cache --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --run-folder-stats --run-delayed \
  --verification-csv --verification-no-limit
```

**Caveat:** During the "Run 05–09" phase, the orchestrator executes all scripts in
`b4_upload/` (including `03_to_sync.sh` / `04_to_sync_delayed.sh` which already ran
in "Run 03/04"). This is redundant but harmless — the artifacts are already on the
target, so copy/upload commands are effectively no-ops.

**Expected result (both approaches):** The orchestrator extracts URIs, runs 03/04 to
sync artifacts, collects targeted stats/properties (Pass 2), generates and runs
scripts 05–09. Only the delta folders/files are processed.

Verify that all tag and folder properties for the new images are present in the target repo.

---

## 7. Populating the `targeted_uris` table (plugin Task 38)

The `targeted_uris` table is used by the after-upload views (`reconcile_folder_stats`,
`reconcile_download_stats`, `properties_reconcile_phase2_sync`) to scope scripts 07–09
to only the delta folders/files. The table is populated **automatically** by the plugin
during `jf compare list --collect-stats-for-uris`.

In the targeted stats workflow (`sync-with-targeted-stats.sh`), Pass 2 already runs
this command, so the table is filled before scripts 07–09 are generated. No manual
action is needed.

### 7.1. Verify `targeted_uris`

```
jf compare query "SELECT count(*) FROM targeted_uris"
jf compare query "SELECT * FROM targeted_uris LIMIT 5"
```

When `targeted_uris` is non-empty, the after-upload views automatically join with it,
so scripts 07–09 contain only the delta — not all previously synced folders.

---

## 8. Troubleshooting — Older comparison.db missing `targeted_uris`

If you are working with a `comparison.db` created before Task 38, the `targeted_uris`
table won't exist. Follow these sub-steps to create the schema and populate the table.

### 8.1. Create the missing table schema

Run `jf compare init` (without `--clean`) to add the new table without wiping existing data:

```
cd "$RECONCILE_BASE_DIR"
jf compare init
```

### 8.2. Regenerate `uris_to_collect.txt` (if missing)

If `uris_to_collect.txt` was deleted or was never created (e.g. step 5 was run with an
older plugin), regenerate it from `comparison.db` using the same query that
`sync-with-targeted-stats.sh` uses:

```
cd "$RECONCILE_BASE_DIR" && \
  jf compare query --csv --header=false \
    "SELECT DISTINCT path FROM reconcile_phase2_sync
     UNION
     SELECT DISTINCT path FROM reconcile_phase2_sync_delayed" \
    > "$RECONCILE_BASE_DIR/uris_to_collect.txt"
```

This works as long as `comparison.db` still has the delta (i.e. you used `--generate-only`
in step 5 and haven't run `--run-only` yet, which would sync artifacts and zero out
the views).

Verify the file:

```
wc -l "$RECONCILE_BASE_DIR/uris_to_collect.txt"
head -5 "$RECONCILE_BASE_DIR/uris_to_collect.txt"
```

### 8.3. Re-run targeted collection to populate `targeted_uris`

Run the targeted collection for both authorities to populate the table:

```
jf compare list psazuse \
  --collect-stats-for-uris "$RECONCILE_BASE_DIR/uris_to_collect.txt" \
  --repos=sv-docker-local --include-remote-cache

jf compare list psazuse1 \
  --collect-stats-for-uris "$RECONCILE_BASE_DIR/uris_to_collect.txt" \
  --repos=docker-trivy-repo --include-remote-cache
```

### 8.4. Verify

```
jf compare query "SELECT count(*) FROM targeted_uris"
jf compare query "SELECT * FROM targeted_uris LIMIT 5"
```

After completing steps 8.1–8.4, return to [step 6](#6-run-targeted-sync-with---skip-pass1)
to run the targeted sync.
