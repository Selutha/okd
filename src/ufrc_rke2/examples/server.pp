class { 'ufrc_rke2':
  node_type        => 'server',
  manage_firewalld => true,
  vm_iface         => 'ens224',
  mgmt_iface       => 'ens192',
  config           => {
    'profile'            => 'cis',
    'selinux'            => false,
    'cni'                => 'cilium',
    'disable-kube-proxy' => true,
    'disable'            => ['rke2-ingress-nginx'],
    'cluster-cidr'       => '192.168.0.0/20',
    'service-cidr'       => '192.168.16.0/20',
    'tls-san'            => ['vkub-mgmt.ufhpc', '172.16.192.6'],
    'node-label'         => ['topology.kubernetes.io/region=ufhpc-dh', 'cluster=mgmt'],
  },
}
