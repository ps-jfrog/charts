#!/bin/bash

set -euo pipefail

# ============================================================================
# CONFIGURATION GUIDE
# ============================================================================
# Based on your comparison scenario (a, b, or c), you MUST set the following
# environment variables before running this script:
#
# Case a) Compare Artifactory SH to Artifactory Cloud:
#   REQUIRED:
#     - SH_ARTIFACTORY_BASE_URL (e.g., "http://34.26.38.195/artifactory/")
#     - SH_ARTIFACTORY_AUTHORITY (e.g., "app1")
#     - CLOUD_ARTIFACTORY_BASE_URL (e.g., "http://34.23.57.82/artifactory/")
#     - CLOUD_ARTIFACTORY_AUTHORITY (e.g., "app2")
#   OPTIONAL:
#     - ARTIFACTORY_DISCOVERY_METHOD (default: "artifactory_aql")
#     - SH_ARTIFACTORY_REPOS (comma-separated list, e.g., "repo1,repo2,repo3")
#     - CLOUD_ARTIFACTORY_REPOS (comma-separated list, e.g., "repo1,repo2,repo3")
#
# Case b) Compare Nexus to Artifactory Cloud:
#   REQUIRED:
#     - SOURCE_NEXUS_BASE_URL (e.g., "https://support-team-aaronc-docker-0.jfrog.farm/nexus/")
#     - SOURCE_NEXUS_AUTHORITY (e.g., "stnexus")
#     - CLOUD_ARTIFACTORY_BASE_URL (e.g., "http://34.23.57.82/artifactory/")
#     - CLOUD_ARTIFACTORY_AUTHORITY (e.g., "app2")
#     - NEXUS_ADMIN_TOKEN (or NEXUS_ADMIN_USERNAME + NEXUS_ADMIN_PASSWORD)
#   OPTIONAL:
#     - NEXUS_REPOSITORIES_FILE (default: "repos.txt")
#     - NEXUS_RUN_ID (required if using repos.txt)
#     - ARTIFACTORY_DISCOVERY_METHOD (default: "artifactory_aql")
#     - CLOUD_ARTIFACTORY_REPOS (comma-separated list, e.g., "repo1,repo2,repo3")
#
# Case c) Compare Nexus to Artifactory SH:
#   REQUIRED:
#     - SOURCE_NEXUS_BASE_URL (e.g., "https://support-team-aaronc-docker-0.jfrog.farm/nexus/")
#     - SOURCE_NEXUS_AUTHORITY (e.g., "stnexus")
#     - SH_ARTIFACTORY_BASE_URL (e.g., "http://34.26.38.195/artifactory/")
#     - SH_ARTIFACTORY_AUTHORITY (e.g., "app1")
#     - NEXUS_ADMIN_TOKEN (or NEXUS_ADMIN_USERNAME + NEXUS_ADMIN_PASSWORD)
#   OPTIONAL:
#     - NEXUS_REPOSITORIES_FILE (default: "repos.txt")
#     - NEXUS_RUN_ID (required if using repos.txt)
#     - ARTIFACTORY_DISCOVERY_METHOD (default: "artifactory_aql")
#     - SH_ARTIFACTORY_REPOS (comma-separated list, e.g., "repo1,repo2,repo3")
# ============================================================================

# Comparison flags (0 = false, 1 = true) - MUST be set by user
export COMPARE_SOURCE_NEXUS="${COMPARE_SOURCE_NEXUS:-0}"
export COMPARE_TARGET_ARTIFACTORY_SH="${COMPARE_TARGET_ARTIFACTORY_SH:-0}"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="${COMPARE_TARGET_ARTIFACTORY_CLOUD:-0}"

# Discovery method for Artifactory instances (artifactory_aql or artifactory_filelist)
export ARTIFACTORY_DISCOVERY_METHOD="${ARTIFACTORY_DISCOVERY_METHOD:-artifactory_aql}"

# Command name (default to jf compare)
export COMMAND_NAME="${COMMAND_NAME:-jf compare}"

# Other optional settings with defaults
export JFROG_CLI_LOG_LEVEL="${JFROG_CLI_LOG_LEVEL:-DEBUG}"
export JFROG_CLI_LOG_TIMESTAMP="${JFROG_CLI_LOG_TIMESTAMP:-DATE_AND_TIME}"
export NEXUS_REPOSITORIES_FILE="${NEXUS_REPOSITORIES_FILE:-repos.txt}"

