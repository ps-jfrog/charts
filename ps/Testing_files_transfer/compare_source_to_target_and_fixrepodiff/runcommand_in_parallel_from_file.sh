#!/bin/bash
#
# Run commands from a file in parallel with configurable concurrency.
# Logs failures to a file; optionally logs successes. Uses per-task temp
# dirs (TMPDIR/TEMP/TMP) and cleans up /tmp paths referenced in commands.
#
# Usage:
#   bash runcommand_in_parallel_from_file.sh [--log-success | --success-log <path>] <command_file> <failure_log_file> <max_parallel>
#
# Options:
#   --log-success       Write successful commands to a success log derived from
#                       <failure_log_file>: if it ends with .txt, replace with
#                       _success.txt; otherwise append _success.txt.
#   --success-log <path>  Write successful commands to <path>.
#   -h, --help          Show this help and exit.
#
# Arguments:
#   command_file        File with one command per line (trimmed; empty lines skipped).
#   failure_log_file   File to append failed commands and their output to.
#   max_parallel       Maximum number of commands to run in parallel (positive integer).
#
# Progress output:
#   [task <i> of <total> <percent>%] Command successful: <command>
#   [task <i> of <total> <percent>%] Command failed: <command>
#

show_help() {
  sed -n '2,25p' "$0" | sed 's/^# \?//'
  exit 0
}

# Parse optional success-log options
success_log_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      ;;
    --log-success)
      # Will derive from failure_log_file after we have it
      success_log_path="AUTO"
      shift
      ;;
    --success-log)
      [[ $# -lt 2 ]] && { echo "Error: --success-log requires <path>." >&2; exit 1; }
      success_log_path="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 3 ]]; then
  echo "Error: Required arguments: <command_file> <failure_log_file> <max_parallel>" >&2
  echo "Usage: bash $(basename "$0") [--log-success | --success-log <path>] <command_file> <failure_log_file> <max_parallel>" >&2
  exit 1
fi

command_file="$1"
failure_log_file="$2"
max_parallel="$3"

if [[ "$success_log_path" == "AUTO" ]]; then
  if [[ "$failure_log_file" == *.txt ]]; then
    success_log_path="${failure_log_file%.txt}_success.txt"
  else
    success_log_path="${failure_log_file}_success.txt"
  fi
fi

# Validate command_file
if [[ ! -f "$command_file" ]] || [[ ! -r "$command_file" ]]; then
  echo "Error: command_file must be a readable file: $command_file" >&2
  exit 1
fi

# Validate max_parallel
if [[ ! "$max_parallel" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: max_parallel must be a positive integer." >&2
  exit 1
fi

# Function to execute a single command and log outcome
execute_command() {
  local command="$1"
  local log_file="$2"
  local task_index="$3"
  local total="$4"
  local success_log="$5"
  local percent=$(( task_index * 100 / total ))
  local task_tmpdir
  task_tmpdir=$(mktemp -d)
  local output
  output="$(TMPDIR="$task_tmpdir" TEMP="$task_tmpdir" TMP="$task_tmpdir" $SHELL -c "$command" 2>&1)"
  local exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    echo "[task $task_index of $total ${percent}%] Command successful: $command"
    if [ -n "$success_log" ]; then
      echo "$command" >> "$success_log"
    fi
  else
    echo "[task $task_index of $total ${percent}%] Command failed: $command"
    echo "$command" >> "$log_file"
    echo "$output" >> "$log_file"
  fi

  # Remove per-task temp dir (where tools respecting TMPDIR/TEMP/TMP write downloads)
  rm -rf "$task_tmpdir"

  # Delete any /tmp/ path explicitly mentioned in the command (e.g. jf rt dl ... /tmp/xxx or "/tmp/xxx")
  echo "$command" | grep -oE '/tmp/[^ "]+' | sort -u | while IFS= read -r path; do
    [ -n "$path" ] && [ -e "$path" ] && rm -rf "$path"
  done
}

# Read commands from file (trim, skip empty); store in array to get total
commands=()
while IFS= read -r line; do
  line="$(echo -e "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$line" ] && commands+=("$line")
done < "$command_file"

total=${#commands[@]}
if [ "$total" -eq 0 ]; then
  echo "No commands to run in $command_file (only empty or whitespace lines)."
  exit 0
fi

# Run commands in parallel
task_index=0
for command in "${commands[@]}"; do
  ((task_index++))
  execute_command "$command" "$failure_log_file" "$task_index" "$total" "$success_log_path" &

  # Limit the number of parallel processes
  while (( $(jobs -r | wc -l) >= max_parallel )); do
    sleep 1
  done
done

# Wait for all background jobs to finish
wait
