#!/usr/bin/env bash
# Renders every golden test app and checks that no placeholder is left, that every size, ceiling and tier
# combination gives an HPA with room to scale, and, when POLICIES names a file of Kyverno policies, that the pods pass
# them in a namespace carrying NAMESPACE_LABELS.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
components=$root/components
policies=${POLICIES:-}
namespace_labels=${NAMESPACE_LABELS:-pavlabs.dev/workloads=apps}
kyverno_cli=ghcr.io/kyverno/kyverno-cli:v1.19.2
# Physical path: Docker Desktop mounts /private/var/folders but not its /var/folders symlink.
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

pods_of() {
  # eval-all: building new objects per document in a plain stream keeps only the last one.
  yq eval-all '[select(.kind == "Deployment" or .kind == "Job") | {"apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": .metadata.name, "namespace": "golden-test", "labels": .spec.template.metadata.labels},
    "spec": .spec.template.spec}] | .[] | split_doc'
}

# Kustomize refuses absolute component paths, so the template copy and the combinations are built inside the repo.
template=$root/.template
app=$root/.combination
trap 'rm -rf "$work" "$app" "$template"' EXIT

# The template's platform-deployed overlay is what onboarded apps start from, so it is checked like the test apps,
# against this checkout's components rather than the published tag it names.
rm -rf "$template" && cp -R "$root/template" "$template"
sed -i.bak 's|https://github.com/pavlabs/golden-kustomize//\([^?]*\)?ref=[^ ]*|../../../\1|' "$template/deploy/app/kustomization.yaml"

: >"$work/pods.yaml"
for test in "$root"/tests/*/ "$template/deploy/overlays/dev/"; do
  rendered=$(kubectl kustomize "$test")
  if grep -qw golden <<<"$rendered"; then
    fail "placeholder left in output: test=$(basename "$test")"
  fi
  pods_of <<<"$rendered" >>"$work/pods.yaml"
  echo '---' >>"$work/pods.yaml"
done
combinations=0
for size in "$components"/size/[0-9]*; do
  for ceiling in "" "$components"/ceiling/*; do
    for tier in "" "$components/tier/enterprise"; do
      rm -rf "$app" && mkdir -p "$app"
      cp "$root/tests/full/golden.yaml" "$app/"
      yq -n ".resources = [\"golden.yaml\"] |
        .components = ([\"workload\", \"${size#"$components"/}\", \"${ceiling#"$components"/}\", \"${tier#"$components"/}\"] | map(select(. != \"\")) | map(\"../components/\" + .))" \
        >"$app/kustomization.yaml"
      hpa=$(kubectl kustomize "$app" | yq 'select(.kind == "HorizontalPodAutoscaler") | .spec')
      read -r min max < <(yq '(.minReplicas | tostring) + " " + (.maxReplicas | tostring)' <<<"$hpa" | tr -d '"')
      if [ "$min" -ge "$max" ]; then
        fail "HPA cannot scale: size=$(basename "$size") ceiling=$(basename "${ceiling:-none}") tier=$(basename "${tier:-startup}") min=$min max=$max"
      fi
      combinations=$((combinations + 1))
    done
  done
done
echo "hpa combinations checked: total=${combinations}"

if [ -z "$policies" ]; then
  echo "policy checks skipped: set POLICIES to a file of Kyverno policies"
  exit 0
fi
[ -f "$policies" ] || fail "policies file not found: path=$policies"
cp "$policies" "$work/policies.yaml"
LABELS="$namespace_labels" yq -n '.apiVersion = "cli.kyverno.io/v1alpha1" | .kind = "Value" | .metadata.name = "namespaces" |
  .namespaceSelector = [{"name": "golden-test", "labels": (strenv(LABELS) | split(",") | map(split("=") | {"key": .[0], "value": .[1]}) | from_entries)}]' \
  >"$work/namespaces.yaml"

docker run --rm -v "$work:/w:ro" "$kyverno_cli" apply /w/policies.yaml \
  --resource /w/pods.yaml --values-file /w/namespaces.yaml --policy-report >"$work/report.yaml" || status=$?
summary=$(yq '(.results | length | tostring) + " " + ([.results[] | select(.result != "pass")] | length | tostring)' "$work/report.yaml" | tr -d '"')
read -r checks failures <<<"$summary"
[ "$checks" -gt 0 ] || fail "kyverno produced no results: exit=${status:-0}"
yq -N '.results[] | select(.result != "pass") | .resources[0].name + " " + .policy + ": " + .message' "$work/report.yaml"
echo "golden policy checks: total=${checks} failed=${failures}"
[ "$failures" -eq 0 ]
