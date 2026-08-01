<#
    Mints a scoped, individually-revocable kubectl credential for a new
    person or device, instead of ever handing out the cluster-admin
    kubeconfig talos-bootstrap.ps1 produces.

    Mechanism: Kubernetes' built-in CertificateSigningRequest API.
    - Generates an ECDSA P-256 keypair and a CSR (CN=<Username>, and O=<Group>
      for each -Group given) entirely via .NET's CertificateRequest -- no
      openssl/cfssl dependency.
    - Submits it as a CertificateSigningRequest with
      signerName=kubernetes.io/kube-apiserver-client, approves it (this
      signer is NOT auto-approved by Talos/Kubernetes by default -- an
      admin approval step is the point), and reads back the cert the
      cluster's own CA just signed.
    - Ensures a ClusterRoleBinding exists binding that exact Username (kind:
      User, not Group -- see "Revocation" below for why) to -ClusterRole.
    - Assembles a ready-to-use kubeconfig pointed at the LAN-forwarded API
      address (see k8s-api-bridge.ps1) and writes it under
      talosconfig/issued/, which inherits talosconfig/'s .gitignore rule --
      these are live credentials, same handling as the admin kubeconfig.

    Requires an ADMIN kubeconfig to run (default: talosconfig/kubeconfig) --
    this script is what an admin runs to onboard someone else, it doesn't
    bootstrap itself from nothing.

    ---------------------------------------------------------------------
    REVOCATION -- read this before treating this as equivalent to OIDC/SSO
    ---------------------------------------------------------------------
    Kubernetes' native x509 client-cert auth has NO certificate revocation
    list or OCSP. A signed client cert remains cryptographically valid,
    and will keep AUTHENTICATING successfully, until it expires --
    regardless of anything you do to RBAC. What you actually control is
    AUTHORIZATION: revoke-cluster-user.ps1 deletes the ClusterRoleBinding,
    so a revoked identity still proves who it is but is authorized for
    nothing (every API call 403s) -- functionally equivalent to revocation
    for practical purposes, but not the same guarantee a CRL/OIDC token
    revocation gives you. The actual safety net is -ExpirationDays: keep it
    short (default 90) so a credential you forgot to revoke, or a
    compromised device you don't yet know about, ages out on its own. If
    you ever need a true hard cutover (e.g. a known key compromise), the
    only real lever is rotating the cluster's signing CA -- which breaks
    every other issued credential too, including your own admin one. This
    is a well-known limitation of native Kubernetes client-cert auth, not a
    gap specific to this script -- it's exactly why larger clusters move to
    OIDC once the number of users grows past a handful.

    Safe to re-run for the same Username: the ClusterRoleBinding is applied
    idempotently (same deterministic name), so re-running just issues that
    person a fresh cert (e.g. after their old one expired) without touching
    anyone else's access.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Username,
    [string[]]$Group = @(),
    [string]$ClusterRole = 'view',
    [int]$ExpirationDays = 90,
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'cluster-inventory.yaml'),
    [string]$ApiServerAddress,
    [int]$ApiServerPort = 6443,
    [string]$AdminKubeconfigPath = (Join-Path $PSScriptRoot 'talosconfig\kubeconfig'),
    [string]$OutputDir = (Join-Path $PSScriptRoot 'talosconfig\issued'),
    [string]$KubectlPath = 'kubectl',
    [int]$ApprovalTimeoutSeconds = 30
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

function Invoke-Kubectl {
    # Wraps kubectl: a non-zero exit code doesn't become a terminating
    # PowerShell error on its own, which would otherwise let a failed
    # apply/approve silently fall through as "success" (see talos-bootstrap.ps1).
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    $output = & $KubectlPath --kubeconfig $AdminKubeconfigPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "kubectl $($Arguments -join ' ') exited $($LASTEXITCODE): $output"
    }
    return $output
}

