# Homelab Platform

A Talos Linux based Kubernetes homelab. It runs today as Hyper-V VMs on a single Windows 11 Pro host, as an interim step before migrating to bare-metal server PCs.

## What's built so far

| Layer | Status | Docs |
| --- | --- | --- |
| Hyper-V bootstrap — VM lifecycle, vSwitch, Talos install | Built | [Hyper-V Bootstrap](hyper-v-bootstrap.md) |
| Kubernetes & GitOps — Cilium CNI, ArgoCD | Built | [Kubernetes & GitOps](kubernetes-gitops.md) |
| Everything else — storage, secrets, infra-as-code, CI/CD, observability, developer portal | Planned | [Roadmap](roadmap.md) |

## Software stack

| Layer | Tool | Status |
| --- | --- | --- |
| Operating System | Talos Linux | Built |
| Kubernetes | Talos Distro | Built |
| Networking | Cilium | Built |
| GitOps | ArgoCD | Built |
| Storage | Longhorn | Planned |
| Secrets | SOPS + Age | Planned |
| Infrastructure | Atlantis & Crossplane | Planned |
| CI/CD | Self-hosted GitHub Actions runners | Planned |
| Monitoring | Prometheus + Grafana | Planned |
| Logging | Loki | Planned |
| Dashboards | Grafana | Planned |
| Developer Portal | Backstage | Planned — this doc site is built for it (TechDocs) |

## Cluster at a glance

- **Cluster name:** `iolaus-prod`
- **Nodes:** 1 control-plane + 2 workers — Talos v1.13.7, Kubernetes v1.36.2, Hyper-V Generation 2 VMs
- **Network:** `10.20.10.0/24`, either bridged to the physical LAN (External vSwitch) or NAT'd through the host (Internal vSwitch, for hosts with no spare physical NIC)
- **CNI:** Cilium, full kube-proxy replacement via Talos's built-in KubePrism (`localhost:7445`)
- **GitOps:** ArgoCD app-of-apps, reconciling from this repository's `kubernetes/` directory on `main`

## Repository layout

```text
infrastructure/hyper-v/   Hyper-V VM lifecycle + Talos bootstrap (PowerShell)
kubernetes/               Cilium + ArgoCD GitOps manifests (Kustomize / ArgoCD Applications)
docs/                     This documentation site (TechDocs)
```

Start with [Hyper-V Bootstrap](hyper-v-bootstrap.md) if you're standing up a new host, [Kubernetes & GitOps](kubernetes-gitops.md) if the cluster already exists and you're changing what runs on it, or [Roadmap](roadmap.md) for what's coming next.
