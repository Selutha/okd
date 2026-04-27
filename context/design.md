# Multi-Cluster OKD Infrastructure — Design Document

**Status:** Draft v0.6 — for iteration
**Date:** 2026-04-24
**Changes since v0.5:** Added §6.5 — GPU Operator install/upgrade impact on OKD verified against NVIDIA + CRI-O docs. Toolkit writes a CRI-O drop-in (not via MachineConfig), CRI-O reload doesn't bounce kubelet, RHCOS upgrades use per-version Driver DaemonSets. Smaller per-upgrade blast radius than RKE2 because kubelet is independent of CRI-O on OKD.
**Changes since v0.4:** DR-2 rewritten as a pending decision with Option A vs Option B laid out honestly and a curated reading list covering worker OS, RHEL-worker retirement in OCP, and the FCOS→SCOS flip. §13 updated to reflect pending status.
**Changes since v0.3:** Lustre confirmed DDN-backed; DDN CSI locked as the storage-orchestration layer.
**Changes since v0.2:** Added DDN Lustre CSI as the Lustre integration path in G-2.
**Changes since v0.1:** LB choice locked (Kemp); storage strategy locked (Pure + Lustre); identity locked (AD, integration shape TBD).
**Scope:** Foreman-driven provisioning of two OKD clusters (infra + GPU/B200) on a hybrid VMware/bare-metal substrate, with a separate RKE2/Rancher cluster for multi-cluster management.

> Read the **"Decisions to Revisit"** and **"Identified Gaps"** sections at the end first. Several items in the original plan are either non-standard for OKD or missing entirely (load balancing, storage, DNS, registry, identity). The body of the document assumes those gaps will be filled; the call-outs explain why they matter.

---

## 1. Architecture Overview

### 1.1 Layering

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Layer 0 — Provisioning & Lifecycle                                      │
│  Foreman (existing)                                                      │
│   - PXE / DHCP / TFTP for bare-metal                                     │
│   - Kickstart for RHEL                                                   │
│   - Ignition delivery for FCOS targets (via HTTP)                        │
│   - Puppet for post-install RHEL config (NOT for OKD worker join)        │
└────────────┬─────────────────────────────────────┬───────────────────────┘
             │ provisions HW                       │ provisions HW
             ▼                                     ▼
┌────────────────────────────┐         ┌──────────────────────────────────┐
│  Layer 1a — Bare metal     │         │  Layer 1b — VMware vSphere       │
│                            │         │  (existing)                      │
│  Workers (FCOS):           │         │                                  │
│   - OKD-Infra workers ×N   │         │  Control planes (FCOS) ×3 each:  │
│   - OKD-GPU workers ×N     │         │   - okd-infra-cp-{1,2,3}         │
│     (NVIDIA B200)          │         │   - okd-gpu-cp-{1,2,3}           │
│                            │         │                                  │
│                            │         │  Mgmt VMs (RHEL/SLES):           │
│                            │         │   - rancher-rke2-{1,2,3}         │
│                            │         │                                  │
│                            │         │  Support VMs (RHEL):             │
│                            │         │   - api/ingress LB pair          │
│                            │         │   - bastion / install host       │
└────────┬───────────────────┘         └─────────────┬────────────────────┘
         │ join (Ignition)                           │
         └──────────────────┬────────────────────────┘
                            ▼
        ┌────────────────────────────────────────┐
        │  Layer 2 — Workload clusters           │
        │   - OKD-Infra (general workloads)      │
        │   - OKD-GPU   (B200 inference)         │
        │   - OKD-GPU-2 (future mirror)          │
        └─────────────────┬──────────────────────┘
                          │ kubeconfig import (read + manage, not deploy)
                          ▼
        ┌────────────────────────────────────────┐
        │  Layer 3 — Multi-cluster management    │
        │   Rancher on RKE2 (3 VMs)              │
        │   Isolated from downstream clusters    │
        └────────────────────────────────────────┘
