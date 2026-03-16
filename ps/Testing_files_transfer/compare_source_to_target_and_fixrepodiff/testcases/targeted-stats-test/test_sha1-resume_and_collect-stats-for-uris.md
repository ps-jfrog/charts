# Set Docker credentials as environment variables
export DOCKER_USERNAME="svenkate"
CLI_CONFIG=$(jf c export psazuse | base64 -d)
ARTIFACTORY_URL=$(echo "$CLI_CONFIG" | jq -r '.url')
# Remove trailing slash if it exists
ARTIFACTORY_URL="${ARTIFACTORY_URL%/}"
MYTOKEN=$(echo "$CLI_CONFIG" | jq -r '.accessToken')

export DOCKER_PASSWORD="$MYTOKEN"

python /Users/sureshv/mycode/github-sv/utils/publish_to_artifactory/docker_publish/docker_image_generator.py \
    --image-count 4 \
    --image-size-mb 10 \
    --layers 3 \
    --threads 4 \
    --registry "${ARTIFACTORY_URL#*//}" \
    --artifactory-repo "sv-docker-local"

Add properties on some of the tag folders in sv-docker-local.

Do one-shot:
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

# Optional: limit to specific repos
export SH_ARTIFACTORY_REPOS="sv-docker-local"
export CLOUD_ARTIFACTORY_REPOS="docker-trivy-repo"

# Optional: where to put b4_upload/ and after_upload/ (default: script directory)
export RECONCILE_BASE_DIR="/Users/sureshv/From_Customer/smartsheet/compare_and_reconcile_tests/one-shot-test"

bash /Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/sync-target-from-source.sh \
  --include-remote-cache --run-folder-stats --run-delayed --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16 \
  --verification-csv --verification-no-limit
```
All the files and properties including the folder properties were synched successfully.

Now publish a delta (4 more docker images i.e tags):
```
python /Users/sureshv/mycode/github-sv/utils/publish_to_artifactory/docker_publish/docker_image_generator.py \
    --image-count 4 \
    --image-size-mb 10 \
    --layers 3 \
    --threads 4 \
    --registry "${ARTIFACTORY_URL#*//}" \
    --artifactory-repo "sv-docker-local"
```




Add properties on some of the folders for the new docker tags   that we want to 
sync as delta.



Now sync the remaining delta:

Copy the existing one-shot-test/comparison.db to a new "one-shot-targeted-stats-for-remianing-tags"
and using that as the new RECONCILE_BASE_DIR and use "--generate-only --skip-collect-stats-properties" so you can crawl the delta and update the comparison.db

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

Copy the existing one-shot-targeted-stats-for-remianing-tags/comparison.db to a new "one-shot-targeted-stats-with-skip-pass1"
and using that as the new RECONCILE_BASE_DIR.

**Edge case:** If step (73-82) was run with an older plugin (before Task 38) but this
step uses the newer plugin, the `targeted_uris` table won't exist in the copied DB.
In that case, run `jf compare init` (without `--clean`) after copying the DB to create
the table schema without wiping existing data — see the
"If `targeted_uris` doesn't exist" section below.

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


Verify all the other  tag and folder properties are in the target repo.

## Populating the `targeted_uris` table (plugin Task 38)

The `targeted_uris` table is used by the after-upload views (`reconcile_folder_stats`,
`reconcile_download_stats`, `properties_reconcile_phase2_sync`) to scope scripts 07–09
to only the delta folders/files. The table is populated **automatically** by the plugin
during `jf compare list --collect-stats-for-uris`.

In the targeted stats workflow (`sync-with-targeted-stats.sh`), Pass 2 already runs
this command, so the table is filled before scripts 07–09 are generated. No manual
action is needed.

### If `targeted_uris` doesn't exist (older comparison.db)

If you're working with a `comparison.db` created before Task 38, the table won't exist.
Run `jf compare init` (without `--clean`) to create the schema without wiping existing data:

```
cd "$RECONCILE_BASE_DIR"
jf compare init
```

Then re-run the targeted collection for both authorities to populate it:

```
jf compare list psazuse \
  --collect-stats-for-uris "$RECONCILE_BASE_DIR/uris_to_collect.txt" \
  --repos=sv-docker-local --include-remote-cache

jf compare list psazuse1 \
  --collect-stats-for-uris "$RECONCILE_BASE_DIR/uris_to_collect.txt" \
  --repos=docker-trivy-repo --include-remote-cache
```

### Verify

```
jf compare query "SELECT count(*) FROM targeted_uris"
jf compare query "SELECT * FROM targeted_uris LIMIT 5"
```

When `targeted_uris` is non-empty, the after-upload views automatically join with it,
so scripts 07–09 contain only the delta — not all previously synced folders.