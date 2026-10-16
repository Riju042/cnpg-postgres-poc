#!/usr/bin/env bash
# =============================================================================
# CNPG Failover Test Script
# =============================================================================
# Tests automated failover by deleting the primary pod and verifying that a
# replica is promoted to primary within the expected timeframe.
#
# Usage:
#   ./scripts/test-failover.sh [CLUSTER_NAME] [NAMESPACE]
#
# Defaults:
#   CLUSTER_NAME = production-pg
#   NAMESPACE    = postgres
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME="${1:-production-pg}"
NAMESPACE="${2:-postgres}"
FAILOVER_TIMEOUT=120  # seconds to wait for failover
POLL_INTERVAL=5       # seconds between status checks

# ---------------------------------------------------------------------------
# Colors & helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
log_info "=== CNPG Failover Test ==="
log_info "Cluster:   ${CLUSTER_NAME}"
log_info "Namespace: ${NAMESPACE}"
echo

# Verify kubectl access
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    log_error "Namespace '${NAMESPACE}' not found. Aborting."
    exit 1
fi

# Verify cluster exists
if ! kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    log_error "CNPG Cluster '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}'. Aborting."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Capture current cluster state
# ---------------------------------------------------------------------------
log_info "Step 1: Capturing current cluster state..."

CURRENT_PRIMARY=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.currentPrimary}')

if [[ -z "${CURRENT_PRIMARY}" ]]; then
    log_error "Could not determine current primary pod. Aborting."
    exit 1
fi

INSTANCE_COUNT=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.instances}')
READY_INSTANCES=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyInstances}')

log_info "Current primary:   ${CURRENT_PRIMARY}"
log_info "Total instances:   ${INSTANCE_COUNT}"
log_info "Ready instances:   ${READY_INSTANCES}"

if [[ "${READY_INSTANCES}" -lt 2 ]]; then
    log_error "Need at least 2 ready instances for failover test. Found: ${READY_INSTANCES}"
    exit 1
fi

# List all pods and their roles
log_info "Current pod roles:"
kubectl get pods -n "${NAMESPACE}" \
    -l "cnpg.io/cluster=${CLUSTER_NAME}" \
    -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.role,STATUS:.status.phase,NODE:.spec.nodeName' \
    --no-headers | while read -r line; do
    log_info "  ${line}"
done

echo

# ---------------------------------------------------------------------------
# Step 2: Delete the primary pod
# ---------------------------------------------------------------------------
log_warn "Step 2: Deleting primary pod '${CURRENT_PRIMARY}'..."
log_warn "This will trigger an automatic failover."
echo

FAILOVER_START=$(date +%s)

kubectl delete pod "${CURRENT_PRIMARY}" -n "${NAMESPACE}" --grace-period=0 --force 2>/dev/null || \
    kubectl delete pod "${CURRENT_PRIMARY}" -n "${NAMESPACE}"

log_info "Primary pod deleted at $(date '+%H:%M:%S')"
echo

# ---------------------------------------------------------------------------
# Step 3: Wait for failover — new primary promotion
# ---------------------------------------------------------------------------
log_info "Step 3: Waiting for new primary to be promoted (timeout: ${FAILOVER_TIMEOUT}s)..."

ELAPSED=0
NEW_PRIMARY=""

while [[ ${ELAPSED} -lt ${FAILOVER_TIMEOUT} ]]; do
    sleep "${POLL_INTERVAL}"
    ELAPSED=$(( $(date +%s) - FAILOVER_START ))

    NEW_PRIMARY=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo "")

    CLUSTER_PHASE=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")

    if [[ -n "${NEW_PRIMARY}" && "${NEW_PRIMARY}" != "${CURRENT_PRIMARY}" ]]; then
        FAILOVER_DURATION=${ELAPSED}
        log_ok "New primary detected: ${NEW_PRIMARY} (after ${FAILOVER_DURATION}s)"
        break
    fi

    log_info "  Waiting... (${ELAPSED}s elapsed, cluster phase: ${CLUSTER_PHASE})"
done

if [[ -z "${NEW_PRIMARY}" || "${NEW_PRIMARY}" == "${CURRENT_PRIMARY}" ]]; then
    log_error "Failover did not complete within ${FAILOVER_TIMEOUT}s. Investigation required."
    log_error "Current cluster status:"
    kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" -o yaml | grep -A 20 'status:'
    exit 1
fi

echo

# ---------------------------------------------------------------------------
# Step 4: Wait for cluster to become fully healthy
# ---------------------------------------------------------------------------
log_info "Step 4: Waiting for cluster to return to healthy state..."

HEALTH_TIMEOUT=180
HEALTH_START=$(date +%s)
HEALTH_ELAPSED=0

while [[ ${HEALTH_ELAPSED} -lt ${HEALTH_TIMEOUT} ]]; do
    sleep "${POLL_INTERVAL}"
    HEALTH_ELAPSED=$(( $(date +%s) - HEALTH_START ))

    CURRENT_READY=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")

    if [[ "${CURRENT_READY}" -eq "${INSTANCE_COUNT}" ]]; then
        log_ok "All ${INSTANCE_COUNT} instances are ready (recovered in ${HEALTH_ELAPSED}s)"
        break
    fi

    log_info "  Ready: ${CURRENT_READY}/${INSTANCE_COUNT} (${HEALTH_ELAPSED}s elapsed)"
done

if [[ "${CURRENT_READY}" -ne "${INSTANCE_COUNT}" ]]; then
    log_warn "Cluster did not fully recover within ${HEALTH_TIMEOUT}s."
    log_warn "Ready: ${CURRENT_READY}/${INSTANCE_COUNT}"
fi

echo

# ---------------------------------------------------------------------------
# Step 5: Verify new cluster state
# ---------------------------------------------------------------------------
log_info "Step 5: Verifying final cluster state..."

FINAL_PRIMARY=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.currentPrimary}')
FINAL_READY=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyInstances}')
FINAL_PHASE=$(kubectl get cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}')

log_info "Final pod roles:"
kubectl get pods -n "${NAMESPACE}" \
    -l "cnpg.io/cluster=${CLUSTER_NAME}" \
    -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.role,STATUS:.status.phase,NODE:.spec.nodeName' \
    --no-headers | while read -r line; do
    log_info "  ${line}"
done

echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_info "=========================================="
log_info "          Failover Test Summary"
log_info "=========================================="
log_info "Old primary:        ${CURRENT_PRIMARY}"
log_info "New primary:        ${FINAL_PRIMARY}"
log_info "Failover duration:  ${FAILOVER_DURATION:-N/A}s"
log_info "Cluster phase:      ${FINAL_PHASE}"
log_info "Ready instances:    ${FINAL_READY}/${INSTANCE_COUNT}"

if [[ "${FINAL_PRIMARY}" != "${CURRENT_PRIMARY}" && "${FINAL_READY}" -eq "${INSTANCE_COUNT}" ]]; then
    echo
    log_ok "=== FAILOVER TEST PASSED ==="
    exit 0
elif [[ "${FINAL_PRIMARY}" != "${CURRENT_PRIMARY}" ]]; then
    echo
    log_warn "=== FAILOVER SUCCEEDED but cluster not fully recovered ==="
    exit 0
else
    echo
    log_error "=== FAILOVER TEST FAILED ==="
    exit 1
fi
