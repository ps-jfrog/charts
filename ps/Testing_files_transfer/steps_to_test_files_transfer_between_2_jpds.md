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

Install the data transfer plugin in the source JPD using:
https://git.jfrog.info/projects/PROFS/repos/ps_jfrog_scripts/browse/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins/install_source_rt_plugins

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

Install the config import plugin in the target JPD using:
https://git.jfrog.info/projects/PROFS/repos/ps_jfrog_scripts/browse/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins/install_target_rt_plugins

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
- https://github.com/sureshvenkatesan/utils/tree/main/publish_to_artifactory/docker_publish
- https://github.com/ps-jfrog/ps-coupa/blob/main/rt_docker_repo_performance_test/

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

## Comparing Artifacts Between Instances

The `compare-artifacts.sh` script can be used to compare artifacts between different sources (Nexus or Artifactory) and Artifactory targets using the JFrog CLI compare tool. The script supports comparing:
- **Nexus** to Artifactory instances
- **Artifactory** to Artifactory instances

### Available Comparison Scenarios

The script supports flexible comparison scenarios based on environment variable flags. **All required environment variables must be set** before running the script.

#### Case a) Compare Two Artifactory Instances (No Nexus)

Compare Artifactory SH to Artifactory Cloud:

```bash
# REQUIRED environment variables:
export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="http://35.229.108.92/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export CLOUD_ARTIFACTORY_BASE_URL="http://34.73.108.59/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"

# OPTIONAL (recommended for < 100K artifacts):
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_filelist"

./Testing_files_transfer/compare_source_to_target/compare-artifacts.sh
```

**Output:** `report-artifactory-sh-to-cloud-YYYYMMDD-HHMMSS.csv` (includes datetime timestamp)

#### Case b) Compare Nexus to Artifactory Cloud

Compare Nexus repository to Artifactory Cloud:

```bash
# REQUIRED environment variables:
export COMPARE_SOURCE_NEXUS="1"
export COMPARE_TARGET_ARTIFACTORY_SH="0"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SOURCE_NEXUS_BASE_URL="https://support-team-aaronc-docker-0.jfrog.farm/nexus/"
export SOURCE_NEXUS_AUTHORITY="stnexus"
export CLOUD_ARTIFACTORY_BASE_URL="http://34.73.108.59/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"
export NEXUS_ADMIN_TOKEN="your-token"
# OR use username/password:
# export NEXUS_ADMIN_USERNAME="admin"
# export NEXUS_ADMIN_PASSWORD="password"

# OPTIONAL (if using repos.txt file):
export NEXUS_REPOSITORIES_FILE="repos.txt"
export NEXUS_RUN_ID="019a5a07-cedd-7e50-acb4-c51c1b0b1063"

./Testing_files_transfer/compare_source_to_target/compare-artifacts.sh
```

**Output:** `report-nexus-to-cloud-YYYYMMDD-HHMMSS.csv` (includes datetime timestamp)

#### Case c) Compare Nexus to Artifactory SH

Compare Nexus repository to Artifactory SH:

```bash
# REQUIRED environment variables:
export COMPARE_SOURCE_NEXUS="1"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="0"
export SOURCE_NEXUS_BASE_URL="https://support-team-aaronc-docker-0.jfrog.farm/nexus/"
export SOURCE_NEXUS_AUTHORITY="stnexus"
export SH_ARTIFACTORY_BASE_URL="http://35.229.108.92/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export NEXUS_ADMIN_TOKEN="your-token"
# OR use username/password:
# export NEXUS_ADMIN_USERNAME="admin"
# export NEXUS_ADMIN_PASSWORD="password"

# OPTIONAL (if using repos.txt file):
export NEXUS_REPOSITORIES_FILE="repos.txt"
export NEXUS_RUN_ID="019a5a07-cedd-7e50-acb4-c51c1b0b1063"

./Testing_files_transfer/compare_source_to_target/compare-artifacts.sh
```

**Output:** `report-nexus-to-sh-YYYYMMDD-HHMMSS.csv` (includes datetime timestamp)

### Discovery Method Selection

**Important:** For instances with less than 100K artifacts, using `--discovery=artifactory_filelist` is the most efficient method, because `--discovery=artifactory_aql` crawl has too much overhead for smaller instances.