function ConvertTo-SanitizedName {
    # Kubernetes object names must be lowercase DNS-1123 subdomains; a
    # human-friendly Username (e.g. "Carlos B", "carlos@macbook") isn't
    # necessarily one, so derive a safe object-name form without losing the
    # original as the cert's CN.
    param([Parameter(Mandatory)][string]$Value)
    $lowered = $Value.ToLowerInvariant() -replace '[^a-z0-9.-]', '-'
    $trimmed = $lowered.Trim('-')
    if (-not $trimmed) { throw "Username '$Value' has no usable characters for a Kubernetes object name." }
    return $trimmed
}

if (-not (Get-Command $KubectlPath -ErrorAction SilentlyContinue)) {
    throw "kubectl not found at '$KubectlPath'. Pass -KubectlPath, or make sure it's on PATH."
}
if (-not (Test-Path $AdminKubeconfigPath)) {
    throw "Admin kubeconfig not found at '$AdminKubeconfigPath'. This script needs cluster-admin access to approve the CSR and manage RBAC -- pass -AdminKubeconfigPath if it lives elsewhere."
}

$sanitized = ConvertTo-SanitizedName -Value $Username
$csrName = "homelab-user-$sanitized-$(Get-Date -Format 'yyyyMMddHHmmss')"
$bindingName = "homelab-user-$sanitized"

# ---------------------------------------------------------------------------
# Resolve cluster name + API address
# ---------------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "The 'powershell-yaml' module is required. Install it with:`n  Install-Module -Name powershell-yaml -Scope CurrentUser -Force"
}
Import-Module powershell-yaml -ErrorAction Stop

if (-not (Test-Path $InventoryPath)) { throw "Inventory file not found: $InventoryPath" }
$inventory = ConvertFrom-Yaml -Yaml (Get-Content -Path $InventoryPath -Raw)
$clusterName = $inventory.cluster.name

if (-not $ApiServerAddress) {
    # Same auto-detect convention as k8s-api-bridge.ps1 -- this script
    # assumes that bridge is what a remote user will actually connect
    # through, so it defaults to the same LAN-facing address.
    $lanConfig = Get-NetIPConfiguration | Where-Object {
        $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.InterfaceAlias -notmatch '^vEthernet'
    } | Select-Object -First 1
    if (-not $lanConfig) {
        throw 'Could not auto-detect a LAN-facing adapter. Pass -ApiServerAddress explicitly (the address k8s-api-bridge.ps1 forwards port 6443 on).'
    }
    $ApiServerAddress = $lanConfig.IPv4Address[0].IPAddress
    Write-Log "Auto-detected API server address $ApiServerAddress (same convention as k8s-api-bridge.ps1)."
}

# ---------------------------------------------------------------------------
# Generate keypair + CSR (pure .NET -- no openssl/cfssl dependency)
# ---------------------------------------------------------------------------

Write-Log "Generating ECDSA P-256 keypair and CSR for CN=$Username$(if ($Group) { ", O=$($Group -join ',O=')" })..."
Add-Type -AssemblyName System.Security
$ecdsa = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
try {
    $subjectParts = @("CN=$Username") + ($Group | ForEach-Object { "O=$_" })
    $subject = [string]::Join(',', $subjectParts)
    $certRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $subject, $ecdsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $csrPem = $certRequest.CreateSigningRequestPem()
    $keyPem = $ecdsa.ExportPkcs8PrivateKeyPem()
} finally {
    $ecdsa.Dispose()
}

# ---------------------------------------------------------------------------
# Submit + approve the CertificateSigningRequest
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$csrBytes = [System.Text.Encoding]::ASCII.GetBytes($csrPem)
$csrBase64 = [Convert]::ToBase64String($csrBytes)
$expirationSeconds = $ExpirationDays * 24 * 60 * 60

$csrManifest = @"
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $csrName
spec:
  request: $csrBase64
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
  expirationSeconds: $expirationSeconds
"@
$csrManifestPath = Join-Path $OutputDir "$csrName.csr.yaml"
$csrManifest | Set-Content -Path $csrManifestPath -Encoding ascii

Write-Log "Submitting CertificateSigningRequest/$csrName (requested validity: $ExpirationDays days)..."
Invoke-Kubectl -Arguments @('apply', '-f', $csrManifestPath) | Out-Null
Remove-Item -Path $csrManifestPath -Force