# Function to display help text
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

This script compares artifacts between different sources (Nexus, Artifactory SH, Artifactory Cloud)
using the JFrog CLI compare tool.

COMPARISON SCENARIOS:

Case a) Compare two Artifactory instances (no Nexus):
  # REQUIRED environment variables:
  export COMPARE_SOURCE_NEXUS="0"
  export COMPARE_TARGET_ARTIFACTORY_SH="1"
  export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
  export SH_ARTIFACTORY_BASE_URL="http://34.26.38.195/artifactory/"
  export SH_ARTIFACTORY_AUTHORITY="app1"
  export CLOUD_ARTIFACTORY_BASE_URL="http://34.23.57.82/artifactory/"
  export CLOUD_ARTIFACTORY_AUTHORITY="app2"
  
  # OPTIONAL (recommended for < 100K artifacts):
  export ARTIFACTORY_DISCOVERY_METHOD="artifactory_filelist"
  # OPTIONAL (filter specific repositories):
  export SH_ARTIFACTORY_REPOS="repo1,repo2,repo3"
  export CLOUD_ARTIFACTORY_REPOS="repo1,repo2,repo3"
  
  $0

Case b) Compare Nexus to Artifactory Cloud (no SH Artifactory):
  # REQUIRED environment variables:
  export COMPARE_SOURCE_NEXUS="1"
  export COMPARE_TARGET_ARTIFACTORY_SH="0"
  export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
  export SOURCE_NEXUS_BASE_URL="https://support-team-aaronc-docker-0.jfrog.farm/nexus/"
  export SOURCE_NEXUS_AUTHORITY="stnexus"
  export CLOUD_ARTIFACTORY_BASE_URL="http://34.23.57.82/artifactory/"
  export CLOUD_ARTIFACTORY_AUTHORITY="app2"
  export NEXUS_ADMIN_TOKEN="your-nexus-token-here"
  # OR use username/password:
  # export NEXUS_ADMIN_USERNAME="admin"
  # export NEXUS_ADMIN_PASSWORD="password"
  
  # OPTIONAL (if using repos.txt file):
  export NEXUS_REPOSITORIES_FILE="repos.txt"
  export NEXUS_RUN_ID="019a5a07-cedd-7e50-acb4-c51c1b0b1063"
  # OPTIONAL (filter specific Artifactory repositories):
  export CLOUD_ARTIFACTORY_REPOS="repo1,repo2,repo3"
  
  $0

Case c) Compare Nexus to Artifactory SH:
  # REQUIRED environment variables:
  export COMPARE_SOURCE_NEXUS="1"
  export COMPARE_TARGET_ARTIFACTORY_SH="1"
  export COMPARE_TARGET_ARTIFACTORY_CLOUD="0"
  export SOURCE_NEXUS_BASE_URL="https://support-team-aaronc-docker-0.jfrog.farm/nexus/"
  export SOURCE_NEXUS_AUTHORITY="stnexus"
  export SH_ARTIFACTORY_BASE_URL="http://34.26.38.195/artifactory/"
  export SH_ARTIFACTORY_AUTHORITY="app1"
  export NEXUS_ADMIN_TOKEN="your-nexus-token-here"
  # OR use username/password:
  # export NEXUS_ADMIN_USERNAME="admin"
  # export NEXUS_ADMIN_PASSWORD="password"
  
  # OPTIONAL (if using repos.txt file):
  export NEXUS_REPOSITORIES_FILE="repos.txt"
  export NEXUS_RUN_ID="019a5a07-cedd-7e50-acb4-c51c1b0b1063"
  # OPTIONAL (filter specific Artifactory repositories):
  export SH_ARTIFACTORY_REPOS="repo1,repo2,repo3"
  
  $0

ENVIRONMENT VARIABLES:

Required (set based on comparison scenario):
  COMPARE_SOURCE_NEXUS              - Enable Nexus as source (0 or 1)
  COMPARE_TARGET_ARTIFACTORY_SH     - Enable Artifactory SH as target (0 or 1)
  COMPARE_TARGET_ARTIFACTORY_CLOUD  - Enable Artifactory Cloud as target (0 or 1)

