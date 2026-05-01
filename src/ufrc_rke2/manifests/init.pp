# @summary Manages RKE2 prereqs, config drop-ins, and Rancher registration.
#
# This module sits inside the OS↔Rancher boundary: Foreman/Puppet prepare the host
# (sysctls, firewalld, kernel modules, RKE2 config drop-in) but do NOT install the
# RKE2 binary or manage its version. Rancher's registration command (delivered by
# bootstrap-cluster.sh on the bastion, or via `registration_command` here as a
# fallback) installs the binary; Rancher's system-upgrade-controller drives upgrades.
#
# @param node_type
#   Whether this host runs an RKE2 server or agent. Drives which systemd unit the
#   register class checks for idempotency.
#
# @param config
#   Free-form hash rendered to /etc/rancher/rke2/config.yaml.d/00-puppet.yaml.
#   Drop-in style — coexists with Rancher's 50-rancher.yaml registration drop-in.
#   Token, server URL, and node-name should NOT be here; Rancher supplies those.
#
# @param registration_command
#   Optional. The full Rancher registration curl|sh command. If set, the register
#   class runs it once (gated on the rke2 systemd unit not being enabled).
#   Normally left undef — bootstrap-cluster.sh handles registration directly.
#
# @param harbor_url
#   Optional. If set, /etc/rancher/rke2/registries.yaml is rendered with docker.io
#   mirrored to this URL. Mgmt cluster boots without it; gets added once Harbor is up.
#
# @param manage_firewalld
#   Whether to open RKE2/Cilium ports in firewalld. Default false to avoid surprising
#   sites that disable firewalld inside the cluster network.
#
# @param vm_iface
#   Optional. Interface name carrying the high-speed/cluster network. When set, the
#   IP of this interface is injected as `node-ip` in the rendered drop-in. Lets us
#   keep node-ip out of per-host Foreman config — every host derives its own.
#   A value of `node-ip` in $config takes precedence (escape hatch).
#
# @param mgmt_iface
#   Optional. Interface name carrying the management network. When set, the IP of
#   this interface is injected as `node-external-ip`. Same precedence rule as vm_iface.
class ufrc_rke2 (
  Enum['server', 'agent']  $node_type,
  Hash                     $config = {},
  Optional[String[1]]      $registration_command = undef,
  Optional[String[1]]      $harbor_url = undef,
  Boolean                  $manage_firewalld = false,
  Optional[String[1]]      $vm_iface = undef,
  Optional[String[1]]      $mgmt_iface = undef,
) {
  contain ufrc_rke2::prereqs
  contain ufrc_rke2::config
  contain ufrc_rke2::register

  Class['ufrc_rke2::prereqs']
  -> Class['ufrc_rke2::config']
  -> Class['ufrc_rke2::register']
}
