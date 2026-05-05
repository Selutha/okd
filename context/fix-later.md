# Fix-Later — Tracked Technical Debt

Things we left as workarounds, expedients, or "good enough for now" while
building out the mgmt cluster. Not blocking production, but each one is
real debt that should be paid down before declaring this fully baked.

Format: priority → item → why it's debt → what to do. Cross out items as
they're addressed.

---

## High priority — touch before production

### Rotate the etcd-snapshot S3 access key

**Why it's debt**: the access key currently in
`Foreman → smart class param → ufrc_rke2::config.etcd-s3-access-key` was
created during build and was visible in the operations chat / paste
buffer / terminal scrollback. Defensive rotation before production hands
this cluster real workloads.

**What to do**:

```bash
# On the Qumulo admin host
python3 /opt/qumulo_api/qq --credentials-store /root/.qq_cache --host qumulo-data.ufhpc \
  s3_create_access_key "SID:S-1-5-21-3634500286-2099014746-2689594825-1004"
# Capture the new access_key_id + secret_access_key

# Update Foreman smart class param ufrc_rke2::config:
#   etcd-s3-access-key:  <new id>
#   etcd-s3-secret-key:  <new secret>

# Roll the change to all 5 servers, one at a time:
sudo puppet agent -t                   # picks up new keys in 00-puppet.yaml
sudo systemctl restart rke2-server
# Wait for Ready before next node

# Delete the old access key
python3 /opt/qumulo_api/qq --credentials-store /root/.qq_cache --host qumulo-data.ufhpc \
  s3_delete_access_key 00000000000003ec74e6
```

Verify after rotation: take a manual snapshot, confirm it lands in S3 with
the new credentials.

### Replace `etcd-s3-skip-ssl-verify: true` with proper CA validation

**Why it's debt**: skip-verify trades transport-layer integrity for
operational ease. Acceptable on a tightly-controlled internal fabric, but
removes a layer of defense against MITM that's free to put back. Leaving
it indefinitely also means TLS upgrades on the Qumulo side go silently
unvalidated.

**What to do**:

1. Get the Qumulo CA cert chain from your Qumulo admin (or pull it from
   the live cert):
   ```bash
   openssl s_client -showcerts -connect qumulo-data.ufhpc:9000 </dev/null 2>/dev/null | \
     awk '/BEGIN/,/END/' > qumulo-ca.crt
   # Inspect the chain — the issuer cert(s) above the leaf are what go in the CA file
   ```
2. Decide: install via Puppet's existing TLS-trust class (preferred —
   adds to `/etc/pki/ca-trust/source/anchors/` and runs `update-ca-trust`),
   OR drop at a known path and reference it from RKE2 config.
3. If using Puppet system trust: remove `etcd-s3-skip-ssl-verify` from
   `ufrc_rke2::config` smart class param. RKE2 falls back to system trust.
4. If using a per-RKE2 path: replace the skip-verify line with
   `etcd-s3-endpoint-ca: /etc/rancher/rke2/qumulo-ca.crt` and have Puppet
   manage that file via the rke2 module.
5. Roll the config change to all 5 nodes, restart rke2-server one at a
   time, take a manual snapshot to verify TLS validation succeeds.

---

## Medium priority — when convenient

### Confirm `sysctl` module data has CIS sysctls gated by `has_kub_installed`

**Why it's debt**: during the bootstrap of kub-mgmt1 we manually dropped
`/etc/sysctl.d/90-rke2-cis.conf` because RKE2 with `profile: cis` was
failing on missing kernel parameters. The proper home is the `sysctl`
puppet module's data set, not a manual file. Without that, future cluster
builds (workload clusters) will hit the same wall.

**What to do**:

1. Verify the `sysctl` puppet module's data when `has_kub_installed=true`
   includes:
   ```
   vm.panic_on_oom         = 0
   vm.overcommit_memory    = 1
   kernel.panic            = 10
   kernel.panic_on_oops    = 1
   kernel.keys.root_maxbytes = 25000000
   kernel.keys.root_maxkeys  = 1000000
   ```
