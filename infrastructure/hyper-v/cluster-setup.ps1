<#
    Creates and reconciles the Hyper-V VMs described in cluster-inventory.yaml.

    Scope: Hyper-V VM lifecycle only. It does not generate or apply Talos machine
    configs, bootstrap etcd, or touch Kubernetes -- that is a separate talosctl
    step reading the same inventory file. See README.md for the full workflow
    and the drift-handling rules this script follows.
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'cluster-inventory.yaml'),
    [switch]$Validate,
    [switch]$Report,
    [switch]$AllowDisruptive,
    [switch]$AllowDestructive,
    [switch]$InstallScheduledTask,
    [int]$IntervalMinutes = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

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
    $logDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
    Add-Content -Path (Join-Path $logDir "cluster-setup-$(Get-Date -Format 'yyyy-MM-dd').log") -Value $line
}

# ---------------------------------------------------------------------------
# Inventory loading and validation
# ---------------------------------------------------------------------------

function Import-ClusterInventory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "Inventory file not found: $Path" }
    $raw = ConvertFrom-Yaml -Yaml (Get-Content -Path $Path -Raw)

    $cluster = [PSCustomObject]@{
        Name              = $raw.cluster.name
        TalosVersion      = $raw.cluster.talosVersion
        KubernetesVersion = $raw.cluster.kubernetesVersion
        Endpoint          = $raw.cluster.endpoint
    }

    $hyperv = [PSCustomObject]@{
        VmPath               = $raw.hyperv.vmPath
        Switch               = $raw.hyperv.switch
        Generation           = [int]$raw.hyperv.generation
        SecureBoot           = [bool]$raw.hyperv.secureBoot
        DynamicMemory        = [bool]$raw.hyperv.dynamicMemory
        AutomaticCheckpoints = [bool]$raw.hyperv.automaticCheckpoints
        AutomaticStopAction  = $raw.hyperv.automaticStopAction
        MacAddressSpoofing   = [bool]$raw.hyperv.macAddressSpoofing
        HostReserveGB        = [double]$raw.hyperv.hostReserveGB
        IsoPath              = $raw.hyperv.isoPath
    }

    $nodes = foreach ($n in $raw.nodes) {
        $roleDefaults = $raw.defaults[$n.role]
        if (-not $roleDefaults) { throw "No defaults defined for role '$($n.role)' (node '$($n.name)')" }

        $cpu      = if ($n.ContainsKey('cpu'))      { $n.cpu }      else { $roleDefaults.cpu }
        $memoryGB = if ($n.ContainsKey('memoryGB')) { $n.memoryGB } else { $roleDefaults.memoryGB }
        $diskDefs = if ($n.ContainsKey('disks'))    { $n.disks }    else { $roleDefaults.disks }

        $disks = foreach ($d in $diskDefs) {
            [PSCustomObject]@{ Name = $d.name; SizeGB = [int]$d.sizeGB; Type = $d.type }
        }

        [PSCustomObject]@{
            Name       = $n.name
            Role       = $n.role
            Address    = $n.address
            MacAddress = $n.macAddress
            Cpu        = [int]$cpu
            MemoryGB   = [int]$memoryGB
            Disks      = @($disks)
        }
    }

    [PSCustomObject]@{
        Cluster = $cluster
        Hyperv  = $hyperv
        Nodes   = @($nodes)
    }
}