- **`artifactory_filelist`**: Recommended for instances with < 100K artifacts (more efficient)
- **`artifactory_aql`**: For larger instances, but has overhead for smaller instances

Set the discovery method:

```bash
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_filelist"  # or "artifactory_aql"
```

**Note:** The `--collect-stats --aql-style=sha1` command is only executed when using `--discovery=artifactory_aql` method.

### Environment Variables

**Required (set based on comparison scenario):**
- `COMPARE_SOURCE_NEXUS` - Enable Nexus as source (0 or 1)
- `COMPARE_TARGET_ARTIFACTORY_SH` - Enable Artifactory SH as target (0 or 1)
- `COMPARE_TARGET_ARTIFACTORY_CLOUD` - Enable Artifactory Cloud as target (0 or 1)

**Case a) Required:**
- `SH_ARTIFACTORY_BASE_URL` - Artifactory SH base URL (e.g., `"http://35.229.108.92/artifactory/"`)
- `SH_ARTIFACTORY_AUTHORITY` - Artifactory SH authority name (e.g., `"app1"`)
- `CLOUD_ARTIFACTORY_BASE_URL` - Artifactory Cloud base URL (e.g., `"http://34.73.108.59/artifactory/"`)
- `CLOUD_ARTIFACTORY_AUTHORITY` - Artifactory Cloud authority name (e.g., `"app2"`)

**Case b) Required:**
- `SOURCE_NEXUS_BASE_URL` - Nexus base URL (e.g., `"https://support-team-aaronc-docker-0.jfrog.farm/nexus/"`)
- `SOURCE_NEXUS_AUTHORITY` - Nexus authority name (e.g., `"stnexus"`)
- `CLOUD_ARTIFACTORY_BASE_URL` - Artifactory Cloud base URL
- `CLOUD_ARTIFACTORY_AUTHORITY` - Artifactory Cloud authority name
- `NEXUS_ADMIN_TOKEN` - Nexus admin token (or use `NEXUS_ADMIN_USERNAME` + `NEXUS_ADMIN_PASSWORD`)

**Case c) Required:**
- `SOURCE_NEXUS_BASE_URL` - Nexus base URL
- `SOURCE_NEXUS_AUTHORITY` - Nexus authority name
- `SH_ARTIFACTORY_BASE_URL` - Artifactory SH base URL
- `SH_ARTIFACTORY_AUTHORITY` - Artifactory SH authority name
- `NEXUS_ADMIN_TOKEN` - Nexus admin token (or use `NEXUS_ADMIN_USERNAME` + `NEXUS_ADMIN_PASSWORD`)

**Optional (all scenarios):**
- `ARTIFACTORY_DISCOVERY_METHOD` - Discovery method: `artifactory_aql` or `artifactory_filelist` (default: `artifactory_aql`)
- `COMMAND_NAME` - Command to use (default: `jf compare`)
- `NEXUS_REPOSITORIES_FILE` - File with Nexus repository list (default: `repos.txt`)
- `NEXUS_RUN_ID` - Run ID for grouping Nexus repositories (required if using `repos.txt`)

### Script Features

The script includes the following features:

- **Automatic validation**: Validates all required environment variables based on the selected comparison scenario
- **Clear error messages**: Shows exactly which variables are missing with example values
- **Timestamped reports**: Report filenames include a datetime timestamp (format: `YYYYMMDD-HHMMSS`) to prevent overwriting previous reports
- **Execution time tracking**: Displays the total execution time at the end of the comparison
- **Flexible configuration**: Uses environment variables for all configuration, including CLI profile names

### Help and Usage

View help text with detailed examples:

```bash
./Testing_files_transfer/compare_source_to_target/compare-artifacts.sh -h
```

The help text includes:
- All comparison scenarios with complete example commands
- Required and optional environment variables with example values
- Discovery method recommendations
- Usage examples for each scenario

### Output

The script generates:
- **Report file**: CSV file with comparison results (e.g., `report-artifactory-sh-to-cloud-20241118-162405.csv`)
- **Execution summary**: Displays comparison scenario, discovery method, report filename, and total execution time

**Example output:**
```
=== Comparison Scenario: artifactory-sh-to-cloud ===
Discovery Method: artifactory_filelist
Report File: report-artifactory-sh-to-cloud-20241118-162405.csv

... (comparison process) ...

=== Comparison complete ===
Execution time: 5 minute(s) 23 second(s)
```
