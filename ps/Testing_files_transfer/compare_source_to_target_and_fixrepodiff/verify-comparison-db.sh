#!/bin/bash
#
# Post-sync verification: queries comparison.db via "jf compare query" to
# display exclusion rules, repo mapping, reason-category counts, and a
# sample of excluded/delayed files.
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
  Excluded/delayed files sample per repo (when --repos is set)

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
echo "--- Count grouped by reason category (excluding delays) for source=${SOURCE} ---"
jf compare query "SELECT reason_category, COUNT(*) AS count FROM comparison_reasons WHERE reason_category != 'delay' AND source = '${SOURCE}' GROUP BY reason_category ORDER BY count DESC"

if [[ -n "$REPOS" ]]; then
  echo ""
  echo "--- Excluded files sample (source=${SOURCE}, per repo) ---"
  IFS=',' read -ra _repos <<< "$REPOS"
  for _repo in "${_repos[@]}"; do
    _repo="$(echo "$_repo" | xargs)"
    echo ""
    echo "  Repository: $_repo"
    jf compare query "SELECT source, repository_name, uri, reason, reason_category FROM comparison_reasons WHERE source = '${SOURCE}' AND repository_name = '${_repo}' LIMIT 10"
  done
fi
