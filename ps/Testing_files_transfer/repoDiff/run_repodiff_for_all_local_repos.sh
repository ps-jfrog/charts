#!/bin/bash

# Validate input
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <SOURCE_ARTIFACTORY_ID> <TARGET_ARTIFACTORY_ID> <REPO_LIST_FILE> <PYTHON_SCRIPT>"
  exit 1
fi

# Assign inputs to variables
SOURCE_ARTIFACTORY_ID="$1"
TARGET_ARTIFACTORY_ID="$2"
REPO_LIST_FILE="$3"
PYTHON_SCRIPT="$4"

echo "Fetching list of local repositories from source Artifactory..."

# Fetch all local repos and write to file
jf rt curl -X GET "/api/repositories?type=local" --server-id "$SOURCE_ARTIFACTORY_ID" \
  | jq -r '.[] | .key' > "$REPO_LIST_FILE"

# Sort the list in-place
sort -o "$REPO_LIST_FILE" "$REPO_LIST_FILE"


REPO_COUNT=$(wc -l < "$REPO_LIST_FILE")
echo "Found $REPO_COUNT local repositories. Starting repodiff execution..."

# Loop through each repository
while IFS= read -r repo; do
  echo "Running repodiff.py for repo: $repo"
  python "$PYTHON_SCRIPT" \
    --source-artifactory "$SOURCE_ARTIFACTORY_ID" \
    --target-artifactory "$TARGET_ARTIFACTORY_ID" \
    --source-repo "$repo" \
    --target-repo "$repo"
done < "$REPO_LIST_FILE"

echo "✅ Completed repodiff for all $REPO_COUNT local repositories."
