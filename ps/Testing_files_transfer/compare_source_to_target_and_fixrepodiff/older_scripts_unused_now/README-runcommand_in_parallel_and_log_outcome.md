# runcommand_in_parallel_and_log_outcome.sh (deprecated)

> **Note:** This script has been superseded by `runcommand_in_parallel_from_file.sh` (in the parent directory), which provides progress reporting with total/percent, optional success logging, and is used by `sync-target-from-source.sh`.

Reads **one command per line** from **standard input**. Trims lines and skips empty ones. Use in a pipeline when commands come from another process or from `cat file`.

## Usage

```text
./runcommand_in_parallel_and_log_outcome.sh <failure_log_file> <max_parallel>
```

Commands are read from stdin; no command file argument.

## Arguments

| Argument | Description |
|----------|-------------|
| `failure_log_file` | File to append failed commands and their output to. |
| `max_parallel` | Maximum number of commands running at once (positive integer). |

## Output

- **Success:** `[task <i>] Command successful: <command>`
- **Failure:** `[task <i>] Command failed: <command>`

Task index `i` is the 1-based index of the command in the input stream. There is no total or percentage (input length is not known in advance when using stdin).

## Examples

Pipe a command file into the script:

```bash
cat test_reconcile_target_only/03_to_sync.sh | ./runcommand_in_parallel_and_log_outcome.sh test_reconcile_target_only/03_to_sync_out.txt 10
```

Pipe from another script:

```bash
./some_script_that_prints_commands.sh | ./runcommand_in_parallel_and_log_outcome.sh failures.txt 16
```

## Behavior

- **Concurrency:** At most `max_parallel` commands run at once; the script waits when the limit is reached.
- **Temp isolation (per-task /tmp rewrite):** Each command runs with `TMPDIR`, `TEMP`, and `TMP` set to a new `mktemp -d` directory. Before execution, any `/tmp/` paths in the command are **rewritten** to the per-task temp dir so parallel tasks downloading the same SHA1 don't collide or delete each other's files. The per-task temp dir is removed after the command finishes.
- **Failure log:** For each failed command, the script appends the command line and the command's stdout/stderr to the failure log file.
