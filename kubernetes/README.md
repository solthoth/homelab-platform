# Kubernetes layer (`kubernetes/`)

Cilium (CNI, full kube-proxy replacement) and ArgoCD (GitOps) for the `iolaus-prod` cluster provisioned under [infrastructure/hyper-v/](../infrastructure/hyper-v/).

Two mechanisms are used, deliberately, not one uniform choice:
- **ArgoCD-managed addons use ArgoCD's native Helm source** (`spec.sources` with `chart:`/`targetRevision:` pointing at the upstream Helm repo, plus a second source that's just this git repo for the values file). This is the direct analog of Flux's `HelmRelease` — the chart is fetched from upstream at sync time, nothing about it is vendored into this repo, only our own values overrides are committed.
- **`bootstrap/argocd` (ArgoCD's own one-time, non-ArgoCD-managed install) uses Kustomize's `helmCharts:` field** instead, since it's applied by a human with `kustomize build`, not reconciled by ArgoCD — Kustomize is reserved for cases like this, or a future addon that needs plain-manifest patches layered on top of a chart's output, not used reflexively everywhere a Helm chart is involved.

## Layout

```
clusters/iolaus-prod/
  bootstrap/     one-time, manually kubectl-applied; never watched by an Application
    argocd/        ArgoCD's own install (Kustomize + helmCharts: argo-cd)
    root-app.yaml  the app-of-apps root Application
  apps/          ArgoCD Application CRs -- "what should exist"; watched by root-app.yaml
  addons/        values.yaml (etc.) for each addon's Helm chart -- "how to configure it"
```

`bootstrap/` holds only what must exist before any GitOps tooling can help (ArgoCD itself, and the single root Application that hands control to it) — it deliberately does not include Cilium. `apps/` and `addons/` are ArgoCD-managed from the moment `root-app.yaml` is applied.

Adding a future addon (Longhorn, monitoring, etc.) is: `addons/<name>/values.yaml` (the chart's overrides), `apps/<name>.yaml` (an Application referencing the upstream chart + that values file, per `cilium.yaml`'s pattern), add it to `apps/kustomization.yaml`, commit. No manual `kubectl`/`helm` step required — the root Application picks up the new child on its next reconcile.

## Why Cilium has no `bootstrap/` entry

The one-time manual Cilium install (step 1 below) runs `helm template` against the exact same chart version + `addons/cilium/values.yaml` that `apps/cilium.yaml` later points ArgoCD at. There's one source of truth; "manually installed" and "ArgoCD-managed" render the same manifests, so ArgoCD's first sync is a clean no-op diff rather than something requiring special adoption handling.

## Why ArgoCD isn't self-managed (yet)

The app-of-apps root Application should never include or manage itself — doing so creates confusing self-referential prune/delete behavior. `root-app.yaml` lives in `bootstrap/`, not `apps/`, specifically so `apps/` is only ever scanned for *children*. ArgoCD's own install stays a manual, imperative concern for now (re-run the `kustomize build | kubectl apply` command in step 3 to upgrade it); revisit self-management later once the app-of-apps pattern has proven out on real addons.

## Prerequisites

- A cluster already bootstrapped per [infrastructure/hyper-v/README.md](../infrastructure/hyper-v/README.md) (`switch-setup.ps1` → `cluster-setup.ps1` → `talos-bootstrap.ps1`), with `KUBECONFIG` pointed at it.
- `helm` on `PATH` (Cilium install). Standalone `kustomize` binary too, for `bootstrap/argocd` — **`kubectl apply -k` does not support `helmCharts:` inflation**, only `kustomize build --enable-helm` does; `kubectl`'s built-in Kustomize support intentionally disables the Helm plugin.
- `argocd` CLI and `cilium` CLI are optional, used only in the verification steps below.

## Bootstrap sequence

Since `talos-bootstrap.ps1` now sets `cluster.network.cni.name: none` and `cluster.proxy.disabled: true`, every node comes up **NotReady** until Cilium is installed — this is expected, not a failure (the `talos-bootstrap.ps1` health-check warning says so explicitly).

```powershell
# 0. Bring up the cluster (see infrastructure/hyper-v/README.md for full detail)
cd infrastructure\hyper-v
.\cluster-setup.ps1
.\talos-bootstrap.ps1
$env:KUBECONFIG = (Resolve-Path .\talosconfig\kubeconfig)
kubectl get nodes            # 3 nodes, all NotReady -- expected, no CNI yet

# 1. Install Cilium (imperative, one-time; same chart+values ArgoCD uses later)
cd ..\..
helm repo add cilium https://helm.cilium.io/
helm repo update cilium
helm template cilium cilium/cilium --version 1.19.6 --namespace kube-system `
    -f kubernetes\clusters\iolaus-prod\addons\cilium\values.yaml --include-crds |
  kubectl apply --server-side --force-conflicts -f -

# 2. Verify nodes go Ready
kubectl -n kube-system get pods -l k8s-app=cilium -w
kubectl get nodes -o wide                          # all 3 flip to Ready
cilium status --wait                                # KubeProxyReplacement: True (Strict), 3/3 healthy
talosctl --talosconfig infrastructure\hyper-v\talosconfig\talosconfig -n 10.20.10.11 health --wait-timeout 3m   # now passes cleanly

# 3. Install ArgoCD (imperative, one-time; re-run this same command to upgrade it later)
# --server-side is required: plain `kubectl apply` fails on the ApplicationSet
# CRD with "metadata.annotations: Too long" (its schema exceeds the 262144-byte
# last-applied-configuration annotation limit).
kustomize build --enable-helm kubernetes\clusters\iolaus-prod\bootstrap\argocd |
  kubectl apply --server-side --force-conflicts -f -
kubectl -n argocd get pods -w

# 4. Grant ArgoCD access to this repo (skip if the repo is public)
argocd login localhost:8080 --username admin --password <argocd-initial-admin-secret> --insecure
argocd repo add https://github.com/solthoth/homelab-platform.git --username <gh-user> --password <PAT>

# 5. Hand off to GitOps (once) -- ArgoCD takes it from here
kubectl apply -f kubernetes\clusters\iolaus-prod\bootstrap\root-app.yaml

# 6. Verify ArgoCD adopted Cilium cleanly
argocd app list          # root: Synced/Healthy, then cilium: Synced/Healthy
argocd app diff cilium   # expect an empty diff -- same chart+values rendered by hand in step 1
```

ArgoCD's initial admin password (step 4) is in the auto-generated `argocd-initial-admin-secret` Secret in the `argocd` namespace:
```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

No ingress/LoadBalancer exists yet, so reach the ArgoCD UI/API via port-forward: `kubectl -n argocd port-forward svc/argocd-server 8080:443`.

## Not yet handled here

- **Secrets**: ArgoCD's repo credentials (step 4) are an imperative, out-of-band step — SOPS+Age isn't wired up yet, so nothing about repo access is committed to git.
- **Exposing services beyond the cluster network**: no MetalLB/ingress layer yet. Cilium can potentially provide its own L2/BGP LoadBalancer IPAM, worth evaluating instead of a separate MetalLB addon when this is designed.
- **ArgoCD self-management, Longhorn, monitoring**: future layers, not designed here — see "Layout" above for how they'd slot in.
