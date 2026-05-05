# Mgmt Cluster — Operations Runbook

Day-2 operational reference for the mgmt RKE2 cluster. Covers cluster
access, etcd snapshots (Qumulo S3), restore procedures, and the verification
commands you'll reach for at 2am when something looks off.

For the initial bootstrap procedure see `bootstrap.md`. For network/CIDR
design see `cidr-plan.md`. For Kemp VIP topology see `kemp-vip-design.md`.

## Cluster overview

| Property | Value |
|---|---|
| Cluster name | mgmt |
| Node count | 5 (all servers / control-plane) |
| Etcd quorum | 3 of 5 — tolerates 2 simultaneous failures |
| Pod CIDR | 192.168.0.0/20 |
| Service CIDR | 192.168.16.0/20 |
| Per-node pod /25 mask | 128 pods/node, 32-node ceiling |
| Underlay MTU | 9000 (VM network, ens224) |
| Pod MTU | 8950 (VXLAN encap overhead = 50) |
| CNI | Cilium 1.19 (VXLAN, kubeProxyReplacement, Gateway API) |
| Kubernetes version | v1.35.4+rke2r1 (pinned) |
| API VIP | `vkub-mgmt.ufhpc` (172.16.192.6) — Kemp L4 passthrough |
| Supervisor port | 9345 (TCP) |
| API port | 6443 (TCP) |

| Node | Mgmt IP (ens192) | VM IP (ens224) |
|---|---|---|
| kub-mgmt1 | 172.16.192.1 | 10.13.160.1 |
| kub-mgmt2 | 172.16.192.2 | 10.13.160.2 |
| kub-mgmt3 | 172.16.192.3 | 10.13.160.3 |
| kub-mgmt4 | 172.16.192.4 | 10.13.160.4 |
| kub-mgmt5 | 172.16.192.5 | 10.13.160.5 |

## Cluster access (kubectl)

### From a control-plane node directly

```bash
sudo cp /etc/rancher/rke2/rke2.yaml ~/rke2.yaml
sudo chown $USER ~/rke2.yaml
chmod 0600 ~/rke2.yaml
export KUBECONFIG=~/rke2.yaml
export PATH=/var/lib/rancher/rke2/bin:$PATH

kubectl get nodes
```

The default kubeconfig points at `https://127.0.0.1:6443` — fine for
on-node use; that's how the apiserver listens locally.

### From a workstation (off-cluster)

Copy the kubeconfig and rewrite the server URL to use the Kemp VIP:

```bash
scp kub-mgmt1.ufhpc:/etc/rancher/rke2/rke2.yaml ./mgmt-kubeconfig.yaml
sed -i 's|server: https://127.0.0.1:6443|server: https://vkub-mgmt.ufhpc:6443|' ./mgmt-kubeconfig.yaml
chmod 0600 ./mgmt-kubeconfig.yaml
export KUBECONFIG=$(pwd)/mgmt-kubeconfig.yaml
kubectl get nodes
```

The cluster cert's `tls-san` already includes `vkub-mgmt.ufhpc`, the VIP IP,
and per-node FQDNs (both `kub-mgmtN.ufhpc` and `kub-mgmtN-vm.ufhpc` variants),
so cert validation works no matter which name you use.

The kubeconfig grants `cluster-admin` — treat the file like the root
password equivalent. Don't paste it. Don't commit it. Rotate via Rancher
RBAC (once installed) or by regenerating `/etc/rancher/rke2/rke2.yaml` on
the cluster.

## Etcd snapshots

### Where snapshots live

| Location | Path / URL | Retention |
|---|---|---|
| Local (each server) | `/var/lib/rancher/rke2/server/db/snapshots/` | 28 |
| Remote (Qumulo S3) | `s3://kub-mgmt-etcd/<filename>` | 28 (per server) |

S3 endpoint: `qumulo-data.ufhpc:9000`. TLS is currently configured with
`etcd-s3-skip-ssl-verify: true` (Qumulo cert not in system trust). To switch
to proper validation, install the Qumulo CA cert and reference it via
`etcd-s3-endpoint-ca`.

S3 credentials are stored as Foreman host parameters (smart class param
`ufrc_rke2::config` keys `etcd-s3-access-key` and `etcd-s3-secret-key`) —
the same accepted-risk posture as the cluster join token. **Rotate the
access key before production.**

### Schedule

Cron: `0 */6 * * *` (every 6 hours: 00:00, 06:00, 12:00, 18:00 UTC)

Each of the 5 servers takes its own snapshot at every tick. Every snapshot
is a complete, self-sufficient backup of the cluster state — they're
identical content, just distinct filenames.

At steady state: 5 servers × 28 retention = 140 snapshots in S3, ~1 GB total.

### Take a manual snapshot

```bash
# On any server node
sudo /usr/local/bin/rke2 etcd-snapshot save --name=<descriptive-name>

# Example:
sudo /usr/local/bin/rke2 etcd-snapshot save --name=pre-rancher-install
```

