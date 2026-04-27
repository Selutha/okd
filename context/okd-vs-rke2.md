# OKD vs RKE2 — Platform Comparison for the Two-Cluster Build

**Status:** Draft v0.1 — for iteration
**Date:** 2026-04-24
**Purpose:** Decide whether the two workload clusters (infra + GPU inference, future mirror) should run on OKD or on RKE2. This document compares both platforms specifically for the user's situation: HPC center, Foreman/Katello+Puppet shop, existing Rancher-on-RKE2 management plan, DDN Lustre + Pure Storage backends, NVIDIA L40 + B200 + B300 GPUs, Slurm remains the primary HPC scheduler with Slinky as a future capability rather than a wholesale conversion.

---

## 0. Executive summary

Both platforms can run this workload. The honest distinction is:

- **OKD** is an opinionated, batteries-included platform. You get OAuth, image registry, ingress router, monitoring, logging, SCCs, and node-level OS management as integrated operators. The cost is OS lock-in (FCOS pivoting to SCOS on 4.16+) and a worker-node management model (Machine Config Operator) that is incompatible with Puppet on the same surface.
- **RKE2** is a CNCF-conformant, security-hardened, lightly-bundled distribution. You assemble registry, OAuth/OIDC, monitoring, etc. yourself from upstream/third-party charts. The benefit is RHEL all the way down, Puppet/Katello in unmodified form, and Rancher's full lifecycle (provisioning, upgrade, etcd snapshot/restore) for the workload clusters — which Rancher does *not* offer for OKD clusters it merely imports.

**Recommendation, given the user's specific situation: lean RKE2, with caveats.** Three of the four big drivers point that way (existing Puppet/Katello pipeline, RHEL-native fit, Rancher full lifecycle on RKE2). The fourth (OKD's batteries-included integration) doesn't pay for itself when the user is already planning to bring AD/Keycloak, Pure-CSI, DDN Lustre CSI, and the NVIDIA GPU Operator — all of which are equally first-class on RKE2. The HPC fit (Slinky) is platform-agnostic but has more community traction on vanilla/RKE2.

The caveats — and they are real — are listed in §6. Read them before locking the decision.

---

## 1. Methodology

The comparison weighs:

1. **Functional parity** — can each platform run the workloads (general infra services + GPU inference at B200/B300 scale)?
2. **Integration fit** — how well each platform meshes with the user's existing tooling (Foreman, Katello, Puppet, Rancher, Kemp, Pure, DDN Lustre, AD).
3. **Operational lift** — what you have to deploy, configure, and own day-2 on each platform.
4. **HPC fit** — coexistence with the existing Slurm bare-metal HPC stack; Slinky integration; node feature discovery; large-image pull patterns; RDMA/InfiniBand networking; multi-arch GPU pools.
5. **Risk profile** — supportability, upgrade path, lifecycle of OS and platform, deprecations on the horizon.

Where docs are cited inline, the source links are at the bottom of the document.

---

## 2. Feature-parity matrix

| Capability | OKD (current) | RKE2 (current) |
|---|---|---|
| CNCF-conformant Kubernetes | Yes | Yes |
| HA control plane (3-server) | Yes (3 masters w/ etcd) | Yes (3 servers w/ etcd; agents = workers) |
| Worker / agent OS | FCOS → SCOS (4.16+) | RHEL, Rocky, SLES, Ubuntu |
| Node OS managed by | Machine Config Operator | None (you/Puppet manage RHEL) |
| Container runtime | CRI-O | containerd |
| CNI default | OVN-Kubernetes | Canal (Flannel + Calico); Calico/Cilium options |
| Image registry (built-in) | Yes (operator-managed; needs PV) | No — deploy Harbor or external |
| Ingress (built-in) | HAProxy router (operator-managed) | ingress-nginx (default; optional) |
| OAuth / IdP integration | Built-in (LDAP/OIDC providers) | None — deploy Keycloak/Dex/oauth2-proxy |
| Monitoring (built-in) | cluster-monitoring (Prometheus stack) | None — deploy `kube-prometheus-stack` |
| Logging (built-in) | cluster-logging operator (optional) | None — deploy Loki/EFK yourself |
| Pod security | SCCs (Security Context Constraints) | PSA + Kyverno/Gatekeeper |
| RBAC defaults / projects | OpenShift Projects, namespace templating | Plain Kubernetes namespaces; Rancher Projects layer |
| CIS hardening profile | Default hardened | Toggle via `profile: cis` in `/etc/rancher/rke2/config.yaml` |
| FIPS 140-2 | No | Yes (linux/amd64; BoringCrypto) |
| Etcd snapshots | Manual cron (cluster-backup.sh); not auto-scheduled | Default: 2×/day, 5 retained, optional S3 upload |
| Cluster lifecycle from Rancher | Import only (read-mostly) | Full: provision, upgrade, snapshot, restore |
| NVIDIA GPU Operator | Supported (community on OKD) | Supported (Helm install; CDI-based on v25.10+) |
| NVIDIA Network Operator (RDMA) | Supported | Supported |
| Pure Storage CSI (`pure-csi`) | Supported | Supported (Pure publishes a Rancher whitepaper) |
| DDN EXAScaler / Lustre CSI | Supported (uses KMM in `openshift-kmm` namespace) | Supported (generic k8s deployment) |
| Slinky (Slurm operator) | Works on conformant k8s ≥ 1.29; community traction is RKE2/vanilla | Works on conformant k8s ≥ 1.29; first-class fit |
| Provisioning model | Ignition + MCS + MCO | Foreman kickstart RHEL → install RKE2 binary → Puppet for hostlevel |

