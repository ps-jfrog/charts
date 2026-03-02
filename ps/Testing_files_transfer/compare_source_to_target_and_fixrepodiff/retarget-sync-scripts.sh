#!/bin/bash
#
# retarget-sync-scripts.sh — Copy generated before-upload scripts (03–06) from
# a previous --generate-only run and rewrite them to upload to a different
# target repository, without re-running the full compare workflow.
#
# After rewriting, prints guidance on how to execute the rewritten scripts and
# complete the after-upload phase (07–09) via sync-target-from-source.sh --run-only.
#
# Usage:
#   bash retarget-sync-scripts.sh \
#     --source-dir /path/to/original/reconcile-dir \
#     --target-dir /path/to/new/reconcile-dir \
#     --old-repo npmjs-remote-cache \
#     --new-repo my-other-repo \
#     [--old-server-id psazuse1 --new-server-id psazuse2]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SOURCE_DIR=""
TARGET_DIR=""
OLD_REPO=""
NEW_REPO=""
OLD_SERVER_ID=""
NEW_SERVER_ID=""

show_help() {
  cat << 'EOF'
Usage: retarget-sync-scripts.sh [OPTIONS]

Copy before-upload scripts (03–06) from a previous --generate-only run and
rewrite them to upload artifacts to a different target repository.

REQUIRED:
  --source-dir <dir>      Path to the original RECONCILE_BASE_DIR containing b4_upload/.
  --target-dir <dir>      Path to the new RECONCILE_BASE_DIR. Created if it doesn't exist.
  --old-repo <name>       Target repo name to replace (e.g. npmjs-remote-cache).
  --new-repo <name>       New target repo name (e.g. my-other-repo).

OPTIONAL:
  --old-server-id <id>    Current target Artifactory server-id to replace.
  --new-server-id <id>    New target Artifactory server-id.
                          Both --old-server-id and --new-server-id must be provided together.
  -h, --help              Show this help.

WHAT IT DOES:
  1. Copies 03_to_sync.sh, 04_to_sync_delayed.sh, 05_to_sync_stats.sh, and
     06_to_sync_folder_props.sh from <source-dir>/b4_upload/ to
     <target-dir>/b4_upload/.
  2. Rewrites the target repository name in all copied scripts.
  3. If --old-server-id/--new-server-id are given, rewrites the target server-id
     (upload/target side only; the download/source side in 03/04 is unchanged).
  4. Prints next-steps guidance for running the rewritten scripts and completing
     the after-upload phase (07–09).

SED PATTERNS (per script):
  03/04 (jf rt dl+u or jf rt cp):
    Repo:       "OLD_REPO/  →  "NEW_REPO/       (matches upload target path)
    Server-id:  only replaced after '&&' (upload side, not download side)
  05 (jf rt curl -X PUT):
    Repo:       "/OLD_REPO/ →  "/NEW_REPO/       (matches curl API path)
    Server-id:  global replace (single server-id per line)
  06 (jf rt sp):
    Repo:       "OLD_REPO/  →  "NEW_REPO/        (matches property target path)
    Server-id:  global replace (single server-id per line)

NEXT STEPS (printed after rewrite):
  Create a config file with the new CLOUD_ARTIFACTORY_REPOS and RECONCILE_BASE_DIR,
  then run: sync-target-from-source.sh --config <new-config> --run-only --run-delayed ...

EXAMPLES:
  # Retarget from npmjs-remote-cache to my-other-repo:
  bash retarget-sync-scripts.sh \
    --source-dir /tmp/reconcile-run1 \
    --target-dir /tmp/reconcile-retarget \
    --old-repo npmjs-remote-cache \
    --new-repo my-other-repo

  # Also change the target server-id:
  bash retarget-sync-scripts.sh \
    --source-dir /tmp/reconcile-run1 \
    --target-dir /tmp/reconcile-retarget \
    --old-repo npmjs-remote-cache \
    --new-repo my-other-repo \
    --old-server-id psazuse1 \
    --new-server-id psazuse2
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)    SOURCE_DIR="$2"; shift 2 ;;
    --target-dir)    TARGET_DIR="$2"; shift 2 ;;
    --old-repo)      OLD_REPO="$2"; shift 2 ;;
    --new-repo)      NEW_REPO="$2"; shift 2 ;;
    --old-server-id) OLD_SERVER_ID="$2"; shift 2 ;;
    --new-server-id) NEW_SERVER_ID="$2"; shift 2 ;;
    -h|--help)       show_help ;;
    *)               echo "Error: unknown option: $1" >&2; echo "Run with --help for usage." >&2; exit 1 ;;
  esac
