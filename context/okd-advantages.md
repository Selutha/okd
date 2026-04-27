# What OKD Gets You Over Rancher / RKE2

**Status:** Draft v0.2 — for iteration alongside `okd-vs-rke2.md`
**Date:** 2026-04-24
**Purpose:** Steel-man OKD specifically. The comparison doc leans toward RKE2 for this user's situation; this doc isolates and tests what OKD genuinely brings to the table that Rancher/RKE2 does not — measured against the user's HPC + Slurm + RHEL 9 + DDN Lustre + Pure + Mixed-GPU context.
**Changes since v0.1:** Added a fifth genuine OKD advantage — **Driver Toolkit (DTK) + per-RHCOS-version Driver DaemonSet** — discovered during the GPU Operator upgrade-impact verification. Updated §0 summary and added §1.5.

> **Reading order:** Read `okd-vs-rke2.md` first for the broad comparison, then this doc to make sure the OKD side has been fairly steel-manned, then `slinky-reading.md` for the HPC-integration-platform context. Decision should be informed by all three.

---

## 0. The honest summary

OKD's real, defensible advantages over Rancher/RKE2 for *this user* boil down to five items:

1. **Cluster Version Operator (CVO) atomic upgrades** — bundled, all-or-nothing version revs of kubelet, CRI-O, OS, and platform operators.
2. **OperatorHub with curated/certified operator catalogs** — broader and more vetted catalog than Rancher's app catalog for many enterprise add-ons.
3. **Security Context Constraints (SCCs) as the default authorization model** — stronger out-of-box security posture than the PSA + Kyverno/Gatekeeper assembly RKE2 requires.
4. **Tighter integration of OpenShift-family operators** (Pipelines, Service Mesh, GitOps) when run on OKD via OperatorHub.
5. **Driver Toolkit (DTK) + per-RHCOS-version GPU driver DaemonSets** — automatic kernel-module-version compatibility across cluster upgrades, with smaller per-upgrade blast radius than the equivalent RKE2 path. **Most directly relevant to your B200/B300 GPU cluster.**

Each of those is real. Each has a counterweight in the RHEL 9 / Slurm / mixed-GPU HPC context that this user actually operates in. The remainder of this doc takes them one at a time, then explicitly busts a few myths about OKD advantages that *don't* hold for OKD specifically (vs. paid OCP).

---

## 1. The five genuine advantages, examined

### 1.1 Cluster Version Operator (CVO) atomic upgrades

**What it is:** OpenShift/OKD ships a Cluster Version Operator that consumes a single "release payload image" representing a specific version. CVO reconciles every cluster operator (etcd, kube-apiserver, ingress, registry, monitoring, MCO, etc.) to their bundled versions, and Cluster Operators in turn reconcile their operands. The Machine Config Operator handles the OS rev (rpm-ostree pivots the FCOS/SCOS image). Upgrades propagate through the control plane, then workers, in a coordinated fashion.

