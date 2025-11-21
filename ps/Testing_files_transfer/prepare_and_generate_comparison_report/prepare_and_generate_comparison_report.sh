#!/bin/bash

# Set error handling
set -e

# Function to display usage
usage() {
    echo "Usage: $0 [SOURCE_SERVER] [TARGET_SERVER]"
    echo ""
    echo "Arguments:"
    echo "  SOURCE_SERVER    JFrog CLI server ID for source Artifactory (default: source-server)"
    echo "  TARGET_SERVER    JFrog CLI server ID for target Artifactory (default: target-server)"
    echo ""
    echo "Environment variables (optional):"
    echo "  SOURCE_SERVER    Can be set as environment variable"
    echo "  TARGET_SERVER    Can be set as environment variable"
    echo ""
    echo "Examples:"
    echo "  $0 source-artifactory target-artifactory"
    echo "  SOURCE_SERVER=my-source TARGET_SERVER=my-target $0"
    exit 1
}

# Parse command-line arguments or use defaults
if [ $# -eq 1 ] && ([ "$1" = "-h" ] || [ "$1" = "--help" ]); then
    usage
fi

# Variables with defaults (can be overridden by command-line args or environment variables)
timestamp=$(date +"%Y-%m-%d-%H-%M-%S")
SOURCE_SERVER="${1:-${SOURCE_SERVER:-source-server}}"
TARGET_SERVER="${2:-${TARGET_SERVER:-target-server}}"
LOCAL_REPOS_FILE="all-local-repo-source-${timestamp}.txt"
FEDERATED_REPOS_FILE="all-federated-repos-in-source-${timestamp}.txt"
SOURCE_STORAGE_INFO="source-storageinfo-${timestamp}.json"
TARGET_STORAGE_INFO="target-storageinfo-${timestamp}.json"
COMPARISON_OUTPUT="comparison-${timestamp}.txt"

# Function to calculate storage info
calculate_storage_info() {
    local server_id=$1
    echo "Calculating storage info for ${server_id}..."
    jf rt curl -X POST "/api/storageinfo/calculate" --server-id="${server_id}"
}

# Function to get repository list
get_repo_list() {
    local server_id=$1
    local type=$2
    local output_file=$3
    # local repo_name=rev-pipeline-release-local
    echo "Getting ${type} repositories from ${server_id}..."
    jf rt curl -X GET "/api/repositories?type=${type}" --server-id="${server_id}" | jq -r '.[] | .key' > "${output_file}"
    # redirect repo_name to output_file
    # echo "${repo_name}" >> "${output_file}"
    sort -o "${output_file}" "${output_file}"
}

# Function to get storage info
get_storage_info() {
    local server_id=$1
    local output_file=$2
    echo "Getting storage info for ${server_id}..."
    jf rt curl -X GET "/api/storageinfo" --server-id="${server_id}" > "${output_file}"
}

# Main execution
echo "Starting repository comparison..."

# Calculate storage info for both servers
calculate_storage_info "${SOURCE_SERVER}"
calculate_storage_info "${TARGET_SERVER}"

# Get repository lists
get_repo_list "${SOURCE_SERVER}" "local" "${LOCAL_REPOS_FILE}"
# get_repo_list "${SOURCE_SERVER}" "federated" "${FEDERATED_REPOS_FILE}"

# Get storage info
get_storage_info "${SOURCE_SERVER}" "${SOURCE_STORAGE_INFO}"
get_storage_info "${TARGET_SERVER}" "${TARGET_STORAGE_INFO}"

# Run comparison for local repositories
echo "Running comparison..."
python compare_repo_list_details_in_source_vs_target_rt_after_migration.py \
    --source "${SOURCE_STORAGE_INFO}" \
    --target "${TARGET_STORAGE_INFO}" \
    --repos "${LOCAL_REPOS_FILE}" \
    --out "${COMPARISON_OUTPUT}" \
    --source_server_id "${SOURCE_SERVER}" \
    --target_server_id "${TARGET_SERVER}"

# Run comparison for federated repositories
# echo "Running comparison..."
# python compare_repo_list_details_in_source_vs_target_rt_after_migration.py \
#     --source "${SOURCE_STORAGE_INFO}" \
#     --target "${TARGET_STORAGE_INFO}" \
#     --repos "${FEDERATED_REPOS_FILE}" \
#     --out "${COMPARISON_OUTPUT}" \
#     --source_server_id "${SOURCE_SERVER}" \
#     --target_server_id "${TARGET_SERVER}"

echo "Comparison complete. Results saved to ${COMPARISON_OUTPUT}"

