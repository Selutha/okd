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
class ufrc_rke2 (
  Enum['server', 'agent']  $node_type,
  Hash                     $config = {},
  Optional[String[1]]      $registration_command = undef,
  Optional[String[1]]      $harbor_url = undef,
  Boolean                  $manage_firewalld = false,
) {
  contain ufrc_rke2::prereqs
  contain ufrc_rke2::config
  contain ufrc_rke2::register

  Class['ufrc_rke2::prereqs']
  -> Class['ufrc_rke2::config']
  -> Class['ufrc_rke2::register']
}
