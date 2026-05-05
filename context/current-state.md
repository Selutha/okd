# Current State — Resume Checkpoint

**Last updated:** 2026-05-04 (Rancher live — first major milestone after cluster bootstrap)
**Read this first when picking up this build in a new session.**

This doc is the entry point. It points to the canonical per-topic docs
and captures context that lives only in conversation history (so future
sessions can recover the why behind decisions without re-deriving them).

---

## TL;DR

The **mgmt RKE2 cluster is built and operational, with Rancher live**.
5 nodes Ready, Cilium 1.19 with VXLAN + Gateway API + L2 announcements,
Hubble UI deployed, Cilium Gateway terminating TLS for `*.rc.ufl.edu`,
Rancher 2.14.1 running and managing the local cluster. etcd snapshots
flowing every 6h to a Qumulo S3 bucket. Next phases: cert-manager + ACME
(Phase 2), workload cluster bootstraps under Rancher, Vault stand-up.

## What exists right now

### Mgmt cluster — built, healthy, operational

| Property | Value |
|---|---|
| Cluster name | mgmt |
| Nodes | kub-mgmt1 through kub-mgmt5 (all server / control-plane) |
| Etcd quorum | 3 of 5 (tolerates 2 failures) |
| Kubernetes version | v1.35.4+rke2r1 |
| CNI | Cilium 1.19 — VXLAN tunnel, kubeProxyReplacement: true, Gateway API enabled |
| Pod CIDR | 192.168.0.0/20 (per-node /25 = 32-node ceiling) |
| Service CIDR | 192.168.16.0/20 |
| MTU | 8950 (underlay 9000 - 50 byte VXLAN overhead) |
| API VIP | vkub-mgmt.ufhpc (172.16.192.6) — Kemp L4 passthrough |
| Network split | mgmt (ens192, 172.16.192.x) for control plane; VM (ens224, 10.13.160.x) for cluster-internal + etcd peer + Cilium tunnel |
| etcd backups | Every 6h to s3://kub-mgmt-etcd/ on qumulo-data.ufhpc:9000, retention 28 per server |
| GatewayClass | `cilium` (Accepted: True) |
| PSA enforcement | `restricted` (via `profile: cis`) — pods need compliant securityContext |
| Profile | `cis` enabled — requires CIS sysctls + etcd user (currently set manually on each node, see fix-later.md) |

### What's installed (May 2026)

- **Cilium L2 announcements**: `mgmt-pool` (172.16.192.7-9 on ens192) and
  `vm-pool` (10.13.160.7-9 on ens224) live and validated end-to-end.
- **Hubble**: server + relay + UI deployed. UI live at
  `http://hubble.rc.ufl.edu/` (172.16.192.8). Unauthenticated until
  Keycloak SSO lands; gated by network ACLs only.
- **Cilium Gateway** in `gateway-system` namespace, listening on
  172.16.192.9:443 with wildcard `*.rc.ufl.edu` TLS termination.
- **Rancher 2.14.1**: live at `https://rancher.rc.ufl.edu/`, managing
  the local cluster. Admin password set during bootstrap.

### What's NOT installed yet (queued work)

In recommended order:

1. **etcd snapshot validation drill** — take a real DR snapshot restore
   to a lab to validate `mgmt-cluster-operations.md` restore procedure
   before staking production workloads on it.
2. **cert-manager + ACME** (Phase 2 of cert plan, blocked on the cert
   provider migration). Auto-renewal of the wildcard via DNS-01 against
   `rc.ufl.edu`. Open question: which DNS solver — RFC2136, Infoblox
   webhook, or CNAME-delegation pattern. See `service-vip-and-naming.md`.
3. **Workload cluster bootstraps** under Rancher — gpu, infra. Use
   `src/bootstrap-cluster/bootstrap-cluster.sh` against the live Rancher
   to generate registration commands. Each cluster gets its own
   `src/<cluster-name>/` directory mirroring the `src/kub-mgmt/` shape.
