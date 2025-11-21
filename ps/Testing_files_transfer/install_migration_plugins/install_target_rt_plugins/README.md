# Artifactory Config Import Plugin Installation

This directory contains scripts to install the Config Import plugin on your target Artifactory instance, which is required for importing configuration during the migration process using Hermes.

## Prerequisites

- JFrog access token with admin privileges
- Access to the Artifactory instance (either Kubernetes cluster or VM)

## Scripts Overview

1. `1_run-config-import-plugin-install.sh`: Main script that copies and executes the installation script in the Artifactory pod (Kubernetes only)
2. `2_install-config-import-plugin.sh`: Script that performs the actual plugin installation inside Artifactory

## Installation Methods

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
   bash ./install_target_rt_plugins/1_run-config-import-plugin-install.sh \
     <JFROG_HELM_RELEASE_NAME> \
     <JFROG_PLATFORM_NAMESPACE> \
     ./install_target_rt_plugins/2_install-config-import-plugin.sh \
     <JFROG_ACCESS_TOKEN>
   ```

   **Method 2 - Using environment variable for access token:**
   ```bash
   export JFROG_ACCESS_TOKEN=<your_access_token>
   bash ./install_target_rt_plugins/1_run-config-import-plugin-install.sh \
     <JFROG_HELM_RELEASE_NAME> \
     <JFROG_PLATFORM_NAMESPACE> \
     ./install_target_rt_plugins/2_install-config-import-plugin.sh
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
   scp ./install_target_rt_plugins/2_install-config-import-plugin.sh <node-username>@<node-ip>:/tmp/
   ```

2. SSH into the node and run the script as the Artifactory service user:
   ```bash
   ssh <node-username>@<node-ip>
   sudo -u artifactory bash /tmp/2_install-config-import-plugin.sh <JFROG_ACCESS_TOKEN> "http://localhost:8082/artifactory"
   ```

3. The plugin will automatically be installed  in all nodes in your HA cluster.

---
## What the Scripts Do

1. The main script (`1_run-config-import-plugin-install.sh`):
   - Copies the installation script into the Artifactory pod
   - Executes the installation script with the provided access token
   - Uses the internal Kubernetes service URL for Artifactory

2. The installation script (`2_install-config-import-plugin.sh`):
   - Downloads and configures JFrog CLI
   - Downloads and installs the Config Import plugin
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
   - Verify SSH access to the node
   - Ensure the Artifactory service user has necessary permissions
4. Check the Artifactory logs for detailed error messages

## Next Steps

After successful installation of the Config Import plugin, you can proceed with configuring and running the migration using Hermes as described in the [ARTIFACTORY: Transfer Artifactory Files between Artifactory instances from On-Prem to On-Prem using Hermes](https://jfrog.com/help/r/artifactory-transfer-artifactory-files-between-artifactory-instances-from-on-prem-to-on-prem-using-hermes).

For SAAS migration refer to [CLI for JFrog Cloud Transfer](https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli/cli-for-jfrog-cloud-transfer)

After migration is complete you can remove the plugins as mentioned in [ Removing Plugins](https://jfrog.com/help/r/jfrog-integrations-documentation/remove-plugins)