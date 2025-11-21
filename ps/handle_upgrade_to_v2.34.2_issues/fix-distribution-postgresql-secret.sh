#!/bin/bash

###############################################################################
# Script: fix-distribution-postgresql-secret.sh
#
# Purpose: Fix PostgreSQL secret key format migration when upgrading Distribution
#          chart from version <=102.30 to >=102.31, or recover from blank password
#          issue during upgrade.
#
# Description:
#   When upgrading Distribution chart from <=102.30 to >=102.31, the PostgreSQL
#   subchart changed its secret key format:
#   - Old format (<=102.30): postgresql-password, postgresql-postgres-password
#   - New format (>=102.31): password, postgres-password
#
#   This script:
#   1. Extracts the password from the existing secret (old or new format)
#   2. Deletes the existing secret
#   3. Creates a new secret with the correct format for the new chart version
#   4. Handles the case where password might be blank (extracts from existing secret)
#
# Usage:
#   ./scripts/fix-distribution-postgresql-secret.sh <release_name> <namespace>
#
# Example:
#   ./scripts/fix-distribution-postgresql-secret.sh jpd-dist1 jfrog-dist1
#
# Prerequisites:
#   - kubectl configured and authenticated
#   - Access to the namespace where Distribution is deployed
#   - The secret name format: ${release_name}-distribution-postgresql
#
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required arguments are provided
if [ $# -lt 2 ]; then
    print_error "Usage: $0 <release_name> <namespace>"
    echo ""
    echo "Example:"
    echo "  $0 jpd-dist1 jfrog-dist1"
    echo ""
    echo "This script fixes PostgreSQL secret key format migration when upgrading"
    echo "Distribution chart from version <=102.30 to >=102.31."
    exit 1
fi

RELEASE_NAME="$1"
NAMESPACE="$2"
SECRET_NAME="${RELEASE_NAME}-distribution-postgresql"

print_info "Fixing PostgreSQL secret for Distribution upgrade"
print_info "Release name: ${RELEASE_NAME}"
print_info "Namespace: ${NAMESPACE}"
print_info "Secret name: ${SECRET_NAME}"
echo ""

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    print_error "Namespace '${NAMESPACE}' does not exist"
    exit 1
fi

# Check if secret exists
if ! kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    print_warn "Secret '${SECRET_NAME}' does not exist in namespace '${NAMESPACE}'"
    print_info "The secret will be created by Helm during the next upgrade/apply"
    exit 0
fi

print_info "Found existing secret: ${SECRET_NAME}"

# Try to extract password from old format (postgresql-password)
OLD_PASSWORD=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgresql-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

# Try to extract password from new format (password)
if [ -z "$OLD_PASSWORD" ]; then
    OLD_PASSWORD=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi

# Try to extract postgres admin password (for reference)
OLD_POSTGRES_PASSWORD=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgresql-postgres-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -z "$OLD_POSTGRES_PASSWORD" ]; then
    OLD_POSTGRES_PASSWORD=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi

# Check if password is blank or empty
if [ -z "$OLD_PASSWORD" ]; then
    print_error "Password is blank or could not be extracted from secret"
    print_error "This usually happens when upgrading with default values.yaml that has empty password"
    print_warn "Attempting to extract password from PostgreSQL pod environment..."
    
    # Try to get password from PostgreSQL pod environment
    POSTGRES_POD=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance="${RELEASE_NAME}-distribution" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$POSTGRES_POD" ]; then
        print_info "Found PostgreSQL pod: ${POSTGRES_POD}"
        OLD_PASSWORD=$(kubectl exec -n "${NAMESPACE}" "${POSTGRES_POD}" -- env | grep POSTGRES_PASSWORD | cut -d'=' -f2 || echo "")
        
        if [ -z "$OLD_PASSWORD" ]; then
            print_error "Could not extract password from PostgreSQL pod"
            print_error "You may need to manually set the password"
            print_info "You can connect to the PostgreSQL pod and check the password:"
            echo "  kubectl exec -it -n ${NAMESPACE} ${POSTGRES_POD} -- env | grep POSTGRES"
            exit 1
        else
            print_info "Successfully extracted password from PostgreSQL pod"
        fi
    else
        print_error "PostgreSQL pod not found. Cannot extract password automatically."
        print_error "Please manually specify the password or check your deployment."
        exit 1
    fi
fi

print_info "Extracted distribution user password (length: ${#OLD_PASSWORD} characters)"
if [ -n "$OLD_POSTGRES_PASSWORD" ]; then
    print_info "Extracted postgres admin password (length: ${#OLD_POSTGRES_PASSWORD} characters)"
fi

# Confirm before proceeding
echo ""
print_warn "This will delete the existing secret and create a new one with the correct format."
print_warn "The PostgreSQL data will NOT be affected (stored in PVC)."
read -p "Continue? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Aborted by user"
    exit 0
fi

# Delete the old secret
print_info "Deleting old secret: ${SECRET_NAME}"
kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}" || {
    print_error "Failed to delete secret"
    exit 1
}

# Wait a moment for secret deletion to complete
sleep 2

# Create new secret with correct format for new chart version (>=102.31)
print_info "Creating new secret with correct format..."

# Create secret with new format keys
kubectl create secret generic "${SECRET_NAME}" \
    --from-literal=password="${OLD_PASSWORD}" \
    --from-literal=postgres-password="${OLD_POSTGRES_PASSWORD:-${OLD_PASSWORD}}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

print_info "Successfully created new secret with correct format"
echo ""

# Verify the secret
print_info "Verifying new secret..."
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    NEW_PASSWORD=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)
    if [ "$NEW_PASSWORD" = "$OLD_PASSWORD" ]; then
        print_info "✓ Secret verified successfully"
        print_info "✓ Password matches original password"
    else
        print_warn "Password mismatch detected. Please verify manually."
    fi
else
    print_error "Failed to verify secret"
    exit 1
fi

echo ""
print_info "Secret migration completed successfully!"
print_info "You can now proceed with the Distribution upgrade:"
echo "  terraform apply -var-file=\"terraform.tfvars\""
echo ""
print_info "The new secret format is compatible with Distribution chart version >=102.31"

