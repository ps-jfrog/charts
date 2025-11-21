#!/bin/bash

# Usage:
# ./3_install-config-import-plugin.sh <ACCESS_TOKEN> <ARTIFACTORY_URL>
# OR
# export JFROG_ACCESS_TOKEN=<token>
# ./3_install-config-import-plugin.sh <ARTIFACTORY_URL>
# OR
# export JFROG_ACCESS_TOKEN=<token>
# export ARTIFACTORY_URL=http://your-artifactory-url:8082
# ./3_install-config-import-plugin.sh

set -e  # Exit on error

# --- Get Access Token ---
if [ -n "$1" ] && [[ "$1" != http* ]]; then
  ACCESS_TOKEN="$1"
elif [ -n "$JFROG_ACCESS_TOKEN" ]; then
  ACCESS_TOKEN="$JFROG_ACCESS_TOKEN"
else
  echo "❌ Error: JFrog access token not provided."
  echo "Provide it as the first argument or set JFROG_ACCESS_TOKEN in the environment."
  exit 1
fi

# --- Get Artifactory URL ---
if [[ "$1" == http* ]]; then
  ARTIFACTORY_URL="$1"
elif [ -n "$2" ]; then
  ARTIFACTORY_URL="$2"
elif [ -n "$ARTIFACTORY_URL" ]; then
  ARTIFACTORY_URL="$ARTIFACTORY_URL"
else
  echo "❌ Error: Artifactory URL not provided."
  echo "Provide it as the second argument or set ARTIFACTORY_URL in the environment."
  exit 1
fi

# Set working directory
WORK_DIR=/opt/jfrog/artifactory/var/tmp
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "📥 Downloading JFrog CLI to $WORK_DIR..."
curl -fkLsS https://getcli.jfrog.io/v2-jf | sh

echo "🔧 Setting executable permission..."
chmod +x jf

export JFROG_CLI_HOME_DIR="$WORK_DIR/.jfrog"

echo "⚙️ Configuring JFrog CLI with Artifactory at $ARTIFACTORY_URL..."
./jf c add target-server \
  --interactive=false \
  --artifactory-url "$ARTIFACTORY_URL" \
  --access-token "$ACCESS_TOKEN" \
  --insecure-tls=true \
  --overwrite=true

echo "📡 Verifying connection with Artifactory..."
./jf rt ping --server-id target-server

echo "✅ JFrog CLI setup completed successfully."

# --- Install the plugin ---
export JFROG_HOME=/opt/jfrog

echo "Installing Config Import plugin (release: [RELEASE])..."

curl -fkLsS "https://releases.jfrog.io/artifactory/jfrog-releases/config-import/\[RELEASE\]/lib/config-import.jar" \
  --output "$JFROG_HOME/artifactory/var/etc/artifactory/plugins/lib/config-import.jar" --create-dirs

curl -fkLsS "https://releases.jfrog.io/artifactory/jfrog-releases/config-import/\[RELEASE\]/configImport.groovy" \
  --output "$JFROG_HOME/artifactory/var/etc/artifactory/plugins/configImport.groovy" --create-dirs

echo "✅ Config Import plugin installed successfully."

# --- Reload Plugins ---
echo ""
echo "🔄 Reloading plugins using JFrog CLI..."
PLUGIN_RELOAD_OUTPUT=$(./jf rt curl -X POST "/api/plugins/reload" --server-id target-server 2>&1)

echo "$PLUGIN_RELOAD_OUTPUT"

# --- Check if the reload output shows success ---
if echo "$PLUGIN_RELOAD_OUTPUT" | grep -q "Successfully loaded"; then
  echo "✅ Plugin reload successful."
else
  echo "⚠️ Plugin reload command completed, but expected success message not found."
  echo "🔍 Please check the Artifactory logs for more details."
fi