The snapshot lands in both `/var/lib/rancher/rke2/server/db/snapshots/`
and S3. Filename includes the node name and timestamp.

The "Unknown flag" warnings during `etcd-snapshot save/list` are noise —
the etcd-snapshot subcommand only knows about etcd-related flags and warns
about all the server-mode flags in `00-puppet.yaml`. Snapshots still work
correctly.

### List snapshots

Via RKE2 (combined local + S3 view):

```bash
sudo /usr/local/bin/rke2 etcd-snapshot list
```

Via aws CLI directly against S3:

```bash
# Credentials live in Foreman; substitute or export from there
AWS_ACCESS_KEY_ID=<from-foreman> \
AWS_SECRET_ACCESS_KEY=<from-foreman> \
aws --endpoint-url=https://qumulo-data.ufhpc:9000 --no-verify-ssl \
    s3 ls s3://kub-mgmt-etcd/
```

### Delete a snapshot

```bash
# Delete from local + S3
sudo /usr/local/bin/rke2 etcd-snapshot delete <snapshot-name>
```

For ad-hoc / test files in the bucket (manual aws-cli puts):

```bash
AWS_ACCESS_KEY_ID=<...> AWS_SECRET_ACCESS_KEY=<...> \
aws --endpoint-url=https://qumulo-data.ufhpc:9000 --no-verify-ssl \
    s3 rm s3://kub-mgmt-etcd/<key>
```

## Etcd snapshot restore (DR)

Use this when you need to recover from data loss / corruption / disaster.
The procedure restores the cluster to the state at the chosen snapshot.

> ⚠ **Restore is destructive** — it overwrites the current etcd contents
> across all servers. Anything written between the snapshot timestamp and
> restore is lost. Take a fresh manual snapshot of the current state
> *before* restoring (assuming the cluster is still partially functional)
> in case you need to roll forward.

### High-level procedure

1. **Pick a snapshot** — any one is sufficient. Generally pick the most
   recent that pre-dates the corruption. Cross-check S3 and local lists.
2. **Stop rke2-server on ALL servers** (cluster goes offline).
3. **On ONE server** (your "restore seed"): run `rke2 server --cluster-reset
   --cluster-reset-restore-path=<snapshot>` to rebuild etcd from the snapshot.
4. **Wipe etcd data** on the other servers so they re-sync from the
   restore seed — `/var/lib/rancher/rke2/server/db/etcd` on each non-seed
   server.
5. **Start rke2-server on the restore seed**, wait for Ready.
6. **Start rke2-server on each remaining server one at a time**, wait for
   each to reach Ready before starting the next. They re-join from the
   restore seed and replicate the restored etcd content.
7. **Verify**: `kubectl get nodes` shows all 5 Ready, workloads come back.

