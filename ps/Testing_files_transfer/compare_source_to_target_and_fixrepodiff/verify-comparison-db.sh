#!/bin/bash
#
# Post-sync verification: queries comparison.db via "jf compare query" to
# display exclusion rules, repo mapping, reason-category counts, and a
# per-repo breakdown of missing files, delay files, and excluded files.
#
# Usage:
#   verify-comparison-db.sh --source <authority> [--repos <csv>]
#
# Options:
#   --source <authority>  Source authority name (e.g. app2). Used to filter
#                         reason-category counts and excluded-files queries.
#   --repos <csv>         Comma-separated list of source repo names. When set,
#                         a per-repo sample of excluded/delayed files is shown.
#   --no-limit            Show all files instead of the default first 20 per section.
#   --csv <dir>           Write CSV report files to <dir> (always full data, no row limit).
#   -h, --help            Show this help and exit.
#
# Environment:
#   SH_ARTIFACTORY_AUTHORITY  Fallback for --source when the flag is omitted.
#   SH_ARTIFACTORY_REPOS      Fallback for --repos when the flag is omitted.
#
# Requires: jf compare query (jfrog-cli-plugin-compare with query subcommand).
# If "jf compare query" is not available the script prints a note and exits 0.
#
# Can be run standalone or called from sync-target-from-source.sh.

set -euo pipefail

SOURCE="${SH_ARTIFACTORY_AUTHORITY:-}"
REPOS="${SH_ARTIFACTORY_REPOS:-}"
NO_LIMIT=0
CSV_DIR=""

show_help() {
  cat << 'EOF'
Usage: verify-comparison-db.sh --source <authority> [--repos <csv>] [--no-limit] [--csv <dir>]

Queries comparison.db via "jf compare query" to display:
  a) Exclusion rules
  c) Cross-instance mapping
  Per-repo report (when --repos is set):
    - Missing files count and listing (in source, not in target)
    - Delay files count and listing (deferred, e.g. Docker manifests)
    - Excluded files count and listing (skipped by exclusion rules)

By default, listings show the first 20 rows per section. Use --no-limit
to display all rows (full report).

Use --csv <dir> to write CSV report files (one per section per repo) to <dir>.
CSV files always contain the full data (no row limit), regardless of --no-limit.
The --no-limit flag only affects the on-screen display.

Options:
  --source <authority>  Source authority name (e.g. app2).
  --repos <csv>         Comma-separated source repo names.
  --no-limit            Show all files instead of the default first 20.
  --csv <dir>           Write CSV report files to <dir>.
  -h, --help            Show this help.

Environment fallbacks: SH_ARTIFACTORY_AUTHORITY (for --source),
SH_ARTIFACTORY_REPOS (for --repos).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -lt 2 ]] && { echo "Error: --source requires a value." >&2; exit 1; }
      SOURCE="$2"
      shift 2
      ;;
    --repos)
      [[ $# -lt 2 ]] && { echo "Error: --repos requires a comma-separated list." >&2; exit 1; }
      REPOS="$2"
      shift 2
      ;;
    --no-limit)
      NO_LIMIT=1
      shift
      ;;
    --csv)
      [[ $# -lt 2 ]] && { echo "Error: --csv requires a directory path." >&2; exit 1; }
      CSV_DIR="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE" ]]; then
  echo "Error: --source <authority> is required (or set SH_ARTIFACTORY_AUTHORITY)." >&2
  exit 1
fi

if [[ "$NO_LIMIT" -eq 1 ]]; then
  LIMIT_CLAUSE=""
else
  LIMIT_CLAUSE=" LIMIT 20"
fi

if [[ -n "$CSV_DIR" ]]; then
  mkdir -p "$CSV_DIR"
  echo "CSV report files will be written to: $CSV_DIR"
fi

write_csv() {
  local file="$1"
  local sql="$2"
  jf compare query --csv "$sql" > "$file"
  echo "  CSV: $file ($(( $(wc -l < "$file" | tr -d ' ') - 1 )) data rows)"
}

