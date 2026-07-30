<#
    Automates the talosctl side of cluster bring-up documented in README.md:
    generate machine configs, apply a static-network patch to each node (this
    switch has no DHCP), bootstrap etcd, and pull kubeconfig.

    Deliberately a separate, manually-invoked script -- never run from
    cluster-setup.ps1's scheduled task. It reads the same cluster-inventory.yaml
    but owns none of the Hyper-V VM lifecycle; cluster-setup.ps1 must already
    have created and started the VMs (see README.md) before this runs.

    Safe to re-run: each node already reachable at its static inventory address
    is left alone. Config generation is skipped if talosconfig/ already has
    configs, unless -Force is passed (which requires -AllowRegenerate too if
    any node is already live, since regenerating secrets breaks trust with
    already-configured nodes).
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'cluster-inventory.yaml'),
    [string]$OutputDir = (Join-Path $PSScriptRoot 'talosconfig'),
    [string]$TalosctlPath = 'talosctl',
    [string]$BootstrapSwitchName = 'Default Switch',
    [string]$GatewayAddress,
    [int]$PrefixLength = 24,
    [string[]]$Nameservers = @('1.1.1.1', '8.8.8.8'),
    [switch]$Force,
    [switch]$AllowRegenerate,
    [switch]$SkipBootstrap,
    [int]$DhcpTimeoutSeconds = 60,
    [int]$MaintenanceTimeoutSeconds = 60,
    [int]$StaticTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Invoke-Talosctl {
    # Wraps the external talosctl.exe call: PowerShell doesn't turn a non-zero
    # exit code into a terminating error on its own, which would otherwise let
    # a failed apply-config/bootstrap silently fall through as "success".
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    & $TalosctlPath @Arguments
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "talosctl $($Arguments -join ' ') exited $LASTEXITCODE"
    }
    return $LASTEXITCODE -eq 0
}

