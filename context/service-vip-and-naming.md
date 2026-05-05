# Service VIP, DNS Naming, and Network Policy Patterns

**Last updated:** 2026-05-02
**Audience:** anyone standing up a new Service on the mgmt cluster (or
future workload clusters) who needs to know where the IP comes from,
what to name it, who terminates TLS, and what NetworkPolicy to ship.

---

## TL;DR

- **HTTP/HTTPS services share one VIP** via SNI/hostname routing on a
  Cilium Gateway. One VIP, many services.
- **Non-HTTP TCP services (databases, etc.) get one VIP each.** No SNI for
  raw TCP; demultiplex by IP, not port.
- **All user-facing names use `*.rc.ufl.edu`**, internal and external. The
  wildcard cert covers everything browser-facing.
- **`*.ufhpc` is infrastructure-only** (kube-apiserver VIP, node hostnames,
  SSH/Foreman targets). Never used for browser-reachable services.
- **DNS is split-horizon**: internal BIND/InfoBlox resolves
  `rc.ufl.edu` to internal IPs. External InfoBlox only has records for
  externally-exposed services.
- **Kemp fronts external-facing services** (WAF, perimeter trust). Internal
  admin tools usually bypass Kemp and hit the K8s LB IP directly.
- **Every Service exposed beyond its namespace needs a NetworkPolicy.**
  RKE2's `profile: cis` adds a default-deny ingress policy to every
  namespace at bootstrap. See `network-policy-templates.yaml` for shapes.

---

## DNS architecture

Three layers of DNS resolution, with different audiences:

| Layer | Where | Resolves | Used by |
|---|---|---|---|
| Internal BIND | UF research-computing controlled, pushed over VPN and to in-cluster nodes | `*.ufhpc`, internal-zone `*.rc.ufl.edu` | VPN clients, cluster nodes |
| InfoBlox internal zone | UF campus DNS, ACL-gated to campus network or VPN | `*.rc.ufl.edu` (internal-only services point at internal IPs; externally-exposed services may also resolve here for split-horizon) | Campus users (lab machines, faculty desktops, etc.) |
| InfoBlox external zone | Public DNS for `rc.ufl.edu` | `*.rc.ufl.edu` (only externally-exposed services; internal-only names omitted) | Internet users |

**Key implication**: `rancher.rc.ufl.edu` can exist *only* in internal
DNS, pointing at an internal-network IP. Internet users get NXDOMAIN.
That's how internal-only admin services stay invisible from outside
without separate naming gymnastics.

---

## Naming conventions

| Domain | Used for | Cert |
|---|---|---|
| `*.rc.ufl.edu` | All browser-facing services (Rancher, Grafana, Prometheus, customer-facing apps, etc.) | Wildcard cert (`*.rc.ufl.edu`); Phase 1 manually loaded as Secret, Phase 2 ACME-renewed via cert-manager |
| `*.ufhpc` | Infrastructure-only: `vkub-mgmt.ufhpc` (kube-apiserver VIP), node hostnames, SSH targets, Foreman/Puppet ER targets | RKE2-managed internal CA (browsers never see these certs) |

`*.rc.ufl.edu` is **single-level wildcard** — `rancher.rc.ufl.edu` ✓,
`mgmt-rancher.rc.ufl.edu` ✓, `rancher.k8s.rc.ufl.edu` ✗ (not covered).
Plan flat hostnames directly under `rc.ufl.edu`.

---

## VIP allocation

The Cilium L2 announcement subsystem hands out IPs from
`CiliumLoadBalancerIPPool` resources to Services of type LoadBalancer.
Each pool has a `serviceSelector` that ties it to a label on the
Service.

### Pools on the mgmt cluster

