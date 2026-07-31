# Kubernetes & GitOps

Cilium (CNI) and ArgoCD (GitOps) for the `iolaus-prod` cluster provisioned per [Hyper-V Bootstrap](hyper-v-bootstrap.md).

Source lives in `kubernetes/`; see that directory's README for the exact bootstrap runbook this page summarizes.

## Cilium: full kube-proxy replacement

Talos's default CNI (flannel) and kube-proxy are disabled at the machine-config level (`cluster.network.cni.name: none`, `cluster.proxy.disabled: true`) — Cilium replaces both entirely, using Talos's built-in **KubePrism** local API-server proxy (`k8sServiceHost: localhost`, `k8sServicePort: 7445`) so it never hardcodes the control-plane's address. This is the modern, ecosystem-recommended setup, and cheaper to get right on a greenfield cluster than to migrate to later.

Two Talos-specific values were necessary to get Cilium actually running:

- `cgroup.autoMount.enabled: false` / `cgroup.hostRoot: /sys/fs/cgroup` — Talos mounts cgroup v2 itself; Cilium must not try to mount its own.
- `securityContext.capabilities` overrides for `ciliumAgent` and `cleanCiliumState`, excluding `SYS_MODULE`/`SYS_BOOT`. **Talos blocks these two capabilities for every container, even privileged ones** (no dynamic kernel modules, no in-container reboot — it's an immutable OS). Cilium's chart defaults request them anyway, which fails its init containers with `unable to apply caps: operation not permitted` until overridden.

## GitOps structure

Two different mechanisms are used on purpose, not one uniform choice:

- **ArgoCD-managed addons use ArgoCD's native Helm source** — an Application's `spec.sources` points directly at the upstream Helm repo (`chart:`/`targetRevision:`), plus a second source that's just this git repo, referenced only for the values file. This is the direct analog of Flux's `HelmRelease`: the chart is fetched from upstream at sync time, nothing about it is vendored into this repository — only the values overrides are committed.
- **ArgoCD's own bootstrap install uses Kustomize's `helmCharts:` field** instead, since it's a one-time install applied by a human with `kustomize build`, not something ArgoCD reconciles. Kustomize is reserved for cases like this — or a future addon that genuinely needs plain-manifest patches layered on top of a chart's output — not used reflexively everywhere a Helm chart is involved.

```text
kubernetes/clusters/iolaus-prod/
  bootstrap/     one-time, manually-applied; never watched by an ArgoCD Application
    argocd/        ArgoCD's own install (Kustomize + helmCharts: argo-cd)
    root-app.yaml  the app-of-apps root Application
  apps/          ArgoCD Application CRs -- "what should exist"; watched by root-app.yaml
  addons/        values.yaml (etc.) for each addon's Helm chart -- "how to configure it"
```

`bootstrap/` holds only what must exist before any GitOps tooling can help (ArgoCD itself, and the single root Application that hands control to it) — it deliberately does not include Cilium. `apps/` and `addons/` are ArgoCD-managed from the moment the root Application is applied.

Adding a future addon (Longhorn, monitoring, etc.): `addons/<name>/values.yaml`, `apps/<name>.yaml` (an Application referencing the upstream chart + that values file, following Cilium's pattern), add it to `apps/kustomization.yaml`, commit. No manual step required — the root Application picks up the new child on its next reconcile.

### Why Cilium has no `bootstrap/` entry

The one-time manual Cilium install (`helm template ... | kubectl apply --server-side`) renders the exact same chart version + values file that the ArgoCD Application later points at. There's one source of truth; "manually installed" and "ArgoCD-managed" render the same manifests, so ArgoCD's first sync is a clean no-op diff — no special adoption handling needed.

### Why ArgoCD isn't self-managed (yet)

The app-of-apps root Application should never include or manage itself — doing so creates confusing self-referential prune/delete behavior. The root Application manifest lives in `bootstrap/`, not `apps/`, specifically so `apps/` is only ever scanned for *children*. ArgoCD's own install/upgrades stay a manual, imperative concern for now; self-management is worth revisiting once the app-of-apps pattern has proven out on real addons.

## Bootstrap sequence (summary)

1. Bring up the cluster (Hyper-V + Talos) — every node comes up `NotReady`, expected, since there's no CNI yet.
2. Install Cilium by hand (`helm template | kubectl apply --server-side`) — nodes flip to `Ready`.
3. Install ArgoCD by hand (`kustomize build --enable-helm | kubectl apply --server-side`) — `--server-side` is required, since a plain `kubectl apply` fails on the `ApplicationSet` CRD (its schema exceeds the 262144-byte `last-applied-configuration` annotation limit).
4. Grant ArgoCD repo access, if the repo is private (skipped for a public repo).
5. Apply the root Application once — ArgoCD takes over from here.
6. Verify ArgoCD adopted Cilium with an empty diff.

From that point on, any change to `kubernetes/clusters/iolaus-prod/` on `main` is picked up and reconciled automatically (`automated: {prune: true, selfHeal: true}`).

## Not yet handled

- **Secrets**: ArgoCD's repo credentials are still an imperative, out-of-band step — SOPS+Age isn't wired up yet, so nothing about repo access is committed to git.
- **Exposing services beyond the cluster network**: no MetalLB/ingress layer yet. Cilium can potentially provide its own L2/BGP LoadBalancer IPAM, worth evaluating instead of a separate MetalLB addon when this is designed.
- **ArgoCD self-management, Longhorn, monitoring**: see [Roadmap](roadmap.md).
