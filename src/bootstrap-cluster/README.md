# bootstrap-cluster

Bash + pdsh tool that fetches a Rancher cluster registration command from the
Rancher API and runs it on the targeted host(s). Lives on the bastion.

## Why this exists

Cluster registration is a per-host `curl|sh` against Rancher's system-agent-install
script, with role-specific flags (`--etcd --controlplane` vs `--worker`). For initial
builds that's six-ish manual paste operations across mgmt + infra + GPU clusters.
This script replaces the paste cycle with one command per cluster + role and is
designed for reuse when adding clusters later (DR rebuilds, future GPU mirror, etc.).

The script is the reproducible path; `runbooks/rke2-cluster-bootstrap-manual.md`
documents the manual procedure as the DR fallback when the script can't run.

## Install

Copy the script to the bastion (`/usr/local/bin/bootstrap-cluster.sh` or wherever
your bastion convention places ops tools). Requires `pdsh`, `curl`, `jq`, and
`base64` on the bastion.

Set up credentials:

```bash
cp rancher-credentials.example ~/.rancher-credentials
$EDITOR ~/.rancher-credentials      # paste real RANCHER_URL + RANCHER_TOKEN
chmod 0600 ~/.rancher-credentials
```

The Rancher API token is created in the Rancher UI: *User Avatar → Account & API
Keys → Create API Key*. Use a no-scope (global) key — cluster-scoped keys can't
enumerate clusters by name, which the script needs.

## Usage

```bash
bootstrap-cluster.sh <cluster-name> <role> [-g <dshgroup> | -w <hostlist>]
```

**Roles:**

| Role | When |
|---|---|
| `seed` | First control-plane node of a brand-new cluster (one host) |
| `server` | Additional control-plane nodes after the seed is Active |
| `agent` | Worker nodes after the cluster's control plane is Active |

`seed` and `server` use identical RKE2 flags — the cluster-init vs cluster-join
distinction is decided by Rancher's controller based on existing cluster state.
The role names exist for operator workflow clarity, not flag differences.

**Targeting:**

By default, the script targets `pdsh -g rke2-<cluster>-<role>` (e.g.,
`rke2-mgmt-seed`). Override with:

- `-g <dshgroup>` — different dshgroup name
- `-w <hostlist>` — explicit comma-separated host list

## Idempotency

Re-running on already-registered hosts is safe. Rancher's system-agent-install
script detects existing registration and exits 0 without changes. The only effect
of an extra run is some wasted log output.

## What the script does NOT do

- Wait for Rancher to mark the cluster Active before returning. Operator runs the
  seed, watches Rancher UI until ready, then runs server/agent stages.
- Manage credentials rotation. When the Rancher token expires or is rotated,
  update `~/.rancher-credentials` manually.
- Verify Foreman/Puppet have completed prereqs on the target hosts. Run Puppet
  agent first; then bootstrap-cluster.

## INSTALL_RKE2_METHOD=tar

The script forces tarball install (`/usr/local/bin/rke2`) instead of RHEL's default
RPM install (`/usr/bin/rke2`). This avoids RPM-database-divergence with Rancher's
system-upgrade-controller, which binary-replaces `/usr/bin/rke2` without running
`dnf` (rancher/rke2#661 — open RFE). Tarball install puts the binary on the same
path SUC writes to, so the database doesn't lie after upgrades.
