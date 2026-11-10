# AI Dev Environment: Zed + Claude Code + Ollama + K8sGPT

The workstation is set up so that AI assistance is available at three layers,
with a deliberate split between **cloud** and **local** models:

| Layer | Tool | Model | Data that leaves the LAN |
|---|---|---|---|
| Editing & IaC authoring | Zed (inline assist, agent panel) | Ollama (local) or Claude | Only when a cloud model is selected |
| Repo-wide agentic work | Claude Code (terminal / Zed agent panel) | Claude | Repo files you allow it to read |
| Cluster diagnostics | K8sGPT (CLI + in-cluster operator) | Ollama (local) | **None** |

The rule of thumb: **anything that reads live cluster state uses a local
model**. Repo code (which is already public and contains no secrets) can go to
Claude.

```
┌──────────────────────────── Mac Workstation ─────────────────────────────┐
│                                                                          │
│   ┌──────────── Zed ─────────────┐        ┌──────── Terminal ────────┐   │
│   │ editor + inline assist       │        │ claude  (Claude Code)    │   │
│   │ agent panel ── Claude Code ──┼──ACP──▶│ kubectl / helm / tf      │   │
│   │ model picker ── Ollama ──┐   │        │ k8sgpt analyze --explain │   │
│   └──────────────────────────┼───┘        └────────────┬─────────────┘   │
│                              ▼                         │                 │
│                    ┌───────────────────┐               │                 │
│                    │ Ollama :11434     │◀──────────────┘                 │
│                    │ OpenAI-compat /v1 │◀──────────────┐                 │
│                    └───────────────────┘               │                 │
└────────────────────────────────────────────────────────┼─────────────────┘
                                                         │ LAN only
                       ┌─────────────── K3s ─────────────┼───┐
                       │ k8sgpt-operator ── K8sGPT CR ───┘   │
                       │   └─ Result CRs (findings + fixes)  │
                       └─────────────────────────────────────┘
```

## 1. Ollama (local LLM runtime)

```bash
brew install ollama
brew services start ollama
ollama pull llama3.1:8b        # general reasoning / K8sGPT explanations
ollama pull qwen2.5-coder:7b   # code completion & edits in Zed
```

By default Ollama listens on `127.0.0.1` only. For the in-cluster K8sGPT
operator to reach it, bind it to the LAN interface:

```bash
launchctl setenv OLLAMA_HOST 0.0.0.0
brew services restart ollama
```

Then restrict port `11434` with the macOS firewall / router rules so only the
K3s node can reach it. Set `OLLAMA_BASE_URL` in `.env` (gitignored) to the
workstation's DHCP-reserved address.

## 2. Zed

Zed's Ollama provider and Claude Code integration are configured in
`~/.config/zed/settings.json` (machine-local, not in this repo). Example:

```jsonc
{
  "language_models": {
    "ollama": {
      "api_url": "http://localhost:11434"
    }
  },
  "agent": {
    "default_model": { "provider": "ollama", "model": "qwen2.5-coder:7b" }
  }
}
```

- **Inline assist / agent panel** — pick Ollama models for quick, private
  edits; switch to Claude for larger refactors.
- **Claude Code in Zed** — Zed can host Claude Code as an external agent in
  the agent panel, so the same `CLAUDE.md` context drives both the terminal
  and the editor.
- Recommended extensions: `terraform`, `helm`, `dockerfile`, `make`.

## 3. Claude Code

[`CLAUDE.md`](../CLAUDE.md) at the repo root is the project memory Claude Code
loads on every session. It encodes:

- The hardware/network topology (so generated config matches reality).
- **Hard security rules** — no IPs, tokens, passwords or domains in tracked
  files; secrets go through SealedSecrets.

Typical workflows:

```bash
claude                                   # interactive, in repo root
claude -p "add a PrometheusRule for ecobee HVAC runtime > 2h"
claude -p "review terraform/aws-backup for least-privilege gaps"
```

Machine-local Claude settings (`.claude/settings.local.json`) are gitignored.

## 4. K8sGPT

### CLI (workstation, ad-hoc)

```bash
brew install k8sgpt
k8sgpt auth add --backend localai --model llama3.1:8b \
  --baseurl http://localhost:11434/v1
k8sgpt analyze --explain --backend localai --anonymize
k8sgpt analyze --filter Pod,Service,Ingress --namespace monitoring --explain
```

`--anonymize` masks object names before they're sent to the model — not
strictly necessary with a local model, but it's a good default habit.

### Operator (in-cluster, continuous)

1. `terraform/k8s-addons` installs the `k8sgpt-operator` Helm chart.
2. `k8s-manifests/k8sgpt/k8sgpt.yaml` creates a `K8sGPT` resource pointing at
   Ollama's OpenAI-compatible endpoint (`localai` backend).
3. The operator periodically analyzes the cluster and writes `Result` CRs:

```bash
kubectl get results -n k8sgpt-operator-system
kubectl get result <name> -n k8sgpt-operator-system -o jsonpath='{.spec.details}'
```

The operator also exposes metrics (scraped via ServiceMonitor) so the number of
open findings can be graphed and alerted on in Grafana.

## Why this split matters (SRE angle)

- **Data governance** — cluster state (pod names, env var names, events) never
  leaves the LAN; this mirrors how a FinTech would treat production telemetry.
- **Cost & availability** — local inference has no per-token cost and still
  works when the internet link is down.
- **Guardrails over trust** — the AI tools are powerful, so the repo enforces
  safety mechanically: `.gitignore`, gitleaks in CI, SealedSecrets, and
  `CLAUDE.md` rules, rather than relying on anyone (human or model) being careful.