Case a) Required:
  SH_ARTIFACTORY_BASE_URL           - Artifactory SH base URL (e.g., "http://34.26.38.195/artifactory/")
  SH_ARTIFACTORY_AUTHORITY          - Artifactory SH authority name (e.g., "app1")
  CLOUD_ARTIFACTORY_BASE_URL        - Artifactory Cloud base URL (e.g., "http://34.23.57.82/artifactory/")
  CLOUD_ARTIFACTORY_AUTHORITY       - Artifactory Cloud authority name (e.g., "app2")

Case b) Required:
  SOURCE_NEXUS_BASE_URL             - Nexus base URL (e.g., "https://support-team-aaronc-docker-0.jfrog.farm/nexus/")
  SOURCE_NEXUS_AUTHORITY            - Nexus authority name (e.g., "stnexus")
  CLOUD_ARTIFACTORY_BASE_URL        - Artifactory Cloud base URL (e.g., "http://34.23.57.82/artifactory/")
  CLOUD_ARTIFACTORY_AUTHORITY       - Artifactory Cloud authority name (e.g., "app2")
  NEXUS_ADMIN_TOKEN                 - Nexus admin token
    OR
  NEXUS_ADMIN_USERNAME              - Nexus admin username
  NEXUS_ADMIN_PASSWORD              - Nexus admin password

Case c) Required:
  SOURCE_NEXUS_BASE_URL             - Nexus base URL (e.g., "https://support-team-aaronc-docker-0.jfrog.farm/nexus/")
  SOURCE_NEXUS_AUTHORITY            - Nexus authority name (e.g., "stnexus")
  SH_ARTIFACTORY_BASE_URL           - Artifactory SH base URL (e.g., "http://34.26.38.195/artifactory/")
  SH_ARTIFACTORY_AUTHORITY          - Artifactory SH authority name (e.g., "app1")
  NEXUS_ADMIN_TOKEN                 - Nexus admin token
    OR
  NEXUS_ADMIN_USERNAME              - Nexus admin username
  NEXUS_ADMIN_PASSWORD              - Nexus admin password

Optional (all scenarios):
  ARTIFACTORY_DISCOVERY_METHOD      - Discovery method: artifactory_aql or artifactory_filelist (default: artifactory_aql)
  COMMAND_NAME                      - Command to use (default: jf compare)
  NEXUS_REPOSITORIES_FILE           - File with Nexus repository list (default: repos.txt)
  NEXUS_RUN_ID                      - Run ID for grouping Nexus repositories (required if using repos.txt)
  SH_ARTIFACTORY_REPOS              - Comma-separated list of Artifactory SH repositories to compare (optional)
  CLOUD_ARTIFACTORY_REPOS           - Comma-separated list of Artifactory Cloud repositories to compare (optional)

DISCOVERY METHOD RECOMMENDATIONS:

⚠️  IMPORTANT: For instances with less than 100K artifacts, using 
   --discovery=artifactory_filelist is the most efficient method, because 
   --discovery=artifactory_aql crawl has too much overhead for smaller instances.

  --discovery=artifactory_filelist: Recommended for instances with < 100K artifacts (more efficient)
  --discovery=artifactory_aql: For larger instances, but has overhead for smaller instances

Note: The --collect-stats --aql-style=sha1 command is only executed when using 
      --discovery=artifactory_aql method.

OPTIONS:
  -h, --help    Show this help message

EOF
}

# Check for help flag
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

# Record start time for execution duration calculation
START_TIME=$(date +%s)

# Validate that at least one comparison scenario is enabled
if [ "$COMPARE_SOURCE_NEXUS" == "0" ] && [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "0" ] && [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "0" ]; then
    echo "Error: At least one comparison flag must be enabled (COMPARE_SOURCE_NEXUS, COMPARE_TARGET_ARTIFACTORY_SH, or COMPARE_TARGET_ARTIFACTORY_CLOUD)"
    echo "Run with -h for help"
    exit 1
fi

