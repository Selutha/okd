class { 'ufrc_rke2':
  node_type        => 'agent',
  manage_firewalld => true,
  config           => {
    'selinux'    => false,
    'node-label' => ['role=worker'],
  },
}
