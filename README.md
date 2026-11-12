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
| `migration-job` | A Job on the workload's image for schema migrations, run on every sync after the app's Secret exists and before the workload rolls, so the migration must be idempotent; the app patches its command |
| `servicemonitor`, `podmonitor` | Prometheus scraping of `/metrics` on `http` (needs the observability stack) |
| `same-namespace` | A CiliumNetworkPolicy that lets every pod in the namespace reach the others (the app's own workloads, its Database), which the platform's default deny blocks; include it once per app, not per workload |
| `kube-api` | Egress to the Kubernetes API and the service account token, for a workload that calls the API (`kubectl` in a Job, leader election, a controller); grant what it may do with its own Role |
| `size/<mru>` | Requests, memory limit and an HPA floor for 100, 1000, 10000 or 100000 monthly recurring users |
| `ceiling/<peakUsers>` | How far the HPA may scale, for 1000 to 1000000 expected peak users (needs a size) |
| `tier/enterprise` | At least 3 pods spread across zones, and a PDB allowing one down at a time (needs a size) |

Every size keeps `minReplicas <= 3 < maxReplicas`, so any size, ceiling and tier combine into an HPA that can still scale. The platform's Kyverno policies check what the base guarantees in namespaces labeled `pavlabs.dev/workloads: apps`. `test.sh` renders the apps in `tests/` and fails on any leftover placeholder or on a size, ceiling and tier combination that cannot scale. Given `POLICIES=<file of Kyverno policies>` (and optionally `NAMESPACE_LABELS=key=value,...`), it also checks the rendered pods against those policies; run it that way after changing the base or the policies. After merging a change, tag the commit `vX.Y.Z` so apps can move to it deliberately.

## Onboarding an app

`template/` is a starting point for an app repo: a `deploy/` folder and a `Tiltfile`.

1. Ask the platform admin to add the repo to the platform's GitHub App installation. The platform then deploys any repo of a configured org that has `deploy/overlays/<stage>` (`dev` on the local cluster) into the namespace `<org alias>-<repo>-<stage>`.
2. Copy `template/deploy` and `template/Tiltfile` into the repo and replace `my-app`, `my-org` and the hosts. `name` in `deploy/app/golden.yaml` names the resources. A platform-deployed app may only use hosts on the platform's app domains (`*.dev.struggleto.build` locally); a Tilt namespace uses the platform domain (`*.local.struggleto.build`).
3. List extra components in `deploy/app/kustomization.yaml` (`externalsecret`, `migration-job`, the monitors, `kube-api`; the template already has `same-namespace`), but not `size`, `ceiling` or `tier`: the platform appends those to each overlay, so keep `deploy/app` a Component and the golden delete patch last in every overlay. Keep the `base` tag in step with the platform's golden version, since the appended components come from that version. An app with several workloads sizes each one itself instead and adds an empty `deploy/overlays/<stage>/.self-sized` file, so the platform appends nothing.
4. Make the image fit the base: serve on port 8080, run as a non-root user (UID 10001 by default), and write only to `/tmp`.
5. Merge to the default branch. The app appears at `https://<host>` from `deploy/app/golden.yaml`, and releases move by bumping the tag in `deploy/overlays/<stage>`.

For the edit loop, run `tilt up`. Tilt builds the image, pushes it to the local cluster's registry and applies `deploy/overlays/local` into `<org alias>-<repo>-local`, at the local host. Add a `live_update` to `docker_build` to sync code into the running container without rebuilding.
