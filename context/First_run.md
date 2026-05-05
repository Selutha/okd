# First Run — Mgmt Cluster: from RKE2-bootstrapped to Rancher-up

**Last updated:** 2026-05-04 (post-rebuild — incorporates lessons from the CIDR pivot)
**Scope:** picks up after `bootstrap.md` finishes (mgmt RKE2 cluster is up
with Cilium + Gateway API CRDs + GatewayClass + Hubble) and ends with
Rancher operational at `https://rancher.rc.ufl.edu/`.
**Estimated duration on a clean run:** 30-60 minutes once the cluster
is bootstrapped. The original first run hit 4-6 hours of recovery from
gotchas now baked into the procedure.

This is a runbook, not a tutorial — it assumes you have read
`current-state.md`, `service-vip-and-naming.md`, and `bootstrap.md` for
context.

---

## Pre-conditions (must all be true)

- All 5 mgmt cluster nodes are `Ready` (`kubectl get nodes`)
- Cilium 1.19 is running with `gatewayAPI.enabled: true`,
  `gatewayClass.create: "true"`, `l2announcements: true`, `hubble` enabled
  (all set in `src/kub-mgmt/cilium-helmchartconfig.yaml` and applied at
  first boot via the seed-only manifest drop)
- **All 6 Gateway API CRDs installed**: 5 from the standard channel
  (gatewayclasses, gateways, httproutes, grpcroutes, referencegrants)
  PLUS experimental TLSRoute. Cilium 1.19's operator hard-requires
  TLSRoute for scheme registration even on clusters that don't
  functionally use it — without it, GatewayClass never gets created.
- `kubectl get gatewayclass` returns `cilium    ...    Accepted=True`
- `kubectl -n kube-system get pods | grep hubble` shows hubble-relay
  and hubble-ui Running
- Pod IPs in `100.64.0.0/20`, service IPs in `100.64.16.0/20` (per
  `cidr-plan.md` after the 2026-05-04 pivot off 192.168/16)
- `profile: cis` is enabled (PSA `restricted` cluster-wide,
  default-deny ingress NetworkPolicy in every namespace)
- Wildcard cert files for `*.rc.ufl.edu` available on the seed node
- Network team has reserved IPs for K8s LB use (3 in mgmt subnet, 3 in
  VM subnet — see `service-vip-and-naming.md`)
- Internal DNS (BIND + InfoBlox internal zone) writable; external
  InfoBlox writable for any externally-exposed services (none in this
  runbook — mgmt cluster is internal-only)
- Working directory on the seed is the local checkout of `src/kub-mgmt/`,
  or files have been scp'd there (commonly to `/root/helm/` — adjust
  path prefixes in apply commands if so)

---

## Phase 0 — Decisions (do not skip)

These are settled per `current-state.md` but worth re-confirming each
time:

| Decision | Choice | Why |
|---|---|---|
| External IP allocator | Cilium L2 announcements | Already paying for Cilium; flat L2 mgmt + VM networks suit ARP-based; one fewer component than MetalLB |
| Cert source (Phase 1) | Wildcard `*.rc.ufl.edu` as static Secret | We have the cert; cert-manager + ACME defers to Phase 2 after cert provider migration |
| Cert source (Phase 2) | cert-manager + ACME (DNS-01) | Auto-renewal post-cert-provider-migration |
| TLS termination point (internal) | Cilium Gateway | Per-service WAF deferred per service |
| TLS termination point (external) | Kemp WAF | Trust boundary at the perimeter |
| Naming | `*.rc.ufl.edu` for user-facing, `*.ufhpc` for infra | One wildcard covers everything browser-facing |
| Vault | Self-hosted, separate VMs (off this cluster) | See `vault-decision.md` |

---

## Phase 1 — Apply LB pools + smoke-test L2 announcements

**Goal:** Services of type `LoadBalancer` get assigned IPs from a pool
and are reachable from the network.

### 1a. Verify Cilium values are already in effect (set at bootstrap)

`src/kub-mgmt/cilium-helmchartconfig.yaml` was applied at first boot
with `l2announcements: true`, `k8sClientRateLimit: 50/100`, and Hubble
enabled. Confirm the ConfigMap reflects them:

