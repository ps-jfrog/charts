# Fix Distribution PostgreSQL Secret - Migration Script

## Purpose

This script fixes PostgreSQL secret key format migration issues when upgrading JFrog Distribution chart from version ≤102.30 to ≥102.31 with `distribution_use_internal_postgresql = true`.

## When to Use This Script

Use this script when you encounter one of the following issues after upgrading Distribution:

1. **Helm upgrade error (secret format)**:
   ```
   Error: execution error at (distribution/charts/postgresql/templates/secrets.yaml:26:16): 
   PASSWORDS ERROR: The secret "jpd-dist1-distribution-postgresql" does not contain the key "password"
   ```

2. **Helm upgrade error (StatefulSet immutable fields)**:
   ```
   Error: cannot patch "jpd-dist1-distribution-postgresql" with kind StatefulSet: 
   StatefulSet.apps "jpd-dist1-distribution-postgresql" is invalid: spec: Forbidden: 
   updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 
   'updateStrategy', 'revisionHistoryLimit', 'persistentVolumeClaimRetentionPolicy' 
   and 'minReadySeconds' are forbidden
   ```

3. **Distribution pod error** (password authentication failed):
   ```
   Caused by: org.springframework.beans.BeanInstantiationException: Failed to instantiate [javax.sql.DataSource]: 
   Factory method 'dataSource' threw exception with message: Failed to initialize pool: 
   FATAL: password authentication failed for user "distribution"
   ```

4. **Upgraded with blank password**: If you upgraded using the default `values.yaml` from the chart repository which has `password: ""`, Distribution cannot connect to PostgreSQL.

