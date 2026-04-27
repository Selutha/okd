# CI/CD and GitOps Strategy

**Status:** Draft v0.3 — for iteration
**Date:** 2026-04-24
**Changes since v0.2:** Build/scan tier moved from mgmt cluster to **infra cluster** (GitLab Runners, SonarQube, DefectDojo). **Two CloudNativePG instances** now: mgmt CNPG hosts keycloak + harbor "valuables"; infra CNPG hosts sonarqube + defectdojo build-tier data. Failure-domain separation between auth/registry tier and build-tier. Added §10.5 — the Devtron-equivalent vulnerability gate via Trivy + Cosign attestations + Kyverno admission. §10 architecture diagram redrawn to show the two-tier split. Phased adoption updated.
**Changes since v0.1:** Added §10 — Code-level security scanning (running OSS scanners in GitLab CI for repos that don't produce container images, plus self-hosted SonarQube + optional DefectDojo). Added the rationale for *not* self-hosting GitLab to get scanning features.
**Purpose:** Decide on a CI/CD + GitOps stack for the multi-cluster Kubernetes infrastructure. Compare candidates (ArgoCD, FluxCD, Devtron, Kargo, others), recommend a starting stack, define where each piece runs in the architecture, and flag what's premature for day-1.

> Reading order: this doc lives alongside `design-rke2.md` (or `design.md` if you go OKD). Cluster topology and platform-tier decisions are in those; this doc layers on top.

---

## 0. Recommended stack — TL;DR

For your situation (HPC center, small ops team, GitLab CI already in place via an org-owned GitLab you don't operate, Harbor already deploying with Trivy built-in, 3-cluster topology), the right starting stack is:

| Layer | Tool | Status |
|---|---|---|
| **GitOps deploy** | **ArgoCD** | Day 1 |
| **CI / image build** | **GitLab CI** (existing org instance) | Day 1 |
| **Self-hosted CI runners** | **GitLab Runner** (k8s executor on mgmt cluster) | Day 1 |
| **Image registry + image vuln scanning** | **Harbor + Trivy** (already in `design-rke2.md` §4.1.1) | Day 1 |
| **Code-level SAST + secret scanning + dep scanning** | **Semgrep + gitleaks + Trivy fs** in CI jobs (see §10) | Day 1 |
| **Centralized SAST + code-quality dashboard** | **SonarQube Community Edition** on mgmt cluster (see §10) | Day 1 |
| **Cross-scanner vuln triage / aggregation** | **DefectDojo** on mgmt cluster (see §10) | Optional — add when triage volume justifies |
| **Image signing** | **Cosign / Sigstore** | Day 1 (cheap to add early) |
| **Admission policy** | **Kyverno** (already in RDR-5) | Day 1 |
| **Progressive delivery** | **Argo Rollouts** | Add when first canary/blue-green need surfaces |
| **Multi-environment promotion** | **Kargo** | Add when dev → staging → prod promotion becomes a real pattern |
| **DAG-style workflows** | Argo Workflows | Add only if you do ML pipelines / batch DAGs on k8s |

**What I'd skip:**
- **Devtron.** Real reasons in §4 below.
- **Self-hosting GitLab** to get security-scanning features. The scanning capability is achievable via the OSS-scanner-in-CI + SonarQube stack — see §10.

---

## 1. The decision space

### 1.1 CI vs CD vs GitOps

These are different jobs that get blended in marketing but are operationally distinct:

| Concern | Definition | Dominant tools |
|---|---|---|
| **CI (Continuous Integration)** | Build, test, scan, push artifacts (container images, Helm charts) in response to git pushes. | **GitLab CI** (you have it), GitHub Actions, Tekton, Jenkins |
| **CD (Continuous Deployment / Delivery)** | Take built artifacts and put them onto running clusters. | Push-based: GitLab CI calling `kubectl apply`. Pull-based (GitOps): ArgoCD, Flux. |
| **GitOps** | A specific shape of CD where the *cluster reconciles to whatever the git repo says*, continuously. Git is the single source of truth; the cluster pulls. | ArgoCD, FluxCD |
| **Progressive delivery** | Release patterns: canary, blue-green, traffic-shifted rollouts. | Argo Rollouts, Flagger |
| **Promotion** | Moving artifacts through environments (dev → staging → prod) with gates and approvals. | Kargo, custom GitLab CI promotion jobs |
| **Image security** | Vuln scanning, image signing, supply-chain verification. | Trivy (in Harbor), Cosign/Sigstore, Kyverno admission |
| **Workflows / DAGs** | Run a pipeline of dependent jobs (often for ML, data, batch). | Argo Workflows, Tekton, GitLab CI multi-stage |

**For this project:** GitLab CI is already your CI tool. The decision space is mostly about CD + GitOps + promotion + security gating.

### 1.2 Push-based CD vs pull-based GitOps

**Push-based (traditional CI/CD):**
- Pipeline does `kubectl apply` or `helm upgrade` from CI runner against the cluster.
- CI runner needs cluster credentials.
- Cluster doesn't actively reconcile — it has whatever the last apply put on it.
- Pros: simple, familiar.
- Cons: drift not detected, audit trail is in CI logs not git, secrets management harder, multi-cluster gets messy.

**Pull-based (GitOps):**
- Cluster runs an agent (ArgoCD or Flux) that watches a git repo and reconciles.
- CI's job ends with "commit new image tag to manifests repo." Cluster picks up from there.
- Drift is auto-detected and (optionally) auto-corrected.
- Pros: git is source of truth, audit trail in git, drift detection, easier multi-cluster.
- Cons: one more component to operate, debugging requires understanding the agent.

**Recommendation:** **GitOps for production, period.** The audit-trail-in-git property alone justifies it for an HPC center where compliance and reproducibility matter. Push-based deploys to k8s in 2026 are a step backward.

---

## 2. GitOps tools — ArgoCD vs FluxCD

Both are CNCF-graduated, both run in production at scale, both pull from git. The differences are real and shape day-to-day operations.

### 2.1 Architecture

| | **ArgoCD** | **FluxCD** |
|---|---|---|
| Shape | Monolithic application — API server, repo server, application controller, Redis cache | Set of independent controllers (source-controller, kustomize-controller, helm-controller, etc.) acting through Kubernetes API |
| UI | **Built-in polished web UI** showing apps, sync status, health, resource tree, YAML diff | **None native** — Weave GitOps (third-party) provides one with varying maturity |
| Multi-cluster | Hub-and-spoke from a single ArgoCD instance — register external clusters | Per-cluster Flux installs; coordinate via shared git structure |
| Helm | Treats Helm as a manifest generator (renders to plain YAML) — manifest transparency, no Helm-native lifecycle | Has a dedicated helm-controller with closer Helm-native semantics |
| RBAC | Sophisticated built-in with SSO integration | Standard Kubernetes RBAC only |
| Memory footprint | Heavier (centralized resource graph) | Lighter per controller |
| Scale ceiling | UI begins slowing past ~3,000–5,000 apps without tuning | Constrained by k8s API server, not Flux itself |

### 2.2 When each fits

**ArgoCD wins when:**
- You want a UI for your ops team (we're a small HPC team, the UI is genuinely useful)
- Multi-cluster from a single management plane (your design has 3+ clusters managed by one mgmt cluster)
- SSO/Keycloak integration matters (it does — Keycloak is the IdP per `design-rke2.md`)
- You want visibility into deploy state without learning yet another CLI

**Flux wins when:**
- Everything-as-code purist — no UI is a feature, not a bug
- Lightweight footprint matters
- Per-cluster autonomy is the operational model
- Team is heavily invested in Helm-native lifecycle

### 2.3 Decision

**ArgoCD.** For your situation:
- Multi-cluster hub-and-spoke is a perfect fit for the mgmt cluster pattern.
- The UI is a genuine help for a small team operating 3 clusters.
- Keycloak OIDC integration is well-documented and well-trodden.
- Argo ecosystem (Rollouts, Workflows, Kargo) is co-designed with ArgoCD — adding pieces later is friction-free.

App scale ceiling (3-5k apps before UI slowdown) is laughably above your fleet's needs (you'll have tens, maybe low hundreds of apps).

---

## 3. Devtron — what it is and why I'd skip it for now

You mentioned Devtron + ArgoCD as appealing, particularly for security scanning. Worth examining honestly because it's a real product and the security-scanning angle is legitimate.

### 3.1 What Devtron is

Open-source Kubernetes management platform that **wraps ArgoCD** (and optionally FluxCD) and adds:

- A unified dashboard for application lifecycle (CI, CD, monitoring, vulnerability scanning)
- Built-in CI pipelines (alternative to GitLab CI)
- Trivy integration with deployment gates that block vulnerable images from production
- RBAC, project hierarchy, deployment templates, observability dashboards
- Per-Devtron Apps, Helm Apps, ArgoCD Apps, FluxCD Apps — Trivy can scan all of them

From [Devtron docs](https://docs.devtron.ai/docs/user-guide/integrations/vulnerability-scanning/trivy): "You can configure Devtron to prevent the deployment of container images based on the severity of vulnerabilities (Critical, Moderate, or Low), ensuring that only secure images can be deployed within the cluster."

That's a real feature. Devtron is a credible platform.

### 3.2 Why it's overkill for your situation

The reasoning is the same shape as our earlier "central Harbor day 1, per-cluster Harbor proxy deferred" call. Devtron is solving a problem at scale you don't have:

1. **You already have GitLab CI.** Devtron's built-in CI is an alternative to GitLab CI, not an augmentation. Adopting Devtron means either ignoring its CI (wasting one of its main features) or migrating off GitLab CI (org-wide rework you don't want).
2. **You already deploy Harbor with Trivy built-in.** [Harbor 2.2+ ships Trivy as the default vulnerability scanner](https://goharbor.io/docs/2.0.0/administration/vulnerability-scanning/). Image scans run automatically on push. Devtron's Trivy integration scans images *again* at deploy-time — useful in some flows but redundant given Harbor already gates the registry.
3. **Devtron adds a layer between you and ArgoCD.** When something breaks, you debug Devtron + ArgoCD, not just ArgoCD. Smaller community; smaller pool of Stack Overflow answers.
4. **You're not a multi-tenant developer-self-service platform.** Devtron's UX shines for "give 50 dev teams self-service deploys with policy guardrails." You're a small ops team running well-known inference services. The UX value is mismatched.
5. **It's a single-vendor open-source product.** Devtron Labs maintains it. Less ecosystem than ArgoCD (which has wider community + sister projects in the Argo family).

### 3.3 The security-scanning gap if you skip Devtron — fillable without it

The Trivy-at-deploy-time gate Devtron offers can be reproduced with:

- **Harbor's Trivy scan results on push** (already happening once Harbor is deployed) — vulnerable images get tagged in Harbor's UI; you can configure Harbor to block pulls of high-severity images.
- **Kyverno admission policy** to enforce "only signed images from Harbor" or "only images that passed Trivy" can run on the cluster. ([Kyverno's image-vulnerability-scanning policies](https://kyverno.io/policies/?policytypes=Verify%2520Images))
- **Cosign / Sigstore** for image signature verification, enforced via Kyverno. [Cosign + Kyverno integration](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/sigstore/)

This stack — Harbor's Trivy + Kyverno + Cosign — gives you the "block vulnerable images from deploy" gate without Devtron's wrapper. Components are independent, well-trodden, replaceable.

### 3.4 When to revisit Devtron

If any of these change, reconsider:
- You start onboarding many independent dev teams with self-service deploy needs (becomes multi-tenant).
- You want to move off GitLab CI for some reason.
- The integrated dashboard becomes more valuable than fewer-moving-parts.

For now: **skip.** Build the simpler stack first.

---

## 4. The supporting tools — when each becomes worth deploying

### 4.1 Argo Rollouts — progressive delivery

**What it is:** ArgoCD-companion controller for canary, blue-green, and traffic-shifted deploys. Replaces standard Deployments with `Rollout` CRDs that support analysis-gated rollouts (e.g., "deploy 10% → check Prometheus error rate → proceed or abort").

**When to add:** when the first inference service goes to production and you want canary deploys for model updates. Day-1 isn't required; deferred is fine.

**Pairs with:** ingress-nginx, Cilium (for traffic shaping), Prometheus (for analysis metrics).

### 4.2 Kargo — multi-environment promotion

**What it is:** Built by the Argo creators (now under Akuity stewardship). Manages promotion of "freight" (versioned artifacts — images, manifests, Helm charts) through stages (dev → staging → prod) with approval gates. Kargo commits to git; ArgoCD reconciles. From [Kargo's docs](https://docs.kargo.io/quickstart/): "Every stage must pass its health or approval check before the next begins."

**When to add:** when you have multiple environments (dev, staging, prod) for the same workloads and want gated promotion. If your environment is just "production cluster only" you don't need it. If you eventually have a "staging" GPU cluster used for testing model updates before the prod GPU cluster, Kargo earns its keep.

### 4.3 Argo Workflows — DAG-based workflows

**What it is:** Workflow engine for k8s — write DAGs of containerized steps. Used for ML training pipelines, data processing, batch jobs.

**When to add:** if and only if you actually run multi-step pipelines on the k8s clusters. For pure inference + general infra services, Argo Workflows is unused weight. **If Slinky (slurm-operator) ends up handling ML training jobs on the GPU cluster, Argo Workflows is redundant** — Slurm already does the DAG semantics.

### 4.4 Tekton / OpenShift Pipelines — alternative CI

**What it is:** Kubernetes-native CI engine. Building blocks (Tasks, Pipelines) defined as CRDs. OpenShift Pipelines is Red Hat's distribution of Tekton.

**When to consider:** if you wanted CI to run on the cluster, defined as CRDs, and integrated tightly with k8s RBAC. **Skip it given GitLab CI is already the org standard.** Two CI systems = no team owns either properly.

### 4.5 Cosign / Sigstore — image signing

**What it is:** Sign container images, verify signatures at deploy-time. Cosign is the CLI/tool, Sigstore is the broader ecosystem (Rekor transparency log, Fulcio cert authority).

**Why it matters:** image signatures + Kyverno admission policy = "this cluster can only run images signed by our build pipeline." Defeats the entire class of "attacker pushes a malicious image to Harbor and waits for it to deploy." Cheap to add early — `cosign sign` in GitLab CI after image push, Kyverno policy verifying signatures cluster-side.

**When to add:** day 1, as part of the GitLab CI image-build pipeline. Trivial cost; meaningful security improvement.

### 4.6 Kyverno — admission policy

Already in your RDR-5 (recommended over Gatekeeper). Day-1 component for:
- Enforcing image-signature verification (with Cosign)
- Blocking vulnerable images from deploy (with Trivy results from Harbor)
- General Pod Security Admission patterns
- Resource-request enforcement
- Namespace lifecycle policies

### 4.7 GitLab Agent for Kubernetes

**What it is:** GitLab's first-party k8s integration. Provides:
- Pull-based GitOps from GitLab repos
- Kubernetes-aware GitLab CI deploy jobs without storing kubeconfig in CI vars
- Cluster observability surfaced in GitLab UI

**Worth knowing about, less attractive than ArgoCD because:**
- GitLab-only — locked to GitLab if you ever want to switch source-control
- Smaller community than ArgoCD
- The "single GitOps tool for the fleet" benefit is bigger than "tighter GitLab integration"

**Use case:** if you really want GitLab to be the only DevOps surface, GitLab Agent unifies the toolchain. For most cases, ArgoCD + GitLab CI is the better split.

---

## 5. The recommended stack, fully drawn out

### 5.1 Component diagram

```
                           ┌─────────────────────────────────┐
                           │ GitLab (existing org instance)   │
                           │  - source repos                  │
                           │  - manifests / Helm charts repo  │
                           │  - CI runners (k8s executor)     │
                           └─────────────────┬────────────────┘
                                             │
                ┌────────────────────────────┼─────────────────────────┐
                │                            │                         │
                ▼                            ▼                         ▼
   ┌────────────────────┐    ┌────────────────────────┐    ┌────────────────────┐
   │ Build & test stage │    │ Push image to Harbor   │    │ Commit image tag   │
   │ (GitLab CI job)    │    │ (Harbor scans w/Trivy) │    │ to manifests repo  │
   └────────────────────┘    │                        │    │ (GitLab CI commit) │
                             │ Cosign sign image      │    └─────────┬──────────┘
                             │ (GitLab CI job)        │              │
                             └────────────────────────┘              │
                                                                     │ git push
                                                                     ▼
                                       ┌──────────────────────────────────────────┐
                                       │ Mgmt cluster (5 RKE2 servers)            │
                                       │  ┌────────────────────────────────────┐  │
                                       │  │ ArgoCD                              │  │
                                       │  │ - watches manifests repo            │  │
                                       │  │ - syncs to downstream clusters      │  │
                                       │  │ - SSO via Keycloak (OIDC)           │  │
                                       │  └─────────────┬──────────────────────┘  │
                                       └────────────────┼─────────────────────────┘
                                                        │ deploys to
                          ┌─────────────────────────────┼─────────────────────────────┐
                          │                             │                             │
                          ▼                             ▼                             ▼
          ┌─────────────────────┐       ┌──────────────────────┐       ┌──────────────────────┐
          │ RKE2-Infra cluster  │       │ RKE2-GPU cluster     │       │ RKE2-GPU-2 (future)  │
          │  - Kyverno          │       │  - Kyverno           │       │  - Kyverno           │
          │  - Argo Rollouts    │       │  - Argo Rollouts     │       │  - Argo Rollouts     │
          │    (when needed)    │       │    (when needed)     │       │    (when needed)     │
          │  - workloads        │       │  - inference         │       │  - inference         │
          └─────────────────────┘       └──────────────────────┘       └──────────────────────┘
```

### 5.2 Where each lives

The split is **runtime-tier vs build-tier**: services that running pods depend on (auth, image source, cluster mgmt) live on the mgmt cluster; build-time activities (CI, scanning, dashboards) live on the infra cluster.

| Component | Where | Why |
|---|---|---|
| **ArgoCD** | Mgmt cluster | Hub for hub-and-spoke deploys to all workload clusters. Co-located with Rancher, Keycloak, Harbor — shared platform tier. Authenticates via Keycloak OIDC. |
| **GitLab CI runners** | **Infra cluster** (k8s executor) | Build/CI is workload activity, lives where workloads live. Infra cluster has more capacity to absorb bursty CI load than mgmt's tightly-sized 5 nodes. |
| **Harbor + Trivy (image scanning)** | Mgmt cluster (already decided) | Single source of truth for images across all clusters. Pod pulls fleet-wide depend on it; mgmt placement protects this dependency. Trivy runs on push. |
| **Cosign signing** | GitLab CI (build job) | Sign immediately after push to Harbor. Keys stored in GitLab CI variables (or HashiCorp Vault if available). |
| **Kyverno** | Each workload cluster (per-cluster install) | Policy enforcement is cluster-local. Same policy bundle deployed to each cluster via ArgoCD. |
| **Argo Rollouts** | Each workload cluster (when adopted) | Rollout controllers run alongside the workloads they govern. |
| **Kargo (future)** | Mgmt cluster (when adopted) | Promotion across stages — naturally fits the central-control model with ArgoCD. |
| **SonarQube CE** | **Infra cluster** | Build-time SAST + code-quality dashboard. Consumed by CI, not by running pods. See §10 for full rationale. |
| **DefectDojo (optional)** | **Infra cluster** | Cross-scanner triage. Pairs with SonarQube; same reasoning. |

**Why the runtime/build split matters:** if SonarQube goes down, only CI builds fail — running pods on workload clusters keep working, Kyverno keeps enforcing scan attestations on cached images. So the "centralize on mgmt to protect against workload-cluster failures" logic that justified Harbor and Keycloak placement doesn't apply with the same force to scanning. Build infrastructure on the infra cluster is the right idiom.

### 5.3 The deploy flow, step by step

For a new inference model image, end-to-end:

1. **Developer commits** code or model config to GitLab source repo.
2. **GitLab CI builds** the container image, runs unit tests.
3. **GitLab CI pushes** image to Harbor (e.g., `harbor.<base>/inference/llama-serve:1.4.2`).
4. **Harbor's Trivy scans** the image on push. If critical vulns found, pipeline can fail at this gate.
5. **GitLab CI signs** the image with Cosign.
6. **GitLab CI commits** the new image tag to the manifests repo (e.g., updates `apps/llama-serve/values.yaml`).
7. **ArgoCD detects** the manifest commit (typically within seconds).
8. **ArgoCD syncs** the change to the target cluster (RKE2-GPU). Resources updated.
9. **Kyverno on the target cluster** verifies the image is signed and Trivy-clean before admitting pods.
10. **Pods roll** (with Argo Rollouts canary if configured, or standard rolling update).
11. **Hubble (Cilium)** records the new flows for observability.

Failure at any gate (Trivy critical vuln, Cosign signature missing, Kyverno policy violation) blocks the deploy. Audit trail is in git + Harbor + ArgoCD history.

---

## 6. Phased adoption — what's day 1, what's later

**Day 1 (with the cluster build-out):**
- ArgoCD installed on mgmt cluster, OIDC via Keycloak
- **GitLab Runners deployed on the infra cluster** (k8s executor)
- GitLab CI configured to push images to Harbor + commit manifest changes
- Harbor's built-in Trivy enabled (default)
- Cosign signing in GitLab CI; **Trivy vulnerability attestations** alongside signatures
- **Kyverno on each workload cluster** verifying signatures + Trivy attestations (the Devtron-equivalent gate, §10.5)
- **SonarQube CE on infra cluster, Postgres via a dedicated CloudNativePG instance on infra** (separate from the mgmt cluster's CNPG)
- **Shared CI security-scan template** (Semgrep + gitleaks + Trivy fs + lang-specific scanners) in every repo
- One ArgoCD app-of-apps pattern for each workload cluster
- Manifests repo structure agreed and templated

**Day 30:**
- Kyverno policies tightened (PSA, image origin, resource limits)
- Argo Rollouts installed when first canary requirement surfaces
- Backup of ArgoCD app definitions to S3 (in addition to git, belt + suspenders)

**Day 90+:**
- Kargo if multi-environment promotion becomes a real pattern
- Argo Workflows if ML pipelines move to k8s (or skip entirely if Slinky/Slurm handles them)
- Renovate (or similar) for keeping Helm chart values up to date automatically

**Skip indefinitely** unless a real need surfaces:
- Devtron (your platform doesn't need the wrapper)
- Tekton / OpenShift Pipelines (you have GitLab CI)
- GitLab Agent for Kubernetes (ArgoCD does the GitOps job better)

---

## 7. Things specifically worth thinking about for HPC

### 7.1 Image size and pull patterns

B200/B300 inference container images are 10–20 GB. Implications:

- **Harbor proxy projects** (mentioned in `design-rke2.md` §6.4) become more attractive as pull volume grows. Per-cluster Harbor caches reduce mgmt-cluster bandwidth on mass scale events. Add when needed.
- **Image deduplication** at the registry layer matters. Layer-based image structure in Dockerfiles → Harbor stores common base layers once, regardless of how many tagged images reference them.
- **Cosign signature verification at Kyverno** adds latency to first pod start (verify sig, fetch from Rekor). Negligible (~100ms) but worth knowing.

### 7.2 Slinky integration

If/when Slinky becomes a production workload (per `slinky-reading.md`), its Helm charts deploy via the same ArgoCD + Harbor flow as anything else. Slinky's slurm-operator runs as a regular k8s workload — nothing special in CI/CD terms. The Slurm cluster definition lives in git, ArgoCD reconciles it, GitLab CI builds any custom slurmd images.

### 7.3 KubeVirt VMs on the infra cluster

KubeVirt VMs are k8s resources too — VM definitions live in git, ArgoCD reconciles them. Bootable images (DataVolumes referencing PVCs from disk images) push to Harbor like any other artifact. CI/CD shape stays the same.

### 7.4 GitOps for cluster bootstrap itself

Once ArgoCD is running, you can put cluster-level configuration *in git* and let ArgoCD bootstrap each new cluster from a template. This is the "Cluster API + ArgoCD bootstrap" pattern:

- Cluster's "platform manifests" (Cilium values, ingress-nginx, cert-manager, GPU Operator config, Lustre CSI driver, Kyverno policies, monitoring) all in a git repo.
- Stand up a new cluster (e.g., the future GPU mirror) via Rancher.
- Register it with ArgoCD pointing at the platform-manifests repo.
- Cluster pulls its own config; comes up production-ready.

Worth setting this up day 1 — it makes the future GPU mirror cluster a one-day stand-up, not a one-week stand-up.

---

## 8. Open questions

1. **Manifests repo structure.** Single mono-repo for all manifests vs per-cluster repo vs per-app repo. Recommendation: single mono-repo with directory structure `clusters/<cluster-name>/<app-name>/` — easiest to reason about for a small team.
2. **Helm vs Kustomize vs raw YAML.** Most workloads in Helm charts (community charts + your own). App-specific overlays in Kustomize where charts don't fit. Raw YAML only for one-off resources.
3. **Where does GitLab keep the manifests repo?** A new project, or subdir of an existing one. Affects RBAC and CI-trigger configuration.
4. **Cosign key management.** Static keys in GitLab CI variables vs ephemeral keys via Sigstore Fulcio. Static keys are simpler day 1; Fulcio (keyless signing) is more secure and operationally cleaner long-term.
5. **Renovate or similar dep-update bot?** Keeps Helm chart versions up to date automatically. Day-30 question, not day-1.

---

## 10. Code-level security scanning — without self-hosting GitLab

The org-owned GitLab is presumably running CE/Free or a tier without the polished security dashboards. The temptation is to self-host GitLab to unlock those features. **Don't.** GitLab Ultimate's security features are mostly polished UI wrappers around OSS scanners that you can run yourself in CI — and a self-hosted SonarQube on your mgmt cluster gives you a comparable dashboard for free.

### 10.1 What GitLab tiers actually include

Per [GitLab's SAST docs](https://docs.gitlab.com/user/application_security/sast/) and tier-comparison research:

| Feature | Free / CE | Premium | Ultimate |
|---|---|---|---|
| Run SAST jobs in CI | ✅ | ✅ | ✅ |
| Run secret-detection jobs in CI | ✅ | ✅ | ✅ |
| Run container-scan jobs in CI | ✅ | ✅ | ✅ |
| JSON report artifacts | ✅ | ✅ | ✅ |
| **MR-integrated security findings UI** | ❌ | ❌ | ✅ |
| **Security Dashboard** (project + group level) | ❌ | ❌ | ✅ |
| **Vulnerability Management** (triage workflow) | ❌ | ❌ | ✅ |
| **GitLab Advanced SAST** (proprietary, lower false-positive rate) | ❌ | ❌ | ✅ |
| **AI-assisted vulnerability explanation / suggested fixes** (GitLab Duo) | ❌ | ❌ | ✅ |

**What this means:** the *scanning capability* is universal. The *dashboard, MR integration, and triage workflow* are Ultimate-only. The OSS scanners GitLab uses internally (Semgrep, Gemnasium, etc.) are runnable directly without GitLab's wrappers.

### 10.2 The OSS scanner toolbox (runs in any GitLab tier)

These all work as CI jobs against the org GitLab regardless of tier. They run on **your in-cluster GitLab Runners**, so the actual scanning happens on your infrastructure — results stay under your control.

| Tool | What it scans | Why it's relevant for HPC |
|---|---|---|
| **[Semgrep](https://semgrep.dev/)** | Multi-language SAST (Python, JS, Go, Java, Ruby, TS, C, others). Pattern-based + 1,000+ community rules + custom rules in YAML. | Same engine GitLab uses under the hood for several languages. Strong default coverage. |
| **[gitleaks](https://github.com/gitleaks/gitleaks)** | Secret detection — hardcoded passwords, API keys, tokens. Scans git history, not just current state. | Catches credentials accidentally committed to research repos. |
| **[Trivy](https://trivy.dev/)** (`trivy fs` / `trivy repo`) | Filesystem and repo scanning for dependency vulnerabilities. Reads `requirements.txt`, `package.json`, `go.mod`, `Gemfile.lock`, `Pipfile.lock`, etc. | Same Trivy you've already deployed in Harbor. Works on code repos without containers. |
| **[Bandit](https://github.com/PyCQA/bandit)** | Python-specific security linter (SQL injection, weak crypto, eval misuse, etc.). | Most HPC analysis code is Python. |
| **[shellcheck](https://www.shellcheck.net/)** | Bash script analysis — bugs, security issues, portability problems. | HPC environments are Bash-heavy. |
| **[ansible-lint](https://ansible.readthedocs.io/projects/lint/)** (with security profile) | Ansible playbook linting + security rules. | Catches Ansible misconfigurations before they hit production. |
| **[Hadolint](https://github.com/hadolint/hadolint)** | Dockerfile linting (best practices + security). | Catches issues before Trivy sees the built image. |
| **[Checkov](https://www.checkov.io/)** | Terraform / CloudFormation / Kubernetes IaC scanning. 1,000+ built-in policies. | Catches misconfigurations in ArgoCD-managed manifests, Terraform infra-as-code, Helm chart values. |
| **[OWASP Dependency-Check](https://owasp.org/www-project-dependency-check/)** | General-purpose dep scanner (Java/Maven, .NET, Node, Python, Go, Ruby). | Broader language coverage than Trivy fs in some cases. Use if Trivy fs misses something. |
| **[tfsec](https://github.com/aquasecurity/tfsec) / [Terrascan](https://runterrascan.io/)** | Terraform-specific security alternatives to Checkov. | Pick one — Checkov is broader, tfsec is faster. |

For an HPC center with Python + R + Bash + Ansible + Terraform/IaC + Dockerfile content, **Semgrep + gitleaks + Trivy fs + Bandit + shellcheck + ansible-lint + Hadolint + Checkov** covers most realistic risk surfaces.

### 10.3 Centralized dashboard — SonarQube CE on the infra cluster

Running scanners in CI gives you JSON reports per pipeline run. That's useful but doesn't aggregate across repos, doesn't show trend lines, doesn't give code-quality context. **SonarQube Community Edition** fills that gap.

**What it is:** Self-hosted SAST + code quality platform. Free under LGPL. Covers 35+ languages with built-in analyzers. Deployed via Helm chart with a Postgres backend.

**What it gives you:**
- Per-project dashboards: SAST findings, code coverage, code smells, duplication, technical debt.
- Quality gates that fail CI builds when code quality drops below thresholds.
- Trend tracking — vulnerabilities found vs. fixed over time, per branch.
- Per-language analyzers for Python, JS, TS, Java, Go, C/C++, Bash, IaC, etc.
- OIDC SSO via Keycloak (matches your existing IdP — Keycloak stays on mgmt; SonarQube federates to it).

**Resource impact:** ~2 vCPU / 4 GiB RAM / 30 GiB PV. Fits easily on the infra cluster's agent capacity.

**Architecture placement — infra cluster:**
- Helm chart on the **infra RKE2 cluster** (alongside CI runners and other build-time infrastructure).
- Postgres via **a CloudNativePG instance running on the infra cluster** (separate from the mgmt cluster's CNPG). Add a `sonarqube` database to it. Future DefectDojo can share the same CNPG instance with its own database.
- Exposed via Kemp VIP for `sonarqube.<base>` → infra cluster's ingress-nginx → SonarQube service.
- ArgoCD-managed from the mgmt cluster (cross-cluster deploy).

**Why infra, not mgmt:** SonarQube is consumed by CI runners and the dev team viewing dashboards — not by running pods on workload clusters. If SonarQube is down, only CI builds fail; pods keep running, Kyverno keeps enforcing scan attestations on already-cached images. So the failure-domain-isolation argument that justified Harbor and Keycloak on mgmt doesn't apply with the same force. SonarQube is build infrastructure, and build infrastructure lives where workloads (and their builds) live.

**CI integration:** standard pattern is the [`sonar-scanner-cli` image](https://hub.docker.com/r/sonarsource/sonar-scanner-cli) in a CI job. Job authenticates to SonarQube with a token, scans the repo, pushes results. SonarQube's UI shows everything.

### 10.4 DefectDojo — optional, for cross-scanner triage

**What it is:** Vulnerability *management* platform — aggregates findings from 200+ scanners (SonarQube, Trivy, Semgrep, gitleaks, Snyk, Burp, ZAP, and many more) into a unified triage workflow. From the search results: *"DefectDojo acts as a central hub for vulnerability management, allowing security teams to track, manage, and remediate vulnerabilities efficiently."*

**What it adds beyond SonarQube:**
- One pane of glass across **all** scanners (Harbor's Trivy + SonarQube SAST + Semgrep CI + gitleaks CI + any future scanner).
- Triage workflow — mark false positive, accept risk, assign owner, track remediation deadline.
- Deduplication — same vulnerability surfaced by two scanners shows up once.
- Compliance reporting / risk dashboards.

**When to add:**
- If you have one scanner, SonarQube + Harbor's Trivy UI is enough.
- If you have many scanners and want unified triage workflow, DefectDojo earns its keep.

**Recommendation:** **defer until you actually have multiple scanners producing findings worth triaging across.** Day 1 stack: SonarQube + Harbor Trivy. Add DefectDojo at day 90+ if the triage burden actually justifies it. Don't add it just because it's there.

**Architecture placement (when adopted) — infra cluster** alongside SonarQube. Same CNPG instance, additional `defectdojo` database. ~1 vCPU / 2 GiB RAM / 20 GiB PV.

### 10.5 The Devtron-style "block deploy on critical CVEs" gate — done with Kyverno + Cosign + Trivy

This is what the Devtron quote you liked describes — *"prevent the deployment of container images based on the severity of vulnerabilities."* The ArgoCD stack does it via **Trivy + Cosign attestations + Kyverno admission**, and the result is *stronger* than Devtron's because the enforcement happens at the cluster admission boundary regardless of how the image got there.

**The three defense layers:**

#### Layer 1: CI fails fast on critical vulns

Build pipeline scans the just-built image. Critical vulns → CI fails → image never pushed to Harbor. Fastest feedback loop:

```yaml
trivy-image-scan:
  stage: scan
  image: aquasec/trivy
  script:
    - trivy image --severity CRITICAL --exit-code 1 $IMAGE_TAG
```

#### Layer 2: Cosign vulnerability attestation

If the scan passes, the pipeline creates a **Trivy vulnerability attestation** (a signed Sigstore-format claim recording the scan result) and signs the image:

```yaml
trivy-attest-and-sign:
  stage: sign
  needs: [trivy-image-scan]
  script:
    - trivy image --format cosign-vuln --output trivy-report.json $IMAGE_TAG
    - cosign attest --predicate trivy-report.json --type vuln $IMAGE_TAG
    - cosign sign $IMAGE_TAG
```

This is Sigstore's standard pattern — the scan result is stored alongside the image as a signed cryptographic attestation. Audit trail in [Rekor](https://docs.sigstore.dev/logging/overview/) (the Sigstore transparency log).

#### Layer 3: Kyverno blocks at admission time

Kyverno's [`verifyImages` rule](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/) supports verifying both signatures **and attestations**. The policy enforces "only admit pods whose images have a Cosign signature AND a Trivy vulnerability attestation showing zero CRITICAL findings":

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-clean-trivy-scan
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-trivy-attestation
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "harbor.<base>/*"
          attestors:
            - entries:
                - keyless:
                    issuer: "https://gitlab.<org>"
                    subject: "https://gitlab.<org>/*"
          attestations:
            - type: "https://cosign.sigstore.dev/attestation/vuln/v1"
              conditions:
                - all:
                    - key: "{{ scanner.result.summary.CRITICAL || 0 }}"
                      operator: Equals
                      value: 0
```

This is the rule that says: *"Pods can only run images from `harbor.<base>` that have a signed Trivy vulnerability attestation showing zero CRITICAL findings."* Anything else is rejected at the API server boundary.

**Why this is stronger than Devtron's gate:**

- Devtron's gate lives in Devtron — bypass Devtron's UI/API, bypass the gate.
- Kyverno's gate lives in the cluster's admission webhook. Bypass CI, bypass Cosign, bypass Harbor — Kyverno still rejects the pod. **No path into the cluster avoids admission.**
- Standard Sigstore patterns, no proprietary tooling, audit trail in cryptographic attestations.
- Kyverno policies live in git, deployed via ArgoCD, version-controlled like everything else.

**Tuning:**

- For "Critical only" use the policy above.
- For "Critical OR High" change the predicate to `{{ (scanner.result.summary.CRITICAL || 0) + (scanner.result.summary.HIGH || 0) }}`.
- For exemptions during incident response (e.g., "the only image that fixes a P1 issue happens to have a known CVE we'll accept"), use Kyverno's [`PolicyException`](https://kyverno.io/docs/exceptions/) resource to grant scoped exemptions with audit trail.

**Per-cluster, not per-app:** the same Kyverno policy bundle deploys to every workload cluster (infra + GPU + future GPU mirror) via ArgoCD. Scan-attestation enforcement applies cluster-wide automatically. New cluster spun up from your platform-manifests repo gets the policy as part of bootstrap — no per-cluster config drift.

### 10.6 The full security-scanning architecture

Two CloudNativePG instances — one on mgmt for "valuables" (auth + image-registry metadata), one on infra for build/scan data:

```
   ┌─────────────────────────────────────────┐
   │ Org GitLab (unchanged)                  │
   │  - source repos                         │
   │  - CI orchestration (.gitlab-ci.yml)    │
   └────────────────────┬────────────────────┘
                        │ runs CI jobs on
                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ INFRA CLUSTER (build & scan tier)                                       │
│                                                                         │
│  ┌─────────────────────────────────────────┐                            │
│  │ GitLab Runners (k8s executor)           │                            │
│  │ pods spin up per job, tear down after   │                            │
│  └────────────────────┬────────────────────┘                            │
│                       │                                                 │
│       ┌───────────────┼───────────────┬──────────────┐                  │
│       │               │               │              │                  │
│       ▼               ▼               ▼              ▼                  │
│  ┌────────┐   ┌────────────┐   ┌────────────┐   ┌────────────┐          │
│  │Semgrep │   │ gitleaks   │   │ Trivy fs   │   │ Lang/IaC:  │          │
│  │ (SAST) │   │ (secrets)  │   │ (deps)     │   │ Bandit,    │          │
│  │        │   │            │   │            │   │ shellcheck,│          │
│  │        │   │            │   │            │   │ ansible-   │          │
│  │        │   │            │   │            │   │ lint,      │          │
│  │        │   │            │   │            │   │ Hadolint,  │          │
│  │        │   │            │   │            │   │ Checkov    │          │
│  └────┬───┘   └────────┬───┘   └──────┬─────┘   └──────┬─────┘          │
│       │                │              │                │                │
│       │   results pushed/imported     │                │                │
│       └────────────────┴──────────────┴────────────────┘                │
│                            │                                            │
│                            ▼                                            │
│           ┌─────────────────────────────────┐                           │
│           │ SonarQube CE                    │ ◄── per-repo dashboards   │
│           │ Helm-deployed                   │     SAST + code quality   │
│           └────────────────┬────────────────┘     trends + gates        │
│                            │                                            │
│                            │ (optional, day 90+)                        │
│                            ▼                                            │
│           ┌─────────────────────────────────┐                           │
│           │ DefectDojo                      │ ◄── cross-scanner triage  │
│           │ Helm-deployed                   │     dedup, ownership      │
│           └────────────────┬────────────────┘                           │
│                            │                                            │
│                            ▼                                            │
│           ┌─────────────────────────────────┐                           │
│           │ CloudNativePG (infra instance)  │ ◄── builds-tier "non-     │
│           │   • sonarqube DB                │     valuable" data        │
│           │   • defectdojo DB (when added)  │     barman → FlashBlade   │
│           └─────────────────────────────────┘                           │
└─────────────────────────────────────────────────────────────────────────┘
                            │
                            │ Harbor scan results imported into SonarQube/
                            │ DefectDojo via Harbor webhook + API
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ MGMT CLUSTER (auth + image-registry tier)                               │
│                                                                         │
│   ┌──────────────────────┐    ┌──────────────────────┐                  │
│   │ Harbor (Trivy on push)│    │ Keycloak (OIDC IdP)  │                  │
│   └──────────┬───────────┘    └──────────┬───────────┘                  │
│              │                            │                             │
│              └─────────────┬──────────────┘                             │
│                            ▼                                            │
│           ┌─────────────────────────────────┐                           │
│           │ CloudNativePG (mgmt instance)   │ ◄── auth + image-         │
│           │   • keycloak DB                 │     registry "valuables"  │
│           │   • harbor DB                   │     barman → FlashBlade   │
│           └─────────────────────────────────┘                           │
└─────────────────────────────────────────────────────────────────────────┘
```

**Two CloudNativePG instances, by design:**
- **Mgmt CNPG** — keycloak + harbor metadata. Auth and image-registry "valuables." Failure-domain isolated from build infrastructure.
- **Infra CNPG** — sonarqube + defectdojo (when added). Build/scan data. Independent lifecycle from mgmt-tier services.
- Both back up via barman to Pure FlashBlade S3 — same backup chain, different buckets. Restore is independent per cluster.

### 10.7 Example CI template — what this looks like in practice

A shared `.gitlab-ci.yml` template that any repo can `include:` to pick up the security-scan stage. Concrete example:

```yaml
# security-scan.gitlab-ci.yml — shared template, included by every repo
stages:
  - test
  - security

semgrep:
  stage: security
  image: returntocorp/semgrep
  script:
    - semgrep ci --config=auto --json -o semgrep.json
  artifacts:
    reports:
      sast: semgrep.json
    when: always

gitleaks:
  stage: security
  image: zricethezav/gitleaks
  script:
    - gitleaks detect --source . --report-path gitleaks.json --report-format json
  artifacts:
    paths: [gitleaks.json]
    when: always

trivy-fs:
  stage: security
  image: aquasec/trivy
  script:
    - trivy fs --format json --output trivy-fs.json --severity HIGH,CRITICAL .
  artifacts:
    paths: [trivy-fs.json]
    when: always

# Language-specific — include as appropriate per repo
bandit:
  stage: security
  image: python:3.12-slim
  before_script:
    - pip install bandit
  script:
    - bandit -r . -f json -o bandit.json || true
  artifacts:
    paths: [bandit.json]
    when: always
  rules:
    - if: $CI_PROJECT_HAS_PYTHON  # only runs if repo has Python

# Push aggregated results to SonarQube
sonarqube:
  stage: security
  image: sonarsource/sonar-scanner-cli
  variables:
    SONAR_HOST_URL: "https://sonarqube.<base>"
    SONAR_TOKEN: "$SONAR_TOKEN"  # from CI variables, vault-managed
  script:
    - sonar-scanner
  needs: [semgrep, gitleaks, trivy-fs, bandit]
```

Each repo's `.gitlab-ci.yml` then just does:

```yaml
include:
  - project: 'platform/ci-templates'
    file: '/security-scan.gitlab-ci.yml'
```

### 10.8 Honest trade-offs

**What this stack gives you that you don't have today:**
- SAST on every commit
- Secret detection on every commit
- Dependency vulnerability scanning on every commit
- IaC scanning on every commit
- Centralized SonarQube dashboard with trend tracking
- Kyverno-enforced "no critical CVEs in production" gate at the cluster boundary
- All running on your own infrastructure

**What you don't get without GitLab Ultimate:**
- MR-integrated security findings UI in GitLab itself (findings show up in SonarQube and as CI artifacts instead)
- AI-assisted vulnerability triage (some teams find this overhyped; not critical for a small ops team)
- "Vulnerabilities" tab in GitLab project navigation

For a small HPC team with a security-conscious mindset but a modest scanner volume, the SonarQube tab is a perfectly good substitute for GitLab's "Vulnerabilities" tab. The MR-integration loss is the real one — but it's manageable: CI fails on critical findings, devs see the CI failure, devs check the SonarQube dashboard or the CI artifact JSON.

**Cost comparison:**
- GitLab Ultimate: ~$99/user/month at the time of writing. For a 20-person team that's ~$24k/year. Per-org pricing varies.
- This stack: SonarQube CE is free; DefectDojo is free; OSS scanners are free; infrastructure cost is absorbed by the infra cluster's existing capacity — call it $0 incremental.

For most HPC research environments, the stack is the better answer. If your org already pays for GitLab Ultimate (or might), revisit — Ultimate's polish is real, just not free.

### 10.9 Open questions specific to this section

1. **Does the org GitLab support `include:` from external sources?** Most do. If locked down, the security-scan template lives inline in each repo's `.gitlab-ci.yml`.
2. **GitLab Runner deployment scope.** Runners in-cluster on the mgmt cluster (k8s executor) is simplest. If isolation matters more than simplicity, dedicated runner VMs work too.
3. **SonarQube auth — Keycloak OIDC or local accounts?** OIDC integrates cleanly via Keycloak. Local accounts are simpler day 1. Recommendation: OIDC from day 1, since Keycloak is already running for everything else.
4. **Where do CI tokens live?** GitLab CI variables are the obvious answer. If you eventually deploy Vault, migrate sensitive tokens (Sonar API tokens, Cosign keys) there.
5. **Quality-gate enforcement aggressiveness.** Day 1: fail builds on critical SAST findings or critical CVEs in deps. Don't fail on style/code-smell. Day 30: tighten as the team learns what's noise.

---

## 9. Sources

**GitOps tools comparison:**
- [ArgoCD docs](https://argo-cd.readthedocs.io/)
- [FluxCD docs](https://fluxcd.io/)
- [The GitOps Standard in 2026: ArgoCD vs FluxCD analysis (Mechcloud)](https://dev.to/mechcloud_academy/the-gitops-standard-in-2026-a-comparative-research-analysis-of-argocd-and-fluxcd-46d8)
- [ArgoCD vs FluxCD Detailed Feature Comparison (OneUptime)](https://oneuptime.com/blog/post/2026-02-26-argocd-vs-fluxcd-comparison/view)

**Devtron:**
- [Devtron GitHub](https://github.com/devtron-labs/devtron)
- [Devtron Trivy integration docs](https://docs.devtron.ai/docs/user-guide/integrations/vulnerability-scanning/trivy)

**Promotion / progressive delivery:**
- [Kargo project site](https://kargo.io/)
- [Kargo Quickstart docs](https://docs.kargo.io/quickstart/)
- [Argo Rollouts docs](https://argoproj.github.io/argo-rollouts/)

**Image security:**
- [Harbor vulnerability scanning docs (Trivy default)](https://goharbor.io/docs/2.0.0/administration/vulnerability-scanning/)
- [Harbor Scanner Adapter for Trivy (GitHub)](https://github.com/aquasecurity/harbor-scanner-trivy)
- [Cosign / Sigstore](https://docs.sigstore.dev/)
- [Kyverno verify-images policies](https://kyverno.io/policies/?policytypes=Verify%2520Images)

**Code-level security scanning:**
- [Semgrep (semgrep.dev)](https://semgrep.dev/)
- [Semgrep + GitLab integration](https://semgrep.dev/for/gitlab/)
- [gitleaks on GitHub](https://github.com/gitleaks/gitleaks)
- [Trivy filesystem scanning](https://trivy.dev/v0.18.3/getting-started/quickstart/#scan-filesystem)
- [Bandit (Python SAST)](https://github.com/PyCQA/bandit)
- [shellcheck](https://www.shellcheck.net/)
- [ansible-lint](https://ansible.readthedocs.io/projects/lint/)
- [Hadolint](https://github.com/hadolint/hadolint)
- [Checkov (IaC scanning)](https://www.checkov.io/)
- [OWASP Dependency-Check](https://owasp.org/www-project-dependency-check/)
- [tfsec](https://github.com/aquasecurity/tfsec)
- [GitLab SAST documentation](https://docs.gitlab.com/user/application_security/sast/)
- [GitLab tier pricing](https://about.gitlab.com/pricing/)

**SonarQube + DefectDojo:**
- [SonarQube documentation](https://docs.sonarsource.com/sonarqube-server/latest/)
- [SonarQube Community Build (free) details](https://www.sonarsource.com/products/sonarqube/downloads/)
- [DefectDojo project (BSD 3-Clause)](https://github.com/DefectDojo/django-DefectDojo)
- [DefectDojo SonarQube integration](https://defectdojo.com/integrations/sonarqube)
- [DefectDojo integrations index (200+ tools)](https://defectdojo.com/integrations)

**Other tools:**
- [Argo Workflows](https://argoproj.github.io/argo-workflows/)
- [Tekton](https://tekton.dev/)
- [GitLab Agent for Kubernetes](https://docs.gitlab.com/ee/user/clusters/agent/)
- [Renovate (dep updates)](https://docs.renovatebot.com/)