Write-Log "Approving CertificateSigningRequest/$csrName..."
Invoke-Kubectl -Arguments @('certificate', 'approve', $csrName) | Out-Null

Write-Log 'Waiting for the cluster CA to sign it...'
$deadline = (Get-Date).AddSeconds($ApprovalTimeoutSeconds)
$signedCertB64 = $null
do {
    $signedCertB64 = Invoke-Kubectl -Arguments @('get', 'csr', $csrName, '-o', 'jsonpath={.status.certificate}') -AllowFailure
    if ($signedCertB64) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
if (-not $signedCertB64) {
    throw "CertificateSigningRequest/$csrName was approved but no signed certificate appeared within ${ApprovalTimeoutSeconds}s. Check 'kubectl describe csr $csrName' and that kube-controller-manager has --cluster-signing-cert-file/--cluster-signing-key-file configured."
}
$certPem = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($signedCertB64))
Write-Log 'Certificate issued.'

# The signed cert is now embedded in the kubeconfig below -- the CSR object
# itself has no further purpose and would otherwise linger in `kubectl get
# csr` forever. Deleting it does NOT revoke the cert (see header comment).
Invoke-Kubectl -Arguments @('delete', 'csr', $csrName) -AllowFailure | Out-Null

# ---------------------------------------------------------------------------
# Ensure the RBAC binding exists (idempotent: deterministic name, kubectl apply)
# ---------------------------------------------------------------------------

Write-Log "Ensuring ClusterRoleBinding/$bindingName grants ClusterRole/$ClusterRole to User=$Username..."
$bindingManifest = @"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $bindingName
  labels:
    homelab.local/managed-by: new-cluster-user.ps1
subjects:
- kind: User
  name: $Username
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: $ClusterRole
  apiGroup: rbac.authorization.k8s.io
"@
$bindingManifestPath = Join-Path $OutputDir "$bindingName.binding.yaml"
$bindingManifest | Set-Content -Path $bindingManifestPath -Encoding ascii
Invoke-Kubectl -Arguments @('apply', '-f', $bindingManifestPath) | Out-Null
Remove-Item -Path $bindingManifestPath -Force

# ---------------------------------------------------------------------------
# Assemble the kubeconfig
# ---------------------------------------------------------------------------

Write-Log 'Fetching cluster CA (kube-root-ca.crt configmap)...'
$caB64Raw = Invoke-Kubectl -Arguments @('get', 'configmap', 'kube-root-ca.crt', '-n', 'default', '-o', 'jsonpath={.data.ca\.crt}')
$caB64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(($caB64Raw -join "`n")))
$certB64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($certPem))
$keyB64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($keyPem))
$contextName = "$sanitized@$clusterName"

$kubeconfig = @"
apiVersion: v1
kind: Config
clusters:
- name: $clusterName
  cluster:
    server: https://$ApiServerAddress`:$ApiServerPort
    certificate-authority-data: $caB64
users:
- name: $Username
  user:
    client-certificate-data: $certB64
    client-key-data: $keyB64
contexts:
- name: $contextName
  context:
    cluster: $clusterName
    user: $Username
current-context: $contextName
"@

$outputPath = Join-Path $OutputDir "$sanitized-kubeconfig"
$kubeconfig | Set-Content -Path $outputPath -Encoding ascii

Write-Log "Wrote $outputPath"
Write-Host ''
Write-Log "Next steps:"
Write-Log "  1. Transfer $outputPath to $Username's device over any channel you trust (it's a scoped, $ExpirationDays-day credential, not the cluster-admin master key -- but still a live credential, so treat it like one: no email/chat, prefer AirDrop/USB/SCP/a temporary secure share)."
Write-Log "  2. On that device: export KUBECONFIG=<path to this file>  (or merge it into ~/.kube/config) -- see kubernetes/README.md's 'Remote cluster access' section for OS-specific steps."
Write-Log "  3. To revoke this person's access later, run: .\revoke-cluster-user.ps1 -Username '$Username'  -- note this removes AUTHORIZATION only; the cert itself stays valid until it expires in $ExpirationDays days (see this script's header comment)."
