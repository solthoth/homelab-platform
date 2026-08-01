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

Adding a future addon (Longhorn, monitoring, etc.) is: `addons/<name>/values.yaml` (the chart's overrides), `apps/<name>.yaml` (an Application referencing the upstream chart + that values file, per `cilium.yaml`'s pattern), add it to `apps/kustomization.yaml`, commit. No manual `kubectl`/`helm` step required — the root Application picks up the new child on its next reconcile. Exposing a new service on the LAN follows the same idea: its own `addons/<name>-ingress/` (an `Ingress` with `ingressClassName: cilium` and the `cert-manager.io/cluster-issuer` annotation, following `argocd-ingress`'s pattern) — no changes needed to the LB pool, L2 policy, `ClusterIssuer`, or the host-side bridge script.

### Sync-wave ordering

Some addons depend on another addon's CRDs already existing (`cilium-lb-pool` needs Cilium's CRDs; `cert-manager-issuer` needs cert-manager's CRDs *and* its webhook actually serving; `argocd-ingress` needs both the LB pool and the issuer). This is sequenced with `argocd.argoproj.io/sync-wave` annotations on the `Application` resources themselves — `cilium`/`cert-manager` at the default wave (`0`), `cilium-lb-pool`/`cert-manager-issuer` at `1`, `argocd-ingress` at `2`. ArgoCD only advances to the next wave once every `Application` in the current one is both `Synced` and `Healthy`.

**This requires one non-obvious fix**, already applied in `bootstrap/argocd/values.yaml`: ArgoCD removed built-in health assessment of its own `argoproj.io/Application` CRD in v1.8+. Without restoring it via a `resource.customizations.health.argoproj.io_Application` Lua script in `configs.cm`, sync-waves would still create things in the right order, but wouldn't actually *wait* for the previous wave to be healthy first — a later addon could get applied before its dependency's CRDs exist, and just sit retrying instead of being avoided cleanly.

## Exposing services to the home LAN

The Hyper-V vSwitch (`k8s-external`) is an **Internal** switch + Windows NAT — the host has no spare physical NIC for an External switch bridged onto the LAN. That has real consequences for exposing anything:

- The cluster's `10.20.10.0/24` network is its own L2 segment. The host is *on* it (it's the NAT gateway), but no other LAN device is. A `CiliumLoadBalancerIPPool` (`addons/cilium-lb-pool/ippool.yaml`) only allocates an IP at the Kubernetes API level — nothing answers ARP for it without **Cilium L2 Announcements** (`l2announcements.enabled: true` in `addons/cilium/values.yaml`, activated by `addons/cilium-lb-pool/l2announcement-policy.yaml`) also enabled. That's what makes the shared ingress IP reachable from the host at all, which every other LAN device's path depends on.
- Cilium's Ingress Controller runs in **shared** mode (`ingressController.loadbalancerMode: shared` in `addons/cilium/values.yaml`) — one LoadBalancer Service (`cilium-ingress` in `kube-system`) backs every `Ingress` resource cluster-wide, so exposing a second service later needs no new LB IP.
- **cert-manager** + a `ClusterIssuer` (`addons/cert-manager-issuer/clusterissuer.yaml`) get real, trusted, auto-renewing certificates from Let's Encrypt via **DNS-01 through Azure DNS** — this only needs Azure DNS API access to create a TXT record; the domain's actual A/CNAME record never needs to be internet-reachable, since LAN clients resolve it separately (see the runbook below).
- [infrastructure/hyper-v/lan-ingress-bridge.ps1](../infrastructure/hyper-v/lan-ingress-bridge.ps1) forwards the host's LAN-facing port 443 to whatever IP the shared ingress currently has (discovered live via `kubectl`, never hardcoded) — this is the actual bridge from the rest of the home network into the cluster.

### One-time setup runbook

Do this after `cilium`/`cert-manager` (wave 0) and `cilium-lb-pool`/`cert-manager-issuer` (wave 1) have synced:

1. **Azure Service Principal**, scoped to only the DNS zone:
   ```bash
   ZONE_ID=$(az network dns zone show --resource-group <rg> --name <your-domain> --query id -o tsv)
   az ad sp create-for-rbac --name cert-manager-dns01 --role "DNS Zone Contributor" --scopes "$ZONE_ID"
   az account show --query id -o tsv   # subscriptionID
   ```
