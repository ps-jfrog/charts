# compare-artifacts.sh

A bash script for comparing artifacts between different sources (Nexus or Artifactory) and Artifactory targets using the JFrog CLI compare tool.

## Overview

This script provides a flexible way to compare artifacts between:
- **Nexus** to Artifactory instances
- **Artifactory** to Artifactory instances

The script uses the `jf compare` command to perform the comparison and generates CSV reports with timestamped filenames to prevent overwriting previous results.

## Prerequisites

1. **JFrog CLI** installed and configured
   - The `jf compare` command must be available in your PATH
   - For Artifactory targets, you must have JFrog CLI profiles configured (e.g., `app1`, `app2`)

2. **Access credentials**:
   - For Nexus sources: Nexus admin token or username/password
   - For Artifactory targets: JFrog CLI profiles must be configured with appropriate credentials

3. **sqlite3** (optional but recommended):
   - Required for generating CSV reports from the comparison database
   - If not available, comparison data will still be in `comparison.db` but CSV export will be skipped


## Quick Start

### Case a) Compare Two Artifactory Instances

```bash
# Set required environment variables
export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="http://35.229.108.92/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export CLOUD_ARTIFACTORY_BASE_URL="http://34.73.108.59/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_filelist"

# Optional: Filter specific repositories
export SH_ARTIFACTORY_REPOS="docker-local,maven-releases"
export CLOUD_ARTIFACTORY_REPOS="docker-local,maven-releases"

# Run the script
./compare-artifacts.sh
```

### Case b) Compare Nexus to Artifactory Cloud

```bash
# Set required environment variables
export COMPARE_SOURCE_NEXUS="1"
export COMPARE_TARGET_ARTIFACTORY_SH="0"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SOURCE_NEXUS_BASE_URL="https://support-team-aaronc-docker-0.jfrog.farm/nexus/"
export SOURCE_NEXUS_AUTHORITY="stnexus"
export CLOUD_ARTIFACTORY_BASE_URL="http://34.73.108.59/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"
export NEXUS_ADMIN_TOKEN="your-nexus-token-here"

# Optional: Filter specific Artifactory repositories
export CLOUD_ARTIFACTORY_REPOS="docker-local,maven-releases"

# Run the script
./compare-artifacts.sh
```

### Case c) Compare Nexus to Artifactory SH

```bash
# Set required environment variables
export COMPARE_SOURCE_NEXUS="1"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="0"
export SOURCE_NEXUS_BASE_URL="https://support-team-aaronc-docker-0.jfrog.farm/nexus/"
export SOURCE_NEXUS_AUTHORITY="stnexus"
export SH_ARTIFACTORY_BASE_URL="http://35.229.108.92/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export NEXUS_ADMIN_TOKEN="your-nexus-token-here"

# Optional: Filter specific Artifactory repositories
export SH_ARTIFACTORY_REPOS="docker-local,maven-releases"

# Run the script
./compare-artifacts.sh
```

## Environment Variables

### Comparison Flags (Required)

These flags determine which comparison scenario to run:

- `COMPARE_SOURCE_NEXUS` - Enable Nexus as source (`0` or `1`)
- `COMPARE_TARGET_ARTIFACTORY_SH` - Enable Artifactory SH as target (`0` or `1`)
- `COMPARE_TARGET_ARTIFACTORY_CLOUD` - Enable Artifactory Cloud as target (`0` or `1`)

### Case a) Compare Artifactory SH to Artifactory Cloud:

**Required Variables**

- `SH_ARTIFACTORY_BASE_URL` - Artifactory SH base URL (e.g., `"http://35.229.108.92/artifactory/"`)
- `SH_ARTIFACTORY_AUTHORITY` - Artifactory SH authority name (e.g., `"app1"`)
- `CLOUD_ARTIFACTORY_BASE_URL` - Artifactory Cloud base URL (e.g., `"http://34.73.108.59/artifactory/"`)
- `CLOUD_ARTIFACTORY_AUTHORITY` - Artifactory Cloud authority name (e.g., `"app2"`)

### Case b) Compare Nexus to Artifactory Cloud:

**Required Variables**

- `SOURCE_NEXUS_BASE_URL` - Nexus base URL (e.g., `"https://support-team-aaronc-docker-0.jfrog.farm/nexus/"`)
- `SOURCE_NEXUS_AUTHORITY` - Nexus authority name (e.g., `"stnexus"`)
- `CLOUD_ARTIFACTORY_BASE_URL` - Artifactory Cloud base URL
- `CLOUD_ARTIFACTORY_AUTHORITY` - Artifactory Cloud authority name
- `NEXUS_ADMIN_TOKEN` - Nexus admin token
  - **OR** `NEXUS_ADMIN_USERNAME` + `NEXUS_ADMIN_PASSWORD`

### Case c) Compare Nexus to Artifactory SH:

**Required Variables**