```bash
kubectl -n kube-system get cm cilium-config -o yaml | \
  grep -E "enable-l2-announcements|k8s-client-qps|k8s-client-burst|enable-hubble"
# Expect: enable-l2-announcements: "true"
#         k8s-client-burst: "100"
#         k8s-client-qps: "50"
#         enable-hubble: "true"
```

If any are missing, the `cilium-helmchartconfig.yaml` didn't get dropped
on the seed before first start. Reapply via `kubectl apply -f` and bounce
the operator + agent DaemonSet:

```bash
kubectl apply -f src/kub-mgmt/cilium-helmchartconfig.yaml
kubectl -n kube-system delete pod -l io.cilium/app=operator
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=2m
```

### 1b. (Skipped — verification handled in 1a)

### 1c. Apply LB pools and L2 policies

```bash
kubectl apply -f src/kub-mgmt/cilium-l2-pools.yaml
kubectl get ciliumloadbalancerippool
# Expect: mgmt-pool and vm-pool, IPS AVAILABLE: 3 each, CONFLICTING: False
kubectl get ciliuml2announcementpolicy
# Expect: mgmt-l2 and vm-l2
```

> **Gotcha**: Cilium 1.16+ promoted `CiliumLoadBalancerIPPool` to `v2`.
> If you see `Warning: cilium.io/v2alpha1 CiliumLoadBalancerIPPool is
> deprecated`, the apply still succeeds but update the manifest.
> `CiliumL2AnnouncementPolicy` is still `v2alpha1` in 1.19 — leave it.

### 1d. Smoke test

The bundled `lb-test.yaml` includes a PSA-restricted-compliant nginx
pod, a LoadBalancer Service pinned to `172.16.192.7`, and the required
NetworkPolicy. Apply, validate, tear down:

```bash
kubectl apply -f src/kub-mgmt/lb-test.yaml

# IP assignment
kubectl get svc lb-test
# EXTERNAL-IP should be 172.16.192.7 within ~10s

# ARP from another mgmt-network host
arping -c 3 -I ens192 172.16.192.7
# Expect: replies with the leader node's MAC

# HTTP test
curl -sv -m 5 http://172.16.192.7/
# Expect: nginx welcome page

# Tear down — test was successful
kubectl delete -f src/kub-mgmt/lb-test.yaml
```

> **Gotcha 1**: stock nginx will be rejected by PSA `restricted`. Use
> `nginxinc/nginx-unprivileged` and ship a compliant securityContext.
> **Gotcha 2**: `default-network-policy` (CIS 5.3.2) blocks ingress
> from `world` by default. Every external-facing Service needs an
> explicit allow NetworkPolicy. `lb-test.yaml` ships one bundled.

---

## Phase 2 — Enable Hubble (network observability)

**Goal:** Hubble UI, server, relay deployed; UI reachable on
`http://hubble.rc.ufl.edu/`.

### 2a. Update Cilium values

`src/kub-mgmt/cilium-helmchartconfig.yaml` includes the `hubble:` block
(server enabled, relay + UI deployments enabled, basic metrics).

The config was already applied in Phase 1. If you need to re-apply
because Hubble wasn't enabled at the time:

```bash
kubectl apply -f src/kub-mgmt/cilium-helmchartconfig.yaml
kubectl -n kube-system rollout status deploy/hubble-relay --timeout=2m
kubectl -n kube-system rollout status deploy/hubble-ui    --timeout=2m
```

### 2b. Expose Hubble UI via the mgmt-pool LB

```bash
kubectl apply -f src/kub-mgmt/hubble-expose.yaml
kubectl -n kube-system get svc hubble-ui-lb
# EXTERNAL-IP should be 172.16.192.8 within ~10s
```

### 2c. Verify (DNS must already be in place)

```bash
curl -I http://hubble.rc.ufl.edu/
# Expect: HTTP/1.1 200 OK
# Then in browser: http://hubble.rc.ufl.edu/
```

> **Note**: Hubble UI is unauthenticated. Access is gated by network
> ACLs (campus VPN / cluster network). When Keycloak SSO is in place,
> move it behind a Gateway+oauth2-proxy. See `fix-later.md`.

---

## Phase 3 — Wildcard cert + Cilium Gateway

**Goal:** A shared Cilium Gateway terminates TLS for all `*.rc.ufl.edu`
services. HTTPRoutes from any namespace can attach.

### 3a. Create gateway-system namespace + load wildcard cert Secret

