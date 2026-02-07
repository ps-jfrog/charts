#!/bin/bash

set -euo pipefail

# ============================================================================
# Compare and Reconcile: compare artifacts and optionally generate reconciliation scripts
# Extends compare-artifacts.sh with --collect-stats/--collect-properties and phased reconciliation.
# See plan.md and README.md in this directory.
# ============================================================================

# Comparison flags (0 = false, 1 = true)
export COMPARE_SOURCE_NEXUS="${COMPARE_SOURCE_NEXUS:-0}"
export COMPARE_TARGET_ARTIFACTORY_SH="${COMPARE_TARGET_ARTIFACTORY_SH:-0}"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="${COMPARE_TARGET_ARTIFACTORY_CLOUD:-0}"

# Discovery method for Artifactory (artifactory_aql or artifactory_filelist)
export ARTIFACTORY_DISCOVERY_METHOD="${ARTIFACTORY_DISCOVERY_METHOD:-artifactory_aql}"

# Optional: collect stats and properties on target (only with artifactory_aql)
export COLLECT_STATS_PROPERTIES="${COLLECT_STATS_PROPERTIES:-0}"

# Optional: generate reconciliation scripts after compare
export RECONCILE="${RECONCILE:-0}"

# Optional: directory for generated reconcile scripts (default: current directory)
export RECONCILE_OUTPUT_DIR="${RECONCILE_OUTPUT_DIR:-.}"

# Optional: when generating reconcile scripts, keep only commands that update the target instance
# (one-way: make target match source). Use with --reconcile.
export RECONCILE_TARGET_ONLY="${RECONCILE_TARGET_ONLY:-0}"

# Repos: ARTIFACTORY_REPOS applies to target; SH_ARTIFACTORY_REPOS / CLOUD_ARTIFACTORY_REPOS override per side when both are used (Case a)
export ARTIFACTORY_REPOS="${ARTIFACTORY_REPOS:-}"
export SH_ARTIFACTORY_REPOS="${SH_ARTIFACTORY_REPOS:-}"
export CLOUD_ARTIFACTORY_REPOS="${CLOUD_ARTIFACTORY_REPOS:-}"

export COMMAND_NAME="${COMMAND_NAME:-jf compare}"
export JFROG_CLI_LOG_LEVEL="${JFROG_CLI_LOG_LEVEL:-DEBUG}"
export JFROG_CLI_LOG_TIMESTAMP="${JFROG_CLI_LOG_TIMESTAMP:-DATE_AND_TIME}"
export NEXUS_REPOSITORIES_FILE="${NEXUS_REPOSITORIES_FILE:-repos.txt}"

# Views and output scripts for phased reconciliation (jfrog-cli-plugin-compare)
# Output names are numbered 01-09 so run order is obvious.
RECONCILE_VIEWS=(
    "reconcile_phase1_consolidate:01_to_consolidate.sh"
    "properties_reconcile_phase1_consolidate:02_to_consolidate_props.sh"
    "reconcile_phase2_sync:03_to_sync.sh"
    "properties_reconcile_phase2_sync:04_to_sync_props.sh"
    "reconcile_phase2_sync_delayed:05_to_sync_delayed.sh"
    "properties_reconcile_phase2_sync_delayed:06_to_sync_delayed_props.sh"
    "reconcile_stats_actionable:07_to_sync_stats.sh"
    "reconcile_download_stats:08_to_sync_download_stats.sh"
    "reconcile_folder_stats:09_to_sync_folder_stats.sh"
)

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Compares artifacts (Nexus/Artifactory SH/Artifactory Cloud) and optionally collects
stats/properties and generates phased reconciliation scripts (binaries, properties, statistics).

OPTIONS:
  --collect-stats-properties   Run 'jf compare list target --collect-stats --collect-properties'
                               after compare. Only valid when ARTIFACTORY_DISCOVERY_METHOD=artifactory_aql.
  --reconcile                  After compare (and optional collect), generate reconciliation scripts
                               (Phase 1, Phase 2, Phase 2b delayed, stats) from jf compare report.
  --target-only                With --reconcile: keep only commands that update the target instance (e.g. app2).
                               One-way sync: make target match source. Drops commands that update the source.
  -h, --help                   Show this help.

