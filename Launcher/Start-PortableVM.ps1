<#
  Starts the VM straight from this USB stick, using the hypervisor installed
  on this PC: VMware Workstation if present, otherwise VirtualBox. No VM list is shown.
  Double-click "Start VM.cmd" (one folder up) to run it.

  The VM boots this stick itself (raw disk). Before every start the launcher:
    - asks for administrator rights (needed to give a VM a physical disk),
    - finds which disk number the stick has on this PC and checks that it really is
      this stick (MBR signature, size, partition layout) - otherwise nothing starts,
    - points the VM's raw-disk file at that disk number,
    - fixes the stick's drive letter in the VirtualBox files,
    - refuses to start the VM in one program while it has a saved state in the other.

  Settings: settings.psd1 next to this script. Log: launcher.log next to this script.
  -DryRun runs every check and logs what would change, without changing or starting anything.
#>
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Root = Split-Path $Here
$LogFile = Join-Path $Here 'launcher.log'

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line
}

function Show-Message([string]$Message, [string]$Icon) {
    if ($DryRun) { return }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Portable VM',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]$Icon,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1, [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
}

function Stop-Launcher([string]$Message) {
    Write-Log "STOPPED: $Message"
    Show-Message $Message 'Error'
    exit 1
}

# In a dry run, problems that only block the start are logged and the checks carry on.
function Stop-Unless-DryRun([string]$Message) {
    if ($DryRun) { Write-Log "DRY RUN - a real start would stop here: $Message" } else { Stop-Launcher $Message }
}

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n").Trim() }
}

# --- Administrator rights -------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Minimized `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    } catch {
        Show-Message 'The launcher needs administrator rights, because the VM boots this USB stick directly.' 'Warning'
    }
    exit
}

# --- Raw-disk files ---------------------------------------------------------------------
# What the VM sees: sectors 0..VmSectors-1 of the stick, optionally with the Data partition blanked.
function Get-DiskLayout([string]$Drive, [bool]$HideData) {
    if ($HideData) {
        @{ CreateType = 'partitionedDevice'
           Extents    = @(('RW {0} FLAT "{1}" 0' -f $S.DataPartitionStart, $Drive),
                          ('RW {0} ZERO' -f ($S.VmSectors - $S.DataPartitionStart))) }
    } else {
        @{ CreateType = 'fullDevice'
           Extents    = @(('RW {0} FLAT "{1}" 0' -f $S.VmSectors, $Drive)) }
    }
}

# Rewrites only the extent lines and createType of an existing descriptor; everything else stays.
function Set-DiskDescriptor([string]$Path, $Layout) {
    $text = [IO.File]::ReadAllText($Path)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $extentsWritten = $false
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*(RW|RDONLY|NOACCESS)\s+\d+\s+(FLAT|ZERO)\b') {
            if (-not $extentsWritten) { foreach ($e in $Layout.Extents) { $lines.Add($e) }; $extentsWritten = $true }
        } elseif ($line -match '^\s*createType\s*=') {
            $lines.Add('createType="' + $Layout.CreateType + '"')
        } else {
            $lines.Add($line)
        }
    }
    if (-not $extentsWritten) { Stop-Launcher "Unexpected content in $Path - no disk extent found. Nothing was started." }
    $new = $lines -join $newline
    $name = Split-Path $Path -Leaf
    if ($new -eq $text) { Write-Log "$name already points at the stick"; return }
    Write-Log "$name -> $($Layout.Extents -join ' | ')"
    if ($DryRun) { return }
    if (-not (Test-Path -LiteralPath "$Path.orig")) { Copy-Item -LiteralPath $Path -Destination "$Path.orig" }
    [IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding $false))
}

function New-VMwareDescriptor([string]$Path, $Layout) {
    $lines = @('# Disk DescriptorFile', 'version=1', 'encoding="windows-1252"', 'CID=fffffffe', 'parentCID=ffffffff',
               ('createType="{0}"' -f $Layout.CreateType), '', '# Extent description') +
             $Layout.Extents +
             @('', '# The Disk Data Base', '#DDB', '', 'ddb.adapterType = "ide"', 'ddb.geometry.cylinders = "16383"',
               'ddb.geometry.heads = "16"', 'ddb.geometry.sectors = "63"', 'ddb.virtualHWVersion = "20"', '')
    Write-Log "Creating $(Split-Path $Path -Leaf) -> $($Layout.Extents -join ' | ')"
    if ($DryRun) { return }
    [IO.File]::WriteAllText($Path, ($lines -join "`r`n"), [Text.Encoding]::ASCII)
}

