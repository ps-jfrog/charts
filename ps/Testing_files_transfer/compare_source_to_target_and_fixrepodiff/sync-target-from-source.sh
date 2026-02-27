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

OVERALL_START=$(date +%s)

format_elapsed() {
  local secs=$(( $(date +%s) - $1 ))
  local h=$(( secs / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  local s=$(( secs % 60 ))
  if [[ $h -gt 0 ]]; then
    printf '%dh %dm %ds' $h $m $s
  elif [[ $m -gt 0 ]]; then
    printf '%dm %ds' $m $s
  else
    printf '%ds' $s
  fi
}

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
AQL_PAGE_SIZE=""
FOLDER_PARALLEL=""
INCLUDE_REMOTE_CACHE=""
GENERATE_ONLY=0
RUN_ONLY=0
RUN_FOLDER_STATS=0
VERIFICATION_CSV=""
VERIFICATION_CSV_ENABLED=0
VERIFICATION_NO_LIMIT=0

show_help() {
  cat << EOF
Usage: $0 [OPTIONS]

Runs the full sync workflow (QUICKSTART Steps 2–5): compare-and-reconcile
(b4-upload) → run before-upload scripts (01–06) → compare-and-reconcile
(after-upload) → run after-upload scripts (07–09).

Step 1 (environment variables) must be done before running this script, or use --config.

OPTIONS:
  --config <file>       Source <file> before running (e.g. export COMPARE_* and REPO vars).
  --generate-only       Run before-upload compare (Step 2) to generate scripts 01–06 but do NOT
                        execute any of them. Exit after printing a summary. Use --run-only later
                        to execute. Mutually exclusive with --run-only.
  --run-only            Skip before-upload compare (Step 2); execute previously generated
                        scripts (Steps 3–5). The output directory must already contain scripts
                        from a prior --generate-only run. Mutually exclusive with --generate-only.
  --skip-consolidation  Do not run 01_to_consolidate.sh or 02_to_consolidate_props.sh.
  --run-delayed         Run 04_to_sync_delayed.sh (default: skip it).
  --run-folder-stats    Run 09_to_sync_folder_stats_as_properties.sh in the after-upload phase
                        (default: skip it).
  --max-parallel <N>    Max concurrent commands when running reconciliation scripts (default: 10).
  --aql-style <style>   AQL crawl style for 'jf compare list' (e.g. sha1-prefix). Passed to
                        compare-and-reconcile.sh. Also settable via env COMPARE_AQL_STYLE.
  --aql-page-size <N>  AQL page size for 'jf compare list' (default 500). Larger values (e.g. 5000)
                        reduce round trips. Passed to compare-and-reconcile.sh. Also settable via env
                        COMPARE_AQL_PAGE_SIZE.
  --folder-parallel <N> Parallel workers for folder crawl in sha1-prefix mode (default 4). Useful
                        for large Docker repos with many sha256: folders. Passed to
                        compare-and-reconcile.sh. Also settable via env COMPARE_FOLDER_PARALLEL.
  --include-remote-cache  Include remote-cache repos in the crawl. Required when --repos names a
                        remote-cache repo (e.g. npmjs-remote-cache). Passed to compare-and-reconcile.sh.
                        Also settable via env COMPARE_INCLUDE_REMOTE_CACHE=1.
  --verification-csv [dir]  Write CSV report files during Step 6 verification (one file per
                        section per repo). If <dir> is omitted, defaults to RECONCILE_BASE_DIR.
                        Passed to verify-comparison-db.sh --csv.
  --verification-no-limit   Show all files in verification (Step 6) instead of the default first 20.
                        Passed to verify-comparison-db.sh --no-limit.
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

See README.md for full documentation.
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
    --aql-page-size)
      [[ $# -lt 2 ]] && { echo "Error: --aql-page-size requires a numeric value." >&2; exit 1; }
      AQL_PAGE_SIZE="$2"
      shift 2
      ;;
    --folder-parallel)
      [[ $# -lt 2 ]] && { echo "Error: --folder-parallel requires a numeric value." >&2; exit 1; }
      FOLDER_PARALLEL="$2"
      shift 2
      ;;
    --include-remote-cache)
      INCLUDE_REMOTE_CACHE=1
      shift
      ;;
    --generate-only)
      GENERATE_ONLY=1
      shift
      ;;
    --run-only)
      RUN_ONLY=1
      shift
      ;;
    --run-folder-stats)
      RUN_FOLDER_STATS=1
      shift
      ;;
    --verification-csv)
      VERIFICATION_CSV_ENABLED=1
      if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
        VERIFICATION_CSV="$2"
        shift 2
      else
        shift
      fi
      ;;
    --verification-no-limit)
      VERIFICATION_NO_LIMIT=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

if [[ "$GENERATE_ONLY" -eq 1 ]] && [[ "$RUN_ONLY" -eq 1 ]]; then
  echo "Error: --generate-only and --run-only are mutually exclusive." >&2
  exit 1
