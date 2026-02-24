# convert_dl_upload_to_rt_cp.sh

Converts a reconciliation script that uses **download + upload** (`jf rt dl` then `jf rt u`) per artifact into a script that uses **copy** (`jf rt cp`) within the same Artifactory instance. Use this when source and target are on the **same** Artifactory (e.g. different CLI profiles like app2 → app3) so artifacts are copied server-side instead of streaming through the client.

## When to use

- You have a generated script such as **03_to_sync.sh** (one `jf rt dl ... && jf rt u ...` per line).
- Source and target repos are on the **same** Artifactory URL (same JPD).
- You want to run **jf rt cp** instead of dl+upload for better performance and no local temp files.

**sync-target-from-source.sh** uses this automatically when `SH_ARTIFACTORY_BASE_URL` and `CLOUD_ARTIFACTORY_BASE_URL` are the same: it generates `03_to_sync_using_copy.sh` and runs that instead of `03_to_sync.sh`.

## Usage

```bash
./convert_dl_upload_to_rt_cp.sh <path/to/script.sh>
```

**Example:**

```bash
./convert_dl_upload_to_rt_cp.sh test/03_to_sync.sh
# Creates test/03_to_sync_using_copy.sh
# Prints: Wrote N cp line(s) to test/03_to_sync_using_copy.sh
```

- **Input:** Any script whose lines follow the dl+upload format (see below). Other lines are copied through unchanged; empty lines and `#` comments are skipped.
- **Output:** Written to the **same directory** as the input file, with the same basename plus `_using_copy.sh` (e.g. `03_to_sync.sh` → `03_to_sync_using_copy.sh`). The output file is overwritten.

## Line format

**Input (one line per artifact):**

```text
jf rt dl --server-id=SOURCE --flat "SOURCE_PATH" "/tmp/xxx" && jf rt u --server-id=TARGET "/tmp/xxx" "DEST_PATH"
```

**Output:**

```text
jf rt cp SOURCE_PATH DEST_PATH --flat=true --threads=8 --dry-run=false --server-id=TARGET
```

- **SOURCE_PATH** / **DEST_PATH** are the repo paths (e.g. `example-repo-local/main.go`, `example-repo-local-copy/main.go`).
- **TARGET** is taken from the upload command’s `--server-id` (e.g. `app3`) and used as the server for `jf rt cp`.

## Environment variables

| Variable         | Default   | Description                                      |
|------------------|-----------|--------------------------------------------------|
| `RT_CP_THREADS`  | `8`       | Value for `--threads` in generated `jf rt cp`.  |
| `RT_CP_DRY_RUN`  | `false`   | Value for `--dry-run` in generated `jf rt cp`. |

Example:

```bash
export RT_CP_THREADS=4
export RT_CP_DRY_RUN=true
./convert_dl_upload_to_rt_cp.sh b4_upload/03_to_sync.sh
```

## Running the generated script

Use the same runner as for other reconciliation scripts:

```bash
./runcommand_in_parallel_from_file.sh --log-success ./03_to_sync_using_copy.sh ./03_to_sync_using_copy_out.txt 10
```

Or from **sync-target-from-source.sh**: when both Artifactory URLs are the same, it generates and runs `03_to_sync_using_copy.sh` for you.

## Requirements

- **Bash** (script uses arrays and `=~`).
- **Input:** A file whose lines match the dl+upload pattern above. Lines that don’t match are copied through; parsing warnings are printed to stderr.

## See also

- [README.md](README.md) — One-shot workflow; uses this converter when source and target URLs are the same.
- [convert_dl_upload_to_rt_cp.sh](convert_dl_upload_to_rt_cp.sh) — The script itself.
