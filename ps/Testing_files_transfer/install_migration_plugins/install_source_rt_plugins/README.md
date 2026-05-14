# Artifactory Data Transfer Plugin Installation

This directory contains scripts to install the Artifactory Data Transfer plugin on your source Artifactory instance, which is required for migrating data between Artifactory instances using Hermes.

## Prerequisites

- JFrog access token with admin privileges
- Access to the Artifactory instance (either Kubernetes cluster or VM)

## Scripts Overview

1. `1_run-transfer-plugin-install.sh`: Main script that copies and executes the installation script in the Artifactory pod (Kubernetes only)
2. `2_install-transfer-plugin.sh`: Script that performs the actual plugin installation inside Artifactory

## Installation Methods

The  easiest way to install the plugin is to install the data-transfer user plugin in the first node or artifactory pod of the source instance ( if it has access to internet) as mentioned in “[Step 2: Set up the source instance for pushing files to the target instance](https://docs.jfrog.com/integrations/docs/cli-for-jfrog-cloud-transfer#step-2-set-up-the-source-instance-for-pushing-files-to-the-target-instance)” i.e :

a) Install the `jf` cli using curl .

If you have sudo access install as mentioned in https://jfrog.com/getcli/ 
which installs jf in /usr/local/bin
```
curl -fL https://install-cli.jfrog.io | sh
```

or as mentioned in [2_install-transfer-plugin.sh](2_install-transfer-plugin.sh)
```
# Set working directory
WORK_DIR=/opt/jfrog/artifactory/var/tmp
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "📥 Downloading JFrog CLI to $WORK_DIR..."
curl -fkLsS https://getcli.jfrog.io/v2-jf | sh

echo "🔧 Setting executable permission..."
chmod +x jf
```
b) configure the jf cli to connect to the source server:
```
# Set the JFROG_CLI_HOME_DIR if needed:
export JFROG_CLI_HOME_DIR="$WORK_DIR/.jfrog"

echo "⚙️ Configuring JFrog CLI with Artifactory at $ARTIFACTORY_URL..."
./jf c add source-server \
  --interactive=false \
  --artifactory-url "http://localhost:8082/artifactory" \
  --access-token "$ACCESS_TOKEN" \
  --insecure-tls=true \
  --overwrite=true

echo "📡 Verifying connection with Artifactory..."
./jf rt ping --server-id source-server 
```
c) Next install the data transfer plugin:

```
./jf rt transfer-plugin-install source-server --home-dir /opt/jfrog
```
You should see below output:
```
18:11:01 [🔵Info] Installing 'data-transfer' plugin...
18:11:08 [🔵Info] The data-transfer plugin installed successfully.
```
d) Then when  the source artifactory has a HA setup, from any client machine which has jf cli configured to the source JPD you can reload the plugin from the loadbalancer url using:
```
jf rt curl -XGET "/api/plugins/reload" --server-id source-server

# Then verify using:
jf rt curl -XGET "/api/plugins" --server-id source-server
```

Otherwise use one of the following methods:

### Method 1: Kubernetes-based Artifactory Installation

#### Prerequisites
- Access to the Kubernetes cluster where Artifactory is deployed
- `kubectl` configured with access to the cluster
- The Helm release name of your Artifactory installation
- The Kubernetes namespace where Artifactory is deployed

#### Installation Steps

1. Navigate to the scripts directory:
   ```bash
   cd /path/to/install_migration_plugins
   ```

2. Run the installation script using one of these methods:

   **Method 1 - Using access token as argument:**
   ```bash
   bash ./install_source_rt_plugins/1_run-transfer-plugin-install.sh \
     <JFROG_HELM_RELEASE_NAME> \
     <JFROG_PLATFORM_NAMESPACE> \
     ./install_source_rt_plugins/2_install-transfer-plugin.sh \
     <JFROG_ACCESS_TOKEN>
   ```

   **Method 2 - Using environment variable for access token:**
   ```bash
   export JFROG_ACCESS_TOKEN=<your_access_token>
   bash ./install_source_rt_plugins/1_run-transfer-plugin-install.sh \
     <JFROG_HELM_RELEASE_NAME> \
     <JFROG_PLATFORM_NAMESPACE> \
     ./install_source_rt_plugins/2_install-transfer-plugin.sh
   ```

---
### Method 2: VM-based Artifactory Installation

#### Prerequisites
- SSH access to any Artifactory HA node
- Artifactory service user credentials
- The Artifactory URL for your instance

#### Installation Steps

In any one of the nodes of your Artifactory HA cluster:

1. Copy the installation script to the node:
   ```bash
   scp ./install_source_rt_plugins/2_install-transfer-plugin.sh <node-username>@<node-ip>:/tmp/
   ```