fi

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

# AQL page size: CLI flag overrides env; env from config is also respected
[[ -n "$AQL_PAGE_SIZE" ]] && export COMPARE_AQL_PAGE_SIZE="$AQL_PAGE_SIZE"

# Folder parallel: CLI flag overrides env; env from config is also respected
[[ -n "$FOLDER_PARALLEL" ]] && export COMPARE_FOLDER_PARALLEL="$FOLDER_PARALLEL"

# Include remote-cache: CLI flag overrides env; env from config is also respected
[[ -n "$INCLUDE_REMOTE_CACHE" ]] && export COMPARE_INCLUDE_REMOTE_CACHE="$INCLUDE_REMOTE_CACHE"

# Output dirs: respect RECONCILE_BASE_DIR from config or environment
RECONCILE_BASE_DIR="${RECONCILE_BASE_DIR:-$SCRIPT_DIR}"
B4_DIR="$RECONCILE_BASE_DIR/b4_upload"
AFTER_DIR="$RECONCILE_BASE_DIR/after_upload"

# Verification CSV: default dir to RECONCILE_BASE_DIR when flag is used without a path
if [[ "$VERIFICATION_CSV_ENABLED" -eq 1 ]] && [[ -z "$VERIFICATION_CSV" ]]; then
  VERIFICATION_CSV="$RECONCILE_BASE_DIR"
fi

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
FOLDER_PROPS_FILTER="$SCRIPT_DIR/filter_sync_only_folder_props.sh"
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
    local _start=$(date +%s)
    echo "  Running $name ..."
    ( cd "$dir" && bash "$RUNNER" --log-success "./$name" "./$out_log" "$MAX_PARALLEL" )
    echo "  [timing] $name completed in $(format_elapsed $_start)"
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
    local _gstart=$(date +%s)
    echo "  Grouping $name by SHA1 to reduce duplicate downloads ..."
    bash "$GROUPER" "$dir/$name"
    echo "  [timing] Grouping $name completed in $(format_elapsed $_gstart)"
    run_script_if_exists "$dir" "$grouped"
  else
    echo "  group_sync_by_sha1.sh not found; running $name without grouping" >&2
    run_script_if_exists "$dir" "$name"
  fi
}

run_verification() {
  local _start=$(date +%s)
  echo ""
  echo "=== Step 6: Post-sync verification (jf compare query) ==="
  VERIFY_SCRIPT="$SCRIPT_DIR/verify-comparison-db.sh"
  if [[ -f "$VERIFY_SCRIPT" ]] && [[ -r "$VERIFY_SCRIPT" ]]; then
    VERIFY_ARGS=(--source "$SH_ARTIFACTORY_AUTHORITY")
    [[ -n "${SH_ARTIFACTORY_REPOS:-}" ]] && VERIFY_ARGS+=(--repos "$SH_ARTIFACTORY_REPOS")
    [[ "$VERIFICATION_NO_LIMIT" -eq 1 ]] && VERIFY_ARGS+=(--no-limit)
    [[ -n "$VERIFICATION_CSV" ]] && VERIFY_ARGS+=(--csv "$VERIFICATION_CSV")
    ( cd "$RECONCILE_BASE_DIR" && bash "$VERIFY_SCRIPT" "${VERIFY_ARGS[@]}" )
  else
    echo "  verify-comparison-db.sh not found; skipping verification queries." >&2
    echo "  Use sqlite3 with comparison.db instead. See QUICKSTART.md 'Inspecting comparison.db'."
  fi
  echo "[timing] Step 6 (verification queries) completed in $(format_elapsed $_start)"
}

# Step 2: Compare and reconcile (before-upload) — run from RECONCILE_BASE_DIR so comparison.db and reports are created there
STEP2_START=$(date +%s)
if [[ "$RUN_ONLY" -eq 1 ]]; then
  echo "=== Step 2: Skipped (--run-only) ==="
  if [[ ! -d "$B4_DIR" ]]; then
    echo "Error: Before-upload output directory not found: $B4_DIR" >&2
    echo "  Run with --generate-only first to create it." >&2
    exit 1
  fi
else
  echo "=== Step 2: Compare and reconcile (before-upload) ==="
  export RECONCILE_OUTPUT_DIR="$B4_DIR"
  ( cd "$RECONCILE_BASE_DIR" && bash "$COMPARE_SCRIPT" --b4upload --collect-stats-properties --reconcile --target-only )
fi
echo "[timing] Step 2 (before-upload compare) completed in $(format_elapsed $STEP2_START)"

