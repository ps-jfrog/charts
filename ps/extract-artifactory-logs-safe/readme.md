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
* The crashing pod’s should be provided (`jpd-prod-artifactory-2`in this case).
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
  --namespace <namespace> \
  --pod <pod-name> \
  [--output-dir <dir>] \
  [--terminate-pod]
```
Example:
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

Send this `jpd-prod-artifactory-2-logs-<timestamp>.tar.gz` file to Jfrog PS team.

---

## 🧹 Step 5: Cleanup 

The script automatically:

* Deletes the temporary BusyBox pod used for extraction.
* Scales the StatefulSet back up to its previous replica count.

No further cleanup is required.

---

## ⚠️ Notes & Best Practices

* Always run this script **from outside** the Artifactory pods (for example, from an admin node or jump host).
* Do **not** modify the StatefulSet manually during extraction.
* The process is safe for production environments — it will not modify Artifactory data.
* If extraction fails, re-run the script with the same parameters. It will clean up any previous temporary resources automatically.

---

## 🆘 Also create JFrog Support ticket and upload the logs (optional follow-up)

Please Create a JFrog Support ticket for this.
Once you have the ticket number  upload the `./logs/jpd-prod-artifactory-2-logs-<timestamp>.tar.gz` to your ticket as:
```bash

curl -i -T  ./logs/jpd-prod-artifactory-2-logs-<timestamp>.tar.gz "https://supportlogs.jfrog.com/logs/<TICKET_NUMBER>/"

```
For example if the JFrog Support ticket number you created is `12345` you can run:
```bash

curl -i -T  ./logs/jpd-prod-artifactory-2-logs-<timestamp>.tar.gz "https://supportlogs.jfrog.com/logs/12345/"

```

---

## ✅ Expected Outcome

After running the script:

* Logs from `jpd-prod-artifactory-2` are available for analysis.
* The upgrade process for pods `jpd-prod-artifactory-1` and `0` can proceed normally.
* Cluster state and data integrity are preserved.

---

Would you like me to include a **“Troubleshooting”** section at the bottom (covering what to do if PVCs remain mounted or StatefulSet scale-up fails)? It’s helpful for customers using cloud-managed Kubernetes (like EKS or AKS).
