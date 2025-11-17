# Artifactory Log Extraction (Safe Script)

## Overview

The `extract-artifactory-logs-safe.sh` script safely extracts Artifactory logs from pods or their PersistentVolumeClaims (PVCs), with intelligent handling of ReadWriteOnce (RWO) PVC constraints. It automatically handles StatefulSet-managed pods by scaling them down temporarily to free the PVC.

This script is designed to work with:
- Running pods
- CrashLoopBackOff pods
- Completely down pods
- StatefulSet-managed pods (automatically scales down/up)
- ReadWriteOnce (RWO) PVCs

## Features

- ✅ **Safe for RWO PVCs**: Intelligently handles ReadWriteOnce constraints
- ✅ **StatefulSet-aware**: Automatically scales down StatefulSets to free PVCs, then restores them
- ✅ **CrashLoopBackOff detection**: Automatically detects and handles restarting pods
- ✅ **Automatic pod termination**: Optional `--terminate-pod` flag to automatically terminate problematic pods
- ✅ **Multiple extraction methods**: Tries direct extraction first, falls back to PVC method
- ✅ **Automatic cleanup**: Restores StatefulSets and cleans up temporary resources
- ✅ **Customer-ready**: Independent of JPD/terraform configuration, uses standard Kubernetes resources

## Prerequisites

- `kubectl` installed and configured
- Access to the Kubernetes cluster where Artifactory is deployed
- Appropriate permissions to:
  - Get pod/PVC/StatefulSet information
  - Execute commands in pods
  - Create temporary pods
  - Scale StatefulSets (when using `--terminate-pod` flag)
  - Delete pods (when using `--terminate-pod` flag)

## Usage

### Flag-Based Syntax (Recommended)

```bash
./scripts/extract-artifactory-logs-safe/extract-artifactory-logs-safe.sh \
  --namespace <namespace> \
  --pod <pod-name> \
  [--output-dir <dir>] \
  [--terminate-pod]
```

### Legacy Positional Syntax

```bash
./scripts/extract-artifactory-logs-safe/extract-artifactory-logs-safe.sh <namespace> <pod-name> [output-dir]
```

## Options

| Option | Description | Required | Default |
|--------|-------------|----------|---------|
| `--namespace <namespace>` | Kubernetes namespace | Yes | - |
| `--pod <pod-name>` | Pod name | Yes | - |
| `--output-dir <dir>` | Output directory for tar.gz file | No | `./` |
| `--terminate-pod` | Automatically terminate CrashLoopBackOff pods or scale down StatefulSets | No | - |
| `--help` or `-h` | Show help message | No | - |

## How It Works

### Extraction Methods

1. **Direct Extraction**
   - Attempts to extract logs directly from the running pod
   - Fastest method when pod is stable
   - Currently commented out in the script

2. **PVC Extraction via Temporary Pod**
   - Creates a temporary pod with the PVC mounted
   - Extracts logs from the PVC
   - Automatically cleans up the temporary pod

### StatefulSet Handling

When a pod is managed by a StatefulSet and `--terminate-pod` is used:

1. **Scale Down**: The script scales the StatefulSet to 0 replicas (saving the original count)
2. **Wait**: Waits for all pods to terminate and PVC to be unmounted
3. **Extract**: Creates a temporary pod to extract logs
4. **Restore**: Automatically scales the StatefulSet back to its original replica count

**Important**: The original replica count is stored in `/tmp/sts-<name>-replicas-<PID>.txt` and is automatically restored after extraction.

### CrashLoopBackOff Detection

The script detects CrashLoopBackOff pods by checking:
- Explicit CrashLoopBackOff state
- High restart count (>5) with container not ready
- Container readiness status

## Examples

### Extract Logs from Running Pod

```bash
./scripts/extract-artifactory-logs-safe/extract-artifactory-logs-safe.sh \
  --namespace jfrog-prod \
  --pod jpd-prod-artifactory-0 \
  --output-dir ./logs/
```

### Extract Logs with Automatic Pod Termination

```bash
./scripts/extract-artifactory-logs-safe/extract-artifactory-logs-safe.sh \
  --namespace jfrog-prod \
  --pod jpd-prod-artifactory-0 \
  --output-dir ./logs/ \
  --terminate-pod
```