# --generate-only: print summary and exit before executing any scripts
if [[ "$GENERATE_ONLY" -eq 1 ]]; then
  echo ""
  echo "=== --generate-only: scripts generated in $B4_DIR ==="
  for f in "$B4_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    local_name="$(basename "$f")"
    lines=$(wc -l < "$f" | tr -d ' ')
    echo "  $local_name  ($lines lines)"
  done
  echo ""
  echo "Review these scripts, then run with --run-only to execute Steps 3–5."
  run_verification
  echo ""
  echo "[timing] Total elapsed: $(format_elapsed $OVERALL_START)"
  exit 0
fi

# Step 3: Before-upload reconciliation scripts
STEP3_START=$(date +%s)
echo "=== Step 3: Before-upload reconciliation scripts ==="
if [[ "$SKIP_CONSOLIDATION" -eq 0 ]]; then
  run_script_if_exists "$B4_DIR" "01_to_consolidate.sh"
  run_script_if_exists "$B4_DIR" "02_to_consolidate_props.sh"
fi
if [[ "$SAME_ARTIFACTORY_URL" -eq 1 ]]; then
  # Same Artifactory: use jf rt cp (server-side copy, no temp files)
  if [[ -f "$B4_DIR/03_to_sync.sh" ]]; then
    if [[ -f "$CONVERTER" ]] && [[ -r "$CONVERTER" ]]; then
      local_conv_start=$(date +%s)
      echo "  Same Artifactory URL: generating 03_to_sync_using_copy.sh (jf rt cp) from 03_to_sync.sh ..."
      bash "$CONVERTER" "$B4_DIR/03_to_sync.sh"
      echo "  [timing] Converting 03_to_sync.sh → 03_to_sync_using_copy.sh completed in $(format_elapsed $local_conv_start)"
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
        local_conv_start=$(date +%s)
        echo "  Same Artifactory URL: generating 04_to_sync_delayed_using_copy.sh (jf rt cp) from 04_to_sync_delayed.sh ..."
        bash "$CONVERTER" "$B4_DIR/04_to_sync_delayed.sh"
        echo "  [timing] Converting 04_to_sync_delayed.sh → 04_to_sync_delayed_using_copy.sh completed in $(format_elapsed $local_conv_start)"
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
if [[ -f "$B4_DIR/06_to_sync_folder_props.sh" ]]; then
  if [[ -f "$FOLDER_PROPS_FILTER" ]] && [[ -r "$FOLDER_PROPS_FILTER" ]]; then
    local_filter_start=$(date +%s)
    echo "  Filtering 06_to_sync_folder_props.sh to exclude sync.*-only lines ..."
    bash "$FOLDER_PROPS_FILTER" "$B4_DIR/06_to_sync_folder_props.sh"
    echo "  [timing] Filtering 06_to_sync_folder_props.sh completed in $(format_elapsed $local_filter_start)"
    run_script_if_exists "$B4_DIR" "06a_lines_other_than_only_sync_folder_props.sh"
  else
    echo "  filter_sync_only_folder_props.sh not found; running 06_to_sync_folder_props.sh as-is" >&2
    run_script_if_exists "$B4_DIR" "06_to_sync_folder_props.sh"
  fi
else
  echo "  Skipping 06_to_sync_folder_props.sh (not generated)."
fi
echo "[timing] Step 3 (before-upload reconciliation) completed in $(format_elapsed $STEP3_START)"

# Step 4: Compare and reconcile (after-upload) — run from RECONCILE_BASE_DIR so comparison.db and reports stay there
STEP4_START=$(date +%s)
echo "=== Step 4: Compare and reconcile (after-upload) ==="
export RECONCILE_OUTPUT_DIR="$AFTER_DIR"
( cd "$RECONCILE_BASE_DIR" && bash "$COMPARE_SCRIPT" --after-upload --collect-stats-properties --reconcile --target-only )
echo "[timing] Step 4 (after-upload compare) completed in $(format_elapsed $STEP4_START)"

# Step 5: After-upload reconciliation scripts
STEP5_START=$(date +%s)
echo "=== Step 5: After-upload reconciliation scripts ==="
run_script_if_exists "$AFTER_DIR" "07_to_sync_download_stats.sh"
run_script_if_exists "$AFTER_DIR" "08_to_sync_props.sh"
if [[ "$RUN_FOLDER_STATS" -eq 1 ]]; then
  run_script_if_exists "$AFTER_DIR" "09_to_sync_folder_stats_as_properties.sh"
else
  echo "  Skipping 09_to_sync_folder_stats_as_properties.sh (use --run-folder-stats to include)."
fi
echo "[timing] Step 5 (after-upload reconciliation) completed in $(format_elapsed $STEP5_START)"

run_verification

echo ""
echo "=== Sync workflow complete ==="
echo "  Before-upload output: $B4_DIR"
echo "  After-upload output:  $AFTER_DIR"
echo "  Next: Verify from target (e.g. docker pull). See QUICKSTART.md Step 6."
echo ""
echo "[timing] Total elapsed: $(format_elapsed $OVERALL_START)"
