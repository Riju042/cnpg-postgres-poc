#!/usr/bin/env bash
# =============================================================================
# CNPG Restore from Backup Script
# =============================================================================
# Restores a CNPG PostgreSQL cluster from an S3 barman backup.
# Creates a new cluster that bootstraps from the specified backup.
#
# Usage:
#   ./scripts/restore-from-backup.sh [BACKUP_NAME] [TARGET_TIME]
#
# Examples:
#   # Restore from a specific backup
#   ./scripts/restore-from-backup.sh production-pg-daily-backup-20260101020000
#
#   # Point-in-time recovery to a specific timestamp
#   ./scripts/restore-from-backup.sh production-pg-daily-backup-20260101020000 "2026-01-01 12:00:00"
#
#   # Interactive mode (no arguments)
#   ./scripts/restore-from-backup.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SOURCE_CLUSTER="${SOURCE_CLUSTER:-production-pg}"
SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-postgres}"
RESTORE_NAMESPACE="${RESTORE_NAMESPACE:-postgres-restore}"
S3_DESTINATION="${S3_DESTINATION:-s3://my-cnpg-backups/production-pg/}"
RESTORE_CLUSTER_NAME="restored-pg"

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
log_info "=== CNPG Restore from Backup ==="
log_info "Source cluster:     ${SOURCE_CLUSTER}"
log_info "Source namespace:   ${SOURCE_NAMESPACE}"
log_info "Restore namespace:  ${RESTORE_NAMESPACE}"
echo

# ---------------------------------------------------------------------------
# Step 1: List available backups
# ---------------------------------------------------------------------------
log_info "Step 1: Listing available backups..."

BACKUPS=$(kubectl get backups -n "${SOURCE_NAMESPACE}" \
    -l "cnpg.io/cluster=${SOURCE_CLUSTER}" \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,START:.status.beginWal,STOP:.status.endWal,STARTED:.status.startedAt,COMPLETED:.status.stoppedAt' \
    --no-headers 2>/dev/null || echo "")

if [[ -z "${BACKUPS}" ]]; then
    log_warn "No backups found for cluster '${SOURCE_CLUSTER}' in namespace '${SOURCE_NAMESPACE}'."
    log_info "Will attempt recovery from the S3 object store directly."
else
    echo "${BACKUPS}" | while read -r line; do
        log_info "  ${line}"
    done
fi

echo

# ---------------------------------------------------------------------------
# Step 2: Determine backup to restore from
# ---------------------------------------------------------------------------
BACKUP_NAME="${1:-}"
TARGET_TIME="${2:-}"

if [[ -z "${BACKUP_NAME}" ]]; then
    log_info "No backup name specified. Using the latest available backup from S3."
    RECOVERY_SOURCE="objectStore"
else
    log_info "Restoring from backup: ${BACKUP_NAME}"
    RECOVERY_SOURCE="backup"
fi

if [[ -n "${TARGET_TIME}" ]]; then
    log_info "Point-in-time recovery target: ${TARGET_TIME}"
fi

echo

# ---------------------------------------------------------------------------
# Step 3: Create restore namespace
# ---------------------------------------------------------------------------
log_info "Step 2: Ensuring restore namespace exists..."
kubectl create namespace "${RESTORE_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
log_ok "Namespace '${RESTORE_NAMESPACE}' ready."

# ---------------------------------------------------------------------------
# Step 4: Copy S3 credentials to restore namespace
# ---------------------------------------------------------------------------
log_info "Step 3: Copying S3 credentials to restore namespace..."

if kubectl get secret cnpg-s3-creds -n "${SOURCE_NAMESPACE}" &>/dev/null; then
    kubectl get secret cnpg-s3-creds -n "${SOURCE_NAMESPACE}" -o json \
        | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp)' \
        | kubectl apply -n "${RESTORE_NAMESPACE}" -f -
    log_ok "S3 credentials copied."
else
    log_error "Secret 'cnpg-s3-creds' not found in '${SOURCE_NAMESPACE}'. Create it before proceeding."
    exit 1
fi

echo

# ---------------------------------------------------------------------------
# Step 5: Generate and apply the restore cluster manifest
# ---------------------------------------------------------------------------
log_info "Step 4: Generating restore cluster manifest..."

PITR_SECTION=""
if [[ -n "${TARGET_TIME}" ]]; then
    PITR_SECTION="
      recoveryTarget:
        targetTime: \"${TARGET_TIME}\""
fi

cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${RESTORE_CLUSTER_NAME}
  namespace: ${RESTORE_NAMESPACE}
  labels:
    app: ${RESTORE_CLUSTER_NAME}
    environment: restore
    source-cluster: ${SOURCE_CLUSTER}
spec:
  description: "Restored from ${SOURCE_CLUSTER} backup"
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4-12
  instances: 1

  bootstrap:
    recovery:
      source: ${SOURCE_CLUSTER}${PITR_SECTION}

  externalClusters:
    - name: ${SOURCE_CLUSTER}
      barmanObjectStore:
        destinationPath: "${S3_DESTINATION}"
        s3Credentials:
          accessKeyId:
            name: cnpg-s3-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: cnpg-s3-creds
            key: SECRET_ACCESS_KEY
          region:
            name: cnpg-s3-creds
            key: REGION
        wal:
          maxParallel: 4

  storage:
    size: 50Gi
    storageClass: gp3-enc

  resources:
    requests:
      cpu: "1"
      memory: 2Gi
    limits:
      cpu: "2"
      memory: 4Gi
EOF

log_ok "Restore cluster manifest applied."
echo

# ---------------------------------------------------------------------------
# Step 6: Monitor restore progress
# ---------------------------------------------------------------------------
log_info "Step 5: Monitoring restore progress..."

RESTORE_TIMEOUT=600
RESTORE_START=$(date +%s)
RESTORE_ELAPSED=0

while [[ ${RESTORE_ELAPSED} -lt ${RESTORE_TIMEOUT} ]]; do
    sleep 10
    RESTORE_ELAPSED=$(( $(date +%s) - RESTORE_START ))

    CLUSTER_PHASE=$(kubectl get cluster "${RESTORE_CLUSTER_NAME}" -n "${RESTORE_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    READY_INSTANCES=$(kubectl get cluster "${RESTORE_CLUSTER_NAME}" -n "${RESTORE_NAMESPACE}" \
        -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")

    log_info "  Phase: ${CLUSTER_PHASE}, Ready: ${READY_INSTANCES}/1 (${RESTORE_ELAPSED}s elapsed)"

    if [[ "${CLUSTER_PHASE}" == "Cluster in healthy state" && "${READY_INSTANCES}" -ge 1 ]]; then
        log_ok "Restore completed successfully!"
        break
    fi

    if [[ "${CLUSTER_PHASE}" == *"error"* || "${CLUSTER_PHASE}" == *"fail"* ]]; then
        log_error "Restore failed. Cluster phase: ${CLUSTER_PHASE}"
        log_error "Check events:"
        kubectl get events -n "${RESTORE_NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
        exit 1
    fi
done

if [[ ${RESTORE_ELAPSED} -ge ${RESTORE_TIMEOUT} ]]; then
    log_warn "Restore did not complete within ${RESTORE_TIMEOUT}s. It may still be in progress."
    log_info "Monitor with: kubectl get cluster ${RESTORE_CLUSTER_NAME} -n ${RESTORE_NAMESPACE} -w"
fi

echo

# ---------------------------------------------------------------------------
# Step 7: Print connection information
# ---------------------------------------------------------------------------
log_info "=========================================="
log_info "        Restore Summary"
log_info "=========================================="
log_info "Restored cluster:  ${RESTORE_CLUSTER_NAME}"
log_info "Namespace:         ${RESTORE_NAMESPACE}"

RW_SERVICE="${RESTORE_CLUSTER_NAME}-rw.${RESTORE_NAMESPACE}.svc"
log_info "Connection (RW):   postgresql://appuser@${RW_SERVICE}:5432/appdb"

echo
log_info "To connect via port-forward:"
log_info "  kubectl port-forward -n ${RESTORE_NAMESPACE} svc/${RESTORE_CLUSTER_NAME}-rw 5432:5432"
log_info "  psql -h localhost -U appuser -d appdb"

echo
log_info "To verify data integrity, connect and run your validation queries."
log_info "Once verified, you can scale up replicas:"
log_info "  kubectl patch cluster ${RESTORE_CLUSTER_NAME} -n ${RESTORE_NAMESPACE} --type merge -p '{\"spec\":{\"instances\":3}}'"

echo
log_info "To clean up the restore cluster when done:"
log_info "  kubectl delete cluster ${RESTORE_CLUSTER_NAME} -n ${RESTORE_NAMESPACE}"
log_info "  kubectl delete namespace ${RESTORE_NAMESPACE}"
