#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# find-truly-missing-uris.sh
#
# Compares two Artifactory repositories via AQL and identifies URIs that exist
# in the source repo but not in the target repo (truly missing files).
# Handles paginated AQL responses automatically.
#
# Usage:
#   bash find-truly-missing-uris.sh \
#     --source-repo <repo>   --source-server-id <id> \
#     --target-repo <repo>   --target-server-id <id> \
#     [--page-size <n>]      [--output-dir <dir>]
#
# Options:
#   --source-repo        Source repository name (required)
#   --source-server-id   JFrog CLI server ID for the source (required)
#   --target-repo        Target repository name (required)
#   --target-server-id   JFrog CLI server ID for the target (required)
#   --page-size          AQL pagination size (default: 1000)
#   --output-dir         Directory for output files (default: current directory)
#   -h, --help           Show this help message
#
# Output files (written to --output-dir):
#   source_uris.txt              Sorted list of all file URIs in the source repo
#   target_uris.txt              Sorted list of all file URIs in the target repo
#   truly_missing_uris.txt       URIs in source but not in target
#   target_only_uris.txt         URIs in target but not in source
#   shared_uris.txt              URIs present on both sides
#
# Examples:
#   # Same Artifactory instance, two repos
#   bash find-truly-missing-uris.sh \
#     --source-repo npmjs-remote-cache --source-server-id psazuse \
#     --target-repo sv-npmjs-remote-cache-copy --target-server-id psazuse
#
#   # Different instances, custom page size
#   bash find-truly-missing-uris.sh \
#     --source-repo my-maven-local --source-server-id prod \
#     --target-repo my-maven-local --target-server-id dr \
#     --page-size 5000 --output-dir /tmp/compare-results
###############################################################################

SOURCE_REPO=""
SOURCE_SERVER_ID=""
TARGET_REPO=""
TARGET_SERVER_ID=""
PAGE_SIZE=1000
OUTPUT_DIR="."

usage() {
  sed -n '/^# Usage:/,/^###/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-repo)        SOURCE_REPO="$2";        shift 2 ;;
    --source-server-id)   SOURCE_SERVER_ID="$2";   shift 2 ;;
    --target-repo)        TARGET_REPO="$2";        shift 2 ;;
    --target-server-id)   TARGET_SERVER_ID="$2";   shift 2 ;;
    --page-size)          PAGE_SIZE="$2";           shift 2 ;;
    --output-dir)         OUTPUT_DIR="$2";          shift 2 ;;
    -h|--help)            usage 0 ;;
    *)                    echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$SOURCE_REPO" ]]      && { echo "Error: --source-repo is required" >&2; usage 1; }
[[ -z "$SOURCE_SERVER_ID" ]] && { echo "Error: --source-server-id is required" >&2; usage 1; }
[[ -z "$TARGET_REPO" ]]      && { echo "Error: --target-repo is required" >&2; usage 1; }
[[ -z "$TARGET_SERVER_ID" ]] && { echo "Error: --target-server-id is required" >&2; usage 1; }

mkdir -p "$OUTPUT_DIR"

# Crawl a repo via paginated AQL, writing sorted path/name URIs to the output file.
# Args: $1=repo  $2=server-id  $3=output-file
crawl_repo() {
  local repo="$1" server_id="$2" out_file="$3"
  local offset=0 batch_count tmp_aql tmp_raw tmp_uris

  tmp_uris="$(mktemp)"

  echo "Crawling $repo (server: $server_id, page size: $PAGE_SIZE) ..."

  while true; do
    tmp_aql="$(mktemp)"
    tmp_raw="$(mktemp)"

    cat > "$tmp_aql" <<EOF
items.find({"type": "file", "repo": "$repo"}).include("path","name").sort({"\$asc":["path","name"]}).offset($offset).limit($PAGE_SIZE)
EOF

    jf rt curl -s -XPOST "/api/search/aql" -H "Content-Type: text/plain" \
      -d @"$tmp_aql" --server-id="$server_id" > "$tmp_raw"
    rm -f "$tmp_aql"

    batch_count=$(jq '.results | length' "$tmp_raw")
    jq -r '.results[] | "\(.path)/\(.name)"' "$tmp_raw" >> "$tmp_uris"
    rm -f "$tmp_raw"

    echo "  offset=$offset  fetched=$batch_count"

    if [[ "$batch_count" -lt "$PAGE_SIZE" ]]; then
      break
    fi
    offset=$((offset + PAGE_SIZE))
  done

  sort "$tmp_uris" > "$out_file"
  rm -f "$tmp_uris"

  local total
  total=$(wc -l < "$out_file" | tr -d ' ')
  echo "  Total URIs: $total -> $out_file"
}

source_file="$OUTPUT_DIR/source_uris.txt"
target_file="$OUTPUT_DIR/target_uris.txt"

crawl_repo "$SOURCE_REPO" "$SOURCE_SERVER_ID" "$source_file"
echo ""
crawl_repo "$TARGET_REPO" "$TARGET_SERVER_ID" "$target_file"
echo ""

truly_missing="$OUTPUT_DIR/truly_missing_uris.txt"
target_only="$OUTPUT_DIR/target_only_uris.txt"
shared="$OUTPUT_DIR/shared_uris.txt"

comm -23 "$source_file" "$target_file" > "$truly_missing"
comm -13 "$source_file" "$target_file" > "$target_only"
comm -12 "$source_file" "$target_file" > "$shared"

echo "=== Results ==="
echo "Source URIs:        $(wc -l < "$source_file" | tr -d ' ')"
echo "Target URIs:        $(wc -l < "$target_file" | tr -d ' ')"
echo "Truly missing:      $(wc -l < "$truly_missing" | tr -d ' ')  -> $truly_missing"
echo "Target-only:        $(wc -l < "$target_only" | tr -d ' ')  -> $target_only"
echo "Shared:             $(wc -l < "$shared" | tr -d ' ')  -> $shared"