ENVIRONMENT (same as compare-artifacts.sh):
  COMPARE_SOURCE_NEXUS, COMPARE_TARGET_ARTIFACTORY_SH, COMPARE_TARGET_ARTIFACTORY_CLOUD
  SH_ARTIFACTORY_BASE_URL, SH_ARTIFACTORY_AUTHORITY, CLOUD_ARTIFACTORY_BASE_URL, CLOUD_ARTIFACTORY_AUTHORITY
  SOURCE_NEXUS_*, NEXUS_ADMIN_TOKEN or NEXUS_ADMIN_USERNAME/PASSWORD
  ARTIFACTORY_DISCOVERY_METHOD (default: artifactory_aql)
  SH_ARTIFACTORY_REPOS, CLOUD_ARTIFACTORY_REPOS  (comma-separated; optional)
  ARTIFACTORY_REPOS  (optional; used as target repos when set, else SH/CLOUD_ARTIFACTORY_REPOS per scenario)

RECONCILIATION:
  COLLECT_STATS_PROPERTIES=1   Same as --collect-stats-properties (only with artifactory_aql).
  RECONCILE=1                  Same as --reconcile.
  RECONCILE_TARGET_ONLY=1      Same as --target-only (filter scripts so only target-side commands remain).
  RECONCILE_OUTPUT_DIR=<dir>   Where to write to_*.sh scripts (default: current directory).

Reconciliation applies to specific Artifactory repositories when ARTIFACTORY_REPOS (or
CLOUD_ARTIFACTORY_REPOS / SH_ARTIFACTORY_REPOS for the target) is set; otherwise all repositories.
Order: compare first, then optional collect-stats/collect-properties, then optional reconcile scripts.
Generated scripts are numbered 01-09 in run order. Phase 1 (01_, 02_) -> Phase 2 (03_, 04_) -> Phase 2b delayed (05_, 06_) -> statistics (07_, 08_, 09_). Run in numeric order.
Requires: jf compare (jfrog-cli-plugin-compare), and jq for --reconcile.

EOF
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --collect-stats-properties)
            COLLECT_STATS_PROPERTIES=1
            shift
            ;;
        --reconcile)
            RECONCILE=1
            shift
            ;;
        --target-only)
            RECONCILE_TARGET_ONLY=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

START_TIME=$(date +%s)

# Validate comparison scenario
if [ "$COMPARE_SOURCE_NEXUS" == "0" ] && [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "0" ] && [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "0" ]; then
    echo "Error: At least one comparison flag must be enabled (COMPARE_SOURCE_NEXUS, COMPARE_TARGET_ARTIFACTORY_SH, COMPARE_TARGET_ARTIFACTORY_CLOUD)"
    echo "Run with -h for help"
    exit 1
fi

# Determine scenario and required vars (same as compare-artifacts.sh)
if [ "$COMPARE_SOURCE_NEXUS" == "0" ] && [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "1" ] && [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "1" ]; then
    COMPARISON_SCENARIO="artifactory-sh-to-cloud"
    REPORT_FILE="report-artifactory-sh-to-cloud.csv"
    SOURCE_AUTHORITY="${SH_ARTIFACTORY_AUTHORITY}"
    TARGET_AUTHORITY="${CLOUD_ARTIFACTORY_AUTHORITY}"
    # Target repos: ARTIFACTORY_REPOS or CLOUD_ARTIFACTORY_REPOS
    if [ -n "${ARTIFACTORY_REPOS:-}" ]; then
        TARGET_REPOS="${ARTIFACTORY_REPOS}"
    else
        TARGET_REPOS="${CLOUD_ARTIFACTORY_REPOS:-}"
    fi
    SH_LIST_REPOS="${SH_ARTIFACTORY_REPOS:-${ARTIFACTORY_REPOS:-}}"
    CLOUD_LIST_REPOS="${CLOUD_ARTIFACTORY_REPOS:-${ARTIFACTORY_REPOS:-}}"

    MISSING_VARS=()
    [ -z "${SH_ARTIFACTORY_BASE_URL:-}" ] && MISSING_VARS+=("SH_ARTIFACTORY_BASE_URL")
    [ -z "${SH_ARTIFACTORY_AUTHORITY:-}" ] && MISSING_VARS+=("SH_ARTIFACTORY_AUTHORITY")
    [ -z "${CLOUD_ARTIFACTORY_BASE_URL:-}" ] && MISSING_VARS+=("CLOUD_ARTIFACTORY_BASE_URL")
    [ -z "${CLOUD_ARTIFACTORY_AUTHORITY:-}" ] && MISSING_VARS+=("CLOUD_ARTIFACTORY_AUTHORITY")
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo "Error: Missing required env for Case a): ${MISSING_VARS[*]}. Run with -h for help."
        exit 1
    fi