function Test-ClusterInventory {
    param([Parameter(Mandatory)]$Config)

    # Named $validationErrors, not $errors -- PowerShell variable names are
    # case-insensitive, so $errors would silently alias the automatic $Error variable.
    $validationErrors = New-Object System.Collections.Generic.List[string]

    foreach ($group in ($Config.Nodes.Name | Group-Object | Where-Object Count -gt 1)) {
        $validationErrors.Add("Duplicate node name: $($group.Name)")
    }
    # Deliberately NOT $Config.Nodes.Address: PowerShell arrays carry a hidden
    # CLR "Address(int)" member (used for by-ref element access), and dotted
    # member-enumeration binds to that instead of collecting each node's
    # Address property -- silently disabling duplicate-IP detection.
    foreach ($group in ($Config.Nodes | ForEach-Object Address | Group-Object | Where-Object Count -gt 1)) {
        $validationErrors.Add("Duplicate node address: $($group.Name)")
    }
    foreach ($group in ($Config.Nodes.MacAddress | Group-Object | Where-Object Count -gt 1)) {
        $validationErrors.Add("Duplicate MAC address: $($group.Name)")
    }

    foreach ($node in $Config.Nodes) {
        if ($node.MacAddress -notmatch '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$') {
            $validationErrors.Add("Node '$($node.Name)': MAC address '$($node.MacAddress)' is not in NN-NN-NN-NN-NN-NN format")
        }
        if ($node.Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            $validationErrors.Add("Node '$($node.Name)': address '$($node.Address)' is not a valid IPv4 address")
        }
    }

    $totalMemoryGB = ($Config.Nodes | Measure-Object -Property MemoryGB -Sum).Sum
    $physicalMemoryGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $requiredGB = $totalMemoryGB + $Config.Hyperv.HostReserveGB
    if ($requiredGB -gt $physicalMemoryGB) {
        $validationErrors.Add("Inventory requests $($totalMemoryGB)GB plus a $($Config.Hyperv.HostReserveGB)GB host reserve = $($requiredGB)GB, but the host only has $($physicalMemoryGB)GB of physical RAM")
    }

    $totalCpu = ($Config.Nodes | Measure-Object -Property Cpu -Sum).Sum
    $logicalCpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if ($totalCpu -gt $logicalCpus) {
        Write-Log "Inventory requests $totalCpu vCPUs against $logicalCpus logical processors on the host. This is fine as overcommit -- just watch scheduling latency under load." -Level Warning
    }

    if (-not (Test-Path $Config.Hyperv.IsoPath)) {
        Write-Log "Talos ISO not found at $($Config.Hyperv.IsoPath). VM creation will fail until it is downloaded there." -Level Warning
    }

    if ($validationErrors.Count -gt 0) {
        throw ("Inventory validation failed:`n - " + ($validationErrors -join "`n - "))
    }

    Write-Log "Inventory validation passed: $($Config.Nodes.Count) node(s), $($totalMemoryGB)GB RAM requested, $($physicalMemoryGB)GB physical RAM."
}

function Test-ClusterSwitch {
    param([Parameter(Mandatory)][string]$SwitchName)
    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        throw "Hyper-V switch '$SwitchName' does not exist. Creating an external switch can briefly drop host networking, so this script will not do it for you. Create it manually first, e.g.:`n  New-VMSwitch -Name '$SwitchName' -NetAdapterName '<your physical NIC name>' -AllowManagementOS `$true"
    }
}

function ConvertTo-HyperVMac {
    param([Parameter(Mandatory)][string]$Mac)
    ($Mac -replace '[-:]', '').ToUpperInvariant()
}

# ---------------------------------------------------------------------------
# VM creation
# ---------------------------------------------------------------------------

