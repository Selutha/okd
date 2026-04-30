# @summary Optional fallback path for running the Rancher registration command.
#
# Normally bootstrap-cluster.sh on the bastion runs the registration via pdsh and
# this class is a no-op (registration_command is undef). When set, this class
# execs the command once, gated on the rke2 systemd unit not being enabled.
#
# INSTALL_RKE2_METHOD=tar forces tarball install at /usr/local/bin/rke2 instead
# of the RHEL default (RPM at /usr/bin/rke2). Per design RDR-8: Rancher's
# system-upgrade-controller binary-replaces the RKE2 binary without running dnf,
# which leaves the RPM database stale on RPM-installed nodes. Forcing tarball
# install bypasses that divergence — RPM database doesn't track RKE2 at all.
#
# @api private
class ufrc_rke2::register {
  if $ufrc_rke2::registration_command {
    $svc = $ufrc_rke2::node_type ? {
      'server' => 'rke2-server',
      'agent'  => 'rke2-agent',
    }

    exec { 'ufrc_rke2-register':
      command     => "/bin/bash -c '${ufrc_rke2::registration_command}'",
      environment => ['INSTALL_RKE2_METHOD=tar'],
      unless      => "/usr/bin/systemctl is-enabled ${svc} > /dev/null 2>&1",
      timeout     => 600,
      logoutput   => 'on_failure',
    }
  }
}
