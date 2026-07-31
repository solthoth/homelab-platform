<#
    Bridges the home LAN (Wi-Fi-facing) to the cluster's shared Cilium
    Ingress LoadBalancer Service. Nothing besides this host is attached to
    the k8s-external vSwitch's L2 segment, so no other LAN device can ever
    reach 10.20.10.0/24 directly -- this script is what makes the shared
    ingress reachable from the rest of the LAN, by forwarding LAN-facing
    ports to it.

    Discovers the shared ingress Service's current LoadBalancer IP via
    kubectl (LB-IPAM assigns it dynamically from a CiliumLoadBalancerIPPool --
    never hardcoded here) and forwards it via `netsh interface portproxy`,
    plus a matching Windows Firewall inbound-allow rule scoped to the LAN's
    own CIDR (not "Any").

    DNS-01 (Azure DNS) never needs port 80 open on any interface -- it's
    HTTP-01 that would. Port 80 here exists purely so a bare http:// hit gets
    Cilium's enforceHttps redirect to https://, which is why it's opt-in via
    -IncludeHttp rather than forwarded by default.

    Safe to re-run: compares current netsh/firewall state against the
    freshly-discovered backend IP and desired ports, and only changes what's
    stale (e.g. after the LB pool reassigns a different IP). No scheduled
    task for this one -- LB-IPAM keeps the IP stable across restarts once
    assigned; re-run manually after an intentional pool change.
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$KubeconfigPath = $(if ($env:KUBECONFIG) { $env:KUBECONFIG } else { Join-Path $PSScriptRoot 'talosconfig\kubeconfig' }),
    [string]$ServiceNamespace = 'kube-system',
    [string]$ServiceName = 'cilium-ingress',
    [string]$KubectlPath = 'kubectl',
    [string]$ListenAddress,
    [string]$LanCidr,
    [switch]$IncludeHttp,
    [string]$RuleName = 'HomelabIngressBridge-Inbound'
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
    # Kept in sync with switch-setup.ps1's copy of the same helper.
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

if (-not (Get-Command $KubectlPath -ErrorAction SilentlyContinue)) {
    throw "kubectl not found at '$KubectlPath'. Pass -KubectlPath, or make sure it's on PATH."
}
if (-not (Test-Path $KubeconfigPath)) {
    throw "Kubeconfig not found at '$KubeconfigPath'. Pass -KubeconfigPath or set `$env:KUBECONFIG."
}

# ---------------------------------------------------------------------------
# Discover the shared ingress Service's current LoadBalancer IP
# ---------------------------------------------------------------------------

$svcJson = & $KubectlPath --kubeconfig $KubeconfigPath -n $ServiceNamespace get svc $ServiceName -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $svcJson) {
    throw "Could not read Service '$ServiceNamespace/$ServiceName' via kubectl. Has the cilium-lb-pool addon synced yet ('argocd app get cilium-lb-pool', 'kubectl -n $ServiceNamespace get svc')?"
}
$svc = $svcJson | ConvertFrom-Json
$backendIp = $svc.status.loadBalancer.ingress | Select-Object -First 1 -ExpandProperty ip -ErrorAction SilentlyContinue
if (-not $backendIp -or $backendIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "Service '$ServiceNamespace/$ServiceName' has no LoadBalancer IP yet. Check 'kubectl get ciliumloadbalancerippools,ciliuml2announcementpolicies' -- LB-IPAM may not have a free address, or nothing is announcing it on the L2 segment yet."
}

$desiredPorts = @(443)
if ($IncludeHttp) { $desiredPorts += 80 }
$managedPorts = @(443, 80)   # everything this script ever owns, so toggling -IncludeHttp off also cleans up port 80's rules

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
# Reconcile portproxy rules
# ---------------------------------------------------------------------------

$existingRules = Get-PortProxyRules

foreach ($port in $managedPorts) {
    $existing = $existingRules | Where-Object { $_.ListenAddress -eq $ListenAddress -and $_.ListenPort -eq $port }
    $wanted = $port -in $desiredPorts

    if (-not $wanted) {
        if ($existing) {
            netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$port | Out-Null
            Write-Log "Removed forward for $ListenAddress`:$port (not requested; pass -IncludeHttp to keep 80)."
        }
        continue
    }

    if ($existing -and $existing.ConnectAddress -eq $backendIp -and $existing.ConnectPort -eq $port) {
        Write-Log "$ListenAddress`:$port -> $backendIp`:$port already in place."
        continue
    }

    if ($existing) {
        netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$port | Out-Null
        Write-Log "Replacing stale forward $ListenAddress`:$port -> $($existing.ConnectAddress):$($existing.ConnectPort) (backend changed)." -Level Warning
    }
    netsh interface portproxy add v4tov4 listenaddress=$ListenAddress listenport=$port connectaddress=$backendIp connectport=$port | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "netsh portproxy add failed for $ListenAddress`:$port" }
    Write-Log "Forwarding $ListenAddress`:$port -> $backendIp`:$port"
}

# ---------------------------------------------------------------------------
# Reconcile the firewall rule (scoped to the LAN, not open to every source)
# ---------------------------------------------------------------------------

$existingFw = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
$fwMatches = $false
if ($existingFw) {
    $portFilter = $existingFw | Get-NetFirewallPortFilter
    $addrFilter = $existingFw | Get-NetFirewallAddressFilter
    $currentPorts = @($portFilter.LocalPort | Sort-Object) -join ','
    $desiredPortsStr = @($desiredPorts | Sort-Object) -join ','
    $fwMatches = ($currentPorts -eq $desiredPortsStr) -and ($addrFilter.RemoteAddress -eq $LanCidr)
}

if (-not $fwMatches) {
    if ($existingFw) {
        $existingFw | Remove-NetFirewallRule -Confirm:$false
        Write-Log "Removed out-of-date firewall rule '$RuleName'." -Level Warning
    }
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $desiredPorts -RemoteAddress $LanCidr -Profile Any -ErrorAction Stop | Out-Null
    Write-Log "Firewall rule '$RuleName' allows TCP $($desiredPorts -join ',') from $LanCidr."
} else {
    Write-Log "Firewall rule '$RuleName' already matches desired state."
}

Write-Log "LAN clients can now reach https://$ListenAddress/ (forwarded to $backendIp`:443 in-cluster). Re-run this script any time the shared ingress IP changes (e.g. after editing cilium-lb-pool's CiliumLoadBalancerIPPool)."
