<#
    Revokes a user provisioned by new-cluster-user.ps1 -- deletes their
    ClusterRoleBinding (homelab-user-<sanitized-username>), i.e. removes
    every authorization they had.

    READ THIS: this does NOT revoke their signed certificate. Kubernetes'
    native x509 client-cert auth has no CRL/OCSP -- their cert stays
    cryptographically valid and will keep AUTHENTICATING successfully
    until it expires (whatever -ExpirationDays was used to mint it). After
    this script runs, every one of their API calls will 403 (no RBAC
    grants left), which is functionally equivalent to revocation for
    practical purposes -- but if you need a true hard guarantee (e.g. a
    known compromised device) before their cert's natural expiry, the only
    further lever is rotating the cluster's signing CA, which invalidates
    every other issued credential too, including your own admin one. See
    new-cluster-user.ps1's header comment for the full explanation.

    Safe to re-run: deleting an already-deleted ClusterRoleBinding is a
    no-op (kubectl delete --ignore-not-found).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Username,
    [string]$AdminKubeconfigPath = (Join-Path $PSScriptRoot 'talosconfig\kubeconfig'),
    [string]$KubectlPath = 'kubectl'
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

if (-not (Get-Command $KubectlPath -ErrorAction SilentlyContinue)) {
    throw "kubectl not found at '$KubectlPath'. Pass -KubectlPath, or make sure it's on PATH."
}
if (-not (Test-Path $AdminKubeconfigPath)) {
    throw "Admin kubeconfig not found at '$AdminKubeconfigPath'. Pass -AdminKubeconfigPath if it lives elsewhere."
}

$sanitized = ($Username.ToLowerInvariant() -replace '[^a-z0-9.-]', '-').Trim('-')
$bindingName = "homelab-user-$sanitized"

if ($PSCmdlet.ShouldProcess("ClusterRoleBinding/$bindingName", 'Delete')) {
    & $KubectlPath --kubeconfig $AdminKubeconfigPath delete clusterrolebinding $bindingName --ignore-not-found
    if ($LASTEXITCODE -ne 0) { throw "kubectl delete clusterrolebinding $bindingName exited $LASTEXITCODE" }
    Write-Log "Removed ClusterRoleBinding/$bindingName -- '$Username' has no RBAC grants left in this cluster."
    Write-Log "Their certificate remains cryptographically valid until it expires -- this only removed authorization, not authentication. See this script's header comment." -Level Warning
}
