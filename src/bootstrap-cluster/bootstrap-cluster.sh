#!/bin/bash
#
# Fetch a Rancher cluster registration command and run it on targeted hosts via pdsh.
#
# Forces INSTALL_RKE2_METHOD=tar so the binary lands at /usr/local/bin/rke2.
# Default RHEL behavior is RPM install at /usr/bin/rke2, but Rancher's
# system-upgrade-controller binary-replaces /usr/bin/rke2 without running dnf,
# leaving the RPM database stale (rancher/rke2#661). Tar install bypasses that.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <cluster-name> <role> [-g <dshgroup> | -w <hostlist>]

Roles:
  seed     First control-plane node (cluster-init, run once per cluster build)
  server   Additional control-plane nodes
  agent    Worker nodes

Targeting (pick one):
  no flag:           pdsh -g rke2-<cluster>-<role>     [default convention]
  -g <dshgroup>:     pdsh -g <dshgroup>                [override dshgroup name]
  -w <hostlist>:     pdsh -w <comma-separated hosts>   [explicit hostlist]

Credentials:
  Reads ~/.rancher-credentials (must be mode 0600).
  Required: RANCHER_URL, RANCHER_TOKEN.

Examples:
  $(basename "$0") mgmt seed
  $(basename "$0") mgmt server
  $(basename "$0") infra agent -g rke2-infra-workers
  $(basename "$0") gpu seed -w gpu-server-001.example.com
EOF
}

if [[ $# -lt 2 ]]; then usage; exit 1; fi

cluster=$1
role=$2
shift 2

pdsh_flags=("-g" "rke2-${cluster}-${role}")

while getopts ":g:w:h" opt; do
  case $opt in
    g) pdsh_flags=("-g" "$OPTARG") ;;
    w) pdsh_flags=("-w" "$OPTARG") ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument" >&2; usage; exit 1 ;;
  esac
done

case "$role" in
  seed|server|agent) ;;
  *) echo "Invalid role: $role (must be seed, server, or agent)" >&2; exit 1 ;;
esac

cred_file="${HOME}/.rancher-credentials"
if [[ ! -f "$cred_file" ]]; then
  echo "Credentials file not found: $cred_file" >&2
  echo "Create it with RANCHER_URL=... and RANCHER_TOKEN=... then chmod 0600." >&2
  exit 1
fi
if [[ "$(stat -c %a "$cred_file")" != "600" ]]; then
  echo "Refusing to read $cred_file: must be mode 0600 (run: chmod 0600 $cred_file)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$cred_file"

if [[ -z "${RANCHER_URL:-}" || -z "${RANCHER_TOKEN:-}" ]]; then
  echo "RANCHER_URL or RANCHER_TOKEN not set in $cred_file" >&2
  exit 1
fi

cluster_id=$(curl -sfk -H "Authorization: Bearer $RANCHER_TOKEN" \
  "${RANCHER_URL}/v3/clusters?name=${cluster}" \
  | jq -r '.data[0].id // empty')

if [[ -z "$cluster_id" ]]; then
  echo "No Rancher cluster found with name '$cluster'" >&2
  exit 1
fi
echo "Cluster '$cluster' resolved to ID '$cluster_id'"

node_command=$(curl -sfk -H "Authorization: Bearer $RANCHER_TOKEN" \
  "${RANCHER_URL}/v3/clusterregistrationtokens?clusterId=${cluster_id}" \
  | jq -r '.data[0].nodeCommand // empty')

if [[ -z "$node_command" ]]; then
  echo "No registration command available for cluster $cluster" >&2
  echo "Ensure the cluster has a registration token in Rancher UI." >&2
  exit 1
fi

# Rancher's nodeCommand is the prefix; the operator appends role flags.
# seed and server use identical flags — the cluster-init vs cluster-join distinction
# is decided by Rancher's controller based on existing cluster state, not by the host.
case "$role" in
  seed|server) role_flags="--etcd --controlplane" ;;
  agent)       role_flags="--worker" ;;
esac

registration_cmd="${node_command} ${role_flags}"
echo "Registration command resolved (${#registration_cmd} chars)"

# base64-encode the command before pdsh-ing — Rancher's nodeCommand contains
# single quotes (e.g., --label 'cattle.io/os=linux') that would otherwise need
# elaborate escaping. base64 alphabet has no shell metacharacters.
encoded=$(printf 'export INSTALL_RKE2_METHOD=tar\n%s\n' "$registration_cmd" | base64 -w0)

echo "Running registration via pdsh ${pdsh_flags[*]}"
echo "(Already-registered hosts will be detected by Rancher's installer and no-op'd)"
pdsh "${pdsh_flags[@]}" "echo '$encoded' | base64 -d | sudo bash"

echo
echo "Done. Verify in Rancher UI: ${RANCHER_URL}/dashboard/c/${cluster_id}/explorer"