**What happens:**
- Script detects pod is in CrashLoopBackOff or problematic state
- If StatefulSet-managed: scales down StatefulSet to 0
- If regular pod: deletes the pod
- Waits for PVC to be unmounted
- Extracts logs using temporary pod
- Restores StatefulSet (if applicable)

### Extract Logs from StatefulSet-Managed Pod

```bash
./scripts/extract-artifactory-logs-safe/extract-artifactory-logs-safe.sh \
  --namespace jfrog-prod \
  --pod jpd-prod-artifactory-0 \
  --output-dir ./logs/ \
  --terminate-pod
```

**Output example:**
```
Extracting Artifactory logs from jpd-prod-artifactory-0 in namespace jfrog-prod...
Detected PVC: artifactory-volume-jpd-prod-artifactory-0 (AccessMode: ReadWriteOnce)
⚠️ PVC is ReadWriteOnce and currently mounted by another pod.
🔍 --terminate-pod flag is set. Looking for pods to terminate...
Found pods using PVC: jpd-prod-artifactory-0
  Checking pod jpd-prod-artifactory-0: state=Running, waiting_reason=, restart_count=17, ready=false
✅ Pod jpd-prod-artifactory-0 is in CrashLoopBackOff or has been restarting (restart_count=17). Terminating...
⚠️  Pod jpd-prod-artifactory-0 is managed by StatefulSet jpd-prod-artifactory. Scaling down StatefulSet instead of deleting pod...
📉 Scaling down StatefulSet jpd-prod-artifactory from 1 to 0 replicas...
✅ StatefulSet jpd-prod-artifactory scaled down successfully
Waiting for pod to be fully terminated and PVC to be unmounted...
⏳ Waiting for PVC artifactory-volume-jpd-prod-artifactory-0 to be unmounted (max 60s)...
✅ PVC artifactory-volume-jpd-prod-artifactory-0 is now unmounted
Proceeding with temporary pod extraction...
📦 Using temporary pod with PVC: artifactory-volume-jpd-prod-artifactory-0
✅ Logs saved from PVC to ./logs/jpd-prod-artifactory-0-logs-20241116-193045.tar.gz
Restoring StatefulSet jpd-prod-artifactory...
📈 Scaling up StatefulSet jpd-prod-artifactory back to 1 replicas...
✅ StatefulSet jpd-prod-artifactory scaled up to 1 replicas
To extract: tar -xzf ./logs/jpd-prod-artifactory-0-logs-20241116-193045.tar.gz
```

### Legacy Positional Syntax

```bash
./scripts/extract-artifactory-logs-safe/extract-artifactory-logs-safe.sh jfrog-prod jpd-prod-artifactory-0 ./logs/
```

## Output

The script creates a tar.gz file with a timestamp in the specified output directory:

```
<pod-name>-logs-<timestamp>.tar.gz
```

**Example**: `jpd-prod-artifactory-0-logs-20241116-193045.tar.gz`

### Extracting the Archive

```bash
# Extract the tar.gz file
tar -xzf jpd-prod-artifactory-0-logs-20241116-193045.tar.gz

# Or extract to a specific directory
tar -xzf jpd-prod-artifactory-0-logs-20241116-193045.tar.gz -C ./extracted-logs/
```

## Troubleshooting

### Pod Not Found

**Error**: `Pod <pod-name> not found`

**Solution**: 
- Verify pod name: `kubectl get pods -n <namespace>`
- Check namespace: `kubectl get pods -n <namespace>`

### PVC Not Found

**Error**: `No PVC detected and pod never entered Running state`

**Solution**:
- Verify pod has a PVC: `kubectl describe pod <pod-name> -n <namespace>`
- Check if pod exists: `kubectl get pod <pod-name> -n <namespace>`

### ReadWriteOnce Constraint Error

**Error**: `PVC is ReadWriteOnce and currently mounted by another pod`

**Solution**:
- Use `--terminate-pod` flag to automatically handle this
- Or wait for the pod to terminate naturally
- For StatefulSet-managed pods, the script will automatically scale down the StatefulSet

