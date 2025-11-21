# Steps to Test File Transfer Between 2 JPDs

This guide walks through the process of testing file transfers from a source JPD (`jpd-dev`, `app1`) to a target JPD (`jpd-prod`, `app2`).

## Prerequisites

### 1. Configure JFrog CLI

On your Mac (with access to the K8s cluster), configure the JFrog CLI with both source and target JPDs.

- **Server ID `app1`**: Source JPD (`jpd-dev`)
- **Server ID `app2`**: Target JPD (`jpd-prod`)

#### Get LoadBalancer IPs for All JPDs

```bash
# Get LoadBalancer IPs for all JPDs
for ns in jfrog-prod jfrog-dev; do
  echo "=== $ns ==="
  kubectl get svc -n $ns | grep LoadBalancer
done
```

**Expected Output:**
```
=== jfrog-dev is app1 ===
jpd-dev-artifactory-nginx   LoadBalancer   10.2.123.13   34.26.38.195   80:32520/TCP,443:31707/TCP   11m

=== jfrog-prod is app2 ===
jpd-prod-artifactory-nginx   LoadBalancer   10.2.94.58     34.23.57.82   80:30213/TCP,443:30392/TCP   11m
```

### 2. Verify Helm Release Names

As per configuration in `example.tfvars`:
- `jpd-prod` → namespace: `jfrog-prod`, release_name: `jpd-prod`
- `jpd-dev` → namespace: `jfrog-dev`, release_name: `jpd-dev`

Verify with:
```bash
helm list -n jfrog-prod
helm list -n jfrog-dev
```

## Setup

### 3. Install Data Transfer Plugin in Source JPD (app1)

Install the data transfer plugin in the source JPD. For detailed instructions, see the [install_source_rt_plugins README](install_migration_plugins/install_source_rt_plugins/README.md).
<!-- https://git.jfrog.info/projects/PROFS/repos/ps_jfrog_scripts/browse/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins/install_source_rt_plugins -->

```bash
# Extract URL and access token from JFrog CLI configuration
CLI_CONFIG=$(jf c export app1 | base64 -d)
APP1_ARTIFACTORY_URL=$(echo "$CLI_CONFIG" | jq -r '.url')
# Remove trailing slash if it exists
APP1_ARTIFACTORY_URL="${APP1_ARTIFACTORY_URL%/}"
APP1_JFROG_ACCESS_TOKEN=$(echo "$CLI_CONFIG" | jq -r '.accessToken')

# Install transfer plugin
# Params: <JFROG_HELM_RELEASE_NAME> <JFROG_PLATFORM_NAMESPACE> <FULL_PATH_TO_SCRIPT> [APP1_JFROG_ACCESS_TOKEN]
bash /Users/sureshv/mycode/github.jfrog.info/ps_jfrog_scripts/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins/install_source_rt_plugins/1_run-transfer-plugin-install.sh jpd-dev jfrog-dev \
  /Users/sureshv/mycode/github.jfrog.info/ps_jfrog_scripts/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins/install_source_rt_plugins/2_install-transfer-plugin.sh \
  $APP1_JFROG_ACCESS_TOKEN
```

### 4. Install Config Import Plugin in Target JPD (app2)

Install the config import plugin in the target JPD . For detailed instructions, see the

[install_target_rt_plugins README](install_migration_plugins/install_target_rt_plugins/README.md).
<!-- https://git.jfrog.info/projects/PROFS/repos/ps_jfrog_scripts/browse/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins/install_target_rt_plugins -->
```bash
# Extract URL and access token from JFrog CLI configuration
CLI_CONFIG=$(jf c export app2 | base64 -d)
APP2_JFROG_ACCESS_TOKEN=$(echo "$CLI_CONFIG" | jq -r '.accessToken')

# Install config import plugin
bash /Users/sureshv/mycode/github.jfrog.info/ps_jfrog_scripts/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins/install_target_rt_plugins/1_run-config-import-plugin-install.sh \
  jpd-prod \
  jfrog-prod \
  /Users/sureshv/mycode/github.jfrog.info/ps_jfrog_scripts/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins/install_target_rt_plugins/2_install-config-import-plugin.sh \
  $APP2_JFROG_ACCESS_TOKEN
```

### 5a. Create Test Data in Source JPD (app1)

In `app1`, create a Docker repository `sv-docker-local` and publish Docker images.

