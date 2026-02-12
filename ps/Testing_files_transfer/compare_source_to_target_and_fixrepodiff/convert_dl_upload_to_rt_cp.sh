#!/usr/bin/env bash
# Convert a sync script that uses "jf rt dl ... && jf rt u ..." per line into a script
# that uses "jf rt cp" (copy within the same Artifactory). Writes output to the same
# directory as the input with suffix _using_copy.sh.
#
# Input line format:
#   jf rt dl --server-id=SOURCE --flat "SOURCE_PATH" "/tmp/xxx" && jf rt u --server-id=TARGET "/tmp/xxx" "DEST_PATH"
# Output line format:
#   jf rt cp SOURCE_PATH DEST_PATH --flat=false --threads=8 --dry-run=false --server-id=TARGET
#
# Usage: $0 <path/to/script.sh>
# Example: ./convert_dl_upload_to_rt_cp.sh test/03_to_sync.sh
#   -> creates test/03_to_sync_using_copy.sh

set -e

usage() {
  echo "Usage: $0 <path/to/script.sh>" >&2
  echo "Converts dl+upload lines to jf rt cp lines. Output: same dir, <basename>_using_copy.sh" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage
INPUT="$1"
[[ -z "$INPUT" || ! -f "$INPUT" ]] && { echo "Error: not a file: $INPUT" >&2; usage; }

DIR=$(dirname "$INPUT")
BASE=$(basename "$INPUT" .sh)
OUTPUT="${DIR}/${BASE}_using_copy.sh"

# Optional: make --threads and --server-id configurable via env
THREADS="${RT_CP_THREADS:-8}"
DRY_RUN="${RT_CP_DRY_RUN:-false}"

: > "$OUTPUT"
count=0
while IFS= read -r line; do
  line_trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Skip empty lines and comments
  [[ -z "$line_trimmed" || "$line_trimmed" =~ ^# ]] && continue
  # Only convert lines that look like "jf rt dl ... && jf rt u ..."
  if [[ ! "$line_trimmed" =~ jf\ rt\ dl.*jf\ rt\ u ]]; then
    echo "$line_trimmed" >> "$OUTPUT"
    continue
  fi
  # Extract --server-id from the upload (jf rt u) part — that's the target server for cp
  server_id=$(echo "$line_trimmed" | sed -n 's/.*jf rt u --server-id=\([^[:space:]]*\).*/\1/p')
  [[ -z "$server_id" ]] && { echo "Warning: could not find server-id in: $line_trimmed" >&2; echo "$line_trimmed" >> "$OUTPUT"; continue; }
  # Extract quoted strings in order; we need first (source path) and last (dest path)
  # Format: "source_path" "/tmp/..." ... "/tmp/..." "dest_path"
  quoted=()
  rest="$line_trimmed"
  while [[ "$rest" =~ \"([^\"]*)\" ]]; do
    quoted+=("${BASH_REMATCH[1]}")
    rest="${rest#*\"${BASH_REMATCH[1]}\"}"
  done
  if [[ ${#quoted[@]} -lt 2 ]]; then
    echo "Warning: could not parse quoted paths in: $line_trimmed" >&2
    echo "$line_trimmed" >> "$OUTPUT"
    continue
  fi
  # First quoted = source path, last quoted = dest path (skip /tmp in between)
  source_path="${quoted[0]}"
  last_idx=$((${#quoted[@]} - 1))
  dest_path="${quoted[$last_idx]}"
  echo "jf rt cp ${source_path} ${dest_path} --flat=true --threads=${THREADS} --dry-run=${DRY_RUN} --server-id=${server_id}" >> "$OUTPUT"
  (( count++ )) || true
done < "$INPUT"

echo "Wrote $count cp line(s) to $OUTPUT" >&2