2. SSH into the node and run the script as the Artifactory service user:
   ```bash
   ssh <node-username>@<node-ip>
   sudo -u artifactory bash /tmp/2_install-transfer-plugin.sh <JFROG_ACCESS_TOKEN> "http://localhost:8082/artifactory"
   ```

3. The plugin will automatically be installed  in all nodes in your HA cluster.

**Note:** If Artifactory is not installed under `/opt/jfrog/artifactory`, edit `2_install-transfer-plugin.sh` **before** you copy it to the node (or edit the copy in `/tmp`) so the paths match your layout:

1. **`JFROG_HOME`** (default `/opt/jfrog`) — Set this to the directory that **contains** the `artifactory` folder. Example: if your install is `/data/jfrog/artifactory/...`, use `JFROG_HOME=/data/jfrog`.
2. **`WORK_DIR`** (default `/opt/jfrog/artifactory/var/tmp`) — Set this to your instance’s `var/tmp` under that Artifactory home, e.g. `$JFROG_HOME/artifactory/var/tmp` with your actual `$JFROG_HOME`.

The script writes the plugin JAR and Groovy file under `$JFROG_HOME/artifactory/var/etc/artifactory/plugins/`; those lines assume the same `JFROG_HOME` you set above.

Also confirm:

- **`sudo -u artifactory`** — Use the real OS user that runs the Artifactory process if it is not `artifactory`.

`2_install-transfer-plugin.sh` already checks that the plugin installed and that the reload reported success. To confirm manually, list plugins with the JFrog CLI using the same configuration the install script created.

Before running `jf`, point the CLI at the same home directory the install used: export `JFROG_CLI_HOME_DIR` to `$WORK_DIR/.jfrog`, where `$WORK_DIR` is the value set in `2_install-transfer-plugin.sh` (default: `/opt/jfrog/artifactory/var/tmp`). Alternatively, run the command from that `$WORK_DIR` and invoke the local `./jf` binary placed there by the install script.

```bash
export JFROG_CLI_HOME_DIR=/opt/jfrog/artifactory/var/tmp/.jfrog   # adjust if you changed WORK_DIR
cd /opt/jfrog/artifactory/var/tmp                                  # same directory as WORK_DIR
./jf rt curl -XGET "/api/plugins/reload" --server-id source-server
./jf rt curl -XGET "/api/plugins" --server-id source-server
```

On a High Availability cluster, plugin definitions are shared across the cluster; you should see `dataTransfer.groovy` at `$JFROG_HOME/artifactory/var/etc/artifactory/plugins/dataTransfer.groovy` on each node (using each node’s `$JFROG_HOME` if paths differ per host).

---

## What the Scripts Do

1. The main script (`1_run-transfer-plugin-install.sh`):
   - Automatically discovers all Artifactory pods in the HA cluster
   - Copies the installation script into the first `Running` Artifactory pod
   - Executes the installation script with the provided access token
   - Uses the internal Kubernetes service URL for Artifactory
   - Provides progress updates for this pod. 
   - Successful plugin installation on 1 pod installs the plugin on all Artifactory pods in the HA cluster

2. The installation script (`2_install-transfer-plugin.sh`):
   - Downloads and configures JFrog CLI
   - Downloads and installs the Data Transfer plugin
   - Reloads the Artifactory plugins
   - Verifies the installation

## Verification

After running the scripts, you should see success messages indicating:
- JFrog CLI setup completion
- Plugin installation success
- Plugin reload success

If you see any warnings or errors, check the Artifactory logs for more details.

## Troubleshooting

If you encounter issues:
1. Verify your access token has admin privileges
2. For Kubernetes installations:
   - Check that the Helm release name and namespace are correct
   - Ensure you have proper access to the Kubernetes cluster
3. For VM installations:
   - Verify SSH access to all nodes
   - Ensure the Artifactory service user has necessary permissions
4. Check the Artifactory logs for detailed error messages

## Next Steps

After successful installation of the Data Transfer plugin, you can proceed with configuring and running the migration using Hermes as described in the [ARTIFACTORY: Transfer Artifactory Files between Artifactory instances from On-Prem to On-Prem using Hermes](https://jfrog.com/help/r/artifactory-transfer-artifactory-files-between-artifactory-instances-from-on-prem-to-on-prem-using-hermes).

For SAAS migration refer to [CLI for JFrog Cloud Transfer](https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli/cli-for-jfrog-cloud-transfer)

After migration is complete you can remove the plugins as mentioned in [ Removing Plugins](https://jfrog.com/help/r/jfrog-integrations-documentation/remove-plugins)