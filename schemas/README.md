# Vendored CRD schemas

JSON schemas for custom resources that the
[datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog) doesn't cover.
`make lint` and CI pass this directory to kubeconform, so `-strict` validation
skips 0 resources. Layout: `{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json`.

| Schema | Source |
|---|---|
| `core.k8sgpt.ai/k8sgpt_v1alpha1.json` | k8sgpt-operator `v0.2.29`, `config/crd/bases/core.k8sgpt.ai_k8sgpts.yaml` |

## Regenerate (requires `yq`, `jq`)

```bash
TAG=v0.2.29
curl -fsSL "https://raw.githubusercontent.com/k8sgpt-ai/k8sgpt-operator/${TAG}/config/crd/bases/core.k8sgpt.ai_k8sgpts.yaml" \
  | yq -o json '.spec.versions[] | select(.name=="v1alpha1") | .schema.openAPIV3Schema' \
  | jq --indent 2 'walk(if type=="object" then
      (if has("properties") and (has("additionalProperties")|not) then . + {additionalProperties:false} else . end)
      | (if .["x-kubernetes-int-or-string"]==true then del(.type) + {oneOf:[{type:"string"},{type:"integer"}]} else . end)
    else . end)' > schemas/core.k8sgpt.ai/k8sgpt_v1alpha1.json
```

When the `k8sgpt_operator` chart version is pinned in `terraform/k8s-addons`,
regenerate from the matching operator tag.
