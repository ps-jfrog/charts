#!/bin/bash
# Extract Artifactory logs from a CrashLoopBackOff pod or its PVC (safe for RWO)
# Usage: 
#   ./extract-artifactory-logs-safe.sh <namespace> <pod-name> [output-dir]
#   ./extract-artifactory-logs-safe.sh --namespace <namespace> --pod <pod-name> [--output-dir <dir>] [--terminate-pod]

set -euo pipefail

# Default values
NS=""
POD=""
OUTDIR="./"
TERMINATE_POD=false
SCALED_DOWN_STS=""  # Track which StatefulSet was scaled down

# Parse arguments
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [OPTIONS]"
  echo "  --namespace <namespace>     Kubernetes namespace (required)"
  echo "  --pod <pod-name>            Pod name (required)"
  echo "  --output-dir <dir>         Output directory (default: ./)"
  echo "  --terminate-pod             Delete CrashLoopBackOff pod to free PVC (optional)"
  echo ""
  echo "Legacy usage (positional args):"
  echo "  $0 <namespace> <pod-name> [output-dir]"
  exit 1
fi

# Check if using new flag-based syntax or legacy positional
if [[ "$1" == "--namespace" ]] || [[ "$1" == "--pod" ]] || [[ "$1" == "--output-dir" ]] || [[ "$1" == "--terminate-pod" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
  # New flag-based syntax
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
        echo "  --output-dir <dir>         Output directory (default: ./)"
        echo "  --terminate-pod             Delete CrashLoopBackOff pod to free PVC (optional)"
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
  done
else
  # Legacy positional syntax
  NS=$1
  POD=$2
  OUTDIR=${3:-./}
fi

# Validate required arguments
if [[ -z "$NS" ]] || [[ -z "$POD" ]]; then
  echo "Error: --namespace and --pod are required"
  exit 1
fi

OUTFILE="${OUTDIR}/${POD}-logs-$(date +%Y%m%d-%H%M%S).tar.gz"
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

# --- Try extracting directly from the restarting pod ---
extract_via_exec() {
  local paths=(
    "/opt/jfrog/artifactory/var/log"
  )
  
  # Check if pod exists first
  local pod_state=$(get_state "$POD")
  if [[ "$pod_state" == "NotFound" ]]; then
    echo "⚠️  Pod $POD does not exist. Skipping direct extraction, will use PVC method."
    return 1
  fi
  
  echo "🔍 Attempting live extraction from $POD..."
  for i in {1..20}; do
    pod_state=$(get_state "$POD")
    [[ "$pod_state" == "Running" ]] || { sleep 0.5; continue; }
    for p in "${paths[@]}"; do
      if kubectl exec -n "$NS" "$POD" -c artifactory -- sh -c "tar -cz -C $(dirname "$p") $(basename "$p")" > "$OUTFILE" 2>/dev/null; then
        [ -s "$OUTFILE" ] && { echo "✅ Logs saved to $OUTFILE"; return 0; }
      fi
    done
    sleep 0.5
  done
  return 1
}

# --- PVC fallback extraction ---
extract_via_temp_pod() {
  local PVC=$1
  echo "📦 Using temporary pod with PVC: $PVC"
  TMPPOD="log-extractor-$(date +%s)"
  kubectl run "$TMPPOD" -n "$NS" --image=busybox --restart=Never \
    --overrides="{\"spec\":{\"volumes\":[{\"name\":\"data\",\"persistentVolumeClaim\":{\"claimName\":\"$PVC\"}}],\"containers\":[{\"name\":\"extractor\",\"image\":\"busybox\",\"command\":[\"sleep\",\"3600\"],\"volumeMounts\":[{\"name\":\"data\",\"mountPath\":\"/mnt\"}]}]}}" >/dev/null
  for _ in {1..30}; do
    [[ "$(get_state "$TMPPOD")" == "Running" ]] && break
    sleep 1
  done
  for p in /mnt/var/log /mnt/artifactory/var/log /mnt/log; do
    kubectl exec -n "$NS" "$TMPPOD" -- sh -c "[ -d '$p' ] && tar -cz -C $(dirname "$p") $(basename "$p")" > "$OUTFILE" 2>/dev/null && break
  done
  kubectl delete pod "$TMPPOD" -n "$NS" --ignore-not-found >/dev/null
  [ -s "$OUTFILE" ] && { echo "✅ Logs saved from PVC to $OUTFILE"; return 0; }
  return 1
}

# --- Main logic ---
echo "Extracting Artifactory logs from $POD in namespace $NS..."
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

# Extract logs
extract_via_temp_pod "$PVC" || {
  echo "❌ Failed to extract logs from PVC $PVC"
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
