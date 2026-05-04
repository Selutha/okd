# Portworx CSI for FA/FB — Install Notes

Working notes captured during the storage CSI buildout. Once this is finished,
the relevant operational steps fold into:
- `src/ufrc_rke2/README.md` (Puppet module README)
- `src/bootstrap-cluster/manual-bootstrap-runbook.md`
- A new `src/kub-mgmt/portworx-*.yaml` for the cluster-side install

Treat this file as scratchpad, not authoritative docs.

## Decision recap

- **Driver:** Portworx CSI for FA/FB (free tier, included with Evergreen / PaaS subscription).
- **Activation:** Self-licenses when the `pure.json` Kubernetes secret with valid FA creds is present. No portal registration. Verified at install time via Portworx operator logs.
- **Transport:** NVMe-oF over TCP (NOT RoCE). RoCE NICs live on the ESXi hypervisors; K8s nodes are guest VMs and can't naturally see RDMA hardware. Forcing RoCE into guests requires SR-IOV/DPIO (kills vMotion) or PVRDMA (VMware-specific paravirt) — both add complexity and lock-in. NVMe/TCP runs over standard guest VMXNET3 NICs, requires zero hypervisor-side configuration, is the most portable transport (works identically on Proxmox/KVM/bare-metal), and is supported on Purity 6.4.2+ (we're on 6.9.2). Latency tradeoff (~50-100µs TCP vs ~10-20µs RoCE) is irrelevant for K8s database workloads. All three transports (FC, RoCE, TCP) can run concurrently on the array — ESXi keeps using RoCE for its datastores; K8s gets its own NVMe/TCP path.
- **What this CSI does:** provisions Direct Access (FADA) volumes — real per-PVC array volumes with array-native snapshots/clones.
- **What it does NOT do:** PX-Replication, PX-Backup BaaS, async DR, KubeVirt features. None needed for mgmt cluster.

## Section 1: Host node prereqs

### Architectural reality: K8s nodes are guests on ESXi

The ESXi hypervisors hold the RoCE NICs. K8s nodes are guest VMs — they can't see the host's RDMA hardware without explicit passthrough (SR-IOV/DPIO) or paravirtualization (PVRDMA), both of which:
- Require hypervisor-side config the virt team has to maintain
- Either kill vMotion (DPIO/SR-IOV) or carry performance overhead and VMware-specificity (PVRDMA)
- Add VMware lock-in — counter to the user's portability goals

**Decision: use NVMe/TCP instead.** Purity 6.9.2 supports it; all three transports (FC/RoCE/TCP) can run concurrently on the array; NVMe/TCP runs natively over standard guest VMXNET3 NICs with no hypervisor-side setup. Latency tradeoff is negligible for the workloads this cluster runs.

**Storage-team prerequisite:** enable the NVMe/TCP service on the FlashArray and ensure the K8s VM network has IP-routable access to the array's NVMe/TCP listener IPs. Open question for user: do the K8s nodes need a new vNIC on a storage-network portgroup, or does the existing portgroup already route to the FA data plane?

### Inventory of what each RKE2 node needs (NVMe/TCP)

**Kernel modules (load at boot):**
- `nvme-fabrics` — generic NVMe-oF transport framework
- `nvme-tcp` — NVMe-oF over TCP transport
- (No `nvme-rdma`, no RDMA stack — guest doesn't see the RoCE hardware)

**Packages (RHEL 9 / Alma 9 / Rocky 9):**
- `nvme-cli` — userspace nvme tool
- `device-mapper-multipath` — DM-multipath stack
- (No `rdma-core`, no `infiniband-diags` — not needed for TCP)

**Configuration files:**
- `/etc/nvme/hostnqn` — unique-per-node NQN. Format `nqn.2014-08.org.nvmexpress:uuid:<UUID>`. Generated once via `nvme gen-hostnqn`, then persisted.
- `/etc/nvme/hostid` — unique-per-node host ID. UUID format. Same generate-once-persist semantics.
- `/etc/multipath.conf` — DM-multipath config tuned for Pure FA volumes. **Owned by the existing site multipath module**, NOT this new module — we just declare a dependency.
- `/etc/modprobe.d/disable-nvme-native-multipath.conf` — `options nvme_core multipath=N` to disable native NVMe multipath. Portworx requires DM-multipath, not native.

**Services:**
- `multipathd` — enabled and running (managed by the existing multipath module).
- No persistent `nvme connect` at boot — Portworx Operator handles connection lifecycle per PVC at provision time.

**Firewall:**
- NVMe/TCP listener uses TCP port 4420 (default). The connection is *outbound* from the K8s node to the FA, so no inbound firewall rule needed on the K8s node. Confirm storage-network firewalling is set so the K8s node CIDR can reach the FA's NVMe/TCP listener IPs on 4420.

**Reboot triggers:**
- Disabling native NVMe multipath (`nvme_core.multipath=N`) is a module load-time option. User confirmed manual reboot during maintenance — module drops the file, Puppet README documents the reboot requirement, sysadmin reboots when scheduled.

### Architecture decisions (locked in)

1. **Separate puppet module**, not folded into `ufrc_rke2`. NVMe/TCP host prereqs are storage-fabric glue, not cluster-runtime. Reusable across DR/infra/GPU clusters and any future non-K8s host that needs FA access.
   - Working name: `ufrc_pure_nvmeof` (revisit naming before publishing).

2. **Multipath config** is owned by the existing site multipath puppet module. This new module declares the dependency (e.g., requires `device-mapper-multipath` package and `multipathd` service to be present and running) but does not write `/etc/multipath.conf`. The site multipath module needs FA-NVMe-tuned content added to it — separate work item, tracked in the site repo.

3. **Reboots** are operator-driven during maintenance windows. Puppet drops the `nvme_core.multipath=N` modprobe file; module README and bootstrap runbook document the reboot requirement.

### Still-open architecture questions

1. **Hostnqn/hostid generation strategy?**
   - Need: unique-per-node, must persist across runs (regenerating would break FA host group membership).
   - Options:
     - (a) Puppet `exec` with `creates => /etc/nvme/hostnqn`, runs `nvme gen-hostnqn` once. Simple but hides the value from Puppet's view.
     - (b) Custom fact that generates if missing, file resource that pins via `replace => false`. Idempotent, value visible in facts (useful for FA host group provisioning).
     - (c) Foreman host parameter. Explicit, auditable, but requires per-host config.
   - **Lean toward (b)** — fact-driven, no per-host config burden, but exposes the NQN/hostid as facts so you can pull them into the FA host group provisioning workflow (e.g., a script that reads node facts via PuppetDB and writes them to the array's host group).

2. **`manage_firewalld` parameter pattern.** Carry the same Boolean pattern as `ufrc_rke2`, default false? Or skip entirely since NVMe/TCP is outbound-only?
   - Lean: skip the parameter; document outbound-only nature in README.

3. **Network reachability.** Do K8s VM portgroups already route to the FA's NVMe/TCP listener subnet, or do nodes need a new vNIC? **Storage-team / virt-team question, not a Puppet question, but blocks the install.**
