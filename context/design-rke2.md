# Multi-Cluster RKE2 Infrastructure — Design Document (Alternative)

**Status:** Draft v0.9 — for iteration alongside `design.md` (the OKD variant)
**Date:** 2026-05-01

> **⚠ Architecture supersession notice (v0.9):** several major decisions in
> this document have been replaced during build-out. **For current canonical
> answers consult these docs first; this design doc is a historical record:**
>
> - **Cilium data plane**: VXLAN encapsulation, NOT native routing. See
>   `kemp-cilium-routing.md`. (Replaces §3.4 native-routing assumptions
>   and §5.5 Connection Manager static-route configuration.)
> - **In-cluster ingress**: Cilium Gateway API. See `kemp-cilium-routing.md`.
>   (Replaces RDR-7 / Kemp Connection Manager Ingress Controller. The
>   `*.apps.<cluster>.<base>` Kemp VIP is no longer part of the design.
>   `rke2-ingress-nginx` stays disabled.)
> - **Kemp's role**: L4 TCP passthrough only — kube-apiserver (6443) and RKE2
>   supervisor (9345). Optional per-service external relay VIPs may be added
>   later; WAF deferred per-service. See `kemp-vip-design.md`.
> - **Pod / service CIDRs**: 192.168.0.0/16 carved into /20 pairs per cluster,
>   not 10.40.0.0/18. See `cidr-plan.md`. (Replaces §3.4 CIDR allocation table.)
> - **Underlay network**: pod traffic and etcd peer traffic ride the high-speed
>   VM network (`<host>-vm.ufhpc`, ens224, MTU 9000); management traffic
>   (kubectl, Kemp VIP) stays on the mgmt network (ens192, 172.16.192.0/24).
>
> Sections in this doc that reference RDR-7, Cilium native routing, the
> 10.40.x.x CIDR space, or `*.apps.<cluster>.<base>` Kemp ingress are
> superseded. The decision rationale they captured is preserved here as
> history; the operational truth lives in the per-topic docs above.

**Changes since v0.8:** Architecture supersession notice added (above):
RDR-7 retired in favor of Cilium Gateway API; Cilium switched to VXLAN
encapsulation; CIDR space changed to 192.168.0.0/16; underlay split between
mgmt (ens192) and high-speed VM (ens224) networks formalized.
**Changes since v0.7:** Added §3.1.1 — server-node redundancy planning per cluster. Etcd quorum math reference table (3 = 1 failure, 5 = 2 failures, 7 = 3 failures, with maintenance-window-safety column). Per-cluster lean captured: **5 / 3 / 3 for mgmt / infra / GPU.** Asymmetry rationale documented (platform tier durable, workload tier disposable). Triggers for bumping GPU to 5 listed. Install-flow updated to reference variable server count.
**Changes since v0.6:** **RDR-7 architecture corrected after PDF review of the actual Connection Manager Ingress Controller documentation.** Major correction: there is **no in-cluster Ingress Controller pod** — the controller is an **add-on installed on the Connection Manager itself** that polls K8s API directly via uploaded kubeconfig. **TLS cert flow corrected:** certs uploaded to CM by name and referenced via `kemp.ax/certfile` annotation. Added §5.5 — Connection Manager static-route configuration for pod CIDRs (Cilium native-routing mode required).
**Changes since v0.5:** RDR-7 added: Kemp Ingress Controller adopted for L7 ingress; ingress-nginx removed from workload clusters. §3.3 RKE2 config updated (`disable: rke2-ingress-nginx`, `disable-kube-proxy: true`). §5.2 Kemp VS table split into L4 (kube-apiserver/registration) and L7. §5.3 DNS section expanded with wildcard pattern.
**Changes since v0.4:** Consolidated platform tier on the mgmt cluster — **RDR-3 (Harbor) and RDR-4 (Keycloak) resolved as in-cluster on mgmt RKE2.** Mgmt cluster sized to **5 nodes at 8/32/200** for 2-failure tolerance + maintenance-window safety. §1.1 architecture diagram, §4.1 sizing, §4.1.1 platform-tier workloads, §7 backup, §8 failure matrix, §9 Phase 1 deployment order all updated for the consolidated tier.
**Changes since v0.3:** §3.4 rewritten as a full CNI section. **RDR-2 resolved: Cilium on both clusters.**
**Changes since v0.2:** §6.3 — clarified that the SIGHUP/RKE2-restart impact is scoped to GPU-bearing agent nodes only.
**Changes since v0.1:** §6.3 corrected — the GPU Operator's containerd SIGHUP happens on upgrades that bump the toolkit image, not only on first install.
**Scope:** Same target as `design.md` — two workload clusters (general infra + GPU inference on B200/B300; future mirror) with Foreman-driven RHEL provisioning, Puppet config, Rancher multi-cluster management, Pure Storage + DDN Lustre, Kemp LB, AD identity. The variable here is the Kubernetes distribution: **RKE2 instead of OKD**.

> Read `okd-vs-rke2.md` first. This doc and `design.md` should be compared as alternatives; pick one to take forward.

---

## 1. Architecture Overview

### 1.1 Layering

```text
┌──────────────────────────────────────────────────────────────────────────┐
│  Layer 0 — Provisioning & Lifecycle                                      │
│  Foreman + Katello + Puppet (existing, unchanged)                        │
│   - PXE / DHCP / TFTP for bare-metal                                     │
│   - Kickstart for RHEL                                                   │
│   - Katello content lifecycle (inc. RKE2 channel + DDN Lustre repo)      │
│   - Puppet for ALL RHEL hosts (mgmt VMs, RKE2 servers, RKE2 agents)      │
└────────────┬─────────────────────────────────────┬───────────────────────┘
             │ provisions HW                       │ provisions HW
             ▼                                     ▼
┌────────────────────────────┐         ┌──────────────────────────────────┐
│  Layer 1a — Bare metal     │         │  Layer 1b — VMware vSphere       │
│                            │         │  (existing)                      │
│  RKE2 agents (RHEL):       │         │                                  │
│   - rke2-infra-agents ×N   │         │  RKE2 servers (RHEL):            │
│   - rke2-gpu-agents ×N     │         │   - rke2-mgmt-srv-{1..5}  ×5     │
│     (L40 / B200 / B300)    │         │   - rke2-infra-srv-{1..3} ×3     │
│                            │         │   - rke2-gpu-srv-{1..3}   ×3     │
│                            │         │                                  │
│                            │         │  Support VMs (RHEL):             │
│                            │         │   - bastion / install host       │
└────────┬───────────────────┘         └─────────────┬────────────────────┘
         │ join via fixed registration               │
         │ endpoint (Kemp VIP : 9345)                │
         └──────────────────┬────────────────────────┘
                            ▼
        ┌────────────────────────────────────────┐
        │  Layer 2 — Workload clusters           │
        │   - RKE2-Infra (general workloads,     │
        │       future home for KubeVirt)        │
        │   - RKE2-GPU   (B200/B300 inference)   │
        │   - RKE2-GPU-2 (future mirror)         │
        └─────────────────┬──────────────────────┘
                          │ provisioned + lifecycled by
                          ▼
        ┌────────────────────────────────────────┐
        │  Layer 3 — Mgmt + platform tier        │
        │   Single 5-node RKE2 cluster hosting:  │
        │   - Rancher (multi-cluster mgmt)       │
        │   - Keycloak (OIDC IdP, AD broker)     │
        │   - CloudNativePG (Postgres for KC+HB) │
        │   - Harbor (registry, S3 → FlashBlade) │
        │   - Redis (Harbor sessions/cache)      │
        │   - ingress-nginx + cert-manager       │
        │   - cluster-monitoring                 │
        │  Sized for 2-failure tolerance + safe  │
        │  rolling upgrades.                     │
        └────────────────────────────────────────┘
```

### 1.2 Design tenets (unchanged from `design.md`)

- Strict separation of concerns by layer.
- Each cluster is self-sufficient — workloads keep running if Rancher, Foreman, or Puppet are simultaneously offline.
- VMs for control, bare metal for workload.
- Stay Red Hat where it pulls weight, leave where it doesn't. **In this variant, the host OS is RHEL everywhere — the K8s distribution is the only non-Red-Hat piece.**

### 1.3 What changes vs. the OKD design

| Area | OKD design | RKE2 design |
|---|---|---|
| Worker OS | FCOS / SCOS | RHEL 9 |
| Worker config system | Machine Config Operator | **Puppet** (unchanged from rest of fleet) |
| Cluster install | `openshift-install` agent-based | RKE2 binary + Rancher provisioning |
| Cluster lifecycle | OKD CVO (Rancher imports only) | **Rancher full lifecycle** |
| Image registry | OKD internal registry (operator) | **Harbor** (external or in-cluster) |
| OAuth / IdP | OKD OAuth → AD LDAP | **Keycloak** (OIDC) → AD |
| Ingress | OpenShift Router (HAProxy) | ingress-nginx (RKE2 default) |
| Monitoring | cluster-monitoring operator | `kube-prometheus-stack` (Helm) |
| Logging | OKD cluster-logging operator | Loki + Promtail (Helm) |
| Pod security | SCCs | PSA + Kyverno or Gatekeeper |
| Etcd backup | Manual CronJob | **Default 2×/day, S3 upload** |
| Lustre kernel module | KMM / rpm-ostree layered | **Puppet `dnf install` (DDN repo)** |
| GPU drivers | GPU Operator (containerized) | GPU Operator (containerized) |

---

## 2. Foreman / Katello / Puppet Responsibilities

### 2.1 In scope — the OS↔Rancher boundary

The OS layer (Foreman/Katello/Puppet) stops at "host is ready to receive a Kubernetes install." The Kubernetes layer (Rancher) takes over from there. Puppet does **not** install the RKE2 binary, manage RKE2 versions, or touch cluster lifecycle — those are Rancher's responsibility via the registration command and system-upgrade-controller (SUC).

| Target | OS | Provisioning method | Puppet's role (via `ufrc_rke2` module) |
|---|---|---|---|
| RKE2 servers (all clusters) | RHEL 9 | Foreman kickstart | Base hardening + RKE2 prereqs (sysctls, firewalld, `rke2-selinux`, kernel modules) + config drop-in at `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` + one-shot Rancher registration exec |
| RKE2 agents (bare-metal workers) | RHEL 9 | Foreman kickstart | Same as servers + DDN Lustre client (infra/GPU agents) + NVIDIA repo (GPU agents only — driver itself comes from GPU Operator) |
| Bastion / install host | RHEL 9 | Foreman kickstart | kubectl, helm, rancher CLI, jq, **pdsh** (used by `bootstrap-cluster.sh`) |