**Key takeaway:** functional parity is essentially complete for the workloads in scope. The differences are about *who installs what* and *who manages day-2*, not *can it be done*.

---

## 3. Where they materially differ

### 3.1 OS and host management

This is the single biggest difference and the source of most of the others.

**OKD:** Workers run FCOS now and pivot to SCOS on 4.16+. The Machine Config Operator owns the kernel, CRI-O, kubelet, systemd, NetworkManager, and any host config you want to apply. Puppet on these hosts fights MCO's drift-detection loop. There is no documented OKD path that produces a working RHEL worker. (RHEL workers existed in OCP 4.x via the openshift-ansible scaleup playbook and were **deprecated in OCP 4.16**, slated for removal.)

**RKE2:** Servers and agents are plain RHEL/Rocky/SLES/Ubuntu hosts. RKE2 ships as a single binary plus systemd unit. Foreman PXE-installs RHEL with kickstart, Puppet applies your standard base profile (SSH keys, NTP, repos, hardening, audit, etc.), then RKE2 is installed and joined. Day-2 host config — including SSH keys, kernel modules (Lustre, NVIDIA), sysctls, security settings — stays in Puppet exactly as it does on every other RHEL host you operate.

Implication for this user: keeping Puppet/Katello as the system of record for host configuration is a real operational cost saver. RKE2 lets that pipeline keep working without modification. OKD requires learning MachineConfig CRDs as a parallel system for OKD nodes specifically.

### 3.2 Rancher's relationship to the cluster

**OKD imported into Rancher:** Rancher provides app catalog, RBAC projection, monitoring dashboards, kubectl shell, multi-cluster UI. Rancher does **not** drive OKD upgrades, etcd backup/restore, node provisioning, or cluster scaling. Those stay with OKD's CVO / Machine API.

**RKE2 provisioned by Rancher:** Rancher drives the entire cluster lifecycle — provisioning new nodes (CAPI controllers under the hood), version upgrades, etcd snapshot scheduling and restore, ClusterClass templates for repeatable cluster builds. The future mirror cluster (DR-4) becomes a one-click clone of an existing template.

This is meaningful for a small team operating multiple clusters: with RKE2, Rancher genuinely is your management plane. With OKD, Rancher is a UI on top of two parallel control surfaces (Rancher + OKD CVO).

### 3.3 What you assemble vs. what comes pre-built

**OKD includes (without further deployment):**

- Internal image registry (operator)
- HAProxy ingress router (operator)
- OAuth server with LDAP/OIDC/htpasswd providers
- Cluster monitoring (Prometheus, Alertmanager, Grafana, Thanos optional)
- Cluster logging (optional operator: Loki or EFK)
- Console / web UI
- SCCs and OpenShift Projects
- Machine Config Operator for OS management
- Cluster Version Operator for atomic upgrades

**RKE2 includes:**

- ingress-nginx (toggleable; can disable to bring your own)
- CoreDNS, metrics-server, Helm controller
- CIS-aligned defaults; FIPS-mode binary available

