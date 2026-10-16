# CNPG PostgreSQL Operator POC on EKS

End-to-end **CloudNativePG** (CNPG) deployment on Amazon EKS with automated S3 backups, gp3 PVC provisioning, Prometheus monitoring, Grafana dashboards, and production-hardened network policies.

---

## Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │               Amazon EKS Cluster            │
                         │                                             │
  ┌──────────┐           │  ┌───────────────────────────────────────┐  │
  │  Grafana  │◄──────────┼──│  Prometheus (kube-prometheus-stack)   │  │
  └──────────┘           │  │  - PodMonitor scrapes :9187            │  │
                         │  │  - PrometheusRule alert rules          │  │
                         │  └──────────────┬────────────────────────┘  │
                         │                 │ scrape                    │
                         │                 ▼                           │
                         │  ┌──────────────────────────────────────┐   │
                         │  │        CNPG Operator (cnpg-system)   │   │
                         │  │        - Manages Cluster CRDs        │   │
                         │  │        - Handles failover             │   │
                         │  │        - Orchestrates backups         │   │
                         │  └──────────────┬───────────────────────┘   │
                         │                 │ manages                   │
                         │                 ▼                           │
                         │  ┌──────────────────────────────────────┐   │
                         │  │        postgres namespace             │   │
                         │  │                                      │   │
  ┌──────────┐           │  │  ┌─────────┐  ┌─────────┐  ┌──────┐ │   │
  │   App    │──────5432──┼──│  │ Primary │  │Replica 1│  │Rep. 2│ │   │
  │  Pods    │           │  │  │  (RW)   │─▶│  (RO)   │─▶│ (RO) │ │   │
  └──────────┘           │  │  └────┬────┘  └─────────┘  └──────┘ │   │
                         │  │       │                              │   │
                         │  │  ┌────▼────┐                         │   │
                         │  │  │ gp3 PVC │  50Gi per instance      │   │
                         │  │  │ (EBS)   │  + 10Gi WAL storage     │   │
                         │  │  └────┬────┘                         │   │
                         │  └───────┼──────────────────────────────┘   │
                         │          │                                   │
                         └──────────┼───────────────────────────────────┘
                                    │ WAL archiving + base backups
                                    ▼
                         ┌─────────────────────┐
                         │   Amazon S3 Bucket   │
                         │  (cnpg-backups)      │
                         │  - Daily backups     │
                         │  - Weekly full       │
                         │  - 30d retention     │
                         └─────────────────────┘
```

## Repository Structure

```
cnpg-postgres-poc/
├── operator/
│   └── install.yaml              # Helm values for CNPG operator
├── clusters/
│   ├── production-cluster.yaml   # 3-instance HA cluster (1 primary + 2 replicas)
│   └── dev-cluster.yaml          # Single-instance dev cluster
├── backups/
│   ├── scheduled-backup.yaml     # Daily + weekly scheduled backups to S3
│   └── backup-on-demand.yaml     # On-demand backup template
├── monitoring/
│   ├── grafana-dashboard.json    # Grafana dashboard (connections, replication, WAL, storage)
│   ├── servicemonitor.yaml       # Prometheus PodMonitor for CNPG instances
│   └── alerts.yaml               # PrometheusRule: replication lag, connections, storage, backups
├── networking/
│   └── networkpolicy.yaml        # Ingress/egress network policies for PostgreSQL pods
├── scripts/
│   ├── test-failover.sh          # Automated failover test (delete primary, verify promotion)
│   └── restore-from-backup.sh    # Restore cluster from S3 backup with optional PITR
├── LICENSE
└── README.md
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| **AWS EKS** | 1.28+ | Kubernetes cluster |
| **kubectl** | 1.28+ | Cluster management |
| **Helm** | 3.12+ | CNPG operator installation |
| **aws CLI** | 2.x | S3 bucket and IAM setup |
| **kubectl-cnpg** | 1.25+ | CNPG CLI plugin (optional but recommended) |

### EKS Cluster Requirements