elif [ "$COMPARE_SOURCE_NEXUS" == "1" ] && [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "0" ] && [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "1" ]; then
    COMPARISON_SCENARIO="nexus-to-cloud"
    REPORT_FILE="report-nexus-to-cloud.csv"
    SOURCE_AUTHORITY="${SOURCE_NEXUS_AUTHORITY}"
    TARGET_AUTHORITY="${CLOUD_ARTIFACTORY_AUTHORITY}"
    TARGET_REPOS="${ARTIFACTORY_REPOS:-${CLOUD_ARTIFACTORY_REPOS:-}}"
    CLOUD_LIST_REPOS="${CLOUD_ARTIFACTORY_REPOS:-${ARTIFACTORY_REPOS:-}}"
    SH_LIST_REPOS=""

    MISSING_VARS=()
    [ -z "${SOURCE_NEXUS_BASE_URL:-}" ] && MISSING_VARS+=("SOURCE_NEXUS_BASE_URL")
    [ -z "${SOURCE_NEXUS_AUTHORITY:-}" ] && MISSING_VARS+=("SOURCE_NEXUS_AUTHORITY")
    [ -z "${CLOUD_ARTIFACTORY_BASE_URL:-}" ] && MISSING_VARS+=("CLOUD_ARTIFACTORY_BASE_URL")
    [ -z "${CLOUD_ARTIFACTORY_AUTHORITY:-}" ] && MISSING_VARS+=("CLOUD_ARTIFACTORY_AUTHORITY")
    [ -z "${NEXUS_ADMIN_TOKEN:-}" ] && [ -z "${NEXUS_ADMIN_USERNAME:-}" ] && MISSING_VARS+=("NEXUS_CREDENTIALS")
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo "Error: Missing required env for Case b): ${MISSING_VARS[*]}. Run with -h for help."
        exit 1
    fi

elif [ "$COMPARE_SOURCE_NEXUS" == "1" ] && [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "1" ] && [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "0" ]; then
    COMPARISON_SCENARIO="nexus-to-sh"
    REPORT_FILE="report-nexus-to-sh.csv"
    SOURCE_AUTHORITY="${SOURCE_NEXUS_AUTHORITY}"
    TARGET_AUTHORITY="${SH_ARTIFACTORY_AUTHORITY}"
    TARGET_REPOS="${ARTIFACTORY_REPOS:-${SH_ARTIFACTORY_REPOS:-}}"
    SH_LIST_REPOS="${SH_ARTIFACTORY_REPOS:-${ARTIFACTORY_REPOS:-}}"
    CLOUD_LIST_REPOS=""

    MISSING_VARS=()
    [ -z "${SOURCE_NEXUS_BASE_URL:-}" ] && MISSING_VARS+=("SOURCE_NEXUS_BASE_URL")
    [ -z "${SOURCE_NEXUS_AUTHORITY:-}" ] && MISSING_VARS+=("SOURCE_NEXUS_AUTHORITY")
    [ -z "${SH_ARTIFACTORY_BASE_URL:-}" ] && MISSING_VARS+=("SH_ARTIFACTORY_BASE_URL")
    [ -z "${SH_ARTIFACTORY_AUTHORITY:-}" ] && MISSING_VARS+=("SH_ARTIFACTORY_AUTHORITY")
    [ -z "${NEXUS_ADMIN_TOKEN:-}" ] && [ -z "${NEXUS_ADMIN_USERNAME:-}" ] && MISSING_VARS+=("NEXUS_CREDENTIALS")
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo "Error: Missing required env for Case c): ${MISSING_VARS[*]}. Run with -h for help."
        exit 1
    fi
else
    echo "Warning: Unsupported combination of comparison flags. Use one of Case a/b/c. Run with -h for help."
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="${REPORT_FILE%.csv}-${TIMESTAMP}.csv"

echo "=== Compare and Reconcile ==="
echo "Scenario: $COMPARISON_SCENARIO | Discovery: $ARTIFACTORY_DISCOVERY_METHOD | Report: $REPORT_FILE"
echo "Collect stats/properties: $COLLECT_STATS_PROPERTIES | Generate reconcile scripts: $RECONCILE"
[ -n "$TARGET_REPOS" ] && echo "Target repos: $TARGET_REPOS"
echo ""

# ----------------------------------------------------------------------------
# Compare flow: init, authorities, credentials, list source and target(s)
# ----------------------------------------------------------------------------
$COMMAND_NAME init --clean

