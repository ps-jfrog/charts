#!/bin/bash

# Usage:
# ./4_run-config-import-plugin-install.sh <JFROG_HELM_RELEASE_NAME> <JFROG_PLATFORM_NAMESPACE> <FULL_PATH_TO_SCRIPT> [JFROG_ACCESS_TOKEN]
#
# Example:
# cd /Users/sureshv/mycode/bitbucket-ps/ps_jfrog_scripts/jf-transfer-migration-helper-scripts/before-migration-helper-scripts/install_migration_plugins
# bash ./install_target_rt_plugins/1_run-config-import-plugin-install.sh apple2-release ps-jfrog-platform ./install_target_rt_plugins/2_install-config-import-plugin.sh abc123mytoken
# OR
# export JFROG_ACCESS_TOKEN=abc123mytoken
# bash ./install_target_rt_plugins/1_run-config-import-plugin-install.sh apple2-release ps-jfrog-platform ./install_target_rt_plugins/2_install-config-import-plugin.sh

set -e

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <JFROG_HELM_RELEASE_NAME> <JFROG_PLATFORM_NAMESPACE> <FULL_PATH_TO_SCRIPT> [JFROG_ACCESS_TOKEN]"
  exit 1
fi

HELM_RELEASE="$1"
NAMESPACE="$2"
SCRIPT_FULL_PATH="$3"
ACCESS_TOKEN_ARG="$4"

# Resolve token from argument or environment
if [ -n "$ACCESS_TOKEN_ARG" ]; then
  ACCESS_TOKEN="$ACCESS_TOKEN_ARG"
elif [ -n "$JFROG_ACCESS_TOKEN" ]; then
  ACCESS_TOKEN="$JFROG_ACCESS_TOKEN"
else
  echo "❌ Error: JFrog access token not provided."
  echo "Pass it as the 4th argument or export JFROG_ACCESS_TOKEN in your environment."
  exit 1
fi

SCRIPT_NAME=$(basename "$SCRIPT_FULL_PATH")

CONTAINER_NAME="artifactory"
REMOTE_PATH="/tmp/${SCRIPT_NAME}"
SERVICE_NAME="${HELM_RELEASE}-artifactory"
ARTIFACTORY_URL="http://${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:8082/artifactory"

FIRST_RUNNING_ARTIFACTORY_POD=""

# Loop through all pods and find the first matching one that is Running
while read -r POD_NAME STATUS; do
  if [[ "$POD_NAME" =~ ^${HELM_RELEASE}-artifactory-[0-9]+$ ]] && [[ "$STATUS" == "Running" ]]; then
    FIRST_RUNNING_ARTIFACTORY_POD="$POD_NAME"
    break
  fi
done < <(kubectl get pods -n "${NAMESPACE}" --no-headers | awk '{print $1, $3}')

if [[ -n "$FIRST_RUNNING_ARTIFACTORY_POD" ]]; then
  echo "✅ First running Artifactory pod: $FIRST_RUNNING_ARTIFACTORY_POD"
else
  echo "❌ Error: No Artifactory pods found for release ${HELM_RELEASE}"
  exit 1
fi



echo "�� Processing pod: ${FIRST_RUNNING_ARTIFACTORY_POD}"

echo "📦 Copying ${SCRIPT_NAME} into container '${CONTAINER_NAME}' of pod ${FIRST_RUNNING_ARTIFACTORY_POD}..."

# Copy the script into the container using tar workaround
tar cf - -C "$(dirname "$SCRIPT_FULL_PATH")" "$SCRIPT_NAME" | \
kubectl exec -i "${FIRST_RUNNING_ARTIFACTORY_POD}" -c "${CONTAINER_NAME}" -n "${NAMESPACE}" -- tar xf - -C /tmp

echo "🚀 Executing ${SCRIPT_NAME} with token and Artifactory URL inside '${CONTAINER_NAME}'..."
kubectl exec -it "${FIRST_RUNNING_ARTIFACTORY_POD}" -c "${CONTAINER_NAME}" -n "${NAMESPACE}" -- \
  bash "$REMOTE_PATH" "$ACCESS_TOKEN" "$ARTIFACTORY_URL"

echo "✅ Script executed successfully in '${CONTAINER_NAME}' container of pod ${FIRST_RUNNING_ARTIFACTORY_POD}."


echo "✅ Installation completed on all Artifactory pods."