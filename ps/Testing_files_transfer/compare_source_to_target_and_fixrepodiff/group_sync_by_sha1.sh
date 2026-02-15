#!/usr/bin/env bash
# Group a sync script's dl+upload lines by their /tmp/sha1 path so each SHA1
# is downloaded once and uploaded to all destinations before cleanup.
#
# Input line format:
#   jf rt dl --server-id=SRC --flat "SOURCE_PATH" "/tmp/SHA1" && jf rt u --server-id=TGT "/tmp/SHA1" "DEST_PATH"
#
# Output (one line per unique SHA1):
#   _TD=$(mktemp -d) && jf rt dl --server-id=SRC --flat "SOURCE_PATH" "$_TD/SHA1" && jf rt u --server-id=TGT "$_TD/SHA1" "DEST1" && jf rt u --server-id=TGT "$_TD/SHA1" "DEST2" && ... ; rm -rf "$_TD"
#
# Lines that don't match the dl+upload pattern are passed through unchanged.
# Empty lines and comments are skipped.
#
# Usage: $0 <path/to/script.sh>
# Example: ./group_sync_by_sha1.sh b4_upload/03_to_sync.sh
#   -> creates b4_upload/03_to_sync_grouped.sh
#
# The runner (runcommand_in_parallel_from_file.sh) then parallelises across groups.
# Within each group: one download, sequential uploads, then cleanup.
# This avoids duplicate downloads of the same blob and eliminates /tmp race conditions.

set -e

usage() {
  echo "Usage: $0 <path/to/script.sh>" >&2
  echo "Groups dl+upload lines by SHA1. Output: same dir, <basename>_grouped.sh" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage
INPUT="$1"
[[ -z "$INPUT" || ! -f "$INPUT" ]] && { echo "Error: not a file: $INPUT" >&2; usage; }

DIR=$(dirname "$INPUT")
BASE=$(basename "$INPUT" .sh)
OUTPUT="${DIR}/${BASE}_grouped.sh"

# Work directory for grouping
tmpwork=$(mktemp -d)
trap 'rm -rf "$tmpwork"' EXIT

pass_through_file="$tmpwork/_passthrough"
: > "$pass_through_file"

total_lines=0
grouped_lines=0

while IFS= read -r line; do
  line_trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$line_trimmed" || "$line_trimmed" =~ ^# ]] && continue

  # Only group lines that match "jf rt dl ... && jf rt u ..."
  if [[ ! "$line_trimmed" =~ jf\ rt\ dl.*jf\ rt\ u ]]; then
    echo "$line_trimmed" >> "$pass_through_file"
    continue
  fi

  # Extract the /tmp/sha1 path (first /tmp path found, unquoted)
  tmp_path=$(echo "$line_trimmed" | grep -oE '"/tmp/[^"]+' | head -1 | tr -d '"')
  if [[ -z "$tmp_path" ]]; then
    echo "$line_trimmed" >> "$pass_through_file"
    continue
  fi

  sha_key=$(basename "$tmp_path")

  # Extract upload server-id and dest path from this line
  ul_server=$(echo "$line_trimmed" | sed -n 's/.*jf rt u --server-id=\([^[:space:]]*\).*/\1/p')
  # Dest path is the last quoted string
  dest_path=$(echo "$line_trimmed" | grep -oE '"[^"]*"' | tail -1 | tr -d '"')

  # If first time seeing this SHA1, also record the download part
  if [[ ! -f "$tmpwork/dl_${sha_key}" ]]; then
    # Download server-id
    dl_server=$(echo "$line_trimmed" | sed -n 's/.*jf rt dl --server-id=\([^[:space:]]*\).*/\1/p')
    # Source path: first quoted string that is not a /tmp path
    source_path=$(echo "$line_trimmed" | grep -oE '"[^"]*"' | grep -v '/tmp/' | head -1 | tr -d '"')
    echo "${dl_server}|${source_path}|${ul_server}" > "$tmpwork/dl_${sha_key}"
  fi

  # Append dest path for this SHA1
  echo "$dest_path" >> "$tmpwork/dest_${sha_key}"
  (( total_lines++ )) || true
done < "$INPUT"

# Build output file
: > "$OUTPUT"

# Pass-through lines first
if [[ -s "$pass_through_file" ]]; then
  cat "$pass_through_file" >> "$OUTPUT"
fi

# Grouped commands: one per unique SHA1
for dl_file in "$tmpwork"/dl_*; do
  [[ ! -f "$dl_file" ]] && continue
  sha_key=$(basename "$dl_file" | sed 's/^dl_//')
  dest_file="$tmpwork/dest_${sha_key}"
  [[ ! -f "$dest_file" ]] && continue

  IFS='|' read -r dl_server source_path ul_server < "$dl_file"

  # Build compound command: mktemp -> download -> upload(s) -> cleanup
  cmd="_TD=\$(mktemp -d) && jf rt dl --server-id=${dl_server} --flat \"${source_path}\" \"\$_TD/${sha_key}\""

  while IFS= read -r dest; do
    cmd="${cmd} && jf rt u --server-id=${ul_server} \"\$_TD/${sha_key}\" \"${dest}\""
  done < "$dest_file"

  cmd="${cmd} ; rm -rf \"\$_TD\""

  echo "$cmd" >> "$OUTPUT"
  (( grouped_lines++ )) || true
done

echo "Grouped $total_lines lines into $grouped_lines tasks (unique SHA1s) in $OUTPUT" >&2
