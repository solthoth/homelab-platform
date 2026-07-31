# Hyper-V Bootstrap

Provisions the `iolaus-prod` Talos/Kubernetes cluster as Hyper-V VMs on a single Windows 11 Pro host. This is an interim platform: the long-term target is bare-metal server PCs, and the design is deliberately kept to "manage Hyper-V VMs from a declarative inventory" so most of it (the inventory schema, the Talos config) carries over — only the Hyper-V-specific scripts get retired at that point.

Source lives in `infrastructure/hyper-v/`; see that directory's README for the file-level detail this page summarizes.

## The three scripts

| Script | Owns | Invoked |
| --- | --- | --- |
| `switch-setup.ps1` | The Hyper-V vSwitch (External NIC binding, or Internal + NAT) | Manually, once, before the first `cluster-setup.ps1` run |
| `cluster-setup.ps1` | VM lifecycle — create/reconcile CPU, memory, disks, network settings against the inventory | Manually, or on a 15-minute scheduled task |
| `talos-bootstrap.ps1` | Talos machine config generation, static per-node networking, etcd bootstrap, kubeconfig | Manually, once per cluster (idempotent, safe to re-run) |

Each is deliberately scoped to one concern and never invokes the others automatically — in particular, **nothing here ever touches Kubernetes or Talos machine configs from an unattended context.** An unattended interval job should never hold the power to reconfigure a live cluster.

`cluster-inventory.yaml` is the single declarative source of truth: cluster name/endpoint/versions, Hyper-V settings (vSwitch name, VM path, ISO path), and the node list (name, role, static IP, MAC address).

## Sizing

Host: 64 GB RAM, 13th-gen Core i9, Windows 11 Pro.

| Role | Count | vCPU | RAM | Disks |
| --- | --- | --- | --- | --- |
| controlplane | 1 | 4 | 8 GB | 64 GB OS |
| worker | 2–3 | 8 | 8–14 GB | 64 GB OS + 250 GB Longhorn |

A single control plane means a control-plane restart is a full API-server outage — acceptable for a homelab; multi-CP HA gets rehearsed later on bare metal, where a 3-member etcd running on 3 *separate* physical hosts actually buys availability instead of just adding fsync load on one disk.

## Prerequisites

1. Hyper-V feature enabled, host rebooted.
2. `powershell-yaml` PowerShell module installed.
3. A vSwitch matching the inventory's `hyperv.switch`, created via `switch-setup.ps1` (see below) — never created automatically, since changing a vSwitch can briefly drop host networking.
4. The Talos metal ISO downloaded to the inventory's `hyperv.isoPath`.
5. PowerShell running as Administrator.

## vSwitch setup

`switch-setup.ps1` supports two topologies and is idempotent — safe to re-run, and it migrates any attached VMs before removing an old switch rather than assuming that will just work:

- **External**, bound to a physical, connected NIC — the cluster gets a real presence on the LAN, with DHCP/routing handled upstream.
- **Internal + NAT**, for hosts with no spare physical NIC (e.g. a Wi-Fi-only laptop/NUC) — Hyper-V External switches generally can't bind reliably to Wi-Fi adapters. This mode sets up a host-only switch with Windows NAT, gateway inferred from the first node's address in the inventory. It provides outbound connectivity but **no DHCP**, which is why the Talos bootstrap step below has to patch in static networking itself.

## VM lifecycle and drift handling

`cluster-setup.ps1` classifies every difference between the inventory and live Hyper-V state:

| Class | Example | Scheduled run | Manual run |
| --- | --- | --- | --- |
| **Create** | VM doesn't exist yet | Created | Created |
| **Hot** | checkpoint/stop-action policy, switch connection, boot order, missing data disk, VM stopped | Applied immediately | Applied immediately |
| **RequiresRestart** | vCPU count, memory size, Secure Boot, static MAC, disk grow | Reported only | `-AllowDisruptive`: VM powered off, change applied, powered back on, waits for a Hyper-V heartbeat before moving to the next node |
| **Destructive** | disk shrink, a VM tagged for this cluster but no longer in the inventory | Reported only | `-AllowDestructive`: interactive confirmation per change |

Two things are absolute, not flag-gated:

- **Disk shrink is never applied automatically**, under any flag — it requires a guest-aware partition shrink first, the one operation where getting it wrong loses data.
- **The vSwitch is never created or modified** by this script — that's always `switch-setup.ps1`, run by a human.

`-AllowDisruptive` processes one node at a time (stop, apply, start, wait for heartbeat) so a control-plane and all workers are never down simultaneously from one invocation.

VMs are tracked by a `managed-by=cluster-setup.ps1;cluster=iolaus-prod` tag, not by name — rogue-VM detection only looks at tagged VMs, so unrelated VMs on the same host/switch are never touched.

### Talos-on-Hyper-V settings enforced

- Generation 2, Secure Boot **off** (the standard Talos ISO isn't signed against the Microsoft UEFI CA).
- Dynamic memory **off** (kubelet reads memory capacity at boot; ballooning skews it).
- Automatic checkpoints off (checkpointing an etcd member corrupts it).
- Stop action **Shutdown**, not **Save** (resuming from saved state causes clock skew etcd handles badly).
- MAC address spoofing **on** (required for pod traffic under several Cilium modes).
- Hyper-V Time Synchronization integration service **disabled** (Talos runs its own NTP).
- Boot order disk-then-DVD, so first boot falls through to the ISO and every later boot just uses the disk.

## Talos bootstrap

Once VMs exist, each node boots to Talos maintenance mode (disk is empty, firmware falls through to the attached ISO). `talos-bootstrap.ps1` automates everything from there: generates machine configs pinned to the inventory's Kubernetes version, applies each node's config, bootstraps etcd, and pulls kubeconfig. It's idempotent — a node already reachable at its static address is left alone, and etcd bootstrap/kubeconfig fetch are skipped if already done.

It also patches `cluster.network.cni.name: none` and `cluster.proxy.disabled: true` into every node's config — Talos's default CNI (flannel) and kube-proxy are disabled because Cilium replaces both (see [Kubernetes & GitOps](kubernetes-gitops.md)). **Every node comes up `NotReady` until Cilium is installed** — expected, not a failure.

### Why bootstrap needs a "dance"

Since the vSwitch has no DHCP (true for Internal+NAT, and true for an External switch unless reservations are set up), a node given the default `talosctl gen config` output would get no usable IPv4 at all. Two things make this fiddly enough to be worth scripting rather than a copy-pasted command sequence:

- **The Hyper-V synthetic NIC's Linux interface name is `enx<mac>`, not `eth0`** (e.g. MAC `00-15-5D-20-10-11` → `enx00155d201011`). Getting this wrong silently matches nothing and the node falls back to DHCP with no error.
- **Some reachable address is needed to push the very first config to.** Link-local IPv6 is reachable by ping, but `talosctl`'s gRPC client can't dial a zone-scoped IPv6 target (a client bug, not fixed by upgrading). The script's workaround: temporarily reconnect the VM to Hyper-V's built-in "Default Switch" (working NAT+DHCP out of the box), apply the config there, then reconnect to the real cluster switch — the node comes up already using its static inventory address.

### Running on an interval

`cluster-setup.ps1 -InstallScheduledTask` registers a 15-minute `SYSTEM` task that creates missing VMs and hot-applies safe drift only — it never passes `-AllowDisruptive` or `-AllowDestructive`, and it never touches the vSwitch or Talos/Kubernetes config. Those stay for a human at the keyboard.
