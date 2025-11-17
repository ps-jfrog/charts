

## 🧾 Artifactory Log Extraction – CrashLoopBackOff Pod (`jpd-prod-artifactory-2`)

### 📘 Overview

During the upgrade of an Artifactory cluster with multiple replicas (for example, 3 pods: `jpd-prod-artifactory-0`, `1`, and `2`), the upgrade proceeds **in reverse order**.

If the first pod in the upgrade sequence — **`jpd-prod-artifactory-2`** — becomes stuck in a `CrashLoopBackOff` state, it blocks the remaining replicas (`1` and `0`) from upgrading.

This guide provides a **safe and automated method** to extract the Artifactory logs from that crashing pod for troubleshooting.

---

## ⚙️ What This Script Does

The script:

1. Detects that the pod is stuck in a `CrashLoopBackOff` or restart loop.
2. Identifies the **StatefulSet** managing the pod (`jpd-prod-artifactory`).
3. **Scales down** that StatefulSet temporarily to safely detach the pod’s **ReadWriteOnce PVC**.
4. Mounts the PVC to a **temporary BusyBox pod** and extracts all logs.
5. **Scales the StatefulSet back up** to restore normal operation.

✅ **No data loss**
✅ **No manual PVC handling required**
✅ **Fully automated cleanup and recovery**

---

## 🧰 Prerequisites

Before running the script:

* You have `kubectl` installed and configured with cluster access.
* You can run commands in the same namespace as Artifactory (`jfrog-prod` in this case).
* The crashing pod’s name is `jpd-prod-artifactory-2`.
* Your user has permission to:

  * Scale StatefulSets
  * Delete pods
  * Create temporary pods

---

## 📥 Step 1: Download the Script

Save the provided script as:

```bash
extract-artifactory-logs-safe.sh
```

Make it executable:

```bash
chmod +x extract-artifactory-logs-safe.sh
```

---

## 🚀 Step 2: Run the Script

Run the following command to collect logs from the crashing pod:

```bash
./extract-artifactory-logs-safe.sh \
  --namespace jfrog-prod \
  --pod jpd-prod-artifactory-2 \
  --output-dir ./logs \
  --terminate-pod
```

### Explanation of parameters:

| Flag              | Description                                                      |
| ----------------- | ---------------------------------------------------------------- |
| `--namespace`     | Kubernetes namespace where Artifactory is running                |
| `--pod`           | Name of the crashing pod (in this case `jpd-prod-artifactory-2`) |
| `--output-dir`    | Directory to save the collected logs                             |
| `--terminate-pod` | Safely scales down or deletes the crashing pod to free its PVC   |

---

## 🧾 Step 3: Wait for the Process to Complete

During execution, you’ll see output similar to:

```
Extracting Artifactory logs from jpd-prod-artifactory-2 in namespace jfrog-prod...
⚠️ Pod jpd-prod-artifactory-2 is managed by StatefulSet jpd-prod-artifactory.
📉 Scaling down StatefulSet jpd-prod-artifactory from 3 to 0 replicas...
✅ StatefulSet jpd-prod-artifactory scaled down successfully
✅ PVC artifactory-volume-jpd-prod-artifactory-2 is now unmounted
📦 Using temporary pod with PVC: artifactory-volume-jpd-prod-artifactory-2
✅ Logs saved from PVC to ./logs/jpd-prod-artifactory-2-logs-20251116-143015.tar.gz
📈 Scaling up StatefulSet jpd-prod-artifactory back to 3 replicas...
✅ StatefulSet jpd-prod-artifactory scaled up successfully
```

This indicates:

* The crashing pod’s PVC was safely detached.
* Logs were collected successfully.
* The StatefulSet was restored to its original size.

---

## 📂 Step 4: Retrieve the Logs

The script saves logs in a compressed file under your output directory:

```bash
./logs/jpd-prod-artifactory-2-logs-<timestamp>.tar.gz
```

To extract the logs locally:

```bash
tar -xzf ./logs/jpd-prod-artifactory-2-logs-<timestamp>.tar.gz -C ./logs/
```

You should now see contents similar to:

```
logs/
  ├── artifactory-service.log
  ├── artifactory-bootstrap.log
  ├── access.log
  └── request.log
```

---

## 🧹 Step 5: Cleanup

The script automatically:

* Deletes the temporary BusyBox pod created for log extraction.
* Restores the StatefulSet to its previous replica count.
* Removes any temporary state-tracking files under `/tmp/`.

If you re-run the script, it will detect and re-create only what’s necessary.

---

## ⚠️ Notes & Best Practices

* Always run this script **from outside** the Artifactory pods (for example, from an admin node or jump host).
* Do **not** manually scale or delete the StatefulSet while the script runs.
* Safe for production — it only manipulates pod replicas and temporary resources.
* If extraction fails, re-run the script with the same parameters. It will automatically clean up and retry from a clean state.

---

## 🔧 Troubleshooting

### 1. PVC Remains Mounted

If the script reports:

```
❌ Timeout waiting for PVC to be unmounted. Cannot safely create temporary pod.
```

**What it means:**
The crashing pod’s PVC (`ReadWriteOnce`) is still attached to a running or terminating pod.

**What to do:**

1. Run:

   ```bash
   kubectl get pods -n jfrog-prod -o wide | grep artifactory-2
   ```
2. Check if the pod is still in `Terminating` or `CrashLoopBackOff`.
3. Wait a few minutes for Kubernetes to detach the volume, or manually force delete the pod:

   ```bash
   kubectl delete pod jpd-prod-artifactory-2 -n jfrog-prod --grace-period=0 --force
   ```
4. Once the PVC is free, rerun the script with the same parameters.

---

### 2. Temporary Pod Fails to Start

If you see:

```
Error: cannot mount volume... already in use
```

It means the PVC was still mounted when the temp pod was created.
Wait a few more seconds, delete the temporary pod (if present), and rerun:

```bash
kubectl delete pod -n jfrog-prod -l run=log-extractor
./extract-artifactory-logs-safe.sh --namespace jfrog-prod --pod jpd-prod-artifactory-2 --output-dir ./logs --terminate-pod
```

---

### 3. StatefulSet Does Not Scale Back Up

If the final messages show:

```
⚠️ Failed to scale up StatefulSet jpd-prod-artifactory.
Please scale it manually.
```

Run this command manually to restore the replica count:

```bash
kubectl scale statefulset jpd-prod-artifactory -n jfrog-prod --replicas=3
```

Verify pods:

```bash
kubectl get pods -n jfrog-prod -l app=artifactory
```

Once the pods are running again, the upgrade can resume normally.

---

### 4. No Logs Found in PVC

If the tarball is empty:

1. Verify you selected the correct pod name (`jpd-prod-artifactory-2`).
2. Re-run the script with `--output-dir` pointing to a writable local path.
3. If still empty, run:

   ```bash
   kubectl exec -n jfrog-prod <temp-pod-name> -- find /mnt -type f -name "*.log"
   ```

   to manually inspect log locations inside the PVC.

---

### 5. Network / Permission Errors

If you get authentication or RBAC errors:

* Ensure your user has permissions for:

  * `pods`, `pods/exec`, `pods/delete`
  * `statefulsets/scale`
  * `persistentvolumeclaims`
* Run as a cluster admin if unsure:

  ```bash
  kubectl auth can-i delete pod --namespace jfrog-prod
  kubectl auth can-i create pod --namespace jfrog-prod
  ```

---

## ✅ Expected Outcome

After running the script:

* Logs from `jpd-prod-artifactory-2` are saved locally for analysis.
* The pod’s PVC is safely detached and remounted only for reading.
* The `jpd-prod-artifactory` StatefulSet is restored to its previous state.
* Remaining pods (`artifactory-1`, `artifactory-0`) can continue the upgrade sequence.

---

## 🧩 Where Cleanup Happens in the Script

In the script you provided:

* Temporary pods created for extraction are **deleted automatically** at the end of:

  ```bash
  kubectl delete pod "$TMPPOD" -n "$NS" --ignore-not-found >/dev/null
  ```
* Scaled-down StatefulSets are **restored** by:

  ```bash
  scale_up_statefulset "$SCALED_DOWN_STS"
  ```
* Temporary replica-tracking files are cleaned up:

  ```bash
  rm -f "/tmp/sts-${sts}-replicas-$$.txt"
  ```

So, when you re-run the script:

* Any leftover temporary pod is deleted before reuse (`--ignore-not-found` ensures idempotence).
* Any previous scaling action is automatically reverted.
* It always operates from a clean state, even after partial failures.