function New-TalosVM {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Config
    )

    Write-Log "Creating VM $($Node.Name)..."

    if (-not (Test-Path $Config.Hyperv.IsoPath)) {
        throw "Talos ISO not found at $($Config.Hyperv.IsoPath). Download it before creating VMs."
    }

    $vmDir = Join-Path $Config.Hyperv.VmPath $Node.Name
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    New-VM -Name $Node.Name `
        -Generation $Config.Hyperv.Generation `
        -MemoryStartupBytes ([int64]$Node.MemoryGB * 1GB) `
        -Path $Config.Hyperv.VmPath `
        -SwitchName $Config.Hyperv.Switch `
        -NoVHD | Out-Null

    Set-VMProcessor -VMName $Node.Name -Count $Node.Cpu

    Set-VMMemory -VMName $Node.Name `
        -DynamicMemoryEnabled $Config.Hyperv.DynamicMemory `
        -StartupBytes ([int64]$Node.MemoryGB * 1GB)

    Set-VM -Name $Node.Name `
        -AutomaticCheckpointsEnabled $Config.Hyperv.AutomaticCheckpoints `
        -CheckpointType Disabled `
        -AutomaticStopAction $Config.Hyperv.AutomaticStopAction

    Set-VMFirmware -VMName $Node.Name -EnableSecureBoot $(if ($Config.Hyperv.SecureBoot) { 'On' } else { 'Off' })

    Set-VMNetworkAdapter -VMName $Node.Name `
        -StaticMacAddress (ConvertTo-HyperVMac $Node.MacAddress) `
        -MacAddressSpoofing $(if ($Config.Hyperv.MacAddressSpoofing) { 'On' } else { 'Off' })

    # Talos manages its own NTP; letting the Hyper-V time-sync integration
    # service also discipline the clock produces conflicting corrections.
    Disable-VMIntegrationService -VMName $Node.Name -Name 'Time Synchronization'

    foreach ($disk in $Node.Disks) {
        $vhdPath = Join-Path $vmDir "$($disk.Name).vhdx"
        if ($disk.Type -eq 'Fixed') {
            New-VHD -Path $vhdPath -SizeBytes ([int64]$disk.SizeGB * 1GB) -Fixed | Out-Null
        } else {
            New-VHD -Path $vhdPath -SizeBytes ([int64]$disk.SizeGB * 1GB) -Dynamic | Out-Null
        }
        Add-VMHardDiskDrive -VMName $Node.Name -Path $vhdPath
    }

    Add-VMDvdDrive -VMName $Node.Name -Path $Config.Hyperv.IsoPath

    # Disk first, DVD second: on first boot the disk is empty so firmware falls
    # through to the ISO and Talos comes up in maintenance mode. Once installed,
    # the disk boots directly and the DVD entry never needs to be touched again.
    $bootDisk = Get-VMHardDiskDrive -VMName $Node.Name | Select-Object -First 1
    $bootDvd = Get-VMDvdDrive -VMName $Node.Name
    Set-VMFirmware -VMName $Node.Name -BootOrder $bootDisk, $bootDvd

    Set-VM -Name $Node.Name -Notes "managed-by=cluster-setup.ps1;cluster=$($Config.Cluster.Name)"

    Start-VM -Name $Node.Name

    Write-Log "Created and started $($Node.Name)"
}

function Get-RogueVMs {
    param([Parameter(Mandatory)]$Config)
    $desiredNames = @($Config.Nodes.Name)
    Get-VM | Where-Object {
        $_.Notes -match [regex]::Escape("cluster=$($Config.Cluster.Name)") -and
        $desiredNames -notcontains $_.Name
    }
}

# ---------------------------------------------------------------------------
# Drift detection and reconciliation
# ---------------------------------------------------------------------------

function New-DriftItem {
    param($NodeName, $Class, $Property, $Desired, $Actual)
    [PSCustomObject]@{
        Node     = $NodeName
        Class    = $Class
        Property = $Property
        Desired  = $Desired
        Actual   = $Actual
        Applied  = $false
    }
}

