# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

Most of the platform (GitOps manifests, Crossplane/Atlantis config, Backstage, etc.) hasn't been scaffolded yet. The one piece that exists is the Hyper-V bootstrap layer under `infrastructure/hyper-v/` — see below. When asked to build out another layer, ask which one rather than assuming a structure.

## Hyper-V bootstrap (`infrastructure/hyper-v/`)

The cluster runs as Hyper-V VMs on a single Windows 11 Pro host (64 GB RAM, 13th-gen i9) as an interim step before migrating to bare-metal server PCs. [cluster-inventory.yaml](infrastructure/hyper-v/cluster-inventory.yaml) is the declarative source of truth (nodes, roles, addresses, MACs, Hyper-V settings); [cluster-setup.ps1](infrastructure/hyper-v/cluster-setup.ps1) reconciles Hyper-V VM state to match it. Full details, including the drift-classification rules and prerequisites, are in [infrastructure/hyper-v/README.md](infrastructure/hyper-v/README.md) — read that before changing the script.

Key things to know before touching this script:
- **Scope is VM lifecycle only.** It never applies Talos machine configs or touches Kubernetes — that's [talos-bootstrap.ps1](infrastructure/hyper-v/talos-bootstrap.ps1), a separate, manually-invoked script (also never run from the scheduled task) that generates machine configs, patches in static per-node networking (this switch has no DHCP), applies them, bootstraps etcd, and pulls kubeconfig. Don't fold that logic into cluster-setup.ps1.
- **Drift is classified Hot / RequiresRestart / Destructive.** Hot changes apply on a running VM; RequiresRestart needs `-AllowDisruptive` (rolls one node at a time); Destructive (disk shrink, VM no longer in inventory) is never auto-applied — disk shrink not even with a flag, since it requires a guest-aware resize done by hand.
- **The script never creates the vSwitch** — a missing switch is a hard error pointing at [switch-setup.ps1](infrastructure/hyper-v/switch-setup.ps1), a separate, manually-invoked script (never run from the scheduled task either), because creating or changing a vSwitch can drop host networking. It supports both an External switch bound to a physical NIC and an Internal switch + NAT for hosts with no spare NIC (e.g. Wi-Fi-only).
- Run `.\cluster-setup.ps1 -Validate` (schema + RAM/CPU budget check, no Hyper-V calls) or `-WhatIf` (dry run of Hyper-V changes) before applying changes to the inventory.

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

This implies a GitOps-driven layout is expected eventually (e.g. ArgoCD watching manifests in-repo, Crossplane/Atlantis managing infrastructure as code, SOPS+Age for encrypting secrets committed to git). As these pieces land, update this file with actual directory layout, apply/deploy commands, and how ArgoCD is pointed at this repo.