Detailed commands and version-specific quirks: see [RKE2's official restore
docs](https://docs.rke2.io/backup_restore) — RKE2 changes the exact flag
names occasionally, so always cross-reference current docs against your
RKE2 version.

### Restore from S3 (snapshot not on local disk)

If the cluster is wiped and you only have S3 snapshots:

```bash
# Download from S3 first
AWS_ACCESS_KEY_ID=<...> AWS_SECRET_ACCESS_KEY=<...> \
aws --endpoint-url=https://qumulo-data.ufhpc:9000 --no-verify-ssl \
    s3 cp s3://kub-mgmt-etcd/<snapshot-filename> \
          /var/lib/rancher/rke2/server/db/snapshots/<snapshot-filename>

# Then restore using the local path:
sudo /usr/local/bin/rke2 server \
    --cluster-reset \
    --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/<filename>
```

RKE2 also supports restore directly from S3 via
`--cluster-reset-restore-path=s3://...` plus the same etcd-s3-* flags as
the running config. The download-then-restore path above is the simpler
mental model and works regardless of credential availability at restore
time.

## Verification commands

Cluster health (run from any node or workstation with kubeconfig):

```bash
# All 5 nodes Ready, control-plane,etcd roles
kubectl get nodes -o wide

# Etcd member list (from inside an etcd pod)
kubectl -n kube-system exec etcd-kub-mgmt1.ufhpc -- \
    etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
    member list

# All system pods Running (Completed for helm-install jobs)
kubectl -n kube-system get pods

# Cilium agents on all nodes
kubectl -n kube-system get pods -l k8s-app=cilium -o wide

# Cilium status (from any node)
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief

# Gateway API GatewayClass accepted
kubectl get gatewayclass

# Cilium configmap reflects expected values
kubectl -n kube-system get configmap cilium-config -o yaml | \
    grep -E 'tunnel|mtu|cluster-pool|gateway-api|kube-proxy-replacement'
```

Network connectivity smoke test (PSA-restricted-compliant pod, see
`bootstrap.md` Phase 8 for the full manifest):

```bash
# Quick re-creates a netshoot pod, runs DNS + TCP + HTTPS tests
kubectl run nettest \
  --image=nicolaka/netshoot --restart=Never -- sleep 600 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"nettest","image":"nicolaka/netshoot","command":["sleep","600"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":65532,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'

# (or use the manifest from bootstrap.md if --overrides gets unwieldy)
```

## Adding a node

(Pre-bootstrap of a workload cluster is in `bootstrap-cluster/`. This is for
adding nodes to *this* cluster.)

1. **Foreman**: provision the new VM, assign it to the `mgmt_cluster`
   hostgroup. Verify Puppet flags: `is_kub_management_cluster=true`,
   `has_kub_installed=true`, `has_etcd_local_user=true`.
2. **Puppet**: `puppet agent -t` on the new node. Verify
   `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` has the expected values
   including `server: https://vkub-mgmt.ufhpc:9345` and the cluster token.
3. **Skip the seed-only step** (no removing of `server:` line) — this node
   is a joiner.
4. **Install RKE2 binary** (same as bootstrap.md Phase 2):
   ```bash
   curl -sfL https://get.rke2.io | \
     sudo INSTALL_RKE2_METHOD=tar \
          INSTALL_RKE2_VERSION=v1.35.4+rke2r1 \
          INSTALL_RKE2_TYPE=server \
     sh -
   ```
5. **Start**: `sudo systemctl enable rke2-server.service --now`. Watch
   logs; wait for Ready.
6. **Verify** from kub-mgmt1 (or wherever): `kubectl get nodes` shows the
   new node Ready.

Add nodes one at a time — etcd quorum during member additions is fragile.

## Removing a node (graceful)

For planned decommission (hardware refresh, capacity change):

```bash
# 1. Cordon and drain
kubectl cordon <node-name>
kubectl drain <node-name> --delete-emptydir-data --ignore-daemonsets

# 2. Stop rke2-server on the node
sudo systemctl stop rke2-server

# 3. Remove from etcd cluster (run from a healthy server)
kubectl -n kube-system exec etcd-<healthy-node> -- \
    etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
    member remove <member-id>
# Get member-id from `etcdctl member list` first

# 4. Delete the Node object
kubectl delete node <node-name>

# 5. On the removed node: full uninstall
sudo /usr/local/bin/rke2-uninstall.sh

# 6. Foreman: deprovision or move to a different hostgroup
```

## Where credentials live

| Credential | Storage | Rotation |
|---|---|---|
| Cluster join token | Foreman smart class param `ufrc_rke2::config.token` (hidden) | Manual — generate new token, update Foreman, run puppet on all nodes, restart rke2-server rolling |
| Cluster admin kubeconfig | `/etc/rancher/rke2/rke2.yaml` on each server | Per-component cert rotation handled by RKE2; for the kubeconfig file itself, regenerate or use Rancher RBAC |
| etcd-snapshot S3 access key | Foreman smart class param `ufrc_rke2::config.etcd-s3-access-key` | `qq s3_delete_access_key` + `s3_create_access_key` on Qumulo, update Foreman, puppet, rke2-server restart rolling |
| etcd-snapshot S3 secret | Foreman smart class param `ufrc_rke2::config.etcd-s3-secret-key` | Same as above (rotated together with the access key) |

**TODO before production**: rotate the etcd-snapshot S3 access key. Current
key was created during build and may have been seen in operations chats.

## Common troubleshooting

### Snapshot job failing

Check logs on a server:

```bash
sudo journalctl -u rke2-server --since "1 hour ago" | grep -iE 'etcd-snapshot|s3'
```

Symptoms vs. fixes:
- `403 Forbidden` from S3 → Qumulo bucket ACL lost the user; re-apply `fs_modify_acl`
- `connection refused` → Qumulo S3 service down or hostname/port wrong
- `x509: certificate signed by unknown authority` → cert chain changed on Qumulo, update `etcd-s3-endpoint-ca` or temp-toggle skip-verify

### Pod stuck Pending

```bash
kubectl describe pod <name> -n <ns>
# Look at Events at the bottom — most common causes:
# - PSA "restricted" rejection (need securityContext fields, see bootstrap.md)
# - Anti-affinity (multi-replica deployment can't schedule both on same node)
# - PVC Pending (storage class issue)
```

### Cilium agent crashing

```bash
kubectl -n kube-system logs ds/cilium --tail=100
kubectl -n kube-system exec ds/cilium -- cilium-dbg status
```

### A server node won't rejoin after reboot

If kub-mgmt(N) was healthy, was rebooted, and now won't reach Ready:

```bash
# On the broken node
sudo journalctl -u rke2-server --since "10 minutes ago"
```

Common: etcd member entry is stale (pre-reboot member ID still in cluster).
Remove and re-add via the "Removing a node" + "Adding a node" sequences.

## What this doc does NOT cover

- Initial cluster bootstrap → `bootstrap.md`
- CIDR allocation policy → `cidr-plan.md`
- Kemp VIP design → `kemp-vip-design.md`
- Cilium / ingress architecture → `kemp-cilium-routing.md`
- Rancher install (deferred — separate runbook when built)
- Application Gateways / HTTPRoutes (deferred — per-app)
- cert-manager setup (deferred)
- MetalLB / Cilium L2 announcements (deferred)
