#!/bin/bash
#
# End-to-end sync with targeted stats/properties collection.
#
# Orchestrates the full generate → extract → run → generate → run cycle:
#   Pass 1:  Generate sync scripts 03/04 (no stats/properties)
#   Extract: Query comparison.db for pending-sync URIs (before Run 03/04 modifies the DB)
#   Run:     Execute 03/04 to sync artifacts to target (--skip-compare: no re-crawl)
#   Pass 2:  Collect stats/properties for those URIs + parent folders, generate 05–06
#            in b4_upload/ and 07–09 in after_upload/
#   Run:     Execute 05–09 to apply stats/properties/folder metadata (--skip-compare: no re-crawl)
#
# With --skip-pass1, skips the full crawl in Pass 1 and uses the existing
# comparison.db + generated scripts from a prior run or copy.
#
# This avoids the full --collect-stats --collect-properties crawl, reducing
# a 10+ hour two-authority crawl to minutes.
#
# Usage:
#   ./sync-with-targeted-stats.sh --config <config> [OPTIONS]
#
# All options are passed through to sync-target-from-source.sh.
# See 04-README-targeted-stats-collection.md for details.
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
SYNC_SCRIPT="$SCRIPT_DIR/sync-target-from-source.sh"

if [[ ! -f "$SYNC_SCRIPT" ]]; then
  echo "Error: sync-target-from-source.sh not found: $SYNC_SCRIPT" >&2
  exit 1
fi

show_help() {
  cat << 'EOF'
Usage: sync-with-targeted-stats.sh --config <config> [OPTIONS]

End-to-end sync with targeted stats/properties collection. Runs the full
generate → run → generate → run cycle in one invocation.

All OPTIONS are passed through to sync-target-from-source.sh (except the ones
managed internally: --generate-only, --run-only, --skip-collect-stats-properties,
--skip-consolidation, --collect-stats-for-uris).

Options managed by this script:
  --skip-pass1                Skip Pass 1 (the full artifact crawl). Use when comparison.db
                              already has the delta from a prior run or copy. The script jumps
                              directly to URI extraction → Run 03/04 → Pass 2 → Run 05–09.

Common options passed through to sync-target-from-source.sh:
  --config <file>             Config file (required).
  --include-remote-cache      Include remote-cache repos in the crawl.
  --aql-style <style>         AQL crawl style (e.g. sha1-prefix).
  --aql-page-size <N>         AQL page size (e.g. 5000).
  --folder-parallel <N>       Parallel workers for folder crawl.
  --sha1-resume <pairs>       Resume a failed sha1-prefix crawl in Pass 1 (e.g. f2:40000,f3:40000).
                              Skips init --clean. Only affects the Pass 1 crawl.
  --sha1-resume-authority <id>  Scope --sha1-resume (Pass 1) or targeted collection (Pass 2) to
                              a single authority.
  --run-delayed               Run 04_to_sync_delayed.sh (default: skip).
  --run-folder-stats          Run 09_to_sync_folder_stats_as_properties.sh.
  --max-parallel <N>          Max concurrent commands (default: 10).
  --verification-csv [dir]    Write CSV reports during verification.
  --verification-no-limit     Show all files in verification output.
  -h, --help                  Show this help.

See 04-README-targeted-stats-collection.md for the full workflow explanation.
EOF
  exit 0
}

# Check for --help before passing through
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "Error: --config <file> is required." >&2
  show_help
fi

# Parse --skip-pass1 (consumed here) and collect remaining args as pass-through
SKIP_PASS1=0
PASSTHROUGH_ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--skip-pass1" ]]; then
    SKIP_PASS1=1
  else
    PASSTHROUGH_ARGS+=("$arg")
  fi
done

# Source the config file ourselves so we can resolve RECONCILE_BASE_DIR
CONFIG_FILE=""
for i in "${!PASSTHROUGH_ARGS[@]}"; do
  if [[ "${PASSTHROUGH_ARGS[$i]}" == "--config" ]]; then
    CONFIG_FILE="${PASSTHROUGH_ARGS[$((i+1))]:-}"
    break
  fi
done

if [[ -n "$CONFIG_FILE" ]] && [[ -f "$CONFIG_FILE" ]]; then
  set +u
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set -u
fi

