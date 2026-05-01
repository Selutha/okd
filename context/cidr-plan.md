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

## Address space choice — 192.168.0.0/16

We use **192.168.0.0/16** for all Kubernetes pod and service CIDRs across
the fleet.

Why not other ranges:

- **10.0.0.0/8** — already in use as the org network. Hard no.
- **172.16.0.0/12** — partially in use (mgmt network is 172.16.192.0/24).
  Risk of future collisions as more 172.16 space gets allocated.
- **100.64.0.0/10** (RFC6598) — viable alternative. Held in reserve in case
  we exhaust 192.168.0.0/16 or need to extend k8s networking off the HPC
  fabric (federation, hybrid cloud) where 192.168 ranges might collide
  with on-prem customer networks. See [`cidr-100.64-notes.md`](cidr-100.64-notes.md)
  for the full pros/cons writeup, including the Tailscale collision gotcha.

192.168.0.0/16 sliced into /20s gives 16 slots, two slots per cluster (one
for pods, one for services) = 8 clusters before we tap 100.64.0.0/10.

## Allocation rules

1. Each cluster gets two adjacent /20 blocks: pods first, then services.
   This means each cluster effectively owns a /19's worth of address space
   (`192.168.<n>.0/19` where `n` is a multiple of 32).
2. Allocations are recorded in the table below. Never reuse a slot, even
   after a cluster is decommissioned — the slot stays burned for
   one rebuild cycle to avoid stale ARP/route confusion during transitions.
3. Per-node mask is `/25` (128 pods/node) by default. Cluster-cidr `/20`
   with `/25` per-node yields a 32-node ceiling per cluster — well above
   our expected max of ~16 nodes per cluster.
4. New cluster? Add a row to the table below before deploying.

## Allocations

| Cluster | Purpose | Pod CIDR | Service CIDR | Per-node mask | Node ceiling | Status |
|---|---|---|---|---|---|---|
| mgmt | Management plane (Rancher, monitoring, registry, etc.) | 192.168.0.0/20 | 192.168.16.0/20 | /25 | 32 | active |
| _reserved_ | (next cluster) | 192.168.32.0/20 | 192.168.48.0/20 | — | — | unused |
| _reserved_ | | 192.168.64.0/20 | 192.168.80.0/20 | — | — | unused |
| _reserved_ | | 192.168.96.0/20 | 192.168.112.0/20 | — | — | unused |
| _reserved_ | | 192.168.128.0/20 | 192.168.144.0/20 | — | — | unused |
| _reserved_ | | 192.168.160.0/20 | 192.168.176.0/20 | — | — | unused |
| _reserved_ | | 192.168.192.0/20 | 192.168.208.0/20 | — | — | unused |
| _reserved_ | | 192.168.224.0/20 | 192.168.240.0/20 | — | — | unused |

## mgmt cluster — sizing rationale

The mgmt cluster is hard-capped at 5 nodes for the foreseeable future. /20
pod CIDR with /25 per-node allocations is more than sufficient (32-node
ceiling, 128 pods/node). We keep the /20 size — rather than shrinking — so
that the allocation scheme is uniform across all clusters and the table
above stays clean.

Address efficiency on the mgmt cluster is irrelevant: we are not short on
192.168 space, and uniform sizing is more valuable than a few thousand
unused addresses.

## Worker / agent cluster sizing

Future workload clusters are also expected to stay under ~16 nodes each.
The /20 + /25 default fits them too. Only deviate from these defaults if a
specific cluster has a documented reason to need more (or fewer) addresses.

## Why not 10.x like most k8s tutorials show

Default RKE2 cluster-cidr is `10.42.0.0/16`, default service-cidr is
`10.43.0.0/16`. Both collide with our org 10.0.0.0/8 network. Any cluster
left at defaults will have pod-to-pod traffic that is indistinguishable
from org traffic in flow logs, and any pod attempting to reach an org
service in the 10.42 or 10.43 range will be silently routed to a pod IP
inside the cluster. We override to 192.168 space on every cluster,
without exception.