# VirtualBox stores some paths on the stick with a drive letter (e.g. the VM's entry in VirtualBox.xml),
# and the stick's letter differs between PCs. Handles both \ and / separators.
function Set-DriveLetterInFile([string]$Path, [string]$Letter) {
    $text = [IO.File]::ReadAllText($Path)
    $new = $text
    foreach ($sep in '\', '/') {
        $relative = $Root.Substring(2).Replace('\', $sep) + $sep
        $new = [regex]::Replace($new, '"[A-Za-z]:' + [regex]::Escape($relative), ('"' + $Letter + ':' + $relative))
    }
    $name = Split-Path $Path -Leaf
    if ($new -eq $text) { Write-Log "${name}: drive letter OK"; return }
    Write-Log "${name}: paths moved to drive ${Letter}:"
    if ($DryRun) { return }
    if (-not (Test-Path -LiteralPath "$Path.launcher-backup")) { Copy-Item -LiteralPath $Path -Destination "$Path.launcher-backup" }
    [IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding $false))
}

# --- Is the VM already running somewhere? ------------------------------------------------
function Get-VirtualBoxVmProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'")
}
function Test-RunningInVirtualBox {
    # A VirtualBox VM process whose command line can't be read might be this VM, so it counts.
    [bool](Get-VirtualBoxVmProcesses | Where-Object { -not $_.CommandLine -or $_.CommandLine -match $S.VirtualBoxVmUuid })
}
function Test-RunningInVMware([string]$Vmx) {
    [bool](Get-CimInstance Win32_Process -Filter "Name='vmware-vmx.exe'" |
        Where-Object { -not $_.CommandLine -or $_.CommandLine.ToLower().Contains($Vmx.ToLower()) })
}

# --- Saved states ------------------------------------------------------------------------
# A saved (VirtualBox) or suspended (VMware) VM still holds unwritten changes to the stick in its
# saved memory. Booting the stick any other way before resuming it can corrupt the guest's file system.
function Test-VirtualBoxSaved {
    $vbox = Join-Path $Root $S.VirtualBoxVbox
    (Test-Path -LiteralPath $vbox) -and ([IO.File]::ReadAllText($vbox) -match '<Machine\s[^>]*\bstateFile="[^"]+"')
}
function Test-VMwareSuspended {
    $vmx = Join-Path $Root $S.VMwareVmx
    (Test-Path -LiteralPath $vmx) -and ([IO.File]::ReadAllText($vmx) -match '(?m)^\s*checkpoint\.vmState\s*=\s*"[^"]+"')
}

# Auto resumes a saved state in the program that holds it; otherwise VMware is preferred.
function Select-Hypervisor([string]$VMwareDir, [string]$VirtualBoxDir) {
    switch ($S.Hypervisor) {
        'VMware'     { return 'VMware' }
        'VirtualBox' { return 'VirtualBox' }
    }
    if ($VMwareDir -and (Test-VMwareSuspended)) { return 'VMware' }
    if ($VirtualBoxDir -and (Test-VirtualBoxSaved)) { return 'VirtualBox' }
    if ($VMwareDir -and (Test-Path -LiteralPath (Join-Path $Root $S.VMwareVmx))) { return 'VMware' }
    'VirtualBox'
}

# --- VMware Workstation ------------------------------------------------------------------
function Get-VMwareDir {
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation', 'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation') {
        $dir = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).InstallPath
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'vmware.exe'))) { return $dir }
    }
}

