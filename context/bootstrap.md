# Mgmt cluster bootstrap runbook

End-to-end procedure for bootstrapping the **mgmt RKE2 cluster** from clean,
freshly-provisioned RHEL 9 hosts. This is the *first* cluster in the fleet —
no Rancher exists yet to register against, so `bootstrap-cluster.sh` does NOT
apply here. That script is for cluster #2 onwards.

For workload clusters (infra, gpu) once Rancher is up, see
`bootstrap-cluster/README.md` and `bootstrap-cluster/manual-bootstrap-runbook.md`.

## Scope and applicability

> **Gateway API CRDs — install all six (5 standard + experimental TLSRoute):**
> This runbook installs all five **standard** Gateway API CRDs (GatewayClass,
> Gateway, HTTPRoute, GRPCRoute, ReferenceGrant) **plus** the experimental
> TLSRoute CRD on the mgmt cluster.
>
> Earlier guidance said "TLSRoute is intentionally NOT installed on mgmt
> cluster" since the mgmt cluster doesn't route TLS through the Gateway API.
> That guidance is **wrong for Cilium 1.19**: the operator's gateway
> controller registers the `TLSRouteList` type in its Go scheme regardless
> of whether it's used, and without the CRD installed the scheme
> registration fails. The reconcile loop then spins on
> `Failed to get related HTTPRoutes ... no kind is registered for
> v1alpha2.TLSRouteList` errors, and the GatewayClass never gets created.
>
> When you build the GPU cluster, the same six-CRD install applies. The
> external L4 TLS passthrough use case described in `kemp-cilium-routing.md`
> uses TLSRoute functionally on that cluster; here we install the CRD only
> to satisfy the operator's scheme registration.

## Prerequisites

These must be true before starting. Failures here produce confusing errors
later that look like RKE2 bugs.

### Puppet-managed prerequisites (verified via host facts/params)

The following are handled by puppet classes triggered by host parameters set
on the host or hostgroup. **Verify they're set in Foreman before puppet runs**:

| Foreman host param | What it triggers | Why |
|---|---|---|
| `has_etcd_local_user = true` | Creates the system `etcd` user/group | RKE2 with `profile: cis` requires etcd to run as a dedicated non-root user; startup fails fast without it |
| `has_kub_installed = true` | Sysctl class applies CIS-required kernel parameters | RKE2 with `profile: cis` enforces `vm.overcommit_memory=1`, `vm.panic_on_oom=0`, `kernel.panic=10`, `kernel.panic_on_oops=1`, `kernel.keys.root_maxbytes=25000000`, `kernel.keys.root_maxkeys=1000000` |
| `is_kub_management_cluster = true` | Tagging param (read by other classes); host inclusion in mgmt cluster scope | Marker for the mgmt cluster's identity |

After `puppet agent -t`, verify on the node:

```bash
# etcd user exists
id etcd     # uid=NNN(etcd) gid=NNN(etcd) groups=NNN(etcd)

# All six CIS sysctls applied
for k in vm.overcommit_memory vm.panic_on_oom kernel.panic kernel.panic_on_oops kernel.keys.root_maxbytes kernel.keys.root_maxkeys; do
  sysctl $k
done
# Expected:
#   vm.overcommit_memory = 1
#   vm.panic_on_oom = 0
#   kernel.panic = 10
#   kernel.panic_on_oops = 1
#   kernel.keys.root_maxbytes = 25000000
#   kernel.keys.root_maxkeys = 1000000

# node-ip and node-external-ip should be populated in 00-puppet.yaml
grep -E '^node-(ip|external-ip):' /etc/rancher/rke2/config.yaml.d/00-puppet.yaml
# Expected (values match interface IPs):
#   node-ip: 10.13.160.X
#   node-external-ip: 172.16.192.X
```

**If `node-ip` / `node-external-ip` are missing**: `ufrc_rke2`'s
interface-IP derivation soft-skips when the named interfaces (`ens224`,
`ens192`) don't exist or have no IP yet. This typically happens during
the first puppet run if it fires before systemd-udev's predictable
network naming has fully settled (interfaces transiently appear as
`eth0`/`eth1` instead of `ens192`/`ens224`), or before NetworkManager
has assigned IPs to all NICs. Check Puppet's run output for a
`Notice: Scope(Class[Ufrc_rke2::Config]): ... missing or has no IP`
line confirming the soft-skip happened. Re-run puppet manually:

```bash
ip -br addr show ens192 ens224     # confirm both have IPs now
sudo puppet agent -t
grep -E '^node-(ip|external-ip):' /etc/rancher/rke2/config.yaml.d/00-puppet.yaml
# Both lines should now be present
```

**Do not start `rke2-server` until `node-ip` is populated** — without
it, RKE2's auto-detection picks an interface IP non-deterministically
(often the management network instead of the VXLAN underlay), which
breaks Cilium's tunnel addressing.

### `00-puppet.yaml` content check (critical for seed)

Puppet renders `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` from the
`ufrc_rke2::config` smart class param. **`server:` is set uniformly at the
hostgroup level** so all three nodes have identical Foreman config — this is
intentional. Joiners (kub-mgmt2/3) need `server:` to reach the cluster on
first boot; the seed (kub-mgmt1) does not.

RKE2 decides "init a new cluster" vs "join an existing one" by the
presence/absence of `server:`. On the seed, that single line has to be
absent at first boot, or RKE2 will try to join via the Kemp VIP, find no
healthy backends (cluster doesn't exist yet), and never bootstrap.

The pattern: **manually remove the `server:` line from 00-puppet.yaml on the
seed before first start.** Once the cluster is initialized, Puppet's next
run re-adds the line — harmless, because RKE2 sees existing local etcd data
and ignores `server:` on subsequent starts.

```bash
# On kub-mgmt1 (seed) only, BEFORE starting rke2-server:
sudo sed -i '/^server:/d' /etc/rancher/rke2/config.yaml.d/00-puppet.yaml

# Verify the line is gone
grep '^server:' /etc/rancher/rke2/config.yaml.d/00-puppet.yaml
# Should produce no output.

# On joiners (kub-mgmt2/3): leave it alone, the line stays
grep '^server:' /etc/rancher/rke2/config.yaml.d/00-puppet.yaml
# Should produce: server: https://vkub-mgmt.ufhpc:9345
```

Required end state at the time `rke2-server` first starts:

| Node | `server:` line in 00-puppet.yaml |
|---|---|
| kub-mgmt1 (seed) | absent (you delete it manually) |
| kub-mgmt2, kub-mgmt3 (joiners) | `https://vkub-mgmt.ufhpc:9345` |

Foreman scope (uniform across all nodes):

| Foreman scope | `server:` value in `ufrc_rke2::config` |
|---|---|
| Hostgroup `mgmt_cluster` | `https://vkub-mgmt.ufhpc:9345` |
| Per-host overrides | none needed |

**Why this approach over per-host overrides:** all three nodes share one
config in Foreman → simpler to maintain, no per-host special cases. The cost
is one manual `sed` on the seed at bootstrap time. After the cluster is up,
Puppet's reconciliation puts the line back on the seed, and the three nodes
end up with literally identical config.

### Other pre-flights

```bash
# RKE2 not installed yet
systemctl is-active rke2-server 2>/dev/null && echo "STOP — already running" || echo "clean"
which rke2 2>/dev/null && echo "STOP — binary present" || echo "clean"
ls /var/lib/rancher 2>/dev/null && echo "STOP — state dir exists" || echo "clean"

# Firewalld disabled (handled by base profile, not the rke2 module)
systemctl is-active firewalld    # inactive

# DNS for the VIP resolves
dig +short vkub-mgmt.ufhpc       # 172.16.192.6

# Kemp VIP exists with both VSes (TCP/6443 and TCP/9345)
# All planned server FQDNs as Real Servers
# Real Servers will be unhealthy until rke2-server starts on the seed — expected
```

## Phase 1 — Drop the Cilium HelmChartConfig manifest (seed only)

The Cilium config (VXLAN, /20 cluster pool, MTU 8950, kube-proxy replacement,
Gateway API enabled, L2 announcements enabled) lives in
`kub-mgmt/cilium-helmchartconfig.yaml`. RKE2's manifest deploy controller
picks it up at first start.

**Only on the seed (kub-mgmt1)**:

```bash
# Manifests directory may not exist yet
sudo mkdir -p /var/lib/rancher/rke2/server/manifests

# Copy from your local copy of the repo / from the bastion
sudo install -m 0644 -o root -g root \
  /path/to/src/kub-mgmt/cilium-helmchartconfig.yaml \
  /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml

# Verify
sudo head -5 /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
# apiVersion: helm.cattle.io/v1
# kind: HelmChartConfig
# metadata:
#   name: rke2-cilium
#   namespace: kube-system
```

helm-controller is cluster-wide; one CR applies to all nodes. The seed is
the only place that needs the file on disk. It will be deleted in Phase 8.

## Phase 2 — Install the RKE2 binary

```bash
curl -sfL https://get.rke2.io | \
  sudo INSTALL_RKE2_METHOD=tar \
       INSTALL_RKE2_VERSION=v1.35.4+rke2r1 \
       INSTALL_RKE2_TYPE=server \
  sh -
```

`INSTALL_RKE2_METHOD=tar` is mandatory — see design-rke2.md RDR-8 (avoids RPM
divergence with Rancher's system-upgrade-controller). Binary lands at
`/usr/local/bin/rke2`. Service unit installed but not started.

## Phase 3 — Start rke2-server and watch it bootstrap

```bash
sudo systemctl enable rke2-server.service --now

# In another terminal, follow the logs:
sudo journalctl -u rke2-server -f
```

What you'll see (3–8 minutes for the seed):

1. Pulling images for kube-apiserver, etcd, controller-manager, scheduler
2. etcd starts as a single-member cluster, becomes leader
3. Apiserver becomes Ready
4. Manifest deploy controller picks up `rke2-cilium-config.yaml`
5. helm-install-rke2-cilium job runs, installs Cilium with the override values
6. Cilium DaemonSet starts on the node
7. kubelet reports Ready

Wait for: `Node 'kub-mgmt1.ufhpc' is now ready`.

If it fails fast, the journal will say why. Common patterns:
- Missing CIS sysctl → check Foreman/puppet ran with `has_kub_installed=true`
- Missing etcd user → check `has_etcd_local_user=true`
- `server:` in 00-puppet.yaml on seed → Foreman config issue, see Prerequisites

## Phase 4 — kubectl convenience

```bash
sudo cp /etc/rancher/rke2/rke2.yaml ~/rke2.yaml
sudo chown $USER ~/rke2.yaml
chmod 0600 ~/rke2.yaml

export KUBECONFIG=~/rke2.yaml
export PATH=/var/lib/rancher/rke2/bin:$PATH

# Sanity check
kubectl get nodes -o wide
# kub-mgmt1.ufhpc Ready control-plane,etcd,master ... 10.13.160.1 172.16.192.1
```

## Phase 5 — Install Gateway API CRDs (5 standard + 1 experimental)

Cilium 1.19's operator **hard-requires six Gateway API CRDs**: the five
standard channel ones (GatewayClass, Gateway, HTTPRoute, GRPCRoute,
ReferenceGrant) **plus** TLSRoute from the experimental channel. The
operator's gateway controller registers `TLSRouteList` in its Go scheme
regardless of whether it's used — without the CRD, the reconcile loop
spins on errors and GatewayClass creation never happens. Install all six.

```bash
GATEWAY_API_VERSION=v1.2.0
BASE=https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd

# Standard channel (5 CRDs)
for crd in gatewayclasses gateways httproutes grpcroutes referencegrants; do
  kubectl apply -f ${BASE}/standard/gateway.networking.k8s.io_${crd}.yaml
done

# Experimental channel — TLSRoute (required for Cilium 1.19 operator scheme,
# even on clusters that don't functionally use TLSRoute routing)
kubectl apply -f ${BASE}/experimental/gateway.networking.k8s.io_tlsroutes.yaml

# Verify all 6 CRDs are registered
kubectl get crd | grep gateway.networking.k8s.io
# Expected:
#   gatewayclasses.gateway.networking.k8s.io
#   gateways.gateway.networking.k8s.io
#   grpcroutes.gateway.networking.k8s.io
#   httproutes.gateway.networking.k8s.io
#   referencegrants.gateway.networking.k8s.io
#   tlsroutes.gateway.networking.k8s.io
```

### Phase 5a — Restart the cilium-operator (mandatory)

Two problems happen at first boot:

1. The Cilium chart's `gatewayClass.create` default doesn't always create
   the `cilium` GatewayClass on its own — without explicit
   `gatewayClass.create: "true"` in the helm values, the operator's
   gatewayclass controller only WATCHES for the resource rather than
   creating it. Our `kub-mgmt/cilium-helmchartconfig.yaml` sets this to
   `"true"` so the operator creates it on startup.
2. The operator registers Gateway API types in its Go scheme at startup
   time. The pod started before Phase 5 ran (so before any CRDs existed),
   so its scheme is missing all 6 Gateway API types.

Both fixed by bouncing the operator pod so it re-runs scheme registration
with all 6 CRDs now present:

```bash
# Force operator pod recreation; new pod starts with all CRDs visible
kubectl -n kube-system delete pod -l name=cilium-operator
# Both pods deleted; one schedules on kub-mgmt1, the other pends (anti-affinity)
# Anti-affinity will resolve once kub-mgmt2 joins

sleep 60

# Verify GatewayClass is now accepted
kubectl get gatewayclass
# NAME     CONTROLLER                     ACCEPTED   AGE
# cilium   io.cilium/gateway-controller   True       60s

# Operator logs should now show gateway controller startup
kubectl -n kube-system logs -l name=cilium-operator --tail=100 | \
  grep -iE 'gateway-api|gatewayclass'
# Expected lines about "Checking for required GatewayAPI resources" and
# the controller starting reconciliation
```

### Troubleshooting GatewayClass stuck at "Waiting for controller"

If `kubectl get gatewayclass` still shows `Accepted: Unknown` after Phase 5a:

```bash
# Confirm operator config has gateway-api enabled
kubectl -n kube-system logs -l name=cilium-operator | \
  grep -E '\-\-enable-gateway-api='
# Expected: --enable-gateway-api='true'

# Confirm operator sees all 5 required CRDs
kubectl -n kube-system logs -l name=cilium-operator | \
  grep -i 'requiredGVK'
# The log line lists what it requires; cross-check against `kubectl get crd`
```

If the operator says `--enable-gateway-api='false'` despite the configmap
saying true, the chart's first install rendered the operator wrong — fall
through to the nuclear option: delete the helm release Secret and helm-install
Job, let helm-controller do a from-scratch reinstall with current cluster
state:

```bash
kubectl -n kube-system delete secret -l owner=helm,name=rke2-cilium
kubectl -n kube-system delete job helm-install-rke2-cilium
# Wait for helm-controller to recreate the Job and complete
kubectl -n kube-system get jobs -w | grep helm-install-rke2-cilium
```

## Phase 6 — Verify cluster health

```bash
# Node Ready, IPs as expected
kubectl get nodes -o wide

# All system pods Running (or Completed for helm-install jobs)
kubectl -n kube-system get pods

# Expected pending pods (NORMAL on a 1-node cluster):
#   - One cilium-operator replica (anti-affinity, schedules when 2nd node joins)

# kube-proxy is NOT present (Cilium replaces it)
kubectl -n kube-system get pods | grep -i kube-proxy
# (no output)

# rke2-ingress-nginx is NOT present (we disabled it)
kubectl -n kube-system get pods | grep -i ingress-nginx
# (no output)

# Cilium configmap reflects our overrides
kubectl -n kube-system get configmap cilium-config -o yaml | \
  grep -E 'tunnel|mtu|cluster-pool|gateway-api'
# Expected lines:
#   cluster-pool-ipv4-cidr: 192.168.0.0/20
#   cluster-pool-ipv4-mask-size: "25"
#   enable-gateway-api: "true"
#   mtu: "8950"
#   routing-mode: tunnel
#   tunnel-protocol: vxlan
```

## Phase 7 — Remove the on-disk Cilium manifest (seed only)

Once the cluster is stable and Cilium is reconciled, delete the on-disk file.
The HelmChartConfig CR persists in etcd; this prevents RKE2's manifest deploy
controller from overwriting subsequent changes.

```bash
sudo rm /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
```

Day-2 changes from now on go through the repo, not `kubectl edit`:

```bash
# Edit src/kub-mgmt/cilium-helmchartconfig.yaml in your local checkout, then:
kubectl diff  -f src/kub-mgmt/cilium-helmchartconfig.yaml   # preview
kubectl apply -f src/kub-mgmt/cilium-helmchartconfig.yaml   # push
# helm-controller reconciles, Cilium DaemonSet rolls
git add src/kub-mgmt/cilium-helmchartconfig.yaml && git commit
```

Avoid `kubectl edit` — it bypasses the file and silently desyncs the repo
from cluster state. If you do edit live (e.g., during incident response),
reflect the change back to `cilium-helmchartconfig.yaml` and commit
immediately, before you forget.

## Phase 8 — Smoke test (PSA-compliant)

The mgmt cluster runs `profile: cis`, which enforces PodSecurity Admission
at the **restricted** level. Non-compliant pods (running as root, with
capabilities, etc.) are rejected. Standard `kubectl run nettest --image=...`
will fail with:

```
violates PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false
  unrestricted capabilities
  runAsNonRoot != true
  seccompProfile
```

Use this compliant manifest instead:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nettest
  namespace: default
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: nettest
      image: nicolaka/netshoot
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 65532
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
EOF

kubectl wait --for=condition=Ready pod/nettest --timeout=60s

# DNS works
kubectl exec -it nettest -- nslookup kubernetes.default.svc.cluster.local

# TCP to apiserver works (use nc, not ping — ping needs CAP_NET_RAW which we dropped)
kubectl exec -it nettest -- nc -zv kubernetes.default.svc.cluster.local 443

# Service-IP resolution works through Cilium's eBPF datapath
kubectl exec -it nettest -- curl -sk https://kubernetes.default.svc.cluster.local/healthz
# expect: ok

# Cleanup
kubectl delete pod nettest
```

If all three pass, networking is functional end-to-end on the seed. You can
move on to joining kub-mgmt2.

> **Note on `ping` in restricted PSA:** ICMP raw sockets need `CAP_NET_RAW`,
> which `restricted` policy drops. `ping` will report "Operation not
> permitted." Use `nc -zv` (TCP) or `curl` (HTTP/HTTPS) for connectivity
> testing in PSA-restricted contexts. This is the new normal, not a bug.

## Joining kub-mgmt2 and kub-mgmt3

Same procedure as the seed with three differences:

1. **Foreman per-host override** must include
   `server: https://vkub-mgmt.ufhpc:9345` in `ufrc_rke2::config`. Verify in
   `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` after puppet runs.
2. **Skip Phase 1** — the HelmChartConfig CR is already in etcd and
   applies cluster-wide. Don't drop the manifest on joiners.
3. **Skip Phase 5** — Gateway API CRDs are cluster-wide, already installed.

Phase 2 (binary install), Phase 3 (start service), Phase 6 (verify) apply.

**Add servers serially**: bring kub-mgmt2 to Ready before starting kub-mgmt3.
Etcd quorum is fragile during member additions — parallel joins increase the
window where a transient failure breaks the cluster.

After all 3 nodes are Ready:

```bash
kubectl get nodes -o wide
# kub-mgmt1.ufhpc Ready control-plane,etcd,master ... 10.13.160.1 172.16.192.1
# kub-mgmt2.ufhpc Ready control-plane,etcd,master ... 10.13.160.2 172.16.192.2
# kub-mgmt3.ufhpc Ready control-plane,etcd,master ... 10.13.160.3 172.16.192.3

# 3-member etcd, tolerates 1 failure
kubectl -n kube-system get pods | grep etcd
```

## Rebuilding from scratch (DR or "I broke it")

If you need to wipe a node and start over (the path we just walked):

```bash
# 1. Stop and run the killall script (kills containerd, kubelet, etc.)
sudo systemctl stop rke2-server.service 2>/dev/null
sudo /usr/local/bin/rke2-killall.sh 2>/dev/null

# 2. Full uninstall (binary, /var/lib/rancher/rke2/, systemd units, iptables)
sudo /usr/local/bin/rke2-uninstall.sh

# 3. Remove any bootstrap-only drop-ins
sudo rm -f /etc/rancher/rke2/config.yaml.d/10-bootstrap.yaml
sudo rm -f /etc/rancher/rke2/config.yaml.d/50-rancher.yaml

# KEEP /etc/rancher/rke2/config.yaml.d/00-puppet.yaml — puppet re-renders anyway
```

If the install never got far enough for the uninstall scripts to land,
the manual fallback is in `bootstrap-cluster/manual-bootstrap-runbook.md`
under "Need to back out a registration."

After cleanup, re-run from Phase 0.

## Next phases (separate runbooks)

Once all 3 mgmt servers are Ready:

1. **etcd snapshots → S3 (FlashBlade)** — configure before installing Rancher
2. **cert-manager** — Helm install, prerequisite for Rancher's TLS and for
   Gateway API listener certs
3. **Rancher** — Helm install into mgmt cluster; auto-discovers as "local"
4. **MetalLB or Cilium L2 announcements** — provides external IPs to
   LoadBalancer-typed Services (Cilium Gateway needs one)
5. **First Gateway + HTTPRoute** — for Rancher UI access

These will be captured as separate runbooks once their patterns are nailed
down.

## What this runbook does NOT cover

- Workload cluster bootstrap — see `bootstrap-cluster/manual-bootstrap-runbook.md`
- Rancher install
- cert-manager / DNS-01 / internal CA
- Gateway / HTTPRoute / TLSRoute config (the CRDs are installed; usage is per-app)
- Day-2 cluster operations (etcd snapshots, upgrades, node replacement)