Keycloak and Harbor are no longer Puppet-managed hosts — they run as Helm charts inside the mgmt RKE2 cluster (per RDR-3 and RDR-4).

### 2.2 Out of scope

- **RKE2 binary install** — done by Rancher's registration `curl|sh`, not by Puppet.
- **RKE2 version pinning and upgrades** — owned by the Rancher Cluster CR (`spec.kubernetesVersion`); SUC drives node-by-node rolling upgrades.
- **In-cluster Kubernetes objects** — Foreman/Puppet do not modify K8s resources; that's GitOps territory.
- **Cluster identity** (token, server URL, node-name) — supplied by Rancher's registration drop-in at `config.yaml.d/50-rancher.yaml`, not by Puppet hiera.

### 2.3 Integration points

- **Katello content view for the DDN Lustre client repo** (so `dnf install ddn-lustre-client` works on agents). No RKE2-related content views — RKE2 binary install is sourced directly from `get.rke2.io` via the Rancher registration `curl|sh` (not air-gapped, direct internet access available).
- **`ufrc_rke2` Puppet module** — custom thin module (3 manifest classes: `prereqs`, `config`, `register`), no upstream Forge dependency. Both candidate Forge modules (lsst-rke2 and etma-rke2) were evaluated and rejected; rationale captured in §3.2.
- **`bootstrap-cluster.sh`** on the bastion — bash + pdsh + Rancher API. Fetches the registration command for the target cluster+role from Rancher, pdsh's it to the matching genders host group. Designed for reuse across future cluster builds, not just the initial three.
- **Hostname/IP allocation** — Foreman is source of truth for RKE2 node hostnames and IPs.
- **Fixed registration address** — Kemp VIP that all servers + agents register against (port 9345). Same Kemp box used for the cluster's API VIP (6443).

---

## 3. RKE2 Cluster Architecture (per cluster)

### 3.1 Topology

| Role | Placement | OS | Sizing (starting point) |
|---|---|---|---|
| Server (control plane + etcd) | VMware | RHEL 9 | 8 vCPU / 16 GiB / 120 GiB SSD (or 4 vCPU / 16 GiB / 100 GiB if servers are tainted control-plane-only) |
| Agent (worker) | Bare metal | RHEL 9 | infra: TBD; GPU: B200/B300/L40 hosts |

Server count is per-cluster — see §3.1.1 for the redundancy math and the current per-cluster lean.

> Note: RKE2's standard topology co-locates etcd on the server nodes. Splitting etcd to a separate tier is *technically* supportable in RKE2 (set `disable-etcd: true` on agents and run etcd-only servers), but it's the same answer as DR-1 in the OKD doc — the supported and overwhelmingly common path is etcd on the servers. Not recommended to split unless a specific pain point shows up.

### 3.1.1 Server-node redundancy planning (cluster-by-cluster)

**Etcd quorum math reminder:**

| Server count | Quorum needed | Failures tolerated | Maintenance-window safety (drain 1 → tolerate during the window) |
|---|---|---|---|
| 1 | 1 | 0 | n/a |
| **3** | 2 | **1** | 0 (drain 1 → 2 left → next failure = quorum loss) |
| **5** | 3 | **2** | 1 (drain 1 → 4 left → still 1-failure-tolerant) |
| **7** | 4 | **3** | 2 (drain 1 → 6 left → still 2-failure-tolerant) |

**Always odd numbers.** Even sizes don't improve fault tolerance — a 4-node cluster has the same quorum (3) as a 5-node cluster but more failure surface; a 6-node has the same quorum (4) as a 7-node. RKE2 will let you do an even count; it's just operationally pointless.

**Current per-cluster lean: 5 / 3 / 3 (mgmt / infra / GPU)**

| Cluster | Server count | Failures tolerated | Maintenance-window safety | Rationale |
|---|---|---|---|---|
| **Mgmt RKE2** | **5** | 2 | Survives 1 failure during a node-drain | Platform tier — recovery is hard (etcd snapshot restore + reload Keycloak/Harbor/CNPG state). Worth maximum reasonable redundancy. |
| **RKE2-Infra** | **3** | 1 | Vulnerable during node-drain windows | Workload tier — disposable; ClusterClass rebuild via Rancher + ArgoCD reconcile is the recovery path; ~hours, mostly automated. |
| **RKE2-GPU** | **3** | 1 | Vulnerable during node-drain windows | Same disposable framing; bumps to 5 only if inference SLA tightens or GPU mirror cluster isn't yet active-active. Server-count change is hours, not days — node-add operation, not rebuild. |
| **RKE2-GPU-2** (future mirror) | TBD: 3 if DR/standby; match primary if active-active | 1 or 2 depending | per primary | Decision deferred per DR-4. |

**Why the asymmetry is right:** the 5-node bump for mgmt is *targeted* — it's paid for by the recovery-cost asymmetry between the platform tier (state-bearing, hard to restore) and the workload tier (stateless from the cluster's perspective; rebuild path well-trodden via ArgoCD). Five-everywhere is uniform-but-wasteful; three-everywhere is uniform-but-fragile-on-mgmt; **5/3/3 is asymmetric-but-correct.**

**Triggers to revisit and bump GPU to 5:**

- Inference SLA tightens (customer-facing, time-bound, revenue-bearing).
- GPU mirror is not in place or is DR-only (so no failover capacity during primary outage).
- A specific incident or near-miss demonstrates the 1-failure-tolerance gap is real.

**The transition from 3 → 5 server nodes** doesn't require a rebuild. RKE2 supports adding server nodes to an existing cluster via `rke2-server` join. Plan for ~half-day per server added; serial roll to maintain quorum throughout.

**Do NOT scale down server nodes (5 → 3) on a running cluster** without careful etcd member-removal procedure. Easier to never have to.

### 3.2 Install flow

1. **Foreman** PXE-installs RHEL 9 on the cluster's server VMs (5 for mgmt, 3 for infra/GPU per §3.1.1).
2. **Puppet (`ufrc_rke2` module)** applies base profile + RKE2 prereqs: sysctls (`net.ipv4.ip_forward`, `br_netfilter`, `vm.max_map_count`), firewalld rules (6443, 9345, 10250, 4240, 8472), kernel modules (overlay, br_netfilter). **SELinux is disabled cluster-wide per fleet practice (see §3.3) — no `rke2-selinux` package required.** Renders `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` from a hiera hash (`stdlib::to_yaml`) — drop-in style, doesn't touch other files in `.d/`. Hash carries `cni: cilium`, `disable-kube-proxy: true`, `disable: [rke2-ingress-nginx]`, `profile: cis`, tls-san additions, node-labels, cluster/service CIDRs. **Token, server URL, and node-name are NOT here** — they come from Rancher.
3. **Operator** creates the Cluster CR in Rancher with target `kubernetesVersion: v1.35.4+rke2r1` (current pin, see §11 RDR-8). Rancher generates registration commands per role (seed-server / additional-server / agent).
4. **Operator** runs `bootstrap-cluster.sh <cluster> seed` from the bastion. Script calls Rancher API to fetch the seed-server registration command, pdsh's it to the genders group `<cluster>-seed` (one host). The script forces `INSTALL_RKE2_METHOD=tar` (binary install at `/usr/local/bin/rke2`) — see §3.2 install-method note. The registration command writes the cluster identity drop-in to `/etc/rancher/rke2/config.yaml.d/50-rancher.yaml`. RKE2 starts with both Puppet's and Rancher's drop-ins merged.
5. **Operator** runs `bootstrap-cluster.sh <cluster> server` once the seed is Active in Rancher UI. Script fetches the additional-server registration command and pdsh's it to the `<cluster>-server` genders group. Servers join serially via the Kemp VIP at port 9345.
6. **Operator** runs `bootstrap-cluster.sh <cluster> agent` for clusters with separate agent nodes (infra and GPU; mgmt has no agents). Same flow, different registration command.
7. **Day-2 RKE2 binary upgrades** are driven by Rancher's `system-upgrade-controller` — bump `kubernetesVersion` in the Cluster CR; SUC drains and replaces nodes one at a time. Puppet does NOT touch RKE2 versions; `ufrc_rke2::register` is idempotent (gated on existing etcd data) so repeat agent runs are no-ops.

#### Install method: binary (tarball), not RPM

`get.rke2.io` defaults to RPM install on RHEL family, but Rancher's `system-upgrade-controller` does NOT use `dnf` to upgrade RPM-installed nodes — it overwrites the binary at `/usr/bin/rke2` with a fresh download, leaving the RPM database stale (`rpm -q rke2-server` reports the install-time version while `rke2 --version` reports the upgraded version, and `rpm -V` flags the binary as modified). See [rancher/rke2#661](https://github.com/rancher/rke2/issues/661) for the open RFE.

To avoid the RPM-database-divergence problem, `bootstrap-cluster.sh` forces `INSTALL_RKE2_METHOD=tar` when invoking the registration command. RKE2 binary lands at `/usr/local/bin/rke2`; SUC upgrades the same path. RPM database is not used to track RKE2 — Rancher Cluster CR's `kubernetesVersion` is the single source of truth for cluster version state.

#### Why a custom `ufrc_rke2` module instead of a Forge community module

Both candidate Forge modules were evaluated and rejected:

- **lsst-rke2** — RPM-only install, no binary path. Worse, it actively *deletes* `/etc/rancher/rke2/config.yaml.d/` to enforce single-source-of-truth at full `config.yaml`. That would actively break Rancher's registration drop-in pattern.
- **etma-rke2** — supports binary install and uses the drop-in pattern (right *shape*) but the config template is hardcoded to a small fixed set of keys and can't render `cni`, `disable-kube-proxy`, `profile: cis`, etc. Has a Ruby syntax bug at `@max-pods` in the template. REFERENCE.md still references "k3s." Last commit September 2023. Puppet 4–7 only in metadata.

The right shape (drop-in pattern + binary install) is taken; the implementation is custom: ~80 lines across `ufrc_rke2::{prereqs,config,register}` with `stdlib::to_yaml(lookup('rke2_config', merge => deep))` for free-form config rendering. No upstream module dependency.

### 3.3 RKE2 configuration choices

Configuration is split between **Puppet's drop-in** at `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` (rendered by the `ufrc_rke2` module from a hiera hash) and **Rancher's drop-in** at `/etc/rancher/rke2/config.yaml.d/50-rancher.yaml` (written by the registration command). RKE2 merges all files in `config.yaml.d/` lexicographically at startup.