- At least 3 nodes spread across 3 availability zones (for production HA)
- EBS CSI driver installed with a `gp3-enc` StorageClass
- VPC CNI configured for pod networking

### StorageClass Setup

Create a gp3 encrypted StorageClass if one does not already exist:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-enc
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  fsType: ext4
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

### S3 Bucket and Credentials

```bash
# Create S3 bucket for backups
aws s3 mb s3://my-cnpg-backups --region us-east-1

# Create Kubernetes secret with S3 credentials
kubectl create namespace postgres

kubectl create secret generic cnpg-s3-creds \
  --namespace postgres \
  --from-literal=ACCESS_KEY_ID='<your-access-key>' \
  --from-literal=SECRET_ACCESS_KEY='<your-secret-key>' \
  --from-literal=REGION='us-east-1'
```

> **Note:** For production, use IRSA (IAM Roles for Service Accounts) instead of static credentials.

---

## Deployment Guide

### Step 1: Install the CNPG Operator

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  -f operator/install.yaml

# Verify operator is running
kubectl get deployment -n cnpg-system cnpg-controller-manager
kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=120s
```

### Step 2: Create Namespaces and Secrets

```bash
# Production namespace
kubectl create namespace postgres

# Superuser secret
kubectl create secret generic production-pg-superuser \
  --namespace postgres \
  --from-literal=username=postgres \
  --from-literal=password="$(openssl rand -base64 32)"

# Readonly role password
kubectl create secret generic production-pg-readonly-password \
  --namespace postgres \
  --from-literal=username=readonly \
  --from-literal=password="$(openssl rand -base64 32)"

# Dev namespace (optional)
kubectl create namespace postgres-dev
kubectl create secret generic dev-pg-superuser \
  --namespace postgres-dev \
  --from-literal=username=postgres \
  --from-literal=password="$(openssl rand -base64 24)"
```

### Step 3: Deploy the Production Cluster

```bash
kubectl apply -f clusters/production-cluster.yaml

# Watch the cluster come up
kubectl get cluster production-pg -n postgres -w

# Detailed status (requires kubectl-cnpg plugin)
kubectl cnpg status production-pg -n postgres
```

Wait until all 3 instances report `Ready` and the cluster phase shows `Cluster in healthy state`.

### Step 4: Deploy the Dev Cluster (Optional)

```bash
kubectl apply -f clusters/dev-cluster.yaml
kubectl get cluster dev-pg -n postgres-dev -w
```

### Step 5: Set Up Automated Backups

```bash
kubectl apply -f backups/scheduled-backup.yaml

# Verify scheduled backups are registered
kubectl get scheduledbackups -n postgres
```

### Step 6: Apply Network Policies

```bash
# Label application namespaces for network policy access
kubectl label namespace <your-app-namespace> cnpg-access=true

kubectl apply -f networking/networkpolicy.yaml
```

### Step 7: Connect to PostgreSQL

```bash
# Port-forward to the primary (read-write) service
kubectl port-forward -n postgres svc/production-pg-rw 5432:5432 &

# Connect with psql
psql -h localhost -U appuser -d appdb

# Service DNS names for in-cluster applications:
#   Read-Write:  production-pg-rw.postgres.svc:5432
#   Read-Only:   production-pg-ro.postgres.svc:5432
#   Any replica:  production-pg-r.postgres.svc:5432
```

---

## Monitoring Setup

### Prerequisites

Install the kube-prometheus-stack (Prometheus + Grafana):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false
```

### Deploy Monitoring Resources

```bash
# PodMonitor for scraping CNPG metrics
kubectl apply -f monitoring/servicemonitor.yaml

# Alerting rules
kubectl apply -f monitoring/alerts.yaml
```

### Import Grafana Dashboard

1. Open Grafana (port-forward or Ingress)
2. Go to **Dashboards** > **Import**
3. Upload `monitoring/grafana-dashboard.json`
4. Select your Prometheus data source
5. Click **Import**

### Dashboard Panels

