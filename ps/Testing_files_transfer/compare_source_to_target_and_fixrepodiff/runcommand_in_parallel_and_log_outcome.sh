#!/bin/bash
# usage: ./patch_props_for_artifacts_in_target.sh usvartifactory5 liquid jfrogio liquid  test | ./runcommand_in_parallel_and_log_outcome.sh properties_patch_failed.txt 16
# cat test_reconcile_target_only/03_to_sync.sh | bash ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/runcommand_in_parallel_and_log_outcome.sh test_reconcile_target_only/03_to_sync_out.txt 10

log_file=$1
max_parallel="$2"

# Function to execute a single command and log failures
execute_command() {
  local command="$1"
  local log_file="$2"
  local task_index="$3"
  local task_tmpdir
  task_tmpdir=$(mktemp -d)

  # Isolate /tmp paths: rewrite /tmp/ references in the command to the per-task temp dir
  # so parallel tasks downloading the same SHA1 don't collide or delete each other's files.
  local exec_command
  exec_command=$(echo "$command" | sed "s|/tmp/|${task_tmpdir}/|g")

  local output
  output="$(TMPDIR="$task_tmpdir" TEMP="$task_tmpdir" TMP="$task_tmpdir" $SHELL -c "$exec_command" 2>&1)"
  local exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    echo "[task $task_index] Command successful: $command"
  else
    echo "[task $task_index] Command failed: $command"
    echo "$command" >> "$log_file"
    echo "$output" >> "$log_file"
  fi

  # Remove per-task temp dir (contains all downloaded files for this task)
  rm -rf "$task_tmpdir"
}

# Check if max_parallel is a positive integer
if [[ ! "$max_parallel" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: max_parallel must be a positive integer."
  exit 1
fi

# Read commands from standard input
task_index=0
while IFS= read -r command; do
  # Remove leading and trailing whitespace
  command="$(echo -e "${command}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  
  # Check if the trimmed command is not empty
  if [ -n "$command" ]; then
    ((task_index++))
    execute_command "$command" "$log_file" "$task_index" &
    
    # Limit the number of parallel processes
    while (( $(jobs | wc -l) >= max_parallel )); do
      sleep 1
    done
  fi
done

# Wait for all background jobs to finish
wait