```

### 1.2 Design tenets

- **Strict separation of concerns by layer.** A failure in any one layer must not cascade upward or downward beyond well-defined recovery procedures.
- **Each cluster is self-sufficient.** OKD clusters keep running with full data-plane and control-plane availability if Rancher, Foreman, or Puppet are all simultaneously offline.
- **VMs for control, bare metal for workload.** VMs give snapshot/clone/HA-restart lifecycle benefits for stateful-ish components (etcd, Rancher); bare metal gives full hardware access (B200 GPUs, NUMA, NICs) for workloads.
- **Stay Red Hat where it pulls weight, leave where it doesn't.** OKD/FCOS/Foreman are mature; ACM/MCE for multi-cluster management is not yet competitive with Rancher for this use case.

---

## 2. Foreman Responsibilities and Scope

### 2.1 In scope

| Target | OS | Provisioning method | Post-install config |
|---|---|---|---|
| OKD bare-metal workers | Fedora CoreOS | PXE → live ISO → Ignition fetch (HTTP from install host) | None — Machine Config Operator (MCO) owns config |
| OKD VM control planes (FCOS) | Fedora CoreOS | Not Foreman — VMware OVA or PXE-via-Foreman, Ignition delivered via guestinfo | None — MCO owns config |
| Rancher RKE2 nodes | RHEL 9 | Foreman kickstart | Puppet (NTP, repos, hardening, RKE2 install) |
| Bastion / install host | RHEL 9 | Foreman kickstart | Puppet (openshift-install binary, oc, helm, OCP/OKD images mirror if disconnected) |
| Foreman LB VMs (if HAProxy/keepalived chosen) | RHEL 9 | Foreman kickstart | Puppet (HAProxy + keepalived configs) |

### 2.2 Out of scope (important)

- **Foreman does NOT join workers to OKD.** Joining is an Ignition-driven flow owned by the OKD installer and MCO. The original plan mentioned "Puppet to apply… the OKD worker binary" — there is no such binary in OKD. Workers boot FCOS with an Ignition config that points at the cluster's Machine Config Server (MCS) on `api-int.<cluster>:22623`, and MCO takes over from there. **See Decision DR-2.**
- **Foreman does NOT manage day-2 OS state on OKD nodes.** FCOS is immutable + MCO-managed; Puppet must not touch OKD nodes.
- **Foreman does NOT provision the OKD cluster itself.** It provisions the *substrate* (machines + their OS); the OKD installer (`openshift-install` for IPI/UPI, or `agent-based-installer`) provisions the cluster on top.

### 2.3 Integration points

- **HTTP server for Ignition.** Foreman or a small companion HTTP server (could live on the install host) must serve `bootstrap.ign`, `master.ign`, `worker.ign` to FCOS first-boot.
- **DHCP next-server / filename.** Foreman's DHCP/TFTP needs FCOS-aware boot entries (different kernel args than RHEL — `coreos.inst.install_dev`, `coreos.inst.ignition_url`, etc.).
- **Hostname/IP allocation.** Foreman should be source of truth for node hostnames and primary IPs to keep DNS/LB configs reproducible.

---

## 3. OKD Cluster Architecture (per cluster)

Both `OKD-Infra` and `OKD-GPU` use identical topology except for worker hardware and GPU operator presence.

### 3.1 Topology

| Role | Count | Placement | OS | Sizing (starting point) |
|---|---|---|---|---|
| Control plane (master) | 3 | VMware | FCOS | 8 vCPU / 16 GiB / 120 GiB SSD |
| Worker | N | Bare metal | FCOS | infra: TBD; GPU: B200-class hosts |
| Bootstrap (install-time only) | 1 | VMware | FCOS | 4 vCPU / 16 GiB — destroyed after install |

> **Note on the "3 separate ETCD nodes" decision in the original plan:** OKD does not support a topology with etcd on dedicated nodes outside the control plane in a supported way. etcd is deployed as a static pod by the cluster-etcd-operator on the master nodes. Running etcd on three additional VMs would require manual etcd management and lose operator support. **See Decision DR-1.** The table above assumes etcd runs co-located on the 3 control-plane VMs (the supported topology).

### 3.2 Install method options

| Method | Pros | Cons | Recommendation |
|---|---|---|---|
| **Agent-based installer** | No bootstrap node; produces a single ISO; works air-gapped; good for hybrid VM+bare-metal | Newer; some quirks around mixed-arch and large clusters | **Preferred.** Best fit for VM control plane + bare-metal workers without IPI's hard requirements. |
| **UPI (User-provisioned)** | Maximum control; Foreman-friendly; well-understood | Bootstrap node lifecycle is manual; you build all PXE/Ignition plumbing | Acceptable fallback if agent-based hits limitations. |
| **IPI on bare metal** | Most automated; uses Metal3/BMO under the hood | Assumes BMC access, doesn't mix VM+bare-metal cleanly, opinionated about networking | Not recommended for this hybrid layout. |

### 3.3 Networking inside the cluster

- **CNI:** OVN-Kubernetes (OKD default since 4.12). Provides network policies, egress IPs, and is required for several modern features. Calico is possible but requires explicit choice at install time and is less commonly tested with OKD.
- **Pod / Service CIDRs:** Must be unique per cluster and non-overlapping with any other cluster (including the future third) and with VMware/bare-metal subnets. Suggested allocation:
  - `OKD-Infra`: pods `10.128.0.0/14`, services `172.30.0.0/16` (defaults are fine if isolated)
  - `OKD-GPU`: pods `10.132.0.0/14`, services `172.31.0.0/16`
  - `OKD-GPU-2` (future): pods `10.136.0.0/14`, services `172.32.0.0/16`
- **MTU:** decide early. If GPU cluster will do RDMA / multi-node inference, plan for jumbo frames (9000) on the GPU fabric and matching pod-network MTU offset.

### 3.4 Required cluster endpoints

OKD requires DNS records that resolve from every node and from anything that talks to the cluster:

- `api.<cluster>.<base-domain>` → API VIP (external)
- `api-int.<cluster>.<base-domain>` → API VIP (internal — used by nodes for MCS/kube-apiserver)
- `*.apps.<cluster>.<base-domain>` → Ingress VIP

These VIPs must be load-balanced across the 3 masters (API) and the ingress controller pods (apps). **See Section 5 for LB options.**

---

## 4. RKE2 + Rancher Management Cluster

### 4.1 Sizing

3 VMs on VMware, each 4 vCPU / 16 GiB / 100 GiB SSD is sufficient for a Rancher managing 2–3 downstream clusters of modest size. Scale up only if Rancher's monitoring/logging stack is enabled in-cluster.

### 4.2 Install flow

1. Foreman provisions 3 RHEL 9 VMs.
2. Puppet applies base hardening, NTP, repos.
3. RKE2 installed via `curl -sfL https://get.rke2.io | sh -` on node 1 with `server` role; nodes 2/3 join with `server` role too (HA control plane).
4. cert-manager + Rancher Helm chart deployed onto RKE2.
5. Rancher exposed via either the bundled ingress-nginx or via an external LB pointing at the 3 RKE2 nodes on 443.

### 4.3 Attaching OKD clusters

