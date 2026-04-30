# Cilium native-routing static routes on Kemp

Per-cluster static routes that let the Kemp Connection Manager Ingress Controller
(RDR-7) reach pod IPs directly as next-hop-routable destinations. This is the
hard requirement that gates the entire L7 ingress architecture.

**This doc is separate from `kemp-vip-design.md`** because the routing applies to
the CM's data path for the L7 ingress add-on, not the L4 apiserver/supervisor
VIPs. Those VIPs work regardless of pod-CIDR routing.

## Why Cilium has to be in native-routing mode

The Kemp Ingress Controller add-on populates each Virtual Service's Real Server
list with **pod IPs** (taken from the `Service.endpoints` resource on the K8s API).
For the CM to forward traffic to those pod IPs, they have to be reachable via
standard IP routing — i.e., the CM's kernel needs a route entry that says "send
packets for `<pod-CIDR>` via `<some-node-IP>`."

Cilium has two main data plane modes:

| Mode | How pods reach each other | CM-to-pod reachability |
|---|---|---|
| **Native routing** | Direct via host routing tables; pod CIDR is L3-routable across the cluster | **Yes** — CM can also route to pod IPs given static routes per node |
| **Encapsulation** (VXLAN/Geneve) | Pods communicate via tunnels between Cilium agents | **No** — pod IPs only exist inside the tunnel mesh |

For this project we set `cni: cilium` with `tunnelProtocol: disabled` (or the
equivalent native-routing flag in the Cilium values file), making pod IPs
visible at L3 from anywhere on the cluster's node VLAN that has a route to them.

## What "static routes per node" actually means