function Get-NodeDrift {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Config
    )

    $items = @()
    $firmware = Get-VMFirmware -VMName $Node.Name
    $nic = Get-VMNetworkAdapter -VMName $Node.Name | Select-Object -First 1
    $timeSync = Get-VMIntegrationService -VMName $Node.Name -Name 'Time Synchronization'
    $dvd = Get-VMDvdDrive -VMName $Node.Name | Select-Object -First 1
    $disks = Get-VMHardDiskDrive -VMName $Node.Name

    # -- Hot: safe on a running VM --
    if ($VM.State -eq 'Off') {
        $items += New-DriftItem $Node.Name Hot 'PowerState' 'Running' 'Off'
    }
    if ($VM.AutomaticStopAction -ne $Config.Hyperv.AutomaticStopAction) {
        $items += New-DriftItem $Node.Name Hot 'AutomaticStopAction' $Config.Hyperv.AutomaticStopAction $VM.AutomaticStopAction
    }
    if ($VM.AutomaticCheckpointsEnabled -ne $Config.Hyperv.AutomaticCheckpoints -or $VM.CheckpointType -ne 'Disabled') {
        $items += New-DriftItem $Node.Name Hot 'Checkpoints' 'Disabled' $VM.CheckpointType
    }
    if ($nic.SwitchName -ne $Config.Hyperv.Switch) {
        $items += New-DriftItem $Node.Name Hot 'SwitchName' $Config.Hyperv.Switch $nic.SwitchName
    }
    $desiredSpoof = if ($Config.Hyperv.MacAddressSpoofing) { 'On' } else { 'Off' }
    if ($nic.MacAddressSpoofing -ne $desiredSpoof) {
        $items += New-DriftItem $Node.Name Hot 'MacAddressSpoofing' $desiredSpoof $nic.MacAddressSpoofing
    }
    if ($dvd.Path -ne $Config.Hyperv.IsoPath) {
        $items += New-DriftItem $Node.Name Hot 'DvdPath' $Config.Hyperv.IsoPath $dvd.Path
    }
    if ($timeSync.Enabled) {
        $items += New-DriftItem $Node.Name Hot 'TimeSyncIntegration' 'Disabled' 'Enabled'
    }
    $bootDiskFirst = $firmware.BootOrder.Count -gt 0 -and $firmware.BootOrder[0] -is [Microsoft.HyperV.PowerShell.HardDiskDrive]
    if (-not $bootDiskFirst) {
        $items += New-DriftItem $Node.Name Hot 'BootOrder' 'Disk,DVD' 'DVD,Disk'
    }

    # -- RequiresRestart: needs the VM powered off --
    if ($VM.ProcessorCount -ne $Node.Cpu) {
        $items += New-DriftItem $Node.Name RequiresRestart 'ProcessorCount' $Node.Cpu $VM.ProcessorCount
    }
    if ($VM.DynamicMemoryEnabled -ne $Config.Hyperv.DynamicMemory) {
        $items += New-DriftItem $Node.Name RequiresRestart 'DynamicMemoryEnabled' $Config.Hyperv.DynamicMemory $VM.DynamicMemoryEnabled
    } elseif ($VM.MemoryStartup -ne ([int64]$Node.MemoryGB * 1GB)) {
        $items += New-DriftItem $Node.Name RequiresRestart 'MemoryStartup' "$($Node.MemoryGB)GB" "$([math]::Round($VM.MemoryStartup / 1GB))GB"
    }
    $desiredSecureBoot = if ($Config.Hyperv.SecureBoot) { 'On' } else { 'Off' }
    if ($firmware.SecureBoot -ne $desiredSecureBoot) {
        $items += New-DriftItem $Node.Name RequiresRestart 'SecureBoot' $desiredSecureBoot $firmware.SecureBoot
    }
    $desiredMac = ConvertTo-HyperVMac $Node.MacAddress
    if ($nic.MacAddress -and $nic.MacAddress -ne $desiredMac) {
        $items += New-DriftItem $Node.Name RequiresRestart 'MacAddress' $desiredMac $nic.MacAddress
    }

    foreach ($diskSpec in $Node.Disks) {
        $vhdPath = Join-Path (Join-Path $Config.Hyperv.VmPath $Node.Name) "$($diskSpec.Name).vhdx"
        $actualDisk = $disks | Where-Object { $_.Path -eq $vhdPath }
        if (-not $actualDisk) {
            $items += New-DriftItem $Node.Name Hot "Disk:$($diskSpec.Name)" 'attached' 'missing'
            continue
        }
        $vhdInfo = Get-VHD -Path $vhdPath
        $desiredBytes = [int64]$diskSpec.SizeGB * 1GB
        if ($vhdInfo.Size -lt $desiredBytes) {
            $items += New-DriftItem $Node.Name RequiresRestart "Disk:$($diskSpec.Name):Grow" "$($diskSpec.SizeGB)GB" "$([math]::Round($vhdInfo.Size / 1GB))GB"
        } elseif ($vhdInfo.Size -gt $desiredBytes) {
            # -- Destructive: reported only, never auto-applied (see Resolve-NodeDrift) --
            $items += New-DriftItem $Node.Name Destructive "Disk:$($diskSpec.Name):Shrink" "$($diskSpec.SizeGB)GB" "$([math]::Round($vhdInfo.Size / 1GB))GB"
        }
    }

    return $items
}

