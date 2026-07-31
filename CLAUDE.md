# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

Most of the platform (Crossplane/Atlantis config, Backstage, Longhorn, monitoring/logging, etc.) hasn't been scaffolded yet. Two layers exist: the Hyper-V bootstrap under `infrastructure/hyper-v/`, and the Kubernetes/GitOps layer under `kubernetes/` (Cilium CNI + ArgoCD) — see below for both. When asked to build out another layer, ask which one rather than assuming a structure.

## Hyper-V bootstrap (`infrastructure/hyper-v/`)

The cluster runs as Hyper-V VMs on a single Windows 11 Pro host (64 GB RAM, 13th-gen i9) as an interim step before migrating to bare-metal server PCs. [cluster-inventory.yaml](infrastructure/hyper-v/cluster-inventory.yaml) is the declarative source of truth (nodes, roles, addresses, MACs, Hyper-V settings); [cluster-setup.ps1](infrastructure/hyper-v/cluster-setup.ps1) reconciles Hyper-V VM state to match it. Full details, including the drift-classification rules and prerequisites, are in [infrastructure/hyper-v/README.md](infrastructure/hyper-v/README.md) — read that before changing the script.

Key things to know before touching this script:
- **Scope is VM lifecycle only.** It never applies Talos machine configs or touches Kubernetes — that's [talos-bootstrap.ps1](infrastructure/hyper-v/talos-bootstrap.ps1), a separate, manually-invoked script (also never run from the scheduled task) that generates machine configs, patches in static per-node networking (this switch has no DHCP), applies them, bootstraps etcd, and pulls kubeconfig. Don't fold that logic into cluster-setup.ps1.
- **Drift is classified Hot / RequiresRestart / Destructive.** Hot changes apply on a running VM; RequiresRestart needs `-AllowDisruptive` (rolls one node at a time); Destructive (disk shrink, VM no longer in inventory) is never auto-applied — disk shrink not even with a flag, since it requires a guest-aware resize done by hand.
- **The script never creates the vSwitch** — a missing switch is a hard error pointing at [switch-setup.ps1](infrastructure/hyper-v/switch-setup.ps1), a separate, manually-invoked script (never run from the scheduled task either), because creating or changing a vSwitch can drop host networking. It supports both an External switch bound to a physical NIC and an Internal switch + NAT for hosts with no spare NIC (e.g. Wi-Fi-only).
- Run `.\cluster-setup.ps1 -Validate` (schema + RAM/CPU budget check, no Hyper-V calls) or `-WhatIf` (dry run of Hyper-V changes) before applying changes to the inventory.

## Kubernetes/GitOps layer (`kubernetes/`)

Full details, including the bootstrap runbook and the rationale behind the structure, are in [kubernetes/README.md](kubernetes/README.md) — read that before changing anything here.

Key things to know:
- **`talos-bootstrap.ps1` now sets `cluster.network.cni.name: none` and `cluster.proxy.disabled: true`** — Talos never installs flannel or kube-proxy; Cilium replaces both (full kube-proxy replacement via Talos's KubePrism, `k8sServiceHost: localhost` / `k8sServicePort: 7445`, so it never hardcodes the control-plane IP). Every node comes up NotReady until Cilium is installed — expected, not a bug.
- **ArgoCD-managed addons use ArgoCD's native Helm source, not Kustomize.** `apps/cilium.yaml` uses `spec.sources` with `chart:`/`targetRevision:` against the upstream Helm repo plus this git repo (via `ref: values`) for `addons/cilium/values.yaml` — the direct analog of Flux's `HelmRelease`, nothing about the chart is vendored into this repo. Kustomize's `helmCharts:` field is reserved for `bootstrap/argocd` (ArgoCD's own one-time, non-ArgoCD-managed install, applied by a human via `kustomize build --enable-helm`) or a future addon that genuinely needs plain-manifest patches layered on a chart's output — not used reflexively everywhere a Helm chart is involved. `kustomize build --enable-helm`/`kubectl apply -k` don't support the same thing (`-k` doesn't do Helm inflation at all); both `kustomize` and `helm` need to be on `PATH`.
- **Three-way directory split** under `kubernetes/clusters/iolaus-prod/`: `bootstrap/` (one-time, manually-applied — ArgoCD's own install and the app-of-apps root Application; never watched by an Application), `apps/` (ArgoCD Application CRs — "what should exist"), `addons/` (each addon's `values.yaml` — "how to configure it"). Cilium has no `bootstrap/` entry: the manual first install (`helm template` + `kubectl apply --server-side`) and the ArgoCD-managed install render the exact same chart version + values file, so there's no drift for ArgoCD to reconcile on first sync.
- **ArgoCD does not manage itself.** The root Application lives in `bootstrap/`, not `apps/`, specifically so `apps/` is only ever scanned for children — the community-recommended way to avoid a root Application pruning/deleting itself. ArgoCD's own upgrades stay a manual, imperative step for now.
- Secrets (ArgoCD repo credentials) are still imperative/out-of-band — SOPS+Age isn't wired up yet.

## Documentation (`docs/`)

User-facing docs (not this file) live in `docs/`, built for Backstage's TechDocs plugin — `mkdocs.yml` and `catalog-info.yaml` at the repo root are the TechDocs plumbing (`backstage.io/techdocs-ref: dir:.`). It's a curated summary of the two layers above (`docs/index.md`, `hyper-v-bootstrap.md`, `kubernetes-gitops.md`, `roadmap.md`), written for a docs-site reader rather than mirroring the component READMEs verbatim — when either layer changes meaningfully, update both the component's own README *and* the relevant `docs/` page, since they serve different audiences and can drift.

## Purpose

A Talos Linux based Kubernetes homelab. The intended software stack, per [README.md](README.md), is:

| Layer | Tool |
| --- | --- |
| Operating System | Talos Linux |
| Kubernetes | Talos Distro |
| GitOps | ArgoCD |
| CI/CD | Self-hosted GitHub Actions runners |
| Infrastructure | Atlantis & Crossplane |
| Developer Portal | Backstage |
| Storage | Longhorn |
| Networking | Cilium |
| Secrets | SOPS + Age |
| Monitoring | Prometheus + Grafana |
| Logging | Loki |
| Dashboards | Grafana |

Cilium and ArgoCD have landed (see `kubernetes/` above). Crossplane/Atlantis, Backstage, Longhorn, SOPS+Age, and the monitoring/logging stack have not — as each lands, update this file the same way the Kubernetes/GitOps section above was added.