**RKE2 needs you to deploy yourself:**

- Image registry (Harbor is the common answer; or external pull-through)
- OAuth/OIDC for cluster auth (Keycloak/Dex/Authentik in front of AD)
- Monitoring stack (`kube-prometheus-stack` is the standard)
- Logging (Loki + Promtail or EFK)
- Pod-security policy engine (Kyverno or Gatekeeper)
- Cert-manager for workload TLS (also recommended on OKD)

This is where the "OKD is batteries-included" argument has weight — but only if you intend to use the OKD batteries. For a user who is deploying Keycloak in front of AD anyway (per G-4 in the design doc), running their own monitoring stack to integrate with existing enterprise observability, and using Harbor as a global org registry, the OKD batteries are net work to disable or migrate away from, not net work saved.

### 3.4 Upgrade model

**OKD:** Cluster Version Operator pulls a release image and atomically upgrades the entire stack — kubelet, CRI-O, OS (via MCO + ostree), operators, kube-apiserver. One command (`oc adm upgrade`) drives the whole thing. Strong consistency guarantee; less flexibility (kubelet version is bound to OKD release).

**RKE2:** RKE2 binary version drives kubelet/control-plane versions. Upgrades are per-node (drain + replace binary + restart) and Rancher orchestrates them when Rancher provisions the cluster. CSI drivers, GPU Operator, ingress, monitoring all upgrade independently. Weaker integration; more flexibility (you can pin kubelet to 1.30 while running newer versions of GPU Operator, for example).

### 3.5 Security baselines

**OKD:** Hardened by default. SCCs prevent most workloads from running as root or with elevated privileges unless you grant a specific SCC. SELinux enforcing on FCOS/SCOS by default. OAuth integrated. This is "secure-by-default" in the strongest sense.

**RKE2:** Also "secure-by-default" but in a different idiom. CIS Kubernetes Benchmark-compliant when `profile: cis` is set. SELinux supported on RHEL hosts. **FIPS 140-2 mode available** (BoringCrypto-compiled binaries) — relevant if there's any government/regulated workload exposure. Pod Security Admission needs explicit configuration; Kyverno or Gatekeeper for policy. Equivalent security posture is achievable but is configuration you write rather than configuration you inherit.

### 3.6 Documentation and community fit

**OKD:** Documentation is a subset of OCP documentation, frequently lagging on detail for community-only paths (e.g., RHEL workers, GPU Operator on OKD specifically). Mailing lists and the OKD Working Group are responsive but small.

**RKE2:** Documentation is direct Rancher/SUSE docs, well-maintained. Larger general-purpose Kubernetes community since RKE2 is closer to "vanilla" — Stack Overflow answers for k8s problems usually apply.

---

## 4. HPC fit

### 4.1 The Slurm question

The user's HPC center keeps Slurm as the primary scheduler. Slinky is "interesting" but they will not converge the entire bare-metal Slurm cluster onto k8s.

The relevant Slinky options for this user:

| Slinky component | What it does | Realistic use here |
|---|---|---|
| **slurm-operator** | Run a Slurm cluster *inside* Kubernetes as pods | Small, ephemeral Slurm clusters for specific use cases (e.g., a Slurm-aware ML training job inside the GPU cluster). Doesn't replace the bare-metal Slurm. |
| **slurm-bridge** | Make Slurm the *Kubernetes scheduler* on a converged node pool | Only if you want some k8s nodes to be schedulable from the existing Slurm controller — e.g., an overflow tier where the GPU inference cluster's spare capacity can take Slurm jobs at night. Probably not day-1 territory for this user. |
| **slurm-client / images** | Library + container images for Slurm components | Building blocks; used by both of the above |