function Resolve-HotDrift {
    param($Node, $Config, $Item)
    switch -Wildcard ($Item.Property) {
        'PowerState' { Start-VM -Name $Node.Name }
        'AutomaticStopAction' { Set-VM -Name $Node.Name -AutomaticStopAction $Config.Hyperv.AutomaticStopAction }
        'Checkpoints' { Set-VM -Name $Node.Name -AutomaticCheckpointsEnabled $Config.Hyperv.AutomaticCheckpoints -CheckpointType Disabled }
        'SwitchName' { Connect-VMNetworkAdapter -VMName $Node.Name -SwitchName $Config.Hyperv.Switch }
        'MacAddressSpoofing' { Set-VMNetworkAdapter -VMName $Node.Name -MacAddressSpoofing $(if ($Config.Hyperv.MacAddressSpoofing) { 'On' } else { 'Off' }) }
        'DvdPath' { Set-VMDvdDrive -VMName $Node.Name -Path $Config.Hyperv.IsoPath }
        'TimeSyncIntegration' { Disable-VMIntegrationService -VMName $Node.Name -Name 'Time Synchronization' }
        'BootOrder' {
            $disk = Get-VMHardDiskDrive -VMName $Node.Name | Select-Object -First 1
            $dvd = Get-VMDvdDrive -VMName $Node.Name
            Set-VMFirmware -VMName $Node.Name -BootOrder $disk, $dvd
        }
        'Disk:*' {
            $diskName = ($Item.Property -split ':')[1]
            $diskSpec = $Node.Disks | Where-Object Name -eq $diskName
            $vhdPath = Join-Path (Join-Path $Config.Hyperv.VmPath $Node.Name) "$($diskSpec.Name).vhdx"
            if (-not (Test-Path $vhdPath)) {
                if ($diskSpec.Type -eq 'Fixed') {
                    New-VHD -Path $vhdPath -SizeBytes ([int64]$diskSpec.SizeGB * 1GB) -Fixed | Out-Null
                } else {
                    New-VHD -Path $vhdPath -SizeBytes ([int64]$diskSpec.SizeGB * 1GB) -Dynamic | Out-Null
                }
            }
            Add-VMHardDiskDrive -VMName $Node.Name -Path $vhdPath
        }
    }
    $Item.Applied = $true
    Write-Log "Applied [$($Node.Name)] $($Item.Property): $($Item.Actual) -> $($Item.Desired)"
}