RECONCILE_BASE_DIR="${RECONCILE_BASE_DIR:-$SCRIPT_DIR}"
URIS_FILE="$RECONCILE_BASE_DIR/uris_to_collect.txt"

echo "============================================================"
echo "  Sync with targeted stats/properties collection"
echo "============================================================"
echo "RECONCILE_BASE_DIR: $RECONCILE_BASE_DIR"
echo "URI extract file:   $URIS_FILE"
echo ""

# ── Pass 1: Generate sync scripts (no stats/properties) ──────────────────
STEP_START=$(date +%s)
if [[ "$SKIP_PASS1" -eq 1 ]]; then
  echo "=== Pass 1: Skipped (--skip-pass1) — using existing comparison.db ==="
else
  echo "=== Pass 1: Generate sync scripts (no stats/properties) ==="
  bash "$SYNC_SCRIPT" "${PASSTHROUGH_ARGS[@]}" \
    --generate-only --skip-collect-stats-properties
fi
echo "[timing] Pass 1 completed in $(format_elapsed $STEP_START)"
echo ""

# ── Extract URIs from comparison.db ───────────────────────────────────────
# Must run BEFORE Run 03/04: the --run-only step includes an after-upload
# compare (Step 4) that re-crawls the target. After Run 03/04 copies files
# to the target, Step 4 discovers they now exist on both sides and zeros out
# reconcile_phase2_sync. Extracting URIs here preserves the pending-sync
# data from Pass 1.
STEP_START=$(date +%s)
echo "=== Extract URIs for targeted stats collection ==="
( cd "$RECONCILE_BASE_DIR" && \
  jf compare query --csv --header=false \
    "SELECT DISTINCT path FROM reconcile_phase2_sync
     UNION
     SELECT DISTINCT path FROM reconcile_phase2_sync_delayed" \
    > "$URIS_FILE" )

URI_COUNT=$(wc -l < "$URIS_FILE" | tr -d ' ')
echo "Extracted $URI_COUNT URIs to $URIS_FILE"
echo "[timing] URI extraction completed in $(format_elapsed $STEP_START)"
echo ""

if [[ "$URI_COUNT" -eq 0 ]]; then
  echo "No URIs to collect stats for — Pass 1 found no artifacts to sync. Skipping Run 03/04 and Pass 2."
  echo ""
  echo "[timing] Total elapsed: $(format_elapsed $OVERALL_START)"
  exit 0
fi

# ── Run 03/04: Sync missing artifacts to target ──────────────────────────
# --skip-compare prevents Step 4 (after-upload compare) from running init --clean
# and re-crawling the entire repo, which would wipe comparison.db.
STEP_START=$(date +%s)
echo "=== Run 03/04: Sync missing artifacts to target ==="
bash "$SYNC_SCRIPT" "${PASSTHROUGH_ARGS[@]}" \
  --run-only --skip-consolidation --skip-compare
echo "[timing] Run 03/04 completed in $(format_elapsed $STEP_START)"
echo ""

# ── Pass 2: Collect targeted stats/properties, generate 05–06 + 07–09 ─────
STEP_START=$(date +%s)
echo "=== Pass 2: Collect targeted stats/properties for $URI_COUNT URIs ==="
bash "$SYNC_SCRIPT" "${PASSTHROUGH_ARGS[@]}" \
  --generate-only \
  --collect-stats-for-uris "$URIS_FILE"
echo "[timing] Pass 2 completed in $(format_elapsed $STEP_START)"
echo ""

# ── Run 05–09: Apply stats/properties/folder metadata ────────────────────
# --skip-compare prevents Step 4 from re-crawling after script execution.
STEP_START=$(date +%s)
echo "=== Run 05–09: Apply stats, properties, and folder metadata ==="
bash "$SYNC_SCRIPT" "${PASSTHROUGH_ARGS[@]}" \
  --run-only --skip-consolidation --skip-compare
echo "[timing] Run 05–09 completed in $(format_elapsed $STEP_START)"
echo ""

echo "============================================================"
echo "  Sync with targeted stats complete"
echo "============================================================"
echo "  URI file:          $URIS_FILE ($URI_COUNT URIs)"
echo "  Before-upload:     $RECONCILE_BASE_DIR/b4_upload/"
echo "  After-upload:      $RECONCILE_BASE_DIR/after_upload/"
echo ""
echo "[timing] Total elapsed: $(format_elapsed $OVERALL_START)"