- Use Rancher's **"Import existing"** flow. This generates a YAML manifest that, when applied to the OKD cluster with cluster-admin, deploys the `cattle-cluster-agent` and `cattle-node-agent`.
- Rancher then provides: cluster overview, app catalog, RBAC projection, kubectl shell, monitoring/logging install (optional), workload visibility.
- Rancher will **not** drive OKD upgrades. OKD upgrades go through `oc adm upgrade` / the Cluster Version Operator. This is correct and expected — call it out in runbooks so no one expects "upgrade button in Rancher" to work for OKD.

### 4.4 Backup posture

- RKE2's native etcd snapshot feature (`/var/lib/rancher/rke2/server/db/snapshots/`) — schedule every 6 h, retain 28.
- Ship snapshots off-cluster (S3 or NFS).
- VMware snapshots are useful for **pre-change rollback** of the VMs themselves but are **not a substitute** for etcd snapshots — VM snapshots of a running etcd member can capture inconsistent state. **See Decision DR-3.**

---

## 5. Networking

### 5.1 VLAN / segmentation recommendation

| VLAN | Purpose | Hosts |
|---|---|---|
| `mgmt` | Foreman, Puppet, Rancher, bastion, OOB tooling | All mgmt VMs, BMCs |
| `okd-infra-node` | OKD-Infra node-to-node, API/ingress traffic | infra cluster nodes + LB |
| `okd-gpu-node` | OKD-GPU node-to-node, API/ingress traffic | GPU cluster nodes + LB |
| `gpu-fabric` (optional) | RDMA/RoCE or InfiniBand between GPU workers | GPU bare-metal NICs |
| `storage` | NFS/iSCSI/Ceph traffic | All workers + storage backends |

L3 routing between `mgmt` and the cluster VLANs is required so Rancher can reach the OKD APIs.

### 5.2 Load balancing for API and Ingress — Kemp LoadMaster

**Decision:** Use the existing enterprise Kemp LoadMaster for both clusters' API and Ingress VIPs. This eliminates the need for a dedicated HAProxy+keepalived VM pair per cluster (saves 4 VMs across 2 clusters, 6 across the future 3rd).

Required Virtual Services per cluster:

| VIP | Port | Mode | Backends | Health check |
|---|---|---|---|---|
| `api.<cluster>.<base>` | 6443/TCP | TCP passthrough | 3 master VMs | TCP 6443 |
| `api-int.<cluster>.<base>` (often same VIP) | 6443/TCP | TCP passthrough | 3 master VMs | TCP 6443 |
| `api-int` MCS | 22623/TCP | TCP passthrough | 3 master VMs | TCP 22623 (HTTP 200 on `/healthz` if Kemp permits) |
| `*.apps.<cluster>.<base>` | 80/TCP, 443/TCP | TCP passthrough (preserve TLS to ingress controller) | All worker nodes (or just ingress-router-bearing ones) | TCP 1936 (router stats) or TCP 443 |

Notes:
- **Don't terminate TLS at Kemp for `*.apps`** — terminate at the OKD ingress controller (HAProxy router) so cluster-managed certs work and so workloads that need mTLS pass-through still can. Kemp is L4 here, not L7.
- **MCS (22623)** is required during install and node-join. It can be on the same VIP as the API or a separate VIP — same VIP is simpler.
- Confirm the Kemp's data-path interfaces are reachable from both `okd-infra-node` and `okd-gpu-node` VLANs (Section 5.1) and from the masters' subnet for the loop-back path nodes use to reach `api-int`.
- One Kemp VS group per cluster; reuse the same Kemp pair for cluster #3 — no per-cluster scaling concern at this size.

### 5.3 DNS

OKD is unforgiving about DNS. Required (per cluster):

- Forward and reverse for every node
- `api.<cluster>.<base>` → API VIP
- `api-int.<cluster>.<base>` → API VIP (often same address, definitely same record set)
- `*.apps.<cluster>.<base>` → Ingress VIP

Use the existing enterprise DNS (likely Active Directory–integrated). Delegate `<base>` or a sub-zone to make automation easier.

### 5.4 NTP / time

OKD will refuse to start or behave unpredictably with skewed clocks. Every node must point at the same NTP source (usually AD DCs or an internal stratum-2). Verify on FCOS via `chronyc tracking`.

---

## 6. GPU / B200 Considerations (OKD-GPU cluster)

### 6.1 Stack

1. **Node Feature Discovery (NFD) Operator** — labels nodes with PCI/CPU/kernel features; required by GPU Operator.
2. **NVIDIA GPU Operator** — installs drivers (containerized), nvidia-container-toolkit, device plugin, DCGM exporter, MIG manager. Officially supports OpenShift; OKD support is community-driven but works.
3. **Optional: NVIDIA Network Operator** — needed if you want RDMA/GPUDirect across nodes (multi-node inference, large model serving).

### 6.2 B200 specifics

- B200 requires a recent driver branch (R570+ at time of writing). Verify the GPU Operator version you pin actually ships that branch.
- B200 requires CUDA 12.8+ in user images.
- FCOS kernel must have IOMMU enabled and be recent enough for the driver. Check your target OKD release's FCOS kernel version against NVIDIA's compat matrix before committing.
- Power & cooling: B200 SXM systems pull 1000W+ per GPU. Make sure the bare-metal hosts and rack PDUs are sized for it.
- If using SXM modules, MIG partitioning behavior differs from H100 — confirm with the inference workload owners whether MIG is needed or full-GPU allocation.

### 6.3 Scheduling

- Taint GPU nodes (e.g., `nvidia.com/gpu=present:NoSchedule`) and require pods to tolerate + request `nvidia.com/gpu`.
- Avoid mixing CPU-only general workloads onto GPU nodes — defeats the cluster-separation rationale.