**Tools:**
<!--
- https://github.com/sureshvenkatesan/utils/tree/main/publish_to_artifactory/docker_publish
- https://github.com/ps-jfrog/ps-coupa/blob/main/rt_docker_repo_performance_test/
-->
- https://github.com/ps-jfrog/charts/blob/master/ps/publish_to_artifactory/docker_publish
- https://github.com/ps-jfrog/charts/blob/master/ps/rt_docker_repo_performance_test

```bash
# Set Docker credentials as environment variables
export DOCKER_USERNAME="sureshv"
export DOCKER_PASSWORD="$APP1_JFROG_ACCESS_TOKEN"

python /Users/sureshv/mycode/github-sv/utils/publish_to_artifactory/docker_publish/docker_image_generator.py \
    --image-count 4 \
    --image-size-mb 10 \
    --layers 3 \
    --threads 4 \
    --registry "${APP1_ARTIFACTORY_URL#*//}" \
    --artifactory-repo "sv-docker-local" \
    --insecure
```

#### Step 5b: Create Repositories in Target JPD

Create the repositories in the target JPD:

```bash
jf rt transfer-config-merge --include-projects "" --include-repos "sv-docker-local" app1 app2
```

## File Transfer Methods

### Method 1: Initial Transfer (DB Dump + Filestore Sync)

**When to use:** Initial large transfer with both metadata and binaries.

#### Step 6a: Copy Binaries via GCS

Copy only the binaries from the `app1` filestore to `app2` filestore directly in GCP.

**Option 1: Recursive Copy (All Objects)**
```bash
gsutil -m cp -r "gs://sureshv-ps-jpd-dev-artifactory-storage/*" gs://sureshv-ps-jpd-prod-artifactory-storage/
```

**Option 2: Synchronize/Rsync (Recommended for Incremental Updates)**
```bash
gsutil -m rsync -r gs://sureshv-ps-jpd-dev-artifactory-storage/ gs://sureshv-ps-jpd-prod-artifactory-storage/
```



#### Step 6b: Transfer Files Without --filestore Flag

**When to use:** If metadata is already in `app2` DB and binaries are in `app2` filestore (after DB dump and filestore rsync), use this to sync transfer state. It will perform the checksum in the DB first so no need for the `--filestore` option.

```bash
export JFROG_CLI_LOG_LEVEL=DEBUG

jf rt transfer-files --include-repos "sv-docker-local" app1 app2
```

**Note:** This will transfer small metadata files but skip large binaries that already exist (confirmed by checksum verification).

**Verification:** Check SHA1 hashes show smaller files (like 1.5 KB) get transferred:
- `cc243324782c573074f846c0acf400312a6d9a4e`
- `ce8f30cdf948d8d373cf993c7e4b0b748a9fa1f3`

But 3MB files are not retransferred:
- `8af059e77176d88c8ce6b73f96b1a6f8b022b85b`

---

### Method 2: Delta Transfer (Filestore Only, No DB Metadata)

**When to use:** Only binaries are rsynced from `jpd-dev` (app1) to `jpd-prod` (app2), and metadata is **not** in DB. This is the case for delta transfers.

#### Step 7a: Enable Checksum Replication

**Prerequisite:** Enable checksum replication before using the `--filestore` option.