function Resolve-RestartDrift {
    param($Node, $Config, $Item)
    switch -Wildcard ($Item.Property) {
        'ProcessorCount' { Set-VMProcessor -VMName $Node.Name -Count $Node.Cpu }
        'DynamicMemoryEnabled' { Set-VMMemory -VMName $Node.Name -DynamicMemoryEnabled $Config.Hyperv.DynamicMemory -StartupBytes ([int64]$Node.MemoryGB * 1GB) }
        'MemoryStartup' { Set-VMMemory -VMName $Node.Name -StartupBytes ([int64]$Node.MemoryGB * 1GB) }
        'SecureBoot' { Set-VMFirmware -VMName $Node.Name -EnableSecureBoot $(if ($Config.Hyperv.SecureBoot) { 'On' } else { 'Off' }) }
        'MacAddress' { Set-VMNetworkAdapter -VMName $Node.Name -StaticMacAddress (ConvertTo-HyperVMac $Node.MacAddress) }
        'Disk:*:Grow' {
            $diskName = ($Item.Property -split ':')[1]
            $diskSpec = $Node.Disks | Where-Object Name -eq $diskName
            $vhdPath = Join-Path (Join-Path $Config.Hyperv.VmPath $Node.Name) "$($diskSpec.Name).vhdx"
            Resize-VHD -Path $vhdPath -SizeBytes ([int64]$diskSpec.SizeGB * 1GB)
            Write-Log "Grew $vhdPath to $($diskSpec.SizeGB)GB; the guest partition still needs to be extended from inside the OS." -Level Warning
        }
    }
    $Item.Applied = $true
    Write-Log "Applied [$($Node.Name)] $($Item.Property) (restart): $($Item.Actual) -> $($Item.Desired)"
}

function Wait-ForVMHeartbeat {
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        $hb = Get-VMIntegrationService -VMName $Name -Name 'Heartbeat' -ErrorAction SilentlyContinue
        if ($hb -and $hb.PrimaryStatusDescription -eq 'OK') {
            Write-Log "$Name is back up (Hyper-V heartbeat OK)."
            return
        }
    } while ((Get-Date) -lt $deadline)
    Write-Log "$Name did not report a healthy heartbeat within ${TimeoutSeconds}s. This only checks VM-level responsiveness, not Kubernetes node readiness -- verify manually before touching the next node." -Level Warning
}

function Resolve-NodeDrift {
    [CmdletBinding()]
    param($Node, $Config, [array]$Items, [switch]$AllowDisruptive)

    foreach ($item in ($Items | Where-Object Class -eq 'Hot')) {
        try {
            Resolve-HotDrift -Node $Node -Config $Config -Item $item
        } catch {
            Write-Log "Failed to apply [$($Node.Name)] $($item.Property): $_" -Level Error
        }
    }

    $restartItems = @($Items | Where-Object Class -eq 'RequiresRestart')
    if ($restartItems.Count -gt 0) {
        if ($AllowDisruptive) {
            Write-Log "Applying $($restartItems.Count) restart-required change(s) to $($Node.Name); powering off."
            try {
                Stop-VM -Name $Node.Name -Force
                foreach ($item in $restartItems) {
                    try {
                        Resolve-RestartDrift -Node $Node -Config $Config -Item $item
                    } catch {
                        Write-Log "Failed to apply [$($Node.Name)] $($item.Property): $_" -Level Error
                    }
                }
            } finally {
                Start-VM -Name $Node.Name
                Wait-ForVMHeartbeat -Name $Node.Name
            }
        } else {
            foreach ($item in $restartItems) {
                Write-Log "DRIFT [RequiresRestart, not applied] $($Node.Name) $($item.Property): desired=$($item.Desired) actual=$($item.Actual). Re-run with -AllowDisruptive to apply (powers this node off)." -Level Warning
            }
        }
    }

    # Disk shrink is reported only. Ever. A guest-aware shrink (partition first,
    # then the VHDX) has to be done by hand -- see README.md.
    foreach ($item in ($Items | Where-Object Class -eq 'Destructive')) {
        Write-Log "DRIFT [Destructive, never auto-applied] $($Node.Name) $($item.Property): desired=$($item.Desired) actual=$($item.Actual). See infrastructure/hyper-v/README.md for the manual procedure." -Level Warning
    }
}

function Write-DriftReport {
    param([array]$Items, [string]$OutputPath)

    foreach ($group in ($Items | Group-Object Class)) {
        Write-Log "Drift summary: $($group.Name) = $($group.Count)"
    }

    $report = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        Items     = $Items
    }
    New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding utf8

    if ($Items | Where-Object { -not $_.Applied }) { return 2 }
    return 0
}