# Determine comparison scenario and validate required variables
if [ "$COMPARE_SOURCE_NEXUS" == "0" ] && [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "1" ] && [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "1" ]; then
    # Case a) Compare Artifactory SH to Artifactory Cloud
    COMPARISON_SCENARIO="artifactory-sh-to-cloud"
    REPORT_FILE="report-artifactory-sh-to-cloud.csv"
    
    # Validate required variables for Case a
    MISSING_VARS=()
    if [ -z "${SH_ARTIFACTORY_BASE_URL:-}" ]; then
        MISSING_VARS+=("SH_ARTIFACTORY_BASE_URL")
    fi
    if [ -z "${SH_ARTIFACTORY_AUTHORITY:-}" ]; then
        MISSING_VARS+=("SH_ARTIFACTORY_AUTHORITY")
    fi
    if [ -z "${CLOUD_ARTIFACTORY_BASE_URL:-}" ]; then
        MISSING_VARS+=("CLOUD_ARTIFACTORY_BASE_URL")
    fi
    if [ -z "${CLOUD_ARTIFACTORY_AUTHORITY:-}" ]; then
        MISSING_VARS+=("CLOUD_ARTIFACTORY_AUTHORITY")
    fi
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo "Error: The following required environment variables are missing for Case a) comparison:"
        for var in "${MISSING_VARS[@]}"; do
            case "$var" in
                SH_ARTIFACTORY_BASE_URL)
                    echo "  - SH_ARTIFACTORY_BASE_URL (Example: export SH_ARTIFACTORY_BASE_URL=\"http://34.26.38.195/artifactory/\")"
                    ;;
                SH_ARTIFACTORY_AUTHORITY)
                    echo "  - SH_ARTIFACTORY_AUTHORITY (Example: export SH_ARTIFACTORY_AUTHORITY=\"app1\")"
                    ;;
                CLOUD_ARTIFACTORY_BASE_URL)
                    echo "  - CLOUD_ARTIFACTORY_BASE_URL (Example: export CLOUD_ARTIFACTORY_BASE_URL=\"http://34.23.57.82/artifactory/\")"
                    ;;
                CLOUD_ARTIFACTORY_AUTHORITY)
                    echo "  - CLOUD_ARTIFACTORY_AUTHORITY (Example: export CLOUD_ARTIFACTORY_AUTHORITY=\"app2\")"
                    ;;
            esac
        done
        echo "Run with -h for help"
        exit 1
    fi
    # Set variables after validation
    SOURCE_AUTHORITY="${SH_ARTIFACTORY_AUTHORITY}"
    TARGET_AUTHORITY="${CLOUD_ARTIFACTORY_AUTHORITY}"
    
elif [ "$COMPARE_SOURCE_NEXUS" == "1" ] && [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "0" ] && [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "1" ]; then
    # Case b) Compare Nexus to Artifactory Cloud
    COMPARISON_SCENARIO="nexus-to-cloud"
    REPORT_FILE="report-nexus-to-cloud.csv"
    
    # Validate required variables for Case b
    MISSING_VARS=()
    if [ -z "${SOURCE_NEXUS_BASE_URL:-}" ]; then
        MISSING_VARS+=("SOURCE_NEXUS_BASE_URL")
    fi
    if [ -z "${SOURCE_NEXUS_AUTHORITY:-}" ]; then
        MISSING_VARS+=("SOURCE_NEXUS_AUTHORITY")
    fi
    if [ -z "${CLOUD_ARTIFACTORY_BASE_URL:-}" ]; then
        MISSING_VARS+=("CLOUD_ARTIFACTORY_BASE_URL")
    fi
    if [ -z "${CLOUD_ARTIFACTORY_AUTHORITY:-}" ]; then
        MISSING_VARS+=("CLOUD_ARTIFACTORY_AUTHORITY")
    fi
    if [ -z "${NEXUS_ADMIN_TOKEN:-}" ] && [ -z "${NEXUS_ADMIN_USERNAME:-}" ]; then
        MISSING_VARS+=("NEXUS_ADMIN_TOKEN_OR_CREDENTIALS")
    fi
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo "Error: The following required environment variables are missing for Case b) comparison:"
        for var in "${MISSING_VARS[@]}"; do
            case "$var" in
                SOURCE_NEXUS_BASE_URL)
                    echo "  - SOURCE_NEXUS_BASE_URL (Example: export SOURCE_NEXUS_BASE_URL=\"https://support-team-aaronc-docker-0.jfrog.farm/nexus/\")"
                    ;;
                SOURCE_NEXUS_AUTHORITY)
                    echo "  - SOURCE_NEXUS_AUTHORITY (Example: export SOURCE_NEXUS_AUTHORITY=\"stnexus\")"
                    ;;
                CLOUD_ARTIFACTORY_BASE_URL)
                    echo "  - CLOUD_ARTIFACTORY_BASE_URL (Example: export CLOUD_ARTIFACTORY_BASE_URL=\"http://34.23.57.82/artifactory/\")"
                    ;;
                CLOUD_ARTIFACTORY_AUTHORITY)
                    echo "  - CLOUD_ARTIFACTORY_AUTHORITY (Example: export CLOUD_ARTIFACTORY_AUTHORITY=\"app2\")"
                    ;;
                NEXUS_ADMIN_TOKEN_OR_CREDENTIALS)
                    echo "  - NEXUS_ADMIN_TOKEN (Example: export NEXUS_ADMIN_TOKEN=\"your-nexus-token-here\")"
                    echo "    OR NEXUS_ADMIN_USERNAME and NEXUS_ADMIN_PASSWORD"
                    echo "    (Example: export NEXUS_ADMIN_USERNAME=\"admin\""
                    echo "             export NEXUS_ADMIN_PASSWORD=\"password\")"
                    ;;
            esac
        done
        echo "Run with -h for help"
        exit 1
    fi
    # Set variables after validation
    SOURCE_AUTHORITY="${SOURCE_NEXUS_AUTHORITY}"
    TARGET_AUTHORITY="${CLOUD_ARTIFACTORY_AUTHORITY}"
    
