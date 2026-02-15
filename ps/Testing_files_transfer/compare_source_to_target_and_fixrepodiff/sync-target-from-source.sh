#!/bin/bash
#
# One-shot script: automates QUICKSTART Steps 1–5 to sync target Artifactory
# to match source (compare plugin workflow). Runs compare-and-reconcile in
# b4-upload mode, runs before-upload reconciliation scripts, then
# compare-and-reconcile in after-upload mode, then after-upload scripts.
#
# Step 1: Environment variables must be set before invocation (or use --config).
# Step 2: compare-and-reconcile.sh --b4upload ...
# Step 3: Run 01–06 scripts via runcommand_in_parallel_from_file.sh
# Step 4: compare-and-reconcile.sh --after-upload ...
# Step 5: Run 07–09 scripts via runcommand_in_parallel_from_file.sh
#
# Usage:
#   export COMPARE_SOURCE_NEXUS=0 COMPARE_TARGET_ARTIFACTORY_SH=1 ...
#   ./sync-target-from-source.sh [OPTIONS]
#
# Or: ./sync-target-from-source.sh --config env.sh [OPTIONS]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECONCILE_BASE_DIR="${RECONCILE_BASE_DIR:-$SCRIPT_DIR}"
# B4_DIR and AFTER_DIR are set after config is sourced so RECONCILE_BASE_DIR from env.sh is respected
B4_DIR=""
AFTER_DIR=""
MAX_PARALLEL="${MAX_PARALLEL:-10}"
SKIP_CONSOLIDATION=0
SKIP_DELAYED=1
CONFIG_FILE=""
AQL_STYLE=""