| Section | Panels |
|---------|--------|
| **Cluster Overview** | Instance status, max replication lag, active connections, database size, WAL archive failures, time since last archive |
| **Connections** | Total connections vs max, connections by state (active/idle/idle-in-txn), connection utilization gauge, longest running transaction |
| **Replication** | Replication lag over time, streaming status per replica |
| **WAL & Backups** | WAL storage size, WAL archiving rate (archived vs. failed) |
| **Storage & I/O** | Database size by instance, buffer writes (checkpoint vs. backend) |
| **Transactions** | Transaction rate (commits/rollbacks), row operations (returned/fetched/inserted/updated/deleted), buffer cache hit ratio |

### Alerts

| Alert | Severity | Condition |
|-------|----------|-----------|
| `CNPGReplicationLagHigh` | warning | Lag > 10s for 5m |
| `CNPGReplicationLagCritical` | critical | Lag > 30s for 2m |
| `CNPGReplicaNotStreaming` | critical | Replica stops streaming for 3m |
| `CNPGConnectionsHigh` | warning | Usage > 80% for 5m |
| `CNPGConnectionsCritical` | critical | Usage > 95% for 2m |
| `CNPGLongRunningQueries` | warning | Transaction > 5m |
| `CNPGStorageUsageHigh` | warning | Storage > 80% for 10m |
| `CNPGStorageUsageCritical` | critical | Storage > 90% for 5m |
| `CNPGWALStorageHigh` | warning | No WAL archive in 10m |
| `CNPGBackupFailed` | warning | WAL archiver failures detected |
| `CNPGLastBackupTooOld` | critical | No successful archive in 24h |
| `CNPGInstanceDown` | critical | Instance unreachable for 2m |

---

## Backup and Restore Procedures

### Trigger an On-Demand Backup

```bash
kubectl apply -f backups/backup-on-demand.yaml

# Monitor backup progress
kubectl get backup production-pg-on-demand -n postgres -w
```

### List All Backups

```bash
kubectl get backups -n postgres
# or with the CNPG plugin:
kubectl cnpg backup list production-pg -n postgres
```

### Restore from Backup

The restore script creates a new cluster that bootstraps from an S3 backup:

```bash
# Restore from the latest backup
./scripts/restore-from-backup.sh

# Restore from a specific backup
./scripts/restore-from-backup.sh production-pg-daily-backup-20260101020000

# Point-in-time recovery
./scripts/restore-from-backup.sh production-pg-daily-backup-20260101020000 "2026-01-01 12:00:00"
```

The restored cluster is created in a separate `postgres-restore` namespace. After validating data integrity, you can scale it up or promote it.

### Verify Backup Integrity

```bash
# Check the last successful archive time
kubectl get cluster production-pg -n postgres \
  -o jsonpath='{.status.lastSuccessfulBackup}'

# Check WAL archiver status
kubectl cnpg status production-pg -n postgres | grep -A5 "WAL archiving"
```

---

## Failover Testing

```bash
# Run the automated failover test
./scripts/test-failover.sh production-pg postgres
```

The script will:

1. Identify the current primary pod
2. Forcefully delete it
3. Monitor for automatic replica promotion
4. Wait for the cluster to return to a healthy state
5. Report failover duration and final cluster state

Expected failover time: **10-30 seconds** depending on cluster configuration and load.

### Manual Switchover

```bash
# Promote a specific replica to primary (graceful)
kubectl cnpg promote production-pg production-pg-2 -n postgres
```

---

## Production Considerations

- **IRSA:** Replace static S3 credentials with IAM Roles for Service Accounts
- **Encryption:** Enable at-rest encryption via `gp3-enc` StorageClass (included) and TLS for client connections
- **Connection Pooling:** Deploy PgBouncer via the CNPG `Pooler` CRD for high-concurrency workloads
- **Multi-AZ:** The production cluster uses pod anti-affinity across `topology.kubernetes.io/zone`
- **PDB:** CNPG automatically manages PodDisruptionBudgets for the cluster
- **Secrets Management:** Integrate with AWS Secrets Manager or HashiCorp Vault via External Secrets Operator

---

## Author

**Mayank Bhardvaj** -- Staff Software Engineer

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
