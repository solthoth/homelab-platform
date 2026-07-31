# Roadmap

What's built vs. what's still ahead, per the intended [software stack](index.md#software-stack).

## Built

- **Hyper-V bootstrap** — VM lifecycle, vSwitch setup, Talos install. See [Hyper-V Bootstrap](hyper-v-bootstrap.md).
- **Networking (Cilium)** and **GitOps (ArgoCD)** — full kube-proxy replacement, Kustomize/native-Helm addon structure, app-of-apps reconciliation from `main`. See [Kubernetes & GitOps](kubernetes-gitops.md).

## Planned, not yet started

- **Storage — Longhorn.** Worker nodes are already provisioned with a second disk earmarked for it (see [Hyper-V Bootstrap](hyper-v-bootstrap.md#sizing)); three workers exist specifically so Longhorn gets its default 3 replicas.
- **Secrets — SOPS + Age.** Needed before ArgoCD's repo credentials (or any application secret) can be committed to git instead of applied out-of-band by hand.
- **Infrastructure — Atlantis & Crossplane.** Infrastructure-as-code / PR-driven infra changes, for whatever sits outside plain Kubernetes manifests.
- **CI/CD — self-hosted GitHub Actions runners.**
- **Monitoring — Prometheus + Grafana**, **Logging — Loki**, **Dashboards — Grafana.**
- **Developer Portal — Backstage.** This documentation site is built for Backstage's TechDocs plugin in anticipation of this — once Backstage exists, it needs a `catalog-info.yaml`-registered entity pointing at this repo to actually render these pages.
- **ArgoCD self-management.** Currently a manual, imperative install/upgrade (see [Kubernetes & GitOps](kubernetes-gitops.md#why-argocd-isnt-self-managed-yet)) by design, deferred until the app-of-apps pattern has proven out on more addons.
- **Exposing cluster services beyond the cluster network.** No MetalLB/ingress layer yet; Cilium's own L2/BGP LoadBalancer IPAM is worth evaluating first, before reflexively adding MetalLB.
- **Bare-metal migration.** The Hyper-V layer is explicitly an interim step — the inventory schema and Talos config are designed to carry over largely unchanged; only the Hyper-V-specific provisioning scripts get retired.