> "First, the cluster operators are updated; next, the nodes running the control plane and worker nodes have their operating system and configuration changed. Worker nodes are upgraded after the Control Plane has finished upgrading and do not block the cluster's upgrade process." ([OpenShift docs](https://docs.openshift.com/en/container-platform/4.10/architecture/control-plane))

**Why it matters for this user:**

- One command (`oc adm upgrade`) drives the whole stack — kubelet + CRI-O + OS + operators rev together with strong version coupling.
- Reduces the "did I forget to update the CSI driver after kubelet?" class of incident.
- For a small HPC team, this lowers cognitive load on routine upgrades.

**The counterweight in the RKE2 path:**

- Rancher (when it provisions RKE2 directly) orchestrates the rolling drain + binary swap + restart per node automatically. It's not as opinionated as CVO — kubelet is the only thing CVO upgrades atomically; the GPU Operator, ingress, monitoring, etc. are still per-component upgrades on RKE2.
- However: each of those components has a Helm chart with a known version-pinning model, and tools like ArgoCD/Flux make the multi-component rev a tracked GitOps operation. That's not "one button," but it's not chaos either.

**Net:** CVO is a real ergonomic win for OKD. It's the strongest single argument, and it's most valuable if your team's bandwidth for upgrade choreography is thin. **Worth ~Medium-High weight** in the decision.

**Sources:**

- [OpenShift cluster-version-operator on GitHub](https://github.com/openshift/cluster-version-operator)
- [The Ultimate Guide to OpenShift Update for Cluster Administrators](https://www.redhat.com/en/blog/the-ultimate-guide-to-openshift-update-for-cluster-administrators)
- [OpenShift Control Plane Architecture](https://docs.openshift.com/en/container-platform/4.10/architecture/control-plane)

---

### 1.2 OperatorHub with curated and certified catalogs

**What it is:** OpenShift/OKD ships OperatorHub as the canonical in-cluster operator marketplace. It surfaces four catalogs by default: Red Hat Operators (paid OCP), Certified Operators (third-party-vendored, Red Hat-certified), Red Hat Marketplace, and Community Operators. OperatorHub uses the Operator Lifecycle Manager (OLM) to install and upgrade operators with version channels, dependency resolution, and CRD versioning.

> "The Embedded OperatorHub is a registry of certified Operators from software vendors and open source projects, where you can browse and install a library of Operators that have been verified to work with Red Hat OpenShift and that have been packaged for easy lifecycle management." ([Red Hat OperatorHub catalog](https://catalog.redhat.com/en/software/containers/openshift4/ose-operator-marketplace/5cddce4dbed8bd5717d6789d))

**Why it matters for this user:**

- Single discovery surface for vendor operators (DDN exa-csi-driver, NVIDIA GPU Operator, NFD, Red Hat Service Mesh, etc.).
- OLM gives lifecycle management (channel-based subscriptions, automatic minor-version updates, failed-upgrade rollback) that Helm doesn't natively provide.
- Certified Operator catalog has been quality-gated by Red Hat — a useful proxy for "this works on the platform."

**The counterweight in the RKE2 path:**

- Rancher's app catalog (via the Rancher Helm chart catalogs and the Apps marketplace) covers the major operators and Helm charts but is not as deep on certified third-party vendor operators.
- OLM can be installed on RKE2 (it's an upstream Kubernetes project, not OpenShift-only), but it's not the default and not as well-integrated.
- Most operators in the certified catalog also publish Helm charts that work on RKE2 — you trade convenience and cohesion for vendor-package-flexibility.

**Net:** OperatorHub is a real day-2 ergonomics win for shops that want to install many operators and don't want to chase Helm charts and CRD compatibility. For the HPC + AI inference workload, the operator universe in active use is small (NFD, GPU Operator, Pure CSI, DDN CSI, ingress, monitoring, cert-manager) — OperatorHub adds modest value in a small-operator-count environment. **Worth ~Medium weight.**

**Sources:**

- [OpenShift OperatorHub — Red Hat Ecosystem Catalog](https://catalog.redhat.com/en/software/containers/openshift4/ose-operator-marketplace/5cddce4dbed8bd5717d6789d)
- [What are Red Hat OpenShift Operators?](https://www.redhat.com/en/technologies/cloud-computing/openshift/what-are-openshift-operators)
- [Operator Hub Catalogs — OKD](https://okd.io/docs/operators/)
- [redhat-openshift-ecosystem/certified-operators on GitHub](https://github.com/redhat-openshift-ecosystem/certified-operators)

---

### 1.3 Security Context Constraints (SCCs) as default authorization

**What it is:** OpenShift/OKD predates Kubernetes Pod Security Admission (PSA) and ships its own model: SCCs. Every pod is admitted only if the requesting service account is granted an SCC that permits the pod's security context. The default SCCs (`restricted-v2`, `nonroot-v2`, `anyuid`, `privileged`) provide a baseline that's strictly more restrictive than Kubernetes' default.

**Why it matters for this user:**

- New workloads must be granted SCCs explicitly — this catches "developer pasted a Helm chart that wants to run as root" before it lands.
- HPC workloads that need elevated privileges (e.g., Slinky's slurmd containers, GPU driver containers) require explicit SCC grants — visible in the cluster's RBAC audit, not implicit.
- "Secure by default" is a real posture, not a config you have to remember to enable.

**The counterweight in the RKE2 path:**

- RKE2 enables CIS profile (`profile: cis` in config.yaml) and Pod Security Admission, plus SELinux on RHEL hosts. Adding Kyverno or Gatekeeper gives policy that's at least as expressive as SCCs.
- But: that's configuration *you* author. With OKD, the equivalent posture exists day 1. The cost is real if the team is small.

**Net:** Real advantage for OKD if security posture and out-of-box secure defaults are a priority. **However, the same posture is achievable on RKE2 with a few hours of config + one Helm chart (Kyverno or Gatekeeper).** Whether it's worth Medium or Low weight depends on team experience with k8s security models. For an HPC center where Slurm provides scheduling and the k8s cluster is hosting service workloads (not multi-tenant developer self-service), the marginal value is **Medium-Low**.

**Sources:**

- [OKD docs — Managing security context constraints](https://docs.okd.io/latest/authentication/managing-security-context-constraints.html)

---

### 1.4 Tighter integration with OpenShift-family operators (Pipelines, Service Mesh, GitOps)

**What it is:** Red Hat publishes operators for several adjacent platforms — OpenShift Pipelines (Tekton), OpenShift Service Mesh (Istio), OpenShift GitOps (ArgoCD), OpenShift Logging — as OperatorHub-installable operators. They install with sane defaults that integrate with OpenShift's auth, monitoring, and Routes.

**Why it matters for this user:**

- If the inference service workload eventually wants Tekton-based CI/CD or Argo-based GitOps, OpenShift's versions install with one click and integrate with cluster auth.
- Service Mesh integration is well-trodden territory on OpenShift.

**The counterweight in the RKE2 path:**

- Tekton, Argo, Istio, Loki, and friends are all upstream projects with their own Helm charts. They run on RKE2 without modification — you just install them yourself.
- The "integration with cluster auth" benefit is real on OKD (auto-wired to OAuth) but evaporates if you've deployed Keycloak as the OIDC provider for both clusters anyway (which you'd do on either platform per G-4 of the main design doc).

**Net:** Modest. The integration is real but benefits accrue only if you adopt those specific tools and want the OpenShift-flavored configs. For inference workloads specifically, this is **Low weight** unless the team has existing OpenShift Pipelines / Service Mesh skills.

**Sources:**

- [OpenShift Pipelines (Tekton) docs](https://docs.openshift.com/pipelines/latest/about/about-pipelines.html)
- [OpenShift GitOps docs](https://docs.openshift.com/gitops/latest/understanding_openshift_gitops/about-redhat-openshift-gitops.html)

---

### 1.5 Driver Toolkit + per-RHCOS-version Driver DaemonSets — the GPU-specific OKD win

**This one is the most directly relevant to your B200/B300 GPU cluster.** It surfaced during the GPU-Operator-upgrade-impact verification and didn't make the v0.1 of this doc; it deserves the same treatment as the other four.

**What it is:** On OpenShift/OKD, the NVIDIA GPU Operator integrates with the **Driver Toolkit (DTK)** — a Red Hat–maintained container image whose tag corresponds 1:1 to a specific RHCOS version and ships the matching kernel headers and build tooling. The Operator runs DTK as a sidecar to its driver container; the two share a directory and the DTK side compiles the NVIDIA driver kernel module against the *exact* kernel of the running RHCOS image. Then the Operator creates **one driver DaemonSet per RHCOS version present in the cluster** — not just one cluster-wide. As nodes roll through an RHCOS upgrade, each node "slips" from the old RHCOS-version DaemonSet to the new one automatically.

From the [Red Hat blog on entitlement-free deployment](https://www.redhat.com/en/blog/entitlement-free-deployment-of-the-nvidia-gpu-operator-on-openshift):

> "the operator driver DaemonSet must either work well with any RHCOS version, or spawn multiple DaemonSets, one per RHCOS version. The solution implements the latter approach."
>
> "At each iteration of the GPU Operator reconciliation loop, the controller checks if new RHCOS versions appeared in the cluster (at the beginning of an upgrade), or if existing RHCOS-specific DaemonSets are no longer in use (at the end of an upgrade)."
>
> "Between these two steps, the cluster nodes will be rebooted and upgraded by the Machine Config Operator, and they will slip from one DaemonSet to the other."

**Why it matters for this user:**

This is the kernel-module-version compatibility problem solved by design. For a fleet that mixes L40 / B200 / B300 — three driver branches across multiple kernel revisions over a multi-year operating life — manually coordinating "RHEL kernel update" with "NVIDIA driver branch" is a real ops burden. On OKD the Operator does it. The DTK image tag pins to RHCOS version; the Operator picks the right one; the kernel module is always compiled against the actually-running kernel; transitions through cluster upgrades happen automatically.

**The counterweight on RKE2:**
The GPU Operator on RKE2 also supports kernel-module compatibility — it uses the [precompiled-kernel-modules approach or the standard driver-container build pattern](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-kernel-modules.html). The driver container detects the running kernel and pulls a matching driver image (or builds one). This works. **However:**

- There's no "DTK equivalent" pinned to specific RHEL kernel versions — you rely on NVIDIA's published precompiled images covering your kernel, or fall back to runtime compilation.
- Cluster-OS upgrades on RKE2 are RHEL kernel updates managed by Puppet/dnf — coordinating those with GPU driver compatibility is an operations task you own. The GPU Operator helps but doesn't have an OpenShift-style "switch DaemonSet automatically when the kernel changes" behavior.
- For mixed driver branches (L40 on R535, B200 on R570+, B300 on whatever production branch is current when B300 ships), this gets multi-dimensional on RKE2 — per-node-pool driver branch *and* per-kernel compatibility *and* per-Puppet-managed-kernel-update window. Doable; more bookkeeping.

**Smaller per-upgrade blast radius — bonus:**
Separate from DTK: the toolkit DaemonSet on OKD writes a CRI-O drop-in (`/etc/crio/conf.d/99-nvidia.toml`) and reloads CRI-O. Kubelet on OKD is a separate systemd unit; CRI-O reload doesn't bounce kubelet. On RKE2, the toolkit SIGHUPs containerd, which RKE2 supervises, which restarts RKE2 (and kubelet) on the node. So a routine GPU Operator chart bump is a smaller event on OKD than on RKE2 — non-GPU pods on the node are completely undisturbed; GPU containers may briefly disrupt during runtime reload. See `design.md` §6.5 vs `design-rke2.md` §6.3 for the full breakdown.

**Net:** This is a **Medium-to-High weight** advantage *if* you anticipate kernel revisions during the cluster's operating life (you will — RHCOS gets routine kernel updates) and *if* mixed-driver-branch GPU pools are part of the long-term plan (you've stated they are). For a single-driver-branch homogeneous GPU fleet that never upgrades the kernel, the value drops sharply — but that's not your fleet.

**Sources:**

- [Entitlement-Free Deployment of the NVIDIA GPU Operator on OpenShift (Red Hat blog)](https://www.redhat.com/en/blog/entitlement-free-deployment-of-the-nvidia-gpu-operator-on-openshift)
- [DeepWiki — NVIDIA GPU Operator OpenShift Integration](https://deepwiki.com/NVIDIA/gpu-operator/10-openshift-integration)
- [NVIDIA GPU Operator on OpenShift — install docs](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html)
- [NVIDIA GPU Operator — Precompiled Kernel Modules (RKE2/upstream alternative)](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-kernel-modules.html)
- [NVIDIA Container Toolkit install guide — drop-in CRI-O config](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [CRI-O config reload model (cri-o repo)](https://github.com/cri-o/cri-o/blob/main/docs/crio.conf.5.md)

---

## 2. Myth-busting: things that are NOT OKD advantages over RKE2

These come up regularly in OKD/OCP advocacy. They don't apply to OKD (the community distribution) for this user.

### 2.1 ❌ "OpenShift AI / RHODS for the inference workload"

This is the biggest one because the user's GPU cluster is for inference, and OpenShift AI is the obvious-sounding answer.

**The reality:** Red Hat OpenShift AI is supported only on **Red Hat OpenShift Container Platform (paid OCP)**, not on OKD. Per Red Hat's own docs:

> "Red Hat OpenShift AI is provided as a managed cloud service add-on for Red Hat OpenShift or as self-managed software that you can install on-premise or in the public cloud on OpenShift." ([Red Hat OpenShift AI](https://www.redhat.com/en/products/ai/openshift-ai))

OpenShift AI is built on OpenShift's specific operators (OpenShift Routes, OAuth, Service Mesh integration) and is not packaged for OKD. To get its features (KServe-based model serving, Jupyter pipelines, model registry, GPU autoscaling integration) on OKD you'd be deploying upstream KServe, Jupyter, Kubeflow components yourself — **the same work as on RKE2**, with no help from Red Hat tooling.

**Implication:** If the inference workload would benefit from OpenShift AI, the path is *paid OCP*, not OKD. OKD-vs-RKE2 is a wash for AI/ML platform features. The user's stated direction is OKD (community), so this advantage is off the table either way.

**Sources:**

- [Red Hat OpenShift AI overview](https://www.redhat.com/en/products/ai/openshift-ai)
- [Installing OpenShift AI Self-Managed (Red Hat docs)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)

### 2.2 ❌ "Red Hat support pathway"

OKD does not come with Red Hat support. Per Red Hat:

> "OKD is the upstream and community-supported version of the Red Hat OpenShift Container Platform (OCP)." ([Red Hat OpenShift vs. OKD](https://www.redhat.com/en/topics/containers/red-hat-openshift-okd))

Support for OKD comes from the OKD Working Group, mailing lists, and community. RKE2 + Rancher Prime gives you SUSE support, which is a real commercial pathway. **OKD has no equivalent unless you upgrade to paid OCP.**

If you're choosing OKD specifically as a community-supported community-maintained distribution because your team is comfortable with that posture, fine — but don't buy OKD on the assumption that "Red Hat will help if it breaks."

### 2.3 ❌ "FIPS 140-2"

OKD does not ship FIPS-validated binaries. Paid OCP does in some configurations. RKE2 does (linux/amd64, BoringCrypto-compiled).

> "RKE2 and its deployed components (except NGINX ingress) have been compiled to leverage the FIPS 140-2 validated BoringCrypto module." ([RKE2 hardening guide](https://docs.rke2.io/security/hardening_guide))

If FIPS is a hard requirement, **RKE2 wins**. Not OKD.

### 2.4 ❌ "Better HPC integration / Slinky support"

OKD has no HPC-specific integration that RKE2 lacks. Both run conformant Kubernetes; both support Slinky (with platform-specific friction). The user's HPC stack (Slurm bare metal, DDN Lustre, NVIDIA GPUs) integrates with the k8s cluster through standard CSI drivers and the GPU Operator — neither of which is OKD-specific.

OpenShift has published HPC-on-OpenShift blog posts (e.g., MPI + Lustre walkthroughs) but the technologies described — MPI Operator, OpenMPI, Lustre clients — work the same on RKE2. The blog posts are evangelism, not capability differentiation.

> "The article emphasizes that Slinky uses Slurm 25.11 features including configless mode, dynamic nodes, and cgroups v2 for resource isolation." ([NVIDIA on Slurm + Kubernetes](https://developer.nvidia.com/blog/running-large-scale-gpu-workloads-on-kubernetes-with-slurm/))

These are platform-agnostic Slurm and Kubernetes features. They work on either distribution.

### 2.5 ❌ "ODF / OpenShift Data Foundation as an in-cluster storage layer"

ODF (Ceph + Rook + NooBaa) is available as an operator on OKD. It provides RWX block, RWX filesystem, and S3 object storage from in-cluster local disks.

But: **the user has Pure FlashArray + FlashBlade and DDN Lustre.** ODF would be redundant. Even if the user wanted in-cluster storage, ODF requires ≥3 storage workers with local disks earmarked for Ceph — that's bare-metal worker capacity allocated to storage instead of inference, with the same Ceph operations to manage as a standalone Ceph cluster.

ODF is a real OpenShift feature. It's not a real *advantage* in this stack.

**Sources:**

- [Deploying ODF on bare metal infrastructure (Red Hat docs)](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.17/html-single/deploying_openshift_data_foundation_using_bare_metal_infrastructure/index)
- [ODF architecture](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.12/html/planning_your_deployment/odf-architecture_rhodf)

---

## 3. Specific HPC + Slurm + RHEL 9 considerations

### 3.1 OS divergence cost

The single biggest "OKD tax" in an HPC environment is the OS divergence between OKD nodes (FCOS pivoting to SCOS) and the rest of the bare-metal Slurm fleet (RHEL/Rocky). Operationally this means:

- OKD nodes can't share Puppet profiles with the Slurm cluster's nodes.
- Lustre client builds for OKD nodes are managed by Kernel Module Management (KMM) operator on a different cadence than the Slurm fleet's `dnf install` pipeline.
- Auditors and compliance staff need to learn FCOS/SCOS semantics in addition to RHEL.

SCOS is closer to RHEL than FCOS was (CentOS Stream lineage), but it is still not RHEL. For an HPC center where every other host is RHEL, this divergence has a real operational cost that doesn't show up in a feature-parity matrix.

> "OKD 4.16 transitions the node operating system and base container images from Fedora CoreOS (FCOS) to CentOS Stream CoreOS (SCOS). This change reduces the complexity of rebuilding all the cluster component containers." ([SCOS migration notes](https://okd.io/docs/project/upgrade-notes/from-4-15/fcos-to-scos-migration/))

This cost is reduced (FCOS→SCOS narrows the gap) but not eliminated. **Counted against OKD in the HPC context.**

### 3.2 Slinky friction on OpenShift

Slurm-operator and slurm-bridge run on conformant k8s. They run on OKD. But:

- slurm-operator pods need privileges to manage Slurm daemons (cgroup access, hostPath for shared filesystems, in some configs privileged mode). On OKD, this means writing custom SCCs and binding them to slurm-operator's service account. Doable; an extra moving part.
- The slurmd container image SchedMD ships is built on Ubuntu 24.04 with GLIBC 2.38 ([per slinky.schedmd.com](https://slinky.schedmd.com/projects/slurm-operator)). On OKD, the SCC and image-policy interactions need explicit handling.

On RKE2, the equivalent install is a Helm install with default RBAC and no SCC layer. Less friction.

This isn't unique to HPC, but it lands harder for an HPC center because Slinky is one of the few HPC-specific integrations the cluster might host.

### 3.3 GPU Operator — partial parity, with one OKD-specific edge

L40 / B200 / B300 GPU support via the NVIDIA GPU Operator works on both platforms. NVIDIA's docs and the GPU Operator catalog include both targets, and basic GPU exposure (NFD labels, device plugin, DCGM, driver containerization) is comparable on each.

**The OKD-specific edge** is the Driver Toolkit + per-RHCOS-version DaemonSet model — see §1.5. For a multi-driver-branch fleet (L40 R535, B200 R570+, B300 whatever-the-current-branch-is-when-it-ships) that will see kernel revisions during its operating life, this materially reduces the kernel/driver coordination burden. On RKE2, the GPU Operator's [precompiled-kernel-modules](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-kernel-modules.html) feature handles the same problem in a different idiom — coverage is good but you sometimes hit the runtime-build fallback path when a kernel image isn't precompiled.

Plus the smaller-blast-radius point on routine GPU Operator upgrades (kubelet stays up on OKD because CRI-O is a separate systemd unit; on RKE2 a containerd SIGHUP cascades into RKE2 restart). See `design.md` §6.5 vs `design-rke2.md` §6.3.

**Net for HPC + Mixed-GPU + multi-year operating life:** OKD has a real GPU-lifecycle advantage. Don't double-count it (it's already in §1.5), but recognize it's specifically an HPC-relevant win, not a generic OKD-platform claim.

### 3.4 Disconnected install posture

OpenShift has strong disconnected install support via `oc-mirror` and operator catalog mirroring. RKE2 has good disconnected support via airgap images. **Both are credible.** OKD has the slight edge if you're already going to mirror operator catalogs for other Red Hat platforms, because you'd reuse the mirror infrastructure.

If the deployment is fully connected (cluster talks to Quay.io and registry.redhat.io directly), this advantage doesn't apply.

---

## 4. When OKD is the right call for *this* user

OKD over RKE2 makes sense if **all** of these are true:

- The team values "secure-by-default, all-batteries-included, one-button upgrades" more than it values "Puppet-managed RHEL hosts and Rancher full-lifecycle."
- OS divergence between Slurm bare-metal (RHEL) and OKD nodes (SCOS) is acceptable, including the parallel config pipeline (KMM for Lustre, GPU Operator for drivers, MachineConfig for everything else).
- The team plans to use OperatorHub heavily (many operators, frequent installs) — the OperatorHub ergonomic win pays for itself.
- There's organizational momentum or sunk-cost in OpenShift skills/tooling that pulls toward OKD.
- FIPS 140-2 is **not** a requirement. (If it is, RKE2 is the answer.)
- OpenShift AI is **not** the planned model-serving platform. (If it is, paid OCP is the answer, not OKD.)

If any of those bullet points fail, the case for RKE2 strengthens. The single most common failure point for HPC sites is the OS-divergence one.

---

## 5. When OKD is the wrong call for *this* user

- The team is invested in Puppet/Katello and wants RKE2 nodes managed identically to the Slurm fleet — **RKE2 wins**.
- Rancher's full lifecycle (provisioning, upgrade, etcd snapshot) on workload clusters is desired — **RKE2 wins**.
- FIPS 140-2 required — **RKE2 wins**.
- Slinky integration friction needs to be minimized — **RKE2 wins**.
- The team would deploy Keycloak, Harbor, kube-prometheus-stack regardless of platform — **most of OKD's batteries-included value is moot, RKE2 ties or wins**.

---

## 6. Decision framing

For this user's specific situation, the OKD case now rests on three real advantages plus two modest ones:

- **CVO atomic upgrades** (Medium-High) — one-button, all-components-rev-together cluster upgrades.
- **DTK + per-RHCOS-version Driver DaemonSets for GPU** (Medium-High *for this fleet specifically*) — automatic kernel/driver compatibility across the cluster's operating life; smaller per-upgrade blast radius for routine GPU Operator chart bumps.
- **OperatorHub** (Medium) — curated catalog ergonomic win, scales with operator count.
- **SCCs as default authz** (Medium-Low) — secure-by-default posture you'd otherwise build with PSA + Kyverno.
- **OpenShift-family operator integration** (Low) — Pipelines / GitOps / Service Mesh fit if you adopt them.

The RKE2 case rests on:

- **Puppet-everywhere fit** for an existing Puppet/Katello shop (High).
- **Rancher full lifecycle** for the workload clusters — provisioning, upgrade, etcd snapshot/restore (Medium-High).
- **Less Slinky friction** if Slinky is in the future (Medium, conditional).
- **Default-on etcd backup** (Medium).
- **FIPS 140-2 available** (Site-dependent, can be High).

The myths (OpenShift AI, Red Hat support, FIPS, ODF) **do not apply** to OKD specifically — they apply to paid OCP, or they're available on RKE2 too, or they don't fit the stack.

**The decision is closer than the v0.1 of this doc made it look.** The DTK/per-RHCOS-version DaemonSet finding is HPC-relevant in a way that the other four OKD advantages aren't, and for a B200/B300/L40 fleet that's going to see multiple kernel revisions over a 3-5 year operating life, the kernel/driver lifecycle matters. RKE2 is still a credible answer — its precompiled-kernel-modules path covers most cases — but the ergonomic gap between OKD's automatic transition and RKE2's "monitor, fall back to runtime build, coordinate with Puppet kernel updates" is real.

For an HPC center keeping Slurm as primary, the RKE2 case is *still* materially stronger because of Puppet/Katello fit and Rancher full-lifecycle. But OKD's GPU lifecycle story is the specific axis on which OKD is genuinely better for *this stack* — not just better for "OpenShift shops in general." Worth more weight than the v0.1 framing suggested.

---

## 7. Open questions for the user to think about

1. How much value does your team place on "one-button atomic cluster upgrades" vs. "explicit per-component upgrade control via GitOps"? This is the cleanest lens on the CVO question.
2. What's your operator install cadence going to look like — handful of operators (NFD, GPU, CSI, ingress, monitoring) or dozens? OperatorHub's value scales with operator count.
3. Is paid OCP under any circumstances on the table later? If so, OKD-now-OCP-later is a coherent transition path that RKE2 doesn't offer.
4. Has anyone on the team operated OpenShift in production before? Skill momentum is a real factor in either direction.

---

## Sources

**OKD upgrade model and CVO:**

- [OpenShift cluster-version-operator on GitHub](https://github.com/openshift/cluster-version-operator)
- [The Ultimate Guide to OpenShift Update for Cluster Administrators](https://www.redhat.com/en/blog/the-ultimate-guide-to-openshift-update-for-cluster-administrators)
- [OpenShift Control Plane Architecture](https://docs.openshift.com/en/container-platform/4.10/architecture/control-plane)

**OperatorHub:**

- [OpenShift OperatorHub — Red Hat Ecosystem Catalog](https://catalog.redhat.com/en/software/containers/openshift4/ose-operator-marketplace/5cddce4dbed8bd5717d6789d)
- [What are Red Hat OpenShift Operators?](https://www.redhat.com/en/technologies/cloud-computing/openshift/what-are-openshift-operators)
- [Operator Hub Catalogs — OKD](https://okd.io/docs/operators/)
- [redhat-openshift-ecosystem/certified-operators](https://github.com/redhat-openshift-ecosystem/certified-operators)
- [redhat-openshift-ecosystem/community-operators-prod](https://github.com/redhat-openshift-ecosystem/community-operators-prod)

**OpenShift AI / RHODS (NOT on OKD):**

- [Red Hat OpenShift AI overview](https://www.redhat.com/en/products/ai/openshift-ai)
- [OpenShift AI Self-Managed installation docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [From raw data to model serving with OpenShift AI](https://developers.redhat.com/articles/2025/07/29/raw-data-model-serving-openshift-ai)

**OKD vs OCP positioning:**

- [Red Hat OpenShift vs. OKD](https://www.redhat.com/en/topics/containers/red-hat-openshift-okd)
- [okd-project/okd on GitHub](https://github.com/okd-project/okd)

**OS / SCOS migration:**

- [Node OS changes to SCOS](https://okd.io/docs/project/upgrade-notes/from-4-15/fcos-to-scos-migration/)
- [Fedora CoreOS — OKD 4 Architecture](https://docs.okd.io/latest/architecture/architecture-rhcos.html)

**OpenShift Data Foundation:**

- [Deploying ODF on bare metal](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.17/html-single/deploying_openshift_data_foundation_using_bare_metal_infrastructure/index)
- [ODF architecture overview](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.12/html/planning_your_deployment/odf-architecture_rhodf)

**Adjacent OpenShift operators:**

- [OpenShift Pipelines (Tekton)](https://docs.openshift.com/pipelines/)
- [OpenShift GitOps](https://docs.openshift.com/gitops/)
- [OpenShift Service Mesh](https://docs.openshift.com/container-platform/latest/service_mesh/v2x/ossm-about.html)

**RKE2 counterweights:**

- [RKE2 Hardening / CIS](https://docs.rke2.io/security/hardening_guide)
- [RKE2 etcd backup default](https://docs.rke2.io/datastore/backup_restore)
- [Rancher Apps and Marketplace](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-cluster-setup/apps-and-marketplace)
