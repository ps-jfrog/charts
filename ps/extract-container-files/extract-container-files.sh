#!/bin/bash
# Extract files from a container in a CrashLoopBackOff pod or its PVC (safe for RWO)
# Usage: 
#   ./extract-container-files.sh --namespace <namespace> --pod <pod-name> --path <path> [OPTIONS]
#
# This script is an enhanced version that allows:
# - Specifying container name
# - Specifying multiple paths
# - Choosing recursive or non-recursive extraction

set -euo pipefail

# Default values
NS=""
POD=""
CONTAINER="artifactory"  # Default container name
PATHS=()  # Array to store paths
PATH_RECURSIVE=()  # Parallel array: "true" or "false" for recursive (same index as PATHS)
OUTDIR="./"
TERMINATE_POD=false
SCALED_DOWN_STS=""  # Track which StatefulSet was scaled down
LAST_PATH_INDEX=-1  # Track the index of the last path added to apply --no-recursive to it

# Parse arguments
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [OPTIONS]"
  echo "  --namespace <namespace>     Kubernetes namespace (required)"
  echo "  --pod <pod-name>            Pod name (required)"
  echo "  --path <path>               Path to extract (can be specified multiple times) (required)"
  echo "                              If followed by --no-recursive, extracts only files in that path"
  echo "                              Otherwise, extracts recursively (default)"
  echo "  --no-recursive              Apply to the immediately preceding --path (non-recursive extraction)"
  echo "  --container <name>          Container name (default: artifactory)"
  echo "  --output-dir <dir>         Output directory (default: ./)"
  echo "  --terminate-pod             Delete CrashLoopBackOff pod to free PVC (optional)"
  echo ""
  echo "Examples:"
  echo "  # Extract logs recursively from artifactory container"
  echo "  $0 --namespace myns --pod mypod --path /opt/jfrog/artifactory/var/log"
  echo ""
  echo "  # Extract multiple paths: first recursively, second non-recursively"
  echo "  $0 --namespace myns --pod mypod --container xray \\"
  echo "     --path /opt/jfrog/xray/var/log \\"
  echo "     --path /opt/jfrog/xray/var/etc --no-recursive"
  echo ""
  echo "  # Extract with automatic pod termination"
  echo "  $0 --namespace myns --pod mypod --path /var/log --terminate-pod"
  exit 1
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NS="$2"
      shift 2
      ;;
    --pod)
      POD="$2"
      shift 2
      ;;
    --container)
      CONTAINER="$2"
      shift 2
      ;;
    --path)
      PATHS+=("$2")
      PATH_RECURSIVE+=("true")  # Default to recursive
      LAST_PATH_INDEX=$((${#PATHS[@]} - 1))  # Track index of last path
      shift 2
      ;;
    --no-recursive)
      if [[ $LAST_PATH_INDEX -lt 0 ]]; then
        echo "Error: --no-recursive must follow a --path option"
        exit 1
      fi
      PATH_RECURSIVE[$LAST_PATH_INDEX]="false"  # Mark last path as non-recursive
      LAST_PATH_INDEX=-1  # Reset so --no-recursive can't be applied twice
      shift
      ;;
    --output-dir)
      OUTDIR="$2"
      shift 2
      ;;
    --terminate-pod)
      TERMINATE_POD=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo "  --namespace <namespace>     Kubernetes namespace (required)"
      echo "  --pod <pod-name>            Pod name (required)"
      echo "  --path <path>               Path to extract (can be specified multiple times) (required)"
      echo "                              If followed by --no-recursive, extracts only files in that path"
      echo "                              Otherwise, extracts recursively (default)"
      echo "  --no-recursive              Apply to the immediately preceding --path (non-recursive extraction)"
      echo "  --container <name>          Container name (default: artifactory)"
      echo "  --output-dir <dir>         Output directory (default: ./)"
      echo "  --terminate-pod             Delete CrashLoopBackOff pod to free PVC (optional)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$NS" ]] || [[ -z "$POD" ]]; then
  echo "Error: --namespace and --pod are required"
  exit 1
fi

