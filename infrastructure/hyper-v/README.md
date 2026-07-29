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
3. An external vSwitch matching `hyperv.switch` in the inventory. The script deliberately will not create this for you — creating an external switch can briefly drop host networking:
   ```powershell
   New-VMSwitch -Name k8s-external -NetAdapterName '<your physical NIC name>' -AllowManagementOS $true
   ```
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

Each node boots to Talos maintenance mode on first start (disk is empty, firmware falls through to the attached ISO). From there, cluster bring-up is a normal `talosctl` flow reading the same inventory for addresses/roles:

```powershell
talosctl gen config iolaus-prod https://10.20.10.11:6443 --output-dir ./talosconfig
talosctl apply-config --insecure -n 10.20.10.11 -e 10.20.10.11 --file ./talosconfig/controlplane.yaml
talosctl apply-config --insecure -n 10.20.10.21 -e 10.20.10.21 --file ./talosconfig/worker.yaml
# ...repeat apply-config for the other workers, then:
talosctl bootstrap -n 10.20.10.11 -e 10.20.10.11
talosctl kubeconfig -n 10.20.10.11 -e 10.20.10.11
```

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
- **The script never creates or modifies the vSwitch.** A missing switch is a hard error with the `New-VMSwitch` command to run yourself.

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