Reference: [Manually copying the filestore to reduce the transfer time](https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli/cli-for-jfrog-cloud-transfer#manually-copying-the-filestore-to-reduce-the-transfer-time)

**Enable Checksum Replication:**
```bash
jf rt curl -XPUT \
  -H "Content-Type: application/json" \
  -d '{"checkBinaryExistenceAllowed":"true"}' \
  "/api/config/storage/checksumReplication" --server-id app2
```

**Or with trust period:**
```bash
jf rt curl -XPUT \
  -H "Content-Type: application/json" \
  -d '{"checkBinaryExistenceAllowed":"true","daysToTrust":"3"}' \
  "/api/config/storage/checksumReplication" --server-id app2
```

**Verify Configuration:**
```bash
jf rt curl -XGET "/api/config/storage/checksumReplication" --server-id app2
```

**Expected Output:**
```json
{
  "checkBinaryExistenceAllowed" : true,
  "trustUntil" : "N/A"
}
```

Or:
```json
{
 "checkBinaryExistenceAllowed": true,
 "trustUntil": "2023-01-25 21:46:46 +0200"
}
```


#### Step 7b: Transfer Files with --filestore Flag

```bash
export JFROG_CLI_LOG_LEVEL=DEBUG

jf rt transfer-files --filestore=true --include-repos "sv-docker-local" app1 app2
```

**Note:** The `--filestore` flag tells the transfer process to check if binaries already exist in the filestore before transferring, significantly improving performance for delta transfers.

---
<!-->
## Performance Testing

### Test Performance with --filestore Option

This test confirms that using the `--filestore` option provides significant performance improvement.

#### Test 1: Without Checksum Replication (Slower)

1. **Disable `checkBinaryExistenceAllowed` flag:**
   ```bash
   jf rt curl -XPUT \
     -H "Content-Type: application/json" \
     -d '{"checkBinaryExistenceAllowed":"false"}' \
     "/api/config/storage/checksumReplication" --server-id app2
   ```

2. **Run transfer with --filestore flag:**
   ```bash
   export JFROG_CLI_LOG_LEVEL=DEBUG
   
   jf rt transfer-files --filestore=true --include-repos "sv-docker-local" app1 app2
   ```

   **Result:** Takes 2 min 3 seconds for 103.6MB.

#### Test 2: With Checksum Replication Enabled (Faster)

1. **Enable `checkBinaryExistenceAllowed` flag:**
   ```bash
   jf rt curl -XPUT \
     -H "Content-Type: application/json" \
     -d '{"checkBinaryExistenceAllowed":"true"}' \
     "/api/config/storage/checksumReplication" --server-id app2
   ```

2. **Rsync filestore again (if needed):**
   ```bash
   gsutil -m rsync -r gs://sureshv-ps-jpd-dev-artifactory-storage/ gs://sureshv-ps-jpd-prod-artifactory-storage/
   ```

3. **Run transfer with --filestore flag:**
   ```bash
   export JFROG_CLI_LOG_LEVEL=DEBUG
   
   jf rt transfer-files --filestore=true --include-repos "sv-docker-local" app1 app2
   ```

   **Result:** Takes 1 minute 3 seconds for 103.6MB (approximately 50% faster).
-->

---

## Verification

### Verify No Large Files Were Transferred

After a successful transfer with `--filestore=true`, verify that no files > 100KB were transferred in the last 15 minutes:

```bash
gcls-large gs://sureshv-ps-jpd-prod-artifactory-storage/filestore/ 15 100
```

**Expected Result:** No files should be listed, confirming that the `--filestore=true` option correctly skipped large binaries that already exist in the filestore.

This confirms that:
1. Large files were already present from the filestore rsync
2. The transfer process correctly detected them via checksum verification
3. Only metadata and missing files were transferred

## Repository-Level Comparison Report

After the artifact/data transfer is complete, you can generate a high-level comparison report of repositories between the source and target Artifactory instances using the repository comparison tools.

### Overview

The [compare_repo_list_details_in_source_vs_target_rt_after_migration.py](AllReposComparisonReport/compare_repo_list_details_in_source_vs_target_rt_after_migration.py) Python script compares a list of repositories between source and target Artifactory instances and generates a comprehensive comparison report. The report includes:

- Tabular comparison of repositories showing file counts, used space, and differences
- Identification of repositories with space differences
- Repositories with both file count and space differences
- Transfer commands for repositories requiring migration
- Repodiff commands for detailed repository comparison

The generated report is similar to the [example comparison report](AllReposComparisonReport/output/comparison_report_jun17_2024.txt), providing a clear overview of what has been transferred and what remains.

For detailed usage instructions and examples, refer to the [AllReposComparisonReport README](AllReposComparisonReport/readme.md).

### Automated Report Generation

The [prepare_and_generate_comparison_report.sh](prepare_and_generate_comparison_report/prepare_and_generate_comparison_report.sh) script automates the process of generating the comparison report. It:

- Calculates storage info for both source and target Artifactory instances
- Retrieves repository lists from both instances
- Executes the comparison script to generate the comprehensive report

This script simplifies the workflow by handling all the prerequisite steps before running the comparison. For more information, see the [prepare_and_generate_comparison_report README](prepare_and_generate_comparison_report/README.md).

## Comparing Artifacts Between Instances

The [compare-artifacts.sh](compare_source_to_target/compare-artifacts.sh) script can be used to compare artifacts between different sources (Nexus or Artifactory) and Artifactory targets using the JFrog CLI compare tool. The script supports comparing:
- **Nexus** to Artifactory instances
- **Artifactory** to Artifactory instances

Please review the  examples of [Available Comparison Scenarios](compare_source_to_target/README.md#examples) in the [compare_source_to_target/README.md](compare_source_to_target/README.md)