### 6.4 Image registry for GPU images

GPU container images are large (5–15 GB). Plan for either an in-cluster registry with adequate storage or a pull-through cache to your existing registry. **See Gap G-3.**

### 6.5 GPU Operator install and upgrade impact on OKD

For comparison against the RKE2 alternative path (`design-rke2.md` §6.3), here's how the GPU Operator's lifecycle works on OKD specifically.

**Mechanism — important to understand:**

- The GPU Operator's nvidia-container-toolkit DaemonSet writes a CRI-O **drop-in config file** at `/etc/crio/conf.d/99-nvidia.toml` on each GPU node. Per the [NVIDIA Container Toolkit install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) and the [GPU Operator CDI/drop-in default behavior](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/cdi.html). **This does not go through MachineConfig.**
- Because the toolkit doesn't create a MachineConfig, the Machine Config Operator does **not** drain or reboot nodes for a normal GPU Operator install or chart upgrade. Drain+reboot via MCO is reserved for actual MachineConfig-class changes (kernel args, RHCOS version transitions, file-on-host changes captured in MachineConfig YAML).
- After writing the drop-in, the toolkit triggers a CRI-O reload to pick up the new runtime. CRI-O supports [partial config reload via SIGHUP](https://github.com/cri-o/cri-o/blob/main/docs/crio.conf.5.md), and reload is "designed to be non-disruptive to running containers when only reloading supported configuration options."
- **Crucially:** kubelet on OKD is a separate systemd unit from CRI-O. A CRI-O reload does not bounce kubelet. Pods on the node do not get marked NotReady. This is the meaningful difference vs. the RKE2 path, where RKE2 supervises containerd and a containerd SIGHUP cascades into an RKE2 (kubelet) restart.

**Three upgrade scenarios on OKD:**

| Scenario | Mechanism | Node impact |
|---|---|---|
| **First install** | Toolkit writes drop-in, CRI-O reloads, driver DaemonSet pulls + loads kernel module | GPU containers may briefly disrupt during driver-module load; kubelet stays up; non-GPU containers untouched |
| **Toolkit image upgrade** (most chart bumps) | New toolkit pod re-applies drop-in, triggers CRI-O reload | Same as install — CRI-O reload, kubelet stays up. Smaller blast radius than RKE2. |
| **Driver-only upgrade** | Driver upgrade controller drains GPU pods (`gpuPodDeletion`), updates driver DaemonSet pod, re-loads kernel module | GPU pods drain and reschedule; non-GPU pods unaffected; no CRI-O or kubelet touch |
| **RHCOS (cluster OS) upgrade** | Standard MCO drain + reboot per node; GPU Operator transitions nodes from old RHCOS-version DaemonSet to new one using [Driver Toolkit (DTK)](https://www.redhat.com/en/blog/entitlement-free-deployment-of-the-nvidia-gpu-operator-on-openshift) | Full node drain + reboot per node — but this is a *cluster upgrade*, not a GPU Operator upgrade. Standard OKD upgrade procedure. |

**RHCOS-version-specific Driver DaemonSets — an OKD-only advantage:**
The GPU Operator on OpenShift creates one driver DaemonSet per RHCOS version present in the cluster, with the matching DTK image baked in for kernel-module compatibility. During an OKD cluster upgrade, as nodes roll from RHCOS N to RHCOS N+1, the GPU Operator dynamically transitions each node from the old DaemonSet to the new one. **This handles the kernel-module-version-pinning problem automatically** — the equivalent on RKE2 would require careful coordination between kernel updates and driver branch updates, which is operationally heavier.

**Open verification item:** the docs don't pin down whether the GPU Operator's containerized toolkit on OpenShift issues `systemctl reload crio` (non-disruptive to running containers) or `systemctl restart crio` (restarts CRI-O, terminates containers). The manual nvidia-container-toolkit install guide says `systemctl restart crio`, but that's the manual host-install path — not necessarily what the Operator's containerized toolkit does. Validate during the install spike before committing to "minimal disruption" claims for production rollouts.

**Net comparison vs RKE2 (`design-rke2.md` §6.3):**
OKD's GPU Operator path has a **smaller blast radius per upgrade** because it only touches CRI-O, not kubelet. Workloads on the node may experience brief GPU-runtime disruption but the node doesn't go NotReady. RKE2's path takes kubelet down on every toolkit upgrade because RKE2 supervises containerd. Both can be done node-by-node with rolling drains; OKD's is closer to "transparent" for the upgrade itself, while RKE2's needs explicit drain+wait per node.

---

## 7. Backup Strategy

| Component | What | How | Retention | Restore RTO |
|---|---|---|---|---|
| Foreman | Postgres DB + `/etc/foreman*` + `/var/lib/tftpboot` templates | foreman-maintain backup | 30 days, offsite | < 4 h |
| Puppet | r10k-managed Git repo (already in GitLab) | Git is the backup | n/a | < 1 h (git checkout) |
| Rancher RKE2 | etcd snapshots + Rancher Helm values | RKE2 snapshot timer + `helm get values` to git | 28 snapshots / 30 days values | < 2 h |
| OKD etcd (each cluster) | etcd snapshot via cluster-backup.sh | CronJob writing to PV → external storage | 14 days | < 1 h to restore single cluster |
| OKD MachineConfigs | Implicit in etcd backup | n/a | n/a | n/a |
| Application PVs | Workload-specific (Velero, app-level, ODF mirroring) | TBD per workload | TBD | TBD |

> **OKD does not auto-backup etcd.** You must schedule `cluster-backup.sh` (provided by the etcd operator) yourself. The original plan said "OKD clusters handle their own ETCD backups via OKD's native mechanisms" — the mechanism exists but is not enabled by default. **See Gap G-1.**

---

## 8. Failure Modes and Recovery

### 8.1 Failure matrix

| Failure | Blast radius | Workloads affected? | Recovery |
|---|---|---|---|
| Foreman down | New provisioning blocked | No | Restore from foreman-maintain backup; existing nodes unaffected |
| Puppet down | RHEL drift on Rancher/LB VMs | No | Restore Puppet master from Git; agents resume |
| Rancher RKE2 quorum loss (1 node) | Rancher UI degraded | No | Replace node, RKE2 rejoins |
| Rancher RKE2 quorum loss (≥2 nodes) | Rancher down | No | Restore from RKE2 etcd snapshot; if total loss, fresh RKE2 install + Rancher reinstall + re-import OKD clusters |
| OKD master down (1 of 3) | Reduced API HA | No | Replace VM via openshift-install or manual control-plane replacement procedure |
| OKD master down (2 of 3) | API + etcd quorum lost | **Yes** (no scheduling, but running pods continue) | Restore etcd from backup using OKD disaster-recovery playbook; rebuild masters |
| OKD master down (3 of 3) | Full control plane loss | Running pods continue, no new scheduling, no self-healing | Same as above; longer; have the procedure rehearsed |
| OKD worker down | One node's pods rescheduled | Partial / brief | Reprovision via Foreman; FCOS+Ignition rejoin |
| GPU node hardware failure | GPU pods on that node down | Yes for that node | Reprovision; B200 RMA process is its own beast — keep a hot spare if SLA matters |
| VMware host failure | Whatever was on it; vSphere HA restarts VMs | Brief | Standard vSphere HA |
| Storage backend failure | Anything with PVs | **Yes**, severely | Out of scope of this doc — but **must be designed.** See Gap G-2. |

### 8.2 Recovery playbook stubs (to be expanded)

- `runbooks/foreman-restore.md`
- `runbooks/rancher-rke2-rebuild.md`
- `runbooks/okd-etcd-restore.md` ← **highest priority; rehearse twice a year**
- `runbooks/okd-control-plane-replace.md`
- `runbooks/gpu-node-reprovision.md`

---

## 9. Deployment Sequencing

**Phase 0 — Prerequisites (existing or to confirm)**
1. VMware capacity: ≥ 9 VMs at planned size + headroom (3 Rancher + 3 masters/cluster × 2 clusters; bootstrap VMs short-lived).
2. Bare-metal hardware racked, BMC accessible from Foreman.
3. VLANs + L3 + firewall rules (per Section 5.1).
4. DNS sub-zone delegated.
5. AD service account provisioned for OKD OAuth LDAP bind (and/or Keycloak — see G-4); groups identified for cluster-admin / cluster-reader RBAC.
6. Kemp LoadMaster: confirm capacity for added Virtual Services and that data-path interfaces reach the cluster VLANs (Section 5.2).
7. Pure Storage: confirm FlashArray/FlashBlade tenancy or LUNs/exports earmarked; obtain API credentials for `pure-csi` provisioner.
8. DDN Lustre: identify which DDN Lustre filesystem(s) the OKD-GPU workers will mount; obtain DDN CSI driver release matched to the target OKD/FCOS kernel; confirm DDN support contract covers FCOS/RHCOS.

**Phase 1 — Management plane**
1. Foreman: confirm DHCP/TFTP/PXE working for both RHEL kickstart and FCOS PXE.
2. Configure Kemp Virtual Services for OKD-Infra (api, api-int/MCS, *.apps) per Section 5.2; backends will report unhealthy until masters exist — that's expected.
3. Build 3 Rancher RKE2 VMs; install RKE2; install Rancher.

**Phase 2 — OKD-Infra cluster**
1. Generate install-config.yaml; render Ignition.
2. Provision FCOS bootstrap VM and 3 master VMs (Ignition via guestinfo or HTTP).
3. PXE-boot bare-metal workers via Foreman pointing at worker.ign.
4. Wait for `openshift-install wait-for install-complete`.
5. Configure cluster: identity provider, ingress cert, internal registry storage, etcd backup CronJob, monitoring storage.
6. Import into Rancher.

**Phase 3 — OKD-GPU cluster**
1. Repeat Phase 2 with cluster-specific VIPs, hostnames, CIDRs.
2. Install NFD Operator → GPU Operator → (optional) Network Operator.
3. Validate `nvidia-smi` from a test pod on each GPU worker.
4. Import into Rancher.

**Phase 4 — Operationalize**
1. Schedule etcd backups on both OKD clusters; verify a restore in a test environment.
2. Document and rehearse the full disaster-recovery playbook.
3. Onboard the first real workload to OKD-Infra; the first inference workload to OKD-GPU.

**Phase 5 — Future**
- OKD-GPU-2 mirror cluster — repeat Phase 3 with new VIPs/CIDRs/DNS. Determine whether it's DR (cold/warm standby) or active (front-ended by a higher-level LB).

---

## 10. Scaling Considerations

### 10.1 Adding workers

- Bare metal: rack hardware → register in Foreman → PXE → FCOS Ignition picks up worker config from MCS → node appears in OKD as `Ready`. Time-to-ready: 30–60 minutes including hardware burn-in.
- Reusable: Foreman host group, Ignition template, MCS endpoint. No new design needed.

### 10.2 Adding a third cluster (mirror inference)

Reusable as-is:
- Foreman host groups, Puppet modules, RKE2/Rancher (just import the new cluster).
- LB VM pair pattern.
- DNS sub-zone pattern.
- GPU operator stack.

Needs new design:
- New unique CIDRs (pod, service, node).
- Decision: is it DR (cold/warm) or active second site? Affects whether a global LB or DNS-based traffic split sits in front.
- If geographically separate, latency to Rancher matters less than network reachability — confirm Rancher can reach both clusters' API VIPs.

### 10.3 Scaling out the management cluster

3-node RKE2 is sufficient up to ~10 downstream clusters. Beyond that, scale Rancher vertically (more RAM) before scaling RKE2 horizontally — Rancher's bottleneck is single-process Go memory, not control-plane CPU.

---

## 11. Decisions to Revisit

> Each item is something in the original plan that I think warrants a second look before we commit. The IDs are referenced from earlier sections.

### DR-1 — Separate ETCD nodes from control plane
**Original plan:** "3 control plane (head) nodes — VMs in VMware; 3 ETCD nodes — VMs in VMware".
**Issue:** OKD's cluster-etcd-operator deploys etcd as static pods on master nodes. There is no supported topology that runs etcd on separate machines. Going off-script means you self-manage etcd, lose operator-driven upgrades and cert rotation, and likely fail conformance.
**Recommendation:** Drop the separate etcd tier. Keep the 3 masters; etcd lives on them. This saves 6 VMs across two clusters and aligns with the supported path.
**Counter-argument:** If the goal was etcd performance isolation, the right answer is fast local NVMe on the master VMs (already standard guidance — etcd needs <10 ms fsync), not separate machines.

### DR-2 — Worker OS and the role of Puppet on OKD nodes
**Status:** 🟡 **Pending — user evaluating.** Not locked. Revisit after background reading.

**Original plan:** "Workers are standard RHEL with a Puppet config to apply settings and the OKD worker binary."

**Context that makes this non-trivial:**
- The user's org is a Foreman / Katello + Puppet shop. Puppet is the existing delivery path for SSH keys, Lustre kernel modules, NVIDIA drivers, and general host config across the RHEL/Rocky fleet.
- Changing the OKD worker config model doesn't retool the whole org — Puppet/Katello still owns Foreman itself, the Rancher RKE2 VMs, the bastion, the install host, and any other RHEL/Rocky admin VMs. The scope of change is *only* the OKD worker config surface.
- Worker GPU mix is L40 + B200 + B300, which raises the stakes on whichever driver-delivery path is chosen (see §6).

**Issue with the original plan as written:**
- There is no "OKD worker binary" that Puppet installs onto RHEL to produce a working OKD worker. OKD's worker join flow is Ignition → Machine Config Server → Machine Config Operator, and MCO expects an FCOS/SCOS host it can manage.
- RHEL compute nodes were a *first-class supported* path in Red Hat's paid OCP product via `openshift-ansible` scaleup playbooks. That path was **deprecated in OCP 4.16** and slated for removal. It was never first-class in OKD.
- The node OS itself is mid-transition: **OKD 4.16 shifted from Fedora CoreOS (FCOS) to CentOS Stream CoreOS (SCOS)**. New clusters still boot an FCOS live image but pivot to SCOS during init. SCOS is philosophically closer to RHEL than FCOS was.

**Two realistic options:**

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **A — SCOS workers, MCO-managed** | Foreman PXEs FCOS live → Ignition → pivot to SCOS → MCO owns day-2. SSH keys via MachineConfig. Lustre via rpm-ostree layered module + DDN CSI. NVIDIA via GPU Operator (containerized drivers, per-node-pool driver branches for L40 vs Blackwell). | Standard OKD path; cluster manages OS/kubelet/CRI-O/upgrades; mixed GPU types handled natively by GPU Operator + NFD; no per-node Puppet reconciliation. | Team learns MachineConfig + GPU Operator patterns for the OKD node surface specifically. Week-to-days of ramp for a competent Puppet shop. |
| **B — RHEL workers self-managed with Puppet** | Foreman provisions RHEL; Puppet installs CRI-O, kubelet, kubelet config, kube-proxy/OVN-K bits, certs, NVIDIA drivers, Lustre client. Manual CSR approval for join. | Keeps existing Puppet pipeline end-to-end. Familiar tooling for the whole host lifecycle. | No documented OKD path — you own join flow and day-2 forever. OKD upgrades don't coordinate kubelet upgrades on these nodes. NVIDIA GPU Operator's containerized driver model conflicts with host-installed drivers, so the Operator benefits (multi-driver-branch for L40/B200/B300, DCGM, MIG mgmt) are lost or require parallel solutions. |

**Current lean (not locked):** Option A, on these grounds:
- Puppet stays fully in use for everything that isn't an OKD node (Rancher, bastion, Foreman itself, any other VMs). Scope of change is bounded.
- Mixed GPU architectures (L40 / B200 / B300) make the GPU Operator's per-node-pool driver model strongly preferable to a hand-rolled Puppet equivalent.
- MachineConfig has direct analogs for the things Puppet currently does on hosts (sysctls, kernel args, file drops, systemd units, SSH keys, rpm-ostree layered packages).

**Reading to inform the decision:**

*Worker OS — what FCOS/SCOS actually is and what it implies:*
- [Fedora CoreOS — OKD 4 Architecture](https://docs.okd.io/latest/architecture/architecture-rhcos.html) — canonical node-OS architecture page.
- [Preparing to install on bare metal — OKD 4](https://docs.okd.io/latest/installing/installing_bare_metal/preparing-to-install-on-bare-metal.html) — install flow showing the Ignition/MCS expectations for nodes.
- [Machine configuration overview — OKD 4](https://docs.okd.io/latest/machine_configuration/index.html) — what MCO manages on every node (kernel, CRI-O, kubelet, systemd, NetworkManager, files).
- [Machine Config Daemon metrics — OKD 4.14](https://docs.okd.io/4.14/nodes/nodes/nodes-nodes-machine-config-daemon-metrics.html) — the drift-detection loop that makes Puppet-on-OKD-nodes a drift war.

*Retirement of RHEL workers in OCP:*
- [OCP 4.16 Release Notes — RHEL compute machines deprecated](https://docs.openshift.com/container-platform/4.16/release_notes/ocp-4-16-release-notes.html) — the announcement.
- [OCP 4.18 Release Notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/release_notes/ocp-4-18-release-notes) — deprecation continues; removal forthcoming.
- [OpenShift Nodes documentation — RHEL compute machines](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.13/html-single/nodes/index) — last version of OCP with a robust RHEL-worker story, useful for understanding what's being sunset.

*The FCOS → SCOS (CentOS Stream CoreOS) flip:*
- [Node Operating System changes to SCOS — OKD upgrade notes](https://okd.io/docs/project/upgrade-notes/from-4-15/fcos-to-scos-migration/) — the migration doc (new clusters now target SCOS; FCOS is only used as the live-install image before pivot).
- [OKD 4.16 release announcement (okd.io blog)](https://okd.io/blog/) — landing page; scan for the 4.16 release post for the SCOS context.

**Decision gate:** pick A or B before Phase 2 begins. The answer determines Foreman host-group templates, Ignition vs kickstart for workers, and whether the NVIDIA GPU Operator or Puppet owns driver lifecycle on GPU workers.

### DR-3 — VMware snapshot as Rancher backup mechanism
**Original plan:** "VMware snapshots after stable configuration… snapshot rollback is the recovery path."
**Issue:** A VMware snapshot of a *running* etcd member can capture an inconsistent state mid-write. Restoring it can leave the etcd cluster unable to form quorum. VMware snapshots also accumulate delta files that hurt I/O if left in place.
**Recommendation:** Use RKE2's native etcd snapshot feature as primary backup. Use VMware snapshots only as short-lived pre-change rollback markers (delete within hours), not as a recovery mechanism.

### DR-4 — Mirror cluster purpose unspecified
**Original plan:** "A future third cluster may be added as a mirror of the inference cluster."
**Issue:** "Mirror" can mean DR (cold/warm), HA (active/active behind a global LB), or capacity overflow. Each implies different networking, data-replication, and operational design.
**Recommendation:** Defer the design but write down the *intent* now so Phase 1 networking choices don't paint you into a corner (e.g., overlapping CIDRs, single-region DNS).

### DR-5 — Rancher's role w.r.t. OKD upgrades
**Original plan implies:** "Rancher handles ongoing management, updates."
**Issue:** Rancher does not drive OKD upgrades. OKD upgrades go through CVO. Rancher's "upgrade" buttons apply to RKE/RKE2/K3s clusters it provisioned.
**Recommendation:** Set the expectation in runbooks: Rancher is for visibility, RBAC, app catalog, kubectl access. OKD lifecycle stays with `oc adm upgrade`.

---

## 12. Identified Gaps

> Things missing from the original plan that need to be designed before Phase 2.

### G-1 — etcd backup automation on OKD
There is no etcd backup unless you build one. Action: deploy a CronJob that runs `cluster-backup.sh` on a master, ships the tarball to S3/NFS, and prunes by age. Test restore.

### G-2 — Persistent storage strategy — Pure Storage + DDN Lustre

**Decision:** Pure Storage for general PVs (block via FlashArray and/or file via FlashBlade) and DDN-backed Lustre (EXAScaler / SFA) for HPC parallel-IO workloads. Suggested role split:

| Workload | Backend | Access mode | Notes |
|---|---|---|---|
| OKD internal image registry | Pure (FlashBlade NFS or FlashArray block) | RWX (FB) or RWO (FA) | RWX preferred so registry pods can scale |
| Prometheus / Alertmanager | Pure block (FlashArray) | RWO | Latency-sensitive, small volumes |
| Loki / log storage | Pure object (FlashBlade S3) or external object | n/a (S3) | Avoid putting bulk log retention on block |
| App PVs (general infra cluster) | Pure block | RWO/RWX | Default StorageClass = `pure-block` |
| Inference model artifacts (read-mostly, large) | Pure FlashBlade NFS *or* Lustre | RWX/RO | Pure if size is moderate; Lustre if multi-GB models pulled in parallel by many pods |
| Training datasets / scratch / checkpointing | **Lustre** | RWX | Parallel filesystem is the right shape here |

**Implementation:**
- **Pure CSI driver** (`pure-csi`) installs cleanly on OKD via the certified operator. One install per cluster. Two backends configurable in one driver instance (FlashArray + FlashBlade).
- **Lustre client on FCOS** is the hard part. FCOS is immutable + rpm-ostree, so `dnf install lustre-client` on the host is not the path. Four options:
  1. **DDN Lustre CSI driver** ✅ — vendor-supported CSI from DDN, dynamic PV provisioning, k8s-native integration. The Lustre backend is DDN, so this is the supported, on-the-rails path and the chosen storage-orchestration layer. **Caveat:** the CSI driver still needs the Lustre client kernel module present on the host — it orchestrates mounts, it doesn't ship the kernel module by itself. So this option pairs with one of (2)/(3) below for the actual module delivery, but the operational layer (StorageClass, PVC, mount lifecycle) is owned by DDN's driver instead of homemade glue. Verify FCOS/RHCOS support against DDN's compatibility matrix for the OKD release you target.
  2. **`MachineConfig` with rpm-ostree layered package** — adds the kernel module to the FCOS image at boot. Tied to the FCOS kernel version; needs rebuild when OKD upgrades the kernel. Pairs naturally with option 1 to satisfy the kernel-module requirement.
  3. **Containerized Lustre client DaemonSet** (driver-container pattern) — privileged pod loads the kernel module against the running FCOS kernel, similar to how the NVIDIA GPU Operator delivers its driver. More portable across kernel changes than rpm-ostree layering, but a less-common Lustre deployment pattern.
  4. **NFS gateway in front of Lustre** — gives up most of the parallel-IO benefit; only do this if you're hitting Lustre rarely and want operational simplicity.
- **Chosen path:** option 1 (DDN CSI) for the orchestration layer is locked in. Kernel-module delivery starts at option 2 (rpm-ostree layered module) and falls back to option 3 (driver-container DaemonSet) only if FCOS-kernel churn at OKD upgrade time becomes operationally painful. OKD-Infra does not need Lustre.

**Open sub-decision:** which workloads land on FlashArray vs FlashBlade. Mostly determined by RWX needs and IO profile; settle when the first workloads are scoped.

### G-3 — Container registry strategy
OKD ships an internal registry (operator-managed) that defaults to `emptyDir` (i.e., useless). It needs persistent backing. Separately, for B200 inference images (often 5–15 GB each), a pull-through cache to your enterprise registry is strongly advised to avoid pulling from Docker Hub / NGC repeatedly.

### G-4 — Identity / OAuth integration — Active Directory

**Decision:** AD is the identity source for both clusters. Two integration shapes still on the table:

| Option | Pros | Cons |
|---|---|---|
| **OKD OAuth → LDAP (direct AD bind)** | Simplest path; no extra infra; well-trodden in OKD | Per-cluster bind config; group sync needs the `groupsync` operator/CronJob; password policy + lockout flows live in AD only |
| **OKD OAuth → OIDC → Keycloak (Red Hat SSO) → AD** | Single SSO surface for many platforms; richer claim/group mapping; MFA orchestration; future-proof for non-AD IdPs | Extra component to run + back up; first-time effort to stand up Keycloak in HA |

Recommendation: **OIDC via Keycloak** if you have or plan to have more than one or two platforms integrating with AD. **Direct LDAP** if OKD is and will remain the only consumer. For an enterprise Red Hat shop with growing platform count, Keycloak usually wins within 12–18 months.

In either case:
- Service account in AD for the bind (least-privilege OU read).
- Group sync configured so OKD RBAC can reference AD groups.
- `htpasswd` identity provider stays only as a break-glass admin path, on a separate provider name.

### G-5 — Monitoring / logging / alerting
OKD ships cluster-monitoring (Prometheus, Alertmanager, Grafana) and cluster-logging (optional). Where do alerts go? PagerDuty? Email? Where do logs go long-term? These need PVs and external sinks; not free.

### G-6 — Air-gap / disconnected install posture
Are these clusters internet-connected, proxied, or fully disconnected? OKD installs and ongoing operator updates assume access to Quay.io and other registries unless you mirror. RHEL shops often go disconnected; if you do, plan a mirror registry (`oc-mirror`) and offline operator catalog.

### G-7 — Secrets management
Sealed Secrets, External Secrets Operator + Vault, or native? Decide before workloads land.

### G-8 — Network ingress for workloads
Default Ingress Controller on `*.apps.<cluster>` is fine for HTTP. If GPU inference exposes gRPC at scale, plan for an ingress that does HTTP/2 properly (HAProxy router does, but tuning is non-trivial), or run a dedicated gateway (Envoy / Istio / Gateway API).

### G-9 — Capacity planning
Worker count is "TBD". For early planning, even a target range (e.g., infra: 4–8 nodes, GPU: 4 B200 hosts × 8 GPU = 32 GPUs) lets you size LB VMs, IP space, and storage. Pin a starting number even if it's wrong; revise.

### G-10 — Change management / promotion
Two clusters and a future third — how are workload manifests promoted? GitOps with ArgoCD or Flux? Per-cluster app-of-apps? This is a Phase-4 question but the answer constrains how Rancher's projects/RBAC are structured.

---

## 13. Open Questions for the Next Iteration

**Resolved in v0.2 (2026-04-24):**
- ~~LB option~~ → Kemp LoadMaster (Section 5.2).
- ~~Storage option~~ → Pure Storage + Lustre (G-2).
- ~~Identity provider~~ → Active Directory (G-4); LDAP-direct vs OIDC-via-Keycloak still TBD.

**Still open:**
1. Confirm DR-1 (collapse separate etcd tier into masters) before any VM provisioning.
2. DR-2: worker OS + Puppet role on OKD nodes. Pending user reading — reading links in §DR-2. Current lean is Option A (SCOS workers, MCO-managed; Puppet retained for non-OKD hosts).
3. Pick install method (agent-based vs UPI) from Section 3.2.
4. Define DR-4 (mirror cluster purpose: DR vs active-active vs overflow).
5. Worker count targets per cluster (Gap G-9).
6. Disconnected vs connected install (Gap G-6).
7. AD integration shape: direct LDAP vs OIDC-via-Keycloak (G-4 sub-decision).
8. Lustre kernel-module delivery on FCOS: rpm-ostree layered package (default) vs driver-container DaemonSet (fallback). Storage-orchestration layer is locked to DDN CSI. Gates the OKD-GPU worker template.
9. Pure FlashArray vs FlashBlade role split (G-2 sub-decision) — settle alongside first workloads.

When the still-open items are answered, this document graduates from v0.2 draft to v1.0 baseline.
