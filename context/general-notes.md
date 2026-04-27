# General Notes — Reference Doc

**Status:** Living reference, not a design doc
**Date:** 2026-04-24
**Purpose:** Catch-all for the technical concepts and comparisons that have come up during the OKD/RKE2 design work. Bookmark for future reference. Add to it as new topics surface.

> Things in here are *background knowledge*, not project decisions. Project decisions live in `design.md`, `design-rke2.md`, `okd-vs-rke2.md`, `okd-advantages.md`. Decisions about specific vendor choices live in `~/.claude/projects/-home-selutha-claude-okd/memory/project_vendors.md`.

---

## Table of contents

1. [The container stack — who talks to whom](#1-the-container-stack--who-talks-to-whom)
2. [CRI — Container Runtime Interface](#2-cri--container-runtime-interface)
3. [CNI — Container Network Interface](#3-cni--container-network-interface)
4. [CSI — Container Storage Interface](#4-csi--container-storage-interface)
5. [OCI runtimes — runc vs crun (and others)](#5-oci-runtimes--runc-vs-crun-and-others)
6. [cgroups (v1 vs v2) and what they do for HPC](#6-cgroups-v1-vs-v2-and-what-they-do-for-hpc)
7. [RKE2 vs vanilla Kubernetes (kubeadm)](#7-rke2-vs-vanilla-kubernetes-kubeadm)
8. [eBPF and what "eBPF-based observability" means](#8-ebpf-and-what-ebpf-based-observability-means)
9. [NFD and how the GPU Operator targets nodes](#9-nfd-and-how-the-gpu-operator-targets-nodes)
10. [etcd — quorum math, performance, snapshots](#10-etcd--quorum-math-performance-snapshots)
11. [Sources](#sources)

---

## 1. The container stack — who talks to whom

```text
┌─────────────────────────────────────────────────┐
│ kubelet                                         │  ← Kubernetes
└────────────────────┬────────────────────────────┘
                     │ CRI gRPC API
                     ▼
┌─────────────────────────────────────────────────┐
│ CRI implementation                              │
│   (containerd or CRI-O)                         │
└────────────────────┬────────────────────────────┘
                     │ OCI runtime spec
                     ▼
┌─────────────────────────────────────────────────┐
│ OCI runtime                                     │
│   (runc, crun, kata-runtime, runsc, youki)      │
└────────────────────┬────────────────────────────┘
                     │ syscalls (clone, unshare,
                     │   pivot_root, mount, etc.)
                     ▼
┌─────────────────────────────────────────────────┐
│ Linux kernel (cgroups, namespaces, seccomp)     │
└─────────────────────────────────────────────────┘
```

**Key point:** these are layers, not alternatives. containerd doesn't compete with runc — containerd uses runc (or crun) underneath. CRI implementations and OCI runtimes are at different levels.

**What competes with what:**

| Layer | Options |
|---|---|
| CRI implementations | containerd, CRI-O, (historically dockershim — removed in K8s 1.24) |
| OCI runtimes | runc, crun, kata-runtime, runsc (gVisor), youki |
| CNI plugins | Canal, Calico, Cilium, Flannel, Multus, Antrea, others |
| CSI drivers | One per storage backend (pure-csi, ddn-exa-csi, vmware-csi, etc.) |

---

## 2. CRI — Container Runtime Interface

**What it is:** the gRPC API contract that kubelet uses to start/stop containers and manage their lifecycle. Standardized so kubelet doesn't have to care about which container runtime is underneath.

**Two production implementations:**

| | containerd | CRI-O |
|---|---|---|
| Maintainer | CNCF graduated 2019 | CNCF graduated 2023 |
| Default OCI runtime | runc | crun (in modern OpenShift) |
| Default in | EKS, GKE, AKS, k3s, **RKE2**, kubeadm, Docker Desktop, Rancher Desktop | **OpenShift / OKD**, MicroShift |
| Philosophy | General-purpose container runtime; works beyond Kubernetes | Kubernetes-only; minimalist; built specifically for the CRI spec |
| Adoption | Dominant in cloud-native ecosystem | Concentrated in Red Hat ecosystem |

**Trend (as of 2026):** no broad shift in either direction. Both are stable, both are CNCF-graduated, and adoption is driven primarily by which platform you choose. CRI-O is growing within its niche (security-conscious enterprise OpenShift shops), but it's not displacing containerd elsewhere.

**Practical implication for this project:** the platform choice (RKE2 vs OKD) carries the CRI choice with it. You don't pick CRI-O and OpenShift independently; you pick OpenShift and CRI-O comes with it. Same for RKE2 → containerd.

---

## 3. CNI — Container Network Interface

**What it is:** the interface plugin that Kubernetes uses to give pods IP addresses, route traffic between nodes, and (depending on plugin) enforce NetworkPolicy.

**The four CNIs RKE2 ships:**

| CNI | Mechanism | NetworkPolicy? | Notable feature |
|---|---|---|---|
| **Canal** (RKE2 default) | Flannel for inter-node overlay (VXLAN) + Calico for intra-node + NetworkPolicy enforcement | Yes (via Calico component) | Historical hybrid for "overlay + policy with minimum friction" |
| **Calico** | Multiple data planes: IPIP/VXLAN overlays, BGP, eBPF | Yes (richer than standard k8s NP — adds GlobalNetworkPolicy, NetworkSet CRDs) | BGP if your fabric supports it; eBPF data plane option |
| **Cilium** | eBPF programs in the kernel; bypasses iptables/conntrack/kube-proxy | Yes (identity-based, L7-aware) | Full kube-proxy replacement, Hubble observability, identity-based and L7 policies |
| **Flannel-only** | VXLAN overlay, no policy | **No — NetworkPolicy is silently ignored** | Simplest, not appropriate for production |

**OKD default:** OVN-Kubernetes — comparable in capability to Cilium (overlay + NetworkPolicy + egress IP), but not eBPF-native.

**Project decision:** **Cilium on both clusters in the RKE2 design** (per `design-rke2.md` §3.4), for fleet-wide consistency and Hubble observability on the GPU cluster.

---

## 4. CSI — Container Storage Interface

**What it is:** the standardized interface that lets storage vendors plug into Kubernetes without modifying core code. Each storage backend has its own CSI driver implementing the spec.

**For this project:**

| Backend | CSI driver | Use case |
|---|---|---|
| Pure FlashArray (block) | `pure-csi` | General PVs (Postgres, Redis, app PVCs); RWO mostly |
| Pure FlashBlade (file/S3) | `pure-csi` (file mode) and FlashBlade-native S3 (no CSI needed) | RWX file workloads; Harbor's image storage backend uses S3 directly |
| DDN Lustre (HPC parallel FS) | `ddn-exa-csi-driver` (DDNStorage/exa-csi-driver) | Training data, model artifacts, scratch on the GPU cluster |

**RKE2 vs OKD path differences:**

- On RKE2: kernel modules for storage clients (Lustre) installed via Puppet `dnf install ddn-lustre-client`. CSI driver is a Helm install on the cluster.
- On OKD: kernel modules built via Kernel Module Management (KMM) operator in `openshift-kmm` namespace; CSI driver via OperatorHub.

CSI itself is the same on both — only the host-side kernel module lifecycle differs.

---

## 5. OCI runtimes — runc vs crun (and others)

**What they are:** the low-level binaries that actually create the namespaces, apply cgroups, and exec the container process. They run *under* containerd or CRI-O.

| | runc | crun | kata-runtime | runsc (gVisor) | youki |
|---|---|---|---|---|---|
| Language | Go | C | Go (driver, with VM) | Go (userspace kernel) | Rust |
| Container start time | Baseline | ~50% faster | Slow (VM boot) | Slow | Fast |
| Memory per container | ~10 MB | ~few hundred KB | High (VM) | Medium | Low |
| Isolation | Namespace + cgroups | Same | **Hardware VM** | **Userspace kernel intercepts syscalls** | Same as runc |
| Default in | containerd, k8s default-default | CRI-O / OpenShift / Podman | Opt-in for multi-tenant | Opt-in for sandboxing | Experimental |

### runc → crun migration trend

Real shift in the Red Hat-aligned ecosystem. Podman, RHEL container tooling, and OpenShift's CRI-O have all moved to **crun as default**. The cloud-native ecosystem (containerd-based) still uses runc. Both implement the OCI spec correctly; switching is workload-transparent.

### Why runc still wins for most situations

The advertised crun benefits — faster start, smaller memory footprint — show up most for:

- High-churn workloads (CI/CD runners, FaaS, batch jobs)
- Memory-dense nodes (1000+ containers per node)
- Cold-start-sensitive paths

For long-running services (inference, platform tier), the difference is invisible. **For this project's workloads (B200/B300 inference, platform-tier services, general HPC services), the runtime layer is operationally invisible.** The switch isn't worth the operational cost.

### How to switch RKE2 from runc to crun (if you ever decide to)

1. Install `crun` on every node via Puppet (`dnf install crun`).
2. Override RKE2's containerd config template at `/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl` (or `config-v3.toml.tmpl` for containerd 2.0):

   ```toml
   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun]
     runtime_type = "io.containerd.runc.v2"
     [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun.options]
       BinaryName = "/usr/bin/crun"
       SystemdCgroup = true
   ```

3. Create a Kubernetes RuntimeClass:

   ```yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: crun
   handler: crun
   ```

4. Either opt workloads in via `runtimeClassName: crun` per pod, or set crun as cluster-wide default by setting `default_runtime_name = "crun"` in the containerd template.
5. Restart RKE2 service on each node. Drain/uncordon to avoid disruption.

**Recurring operational cost:** RKE2 binary upgrades may rewrite the containerd config; you'd need to re-validate the override after each RKE2 upgrade. This is the real ongoing burden.

**Compatibility caveats:**

- NVIDIA Container Toolkit registers as an OCI prestart hook; crun supports OCI hooks the same way runc does, but it's less commonly tested in the wild.
- Off the well-trodden RKE2 community path; troubleshooting may take longer.

### kata-runtime and gVisor — when they matter

Both add **stronger isolation** at performance cost. Use cases:

- Multi-tenant clusters running untrusted workloads.
- Compliance environments requiring VM-level isolation per container.

Neither is relevant for this project (single-tenant HPC center, trusted workloads). Worth knowing they exist.

---

## 6. cgroups (v1 vs v2) and what they do for HPC

**What they are:** Linux kernel feature that groups processes and limits / accounts for their resource usage (CPU, memory, IO, PIDs, etc.). Containers are processes inside cgroups; container runtimes use cgroups to enforce resource requests/limits.

### cgroup v1 vs v2

| | cgroup v1 | cgroup v2 |
|---|---|---|
| Hierarchy | Multiple, one per controller (one tree for memory, one for CPU, etc.) | **Single unified tree** |
| Status | Legacy | Modern default |
| RHEL 9 default | n/a | **Yes (v2 by default)** |
| systemd-as-PID1 default | n/a | **Yes (modern systemd)** |
| Controllers | Each managed independently | All managed through unified hierarchy |
| Subtree delegation | Limited | Native, used by k8s, Slinky, rootless containers |
| Pressure Stall Information (PSI) | No | **Yes** — kernel-reported memory/CPU/IO pressure metrics |
| Rootless containers | Limited | Better support |

### Why v2 matters for HPC and Kubernetes

- **Slinky (slurm-operator) requires cgroup v2** ([requirement documented in slurm-operator README](https://github.com/SlinkyProject/slurm-operator)). RHEL 9 defaults to v2; SCOS/FCOS default to v2; both qualify.
- **PSI metrics** give kernel-level signal on resource pressure (memory pressure, CPU contention, IO stalls) — useful for HPC observability and autoscaling decisions.
- **Subtree delegation** is what lets a process create child cgroups and manage them — needed for Slurm's job-level resource enforcement and for rootless container runtimes.
- **CloudNativePG, Postgres, and modern databases** benefit from v2's better IO accounting.

### The Slinky cgroup constraint (worth knowing)

[StackHPC's evaluation](https://www.stackhpc.com/slinky-backfill.html) of Slinky on Dawn (Cambridge HPC) noted: *"Slinky can't enable Slurm's cgroup plugins"* because of *"Kubernetes lacks native cgroup subtree delegation, preventing per-job resource enforcement."*

**Important nuance:** this is a **kubelet-level limitation**, not a runtime-level one. Switching the OCI runtime (runc → crun) does NOT fix it — kubelet's pod-cgroup management is the bottleneck. The `slurm-bridge` project (Pattern B) is SchedMD's stated path forward for this case.

### Both runc and crun support cgroup v2 cleanly

The historical "crun had v2 first / better" advantage has evaporated. Modern runc is feature-complete on cgroup v2. Either runtime works fine on RHEL 9 + RKE2.

---

## 7. RKE2 vs vanilla Kubernetes (kubeadm)

**Both run the same Kubernetes** — same APIs, same kubectl, same workload manifests, same conformance test suite. RKE2 is not a fork; it's the upstream binaries plus a curated set of supporting components, packaged together.

### Architectural difference

**Vanilla (kubeadm):** an *installer*. Bootstraps the control plane and gets out of your way. Every other piece — runtime, CNI, CSI, ingress, monitoring, certs — is yours to install, configure, and upgrade independently.

**RKE2:** a *distribution*. Single Go binary that bundles tested versions of containerd + runc + Kubernetes components + etcd + Helm controller + default CNI + default ingress. One systemd unit, one upgrade path.

### What RKE2 ships that kubeadm doesn't

| Component | Vanilla k8s | RKE2 |
|---|---|---|
| Container runtime (containerd) | Install separately | **Embedded** |
| etcd | Separate install / kubeadm-managed; manual cert rotation | **Embedded as static pod**; auto-managed certs; 2×/day snapshots default; S3 upload built-in |
| Helm controller | Not present | **Embedded** — drop manifests, RKE2 deploys |
| ingress-nginx | Install yourself | **Bundled, optional** (toggleable) |
| CoreDNS, metrics-server, snapshot controller | Install yourself | **Bundled** |
| CIS hardening profile | Manual config | **`profile: cis` in config.yaml**, applied automatically |
| FIPS 140-2 compliance | Not available out of box | **Available** (BoringCrypto-compiled binaries) |

### Control-plane supervision model

- **Vanilla (kubeadm):** kube-apiserver/scheduler/controller-manager run as static pods managed by kubelet via `/etc/kubernetes/manifests/`.
- **RKE2:** same static-pod pattern, but supervised by the **rke2 binary itself** (rke2-server systemd unit). Containerd, etcd, kubelet — all wrapped under one rke2-server unit. One process tree, one log stream (`journalctl -u rke2-server`), one upgrade path.

### Versioning

RKE2 versions look like `v1.30.5+rke2r1` — first part is upstream Kubernetes version, suffix is RKE2 release iteration. Tracks upstream within weeks.

### When each is the right answer

**RKE2 wins:** Rancher integration, enterprise defaults out of box (CIS, FIPS, SELinux-aware), single-binary upgrade story, bundled component testing.

**Vanilla wins:** maximum per-component version control, deeply unusual stack requirements, existing pipelines targeting vanilla, team that wants to learn Kubernetes plumbing.

---

## 8. eBPF and what "eBPF-based observability" means

**eBPF (extended Berkeley Packet Filter):** Linux kernel feature that lets small, sandboxed programs run inside the running kernel at specific hook points (packet receive, syscall entry, function call, etc.) **without** patching the kernel or loading kernel modules.

### Key properties

- **Kernel-space execution** — no copy-to-userspace overhead per event.
- **Verified before load** — eBPF verifier proves the program won't crash the kernel or loop forever. Safety property unique to eBPF.
- **Hot-loaded** — no reboot, no kernel-module rebuild, no compilation step at runtime.
- **Per-event Kubernetes context** — pod, namespace, labels, container ID — available in eBPF programs without ptrace overhead.
- **JIT-compiled** to native machine code by the kernel for performance.

### Why it matters

Traditional observability tools (tcpdump, iptables, strace) either copy events to userspace (expensive) or do sequential rule-list processing (slow at scale). eBPF programs run at hook points with O(1) map lookups and O(1) operations. **Same observation depth at orders of magnitude less overhead.**

### Hubble (Cilium's observability layer)

Hubble taps the eBPF event stream that Cilium's data plane produces and surfaces:

- **Per-flow records with Kubernetes identity** — not "10.42.3.5 → 10.42.7.12" but `payments/api → orders/db` with namespaces, labels, and policy verdict.
- **Service map** — auto-generated graph of cluster service dependencies.
- **L7 visibility** — HTTP method/path, gRPC method, DNS query, Kafka topic.
- **Drop/deny visibility** — which policy denied a flow and which 5-tuple was involved.

Architecture: Hubble server runs in the Cilium agent on each node (gRPC API). Hubble Relay aggregates across nodes. Hubble CLI and UI consume the relay.

### Other eBPF tools to know

- **Falco** — runtime security; flags suspicious syscalls.
- **Pixie** — application observability; auto-instruments services.
- **Inspektor Gadget** — debugging toolkit for k8s, eBPF-based.
- **bpftrace** — high-level scripting language for ad-hoc kernel tracing.

---

## 9. NFD and how the GPU Operator targets nodes

**Node Feature Discovery (NFD)** detects hardware features on each node and applies labels. The NVIDIA GPU Operator reads those labels to decide which nodes get its DaemonSets.

### The label that matters

> *"GPU worker nodes are identified by the presence of the label `feature.node.kubernetes.io/pci-10de.present=true`. The value `0x10de` is the PCI vendor ID that is assigned to NVIDIA."* ([NVIDIA GPU Operator docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html))

NFD detects the PCI vendor ID `0x10DE` (NVIDIA) on the node's PCIe bus and applies the label. The GPU Operator's DaemonSets (toolkit, driver, device-plugin, validator, MIG manager, DCGM exporter) all use this label as their nodeSelector.

### Practical implication

In a mixed cluster (GPU + non-GPU nodes), GPU Operator components only land on GPU nodes. The mgmt cluster's RKE2 server VMs (no GPUs) never get a toolkit pod. So a GPU Operator chart upgrade only restarts containerd on GPU-bearing nodes — the control plane and non-GPU agents are unaffected.

### Excluding specific nodes

You can prevent deployment on individual GPU nodes by labeling them `nvidia.com/gpu.deploy.operands=false` or `nvidia.com/gpu.deploy.driver=false`.

---

## 10. etcd — quorum math, performance, snapshots

### Quorum math

| Cluster size | Quorum needed | Failure tolerance |
|---|---|---|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | **2** |
| 7 | 4 | 3 |

**Always odd numbers.** Even numbers don't improve fault tolerance (4-node cluster's quorum is 3, same as 5; you've just added a node that can fail without helping you).

### Why 5 over 3 for production

Maintenance-window safety. With 3 nodes, draining 1 for upgrade leaves 2 — any other failure takes the cluster down. With 5 nodes, drain 1 → 4 healthy → still 1-failure-tolerant during the maintenance window.

### Performance requirements ([etcd docs](https://etcd.io/docs/v3.3/op-guide/hardware/))

- "Run etcd on a block device that can write at least 50 IOPS of 8KB sequentially, including fdatasync, in under 10ms."
- p99 fdatasync latency should be < 10ms. Spinning disks → ~10ms typical. SSDs → < 1ms typical. NVMe → < 100µs typical.
- **Don't share etcd's drive with heavy-IO workloads** — Postgres vacuums, log files, etc. can spike fsync latency past etcd's tolerance.
- Avoid network-attached storage (iSCSI). NVMe local (or NVMe-attached SAN like Pure with RoCE) is fine.

### How RKE2 handles etcd

- Embedded as a static pod managed by the rke2-server process.
- Auto-managed certs (rotation handled).
- **Default 2×/day snapshots** at 00:00 and 12:00, 5 retained locally.
- Optional S3 upload for offsite retention.
- CLI: `rke2 etcd-snapshot save` for ad-hoc snapshots.
- Restore: `rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>`.

### How OKD handles etcd

- Static pod managed by the cluster-etcd-operator on master nodes.
- Auto-managed certs.
- **No automatic snapshots** — you must build a CronJob using `cluster-backup.sh` (provided by the etcd operator). Don't forget this on a fresh OKD install.

---

## Sources

- [Kubernetes Container Runtime Interface (CRI)](https://kubernetes.io/docs/concepts/containers/cri/)
- [Kubernetes Container Runtimes documentation](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [containerd project](https://containerd.io/)
- [CRI-O project](https://cri-o.io/)
- [CNCF announces CRI-O graduation (July 2023)](https://www.cncf.io/announcements/2023/07/19/cloud-native-computing-foundation-announces-graduation-of-cri-o/)
- [runc project on GitHub](https://github.com/opencontainers/runc)
- [crun project on GitHub](https://github.com/containers/crun)
- [Red Hat: An introduction to crun](https://www.redhat.com/en/blog/introduction-crun)
- [OCI Runtime Specification](https://github.com/opencontainers/runtime-spec)
- [Kubernetes RuntimeClass documentation](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- [RKE2 Architecture (docs.rke2.io)](https://docs.rke2.io/architecture)
- [RKE2 Advanced Options (containerd template overrides)](https://docs.rke2.io/advanced)
- [Cilium overview](https://docs.cilium.io/en/stable/overview/intro/)
- [Hubble on GitHub](https://github.com/cilium/hubble)
- [eBPF Tools overview — The New Stack](https://thenewstack.io/ebpf-tools-an-overview-of-falco-inspektor-gadget-hubble-and-cilium/)
- [NVIDIA GPU Operator — Getting Started](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html)
- [Slinky slurm-operator on GitHub](https://github.com/SlinkyProject/slurm-operator)
- [StackHPC — Stop Scientists Stealing Your Nodes (Slinky/cgroup limitation)](https://www.stackhpc.com/slinky-backfill.html)
- [etcd Hardware recommendations](https://etcd.io/docs/v3.3/op-guide/hardware/)
- [etcd Performance documentation](https://etcd.io/docs/v3.5/op-guide/performance/)
- [Kubernetes cgroup v2 documentation](https://kubernetes.io/docs/concepts/architecture/cgroups/)
- [systemd cgroup v2 docs](https://systemd.io/CGROUP_DELEGATION/)