```bash
kubectl create namespace gateway-system

kubectl -n gateway-system create secret tls wildcard-rc-ufl-edu \
  --cert=/etc/pki/tls/certs/rc.ufl.edu.cert-chain.pem \
  --key=/etc/pki/tls/private/rc.ufl.edu.key

# Verify the cert has the expected SANs
kubectl -n gateway-system get secret wildcard-rc-ufl-edu \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -subject -issuer -dates -ext subjectAltName
# Expect: SAN includes DNS:*.rc.ufl.edu, expiry well in the future
```

### 3b. Apply the Gateway

```bash
kubectl apply -f src/kub-mgmt/gateway.yaml

# Watch
kubectl -n gateway-system get gateway main -w
# ADDRESS column should populate with 172.16.192.9
# PROGRAMMED column should be True

# Detail check
kubectl -n gateway-system describe gateway main
# Listeners.https.Conditions: Accepted=True, ResolvedRefs=True, Programmed=True
```

### 3c. Verify TLS termination

```bash
# DNS already in place (rancher.rc.ufl.edu → 172.16.192.9)
curl -v https://rancher.rc.ufl.edu/ 2>&1 | head -30
# Expect: TLS handshake succeeds with valid wildcard cert.
# Body will be a 404 from Envoy (no HTTPRoute yet — fine for this test).
```

---

## Phase 4 — Rancher install

**Goal:** Rancher running at `https://rancher.rc.ufl.edu/`,
auto-discovers the mgmt cluster as `local`.

### 4a. Pre-create ALL Rancher-managed namespaces with right PSA labels

**Order matters.** The HelmChart's `createNamespace: true` creates
cattle-system with default labels (PSA `restricted`, inherited from
cluster default). Rancher pods don't satisfy `restricted` — and
`baseline` isn't enough either: `system-upgrade-controller` mounts
hostPath (`/etc/ssl`, `/etc/pki`, `/etc/ca-certificates`), which is
forbidden under baseline. **cattle-system must be `privileged`.**

`rancher-managed-namespaces.yaml` pre-creates all the namespaces
Rancher (and its add-ons) will create, with PSA tuned per what each
workload actually needs:

| Namespace | PSA | Why |
|---|---|---|
| `cattle-system` | `privileged` | system-upgrade-controller mounts hostPath |
| `cattle-monitoring-system` | `privileged` | node-exporter mounts /proc, /sys |
| `cattle-logging-system` | `privileged` | FluentBit mounts /var/log |
| `cattle-fleet-system` | `baseline` | runs as root, no hostPath |
| `cattle-fleet-local-system` | `baseline` | same |
| `cattle-impersonation-system` | `baseline` | same |
| `cattle-resources-system` | `baseline` | rancher-backup operator |

Apply:

```bash
kubectl apply -f src/kub-mgmt/rancher-managed-namespaces.yaml

kubectl get namespace cattle-system -o jsonpath='{.metadata.labels}' ; echo
# Expect: pod-security.kubernetes.io/enforce=privileged (NOT baseline)
```

(The older `src/kub-mgmt/cattle-system-namespace.yaml` was the first
attempt — it set cattle-system to `baseline`, which got us further than
default `restricted` but still rejected system-upgrade-controller pods
when Rancher tried to enable it. Replaced by
`rancher-managed-namespaces.yaml` which covers all the namespaces
correctly. Don't apply both — `rancher-managed-namespaces.yaml`
supersedes.)

### 4b. Pin the Rancher version