2. If absent, add them.
3. Run `puppet agent -t` on each mgmt node to pick up the change.
4. Once the puppet-rendered file matches what's in `/etc/sysctl.d/90-rke2-cis.conf`,
   remove the manual file:
   ```bash
   sudo rm /etc/sysctl.d/90-rke2-cis.conf
   sudo sysctl --system
   sysctl vm.overcommit_memory   # should still be 1, now via puppet's file
   ```

After confirming, update `bootstrap.md` Phase 1 to remove the manual sysctl
drop and replace with "verify Puppet flag `has_kub_installed=true` is set."

### Confirm user puppet class creates `etcd` user gated by `has_etcd_local_user`

**Why it's debt**: same shape as the sysctl debt — we manually ran
`useradd -r etcd -U` during bootstrap. Should be in the puppet user/account
class, gated by `has_etcd_local_user=true`.

**What to do**:

1. Verify the user/account puppet class creates the `etcd` system user
   when `has_etcd_local_user=true`. Should mirror:
   ```puppet
   group { 'etcd': ensure => present, system => true }
   user  { 'etcd': ensure => present, gid => 'etcd', system => true,
                   shell => '/sbin/nologin', managehome => false,
                   require => Group['etcd'] }
   ```
2. If absent, add it.
3. `puppet agent -t` on mgmt nodes — should be a no-op if the user
   already exists, otherwise creates it.

After confirming, update `bootstrap.md` Phase 1 to drop the manual
`useradd` step.

### Pre-place Gateway API CRDs in `/var/lib/rancher/rke2/server/manifests/` to avoid the operator-restart dance

**Why it's debt**: during bootstrap we hit the chart-time CRD detection
problem — Cilium chart's first install couldn't see Gateway API CRDs
(installed later), so it skipped GatewayClass creation and the operator
required a manual restart after CRDs landed. We worked around it with
`gatewayClass.create: "true"` in the values + an operator restart, but
that's two extra steps the next cluster builder has to remember.

**What to do (option A)**: bundle all 6 Gateway API CRDs (5 standard +
experimental TLSRoute) into a single multi-doc YAML (e.g.,
`kub-mgmt/gateway-api-crds.yaml`), copy alongside
`cilium-helmchartconfig.yaml` to
`/var/lib/rancher/rke2/server/manifests/` on the seed before first start.
RKE2's manifest deploy controller applies both at the same time — chart
sees CRDs at install time, no operator restart needed.

Trade-off: bundle drifts from upstream over time; need a process to
refresh it on Cilium / Gateway API version bumps.

**What to do (option B)**: keep the current procedure, accept the
operator restart as documented in `bootstrap.md` Phase 5a. Lower
maintenance, slightly more operator pain.

Decide when building the next cluster — on its own, this isn't worth
investing in for a one-time mgmt build, but the GPU cluster will
re-encounter the same issue.

### Add S3 bucket lifecycle policy as defense-in-depth

**Why it's debt**: RKE2's `etcd-snapshot-retention` deletes oldest
snapshots when count exceeds the limit (per server). If RKE2 ever fails
to clean up — bug, network issue at delete time, credential problem —
snapshots accumulate indefinitely.

**What to do**: configure a Qumulo bucket lifecycle policy to delete
objects older than ~14 days (roughly 2× the RKE2 retention window in
days, so RKE2's normal retention runs first; lifecycle policy only kicks
in if RKE2 fails). Defense-in-depth, not the primary cleanup mechanism.

Confirm the syntax / capability with Qumulo docs — bucket lifecycle on
Qumulo's S3 is configured differently from AWS S3.

### Automate cattle-system namespace pre-creation in cluster bootstrap

**Why it's debt**: Rancher's HelmChart with `createNamespace: true`
creates `cattle-system` with default labels. On `profile: cis` clusters
the cluster-wide PSA enforcement is `restricted`, which Rancher pods
don't satisfy. Install hangs, leaves stale ValidatingWebhookConfigs
behind, becomes a pain to clean up. We hit this on the first install
attempt — recovery took ~3 hours.

