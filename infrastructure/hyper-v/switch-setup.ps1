<#
    Creates and reconciles the Hyper-V vSwitch that cluster-setup.ps1 attaches
    VMs to. Deliberately a separate, manually-invoked script: changing a
    vSwitch can briefly interrupt host networking, so this must never run
    from the scheduled task -- see README.md.

    Supports two topologies:
      -Mode External  binds the switch to a physical NIC (needs a spare,
                       connected adapter and DHCP/routing on that network).
      -Mode Internal  host-only switch + Windows NAT, for hosts with no
                       spare physical NIC (e.g. Wi-Fi-only laptops/NUCs).
                       There's no DHCP on this network -- node addressing is
                       handled by static config in the Talos machine configs
                       (see README.md), not by this script.

    Safe to re-run: if the switch already matches the requested (or, absent
    -Mode, the existing) type it does nothing. Changing types migrates any
    attached VMs to the new switch before removing the old one, rather than
    assuming Remove-VMSwitch will succeed while VMs are still attached.
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'cluster-inventory.yaml'),
    [string]$SwitchName,
    [ValidateSet('External', 'Internal')]
    [string]$Mode,
    [string]$NetAdapterName,
    [bool]$AllowManagementOS = $true,
    [string]$GatewayAddress,
    [int]$PrefixLength = 24,
    [string]$NatName
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

function Get-NetworkAddress {
    param([Parameter(Mandatory)][string]$IPAddress, [Parameter(Mandatory)][int]$PrefixLength)
    $ipBytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    $maskBits = ('1' * $PrefixLength).PadRight(32, '0')
    $maskBytes = 0..3 | ForEach-Object { [Convert]::ToByte($maskBits.Substring($_ * 8, 8), 2) }
    $netBytes = 0..3 | ForEach-Object { $ipBytes[$_] -band $maskBytes[$_] }
    $netBytes -join '.'
}

function Get-AttachedVMNetworkAdapters {
    param([Parameter(Mandatory)][guid]$SwitchId)
    Get-VM | Get-VMNetworkAdapter | Where-Object { $_.SwitchId -eq $SwitchId }
}

function Wait-ForManagementAdapter {
    # Get-VMNetworkAdapter -ManagementOS's .Name is a Hyper-V-level label (e.g.
    # "k8s-external"), NOT the Windows InterfaceAlias New-NetIPAddress etc. need
    # (e.g. "vEthernet (k8s-external) 2" -- Windows appends a numeric suffix
    # whenever the plain name was already taken by a since-removed switch).
    # MAC address is the reliable join key between the two object types.
    param([Parameter(Mandatory)][string]$SwitchName, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $vNic = Get-VMNetworkAdapter -ManagementOS -SwitchName $SwitchName -ErrorAction SilentlyContinue
        if ($vNic) {
            $mac = ($vNic.MacAddress -replace '[-:]', '').ToUpperInvariant()
            $netAdapter = Get-NetAdapter | Where-Object { ($_.MacAddress -replace '[-:]', '').ToUpperInvariant() -eq $mac }
            if ($netAdapter) { return $netAdapter }
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    throw "Could not resolve the Windows network adapter for switch '$SwitchName' management OS NIC within ${TimeoutSeconds}s."
}

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V feature first.'
}
Import-Module Hyper-V -ErrorAction Stop

if (-not $SwitchName) {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "No -SwitchName given and reading it from the inventory requires the 'powershell-yaml' module:`n  Install-Module -Name powershell-yaml -Scope CurrentUser -Force"
    }
    Import-Module powershell-yaml -ErrorAction Stop
    if (-not (Test-Path $InventoryPath)) { throw "Inventory file not found: $InventoryPath" }
    $inventory = ConvertFrom-Yaml -Yaml (Get-Content -Path $InventoryPath -Raw)
    $SwitchName = $inventory.hyperv.switch
    if (-not $SwitchName) { throw "No -SwitchName given and 'hyperv.switch' is not set in $InventoryPath." }
}