elif [ "$COMPARE_SOURCE_NEXUS" == "1" ] && [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "1" ] && [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "0" ]; then
    # Case c) Compare Nexus to Artifactory SH
    COMPARISON_SCENARIO="nexus-to-sh"
    REPORT_FILE="report-nexus-to-sh.csv"
    
    # Validate required variables for Case c
    MISSING_VARS=()
    if [ -z "${SOURCE_NEXUS_BASE_URL:-}" ]; then
        MISSING_VARS+=("SOURCE_NEXUS_BASE_URL")
    fi
    if [ -z "${SOURCE_NEXUS_AUTHORITY:-}" ]; then
        MISSING_VARS+=("SOURCE_NEXUS_AUTHORITY")
    fi
    if [ -z "${SH_ARTIFACTORY_BASE_URL:-}" ]; then
        MISSING_VARS+=("SH_ARTIFACTORY_BASE_URL")
    fi
    if [ -z "${SH_ARTIFACTORY_AUTHORITY:-}" ]; then
        MISSING_VARS+=("SH_ARTIFACTORY_AUTHORITY")
    fi
    if [ -z "${NEXUS_ADMIN_TOKEN:-}" ] && [ -z "${NEXUS_ADMIN_USERNAME:-}" ]; then
        MISSING_VARS+=("NEXUS_ADMIN_TOKEN_OR_CREDENTIALS")
    fi
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo "Error: The following required environment variables are missing for Case c) comparison:"
        for var in "${MISSING_VARS[@]}"; do
            case "$var" in
                SOURCE_NEXUS_BASE_URL)
                    echo "  - SOURCE_NEXUS_BASE_URL (Example: export SOURCE_NEXUS_BASE_URL=\"https://support-team-aaronc-docker-0.jfrog.farm/nexus/\")"
                    ;;
                SOURCE_NEXUS_AUTHORITY)
                    echo "  - SOURCE_NEXUS_AUTHORITY (Example: export SOURCE_NEXUS_AUTHORITY=\"stnexus\")"
                    ;;
                SH_ARTIFACTORY_BASE_URL)
                    echo "  - SH_ARTIFACTORY_BASE_URL (Example: export SH_ARTIFACTORY_BASE_URL=\"http://34.26.38.195/artifactory/\")"
                    ;;
                SH_ARTIFACTORY_AUTHORITY)
                    echo "  - SH_ARTIFACTORY_AUTHORITY (Example: export SH_ARTIFACTORY_AUTHORITY=\"app1\")"
                    ;;
                NEXUS_ADMIN_TOKEN_OR_CREDENTIALS)
                    echo "  - NEXUS_ADMIN_TOKEN (Example: export NEXUS_ADMIN_TOKEN=\"your-nexus-token-here\")"
                    echo "    OR NEXUS_ADMIN_USERNAME and NEXUS_ADMIN_PASSWORD"
                    echo "    (Example: export NEXUS_ADMIN_USERNAME=\"admin\""
                    echo "             export NEXUS_ADMIN_PASSWORD=\"password\")"
                    ;;
            esac
        done
        echo "Run with -h for help"
        exit 1
    fi
    # Set variables after validation
    SOURCE_AUTHORITY="${SOURCE_NEXUS_AUTHORITY}"
    TARGET_AUTHORITY="${SH_ARTIFACTORY_AUTHORITY}"
    