4. **Vault** on dedicated VMware VMs (parallel track, see
   `vault-decision.md`). Driven by campus-Vault 10s-lag pain.
5. **Keycloak SSO** — once available, put Hubble UI and other
   currently-unauthenticated admin tools behind oauth2-proxy + Keycloak.
6. **Migrate cert-manager Issuer to Vault PKI** for internal mTLS once
   Vault is up.

After Rancher is up, the `bootstrap-cluster/` tooling and design-rke2.md's
post-Rancher procedures take over for the rest of the fleet.

### Cert strategy (locked)

| Layer | Phase 1 (now) | Phase 2 (after cert provider migration) |
|---|---|---|
| Mgmt cluster admin UIs (`*.rc.ufl.edu`) | Wildcard cert as static Secret, manual rotation | cert-manager + ACME ClusterIssuer + DNS-01, auto-renewed |
| Customer-facing services (future workload clusters) | Wildcard at Kemp, plain HTTP behind | Wildcard at Kemp, plain HTTP behind |
| Internal mTLS / service-to-service (future) | Not yet needed | Vault PKI (when Vault lands) |
| Kube-apiserver / etcd (`.ufhpc` names) | RKE2-managed internal CA | RKE2-managed internal CA |
| AD-CS | **Not used** — AD is for logins only | **Not used** |

Two parallel domain spaces: `.ufhpc` (internal, RKE2-managed certs) and
`.rc.ufl.edu` (user-facing, wildcard-covered). Hostname planning needs to
keep them separate.

Phase 2 ACME work blocked on: cert provider migration completing. Open
question for that phase: which DNS solver for cert-manager DNS-01 against
`rc.ufl.edu` (RFC2136 vs Infoblox vs CNAME-delegation to a smaller zone).
See `vault-decision.md` for the parallel Vault track.

## Recent build trajectory (reading the conversation context)

- Initial design assumed Cilium native routing + Kemp Connection Manager
  Ingress Controller (RDR-7 in design-rke2.md). **This was retired during
  build** in favor of Cilium VXLAN + Cilium Gateway API. design-rke2.md has
  a v0.9 supersession header documenting the change; per-topic docs are
  current.
- Mgmt cluster is the **first cluster** in the fleet — Rancher doesn't
  exist yet. `bootstrap-cluster.sh` does NOT apply here (it requires
  Rancher to fetch a registration token). Mgmt cluster bootstraps with
  direct binary install (tar method per RDR-8) — see `bootstrap.md`.
- Several "obvious" defaults bit during build: Gateway API CRDs need to
  be installed *before* Cilium chart renders (or with `gatewayClass.create:
  "true"` set explicitly), the operator does its CRD-presence check at
  startup so a restart is needed if CRDs land later, GRPCRoute is a hard
  requirement (not just optional), and `profile: cis` enforces a strict
  set of sysctls + a non-root etcd user that don't exist on RHEL by
  default. All captured in `bootstrap.md` Phase 5 + Phase 5a.

## Doc map — what to read for what

Order: read top-down on first session; jump to specific docs after.

