# Kemp VIP design — kube-apiserver + RKE2 supervisor

Per-cluster L4 TCP passthrough VIPs on the Kemp Connection Manager HA pair, one
per cluster, fronting both `kube-apiserver` (TCP 6443) and `rke2-server` /
supervisor (TCP 9345). This document is the build checklist.

**Scope of this doc:** the cluster API + registration VIPs only — the L4 TCP
passthrough VIPs that front kube-apiserver (6443) and the RKE2 supervisor
(9345) for each cluster.

Application ingress (HTTPS to apps inside the cluster) is **not** handled by
Kemp in this design. That's now Cilium Gateway API in-cluster — see
`kemp-cilium-routing.md` for the ingress architecture. Kemp may still appear
in the path for *external* traffic that needs to reach a cluster service,
either as L4 passthrough (preferred default) or as a per-service L7 VIP
when WAF / content rules are required (deferred per-service decision).

## Per-cluster shape

Each cluster gets **one VIP** carrying **two Virtual Services** (one per port) on
the same backend pool of control-plane (server) nodes.

```
DNS A:  <cluster>.<base>  →  <kemp-vip>

VIP <kemp-vip>:
  VS1  TCP 6443  → control-plane servers   (kube-apiserver)
  VS2  TCP 9345  → control-plane servers   (rke2-server supervisor)
```

Workers (agents) are NOT in the backend pool — only servers run apiserver and
supervisor. Adding a worker as a backend would produce health-check failures.

## VIP allocation table

Fill in IPs/FQDNs per your existing IPAM:

| Cluster | DNS name | VIP | Server node FQDNs |
|---|---|---|---|
| mgmt | `mgmt.<base>` | TBD | mgmt-server-001…005 |
| infra | `infra.<base>` | TBD | infra-server-001…003 |
| gpu | `gpu.<base>` | TBD | gpu-server-001…003 |
| gpu-2 (future) | `gpu-2.<base>` | TBD | gpu-2-server-001…003 |

The DNS name appears in the cluster config's `tls-san` list (per the
`ufrc_rke2::config` smart class param) so that kubectl + cluster components can
verify the cert against the FQDN — not just the VIP IP.

## Why L4 TCP passthrough and not L7

- **kube-apiserver speaks TLS end-to-end.** Termination at Kemp would require
  Kemp to hold the cluster CA's signing chain and re-encrypt; doable but pointless
  given the apiserver does the auth/authz Kemp can't replicate.
- **RKE2 supervisor (9345) is also TLS end-to-end** with its own cert chain.
- **TCP passthrough preserves client cert auth.** kubectl with client certs,
  webhooks, admission controllers — all rely on mTLS that L7 termination would
  break.
- **Simpler failover.** Stateless TCP forwarding; no session affinity to track.

## VS configuration (both VS1 and VS2)

| Setting | Value | Why |
|---|---|---|
| Service type | Generic / Layer 4 | TCP passthrough |
| Protocol | TCP | not UDP, not HTTP |
| Persistence | None | apiserver is stateless; kubectl reconnects automatically on failover |
| Idle connection timeout | 3600s (1 hour) | Kemp default 5 min would kill `kubectl exec`, `kubectl logs -f`, port-forward, websocket watches |
| Scheduling method | least-connection or round-robin | round-robin is fine; least-connection slightly more even under bursty load |
| Real Server check | TCP connect on the VS port | HTTPS check would need Kemp to trust cluster CA which only exists post-cluster — chicken-and-egg |
| Check interval | 9s (Kemp default) | tune later if cluster events show slow failover |
| Retry count | 2 | tolerates a missed probe without flapping |

## DNS

Single A record per cluster pointing to the VIP. AAAA optional (depends on your
IPv6 posture). No CNAME — RKE2's `tls-san` validation chains through the SAN list
and CNAMEs add a layer that doesn't help.

```
mgmt.<base>.    IN A    <kemp-vip-mgmt>
infra.<base>.   IN A    <kemp-vip-infra>
gpu.<base>.     IN A    <kemp-vip-gpu>
```