### StatefulSet Not Restored

**Warning**: `Could not find original replica count for StatefulSet`

**Solution**:
- The script stores the replica count in `/tmp/sts-<name>-replicas-<PID>.txt`
- If the file is missing, manually scale the StatefulSet:
  ```bash
  kubectl scale statefulset <name> -n <namespace> --replicas=<original-count>
  ```
- Check StatefulSet status: `kubectl get statefulset <name> -n <namespace>`

### Timeout Waiting for PVC to be Unmounted

**Error**: `Timeout waiting for PVC to be unmounted`

**Solution**:
- For StatefulSet-managed pods, ensure the StatefulSet was scaled down successfully
- Check if pods are still running: `kubectl get pods -n <namespace>`
- Verify StatefulSet replica count: `kubectl get statefulset -n <namespace>`
- The script will attempt to create the temporary pod anyway (may succeed if timing is right)

### Temporary Pod Creation Failed

**Error**: `Failed to extract logs from PVC`

**Solution**:
- Check if PVC is still mounted: `kubectl get pods -n <namespace> -o wide`
- Verify PVC exists: `kubectl get pvc -n <namespace>`
- Check RBAC permissions (need to create pods)
- Verify namespace exists
- Check for resource quotas

## Important Notes

### StatefulSet Behavior

- **Automatic Scaling**: When `--terminate-pod` is used with StatefulSet-managed pods, the script automatically scales down the StatefulSet to 0, extracts logs, then scales it back up
- **Replica Count Storage**: The original replica count is stored in `/tmp/sts-<name>-replicas-<PID>.txt` using the script's process ID for uniqueness
- **Restoration**: The StatefulSet is automatically restored even if log extraction fails
- **Manual Restoration**: If the script is interrupted, you may need to manually restore the StatefulSet

### Safety Considerations

- **ReadWriteOnce PVCs**: The script safely handles RWO PVCs by ensuring they're unmounted before creating temporary pods
- **StatefulSet Restoration**: Always restores StatefulSets to their original replica count
- **Cleanup**: Automatically cleans up temporary pods and files
- **Error Handling**: Attempts to restore StatefulSets even if extraction fails

### When to Use `--terminate-pod`

Use the `--terminate-pod` flag when:
- Pod is in CrashLoopBackOff state
- Pod has high restart count (>5) and container is not ready
- Pod is blocking PVC access and you need to extract logs
- You want the script to automatically handle StatefulSet scaling

**Note**: The flag will terminate problematic pods or scale down StatefulSets. For StatefulSet-managed pods, this is safe as the StatefulSet will be automatically restored.

## Comparison with `extract-artifactory-logs.sh`

| Feature | `extract-artifactory-logs-safe.sh` | `extract-artifactory-logs.sh` |
|---------|-----------------------------------|-------------------------------|
| StatefulSet handling | ✅ Automatic scale down/up | ❌ Manual intervention needed |
| RWO PVC safety | ✅ Automatic waiting | ✅ Automatic waiting |
| Pod termination | ✅ Optional `--terminate-pod` flag | ❌ No automatic termination |
| Extraction methods | PVC via temp pod | Multiple methods (exec, debug, temp pod) |
| Complexity | Simpler, focused on safety | More comprehensive, handles more edge cases |

## Related Scripts

- `extract-artifactory-logs.sh` - More comprehensive log extraction with multiple methods
- `backup-jpd-databases.sh` - Backup Artifactory databases
- `restore-jpd-databases.sh` - Restore Artifactory databases
- `cost-saving-teardown.sh` - Teardown JPD deployments

## See Also

- [DEPLOYMENT.md](../DEPLOYMENT.md) - Deployment guide
- [TEARDOWN.md](../TEARDOWN.md) - Teardown procedures
- [README.md](../README.md) - Project overview
- [README-extract-artifactory-logs.md](./README-extract-artifactory-logs.md) - Comprehensive log extraction guide

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review pod/PVC/StatefulSet status: `kubectl get pods,pvc,statefulset -n <namespace>`
3. Check script output for detailed error messages
4. Verify Kubernetes cluster version and kubectl version
5. Ensure you have appropriate RBAC permissions

