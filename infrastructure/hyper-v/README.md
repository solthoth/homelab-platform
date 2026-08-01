# Hyper-V Talos cluster

Provisions the `iolaus-prod` Talos/Kubernetes cluster as Hyper-V VMs on a single Windows 11 Pro host. This is an interim platform: the long-term target is bare-metal server PCs, and the design here is deliberately kept to "manage Hyper-V VMs from a declarative inventory" so most of it (the inventory schema, the Talos config, the DHCP reservations) carries over — only [cluster-setup.ps1](cluster-setup.ps1) gets deleted at that point.

## Scope

[cluster-setup.ps1](cluster-setup.ps1) owns **Hyper-V VM lifecycle only**: creating VMs, keeping their CPU/memory/disks/network settings in sync with [cluster-inventory.yaml](cluster-inventory.yaml), and reporting anything it won't touch automatically. It does not generate or apply Talos machine configs, bootstrap etcd, or manage Kubernetes. That's a separate, manual `talosctl` step below — an unattended interval job should never hold the power to reconfigure a live cluster.

## Sizing

Host: 64 GB RAM, 13th-gen Core i9, Windows 11 Pro.

| Role | Count | vCPU | RAM | Disks |
| --- | --- | --- | --- | --- |
| controlplane | 1 | 4 | 8 GB | 64 GB os |
| worker | 3 | 8 | 14 GB | 64 GB os + 250 GB longhorn |

That's 28 vCPU (overcommit is fine), 50 GB RAM allocated, leaving ~14 GB for Windows and the Hyper-V parent partition. Three workers so Longhorn gets its default 3 replicas. A single control plane means a CP restart is a full API-server outage — acceptable for a homelab; multi-CP HA gets rehearsed later on bare metal, where a 3-member etcd running on 3 *separate* physical hosts actually buys availability instead of just adding fsync load on one disk.

## Prerequisites

