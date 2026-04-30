# Manual cluster bootstrap runbook (DR fallback)

This is the by-hand procedure for registering hosts to a Rancher RKE2 cluster
when `bootstrap-cluster.sh` can't run. Use cases:

- Script bug or environment issue on the bastion
- Rancher API unreachable from the bastion but reachable from cluster nodes
- Partial cluster recovery (one node failed, want to add a single replacement)
- DR rebuild where the script's assumptions don't hold
- Sanity-check that cluster forms correctly before trusting automation

The script (`bootstrap-cluster.sh`) is the primary path. This runbook is the
fallback. They produce equivalent end states.

## Pre-flight (before any registration)

These must all be true before you start. Skipping any of these is the most
common cause of "registration ran but the cluster doesn't form."

- [ ] Rancher mgmt cluster is up and the Rancher UI is reachable.
- [ ] Cluster CR exists in Rancher (created via UI: *Cluster Management → Create
      → Custom*) with the correct `kubernetesVersion` (currently
      `v1.35.4+rke2r1` per RDR-8) and CNI set to `none` (so RKE2 doesn't try to
      install Canal — Cilium is set via Puppet's config drop-in).
- [ ] Kemp VIP is created with the planned server FQDNs as Real Servers (per
      `kemp-vip-design.md`). Real Servers will all be unhealthy until the seed
      comes up — that's expected.
- [ ] DNS A record `<cluster>.<base>` resolves to the Kemp VIP from BOTH the
      bastion and the target nodes.
- [ ] Foreman has provisioned the target hosts; they're booted, SSH-reachable,
      Puppet has applied at least once.
- [ ] On each target node, Puppet has rendered
      `/etc/rancher/rke2/config.yaml.d/00-puppet.yaml` (verify with
      `cat /etc/rancher/rke2/config.yaml.d/00-puppet.yaml` — should contain
      `cni: cilium`, `disable-kube-proxy: true`, etc).
- [ ] On each target node, `rke2-server` and `rke2-agent` services are NOT yet
      running (`systemctl is-active rke2-server rke2-agent` should both fail).
      If a service is already active, the node is already registered — STOP and
      investigate before attempting to register again.

## Step 1 — Get the registration commands from Rancher UI

In Rancher UI:

1. *Cluster Management → Clusters → click the cluster name*
2. The page shows the registration command. There are usually role checkboxes:
   - **etcd** + **Control Plane** → run on server nodes (seed and additional)
   - **Worker** → run on agent nodes
3. The command looks like:

   ```bash
   curl --insecure -fL https://rancher.example.com/system-agent-install.sh | sudo sh -s - \
     --server https://rancher.example.com \
     --label 'cattle.io/os=linux' \
     --token <bigtoken>:<bigsecret> \
     --ca-checksum <hash>
   ```

4. Copy the command for each role you need (server vs agent). The command itself
   is the same; only the role flags appended at the end differ.

**Always prepend `INSTALL_RKE2_METHOD=tar`** to force tarball install at
`/usr/local/bin/rke2`. Without this, RHEL defaults to RPM install at
`/usr/bin/rke2`, which conflicts with Rancher SUC's binary-replace upgrade
flow (rancher/rke2#661 — see RDR-8).

## Step 2 — Register the seed (first control-plane node, one host only)

Pick the seed host from the planned server list (any of them works; convention
is `<cluster>-server-001`). SSH to it as a sudoer:

```bash
ssh <cluster>-server-001
```

Run the command (server role flags: `--etcd --controlplane`):

```bash
sudo INSTALL_RKE2_METHOD=tar bash -c 'curl --insecure -fL \
  https://rancher.example.com/system-agent-install.sh | sh -s - \
  --server https://rancher.example.com \
  --label "cattle.io/os=linux" \
  --token <token> \
  --ca-checksum <hash> \
  --etcd --controlplane'
```

Replace `<token>` and `<hash>` with the values from Rancher UI. Note the env
var goes BEFORE `bash -c` so it's inherited into the curl|sh subprocess.

**What you'll see:**

The system-agent install script downloads the rancher-system-agent, sets up its
systemd unit, and starts it. The agent then talks back to Rancher and pulls the
RKE2 install plan, which downloads the binary and starts `rke2-server`.

This takes 3-10 minutes depending on network speed. Watch progress:

```bash
sudo journalctl -u rancher-system-agent -f         # in one terminal
sudo journalctl -u rke2-server -f                  # in another, after rke2-server starts
```

You can also tail the rke2 logs:

```bash
sudo tail -f /var/lib/rancher/rke2/server/cluster-init/log
```

Wait until `kubectl get nodes` (run on the seed itself with the kubeconfig at
`/etc/rancher/rke2/rke2.yaml`) shows the seed as `Ready`:

```bash
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl get nodes
```

In Rancher UI, the cluster moves from `Updating` to `Active`.

**Do NOT proceed to step 3 until the seed is Ready.** Adding more servers while
the seed is still bootstrapping can produce etcd-quorum confusion that's
recoverable but annoying.

## Step 3 — Register additional control-plane servers

For each remaining server node (e.g., `-002` through `-005` for mgmt cluster):

```bash
ssh <cluster>-server-002
sudo INSTALL_RKE2_METHOD=tar bash -c '<same curl command as step 2, with --etcd --controlplane>'
```

Same command as the seed. Rancher's controller decides this is an "additional"
node based on cluster state (cluster already has nodes); the host doesn't pass
a special flag for it.

**Add servers one at a time, waiting for each to reach Ready before starting
the next.** This preserves etcd quorum at every step. A 5-node cluster goes:

- 1 server (seed) Ready → quorum=1, can tolerate 0 failures
- Add server 2 → quorum=2 needed, 2 nodes present, can tolerate 0 failures during the add
- Server 2 Ready → quorum=2, can tolerate 0 failures
- Add server 3 → quorum=2 needed, 3 nodes present, **can tolerate 0 failures during the add** (still vulnerable)
- Server 3 Ready → quorum=2, can tolerate 1 failure
- Add server 4 → quorum=3 needed, can tolerate 0 during the add
- Server 4 Ready → quorum=3 (still tolerating 1)
- Add server 5 → can tolerate 0 during
- Server 5 Ready → quorum=3, can tolerate 2 failures

If you parallelize the adds, you increase the window during which a transient
node failure breaks quorum. Serial is safer.

After each server, verify in Rancher UI and via:

```bash
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl get nodes
```

## Step 4 — Register agent (worker) nodes

Once all servers are Ready, register agents. Agents can be added in parallel —
they don't participate in etcd quorum.

For each agent node:

```bash
ssh <cluster>-agent-XYZ
sudo INSTALL_RKE2_METHOD=tar bash -c '<same curl command, but with --worker INSTEAD of --etcd --controlplane>'
```

The role flag is `--worker` for agents. Everything else identical.

You can run all agent registrations near-simultaneously; if you want a single
ssh-and-go pattern from the bastion, use pdsh as the script does:

```bash
pdsh -w <cluster>-agent-001,<cluster>-agent-002,...   \
  "sudo INSTALL_RKE2_METHOD=tar bash -c '<full curl command with --worker>'"
```

But that's basically what the script does — at this point you're usually doing
manual mode for a reason (single replacement, debugging).

## Step 5 — Verify the cluster is healthy

```bash
# All nodes Ready
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl get nodes

# Cilium pods running on all nodes
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl -n kube-system get pods -l k8s-app=cilium

# kube-proxy is NOT present (Cilium replaces it)
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl -n kube-system get pods | grep -i kube-proxy
# (above should return nothing)

# rke2-ingress-nginx is NOT present (Kemp does L7)
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl -n kube-system get pods | grep -i ingress
# (above should return nothing)
```

In Rancher UI, the cluster shows `Active` with all expected nodes.

## What goes wrong (and how to recover)

### "Registration command ran but rke2-server never starts"

Check `journalctl -u rancher-system-agent`. Most common cause is the agent
can't reach Rancher (firewall, DNS, cert issue). Confirm:

```bash
curl --insecure -v https://rancher.example.com/ping
```

### "rke2-server starts but the node never reaches Ready"

Check `journalctl -u rke2-server`. Common causes:

- **DNS or routing broken to the Kemp VIP** — node can't reach `<cluster>.<base>:9345` for join. Test with `nc -zv <cluster>.<base> 9345`.
- **Token mismatch** — registration command was for a different cluster. Generate a fresh token in Rancher UI; run the new command.
- **Pod CIDR collision** — Cilium fails to set up routing because pod CIDR overlaps with something on the host. Check `ip route` on the node.

### "Need to back out a registration"

```bash
sudo /usr/local/bin/rke2-uninstall.sh   # for tar-installed
# or
sudo /usr/bin/rke2-uninstall.sh         # for rpm-installed (shouldn't happen with this design)
```

This stops services, removes the binary, and cleans `/var/lib/rancher/rke2/`.
Then `rm -rf /etc/rancher/rke2/config.yaml.d/50-rancher.yaml` to remove the
Rancher-side drop-in. Puppet's `00-puppet.yaml` stays.

In Rancher UI, delete the node from the cluster (*Cluster Management → cluster
→ Nodes → ... → Delete*).

After cleanup, the node is back to "Foreman+Puppet ready, waiting for
registration." You can re-run the registration command.

### "Need to back out the entire cluster"

```bash
# On every node:
sudo /usr/local/bin/rke2-uninstall.sh
sudo rm -rf /etc/rancher/rke2/config.yaml.d/50-rancher.yaml

# In Rancher UI:
# Cluster Management → Clusters → ... → Delete
```

DNS and Kemp VIP can stay in place — they'll be reused when you rebuild.

## When to use this runbook vs. the script

| Situation | Use |
|---|---|
| Initial cluster build (greenfield) | Script |
| Adding more agent nodes to an existing cluster | Script |
| Future new cluster (gpu-2 mirror, etc.) | Script |
| Single-node replacement after a failure | Either; manual is faster for one node |
| Bastion is unavailable | Manual |
| Rancher API token expired/rotated mid-build | Manual until token is updated |
| Debugging "the script ran but cluster didn't form" | Manual, to verify each step independently |
| Production change-window with formal review | Manual is sometimes preferred for paper-trail reasons |
