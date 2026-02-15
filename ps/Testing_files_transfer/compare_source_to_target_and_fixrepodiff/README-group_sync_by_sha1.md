# group_sync_by_sha1.sh

Groups a reconciliation sync script (e.g. `03_to_sync.sh`) by the SHA1 hash of each artifact so that **each blob is downloaded exactly once** and then uploaded to all its destinations before cleanup. This eliminates redundant downloads when the same blob appears in multiple paths (common in Docker repos where layers are shared across image tags).

## When to use

- You have a script like **03_to_sync.sh** with one `jf rt dl ... && jf rt u ...` per line.
- The same SHA1 (the `/tmp/<sha1>` path) appears in **multiple lines** (shared blob / Docker layer).
- Running those lines in parallel would cause:
  - **Race conditions:** two tasks download to the same `/tmp/<sha1>`, overwriting or deleting each other's file.
  - **Wasted bandwidth:** the same blob is downloaded N times instead of once.

**sync-target-from-source.sh** calls this automatically before running `03_to_sync.sh` when source and target are on **different** Artifactory instances.

## Usage

```bash
./group_sync_by_sha1.sh <path/to/script.sh>
```

**Example:**

```bash
./group_sync_by_sha1.sh b4_upload/03_to_sync.sh
# Output: Grouped 128 lines into 51 tasks (unique SHA1s) in b4_upload/03_to_sync_grouped.sh
```

- **Input:** A script with dl+upload lines (see format below). Non-matching lines are passed through; empty lines and comments are skipped.
- **Output:** Written to the **same directory** as the input, with suffix `_grouped.sh` (e.g. `03_to_sync.sh` → `03_to_sync_grouped.sh`). Overwritten on each run.

## Line format

**Input (multiple lines may share the same `/tmp/<sha1>`):**

```text
jf rt dl --server-id=app2 --flat "repo/img1/layer_abc" "/tmp/SHA1" && jf rt u --server-id=app3 "/tmp/SHA1" "repo-copy/img1/layer_abc"
jf rt dl --server-id=app2 --flat "repo/img2/layer_abc" "/tmp/SHA1" && jf rt u --server-id=app3 "/tmp/SHA1" "repo-copy/img2/layer_abc"
```

**Output (one compound command per unique SHA1):**

```text
_TD=$(mktemp -d) && jf rt dl --server-id=app2 --flat "repo/img1/layer_abc" "$_TD/SHA1" && jf rt u --server-id=app3 "$_TD/SHA1" "repo-copy/img1/layer_abc" && jf rt u --server-id=app3 "$_TD/SHA1" "repo-copy/img2/layer_abc" ; rm -rf "$_TD"
```

- **One download** per unique SHA1 (from the first source path seen — same content regardless of source path).
- **All uploads** chained with `&&` (sequential within the group — the downloaded file is shared).
- **Cleanup** at the end (`rm -rf "$_TD"`); only runs after all uploads complete.
- Each group is **one task** for the parallel runner: different SHA1 groups run in parallel; within each group, uploads are sequential (safe).

## How it interacts with the parallel runner

After grouping, each line in `_grouped.sh` is executed as a single parallel task by **runcommand_in_parallel_from_file.sh**. The runner also applies **per-task /tmp isolation** (Option A): any remaining `/tmp/` references are rewritten to a per-task temp dir. Together:

| Protection | Provided by |
|------------|-------------|
| Eliminate duplicate downloads (network savings) | **group_sync_by_sha1.sh** |
| Isolate /tmp paths between parallel tasks (race-condition safety) | **runcommand_in_parallel_from_file.sh** (Option A) |
| Cleanup temp files after each task | Both (grouped script's `rm -rf $_TD` + runner's `rm -rf $task_tmpdir`) |

## Running the grouped script

```bash
./runcommand_in_parallel_from_file.sh --log-success ./03_to_sync_grouped.sh ./03_to_sync_grouped_out.txt 10
```

Or via **sync-target-from-source.sh**, which groups and runs automatically.

## Edge case: upload failure mid-chain

If one upload fails in the `&&` chain, the remaining uploads for that SHA1 are skipped (the chain stops). The temp file is still cleaned up (the `; rm -rf` uses `;` not `&&`). On retry, rerun the original `03_to_sync.sh` through the grouper.

## Requirements

- **Bash** (uses arrays and `=~`; no associative arrays — compatible with bash 3.2+).
- **Input:** Lines matching the dl+upload format above.

## See also

- [README-sync-target-from-source.md](README-sync-target-from-source.md) — One-shot workflow; uses this grouper automatically.
- [README-convert_dl_upload_to_rt_cp.md](README-convert_dl_upload_to_rt_cp.md) — Converter for same-Artifactory (jf rt cp); used instead of grouping when source and target URLs are identical.
- [README-helper-scripts.md](README-helper-scripts.md) — Parallel runner docs.