if (-not $NatName) { $NatName = "$SwitchName-nat" }
$tempName = "$SwitchName-pending"

# ---------------------------------------------------------------------------
# Clean up a leftover temp switch from a previously interrupted run
# ---------------------------------------------------------------------------

$stalePending = Get-VMSwitch -Name $tempName -ErrorAction SilentlyContinue
if ($stalePending) {
    $strandedVMs = Get-AttachedVMNetworkAdapters -SwitchId $stalePending.Id
    if ($strandedVMs) {
        throw "Switch '$tempName' from a previous interrupted run still has VM(s) attached: $($strandedVMs.VMName -join ', '). Reconnect them manually (Connect-VMNetworkAdapter) before re-running this script."
    }
    Write-Log "Removing leftover '$tempName' from a previously interrupted run." -Level Warning
    $stalePending | Remove-VMSwitch -Force -Confirm:$false -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Reconcile the switch itself
# ---------------------------------------------------------------------------

$existing = @(Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)
if ($existing.Count -gt 1) {
    Write-Log "Found $($existing.Count) switches named '$SwitchName' (a prior interrupted run?). Reconciling to one." -Level Warning
}

$matchesMode = { param($sw) (-not $Mode) -or ($sw.SwitchType -eq $Mode) }
$keep = $existing | Where-Object $matchesMode | Select-Object -First 1

if ($keep -and $existing.Count -eq 1) {
    Write-Log "Switch '$SwitchName' already exists as $($keep.SwitchType). Nothing to do for the switch itself."
    $vmSwitch = $keep
} else {
    if (-not $Mode) {
        throw "Switch '$SwitchName' needs to be created or changed (found: $(@($existing.SwitchType) -join ', ')), but -Mode was not given. Pass -Mode External -NetAdapterName <nic> or -Mode Internal."
    }

    if ($Mode -eq 'External') {
        if (-not $NetAdapterName) { throw "-Mode External requires -NetAdapterName." }
        $nic = Get-NetAdapter -Name $NetAdapterName -ErrorAction Stop
        if ($nic.Status -ne 'Up') {
            Write-Log "Adapter '$NetAdapterName' reports status '$($nic.Status)', not Up. An External switch bound to a disconnected or Wi-Fi adapter typically won't pass traffic to VMs -- consider -Mode Internal instead." -Level Warning
        }
        New-VMSwitch -Name $tempName -NetAdapterName $NetAdapterName -AllowManagementOS $AllowManagementOS -ErrorAction Stop | Out-Null
    } else {
        New-VMSwitch -Name $tempName -SwitchType Internal -ErrorAction Stop | Out-Null
    }

    foreach ($old in $existing) {
        $attached = Get-AttachedVMNetworkAdapters -SwitchId $old.Id
        if ($attached) {
            $newSwitchObj = Get-VMSwitch -Name $tempName
            Write-Log "Reconnecting $($attached.Count) VM NIC(s) from old '$($old.Name)' ($($old.SwitchType)) to '$tempName': $($attached.VMName -join ', ')"
            $attached | Connect-VMNetworkAdapter -VMSwitch $newSwitchObj -ErrorAction Stop
        }
        $old | Remove-VMSwitch -Force -Confirm:$false -ErrorAction Stop
    }

    Rename-VMSwitch -Name $tempName -NewName $SwitchName -ErrorAction Stop
    $vmSwitch = Get-VMSwitch -Name $SwitchName
    Write-Log "Switch '$SwitchName' is now $($vmSwitch.SwitchType)."

    if ($vmSwitch.SwitchType -eq 'Internal') {
        # Rename-VMSwitch only renames the Hyper-V switch object -- the host's
        # vEthernet NetAdapter keeps its old alias (still "vEthernet ($tempName)")
        # unless renamed explicitly, which would otherwise leave the gateway IP
        # permanently sitting on an adapter named "...-pending".
        $pendingNic = Wait-ForManagementAdapter -SwitchName $SwitchName
        $desiredAlias = "vEthernet ($SwitchName)"
        if ($pendingNic.Name -ne $desiredAlias) {
            Rename-NetAdapter -Name $pendingNic.Name -NewName $desiredAlias -ErrorAction Stop
            Write-Log "Renamed host adapter '$($pendingNic.Name)' to '$desiredAlias'."
        }
    }
}

# ---------------------------------------------------------------------------
# Internal mode: gateway IP + NAT + firewall profile
# ---------------------------------------------------------------------------

if ($vmSwitch.SwitchType -eq 'Internal') {
    if (-not $GatewayAddress) {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            throw "-Mode Internal requires -GatewayAddress (or install 'powershell-yaml' so it can be inferred from the inventory)."
        }
        if (-not $inventory) {
            Import-Module powershell-yaml -ErrorAction Stop
            if (-not (Test-Path $InventoryPath)) { throw "Inventory file not found: $InventoryPath" }
            $inventory = ConvertFrom-Yaml -Yaml (Get-Content -Path $InventoryPath -Raw)
        }
        $firstNode = $inventory.nodes | Select-Object -First 1
        if (-not $firstNode) { throw 'Cannot infer -GatewayAddress: no nodes in inventory. Pass it explicitly.' }
        $octets = $firstNode.address -split '\.'
        $GatewayAddress = '{0}.{1}.{2}.1' -f $octets[0], $octets[1], $octets[2]
        Write-Log "Inferred gateway address $GatewayAddress from node '$($firstNode.name)' ($($firstNode.address))."
    }

    $mgmtNic = Wait-ForManagementAdapter -SwitchName $SwitchName
    $ifAlias = $mgmtNic.Name

    $currentIp = Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -eq 'Manual' } | Select-Object -First 1

    if (-not $currentIp -or $currentIp.IPAddress -ne $GatewayAddress -or $currentIp.PrefixLength -ne $PrefixLength) {
        Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -eq 'Manual' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        try { Set-NetIPInterface -InterfaceAlias $ifAlias -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop } catch {}
        New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $GatewayAddress -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
        Write-Log "Set $ifAlias to $GatewayAddress/$PrefixLength."
    } else {
        Write-Log "Gateway address already set: $GatewayAddress/$PrefixLength on '$ifAlias'."
    }

    $natPrefix = '{0}/{1}' -f (Get-NetworkAddress -IPAddress $GatewayAddress -PrefixLength $PrefixLength), $PrefixLength
    $existingNat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if (-not $existingNat) {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $natPrefix -ErrorAction Stop | Out-Null
        Write-Log "Created NAT '$NatName' for $natPrefix."
    } elseif ($existingNat.InternalIPInterfaceAddressPrefix -ne $natPrefix) {
        $existingNat | Remove-NetNat -Confirm:$false -ErrorAction Stop
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $natPrefix -ErrorAction Stop | Out-Null
        Write-Log "Recreated NAT '$NatName' for $natPrefix (was $($existingNat.InternalIPInterfaceAddressPrefix))."
    } else {
        Write-Log "NAT rule '$NatName' already covers $natPrefix."
    }

    $netProfile = Get-NetConnectionProfile -InterfaceAlias $ifAlias -ErrorAction SilentlyContinue
    if ($netProfile -and $netProfile.NetworkCategory -ne 'Private') {
        Set-NetConnectionProfile -InterfaceAlias $ifAlias -NetworkCategory Private -ErrorAction Stop
        Write-Log "Set '$ifAlias' network category to Private."
    }

    Write-Log "Internal switch '$SwitchName' ready: gateway $GatewayAddress/$PrefixLength, NAT '$NatName' -> $natPrefix. Remember: no DHCP on this network -- nodes need static machine.network config (see README.md)."
} else {
    Write-Log "External switch '$SwitchName' bound to a physical adapter. No NAT/gateway configuration needed here -- DHCP/routing is whatever's upstream on that network."
}