Application hostnames (Rancher, Harbor, Keycloak, etc.) point directly at the
Cilium Gateway's external IP for in-cluster traffic, or at a Kemp L4 VIP
when external-facing traffic must be relayed. Neither uses this VIP — that
DNS/VIP work lives elsewhere (per-service or in `kemp-cilium-routing.md`).

## Real Server membership over the cluster lifecycle

Pre-list ALL planned server FQDNs as Real Servers when you create the VIP, even
before they're provisioned. Kemp marks unprovisioned hosts unhealthy; traffic
naturally flows to whichever subset is currently up.

Order of operations during initial cluster build:

1. **Kemp:** create VIP, both VSes, list all planned server FQDNs as Real Servers
   (all initially unhealthy, that's expected).
2. **DNS:** create the A record. Verify it resolves before the first host boots.
3. **Foreman + Puppet:** provision and configure the seed server.
4. **Bootstrap:** `bootstrap-cluster.sh <cluster> seed` → cluster initializes.
   Seed becomes healthy in Kemp's view automatically.
5. **Foreman + Puppet:** provision the remaining servers.
6. **Bootstrap:** `bootstrap-cluster.sh <cluster> server` → join via the VIP.
7. **Foreman + Puppet:** provision agents.
8. **Bootstrap:** `bootstrap-cluster.sh <cluster> agent` → workers join via VIP.

The chicken-and-egg only exists at step 4: the seed has the VIP DNS in its config
but doesn't *use* it (it's a cluster-of-one until step 6). After step 6, all
joins go through the VIP.

## Kemp HA notes

The Kemp HA pair shares the VIP via VRRP/equivalent. Both units must be on the
same VLAN as the VIP. (The earlier requirement that Kemp be L2-adjacent to the
cluster's node VLAN was driven by the now-retired Cilium native-routing + Kemp
CM ingress design — with VXLAN encap and Cilium GW in-cluster, Kemp doesn't
route to pod IPs and cross-VLAN is fine as long as TCP/6443 and TCP/9345 reach
the server nodes.)

No active/active config needed for these L4 VSes — active/passive is fine
since the latency and throughput requirements are well within a single
unit's capacity.

## Idempotent re-runs and DR rebuilds

Re-running `bootstrap-cluster.sh` against an already-up cluster is safe (Rancher's
installer no-ops). Kemp's Real Server list stays correct as long as the FQDNs
don't change.

For DR rebuild of a cluster onto fresh hosts (same names, fresh OS):
- Kemp config doesn't need to change (Real Server list is by FQDN, IPs stay the
  same via Foreman's IPAM).
- DNS doesn't change.
- Just re-run Foreman provisioning + Puppet + bootstrap-cluster.sh.

For DR rebuild onto NEW hostnames: update Kemp's Real Server list to the new
FQDNs before running bootstrap-cluster.sh.

## Build checklist

For each cluster, in order:

- [ ] IPAM: allocate VIP IP from the cluster's node VLAN (or adjacent).
- [ ] DNS: create A record `<cluster>.<base>` → VIP, verify resolution.
- [ ] Kemp UI: Virtual Services → Add New
  - [ ] VS1: VIP / 6443 TCP, persistence=None, idle=3600s, RS check=TCP/6443
  - [ ] VS2: VIP / 9345 TCP, persistence=None, idle=3600s, RS check=TCP/9345
  - [ ] Both VSes share the same backend pool (or duplicate the Real Server list).
- [ ] Add planned server FQDNs as Real Servers on both VSes.
- [ ] Verify the VIP responds (TCP connect to 6443 will fail until first server
      is up — that's expected; the VIP itself answering is what matters).
- [ ] Confirm the cluster's `ufrc_rke2::config` smart class parameter has
      `tls-san` containing both `<cluster>.<base>` and the VIP IP literal.

## What this VIP does NOT do

- Application ingress / L7 — Cilium Gateway API handles in-cluster ingress;
  external relay is a separate per-service VIP if needed.
- Workers / agents — backend is control-plane only.
- etcd peer traffic (2379/2380) — intra-cluster, on the VM network, Cilium
  handles it.
- kubelet API (10250) — Prometheus / metrics-server hit nodes directly via
  in-cluster service IPs, no external VIP needed.
