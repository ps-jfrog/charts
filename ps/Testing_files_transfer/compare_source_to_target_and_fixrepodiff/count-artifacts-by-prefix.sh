#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# count-artifacts-by-prefix.sh
#
# Count the total number of file artifacts in Artifactory matching a SHA1
# prefix. Uses a single unbounded AQL query for an exact count; falls back
# to paginated queries only when results exceed the server's default limit.
# Optionally filter by repository.
#
# Usage:
#   bash count-artifacts-by-prefix.sh \
#     --prefix <sha1-prefix> --server-id <id> \
#     [--repo <repo-name>[,<repo-name>...]] [--page-size <n>]
#
# Options:
#   --prefix       SHA1 prefix to match (e.g. f2, 00, ab) (required)
#   --server-id    JFrog CLI server ID (required)
#   --repo         Repository name(s) to filter by, comma-separated
#                  (optional; omit for all repos)
#   --page-size    AQL pagination size (default: 10000)
#   -h, --help     Show this help message
#
# Examples:
#   # Count for a specific repo and prefix
#   bash count-artifacts-by-prefix.sh \
#     --prefix f2 --server-id psazuse --repo npmjs-remote-cache
#
#   # Count for multiple repos and prefix
#   bash count-artifacts-by-prefix.sh \
#     --prefix f2 --server-id psazuse --repo repo-a,repo-b,repo-c
#
#   # Count across all repos for a prefix
#   bash count-artifacts-by-prefix.sh \
#     --prefix f2 --server-id psazuse
#
#   # Custom page size
#   bash count-artifacts-by-prefix.sh \
#     --prefix 00 --server-id onprem2 --repo maven-local --page-size 5000
###############################################################################

PREFIX=""
SERVER_ID=""
REPO=""
PAGE_SIZE=10000

usage() {
  sed -n '/^# Usage:/,/^###/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)     PREFIX="$2";    shift 2 ;;
    --server-id)  SERVER_ID="$2"; shift 2 ;;
    --repo)       REPO="$2";     shift 2 ;;
    --page-size)  PAGE_SIZE="$2"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *)            echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$PREFIX" ]]    && { echo "Error: --prefix is required" >&2; usage 1; }
[[ -z "$SERVER_ID" ]] && { echo "Error: --server-id is required" >&2; usage 1; }

repo_filter=""
repo_label="all repos"
if [[ -n "$REPO" ]]; then
  IFS=',' read -ra REPO_ARRAY <<< "$REPO"
  if [[ ${#REPO_ARRAY[@]} -eq 1 ]]; then
    repo_filter=", \"repo\": \"${REPO_ARRAY[0]}\""
  else
    or_parts=""
    for r in "${REPO_ARRAY[@]}"; do
      [[ -n "$or_parts" ]] && or_parts="$or_parts, "
      or_parts="${or_parts}{\"repo\": \"${r}\"}"
    done
    repo_filter=", \"\$or\": [${or_parts}]"
  fi
  repo_label="repo=${REPO}"
fi

echo "Counting artifacts for prefix=$PREFIX $repo_label (server: $SERVER_ID, page size: $PAGE_SIZE) ..."

tmp_aql="$(mktemp)"
tmp_raw="$(mktemp)"

# --- Phase 1: single unbounded query (most accurate for < server limit) ---
cat > "$tmp_aql" <<EOF
items.find({"type": "file", "actual_sha1": {"\$match": "${PREFIX}*"}${repo_filter}}).include("name").offset(0)
EOF

jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" \
  -d @"$tmp_aql" --server-id="$SERVER_ID" > "$tmp_raw" 2>/dev/null

if ! range_total=$(jq '.range.total' "$tmp_raw" 2>/dev/null); then
  echo "  ERROR — AQL response is not valid JSON:" >&2
  head -3 "$tmp_raw" >&2
  rm -f "$tmp_aql" "$tmp_raw"
  exit 1
fi

range_limit=$(jq '.range.limit' "$tmp_raw" 2>/dev/null || echo 0)
rm -f "$tmp_aql" "$tmp_raw"

if [[ "$range_total" -lt "$range_limit" ]]; then
  # All results fit in a single response — exact count
  echo ""
  echo "Total: $range_total items for prefix=$PREFIX $repo_label  (single query)"
  exit 0
fi

# --- Phase 2: result hit the server limit — fall back to paginated counting ---
echo "  Result count ($range_total) reached server limit ($range_limit) — switching to paginated counting ..."
echo "  Note: concurrent writes to the repo may cause a slight over/under-count."
echo ""

offset=0
total=0

while true; do
  cat > "$tmp_aql" <<EOF
items.find({"type": "file", "actual_sha1": {"\$match": "${PREFIX}*"}${repo_filter}}).include("repo","path","name").sort({"\$asc":["repo","path","name"]}).offset(${offset}).limit(${PAGE_SIZE})
EOF

  jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" \
    -d @"$tmp_aql" --server-id="$SERVER_ID" > "$tmp_raw" 2>/dev/null

  if ! batch=$(jq '.results | length' "$tmp_raw" 2>/dev/null); then
    echo "  ERROR at offset=$offset — AQL response is not valid JSON:" >&2
    head -3 "$tmp_raw" >&2
    rm -f "$tmp_aql" "$tmp_raw"
    break
  fi

  total=$((total + batch))
  echo "  offset=$offset  batch=$batch  running_total=$total"

  if [[ "$batch" -lt "$PAGE_SIZE" ]]; then
    break
  fi
  offset=$((offset + PAGE_SIZE))
done

rm -f "$tmp_aql" "$tmp_raw"

echo ""
echo "Total: $total items for prefix=$PREFIX $repo_label  (paginated)"