Slinky requirements (per [SchedMD docs](https://slinky.schedmd.com/projects/slurm-operator)): Kubernetes ≥ v1.29, Slurm ≥ 25.11, cgroup v2. **Both OKD 4.17+ and RKE2 1.30+ meet the k8s requirement.** Cgroup v2 is default on FCOS/SCOS and available on RHEL 9.

**Where each platform stands:**

- RKE2 is the more commonly-tested target for Slinky in HPC contexts. Containerd, plain RHEL hosts, no MCO interfering with cgroup config — fewer moving parts when something doesn't work.
- OKD adds the SCC + MCO layer. Slinky on OpenShift has been demonstrated but requires SCCs to grant the required privileges to slurm-operator pods, and the slurmd image (built on Ubuntu 24.04, GLIBC 2.38) needs to run as a non-root SCC-compatible workload, which means custom SCC wiring. Doable, more friction.

For "we want the door open to Slinky later" — RKE2 has less friction. Not a deal-breaker for OKD; a real advantage for RKE2.

### 4.2 GPU stack

The NVIDIA GPU Operator is supported and well-documented on both platforms. Rancher and Red Hat both publish official guides. Specifics:

- **B200 requires driver branch R570+** (NVIDIA GPU Operator docs cite 570.133.20+ for HGX B200). **B300 driver branch is TBD** until B300 hardware is in hand and NVIDIA's compatibility matrix is verified — assume the latest production branch at that time. Both platforms get drivers via the GPU Operator's containerized driver pod, not host install.
- **L40 + B200 + B300 in the same fleet:** Different GPU pools labelled by Node Feature Discovery; multiple ClusterPolicy / per-node-pool driver branch configurations. Same approach on both platforms.
- **GPU Operator install/upgrade impact differs by platform:**
  - **RKE2:** the toolkit DaemonSet writes containerd config and SIGHUPs containerd. Because RKE2 supervises containerd, the SIGHUP cascades into an RKE2 restart on the node — kubelet bounces, all pods on the node briefly NotReady. Per [NVIDIA's docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/install-gpu-operator.html) this happens "during installation and upgrades," so plan a maintenance window or rolling-drain for any toolkit-image bump.
  - **OKD/OpenShift:** the toolkit DaemonSet writes a CRI-O drop-in at `/etc/crio/conf.d/99-nvidia.toml` (per [NVIDIA Container Toolkit install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) and the GPU Operator's CDI/drop-in default behavior) and triggers a CRI-O reload. **This does not go through MachineConfig and does not trigger MCO drain/reboot.** Kubelet is a separate systemd unit on OKD and is not affected by CRI-O reload. The blast radius is scoped to CRI-O, not the whole node agent. CRI-O's [partial-reload model](https://github.com/cri-o/cri-o/blob/main/docs/crio.conf.5.md) is "designed to be non-disruptive to running containers when only reloading supported configuration options." GPU containers may briefly lose GPU access depending on whether the toolkit issues SIGHUP/reload or a full `systemctl restart crio` — the docs don't pin this down for the Operator's containerized toolkit specifically; the manual install guide says `systemctl restart crio` but the Operator may follow the SIGHUP pattern it uses for containerd.
  - **Driver-only upgrades** are online on both platforms via NVIDIA's GPU driver upgrade controller (drains GPU pods only via `gpuPodDeletion`).
  - **Cluster OS upgrades** differ: RKE2 binary upgrade is per-node drain + restart; RHCOS upgrade on OKD is MCO-driven drain + reboot, and the GPU Operator coordinates a per-RHCOS-version DaemonSet transition using the [Driver Toolkit (DTK)](https://www.redhat.com/en/blog/entitlement-free-deployment-of-the-nvidia-gpu-operator-on-openshift) — kernel-module compatibility is handled automatically.
  - See `design-rke2.md` §6.3 for the RKE2 three-scenario upgrade table.

### 4.3 Lustre

DDN's `exa-csi-driver` supports both OpenShift and generic Kubernetes:

- **On OpenShift/OKD:** uses the Kernel Module Management Operator (KMM) to build and load the Lustre kernel module against the running FCOS/SCOS kernel. Ties module rebuilds to OKD's release cadence. Documented but adds a moving part.
- **On RKE2:** modules installed via standard package management on the host (Puppet `dnf install ddn-lustre-client`, exact pkg name per DDN's RHEL repo). Driver runs as a regular Helm install. Significantly fewer moving parts because the host OS is RHEL with normal package management.

For this user, the RHEL-host path is operationally cheaper and matches existing Puppet patterns for HPC node provisioning.

### 4.4 RDMA / GPUDirect networking

Both platforms support the NVIDIA Network Operator + Mellanox OFED. Implementation effort is similar. No clear winner.

### 4.5 Large image pulls

B200/B300 inference images can be 10–20 GB. Pull-through cache (Harbor with proxy projects, or zot, or a registry mirror) is the standard answer on both platforms. OKD's internal registry can be configured as a pull-through cache; on RKE2 you stand up Harbor anyway.

---

## 5. Operational lift comparison

This table assumes day-1 production deployment of one cluster.

| Day-1 task | OKD | RKE2 |
|---|---|---|
| Install platform | `openshift-install` (agent-based or UPI) | `curl -sfL get.rke2.io \| sh -` on each server, `rancher` provisioning UI for fleet |
| Identity provider | Configure built-in OAuth → AD LDAP or OIDC | Deploy Keycloak (or Dex) → AD; configure RKE2 OIDC |
| Image registry | Configure built-in registry storage (Pure CSI PV) | Deploy Harbor + Pure CSI PV |
| Ingress | Already there | Already there (ingress-nginx) |
| Monitoring | Configure built-in PVs; add Alertmanager routes | Deploy `kube-prometheus-stack`; configure PVs and routes |
| Logging | Optional; install via operator | Deploy Loki + Promtail via Helm |
| Cert manager | Optional install | Standard install |
| GPU Operator | Helm/operator install | Helm install |
| Pure CSI | Helm install | Helm install |
| DDN Lustre CSI | Helm install + KMM build pipeline | Helm install + Puppet for host module |
| Etcd backup | **Build** CronJob with cluster-backup.sh | **Already enabled by default** (2×/day to local + S3) |
| AD / SSO | Built-in OAuth or Keycloak | Keycloak (mandatory) |
| SCCs / pod security | Default SCCs already in place | Configure PSA + Kyverno/Gatekeeper |

**Tally:** OKD saves you ~3 deployments (Keycloak, Harbor, monitoring stack) but costs you the MachineConfig learning curve, the etcd-backup-CronJob build, and the Lustre KMM pipeline. Net day-1 effort is roughly comparable. Day-2 effort on workers is meaningfully lower for RKE2 because Puppet is unchanged.

---

## 6. Risk profile and caveats (read these before locking RKE2)

These are the honest cons for RKE2 that the comparison-by-feature view glosses over.

### 6.1 You own more pieces

The five things RKE2 doesn't include (registry, OAuth, monitoring, logging, policy) are all production systems with their own backup, upgrade, and incident lifecycles. Each needs a runbook and an on-call story. The aggregated cost of "we own five more things" can exceed the savings from "we don't fight MCO."

Mitigation: most enterprise shops already have most of these somewhere (an org-wide Harbor, a centralized Keycloak, a Prometheus or Datadog tenant). If you can plug into existing instances rather than spin up cluster-local copies, the lift drops sharply. Worth inventorying before committing.

### 6.2 Less prescriptive guidance

OKD ships with strong defaults. RKE2 ships with safe defaults but more knobs. For a small team, "we do what the docs say" is faster than "we benchmark Calico vs Cilium and pick a CNI." Plan for an architecture-decisions phase before deploy.

### 6.3 Vendor support model

If something goes deeply wrong on OKD, you can buy OCP support from Red Hat and (with caveats) get help. RKE2 support is via SUSE (paid Rancher Prime) or the open-source community. Both are credible; the procurement process for SUSE support might be new for a Red Hat shop.

### 6.4 GPU Operator restart caveat

On RKE2, installing the NVIDIA GPU Operator restarts containerd which restarts RKE2 on each node. Plan the first install during a maintenance window, and set the operator's `toolkit` daemonset to not run on control-plane nodes if you don't want the API to flap.

### 6.5 SCOS is closer to RHEL than people assume

A counter-caveat: the FCOS→SCOS transition narrows the OS-divergence argument considerably. SCOS is CentOS Stream-based, same kernel line as RHEL, same package set. If the team's discomfort with FCOS was "it's Fedora-flavored weirdness," SCOS fixes most of that. Worth re-reading the SCOS migration notes (linked in §DR-2 of the main design doc) before letting "OS feel" weigh too heavily.

### 6.6 Slinky is young

slurm-operator v0.1.0 shipped November 2024; v0.3.0 in June 2025. Useful in production but expect some sharp edges on either platform. Don't make Slinky the deciding factor; treat it as "available" rather than "production-load-tested."

---

## 7. Decision criteria — which one wins for your situation

Score each criterion as it applies to your situation. (I've filled in my read; correct what's wrong.)

| Criterion | Weight (your call) | OKD | RKE2 | Winner |
|---|---|---|---|---|
| Preserves Puppet/Katello pipeline for OKD nodes | High | No | Yes | RKE2 |
| Preserves Puppet/Katello pipeline for non-OKD VMs | n/a | Yes | Yes | tie |
| Rancher provides full lifecycle for workload clusters | Medium | No | Yes | RKE2 |
| Batteries-included reduces deployment count | Medium | Yes | No | OKD |
| Red Hat ecosystem alignment | Low–Medium | Yes | No | OKD |
| FIPS 140-2 capability | Site-dependent | No | Yes | RKE2 (if needed) |
| Slinky readiness for HPC integration later | Low | Possible | Easier | RKE2 |
| Mature documentation for the user's stack | Medium | Mixed | Strong | RKE2 |
| Single-vendor support story | Medium | Red Hat | SUSE | depends on relationship |
| Default etcd backup posture | Medium | None | 2×/day + S3 | RKE2 |
| Learning curve for the team | Medium | MCO + SCCs + OKD-isms | Standard k8s + Helm | RKE2 |
| GPU Operator first-install impact | Low | None | Containerd restart | OKD |
| L40 + B200 + B300 mixed driver branches via NFD | High | Works | Works | tie (basic) |
| Kernel/driver compatibility across cluster's operating life (DTK on OKD vs precompiled-kernel-modules on RKE2) | High in HPC | Automatic via DTK + per-RHCOS-version DaemonSet | Works via precompiled images, runtime-build fallback | **OKD** (see okd-advantages.md §1.5) |
| Per-upgrade blast radius for routine GPU Operator chart bumps | Medium | CRI-O reload, kubelet unaffected | RKE2/kubelet restart | **OKD** |
| OS upgrade discipline | Medium | Atomic via CVO | Per-component, you sequence | OKD |

**Net:** for this user, the score is closer than it looked at v0.1. RKE2 still leads on the highest-weight axes (Puppet alignment, Rancher full-lifecycle, default etcd backup, learning curve), but OKD has picked up two more real wins on the GPU-lifecycle axis after the verification work — automatic kernel/driver compatibility via DTK and a smaller per-upgrade blast radius because CRI-O is decoupled from kubelet. For an HPC GPU fleet specifically, those two wins matter more than the rest of the OKD wins did. **Roughly 7-5 with one tie, weighted, RKE2 still leans ahead — but the GPU-axis wins on the OKD side are HPC-relevant and substantive, not generic.**

---

## 8. Recommendation

**Go RKE2 for the workload clusters. Keep Rancher-on-RKE2 as the management cluster. Use Puppet/Katello for all RHEL hosts including RKE2 servers and agents.** Specifically:

1. The OKD-Infra cluster becomes RKE2-Infra: 3 RHEL server nodes (control plane + etcd) on VMware, N RHEL agent nodes on bare metal, provisioned by Foreman, configured by Puppet, lifecycled by Rancher.
2. The OKD-GPU cluster becomes RKE2-GPU: same topology, agent nodes are the L40 / B200 / B300 bare metal.
3. Rancher gets a real role beyond visibility — it provisions and upgrades both downstream clusters. Etcd snapshots come "for free" and S3-replicate to the same Pure FlashBlade you're already deploying.
4. The Lustre integration becomes simpler: Puppet `dnf install` the DDN Lustre client on agent nodes; deploy DDN exa-csi-driver via Helm.
5. Stand up Keycloak in the management RKE2 cluster (or a small dedicated one) as the OIDC IdP for both workload clusters. Keycloak federates to AD. This was already the better long-term answer in G-4 of the OKD design doc.
6. Stand up Harbor as the org image registry with Pure FlashBlade backing. This serves both clusters and replaces OKD's internal registry.
7. Deploy `kube-prometheus-stack` + Loki via Rancher's monitoring/logging integration. (Rancher ships these as "apps" with sensible defaults.)

**Do not commit yet if any of these are true:**

- You have an audit/compliance constraint that mandates Red Hat-supported Kubernetes specifically.
- The team's bandwidth to operate Harbor + Keycloak + monitoring stack as new components is genuinely thin and there's no existing org instance to plug into.
- There's a stakeholder commitment to OKD already made that this would unwind.

If any of those apply, the calculus changes and OKD-A (SCOS workers, MCO-managed) becomes the right pick.

---

## 9. Open questions to resolve before locking RKE2

1. Does the org already operate Harbor or another OCI registry? Can the new clusters use it as a pull-through cache instead of standing one up per environment?
2. Does the org already operate Keycloak, ADFS-as-OIDC, or another OIDC provider? Or is OAuth2-Proxy in front of plain LDAP enough?
3. Does the org already have Prometheus/Grafana at scale? Federate to it, or stand up cluster-local stacks?
4. SUSE Rancher Prime support contract — needed, or comfortable with community RKE2 + Rancher?
5. FIPS 140-2 — required for any workload? If yes, RKE2's BoringCrypto build is the answer; OKD doesn't have an equivalent.
6. Slinky — capability we want available, or actively planned for a workload? Affects how much we tune for it day-1.

---

## Sources

**OKD platform**

- [Fedora CoreOS — OKD 4 Architecture](https://docs.okd.io/latest/architecture/architecture-rhcos.html)
- [Machine configuration overview — OKD 4](https://docs.okd.io/latest/machine_configuration/index.html)
- [Node OS changes to SCOS — OKD upgrade notes](https://okd.io/docs/project/upgrade-notes/from-4-15/fcos-to-scos-migration/)
- [OCP 4.16 release notes — RHEL compute deprecation](https://docs.openshift.com/container-platform/4.16/release_notes/ocp-4-16-release-notes.html)

**RKE2 platform**

- [RKE2 HA install guide](https://docs.rke2.io/install/ha)
- [RKE2 CIS Hardening Guide](https://docs.rke2.io/security/hardening_guide)
- [RKE2 backup and restore (etcd snapshots)](https://docs.rke2.io/datastore/backup_restore)
- [RKE2 GPU Operators add-on guide](https://docs.rke2.io/add-ons/gpu_operators)
- [Rancher: Kubernetes clusters in Rancher setup](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-clusters-in-rancher-setup)
- [Rancher: Backing up Rancher-launched clusters](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/backup-restore-and-disaster-recovery/back-up-rancher-launched-kubernetes-clusters)

**NVIDIA on each**

- [NVIDIA GPU Operator — Platform support](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/platform-support.html)
- [NVIDIA GPU Operator — Getting started](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html)
- [Install NVIDIA GPU Operator on RKE2 (community walkthrough)](https://thenewstack.io/install-a-nvidia-gpu-operator-on-rke2-kubernetes-cluster/)

**Storage**

- [Pure Storage and Rancher technical guide (PDF)](https://www.purestorage.com/content/dam/pdf/en/white-papers/wp-rancher-service-orchestrator.pdf)
- [pure-csi Helm chart](https://github.com/purestorage/helm-charts/tree/master/pure-csi)
- [DDN exa-csi-driver](https://github.com/DDNStorage/exa-csi-driver)
- [DDN exascaler-csi-file-driver in Red Hat catalog](https://catalog.redhat.com/en/software/containers/ddn/exascaler-openshift-file-driver/65b95e1b2a0d82543fef7879)
- [Red Hat blog: HPC workloads on OpenShift with MPI and Lustre](https://www.redhat.com/en/blog/running-hpc-workloads-with-red-hat-openshift-using-mpi-and-lustre-filesystem)

**Slinky and Slurm-on-Kubernetes**

- [Slurm Workload Manager — Slinky overview](https://slurm.schedmd.com/slinky.html)
- [SchedMD: Introducing the Slinky Project](https://www.schedmd.com/introducing-slinky-slurm-kubernetes/)
- [Slinky slurm-operator on GitHub](https://github.com/SlinkyProject/slurm-operator)
- [Slinky: The Missing Link Between Slurm and Kubernetes (CUG 2025 PDF)](https://slurm.schedmd.com/MISC25/Slinky-CUG2025.pdf)
- [Running Slurm on Amazon EKS with Slinky (AWS blog)](https://aws.amazon.com/blogs/containers/running-slurm-on-amazon-eks-with-slinky/)

**Comparative**

- [Rancher vs OpenShift (OpenLogic)](https://www.openlogic.com/blog/rancher-vs-openshift)
- [Rancher vs OpenShift (Pure Storage Blog)](https://blog.purestorage.com/purely-educational/rancher-vs-openshift/)
- [Kubernetes deployment options for on-prem clusters (arXiv)](https://arxiv.org/html/2407.01620v1)