done

# --- Validate required options ---
missing=()
[[ -z "$SOURCE_DIR" ]] && missing+=("--source-dir")
[[ -z "$TARGET_DIR" ]] && missing+=("--target-dir")
[[ -z "$OLD_REPO" ]]   && missing+=("--old-repo")
[[ -z "$NEW_REPO" ]]   && missing+=("--new-repo")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required options: ${missing[*]}" >&2
  echo "Run with --help for usage." >&2
  exit 1
fi

if [[ -n "$OLD_SERVER_ID" ]] && [[ -z "$NEW_SERVER_ID" ]]; then
  echo "Error: --old-server-id requires --new-server-id." >&2
  exit 1
fi
if [[ -z "$OLD_SERVER_ID" ]] && [[ -n "$NEW_SERVER_ID" ]]; then
  echo "Error: --new-server-id requires --old-server-id." >&2
  exit 1
fi

if [[ "$OLD_REPO" == "$NEW_REPO" ]]; then
  echo "Error: --old-repo and --new-repo must be different." >&2
  exit 1
fi

# --- Validate source directory ---
SOURCE_B4="$SOURCE_DIR/b4_upload"
TARGET_B4="$TARGET_DIR/b4_upload"

if [[ ! -d "$SOURCE_B4" ]]; then
  echo "Error: source b4_upload/ not found: $SOURCE_B4" >&2
  echo "  Run --generate-only first to create it." >&2
  exit 1
fi

if [[ ! -f "$SOURCE_B4/03_to_sync.sh" ]]; then
  echo "Error: 03_to_sync.sh not found in $SOURCE_B4" >&2
  exit 1
fi

# Warn if target already has scripts
if [[ -d "$TARGET_B4" ]] && ls "$TARGET_B4"/0[3-6]_*.sh >/dev/null 2>&1; then
  echo "Warning: target b4_upload/ already contains scripts — they will be overwritten." >&2
  echo "  Target: $TARGET_B4" >&2
  echo ""
fi

mkdir -p "$TARGET_B4"

# Escape dots in OLD_REPO for sed regex (repo names may contain dots)
OLD_REPO_RE="${OLD_REPO//./\\.}"

echo "=== Retarget: copy and rewrite before-upload scripts (03–06) ==="
echo ""
echo "  Source:     $SOURCE_B4"
echo "  Target:     $TARGET_B4"
echo "  Repo:       $OLD_REPO → $NEW_REPO"
if [[ -n "$OLD_SERVER_ID" ]]; then
  echo "  Server-id:  $OLD_SERVER_ID → $NEW_SERVER_ID"
fi
echo ""

# --- Copy and rewrite each script ---
SCRIPTS=("03_to_sync.sh" "04_to_sync_delayed.sh" "05_to_sync_stats.sh" "06_to_sync_folder_props.sh")
COPIED=0
TOTAL_LINES_MODIFIED=0

