# mgmt cluster rebuild — CIDR pivot to 100.64.0.0/10

One-time operational plan to re-roll the mgmt cluster off 192.168.0.0/16 and
onto the new 100.64.0.0/10 fleet allocation scheme.

Pick up cold from any workstation — this plan is self-contained.

## Background

The original `cidr-plan.md` claimed all of 192.168.0.0/16 was free for K8s.
Discovery on 2026-05-04 showed the environment has many existing subnets
inside 192.168/16 (FA storage `hpg-roce` 192.168.20.0/24, vMotion
192.168.30.0/24, ResVault `192.168.64.0/18`, multiple compute fabrics,
switch management, etc.). See `192.168-allocation-actual.md` for the full
inventory.

The mgmt cluster's current service CIDR (192.168.16.0/20) overlaps the FA
`hpg-roce` subnet — a dormant collision that will break K8s service routing
the moment any K8s node gets an interface on the storage network. Since the
storage CSI work was about to add exactly that connectivity, the cluster has
to be rebuilt with safe CIDRs first.

Updated `cidr-plan.md` allocates the mgmt cluster at:

- Pod CIDR: `100.64.0.0/20`
- Service CIDR: `100.64.16.0/20`
- /16 slot: `100.64.0.0/16` (cluster gets a full /16 with 14 spare /20s for growth)

## Pre-flight decisions (settle these before starting)

1. **Foreman/Hiera location** — confirm where the per-cluster `cluster-cidr`
   and `service-cidr` values are maintained. They get rendered into
   `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` by the `ufrc_rke2`
   Puppet module, but the actual values come from Foreman host parameters or
   a Hiera data file outside this repo. You need to know where to update.

2. **Rancher Cluster CR strategy** — pod and service CIDRs are immutable on
   a Rancher Cluster CR, so this is a delete-and-recreate, not an in-place
   edit. Confirm you're comfortable with that.

3. **Maintenance window** — the rebuild itself is ~30–60 minutes once
   Foreman/Hiera and source files are updated. Plan accordingly. Nothing
   real is running on the cluster yet, so user impact is zero, but you'll
   be unable to run any kubectl/Rancher operations during the window.

4. **Tailscale verification** — your `cidr-100.64-notes.md` flags Tailscale
   as the primary risk for 100.64/10. Confirm with security/netops it's not
   in use in the org. If it is, pause and reconsider — re-rolling onto
   100.64/10 only to discover Tailscale collisions is wasted work.

## Phase 1 — Update source files (in repo, no live impact)

These three files in the repo hold concrete CIDR values that need to match
the new plan. Update and commit *before* starting the teardown so the repo
is the source of truth from the moment the rebuild begins.

### 1a. `src/ufrc_rke2/README.md` (around line 60)

Replace:

```puppet
    'cluster-cidr' => '192.168.0.0/20',
```

with:

```puppet
    'cluster-cidr' => '100.64.0.0/20',
```

### 1b. `src/ufrc_rke2/examples/server.pp` (lines 12–13)

Replace:

```puppet
    'cluster-cidr'       => '192.168.0.0/20',
    'service-cidr'       => '192.168.16.0/20',
```

with:

```puppet
    'cluster-cidr'       => '100.64.0.0/20',
    'service-cidr'       => '100.64.16.0/20',
```

### 1c. `src/kub-mgmt/cilium-helmchartconfig.yaml` (lines 23 and 88)

The comment on line 23:

```yaml
# CIDR scheme is per cidr-plan.md (192.168.0.0/16 sliced into /20 pairs).
```

becomes:

```yaml
# CIDR scheme is per cidr-plan.md (100.64.0.0/10 — each cluster owns a /16 slot).
```

The actual CIDR on line 88:

```yaml
        clusterPoolIPv4PodCIDRList:
          - 192.168.0.0/20
```

becomes:

```yaml
        clusterPoolIPv4PodCIDRList:
          - 100.64.0.0/20
```

### 1d. Commit

Single commit covering all three files. Reference `cidr-plan.md` and
`192.168-allocation-actual.md` in the commit message so the why is captured.

### 1e. Files NOT to touch

- `src/kub-mgmt/cilium-l2-pools.yaml` — 172.16.192.x and 10.13.160.x are
  underlay LoadBalancer IP pools, unrelated to pod/service CIDRs.
- `src/kub-mgmt/network-policy-templates.yaml` — example CIDRs in
  documentation templates, unrelated.

## Phase 2 — Flatten existing cluster

Two acceptable paths. **Path A (flatten and reprovision)** is preferred — it
eliminates any state drift on the nodes from the prior install and is the
likely path. Path B is documented as the lighter-touch alternative.

### Path A — Flatten and reprovision (preferred)

Order matters here: update Foreman/Hiera with the new CIDRs *before* you
reimage, so Puppet renders the new values on first boot of the fresh hosts.

1. **Update Foreman/Hiera** with the new mgmt-cluster CIDRs:
   - `cluster-cidr: 100.64.0.0/20`
   - `service-cidr: 100.64.16.0/20`
