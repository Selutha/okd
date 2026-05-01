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
  if $ufrc_rke2::vm_iface {
    $vm_ip = $facts.dig('networking', 'interfaces', $ufrc_rke2::vm_iface, 'ip')
    unless $vm_ip {
      fail("ufrc_rke2: vm_iface '${ufrc_rke2::vm_iface}' has no IP — interface missing or down")
    }
    $with_vm = { 'node-ip' => $vm_ip }
  } else {
    $with_vm = {}
  }

  if $ufrc_rke2::mgmt_iface {
    $mgmt_ip = $facts.dig('networking', 'interfaces', $ufrc_rke2::mgmt_iface, 'ip')
    unless $mgmt_ip {
      fail("ufrc_rke2: mgmt_iface '${ufrc_rke2::mgmt_iface}' has no IP")
    }
    $with_mgmt = $with_vm + { 'node-external-ip' => $mgmt_ip }
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