| Pool | CIDR | Interface | Selector | Use case |
|---|---|---|---|---|
| `mgmt-pool` | `172.16.192.7-9` | `ens192` (mgmt network) | `lb-pool: mgmt` | Mgmt-plane services (Rancher, monitoring) — all admin tools live here |
| `vm-pool` | `10.13.160.7-9` | `ens224` (VM network, bonded fast NICs) | `lb-pool: vm` | High-throughput / customer-traffic services. Reserved for future use — no Services drawing yet on mgmt cluster. |

Add a Service to a pool with the `lb-pool: <name>` label; pin a specific
IP within the pool with the `lbipam.cilium.io/ips: "<ip>"` annotation.

### Pool sizing

LB IPs scale with the number of **distinct service entry points**, not
node count. Most of the time you need a small handful of IPs per cluster:

| Cluster type | Realistic LB IP need |
|---|---|
| Mgmt cluster | 1 for the Cilium Gateway (hosts Rancher + everything HTTP via SNI) + maybe 1-2 for non-HTTP services if any. **Pool of 2-5 IPs is plenty.** |
| Workload cluster running databases / non-HTTP services | 1 per Cilium Gateway + 1 per externally-exposed TCP service. Could grow to 10-30 IPs per cluster. **Pool of /27 (32 IPs) is a safe starting point.** |

Adding IPs is a one-line edit to the pool's `spec.blocks` list and a
`kubectl apply`. No restart, zero impact on already-assigned IPs. So
err on the small side — grow when needed, not pre-emptively.

### One VIP, many HTTP services (the SNI multiplexing pattern)

A single Cilium Gateway uses **one LB IP** and hosts unlimited HTTPS
services on it, differentiated by SNI/hostname:

```
DNS:
  rancher.rc.ufl.edu     A 172.16.192.7
  grafana.rc.ufl.edu     A 172.16.192.7
  prometheus.rc.ufl.edu  A 172.16.192.7
  argocd.rc.ufl.edu      A 172.16.192.7

K8s side (one Gateway, many HTTPRoutes):
  Gateway: listens on 172.16.192.7:443 with wildcard *.rc.ufl.edu cert
  HTTPRoute "rancher.rc.ufl.edu"     → rancher pods
  HTTPRoute "grafana.rc.ufl.edu"     → grafana pods
  HTTPRoute "prometheus.rc.ufl.edu"  → prometheus pods
  HTTPRoute "argocd.rc.ufl.edu"      → argocd pods
```

Client TLS ClientHello carries SNI = `rancher.rc.ufl.edu`. Cilium GW
matches the SNI to the HTTPRoute, sends to right backend. Same pattern
as Apache/nginx VirtualHost.

**Don't allocate a separate LB IP per HTTP service.** That's wasted IPs
and harder ops surface.

### One VIP per non-HTTP TCP service

Raw TCP doesn't have SNI, so demultiplex-by-port has bad ergonomics
(clients hard-code 3306 etc.). The standard pattern is one LB IP per
non-HTTP service:

```
mysql-prod.rc.ufl.edu  → 172.16.192.20:3306
mysql-stage.rc.ufl.edu → 172.16.192.21:3306
redis.rc.ufl.edu       → 172.16.192.22:6379
```

Each gets its own LoadBalancer Service, its own VIP, all on standard
ports. Operator-managed databases (CrunchyData, Percona, etc.) do this
automatically.

If conserving IPs really matters, alternative patterns exist (Kemp
front-ending with port translation, ProxySQL/MaxScale for MySQL-aware
routing, app-protocol proxies). But the default and cleanest answer is
one VIP per non-HTTP service.

---

## Kemp's role

| Audience | Path | When |
|---|---|---|
| **External customers** (internet) | DNS (InfoBlox external) → Kemp public VIP → L4 passthrough → K8s LB IP → Cilium GW → HTTPRoute → pod | Always, for any externally-exposed service. Kemp is the WAF/trust boundary. |
| **Internal users** (campus, VPN) | DNS (BIND / InfoBlox internal) → K8s LB IP → Cilium GW → HTTPRoute → pod | Default for internal-only services. Bypasses Kemp. ACLs on the network ensure only campus/VPN can reach the internal IP. |
| **Internal users behind Kemp** (optional) | DNS → Kemp internal VIP → L4 → K8s LB IP → Cilium GW → ... | When you want WAF / centralized auditing for internal services too. Not the default for admin tools. |

