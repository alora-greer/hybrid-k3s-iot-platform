# Workstation helpers. Environment-specific values live in .env (gitignored).
SHELL := /bin/bash
.DEFAULT_GOAL := help

-include .env
export

# Only these variables are substituted, so PromQL like {{ $labels.x }} survives.
RENDER_VARS := $$HA_SCRAPE_TARGET $$GRAFANA_HOST $$CLOUDFLARED_IMAGE_TAG \
               $$OLLAMA_BASE_URL $$OLLAMA_MODEL $$K8SGPT_VERSION
MANIFESTS   := k8s-manifests
RENDERED    := .rendered
TF_DIRS     := terraform/aws-backup terraform/gcp-dns terraform/k8s-addons

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

.PHONY: check-env
check-env:
	@test -f .env || { echo "Missing .env — run: cp .env.example .env"; exit 1; }

# --- Manifests ---------------------------------------------------------------
.PHONY: render
render: check-env ## Render k8s-manifests/ with .env values into .rendered/
	@rm -rf $(RENDERED)
	@cd $(MANIFESTS) && find . -name '*.yaml' | while read -r f; do \
	  mkdir -p "../$(RENDERED)/$$(dirname "$$f")"; \
	  envsubst '$(RENDER_VARS)' < "$$f" > "../$(RENDERED)/$$f"; \
	done
	@if grep -rn '\$${' $(RENDERED); then echo "Unrendered variables found ^"; exit 1; fi
	@echo "Rendered to $(RENDERED)/"

.PHONY: diff
diff: render ## kubectl diff rendered manifests against the cluster
	kubectl diff -R -f $(RENDERED) || true

.PHONY: apply
apply: render ## Apply rendered manifests to the cluster
	kubectl apply -R -f $(RENDERED)

# --- Secrets (plaintext only ever exists in a pipe, never on disk) ------------
.PHONY: seal-ha-token
seal-ha-token: check-env ## Seal HA_TOKEN into a committable SealedSecret
	@test -n "$$HA_TOKEN" || { echo "HA_TOKEN is empty in .env"; exit 1; }
	@kubectl create secret generic home-assistant-token -n monitoring \
	  --from-literal=token="$$HA_TOKEN" --dry-run=client -o yaml | \
	  kubeseal --format yaml > $(MANIFESTS)/monitoring/home-assistant-token.sealedsecret.yaml
	@echo "Wrote $(MANIFESTS)/monitoring/home-assistant-token.sealedsecret.yaml"

.PHONY: seal-cloudflared-token
seal-cloudflared-token: check-env ## Seal CLOUDFLARE_TUNNEL_TOKEN into a SealedSecret
	@test -n "$$CLOUDFLARE_TUNNEL_TOKEN" || { echo "CLOUDFLARE_TUNNEL_TOKEN is empty in .env"; exit 1; }
	@kubectl create secret generic cloudflared-token -n cloudflared \
	  --from-literal=token="$$CLOUDFLARE_TUNNEL_TOKEN" --dry-run=client -o yaml | \
	  kubeseal --format yaml > $(MANIFESTS)/cloudflared/cloudflared-token.sealedsecret.yaml
	@echo "Wrote $(MANIFESTS)/cloudflared/cloudflared-token.sealedsecret.yaml"

# --- Terraform ---------------------------------------------------------------
.PHONY: tf-fmt
tf-fmt: ## terraform fmt all modules
	terraform fmt -recursive terraform

.PHONY: tf-validate
tf-validate: ## terraform init (no backend) + validate all modules
	@for d in $(TF_DIRS); do \
	  echo "==> $$d"; \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && \
	  terraform -chdir=$$d validate || exit 1; \
	done

# --- Hygiene -----------------------------------------------------------------
.PHONY: scan
scan: ## Scan the working tree for secrets with gitleaks
	gitleaks detect --source . --no-banner --redact

.PHONY: lint
lint: tf-validate ## Validate Terraform + Kubernetes schemas
	kubeconform -strict -summary -ignore-missing-schemas $(MANIFESTS)
