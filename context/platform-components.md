# Platform Components — Reference Doc

**Status:** Living reference, not a design doc — v0.3
**Date:** 2026-04-24
**Changes since v0.2:** Expanded §12 (Helm) with §12.6 (Helm + ArgoCD: composition, not competition — including the production Application example and bootstrap pattern) and §12.7 (chart sourcing — vendor in git vs upstream reference vs Harbor mirror vs OCI charts; phased recommendation for the project).
**Changes since v0.1:** Added §11 — etcd vs Redis (consistency vs performance), §12 — Helm package-manager analogy, §13 — Kubernetes operators newcomers reinvent badly. Locked Valkey as the chosen cache (§4).
**Purpose:** A catch-all for the platform/infrastructure containers and concepts that show up across the design — databases, storage types, caches, message brokers, secrets management, object stores, and the Kubernetes-native operators that solve operational problems people new to k8s would otherwise solve manually. Things that get casually mentioned ("we'll use CloudNativePG," "Harbor on FlashBlade S3") without unpacking what they are or what the alternatives look like.

> Pairs with `general-notes.md` (which covers container stack layers, CRI/CNI/CSI, eBPF, etc.). This doc covers the workload/data layer; that one covers the runtime/network layer.

---

## Table of contents

1. [Storage types: block vs file vs object (S3) — the foundational distinction](#1-storage-types-block-vs-file-vs-object-s3)
2. [PostgreSQL vs CloudNativePG vs the operator landscape](#2-postgresql-vs-cloudnativepg-vs-the-operator-landscape)
3. [MySQL vs MariaDB — when each fits](#3-mysql-vs-mariadb)
4. [Redis vs Valkey vs KeyDB — caching and queues](#4-redis-vs-valkey-vs-keydb)
5. [Message brokers: Kafka, RabbitMQ, NATS](#5-message-brokers-kafka-rabbitmq-nats)
6. [Object storage: S3-compatible alternatives — MinIO, Pure FlashBlade, Ceph RGW](#6-object-storage-s3-compatible-alternatives)
7. [Secrets management: Vault, External Secrets Operator, Sealed Secrets](#7-secrets-management)
8. [Specialized databases worth knowing about](#8-specialized-databases-worth-knowing-about)
9. [Time-series, search, and observability backends](#9-time-series-search-and-observability-backends)
10. [Things people commonly miss when planning platform tiers](#10-things-people-commonly-miss)
11. [etcd vs Redis — both KV stores, opposite tradeoffs](#11-etcd-vs-redis--both-kv-stores-opposite-tradeoffs)
12. [Helm — the Kubernetes package manager](#12-helm--the-kubernetes-package-manager)
13. [Operators newcomers reinvent badly without realizing they exist](#13-operators-newcomers-reinvent-badly)
14. [Sources](#sources)

---

## 1. Storage types: block vs file vs object (S3)

These are the three foundational storage shapes. Most confusion in cluster design comes from picking the wrong one for a workload. **Each has different access semantics, performance profiles, and APIs.**

### 1.1 Block storage

**What it is:** raw disk presented over a protocol (iSCSI, NVMe-oF, FC, vSphere VMDK, AWS EBS). The host (or VM, or pod) sees it as a block device — `/dev/sdb`, `/dev/nvme0n1` — formats it with a filesystem (xfs, ext4), and mounts it. **Exclusive access** — only one host attaches a block volume at a time.

**Characteristics:**

- **Lowest-latency, highest-IOPS** option for transactional workloads
- **Read-Write-Once (RWO)** in Kubernetes terms — one pod attaches, others can't access concurrently
- Filesystem semantics (POSIX) — fopen, fseek, fsync, etc.
- Capacity is preallocated (or thin-provisioned at the storage backend layer)
- The pod sees a block device; the **content is whatever filesystem you put on it**

**Use cases:**

- Database storage (Postgres, MySQL, etcd) — needs low fsync latency, exclusive access
- VM disks (KubeVirt) — VMs expect block devices
- Application caches that survive pod restarts
- Anything that says "give me a real disk"

**In your stack:** `pure-csi` block class on FlashArray. Used for CloudNativePG, Redis, Harbor's metadata Postgres, monitoring Prometheus PVs. Sub-millisecond latency.

### 1.2 File storage

**What it is:** a shared filesystem accessed over a network protocol (NFS, CIFS/SMB, Lustre). Multiple hosts can mount the same filesystem concurrently. **Shared access**, with locking semantics for coordination.

**Characteristics:**

- **Read-Write-Many (RWX)** in Kubernetes terms — multiple pods can mount, read, write concurrently
- POSIX file semantics — same mental model as block, but with shared visibility
- Performance varies wildly by protocol: NFS is general-purpose, **Lustre is parallel-FS designed for HPC** (much higher throughput on parallel reads)
- Locking can be tricky — applications need to handle "what if another writer modifies the file"

**Use cases:**

- Shared application data — multiple pods reading the same configuration or content
- HPC scratch / training data (Lustre territory)
- Image registries that serve via NFS (less common now; Harbor uses S3 instead)
- "We need a shared filesystem visible from multiple nodes"

**In your stack:** **DDN Lustre** for the GPU cluster's HPC training data / scratch. **FlashBlade NFS** could be used for general RWX needs but isn't planned because the workloads don't really need it.

### 1.3 Object storage (S3)

**What it is:** key/value HTTP API for storing **whole objects** (typically files, but conceptually opaque blobs). You PUT an object, GET it back later by name. **No filesystem** — you can't `fseek` into an S3 object, can't append, can't open-for-read-and-write.

**The S3 protocol (originally AWS, now an industry standard) is the dominant API.** Many vendors (Pure FlashBlade, MinIO, Ceph RadosGW) expose S3-compatible APIs.

**Characteristics:**

- **No POSIX semantics** — no directories (just key prefixes), no mtime guarantees, no atomic rename, no append
- **Eventual consistency** historically (modern S3 is strong-consistency now)
- **Effectively infinite scale** — billions of objects, petabytes
- **HTTP-based** — works across any network, no special protocol
- **Cheap per-GB** — designed for "store lots, read occasionally"
- Versioning, lifecycle policies (auto-tier to cold, auto-delete after N days), bucket-level encryption built-in

**Use cases:**

- Container image storage (Harbor, Quay, ECR all use S3 backends)
- Backup destinations (Postgres barman, etcd snapshots, Velero)
- Long-term log archive
- Data lakes, ML training datasets (read-mostly large blobs)
- Anywhere you'd previously have used "a folder full of files" but at scale

**Critically:** *block and S3 are complementary, not interchangeable.* Postgres can't run on S3 (needs POSIX, low-latency fsync). Container image data shouldn't run on block (doesn't need POSIX, wants infinite scale + cheap storage + HTTP API).

**In your stack:** **Pure FlashBlade S3** for Harbor image data (multi-TB at full deployment), CloudNativePG barman backups, Loki log archive, possibly Velero backups.

### 1.4 Quick decision matrix

| Need | Use |
|---|---|
| Database storage (Postgres, MySQL, etcd) | **Block** (fast, RWO) |
| VM disk image (KubeVirt) | **Block** |
| Single-pod app PV with file semantics | **Block** |
| Multi-pod shared filesystem | **File** (NFS for general; Lustre for HPC parallel) |
| Container images, registry storage | **Object (S3)** |
| Backups (DB dumps, etcd snapshots, log archive) | **Object (S3)** |
| ML training datasets, large read-mostly blobs | **Object (S3)** or **Lustre** for parallel access |
| Application logs (real-time) | **Block** (Loki ingestion) → archived to **Object (S3)** for retention |

### 1.5 Why "S3" became a generic term

S3 is technically AWS's specific service, but its HTTP API (PUT, GET, DELETE, LIST on buckets and keys with signed-URL auth) became the de-facto standard for object storage. Today, "S3-compatible" means a server that speaks the same API — your applications can talk to MinIO, Ceph RGW, or Pure FlashBlade S3 with the same SDKs they'd use against AWS S3.

Pure FlashBlade S3 is **on-prem object storage that speaks the S3 API**. Same protocol, your data center, your network. No AWS involved.

---

## 2. PostgreSQL vs CloudNativePG vs the operator landscape

This came up in the design when I kept saying "CloudNativePG" — worth unpacking.

### 2.1 What "PostgreSQL" actually is

The database engine — a Unix process that listens on a socket, speaks the Postgres wire protocol, persists data to disk via a write-ahead log (WAL) plus heap files. Released as a single source tree by the PostgreSQL Global Development Group (PGDG); same engine whether you install it on RHEL with `dnf install postgresql`, run it in Docker, or deploy it via Helm.

A vanilla Postgres deployment (one container, one process) gives you a working database. **It does not give you HA, automatic failover, scheduled backups, point-in-time-recovery (PITR), monitoring integration, certificate rotation, replica scaling, or rolling upgrades.** Those are operational concerns above the engine.

### 2.2 What an operator adds

A Kubernetes operator is a controller that knows how to operate a stateful service. For Postgres, that means turning "I want a 3-node HA Postgres cluster with WAL archiving and PITR" into actual reconciled state — pods, PVCs, services, secrets, certificates, the works.

The operator turns a CRD like:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-postgres
spec:
  instances: 3
  storage:
    size: 50Gi
    storageClass: pure-block
  backup:
    barmanObjectStore:
      destinationPath: s3://flashblade/barman/
      s3Credentials:
        accessKeyId: { name: backup-creds, key: access }
        secretAccessKey: { name: backup-creds, key: secret }
```

into: 3 stateful Postgres pods with replication, WAL streaming to S3, automated failover when the primary dies, certificate rotation, scheduled base backups, point-in-time recovery, and monitoring metrics — all without you writing the ops glue.

### 2.3 The Postgres operator landscape

| Operator | Maintainer | Status | Notable |
|---|---|---|---|
| **CloudNativePG (CNPG)** | Originally EnterpriseDB; now CNCF Sandbox (2025) | Production-grade, fast-growing adoption | Native barman integration for backups; modern Kubernetes-idiomatic CRDs; what we picked |
| **Zalando Postgres Operator** | Zalando | Production-grade, well-established | First major Postgres operator; uses Patroni internally; battle-tested at scale |
| **Crunchy Data PGO** | Crunchy Data (commercial) | Production-grade, paid support available | Mature; commercial support model |
| **StackGres** | OnGres | Production-grade | Bundles connection pooler (PgBouncer), monitoring (Prometheus), HA (Patroni) automatically |
| **Percona Operator for PostgreSQL** | Percona (commercial) | Production-grade | Percona's distribution; backed by their consulting/support business |

For your stack, **CloudNativePG is the right pick because:**

- CNCF Sandbox project (vendor-neutral governance)
- 132M+ downloads, mature
- Native barman → S3 backup model fits your FlashBlade S3 perfectly
- Multi-database within a single cluster (you can host keycloak, harbor, sonarqube DBs in one CNPG cluster — done in your design)
- Modern Kubernetes-idiomatic CRDs (no Patroni indirection)

### 2.4 The vanilla-Postgres-in-a-container alternative

You *could* run a single Postgres pod via a Helm chart (e.g., the Bitnami chart) without an operator. **For dev, fine. For production, no.** You'd be reinventing what the operator does:

- HA → set up replication manually, monitor primary, fail over by hand
- Backups → schedule a CronJob with `pg_dump`, push to S3, hope it doesn't run during peak load
- Restores → manually find the right dump, import, hope WAL hasn't drifted
- Upgrades → take downtime, manually swap container, hope nothing breaks
- Cert rotation → manually

The operator is the difference between "Postgres in production" and "Postgres on a hobby cluster."

### 2.5 When NOT to use Postgres on Kubernetes

Sometimes a managed cloud Postgres or a dedicated VM Postgres is the better answer:

- **Extreme transaction rates** — when the workload would saturate even Pure FlashArray's IOPS
- **Strict regulatory requirement** for specific deployment shapes
- **Existing org Postgres-as-a-Service** that you can plug into instead
- **Simplicity for low-stakes use cases** — a single VM with hourly snapshots is sometimes enough

For your design, the platform-tier databases (Keycloak, Harbor, SonarQube) are modest workloads — few writes, mostly cached reads. CNPG on Pure FlashArray block PVs is overkill on capability, perfectly sized on cost.

---

## 3. MySQL vs MariaDB

These are siblings, not rivals at the engine level. They share most of the codebase, the wire protocol, and the SQL dialect. The difference is governance and feature drift.

| | MySQL | MariaDB |
|---|---|---|
| Origin | Original; written by MySQL AB, acquired by Sun (2008), then Oracle (2010) | Forked from MySQL by the original author (Monty Widenius) in 2009 after Oracle acquisition |
| Maintainer | Oracle | MariaDB Foundation (open governance) + MariaDB Corporation (commercial) |
| License | GPL (Community) + commercial (Enterprise) | GPL throughout |
| Wire protocol compatibility | Self | **Drop-in compatible with MySQL clients** (mostly) |
| Feature drift | Oracle-driven roadmap; some features Enterprise-only | Community-driven; some unique features (Galera cluster built-in, columnar engine) |
| Default in RHEL 9 | MariaDB (Red Hat ships MariaDB as `mysql` package) | yes |
| Default in Ubuntu 22.04+ | MySQL | (also packaged) |
| Storage engines | InnoDB (transactional, default), MyISAM (legacy) | InnoDB + Aria (improved MyISAM) + ColumnStore (analytics) |

### 3.1 Practical guidance

**Pick MariaDB if:**

- You're on RHEL/Rocky (Red Hat ships it as the default `mysql` package)
- You want fully-open governance (no Oracle-controlled roadmap)
- You need built-in Galera multi-master clustering
- You're starting fresh with no existing MySQL investment

**Pick MySQL if:**

- You have existing MySQL workloads / MySQL DBA expertise
- You need a specific MySQL Enterprise feature (Group Replication, MySQL Shell with AdminAPI)
- Your stack already standardizes on MySQL

**For most new platform-tier deployments,** MariaDB on RHEL is the pragmatic choice. But honestly: **for your stack, prefer Postgres.** Postgres has a stronger feature set (better JSON, partial indexes, more SQL standard compliance, better isolation levels) and CloudNativePG is more mature than the MySQL/MariaDB operator landscape.

The major MySQL/MariaDB Kubernetes operators worth knowing: Oracle's [MySQL Operator for Kubernetes](https://github.com/mysql/mysql-operator), [Percona Operator for MySQL](https://docs.percona.com/percona-operator-for-mysql/), [MariaDB Operator (mariadb-operator)](https://github.com/mariadb-operator/mariadb-operator). All credible, none as ergonomic as CNPG for Postgres.

---

## 4. Redis vs Valkey vs KeyDB

In-memory key/value stores. Used as caches, session stores, message queues (limited), pub/sub. Same protocol, different licenses and governance.

### 4.1 The fork story

**Redis** was the original — open-source, BSD-licensed, dominant in the cache space for over a decade. In **March 2024**, Redis Labs (the corporate sponsor) changed Redis 7.4+ from BSD-3-Clause to a dual RSALv2 / SSPLv1 license, ending its OSS status by the OSI definition. (Redis 7.2.x and earlier remain BSD-licensed; the change is not retroactive.)

This triggered immediate forks:

- **Valkey** — Linux Foundation-backed fork announced March 28, 2024, sponsored by AWS, Google Cloud, Oracle, Ericsson, and Snap. **BSD-3-Clause licensed**, drop-in protocol-compatible (forked from Redis 7.2.4). Now the de-facto OSS Redis successor.
- **KeyDB** — older fork (pre-license-change), multi-threaded redesign of Redis. Different from Valkey but similar protocol compatibility. Now owned by Snap; less community momentum than Valkey.

**Redis ecosystem update worth knowing:** Redis 8 (released later in 2025) added AGPLv3 as a third option, making Redis 8+ tri-licensed under RSALv2 / SSPLv1 / AGPLv3. AGPLv3 is OSI-approved, so Redis 8+ is technically OSS again under that license option — though most cloud-native shops have already standardized on Valkey. **For new deployments**, Valkey remains the cleaner choice (single license, no need to navigate the tri-license + the "but only if you choose AGPL" caveat).

### 4.2 What you actually use it for

- **Session caching** — Harbor uses it for session/token state. Most web apps use Redis-style caches.
- **Job queues** — Sidekiq, GitLab uses Redis for background job queues. CI/CD platforms.
- **Pub/sub** — lightweight message passing within a single app.
- **Distributed locks** — lock state shared across pods.

### 4.3 For your stack — Valkey locked in

**Decision:** Valkey, not Redis. BSD-3-Clause-licensed, Linux Foundation-backed, drop-in protocol-compatible with Redis. Same Helm-deploy pattern (Bitnami valkey chart, or the official Valkey chart), single-instance topology for Harbor's session/cache needs, scales to a primary+replica pair if/when needed.

Reason: Redis's 2024 license change (BSD → SSPL/RSAL) makes new deployments operationally awkward — you're either accepting a non-OSS license for a critical infrastructure component or eventually migrating anyway. Valkey is what the cloud-native community standardized on after the fork, has the major sponsors (AWS, Google, Oracle, Ericsson, etc.), and the protocol compatibility is bit-exact. There's no operational downside to picking Valkey day 1.

---

## 5. Message brokers: Kafka, RabbitMQ, NATS

For the design, none of these are planned. Worth knowing because they show up in adjacent architectures.

| | **Apache Kafka** | **RabbitMQ** | **NATS** |
|---|---|---|---|
| Style | Distributed log (append-only stream) | Message queue (broker-routed, ack/retry) | Pub/sub + queue, lightweight |
| Persistence | Strong (disk-backed log, configurable retention) | Configurable (memory or disk queues) | NATS core: in-memory; NATS JetStream: persistent |
| Throughput | Very high (millions/sec) | Moderate (tens of thousands/sec) | Very high for pub/sub; lower for guaranteed-delivery |
| Operational complexity | High (Zookeeper or KRaft, partitioning, replication factor) | Moderate | **Low — single binary** |
| Use case fit | Event streaming, log aggregation, analytics pipelines | Traditional message queue (work distribution, RPC-style) | Microservices messaging, IoT, edge |

For an HPC center: probably none day-1. **NATS** is the lightest option if you ever need lightweight pub/sub between services. **Kafka** is heavy for anything other than serious event-stream workloads.

The Kubernetes operators worth knowing: [Strimzi](https://strimzi.io/) for Kafka (CNCF Incubating, very mature), [RabbitMQ Cluster Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview), [NATS Operator](https://github.com/nats-io/nats-operator).

---

## 6. Object storage: S3-compatible alternatives

You've got Pure FlashBlade S3 in the design — it's the obvious answer because you already have FlashBlade. But it's worth knowing the landscape because S3-compatible object storage is everywhere now.

| | **Pure FlashBlade S3** | **MinIO** | **Ceph RadosGW** | **AWS S3** |
|---|---|---|---|---|
| Type | Hardware appliance | Software-defined; runs on commodity hardware | Software-defined; runs as Ceph component | Public cloud SaaS |
| License | Commercial | Open source (AGPL) + commercial | LGPL | Commercial |
| Operational complexity | Low — vendor manages | Moderate — you operate it | High — Ceph is its own beast | None — fully managed |
| Performance | Excellent (NVMe-backed, RoCE) | Depends on underlying hardware | Depends on Ceph cluster sizing | Variable |
| Best fit | Have FlashBlade; want zero-operations object storage | Want self-hosted S3 on commodity disks; small to medium scale | Already operate Ceph for block/file; want object too | Don't run on-prem |

### 6.1 MinIO worth knowing about

If you didn't have FlashBlade, **MinIO** would be the obvious self-hosted alternative. Single Go binary, S3-compatible API, runs on any RHEL VM with disks attached. Stateful — distributes data across multiple nodes for HA. Common in air-gapped deployments where AWS S3 isn't reachable.

You don't need it because you have FlashBlade. But mentioning so that if FlashBlade is ever capacity-constrained for some reason, you know there's a "spin up MinIO on a few VMs with local NVMe" option that doesn't require buying more storage.

### 6.2 Ceph as object storage (via RGW)

**OpenShift Data Foundation (ODF)** — which we discussed in the OKD context — is essentially Ceph + Rook + NooBaa packaged for OpenShift. Ceph's RadosGW (RGW) component speaks S3 API. If you ever ended up running Ceph (you're not), you'd get block + file + object from the same cluster. Heavy operationally; not appropriate for a stack where Pure already covers block/file and FlashBlade covers object.

---

## 7. Secrets management

Your design hasn't locked this down (G-7 in the OKD doc). Three patterns to know:

### 7.1 HashiCorp Vault

**The gold standard.** Server cluster (3+ nodes), API for secrets retrieval, dynamic secrets generation (auto-rotating DB credentials, AWS STS tokens, etc.), policy engine, audit log, KV store, transit encryption. Battle-tested at enterprise scale.

**Operationally heavy** — Vault is its own platform with HA, unsealing ceremony, secret backups, etc. The reward for the complexity is the most flexible secrets solution available.

Self-hostable on Kubernetes via the [Vault Helm chart](https://github.com/hashicorp/vault-helm) (Raft-based HA storage backend). Or run on dedicated VMs.

**License watch:** HashiCorp moved Vault (and Terraform, Nomad, Consul) from MPL 2.0 to the Business Source License (BUSL/BSL v1.1) in **August 2023**. The community forked Vault as **OpenBao** (Linux Foundation, MPL-2.0). Functionally equivalent; the Vault protocol is unchanged. (Note: IBM completed its acquisition of HashiCorp in early 2025; future license direction is for IBM to determine.)

### 7.2 External Secrets Operator (ESO)

**Bridges Kubernetes Secrets to external secret stores** (Vault, AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, 1Password, etc.). You define an `ExternalSecret` CRD pointing at a key in Vault; ESO syncs it into a native Kubernetes Secret automatically.

**Use case:** "secrets live in Vault; pods consume them as standard Kubernetes Secrets without each pod knowing about Vault." Decouples application code from the secrets backend.

Strong fit when you have Vault (or equivalent external store).

### 7.3 Sealed Secrets (Bitnami)

**Encrypted secrets in git.** A controller (`sealed-secrets-controller`) generates a cluster-specific key pair. You encrypt a Kubernetes Secret YAML with the controller's public key, commit the encrypted result to git. The controller decrypts at deploy time.

**Pros:** secrets live in git alongside your manifests, GitOps-friendly, no external dependency.
**Cons:** key-rotation is annoying; encrypted secrets are tied to the specific cluster; doesn't work cross-cluster without complications.

**Lightest option day-1.** Pairs naturally with ArgoCD. Many teams start here and migrate to Vault as scale grows.

### 7.4 For your stack — recommendation

**Day 1:** Sealed Secrets via ArgoCD. Lightweight, GitOps-native.

**Day 90+:** Vault (or OpenBao) on dedicated VMs or in-cluster (probably mgmt cluster, alongside the rest of the platform tier), External Secrets Operator on each workload cluster pulling from Vault. Migrate sealed secrets to Vault-backed external secrets gradually.

This is consistent with the "build minimum, expand as scale demands" pattern throughout the design.

---

## 8. Specialized databases worth knowing about

These come up when workloads have specific shapes that Postgres/MySQL aren't ideal for. You're unlikely to need most of them, but knowing they exist saves you from forcing the wrong tool.

### 8.1 MongoDB

Document-oriented (JSON-ish documents instead of rows). Used for "schema-flexible" workloads. License changed to SSPL in 2018, so technically not OSS anymore. **AGPL fork:** [FerretDB](https://www.ferretdb.io/) (which translates Mongo wire protocol to Postgres underneath — interesting but young).

**For your stack:** unlikely to need it. Postgres's `jsonb` column type covers most "schema-flexible" needs.

### 8.2 etcd as an application database

Distributed key/value store. Kubernetes uses it as its own state backend. Some applications use it for distributed coordination (leader election, config). **Don't use it as a general-purpose database** — it's not designed for high-volume reads/writes. For coordination, fine; for app data, no.

### 8.3 ClickHouse

Columnar OLAP database. Insanely fast for analytical queries over large datasets (billions of rows, aggregations, time-series). Used for log analytics, observability, ad-tech.

**For your stack:** worth knowing in case you ever need analytics over GPU job logs or infrastructure metrics at scale. The [Altinity ClickHouse Operator](https://github.com/Altinity/clickhouse-operator) is the production-grade Kubernetes path.

### 8.4 TimescaleDB

PostgreSQL extension that adds time-series optimizations (automatic partitioning by time, compression, continuous aggregates). **Runs as Postgres** — no separate engine.

**For your stack:** if monitoring/observability needs grow beyond Prometheus, TimescaleDB is a great target for long-term metric storage. Compatible with the CloudNativePG cluster you already have.

### 8.5 Cassandra / ScyllaDB

Wide-column distributed databases. Used for very-write-heavy workloads (clickstreams, IoT). Operationally heavy.

**For your stack:** unlikely to need.

---

## 9. Time-series, search, and observability backends

These show up in monitoring/logging stacks. You've got Prometheus + Loki in the design; here's the broader landscape.

### 9.1 Metrics — Prometheus and friends

- **Prometheus** — time-series database + scraper. The k8s standard. Pull-based, PromQL query language.
- **Thanos** — Prometheus federation. Run multiple Prometheus instances, query across all of them, long-term storage in S3. Use when you have many Prometheus instances or need long retention.
- **Mimir** (Grafana) — alternative to Thanos with a different design philosophy. Single global query view, horizontal scaling.
- **VictoriaMetrics** — Prometheus-compatible TSDB with better compression and performance. Lighter than Thanos/Mimir for many cases.

**For your stack:** kube-prometheus-stack (regular Prometheus per cluster) day 1. Federate to Thanos or Mimir if/when long-term retention becomes a real need.

### 9.2 Logs — Loki, Elastic, OpenSearch

- **Loki** (Grafana) — "Prometheus for logs." Indexes labels not full-text. Lightweight, cheap, integrates with Grafana. Backing store: filesystem, S3, BoltDB, etc.
- **Elasticsearch** — full-text indexing, powerful queries, expensive to run. Now under SSPL (license-restricted).
- **OpenSearch** — Amazon's Elasticsearch fork (Apache 2.0). Drop-in replacement for Elastic for most use cases.

**For your stack:** Loki + Grafana is the right answer. Elastic/OpenSearch only if you have specific full-text search requirements.

### 9.3 Distributed tracing

- **Jaeger** — CNCF, distributed tracing. Captures spans across services, visualizes request flow.
- **Tempo** (Grafana) — like Loki but for traces. Cheaper backing storage (S3).
- **OpenTelemetry** — the standard for instrumentation. Vendor-neutral. Both Jaeger and Tempo can ingest OpenTelemetry data.

**For your stack:** not day-1, but worth installing OpenTelemetry instrumentation in apps from the start so traces are available later.

---

## 10. Things people commonly miss

Components that get retrofitted painfully when overlooked early:

### 10.1 An NTP source

Cluster-wide time sync. Without it, etcd, kubelet certs, and federation all break in subtle ways. RHEL hosts default to chrony pointing at the org's stratum. **Confirm this works before bringing the cluster up.** Trivial to overlook.

### 10.2 A DNS strategy that handles ingress + service names

Workload services need DNS records (`*.apps.<cluster>.<base>` → ingress VIP). Manually adding records every time you deploy is operationally awful. ExternalDNS controller automates this — runs on the cluster, watches Service and Ingress resources, creates DNS records via the org's DNS API (BIND, AD DNS, infoblox, route53, etc.).

### 10.3 Cert-manager with an actual issuer configured

Cert-manager is in the design, but only useful if it's pointed at something — Let's Encrypt for public certs, or your org's internal CA (typically AD CS for Windows shops, or Vault PKI). Without an issuer, every workload needing TLS does it manually.

### 10.4 A backup story for stateful workloads in workload clusters

You've got CNPG barman, Harbor S3, RKE2 etcd snapshots, FlashArray snapshots — all good for the platform tier. But what about app-level data on the workload clusters? If an inference service writes state to a PV, what backs that up? Answer: **Velero** (most common k8s backup tool) + Pure CSI snapshots. Day-30+ but don't forget it.

### 10.5 Image pull secret management

Pulling from Harbor requires credentials. Each namespace needs a pull secret. Either: (a) use Harbor's per-project robot accounts and configure secrets per namespace via ArgoCD/Sealed Secrets, or (b) use a shared cluster-wide pull secret. Option (b) is simpler; option (a) is more secure.

### 10.6 Limit ranges and resource quotas

Without LimitRanges and ResourceQuotas in each namespace, a misbehaving pod can request 100 CPUs and break scheduling for everyone. Set sensible defaults at namespace creation; hard to add later without breaking existing workloads.

### 10.7 PodDisruptionBudgets

Already mentioned in the GPU upgrade section. Without PDBs, drains evict freely. Workloads with replicas should set `minAvailable: replicas - 1`.

### 10.8 Service accounts with intentional minimal RBAC

Default service account has no permissions, which is good. But every workload that needs to read its own ConfigMaps, watch other resources, or call the Kubernetes API needs a SA + RoleBinding. Audit periodically — privilege creep happens.

### 10.9 Image signing and admission policy *from the start*

Already in the design (Cosign + Kyverno). Reason it's listed here: shops that don't set this up day-1 typically never do, because retrofitting "now all images must be signed" against running workloads is painful. Day-1 is the time.

### 10.10 A break-glass admin account on every cluster, never federated

If Keycloak goes down and your cluster auth is OIDC-only, you can't log in. Every cluster should have a local admin (kubeconfig with cluster-admin, password vaulted) that bypasses Keycloak. Same for Rancher (the local admin we discussed). Boring but critical.

### 10.11 An out-of-band terminal path

When the cluster is broken in interesting ways, kubectl doesn't help. SSH to nodes via Puppet-managed keys + bastion. Document this. Test it before you need it.

### 10.12 A "small thing on every node" provisioning pattern

Foreman + Puppet handles host config, but the kind of "every node needs this DaemonSet" pattern (node-exporter, NVIDIA driver, Cilium agent, Lustre client) is owned by Kubernetes operators, not Puppet. Be clear about which goes where; don't let them fight.

---

## 11. etcd vs Redis — both KV stores, opposite tradeoffs

Both are key-value at the API surface, but the engineering tradeoffs are diametrically opposite. This is one of those questions where the surface-level similarity hides the deep difference.

| | **etcd** | **Redis / Valkey** |
|---|---|---|
| Consistency | **Strongly consistent** (Raft consensus across nodes — every read sees the same value) | **Eventually consistent** in cluster mode; per-node consistent in single-node |
| Persistence | **Always durable** (every write fsyncs) | Optional (in-memory by default; can persist via AOF/RDB) |
| Throughput | Modest (~10k writes/sec) — limited by Raft + fsync | Massive (millions of ops/sec) — limited by network |
| Latency | ~ms (Raft round-trip + fsync) | ~µs (RAM access) |
| Capacity | Small (~8 GB practical limit historically) | Huge (gigabytes to TB) |
| Watch / change-notify | **Built-in** (kubelet watches etcd this way) | Pub/sub on channels (different model) |
| Cluster size | 3 or 5 nodes (must be odd; quorum) | Single, primary/replica, or sharded cluster |
| Designed for | **Distributed coordination, configuration, metadata** | **Caching, session storage, queues** |

### 11.1 The framing that makes it click

- **etcd's job:** "every node MUST agree on this value, even if it takes 10 ms to write." Use it when correctness > speed and the dataset is small.
- **Redis's job:** "this node has it cached, just give it to me fast." Use it when speed > strong consistency and the dataset can be large.

### 11.2 Why Kubernetes uses etcd, not Redis

If two controllers both ask "what is the desired state of pod X?" — they MUST get the same answer. If Redis cluster's eventual consistency gave them different answers, controller A would scale down while controller B was still scaling up — chaos. etcd's Raft ensures one consistent answer across all readers, always.

### 11.3 Why Harbor uses Valkey, not etcd

Harbor needs to cache "user X's session token is valid until Y." Millions of these per day, sub-millisecond reads, OK if a write takes 10ms to propagate to every replica (a session valid for 24 hours doesn't need 10ms-perfect consistency). etcd would be a thousand times slower than needed and run out of capacity quickly.

### 11.4 Common confusion to avoid

- Don't use etcd as an application cache — too slow, too small, designed for "small but always correct."
- Don't use Redis cluster as your distributed-coordination primitive — it'll silently disagree with itself under network partition.
- Both have a "watch" feature but they mean different things. etcd's watch is "notify me when this exact key changes" — exactly what kubelet uses to react to API server state changes. Redis pub/sub is "notify all subscribers when someone publishes to this channel" — fan-out messaging, not state observation.

The right mental model: **etcd = distributed-systems source-of-truth with small, slow, correct writes. Redis/Valkey = fast cache with high-throughput, sloppy-but-fast semantics.** Same data structure exposed at the API; completely different jobs.

---

## 12. Helm — the Kubernetes package manager

Yes, the apt/dnf analogy is exactly right at first level. Helm packages are called *charts* and you install them with `helm install` the way you'd `dnf install` a package. The mapping is clean — but there are important differences worth understanding because they shape how you use it day-to-day.

### 12.1 The mapping

| Linux | Helm |
|---|---|
| Package (`.rpm`, `.deb`) | **Chart** (a tarball or directory of YAML templates) |
| Repository (yum repo, apt repo) | **Helm repository** (HTTP-served chart index) |
| `dnf install <pkg>` | `helm install <release-name> <chart>` |
| `dnf upgrade <pkg>` | `helm upgrade <release-name> <chart>` |
| `dnf remove <pkg>` | `helm uninstall <release-name>` |
| `/etc/sysconfig/<pkg>` (config file) | **`values.yaml`** (chart configuration) |
| Package list / index | **[ArtifactHub.io](https://artifacthub.io/)** — central chart index |

### 12.2 Where Helm differs from apt/dnf in important ways

1. **Charts are templated, not pre-rendered.** A chart is a folder of `*.yaml.tpl` files with Go-template placeholders. When you install, Helm renders the templates against your `values.yaml` overrides and applies the result to the cluster. **Same chart, different values → different deployment.** apt packages are pre-built; Helm charts are recipes.

2. **You can install the same chart multiple times under different names.** `helm install postgres-keycloak bitnami/postgresql` and `helm install postgres-harbor bitnami/postgresql` give you two independent Postgres instances. apt won't let you install the same package twice.

3. **A "release" is the installed instance.** `helm list` shows your *releases*, not packages. Each release tracks the chart version, the values used, and the rendered manifests applied. `helm rollback <release> <revision>` reverts to a prior revision — a feature `dnf` only loosely approximates.

4. **Dependency resolution is weaker.** Charts can declare subchart dependencies (a "WordPress" chart can pull in a "MySQL" subchart) but it's not as automatic as apt's. For complex stacks, people use **Helmfile** or **ArgoCD app-of-apps** to manage multi-chart installs with proper ordering and release-level dependencies.

5. **Helm doesn't manage application lifecycle.** It renders + applies YAML. Once the YAML is on the cluster, **the operators / deployments / etc. handle the actual workload.** apt installs binaries; Helm installs Kubernetes resources. The "running thing" is owned by Kubernetes, not Helm.

### 12.3 Where you'll encounter Helm in your stack

Almost everything you install on the clusters comes from a Helm chart:

- Rancher (`rancher/rancher`)
- cert-manager (`jetstack/cert-manager`)
- Cilium (`cilium/cilium`)
- ingress-nginx (`ingress-nginx/ingress-nginx`)
- Keycloak (Bitnami chart or `codecentric/keycloakx`)
- CloudNativePG operator (`cnpg/cloudnative-pg`)
- Harbor (`harbor/harbor`)
- Valkey (Bitnami chart)
- ArgoCD (`argo/argo-cd`)
- kube-prometheus-stack (`prometheus-community/kube-prometheus-stack`)
- SonarQube (`sonarqube/sonarqube`)
- NVIDIA GPU Operator (`nvidia/gpu-operator`)

ArgoCD typically renders the charts itself (using its built-in Helm support) and applies the result, so in production **you commit the chart values to a git repo and ArgoCD reconciles** — you don't run `helm install` manually. The CLI is mostly for local testing and one-off installs (e.g., bootstrapping the first cluster).

### 12.4 Useful related tooling

- **[ArtifactHub.io](https://artifacthub.io/)** — the central index for finding charts. Search "kafka helm chart," see all available options ranked by official status, popularity, recency.
- **`helm template`** — render the YAML without applying. Indispensable for "what does this chart actually do?" inspection. Run it before installing anything you don't trust.
- **`helm get values <release>`** — see the values used to install/upgrade a release. Critical for recovery: back this up to git.
- **[Helmfile](https://github.com/helmfile/helmfile)** — declarative wrapper that manages many Helm releases as a unit. Useful before adopting ArgoCD.
- **[Chart Testing (`ct`)](https://github.com/helm/chart-testing)** — lints and tests charts in CI. Useful if you author your own.

### 12.5 One operational thing to know

Helm 3 stores release history in **Kubernetes Secrets** in the namespace where you installed (named like `sh.helm.release.v1.<release-name>.v<revision>`). If you `helm uninstall`, those Secrets go with it — including the rollback history. **ArgoCD-managed installs sidestep this concern** by storing the desired state in git instead of relying on cluster-side Helm release records.

If you ever lose Helm release history but the resources still exist (e.g., manually applied or restored from backup), you can re-adopt with `helm upgrade --install --force` or migrate to ArgoCD ownership directly — but it's painful. GitOps-managed installs avoid this whole class of problem.

### 12.6 Helm + ArgoCD: composition, not competition

A common newcomer question: "are we using Helm or ArgoCD?" — the answer is **both, at different layers.**

- **Helm** is a packaging and templating tool. It defines *what* gets installed (charts + values rendered into Kubernetes YAML).
- **ArgoCD** is a GitOps lifecycle controller. It defines *how/when/where* it gets installed (git as source of truth, continuous reconciliation, drift detection, multi-cluster).

They compose: ArgoCD reads chart references and values from a git repo, runs Helm internally to render the manifests, then applies them to the target cluster. Production goes through ArgoCD; Helm is the engine inside.

**What changes vs the traditional Helm CLI workflow:**

| Traditional (Helm CLI) | GitOps (ArgoCD + Helm) |
|---|---|
| `helm install keycloak bitnami/keycloak -f values.yaml` | Commit `values.yaml` to git; ArgoCD reconciles |
| `helm upgrade keycloak ...` to update | `git push` with updated values; ArgoCD reconciles |
| `helm rollback keycloak <revision>` | Revert the git commit; ArgoCD reconciles |
| Helm release state in cluster Secrets | ArgoCD Application state; git is source of truth |
| Drift undetected unless you check | ArgoCD detects drift, optionally auto-corrects (`selfHeal: true`) |
| Audit trail in CI logs / shell history | Audit trail = git history |
| Different env (dev/prod) = different `helm install` command | Different env = different ArgoCD Application pointing at different values |

**An ArgoCD Application is what you actually write in production:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak
  namespace: argocd
spec:
  project: platform-tier
  source:
    repoURL: https://gitlab.<org>/platform/manifests
    targetRevision: main
    path: clusters/mgmt/keycloak
    helm:
      values: |
        replicas: 2
        ingress:
          hostname: keycloak.<base>
        externalDatabase:
          host: cnpg-mgmt-rw
          database: keycloak
  destination:
    server: https://kubernetes.default.svc
    namespace: keycloak
  syncPolicy:
    automated:
      prune: true       # delete resources removed from git
      selfHeal: true    # revert manual changes back to git state
    syncOptions:
      - CreateNamespace=true
```

That Application:

1. Watches `clusters/mgmt/keycloak` in your manifests git.
2. Finds the Helm chart there (or references one upstream — see §12.7 below).
3. Renders the chart with the embedded values.
4. Applies the result to the destination cluster's `keycloak` namespace.
5. Auto-syncs on git changes; self-heals if someone runs `kubectl edit`; prunes orphaned resources.

**Where Helm still lives:**

- The chart itself (community charts or charts you author) — still Helm-format.
- `values.yaml` — still Helm syntax, Helm template variables, Helm overrides.
- Local testing: `helm template chart/`, `helm lint chart/`, `helm dependency update chart/`. Useful before committing.

**Where ArgoCD takes over:**

- Production install/upgrade/rollback (no `helm install` against prod).
- Continuous reconciliation, drift detection.
- Multi-cluster fan-out (one Application can target a downstream cluster via cluster credentials).
- Audit trail and history.

**The one place you still run `helm install` manually** — the bootstrap chicken-and-egg. You can't ArgoCD-install ArgoCD before ArgoCD exists. Bootstrap order:

1. Cluster comes up (RKE2 + Cilium + ingress).
2. `helm install rancher rancher/rancher` — once, manual.
3. `helm install argo-cd argo/argo-cd -n argocd` — once, manual.
4. Configure ArgoCD's "root" Application pointing at your manifests git repo.
5. **From this point forward, everything (including ArgoCD itself) is managed by ArgoCD.** ArgoCD watches a git path containing its own manifests; updating ArgoCD becomes a git commit, not a `helm upgrade` command.

This is the **app-of-apps / self-managed-ArgoCD** pattern. The bootstrap install is a one-time exception; everything else is GitOps.

**The mental rule for production changes:** *"Did this go through git?"* If yes, it's safe — ArgoCD reconciles, drift is visible, history is auditable. If no — even if you used Helm "properly" — you've created drift that ArgoCD will either revert (with `selfHeal: true`) or flag. The discipline GitOps gives you is exactly this: **git or it didn't happen.**

### 12.7 Charts in git vs charts from upstream — the vendor decision

Once you've accepted "ArgoCD drives Helm" as the model, the next question is: **where do the charts themselves live?** Three patterns, real tradeoffs.

#### Pattern A: ArgoCD references chart from upstream repo

ArgoCD Application points at, say, `https://charts.bitnami.com/bitnami` for the `keycloak` chart. Each sync, ArgoCD pulls the chart from upstream, applies your values, deploys. **Values live in git; chart does not.**

```yaml
spec:
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: keycloak
    targetRevision: 22.4.1
    helm:
      values: |
        replicas: 2
```

**Pros:**

- No copying — chart maintainer ships updates, you bump `targetRevision`.
- Clean git — only your values overrides, no chart code.
- Easy upgrades — change a version number.
- Industry standard for community charts.

**Cons:**

- **External dependency at deploy time.** If `charts.bitnami.com` is down (it has been), your sync fails. If a chart is yanked or moved, you scramble.
- **Supply chain risk.** A compromised upstream chart could compromise your cluster. Helm chart provenance signing helps, but not all chart repos sign.
- **Doesn't work air-gapped** without a mirror.
- **Chart lifecycle decisions are not yours** — Bitnami's deprecations, renames, license changes. Concrete recent example: in **August 2025** (effective Aug 28, later delayed to Sep 29), Broadcom restructured the Bitnami catalog — most non-hardened community images moved to a `bitnamilegacy` archive (no further updates), only a limited "latest-tag hardened" set remains free. Helm chart source on GitHub stays Apache 2 but the prepackaged OCI charts at `docker.io/bitnamicharts` stop receiving updates. **For new deployments, treat Bitnami charts as "verify license + update cadence at install time" rather than "evergreen free."**

#### Pattern B: Chart vendored into git

Download the chart, commit it to your manifests repo alongside the values. ArgoCD reads both from your git. **No upstream dependency at deploy time.**

```yaml
spec:
  source:
    repoURL: https://gitlab.<org>/platform/manifests
    targetRevision: main
    path: clusters/mgmt/keycloak
    # path contains both Chart.yaml/templates/ AND values.yaml
```

**Pros:**

- **No external dependency at deploy time.** Everything in your git, no flaky upstream connections.
- **Reproducible builds.** Same git commit = same exact chart, forever.
- **Supply chain control** — you can audit/scan the chart before committing.
- **Air-gap friendly.**
- **Can patch upstream charts** (carefully) without forking publicly.
- **Visible diff** when you bump a chart version — you actually see what changed.

**Cons:**

- **Chart updates are manual.** Each upstream release means re-downloading and committing.
- **Bigger git repo** — charts (especially with subcharts) can be MB-scale.
- **Drift from upstream** if not maintained. People forget to bump.
- **Helm dependency tooling** (`helm dependency update`) has to run before commit, not at deploy time.

#### Pattern C: Mirror upstream charts into your own registry (Harbor)

Pull upstream chart once, push it into **Harbor's chart repository** (Harbor 2.x supports both classic Helm chart museums and modern OCI-based charts). ArgoCD references your Harbor URL instead of upstream.

```yaml
spec:
  source:
    repoURL: oci://harbor.<base>/library
    chart: keycloak
    targetRevision: 22.4.1
```

**Pros (best of both worlds):**

- **No external dependency at deploy time** — Harbor is local.
- **Can scan charts** before serving them (Trivy, Cosign verification).
- **Air-gap friendly** if Harbor is the only path.
- **Versioning and immutability** at the artifact level.
- **Same registry as images** — one auth pattern, one signing pattern, one backup target.

**Cons:**

- **More moving parts.** You operate the mirror process.
- **Manual or scripted "pull from upstream → push to Harbor"** workflow per chart version.

#### Pattern D (modern preferred): OCI-based Helm charts in Harbor

This is the cleanest answer and it's where the ecosystem is heading. Helm 3.8+ supports storing charts as **OCI artifacts** in a container registry. Harbor supports OCI-native chart storage. Charts and images live in the same registry, share the same auth, signing (Cosign), and scanning paths.

```bash
# CI pipeline pushes a chart as an OCI artifact:
helm package my-chart/
helm push my-chart-1.4.2.tgz oci://harbor.<base>/library

# ArgoCD pulls the same way:
spec:
  source:
    repoURL: oci://harbor.<base>/library
    chart: my-chart
    targetRevision: 1.4.2
```

For community charts you mirror, the same pattern works — pull from upstream, push to Harbor as OCI, reference Harbor everywhere.

**Why this is the future:**

- Harbor already exists in your stack; no separate chart-museum to operate.
- Charts and images use the same Cosign signing keys, same supply-chain attestations, same Kyverno admission verification.
- OCI is the durable artifact format — `oras` CLI handles arbitrary OCI artifacts (charts, SBOMs, attestations).
- Pull-through caching, replication, and lifecycle policies that work for images also work for charts.

#### Recommendation for your stack

**Phased approach:**

| Phase | What | Why |
|---|---|---|
| **Day 1–30** | **Pattern A** (reference upstream) for community charts. **Pattern B** (vendored in git) for charts you author yourselves. | Get things working without over-engineering. Upstream dependency is acceptable risk during initial build-out. |
| **Day 30–90** | **Pattern D** (OCI charts in Harbor) for any chart you depend on heavily — Cilium, Rancher, ArgoCD, CNPG, NVIDIA GPU Operator, Harbor itself. Mirror them into Harbor as OCI; switch ArgoCD references. | Eliminates external deploy-time dependency for production-critical charts. Brings supply-chain controls to charts (Cosign signing, Trivy scanning). |
| **Day 90+** | **Pattern D for everything.** All charts live in Harbor as OCI artifacts. CI pipeline mirrors upstream releases on a cadence. Renovate-style automation bumps version numbers in git. | Steady-state — Harbor is the single artifact source for both images and charts. Clean and auditable. |

**Charts you author yourselves always live in git** — Pattern B for those, no question. They're your code.

#### Helm chart signing with Cosign

Worth knowing: Cosign supports signing Helm charts the same way it signs images. After packaging:

```bash
helm package my-chart/
cosign sign-blob --bundle my-chart-1.4.2.bundle my-chart-1.4.2.tgz
helm push my-chart-1.4.2.tgz oci://harbor.<base>/library
```

Kyverno's `verifyImages` rule can verify chart signatures at admission time (in addition to image signatures). For full supply-chain integrity, sign both. Day-90+ concern; not day-1 critical.

#### Tooling to make this less painful

- **[Renovate](https://docs.renovatebot.com/)** — automation bot that watches your manifests repo and opens MRs/PRs to bump chart and image versions when upstream releases. Works for both `repoURL: https://...` references (Pattern A) and OCI charts (Pattern D).
- **[ChartMuseum](https://chartmuseum.com/)** — alternative to Harbor for chart hosting if you ever needed it (you don't; Harbor covers it).
- **[helm pull](https://helm.sh/docs/helm/helm_pull/)** — the `helm` CLI command that downloads a chart locally. Useful when vendoring: `helm pull bitnami/keycloak --version 22.4.1 --untar --untardir clusters/mgmt/`.
- **[oras CLI](https://oras.land/)** — generic tool for working with OCI artifacts. Useful for inspecting Harbor-hosted charts.

#### The honest framing

**Pattern A (upstream reference) is fine for most things, most of the time.** It's only "wrong" when you need supply-chain controls, deterministic builds, or air-gap operation. Don't vendor charts purely for ideology; vendor them when there's a reason.

**Pattern D (Harbor as chart registry) is the right end-state.** It's worth working toward but isn't day-1 urgent. The "all charts via Harbor" model unifies your supply-chain story and removes external dependencies — both real wins, but achievable as the platform matures.

The temptation to "do it right from day 1" by vendoring everything immediately tends to be a tax on getting the cluster running. Defer the move to Pattern D until after the basics work.

---

## 13. Operators newcomers reinvent badly

The CloudNativePG pattern — "operator that knows how to operate this stateful service so you don't have to" — applies far beyond Postgres. Here are the operators that, if you didn't know they existed, you'd build crooked versions of with raw Deployments + StatefulSets and regret it. Organized by what they solve.

> Convention in this section: **boldface = strongly recommended for any production cluster.** Plain text = good to know exists, deploy when relevant.

### 13.1 Stateful services (turn "I'd manually run 2-3 containers in HA" into "declare a CRD")

| Service | Operator | What it gives you that you'd build worse |
|---|---|---|
| **PostgreSQL** | **CloudNativePG (CNPG)** | HA, failover, barman backups to S3, PITR, monitoring, cert rotation. Already chosen. |
| **PostgreSQL alt** | Zalando, Crunchy PGO, StackGres, Percona | Different idioms; CNPG wins for new stacks. |
| Kafka | **[Strimzi](https://strimzi.io/)** | Brokers, ZooKeeper-or-KRaft, topic CRDs, user/ACL CRDs, mirror-maker. Rolling upgrades that don't break consumers. |
| RabbitMQ | [RabbitMQ Cluster Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview) | HA RabbitMQ clusters with declarative queues/users. |
| NATS | [NATS Operator](https://github.com/nats-io/nats-operator) | NATS clusters + JetStream persistence. |
| MongoDB | [MongoDB Community Operator](https://github.com/mongodb/mongodb-kubernetes-operator), Percona | Replica sets, sharded clusters, backups. Note Mongo's SSPL license. |
| MySQL/MariaDB | [Oracle MySQL Operator](https://github.com/mysql/mysql-operator), Percona, [MariaDB Operator](https://github.com/mariadb-operator/mariadb-operator) | InnoDB Cluster, Galera, backups. None as ergonomic as CNPG for Postgres. |
| Redis/Valkey | Bitnami chart (operator-less is fine at small scale); [redis-operator](https://github.com/spotahome/redis-operator) for sentinel-based HA | Sentinel + replica HA, automatic failover. |
| Cassandra / ScyllaDB | [K8ssandra](https://k8ssandra.io/), [Scylla Operator](https://operator.docs.scylladb.com/) | Wide-column clusters with backups + monitoring. |
| etcd (as standalone DB) | [etcd-operator](https://github.com/etcd-io/etcd-operator) (project status: revived 2024) | Standalone etcd clusters for app-level coordination (separate from k8s's own etcd). |
| ClickHouse | [Altinity ClickHouse Operator](https://github.com/Altinity/clickhouse-operator) | Production-grade ClickHouse, common for log/metric analytics at scale. |

### 13.2 Cluster-glue operators (turn "manual reactive ops" into "auto-reconciled")

These are the ones where missing them = hours of toil per week. Strongly recommended for any production cluster.

| Operator | What it does | Pain it removes |
|---|---|---|
| **[cert-manager](https://cert-manager.io/)** | Provisions and rotates TLS certs from CAs (Let's Encrypt, Vault, your AD CS, internal CAs). | Manual cert rotation. Annual "the cert expired" outage. Get this on day 1. |
| **[ExternalDNS](https://github.com/kubernetes-sigs/external-dns)** | Watches Kubernetes Services and Ingresses, creates matching DNS records via your DNS provider's API (AD DNS, BIND, infoblox, route53). | Hand-editing DNS for every new app. Records out of sync with reality. |
| **[External Secrets Operator (ESO)](https://external-secrets.io/)** | Bridges k8s Secrets to external stores (Vault, AWS/GCP/Azure secret managers, 1Password). | Per-app Vault SDK integration. Secrets-in-git smell. |
| **[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)** | Encrypts Kubernetes Secrets so they can be safely committed to git; controller decrypts at deploy time. | "Where do we store secrets in GitOps?" debate. Day-1-easy alternative to ESO + Vault. |
| **[Reloader (Stakater)](https://github.com/stakater/Reloader)** | Restarts Deployments/StatefulSets automatically when their ConfigMaps or Secrets change. | "I changed config, why isn't it picked up?" → manual rollout restart for every change. |
| **[Reflector (EmberStack)](https://github.com/emberstack/kubernetes-reflector)** | Replicates ConfigMaps/Secrets across namespaces, kept in sync. | Copy-paste TLS certs into every namespace, keep them in sync manually. |
| **[MetalLB](https://metallb.universe.tf/)** | LoadBalancer services on bare metal — assigns external IPs from a pool, advertises via L2 or BGP. | "How does my Service get an external IP without a cloud provider?" You have Kemp, but **MetalLB is the canonical answer** for bare metal k8s without a hardware LB. Worth knowing about. |

### 13.3 Autoscaling beyond "scale on CPU" (turn "fixed replica count" into "responsive scaling")

| Operator | What it does | When it matters |
|---|---|---|
| **[KEDA](https://keda.sh/)** | Event-driven autoscaling. Scale on Kafka lag, RabbitMQ depth, Redis queue length, Prometheus metrics, cron schedule, etc. **Scale to zero** when idle. | Inference services that get bursty load; CI runners; any "scale on a non-CPU signal" workload. **Day-1 worth installing** — even if you don't use it immediately, having it ready means you can scale on any metric without rearchitecting. |
| [Vertical Pod Autoscaler (VPA)](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) | Right-sizes pod CPU/memory requests automatically based on observed usage. | Workloads where you don't know the right requests/limits. |
| [Goldilocks (Fairwinds)](https://github.com/FairwindsOps/goldilocks) | UI dashboard on top of VPA recommendations. Shows "you said 1 CPU, you actually use 200m." | Periodic right-sizing reviews. |
| [HPA (built-in)](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) | Horizontal Pod Autoscaler. Standard k8s feature. Scales pod count on CPU/memory by default; on custom metrics with metrics-server + Prometheus adapter. | Any horizontal-scaling workload. |

### 13.4 Backup and DR (turn "I should set up backups" into "backups exist and have been tested")

| Tool | What it does | Notes |
|---|---|---|
| **[Velero](https://velero.io/)** | Cluster-level backup/restore — Kubernetes resources + PV snapshots. Backs up to S3 (FlashBlade S3 fits). | **Strongly recommended for app-PV backup.** CNPG handles its own; everything else needs Velero. |
| [Stash (KubeDB / AppsCode)](https://stash.run/) | Alternative to Velero with broader app-level integrations. | Velero is more common; pick one. |

### 13.5 Workflow and job scheduling (turn "long-running cron jobs" into "DAG-aware orchestration")

| Tool | What it does | When you'd want it |
|---|---|---|
| [Argo Workflows](https://argoproj.github.io/argo-workflows/) | DAG-based workflow engine. Chains containerized steps with dependencies, parameters, error handling. | ML pipelines, data pipelines, complex CI/CD. |
| [Tekton](https://tekton.dev/) | Kubernetes-native CI engine. CRD-defined pipelines. | CI alternative to GitLab CI. You don't need it; have GitLab CI. |
| [Kueue](https://kueue.sigs.k8s.io/) | Batch job *queueing* — quotas, priorities, preemption for k8s Jobs. | When you have many Jobs competing for cluster capacity. |
| [Volcano](https://volcano.sh/) | HPC-style scheduler with gang scheduling, fair-share. | When you need MPI-style "all pods or no pods" scheduling for batch ML training. |

### 13.6 HPC and ML platform (turn "PhD students wiring up CUDA themselves" into "platform")

| Operator | What it does | Notes |
|---|---|---|
| **[NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator)** | Driver, toolkit, device plugin, MIG manager, DCGM exporter, NFD integration. Already in your design. | Handles the "L40 + B200 + B300 driver branch coordination" problem. |
| **[Node Feature Discovery (NFD)](https://github.com/kubernetes-sigs/node-feature-discovery)** | Labels nodes with hardware/OS features (PCI vendor IDs, kernel version, CPU features). Required by GPU Operator. | Already covered in `general-notes.md`. |
| [NVIDIA Network Operator](https://github.com/Mellanox/network-operator) | Mellanox OFED, RDMA, GPUDirect for multi-node GPU workloads. | When/if multi-node B200/B300 inference does RDMA. |
| [MPI Operator](https://github.com/kubeflow/mpi-operator) | Run MPI jobs (mpirun) on Kubernetes — gang scheduling, hostfile generation. | If MPI workloads come to k8s rather than living on bare-metal Slurm. |
| [Kubeflow](https://www.kubeflow.org/) | ML platform — Jupyter notebooks, training operators, hyperparameter tuning, model serving. | If you want a self-hosted alternative to OpenShift AI. Heavy. |
| [KServe](https://kserve.github.io/website/) | Model serving — REST/gRPC inference endpoints, autoscaling, canary, traffic splitting. | What OpenShift AI uses under the hood. Standalone install is also viable. |
| [Ray Operator](https://docs.ray.io/en/latest/cluster/kubernetes/index.html) | Run Ray clusters (distributed Python compute) on Kubernetes. | When inference or training uses Ray. |
| [Slinky slurm-operator / slurm-bridge](https://github.com/SlinkyProject) | Slurm-on-k8s and Slurm-as-k8s-scheduler. | Already covered in `slinky-reading.md`. |

### 13.7 Service mesh (turn "manual mTLS + traffic policy" into "transparent networking")

| Tool | What it is | When you'd want it |
|---|---|---|
| **Cilium Service Mesh** | eBPF-based service mesh built into Cilium. Already in your stack via the CNI choice — you get most of the service-mesh benefits free. | Already chosen for both clusters. |
| [Linkerd](https://linkerd.io/) | Lightweight Rust-based service mesh. Easier than Istio. | Good alternative to Cilium SM if you wanted a sidecar-based mesh. |
| [Istio](https://istio.io/) | Heavy-but-powerful service mesh. Lots of features, lots of complexity. | When you need every Istio feature. Probably overkill for your scale. |

### 13.8 Misc useful operators worth knowing

| Operator | What it does |
|---|---|
| **[Crossplane](https://www.crossplane.io/)** | Provision external infrastructure (cloud resources, DNS records, AWS RDS, etc.) via Kubernetes API. "Infra as Kubernetes CRDs." Interesting if you ever want declarative cloud provisioning from your clusters. |
| [Knative](https://knative.dev/) | Serverless / scale-to-zero on Kubernetes. Run containers as event-driven functions. |
| [KubeCost / OpenCost](https://www.opencost.io/) | Cost tracking — show CPU/memory/storage cost per namespace, per workload. Useful for chargeback and right-sizing. |
| [Polaris (Fairwinds)](https://github.com/FairwindsOps/polaris) | Workload best-practices linter — flags missing PDBs, missing limits, wrong probes, etc. Run in CI as a gate. |
| [Trivy Operator](https://github.com/aquasecurity/trivy-operator) | Continuously scans cluster images and configs against Trivy DB. Different from Harbor's push-time scan — this is runtime continuous scanning. |
| [Falco](https://falco.org/) | Runtime security monitoring via eBPF — alerts on suspicious syscalls, unexpected exec, container escapes. CNCF graduated. |
| [Kyverno](https://kyverno.io/) | Policy engine — already in your design (RDR-5). Worth listing for completeness. |

### 13.9 What I'd add to your design beyond what's already in it

You've got most of the operationally important ones already. The gaps worth filling specifically for your stack:

1. **cert-manager** — already implied by ingress-nginx + Keycloak TLS, but worth deploying explicitly day-1 with an issuer pointing at your AD CS or Let's Encrypt. Not currently called out.
2. **ExternalDNS** — not in the design. Massive QoL improvement; add day-1 if your DNS provider is API-accessible. Without it, every new ingress means manually adding a DNS record.
3. **Reloader** — small but high-value. Day-1.
4. **KEDA** — day-1 install even if unused initially. When inference workloads need queue-based scaling, you don't have to retrofit it.
5. **Velero** — day-30. Critical for app-PV backup.
6. **Goldilocks + VPA** — day-30. Right-sizing review tool, helps you size workloads sanely.

The rest are workload-specific (Strimzi only if you run Kafka, Crossplane only if you provision external infra, etc.). Don't deploy operators speculatively; deploy them when the specific problem they solve actually shows up.

### 13.10 The honest framing for this list

**Operators are not free.** Each one is more complexity to operate, upgrade, troubleshoot. The right rule is: **deploy an operator when the cost of operating-the-operator is lower than the cost of operating-the-thing-the-operator-runs.** For Postgres in production, that math is wildly in CNPG's favor (manual Postgres HA is hard). For a single-node Redis cache, the math is in raw-Helm-chart's favor (no operator needed; just a Bitnami chart).

The temptation as an HPC team starting out is to either deploy nothing (and re-invent badly) or deploy everything (and drown in operators to maintain). The middle path:

- **Day-1 cluster-glue operators** (cert-manager, ExternalDNS, ESO/Sealed Secrets, Reloader, KEDA installed-but-idle) — these are leverage with small footprint.
- **Day-N stateful-service operators** — install when the specific service shows up. Don't run Strimzi until you actually have a Kafka workload.
- **Anti-pattern:** deploying 20 operators because "they're cool" and creating a new full-time job operating operators.

Your design follows this pattern correctly — CNPG (Postgres operator), GPU Operator, NFD, Kyverno are all there because they solve specific named problems, not because they exist. Keep that discipline as the operator catalog grows.

---

## Sources

**Storage:**

- [Kubernetes Persistent Volumes documentation](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [AWS S3 API reference (de-facto standard)](https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html)
- [Pure Storage FlashBlade S3 docs](https://www.purestorage.com/products/unstructured-data-storage.html)
- [MinIO documentation](https://min.io/docs/minio/linux/index.html)
- [Lustre architecture overview](https://www.lustre.org/about/)

**PostgreSQL and operators:**

- [PostgreSQL official site](https://www.postgresql.org/)
- [CloudNativePG (CNPG) docs](https://cloudnative-pg.io/docs/)
- [Zalando Postgres Operator](https://github.com/zalando/postgres-operator)
- [Crunchy Data PGO](https://www.crunchydata.com/products/crunchy-postgresql-for-kubernetes)
- [StackGres](https://stackgres.io/)

**MySQL/MariaDB:**

- [MariaDB Foundation](https://mariadb.org/)
- [MySQL community](https://www.mysql.com/)
- [MariaDB Operator](https://github.com/mariadb-operator/mariadb-operator)
- [Percona Operator for MySQL](https://docs.percona.com/percona-operator-for-mysql/)

**Redis ecosystem:**

- [Redis OSS license change announcement (2024)](https://redis.io/blog/redis-adopts-dual-source-available-licensing/)
- [Valkey project](https://valkey.io/)
- [KeyDB](https://docs.keydb.dev/)

**Message brokers:**

- [Apache Kafka](https://kafka.apache.org/)
- [Strimzi Kafka Operator](https://strimzi.io/)
- [RabbitMQ](https://www.rabbitmq.com/)
- [NATS](https://nats.io/)

**Secrets management:**

- [HashiCorp Vault docs](https://developer.hashicorp.com/vault/docs)
- [OpenBao (Vault fork)](https://openbao.org/)
- [External Secrets Operator](https://external-secrets.io/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)

**Specialized databases:**

- [MongoDB (note: SSPL)](https://www.mongodb.com/)
- [FerretDB (Mongo-on-Postgres fork)](https://www.ferretdb.io/)
- [ClickHouse](https://clickhouse.com/)
- [TimescaleDB](https://www.timescale.com/)

**Observability backends:**

- [Prometheus](https://prometheus.io/)
- [Grafana Loki](https://grafana.com/oss/loki/)
- [Grafana Tempo](https://grafana.com/oss/tempo/)
- [Thanos](https://thanos.io/)
- [VictoriaMetrics](https://victoriametrics.com/)
- [OpenSearch](https://opensearch.org/)
- [OpenTelemetry](https://opentelemetry.io/)

**Common-pitfalls helpers:**

- [ExternalDNS](https://github.com/kubernetes-sigs/external-dns)
- [cert-manager](https://cert-manager.io/)
- [Velero (k8s backup)](https://velero.io/)
