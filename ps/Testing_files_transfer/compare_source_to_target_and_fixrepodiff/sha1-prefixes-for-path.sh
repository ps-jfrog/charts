#!/bin/bash
#
# Queries Artifactory via AQL to find all files under a repo path and outputs
# their unique 2-digit SHA1 prefixes in RESUME format (prefix:0,prefix:0,...).
#
# Usage:
#   ./sha1-prefixes-for-path.sh --server-id <authority> --repo <repo> --path <path>
#
# Example:
#   ./sha1-prefixes-for-path.sh --server-id psazuse --repo sv-docker-local \
#     --path "merry-raven/v927.3.9_0"
#
#   Output:
#     f6:0,d6:0,c6:0,66:0,cc:0,24:0,a3:0,5b:0,8b:0,7f:0
#
#   Then use it:
#     RESUME=$(./sha1-prefixes-for-path.sh --server-id psazuse --repo sv-docker-local \
#       --path "merry-raven/v927.3.9_0")
#     bash sync-with-targeted-stats.sh --config <config> ... --sha1-resume "$RESUME"
#

set -euo pipefail

SERVER_ID=""
REPO=""
SEARCH_PATH=""

show_help() {
  cat << 'EOF'
Usage: sha1-prefixes-for-path.sh --server-id <authority> --repo <repo> --path <path>

Queries Artifactory via AQL to find all files under <repo>/<path> and outputs
their unique 2-digit SHA1 prefixes as comma-separated prefix:0 pairs, ready
for use with --sha1-resume.

OPTIONS:
  --server-id <id>    JFrog CLI server ID / authority (e.g. psazuse).
  --repo <repo>       Repository name (e.g. sv-docker-local).
  --path <path>       Path within the repo (e.g. merry-raven/v927.3.9_0).
                      Do not include the repo name or leading/trailing slashes.
  -h, --help          Show this help.

OUTPUT:
  Comma-separated prefix:0 pairs (e.g. f6:0,d6:0,c6:0).
  Use with: --sha1-resume "$(./sha1-prefixes-for-path.sh ...)"
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-id)
      [[ $# -lt 2 ]] && { echo "Error: --server-id requires a value." >&2; exit 1; }
      SERVER_ID="$2"; shift 2 ;;
    --repo)
      [[ $# -lt 2 ]] && { echo "Error: --repo requires a value." >&2; exit 1; }
      REPO="$2"; shift 2 ;;
    --path)
      [[ $# -lt 2 ]] && { echo "Error: --path requires a value." >&2; exit 1; }
      SEARCH_PATH="$2"; shift 2 ;;
    -h|--help) show_help ;;
    *) echo "Unknown option: $1" >&2; show_help ;;
  esac
done

if [[ -z "$SERVER_ID" ]] || [[ -z "$REPO" ]] || [[ -z "$SEARCH_PATH" ]]; then
  echo "Error: --server-id, --repo, and --path are all required." >&2
  exit 1
fi

# Strip leading/trailing slashes from path
SEARCH_PATH="${SEARCH_PATH#/}"
SEARCH_PATH="${SEARCH_PATH%/}"

AQL_QUERY="items.find({
  \"repo\": \"$REPO\",
  \"path\": {\"\$match\": \"$SEARCH_PATH*\"},
  \"type\": \"file\"
}).include(\"actual_sha1\")"

RESULT=$(jf rt curl -s -XPOST "/api/search/aql" \
  --server-id="$SERVER_ID" \
  -H "Content-Type: text/plain" \
  -d "$AQL_QUERY")

PREFIXES=$(echo "$RESULT" | jq -r '.results[].actual_sha1' 2>/dev/null \
  | sed 's/^\(..\).*/\1/' \
  | sort -u \
  | sed 's/$/:0/' \
  | paste -sd, -)

if [[ -z "$PREFIXES" ]]; then
  echo "No files found under $REPO/$SEARCH_PATH" >&2
  exit 1
fi

echo "$PREFIXES"
