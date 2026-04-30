# @summary Host-level RKE2 prereqs: sysctls, kernel modules, optional firewalld.
#
# SELinux is intentionally NOT touched (per design RDR-9, SELinux is disabled
# cluster-wide to match fleet practice). No rke2-selinux package is installed.
#
# @api private
class ufrc_rke2::prereqs {
  $sysctls = {
    'net.ipv4.ip_forward'                 => 1,
    'net.bridge.bridge-nf-call-iptables'  => 1,
    'net.bridge.bridge-nf-call-ip6tables' => 1,
    'vm.max_map_count'                    => 524288,
  }

  $kernel_modules = ['overlay', 'br_netfilter']

  file { '/etc/modules-load.d/rke2.conf':
    ensure  => file,
    mode    => '0644',
    content => $kernel_modules.join("\n") + "\n",
  }

  $kernel_modules.each |String $kernel_module| {
    exec { "modprobe-${kernel_module}":
      command => "/usr/sbin/modprobe ${kernel_module}",
      unless  => "/usr/sbin/lsmod | /usr/bin/grep -q '^${kernel_module} '",
      require => File['/etc/modules-load.d/rke2.conf'],
    }
  }

  $sysctl_lines = $sysctls.map |String $key, Integer $value| { "${key} = ${value}" }

  file { '/etc/sysctl.d/99-rke2.conf':
    ensure  => file,
    mode    => '0644',
    content => $sysctl_lines.join("\n") + "\n",
    notify  => Exec['rke2-sysctl-reload'],
  }

  exec { 'rke2-sysctl-reload':
    command     => '/usr/sbin/sysctl --system',
    refreshonly => true,
  }

  if $ufrc_rke2::manage_firewalld {
    $firewall_ports = {
      'rke2-api'        => { port => 6443,  protocol => 'tcp' },
      'rke2-supervisor' => { port => 9345,  protocol => 'tcp' },
      'kubelet'         => { port => 10250, protocol => 'tcp' },
      'cilium-health'   => { port => 4240,  protocol => 'tcp' },
      'hubble-server'   => { port => 4244,  protocol => 'tcp' },
      'hubble-relay'    => { port => 4245,  protocol => 'tcp' },
    }

    $firewall_ports.each |String $name, Hash $spec| {
      exec { "firewalld-add-${name}":
        command => "/usr/bin/firewall-cmd --permanent --add-port=${spec['port']}/${spec['protocol']}",
        unless  => "/usr/bin/firewall-cmd --query-port=${spec['port']}/${spec['protocol']} --permanent",
        notify  => Exec['firewalld-reload'],
      }
    }

    exec { 'firewalld-reload':
      command     => '/usr/bin/firewall-cmd --reload',
      refreshonly => true,
    }
  }
}
