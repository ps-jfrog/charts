# Extract Container Files Script

## Overview

`extract-container-files.sh` is an enhanced version of the `extract-artifactory-logs-safe.sh` script that allows you to extract files from any container in a Kubernetes pod, with configurable paths and extraction modes.

## Key Features

- **Configurable Container Name**: Specify which container to extract files from (default: `artifactory`)
- **Multiple Paths**: Extract from multiple paths in a single run
- **Per-Path Recursive Control**: Specify `--no-recursive` after each `--path` to control extraction mode per path (default: recursive)
- **Safe for RWO PVCs**: Handles ReadWriteOnce PersistentVolumeClaims safely by managing pod termination and StatefulSet scaling
- **Automatic Pod Termination**: Option to automatically terminate CrashLoopBackOff pods to free PVCs
- **Dual Extraction Methods**: Tries direct extraction from the pod first, falls back to PVC-based extraction if needed

## Prerequisites

- `kubectl` configured and authenticated
- Access to the target Kubernetes namespace
- Permissions to create/delete pods and scale StatefulSets (if using `--terminate-pod`)

## Usage

### Basic Syntax

```bash
./extract-container-files.sh --namespace <namespace> --pod <pod-name> --path <path> [OPTIONS]
```

### Required Arguments

- `--namespace <namespace>`: Kubernetes namespace containing the pod
- `--pod <pod-name>`: Name of the pod to extract files from
- `--path <path>`: Path to extract (can be specified multiple times)

### Optional Arguments

- `--container <name>`: Container name (default: `artifactory`)
- `--output-dir <dir>`: Output directory for the archive (default: `./`)
- `--no-recursive`: Apply to the immediately preceding `--path` to extract only files in that directory (excluding subdirectories). If not specified, the path is extracted recursively (default).
- `--terminate-pod`: Automatically delete CrashLoopBackOff pods to free PVCs
- `--help` or `-h`: Display help message

**Note**: The `--no-recursive` flag applies only to the immediately preceding `--path`. Each path can have its own recursive setting. By default, all paths are extracted recursively unless `--no-recursive` is specified after a particular `--path`.

## Examples

### Example 1: Extract Artifactory Logs Recursively

Extract logs from the default `artifactory` container recursively:

```bash
./extract-container-files.sh \
  --namespace jpd-prod \
  --pod artifactory-0 \
  --path /opt/jfrog/artifactory/var/log
```

### Example 2: Extract Multiple Paths with Mixed Recursive Settings

Extract multiple paths from the `xray` container, with different recursive settings per path:

```bash
./extract-container-files.sh \
  --namespace jpd-prod \
  --pod xray-0 \
  --container xray \
  --path /opt/jfrog/xray/var/log \
  --path /opt/jfrog/xray/var/etc --no-recursive \
  --path /opt/jfrog/xray/var/data
```

In this example:
- `/opt/jfrog/xray/var/log` is extracted **recursively** (default)
- `/opt/jfrog/xray/var/etc` is extracted **non-recursively** (only top-level files)
- `/opt/jfrog/xray/var/data` is extracted **recursively** (default)

### Example 3: Extract with Automatic Pod Termination

Extract files and automatically terminate CrashLoopBackOff pods if needed:

```bash
./extract-container-files.sh \
  --namespace jpd-prod \
  --pod artifactory-0 \
  --path /opt/jfrog/artifactory/var/log \
  --terminate-pod
```

### Example 4: Extract from Custom Container and Path

Extract from a custom container and path:

```bash
./extract-container-files.sh \
  --namespace my-namespace \
  --pod my-pod \
  --container my-container \
  --path /var/log/app \
  --path /var/config \
  --output-dir ./extracted-files
```

### Example 5: Extract Only Top-Level Files

Extract only files in the specified directory, excluding subdirectories:

```bash
./extract-container-files.sh \
  --namespace jpd-prod \
  --pod artifactory-0 \
  --path /opt/jfrog/artifactory/var/log \
  --no-recursive
```

### Example 6: All Paths Non-Recursively

Extract multiple paths, all non-recursively:

```bash
./extract-container-files.sh \
  --namespace jpd-prod \
  --pod my-pod \
  --path /var/log/app --no-recursive \
  --path /var/config --no-recursive \
  --path /tmp/data --no-recursive
```

## How It Works