5. **PostgreSQL version incompatibility (CrashLoopBackOff)**:
   ```
   FATAL:  database files are incompatible with server
   DETAIL:  The data directory was initialized by PostgreSQL version 15, which is not compatible with this version 16.6.
   ```
   This occurs when upgrading Distribution chart from 102.29.1 (PostgreSQL 15) to 102.34.2 (PostgreSQL 16). PostgreSQL major versions are incompatible and require data migration. The default PostgreSQL version for Distribution chart 102.34.2 is 16.6.0-debian-12-r2 as per the [official values.yaml](https://github.com/jfrog/charts/blob/distribution/2.33.2/stable/distribution/values.yaml).

## Understanding the Issue

### Who Creates the Secrets?

**Important**: The PostgreSQL secrets are created by the **Bitnami PostgreSQL chart**, not the JFrog Distribution chart.

### How It Works

1. The JFrog Distribution chart includes **Bitnami PostgreSQL as a subchart/dependency**
2. When `postgresql.enabled = true` in your Distribution values, it deploys the Bitnami PostgreSQL subchart
3. The **Bitnami PostgreSQL chart** creates the secrets using its own format
4. The secret key format change is due to updates in the **Bitnami PostgreSQL chart** between versions, not the Distribution chart

### Secret Key Format Change

The Bitnami PostgreSQL chart changed its secret key format between versions:

- **Old format (Distribution chart ≤102.30, uses older Bitnami PostgreSQL)**:
  - Secret keys: `postgresql-password`, `postgresql-postgres-password`
  - Values format: `postgresql.postgresqlUsername`, `postgresql.postgresqlPassword`, `postgresql.postgresqlDatabase`

- **New format (Distribution chart ≥102.31, uses newer Bitnami PostgreSQL)**:
  - Secret keys: `password`, `postgres-password`
  - Values format: `postgresql.auth.username`, `postgresql.auth.password`, `postgresql.auth.database`

### Why the Error Occurs

When upgrading from Distribution chart 102.29.1 to 102.34.2:

1. The old secret exists with keys: `postgresql-password`, `postgresql-postgres-password`
2. The new Bitnami PostgreSQL chart expects keys: `password`, `postgres-password`
3. Helm upgrade fails because the secret doesn't have the expected keys
4. Even if the upgrade succeeds (by deleting the secret), if the password in `values.yaml` is blank or doesn't match the existing database password, Distribution cannot authenticate

## Prerequisites

- `kubectl` configured and authenticated
- Access to the namespace where Distribution is deployed
- The Distribution release name and namespace

## Usage

### Basic Usage

```bash
./fix-distribution-postgresql-secret.sh <release_name> <namespace>
```

### Example

For a deployment with `release_name = "jpd-dist1"` and `namespace = "jfrog-dist1"`:

```bash
./fix-distribution-postgresql-secret.sh jpd-dist1 jfrog-dist1
```

## What the Script Does

1. **Validates inputs**: Checks that namespace exists and secret exists
2. **Extracts password**: 
   - Tries to extract from old format (`postgresql-password`)
   - Falls back to new format (`password`) if already migrated
   - If password is blank, attempts to extract from PostgreSQL pod environment
   Note: If the PostgreSql password is not invalid in a Kubernetes Pod and we are unable to determine the correct password for PostgreSql for any postgresql pod we can follow these steps to reset back to the needed password using KB [POSTGESQL FOR HELM: Getting SQLSTATE 28P01 password authentication failed for user in PostgreSQL](https://jfrog.com/help/r/postgesql-for-helm-getting-sqlstate-28p01-password-authentication-failed-for-user-in-postgresql) (Ref 382641 ). 
3. **Deletes old secret**: Removes the secret with old key format
4. **Creates new secret**: Creates a new secret with correct format (`password`, `postgres-password`)
5. **Verifies migration**: Confirms the new secret has the correct password

## Step-by-Step Resolution Process

### Step 1: Run the Script

```bash
./fix-distribution-postgresql-secret.sh jpd-dist1 jfrog-dist1
```

The script will:
- Extract the existing password from the old secret format
- Delete the old secret
- Create a new secret with the correct format

### Step 1.5: Handle StatefulSet Immutable Fields (If Needed)

**If you encounter the StatefulSet immutable fields error**, you need to delete the PostgreSQL StatefulSet before proceeding. The StatefulSet will be recreated by Helm during the upgrade, and your data is safe in the PVCs.

**Parameters**:
- **StatefulSet name**: `${release_name}-distribution-postgresql` - The PostgreSQL StatefulSet created by the Bitnami PostgreSQL subchart
- **Namespace**: `${namespace}` - The Kubernetes namespace where Distribution is deployed

**Generic commands** (replace `${release_name}` and `${namespace}` with your values):

```bash
# Delete the PostgreSQL StatefulSet (pods will be deleted but PVCs remain)
kubectl delete statefulset ${release_name}-distribution-postgresql -n ${namespace}

# Verify the StatefulSet is deleted (pods will be terminating)
kubectl get pods -n ${namespace} | grep postgresql

# Wait for pods to be fully terminated
kubectl wait --for=delete pod -l app.kubernetes.io/name=postgresql -n ${namespace} --timeout=60s
```

**Example** (for `release_name = "jpd-dist1"` and `namespace = "jfrog-dist1"`):

```bash
# Delete the PostgreSQL StatefulSet (pods will be deleted but PVCs remain)
kubectl delete statefulset jpd-dist1-distribution-postgresql -n jfrog-dist1

# Verify the StatefulSet is deleted (pods will be terminating)
kubectl get pods -n jfrog-dist1 | grep postgresql

# Wait for pods to be fully terminated
kubectl wait --for=delete pod -l app.kubernetes.io/name=postgresql -n jfrog-dist1 --timeout=60s
```

**Important**: 
- The PVCs (PersistentVolumeClaims) are **NOT deleted** - your database data is safe
- The StatefulSet will be recreated by Helm during the upgrade with the new configuration
- This causes temporary downtime for PostgreSQL (typically 1-2 minutes)

### Step 2: Update Your Values File

**Note**: If you encountered the StatefulSet error, complete Step 1.5 first, then proceed with this step.

**CRITICAL**: After running the script, you must update your custom values file used by your Distribution chart  ( `values-distribution_102_31_and_newer.yaml` in my test)  to match the password that was extracted.

According to [JFrog's documentation on auto-generated passwords for internal PostgreSQL](https://jfrog.com/help/r/jfrog-installation-setup-documentation/auto-generated-passwords-internal-postgresql), you need to set the password in your values file.

**Example** ( from my custom `values-distribution_102_31_and_newer.yaml`):

```yaml
## ref: https://github.com/bitnami/charts/blob/master/bitnami/postgresql/README.md
postgresql:
  enabled: true
  # Pin PostgreSQL version to 15 to maintain compatibility with existing data
  # When upgrading from Distribution chart 102.29.1 (PostgreSQL 15) to 102.34.2 (PostgreSQL 16),
  # the data directory is incompatible. PostgreSQL 15 to 16 is a major version upgrade requiring migration.
  # Pinning to 15 avoids data migration. To upgrade to 16 later, perform a proper major version upgrade.
  # Reference: https://github.com/jfrog/charts/blob/distribution/2.33.2/stable/distribution/values.yaml
  image:
    registry: releases-docker.jfrog.io
    repository: bitnami/postgresql
    tag: 15.6.0-debian-11-r16
  auth:
    username: "distribution"
    password: "distribution"  # Must match the password extracted by the fix-distribution-postgresql-secret.sh script
    database: "distribution"
```

**Important**: The password in your values file **must match**:
1. The password that was in your old secret (extracted by the script)
2. The password currently set in your PostgreSQL database

If you're unsure what password was extracted, the script will display it, or you can check it:

```bash
# Get the password from the new secret
kubectl get secret jpd-dist1-distribution-postgresql -n jfrog-dist1 \
  -o jsonpath="{.data.password}" | base64 -d
```

### Step 3: Rerun Helm Upgrade (via Terraform , or helm or ArgoCD )

After updating the values file, rerun the Helm upgrade:

```bash
terraform apply -var-file="terraform.tfvars"
```

Or if using Helm directly:

```bash
helm upgrade jpd-dist1-distribution jfrog/distribution \
  --version 102.34.2 \
  --namespace jfrog-dist1 \
  -f values-distribution_102_31_and_newer.yaml
```

### Step 4: Verify Distribution Pod

After the upgrade completes, check that Distribution can connect to PostgreSQL:

```bash
# Check Distribution pod logs
kubectl logs -n jfrog-dist1 -l app=distribution -c distribution --tail=50

# Check pod status
kubectl get pods -n jfrog-dist1
```

The password authentication error should be resolved.

## Why Rerunning Helm Upgrade is Necessary

After creating the secret with the new format and updating the values file:

1. **Secret format is correct**: The new secret has keys `password` and `postgres-password` that the new Bitnami PostgreSQL chart expects
2. **Values file matches database**: The password in `postgresql.auth.password` matches the actual database password
3. **Helm upgrade applies changes**: Rerunning the upgrade ensures:
   - The Bitnami PostgreSQL chart reads the new secret format correctly
   - Distribution uses the correct password from the values file to connect to PostgreSQL
   - All resources are in sync with the new configuration

**Note**: The Helm upgrade will not recreate the secret (it already exists with the correct format), but it will ensure Distribution uses the correct password configuration.

## Troubleshooting

### Script Cannot Extract Password

If the script cannot extract the password:

1. **Check if PostgreSQL pod exists**:
   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/name=postgresql
   ```

2. **Manually extract from pod**:
   ```bash
   POSTGRES_POD=$(kubectl get pods -n <namespace> -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n <namespace> $POSTGRES_POD -- env | grep POSTGRES_PASSWORD
   ```

3. **Manually create the secret**:
   ```bash
   kubectl create secret generic jpd-dist1-distribution-postgresql \
     --from-literal=password="<your-password>" \
     --from-literal=postgres-password="<your-password>" \
     -n jfrog-dist1
   ```

### Password Still Doesn't Work After Upgrade

If you still see password authentication errors:

1. **Verify secret has correct format**:
   ```bash
   kubectl get secret jpd-dist1-distribution-postgresql -n jfrog-dist1 -o yaml
   ```
   Should show keys: `password` and `postgres-password` (not `postgresql-password`)

2. **Verify values file password matches**:
   ```bash
   # Check what's in the secret
   kubectl get secret jpd-dist1-distribution-postgresql -n jfrog-dist1 \
     -o jsonpath="{.data.password}" | base64 -d
   
   # Compare with your values file
   cat values-distribution_102_31_and_newer.yaml | grep -A 3 "auth:"
   ```

3. **Check PostgreSQL database password**:
   ```bash
   # Connect to PostgreSQL and verify the password
   kubectl run postgresql-client --rm -it --restart='Never' \
     --namespace jfrog-dist1 \
     --image releases-docker.jfrog.io/bitnami/postgresql:15.6.0-debian-11-r16 \
     --env="PGPASSWORD=<password-from-secret>" \
     --command -- psql --host jpd-dist1-distribution-postgresql -U distribution -d distribution
   ```

4. **Restart Distribution pod** (if needed):
   ```bash
   kubectl delete pod -n jfrog-dist1 -l app=distribution
   ```

### PostgreSQL Version Incompatibility (CrashLoopBackOff)

**Symptom**: PostgreSQL pod is in `CrashLoopBackOff` with error:
```
FATAL:  database files are incompatible with server
DETAIL:  The data directory was initialized by PostgreSQL version 15, which is not compatible with this version 16.6.
```

**Root Cause**: When upgrading Distribution chart from 102.29.1 to 102.34.2, the Bitnami PostgreSQL subchart also upgraded from PostgreSQL 15 to PostgreSQL 16. PostgreSQL major versions are incompatible - you cannot mount a data directory from one major version to another without migration. The default PostgreSQL version for Distribution chart 102.34.2 is 16.6.0-debian-12-r2 as per the [official values.yaml](https://github.com/jfrog/charts/blob/distribution/2.33.2/stable/distribution/values.yaml).

**Solution**: Pin the PostgreSQL image version to 15.6.0-debian-11-r16 in your values file to maintain compatibility with existing data (created with PostgreSQL 15). This avoids the need for data migration.

**Step 1: Delete the PostgreSQL StatefulSet** (if it exists and is in Error/CrashLoopBackOff state):

```bash
# Delete the StatefulSet (pods will be deleted but PVCs remain)
kubectl delete statefulset jpd-dist1-distribution-postgresql -n jfrog-dist1

# Wait for pods to be fully terminated
kubectl wait --for=delete pod -l app.kubernetes.io/name=postgresql -n jfrog-dist1 --timeout=60s
```

**Step 2: Update your custom values (`values-distribution_102_31_and_newer.yaml` in my test)**:

```yaml
postgresql:
  enabled: true
  # Pin PostgreSQL version to 15 to maintain compatibility with existing data
  # When upgrading from Distribution chart 102.29.1 (PostgreSQL 15) to 102.34.2 (PostgreSQL 16),
  # the data directory is incompatible. PostgreSQL 15 to 16 is a major version upgrade requiring migration.
  # Pinning to 15 avoids data migration. To upgrade to 16 later, perform a proper major version upgrade.
  # Reference: https://github.com/jfrog/charts/blob/distribution/2.33.2/stable/distribution/values.yaml
  image:
    registry: releases-docker.jfrog.io
    repository: bitnami/postgresql
    tag: 15.6.0-debian-11-r16
  auth:
    username: "distribution"
    password: "distribution"
    database: "distribution"
```

**Step 3: Rerun Terraform apply**:

```bash
terraform apply -var-file="terraform.tfvars"
```

The StatefulSet will be recreated with PostgreSQL 15, which is compatible with your existing data directory. The pod should start successfully.

**Alternative (if you want to upgrade to PostgreSQL 16)**: If you need to upgrade from PostgreSQL 15 to 16, you must perform a proper major version upgrade:
1. Backup your database
2. Dump the data from PostgreSQL 15
3. Delete the existing PVC (or use a new one)
4. Update the values file to use PostgreSQL 16.6.0-debian-12-r2
5. Restore the data to PostgreSQL 16

**Note**: 
- **Recommended**: Pinning to PostgreSQL 15 avoids data migration and maintains compatibility with existing data
- **Alternative**: Pinning to PostgreSQL 16 matches the official chart default but requires data migration if upgrading from 15
- Choose based on your requirements: avoid migration (use 15) or match chart default (use 16, requires migration)

## Safety Notes

- **Safe to run**: The script only affects Kubernetes secrets (passwords), not the PostgreSQL data
- **Data preserved**: Your PostgreSQL data is stored in PersistentVolumeClaims (PVCs), not in secrets
- **No data loss**: Deleting and recreating the secret does not affect your database data
- **Reversible**: If something goes wrong, you can manually recreate the secret with the old format

## Related Documentation

- [JFrog Distribution Chart Documentation](https://github.com/jfrog/charts/tree/master/stable/distribution)
- [Bitnami PostgreSQL Chart Documentation](https://github.com/bitnami/charts/tree/main/bitnami/postgresql)
- [JFrog: Auto-Generated Passwords for Internal PostgreSQL](https://jfrog.com/help/r/jfrog-installation-setup-documentation/auto-generated-passwords-internal-postgresql)

## Support

If you continue to experience issues after following this guide:

1. Check Distribution pod logs: `kubectl logs -n <namespace> -l app=distribution -c distribution`
2. Check PostgreSQL pod logs: `kubectl logs -n <namespace> -l app.kubernetes.io/name=postgresql`
3. Verify secret format: `kubectl get secret <secret-name> -n <namespace> -o yaml`
4. Verify values file configuration matches the secret password