function Install-ClusterScheduledTask {
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$ClusterName, [int]$IntervalMinutes)

    $taskName = "HomelabClusterSetup-$ClusterName"
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration ([TimeSpan]::MaxValue)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Registered scheduled task '$taskName', running every $IntervalMinutes minute(s) as SYSTEM. It applies Hot drift and reports the rest -- it never uses -AllowDisruptive or -AllowDestructive."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V feature first: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All'
}
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "The 'powershell-yaml' module is required to parse the inventory file. Install it with:`n  Install-Module -Name powershell-yaml -Scope CurrentUser -Force"
}
Import-Module Hyper-V -ErrorAction Stop
Import-Module powershell-yaml -ErrorAction Stop

$mutex = New-Object System.Threading.Mutex($false, 'Global\HomelabClusterSetup')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'Another instance of cluster-setup.ps1 is already running on this host. Exiting.' -Level Warning
    exit 1
}

try {
    $config = Import-ClusterInventory -Path $InventoryPath
    Test-ClusterInventory -Config $config

    if ($Validate) {
        Write-Log 'Validation-only run complete.'
        exit 0
    }

    if ($InstallScheduledTask) {
        Install-ClusterScheduledTask -ScriptPath $PSCommandPath -ClusterName $config.Cluster.Name -IntervalMinutes $IntervalMinutes
        exit 0
    }

    Test-ClusterSwitch -SwitchName $config.Hyperv.Switch

    $driftItems = @()

    foreach ($node in $config.Nodes) {
        $vm = Get-VM -Name $node.Name -ErrorAction SilentlyContinue
        if (-not $vm) {
            $createItem = New-DriftItem $node.Name 'Create' 'VM' 'exists' 'absent'
            $driftItems += $createItem
            if (-not $Report) {
                try {
                    New-TalosVM -Node $node -Config $config
                    $createItem.Applied = $true
                } catch {
                    Write-Log "Failed to create $($node.Name): $_" -Level Error
                }
            }
            continue
        }

        $items = Get-NodeDrift -VM $vm -Node $node -Config $config
        $driftItems += $items

        if (-not $Report -and $items) {
            Resolve-NodeDrift -Node $node -Config $config -Items $items -AllowDisruptive:$AllowDisruptive
        }
    }

    foreach ($rogue in (Get-RogueVMs -Config $config)) {
        $item = New-DriftItem $rogue.Name 'Destructive' 'RogueVM' 'absent' 'present'
        $driftItems += $item
        if (-not $Report -and $AllowDestructive) {
            if ($PSCmdlet.ShouldContinue("Remove VM '$($rogue.Name)' and its virtual disks? It is tagged for cluster '$($config.Cluster.Name)' but is no longer listed in the inventory.", 'Destructive drift')) {
                try {
                    Stop-VM -Name $rogue.Name -Force -ErrorAction SilentlyContinue
                    $rogueDisks = Get-VMHardDiskDrive -VMName $rogue.Name | Select-Object -ExpandProperty Path
                    Remove-VM -Name $rogue.Name -Force
                    $rogueDisks | ForEach-Object { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
                    $item.Applied = $true
                    Write-Log "Removed rogue VM $($rogue.Name)" -Level Warning
                } catch {
                    Write-Log "Failed to remove rogue VM $($rogue.Name): $_" -Level Error
                }
            } else {
                Write-Log "Left rogue VM $($rogue.Name) in place (declined)." -Level Warning
            }
        } elseif (-not $Report) {
            Write-Log "DRIFT [Destructive, refused] Rogue VM present: $($rogue.Name). Re-run with -AllowDestructive to remove it interactively." -Level Warning
        }
    }

    $reportPath = Join-Path $PSScriptRoot 'state\drift-report.json'
    $exitCode = Write-DriftReport -Items $driftItems -OutputPath $reportPath
    exit $exitCode
} finally {
    $mutex.ReleaseMutex()
}