**What to do**:

- Add a step to `bootstrap.md` (or a future `mgmt-cluster-runbook.md`)
  that explicitly applies `src/kub-mgmt/cattle-system-namespace.yaml`
  BEFORE applying `rancher-helmchart.yaml`. This is documented in
  `First_run.md` Phase 4 but should also be enforced in any
  scripted/automated install path.
- Long-term: a Kyverno or admission-webhook policy that auto-applies
  PSA labels to known-needs-relaxation namespaces (cattle-system,
  cattle-fleet-system, etc.). Or use an OPA Gatekeeper constraint that
  enforces "namespaces matching `cattle-*` MUST have PSA `baseline`
  labels" so a chart-created namespace gets blocked until labeled.

This applies to every cluster running `profile: cis` that will run
Rancher.

### Tighten Rancher cleanup procedure with safer grep patterns

**Why it's debt**: the naive cleanup pattern
`kubectl get crd | grep -iE "cattle|rancher"` matches both Rancher's
CRDs (which we want to delete) AND RKE2 system CRDs:
- `addons.k3s.cattle.io`
- `etcdsnapshotfiles.k3s.cattle.io`
- `helmchartconfigs.helm.cattle.io`
- `helmcharts.helm.cattle.io`

We accidentally deleted `addons.k3s.cattle.io` during a Rancher
cleanup attempt. Recovery: `systemctl restart rke2-server` re-applies
the bundled manifests. The other 3 system CRDs survived because they
had blocking resources, but it was close.

**What to do**:

- Document the safe pattern in `First_run.md` (DONE — Recovery
  section). Pattern is:

  ```bash
  kubectl get crd -o name | grep -E '\.cattle\.io$' | grep -vE 'k3s\.cattle\.io|helm\.cattle\.io'
  ```

- Or use the label-based selector (Rancher labels its CRDs):

  ```bash
  kubectl get crd -l app.kubernetes.io/managed-by=rancher
  ```

- Long-term: write a small `scripts/rancher-cleanup.sh` in the repo
  that uses the safe pattern AND handles CRD finalizer stripping.
  Reduces operator error during stressful "install failed, need to
  redo" moments.

### Document the Rancher install failure-recovery decision tree

**Why it's debt**: the recovery-mode-decision tree we worked through
during this session (PSA error → namespace label → webhook deadlock →
nuke namespace → strip CR finalizers → strip CRD finalizers → restart
rke2-server if system CRDs were collateral) is now captured in
`First_run.md` Recovery section. But it's a long doc and easy to miss
under stress.

**What to do**: extract just the Recovery section into
`mgmt-cluster-operations.md` as a "Rancher install failure recovery"
runbook so it's findable from the day-2 doc map without reading the
full first-run procedure.

### Put Hubble UI behind Keycloak SSO once auth is in place

**Why it's debt**: Hubble UI is currently enabled and accessed only via
`kubectl port-forward -n kube-system svc/hubble-ui 12000:80`. The UI
itself has no built-in authentication — anyone with cluster access can
see all network flows. Acceptable for now (small team, kubectl access is
already gated), but it's a real audit/exposure concern long-term, and
port-forward isn't a great UX for routine use.

**What to do** (deferred until Keycloak is up):

1. Add a `Gateway` listener at `hubble.rc.ufl.edu` (wildcard cert
   already covers it).
2. Stand up `oauth2-proxy` (or equivalent) configured against Keycloak
   as the OIDC provider.
3. `HTTPRoute hubble.rc.ufl.edu` → oauth2-proxy → hubble-ui Service.
4. NetworkPolicy in `kube-system` allowing ingress to hubble-ui only
   from oauth2-proxy pods.
5. Once verified, document access in mgmt-cluster-operations.md and
   stop using port-forward.

Until then: keep hubble-ui as `ClusterIP`, never expose externally.

### Standardize a "ship NetworkPolicy with every Service" pattern

