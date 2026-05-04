# Kubernetes CIDR Allocation Plan

Fleet-wide plan for pod and service CIDR assignments across all RKE2 clusters
in the HPC environment.

## Why this exists

We will run multiple Kubernetes clusters. Each cluster needs its own
non-overlapping pod and service CIDRs so that:

- `kubectl logs` and packet captures show unambiguous source IPs across
  clusters
- A future Cilium ClusterMesh / multi-cluster setup remains possible without
  rebuilding any cluster
- Troubleshooting tools (`tcpdump`, flow logs) tell us which cluster a packet
  came from at a glance

CIDRs reused across clusters technically work as long as encapsulation hides
them from the underlay, but the operational confusion isn't worth the
addresses saved.

## Address space history

This plan originally allocated K8s CIDRs out of **192.168.0.0/16**. That
turned out to be unsafe: the actual environment has many existing subnets
inside 192.168/16 (FA storage, vMotion, Qumulo backend, switch management,
ResVault, multiple compute fabrics). See
[`192.168-allocation-actual.md`](192.168-allocation-actual.md) for the full
inventory. Specifically, the mgmt cluster's planned service CIDR
(192.168.16.0/20) overlapped the FA `hpg-roce` subnet (192.168.20.0/24) — a
dormant collision that would have broken K8s service routing the moment K8s
nodes gained a path to the storage network.

We pivoted to **100.64.0.0/10** on 2026-05-04 before the mgmt cluster started
serving real workloads. The mgmt cluster is being re-rolled to use the new
CIDRs.

## Address space choice — 100.64.0.0/10

We use **100.64.0.0/10** (RFC6598 "shared address space" / "CGNAT space")
for all Kubernetes pod and service CIDRs across the fleet.

Why not other ranges:

- **10.0.0.0/8** — fully allocated to the org. Hard no.
- **172.16.0.0/12** — used everywhere in the org. Hard no.
- **192.168.0.0/16** — heavily fragmented in our environment (storage,
  hypervisor mgmt, switch mgmt, ResVault, multiple compute fabrics). Only
  three clean /20s exist; not enough for the planned fleet. See
  [`192.168-allocation-actual.md`](192.168-allocation-actual.md).
- **IPv6 ULA** — viable in theory but adds operational complexity (dual-stack
  handling, IPv6 literacy across the team) for no current benefit.

100.64/10 gives us 4,194,304 addresses — vastly more headroom than 192.168/16's
65,536. Trade-offs (Tailscale collision, VPN client quirks, audit confusion)
are documented in [`cidr-100.64-notes.md`](cidr-100.64-notes.md).

## Allocation rules

1. **Each cluster owns a /16 slot** within 100.64.0.0/10. The slot ID
   corresponds directly to the second octet: `100.<64+N>.0.0/16` for cluster
   slot N.
2. **Within each cluster's /16**, pod CIDR and service CIDR are each /20:
   - Pod CIDR: `100.<64+N>.0.0/20`
   - Service CIDR: `100.<64+N>.16.0/20`
3. **Per-node mask** is `/25` (128 pods/node) by default. /20 cluster-cidr
   with /25 per-node yields a 32-node ceiling per cluster — well above our
   expected max of ~16 nodes per cluster.
4. **Spacing /20s on /16 boundaries** means each cluster has 14 unused /20s
   inside its own /16 slot — headroom for future expansion (additional pod
   ranges via secondary-CIDR patterns, larger service CIDR if the cluster
   grows beyond default scale) without renumbering neighbors.
5. **Allocations are recorded in the table below.** Never reuse a slot, even
   after a cluster is decommissioned — the slot stays burned for one rebuild
   cycle to avoid stale ARP/route confusion during transitions.
6. **New cluster?** Add a row to the table below before deploying.

## Allocations

