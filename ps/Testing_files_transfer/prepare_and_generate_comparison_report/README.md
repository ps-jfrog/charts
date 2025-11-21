# Prepare and Generate Repository Comparison Report

This script automates the preparation and generation of a comprehensive repository comparison report between source and target Artifactory instances. It streamlines steps 2-6 of the manual comparison process by automating storage calculation, data collection, and report generation.

## Purpose

This script automates the following tasks:
1. **Calculate storage information** for both source and target Artifactory instances
2. **Retrieve storage details** for all repositories in both instances
3. **Get repository lists** (local repositories by default, federated repositories optionally)
4. **Generate comparison report** comparing repositories between source and target

This automation saves time and reduces manual errors when preparing migration comparison reports.

## Prerequisites

Before running this script, ensure you have:

- **JFrog CLI** (`jf`) installed and configured
- **Python 3.x** installed
- **jq** command-line JSON processor (for parsing repository lists)
- Access to both source and target Artifactory instances
- Configured JFrog CLI server IDs for both instances
- The Python script `compare_repo_list_details_in_source_vs_target_rt_after_migration.py` in the same directory

### Verify Prerequisites

```bash
# Check JFrog CLI installation
jf --version

# Verify server configurations
jf c show

# Check Python installation
python --version

# Check jq installation
jq --version
```

## Installation

1. Ensure the script has execute permissions:
   ```bash
   chmod +x prepare_and_generate_comparison_report.sh
   ```

2. Verify the Python comparison script is in the same directory:
   ```bash
   ls -la compare_repo_list_details_in_source_vs_target_rt_after_migration.py
   ```

## Usage

### Basic Usage

```bash
./prepare_and_generate_comparison_report.sh [SOURCE_SERVER] [TARGET_SERVER]
```

### Arguments

- **`SOURCE_SERVER`** (optional): JFrog CLI server ID for the source Artifactory instance
  - Default: `source-server`
  - Can also be set via environment variable `SOURCE_SERVER`

- **`TARGET_SERVER`** (optional): JFrog CLI server ID for the target Artifactory instance
  - Default: `target-server`
  - Can also be set via environment variable `TARGET_SERVER`

### Usage Examples

#### Using Command-Line Arguments

```bash
./prepare_and_generate_comparison_report.sh my-source-server my-target-server
```

#### Using Environment Variables

```bash
SOURCE_SERVER=art-tools TARGET_SERVER=cloud-instance ./prepare_and_generate_comparison_report.sh
```

#### Using Defaults

```bash
# Uses default values: source-server and target-server
./prepare_and_generate_comparison_report.sh
```

#### View Help

```bash
./prepare_and_generate_comparison_report.sh --help
# or
./prepare_and_generate_comparison_report.sh -h
```

## What the Script Does

The script performs the following operations in sequence:

### 1. Calculate Storage Information
Triggers storage calculation for both source and target Artifactory instances:
```bash
jf rt curl -X POST "/api/storageinfo/calculate" --server-id="${SOURCE_SERVER}"
jf rt curl -X POST "/api/storageinfo/calculate" --server-id="${TARGET_SERVER}"
```

**Note**: Storage calculation may take approximately 2 minutes to complete. The script triggers the calculation but does not wait for completion. You can monitor progress in the Artifactory UI at `Admin Panel > Monitoring > Storage`.

### 2. Retrieve Repository Lists
Gets the list of local repositories from the source instance:
```bash
jf rt curl -X GET "/api/repositories?type=local" --server-id="${SOURCE_SERVER}" | jq -r '.[] | .key'
```

The list is saved to a timestamped file: `all-local-repo-source-YYYY-MM-DD-HH-MM-SS.txt`

**Note**: Federated repository collection is commented out but can be enabled by uncommenting the relevant section.

### 3. Retrieve Storage Details
Retrieves the calculated storage information for all repositories:
```bash
jf rt curl -X GET "/api/storageinfo" --server-id="${SOURCE_SERVER}" > source-storageinfo-YYYY-MM-DD-HH-MM-SS.json
jf rt curl -X GET "/api/storageinfo" --server-id="${TARGET_SERVER}" > target-storageinfo-YYYY-MM-DD-HH-MM-SS.json
```

### 4. Generate Comparison Report
Executes the Python comparison script to generate the detailed comparison report:
```bash
python compare_repo_list_details_in_source_vs_target_rt_after_migration.py \
    --source "${SOURCE_STORAGE_INFO}" \
    --target "${TARGET_STORAGE_INFO}" \
    --repos "${LOCAL_REPOS_FILE}" \
    --out "${COMPARISON_OUTPUT}" \
    --source_server_id "${SOURCE_SERVER}" \
    --target_server_id "${TARGET_SERVER}"
```

## Output Files

The script generates timestamped output files in the current directory:

| File | Description |
|------|-------------|
| `all-local-repo-source-YYYY-MM-DD-HH-MM-SS.txt` | List of local repositories from source instance |
| `all-federated-repos-in-source-YYYY-MM-DD-HH-MM-SS.txt` | List of federated repositories (if enabled) |
| `source-storageinfo-YYYY-MM-DD-HH-MM-SS.json` | Storage information for source instance |
| `target-storageinfo-YYYY-MM-DD-HH-MM-SS.json` | Storage information for target instance |
| `comparison-YYYY-MM-DD-HH-MM-SS.txt` | Generated comparison report |

## Important Notes

### Storage Calculation Timing

The storage calculation API is asynchronous. The script triggers the calculation but does not wait for it to complete. You should:

1. **Wait approximately 2 minutes** after the script triggers the calculation before proceeding, OR
2. **Monitor in the UI**: Go to `Admin Panel > Monitoring > Storage` and click the `Refresh` button to see when calculation completes

If you run the script and immediately retrieve storage info, you may get stale or incomplete data.

### Repository Types

- **Local repositories**: Collected by default
- **Federated repositories**: Collection is commented out but can be enabled by uncommenting lines 75-76 and 92-100

### Error Handling

The script uses `set -e`, which means it will exit immediately if any command fails. This ensures data integrity but requires all prerequisites to be properly configured.

## Troubleshooting

### Common Issues

#### Authentication Errors
**Error**: `Authentication failed` or `401 Unauthorized`

**Solution**:
- Verify JFrog CLI configuration: `jf c show`
- Ensure credentials are valid and have appropriate permissions
- Check if server IDs are correct

#### Storage Calculation Not Complete
**Issue**: Storage info shows old or incomplete data

**Solution**:
- Wait at least 2 minutes after triggering calculation
- Check calculation status in Artifactory UI: `Admin Panel > Monitoring > Storage`
- Re-run the storage info retrieval step manually if needed

#### Missing jq Command
**Error**: `jq: command not found`

**Solution**:
- Install jq: 
  - macOS: `brew install jq`
  - Linux: `sudo apt-get install jq` or `sudo yum install jq`
  - Or use alternative parsing methods (see readme.md for alternatives)

#### Python Script Not Found
**Error**: `python: can't open file 'compare_repo_list_details_in_source_vs_target_rt_after_migration.py'`

**Solution**:
- Ensure the Python script is in the same directory as the bash script
- Verify the script name is correct
- Check file permissions

#### Network/Timeout Issues
**Error**: Connection timeouts or network errors

**Solution**:
- Verify network connectivity to both Artifactory instances
- Check firewall rules
- Verify Artifactory URLs in JFrog CLI configuration
- For large instances, operations may take longer

### Debugging

To see more detailed output, you can modify the script to add verbose logging or run commands manually:

```bash
# Enable debug logging for JFrog CLI
export JFROG_CLI_LOG_LEVEL=DEBUG

# Run the script
./prepare_and_generate_comparison_report.sh source-server target-server
```

## Integration with Manual Process

This script automates steps 2-6 of the manual comparison process described in [readme.md](readme.md):

- **Step 2**: Calculate storage (automated)
- **Step 3**: Wait for calculation (manual - you need to wait ~2 minutes)
- **Step 4**: Generate storage details (automated)
- **Step 5**: Get repository list (automated)
- **Step 6**: Generate comparison report (automated)

After running this script, you can proceed with the remaining steps (7-12) from the main readme.md for further analysis and delta transfer.

## Best Practices

1. **Run during low-traffic periods**: Storage calculation can be resource-intensive
2. **Verify server IDs**: Double-check your JFrog CLI server configurations before running
3. **Monitor storage calculation**: Use the Artifactory UI to verify calculation completion
4. **Review output files**: Check the generated files to ensure they contain expected data
5. **Keep output files**: The timestamped files help track comparison history
6. **Test with small subsets**: For first-time use, consider testing with a filtered repository list

## Related Documentation

- [Main Comparison Report README](readme.md) - Complete manual process and detailed instructions
- [Repository Diff Documentation](../repoDiff/readme.md) - Understanding delta files and cleanpaths.txt
- [JFrog CLI Documentation](https://www.jfrog.com/confluence/display/CLI/JFrog+CLI)
- [Artifactory Storage Info API](https://www.jfrog.com/confluence/display/JFROG/Artifactory+REST+API#ArtifactoryRESTAPI-GetStorageSummaryInfo)

## Example Workflow

```bash
# 1. Navigate to the script directory
cd /path/to/AllReposComparisonReport

# 2. Verify prerequisites
jf c show
python --version
jq --version

# 3. Run the script
./prepare_and_generate_comparison_report.sh source-artifactory target-artifactory

# 4. Wait ~2 minutes for storage calculation (monitor in UI if needed)

# 5. Verify output files were created
ls -lh comparison-*.txt source-storageinfo-*.json target-storageinfo-*.json

# 6. Review the comparison report
cat comparison-YYYY-MM-DD-HH-MM-SS.txt

# 7. Proceed with remaining steps from readme.md
```

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review the main [readme.md](../AllReposComparisonReport/readme.md) for detailed process information
3. Verify all prerequisites are met
4. Check JFrog CLI and Artifactory logs for detailed error messages