- `SOURCE_NEXUS_BASE_URL` - Nexus base URL
- `SOURCE_NEXUS_AUTHORITY` - Nexus authority name
- `SH_ARTIFACTORY_BASE_URL` - Artifactory SH base URL
- `SH_ARTIFACTORY_AUTHORITY` - Artifactory SH authority name
- `NEXUS_ADMIN_TOKEN` - Nexus admin token
  - **OR** `NEXUS_ADMIN_USERNAME` + `NEXUS_ADMIN_PASSWORD`

### Optional Variables

- `ARTIFACTORY_DISCOVERY_METHOD` - Discovery method: `artifactory_aql` or `artifactory_filelist` (default: `artifactory_aql`)
- `COMMAND_NAME` - Command to use (default: `jf compare`)
- `NEXUS_REPOSITORIES_FILE` - File with Nexus repository list (default: `repos.txt`)
- `NEXUS_RUN_ID` - Run ID for grouping Nexus repositories (required if using `repos.txt`)
- `SH_ARTIFACTORY_REPOS` - Comma-separated list of Artifactory SH repositories to compare (e.g., `"repo1,repo2,repo3"`)
- `CLOUD_ARTIFACTORY_REPOS` - Comma-separated list of Artifactory Cloud repositories to compare (e.g., `"repo1,repo2,repo3"`)
- `JFROG_CLI_LOG_LEVEL` - Log level (default: `DEBUG`)
- `JFROG_CLI_LOG_TIMESTAMP` - Log timestamp format (default: `DATE_AND_TIME`)

## Discovery Method Selection

**Important:** For instances with less than 100K artifacts, using `--discovery=artifactory_filelist` is the most efficient method, because `--discovery=artifactory_aql` crawl has too much overhead for smaller instances.

- **`artifactory_filelist`**: Recommended for instances with < 100K artifacts (more efficient)
- **`artifactory_aql`**: For larger instances, but has overhead for smaller instances

**Note:** The `--collect-stats --aql-style=sha1` command is only executed when using `--discovery=artifactory_aql` method.

## Repository Filtering

You can filter comparisons to specific repositories when using Artifactory as source or target by setting the `--repos` parameter via environment variables:

- **`SH_ARTIFACTORY_REPOS`**: Comma-separated list of repositories for Artifactory SH (e.g., `"docker-local,maven-releases,npm-local"`)
- **`CLOUD_ARTIFACTORY_REPOS`**: Comma-separated list of repositories for Artifactory Cloud (e.g., `"docker-local,maven-releases,npm-local"`)

**Example:**
```bash
# Compare only specific repositories
export SH_ARTIFACTORY_REPOS="docker-local,maven-releases"
export CLOUD_ARTIFACTORY_REPOS="docker-local,maven-releases"
./compare-artifacts.sh
```

This is useful when you want to:
- Compare only specific repositories instead of all repositories
- Reduce comparison time by focusing on relevant repositories
- Test specific repository types (e.g., Docker, Maven, npm)

**Note:** The `--repos` parameter is passed to the `jf compare list` command when Artifactory is used as source (Case a) or target (Case b, c).

## Features

- **Automatic validation**: Validates all required environment variables based on the selected comparison scenario
- **Clear error messages**: Shows exactly which variables are missing with example values
- **Timestamped reports**: Report filenames include a datetime timestamp (format: `YYYYMMDD-HHMMSS`) to prevent overwriting previous reports
- **Execution time tracking**: Displays the total execution time at the end of the comparison
- **Flexible configuration**: Uses environment variables for all configuration, including CLI profile names
- **Help text**: Comprehensive help available with `-h` or `--help` flag

## Usage

### Basic Usage

```bash
# Set environment variables
export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="http://35.229.108.92/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export CLOUD_ARTIFACTORY_BASE_URL="http://34.73.108.59/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"

# Run the script
./compare-artifacts.sh
```

### View Help

```bash
./compare-artifacts.sh -h
# or
./compare-artifacts.sh --help
```

### Using Nexus Repository File

If you want to compare specific Nexus repositories, create a `repos.txt` file with one repository name per line:

```bash
# Create repos.txt
cat > repos.txt << EOF
docker-hosted
maven-releases
npm-releases
EOF

# Set NEXUS_RUN_ID (required when using repos.txt)
export NEXUS_RUN_ID="019a5a07-cedd-7e50-acb4-c51c1b0b1063"

# Run the script
./compare-artifacts.sh
```

## Output

### Report Files

The script generates CSV report files with the following naming convention:

- **Case a)**: `report-artifactory-sh-to-cloud-YYYYMMDD-HHMMSS.csv`
- **Case b)**: `report-nexus-to-cloud-YYYYMMDD-HHMMSS.csv`
- **Case c)**: `report-nexus-to-sh-YYYYMMDD-HHMMSS.csv`

The timestamp format (`YYYYMMDD-HHMMSS`) ensures each run creates a unique file, preventing overwriting of previous results.

### Console Output