for script in "${SCRIPTS[@]}"; do
  src="$SOURCE_B4/$script"
  dst="$TARGET_B4/$script"

  if [[ ! -f "$src" ]]; then
    echo "  Skipping $script (not in source)."
    continue
  fi

  src_lines=$(wc -l < "$src" | tr -d ' ')
  if [[ "$src_lines" -eq 0 ]]; then
    echo "  Skipping $script (empty)."
    continue
  fi

  # Build sed expressions
  SED_ARGS=()

  case "$script" in
    05_to_sync_stats.sh)
      # jf rt curl paths use leading slash: "/OLD_REPO/..."
      SED_ARGS+=(-e "s|\"/${OLD_REPO_RE}/|\"/${NEW_REPO}/|g")
      repo_matches=$(grep -c "\"/${OLD_REPO}/" "$src" || true)
      ;;
    *)
      # 03, 04: upload target "OLD_REPO/..." ; 06: jf rt sp "OLD_REPO/..."
      SED_ARGS+=(-e "s|\"${OLD_REPO_RE}/|\"${NEW_REPO}/|g")
      repo_matches=$(grep -c "\"${OLD_REPO}/" "$src" || true)
      ;;
  esac

  sid_matches=0
  if [[ -n "$OLD_SERVER_ID" ]]; then
    case "$script" in
      03_to_sync.sh|04_to_sync_delayed.sh)
        # Only replace server-id on the upload side (after &&)
        SED_ARGS+=(-e "s|\(.* && .*\)--server-id=${OLD_SERVER_ID}|\1--server-id=${NEW_SERVER_ID}|")
        # Count server-id occurrences after && in source
        sid_matches=$(grep -c "&& .*--server-id=${OLD_SERVER_ID}" "$src" || true)
        ;;
      *)
        # 05, 06: single server-id per line — global replace
        SED_ARGS+=(-e "s|--server-id=${OLD_SERVER_ID}|--server-id=${NEW_SERVER_ID}|g")
        sid_matches=$(grep -c "\-\-server-id=${OLD_SERVER_ID}" "$src" || true)
        ;;
    esac
  fi

  sed "${SED_ARGS[@]}" "$src" > "$dst"

  sid_info=""
  [[ -n "$OLD_SERVER_ID" ]] && sid_info=", $sid_matches server-id substitutions"
  echo "  $script: $src_lines lines, $repo_matches repo substitutions${sid_info}"
  COPIED=$((COPIED + 1))
  TOTAL_LINES_MODIFIED=$((TOTAL_LINES_MODIFIED + repo_matches))
done

if [[ "$COPIED" -eq 0 ]]; then
  echo ""
  echo "Error: no scripts were copied. Check that source b4_upload/ contains 03–06 scripts." >&2
  exit 1
fi

echo ""
echo "=== Rewrite complete: $COPIED scripts, $TOTAL_LINES_MODIFIED total repo substitutions ==="
echo ""
echo "Review the rewritten scripts in:"
echo "  $TARGET_B4"

# --- Print next-steps guidance ---
TARGET_DIR_ABS="$(cd "$TARGET_DIR" && pwd)"

echo ""
echo "=== Next steps ==="
echo ""
echo "1. Create a config file (e.g. env_retarget.sh) based on your original config"
echo "   but with the updated target repo and output directory:"
echo ""
echo "     # Copy from your original config, then change these lines:"
echo "     export CLOUD_ARTIFACTORY_REPOS=\"$NEW_REPO\""
echo "     export RECONCILE_BASE_DIR=\"$TARGET_DIR_ABS\""
if [[ -n "$NEW_SERVER_ID" ]]; then
  echo "     export CLOUD_ARTIFACTORY_AUTHORITY=\"$NEW_SERVER_ID\"   # if authority also changed"
fi
echo "     # Keep all other env vars (SH_ARTIFACTORY_*, COMPARE_*, etc.) the same."
echo ""
echo "2. Run sync-target-from-source.sh with --run-only to execute the rewritten"
echo "   scripts (03–06) and then generate/run the after-upload scripts (07–09):"
echo ""
echo "     bash $SCRIPT_DIR/sync-target-from-source.sh \\"
echo "       --config env_retarget.sh \\"
echo "       --run-only --skip-consolidation --run-delayed --run-folder-stats \\"
echo "       --verification-csv --verification-no-limit"
echo ""
echo "   --run-only skips Step 2 (before-upload compare) since the rewritten scripts"
echo "   already exist in b4_upload/. It proceeds with:"
echo "     Step 3: Execute before-upload scripts (03–06) from b4_upload/"
echo "     Step 4: After-upload compare (against $NEW_REPO)"
echo "     Step 5: Execute after-upload scripts (07–09)"
echo "     Step 6: Post-sync verification"
echo ""
echo "   --skip-consolidation skips 01/02 scripts (not present in retargeted dir)."
echo "   --run-delayed ensures 04_to_sync_delayed.sh is executed."
echo ""
echo "   Add --aql-style, --aql-page-size, --folder-parallel, --include-remote-cache"
echo "   as needed (same values as your original run)."