show_help() {
  cat << EOF
Usage: $0 [OPTIONS]

Runs the full sync workflow (QUICKSTART Steps 2–5): compare-and-reconcile
(b4-upload) → run before-upload scripts (01–06) → compare-and-reconcile
(after-upload) → run after-upload scripts (07–09).

Step 1 (environment variables) must be done before running this script, or use --config.

OPTIONS:
  --config <file>       Source <file> before running (e.g. export COMPARE_* and REPO vars).
  --skip-consolidation  Do not run 01_to_consolidate.sh or 02_to_consolidate_props.sh.
  --run-delayed         Run 04_to_sync_delayed.sh (default: skip it).
  --max-parallel <N>    Max concurrent commands when running reconciliation scripts (default: 10).
  --aql-style <style>   AQL crawl style for 'jf compare list' (e.g. sha1-prefix). Passed to
                        compare-and-reconcile.sh. Also settable via env COMPARE_AQL_STYLE.
  -h, --help            Show this help.

ENVIRONMENT (Step 1 – set these or use --config):
  COMPARE_SOURCE_NEXUS, COMPARE_TARGET_ARTIFACTORY_SH, COMPARE_TARGET_ARTIFACTORY_CLOUD
  SH_ARTIFACTORY_BASE_URL, SH_ARTIFACTORY_AUTHORITY
  CLOUD_ARTIFACTORY_BASE_URL, CLOUD_ARTIFACTORY_AUTHORITY
  ARTIFACTORY_DISCOVERY_METHOD (default: artifactory_aql)
  Optional: SH_ARTIFACTORY_REPOS, CLOUD_ARTIFACTORY_REPOS (comma-separated)

OUTPUT DIRECTORIES (default: under script directory):
  RECONCILE_BASE_DIR   Base for both output dirs (default: script dir).
  b4_upload/           Before-upload scripts (01–06) and their logs.
  after_upload/        After-upload scripts (07–09) and their logs.

See README-sync-target-from-source.md for full documentation.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      ;;
    --config)
      [[ $# -lt 2 ]] && { echo "Error: --config requires <file>." >&2; exit 1; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --skip-consolidation)
      SKIP_CONSOLIDATION=1
      shift
      ;;
    --run-delayed)
      SKIP_DELAYED=0
      shift
      ;;
    --max-parallel)
      [[ $# -lt 2 ]] && { echo "Error: --max-parallel requires <N>." >&2; exit 1; }
      MAX_PARALLEL="$2"
      shift 2
      ;;
    --aql-style)
      [[ $# -lt 2 ]] && { echo "Error: --aql-style requires a value (e.g. sha1-prefix)." >&2; exit 1; }
      AQL_STYLE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

if [[ ! "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --max-parallel must be a positive integer." >&2
  exit 1
fi

# Step 1: Optional config file
if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE" >&2
    exit 1
  fi
  echo "Sourcing config: $CONFIG_FILE"
  set +u
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set -u
fi

# AQL style: CLI flag overrides env; env from config is also respected
[[ -n "$AQL_STYLE" ]] && export COMPARE_AQL_STYLE="$AQL_STYLE"

# Output dirs: respect RECONCILE_BASE_DIR from config or environment
RECONCILE_BASE_DIR="${RECONCILE_BASE_DIR:-$SCRIPT_DIR}"
B4_DIR="$RECONCILE_BASE_DIR/b4_upload"
AFTER_DIR="$RECONCILE_BASE_DIR/after_upload"

# Validate required env vars (Case a: Artifactory SH → Cloud)
if [[ "${COMPARE_SOURCE_NEXUS:-}" != "0" ]] || [[ "${COMPARE_TARGET_ARTIFACTORY_SH:-}" != "1" ]] || [[ "${COMPARE_TARGET_ARTIFACTORY_CLOUD:-}" != "1" ]]; then
  echo "Error: This script currently supports only Case a (Artifactory SH → Cloud). Set COMPARE_SOURCE_NEXUS=0, COMPARE_TARGET_ARTIFACTORY_SH=1, COMPARE_TARGET_ARTIFACTORY_CLOUD=1." >&2
  exit 1
fi
for v in SH_ARTIFACTORY_BASE_URL SH_ARTIFACTORY_AUTHORITY CLOUD_ARTIFACTORY_BASE_URL CLOUD_ARTIFACTORY_AUTHORITY; do
  if [[ -z "${!v:-}" ]]; then
    echo "Error: $v must be set." >&2
    exit 1
  fi
done

export ARTIFACTORY_DISCOVERY_METHOD="${ARTIFACTORY_DISCOVERY_METHOD:-artifactory_aql}"
mkdir -p "$B4_DIR" "$AFTER_DIR"

COMPARE_SCRIPT="$SCRIPT_DIR/compare-and-reconcile.sh"
RUNNER="$SCRIPT_DIR/runcommand_in_parallel_from_file.sh"
CONVERTER="$SCRIPT_DIR/convert_dl_upload_to_rt_cp.sh"
GROUPER="$SCRIPT_DIR/group_sync_by_sha1.sh"
if [[ ! -f "$COMPARE_SCRIPT" ]] || [[ ! -r "$COMPARE_SCRIPT" ]]; then
  echo "Error: compare-and-reconcile.sh not found or not readable: $COMPARE_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$RUNNER" ]] || [[ ! -r "$RUNNER" ]]; then
  echo "Error: runcommand_in_parallel_from_file.sh not found or not readable: $RUNNER" >&2
  exit 1
fi

# Same Artifactory instance (source and target URLs match) → use jf rt cp instead of dl+upload for 03
SH_URL_NORM="${SH_ARTIFACTORY_BASE_URL%/}"
CLOUD_URL_NORM="${CLOUD_ARTIFACTORY_BASE_URL%/}"
SAME_ARTIFACTORY_URL=0
[[ "$SH_URL_NORM" == "$CLOUD_URL_NORM" ]] && SAME_ARTIFACTORY_URL=1

run_script_if_exists() {
  local dir="$1"
  local name="$2"
  local out_log="${name%.sh}_out.txt"
  if [[ -f "$dir/$name" ]]; then
    echo "  Running $name ..."
    ( cd "$dir" && bash "$RUNNER" --log-success "./$name" "./$out_log" "$MAX_PARALLEL" )
  else
    echo "  Skipping $name (not generated)."
  fi
}

# Group a dl+upload script by SHA1 to eliminate duplicate downloads, then run the grouped version.
# Falls back to running the original script if the grouper is not available.
group_and_run_sync() {
  local dir="$1"
  local name="$2"
  if [[ ! -f "$dir/$name" ]]; then
    echo "  Skipping $name (not generated)."
    return
  fi
  local base="${name%.sh}"
  local grouped="${base}_grouped.sh"
  if [[ -f "$GROUPER" ]] && [[ -r "$GROUPER" ]]; then
    echo "  Grouping $name by SHA1 to reduce duplicate downloads ..."
    bash "$GROUPER" "$dir/$name"
    run_script_if_exists "$dir" "$grouped"
  else
    echo "  group_sync_by_sha1.sh not found; running $name without grouping" >&2
    run_script_if_exists "$dir" "$name"
  fi
}

# Step 2: Compare and reconcile (before-upload) — run from RECONCILE_BASE_DIR so comparison.db and reports are created there
echo "=== Step 2: Compare and reconcile (before-upload) ==="
export RECONCILE_OUTPUT_DIR="$B4_DIR"
( cd "$RECONCILE_BASE_DIR" && bash "$COMPARE_SCRIPT" --b4upload --collect-stats-properties --reconcile --target-only )

# Step 3: Before-upload reconciliation scripts
echo "=== Step 3: Before-upload reconciliation scripts ==="
if [[ "$SKIP_CONSOLIDATION" -eq 0 ]]; then
  run_script_if_exists "$B4_DIR" "01_to_consolidate.sh"
  run_script_if_exists "$B4_DIR" "02_to_consolidate_props.sh"
fi
if [[ "$SAME_ARTIFACTORY_URL" -eq 1 ]]; then
  # Same Artifactory: use jf rt cp (server-side copy, no temp files)
  if [[ -f "$B4_DIR/03_to_sync.sh" ]]; then
    if [[ -f "$CONVERTER" ]] && [[ -r "$CONVERTER" ]]; then
      echo "  Same Artifactory URL: generating 03_to_sync_using_copy.sh (jf rt cp) from 03_to_sync.sh ..."
      bash "$CONVERTER" "$B4_DIR/03_to_sync.sh"
      run_script_if_exists "$B4_DIR" "03_to_sync_using_copy.sh"
    else
      echo "  Same Artifactory URL but convert_dl_upload_to_rt_cp.sh not found; falling back to grouped dl+upload" >&2
      group_and_run_sync "$B4_DIR" "03_to_sync.sh"
    fi
  else
    echo "  Skipping 03_to_sync.sh (not generated)."
  fi
else
  # Different Artifactory URLs: group by SHA1 to avoid duplicate downloads, then dl+upload
  group_and_run_sync "$B4_DIR" "03_to_sync.sh"
fi
if [[ "$SKIP_DELAYED" -eq 0 ]]; then
  if [[ "$SAME_ARTIFACTORY_URL" -eq 1 ]]; then
    # Same Artifactory: use jf rt cp (server-side copy, no temp files)
    if [[ -f "$B4_DIR/04_to_sync_delayed.sh" ]]; then
      if [[ -f "$CONVERTER" ]] && [[ -r "$CONVERTER" ]]; then
        echo "  Same Artifactory URL: generating 04_to_sync_delayed_using_copy.sh (jf rt cp) from 04_to_sync_delayed.sh ..."
        bash "$CONVERTER" "$B4_DIR/04_to_sync_delayed.sh"
        run_script_if_exists "$B4_DIR" "04_to_sync_delayed_using_copy.sh"
      else
        echo "  Same Artifactory URL but convert_dl_upload_to_rt_cp.sh not found; falling back to grouped dl+upload" >&2
        group_and_run_sync "$B4_DIR" "04_to_sync_delayed.sh"
      fi
    else
      echo "  Skipping 04_to_sync_delayed.sh (not generated)."
    fi
  else
    # Different Artifactory URLs: group by SHA1 to avoid duplicate downloads, then dl+upload
    group_and_run_sync "$B4_DIR" "04_to_sync_delayed.sh"
  fi
fi
run_script_if_exists "$B4_DIR" "05_to_sync_stats.sh"
run_script_if_exists "$B4_DIR" "06_to_sync_folder_props.sh"

# Step 4: Compare and reconcile (after-upload) — run from RECONCILE_BASE_DIR so comparison.db and reports stay there
echo "=== Step 4: Compare and reconcile (after-upload) ==="
export RECONCILE_OUTPUT_DIR="$AFTER_DIR"
( cd "$RECONCILE_BASE_DIR" && bash "$COMPARE_SCRIPT" --after-upload --collect-stats-properties --reconcile --target-only )

# Step 5: After-upload reconciliation scripts
echo "=== Step 5: After-upload reconciliation scripts ==="
run_script_if_exists "$AFTER_DIR" "07_to_sync_download_stats.sh"
run_script_if_exists "$AFTER_DIR" "08_to_sync_props.sh"
run_script_if_exists "$AFTER_DIR" "09_to_sync_folder_stats_as_properties.sh"

echo ""
echo "=== Sync workflow complete ==="
echo "  Before-upload output: $B4_DIR"
echo "  After-upload output:  $AFTER_DIR"
echo "  Next: Verify from target (e.g. docker pull). See QUICKSTART.md Step 6."
