<#
    Bridges the home LAN to the cluster's Kubernetes API (port 6443), the
    same way lan-ingress-bridge.ps1 bridges the LAN to Cilium's Ingress --
    nothing besides this host is attached to the k8s-external vSwitch's L2
    segment, so no other LAN device (a MacBook, say) can reach 10.20.10.0/24
    directly without this forward.

    Unlike the ingress bridge, the backend here is the control-plane node's
    static inventory address, not a dynamically-assigned LoadBalancer IP, so
    no kubectl discovery step is needed -- it's read straight out of
    cluster-inventory.yaml.

    For this to actually pass TLS verification, the control-plane's
    kube-apiserver serving cert must already carry the LAN listen address as
    a SAN -- set via talos-bootstrap.ps1's -ApiServerCertSANs (which patches
    cluster.apiServer.certSANs, NOT machine.certSANs -- see that script's
    comments). Re-running this bridge script does not add SANs; if
    kubectl's TLS handshake fails, check the cert first, not the port
    forward.

    Safe to re-run: compares current netsh/firewall state against the
    desired backend/port and only changes what's stale.
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'cluster-inventory.yaml'),
    [string]$ListenAddress,
    [string]$LanCidr,
    [int]$Port = 6443,
    [string]$RuleName = 'HomelabK8sApiBridge-Inbound'
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
    # Kept in sync with switch-setup.ps1's / lan-ingress-bridge.ps1's copy of the same helper.
    param([Parameter(Mandatory)][string]$IPAddress, [Parameter(Mandatory)][int]$PrefixLength)
    $ipBytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    $maskBits = ('1' * $PrefixLength).PadRight(32, '0')
    $maskBytes = 0..3 | ForEach-Object { [Convert]::ToByte($maskBits.Substring($_ * 8, 8), 2) }
    $netBytes = 0..3 | ForEach-Object { $ipBytes[$_] -band $maskBytes[$_] }
    $netBytes -join '.'
}

function Get-PortProxyRules {
    # No first-class PowerShell cmdlet exists for v4tov4 portproxy state;
    # parse netsh's fixed-format table instead.
    $raw = & netsh interface portproxy show v4tov4
    $rules = @()
    foreach ($line in $raw) {
        if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$') {
            $rules += [pscustomobject]@{
                ListenAddress  = $Matches[1]
                ListenPort     = [int]$Matches[2]
                ConnectAddress = $Matches[3]
                ConnectPort    = [int]$Matches[4]
            }
        }
    }
    return $rules
}

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "The 'powershell-yaml' module is required. Install it with:`n  Install-Module -Name powershell-yaml -Scope CurrentUser -Force"
}
Import-Module powershell-yaml -ErrorAction Stop

if (-not (Test-Path $InventoryPath)) { throw "Inventory file not found: $InventoryPath" }
$inventory = ConvertFrom-Yaml -Yaml (Get-Content -Path $InventoryPath -Raw)
$controlplaneNode = @($inventory.nodes) | Where-Object { $_.role -eq 'controlplane' } | Select-Object -First 1
if (-not $controlplaneNode) { throw "No controlplane-role node in $InventoryPath." }
$backendIp = $controlplaneNode.address

# ---------------------------------------------------------------------------
# Resolve the LAN-facing listen address (auto-detected unless -ListenAddress)
# ---------------------------------------------------------------------------

if (-not $ListenAddress) {
    $lanConfig = Get-NetIPConfiguration | Where-Object {
        $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.InterfaceAlias -notmatch '^vEthernet'
    } | Select-Object -First 1
    if (-not $lanConfig) {
        throw 'Could not auto-detect a LAN-facing adapter (an Up adapter with a default gateway, excluding Hyper-V vEthernet adapters -- those front the cluster, not the LAN). Pass -ListenAddress explicitly.'
    }
    $ListenAddress = $lanConfig.IPv4Address[0].IPAddress
    $lanPrefixLength = $lanConfig.IPv4Address[0].PrefixLength
    Write-Log "Auto-detected LAN-facing address $ListenAddress/$lanPrefixLength on '$($lanConfig.InterfaceAlias)'."
} else {
    $addr = Get-NetIPAddress -IPAddress $ListenAddress -AddressFamily IPv4 -ErrorAction Stop
    $lanPrefixLength = $addr.PrefixLength
}

if (-not $LanCidr) {
    $LanCidr = '{0}/{1}' -f (Get-NetworkAddress -IPAddress $ListenAddress -PrefixLength $lanPrefixLength), $lanPrefixLength
}

# ---------------------------------------------------------------------------
# Reconcile the portproxy rule
# ---------------------------------------------------------------------------

$existingRules = Get-PortProxyRules
$existing = $existingRules | Where-Object { $_.ListenAddress -eq $ListenAddress -and $_.ListenPort -eq $Port }

if ($existing -and $existing.ConnectAddress -eq $backendIp -and $existing.ConnectPort -eq $Port) {
    Write-Log "$ListenAddress`:$Port -> $backendIp`:$Port already in place."
} else {
    if ($existing) {
        netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$Port | Out-Null
        Write-Log "Replacing stale forward $ListenAddress`:$Port -> $($existing.ConnectAddress):$($existing.ConnectPort) (backend changed)." -Level Warning
    }
    netsh interface portproxy add v4tov4 listenaddress=$ListenAddress listenport=$Port connectaddress=$backendIp connectport=$Port | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "netsh portproxy add failed for $ListenAddress`:$Port" }
    Write-Log "Forwarding $ListenAddress`:$Port -> $backendIp`:$Port"
}

# ---------------------------------------------------------------------------
# Reconcile the firewall rule (scoped to the LAN, not open to every source)
# ---------------------------------------------------------------------------

$existingFw = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
$fwMatches = $false
if ($existingFw) {
    $portFilter = $existingFw | Get-NetFirewallPortFilter
    $addrFilter = $existingFw | Get-NetFirewallAddressFilter
    $fwMatches = ($portFilter.LocalPort -eq "$Port") -and ($addrFilter.RemoteAddress -eq $LanCidr)
}

if (-not $fwMatches) {
    if ($existingFw) {
        $existingFw | Remove-NetFirewallRule -Confirm:$false
        Write-Log "Removed out-of-date firewall rule '$RuleName'." -Level Warning
    }
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $Port -RemoteAddress $LanCidr -Profile Any -ErrorAction Stop | Out-Null
    Write-Log "Firewall rule '$RuleName' allows TCP $Port from $LanCidr."
} else {
    Write-Log "Firewall rule '$RuleName' already matches desired state."
}

Write-Log "LAN clients can now reach https://$ListenAddress`:$Port (forwarded to $backendIp`:$Port in-cluster). The API server's cert must carry $ListenAddress as a SAN (see talos-bootstrap.ps1 -ApiServerCertSANs) or kubectl's TLS verification will fail."
