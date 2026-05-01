# ufrc_rke2

Puppet module that prepares RHEL 9 hosts to run RKE2 under Rancher's lifecycle management.

## Scope

This module owns the **OS-layer prereqs** for RKE2 on RHEL-family hosts. It explicitly
does NOT install the RKE2 binary, manage its version, or handle cluster lifecycle —
those belong to Rancher.

| In scope | Out of scope |
|---|---|
| Sysctls (`net.ipv4.ip_forward`, `br_netfilter`, `vm.max_map_count`) | RKE2 binary install (Rancher does this via the registration command) |
| Kernel modules (`overlay`, `br_netfilter`) | RKE2 version pinning or upgrades (Rancher Cluster CR + SUC) |
| Firewalld port rules (optional) | Token, server URL, node-name (Rancher's `50-rancher.yaml` drop-in) |
| Drop-in config at `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` | The full `config.yaml` — coexisting with Rancher's drop-in is the point |
| Optional `registries.yaml` for Harbor mirror | rke2-selinux (SELinux disabled per project design RDR-9) |

## Why a custom module instead of `lsst-rke2` or `etma-rke2`

Both Forge alternatives were evaluated. `lsst-rke2` is RPM-only and actively deletes
`config.yaml.d/`, which would break Rancher's registration drop-in. `etma-rke2`
supports the right shape (binary install, drop-in config) but its config template is
hardcoded to a small fixed set of keys (no `cni`, `disable-kube-proxy`, `profile: cis`),
has a Ruby syntax bug in the template, and is unmaintained.

This module's `config` parameter is a free-form hash rendered via `to_yaml`,
so any current or future RKE2 config key is supported without a module update.

## Usage

Minimum:

```puppet
class { 'ufrc_rke2':
  node_type => 'server',
  config    => {
    'cni'                => 'cilium',
    'disable-kube-proxy' => true,
  },
}
```

See `examples/server.pp` and `examples/agent.pp` for fuller cluster/role configs.

### Auto-deriving node-ip from an interface

When `vm_iface` is set, the module reads that interface's IP from facts and injects
it as `node-ip` in the rendered drop-in. Same for `mgmt_iface` → `node-external-ip`.
Lets every host in a Foreman hostgroup share the same parameter set without
per-host configuration:

```puppet
class { 'ufrc_rke2':
  node_type  => 'server',
  vm_iface   => 'ens224',   # high-speed cluster network NIC
  mgmt_iface => 'ens192',   # management network NIC (optional)
  config     => {
    'cni'          => 'cilium',
    'cluster-cidr' => '192.168.0.0/20',
    # node-ip / node-external-ip are filled in from facts at apply time
  },
}
```

A `node-ip` (or `node-external-ip`) explicitly present in `config` wins over the
derived value — escape hatch for hosts where the convention doesn't fit.

If the named interface has no IP fact (interface missing, down at apply time),
the run fails fast rather than silently producing a config with `node-ip: null`.

## How registration actually happens

`bootstrap-cluster.sh` on the bastion fetches the Rancher registration command via
the Rancher API and pdsh's it to the matching host group. Puppet's `register` class
is a fallback path: if you populate the `registration_command` parameter (e.g., from
a Foreman host parameter), the class will run it once with `INSTALL_RKE2_METHOD=tar`
and a systemd-unit-presence guard for idempotency.

The tarball-install env var is deliberate: Rancher's system-upgrade-controller
binary-replaces RKE2 without running `dnf`, leaving the RPM database stale on
RPM-installed nodes. Forcing tarball install bypasses the divergence.

## Requirements

- RHEL 9, AlmaLinux 9, or Rocky 9
- Puppet 7 or 8
- `puppetlabs/stdlib >= 9.0.0`

## Testing

Unit tests via `pdk test unit` (rspec-puppet). Acceptance tests via Litmus against
a UBI9 init container (`registry.access.redhat.com/ubi9-init`). The module verifies
prereqs apply cleanly and config drop-ins render correctly; actual RKE2 cluster
formation is validated separately on real VMs (see project task #10).
