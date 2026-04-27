# Slinky — Reading and Research Notes

**Status:** Reading list and research notes — not a design or recommendation document.
**Date:** 2026-04-24
**Purpose:** Provide background on the Slinky project so the user can decide whether/how Slurm-Kubernetes integration fits the planned cluster architecture. Every claim is sourced; quotes are reproduced verbatim where they add value. Where docs are silent, this doc says so explicitly rather than guessing.

> The user has stated: HPC center, Slurm remains the primary scheduler on bare metal, Kubernetes is a service-hosting layer beside it (not a replacement). Slinky is "interesting" but not a forcing function. This doc is reading material; pair with `okd-vs-rke2.md` and `okd-advantages.md` when deciding.

---

## 1. What Slinky is

Slinky is a project family from SchedMD (the company that develops Slurm) for integrating Slurm and Kubernetes.

> "The Slinky Project is an open source suite of integration tools designed by SchedMD to bring Slurm capabilities into Kubernetes." — [SchedMD: Introducing the Slinky Project](https://www.schedmd.com/introducing-slinky-slurm-kubernetes/)
>
> "Slinky is a toolkit of projects to integrate Slurm into Kubernetes, released under the Apache-2.0 license." — same source.

The project is hosted under the [SlinkyProject GitHub organization](https://github.com/slinkyproject) and documented at [slinky.schedmd.com](https://slinky.schedmd.com/).

---

## 2. The components

Per the [Slinky project landing page](https://slinky.schedmd.com/) and the [SchedMD Slinky overview](https://slurm.schedmd.com/slinky.html), Slinky comprises four projects:

### 2.1 slurm-operator

> "Manage and scale Slurm clusters on Kubernetes as pods." — [Slurm Workload Manager: Slinky](https://slurm.schedmd.com/slinky.html)

Source: [SlinkyProject/slurm-operator on GitHub](https://github.com/SlinkyProject/slurm-operator)

**Documented prerequisites** (from the project README):

| Component | Minimum |
|---|---|
| Kubernetes | v1.29 |
| Slurm | 25.11 |
| Cgroup | v2 |

**OS / container-runtime / Kubernetes-distribution support:** Not specified in the README.

**Release cadence:**

- v0.1.0 — November 2024
- v0.2.0 — March 2025
- v0.3.0 — June 2025

(Per [search summary on the SlinkyProject organization](https://github.com/slinkyproject); GitHub repo statistics.)

**What it manages**, per the [slurm-operator project page](https://slinky.schedmd.com/projects/slurm-operator):

> "Control plane management: Kubernetes automatically restarts crashed controller pods, providing high availability without shared filesystems"
>
> "Worker node management (NodeSets): Handles scaling, upgrades, and node state tracking"
>
> "Login node management (LoginSets): Provides user-facing submit nodes with SSSD identity management"
>
> "Hybrid support: sometimes a Slurm cluster has some, but not all, of its components in Kubernetes" — the operator is "designed [to] support these use cases."

### 2.2 slurm-bridge

> "Run Slurm as a Kubernetes scheduler. Schedule both Slurm and Kubernetes workloads with Slurm." — [Slurm Workload Manager: Slinky](https://slurm.schedmd.com/slinky.html)

Source: [SlinkyProject/slurm-bridge on GitHub](https://github.com/SlinkyProject/slurm-bridge)

**Documented prerequisites:**

| Component | Minimum |
|---|---|
| Kubernetes | v1.35 (note: newer than slurm-operator's k8s minimum) |
| Slurm | 25.11 |

**Allocation model:** "exclusive, whole node allocations are made for each pod." (Per the project README.)

**GPU support, per the README:** "Only supports the following DRA drivers: DRA Driver CPU for CPUs. DRA Example Driver for GPUs."

> Note on the GPU support text: the README explicitly names the "DRA Example Driver" as the GPU integration. As the name implies, the DRA "example" driver is a reference implementation in the Kubernetes Dynamic Resource Allocation project — not a production-grade vendor driver. **This is a maturity flag.** ([Kubernetes DRA reference](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/) — search "example driver".)

**Release timing:** "Slurm Bridge brings native Kubernetes scheduling plugin support, scheduled to be released in June 2025 and depending on Slurm 25.05." (Per [Slinky CUG 2025 reference](https://slurm.schedmd.com/MISC25/Slinky-CUG2025.pdf) summary; some sources cite June 2025 as the release window.)

**Workload separation:** Slurm Bridge supports Multi-Category Security (MCS) for converged-cluster workload isolation (per the [search summary cited above](https://slurm.schedmd.com/MISC25/Slinky-CUG2025.pdf)).

### 2.3 slurm-client (Go library) and slurm-exporter

Per the [SchedMD Slinky overview](https://slurm.schedmd.com/slinky.html) and the [SlinkyProject organization page](https://github.com/slinkyproject):

- **slurm-client** — Go client library for Slurm's REST API.
- **slurm-exporter** — Prometheus exporter for Slurm's REST API.

Both are utility components used by the operator and by users wanting Slurm metrics in Prometheus/Grafana.

### 2.4 Container images

Per [slinky.schedmd.com](https://slinky.schedmd.com/) and the [slurm-operator project page](https://slinky.schedmd.com/projects/slurm-operator):

- The reference slurmd image is built on **Ubuntu 24.04** with **GLIBC 2.38**. (From an earlier search summary of the slinky.schedmd.com page; cross-reference at install time.)
- Helm charts are provided for the operator and supporting infrastructure.

---

## 3. The two architectural shapes

Slinky offers two distinct integration patterns. Picking the wrong one for a given use case is the most common source of confusion.

### Pattern A — Slurm running inside Kubernetes (slurm-operator)

Kubernetes is the substrate; Slurm components run as pods (slurmctld, slurmdbd, slurmd, login). Useful when:

- You want a small Slurm cluster on demand on top of a k8s cluster.
- You want Slurm jobs in a cloud-native context (e.g., AI training jobs that want Slurm's job-array/sbatch ergonomics on top of k8s GPU nodes).
- The k8s cluster has spare capacity to host a Slurm cluster.

Reference architecture: [Running Slurm on Amazon EKS with Slinky (AWS Containers Blog)](https://aws.amazon.com/blogs/containers/running-slurm-on-amazon-eks-with-slinky/) describes "a controller pod running slurmctld, accounting pods with slurmdbd, worker node pods on accelerated compute instances, and login pods" with "Amazon FSx for Lustre file system mounted to the slurmd pods" and "Amazon Web Services (AWS) Network Load Balancer for traffic routing."

### Pattern B — Slurm as the Kubernetes scheduler (slurm-bridge)

Slurm becomes the scheduler for *Kubernetes pods* — pods are bound to nodes whose allocation comes from Slurm. Useful when:

- You want to converge a single hardware pool to run both Slurm jobs and Kubernetes pods, scheduled by Slurm policy (priority, fairshare, partitions, QoS).
- You're trying to backfill k8s resources with Slurm jobs (or vice versa) on shared compute.

Reference research: [StackHPC — Stop Scientists Stealing Your Nodes: Evaluating Slinky for Backfilling AI Resources](https://www.stackhpc.com/slinky-backfill.html) describes a real HPC-center evaluation. See §5 below for their findings.

---

## 4. Production deployments and performance claims

### 4.1 NVIDIA's claims

From [NVIDIA's developer blog: Running Large-Scale GPU Workloads on Kubernetes with Slurm](https://developer.nvidia.com/blog/running-large-scale-gpu-workloads-on-kubernetes-with-slurm/):

> "Production deployments at NVIDIA have demonstrated that Slinky slurm-operator scales to over 8,000 GPUs."
>
> "GPU communication benchmarks (NCCL `all-reduce` and `all-gather`) match the performance of noncontainerized Slurm deployments, with no measurable impact from the Kubernetes layer."
>
> "The article emphasizes that Slinky uses Slurm 25.11 features including configless mode, dynamic nodes, and cgroups v2 for resource isolation."

NVIDIA references **GB200 NVL72** as the GPU architecture and the **NVIDIA GPU Operator** as the integration path — same GPU Operator already planned for the user's B200/B300 cluster.

### 4.2 AWS reference architecture

The [AWS Containers Blog walkthrough](https://aws.amazon.com/blogs/containers/running-slurm-on-amazon-eks-with-slinky/) describes a deployment on EKS with FSx for Lustre and accelerated compute instances. AWS provides a [Slurm-on-EKS blueprint](https://github.com/aws-samples/data-on-eks) for hands-on deployment. The blueprint exists for slurm-operator (Pattern A), not slurm-bridge.

### 4.3 SchedMD's CUG 2025 presentation

Conference paper available as PDF: [Slinky: The Missing Link Between Slurm and Kubernetes (CUG 2025)](https://slurm.schedmd.com/MISC25/Slinky-CUG2025.pdf) by Skyler Malinowski, Alan Mutschelknaus, Marlow Warnicke, and Tim Wickberg of SchedMD.

KubeCon Europe 2025 talk slides: [Slinky — KubeCon Europe 2025](https://slurm.schedmd.com/MISC25/Slinky-KubeConEurope2025.pdf).

These are SchedMD-authored. Read for architecture intent, not for independent evaluation.

---

## 5. The honest production-readiness signal: StackHPC's evaluation

This is the single most important external read in this list. StackHPC operates the **Dawn supercomputer** for the University of Cambridge, evaluated Slinky in a real HPC environment, and published their findings.

Source: [StackHPC — Stop Scientists Stealing Your Nodes: Evaluating Slinky for Backfilling AI Resources](https://www.stackhpc.com/slinky-backfill.html)

### 5.1 Their use case

> "StackHPC sought to partition resources in their Dawn supercomputer between three pools: reserved Kubernetes nodes for isolated clusters, a Slurm cluster for batch workloads, and a baremetal Kubernetes cluster for self-service apps."

They wanted: "unused resources within a Kubernetes cluster to be automatically backfilled, but preempted by self-service applications when necessary."

### 5.2 What they evaluated

Slinky's slurm-operator with autoscaling driven by Kubernetes Horizontal Pod Autoscalers and KEDA.

### 5.3 What they found (verbatim quotes)

**On cgroup constraints:**

> "Slinky can't enable Slurm's cgroup plugins" because Kubernetes lacks native cgroup subtree delegation, preventing per-job resource enforcement.

**On scheduling races:**

> "pods were at times able to outright ignore the anti-affinity and schedule on the same node."

**On preemption:**

> "the application pod stuck in Pending while steps 3 and 4 repeat indefinitely."

### 5.4 Their conclusion

> Slinky "isn't currently suitable for this purpose" — the purpose being backfilling Slurm batch onto a converged k8s+Slurm cluster.

They remain optimistic about **Slurm Bridge** features arriving in mid-2025. (Note: the StackHPC writeup predates slurm-bridge's June 2025 release.)

### 5.5 What this means for your evaluation

The slurm-operator path (Pattern A: Slurm running on k8s) **had hard, observed problems for a converged HPC use case as of the StackHPC writeup**. The slurm-bridge path (Pattern B: Slurm scheduling k8s pods) is newer and was StackHPC's stated hope, but its production maturity at this writing is limited (k8s ≥ v1.35 requirement is recent; GPU support is via the DRA "example driver"). Re-read StackHPC if/when they publish a slurm-bridge follow-up.

---

## 6. What it would take to use Slinky in your environment

This section maps the Slinky requirements onto the user's planned stack. **Conditional and hypothetical** — the user has not committed to deploying Slinky.

### 6.1 Kubernetes version

- slurm-operator: ≥ v1.29.
- slurm-bridge: ≥ v1.35.

OKD 4.16 ships Kubernetes 1.29; OKD 4.17 ships 1.30; OKD 4.18 ships 1.31. As of 2026-04, OKD's available versions cover the slurm-operator requirement but **likely not yet** slurm-bridge's v1.35 (depending on which OKD release stream you target — verify against the OKD release page at install time).

RKE2 release cadence tracks upstream Kubernetes; 1.35 is current/near-current. Both slurm-operator and slurm-bridge requirements are reachable on RKE2.

> "An odd number (three recommended) of server nodes that will run etcd, the Kubernetes API, and other control plane services" — [RKE2 HA install guide](https://docs.rke2.io/install/ha)

### 6.2 Slurm version

slurm-operator and slurm-bridge both target **Slurm ≥ 25.11**. The user's existing bare-metal Slurm cluster's version is unknown to this doc. Verify before scoping Slinky integration.

### 6.3 Cgroup v2

Required for slurm-operator. RHEL 9 defaults to cgroup v2. SCOS / FCOS likewise. Both platforms qualify.

### 6.4 Storage

The AWS reference uses Lustre (FSx) for shared filesystem to slurmd pods. The user has DDN Lustre and the DDN exa-csi-driver. **Conceptually compatible.** Operationally untested in the user's environment.

### 6.5 GPU

GPU integration uses the NVIDIA GPU Operator. Same on either platform. Slinky's slurm-bridge specifically uses DRA-based GPU support via the "DRA Example Driver" (per the README) — production GPU scheduling via slurm-bridge is at the "this exists, may not be ready for primetime" stage.

The user's NVIDIA GPU Operator deployment for L40 / B200 / B300 inference is independent of Slinky. Slinky integration would be additive.

### 6.6 Privileges

Slurm components (slurmd in particular) need elevated privileges:

- Cgroup access for accounting/limits.
- Optional hostPath mounts for shared filesystems / Slurm spool.
- Optional privileged mode in some configurations.

On OKD this requires explicit SCC grants for the slurm-operator's service account (see [OKD SCC docs](https://docs.okd.io/latest/authentication/managing-security-context-constraints.html)). Documented but adds steps. On RKE2 the equivalent is permitting privileged pods via PSA exception or Kyverno policy carve-out — also documented, also adds steps. **Both require thought; OKD has a thicker ceremony.**

### 6.7 Networking and login

For users to submit jobs, slurm-operator deploys "LoginSets" with SSSD identity management. The user's AD (planned via Keycloak OIDC for k8s auth) would need a separate AD/SSSD integration for the Slurm login pods themselves — these are different auth surfaces.

---

## 7. Honest summary of where Slinky stands as of mid-2026

Synthesized from the citations above. Everything in this section is supported by the linked sources unless caveated.

| Aspect | State |
|---|---|
| slurm-operator general functionality | Released, multiple iterations (v0.1 → v0.3 across 2024-2025); NVIDIA reports 8,000+ GPU production scale |
| slurm-operator on RKE2 | Supported in principle; community walkthroughs exist; no SCC layer to navigate |
| slurm-operator on OKD | Supported in principle; requires SCC configuration for privileged Slurm components; less commonly documented |
| slurm-bridge general functionality | Newer (2025 release); DRA-based; k8s ≥ 1.35 required |
| slurm-bridge production GPU scheduling | Limited per its own README ("DRA Example Driver" only); maturity flag |
| Converged HPC backfill use case (Pattern B–like) | StackHPC found it not yet ready in their evaluation; slurm-bridge is the stated future path |
| Slinky-on-k8s for new ML training jobs (Pattern A) | NVIDIA reports it works at scale; AWS reference architecture exists |
| Replacement of bare-metal Slurm with Slinky-on-k8s | **Not what Slinky is designed for, and the user has explicitly said this is not the goal.** |

---

## 8. Reading list — in suggested order

Recommended reading order for someone who needs to make a "do we plan around Slinky or not?" decision.

1. **[SchedMD: Introducing the Slinky Project](https://www.schedmd.com/introducing-slinky-slurm-kubernetes/)** — short overview from the source.
2. **[Slurm Workload Manager: Slinky](https://slurm.schedmd.com/slinky.html)** — canonical project description.
3. **[slinky.schedmd.com](https://slinky.schedmd.com/)** — landing page for the four sub-projects.
4. **[SlinkyProject/slurm-operator on GitHub](https://github.com/SlinkyProject/slurm-operator)** — concrete prerequisites and architecture for Pattern A.
5. **[SlinkyProject/slurm-bridge on GitHub](https://github.com/SlinkyProject/slurm-bridge)** — concrete prerequisites for Pattern B; note the k8s ≥ v1.35 and DRA-driver caveats.
6. **[StackHPC — Stop Scientists Stealing Your Nodes](https://www.stackhpc.com/slinky-backfill.html)** — independent HPC-center evaluation. **Read this carefully.**
7. **[NVIDIA: Running Large-Scale GPU Workloads on Kubernetes with Slurm](https://developer.nvidia.com/blog/running-large-scale-gpu-workloads-on-kubernetes-with-slurm/)** — counterpoint from a vendor with skin in the game; useful for performance claims.
8. **[AWS Containers Blog: Running Slurm on Amazon EKS with Slinky](https://aws.amazon.com/blogs/containers/running-slurm-on-amazon-eks-with-slinky/)** — reference architecture for Pattern A, including Lustre and login-pod patterns.
9. **[Slinky: The Missing Link Between Slurm and Kubernetes (CUG 2025 PDF)](https://slurm.schedmd.com/MISC25/Slinky-CUG2025.pdf)** — SchedMD's own conference paper; HPC-audience-targeted.
10. **[Slinky — KubeCon Europe 2025 (PDF)](https://slurm.schedmd.com/MISC25/Slinky-KubeConEurope2025.pdf)** — SchedMD's k8s-audience presentation.
11. **[Project Slinky: Bringing Slurm Scheduling to Kubernetes — Rafay blog](https://rafay.co/ai-and-cloud-native-blog/project-slinky-bringing-slurm-scheduling-to-kubernetes)** — third-party walkthrough.
12. **[Slinky Helm Charts on GitHub](https://github.com/SlinkyProject)** — for the implementation-curious.

---

## 9. Things this doc does NOT claim

To stay honest about the limits of the research:

- This doc does not claim that Slinky is or isn't production-ready in general — production-readiness is use-case-specific. The StackHPC evaluation (Pattern B–style) was negative; NVIDIA's claim (Pattern A at scale) was positive. Both are evidence; neither is a universal verdict.
- This doc does not claim Slinky works "better" on RKE2 than OKD. It claims Slinky **has fewer install ceremonies** on RKE2 than OKD because of SCCs vs. PSA-and-Kyverno tradeoffs. Any claim about better/worse end-state performance on either platform should be tested before relying on it.
- This doc does not specify which Slinky component the user should use, or whether they should use Slinky at all. That's a design decision for the user, informed by reading the citations above.
- This doc does not extrapolate from blog posts and presentations to make claims about specific HPC sites' deployments. Where StackHPC and NVIDIA are quoted, those are their words about their environments.

---

## 10. If you decide to pilot Slinky

Suggested pilot scope, conditional on the user committing:

1. Pick **one** Slinky pattern. Pattern A (slurm-operator: Slurm-on-k8s) is more mature; Pattern B (slurm-bridge) is newer. Don't pilot both at once.
2. Pick **one** workload that the pilot will target. E.g., "ML training jobs that want sbatch ergonomics on top of the GPU cluster."
3. Pick the **k8s cluster** to host it. Likely the planned OKD-GPU or RKE2-GPU cluster — wherever the GPUs are.
4. Verify Slurm version: ≥ 25.11 in the bare-metal cluster, or run a fresh slurmctld in the pilot.
5. Validate the cgroup v2 + containerd/CRI-O behavior on test nodes before broader rollout.
6. Set a time-boxed evaluation window (e.g., 8 weeks) with explicit pass/fail criteria. Borrow StackHPC's framing — "what would make us roll it out, what would make us shelve it."
7. Don't bake Slinky into the day-1 production critical path of either cluster. Treat it as a pilot the cluster *can host*, not a workload the cluster *must run* day-1.

---

## Sources

This doc cites sources inline rather than only at the end. The full list of unique URLs referenced:

- [SchedMD: Introducing the Slinky Project](https://www.schedmd.com/introducing-slinky-slurm-kubernetes/)
- [Slurm Workload Manager: Slinky](https://slurm.schedmd.com/slinky.html)
- [slinky.schedmd.com](https://slinky.schedmd.com/)
- [SlinkyProject organization on GitHub](https://github.com/slinkyproject)
- [SlinkyProject/slurm-operator](https://github.com/SlinkyProject/slurm-operator)
- [SlinkyProject/slurm-bridge](https://github.com/SlinkyProject/slurm-bridge)
- [Slinky slurm-operator project page](https://slinky.schedmd.com/projects/slurm-operator)
- [StackHPC — Stop Scientists Stealing Your Nodes (Slinky backfill evaluation)](https://www.stackhpc.com/slinky-backfill.html)
- [NVIDIA Developer Blog — Running Large-Scale GPU Workloads on Kubernetes with Slurm](https://developer.nvidia.com/blog/running-large-scale-gpu-workloads-on-kubernetes-with-slurm/)
- [AWS Containers Blog — Running Slurm on Amazon EKS with Slinky](https://aws.amazon.com/blogs/containers/running-slurm-on-amazon-eks-with-slinky/)
- [Slinky CUG 2025 PDF (SchedMD)](https://slurm.schedmd.com/MISC25/Slinky-CUG2025.pdf)
- [Slinky KubeCon Europe 2025 PDF (SchedMD)](https://slurm.schedmd.com/MISC25/Slinky-KubeConEurope2025.pdf)
- [Project Slinky — Rafay blog](https://rafay.co/ai-and-cloud-native-blog/project-slinky-bringing-slurm-scheduling-to-kubernetes)
- [Implementing Slurm on Kubernetes with Slinky v1.0.0 — TAS Design Group](https://medium.com/@TASDesignGroupInc/implementing-slurm-on-kubernetes-with-slinky-v1-0-0-bb553ed7a165)
- [Deploying SLURM with Slinky — Nick Tailor's blog](https://www.nicktailor.com/?p=2024)
- [Kubernetes Dynamic Resource Allocation (DRA) reference](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [RKE2 HA install guide](https://docs.rke2.io/install/ha) — for cluster-side prerequisites
- [OKD SCC documentation](https://docs.okd.io/latest/authentication/managing-security-context-constraints.html) — for OKD-side privilege model context