if ! jf compare query "SELECT 1" &>/dev/null; then
  echo "jf compare query not available (older plugin version); skipping verification queries."
  echo "Use sqlite3 with comparison.db instead. See QUICKSTART.md 'Inspecting comparison.db'."
  exit 0
fi

echo ""
echo "--- a) Exclusion rules ---"
jf compare query "SELECT id, pattern, reason, enabled, priority FROM exclusion_rules ORDER BY priority, id"
[[ -n "$CSV_DIR" ]] && write_csv "$CSV_DIR/exclusion_rules.csv" "SELECT id, pattern, reason, enabled, priority FROM exclusion_rules ORDER BY priority, id"

echo ""
echo "--- c) Cross-instance mapping ---"
jf compare query "SELECT source, source_repo, equivalence_key, target, target_repo, match_type, sync_type, source_artifact_count, target_artifact_count FROM cross_instance_mapping"
[[ -n "$CSV_DIR" ]] && write_csv "$CSV_DIR/cross_instance_mapping.csv" "SELECT source, source_repo, equivalence_key, target, target_repo, match_type, sync_type, source_artifact_count, target_artifact_count FROM cross_instance_mapping"

if [[ -n "$REPOS" ]]; then
  IFS=',' read -ra _repos <<< "$REPOS"
  for _repo in "${_repos[@]}"; do
    _repo="$(echo "$_repo" | xargs)"
    _repo_safe="${_repo//\//_}"
    echo ""
    echo "=== Repository: $_repo ==="

    _missing_count=$(jf compare query --csv --header=false "SELECT COUNT(*) FROM missing WHERE source = '${SOURCE}' AND source_repo = '${_repo}'" 2>/dev/null | tr -d '[:space:]') || true
    echo ""
    echo "--- Missing files (in source, not in target): ${_missing_count:-0} ---"
    if [[ "${_missing_count:-0}" != "0" ]]; then
      jf compare query "SELECT source, source_repo, target, target_repo, path, sha1_source, size_source FROM missing WHERE source = '${SOURCE}' AND source_repo = '${_repo}'${LIMIT_CLAUSE}"
      [[ -n "$CSV_DIR" ]] && write_csv "$CSV_DIR/${_repo_safe}_missing.csv" "SELECT source, source_repo, target, target_repo, path, sha1_source, size_source FROM missing WHERE source = '${SOURCE}' AND source_repo = '${_repo}'"
    fi

    _delay_count=$(jf compare query --csv --header=false "SELECT COUNT(*) FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'delay'" 2>/dev/null | tr -d '[:space:]') || true
    echo ""
    echo "--- Delay files (deferred): ${_delay_count:-0} ---"
    if [[ "${_delay_count:-0}" != "0" ]]; then
      jf compare query "SELECT source, repository_name, uri, reason FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'delay'${LIMIT_CLAUSE}"
      [[ -n "$CSV_DIR" ]] && write_csv "$CSV_DIR/${_repo_safe}_delay.csv" "SELECT source, repository_name, uri, reason FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'delay'"
    fi

    _excluded_count=$(jf compare query --csv --header=false "SELECT COUNT(*) FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'exclude'" 2>/dev/null | tr -d '[:space:]') || true
    echo ""
    echo "--- Excluded files (skipped by rules): ${_excluded_count:-0} ---"
    if [[ "${_excluded_count:-0}" != "0" ]]; then
      jf compare query "SELECT source, repository_name, uri, reason FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'exclude'${LIMIT_CLAUSE}"
      [[ -n "$CSV_DIR" ]] && write_csv "$CSV_DIR/${_repo_safe}_excluded.csv" "SELECT source, repository_name, uri, reason FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'exclude'"
    fi
  done

  if [[ "$NO_LIMIT" -eq 0 ]]; then
    echo ""
    echo "NOTE: Listings above show at most 20 rows per section. To see the full report, rerun with --no-limit:"
    echo "  bash verify-comparison-db.sh --source ${SOURCE} --repos \"${REPOS}\" --no-limit"
    echo "To also export CSV files, add --csv <dir>:"
    echo "  bash verify-comparison-db.sh --source ${SOURCE} --repos \"${REPOS}\" --no-limit --csv verification_csv"
  fi
fi
