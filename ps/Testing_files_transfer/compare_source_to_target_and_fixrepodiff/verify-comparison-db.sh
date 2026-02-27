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

show_help() {
  cat << 'EOF'
Usage: verify-comparison-db.sh --source <authority> [--repos <csv>]

Queries comparison.db via "jf compare query" to display:
  a) Exclusion rules
  c) Cross-instance mapping
  Reason-category counts (excluding delays) for the given source
  Per-repo report (when --repos is set):
    - Missing files count and listing (in source, not in target)
    - Delay files count and listing (deferred, e.g. Docker manifests)
    - Excluded files count and listing (skipped by exclusion rules)

Options:
  --source <authority>  Source authority name (e.g. app2).
  --repos <csv>         Comma-separated source repo names.
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

if ! jf compare query "SELECT 1" &>/dev/null; then
  echo "jf compare query not available (older plugin version); skipping verification queries."
  echo "Use sqlite3 with comparison.db instead. See QUICKSTART.md 'Inspecting comparison.db'."
  exit 0
fi

echo ""
echo "--- a) Exclusion rules ---"
jf compare query "SELECT id, pattern, reason, enabled, priority FROM exclusion_rules ORDER BY priority, id"

echo ""
echo "--- c) Cross-instance mapping ---"
jf compare query "SELECT source, source_repo, equivalence_key, target, target_repo, match_type, sync_type, source_artifact_count, target_artifact_count FROM cross_instance_mapping"

echo ""
echo "--- Exclusion counts by reason category (delays excluded) for source=${SOURCE} ---"
jf compare query "SELECT reason_category, COUNT(*) AS count FROM comparison_reasons WHERE reason_category != 'delay' AND source = '${SOURCE}' GROUP BY reason_category ORDER BY count DESC"

if [[ -n "$REPOS" ]]; then
  IFS=',' read -ra _repos <<< "$REPOS"
  for _repo in "${_repos[@]}"; do
    _repo="$(echo "$_repo" | xargs)"
    echo ""
    echo "=== Repository: $_repo ==="

    _missing_count=$(jf compare query --csv --header=false "SELECT COUNT(*) FROM missing WHERE source = '${SOURCE}' AND source_repo = '${_repo}'" 2>/dev/null | tr -d '[:space:]') || true
    echo ""
    echo "--- Missing files (in source, not in target): ${_missing_count:-0} ---"
    if [[ "${_missing_count:-0}" != "0" ]]; then
      jf compare query "SELECT source, source_repo, target, target_repo, path, sha1_source, size_source FROM missing WHERE source = '${SOURCE}' AND source_repo = '${_repo}' LIMIT 20"
    fi

    _delay_count=$(jf compare query --csv --header=false "SELECT COUNT(*) FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'delay'" 2>/dev/null | tr -d '[:space:]') || true
    echo ""
    echo "--- Delay files (deferred): ${_delay_count:-0} ---"
    if [[ "${_delay_count:-0}" != "0" ]]; then
      jf compare query "SELECT source, repository_name, uri, reason FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'delay' LIMIT 20"
    fi

    _excluded_count=$(jf compare query --csv --header=false "SELECT COUNT(*) FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'exclude'" 2>/dev/null | tr -d '[:space:]') || true
    echo ""
    echo "--- Excluded files (skipped by rules): ${_excluded_count:-0} ---"
    if [[ "${_excluded_count:-0}" != "0" ]]; then
      jf compare query "SELECT source, repository_name, uri, reason FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' AND reason_category = 'exclude' LIMIT 20"
    fi
  done
fi
