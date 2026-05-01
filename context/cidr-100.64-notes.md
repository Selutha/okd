# Notes on 100.64.0.0/10 for Kubernetes Pod CIDRs

Reference notes on RFC6598 / "shared address space" / "CGNAT space" as a
candidate for Kubernetes cluster-cidr and service-cidr allocations. Not a
decision doc — see `cidr-plan.md` for the actual fleet allocation
(currently 192.168.0.0/16). This file exists to inform a future decision
if we ever outgrow 192.168 or hit a collision we can't engineer around.

## What it is

- **RFC6598** (April 2012) defines `100.64.0.0/10` as "shared address
  space" — an IPv4 range carved out specifically for ISPs running
  Carrier-Grade NAT (CGNAT) so that ISPs can share public IPv4 among
  customers without colliding with the customers' own RFC1918 use.
- Size: **4,194,304 addresses** (a /10 — between RFC1918's 10/8 and the
  smaller 172.16/12).
- IANA-allocated, NOT RFC1918, NOT publicly routable on the internet.
  Routers on the public internet drop traffic to/from 100.64/10 by
  default. Inside a controlled network it behaves like any private
  range.
- Often referred to in k8s docs as "CGNAT space" or "shared space."

## Why k8s shops use it

The classic reason: **RFC1918 collision avoidance**.

In a large enterprise:

- 10.0.0.0/8 is usually fully allocated to corporate networks
- 172.16.0.0/12 is often partially used for VPN, DMZ, lab
  environments
- 192.168.0.0/16 is small (only 64k addresses) and is used by branch
  offices, home users connecting via VPN, IoT segments

Picking a "free" RFC1918 chunk for Kubernetes pods is increasingly
painful. 100.64/10 sidesteps the problem entirely — almost no enterprise
internal network uses it (because it was carved out for ISPs, not
enterprises), so collisions are rare.

Notable adopters:

- **AWS EKS** documents 100.64/10 as a recommended pod CIDR when VPC
  RFC1918 space is exhausted (the "secondary CIDR" pattern uses it)
- **GKE** supports it directly via the "non-RFC1918" pod range option
- Many large on-prem k8s shops adopted it after their second or third
  RFC1918 collision incident

## Pros

| | |
|---|---|
| Size | 4M addresses — vastly larger than 192.168/16 (64k) |
| RFC1918 collisions | Effectively zero with on-prem corporate networks |
| Enterprise familiarity | Most netops people recognize it as "the CGNAT range" |
| Cloud support | First-class on AWS, GCP; works on Azure |
| Routable inside controlled fabric | Behaves identically to RFC1918 once your routers/firewalls know about it |

## Cons / Gotchas

### 1. Tailscale collision (the big one in 2025+)

Tailscale uses 100.64.0.0/10 as its overlay address space. If anyone in
your organization uses Tailscale to reach k8s clusters or k8s nodes
(developer laptops, jump hosts, dev environments), their Tailscale
addresses will overlap with your pod CIDRs.

Effects:
- Tailscale-connected clients can't reach pods at IPs that overlap
  with their own Tailscale-assigned address
- Routing becomes ambiguous when both networks are in scope on the
  same host
- Hard to debug because the symptom is "it works for some users, not
  others" depending on what their Tailscale daemon assigned them

This is the single most-cited reason in 2024–2026 to NOT pick 100.64/10
for k8s. If Tailscale exists or might exist in our environment,
100.64/10 is risky.

### 2. VPN client misbehavior

Some VPN clients (older Cisco AnyConnect, some F5 BIG-IP clients, some
SSL VPN appliances) treat 100.64/10 as "internet that the ISP is
NATting" rather than as private space. Symptoms:

- VPN client tries to NAT 100.64/10 traffic
- VPN client refuses to add a route for 100.64/10 because it conflicts
  with built-in CGNAT detection logic
- Split-tunnel rules mistakenly include or exclude 100.64/10

Modern clients mostly handle it fine, but it's worth testing with
whatever VPN solution we deploy before committing.

### 3. Carrier interop (rare, but worth knowing)

If the cluster is ever reached over a cellular link or residential ISP
that uses CGNAT, the user's link is *also* in 100.64/10. The user's
endpoint IP collides with our pod IPs from the user's perspective.
Symptom: user can't reach specific pod IPs that happen to match their
own NAT-assigned address.

### 4. Tooling / ACL assumptions

Anything that filters "RFC1918 only" excludes 100.64/10:

- `iptables` rules with explicit RFC1918 match lists need updating
- Some logging / SIEM tools categorize 100.64/10 as "public internet"
  and may flag it as an exfiltration risk
- Firewalls with auto-detect "private space" rules vary in behavior

Not deal-breakers, but they're papercuts you only discover after
deployment.

### 5. NOT RFC1918 — psychological trap

People assume RFC1918 == private == safe. 100.64/10 is private in
practice but not RFC1918 by classification. Audit and compliance tooling
sometimes treats it as public. Document the choice clearly so reviewers
don't flag it as a misconfiguration.

## When 100.64/10 is the right call

Pick it over RFC1918 when:

1. RFC1918 is genuinely exhausted in your org (no clean /16 available
   for k8s)
2. You need very large pod CIDRs (e.g., /14 or /15) and can't carve
   that out of RFC1918
3. You operate multi-cluster federation across orgs/sites where each
   side's RFC1918 use is unknown
4. You explicitly want pod traffic to be visually distinguishable from
   org traffic in flow logs

Skip it when:

1. Tailscale is in use anywhere in your org
2. You have RFC1918 headroom (we do: 192.168.0.0/16 is fully free)
3. You have legacy VPN clients you don't fully control
4. Compliance / audit pushes back on non-RFC1918 private space

## Application to our environment

We chose 192.168.0.0/16 over 100.64/10 because:

- We have full /16 of 192.168 free (org uses 10/8)
- Tailscale risk is non-zero in HPC environments where developers may
  use it for laptop-to-jumphost access
- 8-cluster ceiling on 192.168 is well above our planned cluster count
- Simpler conversation with netops ("we're using 192.168.0.0/16 for
  k8s") than explaining RFC6598

100.64/10 stays in our back pocket as the escape hatch if any of those
conditions change.

## Reading list

- [RFC6598](https://datatracker.ietf.org/doc/html/rfc6598) — the
  original spec (short, ~6 pages)
- [IANA IPv4 Special-Purpose Address Registry](https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml)
  — official allocation record
- [AWS EKS — Custom Networking / Secondary CIDR](https://docs.aws.amazon.com/eks/latest/userguide/cni-custom-network.html)
  — production example using 100.64/10
- [Tailscale — IP address ranges](https://tailscale.com/kb/1015/100.x-addresses)
  — explains Tailscale's use of 100.64/10
- Search terms for further reading: "kubernetes 100.64", "RFC6598
  kubernetes", "EKS secondary CIDR", "CGNAT pod CIDR collision"

## Quick decision flowchart

```
Need k8s pod CIDR?
├── RFC1918 has a clean /16 free? ──── YES ──> Use it (we did: 192.168.0.0/16)
│                                       │
│                                       NO
│                                       │
├── Tailscale used anywhere in org? ── YES ──> Avoid 100.64/10, find more RFC1918 or use IPv6
│                                       │
│                                       NO
│                                       │
├── Need very large CIDR (>/16)? ───── YES ──> 100.64/10 is the right call
│                                       │
│                                       NO
│                                       │
└── Multi-org / cross-cloud federation? YES ──> 100.64/10 minimizes collision risk
                                        │
                                        NO ──> Either works; pick by team familiarity
```