The script provides detailed output including:

1. **Comparison scenario** and discovery method
2. **Report filename** that will be generated
3. **Progress messages** during setup and comparison
4. **Execution summary** with total time

**Example output:**
```
=== Comparison Scenario: artifactory-sh-to-cloud ===
Discovery Method: artifactory_filelist
Report File: report-artifactory-sh-to-cloud-20241118-162405.csv

=== Setting up Artifactory SH target ===
=== Setting up Artifactory Cloud target ===
=== Generating comparison report ===
Report generated: report-artifactory-sh-to-cloud-20241118-162405.csv

=== Comparison complete ===
Execution time: 5 minute(s) 23 second(s)
```

### Database File

The script also creates a `comparison.db` SQLite database file that contains the comparison data. This file can be queried directly if needed:

```bash
sqlite3 comparison.db "SELECT * FROM mismatch;"
```

## Error Handling

The script includes comprehensive error handling:

- **Missing variables**: Lists all missing required variables with example values
- **Invalid scenarios**: Validates that at least one comparison flag is enabled
- **Nexus credentials**: Checks for either token or username/password
- **Repository file**: Validates NEXUS_RUN_ID when using repos.txt
- **Command failures**: Exits on any command failure with clear error messages

**Example error output:**
```
Error: The following required environment variables are missing for Case a) comparison:
  - SH_ARTIFACTORY_BASE_URL (Example: export SH_ARTIFACTORY_BASE_URL="http://34.26.38.195/artifactory/")
  - SH_ARTIFACTORY_AUTHORITY (Example: export SH_ARTIFACTORY_AUTHORITY="app1")
Run with -h for help
```

## Troubleshooting


### Missing JFrog CLI Profiles

Ensure your JFrog CLI profiles are configured before running:

```bash
# Configure JFrog CLI profile
jf c add app1 --url="http://35.229.108.92/artifactory/" --user="admin" --password="password"

# Verify profile exists
jf c show app1
```

### sqlite3 Not Found

If `sqlite3` is not installed, the script will still run but won't generate CSV reports. The comparison data will be available in `comparison.db`. To generate CSV reports, you need to install `sqlite3`.

#### Installing sqlite3

**Linux:**

- **Debian/Ubuntu:**
  ```bash
  sudo apt-get update
  sudo apt-get install sqlite3
  ```

- **RHEL/CentOS/Fedora:**
  ```bash
  # RHEL/CentOS 7/8
  sudo yum install sqlite

  # RHEL/CentOS 9 or Fedora
  sudo dnf install sqlite
  ```

- **Alpine Linux:**
  ```bash
  sudo apk add sqlite
  ```

- **Arch Linux:**
  ```bash
  sudo pacman -S sqlite
  ```

**Windows:**

- **Using Chocolatey (if installed):**
  ```powershell
  choco install sqlite
  ```

- **Using Scoop (if installed):**
  ```powershell
  scoop install sqlite
  ```

- **Manual Installation:**
  1. Download precompiled binaries from [SQLite Downloads](https://www.sqlite.org/download.html)
  2. Download the "sqlite-tools-win-x64-*.zip" (or win-x86 for 32-bit)
  3. Extract the ZIP file
  4. Add the extracted folder to your PATH environment variable, or copy `sqlite3.exe` to a directory already in your PATH

**macOS:**

```bash
# Using Homebrew
brew install sqlite3
```

#### Verifying Installation

After installation, verify that `sqlite3` is available:

```bash
sqlite3 --version
```

Once installed, the script will automatically detect `sqlite3` and generate CSV reports on subsequent runs.

#### Alternative: Using the Database Directly

If `sqlite3` is not available, you can still query the database directly (if you have access to a system with sqlite3):

```bash
sqlite3 comparison.db "SELECT * FROM mismatch;" --csv > report.csv
```

### Nexus Authentication Issues

If Nexus authentication fails, verify your credentials:

```bash
# Test with token
curl -H "Authorization: Bearer $NEXUS_ADMIN_TOKEN" "$SOURCE_NEXUS_BASE_URL/service/rest/v1/status"

# Test with username/password
curl -u "$NEXUS_ADMIN_USERNAME:$NEXUS_ADMIN_PASSWORD" "$SOURCE_NEXUS_BASE_URL/service/rest/v1/status"
```

## Examples

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

./compare-artifacts.sh
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

./compare-artifacts.sh
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

./compare-artifacts.sh
```

**Output:** `report-nexus-to-sh-YYYYMMDD-HHMMSS.csv` (includes datetime timestamp)

## Related Documentation

- [Steps to Test File Transfer Between 2 JPDs](../steps_to_test_files_transfer_between_2_jpds.md) - Complete guide for file transfer testing
- [JFrog CLI Documentation](https://www.jfrog.com/confluence/display/CLI/JFrog+CLI) - Official JFrog CLI documentation

## License

This script is part of the jf-gcp-env project. See the main project LICENSE file for details.