2. **Delete the Rancher Cluster CR** (Rancher UI → Cluster Management →
   Clusters → mgmt → ⋯ → Delete). Wait for completion (~60s).
3. **Reimage the VMs** via your normal Foreman reprovisioning workflow.
   Each host comes up clean, Puppet runs as part of provisioning, and
   `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` renders with the new
   CIDRs from the start.
4. **Verify** on each node after Puppet has applied:

   ```bash
   cat /etc/rancher/rke2/config.yaml.d/00-puppet.yaml
   ```

   Expected (relevant lines):

   ```yaml
   cluster-cidr: 100.64.0.0/20
   service-cidr: 100.64.16.0/20
   cni: cilium
   disable-kube-proxy: true
   ```

5. Skip Phase 3 — Foreman/Hiera was updated as part of step 1 and Puppet
   already applied as part of provisioning. Proceed directly to Phase 4.

### Path B — Uninstall in place (lighter touch)

Per the "back out the entire cluster" section of
`src/bootstrap-cluster/manual-bootstrap-runbook.md`, do this on every node:

```bash
sudo /usr/local/bin/rke2-uninstall.sh
sudo rm -f /etc/rancher/rke2/config.yaml.d/50-rancher.yaml
```

Order doesn't matter — once `rke2-uninstall.sh` runs on a server node, the
cluster's etcd quorum is already gone, so additional uninstalls are just
local cleanup.

The `00-puppet.yaml` drop-in stays — Puppet refreshes it with new CIDRs in
Phase 3.

In Rancher UI:

1. Cluster Management → Clusters → mgmt → ⋯ → Delete

Wait for the deletion to complete (usually <60 seconds).

**What stays in place** in either path (no need to recreate):

- Kemp VIP and Real Server config (per `kemp-vip-design.md`)
- DNS A record for `<cluster>.<base>` pointing at the Kemp VIP
- Foreman host registrations (Path A reimages on top of these; Path B leaves
  the OS alone)

## Phase 3 — Update Foreman/Hiera with new CIDRs (Path B only)

**Skip this phase if you took Path A** — Foreman/Hiera is already updated
and Puppet already applied during reprovisioning.

For Path B, in whatever data source feeds Hiera/Puppet for the mgmt cluster
nodes, set:

- `cluster-cidr: 100.64.0.0/20`
- `service-cidr: 100.64.16.0/20`

Then on each cluster node:

```bash
sudo puppet agent -t
```

Verify the rendered drop-in:

```bash
cat /etc/rancher/rke2/config.yaml.d/00-puppet.yaml
```

Expected (relevant lines):

```yaml
cluster-cidr: 100.64.0.0/20
service-cidr: 100.64.16.0/20
cni: cilium
disable-kube-proxy: true
```

If any node still shows 192.168 values, the Foreman/Hiera change didn't
propagate — fix and re-run Puppet before continuing.

## Phase 4 — Re-create Rancher Cluster CR

In Rancher UI:

1. Cluster Management → Create → Custom
2. Name: `mgmt` (same as before)
3. Kubernetes Version: `v1.35.4+rke2r1` (per RDR-8 — match the prior cluster)
4. Container Network: **none** (Cilium is installed via Puppet's RKE2 config drop-in)
5. Cluster Network — **Pod CIDR: 100.64.0.0/20, Service CIDR: 100.64.16.0/20**
6. Other settings: match the prior cluster's config (CIS profile, etc.)

Save the CR. Don't run any registration commands yet.

## Phase 5 — Bootstrap

Follow `src/bootstrap-cluster/manual-bootstrap-runbook.md` — the procedure
is identical to the original build. Key points specific to this rebuild:

### 5a. Pre-flight checks (from the runbook)

Re-verify everything in the runbook's Pre-flight section. The most likely
gotchas after a re-roll:

- DNS record still resolves (it should — we didn't touch it)
- Kemp VIP Real Servers show unhealthy (expected — no nodes registered yet)
- `00-puppet.yaml` shows new CIDRs (verified in Phase 3)
- `rke2-server`/`rke2-agent` services NOT running on any node (verified
  by `rke2-uninstall.sh` in Phase 2)

### 5b. Seed-only Cilium HelmChartConfig drop

On the seed node ONLY:

```bash
scp src/kub-mgmt/cilium-helmchartconfig.yaml <seed>:/tmp/
ssh <seed> sudo install -m 0644 /tmp/cilium-helmchartconfig.yaml \
  /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
```

This must be done **before** `rke2-server` first starts; otherwise default
Cilium values deploy and your overrides only land on next reconcile.

### 5c. Run the bootstrap script (or manual procedure)

Seed first, single node:

```bash
bootstrap-cluster.sh mgmt seed
```

Wait until Rancher UI shows the cluster Active and the seed node Ready.
Don't start the next stage until then — adding more servers while the seed
is still bootstrapping causes etcd-quorum confusion.

Additional servers, **serially** (one at a time):

```bash
bootstrap-cluster.sh mgmt server -w mgmt-server-002.example
# wait for Ready
bootstrap-cluster.sh mgmt server -w mgmt-server-003.example
# wait for Ready
# ...etc through -005
```

Agents, can be parallel:

```bash
bootstrap-cluster.sh mgmt agent
```

## Phase 6 — Validate

Per the runbook's "Verify the cluster is healthy" section, plus
CIDR-specific checks:

```bash
# All nodes Ready
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl get nodes

# Cilium pods running on all nodes
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl -n kube-system get pods -l k8s-app=cilium

# kube-proxy is NOT present
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl -n kube-system get pods | grep kube-proxy
# (should return nothing)

# Pod IPs are in the new CIDR
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl get pods -A -o wide | awk 'NR>1 {print $7}' | sort -u
# (every IP should start with 100.64.)

# Service IPs are in the new CIDR
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl get svc -A | awk 'NR>1 && $4 != "None" && $4 != "<none>" {print $4}' | sort -u
# (every IP should start with 100.64.16. — 100.64.31.)

# Hubble UI accessible (sanity-check Cilium values were applied)
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl -n kube-system get pods -l k8s-app=hubble-ui
# (should show Running)
```

## Phase 7 — Tidy up

### 7a. Remove the bootstrap-only Cilium file from the seed

Per the bootstrap-cluster README, after the cluster is Active and Cilium is
verified healthy:

```bash
ssh <seed> sudo rm /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
```

The HelmChartConfig CR persists in etcd. Day-2 changes to Cilium values now
go through the repo: edit `src/kub-mgmt/cilium-helmchartconfig.yaml`, then
`kubectl apply -f` it.

### 7b. Re-apply post-bootstrap manifests

If the prior cluster had any of these applied, re-apply them now:

- `src/kub-mgmt/cilium-l2-pools.yaml` — LoadBalancer IP pools
- `src/kub-mgmt/cnpg-operator-helmchart.yaml` — CloudNativePG operator
- `src/kub-mgmt/rancher-helmchart.yaml` — Rancher itself (if it was running on this cluster)
- `src/kub-mgmt/cattle-system-namespace.yaml` and the rancher-* policy/route files
- `src/kub-mgmt/gateway.yaml` — if a cluster-level Gateway resource exists
- Anything else under `src/kub-mgmt/` that was applied to the prior cluster

The `keycloak-*.yaml` files were planning artifacts on the prior cluster
and have NOT been deployed (per the agreed build order: ArgoCD → Harbor →
Keycloak). Do not apply them in this phase.

### 7c. Update notes

Once the rebuild is verified, fold any operational lessons from this run
into:

- `src/bootstrap-cluster/manual-bootstrap-runbook.md` — if any step in this
  plan revealed a gap in the runbook, add it there
- `context/192.168-allocation-actual.md` — if you discover additional 192.168
  subnets during the process, add them
- This file (`mgmt-rebuild-cidr-pivot.md`) — can be archived or deleted once
  the rebuild is done; nothing here is reusable for future builds

## Rollback paths

### Mid-Phase 2 (teardown started, didn't finish)

Just finish the teardown. There's no value in a half-torn-down cluster.

### Mid-Phase 5 (bootstrap failing)

Per the runbook's "Need to back out a registration" section, on the
affected node:

```bash
sudo /usr/local/bin/rke2-uninstall.sh
sudo rm -f /etc/rancher/rke2/config.yaml.d/50-rancher.yaml
```

Delete the node from Rancher UI. Investigate the cause (most likely DNS,
token, or `00-puppet.yaml` content), fix, retry from Phase 5.

### Bootstrap fully failed, want to re-attempt

Same as Phase 2 — uninstall on every node, delete cluster CR, re-create CR
with same CIDRs, re-run bootstrap. Foreman/Hiera don't need re-touching
because they're already correct from Phase 3.

### Need to revert to 192.168 CIDRs entirely

Don't. The collision with `hpg-roce` makes 192.168.16.0/20 unsafe for the
service CIDR going forward. If 100.64/10 turns out to be unworkable
(e.g., Tailscale discovered in the org mid-rebuild), pick a different /20
pair from the three known-free 192.168 blocks listed in
`192.168-allocation-actual.md` (192.168.144.0/20, 192.168.160.0/20, or
192.168.240.0/20) and update both `cidr-plan.md` and the source files
accordingly.

## Definition of done

- [ ] All three source files updated and committed (Phase 1)
- [ ] Old cluster fully torn down, Rancher CR deleted (Phase 2)
- [ ] Foreman/Hiera updated, every node's `00-puppet.yaml` shows new CIDRs (Phase 3)
- [ ] New Rancher Cluster CR created with new CIDRs (Phase 4)
- [ ] All planned servers + agents Ready in Rancher UI (Phase 5)
- [ ] Pod IPs in 100.64.0.0/20, service IPs in 100.64.16.0/20 (Phase 6)
- [ ] Cilium values applied (Hubble UI pod Running confirms HelmChartConfig took effect) (Phase 6)
- [ ] Seed-only Cilium manifest file deleted from the seed node (Phase 7a)
- [ ] Pre-existing cluster manifests re-applied (Phase 7b)
- [ ] This file archived or deleted (Phase 7c)