Cilium-in-native-routing assigns each node a slice of the cluster's pod CIDR
(typically a `/24` carved from the cluster's `/16`). For a 3-server cluster:

```
Cluster pod CIDR:   10.42.0.0/16
  Node 1 (10.50.20.31):  pod range 10.42.0.0/24
  Node 2 (10.50.20.32):  pod range 10.42.1.0/24
  Node 3 (10.50.20.33):  pod range 10.42.2.0/24
```

Pods on Node 1 have IPs in `10.42.0.0/24`, etc. To reach `10.42.1.5` from outside
the cluster, you need a route that says "10.42.1.0/24 via 10.50.20.32."

For the Kemp CM to reach any pod, it needs **one route per node** added under
*System Configuration → Network Setup → Additional Routes*:

```
Destination          Gateway          Interface
10.42.0.0/24        10.50.20.31      eth0 (or whichever VLAN interface)
10.42.1.0/24        10.50.20.32      eth0
10.42.2.0/24        10.50.20.33      eth0
```

Per cluster. Multiplied by the number of cluster nodes.

## Where to find each node's assigned slice

Once the cluster is up, query the K8s API:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
```

Output:
```
mgmt-server-001    10.42.0.0/24
mgmt-server-002    10.42.1.0/24
mgmt-server-003    10.42.2.0/24
mgmt-server-004    10.42.3.0/24
mgmt-server-005    10.42.4.0/24
```

Each line maps to one CM Additional Route. As the cluster scales (add agent
nodes), new entries appear; the CM's route list must be updated to match.

## Kemp HA — both units need the routes

The Kemp HA pair acts as one logical unit, but Additional Routes are configured
per-CM. Add the same route table on both units. Otherwise a failover lands you
on a unit that can't reach pods.

## L2 adjacency requirement

Static routes only work if the gateway IP (node IP) is directly reachable from
the CM's interface. That means the CM must be **L2-adjacent to the cluster's
node VLAN** — either an interface on that VLAN, or a VLAN-tagged subinterface on
a trunk. Routes through an intermediate L3 hop (a separate router) won't work
the way you want; the CM would forward to the router, the router would forward
to the node, and ARP resolution for the pod IP is on the node, not the router.

This is captured in design-rke2.md §5.1 + RDR-7 hard requirements. If the
network design forces the CM into a separate L3 segment, fall back to in-cluster
ingress-nginx + Kemp L4 passthrough on `*.apps:443` (the RDR-7 fallback).

## Cilium config that has to match

In the cluster's `ufrc_rke2::config` smart class param (or equivalent), the
Cilium Helm values need:

```yaml
# Cilium Helm chart values (set via HelmChartConfig override or RKE2 manifest dir)
tunnelProtocol: disabled         # native routing, no VXLAN encapsulation
ipam:
  mode: cluster-pool             # gives each node a /24 slice
ipv4NativeRoutingCIDR: 10.42.0.0/16   # match cluster-cidr per cluster
autoDirectNodeRoutes: true       # nodes install routes for each other's slices
```

Different cluster CIDRs per cluster (per design §3.4): infra=10.42.0.0/16,
gpu=10.44.0.0/16, gpu-2=10.46.0.0/16. The CM's route list per cluster matches.

## Verification — how to know it's working

After cluster bootstrap and route configuration, from the CM's serial console
or SSH:

```bash
# Should succeed:
ping -c 3 <node-ip>            # L2 adjacency confirmed
ping -c 3 <pod-ip>             # native routing + static route both work

# Get a known pod IP first:
# (from a host that has kubectl):
kubectl get pods -A -o wide | grep -v "Running\|Pending"   # should be empty
kubectl run -n default test --image=busybox --rm -it --restart=Never -- sleep 60 &
kubectl get pod test -o jsonpath='{.status.podIP}'
```

Pinging the pod from the CM is the canonical "did it work" check. If that fails
but pinging the node IP succeeds, the node-side routing is broken (Cilium not in
native mode) or the pod CIDR is wrong. If pinging the node fails too, L2
adjacency or CM interface config is the problem.

## Per-cluster routing tables — fill in during build

### mgmt cluster

Pod CIDR: 10.42.0.0/16 — 5 server nodes, no agents.

| Destination | Gateway (node IP) | Notes |
|---|---|---|
| 10.42.0.0/24 | TBD (mgmt-server-001 IP) | |
| 10.42.1.0/24 | TBD (mgmt-server-002 IP) | |
| 10.42.2.0/24 | TBD (mgmt-server-003 IP) | |
| 10.42.3.0/24 | TBD (mgmt-server-004 IP) | |
| 10.42.4.0/24 | TBD (mgmt-server-005 IP) | |

### infra cluster

Pod CIDR: 10.42.0.0/16 (separate from mgmt — different cluster, different L3
domain from CM perspective).

Wait — this is a CIDR collision risk if both clusters use 10.42.0.0/16. Two
options:

1. **Use distinct pod CIDRs per cluster** (the design says this in §3.4):
   - mgmt: TBD (allocate from your IPAM)
   - infra: 10.42.0.0/16
   - gpu: 10.44.0.0/16
   - gpu-2: 10.46.0.0/16

2. **Same CIDR but the CM has a separate routing context per cluster** — much
   harder, requires VRF or per-VLAN route tables. Skip.

Pick option 1. The mgmt cluster needs its own pod CIDR allocated. Update
design-rke2.md §3.4 if it currently has mgmt sharing infra's 10.42.0.0/16.

### gpu cluster

Pod CIDR: 10.44.0.0/16 — 3 servers + N agents (B200/B300/L40 hosts).

Routes added as agents are provisioned. Plan for a sweep after each agent batch.

### gpu-2 cluster (future mirror)

Pod CIDR: 10.46.0.0/16. Routes added when cluster is built.

## Build checklist (per cluster, after the cluster is up)

- [ ] Run `kubectl get nodes -o jsonpath=...` to dump node-name → podCIDR mapping.
- [ ] On Kemp CM unit 1: System Config → Network Setup → Additional Routes →
      add one route per node.
- [ ] On Kemp CM unit 2: same routes (HA pair must match).
- [ ] From CM, `ping <pod-ip>` to verify reachability.
- [ ] Document the route table in cluster-specific runbook for ops reference.
- [ ] Set up a calendar reminder or hook to re-sync routes after agent additions.
      (Future: automate this via Foreman post-provision hook + Kemp API.)

## What this does NOT do

- Does not configure the L7 ingress controller itself — that's the RDR-7 install
  spike (separate work).
- Does not handle Cilium config — that's in the cluster's smart class param +
  HelmChartConfig override (part of the module + Foreman setup).
- Does not handle DNS — apiserver DNS is in `kemp-vip-design.md`; the
  `*.apps.<cluster>.<base>` wildcard is RDR-7.