| Doc | What it covers | When to read |
|---|---|---|
| **`current-state.md`** (this file) | Where we are, what's next, doc map | First, every session |
| `bootstrap.md` | End-to-end mgmt cluster bootstrap procedure | When rebuilding or troubleshooting first-boot |
| `mgmt-cluster-operations.md` | Day-2 runbook (kubectl, snapshots, restore, verify, add/remove nodes) | When operating the live cluster |
| `fix-later.md` | Tracked technical debt / known workarounds | When deciding what to harden, before production |
| `cidr-plan.md` | Fleet-wide CIDR allocation policy + per-cluster slot table | Before building any new cluster |
| `cidr-100.64-notes.md` | RFC6598 notes (escape hatch for future, currently unused) | Only if exhausting 192.168.0.0/16 |
| `kemp-vip-design.md` | Kemp L4 VIPs for kube-apiserver + supervisor | Before configuring Kemp for a new cluster |
| `kemp-cilium-routing.md` | Ingress architecture (Cilium GW + optional Kemp relay) | When designing app-facing ingress |
| `design-rke2.md` | Original master design doc (v0.9 supersession header at top) | For decision rationale; trust per-topic docs over this for current procedure |
| `design.md` | OKD-variant design (alternative that wasn't picked) | Historical reference; rarely needed |
| `okd-vs-rke2.md`, `okd-advantages.md` | Why RKE2 was picked over OKD | Historical; only re-read if challenging the choice |
| `platform-components.md` | Inventory of what each platform service does | When picking what to install where |
| `general-notes.md`, `slinky-reading.md` | Misc research notes from earlier phases | Mostly historical |
| `vault-decision.md` | Self-host Vault decision doc (parallel track) | When picking up the Vault stand-up work |
| `First_run.md` | End-to-end runbook: from RKE2-bootstrapped → Rancher live, with the recovery procedures we earned the hard way | Before rebuilding mgmt cluster from scratch, or building any subsequent cluster that uses Rancher + profile:cis |
| `service-vip-and-naming.md` | DNS naming, VIP allocation, Kemp/internal patterns, NetworkPolicy requirements | When planning any new Service exposure |

The `bootstrap-cluster/` directory in `src/` is **for future workload
clusters** (cluster #2 onwards under Rancher's management). Not used for
mgmt cluster bootstrap. See `bootstrap-cluster/README.md` for that
tooling.

## Source code in `src/`

| Path | Status | Notes |
|---|---|---|
| `src/ufrc_rke2/` | **Modified during build, NOT committed** | Added `vm_iface` and `mgmt_iface` params for auto-deriving node-ip / node-external-ip from facts. Uncommitted in working tree as of last session. User will commit + distribute when convenient. |
| `src/kub-mgmt/cilium-helmchartconfig.yaml` | Source of truth for mgmt cluster Cilium values (bootstrap + day-2) | VXLAN, /20 pool, MTU 8950, kubeProxyReplacement, gatewayAPI, l2announcements, k8sClientRateLimit 50/100 |
| `src/kub-mgmt/cilium-l2-pools.yaml` | LoadBalancer IP pools and L2 announcement policies | mgmt-pool (172.16.192.7-9 on ens192), vm-pool (10.13.160.7-9 on ens224); Service selects via `lb-pool: mgmt|vm` label |
| `src/kub-mgmt/lb-test.yaml` | Validation manifest, not declared steady-state | nginx (PSA-restricted-compliant) + LoadBalancer pinned to .7 + NetworkPolicy; delete after smoke test |
| `src/kub-mgmt/hubble-expose.yaml` | LoadBalancer Service + NetworkPolicy exposing hubble-ui | Pinned to 172.16.192.8, internal DNS as `hubble.rc.ufl.edu`. Unauthenticated until Keycloak SSO lands. |
| `src/kub-mgmt/network-policy-templates.yaml` | Copy-paste catalog of NetworkPolicy shapes for common patterns | Not for direct kubectl apply |
| `src/kub-mgmt/gateway.yaml` | Cilium Gateway in `gateway-system`, listener on 172.16.192.9:443 with wildcard TLS | One Gateway, many HTTPRoutes attach |
| `src/kub-mgmt/rancher-helmchart.yaml` | Rancher install via RKE2's helm-controller HelmChart CR (no helm CLI required) | Pin Rancher version before applying |
| `src/kub-mgmt/rancher-route-policy.yaml` | Rancher's HTTPRoute (cattle-system) + ingress NetworkPolicy | Apply after the helm-install Job completes |
| `src/kub-mgmt/cattle-system-namespace.yaml` | cattle-system namespace with PSA `baseline` labels | **Apply BEFORE rancher-helmchart.yaml** |
| `src/kub-mgmt/hubble-expose.yaml` | LoadBalancer Service + NetworkPolicy exposing hubble-ui at 172.16.192.8 | Already applied; safe to re-apply (idempotent) |
| `src/kub-mgmt/cnpg-operator-helmchart.yaml` | CloudNativePG operator (Postgres for Keycloak; future use for other in-cluster DB needs) | Pin chart version |
| `src/kub-mgmt/keycloak-namespace.yaml` | keycloak namespace with PSA `baseline` labels (preemptive) | **Apply BEFORE keycloak-postgres.yaml or keycloak.yaml** |
| `src/kub-mgmt/keycloak-postgres.yaml` | CNPG Cluster CR: 3 Postgres replicas backing Keycloak | Apply after CNPG operator is Ready |
| `src/kub-mgmt/keycloak-operator-install.md` | Procedure for installing Keycloak Operator (raw kubectl apply, no Helm chart available) | Read before applying keycloak.yaml |
| `src/kub-mgmt/keycloak.yaml` | Keycloak CR: 3 instances, backed by keycloak-pg, hostname keycloak.rc.ufl.edu | Apply after Postgres + Operator are Ready |
| `src/kub-mgmt/keycloak-route-policy.yaml` | HTTPRoute attaching Keycloak to the Cilium Gateway + NetworkPolicy allow-from-world | Apply after Keycloak instance is Ready |
| `src/bootstrap-cluster/bootstrap-cluster.sh` | Unchanged from start of session | For Rancher-managed workload clusters, doesn't apply to mgmt |

## Critical context that's not in the per-topic docs

These are decisions / states that live only in conversation history. Worth
preserving for future sessions:

- **S3 access key was shared in conversation** (this session). User is OK
  with current trust posture (HPC controlled environment, accepted risk
  for tokens in Foreman). User explicitly noted they will rotate the key
  before production. Tracked in `fix-later.md` high-priority section.
- **Server URL on the seed**: We picked the "uniform Foreman config + manual
  sed on seed before first start" approach over per-host overrides. Reason:
  all 3+ nodes have identical Foreman config, easier to maintain. The cost
  is one manual `sed -i '/^server:/d'` on the seed at bootstrap. Documented
  in `bootstrap.md`.
- **Two puppet flags drive cluster prereqs**: `has_kub_installed=true`
  triggers the sysctl module; `has_etcd_local_user=true` triggers the user
  class. Both are set on the mgmt_cluster Foreman hostgroup. The `ufrc_rke2`
  module deliberately does NOT manage these (would race with the existing
  modules). Captured in `bootstrap.md` Prerequisites and `fix-later.md`.
- **Cilium Gateway API was a re-architecture decision mid-build.** Original
  plan was Kemp Connection Manager L7 ingress (RDR-7). Decision made during
  conversation to switch to Cilium GW because we already pay for Cilium,
  and Cilium 1.19's Gateway API support is solid. Kemp is reduced to L4
  passthrough only (current cluster) with the option of per-service L7+WAF
  VIPs added later when needed (deferred decision per service).
- **PSA restricted is enforced cluster-wide via `profile: cis`**. Future
  app installs need to ship with PSA-compliant manifests (runAsNonRoot,
  drop ALL caps, seccompProfile=RuntimeDefault, etc.). Helm charts may
  need values overrides to accommodate. `bootstrap.md` Phase 8 has a
  reference compliant manifest.
- **Default-deny ingress NetworkPolicy in every namespace via `profile:
  cis`** (CIS 5.3.2). At cluster bootstrap, RKE2 created a
  `default-network-policy` in every namespace that allows ingress only
  from same-namespace pods + host. **Every Service exposed to traffic
  from outside its namespace (especially anything with `world` ingress —
  LoadBalancer Services, Cilium Gateway listeners, NodePorts) needs an
  explicit NetworkPolicy alongside it allowing the appropriate ingress.**
  Symptom of forgetting: traffic appears to reach the node and gets
  DNAT'd, but is silently dropped at the destination pod's eBPF program
  with "Policy denied". Only visible in `cilium-dbg monitor` or Hubble.
  Pattern: ship NetworkPolicy in the same manifest as the
  Deployment/Service (see `lb-test.yaml` for an example).
- **PSA `baseline` required on cattle-system** to install Rancher.
  Cluster default is `restricted` from `profile: cis`; Rancher pods don't
  satisfy `restricted`. **Always pre-create cattle-system from
  `cattle-system-namespace.yaml` BEFORE applying `rancher-helmchart.yaml`** —
  the chart's `createNamespace: true` creates without PSA labels, pods
  get rejected, install hangs, leaves stale webhooks behind. Recovery is
  documented in `First_run.md` Recovery section.
- **Cleanup grep for Rancher cluster-scoped resources MUST exclude
  `k3s.cattle.io|helm.cattle.io`.** The naive `grep -i "cattle|rancher"`
  matches RKE2 system CRDs (`addons.k3s.cattle.io`,
  `etcdsnapshotfiles.k3s.cattle.io`, `helmchartconfigs.helm.cattle.io`,
  `helmcharts.helm.cattle.io`) — deleting these breaks helm-controller
  and the cluster's chart management. Recovery is `systemctl restart
  rke2-server` (re-applies bundled CRD manifests). Use the safer pattern
  documented in `First_run.md`.
- **All 6 Gateway API CRDs are installed** (5 standard + experimental
  TLSRoute). Earlier guidance excluded TLSRoute on the basis that mgmt
  cluster doesn't functionally use it — that turned out to be wrong for
  Cilium 1.19. The operator's gateway controller registers the
  `TLSRouteList` Go type in its scheme regardless of use; without the
  CRD installed, the reconcile loop spins on errors and GatewayClass is
  never created. Install all 6 (standard channel for the first 5,
  experimental channel for TLSRoute). Same install applies on workload
  clusters.

## Resume cheatsheet — Keycloak install (next session)

All manifests are written and in `src/kub-mgmt/`. Apply in this exact
order from a workstation with kubectl access to the mgmt cluster (or
SSH to kub-mgmt1 and `kubectl` from there).

### Pre-flight checks

```bash
# 1. Working directory at the local checkout root
cd /path/to/okd                         # adjust to wherever you pulled the repo

# 2. Verify cluster is healthy
kubectl get nodes
kubectl -n cattle-system rollout status deploy/rancher --timeout=30s
kubectl -n gateway-system get gateway main
# All should show healthy / Ready / Programmed=True

# 3. Verify Pure Storage CSI StorageClass name (used by keycloak-postgres.yaml)
kubectl get storageclass
# If the class isn't named `pure-block`, edit
# src/kub-mgmt/keycloak-postgres.yaml: spec.storage.storageClassName

# 4. Pin versions before applying (placeholders are in the files)
#    Edit src/kub-mgmt/cnpg-operator-helmchart.yaml: spec.version (CNPG chart)
#    Note Keycloak Operator version for the kubectl apply step (see step 4)
```

### Apply order

```bash
# === Step 1: CNPG operator ===
kubectl apply -f src/kub-mgmt/cnpg-operator-helmchart.yaml

# Wait for helm-install Job
kubectl -n kube-system get job -l owner=helm,name=cnpg-operator -w
# Wait for COMPLETIONS=1/1, Ctrl-C

# Verify operator
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=5m
kubectl get crd | grep cnpg
# Expect: clusters.postgresql.cnpg.io, backups, scheduledbackups, poolers

# === Step 2: keycloak namespace (BEFORE Postgres or Keycloak CRs) ===
kubectl apply -f src/kub-mgmt/keycloak-namespace.yaml
kubectl get ns keycloak -o jsonpath='{.metadata.labels}' ; echo
# Expect: pod-security.kubernetes.io/enforce=baseline visible

# === Step 3: Postgres cluster (3 replicas) ===
kubectl apply -f src/kub-mgmt/keycloak-postgres.yaml
kubectl -n keycloak get cluster keycloak-pg -w
# Wait until STATUS shows "Cluster in healthy state", Ctrl-C

kubectl -n keycloak get pods -l cnpg.io/cluster=keycloak-pg
# Expect: keycloak-pg-1, keycloak-pg-2, keycloak-pg-3 all Running 1/1

kubectl -n keycloak get secret keycloak-pg-app
# Expect: type=Opaque (CNPG bootstrap created it with username + password)

# === Step 4: Keycloak Operator (manual kubectl apply, no Helm chart) ===
# Pick a version (check https://www.keycloak.org/downloads):
VERSION=26.0.5

kubectl apply -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${VERSION}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${VERSION}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
kubectl apply -n keycloak -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${VERSION}/kubernetes/kubernetes.yml

kubectl -n keycloak rollout status deploy/keycloak-operator --timeout=5m

# === Step 5: Keycloak instance ===
kubectl apply -f src/kub-mgmt/keycloak.yaml
kubectl -n keycloak get keycloak keycloak -w
# Wait until conditions show Ready=True (2-3 min for first start)

kubectl -n keycloak get pods -l app=keycloak
# Expect: 3 keycloak pods Running

# === Step 6: HTTPRoute + NetworkPolicy ===
# Verify DNS first:
#   keycloak.rc.ufl.edu  →  172.16.192.9 (in InfoBlox internal zone)
#   already done per project memory

kubectl apply -f src/kub-mgmt/keycloak-route-policy.yaml
kubectl -n keycloak get httproute keycloak
# Look for Status.Parents[0].Conditions: Accepted=True, ResolvedRefs=True

# === Smoke test ===
curl -v https://keycloak.rc.ufl.edu/realms/master 2>&1 | head -30
# Expect: 200 with JSON metadata, valid TLS cert

# === First admin login ===
# Get the auto-generated initial admin password
kubectl -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d ; echo
# Username: admin
# Browser: https://keycloak.rc.ufl.edu/admin/
# Set a durable admin password on first login.
```

### After Keycloak is up — runtime config (UI-driven)

These are tasks #21-23 in the task list. Most of this is point-and-click
in the Keycloak admin UI; some requires UF Shibboleth team coordination.

1. **Task #21 — File SP registration with UF Shibboleth team**
   - Entity ID: `https://keycloak.rc.ufl.edu/realms/ufrc`
   - SP metadata URL: `https://keycloak.rc.ufl.edu/realms/ufrc/broker/saml/endpoint/descriptor`
   - Required attributes: `eppn`, `mail`, `displayName`
   - Allowed callback: `https://keycloak.rc.ufl.edu/realms/ufrc/broker/saml/endpoint`
   - UF responds with the InCommon Federation metadata aggregate URL — that's
     what Keycloak's IdP config uses upstream

2. **Task #22 — Configure Keycloak realm + federation** (in admin UI):
   - Create realm `ufrc`
   - Identity Providers → Add SAML provider, point at InCommon metadata aggregate
   - User Federation → Add LDAP, ldap.ufhpc (anon bind — confirm baseDN later)
   - User Federation → Add LDAP, UFAD (with bind credentials)
   - Edit "First Broker Login" auth flow: deny if user not found in OpenLDAP
   - Configure LDAP Group Mappers (rc-users, rc-rancher-admin via UFAD nesting)
   - Define realm roles → app-specific permissions

3. **Task #23 — OIDC clients**:
   - Rancher: create OIDC client in Keycloak, then in Rancher UI configure
     the OIDC auth provider pointing at Keycloak's OIDC endpoints
   - oauth2-proxy: create OIDC client for Hubble UI front-end
   - Test login flows end-to-end

The runtime config piece will take a few hours. The install (steps 1-6
above) should be ~20-30 minutes if pods come up cleanly first try.

## Resume command suggestions for future sessions

When the user says "let's pick this back up" or similar:

1. Read `current-state.md` first (this file)
2. Read whichever per-topic doc matches the next planned step
3. Verify cluster is still healthy with the verification commands in
   `mgmt-cluster-operations.md` before assuming the documented state still
   holds
4. Update `current-state.md` at the end of the session with progress

If the user has already started a specific task ("install cert-manager",
"add a node", etc.), jump directly to the relevant doc — this file is the
entry point, not a required preamble for every interaction.