else
    COMPARISON_SCENARIO="custom"
    REPORT_FILE="report-comparison.csv"
    echo "Warning: Custom comparison scenario detected. Please ensure all required variables are set."
fi

# Add datetime timestamp to report filename
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
# Insert timestamp before .csv extension
REPORT_FILE="${REPORT_FILE%.csv}-${TIMESTAMP}.csv"

echo "=== Comparison Scenario: $COMPARISON_SCENARIO ==="
echo "Discovery Method: $ARTIFACTORY_DISCOVERY_METHOD"
echo "Report File: $REPORT_FILE"
echo ""

# Initialize comparison
$COMMAND_NAME init --clean

# Setup Nexus source if enabled
if [ "$COMPARE_SOURCE_NEXUS" == "1" ]; then
    echo "=== Setting up Nexus source ==="
    $COMMAND_NAME authority-add "$SOURCE_NEXUS_AUTHORITY" "$SOURCE_NEXUS_BASE_URL"
    
    if [ -n "${NEXUS_ADMIN_TOKEN:-}" ]; then
        $COMMAND_NAME credentials-add "$SOURCE_NEXUS_AUTHORITY" --bearer-token="$NEXUS_ADMIN_TOKEN" --discovery=nexus_assets
    elif [ -n "${NEXUS_ADMIN_USERNAME:-}" ] && [ -n "${NEXUS_ADMIN_PASSWORD:-}" ]; then
        $COMMAND_NAME credentials-add "$SOURCE_NEXUS_AUTHORITY" --username="$NEXUS_ADMIN_USERNAME" --password="$NEXUS_ADMIN_PASSWORD" --discovery=nexus_assets
    else
        echo "Error: NEXUS_ADMIN_TOKEN or NEXUS_ADMIN_USERNAME and NEXUS_ADMIN_PASSWORD must be set"
        exit 1
    fi

    if [ -f "$NEXUS_REPOSITORIES_FILE" ]; then
        # Group all command executions, per-server, to a single run_id
        if [ -z "${NEXUS_RUN_ID:-}" ]; then
            echo "Error: NEXUS_RUN_ID is not set, generate a new one: https://uuidv7.org/"
            echo ""
            echo "Run the following command to set it (replace the example UUID with the one from the website):"
            echo "export NEXUS_RUN_ID=\"019a5a07-cedd-7e50-acb4-c51c1b0b1063\""
            echo ""
            echo "This is to group multiple repositories under a single run_id."
            exit 1
        fi

        while IFS= read -r repo; do
            echo "Crawling repository: $repo"
            
            if ! $COMMAND_NAME list "$SOURCE_NEXUS_AUTHORITY" --repository="$repo" --run-id="$NEXUS_RUN_ID"; then
                echo "Error crawling repository: $repo"
                exit 1
            fi
        done < "$NEXUS_REPOSITORIES_FILE"
    else
        $COMMAND_NAME list "$SOURCE_NEXUS_AUTHORITY"
    fi
    echo ""
fi