`src/kub-mgmt/rancher-helmchart.yaml` sets `version: "2.14.1"`. Do not
leave version unset — chart latest can be a surprise upgrade. The
support matrix should be checked before bumping
(https://www.suse.com/suse-rancher/support-matrix/) — currently 2.14.1
is the version we're on for K8s 1.35.

### 4c. Apply the HelmChart CR

The install runs via RKE2's helm-controller — no `helm` CLI required.

```bash
kubectl apply -f src/kub-mgmt/rancher-helmchart.yaml

# Watch the install Job
kubectl -n kube-system get job -l owner=helm,name=rancher -w
# Wait for COMPLETIONS=1/1, Ctrl-C

# Watch Rancher pods
kubectl -n cattle-system rollout status deploy/rancher --timeout=10m
kubectl -n cattle-system get pods
# Expect: 3x rancher Running 1/1, 1x rancher-webhook Running 1/1
```

### 4d. Apply route + policy

```bash
kubectl apply -f src/kub-mgmt/rancher-route-policy.yaml
kubectl -n cattle-system get httproute rancher
# Look for Status.Parents[0].Conditions: Accepted=True, ResolvedRefs=True
```

### 4e. First login

```bash
# Bootstrap password — shown once, save it
kubectl -n cattle-system get secret bootstrap-secret \
  -o jsonpath='{.data.bootstrapPassword}' | base64 -d ; echo

# Smoke test
curl -v https://rancher.rc.ufl.edu/ 2>&1 | head -30
# Expect: 200 or redirect to /dashboard/

# Browser
# https://rancher.rc.ufl.edu/
# Paste bootstrap password → set durable admin password → accept terms
# Lands on the dashboard with `local` cluster auto-discovered
```

---

## Recovery — failed Rancher install

The Rancher install is unforgiving of partial states. If pods don't
come up cleanly the first time, do not try to "fix in place" — the
chart leaves webhook registrations and CRDs behind that turn into
deadlocks. Tear down and redo from a clean slate.

### Failure mode 1: pods stuck in `Pending` / `Init` with PSA errors

**Diagnosis**:

```bash
kubectl -n cattle-system describe rs $(kubectl -n cattle-system get rs -l app=rancher -o name | head -1)
# Look for: "violates PodSecurity \"restricted:latest\"" or "violates ... baseline"
```

**Fix**: cattle-system (and possibly the other Rancher-managed namespaces)
were created without the right PSA labels — by chart auto-create rather
than from `rancher-managed-namespaces.yaml`. Apply the comprehensive
manifest now:

```bash
kubectl apply -f src/kub-mgmt/rancher-managed-namespaces.yaml
```

This is idempotent; existing namespaces just get their labels updated.
Pods stuck pending admission start scheduling within seconds.

If a Rancher webhook configuration was already registered, the namespace
update may fail because the webhook has no endpoints. Go to recovery
mode 2.

### Failure mode 2: webhook deadlock blocks namespace updates

**Symptom**: any `kubectl apply` against the namespace fails with:

```
failed calling webhook "rancher.cattle.io.namespaces": ...
no endpoints available for service "rancher-webhook"
```

**Fix**: delete the orphaned webhook configurations:

```bash
for w in $(kubectl get validatingwebhookconfiguration -o name | grep -iE "cattle|rancher"); do kubectl delete $w; done
for w in $(kubectl get mutatingwebhookconfiguration   -o name | grep -iE "cattle|rancher"); do kubectl delete $w; done
```

Now namespace updates work again.

### Failure mode 3: full reset (recommended after any partial install)

Clean up everything Rancher and redo from scratch.

```bash
# 1. Delete the HelmChart CR — triggers helm-uninstall Job
kubectl -n kube-system delete helmchart rancher

# 2. Wait, then check what's left
kubectl -n kube-system get job -l owner=helm,name=rancher -w
kubectl -n cattle-system get all,configmap,secret,sa

# 3. Force-delete stuck post-delete pods (the hook can't finish if its
#    ServiceAccount/ConfigMap was already cleaned up)
kubectl -n cattle-system delete job rancher-post-delete --force --grace-period=0 --ignore-not-found
kubectl -n cattle-system delete pod -l "name=helm-operation" --force --grace-period=0 --ignore-not-found

# 4. Delete webhook configs (failure mode 2)
for w in $(kubectl get validatingwebhookconfiguration -o name | grep -iE "cattle|rancher"); do kubectl delete $w; done
for w in $(kubectl get mutatingwebhookconfiguration   -o name | grep -iE "cattle|rancher"); do kubectl delete $w; done

# 5. Nuke the namespace
kubectl delete namespace cattle-system

# If it hangs in Terminating for >2 min, strip the kubernetes finalizer:
#   kubectl get ns cattle-system -o json > /tmp/cs.json
#   jq '.spec.finalizers = []' /tmp/cs.json > /tmp/cs-clean.json
#   kubectl replace --raw "/api/v1/namespaces/cattle-system/finalize" -f /tmp/cs-clean.json

# 6. Cluster-scoped Rancher cleanup
#    CRITICAL: the grep MUST exclude k3s.cattle.io and helm.cattle.io —
#    those are RKE2 system CRDs, not Rancher.

# Preview what would be deleted:
kubectl get crd -o name | grep -E '\.cattle\.io$' | grep -vE 'k3s\.cattle\.io|helm\.cattle\.io'

# Strip finalizers on Rancher CRs first (prevents stuck CRD deletes):
for crd in $(kubectl get crd -o name | grep -E '\.cattle\.io$' | grep -vE 'k3s\.cattle\.io|helm\.cattle\.io' | sed 's|.*/||'); do
  kubectl get $crd -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name 2>/dev/null | \
    while read ns name; do
      [ -z "$name" ] && continue
      if [ "$ns" = "<none>" ] || [ -z "$ns" ]; then
        kubectl patch $crd $name --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null
      else
        kubectl patch $crd -n "$ns" "$name" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null
      fi
    done
done

# Then delete CRDs:
for r in $(kubectl get crd -o name | grep -E '\.cattle\.io$' | grep -vE 'k3s\.cattle\.io|helm\.cattle\.io'); do
  kubectl delete $r --timeout=30s
done

# ClusterRoles, ClusterRoleBindings, APIServices
for r in $(kubectl get clusterrole          -o name | grep -iE "cattle|rancher" | grep -vE 'k3s|helm-controller'); do kubectl delete $r; done
for r in $(kubectl get clusterrolebinding   -o name | grep -iE "cattle|rancher" | grep -vE 'k3s|helm-controller'); do kubectl delete $r; done
kubectl delete apiservice v1.ext.cattle.io --ignore-not-found

# Helm release Secrets
kubectl -n kube-system delete secret -l owner=helm,name=rancher --ignore-not-found

# 7. Verify clean
kubectl get crd                | grep -iE "cattle|rancher" | grep -vE 'k3s|helm.cattle'
kubectl get clusterrole        | grep -iE "cattle|rancher" | grep -vE 'k3s|helm-controller'
kubectl get clusterrolebinding | grep -iE "cattle|rancher" | grep -vE 'k3s|helm-controller'
kubectl get apiservice         | grep -iE "cattle|rancher" | grep -vE 'k3s|helm.cattle'
# All four should be empty.

# 8. Recreate Rancher-managed namespaces with right per-namespace PSA labels
kubectl apply -f src/kub-mgmt/rancher-managed-namespaces.yaml

# 9. Reapply HelmChart
kubectl apply -f src/kub-mgmt/rancher-helmchart.yaml
```

### Failure mode 4: GatewayClass never gets Accepted=True after Phase 5a

Symptom on a fresh build: `kubectl get gatewayclass` returns `No resources found` even after the operator has been bounced post-CRD install.

```bash
# Check operator logs
kubectl -n kube-system logs -l io.cilium/app=operator --tail=200 | grep -iE 'tlsroute|gateway-api|gatewayclass'
```

If you see `no kind is registered for the type v1alpha2.TLSRouteList`:
the experimental TLSRoute CRD wasn't installed. Cilium 1.19's operator
registers `TLSRouteList` in its Go scheme regardless of whether you use
TLSRoute functionally. Without the CRD, the gateway-api reconcile loop
spins on errors and GatewayClass creation never completes.

```bash
GW=https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd
kubectl apply -f ${GW}/experimental/gateway.networking.k8s.io_tlsroutes.yaml
kubectl -n kube-system delete pod -l io.cilium/app=operator
sleep 30
kubectl get gatewayclass
# Expect: cilium    Accepted=True
```

If TLSRoute is present and the operator looks healthy but GatewayClass
still doesn't appear, the helm values need `gatewayClass.create: "true"`:

```yaml
# In src/kub-mgmt/cilium-helmchartconfig.yaml under spec.valuesContent:
gatewayAPI:
  enabled: true
  gatewayClass:
    create: "true"      # ← this is what auto-creates the GatewayClass
```

Then `kubectl apply -f src/kub-mgmt/cilium-helmchartconfig.yaml` and
bounce the operator. Or as a one-shot fix, create the GatewayClass
manually:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
EOF
```

Both fixes coexist — set `gatewayClass.create: "true"` in values for
future reproducibility AND apply the GatewayClass manually to unblock
the current build.

### Failure mode 5: accidentally deleted RKE2 system CRDs

If your cleanup grep was too broad and you nuked
`addons.k3s.cattle.io`, `etcdsnapshotfiles.k3s.cattle.io`,
`helmchartconfigs.helm.cattle.io`, or `helmcharts.helm.cattle.io`:

```bash
# Restart rke2-server on the seed — re-applies bundled manifests
sudo systemctl restart rke2-server

# Verify
kubectl get crd | grep -E "k3s.cattle.io|helm.cattle.io"
# Expect: addons, etcdsnapshotfiles, helmchartconfigs, helmcharts
```

If still missing after restart, roll through the remaining 4 nodes one
at a time, waiting for `kubectl get nodes` to show Ready between each.

The HelmChartConfig CR for `rke2-cilium` is also lost in this scenario
(deleted along with its CRD). Reapply it once the CRD is back:

```bash
kubectl apply -f src/kub-mgmt/cilium-helmchartconfig.yaml
```

Cilium itself keeps running through this — DaemonSets are independent
of the HelmChart that created them.

---

## Post-install state

After this runbook completes:

| Component | URL / Endpoint | Auth |
|---|---|---|
| Rancher UI | https://rancher.rc.ufl.edu/ | Local admin (set during bootstrap) |
| Hubble UI | http://hubble.rc.ufl.edu/ | None — gated by network ACLs |
| K8s API | https://vkub-mgmt.ufhpc:6443/ | kubeconfig (via Rancher or direct) |

Cluster has:
- CIDRs: pod 100.64.0.0/20, service 100.64.16.0/20 (per cidr-plan.md)
- Cilium L2 announcements active on both interfaces (mgmt + VM)
- Two LB pools (mgmt-pool 172.16.192.7-9, vm-pool 10.13.160.7-9)
- One Cilium Gateway with wildcard TLS termination
- Rancher managing the local cluster

Next phases (post-Rancher): cert-manager + ACME (Phase 2), workload
clusters (gpu, infra) bootstrapped via Rancher and `bootstrap-cluster.sh`,
Vault stand-up on dedicated VMware VMs, Keycloak/Shibboleth SSO.

---

## Lessons from the first build (already baked into procedures above)

These are documented here for context — the corrected procedures above
already account for them. Listed so a future operator reading this
runbook understands why specific steps exist.

| Lesson | Why it bit | Where it's now handled |
|---|---|---|
| Pod CIDR 192.168.16.0/20 collided with `hpg-roce` storage subnet | Original cidr-plan assumed 192.168/16 was free; environment had many existing subnets there. Dormant collision until storage CSI added connectivity. | Pivoted to 100.64.0.0/10 (RFC6598). See `cidr-plan.md`. |
| TLSRoute CRD missing → GatewayClass never created | Earlier guidance excluded TLSRoute as "not needed for mgmt." Cilium 1.19's operator registers `TLSRouteList` in its scheme regardless of use. | `bootstrap.md` Phase 5 now installs all 6 CRDs (5 standard + experimental TLSRoute). |
| GatewayClass not auto-created even with CRDs in place | Default helm value for `gatewayAPI.gatewayClass.create` doesn't always trigger creation. | `cilium-helmchartconfig.yaml` explicitly sets `gatewayClass.create: "true"`. |
| `ufrc_rke2` Puppet `fail()` aborted catalog when interfaces named differently at first run (kickstart-time vs post-boot udev rename) | Hard fail on missing interface IP blocked all other Puppet resources from applying. | Soft-skip with notice() in `src/ufrc_rke2/manifests/config.pp`; bootstrap.md Prerequisites verifies node-ip after first puppet run. |
| Rancher install hung with cattle-system at default PSA `restricted` | Chart auto-created cattle-system with cluster-default labels; Rancher pods don't satisfy restricted; admission rejected; webhook deadlock. | Pre-create namespaces from `rancher-managed-namespaces.yaml` BEFORE `rancher-helmchart.yaml`. cattle-system is `privileged` (not baseline — system-upgrade-controller's hostPath mounts need it). |
| Cleanup grep hit RKE2 system CRDs | `grep -i "cattle"` matched `addons.k3s.cattle.io`, `helmchartconfigs.helm.cattle.io`, etc. | All cleanup commands use `grep -E '\.cattle\.io$' \| grep -vE 'k3s\.cattle\.io\|helm\.cattle\.io'` to exclude system CRDs. |
| L2 announce subsystem didn't initialize after enabling at runtime | Cilium pods cached old config until restart. | Restart cilium-operator + agent DaemonSet after applying values changes that affect startup-time features (now in Phase 1a). |
