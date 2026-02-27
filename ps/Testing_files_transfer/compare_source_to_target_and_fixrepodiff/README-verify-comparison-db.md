# verify-comparison-db.sh — Post-sync verification queries

Queries `comparison.db` via `jf compare query` to display a summary of exclusion rules, repo mapping, reason-category counts, and a per-repo breakdown of missing files, delay files, and excluded files — each with count and listing. Requires the `jf compare query` subcommand (see Task 30 in the plugin docs).

This script is called automatically by `sync-target-from-source.sh` as **Step 6**, but can also be run **standalone** at any time after a sync to re-inspect the comparison database without re-running the full workflow.

---

## Usage

```bash
bash verify-comparison-db.sh --source <authority> [--repos <csv>]
```

| Option | Description |
|--------|-------------|
| `--source <authority>` | Source authority name (e.g. `app2`). Used to filter reason-category counts and excluded-files queries. **Required** (or set env `SH_ARTIFACTORY_AUTHORITY`). |
| `--repos <csv>` | Comma-separated list of source repo names. When set, a per-repo report of missing, delay, and excluded files is shown — each with count and listing. Falls back to env `SH_ARTIFACTORY_REPOS`. |
| `-h`, `--help` | Show help and exit. |

---

## What it displays

| Section | Description |
|---------|-------------|
| **a) Exclusion rules** | All path-based exclusion rules from `exclusion_rules` (pattern, reason, priority). |
| **c) Cross-instance mapping** | How source and target repos were paired (`exact_match`, `normalized_match`, or `explicit_sync`), with artifact counts per side. |
| **Reason-category counts** | Count of excluded artifacts grouped by `reason_category` (excluding `delay`), filtered to the given `--source`. |

When `--repos` is set, the following per-repo report is shown for each repository:

| Sub-section | Source | Description |
|-------------|--------|-------------|
| **Missing files** | `missing` view | Artifacts in source but not in target (excludes delays and exclusions). Count + first 20 rows. |
| **Delay files** | `comparison_reasons` (`reason_category = 'delay'`) | Deferred artifacts (e.g. Docker manifests). Count + first 20 rows. |
| **Excluded files** | `comparison_reasons` (`reason_category = 'exclude'`) | Skipped by exclusion rules. Count + first 20 rows. |

**Sample output:**

```
=== Repository: __infra_local_docker ===

--- Missing files (in source, not in target): 136 ---
<table output from jf compare query>

--- Delay files (deferred): 24 ---
<table output from jf compare query>

--- Excluded files (skipped by rules): 2 ---
<table output from jf compare query>
```

---

## Standalone examples

**After a one-shot run:**

```bash
bash sync-target-from-source.sh \
  --config config_env_examples/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh \
  --include-remote-cache --run-folder-stats --run-delayed --aql-style sha1-prefix \
  --aql-page-size 5000 --folder-parallel 16
```

The script automatically runs `verify-comparison-db.sh` as Step 6. To re-run the verification later without re-running the sync:

```bash
bash verify-comparison-db.sh --source app2 --repos "__infra_local_docker,example-repo-local"
```

**Using environment variables from a config file:**

```bash
source config_env_examples/env_app2_app3_same_jpd_different_repos_npm_sha1-prefix.sh
bash verify-comparison-db.sh --source "$SH_ARTIFACTORY_AUTHORITY" --repos "$SH_ARTIFACTORY_REPOS"
```

**Using only the env fallbacks (no flags needed):**

If `SH_ARTIFACTORY_AUTHORITY` and `SH_ARTIFACTORY_REPOS` are already exported (e.g. from a prior `source env.sh`):

```bash
bash verify-comparison-db.sh
```

**Source only, no per-repo breakdown:**

```bash
bash verify-comparison-db.sh --source app2
```

This shows exclusion rules, cross-instance mapping, and reason-category counts but skips the per-repo missing/delay/excluded breakdown.

---

## Graceful fallback

If `jf compare query` is not available (older plugin version without Task 30), the script prints a note and exits with code 0:

```
jf compare query not available (older plugin version); skipping verification queries.
Use sqlite3 with comparison.db instead. See QUICKSTART.md 'Inspecting comparison.db'.
```

You can use `sqlite3` directly as documented in [QUICKSTART.md](QUICKSTART.md) under "Inspecting comparison.db".

---

## See also

- [README.md](README.md) — `sync-target-from-source.sh` documentation (Step 6 calls this script).
- [QUICKSTART.md](QUICKSTART.md) — "Inspecting comparison.db" section for the full set of `sqlite3` / `jf compare query` queries.
- [README-compare-and-reconcile.md](README-compare-and-reconcile.md) — `compare-and-reconcile.sh` documentation.