### Extraction Methods

1. **Direct Extraction (Primary)**: 
   - Attempts to extract files directly from the running pod using `kubectl exec`
   - Works if the pod is in a Running state, even if it's been restarting
   - Tries up to 20 times with 0.5s intervals to catch the pod in a Running state

2. **PVC-Based Extraction (Fallback)**:
   - If direct extraction fails, creates a temporary busybox pod with the same PVC
   - Extracts files from the mounted PVC
   - Automatically cleans up the temporary pod after extraction

### RWO PVC Handling

For ReadWriteOnce (RWO) PVCs that are already mounted:

- **Without `--terminate-pod`**: Waits up to 5 minutes for the pod to terminate naturally
- **With `--terminate-pod`**: 
  - Automatically identifies CrashLoopBackOff pods
  - For StatefulSet-managed pods: Scales down the StatefulSet to 0
  - For regular pods: Deletes the pod
  - Waits for PVC to be unmounted
  - Restores StatefulSet to original replica count after extraction

### Recursive vs Non-Recursive

- **Recursive (default)**: Extracts all files and subdirectories from the specified path
  - Uses: `tar -cz -C <dir> <basename>`
  - Applied when `--no-recursive` is not specified after a `--path`
  
- **Non-Recursive**: Extracts only files in the specified directory, excluding subdirectories
  - Uses: `find <path> -maxdepth 1 -type f | tar -cz -T -`
  - Applied when `--no-recursive` immediately follows a `--path`
  - Each path can have its own recursive setting independently

## Output

The script creates a compressed tar.gz archive with the naming pattern:
```
<pod-name>-<container-name>-files-<timestamp>.tar.gz
```

Example: `artifactory-0-artifactory-files-20240115-143022.tar.gz`

To extract the archive:
```bash
tar -xzf <archive-name>.tar.gz
```

## Error Handling

- Validates required arguments before execution
- Checks if pod exists before attempting extraction
- Handles missing paths gracefully (warns but continues with other paths)
- Restores StatefulSets even if extraction fails
- Provides clear error messages and troubleshooting tips

## Troubleshooting

### Pod Not Found

If the pod doesn't exist, the script will:
- Skip direct extraction
- Attempt to find the PVC by name patterns
- Suggest checking PVCs manually: `kubectl get pvc -n <namespace>`

### Path Not Found

If a specified path doesn't exist:
- The script will warn but continue with other paths
- For PVC extraction, it tries multiple mount point variations
- Check the path exists: `kubectl exec -n <namespace> <pod> -c <container> -- ls -la <path>`

### PVC Still Mounted

If PVC remains mounted after timeout:
- Use `--terminate-pod` flag to force pod termination
- Manually scale down StatefulSet: `kubectl scale statefulset <sts> -n <namespace> --replicas=0`
- Wait for pods to terminate, then retry the script

### Extraction Returns Empty Archive

- Verify paths exist in the container
- Check file permissions
- Ensure the container has the expected directory structure
- Try extracting from PVC directly if pod extraction fails

## Comparison with extract-artifactory-logs-safe.sh

| Feature | extract-artifactory-logs-safe.sh | extract-container-files.sh |
|---------|----------------------------------|------------------------------|
| Container name | Hardcoded to `artifactory` | Configurable via `--container` |
| Paths | Hardcoded to `/opt/jfrog/artifactory/var/log` | Configurable via `--path` (multiple) |
| Recursive option | Always recursive | Configurable (`--recursive`/`--no-recursive`) |
| Use case | Artifactory logs only | Any container, any paths |

## Best Practices

1. **Always specify paths explicitly**: Don't rely on defaults if you're extracting from non-Artifactory containers
2. **Use `--no-recursive` for large directories**: If you only need top-level files, this reduces archive size
3. **Use `--terminate-pod` carefully**: Only use when you're certain the pod is in a problematic state
4. **Check output directory**: Ensure you have write permissions to the output directory
5. **Verify extracted files**: After extraction, verify the archive contains expected files before deleting source data

## Related Scripts

- `extract-artifactory-logs-safe.sh`: Original script for Artifactory-specific log extraction
- `extract-artifactory-logs.sh`: Alternative extraction script

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review script output for specific error messages
3. Verify kubectl access and permissions
4. Check pod and PVC status: `kubectl get pods,pvc -n <namespace>`