**Puppet's drop-in (cluster-wide preferences, baseline):**

```yaml
profile: cis                       # CIS Kubernetes Benchmark — kubelet/apiserver hardening
selinux: false                     # SELinux disabled cluster-wide; matches fleet practice — see SELinux note below
write-kubeconfig-mode: "0640"
tls-san:
  - <cluster-api-fqdn>
  - <kemp-vip-address>
cni: cilium                        # decided per RDR-2; default would be canal
disable-kube-proxy: true           # Cilium kubeProxyReplacement enabled
disable:
  - rke2-ingress-nginx             # Kemp Ingress Controller handles L7 — see §5.2 and RDR-7
cluster-cidr: 10.40.0.0/20         # unique per cluster (must be L3-reachable from Kemp data-path) — see §3.4 for allocation table
service-cidr: 10.41.0.0/22
node-label:
  - "topology.kubernetes.io/region=onprem-dc1"
```

**SELinux disabled — rationale:** Matches existing fleet practice (other K8s clusters in the environment run SELinux disabled). The CIS Kubernetes profile (`profile: cis`) is K8s-component hardening (kubelet flags, apiserver flags, RBAC, audit) and does NOT require host-level SELinux — that's the CIS RHEL Benchmark, a separate document. Concrete reasons specific to this build for keeping SELinux off: pods on the GPU cluster will mount Lustre (DDN client) for training data + scratch + checkpoints — SELinux contexts on Lustre paths are unproven and would surface as AVC denials inside containers; HPC researchers bring custom workloads (pytorch/Singularity-converted images, conda envs) where AVC denials present as silent CrashLoopBackOff with no obvious cause; GPU Operator's driver/toolkit pods plus RDMA device access (/dev/infiniband/*, /dev/nvidia*) add additional SELinux surface that's worth its weight only when paired with SELinux-fluent operations. Security boundary lives elsewhere: image scanning at Harbor, Cilium NetworkPolicy, namespace isolation, Kyverno (RDR-5), AD-based access. SELinux on the K8s nodes would be belt-and-suspenders against threats those layers already cover, while creating a permanent "this cluster is different" footnote in operations.

**Rancher's drop-in (cluster identity, written by registration `curl|sh`):**

```yaml
# Example shape — actual content generated by Rancher per cluster/role
server: https://<kemp-vip>:9345    # join address
token: <rancher-managed-token>     # cluster registration token
node-name: <foreman-fqdn>
```

**Why split this way:** Puppet owns cluster-wide *preferences* (CNI, hardening, network ranges); Rancher owns cluster *identity* (where to join, who I am). Neither needs to know about the other's keys. Puppet hiera does NOT carry the token or server URL — that decoupling is what lets the same Puppet code apply across mgmt/infra/GPU/future-clusters without per-cluster secret management on the Puppet side.

CIS profile is automatically applied by RKE2 when set — no separate hardening pass needed.

### 3.4 Networking inside the cluster — CNI choice

**Decision:** **Cilium on both clusters.** Rationale: one technology to learn and operate across the fleet rather than two different CNIs with two different troubleshooting toolboxes. The GPU cluster needs eBPF-based observability for inference debugging anyway; standardizing on Cilium for the infra cluster too means the operational muscle built once applies everywhere. The marginal complexity of running Cilium on the infra cluster is small relative to the cost of running two CNIs.

#### What RKE2 offers

Per the [RKE2 Networking docs](https://docs.rke2.io/networking/basic_network_options), RKE2 bundles four primary CNIs (plus Multus as a secondary):

| CNI | What it is | Default? |
|---|---|---|
| **Canal** | Flannel for inter-node overlay + Calico for intra-node and NetworkPolicy. VXLAN-based. Hybrid for historical reasons. | **Default** |
| **Calico** | Full CNI: networking + NetworkPolicy. Multiple data planes (IPIP, VXLAN, BGP, eBPF). | Optional |
| **Cilium** | eBPF-based data plane. Replaces kube-proxy. Identity-based and L7-aware policy. Hubble observability built in. Requires kernel ≥ 4.9.17 (RHEL 9 fine). | Optional |
| **Flannel-only** | Overlay only — **no NetworkPolicy support.** | Optional |

#### How they actually differ

**Flannel** is a network plane only — VXLAN encapsulation between nodes, no policy enforcement. Kubernetes NetworkPolicy resources are silently ignored. Not appropriate for production.

**Calico** is a full CNI: networking, IPAM, NetworkPolicy enforcement. Multiple data plane choices — IPIP/VXLAN overlays, BGP if you have BGP-capable fabric, or its own eBPF data plane. Policy enforcement via iptables (default) or eBPF.

**Canal** is the historical hybrid: Flannel for the overlay (simple, well-tested VXLAN) plus Calico for NetworkPolicy enforcement. RKE2's default because it gives working overlay + working NetworkPolicy with minimum friction. Practically equivalent to "VXLAN with NetworkPolicy support — no fancy features."

**Cilium** is architecturally different. Its data plane runs as eBPF programs in the Linux kernel, bypassing iptables/conntrack/kube-proxy entirely. From the [Cilium overview](https://docs.cilium.io/en/stable/overview/intro/):

> "East-west load balancing fully replaces kube-proxy through socket-level connection rewrites, avoiding per-packet NAT overhead."
> "Identity-based security removes reliance on brittle IP addresses ... L7-aware policies enabling granular filtering like 'Allow only GET requests to /public/.*'."

What Cilium gives you that Canal does not:

- **kube-proxy replacement** in eBPF — service load balancing is O(1) map lookups in the kernel, not O(n) iptables rule scans. Scales materially better as service count grows (matters for inference fleets with many model-serving services).
- **Identity-based NetworkPolicy** — policies attach to pod labels/identity rather than IP addresses. IP churn during pod restarts doesn't break policy.
- **L7-aware policy** — enforce HTTP method/path, gRPC service/method, Kafka topic, DNS without a service mesh.
- **Hubble observability** (see below).

#### What "eBPF-based observability" means

eBPF (extended Berkeley Packet Filter) lets small, sandboxed programs run inside the Linux kernel at specific hook points (packet receive, syscall entry, function call) **without** patching the kernel or loading kernel modules. Key properties:

- Runs in kernel space — no copy-to-userspace overhead per event.
- Verified before load — eBPF verifier proves the program won't crash the kernel or loop forever.
- Hot-loaded — no reboot, no module rebuild.
- Per-event Kubernetes context — pod, namespace, labels, container ID — available without ptrace/sidecar overhead.

Why it matters for networking: traditional tools like iptables scan packets sequentially through a rule list. eBPF runs as compiled bytecode at specific hooks with O(1) map lookups. Same observation depth at orders of magnitude less overhead.

[Hubble](https://github.com/cilium/hubble), Cilium's observability layer, taps the eBPF event stream and surfaces:

- **Per-flow records with Kubernetes identity** — not "10.42.3.5 → 10.42.7.12" but `payments/api → orders/db` with namespaces, labels, and the policy verdict (allowed / denied / dropped, plus *which* policy triggered the verdict).
- **Service map** — auto-generated graph of cluster service dependencies, derived from observed flows. Useful for debugging "why is this slow" or "did my new policy break traffic."
- **L7 visibility** — HTTP method/path, gRPC method, DNS query, Kafka topic. Filter flows like `hubble observe --protocol http --to-namespace inference`.
- **Drop/deny visibility** — exact policy and 5-tuple for every dropped flow, so policy debugging stops being guesswork.

Architecture: Hubble server runs in the Cilium agent on each node (gRPC API). Hubble Relay aggregates across nodes into one cluster-wide endpoint. Hubble CLI and UI consume the relay.

#### Costs of the Cilium-on-both decision

To be honest about the trade-offs:

- **Steeper learning curve than Canal.** Troubleshooting eBPF takes different mental models than iptables. `cilium monitor` and Hubble flows replace `iptables -L -n`. Plan for a couple weeks of team ramp.
- **More moving parts.** Cilium agent + Hubble server + Hubble Relay (+ optional UI) on every cluster.
- **Kernel version sensitivity.** Cilium feature availability tracks kernel version. RHEL 9 is fine; pay attention if you ever pin to an older kernel for some compatibility reason.
- **Fewer Stack Overflow answers.** Canal/iptables troubleshooting has a decade of community knowledge; Cilium's community is large but newer.

These are real but they're one-time costs. Operating two CNIs forever — different config syntax, different troubleshooting, different policy idioms — is the recurring cost the unified-on-Cilium decision avoids.

#### Configuration

Set in `/etc/rancher/rke2/config.yaml` per cluster (replaces the `cni: canal` line shown in §3.3):

```yaml
cni: cilium
```

For Cilium-specific tuning (kube-proxy replacement, Hubble enable, etc.), use Rancher's HelmChartConfig override or a Cilium values file passed via the RKE2 manifests directory. Recommended initial values:

```yaml
# cilium values
kubeProxyReplacement: true     # full kube-proxy replacement; disable rke2-kube-proxy
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
ipam:
  mode: cluster-pool
```

When `kubeProxyReplacement: true` is set, also disable RKE2's bundled kube-proxy in the cluster config:

```yaml
disable-kube-proxy: true
```

#### Pod / Service CIDRs

Per-cluster, non-overlapping with anything else. **RKE2 defaults are `10.42.0.0/16` (pods) and `10.43.0.0/16` (services) — far oversized for our node counts.** With Cilium's default `/24` per node, a `/16` cluster CIDR supports 256 nodes; we plan for at most ~7 nodes per cluster today with reasonable growth headroom. Sizing each cluster at `/20` (16 nodes) is the right balance.

| Cluster | Pod CIDR | Service CIDR | Nodes today | Cap at /20 |
|---|---|---|---|---|
| RKE2-Mgmt | `10.40.0.0/20` | `10.41.0.0/22` | 5 | 16 |
| RKE2-Infra | `10.40.16.0/20` | `10.41.4.0/22` | 7 | 16 |
| RKE2-GPU | `10.40.32.0/20` | `10.41.8.0/22` | 7 | 16 |
| RKE2-GPU-2 (future) | `10.40.48.0/20` | `10.41.12.0/22` | TBD | 16 |

Total reserved: `10.40.0.0/18` for pods, `10.41.0.0/20` for services across the four-cluster fleet.

**Why the per-node `/24` stays even though clusters shrink:** Cilium's `cluster-pool` default of `/24` per node (256 IPs) supports kubelet's default 110 pods/node with headroom. Shrinking to `/25` per node caps pod density at ~110 forever; not worth the savings.

**No CIDR collisions across clusters** is a hard requirement — Kemp's routing table can't have two next-hops for the same destination network. The `/20` per cluster within `10.40.0.0/18` makes this collision-free by construction.

#### MTU

Plan for jumbo frames (9000) on the GPU fabric VLAN if multi-node inference uses RDMA; pod-network MTU offset accordingly. Cilium handles MTU detection automatically per interface but you can pin via `MTU` Helm value if needed.

### 3.5 Required cluster endpoints

| FQDN | Port | Purpose |
|---|---|---|
| `api.<cluster>.<base>` | 6443/TCP | kube-apiserver (used by `kubectl`, Rancher) |
| `api.<cluster>.<base>` | 9345/TCP | RKE2 server-registration port (used by joining nodes) |
| `*.apps.<cluster>.<base>` | 80/443 TCP | Workload ingress (ingress-nginx, or Kemp L7) |

DNS records for `api.<cluster>.<base>` and `*.apps.<cluster>.<base>` are required from every node and from Rancher.

---

## 4. Rancher (Management Cluster)

### 4.1 Sizing — 5 nodes for 2-failure tolerance

**5 RHEL VMs on VMware, each 8 vCPU / 32 GiB / 200 GiB SSD.**

Why 5 instead of 3:

- **2-failure tolerance.** 5-node etcd quorum is 3-of-5; the cluster survives 2 simultaneous server losses. With 3 nodes, quorum is 2-of-3 — surviving 1 failure only.
- **Maintenance-window safety is the more important reason.** With 3 nodes, draining 1 for OS patching or RKE2 upgrade leaves 2 healthy → any other failure during the maintenance window (network blip, hardware fault, hung pod) takes the cluster down. With 5 nodes, drain 1 → 4 healthy → still 1-failure-tolerant during the window. You can do unattended rolling upgrades without sweating.
- **Workload-capacity reasoning is secondary.** The platform-tier services (Rancher + Keycloak + CloudNativePG + Harbor + Redis + ingress + monitoring) easily fit on 1 node, much less 5. The 5-node sizing is for fault tolerance + headroom, not raw capacity.

Pure FlashArray (RoCE 400/800G with redundant connections) means storage I/O is not a constraint at this scale; etcd's fsync latency stays well within budget even with concurrent Postgres + Harbor workload. No I/O isolation requirement, so consolidating all platform services on the 5-node mgmt cluster is safe.

### 4.1.1 Platform-tier workloads on the mgmt cluster

The 5-node mgmt cluster hosts the entire platform tier. **No dedicated VMs for Keycloak, Harbor, Postgres, or Redis** — they all run as in-cluster workloads.

| Workload | Replicas | Approx footprint | Storage |
|---|---|---|---|
| Rancher | 3 | 2 vCPU / 4 GiB | n/a |
| Keycloak | 2 | 2 vCPU / 4 GiB | n/a (DB on CloudNativePG) |
| CloudNativePG (Postgres operator + cluster) | 3 (operator + 3 PG replicas) | 1.5 vCPU / 6 GiB | Pure FlashArray block PV (`pure-block` SC), ~50 GiB |
| Harbor (core, registry, jobservice, portal, trivy) | 2 each | 2 vCPU / 6 GiB | **Image data on FlashBlade S3**; small PVs for Postgres + Redis only |
| Redis (Bitnami chart, single instance) | 1 | 0.5 vCPU / 2 GiB | Pure FlashArray block PV, ~10 GiB |
| ingress-nginx (RKE2 default) | 2 | 0.5 vCPU / 1 GiB | n/a |
| cert-manager | 1 | 0.2 vCPU / 0.5 GiB | n/a |
| cluster-monitoring (kube-prometheus-stack) | varies | 4 vCPU / 8 GiB | Pure FlashArray block PV, ~100 GiB |
| **Aggregate (steady state)** | | **~13 vCPU / 32 GiB** | ~160 GiB block + image data on FlashBlade |

5 nodes × 8 vCPU / 32 GiB = **40 vCPU / 160 GiB** total. Aggregate workload uses ~30% of the cluster's compute, leaving 70% headroom for spikes, pod evictions during drain, and future platform additions (Argo, Loki, federated Prometheus, etc.).

**Single Postgres cluster with multiple databases** (CloudNativePG supports this): one CloudNativePG cluster hosts both `keycloak` and `harbor` databases. Simpler to operate than two separate Postgres clusters; blast-radius isolation between Keycloak and Harbor is good enough at this scale.

**Harbor S3 backend on FlashBlade** keeps image storage off the cluster's local PVs entirely. Harbor's pods only need small PVs for Postgres metadata and Redis, both of which fit in the cluster's standard storage class.

### 4.2 Install flow (unchanged from OKD doc)

Same as in `design.md` §4.2 — Foreman + Puppet + RKE2 + Rancher via Helm. The mgmt RKE2 cluster doesn't need Kemp for its API since Rancher's UI is what users hit, not the kube-apiserver directly. Rancher itself is exposed via the bundled ingress-nginx behind a Kemp VIP for `rancher.<base>`.

### 4.3 Provisioning the workload clusters

This is the key difference vs. the OKD design.

**With OKD:** Rancher imports clusters that already exist. It provides UI, RBAC, app catalog. It cannot provision, upgrade, or restore those clusters.

**With RKE2:** Rancher provisions the workload clusters directly using the **CAPRKE2** provider (cluster-api-provider-rke2). Two flows:

| Flow | How | When to use |
|---|---|---|
| **Custom cluster** | Pre-provision RHEL hosts via Foreman, then run a Rancher-generated `curl ... \| sh` on each host to register. Hosts are "pets" Rancher controls but doesn't lifecycle below the OS. | Bare-metal workers, especially GPU hosts. **Use this for both clusters.** |
| **Node-driver provisioning** | Rancher creates VMs via vSphere driver, installs RKE2, joins the cluster. End-to-end Rancher-driven. | Could use for the 3 server VMs; not strictly necessary if Foreman is already standing them up. |

Recommendation: **Custom cluster mode for both workload clusters.** Foreman/Puppet retain ownership of host provisioning and base config; Rancher takes over once the host exists. Best of both pipelines.

### 4.4 Lifecycle features Rancher gains

With RKE2-managed clusters, Rancher exposes:

- **Upgrades** — pick a target RKE2 version in the UI, Rancher orchestrates rolling drain + binary swap + restart per node.
- **Etcd snapshots** — schedule via UI, store on local disk and S3. Restore via UI.
- **ClusterClass templates** — define a "GPU cluster template" once, instantiate for the future mirror.
- **Project RBAC** — multi-tenant project namespaces with AD-group-mapped roles, projected across all managed clusters.
- **Monitoring/Logging apps** — Rancher's app catalog deploys `kube-prometheus-stack` and Loki with sane defaults; one-click on each downstream cluster.

---

## 5. Networking

### 5.1 VLAN / segmentation

Same VLANs:

| VLAN | Purpose |
|---|---|
| `mgmt` | Foreman, Puppet, Rancher, bastion, OOB |
| `rke2-infra-node` | RKE2-Infra node-to-node + API + ingress |
| `rke2-gpu-node` | RKE2-GPU node-to-node + API + ingress |
| `gpu-fabric` (optional) | RDMA/RoCE/InfiniBand between GPU agents |
| `storage` | NFS/iSCSI/NVMe-oF traffic to Pure |

**Critical Connection Manager network constraint** (per Connection Manager Ingress Controller documentation, Chapter 7): the **Connection Manager must have an interface on the same broadcast domain as each cluster's node VLAN.** This is because CM uses node IPs as next-hop gateways for pod traffic; standard IP routing requires gateways to be directly connected.

In practice this means the Kemp HA pair needs interfaces (or VLAN-tagged subinterfaces on a trunk) on each of:

- `mgmt` (for L4 access to mgmt RKE2 servers' kube-apiserver, plus L7 for `rancher.<base>`, `harbor.<base>`, etc.)
- `rke2-infra-node` (for L4 access to infra cluster servers' kube-apiserver + RKE2 registration, plus L7 for `*.apps.rke2-infra.<base>`, plus pod-CIDR routes via infra agent IPs)
- `rke2-gpu-node` (same shape — L4 + L7 + pod-CIDR routes via GPU agent IPs)

Confirm this with your network team before install — if Kemp data-path connectivity to each cluster's node VLAN doesn't already exist, this is the network design item to nail down first.

### 5.2 Load balancing — Kemp LoadMaster (unchanged in role, simpler in shape)

| VIP | Port | Mode | Backends | Health check |
|---|---|---|---|---|
| `api.<cluster>.<base>` | 6443/TCP | **L4 TCP passthrough** (statically configured on Connection Manager) | 3 RKE2 servers | TCP 6443 |
| `api.<cluster>.<base>` | **9345/TCP** | **L4 TCP passthrough** (statically configured on Connection Manager) | 3 RKE2 servers | TCP 9345 |
| `*.apps.<cluster>.<base>` | 80/TCP, 443/TCP | **L7 — auto-provisioned by Connection Manager Ingress Controller** (CM polls K8s API, creates VS + SubVSs per Ingress) | Pod IPs (direct, via routes added in CM) | TCP 443 (per-VS) |

**Two configuration styles, on the same Connection Manager:**

- **kube-apiserver and RKE2 server-registration VIPs** are static Virtual Services configured by network team via the CM UI. TCP passthrough, no L7 awareness — kube-apiserver's mTLS terminates at the apiserver itself, can't be inspected by the CM.
- **`*.apps` ingress VIP** is dynamic — the **Ingress Controller add-on installed on the Connection Manager itself** polls each cluster's K8s API (via uploaded kubeconfig) and auto-provisions Virtual Services + SubVSs as Ingress resources land in the cluster. TLS terminates on the CM, hostname/path routing on the CM, Real Servers are pod IPs (per the [Feature Description doc](https://docs.progress.com/bundle/ecs-connection-manager-feature-description-kemp-ingress-controller-for-kubernetes-ga/), Chapter 5).

**There is no in-cluster Ingress Controller pod.** This is fundamentally different from `ingress-nginx`-style controllers. The "controller" is an add-on installed on the CM hardware/VM (UI: `Virtual Services > Kubernetes Settings > Install` → reboot CM). The CM polls K8s directly. Implication: no Helm chart for the controller, no in-cluster RBAC for an in-cluster controller pod — but the kubeconfig uploaded to the CM does need a ServiceAccount + RBAC in the cluster with read access on `Ingress`, `Service`, `Endpoints`, `Pods`, etc.

**Critical:** see §5.5 for the static routes the CM needs to reach pod CIDRs. This is not optional — without these routes, the CM cannot deliver traffic to pods.

### 5.3 DNS — wildcard pattern with named platform records

DNS continues to live in your existing git-driven BIND. **No ExternalDNS** — the wildcard pattern means per-app DNS records aren't needed.

**Per cluster, in BIND zone (managed via your existing CI):**

```dns
; cluster API endpoints (one per cluster) — point at L4 Kemp VIPs
api.rke2-mgmt.<base>.       IN A   <kemp-vip-mgmt-api>
api.rke2-infra.<base>.      IN A   <kemp-vip-infra-api>
api.rke2-gpu.<base>.        IN A   <kemp-vip-gpu-api>

; wildcard for app ingresses — points at L7 Kemp VIP per cluster
*.apps.rke2-infra.<base>.   IN A   <kemp-vip-infra-ingress>
*.apps.rke2-gpu.<base>.     IN A   <kemp-vip-gpu-ingress>

; named platform-tier services (mgmt cluster ingress)
rancher.<base>.             IN A   <kemp-vip-mgmt-ingress>
harbor.<base>.              IN A   <kemp-vip-mgmt-ingress>
keycloak.<base>.            IN A   <kemp-vip-mgmt-ingress>
argocd.<base>.              IN A   <kemp-vip-mgmt-ingress>

; build-tier services (infra cluster ingress)
sonarqube.<base>.           IN A   <kemp-vip-infra-ingress>
gitlab-runner.<base>.       IN A   <kemp-vip-infra-ingress>   ; if exposed
```

**About the wildcard:** any new app deployed with an Ingress for `myapp.apps.rke2-infra.<base>` resolves automatically — no DNS commit needed per app. The Connection Manager (polling K8s) auto-provisions the matching Virtual Service when the Ingress lands. **Adds zero per-deploy DNS work.**

**TLS cert flow — corrected per Connection Manager Ingress Controller documentation:**

The CM does **not** automatically read TLS Secrets from K8s and serve them. In Ingress Mode, certs are referenced *by name* via the `kemp.ax/certfile` annotation on the Ingress resource:

```yaml
annotations:
  "kemp.ax/sslaccel": "1"
  "kemp.ax/certfile": "wildcard-apps-rke2-infra"
```

The cert named `wildcard-apps-rke2-infra` must already exist in the Connection Manager's certificate store (`Certificates & Security > SSL Certificates`). The CM serves whatever cert the annotation points at; cert lifecycle is managed at the CM, not via cert-manager.

**Three cert-management options for `*.apps` Ingress:**

| Option | How | Trade-off |
|---|---|---|
| **Wildcard cert from AD CS, manually uploaded** (recommended) | Issue `*.apps.<cluster>.<base>` cert from AD CS once per cluster, upload to CM, reference by name in every Ingress. Annual rotation as a calendar event. | Simplest. One cert per cluster. Manual rotation. |
| **CM-managed Let's Encrypt** | If any app is externally exposed: CM has built-in LE integration that auto-renews 90-day certs. Configure per-cluster externally-resolvable hostname. | Auto-rotation; only works for publicly-reachable hostnames. Most internal apps don't qualify. |
| **cert-manager → custom sync to CM API** | Build a CronJob/operator that reads cert-manager-issued K8s Secrets and pushes them to the CM via the REST API as named cert objects. | Fully automated like ingress-nginx; you build and operate the sync tool. Day-90+ if needed. |

**Recommendation:** wildcard cert from AD CS for day 1. Most apps don't need per-host certs; SAN list on the wildcard covers any naming exceptions. If/when cert rotation friction becomes operationally annoying, build the cert-manager → CM sync as a follow-up.

**Note about cert-manager's role on the cluster:** cert-manager is still useful for **in-cluster TLS** (mTLS between pods, webhook certs, internal service-to-service TLS). It just isn't in the path for ingress certs in this design. Keep it deployed; reduce its scope.

### 5.4 NTP / time

Same — chrony pointed at AD DCs / internal stratum-2.

### 5.5 Connection Manager → Pod connectivity (route configuration)

This is a hard requirement for the CM-as-ingress-controller architecture. Per the [Feature Description doc](https://docs.progress.com/bundle/ecs-connection-manager-feature-description-kemp-ingress-controller-for-kubernetes-ga/) Chapter 7, the Connection Manager needs **explicit static routes** to each cluster's pod CIDR, with each cluster node's IP as the next-hop gateway for the pods on that node. Without these, the CM cannot deliver traffic to Real Servers (which are pod IPs).

**Discovery of the routes** (one cluster at a time, run on a cluster admin workstation):

```bash
# For most CNIs (including Cilium native-routing mode):
kubectl get nodes -o jsonpath="{range .items[*]}{'Destination: '}{.spec.podCIDR}{'\t'}{'Gateway: '}{.status.addresses[0].address}{'\n'}{end}"

# Example output (mgmt cluster, pod CIDR 10.40.0.0/20, /24 per node):
# Destination: 10.40.0.0/24    Gateway: 10.50.20.31
# Destination: 10.40.1.0/24    Gateway: 10.50.20.32
# Destination: 10.40.2.0/24    Gateway: 10.50.20.33
# (one row per node, with that node's pod CIDR slice)
```

**Add the routes to the Connection Manager** via UI: `System Configuration > Network Setup > Additional Routes`. Each row is `<podCIDR-slice>` → `<node-IP>`. As nodes are added/removed, routes need updating — either manually or via a small automation that diffs `kubectl get nodes` against the CM's route table.

**For Cilium specifically:**

Cilium has two main modes that change this picture significantly:

| Cilium mode | CM connectivity story |
|---|---|
| **Encapsulation (VXLAN/Geneve, default)** | Pods are not directly routable from outside the cluster — they live on an overlay. CM cannot reach pod IPs by adding static routes pointing at node IPs (the pod IPs are inside the overlay). **This breaks the CM-as-ingress model.** Either switch Cilium to native-routing mode, or fall back to Service Mode targeting NodePort. |
| **Native routing** (`tunnel: disabled`, `routingMode: native`) | Pod CIDRs are advertised as standard L3 routes. CM static routes work as expected. Pods are first-class on the node L3 network. **This is the mode you want.** Requires the underlying network to handle pod CIDRs (works fine on flat L3 networks like yours). |
| **Native routing + BGP** (`bgpControlPlane: enabled`) | Cilium advertises pod CIDRs to your network fabric via BGP. The CM learns routes dynamically; no static-route maintenance. Cleanest answer if your network team is comfortable with BGP. |

**Recommended Cilium config for Kemp Ingress Controller compatibility:**

```yaml
# Cilium Helm values — set ipv4NativeRoutingCIDR per cluster to match that cluster's pod CIDR
tunnel: disabled
routingMode: native
ipv4NativeRoutingCIDR: "10.40.0.0/20"   # mgmt; each cluster uses its own per §3.4 allocation
bgpControlPlane:
  enabled: true   # if your network fabric supports BGP; otherwise leave false and use static routes
autoDirectNodeRoutes: true  # auto-install routes between nodes
```

**Verification step in the install spike:**

1. Deploy a test pod, note its IP.
2. From the CM, run a ping to the pod IP (CM has a network diagnostic tool in the UI).
3. If ping fails: the route is wrong, the Cilium mode doesn't allow direct routing, or the L2 adjacency requirement isn't met.
4. If ping works: the architecture is sound; proceed with Ingress Controller setup.

**This verification gates the entire RDR-7 design.** If it fails, fall back to either (a) NodePort routing with Service Mode, or (b) deploying a different ingress controller (ingress-nginx) for `*.apps` and using Kemp purely as L4 passthrough — same as the original architecture I'd been describing earlier.

---

## 6. GPU / B200 / B300 / L40 Considerations (RKE2-GPU cluster)

### 6.1 Stack

1. **Node Feature Discovery (NFD) Operator** — labels nodes with PCI device IDs.
2. **NVIDIA GPU Operator** — installs containerized drivers, nvidia-container-toolkit, device plugin, DCGM exporter, MIG manager.
3. **Optional: NVIDIA Network Operator** for RDMA / GPUDirect.

### 6.2 Mixed GPU pools

L40 (Ada / compute 8.9), B200 (Blackwell / compute 10.x), B300 (Blackwell refresh) coexist via:

- **Multiple ClusterPolicy resources** keyed off NFD labels — one per GPU architecture.
- **Per-node-pool driver branch:**
  - L40 nodes → driver R535 (or whatever current LTS branch supports Ada).
  - B200 nodes → driver R570+ ([NVIDIA GPU Operator docs confirm 570.133.20+ for HGX B200](https://docs.rke2.io/add-ons/gpu_operators)).
  - B300 nodes → driver branch TBD when B300 ships at scale; verify against NVIDIA's compatibility matrix at deploy time. (Reasonable expectation: the production branch active at that time, likely R580+, but treat as unconfirmed until B300 hardware is in hand.)
- **Taints + tolerations** so workloads land on the right architecture: `nvidia.com/gpu.product=L40-PCIe`, `nvidia.com/gpu.product=B200-SXM6`, etc.

### 6.3 RKE2-specific install and upgrade caveats

The NVIDIA Container Toolkit DaemonSet's documented behavior is to write the nvidia runtime into containerd's config and then SIGHUP containerd so it reloads. Per [NVIDIA's containerd-support announcement](https://developer.nvidia.com/blog/announcing-containerd-support-for-the-nvidia-gpu-operator/) and the [GPU Operator install docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/install-gpu-operator.html), this happens "**during installation and upgrades**" — not only on first install. Because RKE2 supervises containerd, that SIGHUP cascades into an RKE2 restart on the affected node.

**Three upgrade scenarios, three impacts:**

| Upgrade type | Toolkit DaemonSet image changes? | RKE2 restart? | Maintenance window? |
|---|---|---|---|
| **Driver-only upgrade** (driver container version bump only) | No | No | No — handled by NVIDIA's GPU driver upgrade controller, which drains GPU pods only via `gpuPodDeletion` strategy and leaves containerd alone |
| **Toolkit image upgrade** (most operator chart bumps) | Yes | Yes | **Yes** — or do it rolling node-by-node so only one node restarts at a time |
| **Major version upgrade** (e.g., flipping CDI on at v25.10) | Yes | Yes | **Yes** — and audit `containerd` config delta beforehand |

The NVIDIA upgrade docs note that "most of the GPU Operator managed daemonsets can be upgraded seamlessly," but they specifically call out: "the NVIDIA driver daemonset has special considerations." Per the [GPU Driver Upgrades doc](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-driver-upgrades.html), the driver upgrade controller is enabled by default and supports `maxParallelUpgrades` for parallel rollout — this is the path that gives you online driver updates.

**The toolkit-DaemonSet behavior is currently non-idempotent on upgrades.** There is an active community concern about this — multiple open NVIDIA/gpu-operator issues request that the toolkit skip the SIGHUP when containerd config is already correct ([#594](https://github.com/NVIDIA/gpu-operator/issues/594), [#991](https://github.com/NVIDIA/gpu-operator/issues/991), [#1651](https://github.com/NVIDIA/gpu-operator/issues/1651), [#992 RKE2-specific](https://github.com/NVIDIA/gpu-operator/issues/992)). Until/unless that's fixed, plan upgrades that bump the toolkit image as restart-affecting.

**Other RKE2-specific install considerations:**

- Recent GPU Operator (v25.10+) uses **CDI (Container Device Interface)** which is cleaner config than the older nvidia-container-toolkit hooks. Pin to v25.10+ when installing.
- Configure with `CONTAINERD_SOCKET=/run/k3s/containerd/containerd.sock` and **do not** set `CONTAINERD_CONFIG` — per [NVIDIA/gpu-operator#992](https://github.com/NVIDIA/gpu-operator/issues/992), setting `CONTAINERD_CONFIG` can break RKE2 after reboot. RKE2 detects the nvidia runtime independently once present.
- RKE2's `containerd` config uses templates at `/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl` — leave management of that file to RKE2 unless you have a specific reason to override.

**Scope of impact — important.** The GPU Operator targets only GPU-bearing nodes via NFD's `feature.node.kubernetes.io/pci-10de.present=true` label (per [NVIDIA's Getting Started docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html)). In this design, GPUs are on the bare-metal **agent** nodes only. The 3 RKE2 **server** VMs (control plane + etcd) carry no GPUs, so NFD doesn't label them, the toolkit DaemonSet never lands on them, and no SIGHUP ever cascades into a server-side RKE2 restart.

**Practical implication:** during a toolkit-image upgrade, agents restart node-by-node, but the API VIP, kube-apiserver, and etcd quorum stay healthy throughout. The cluster never goes "down" — only individual agent nodes briefly leave and return.

**Operational pattern for production upgrades:**

1. Pin the GPU Operator chart version. Don't auto-upgrade.
2. For driver-only changes (CVE patches, new GPU support that doesn't need a new toolkit), use the driver upgrade controller — online, drains GPU pods only via `gpuPodDeletion`.
3. For chart bumps that include a new toolkit image, schedule a rolling drain. Rancher's upgrade orchestration handles this with:

   ```yaml
   upgradeStrategy:
     workerConcurrency: "1"
     drain:
       enabled: true
       timeout: 600
       deleteEmptyDirData: true
   ```

   This drains and upgrades agents one at a time. API stays up; etcd is unaffected.
4. **Workload-availability prereqs** (don't forget these):
   - **Spare GPU capacity** in the inference pool — at least one node's worth of headroom so drained pods can reschedule. Without slack, drains stall.
   - **PodDisruptionBudgets** on inference workloads. `minAvailable: replicas - 1` is a sensible default — allows drains to proceed but never loses all replicas at once.
   - **Validation gate** between nodes — Rancher waits for node Ready, but Ready ≠ "GPUs are healthy." The GPU Operator's validator pod runs as part of the rollout; for high-stakes inference, consider an explicit smoke test before un-cordoning.

### 6.4 Driver delivery

The GPU Operator ships drivers as a containerized driver pod. **Do not install NVIDIA drivers via Puppet on agent nodes** — that conflicts with the GPU Operator's driver pod. The Lustre kernel module *can* go via Puppet/dnf (different module, different lifecycle). NVIDIA drivers stay in the cluster operator's domain even though everything else on the host is Puppet-managed.

This is the one place where "Puppet manages everything on workers" gets a carve-out. Reasonable: GPU Operator's per-architecture / per-driver-branch logic is genuinely better than a Puppet equivalent for a mixed L40/B200/B300 fleet.

### 6.5 Power & cooling

B200 SXM hosts pull ~1000W per GPU per NVIDIA's HGX B200 specifications. B300 power draw is in the same class or higher per pre-release information; **confirm against NVIDIA's published TDP for whatever B300 SKU you actually order — don't rely on this doc for sizing**. Rack PDUs and cooling must sustain steady-state inference loads, not just the rated TDP burst.

---

## 7. Backup Strategy

| Component | What | How | Retention | Restore RTO |
|---|---|---|---|---|
| Foreman | Postgres DB + `/etc/foreman*` + `/var/lib/tftpboot` | foreman-maintain backup | 30 days, offsite (Pure FlashBlade S3) | < 4 h |
| Puppet | r10k-managed Git repo (already in GitLab) | Git is the backup | n/a | < 1 h |
| Rancher RKE2 (mgmt) | Native etcd snapshots | RKE2 timer + S3 upload to Pure FlashBlade | 28 snapshots / 30 days | < 2 h |
| Workload RKE2 etcd (per cluster) | Native etcd snapshots | **Default-on**: 00:00 + 12:00, 5 retained, S3 to Pure FlashBlade | 28 days w/ S3 retention | < 1 h |
| **CloudNativePG (mgmt cluster, multi-DB)** | Postgres base backup + WAL stream | **CNPG built-in barman to FlashBlade S3**; continuous WAL archiving + scheduled base backups | 30 days PITR window | < 30 min (PITR to any timestamp in window) |
| Keycloak realm config | Realm export YAML/JSON (logical-level config) | CronJob `kc.sh export`, push to S3 | 14 days | < 1 h |
| Harbor metadata | Backed by CloudNativePG above (Harbor's `harbor` DB) | Same as CNPG | Same | Same |
| Harbor image data | Object storage on Pure FlashBlade S3 | FlashBlade-native S3 versioning + cross-region replication if applicable | Configurable | < 1 h (re-point Harbor at restored bucket) |
| Application PVs | Workload-specific (Velero, app-level, Pure FlashArray snapshot) | TBD per workload | TBD | TBD |

> **The big difference from the OKD design:** RKE2 ships with etcd backup enabled by default. No CronJob to build, no `cluster-backup.sh` to schedule. Configure S3 endpoint once and you're done.

---

## 8. Failure Modes and Recovery

### 8.1 Failure matrix

| Failure | Blast radius | Workloads affected? | Recovery |
|---|---|---|---|
| Foreman down | New provisioning blocked | No | Restore from foreman-maintain backup |
| Puppet down | Drift on RHEL hosts (incl. RKE2 hosts) | No (existing config persists) | Restore Puppet master from Git |
| Mgmt cluster server down (1 of 5) | etcd 4/5, brief blip during pod reschedule | No | Replace node; RKE2 rejoins, CloudNativePG rebalances |
| Mgmt cluster server down (2 of 5) | etcd 3/5 (still quorate); cluster fully functional | No | Replace nodes; routine recovery |
| Mgmt cluster server down (3+ of 5) | etcd loses quorum; full mgmt-plane outage. Workload clusters keep running. | No (workload clusters unaffected) | RKE2 `cluster-reset` from etcd snapshot (S3); ~1h restore. CloudNativePG restored from barman PITR; Helm reconciles platform services |
| Workload RKE2 server down (1 of 3) | Reduced HA | No | Drain + reprovision; Rancher rejoins automatically |
| Workload RKE2 server down (2 of 3) | API + etcd quorum lost | Running pods continue, no scheduling | Restore from etcd snapshot via `rke2 server --cluster-reset --cluster-reset-restore-path=...` |
| Workload RKE2 server down (3 of 3) | Full control plane loss | Running pods continue | Same — cluster-reset flow; rehearse this |
| RKE2 agent down | Pods rescheduled | Brief | Reprovision via Foreman; RKE2 agent rejoins |
| GPU node hardware failure | Pods on that node down | Yes for that node | Reprovision; have a hot spare for B200/B300 if SLA matters |
| VMware host failure | Whatever was on it | Brief | Standard vSphere HA |
| Kemp LB failure | API + ingress unreachable | **Yes** until Kemp HA pair fails over | Kemp HA failover (existing infrastructure) |
| Pure FlashArray failure | Anything with PVs on it | **Yes**, severely | Fail over to FlashArray DR target if configured; otherwise out of scope |
| DDN Lustre system failure | GPU jobs that depend on Lustre | **Yes** for affected jobs | Lustre's own HA / failover; out of scope of this doc |

### 8.2 Recovery playbook stubs

- `runbooks/foreman-restore.md`
- `runbooks/rancher-rke2-rebuild.md`
- `runbooks/rke2-etcd-restore.md` ← **highest priority; rehearse twice a year**
- `runbooks/rke2-server-replace.md`
- `runbooks/gpu-node-reprovision.md`
- `runbooks/keycloak-realm-restore.md`
- `runbooks/harbor-restore.md`

---

## 9. Deployment Sequencing

**Phase 0 — Prerequisites**

1. VMware capacity: **12 VMs minimum** (5 mgmt + 3 per workload cluster + 1 bastion).
2. Bare-metal hardware racked, BMC accessible from Foreman.
3. VLANs + L3 + firewall rules.
4. DNS sub-zone delegated.
5. AD service account for Keycloak federation.
6. Kemp LoadMaster: confirm capacity and reachability from cluster VLANs; provision VIPs (incl. port 9345 for RKE2).
7. Pure Storage: confirm tenancy + API credentials for `pure-csi`; provision FlashBlade S3 bucket for Harbor image storage and CNPG barman archives.
8. DDN Lustre: identify filesystems; obtain DDN Lustre client RPM repo and stage in Katello content view.

**Phase 1 — Management plane (consolidated platform tier on 5-node mgmt cluster)**

1. Foreman: confirm RHEL kickstart pipeline, Katello channels for RKE2 + DDN.
2. Configure Kemp VIP for `rancher.<base>` (terminate at ingress-nginx in mgmt cluster).
3. Build 5 RHEL VMs for the mgmt RKE2 cluster (8 vCPU / 32 GiB / 200 GiB SSD each); Puppet applies base + RKE2 server install with `cni: cilium`, `disable-kube-proxy: true`, `profile: cis`.
4. Bootstrap mgmt RKE2 cluster (5 servers, embedded etcd quorum 3-of-5); validate Cilium + Hubble; configure RKE2 etcd snapshots → S3 on FlashBlade.
5. Install Rancher via Helm; expose behind Kemp VIP; configure local-admin break-glass account (do NOT federate this account).
6. Install **CloudNativePG operator** via Helm/manifest. Create one CNPG cluster (3 PG replicas, FlashArray-backed PV, barman → FlashBlade S3 archive). Provision two databases: `keycloak` and `harbor`.
7. Install **Keycloak** via Helm (2 replicas, OIDC, Postgres pointed at CNPG `keycloak` DB). Configure AD federation. Configure Rancher to use Keycloak as OIDC IdP. Configure mgmt cluster's kube-apiserver to trust Keycloak tokens.
8. Install **Redis** (Bitnami chart, single instance, FlashArray PV).
9. Install **Harbor** via Helm (HA values: 2 replicas of core/registry/jobservice, Postgres pointed at CNPG `harbor` DB, Redis pointed at the Redis instance, image storage backend `s3` pointing at FlashBlade S3 bucket). Expose Harbor behind Kemp VIP for `harbor.<base>`.
10. Install `kube-prometheus-stack` via Rancher's app catalog or directly via Helm.
11. Smoke test: Rancher login via Keycloak/AD, Harbor login via Keycloak, push/pull a test image to Harbor.

**Phase 2 — RKE2-Infra cluster**

1. Foreman provisions 3 server VMs; Puppet installs RKE2 server with config pointing at Kemp VIP.
2. Bootstrap server 1, join servers 2 and 3.
3. Foreman provisions N agent VMs/bare metal; Puppet installs RKE2 agent.
4. Register cluster with Rancher (custom cluster mode).
5. Configure cluster: Pure CSI default StorageClass, cert-manager, Keycloak OIDC integration, Rancher Project RBAC.
6. Deploy `kube-prometheus-stack` and Loki via Rancher app catalog.
7. Onboard first workload.

**Phase 3 — RKE2-GPU cluster**

1. Repeat Phase 2 with cluster-specific VIPs/CIDRs/DNS.
2. Agent nodes are the L40 / B200 / B300 bare-metal hosts.
3. Puppet installs DDN Lustre client on agents (`dnf install ddn-lustre-client`).
4. Deploy NFD Operator → GPU Operator → (optional) NVIDIA Network Operator.
5. Deploy DDN exa-csi-driver via Helm.
6. Validate `nvidia-smi` from a test pod on each GPU agent; validate Lustre mount.
7. Onboard first inference workload.

**Phase 4 — Operationalize**

1. Configure RKE2 etcd snapshots to S3 (Pure FlashBlade) on both clusters; verify a restore in a test environment.
2. Document and rehearse the disaster-recovery playbook.
3. Scope Slinky pilot if interest persists (not on critical path).

**Phase 5 — Future**

- RKE2-GPU-2 mirror cluster: with Rancher ClusterClass templates, this is a clone-and-rename operation. Reuse same Foreman host group, Puppet profile, Kemp VIP pattern.
- Slinky integration for specific use cases (Slurm-on-k8s for ML training jobs, or slurm-bridge for an overflow node tier).

---

## 10. Scaling Considerations

### 10.1 Adding agents

- Bare metal: rack hardware → register in Foreman → Puppet provisions RHEL → RKE2 agent install + token → joins cluster. Time-to-ready: 30–60 minutes.
- Reusable: Foreman host group, Puppet profile, registration token (rotate periodically per RKE2 docs).

### 10.2 Adding a third cluster (RKE2-GPU-2)

Reusable as-is (most things, more than the OKD design):

- All Foreman/Puppet/Katello content.
- Kemp LB pattern.
- DNS pattern.
- Rancher: define **ClusterClass** template once, clone to new cluster.
- Pure CSI, DDN exa-csi-driver, GPU Operator, monitoring/logging — all redeployed via the same Helm values.

Needs new design:

- Unique CIDRs (pod, service, node).
- DR vs active-active decision (DR-4 from main design doc).

### 10.3 Scaling out the management cluster

3-node RKE2 mgmt is sufficient up to ~20+ downstream clusters. The bottleneck is Rancher's memory, not RKE2 control plane.

---

## 11. Decisions to Revisit (revised list)

> Many open items from `design.md` collapse if you go RKE2. New decisions surface in their place. IDs prefixed `RDR-` (Rke2 Decisions Revisited) to distinguish from the OKD doc's DR-x.

**Resolved by choosing RKE2:**

- ~~DR-1 (separate etcd tier)~~ — not relevant; RKE2 etcd lives on servers, same supported pattern.
- ~~DR-2 (RHEL workers + Puppet vs FCOS+MCO)~~ — moot; RKE2 is RHEL+Puppet by design.
- ~~G-1 (etcd backup not automated)~~ — RKE2 enables 2×/day snapshots by default; just configure S3.

**Still open (carry over from OKD doc):**

- DR-3 — VMware snapshots of mgmt RKE2 are still not a substitute for etcd snapshots. Use RKE2's native snapshot + S3.
- DR-4 — Mirror cluster purpose (DR / active-active / overflow) — same question, same answer needed.

**New decisions surfaced by RKE2:**

### RDR-1 — Custom cluster vs node-driver provisioning

Rancher can either (a) provision and lifecycle the host VMs/hardware via the vSphere/bare-metal node driver, or (b) consume hosts that Foreman+Puppet already provisioned ("custom cluster"). Recommendation: custom cluster, because Foreman+Puppet already do host lifecycle better than Rancher would.

### ~~RDR-2 — CNI choice~~ ✅ Resolved: **Cilium on both clusters**

**Decision:** Cilium for both RKE2-Infra and RKE2-GPU. **Why:** one technology to learn, one troubleshooting toolbox, one set of operational muscle that applies to the whole fleet. The GPU cluster needs eBPF observability (Hubble) for inference debugging anyway; standardizing the infra cluster on Cilium too is cheaper than running two CNIs forever. The marginal complexity of Cilium-on-infra is small relative to the recurring cost of operating Canal + Cilium in parallel. **Full treatment in §3.4.**

### ~~RDR-3 — Harbor placement~~ ✅ Resolved: **In-cluster on the mgmt RKE2 cluster, central instance only day 1**

Harbor lives on the consolidated 5-node mgmt cluster as a Helm-deployed workload. Image storage backend points at Pure FlashBlade S3; Postgres backed by CloudNativePG (multi-DB cluster shared with Keycloak); Redis via Bitnami chart. **Per-cluster Harbor proxy projects deferred** — add only if pull bandwidth from central Harbor → workload clusters becomes a real bottleneck. Full treatment in §4.1.1 + §9 Phase 1.

### ~~RDR-4 — Keycloak placement and HA~~ ✅ Resolved: **In-cluster on the mgmt RKE2 cluster**

Keycloak runs on the mgmt cluster (2 replicas via official Helm chart) with Postgres backed by the same CloudNativePG cluster as Harbor. The "circular dependency with Rancher" concern is mitigated by Rancher's local-admin break-glass account (never federated, password vaulted, used only for emergencies). Workload clusters depend on Keycloak for new logins but existing tokens + service accounts continue working through any Keycloak outage; pods on workload clusters never become unreachable. Full treatment in §4.1.1.

### RDR-5 — Pod security policy engine

PSA + Kyverno or PSA + Gatekeeper. Both are credible; Kyverno's syntax is friendlier for shops without OPA experience. Recommendation: Kyverno unless there's an existing Gatekeeper investment.

### ~~RDR-6 — Rancher Prime (paid SUSE support) vs community~~ ✅ Resolved: **Community**

**Decision:** Community Rancher (no SUSE Rancher Prime contract). Self-supported. **Trade-off accepted:** SUSE's formal Support Matrix is interpreted as a tested-combinations guideline rather than a contractual constraint. RKE2's release-time QA is the actual technical compatibility gate; what's listed in the matrix is paid-support-coverage, not "what works." When troubleshooting, a problem on a "tested-but-not-matrix-listed" combination is "you knew the trade-off," not a bug to escalate.

If support posture changes (project moves to Rancher Prime, or a SUSE contract is signed), revisit version pinning — the matrix becomes a hard constraint at that point.

### RDR-8 — Initial K8s/RKE2 version pin

**Decision:** RKE2 **v1.35.4+rke2r1** (current stable as of 2026-04-24; re-confirm latest v1.35.x patch when actually creating the Cluster CRs — production deploy is weeks out, may roll forward). Bundled Cilium **v1.19.x** (RKE2 ships and validates the combo as part of release QA). Rancher Manager **2.13.4**.

The v1.35 line dates to December 2025 (~5 months of soak by deploy time) with a healthy patch cadence. The formal Rancher Support Matrix lists v1.32–v1.34, but per RDR-6 we're community-supported and the matrix is a guideline, not a contract.

**Upgrade-cadence philosophy:** pick a version and ride it. Don't reflexively upgrade to v1.36 the moment it's stable; wait until there's a concrete reason — CVE that doesn't backport, feature genuinely needed, ecosystem support gap closing.

**Forward note (informational, not blocking):** RKE2 v1.36 will default to Traefik instead of ingress-nginx (per RKE2 release notes — `ingress-nginx` reaches EOL March 2026). Doesn't affect this design because `rke2-ingress-nginx` is already disabled in favor of the Kemp Connection Manager Ingress Controller (RDR-7). Worth knowing during the eventual v1.35 → v1.36 upgrade so the Traefik default doesn't surprise the operator.

### RDR-9 — SELinux on RKE2 nodes

**Decision:** **Disabled cluster-wide** (`selinux: false` in Puppet's config drop-in; no `rke2-selinux` package installed). Matches existing fleet practice — other K8s clusters in the environment run with SELinux disabled, and making the RKE2 clusters special creates a permanent "remember, RKE2 is different" footnote in operations.

`profile: cis` stays enabled — K8s component hardening (kubelet flags, apiserver flags, RBAC, audit) is independent of host SELinux state. CIS Kubernetes Benchmark and CIS RHEL Benchmark are different documents.

**HPC-specific rationale:** Lustre access from pods (training data, scratch, checkpoints on the GPU cluster), researcher-supplied container images, GPU Operator + RDMA device access — each introduces SELinux surface that would surface as AVC denials and silent pod failures. Security boundary lives at Harbor image scanning, Cilium NetworkPolicy, namespace isolation, Kyverno (RDR-5), and AD-based access. SELinux would be belt-and-suspenders against threats those layers already cover, at the cost of debugging friction the HPC user base would feel daily.

### ~~RDR-7 — L7 ingress: Connection Manager Ingress Controller vs ingress-nginx~~ ✅ Resolved: **Connection Manager Ingress Controller adopted; ingress-nginx removed**

**Decision:** the Kemp Connection Manager (formerly LoadMaster) acts as the L7 ingress controller for both workload clusters via its built-in Ingress Controller add-on. RKE2's bundled `rke2-ingress-nginx` is disabled.

**Architecture (corrected per the Feature Description doc, after PDF review):**

The Ingress Controller is **an add-on installed on the Connection Manager itself**, not a pod in the Kubernetes cluster. There is no in-cluster controller pod, no Helm chart for the controller, no in-cluster ServiceAccount specifically for the controller.

How it works:

1. CM admin installs the add-on via UI (`Virtual Services > Kubernetes Settings > Install`) and reboots the CM.
2. A kubeconfig file with read access to the cluster's K8s API is uploaded to the CM.
3. The CM **polls the K8s API directly** at the configured Ingress Watch Timeout interval (30–900 seconds; default suggested ~60s).
4. When `Ingress` resources or Services with `kempLB:Enabled` labels appear, the CM auto-provisions matching Virtual Services + SubVSs on itself.
5. Real Servers in those VSes are populated with the pod IPs from the K8s Service's endpoints; pod scaling auto-updates the Real Server list.

The "controller" lives on Kemp hardware/VM and treats K8s as a configuration source. Closer to the F5 BIG-IP Container Ingress Services model than to nginx-ingress.

**RBAC for the kubeconfig uploaded to the CM:**
The CM's K8s service account needs cluster-wide read access on:

- `ingresses.networking.k8s.io` (watch, list, get)
- `services` (watch, list, get)
- `endpoints` / `endpointslices.discovery.k8s.io` (watch, list, get)
- `pods` (watch, list, get)
- `nodes` (list, get — for route discovery)
- `namespaces` (list, get)
- `secrets` (list, get — only if cert-sync is added later; otherwise omit)

This is a single ServiceAccount + ClusterRole + ClusterRoleBinding per cluster, with the kubeconfig pointed at that SA's token. Apply via ArgoCD as part of the platform manifests.

**Why this architecture over ingress-nginx:**

- Kemp is fully licensed; the Ingress Controller add-on ships with the existing investment.
- Kernel-space TLS offloading on the CM outperforms containerized userspace ingress-nginx (PDF Chapter 1).
- Single management surface — CM UI for all north-south traffic (L4 + L7).
- Direct pod-IP routing eliminates the NodePort + kube-proxy chain.
- **No in-cluster controller** is genuinely simpler than the ingress-nginx model.
- ~50+ annotations expose deep L7 controls (WAF, OIDC auth integration with Keycloak, cipher sets, persistence, health checks, HTTP/2, FIPS cipher set, etc.) — many things you'd otherwise build with a separate ingress-nginx + service-mesh stack.

**Two operating modes available:**

- **Ingress Mode** (recommended for day 1) — standard K8s `Ingress` objects with `ingressClassName: lmingress` and `kemp.ax/*` annotations auto-provision CM Virtual Services. Cross-functional DevOps shape.
- **Service Mode** — pre-existing CM Virtual Services are attached to K8s Services via `kempLB: Enabled` label and `vsid` annotation. Useful if NetOps wants strict separation from K8s state.

**Hard requirements (per PDF Chapters 2 and 7):**

1. **CM L2-adjacency to each cluster's node VLAN.** CM uses node IPs as next-hop gateways for pod traffic; standard IP routing requires gateways to be directly connected. See §5.1 — the Kemp HA pair needs interfaces (or VLAN-tagged subinterfaces on a trunk) on each cluster's node VLAN.

2. **Static routes on the CM** for each cluster's pod CIDR, with node IPs as next-hop. See §5.5 for discovery and addition. **Cilium must be in native-routing mode** (not encapsulation) for pod IPs to be reachable via these routes.

3. **TLS 1.2 enabled on the CM** (`Certificates & Security > Admin WUI Access > Supported TLS Protocols`).

4. **Cert lifecycle is on the CM, not cert-manager.** Certs uploaded to CM by name, referenced via `kemp.ax/certfile` annotation. Wildcard cert from AD CS recommended (one per cluster, annual rotation). See §5.3 for cert flow.

**ingress-nginx fate:** disabled cluster-wide on both workload clusters (`disable: rke2-ingress-nginx` in `/etc/rancher/rke2/config.yaml`). Mgmt cluster: same — Connection Manager Ingress Controller handles all `*.apps` and named services for consistency.

**Open verification items — narrowed (close via half-day install spike):**

1. **Cilium native-routing mode + L2 adjacency** — confirm the CM can ping pod IPs on a test cluster after configuring native routing and adding static routes. This is the critical de-risking step. If this fails, the entire RDR-7 falls back to ingress-nginx in-cluster + Kemp L4 passthrough.
2. **Multi-cluster kubeconfig handling** — does one CM watch one cluster (one kubeconfig at a time), or can it handle multiple clusters via context-switching? PDF doesn't say; verify in the install. If one-cluster-per-CM-instance, the Kemp HA pair manages all clusters one at a time, or you'd use Service Mode with manually-configured VSes for cross-cluster cases.
3. **kubeconfig RBAC scope** — confirm the minimal SA/ClusterRole listed above is sufficient. If the CM needs more (e.g., write access for some flow), tighten incrementally.
4. **Logs and observability** — the CM-side logs (`System Configuration > Logging Options > Extended Log Files`) include "Ingress Controller Logs" and "Ingress Resource Watcher Logs." Verify these are useful for troubleshooting pre-prod.
5. **Service Mode "nodes on same subnet" constraint** — both PDF mode descriptions list this as a disadvantage. Verify whether it's a hard L2 requirement or a softer "must be next-hop-routable" preference.

**Fallback if RDR-7 doesn't pan out in install spike:** revert to **ingress-nginx in-cluster + Kemp doing L4 passthrough on `*.apps:443`** — the architecture I'd originally been describing. That model is well-trodden, doesn't depend on CM-to-pod L3 reachability, and uses cert-manager natively in-cluster. Real cost: the CM L7 features (WAF, OIDC, etc.) move to in-cluster equivalents (Kyverno, Keycloak's native OIDC, etc.).

---

## 12. Identified Gaps

> Things that need explicit design-time attention even after the major decisions are locked.

### G-1 (revised) — Image registry sourcing

Confirm whether to deploy a new Harbor or plug into an existing org Harbor / Quay. Affects sizing + HA design.

### G-2 (revised) — Identity flow

Confirm whether Keycloak goes on dedicated VMs (recommended above) or in-cluster, and which AD federation mode (LDAP federation or AD-as-IdP-via-Kerberos).

### G-3 — Long-term log retention

Cluster-local Loki retains weeks. For compliance retention beyond that, ship to org SIEM or long-term S3 with Pure FlashBlade lifecycle policy.

### G-4 — RDMA network design (if applicable)

If multi-node B200/B300 inference workloads do RDMA via NVIDIA Network Operator, the GPU fabric VLAN and switch config (RoCE vs InfiniBand) are an explicit hardware-and-network design exercise, not just a Kubernetes config item.

### G-5 — Slinky pilot scope

If Slinky is going to be more than a "could do later" capability, scope a pilot: which Slurm cluster, which workload, slurm-operator vs slurm-bridge. Don't gate the production deployment on it.

### G-6 — Air-gap / disconnected install posture

Same as in the OKD doc. RKE2 has good disconnected-install support — `rke2-airgap` images and packaged binaries. If disconnected, plan the pull-through registry (Harbor) and content lifecycle in Katello.

### G-7 — Secrets management

External Secrets Operator + HashiCorp Vault, or Sealed Secrets, or in-cluster CSI secrets store. Decide before workloads land.

### G-8 — Capacity / node count targets

Same as OKD doc G-9. Nail down a starting count per cluster.

### G-9 — Monitoring federation

Rancher's `kube-prometheus-stack` deployment is per-cluster. For org-wide observability, federate to a central Prometheus / Thanos / Mimir instance. Decide if that's day-1 or day-2.

### G-10 — Change management / promotion

Same as OKD doc G-10. ArgoCD or Flux for workload manifests, app-of-apps per cluster.

---

## 13. Open Questions for the Next Iteration

**Settled by choosing RKE2 (vs. design.md):**

- ~~Worker OS~~ → RHEL 9.
- ~~Worker config system~~ → Puppet.
- ~~etcd backup~~ → built-in RKE2 default + S3 to Pure FlashBlade.

**Resolved earlier (carry over from OKD doc):**

- LB choice → Kemp.
- Storage → Pure (`pure-csi`) + DDN Lustre (DDN exa-csi-driver).
- Identity → AD via Keycloak OIDC.
- **CNI → Cilium on both clusters (RDR-2 resolved).** Full rationale and config in §3.4.
- **Harbor placement → in-cluster on mgmt (RDR-3 resolved).** §4.1.1 + §9 Phase 1.
- **Keycloak placement → in-cluster on mgmt (RDR-4 resolved).** §4.1.1.
- **Mgmt cluster sizing → 5 nodes at 8/32/200 (consolidated platform tier).** §4.1.
- **L7 ingress → Kemp Ingress Controller; ingress-nginx disabled (RDR-7 resolved).** §5.2 + §11. Three open verification items (pod-CIDR L3 reachability, TLS Secret auto-push, RBAC) → install-spike concerns, not architectural ones.

**Still open:**

1. RDR-1 (custom cluster vs node-driver) — recommended custom cluster; confirm.
2. RDR-5 (Kyverno vs Gatekeeper) — recommend Kyverno.
3. RDR-6 (Rancher Prime vs community) — recommend Prime.
4. DR-4 (mirror cluster purpose) — unchanged.
5. Worker count targets per cluster (G-8) — same as OKD doc.
6. Disconnected vs connected install (G-6) — same as OKD doc.
7. Slinky pilot scope (G-5) — defer; capability available either way.

When the still-open items are answered, this document graduates from v0.1 draft to v1.0 baseline.

---

## Appendix A — Cross-references

- Comparison against OKD: `okd-vs-rke2.md`
- OKD variant of this design: `design.md`
- Project-scoped vendor commitments: `~/.claude/projects/-home-selutha-claude-okd/memory/project_vendors.md`