function Get-SwitchHostInterfaceAlias {
    # Get-VMNetworkAdapter -ManagementOS's .Name is a Hyper-V-level label, not
    # the Windows InterfaceAlias Get-NetNeighbor etc. need -- MAC address is
    # the reliable join key between the two object types (see switch-setup.ps1).
    param([Parameter(Mandatory)][string]$SwitchName, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $vNic = Get-VMNetworkAdapter -ManagementOS -SwitchName $SwitchName -ErrorAction SilentlyContinue
        if ($vNic) {
            $mac = ($vNic.MacAddress -replace '[-:]', '').ToUpperInvariant()
            $netAdapter = Get-NetAdapter | Where-Object { ($_.MacAddress -replace '[-:]', '').ToUpperInvariant() -eq $mac }
            if ($netAdapter) { return $netAdapter.Name }
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    throw "Could not resolve the Windows network adapter for switch '$SwitchName' within ${TimeoutSeconds}s."
}

function Wait-ForDhcpLease {
    param(
        [Parameter(Mandatory)][string]$MacAddress,
        [Parameter(Mandatory)][string]$HostInterfaceAlias,
        [int]$TimeoutSeconds = 60
    )
    $normalizedMac = ($MacAddress -replace '[-:]', '').ToUpperInvariant()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $entry = Get-NetNeighbor -InterfaceAlias $HostInterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { ($_.LinkLayerAddress -replace '[-:]', '').ToUpperInvariant() -eq $normalizedMac }
        if ($entry) { return ($entry | Select-Object -First 1 -ExpandProperty IPAddress) }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "No DHCP lease seen for MAC $MacAddress on '$HostInterfaceAlias' within ${TimeoutSeconds}s."
}

function Wait-ForMaintenanceApi {
    param([Parameter(Mandatory)][string]$Address, [int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        & $TalosctlPath -n $Address version --insecure *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    throw "Maintenance API at $Address did not respond within ${TimeoutSeconds}s."
}

function Test-EtcdBootstrapped {
    # 'get members' is a cluster-discovery resource that populates before etcd
    # is ever bootstrapped, so it's always "successful" and useless as a
    # bootstrapped/not-bootstrapped signal. etcd's own service state isn't:
    # Talos parks etcd in "Preparing" indefinitely until told to bootstrap or
    # join, so that's the reliable check.
    param([Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][string]$TalosconfigPath)
    $output = & $TalosctlPath --talosconfig $TalosconfigPath -n $Address -e $Address service etcd 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    $stateLine = $output | Where-Object { $_ -match '^STATE\s+(\S+)' } | Select-Object -First 1
    if (-not $stateLine) { return $false }
    return ($stateLine -replace '^STATE\s+', '').Trim() -ne 'Preparing'
}

function Test-NodeReachable {
    param([Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][string]$TalosconfigPath, [int]$TimeoutSeconds = 5)
    if (-not (Test-Path $TalosconfigPath)) { return $false }
    & $TalosctlPath --talosconfig $TalosconfigPath -n $Address -e $Address version *> $null
    return $LASTEXITCODE -eq 0
}

function Wait-ForNodeReachable {
    param([Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][string]$TalosconfigPath, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-NodeReachable -Address $Address -TalosconfigPath $TalosconfigPath) { return }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "$Address did not become reachable within ${TimeoutSeconds}s."
}

function Set-TalosNodeConfig {
    # Patches in static machine.network (this switch has no DHCP) and moves
    # the hostname into its own HostnameConfig document, per README.md.
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$NodeName,
        [Parameter(Mandatory)][string]$MacAddress,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$PrefixLength,
        [Parameter(Mandatory)][string]$GatewayAddress,
        [Parameter(Mandatory)][string[]]$Nameservers
    )

    $docs = ConvertFrom-Yaml -Yaml (Get-Content -Path $TemplatePath -Raw) -AllDocuments -Ordered

    # The Hyper-V synthetic NIC's Linux interface name is enx<mac>, not eth0 --
    # a wrong name here silently matches nothing and the node falls back to DHCP.
    $interfaceName = 'enx' + (($MacAddress -replace '[-:]', '').ToLowerInvariant())

    $docs[0].machine['network'] = [ordered]@{
        interfaces  = @(
            [ordered]@{
                interface = $interfaceName
                addresses = @("$Address/$PrefixLength")
                routes    = @(@{ network = '0.0.0.0/0'; gateway = $GatewayAddress })
            }
        )
        nameservers = $Nameservers
    }

    $hostnameDoc = $docs | Where-Object { $_['kind'] -eq 'HostnameConfig' } | Select-Object -First 1
    if (-not $hostnameDoc) { throw "No HostnameConfig document found in $TemplatePath -- talosctl's generated config format may have changed." }
    $hostnameDoc.Remove('auto')
    $hostnameDoc['hostname'] = $NodeName

    $yamlParts = foreach ($doc in $docs) { ConvertTo-Yaml -Data $doc }
    New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
    ($yamlParts -join "---`n") | Set-Content -Path $OutputPath -Encoding utf8
}

# ---------------------------------------------------------------------------
# Prerequisites and inventory
# ---------------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name Hyper-V)) { throw 'The Hyper-V PowerShell module is not available.' }
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "The 'powershell-yaml' module is required. Install it with:`n  Install-Module -Name powershell-yaml -Scope CurrentUser -Force"
}
Import-Module Hyper-V -ErrorAction Stop
Import-Module powershell-yaml -ErrorAction Stop

if (-not (Get-Command $TalosctlPath -ErrorAction SilentlyContinue)) {
    throw "talosctl not found at '$TalosctlPath'. Pass -TalosctlPath, or make sure it's on PATH."
}

if (-not (Test-Path $InventoryPath)) { throw "Inventory file not found: $InventoryPath" }
$inventory = ConvertFrom-Yaml -Yaml (Get-Content -Path $InventoryPath -Raw)
$nodes = @($inventory.nodes)
if (-not $nodes) { throw "No nodes defined in $InventoryPath." }

if (-not $GatewayAddress) {
    $octets = $nodes[0].address -split '\.'
    $GatewayAddress = '{0}.{1}.{2}.1' -f $octets[0], $octets[1], $octets[2]
    Write-Log "Inferred gateway address $GatewayAddress from node '$($nodes[0].name)' ($($nodes[0].address))."
}

$clientVersion = (& $TalosctlPath version --client --short 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1).Matches.Value
if ($clientVersion -and $inventory.cluster.talosVersion -and ("v$clientVersion" -ne $inventory.cluster.talosVersion)) {
    Write-Log "talosctl client is v$clientVersion but cluster.talosVersion is $($inventory.cluster.talosVersion) -- gen config may pick defaults that don't match. Use a matching talosctl build." -Level Warning
}

# ---------------------------------------------------------------------------
# Generate machine configs (once, unless -Force)
# ---------------------------------------------------------------------------

$talosconfigPath = Join-Path $OutputDir 'talosconfig'
$controlplaneTemplate = Join-Path $OutputDir 'controlplane.yaml'
$workerTemplate = Join-Path $OutputDir 'worker.yaml'
$configsExist = (Test-Path $controlplaneTemplate) -and (Test-Path $workerTemplate)

if ($configsExist -and -not $Force) {
    Write-Log "Reusing existing generated configs in $OutputDir (pass -Force to regenerate)."
} else {
    if ($configsExist -and $Force -and -not $AllowRegenerate) {
        $anyLive = $nodes | Where-Object { Test-NodeReachable -Address $_.address -TalosconfigPath $talosconfigPath }
        if ($anyLive) {
            throw "Regenerating configs would invalidate the PKI that already-live node(s) trust ($($anyLive.name -join ', ')), breaking them. Pass -AllowRegenerate too if you really mean to do this (you will need to re-apply every node, including ones already up)."
        }
    }
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $k8sVersion = $inventory.cluster.kubernetesVersion -replace '^v', ''
    Write-Log "Generating machine configs for '$($inventory.cluster.name)' pinned to Kubernetes $k8sVersion..."
    Invoke-Talosctl -Arguments @(
        'gen', 'config', $inventory.cluster.name, $inventory.cluster.endpoint,
        '--kubernetes-version', $k8sVersion, '--output-dir', $OutputDir, '--force'
    ) | Out-Null
}

$bootstrapAlias = Get-SwitchHostInterfaceAlias -SwitchName $BootstrapSwitchName

# ---------------------------------------------------------------------------
# Per-node: static config + DHCP-bootstrap dance (skipped if already reachable)
# ---------------------------------------------------------------------------

$failedNodes = @()

foreach ($node in $nodes) {
    if (Test-NodeReachable -Address $node.address -TalosconfigPath $talosconfigPath) {
        Write-Log "$($node.name) ($($node.address)) already reachable -- skipping."
        continue
    }

    Write-Log "Bootstrapping $($node.name) ($($node.address))..."
    try {
        $template = if ($node.role -eq 'controlplane') { $controlplaneTemplate } else { $workerTemplate }
        $patchedPath = Join-Path $OutputDir "generated\$($node.name).yaml"
        Set-TalosNodeConfig -TemplatePath $template -OutputPath $patchedPath -NodeName $node.name `
            -MacAddress $node.macAddress -Address $node.address -PrefixLength $PrefixLength `
            -GatewayAddress $GatewayAddress -Nameservers $Nameservers

        Get-VMNetworkAdapter -VMName $node.name | Connect-VMNetworkAdapter -SwitchName $BootstrapSwitchName -ErrorAction Stop
        $dhcpIp = Wait-ForDhcpLease -MacAddress $node.macAddress -HostInterfaceAlias $bootstrapAlias -TimeoutSeconds $DhcpTimeoutSeconds
        Write-Log "$($node.name) reachable via DHCP at $dhcpIp for bootstrap."
        Wait-ForMaintenanceApi -Address $dhcpIp -TimeoutSeconds $MaintenanceTimeoutSeconds

        Invoke-Talosctl -Arguments @('apply-config', '--insecure', '-n', $dhcpIp, '-e', $dhcpIp, '--file', $patchedPath) | Out-Null

        Get-VMNetworkAdapter -VMName $node.name | Connect-VMNetworkAdapter -SwitchName $inventory.hyperv.switch -ErrorAction Stop
        Wait-ForNodeReachable -Address $node.address -TalosconfigPath $talosconfigPath -TimeoutSeconds $StaticTimeoutSeconds
        Write-Log "$($node.name) is up at its static address $($node.address)."
    } catch {
        Write-Log "Failed to bootstrap $($node.name): $_" -Level Error
        $failedNodes += $node.name
    }
}

if ($failedNodes.Count -gt 0) {
    Write-Log "Node(s) failed to bootstrap: $($failedNodes -join ', ')" -Level Warning
}

# ---------------------------------------------------------------------------
# Cluster bootstrap + kubeconfig
# ---------------------------------------------------------------------------

if ($SkipBootstrap) {
    Write-Log '-SkipBootstrap set -- not running talosctl bootstrap or fetching kubeconfig.'
    if ($failedNodes.Count -gt 0) { exit 1 }
    exit 0
}

$controlplaneNode = $nodes | Where-Object { $_.role -eq 'controlplane' } | Select-Object -First 1
if (-not $controlplaneNode) { throw 'No controlplane-role node in inventory; cannot bootstrap etcd.' }

if ($controlplaneNode.name -in $failedNodes) {
    Write-Log "Control-plane node '$($controlplaneNode.name)' did not come up -- skipping cluster bootstrap/kubeconfig." -Level Error
    exit 1
}

$cpAddress = $controlplaneNode.address
if (Test-EtcdBootstrapped -Address $cpAddress -TalosconfigPath $talosconfigPath) {
    Write-Log 'etcd already bootstrapped.'
} else {
    Write-Log "Bootstrapping etcd on $($controlplaneNode.name) ($cpAddress)..."
    Invoke-Talosctl -Arguments @('--talosconfig', $talosconfigPath, '-n', $cpAddress, '-e', $cpAddress, 'bootstrap') | Out-Null
}

Write-Log 'Fetching kubeconfig...'
Invoke-Talosctl -Arguments @('--talosconfig', $talosconfigPath, '-n', $cpAddress, '-e', $cpAddress, 'kubeconfig', $OutputDir, '--force') | Out-Null

$healthy = Invoke-Talosctl -Arguments @('--talosconfig', $talosconfigPath, '-n', $cpAddress, '-e', $cpAddress, 'health', '--wait-timeout', '3m') -AllowFailure
if ($healthy) {
    Write-Log 'Cluster is healthy.'
} else {
    Write-Log 'Cluster health check did not complete in time -- check manually with talosctl health.' -Level Warning
}

if ($failedNodes.Count -gt 0) { exit 1 }
exit 0
