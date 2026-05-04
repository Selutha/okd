# Keycloak Operator install procedure

The Keycloak Operator (from the Keycloak project, Red Hat-maintained) is
distributed as raw Kubernetes manifests, not as a Helm chart. Install
procedure is `kubectl apply -f <upstream URL>`.

## Pin the version

Pick a Keycloak version. Check
https://www.keycloak.org/downloads (current stable is ~26.x as of mid-2026).
The Operator version matches the Keycloak server version.

In the commands below, replace `<VERSION>` with e.g. `26.0.5`.

## Install

Apply BEFORE the `keycloak.yaml` (which is the Keycloak CR — needs the
CRDs to exist first).

Apply AFTER:
- `keycloak-namespace.yaml`
- `keycloak-postgres.yaml` (Postgres needs to be Ready before Keycloak
  starts, otherwise Keycloak crash-loops)

```bash
VERSION=26.0.5

# Install CRDs first
kubectl apply -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${VERSION}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${VERSION}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml

# Then the operator deployment
kubectl apply -n keycloak -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${VERSION}/kubernetes/kubernetes.yml

# Verify
kubectl -n keycloak rollout status deploy/keycloak-operator --timeout=5m
kubectl -n keycloak get pods -l app.kubernetes.io/name=keycloak-operator
```

## Why not a HelmChart CR?

The Keycloak project doesn't publish a Helm chart for the modern
Quarkus-based operator. (The community maintains
`codecentric/keycloakx` for legacy Wildfly Keycloak, but that's not what
we want.) Direct `kubectl apply` is the supported install path.

If you want this declarative + repo-tracked, an option is to wget the
three YAML files into `src/kub-mgmt/keycloak-operator/` and apply them
from there. That gets a checkpoint of "exactly which version is
running" but adds a manual upgrade step. Trade-off your call.

## Upgrades

To upgrade Keycloak:

1. Re-apply CRDs at the new version (idempotent)
2. Re-apply operator manifests at the new version
3. The Keycloak CR's `spec.image` field auto-pulls the matching server
   image, OR set explicitly to pin

Keycloak Operator manages rolling updates of Keycloak server pods.