# Nexus source
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
        [ -z "${NEXUS_RUN_ID:-}" ] && echo "Error: NEXUS_RUN_ID required when using NEXUS_REPOSITORIES_FILE" && exit 1
        while IFS= read -r repo; do
            echo "Crawling repository: $repo"
            $COMMAND_NAME list "$SOURCE_NEXUS_AUTHORITY" --repository="$repo" --run-id="$NEXUS_RUN_ID"
        done < "$NEXUS_REPOSITORIES_FILE"
    else
        $COMMAND_NAME list "$SOURCE_NEXUS_AUTHORITY"
    fi
    echo ""
fi

# Artifactory SH (source in Case a, target in Case c)
if [ "$COMPARE_TARGET_ARTIFACTORY_SH" == "1" ]; then
    echo "=== Setting up Artifactory SH ==="
    $COMMAND_NAME authority-add "$SH_ARTIFACTORY_AUTHORITY" "$SH_ARTIFACTORY_BASE_URL"
    $COMMAND_NAME credentials-add "$SH_ARTIFACTORY_AUTHORITY" --cli-profile="$SH_ARTIFACTORY_AUTHORITY" --discovery="$ARTIFACTORY_DISCOVERY_METHOD"
    if [ "$ARTIFACTORY_DISCOVERY_METHOD" == "artifactory_aql" ]; then
        if [ -n "${SH_LIST_REPOS:-}" ]; then
            $COMMAND_NAME list "$SH_ARTIFACTORY_AUTHORITY" --repos="$SH_LIST_REPOS" --collect-stats --aql-style=sha1
        else
            $COMMAND_NAME list "$SH_ARTIFACTORY_AUTHORITY" --collect-stats --aql-style=sha1
        fi
    else
        if [ -n "${SH_LIST_REPOS:-}" ]; then
            $COMMAND_NAME list "$SH_ARTIFACTORY_AUTHORITY" --repos="$SH_LIST_REPOS"
        else
            $COMMAND_NAME list "$SH_ARTIFACTORY_AUTHORITY"
        fi
    fi
    echo ""
fi

# Artifactory Cloud (target in Case a and b)
if [ "$COMPARE_TARGET_ARTIFACTORY_CLOUD" == "1" ]; then
    echo "=== Setting up Artifactory Cloud ==="
    $COMMAND_NAME authority-add "$CLOUD_ARTIFACTORY_AUTHORITY" "$CLOUD_ARTIFACTORY_BASE_URL"
    $COMMAND_NAME credentials-add "$CLOUD_ARTIFACTORY_AUTHORITY" --cli-profile="$CLOUD_ARTIFACTORY_AUTHORITY" --discovery="$ARTIFACTORY_DISCOVERY_METHOD"
    if [ "$ARTIFACTORY_DISCOVERY_METHOD" == "artifactory_aql" ]; then
        if [ -n "${CLOUD_LIST_REPOS:-}" ]; then
            $COMMAND_NAME list "$CLOUD_ARTIFACTORY_AUTHORITY" --repos="$CLOUD_LIST_REPOS" --collect-stats --aql-style=sha1
        else
            $COMMAND_NAME list "$CLOUD_ARTIFACTORY_AUTHORITY" --collect-stats --aql-style=sha1
        fi
    else
        if [ -n "${CLOUD_LIST_REPOS:-}" ]; then
            $COMMAND_NAME list "$CLOUD_ARTIFACTORY_AUTHORITY" --repos="$CLOUD_LIST_REPOS"
        else
            $COMMAND_NAME list "$CLOUD_ARTIFACTORY_AUTHORITY"
        fi
    fi
    echo ""
fi