# Setup Artifactory SH target if enabled
if [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "1" ]; then
    echo "=== Setting up Artifactory SH target ==="
    $COMMAND_NAME authority-add "$SH_ARTIFACTORY_AUTHORITY" "$SH_ARTIFACTORY_BASE_URL"
    $COMMAND_NAME credentials-add "$SH_ARTIFACTORY_AUTHORITY" --cli-profile="$SH_ARTIFACTORY_AUTHORITY" --discovery="$ARTIFACTORY_DISCOVERY_METHOD"
    
    # Only run --collect-stats --aql-style=sha1 when using artifactory_aql discovery method
    if [ "$ARTIFACTORY_DISCOVERY_METHOD" == "artifactory_aql" ]; then
        if [ -n "${SH_ARTIFACTORY_REPOS:-}" ]; then
            $COMMAND_NAME list "$SH_ARTIFACTORY_AUTHORITY" --repos="$SH_ARTIFACTORY_REPOS" --collect-stats --aql-style=sha1
        else
            $COMMAND_NAME list "$SH_ARTIFACTORY_AUTHORITY" --collect-stats --aql-style=sha1
        fi
    else
        if [ -n "${SH_ARTIFACTORY_REPOS:-}" ]; then
            $COMMAND_NAME list "$SH_ARTIFACTORY_AUTHORITY" --repos="$SH_ARTIFACTORY_REPOS"
        else
            $COMMAND_NAME list "$SH_ARTIFACTORY_AUTHORITY"
        fi
    fi
    echo ""
fi

# Setup Artifactory Cloud target if enabled
if [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "1" ]; then
    echo "=== Setting up Artifactory Cloud target ==="
    $COMMAND_NAME authority-add "$CLOUD_ARTIFACTORY_AUTHORITY" "$CLOUD_ARTIFACTORY_BASE_URL"
    $COMMAND_NAME credentials-add "$CLOUD_ARTIFACTORY_AUTHORITY" --cli-profile="$CLOUD_ARTIFACTORY_AUTHORITY" --discovery="$ARTIFACTORY_DISCOVERY_METHOD"
    
    # Only run --collect-stats --aql-style=sha1 when using artifactory_aql discovery method
    if [ "$ARTIFACTORY_DISCOVERY_METHOD" == "artifactory_aql" ]; then
        if [ -n "${CLOUD_ARTIFACTORY_REPOS:-}" ]; then
            $COMMAND_NAME list "$CLOUD_ARTIFACTORY_AUTHORITY" --repos="$CLOUD_ARTIFACTORY_REPOS" --collect-stats --aql-style=sha1
        else
            $COMMAND_NAME list "$CLOUD_ARTIFACTORY_AUTHORITY" --collect-stats --aql-style=sha1
        fi
    else
        if [ -n "${CLOUD_ARTIFACTORY_REPOS:-}" ]; then
            $COMMAND_NAME list "$CLOUD_ARTIFACTORY_AUTHORITY" --repos="$CLOUD_ARTIFACTORY_REPOS"
        else
            $COMMAND_NAME list "$CLOUD_ARTIFACTORY_AUTHORITY"
        fi
    fi
    echo ""
fi

# Generate comparison report
echo "=== Generating comparison report ==="
if command -v sqlite3 &> /dev/null; then
    if [ -f "comparison.db" ]; then
        sqlite3 comparison.db "SELECT * FROM mismatch;" --csv > "$REPORT_FILE"
        echo "Report generated: $REPORT_FILE"
    else
        echo "Warning: comparison.db not found. Comparison may not have completed successfully."
    fi
else
    echo "Warning: sqlite3 not found. Cannot generate CSV report."
    echo "Comparison data is available in comparison.db"
fi

# Calculate and display execution time
END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))

# Format elapsed time in human-readable format
if [ $ELAPSED_TIME -lt 60 ]; then
    TIME_FORMATTED="${ELAPSED_TIME} seconds"
elif [ $ELAPSED_TIME -lt 3600 ]; then
    MINUTES=$((ELAPSED_TIME / 60))
    SECONDS=$((ELAPSED_TIME % 60))
    TIME_FORMATTED="${MINUTES} minute(s) ${SECONDS} second(s)"
else
    HOURS=$((ELAPSED_TIME / 3600))
    REMAINING=$((ELAPSED_TIME % 3600))
    MINUTES=$((REMAINING / 60))
    SECONDS=$((REMAINING % 60))
    TIME_FORMATTED="${HOURS} hour(s) ${MINUTES} minute(s) ${SECONDS} second(s)"
fi

echo ""
echo "=== Comparison complete ==="
echo "Execution time: $TIME_FORMATTED"
