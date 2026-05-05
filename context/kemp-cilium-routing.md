# Ingress architecture — Cilium Gateway API

In-cluster ingress is handled by **Cilium Gateway API**, not by Kemp L7 or by
a separate ingress controller (Traefik, ingress-nginx). External traffic that
needs the cluster from outside the HPC fabric optionally relays through Kemp
in **L4 passthrough mode** — Kemp doesn't terminate TLS, doesn't inspect
content, just forwards bytes to a Cilium gateway in the cluster.

## Why this shape

We're already running Cilium with `kubeProxyReplacement: true`. Cilium 1.16+
ships native Gateway API support that re-uses the same eBPF datapath — adding
ingress is enabling a feature flag, not introducing a new control plane or
extra pod. Trade-offs were considered against (a) Kemp L7, (b) Traefik
in-cluster, and (c) Cilium GW; see the project decision log for the full
comparison. Short version:

- One control plane (k8s + Cilium) instead of two (k8s + Kemp L7 config)
- Hubble already gives us L7 observability; in-cluster ingress hooks into it
- GitOps-friendly config via Gateway API CRs
- Gateway API is the SIG-Network direction; Ingress is on the way out
- WAF deferred to per-service Kemp L4-fronted VIPs when needed (Kemp can
  insert L7 + WAF for that one hostname while everything else stays direct)

## Traffic flow

```
internal client (ufhpc network)
        │
        ▼
    DNS:  app.ufhpc → cluster Gateway IP (LoadBalancer-via-MetalLB or NodePort)
        │
        ▼
    Cilium Gateway (eBPF + Envoy filter chain) — TLS termination + L7 routing
        │
        ▼
    backend Service → pod
```

For external-only traffic that must go through Kemp:

```
external client (research collaborator, federation, internet)
        │
        ▼
    DNS:  ext-app.ufhpc → kemp-VIP
        │
        ▼
    Kemp VS  (L4 TCP passthrough, no TLS termination, no inspection)
        │
        ▼
    Cilium Gateway IP   (via static route or via cluster's external network)
        │
        ▼
    Cilium Gateway → backend Service → pod
```

If a specific external service later needs WAF, that one service moves to a
**separate Kemp VIP** in **L7 mode** with the cert at Kemp and WAF rules
applied. The rest of the cluster keeps the L4 passthrough path. WAF is
opt-in per service via DNS hostname routing — no global WAF, no all-or-nothing
choice. (Implementation deferred — capture as a runbook when the first
WAF-needing service surfaces.)

## What's no longer needed (vs the original design)

The earlier design used **Cilium native routing** + **Kemp Connection Manager
Ingress Controller** populating Real Servers from `Service.endpoints`. That
required:

- Static routes per node on Kemp pointing at each node's pod CIDR slice
- L2 adjacency between Kemp and the cluster's node VLAN
- Kemp re-syncing routes whenever a node was added/removed

None of that applies now:

- Cilium runs in **VXLAN encapsulation** mode, so pod IPs are not L3-routable
  outside the tunnel mesh — Kemp couldn't reach them even if we wanted it to
- Kemp doesn't need to know individual pod IPs at all; it just forwards to a
  Service-backed external IP (LoadBalancer via MetalLB, NodePort, or a
  cluster-VIP allocated to the Cilium Gateway)
- Adding/removing nodes requires no Kemp config change

If you find references to "static routes per node on Kemp" or "Kemp CM
Ingress Controller" in older docs (design-rke2.md RDR-7, runbooks, etc.),
those are obsolete — flag for cleanup when next touched.

## Cilium config requirements (already in place)

In `kub-mgmt/cilium-helmchartconfig.yaml`:

```yaml
routingMode: tunnel
tunnelProtocol: vxlan
kubeProxyReplacement: true
gatewayAPI:
  enabled: true
```

Plus the CIDR + MTU + ipam values per cluster.

## Bootstrap order (one-time per cluster)

Gateway API CRDs are NOT bundled with Cilium 1.19 — install them once before
enabling `gatewayAPI: true`:

```bash
GATEWAY_API_VERSION=v1.2.0
for crd in gatewayclasses gateways httproutes referencegrants; do
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml
done

# Experimental — needed for L4 TCP/TLS passthrough routes:
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
```

After CRDs apply, edit the Cilium HelmChartConfig CR to enable
`gatewayAPI: true` (or restart with the updated manifest). Cilium picks up
the CRDs and its GatewayClass becomes available:

```bash
kubectl get gatewayclass
# NAME     CONTROLLER                     ACCEPTED   AGE
# cilium   io.cilium/gateway-controller   True       30s
```

## What goes in a Gateway and HTTPRoute

A `Gateway` resource defines a listener (port + protocol + TLS settings) and
references the `GatewayClass`. It gets a public IP allocated by whatever
external-IP mechanism is in use (MetalLB, Cilium L2 announcement, etc.).

An `HTTPRoute` references a Gateway and defines per-hostname/per-path routing
to backend Services.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cluster-gw
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - name: wildcard-ufhpc-tls   # cert-manager-managed Secret
      allowedRoutes:
        namespaces:
          from: All

---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rancher
  namespace: cattle-system
spec:
  parentRefs:
    - name: cluster-gw
      namespace: gateway-system
  hostnames:
    - rancher.ufhpc
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: rancher
          port: 443
```

Apps install their HTTPRoute alongside their Helm chart values; cluster admin
owns the Gateway resource.

## External LoadBalancer for the Cilium Gateway

Cilium GW listens on a Service of type `LoadBalancer`. Without a cloud
provider, that Service stays `Pending` unless an external-IP allocator is
present. Two options:

1. **MetalLB** — assigns IPs from a configured pool to LoadBalancer
   Services. Pool drawn from the cluster node VLAN (172.16.192.x range, or
   a dedicated subnet for cluster-LB IPs). Standard, well-understood.

2. **Cilium L2 announcements** — Cilium itself can ARP-announce
   LoadBalancer IPs. Removes the MetalLB dependency. Less mature than
   MetalLB but one fewer component to manage. Configure via
   `CiliumL2AnnouncementPolicy` CRDs.

Pick at install time; both work. MetalLB has more StackOverflow coverage.

## Verification (after enabling and applying first Gateway)

```bash
# GatewayClass present and accepted
kubectl get gatewayclass cilium -o yaml | grep -A3 conditions

# Gateway has an address allocated
kubectl get gateway -A

# HTTPRoute is bound to the gateway
kubectl get httproute -A -o wide

# Cilium agent picked it up
kubectl -n kube-system exec ds/cilium -- cilium-dbg config | grep -i gateway
```

## What this doc does NOT cover

- The L4 VIPs for kube-apiserver + supervisor — those are in `kemp-vip-design.md`
- DNS structure for the cluster — in design-rke2.md
- WAF integration when a service needs it — TBD per-service runbook
- cert-manager / Let's Encrypt vs internal CA — TBD per environment policy