2. **Create the credential Secret** (imperative, out-of-band — same pattern as ArgoCD's own repo credentials; SOPS+Age isn't wired up yet):
   ```powershell
   kubectl create secret generic azuredns-config -n cert-manager --from-literal=client-secret='<appSecret from step 1>'
   ```
3. **Fill in the remaining placeholders** (not secret, safe to commit) in `addons/cert-manager-issuer/clusterissuer.yaml` — `clientID`, `subscriptionID`, `tenantID`, `resourceGroupName` (the domain/`hostedZoneName` and the Ingress hostname are already set), then push.
4. Wait for wave 2 (`argocd-ingress`); watch `kubectl -n argocd get certificate argocd-server-tls -w` until `READY=True`.
5. **DHCP reservation** on the home router for the host's Wi-Fi MAC (`Get-NetAdapter -Name Wi-Fi | Select-Object MacAddress`) against its current LAN IP, so it never changes.
6. **Local DNS** for the hostname → that reserved IP: a router/Pi-hole/AdGuard local DNS rewrite if available (covers every device type); otherwise a per-PC `hosts` file entry as a fallback.
7. Run the bridge script:
   ```powershell
   cd infrastructure\hyper-v
   .\lan-ingress-bridge.ps1 -WhatIf   # preview first
   .\lan-ingress-bridge.ps1
   ```

Steps 1–3 can happen any time after wave 1 syncs, and must land before step 4's certificate can go `Ready` — cert-manager just retries DNS-01 until the secret/issuer are correct, that's not a sync-wave concern. Steps 5–7 are independent of the Kubernetes side.