1. Hyper-V feature enabled (`Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`, reboot).
2. `powershell-yaml` module: `Install-Module -Name powershell-yaml -Scope CurrentUser -Force`.
3. A vSwitch matching `hyperv.switch` in the inventory. `cluster-setup.ps1` deliberately will not create this for you — creating or changing a vSwitch can briefly drop host networking. Run [switch-setup.ps1](switch-setup.ps1) once, first:
   ```powershell
   # Host has a spare, physically-connected NIC:
   .\switch-setup.ps1 -Mode External -NetAdapterName '<your physical NIC name>'

   # Host has no spare physical NIC (e.g. a laptop/NUC on Wi-Fi only) --
   # Hyper-V External switches generally can't bind reliably to Wi-Fi adapters:
   .\switch-setup.ps1 -Mode Internal
   ```
   `-Mode Internal` sets up a host-only switch with NAT (gateway inferred from the first node's address in the inventory, e.g. `10.20.10.1/24`, or pass `-GatewayAddress`/`-PrefixLength` explicitly) so VMs get outbound connectivity through whatever uplink the host has. It gets you NAT but **no DHCP** — see the static-networking note below, required either way since this repo doesn't set up DHCP reservations. The script is idempotent and safe to re-run: it only touches the switch/NAT/gateway state that doesn't already match, and migrates any attached VMs before removing an old switch rather than assuming that'll just work.
4. The Talos metal ISO downloaded to the path in `hyperv.isoPath`.
5. Run PowerShell as Administrator — the script requires it.

## First run

```powershell
# Dry run — validates the inventory only, touches no Hyper-V state
.\cluster-setup.ps1 -Validate

# See exactly what would be created, without creating anything
.\cluster-setup.ps1 -WhatIf

# Create the VMs
.\cluster-setup.ps1
```

Each node boots to Talos maintenance mode on first start (disk is empty, firmware falls through to the attached ISO). From there, cluster bring-up is automated by [talos-bootstrap.ps1](talos-bootstrap.ps1):

```powershell
.\talos-bootstrap.ps1
```

This generates the machine configs (pinned to `cluster.kubernetesVersion`), applies each node's config, bootstraps etcd, and pulls kubeconfig into `talosconfig/kubeconfig`. It's idempotent and safe to re-run — a node already reachable at its static inventory address is left alone, and etcd bootstrap/kubeconfig fetch are skipped if already done. Useful flags:

- `-TalosctlPath <path>` if `talosctl` isn't on `PATH`.
- `-Force` regenerates `controlplane.yaml`/`worker.yaml` even if they already exist (e.g. after bumping `cluster.kubernetesVersion`). Refuses to run if any node is already live and reachable unless you also pass `-AllowRegenerate` — regenerating resets the cluster's PKI, which breaks trust with every already-configured node.
- `-SkipBootstrap` applies node configs only, without touching etcd bootstrap or kubeconfig — useful when adding a single new node to an already-bootstrapped cluster.
- `-GatewayAddress`/`-PrefixLength`/`-Nameservers` override the static-network values it patches into each node's config (see below); by default the gateway is inferred from the first node's address, same convention as `switch-setup.ps1`.
- `-ApiServerCertSANs <ip[]>` adds extra SANs to the kube-apiserver's serving cert (`cluster.apiServer.certSANs`) — needed for `kubectl` to TLS-verify against any address besides the node's own static IP, e.g. a LAN IP reachable via a port-forward (see the remote-access section of [kubernetes/README.md](../../kubernetes/README.md)). Don't confuse this with `machine.certSANs`, a different field that only covers Talos's own apid/machined API on port 50000, not the Kubernetes API on 6443.

Like `switch-setup.ps1`, this is a separate, manually-invoked script — never run from `cluster-setup.ps1`'s scheduled task, since an unattended job should never hold the power to reconfigure a live cluster.

This script also disables Talos's default CNI and kube-proxy (`cluster.network.cni.name: none`, `cluster.proxy.disabled: true`) — Cilium replaces both. That means every node comes up **NotReady** until Cilium is installed, which the health-check warning at the end of a run says explicitly; this is expected, not a failure. Continue in [kubernetes/README.md](../../kubernetes/README.md) for the Cilium/ArgoCD bootstrap.

### Why this needs a bootstrap dance at all

`talosctl gen config` emits `network: {}` (DHCP) by default. Since `hyperv.switch` has no DHCP server behind it (true for the Internal+NAT setup above, and true for an External switch unless you've set up reservations), a maintenance-mode node given that config as-is would get no usable IPv4 at all — `apply-config` against the inventory address would then fail with `dial tcp <ip>:50000: i/o timeout`, because nothing is listening there yet. `talos-bootstrap.ps1` avoids this by patching a static `machine.network` block into each node's config *before* ever applying it:

```yaml
machine:
  network:
    interfaces:
      - interface: enx<mac, no separators, lowercase>
        addresses:
          - 10.20.10.11/24
        routes:
          - network: 0.0.0.0/0
            gateway: 10.20.10.1
    nameservers:
      - 1.1.1.1
      - 8.8.8.8
```

(Recent Talos also moved the hostname out into its own `HostnameConfig` document further down the same file — the script sets `hostname:` there, not inside `machine.network`; setting it in both makes `apply-config` reject the file with "static hostname is already set".)

Two things make this fiddly, which is why it's scripted rather than left as a copy-pasted command sequence:
- **The Hyper-V synthetic NIC's Linux interface name is `enx<mac>`, not `eth0`** (e.g. MAC `00-15-5D-20-10-11` → `enx00155d201011`). A `machine.network.interfaces` entry for `eth0` silently matches nothing and the node falls back to DHCP with no error.
- **You need *some* reachable address to push that very first config to.** Link-local IPv6 (visible from the host via `Get-NetNeighbor` once the VM is up) is reachable by ping, but `talosctl`'s gRPC client can't dial a zone-scoped (`%zone`) IPv6 target — this is a client bug, not a config issue, and upgrading `talosctl` doesn't fix it. The script's workaround: temporarily reconnect the VM's network adapter to Hyper-V's built-in "Default Switch" (working NAT+DHCP out of the box), apply the config (with the static block above already patched in) against whatever DHCP address it gets there, then reconnect the VM back to the real cluster switch once `apply-config` reports success. The node comes up on the new switch already using its static inventory address.

Always use a `talosctl` build matching `cluster.talosVersion`, not whatever an old chocolatey/apt package happens to have cached — the script warns if the client version doesn't match but doesn't block on it.

## Running on an interval

```powershell
.\cluster-setup.ps1 -InstallScheduledTask -IntervalMinutes 15
```

Registers a scheduled task running as `SYSTEM` on a 15-minute trigger. The scheduled run always uses the default mode: create missing VMs, hot-apply safe drift, report the rest. It never passes `-AllowDisruptive` or `-AllowDestructive` — those are for a human at the keyboard. Logs land in `logs/`, machine-readable drift in `state/drift-report.json`. Exit codes: `0` in sync, `1` error, `2` drift found but not applied.

## Drift handling

Every difference between the inventory and live Hyper-V state is classified:

| Class | Example | Scheduled run | Manual run |
| --- | --- | --- | --- |
| **Create** | VM doesn't exist yet | Created | Created |
| **Hot** | checkpoint/stop-action policy, switch connection, boot order, missing data disk, VM stopped | Applied immediately | Applied immediately |
| **RequiresRestart** | vCPU count, memory size, Secure Boot, static MAC, disk grow | Reported only | `-AllowDisruptive`: VM is powered off, change applied, powered back on, then the script waits for a Hyper-V heartbeat before moving to the next node |
| **Destructive** | disk shrink, a VM tagged for this cluster but no longer in the inventory | Reported only | `-AllowDestructive`: interactive confirmation per change |

Two things are absolute, not flag-gated:

- **Disk shrink is never applied automatically**, under any flag. Shrinking a VHDX safely means shrinking the guest partition first — that's a manual, guest-aware procedure, and it's the one operation where getting it wrong loses data (including live Longhorn volumes). If `state/drift-report.json` reports a `Disk:*:Shrink` item, shrink the filesystem inside the guest, then run `Resize-VHD -Path <vhdx> -SizeBytes <n>GB` by hand.
- **The script never creates or modifies the vSwitch.** A missing switch is a hard error pointing at `switch-setup.ps1` (see Prerequisites above) — that script is also never invoked automatically, including by the scheduled task.

`-AllowDisruptive` processes one node at a time — stop, apply, start, wait for heartbeat — before moving to the next, so a control-plane and all three workers are never down simultaneously from a single invocation. Note the heartbeat check is VM-level (Hyper-V integration service), not Kubernetes node-readiness — after a disruptive change to a control-plane node in particular, confirm with `kubectl get nodes` before considering the cluster healthy again.

## VMs are tagged, not name-matched

Every VM the script creates gets `Set-VM -Notes "managed-by=cluster-setup.ps1;cluster=iolaus-prod"`. Rogue-VM detection (a VM present on the host but no longer in the inventory) only looks at VMs carrying that tag, so unrelated VMs you keep on the same host/switch are never touched.

## Talos-on-Hyper-V settings the script enforces

- Generation 2, Secure Boot **off** (the standard Talos ISO isn't signed against the Microsoft UEFI CA).
- Dynamic memory **off** (kubelet reads memory capacity at boot; ballooning skews it).
- Automatic checkpoints off, `CheckpointType = Disabled` (checkpointing an etcd member corrupts it).
- `AutomaticStopAction = ShutDown`, not `Save` (resuming from saved state causes clock skew etcd handles badly).
- MAC address spoofing **on** (required for pod traffic under several Cilium modes).
- Hyper-V Time Synchronization integration service **disabled** (Talos runs its own NTP; two clock disciplines fighting each other is worse than one).
- Boot order disk-then-DVD, so first boot falls through to the ISO and every later boot just uses the disk — the DVD never needs to be detached.

Not yet handled here, and worth revisiting before scaling past this inventory: pinning `machine.install.disk` by serial/size in the Talos machine config for any node with more than one virtual disk, so install target selection is deterministic.