if [[ ${#PATHS[@]} -eq 0 ]]; then
  echo "Error: At least one --path is required"
  exit 1
fi

# Ensure arrays are the same length
if [[ ${#PATHS[@]} -ne ${#PATH_RECURSIVE[@]} ]]; then
  echo "Error: Internal error - path arrays mismatch"
  exit 1
fi

OUTFILE="${OUTDIR}/${POD}-${CONTAINER}-files-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p "$OUTDIR"

# --- Utility functions ---
get_state() {
  kubectl get pod "$1" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound"
}

get_pvc() {
  # Try to get PVC from pod spec first
  local pvc=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}' 2>/dev/null || echo "")
  
  # If pod doesn't exist, try to derive PVC name from pod name pattern
  # Common pattern: artifactory-volume-<pod-name>
  if [[ -z "$pvc" ]]; then
    pvc="artifactory-volume-${POD}"
    # Verify the PVC actually exists
    if ! kubectl get pvc "$pvc" -n "$NS" >/dev/null 2>&1; then
      # Try alternative pattern: <pod-name>-volume
      pvc="${POD}-volume"
      if ! kubectl get pvc "$pvc" -n "$NS" >/dev/null 2>&1; then
        echo ""
        return 1
      fi
    fi
  fi
  
  echo "$pvc"
}

get_pvc_access_mode() {
  kubectl get pvc "$1" -n "$NS" -o jsonpath='{.spec.accessModes[0]}' 2>/dev/null || echo ""
}

is_pvc_mounted() {
  local PVC=$1
  local pods=$(kubectl get pods -n "$NS" -o jsonpath="{.items[?(@.spec.volumes[*].persistentVolumeClaim.claimName=='$PVC')].metadata.name}" 2>/dev/null)
  for p in $pods; do
    phase=$(get_state "$p")
    [[ "$phase" =~ ^(Running|Pending|CrashLoopBackOff)$ ]] && return 0
  done
  return 1
}

# Check if pod is in CrashLoopBackOff state or has been restarting
is_pod_crashlooping() {
  local pod=$1
  local waiting_reason=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
  local state=$(get_state "$pod")
  local restart_count=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
  local container_ready=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  
  # Check explicit CrashLoopBackOff state
  if [[ "$waiting_reason" == "CrashLoopBackOff" ]] || [[ "$state" == "CrashLoopBackOff" ]]; then
    return 0  # Pod is in CrashLoopBackOff
  fi
  
  # Check if pod has high restart count and container is not ready (likely crashlooping)
  if [[ "$restart_count" -gt 5 ]] && [[ "$container_ready" != "true" ]]; then
    return 0  # Pod has been restarting frequently
  fi
  
  return 1  # Pod is not in CrashLoopBackOff
}

# Check if pod is managed by a StatefulSet (will be recreated)
is_statefulset_pod() {
  local pod=$1
  local owner=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}' 2>/dev/null || echo "")
  [[ -n "$owner" ]] && return 0
  return 1
}

# Get StatefulSet name for a pod
get_statefulset_name() {
  local pod=$1
  kubectl get pod "$pod" -n "$NS" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}' 2>/dev/null || echo ""
}

# Scale down StatefulSet to 0
scale_down_statefulset() {
  local sts=$1
  local current_replicas=$(kubectl get statefulset "$sts" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  
  if [[ -z "$current_replicas" ]] || [[ "$current_replicas" == "0" ]]; then
    echo "StatefulSet $sts is already scaled to 0"
    return 0
  fi
  
  echo "📉 Scaling down StatefulSet $sts from $current_replicas to 0 replicas..."
  if kubectl scale statefulset "$sts" -n "$NS" --replicas=0 2>/dev/null; then
    echo "✅ StatefulSet $sts scaled down successfully"
    # Store the original replica count for later restoration
    echo "$current_replicas" > "/tmp/sts-${sts}-replicas-$$.txt"
    return 0
  else
    echo "❌ Failed to scale down StatefulSet $sts"
    return 1
  fi
}

# Scale up StatefulSet back to original replica count
scale_up_statefulset() {
  local sts=$1
  local replicas_file="/tmp/sts-${sts}-replicas-$$.txt"
  
  if [[ -f "$replicas_file" ]]; then
    local original_replicas=$(cat "$replicas_file")
    echo "📈 Scaling up StatefulSet $sts back to $original_replicas replicas..."
    if kubectl scale statefulset "$sts" -n "$NS" --replicas="$original_replicas" 2>/dev/null; then
      echo "✅ StatefulSet $sts scaled up to $original_replicas replicas"
      rm -f "$replicas_file"
      return 0
    else
      echo "⚠️  Failed to scale up StatefulSet $sts. Please scale it manually: kubectl scale statefulset $sts -n $NS --replicas=$original_replicas"
      rm -f "$replicas_file"
      return 1
    fi
  else
    echo "⚠️  Could not find original replica count for StatefulSet $sts. Please scale it manually."
    return 1
  fi
}

# Terminate/delete a pod or scale down StatefulSet
terminate_pod() {
  local pod=$1
  
  # If pod is managed by StatefulSet, scale down the StatefulSet instead
  if is_statefulset_pod "$pod"; then
    local sts=$(get_statefulset_name "$pod")
    if [[ -n "$sts" ]]; then
      echo "⚠️  Pod $pod is managed by StatefulSet $sts. Scaling down StatefulSet instead of deleting pod..."
      if scale_down_statefulset "$sts"; then
        # Track which StatefulSet was scaled down
        SCALED_DOWN_STS="$sts"
        return 0
      else
        echo "⚠️  Failed to scale down StatefulSet. Trying to delete pod as fallback..."
        # Fall through to pod deletion
      fi
    fi
  fi
  
  echo "🗑️  Deleting pod $pod to free PVC..."
  if kubectl delete pod "$pod" -n "$NS" --grace-period=30 2>/dev/null; then
    echo "✅ Pod $pod deleted successfully"
    return 0
  else
    echo "❌ Failed to delete pod $pod"
    return 1
  fi
}

# Wait for PVC to be unmounted (all pods using it to terminate)
wait_for_pvc_unmounted() {
  local PVC=$1
  local max_wait=${2:-300}  # Default 5 minutes
  local waited=0
  local interval=5
  
  echo "⏳ Waiting for PVC $PVC to be unmounted (max ${max_wait}s)..."
  while [ $waited -lt $max_wait ]; do
    if ! is_pvc_mounted "$PVC"; then
      echo "✅ PVC $PVC is now unmounted"
      return 0
    fi
    echo "  Still mounted... (waited ${waited}s, checking again in ${interval}s)"
    sleep $interval
    waited=$((waited + interval))
  done
  
  echo "⚠️ Timeout: PVC $PVC is still mounted after ${max_wait}s"
  return 1
}

# Get recursive setting for a path by index
get_path_recursive() {
  local index=$1
  echo "${PATH_RECURSIVE[$index]:-true}"
}

# Build tar command based on recursive flag for a specific path
build_tar_command() {
  local path=$1
  local path_index=$2
  local recursive=$(get_path_recursive "$path_index")
  local dir_path=$(dirname "$path")
  local base_name=$(basename "$path")
  
  if [[ "$recursive" == "true" ]]; then
    # Recursive: include subdirectories
    echo "tar -cz -C \"$dir_path\" \"$base_name\""
  else
    # Non-recursive: only files in the directory, not subdirectories
    # Use find to get only files and pipe to tar
    echo "cd \"$dir_path\" && find \"$base_name\" -maxdepth 1 -type f | tar -cz -T -"
  fi
}

# --- Try extracting directly from the restarting pod ---
extract_via_exec() {
  # Check if pod exists first
  local pod_state=$(get_state "$POD")
  if [[ "$pod_state" == "NotFound" ]]; then
    echo "⚠️  Pod $POD does not exist. Skipping direct extraction, will use PVC method."
    return 1
  fi
  
  echo "🔍 Attempting live extraction from $POD (container: $CONTAINER)..."
  echo "   Paths:"
  for i in "${!PATHS[@]}"; do
    local path="${PATHS[$i]}"
    local recursive=$(get_path_recursive "$i")
    echo "     - $path ($([ "$recursive" == "true" ] && echo "recursive" || echo "non-recursive"))"
  done
  
  # Try multiple times as pod might be restarting
  for i in {1..20}; do
    pod_state=$(get_state "$POD")
    [[ "$pod_state" == "Running" ]] || { sleep 0.5; continue; }
    
    # Try to extract each path
    local extracted_any=false
    local temp_files=()
    
    for path_index in "${!PATHS[@]}"; do
      local path="${PATHS[$path_index]}"
      # Check if path exists in container
      if kubectl exec -n "$NS" "$POD" -c "$CONTAINER" -- sh -c "[ -e '$path' ]" 2>/dev/null; then
        local temp_file="/tmp/extract-$(basename "$path")-$$.tar.gz"
        temp_files+=("$temp_file")
        
        local tar_cmd=$(build_tar_command "$path" "$path_index")
        if kubectl exec -n "$NS" "$POD" -c "$CONTAINER" -- sh -c "$tar_cmd" > "$temp_file" 2>/dev/null; then
          if [[ -s "$temp_file" ]]; then
            extracted_any=true
            echo "  ✅ Extracted: $path"
          fi
        fi
      else
        echo "  ⚠️  Path does not exist: $path"
      fi
    done
    
    # If we extracted at least one path, combine them into final archive
    if [[ "$extracted_any" == true ]]; then
      # Extract all tar files and combine into one archive
      local extract_dir="/tmp/extract-$$"
      mkdir -p "$extract_dir"
      
      for tf in "${temp_files[@]}"; do
        if [[ -s "$tf" ]]; then
          # Extract each tar file into the combined directory
          # Use --strip-components=0 to preserve directory structure
          tar -xzf "$tf" -C "$extract_dir" 2>/dev/null || true
        fi
      done
      
      # Create final combined archive
      if tar -czf "$OUTFILE" -C "$extract_dir" . 2>/dev/null; then
        if [[ -s "$OUTFILE" ]]; then
          echo "✅ Files saved to $OUTFILE"
          rm -rf "$extract_dir"
          rm -f "${temp_files[@]}" 2>/dev/null || true
          return 0
        fi
      fi
      
      # Cleanup on failure
      rm -rf "$extract_dir"
      rm -f "${temp_files[@]}" 2>/dev/null || true
    fi
    
    sleep 0.5
  done
  
  return 1
}

# --- PVC fallback extraction ---
extract_via_temp_pod() {
  local PVC=$1
  echo "📦 Using temporary pod with PVC: $PVC"
  echo "   Paths:"
  for i in "${!PATHS[@]}"; do
    local path="${PATHS[$i]}"
    local recursive=$(get_path_recursive "$i")
    echo "     - $path ($([ "$recursive" == "true" ] && echo "recursive" || echo "non-recursive"))"
  done
  
  TMPPOD="file-extractor-$(date +%s)"
  kubectl run "$TMPPOD" -n "$NS" --image=busybox --restart=Never \
    --overrides="{\"spec\":{\"volumes\":[{\"name\":\"data\",\"persistentVolumeClaim\":{\"claimName\":\"$PVC\"}}],\"containers\":[{\"name\":\"extractor\",\"image\":\"busybox\",\"command\":[\"sleep\",\"3600\"],\"volumeMounts\":[{\"name\":\"data\",\"mountPath\":\"/mnt\"}]}]}}" >/dev/null
  
  # Wait for pod to be running
  for _ in {1..30}; do
    [[ "$(get_state "$TMPPOD")" == "Running" ]] && break
    sleep 1
  done
  
  # Try to find the mounted paths and extract
  local extracted_any=false
  local temp_files=()
  
  for path_index in "${!PATHS[@]}"; do
    local path="${PATHS[$path_index]}"
    # Try common mount point variations
    local found_path=""
    for mount_base in /mnt /mnt/artifactory /mnt/var; do
      local test_path="${mount_base}${path}"
      if kubectl exec -n "$NS" "$TMPPOD" -- sh -c "[ -e '$test_path' ]" 2>/dev/null; then
        found_path="$test_path"
        break
      fi
    done
    
    # If not found with mount base, try the path as-is (might be absolute in PVC)
    if [[ -z "$found_path" ]]; then
      # Try the path directly (relative to /mnt)
      local rel_path="${path#/}"  # Remove leading slash
      if kubectl exec -n "$NS" "$TMPPOD" -- sh -c "[ -e \"/mnt/$rel_path\" ]" 2>/dev/null; then
        found_path="/mnt/$rel_path"
      fi
    fi
    
    if [[ -n "$found_path" ]]; then
      local temp_file="/tmp/extract-$(basename "$path")-$$.tar.gz"
      temp_files+=("$temp_file")
      
      local dir_path=$(dirname "$found_path")
      local base_name=$(basename "$found_path")
      
      # Get recursive setting for this specific path
      local recursive=$(get_path_recursive "$path_index")
      local tar_cmd
      if [[ "$recursive" == "true" ]]; then
        tar_cmd="tar -cz -C \"$dir_path\" \"$base_name\""
      else
        # Non-recursive: only files in the directory, not subdirectories
        tar_cmd="cd \"$dir_path\" && find \"$base_name\" -maxdepth 1 -type f | tar -cz -T -"
      fi
      
      if kubectl exec -n "$NS" "$TMPPOD" -- sh -c "$tar_cmd" > "$temp_file" 2>/dev/null; then
        if [[ -s "$temp_file" ]]; then
          extracted_any=true
          echo "  ✅ Extracted: $path (found at $found_path)"
        fi
      fi
    else
      echo "  ⚠️  Path not found in PVC: $path"
    fi
  done
  
  kubectl delete pod "$TMPPOD" -n "$NS" --ignore-not-found >/dev/null
  
  # Combine extracted files if any were found
  if [[ "$extracted_any" == true ]]; then
    local extract_dir="/tmp/extract-$$"
    mkdir -p "$extract_dir"
    for tf in "${temp_files[@]}"; do
      if [[ -s "$tf" ]]; then
        tar -xzf "$tf" -C "$extract_dir" 2>/dev/null || true
      fi
    done
    tar -czf "$OUTFILE" -C "$extract_dir" . 2>/dev/null
    rm -rf "$extract_dir"
    rm -f "${temp_files[@]}" 2>/dev/null || true
    
    if [[ -s "$OUTFILE" ]]; then
      echo "✅ Files saved from PVC to $OUTFILE"
      return 0
    fi
  fi
  
  return 1
}

# --- Main logic ---
echo "Extracting files from $POD (container: $CONTAINER) in namespace $NS..."
if extract_via_exec; then
  echo "To extract: tar -xzf $OUTFILE"
  exit 0
fi

# Fallback to PVC
PVC=$(get_pvc)
if [ -z "$PVC" ]; then
  echo "❌ Could not detect PVC from pod $POD"
  echo "   Pod may not exist. Please specify PVC directly or ensure pod exists."
  echo "   You can also try: kubectl get pvc -n $NS | grep $POD"
  exit 1
fi

ACCESS=$(get_pvc_access_mode "$PVC")
echo "Detected PVC: $PVC (AccessMode: ${ACCESS:-unknown})"

if [[ "$ACCESS" =~ ^(ReadWriteOnce|RWO)$ ]] && is_pvc_mounted "$PVC"; then
  echo "⚠️ PVC is ReadWriteOnce and currently mounted by another pod."
  
  # Check if --terminate-pod flag is set and pod is in CrashLoopBackOff
  if [[ "$TERMINATE_POD" == true ]]; then
    echo "🔍 --terminate-pod flag is set. Looking for pods to terminate..."
    
    # Find which pod is using the PVC
    pods_using_pvc=$(kubectl get pods -n "$NS" -o jsonpath="{.items[?(@.spec.volumes[*].persistentVolumeClaim.claimName=='$PVC')].metadata.name}" 2>/dev/null)
    
    if [[ -z "$pods_using_pvc" ]]; then
      echo "⚠️  No pods found using PVC $PVC"
    else
      echo "Found pods using PVC: $pods_using_pvc"
    fi
    
    pod_deleted=false
    for p in $pods_using_pvc; do
      pod_state=$(get_state "$p")
      waiting_reason=$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
      restart_count=$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
      container_ready=$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
      echo "  Checking pod $p: state=$pod_state, waiting_reason=$waiting_reason, restart_count=$restart_count, ready=$container_ready"
      
      if is_pod_crashlooping "$p"; then
        echo "✅ Pod $p is in CrashLoopBackOff or has been restarting (restart_count=$restart_count). Terminating..."
        if terminate_pod "$p"; then
          pod_deleted=true
          echo "Waiting for pod to be fully terminated and PVC to be unmounted..."
          # Wait a bit for the pod to be deleted
          sleep 5
        else
          echo "⚠️ Could not delete pod $p, will wait for it to terminate naturally..."
        fi
      else
        echo "  Pod $p is not in CrashLoopBackOff (state: $pod_state, waiting_reason: $waiting_reason, restart_count: $restart_count)"
        # If pod is blocking and --terminate-pod is set, delete it anyway if it's not running properly
        # Also delete if container is not ready (might be in a bad state even if phase is Running)
        if [[ "$pod_state" != "Running" ]] || [[ -n "$waiting_reason" ]] || [[ "$container_ready" != "true" ]]; then
          echo "  Pod $p appears to be in a problematic state. Terminating anyway..."
          if terminate_pod "$p"; then
            pod_deleted=true
            echo "Waiting for pod to be fully terminated and PVC to be unmounted..."
            sleep 5
          fi
        fi
      fi
    done
    
    # Also check if the pod we're extracting from is blocking the PVC
    if [[ "$pod_deleted" == false ]]; then
      pod_state=$(get_state "$POD")
      waiting_reason=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
      restart_count=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
      container_ready=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
      echo "Checking the pod we're extracting from ($POD): state=$pod_state, waiting_reason=$waiting_reason, restart_count=$restart_count, ready=$container_ready"
      
      if is_pod_crashlooping "$POD"; then
        echo "✅ The pod we're extracting from ($POD) is in CrashLoopBackOff or has been restarting (restart_count=$restart_count) and blocking the PVC."
        if terminate_pod "$POD"; then
          pod_deleted=true
          echo "Waiting for pod to be fully terminated and PVC to be unmounted..."
          sleep 5
        fi
      elif [[ "$pod_state" != "Running" ]] || [[ -n "$waiting_reason" ]] || [[ "$container_ready" != "true" ]]; then
        echo "The pod we're extracting from ($POD) appears problematic (state: $pod_state, ready: $container_ready). Terminating..."
        if terminate_pod "$POD"; then
          pod_deleted=true
          echo "Waiting for pod to be fully terminated and PVC to be unmounted..."
          sleep 5
        fi
      fi
    fi
    
    if [[ "$pod_deleted" == false ]]; then
      echo "⚠️  No pods were terminated. They may not be in CrashLoopBackOff state, or deletion failed."
    fi
    
    # Wait for PVC to be unmounted (with timeout)
    # For StatefulSets, we need to wait a bit longer for the scale-down to complete
    max_wait=60
    if wait_for_pvc_unmounted "$PVC" $max_wait; then
      echo "Proceeding with temporary pod extraction..."
    else
      echo "❌ Timeout waiting for PVC to be unmounted after ${max_wait}s."
      echo "⚠️  For StatefulSet-managed pods, the StatefulSet may have been scaled down."
      echo "   Attempting to create temporary pod anyway (may fail if PVC is still mounted)..."
      # Continue anyway - sometimes we can still create the temp pod
    fi
  else
    echo "Waiting for the crashing pod to terminate before creating temporary pod..."
    echo "💡 Tip: Use --terminate-pod flag to automatically delete CrashLoopBackOff pods"
    
    # Wait for PVC to be unmounted (with timeout)
    if wait_for_pvc_unmounted "$PVC" 300; then
      echo "Proceeding with temporary pod extraction..."
    else
      echo "❌ Timeout waiting for PVC to be unmounted. Cannot safely create temporary pod."
      echo "Tip: Use --terminate-pod flag to automatically delete the crashing pod, or manually wait for the pod to terminate, then retry this script."
      exit 1
    fi
  fi
fi

# Extract files
extract_via_temp_pod "$PVC" || {
  echo "❌ Failed to extract files from PVC $PVC"
  # Try to restore StatefulSet even if extraction failed
  if [[ -n "$SCALED_DOWN_STS" ]]; then
    echo "Attempting to restore StatefulSet $SCALED_DOWN_STS..."
    scale_up_statefulset "$SCALED_DOWN_STS"
  fi
  exit 1
}

# Restore StatefulSet if we scaled it down
if [[ -n "$SCALED_DOWN_STS" ]]; then
  echo "Restoring StatefulSet $SCALED_DOWN_STS..."
  scale_up_statefulset "$SCALED_DOWN_STS"
fi

echo "To extract: tar -xzf $OUTFILE"