Verify end-to-end from an **actual other LAN device** (not the host — that's the whole point): `https://<hostname>/` should load with a trusted padlock and no browser warning.

## Remote cluster access (kubectl from another host)

The Kubernetes API (port 6443) has the same reachability problem as any other in-cluster service: `10.20.10.0/24` is its own L2 segment behind the Hyper-V host's NAT, so a device elsewhere on the LAN (a MacBook, say) can't reach `10.20.10.11:6443` directly. [infrastructure/hyper-v/k8s-api-bridge.ps1](../infrastructure/hyper-v/k8s-api-bridge.ps1) bridges it the same way `lan-ingress-bridge.ps1` bridges the ingress — a `netsh interface portproxy` forward from the host's LAN IP to the control-plane node's static address, plus a firewall rule scoped to the LAN's CIDR. Unlike the ingress bridge, the backend is the control-plane's static inventory address (read straight from `cluster-inventory.yaml`), not a dynamically-assigned LoadBalancer IP.

TLS verification is the part that actually needs a real fix, not just a forwarded port: the API server's serving certificate only carries SANs for addresses Talos already knows about (`10.20.10.11`, `127.0.0.1`, the Kubernetes Service IP), not the Hyper-V host's LAN IP. That requires `cluster.apiServer.certSANs` — set via `talos-bootstrap.ps1 -ApiServerCertSANs <lan-ip>` (see [infrastructure/hyper-v/README.md](../infrastructure/hyper-v/README.md)). **Don't confuse this with `machine.certSANs`** — a different field entirely, covering only Talos's own apid/machined API on port 50000, not the Kubernetes API on 6443; setting the wrong one leaves `kubectl` failing TLS verification while `talosctl` works fine, which is a confusing place to debug from.

### One-time setup (on the Hyper-V host)

```powershell
cd infrastructure\hyper-v
# Only needed once, or again if the LAN IP changes: adds the LAN IP as a cert SAN.
.\talos-bootstrap.ps1 -ApiServerCertSANs 192.168.1.170
.\k8s-api-bridge.ps1
```

### Getting a kubeconfig onto the remote host

`infrastructure/hyper-v/talosconfig/kubeconfig` (produced by `talos-bootstrap.ps1`) is **cluster-admin** and deliberately `.gitignore`d — like any live credential in this repo, it's never meant to travel through git, and handing out a copy of it to every device/person that needs `kubectl` access means an ever-growing set of holders of the one credential that can do anything, with no way to take back just one of them. Two ways to get a working kubeconfig onto a remote host, in order of preference:

#### Preferred: a scoped, per-person/device credential (`new-cluster-user.ps1`)

[infrastructure/hyper-v/new-cluster-user.ps1](../infrastructure/hyper-v/new-cluster-user.ps1) mints an individually-revocable credential using Kubernetes' own [CertificateSigningRequest API](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/) — no extra identity-provider infrastructure (OIDC/Dex/etc.) required, just the cluster's own CA, which Talos already wires kube-controller-manager up to sign with. Run **on the Hyper-V host** (or anywhere holding the admin kubeconfig):

```powershell
cd infrastructure\hyper-v
.\new-cluster-user.ps1 -Username "carlos-macbook" -ClusterRole view
```

What it does, end to end:
1. Generates an ECDSA P-256 keypair and a CSR (`CN=<Username>`) entirely in .NET — no `openssl`/`cfssl` needed.
2. Submits it as a `CertificateSigningRequest` (`signerName: kubernetes.io/kube-apiserver-client`) and approves it — this signer is **not** auto-approved by Kubernetes by default, so this admin-approval step is the actual security boundary, not a formality.
3. Reads back the certificate the cluster's own CA just signed.
4. Applies a `ClusterRoleBinding` binding that exact `Username` to `-ClusterRole` (default `view`; pass `-ClusterRole cluster-admin` for full access) — idempotent, so re-running for the same `-Username` later (e.g. to reissue an expired cert) doesn't disturb anyone else's access.
5. Assembles a ready-to-use kubeconfig pointed at the LAN-forwarded address from the section above, and writes it to `infrastructure/hyper-v/talosconfig/issued/<username>-kubeconfig` — inside `talosconfig/`, so it inherits the same `.gitignore` rule as the admin kubeconfig.

The only step left manual — because it's inherent to bootstrapping trust with *any* new device, including OIDC/SSO — is getting that resulting file onto the person's machine. It's a much lower-stakes transfer than the admin kubeconfig, though: scoped to one role, revocable independently of everyone else, and (by default) expires in 90 days on its own. Still treat it as a live credential in transit — AirDrop, `scp`, a USB drive, or a temporary secure share, not email or chat.

Once it's on the remote host, using it is identical to the admin kubeconfig — see "Using a kubeconfig on the remote host" below, just point `KUBECONFIG` at the issued file directly (its `server:`/CA data are already correct, no editing needed, unlike the admin kubeconfig below).

**Revoking access** later: `.\revoke-cluster-user.ps1 -Username "carlos-macbook"`. Read the header comments in both scripts before relying on this for anything sensitive — **Kubernetes' native x509 client-cert auth has no certificate revocation list**, so this removes authorization (every API call immediately 403s) but the certificate itself stays cryptographically valid, and would still authenticate, until its `-ExpirationDays` runs out. That expiration window is the actual safety net, not the revoke script alone; keep it short for anyone/anything you're not fully confident in long-term. This is a known, general limitation of native Kubernetes client-cert auth (not something specific to this script) — it's exactly why clusters with more than a handful of users typically move to OIDC eventually.

#### Fallback: the admin kubeconfig directly

Useful for the Hyper-V host's own first remote-admin device, or in a pinch. Copy `infrastructure/hyper-v/talosconfig/kubeconfig` to the remote host, then edit its `server:` field to point at the Hyper-V host's LAN IP instead of the control-plane's internal address (`https://10.20.10.11:6443` → `https://192.168.1.170:6443`). There's no `scp`/network-share transfer built into this repo for it (it's cluster-admin — deliberately not something to automate the distribution of); use whichever of OpenSSH Server, an SMB share, or a USB drive/AirDrop you're comfortable with on your LAN.

```bash
# after getting the file onto the remote host by whatever means:
sed -i '' 's/10\.20\.10\.11/192.168.1.170/' ~/.kube/homelab-admin-config   # macOS/BSD sed; drop the '' on GNU/Linux
```
```powershell
(Get-Content $env:USERPROFILE\.kube\homelab-admin-config) -replace '10\.20\.10\.11', '192.168.1.170' | Set-Content $env:USERPROFILE\.kube\homelab-admin-config
```

### Using a kubeconfig on the remote host

**Linux / macOS:**
```bash
export KUBECONFIG=~/.kube/homelab-config
kubectl get nodes
```
To use it permanently instead of `~/.kube/config`, add the `export KUBECONFIG=...` line to `~/.zshrc`/`~/.bashrc`, or merge it into `~/.kube/config` under a named context with `kubectl config` commands.

**Windows (PowerShell):**
```powershell
$env:KUBECONFIG = "$env:USERPROFILE\.kube\homelab-config"
kubectl get nodes
```
To persist across sessions, set the `KUBECONFIG` environment variable via `[Environment]::SetEnvironmentVariable('KUBECONFIG', "$env:USERPROFILE\.kube\homelab-config", 'User')` instead of setting it per-session.

Re-run `k8s-api-bridge.ps1` any time the Hyper-V host's LAN IP changes (e.g. a new DHCP lease) — it auto-detects the current one. If it changes, the cert SAN needs updating too (`talos-bootstrap.ps1 -ApiServerCertSANs <new-ip>`), or TLS verification breaks again even though the port forward still works — and any kubeconfig already issued (admin or per-user) needs its `server:` field updated to match, since that address is baked in at issue time.

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

## Secrets (SOPS + Age)

Every Kubernetes Secret in this repo is authored as plaintext, SOPS-encrypted in place, and committed — never applied by hand. ArgoCD's repo-server decrypts them transparently at sync time via [KSOPS](https://github.com/viaduct-ai/kustomize-sops) (see `bootstrap/argocd/values.yaml`'s `repoServer` block: an init container installs the `ksops`/`kustomize` binaries, `kustomize.buildOptions` gains `--enable-alpha-plugins --enable-exec`, and the Age private key is mounted from a `sops-age` Secret), so from the cluster's perspective a SOPS-encrypted generator and a plain `Secret` resource are indistinguishable.

**Adding a new one only ever needs the Age *public* key (already committed in `.sops.yaml`) and the `sops` CLI — never the private key.** Only *decrypting* an existing one (to view/edit it locally, or for ArgoCD's repo-server to render it at sync time) needs the private key, which never leaves this host outside of the `sops-age` Secret in the `argocd` namespace and a backup outside this repo (a password manager, not git).

**Windows note:** `sops` doesn't auto-discover the Age key at its conventional default path on this OS — set `$env:SOPS_AGE_KEY_FILE` explicitly for any local `sops` command (e.g. in your PowerShell profile), or every local encrypt/decrypt fails with a confusing "no matching creation rules found" or "identity did not match any of the recipients" instead of a clear "key not found."

To add `addons/<name>/<secret>.enc.yaml`:

1. Author it as a normal plaintext Secret manifest, `stringData` for human-typed values, **already named with the `.enc.yaml` suffix** (SOPS's creation rules match on the filename you give it, not on where you redirect the output — encrypting a `plain.yaml` into a `secret.enc.yaml` via `>` doesn't match the rule):
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: <secret>
     namespace: <ns>
   type: Opaque
   stringData:
     <key>: "<value>"
   ```
2. Encrypt in place: `sops --encrypt --in-place addons/<name>/<secret>.enc.yaml` (picks up the rule from the repo-root `.sops.yaml` automatically — nothing to pass on the command line).
3. Point a generator at it in that addon's `kustomization.yaml` (`resources:` and `generators:` coexist fine in one file):
   ```yaml
   generators:
     - <secret>.secret-generator.yaml
   ```
   with `<secret>.secret-generator.yaml`:
   ```yaml
   apiVersion: viaduct.ai/v1
   kind: ksops
   metadata:
     name: <secret>-secret-generator
     annotations:
       config.kubernetes.io/function: |
         exec:
           path: ksops
   files:
     - ./<secret>.enc.yaml
   ```
4. Commit and push. ArgoCD picks it up on the addon's normal reconcile — no manual step, same as any other addon change.

To *edit* an existing encrypted secret: `sops addons/<name>/<secret>.enc.yaml` opens it decrypted in `$EDITOR` and re-encrypts on save — this is the one operation that needs the private key.

The Age private key lives only: on this host (`C:\Users\soldo\.config\sops\age\keys.txt`), backed up in a password manager, and inside the `sops-age` Secret in the `argocd` namespace (itself created imperatively, out-of-band — it's the one secret that can never be SOPS-encrypted in this same repo without a bootstrapping paradox). Losing all copies makes every SOPS-encrypted secret in this repo permanently unrecoverable; rotating the key means re-encrypting every `.enc.yaml` and replacing the `sops-age` Secret.

## Not yet handled here

- **Secrets**: ArgoCD's own repo credentials are still an imperative, out-of-band step (SOPS+Age isn't a good fit for bootstrapping ArgoCD's own access to the repo it needs to read `.sops.yaml` from in the first place). The Azure DNS Service Principal's client secret, by contrast, is now SOPS-encrypted and committed — see "Secrets (SOPS + Age)" above.
- **ArgoCD self-management, Longhorn, monitoring**: future layers, not designed here — see "Layout" above for how they'd slot in.
