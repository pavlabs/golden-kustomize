# golden-kustomize

The Kustomize base every pavlabs-built app deploys with. It expects a cluster with a Gateway API gateway named `platform` in the `gateway` namespace (HTTPS listener `https`) and an External Secrets `ClusterSecretStore` named `secrets`. `base` is the default set: one pod serving HTTP behind the platform Gateway (`workload`, `service` and `httproute`). An app adds the components it needs on top, pins everything to a release tag, and supplies a `golden` config that names its resources. The base and its parts are Kustomize components rather than a classic base, because their replacements must run after the app's config is in place.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shop
resources:
  - golden.yaml          # ConfigMap "golden", annotated config.kubernetes.io/local-config: "true", data: name, host
components:
  - https://github.com/pavlabs/golden-kustomize//base?ref=v0.1.0
  - https://github.com/pavlabs/golden-kustomize//components/externalsecret?ref=v0.1.0
  - https://github.com/pavlabs/golden-kustomize//components/size/1000?ref=v0.1.0
images:
  - name: app
    newName: ghcr.io/pavlabs/api
    newTag: 1.4.2
labels:
  - includeTemplates: true
    pairs:
      app.kubernetes.io/part-of: shop
      app.kubernetes.io/component: api
patches:
  # The config has done its job once the components ran; deleting it lets a parent combine several workloads.
  - patch: |-
      $patch: delete
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: golden
```

| Component | Adds |
|---|---|
| `base` (default, first) | `workload`, `service` and `httproute` together; without a size it runs a single pod |
| `workload` | Deployment and ServiceAccount: non-root, read-only root filesystem with a writable `/tmp`, no service-account token, surge-only rollouts, container port `http` 8080. Used alone (first) by workers without a route |
| `service`, `httproute` | Service on port 80, and a route on the platform Gateway's HTTPS listener for the config's `host` |
| `externalsecret` | An ExternalSecret from the `secrets` store, loaded whole into the container's environment; the app patches `spec.data` |
| `migration-job` | A PreSync Job on the workload's image for schema migrations, run before every sync, so the migration must be idempotent; the app patches its command |
| `servicemonitor`, `podmonitor` | Prometheus scraping of `/metrics` on `http` (needs the observability stack) |
| `size/<mru>` | Requests, memory limit and an HPA floor for 100, 1000, 10000 or 100000 monthly recurring users |
| `ceiling/<peakUsers>` | How far the HPA may scale, for 1000 to 1000000 expected peak users (needs a size) |
| `tier/enterprise` | At least 3 pods spread across zones, and a PDB allowing one down at a time (needs a size) |

Every size keeps `minReplicas <= 3 < maxReplicas`, so any size, ceiling and tier combine into an HPA that can still scale. The platform's Kyverno policies check what the base guarantees in namespaces labeled `pavlabs.dev/workloads: apps`. `test.sh` renders the apps in `tests/` and fails on any leftover placeholder or on a size, ceiling and tier combination that cannot scale. Given `POLICIES=<file of Kyverno policies>` (and optionally `NAMESPACE_LABELS=key=value,...`), it also checks the rendered pods against those policies; run it that way after changing the base or the policies. After merging a change, tag the commit `vX.Y.Z` so apps can move to it deliberately.