| Cluster | Slot | Pod CIDR | Service CIDR | Per-node mask | Node ceiling | Status |
|---|---|---|---|---|---|---|
| mgmt | 100.64.0.0/16 | 100.64.0.0/20 | 100.64.16.0/20 | /25 | 32 | re-roll in progress (2026-05-04) |
| _reserved_ | 100.65.0.0/16 | 100.65.0.0/20 | 100.65.16.0/20 | — | — | unused |
| _reserved_ | 100.66.0.0/16 | 100.66.0.0/20 | 100.66.16.0/20 | — | — | unused |
| _reserved_ | 100.67.0.0/16 | 100.67.0.0/20 | 100.67.16.0/20 | — | — | unused |
| _reserved_ | 100.68.0.0/16 | 100.68.0.0/20 | 100.68.16.0/20 | — | — | unused |
| _reserved_ | 100.69.0.0/16 | 100.69.0.0/20 | 100.69.16.0/20 | — | — | unused |
| _reserved_ | 100.70.0.0/16 | 100.70.0.0/20 | 100.70.16.0/20 | — | — | unused |
| _reserved_ | 100.71.0.0/16 | 100.71.0.0/20 | 100.71.16.0/20 | — | — | unused |

Anything past 100.71/16 is undeclared but available — extend the table when
allocating.

## mgmt cluster — sizing rationale

The mgmt cluster is hard-capped at 5 nodes for the foreseeable future. /20
pod CIDR with /25 per-node allocations is more than sufficient (32-node
ceiling, 128 pods/node). We keep the /20 size — rather than shrinking — so
that the allocation scheme is uniform across all clusters and the table
above stays clean.

Address efficiency on the mgmt cluster is irrelevant: 100.64/10 has 4M
addresses, and uniform sizing is more valuable than a few thousand unused
addresses.

## Worker / agent cluster sizing

Future workload clusters are also expected to stay under ~16 nodes each.
The /20 + /25 default fits them too. Only deviate from these defaults if a
specific cluster has a documented reason to need more (or fewer) addresses,
and prefer expanding within the cluster's own /16 slot rather than
allocating a second slot.

## Tailscale considerations

100.64/10 collides with Tailscale's overlay address space. If anyone in the
org runs Tailscale on a machine that needs to reach K8s pod IPs directly, a
fraction of pod IPs (those matching the user's Tailscale-assigned address)
will be silently unreachable from that machine.

Current status: Tailscale is not known to be in use in our environment.

If Tailscale gets adopted later:
- Production workloads are unaffected — pod-to-pod traffic stays inside the
  cluster, never traversing a Tailscale-connected machine.
- Operator impact is bounded — sysadmins discovering "I can't kubectl
  port-forward to that one pod" can either disable Tailscale on their
  machine or work via a bastion that doesn't run Tailscale.
- Re-rolling clusters because of Tailscale adoption would be the wrong
  response; document the tradeoff and mitigate per-user.

See [`cidr-100.64-notes.md`](cidr-100.64-notes.md) for the deeper writeup
on 100.64/10 trade-offs (VPN clients, audit/SIEM categorization, etc.).

## Why not RKE2 defaults

Default RKE2 cluster-cidr is `10.42.0.0/16`, default service-cidr is
`10.43.0.0/16`. Both collide with our org 10.0.0.0/8 network. Any cluster
left at defaults will have pod-to-pod traffic that is indistinguishable
from org traffic in flow logs, and any pod attempting to reach an org
service in the 10.42 or 10.43 range will be silently routed to a pod IP
inside the cluster. We override on every cluster, without exception.

## Files that hold concrete CIDR values (must follow this plan)

When a cluster's CIDRs change, these files need to be kept in sync:

- `src/ufrc_rke2/README.md` — example block in usage docs
- `src/ufrc_rke2/examples/server.pp` — example server hiera/manifest
- `src/kub-mgmt/cilium-helmchartconfig.yaml` — Cilium native-routing CIDR
  list and any pool/IPAM CIDRs

Update them in the same change as the table above.
