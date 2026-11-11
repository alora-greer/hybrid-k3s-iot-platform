# Backup & Restore

## What is backed up

| Source | Mechanism | S3 prefix | Frequency | Retention |
|---|---|---|---|---|
| K3s cluster state | K3s embedded-etcd snapshots (`etcd-s3`) | `k3s/` | every 6 h | K3s keeps the newest 20 (~5 days); pruned snapshots stay as noncurrent versions for 90 d |
| Home Assistant | HA native backups → S3 backup location | `home-assistant/` | daily | per HA setting; superseded or deleted objects stay as noncurrent versions for 90 d |
| Git repo | GitHub | — | every push | forever |

Everything in S3 is **SSE-KMS encrypted**, **versioned**, and only reachable
over TLS. Lifecycle defaults (`terraform/aws-backup/variables.tf`):

- Current objects move to Glacier Instant Retrieval after 30 days
  (`transition_to_glacier_days`) and expire after 365 days (`expiration_days`).
- Noncurrent versions expire after 90 days (`noncurrent_version_expiration_days`).
- With `etcd-snapshot-retention: 20` at a 6 h cadence, K3s prunes snapshots
  after ~5 days, long before the 30-day transition. In practice the Glacier IR
  transition only applies to Home Assistant backups; pruned K3s snapshots
  linger as noncurrent versions until the 90-day expiry.

### What is NOT backed up

etcd snapshots capture Kubernetes **objects** (including the SealedSecrets
key), not PersistentVolume **data**. Prometheus' TSDB and Grafana's database
(both `local-path` PVCs on the node) are not backed up. After a rebuild,
metrics history is gone, and any dashboards created in the Grafana UI are lost
unless they were provisioned from code (dashboards-as-code is on the roadmap).

## Threat model for the backup bucket

- Each source has its **own IAM user**, scoped to its own prefix.
- Writers can delete objects (so tools can prune), but **cannot delete object
  versions** or change bucket config — so a stolen key can't wipe history.
- Access keys are created out-of-band (`aws iam create-access-key`) so they
  never appear in Terraform state.

## Restore drills (do these quarterly)

### K3s

```bash
# List snapshots in S3
sudo k3s etcd-snapshot ls

# Restore (on the server)
sudo systemctl stop k3s
sudo k3s server --cluster-reset \
  --etcd-s3 --etcd-s3-bucket=<bucket> --etcd-s3-folder=k3s \
  --cluster-reset-restore-path=<snapshot-name>
sudo systemctl start k3s
```

> Restoring etcd restores the **SealedSecrets controller's private key** too
> (it lives in `kube-system`). If you rebuild the cluster from scratch instead,
> back up that key separately or re-seal every secret:
> `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`
> — store it in a password manager, **never** in git.

### Home Assistant

1. Flash a fresh Home Assistant OS image to the Pi.
2. During onboarding choose **Restore from backup** and pick the latest S3 backup.
3. Re-plug the Sonoff dongle in the same USB port; the Zigbee network key is
   part of the backup, so devices rejoin without re-pairing.

## RPO / RTO targets

| | RPO | RTO |
|---|---|---|
| K3s | 6 h | 30 min |
| Home Assistant | 24 h | 45 min |