# ----------------------------------------------------------------------------
# Optional: collect-stats and collect-properties (artifactory_aql only)
# Collect on target; in Case a (SH->Cloud) also collect properties on source (SH)
# so the plugin can align source=SH, target=Cloud and emit property sync commands (04, 06).
# ----------------------------------------------------------------------------
if [ "$COLLECT_STATS_PROPERTIES" == "1" ]; then
    if [ "$ARTIFACTORY_DISCOVERY_METHOD" != "artifactory_aql" ]; then
        echo "Note: --collect-stats and --collect-properties are only supported with ARTIFACTORY_DISCOVERY_METHOD=artifactory_aql. Skipping."
    else
        # In Case a (SH->Cloud), collect properties on source (SH) so property sync views use source=SH, target=Cloud
        if [ "$COMPARISON_SCENARIO" == "artifactory-sh-to-cloud" ]; then
            echo "=== Collecting properties on source ($SOURCE_AUTHORITY) for property sync alignment ==="
            if [ -n "${SH_LIST_REPOS:-}" ]; then
                $COMMAND_NAME list "$SOURCE_AUTHORITY" --collect-properties --repos="$SH_LIST_REPOS"
            else
                $COMMAND_NAME list "$SOURCE_AUTHORITY" --collect-properties
            fi
            echo ""
        fi
        echo "=== Collecting stats and properties on target ($TARGET_AUTHORITY) ==="
        if [ -n "${TARGET_REPOS:-}" ]; then
            $COMMAND_NAME list "$TARGET_AUTHORITY" --collect-stats --collect-properties --repos="$TARGET_REPOS"
        else
            $COMMAND_NAME list "$TARGET_AUTHORITY" --collect-stats --collect-properties
        fi
        echo ""
    fi
fi

# ----------------------------------------------------------------------------
# CSV report
# ----------------------------------------------------------------------------
echo "=== Generating comparison report ==="
if command -v sqlite3 &> /dev/null && [ -f "comparison.db" ]; then
    sqlite3 comparison.db "SELECT * FROM mismatch;" --csv > "$REPORT_FILE"
    echo "Report generated: $REPORT_FILE"
else
    [ ! -f "comparison.db" ] && echo "Warning: comparison.db not found."
    command -v sqlite3 &> /dev/null || echo "Warning: sqlite3 not found. CSV report skipped."
fi

# ----------------------------------------------------------------------------
# Optional: generate reconciliation scripts
# ----------------------------------------------------------------------------
if [ "$RECONCILE" == "1" ]; then
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required for --reconcile. Install jq and re-run."
        exit 1
    fi
    OUT_DIR="${RECONCILE_OUTPUT_DIR}"
    mkdir -p "$OUT_DIR"
    [ "$RECONCILE_TARGET_ONLY" == "1" ] && echo "Filtering: target-only (one-way sync to $TARGET_AUTHORITY)"
    [ -n "${TARGET_REPOS:-}" ] && echo "Filtering: only repos in TARGET_REPOS (e.g. CLOUD_ARTIFACTORY_REPOS)"
    echo "=== Generating reconciliation scripts in $OUT_DIR ==="
    # Build grep -e "/repo" args for repo filter when TARGET_REPOS is set (path must reference one of these repos)
    REPO_GREP_ARGS=()
    if [ -n "${TARGET_REPOS:-}" ]; then
        while IFS=',' read -ra PARTS; do
            for p in "${PARTS[@]}"; do
                r=$(echo "$p" | tr -d ' ')
                [ -n "$r" ] && REPO_GREP_ARGS+=(-e "/$r")
            done
        done <<< "$TARGET_REPOS"
    fi
    for entry in "${RECONCILE_VIEWS[@]}"; do
        view="${entry%%:*}"
        outfile="${entry##*:}"
        outpath="$OUT_DIR/$outfile"
        tmpf=$(mktemp)
        $COMMAND_NAME report --jsonl "$view" 2>/dev/null | jq -r '.cmd' 2>/dev/null > "$tmpf" || true
        if [ "$RECONCILE_TARGET_ONLY" == "1" ]; then
            grep -F -e "--server-id=$TARGET_AUTHORITY" "$tmpf" > "${tmpf}.2" && mv "${tmpf}.2" "$tmpf"
        fi
        if [ ${#REPO_GREP_ARGS[@]} -gt 0 ]; then
            grep -F "${REPO_GREP_ARGS[@]}" "$tmpf" > "${tmpf}.2" && mv "${tmpf}.2" "$tmpf"
        fi
        sort -u "$tmpf" > "$outpath"
        rm -f "$tmpf" "${tmpf}.2"
        chmod +x "$outpath" 2>/dev/null || true
        echo "  $outfile"
    done
    echo "Done. Review and run scripts in numeric order (01_to_consolidate.sh ... 09_to_sync_folder_stats.sh)."
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
if [ $ELAPSED -lt 60 ]; then
    TIME_FMT="${ELAPSED}s"
elif [ $ELAPSED -lt 3600 ]; then
    TIME_FMT="$((ELAPSED/60))m $((ELAPSED%60))s"
else
    TIME_FMT="$((ELAPSED/3600))h $((ELAPSED%3600/60))m $((ELAPSED%60))s"
fi
echo ""
echo "=== Complete === Execution time: $TIME_FMT"