Same K8s LB IP serves both audiences — Kemp adds value at the perimeter,
isn't a hard requirement for K8s reachability.

For *non-HTTP* services exposed externally (e.g., a customer-facing
database), Kemp does L4 passthrough. The K8s side still needs its own
LB IP per service (Kemp's VIP terminates at Kemp's IP, then forwards to
K8s's IP).

---

## NetworkPolicy is mandatory for external-facing services

RKE2's `profile: cis` applies a default-deny ingress NetworkPolicy
(`default-network-policy`) to every namespace at cluster bootstrap (CIS
Benchmark 5.3.2). This policy allows ingress only from same-namespace
pods + the host. **Anything else is denied silently** — visible only in
`cilium-dbg monitor` (or Hubble, if enabled).

Forgetting this looks like:

- Service has its LB IP ✓
- ARP works from clients ✓
- TCP SYN reaches the leader node ✓
- Cilium DNATs and forwards to the pod ✓
- **Pod's eBPF program drops the packet** with `Policy denied`
- Client times out, no clue why

Pattern: **ship a NetworkPolicy in the same manifest as the
Deployment/Service.** See `src/kub-mgmt/network-policy-templates.yaml`
for copy-pasteable shapes.

What a service typically needs:

| Service | Allow ingress from |
|---|---|
| LoadBalancer fronting world (external) | `world` (any IP) |
| Cilium Gateway-fronted HTTP service | The Gateway's pods (label-based) — not `world` directly |
| Internal-only Service consumed by other namespaces | The specific source namespace(s) |
| Backend pod consumed only within its namespace | Nothing extra — default-network-policy already allows same-namespace |

---

## End-to-end flow examples

### Example 1: Rancher UI (internal admin tool)

```
Internal admin opens https://rancher.rc.ufl.edu in a browser
  ↓
DNS lookup hits internal BIND/InfoBlox internal zone
  → returns 172.16.192.7 (the Cilium Gateway's LB IP)
  ↓
TLS ClientHello with SNI = rancher.rc.ufl.edu, dest=172.16.192.7:443
  ↓
ARP for 172.16.192.7 on management subnet → leader node responds
  ↓
Cilium GW on 172.16.192.7 terminates TLS using *.rc.ufl.edu Secret
  ↓
HTTPRoute matches "rancher.rc.ufl.edu" → cattle-system/rancher Service
  ↓
Cilium DNATs to a Rancher pod IP, eBPF forwards (possibly via VXLAN
  if pod is on different node)
  ↓
Rancher pod's NetworkPolicy: must allow ingress from Cilium Gateway pods
  ↓
Rancher serves the UI
```

DNS records needed:
- `rancher.rc.ufl.edu` → `172.16.192.7` (internal DNS only; **not** in InfoBlox external zone — Rancher is admin-only)

Manifests needed:
- Cilium Gateway listener on `172.16.192.7:443` with wildcard cert Secret
- HTTPRoute matching `rancher.rc.ufl.edu` → `cattle-system/rancher` Service
- NetworkPolicy in `cattle-system` allowing ingress from Cilium Gateway pods

### Example 2: Customer-facing metrics dashboard

```
External customer opens https://metrics.rc.ufl.edu
  ↓
DNS lookup hits InfoBlox external zone
  → returns Kemp public VIP (e.g., 128.227.x.y)
  ↓
TLS terminated at Kemp using *.rc.ufl.edu wildcard cert (loaded on Kemp)
  ↓
Kemp WAF inspects request
  ↓
Kemp VS forwards plain HTTP to backend pool: K8s LB IP 172.16.192.7
  ↓
[same as Example 1 from the K8s LB IP onward, just plain HTTP not TLS,
 since Kemp already terminated]
```

DNS records needed:
- `metrics.rc.ufl.edu` external A → Kemp public VIP
- `metrics.rc.ufl.edu` internal A → `172.16.192.7` (split-horizon, so internal users don't bounce off Kemp)

Kemp config:
- VS on the public VIP, port 443, terminates TLS, WAF on
- Backend: K8s LB IP `172.16.192.7` on port 80 (plain HTTP)
- Health check: HTTP GET `/healthz` or similar

### Example 3: Internal MySQL (non-HTTP, no Kemp)

```
Internal app pod (or Slurm script) opens mysql://mysql-prod.rc.ufl.edu:3306
  ↓
DNS lookup → 172.16.192.20 (this MySQL's dedicated LB IP)
  ↓
Cilium L2 leader for .20 ARPs, traffic flows to it
  ↓
Cilium DNATs to MySQL pod IP, eBPF forwards
  ↓
MySQL pod's NetworkPolicy: allow ingress from clients (could be CIDR-based
  or namespace-based)
  ↓
MySQL serves the connection
```

DNS records needed:
- `mysql-prod.rc.ufl.edu` internal A → `172.16.192.20`

Manifests needed:
- LoadBalancer Service for the MySQL StatefulSet, label `lb-pool: mgmt`,
  annotation `lbipam.cilium.io/ips: "172.16.192.20"`
- NetworkPolicy allowing ingress on port 3306 from appropriate sources
  (e.g., specific CIDRs or specific namespaces)
- IP `172.16.192.20` added to mgmt-pool's `spec.blocks`

---

## Adding a new service — checklist

For every new Service exposed beyond its namespace:

- [ ] Pick a hostname in `*.rc.ufl.edu` (flat — directly under `rc.ufl.edu`)
- [ ] Decide LB IP source:
  - HTTP and the Cilium Gateway already exists → use the existing GW VIP
  - Non-HTTP, or wants its own Gateway → allocate a new LB IP
- [ ] If new LB IP needed:
  - [ ] Pick an unused IP in the appropriate subnet (see pool table above)
  - [ ] Reserve it in IPAM
  - [ ] Add `- cidr: <ip>/32` to the pool's `spec.blocks`, `kubectl apply`
- [ ] Add DNS:
  - Internal-only service → internal BIND / InfoBlox internal zone only
  - External service → InfoBlox external zone (pointing at Kemp public VIP) + InfoBlox internal zone (pointing at K8s LB IP, for split-horizon)
- [ ] Decide TLS termination:
  - Internal: Cilium GW with wildcard Secret
  - External: Kemp terminates with wildcard, plain HTTP to backend
- [ ] If external: configure Kemp VS pointing to the K8s LB IP
- [ ] Apply manifests:
  - Deployment / StatefulSet (PSA-restricted-compliant securityContext)
  - Service (with `lb-pool` label and `lbipam.cilium.io/ips` annotation if pinned)
  - HTTPRoute (if HTTP, attached to the Cilium Gateway)
  - **NetworkPolicy** (mandatory — see `network-policy-templates.yaml`)
- [ ] Validate end-to-end: DNS resolves, TLS valid, response correct
- [ ] If anything fails, check Hubble/`cilium-dbg monitor` for policy drops

---

## See also

- `network-policy-templates.yaml` — copy-pasteable NetworkPolicy shapes
- `kemp-vip-design.md` — Kemp VIP architecture for the fleet
- `kemp-cilium-routing.md` — ingress architecture (Cilium GW + Kemp relay)
- `cidr-plan.md` — fleet-wide CIDR allocation
- `current-state.md` — Critical context section: PSA + default-deny gotchas
- `bootstrap.md` Phase 8 — reference PSA-compliant pod manifest
- Cilium's [L2 Announcements docs](https://docs.cilium.io/en/v1.19/network/l2-announcements/)
- Cilium's [Hubble overview](https://docs.cilium.io/en/v1.19/observability/hubble/) — get this enabled, will save hours of debugging
