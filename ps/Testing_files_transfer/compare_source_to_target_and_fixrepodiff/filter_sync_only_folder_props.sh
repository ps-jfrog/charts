#!/bin/bash
#
# Filters 06_to_sync_folder_props.sh to exclude lines that set ONLY sync.*
# properties. Lines with at least one non-sync.* property are kept.
#
# Usage: filter_sync_only_folder_props.sh <input_file>
# Output: <input_dir>/06a_lines_other_than_only_sync_folder_props.sh
#
# Example kept line (has folder-color):
#   jf rt sp "repo/path" 'folder-color=red;sync.created=...' --include-dirs=true ...
#
# Example excluded line (only sync.* properties):
#   jf rt sp "repo/path" 'sync.created=...;sync.modifiedBy=...' --include-dirs=true ...

set -euo pipefail

INPUT="$1"
if [[ ! -f "$INPUT" ]]; then
  echo "Error: Input file not found: $INPUT" >&2
  exit 1
fi

INPUT_DIR="$(dirname "$INPUT")"
OUTPUT="$INPUT_DIR/06a_lines_other_than_only_sync_folder_props.sh"

: > "$OUTPUT"

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue

  props=""
  if [[ "$line" =~ \'([^\']+)\' ]]; then
    props="${BASH_REMATCH[1]}"
  else
    echo "$line" >> "$OUTPUT"
    continue
  fi

  has_non_sync=0
  IFS=';' read -ra pairs <<< "$props"
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    if [[ "$key" != sync.* ]]; then
      has_non_sync=1
      break
    fi
  done

  if [[ "$has_non_sync" -eq 1 ]]; then
    echo "$line" >> "$OUTPUT"
  fi
done < "$INPUT"

kept=$(wc -l < "$OUTPUT" | tr -d ' ')
total=$(grep -c . "$INPUT" 2>/dev/null || echo 0)
skipped=$((total - kept))
echo "Filtered $INPUT: $total total, $kept kept (non-sync.* props), $skipped excluded (sync.*-only)"
