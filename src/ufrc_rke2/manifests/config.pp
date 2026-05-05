# @summary Renders RKE2 config drop-ins.
#
# Writes /etc/rancher/rke2/config.yaml.d/00-puppet.yaml from the user-supplied hash.
# Drop-in style is deliberate: Rancher's registration command writes its own
# 50-rancher.yaml drop-in (token, server URL, node-name); RKE2 merges all files in
# the .d/ directory at startup. We must NOT write the full config.yaml or delete
# the .d/ directory — that would break Rancher registration.
#
# @api private
class ufrc_rke2::config {
  $config_dir = '/etc/rancher/rke2/config.yaml.d'

  ensure_resource('file', '/etc/rancher', { ensure => directory, mode => '0755' })
  ensure_resource('file', '/etc/rancher/rke2', { ensure => directory, mode => '0755' })

  file { $config_dir:
    ensure => directory,
    mode   => '0755',
  }

  # Derive node-ip / node-external-ip from interface facts when the corresponding
  # iface parameter is set. User-supplied values in $config take precedence.
  #
  # Soft-skip if the interface isn't found (or has no IP yet). Hard-failing here
  # blocks the entire catalog on first puppet runs — most commonly during kickstart
  # or right after first boot, before systemd-udev's predictable naming has fully
  # settled (interfaces transiently appear as eth0/eth1 instead of ens192/ens224)
  # or before NetworkManager has assigned IPs to secondary NICs. We notice() so
  # the operator can spot it, but let the rest of the catalog (sysctls, modules,
  # 00-puppet.yaml without node-ip) apply. The next puppet run picks up node-ip
  # once the interfaces have settled.
  if $ufrc_rke2::vm_iface {
    $vm_ip = $facts.dig('networking', 'interfaces', $ufrc_rke2::vm_iface, 'ip')
    if $vm_ip {
      $with_vm = { 'node-ip' => $vm_ip }
    } else {
      notice("ufrc_rke2: vm_iface '${ufrc_rke2::vm_iface}' missing or has no IP — skipping node-ip override on this run; will retry next puppet run")
      $with_vm = {}
    }
  } else {
    $with_vm = {}
  }

  if $ufrc_rke2::mgmt_iface {
    $mgmt_ip = $facts.dig('networking', 'interfaces', $ufrc_rke2::mgmt_iface, 'ip')
    if $mgmt_ip {
      $with_mgmt = $with_vm + { 'node-external-ip' => $mgmt_ip }
    } else {
      notice("ufrc_rke2: mgmt_iface '${ufrc_rke2::mgmt_iface}' missing or has no IP — skipping node-external-ip override on this run; will retry next puppet run")
      $with_mgmt = $with_vm
    }
  } else {
    $with_mgmt = $with_vm
  }

  $effective_config = $with_mgmt + $ufrc_rke2::config

  file { "${config_dir}/00-puppet.yaml":
    ensure  => file,
    mode    => '0644',
    content => to_yaml($effective_config),
    require => File[$config_dir],
  }

  if $ufrc_rke2::harbor_url {
    file { '/etc/rancher/rke2/registries.yaml':
      ensure  => file,
      mode    => '0600',
      content => to_yaml({
          'mirrors' => {
            'docker.io' => {
              'endpoint' => [$ufrc_rke2::harbor_url],
            },
          },
      }),
    }
  } else {
    file { '/etc/rancher/rke2/registries.yaml':
      ensure => absent,
    }
  }
}