function Start-WithVMware([string]$VMwareDir, [string]$Drive) {
    # VMware takes every Windows volume in the disk area it gives the VM away from Windows while the VM
    # runs. It can't do that for the Data partition, which holds the VM's own files, so VMware always
    # gets the stick with that partition blanked. It stays a "fullDevice" disk: in "partitionedDevice"
    # mode VMware insists on its own partition-table copy and refuses this descriptor.
    $Layout = Get-DiskLayout $Drive $true
    $Layout.CreateType = 'fullDevice'
    $vmx = Join-Path $Root $S.VMwareVmx
    if (Test-RunningInVMware $vmx) { Write-Log 'Already running in VMware.'; Show-Message 'The VM is already running.' 'Information'; exit }
    if (Test-RunningInVirtualBox) { Stop-Unless-DryRun 'A VirtualBox VM is running, possibly this one. Close it before starting the VM in VMware - the stick must never be used by two VMs at once.' }
    if (Test-VirtualBoxSaved) { Stop-Unless-DryRun 'The VM has a saved state in VirtualBox. Resume it in VirtualBox (on a PC with VirtualBox) and shut the guest down normally before starting it in VMware - otherwise the guest''s disk can get corrupted.' }

    $disk = Join-Path $Root $S.VMwareDisk
    if (Test-Path -LiteralPath $disk) { Set-DiskDescriptor $disk $Layout } else { New-VMwareDescriptor $disk $Layout }
    if ($DryRun) { Write-Log "DRY RUN - would start $vmx with VMware Workstation ($VMwareDir)"; return }

    $view = if ($S.VMwareView -eq 'FullScreen') { '-X' } else { '-x' }
    Start-Process -FilePath (Join-Path $VMwareDir 'vmware.exe') -ArgumentList @('-n', '-q', $view, "`"$vmx`"")
    Write-Log "Started with VMware Workstation ($VMwareDir)"
}

# --- VirtualBox --------------------------------------------------------------------------
function Get-VirtualBoxDir {
    $dir = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction SilentlyContinue).InstallDir
    if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'VBoxManage.exe'))) { return $dir }
}

function Start-WithVirtualBox([string]$VirtualBoxDir, [string]$Drive, [string]$Letter) {
    $Layout = Get-DiskLayout $Drive $S.HideDataPartition
    $vbm = Join-Path $VirtualBoxDir 'VBoxManage.exe'
    $uuid = $S.VirtualBoxVmUuid
    $env:VBOX_USER_HOME = Join-Path $Root $S.VirtualBoxHome
    if (Test-RunningInVMware (Join-Path $Root $S.VMwareVmx)) { Stop-Unless-DryRun 'The VM is running in VMware. Close it before starting it in VirtualBox.' }
    if (Test-VMwareSuspended) { Stop-Unless-DryRun 'The VM is suspended in VMware. Resume it in VMware (on a PC with VMware Workstation) and shut the guest down normally before starting it in VirtualBox - otherwise the guest''s disk can get corrupted.' }

    # All VirtualBox windows of a user share one background service (VBoxSVC), and that service
    # keeps the VM list it was started with. So it has to be started fresh, by this launcher.
    $open = @(Get-CimInstance Win32_Process -Filter "Name='VirtualBox.exe' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'")
    if ($open.Count) {
        # VirtualBox hides its VM processes' command lines, so ask VirtualBox whether this VM is the one running.
        $info = Invoke-Native $vbm @('showvminfo', $uuid, '--machinereadable')
        if ($info.Output -match 'VMState="(running|paused|starting|restoring)"') {
            Write-Log 'Already running in VirtualBox.'; Show-Message 'The VM is already running.' 'Information'; exit
        }
        Stop-Unless-DryRun 'VirtualBox is already open on this PC. Close all VirtualBox windows, then start the VM again.'
    }
    if (-not $DryRun) {
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Process VBoxSVC -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    }
    if (Get-Process VBoxSVC -ErrorAction SilentlyContinue) {
        Stop-Unless-DryRun 'VirtualBox is still running in the background. Wait half a minute, then start the VM again.'
    }

    Set-DriveLetterInFile (Join-Path $Root $S.VirtualBoxVbox) $Letter
    Set-DriveLetterInFile (Join-Path (Join-Path $Root $S.VirtualBoxHome) 'VirtualBox.xml') $Letter
    Set-DiskDescriptor (Join-Path $Root $S.VirtualBoxDisk) $Layout
    if ($DryRun) { Write-Log "DRY RUN - would start VM {$uuid} with VirtualBox ($VirtualBoxDir)"; return }

    $list = Invoke-Native $vbm @('list', 'vms')
    if ($list.Output -notmatch $uuid) { Stop-Launcher "VirtualBox did not find the VM in the stick's VM list:`n`n$($list.Output)" }
    $info = Invoke-Native $vbm @('showvminfo', $uuid, '--machinereadable')
    $state = ($info.Output -split "`n" | Where-Object { $_ -like 'VMState=*' }) -replace '^VMState=', ''
    Write-Log "VirtualBox VM state: $state"
    if ($state -match 'running|paused|starting|restoring') { Show-Message 'The VM is already running.' 'Information'; exit }

    $start = Invoke-Native $vbm @('startvm', $uuid, '--type', 'gui')
    if ($start.ExitCode -ne 0) { Stop-Launcher "VirtualBox could not start the VM:`n`n$($start.Output)" }
    Write-Log "Started with VirtualBox $((Invoke-Native $vbm @('--version')).Output)"
}

# --- Main --------------------------------------------------------------------------------
try {
    Write-Log "----- Start VM$(if ($DryRun) { ' (dry run)' }) -----"
    $S = Import-PowerShellDataFile -LiteralPath (Join-Path $Here 'settings.psd1')

    # 1. Find the stick this launcher is on, and make sure it is the right one.
    $letter = $Here.Substring(0, 1).ToUpper()
    $partition = Get-Partition -DriveLetter $letter
    $disk = Get-Disk -Number $partition.DiskNumber
    $signature = if ($disk.Signature) { '{0:X8}' -f [uint32]$disk.Signature } else { 'none' }
    if ($disk.PartitionStyle -ne 'MBR' -or $signature -ne $S.StickMbrSignature) {
        Stop-Launcher "This is not the expected USB stick (disk ID $signature, expected $($S.StickMbrSignature)). Nothing was started."
    }
    if ($disk.LogicalSectorSize -ne 512 -or [int64]($disk.Size / 512) -ne $S.StickSectors) {
        Stop-Launcher 'The USB stick has an unexpected size. Nothing was started.'
    }
    if ([int64]($partition.Offset / 512) -ne $S.DataPartitionStart -or [int64](($partition.Offset + $partition.Size) / 512) -ne $S.VmSectors) {
        Stop-Launcher 'The partition layout of the USB stick has changed; settings.psd1 needs updating. Nothing was started.'
    }
    if ($disk.IsBoot -or $disk.IsSystem) { Stop-Launcher "Disk $($disk.Number) is this PC's Windows disk. Nothing was started." }
    $drive = "\\.\PhysicalDrive$($disk.Number)"
    Write-Log "Stick found: disk $($disk.Number) ($drive), drive ${letter}:, ID $signature"

    $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    if ($deviceGuard -and ($deviceGuard.SecurityServicesRunning -contains 2)) {
        Write-Log 'Note: Memory Integrity is on, so the VM runs on top of Hyper-V (slower than native).'
    }

    # 2. Pick the hypervisor.
    $vmwareDir = Get-VMwareDir
    $virtualBoxDir = Get-VirtualBoxDir
    if (Test-VMwareSuspended) { Write-Log 'Saved state found: suspended in VMware' }
    if (Test-VirtualBoxSaved) { Write-Log 'Saved state found: saved in VirtualBox' }
    $use = Select-Hypervisor $vmwareDir $virtualBoxDir
    if ($use -eq 'VMware' -and -not $vmwareDir) { Stop-Launcher 'VMware Workstation is not installed on this PC.' }
    if ($use -eq 'VirtualBox' -and -not $virtualBoxDir) { Stop-Launcher 'Neither VMware Workstation nor VirtualBox is installed on this PC.' }
    Write-Log "Using $use"

    # 3. Start.
    if ($use -eq 'VMware') { Start-WithVMware $vmwareDir $drive } else { Start-WithVirtualBox $virtualBoxDir $drive $letter }
} catch {
    Stop-Launcher "Unexpected error: $($_.Exception.Message)"
}
