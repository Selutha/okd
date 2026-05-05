# Vault Self-Hosting Decision

**Status:** in-progress decision doc, parallel track to mgmt cluster build
**Last updated:** 2026-05-01

This doc captures the decision to self-host HashiCorp Vault on dedicated
VMware VMs, the use cases that justify it, and the open questions that
still need to be answered before stand-up.

This is a **separate track** from the mgmt cluster build. cert-manager on
the mgmt cluster does NOT block on Vault — it ships first with a
self-signed cluster CA and graduates to Vault PKI later.

---

## Why self-host (not use campus Vault)

The campus Vault has a confirmed **10s latency on every request**, not
just first-request-after-idle. Campus IT has declined to investigate.

This is disqualifying for HPC workloads:

- Slurm prolog/epilog scripts that fetch DB creds add 10s × every job
- Job array starts that hammer Vault simultaneously serialize on the lag
- Connection-pool warmup in long-running services becomes painful
- Any synchronous "fetch a secret on the request hot path" pattern is dead

Self-hosted Vault on the same network typically runs sub-100ms for secret
reads. That's the gap we're closing.

## Topology

**5 dedicated VMware VMs**, NOT in the mgmt cluster.

Reasoning:
- VMware VMs are cheap in this environment (existing infra, easy to provision)
- Independent failure domain from K8s — cluster outage doesn't take Vault
  down, Vault outage doesn't take cluster recovery down
- Vault is going to serve a fleet of clusters, scripts, DBs, and possibly
  customer-facing services — its blast radius is wider than any one
  cluster
- In-cluster Vault would create chicken-and-egg if Vault issues the
  cluster's own certs (cluster outage = no cert renewal to recover with)
- Operational mental model is simpler: "Vault is over there, K8s is over here"

5 nodes (vs 3) chosen because:
- Customer-facing services are on the table — outage SLO matters
- Tolerates 2 simultaneous failures vs 1 on a 3-node cluster
- Raft quorum cost is negligible at this size

Storage: **Raft integrated storage** (no Consul backend — Consul is no
longer the recommended backend since Vault 1.4).

## Use cases

In rough order of priority:

1. **Script and database password retrieval** — primary pain driver.
   Replaces the campus Vault for everything currently blocked on the 10s
   lag.
2. **Dynamic database credentials** — the genuinely compelling Vault
   feature for HPC. Scripts request short-lived per-invocation DB users
   instead of holding static passwords. Audit log shows exactly which
   script/job got which creds when. Eliminates static password rotation
   entirely.
3. **Internal mTLS / service-to-service certs across the fleet** —
   free incremental value once Vault is up. Vault PKI issues short-lived
   certs to internal services that need to authenticate each other.
   Does NOT replace the wildcard-cert flow for user-facing UIs — those
   stay on the `*.rc.ufl.edu` wildcard (Phase 1 manual, Phase 2 ACME via
   cert-manager).
4. **Customer-facing service secrets** (under investigation) — API
   tokens, OAuth client secrets, etc. (TLS for researcher portals is
   handled by the wildcard at Kemp, not Vault.) This use case raises
   the availability bar (login outage if Vault goes down) and pushes
   the topology toward 5 nodes + auto-unseal mandatory.

## Auth methods (planned)

- **LDAP or OIDC** for human operators (tied to AD — AD is used for
  authentication only; AD-CS is not used for cert issuance)
- **kubernetes auth method** for in-cluster pods (each cluster registered
  as a separate auth backend via its ServiceAccount issuer URL)
- **AppRole** for scripts and cron jobs that aren't running in K8s
- **TLS cert auth** as a fallback for bootstrapping

## Auto-unseal — open question

This is the single biggest unresolved decision before stand-up.

A process cannot start with a secret it doesn't have access to. So the
unseal key has to live somewhere. The chain has to terminate at one of:

| Method | Viability | Notes |
|---|---|---|
| Cloud KMS (AWS/Azure/GCP) | N/A | On-prem only; no cloud account in scope |
| **HSM via PKCS#11** | TBD — depends on campus | Best answer if available |
| **Transit unseal off campus Vault** | Viable | Clever — unseal is once-per-restart, 10s lag is irrelevant |
| YubiHSM 2 pair | Viable, ~$1300 | Real hardware, fits HPC budgets |
| Manual Shamir | Last resort | 3-of-5 humans entering shares per restart — operationally painful |

### Recommended evaluation order

1. **Ask campus IT if there's an institutional HSM** (Thales Luna network
   HSM is common at research universities). If yes, request PKCS#11 access
   for a Vault deployment. Free-ish to consume, professionally operated.
2. **If no institutional HSM**: ask if transit-unseal off the campus Vault
   is acceptable. We're already authorized to use it; unseal is rare
   enough that 10s latency doesn't matter.
3. **If neither**: budget for two YubiHSM 2 devices (~$1300). Real
   hardware, open ecosystem, kept in two physically separate locations.
4. **Shamir is a last resort.** Do not plan around it.

### Recovery key (separate from unseal key)

Regardless of which auto-unseal method is picked, **at Vault init we
generate a recovery key** as 5 Shamir shares with threshold 3. These get
distributed to 5 different humans in 5 different locations.

This is the true-disaster recovery path: HSM destroyed, transit Vault
gone, all auto-unseal infrastructure unavailable. Recovery key shares are
collected, root token regenerated, cluster brought back to a re-seal
configuration pointing at whatever new unseal mechanism is set up.

Auto-unseal does not eliminate Shamir; it just demotes it from
"every-restart" to "true-disaster-only."

## Sequencing relative to other work

**Vault is NOT on the critical path for the mgmt cluster build.** The
mgmt cluster's user-facing TLS uses the `*.rc.ufl.edu` wildcard cert
(Phase 1 static Secret, Phase 2 ACME-renewed via cert-manager). Vault PKI
serves a different use case: internal service-to-service mTLS, which the
mgmt cluster does not need yet.

Order of operations:

1. Mgmt cluster build continues on its track (Cilium L2 → wildcard Secret
   → first Gateway → Rancher)
2. Cert provider migration completes → cert-manager + ACME for wildcard
   auto-renewal (Phase 2 of the cert plan, parallel track)
3. Vault decision doc (this file) iterates in parallel
4. Once unseal mechanism is settled, stand up 5 VMs, install Vault,
   initialize, configure auth methods, migrate scripts/DBs off campus
   Vault
5. Once Vault is stable, internal mTLS use cases get wired in via Vault
   PKI on whichever clusters need it. User-facing UIs stay on the
   wildcard.

## Open questions

Tracked questions to answer before stand-up:

- [ ] Validate campus 10s lag is constant, not config-fixable on their side
      (already confirmed by user — keeping for paper trail)
- [ ] Does campus IT have an institutional HSM accessible via PKCS#11?
- [ ] If no HSM, will campus accept transit-unseal off their Vault?
- [ ] Customer-facing use case — synchronous on hot path, or only at
      startup? Affects HA topology and SLO.
- [ ] AD integration: LDAP or OIDC? AD's OIDC story has improved with
      ADFS / Entra; LDAP is simpler but ages worse.
- [ ] Backup target for Raft snapshots (Qumulo S3 same as etcd snapshots?)
- [ ] Network policy: which subnets and which clusters need to reach Vault
      on 8200/tcp?

## Decisions locked in

- Self-host on 5 VMware VMs (not in mgmt cluster, not 3 nodes)
- Raft integrated storage (not Consul)
- OSS Vault initially; revisit Enterprise only if a feature gap appears
- Recovery key: 5 Shamir shares, threshold 3, distributed to 5 humans

## Decisions deferred

- Auto-unseal mechanism (depends on campus HSM availability)
- Auth method for humans (LDAP vs OIDC)
- Backup destination
- Whether customer-facing services use Vault on the request hot path
