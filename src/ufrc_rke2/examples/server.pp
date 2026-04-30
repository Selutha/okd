class { 'ufrc_rke2':
  node_type        => 'server',
  manage_firewalld => true,
  config           => {
    'profile'            => 'cis',
    'selinux'            => false,
    'cni'                => 'cilium',
    'disable-kube-proxy' => true,
    'disable'            => ['rke2-ingress-nginx'],
    'cluster-cidr'       => '10.42.0.0/16',
    'service-cidr'       => '10.43.0.0/16',
    'tls-san'            => ['mgmt.example.com', '10.50.20.10'],
    'node-label'         => ['topology.kubernetes.io/region=onprem-dc1'],
  },
}