**Why it's debt**: RKE2's `profile: cis` applies a default-deny ingress
NetworkPolicy (`default-network-policy`) to every namespace at bootstrap
per CIS Benchmark 5.3.2. Every Service that needs ingress from outside
its namespace (LoadBalancer, NodePort, anything fronted by Cilium
Gateway) requires an explicit NetworkPolicy alongside it. Forgetting
results in silent drops at the destination pod's eBPF program — visible
only via `cilium-dbg monitor`. We hit this during the LB allocator smoke
test (caught quickly because we were watching cilium monitor; would have
been much harder to diagnose for an installed Helm chart that "just
doesn't work").

**What to do**:

- Add a checklist item to every "install service X" runbook: "did you
  ship a NetworkPolicy?"
- For Helm-installed services (Rancher, future apps): verify each chart's
  values either ship a NetworkPolicy or accept one being added.
  cert-manager, external-dns, Rancher, etc. each have their own pattern.
- Consider a default policy template in `src/kub-mgmt/` (e.g.,
  `network-policy-templates.yaml`) with example shapes for common cases:
  "allow from world", "allow from same namespace + Cilium Gateway",
  "allow from specific source CIDR".
- Long-term: explore whether a generic admission controller or Kyverno
  policy could auto-generate a stub NetworkPolicy for Services missing
  one (and surface a warning), so this is enforced at apply-time rather
  than discovered via `cilium monitor` after the fact.

This applies to every cluster that uses `profile: cis`, not just mgmt.
Document the pattern in any cluster-build runbook generated for
workload clusters.

---

## Low priority — nice to have

### Add `Object inherit` to the Qumulo bucket ACL

**Why it's debt**: we set `Container inherit` only on the bucket ACL.
Works for the current single-writer scope (`kub-mgmt-snapshots` user
owns its own files). If a second writer is ever added (different cluster
sharing the bucket, an audit script writing to the same path), they
won't inherit access on existing files.

**What to do**:

```bash
python3 /opt/qumulo_api/qq --credentials-store /root/.qq_cache --host qumulo-data.ufhpc \
  fs_modify_acl --path /s3/kub-mgmt-etcd modify_entry \
    --position 4 \
    -f 'Container inherit, Object inherit'
# (verify position 4 is still kub-mgmt-snapshots; ACL positions can shift)
```

Skip until there's a real second-writer scenario.

### Automate the seed `server:` line removal

**Why it's debt**: bootstrap.md Phase 0 has a manual `sed -i '/^server:/d'`
step on the seed before first rke2-server start. Easy to forget; not
fatal (the cluster won't init, you notice fast) but adds a manual
checkpoint to a procedure that's otherwise puppet-driven.

**What to do (option A)**: add a per-host Foreman parameter
`is_rke2_seed=true` on the seed host. Extend `ufrc_rke2` to omit
`server:` from the rendered config when this fact is true. Same approach
we discussed for `cluster-init` originally, just without the (k3s-only)
`cluster-init` value.

**What to do (option B)**: keep the manual edit. It's literally one
command, runs once per cluster lifetime.

Probably stay with B unless the team finds itself rebuilding mgmt
clusters often (which would be unusual).

### Run a real DR rebuild drill

**Why it's debt**: the restore procedure in `mgmt-cluster-operations.md`
is theoretical — derived from RKE2 docs, not validated end-to-end against
this cluster's snapshots. First time you actually have to restore is the
worst time to discover gaps.

**What to do**: stand up a 5-node lab cluster (could be VMs on a
workstation), run a restore from a real S3 snapshot, walk through the
`mgmt-cluster-operations.md` "Restore from S3" section, fix any steps
that are wrong or missing, update the doc.

Schedule this as a quarterly drill once production workloads are on the
cluster.

---

## Cross-out template

When something gets fixed:

```markdown
### ~~Title of item~~ ✅ Fixed YYYY-MM-DD

Brief note about what was actually done, especially if different from the
original plan.
```

Keep crossed-out items in this file for ~6 months for institutional memory
(grep target when someone asks "did we ever fix X?"), then prune.
