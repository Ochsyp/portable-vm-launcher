# -------------------------------------------------------
#                      PORTABLE VM
# -------------------------------------------------------
#
# The launcher's checks and start steps, used by Start-PortableVM.ps1 in the same folder: find
# the stick the launcher runs from and check that it is the configured one, choose VMware
# Workstation or VirtualBox, point the VM's raw-disk descriptor at the stick and start the VM.
# The decisions, messages and log lines are those of the launcher before the redesign.
#
# Importing the module runs nothing. Functions take what they need as parameters and throw, and
# Invoke-PortableVM turns a stop into the exit code and the message for the script to show.
# Everything the launcher reads from or starts on the PC goes through an Invoke-Pvm* adapter.
# With $env:PVM_TEST set to '1', as tests\run-checks.ps1 sets it, an adapter that a test did not
# mock throws, so no test reaches a disk, a process or a VM. Files are read and written directly;
# the tests keep theirs in TestDrive.

Set-StrictMode -Version 3.0
# Module functions do not see the caller's preference variables, so the module sets its own.
$ErrorActionPreference = 'Stop'

# --- Stops and logging -----------------------------------------------------------------------

# Return an exception that stops the launcher with $Message, for `throw`. Invoke-PortableVM logs
# it as "STOPPED: <Message>" and returns the message to show; any other exception counts as an
# unexpected error.
function Get-PvmStopException {
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param([Parameter(Mandatory)][string]$Message)
    $exception = [System.Exception]::new($Message)
    $exception.Data['PvmStop'] = $true
    $exception
}

# Return the message of the launcher stop in $ErrorRecord, also when PowerShell wrapped the
# exception of Get-PvmStopException in another one, or $null when it is some other error.
function Get-PvmStopMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    for ($exception = $ErrorRecord.Exception; $null -ne $exception; $exception = $exception.InnerException) {
        if ($exception.Data['PvmStop']) { return $exception.Message }
    }
    $null
}

# Append "<yyyy-MM-dd HH:mm:ss>  <Message>" in local time to the log file $Path and show the line
# on the console. The line is written under -WhatIf too, so a dry run logs what it would do.
function Write-PvmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Write-Host $line
    Add-Content -LiteralPath $Path -Value $line -WhatIf:$false -Confirm:$false
}

# In a dry run ($Context.DryRun), log that a real start would stop here with $Message and carry
# on with the checks; otherwise throw the stop.
function Invoke-PvmStopUnlessDryRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Context.DryRun) { Write-PvmLog -Path $Context.LogPath -Message "DRY RUN - a real start would stop here: $Message" }
    else { throw (Get-PvmStopException -Message $Message) }
}

# --- Adapters --------------------------------------------------------------------------------
# One function for each thing the launcher reads from or starts on this PC, so that tests can
# mock each one. Get-Partition and Get-Disk are functions of another module, which does not see
# this module's $ErrorActionPreference, so their errors are made terminating where they are called.

# Throw when the tests run ($env:PVM_TEST is '1') and reached the adapter $Name unmocked.
function Assert-PvmNotUnderTest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if ($env:PVM_TEST -eq '1') { throw "$Name reached this PC during a test; mock it." }
}

# Return the partition that has the drive letter $DriveLetter.
function Invoke-PvmGetPartition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
}

# Return the disk with the number $Number.
function Invoke-PvmGetDisk {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Number)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Get-Disk -Number $Number -ErrorAction Stop
}

# Return the processes that the WQL condition $Filter selects, as Win32_Process instances with
# Name and CommandLine. CommandLine is empty where this process may not read it.
function Invoke-PvmGetProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Filter)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Get-CimInstance -ClassName Win32_Process -Filter $Filter
}

# Return whether a process named $Name runs on this PC.
function Invoke-PvmTestProcess {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue)
}

# Return the Win32_DeviceGuard instance, or nothing where Windows has no such class.
function Invoke-PvmGetDeviceGuard {
    [CmdletBinding()]
    param()
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
}

# Return the value $Name of the registry key $Path, or $null when the key or the value is
# missing.
function Invoke-PvmGetRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    $key = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -ne $key -and $null -ne $key.PSObject.Properties[$Name]) { $key.PSObject.Properties[$Name].Value }
    else { $null }
}

# Run the program $FilePath with $ArgumentList and wait for it to end. Returns its ExitCode and
# its Output: the lines it wrote to stdout and stderr, joined with LF and trimmed.
function Invoke-PvmNative {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    $output = @()
    # Windows PowerShell 5.1 turns a program's stderr lines into errors, which would stop the
    # launcher under $ErrorActionPreference Stop.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n").Trim() }
}

# Start the program $FilePath with $ArgumentList and return without waiting for it. Start-Process
# joins the arguments with spaces, so an argument that holds spaces must come quoted.
function Invoke-PvmStartProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Start-Process -FilePath $FilePath -ArgumentList $ArgumentList
}

# Set the environment variable $Name to $Value in this process, so the programs it starts get it.
function Invoke-PvmSetEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

# Pause for $Seconds seconds.
function Invoke-PvmSleep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Seconds)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Start-Sleep -Seconds $Seconds
}

# --- Stick identity --------------------------------------------------------------------------

# Return the MBR signature of $Disk as 8 hex digits, or 'none' when the disk has none.
function Get-PvmDiskSignature {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Disk)
    if ($Disk.Signature) { '{0:X8}' -f [uint32]$Disk.Signature } else { 'none' }
}

# Return why $Disk, with $Partition as the partition the launcher runs from, is not the stick that
# $Settings describe, as the message to stop with, or $null when it is that stick. The checks run
# in this order: an MBR disk with the signature StickMbrSignature; 512-byte sectors, StickSectors
# of them; the partition from sector DataPartitionStart to VmSectors; not the PC's boot or system
# disk.
function Get-PvmStickProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $signature = Get-PvmDiskSignature -Disk $Disk
    if ($Disk.PartitionStyle -ne 'MBR' -or $signature -ne $Settings['StickMbrSignature']) {
        return "This is not the expected USB stick (disk ID $signature, expected $($Settings['StickMbrSignature'])). Nothing was started."
    }
    if ($Disk.LogicalSectorSize -ne 512 -or [int64]($Disk.Size / 512) -ne $Settings['StickSectors']) {
        return 'The USB stick has an unexpected size. Nothing was started.'
    }
    if ([int64]($Partition.Offset / 512) -ne $Settings['DataPartitionStart'] -or
        [int64](($Partition.Offset + $Partition.Size) / 512) -ne $Settings['VmSectors']) {
        return 'The partition layout of the USB stick has changed; settings.psd1 needs updating. Nothing was started.'
    }
    if ($Disk.IsBoot -or $Disk.IsSystem) { return "Disk $($Disk.Number) is this PC's Windows disk. Nothing was started." }
    $null
}

# --- Raw-disk descriptors --------------------------------------------------------------------

# Return what the VM gets of the raw disk $Drive, as the CreateType and the Extents lines of a
# descriptor: sectors 0 to VmSectors-1 of the stick, with the Data partition, from sector
# DataPartitionStart on, blanked when $HideData is set.
function Get-PvmDiskLayout {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Drive,
        [int64]$VmSectors,
        [int64]$DataPartitionStart,
        [bool]$HideData
    )
    if ($HideData) {
        @{
            CreateType = 'partitionedDevice'
            Extents    = @(('RW {0} FLAT "{1}" 0' -f $DataPartitionStart, $Drive), ('RW {0} ZERO' -f ($VmSectors - $DataPartitionStart)))
        }
    } else {
        @{
            CreateType = 'fullDevice'
            Extents    = @(('RW {0} FLAT "{1}" 0' -f $VmSectors, $Drive))
        }
    }
}

# Return the descriptor text $Text with its extent lines (RW, RDONLY or NOACCESS with a FLAT or
# ZERO extent) replaced by the Extents of $Layout, written where the first one was, and its
# createType set to $Layout.CreateType. Every other line and the line endings stay. Returns $null
# when $Text has no such extent line.
function ConvertTo-PvmDescriptorText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][hashtable]$Layout
    )
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $extentsWritten = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(RW|RDONLY|NOACCESS)\s+\d+\s+(FLAT|ZERO)\b') {
            if (-not $extentsWritten) {
                foreach ($extent in $Layout.Extents) { $lines.Add($extent) }
                $extentsWritten = $true
            }
        } elseif ($line -match '^\s*createType\s*=') {
            $lines.Add('createType="' + $Layout.CreateType + '"')
        } else {
            $lines.Add($line)
        }
    }
    if (-not $extentsWritten) { return $null }
    $lines -join $newline
}

# Return the text of a new VMware descriptor for $Layout: a header, the Extents of $Layout and a
# disk database for an IDE disk of virtual hardware version 20, with CRLF line endings.
function Get-PvmVMwareDescriptorText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Layout)
    $lines = @('# Disk DescriptorFile', 'version=1', 'encoding="windows-1252"', 'CID=fffffffe', 'parentCID=ffffffff',
        ('createType="{0}"' -f $Layout.CreateType), '', '# Extent description') +
    $Layout.Extents +
    @('', '# The Disk Data Base', '#DDB', '', 'ddb.adapterType = "ide"', 'ddb.geometry.cylinders = "16383"',
        'ddb.geometry.heads = "16"', 'ddb.geometry.sectors = "63"', 'ddb.virtualHWVersion = "20"', '')
    $lines -join "`r`n"
}

# Point the existing descriptor $Path at the stick: its extent lines and createType become those
# of $Layout (ConvertTo-PvmDescriptorText), and the change is logged to $LogPath. Before the first
# rewrite the file is copied to <Path>.orig, which is never replaced; the descriptor is written as
# UTF-8 without a BOM. Throws a stop when the file has no extent line.
function Set-PvmDiskDescriptor {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Layout,
        [Parameter(Mandatory)][string]$LogPath
    )
    $text = [IO.File]::ReadAllText($Path)
    $new = ConvertTo-PvmDescriptorText -Text $text -Layout $Layout
    if ($null -eq $new) { throw (Get-PvmStopException -Message "Unexpected content in $Path - no disk extent found. Nothing was started.") }
    $name = Split-Path $Path -Leaf
    # -eq ignores case, as before the redesign, so a change of case alone is not written.
    if ($new -eq $text) {
        Write-PvmLog -Path $LogPath -Message "$name already points at the stick"
        return
    }
    Write-PvmLog -Path $LogPath -Message "$name -> $($Layout.Extents -join ' | ')"
    if (-not $PSCmdlet.ShouldProcess($Path, 'Point the raw-disk descriptor at the stick')) { return }
    if (-not (Test-Path -LiteralPath "$Path.orig")) { Copy-Item -LiteralPath $Path -Destination "$Path.orig" }
    [IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding $false))
}

# Create the VMware descriptor $Path for $Layout (Get-PvmVMwareDescriptorText) as ASCII, and log
# it to $LogPath.
function New-PvmVMwareDescriptor {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Layout,
        [Parameter(Mandatory)][string]$LogPath
    )
    Write-PvmLog -Path $LogPath -Message "Creating $(Split-Path $Path -Leaf) -> $($Layout.Extents -join ' | ')"
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create the raw-disk descriptor')) { return }
    [IO.File]::WriteAllText($Path, (Get-PvmVMwareDescriptorText -Layout $Layout), [Text.Encoding]::ASCII)
}

# --- Drive letters ---------------------------------------------------------------------------
# VirtualBox stores some paths on the stick with a drive letter, such as the VM's entry in
# VirtualBox.xml, and the stick's letter differs between PCs.

# Return $Text with the drive letter of every quoted path below the folder $Root set to $Letter,
# for \ and / separators alike. Known limits, kept from before the redesign until phase 5: the
# match is case-sensitive, nothing matches when $Root is a drive root, and $Root goes into the
# replacement unescaped, so a '$' in a folder name is read as a substitution.
function ConvertTo-PvmDriveLetterText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Letter
    )
    $new = $Text
    foreach ($separator in '\', '/') {
        $relative = $Root.Substring(2).Replace('\', $separator) + $separator
        $new = [regex]::Replace($new, '"[A-Za-z]:' + [regex]::Escape($relative), ('"' + $Letter + ':' + $relative))
    }
    $new
}

# Set the stick's drive letter $Letter in the paths below $Root in the file $Path
# (ConvertTo-PvmDriveLetterText), and log to $LogPath whether anything changed. Before the first
# rewrite the file is copied to <Path>.launcher-backup, which is never replaced; the file is
# written as UTF-8 without a BOM.
function Set-PvmDriveLetterInFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Letter,
        [Parameter(Mandatory)][string]$LogPath
    )
    $text = [IO.File]::ReadAllText($Path)
    $new = ConvertTo-PvmDriveLetterText -Text $text -Root $Root -Letter $Letter
    $name = Split-Path $Path -Leaf
    # -eq ignores case, as before the redesign, so a letter that differs only in case stays.
    if ($new -eq $text) {
        Write-PvmLog -Path $LogPath -Message "${name}: drive letter OK"
        return
    }
    Write-PvmLog -Path $LogPath -Message "${name}: paths moved to drive ${Letter}:"
    if (-not $PSCmdlet.ShouldProcess($Path, "Move the stick's paths to drive ${Letter}:")) { return }
    if (-not (Test-Path -LiteralPath "$Path.launcher-backup")) { Copy-Item -LiteralPath $Path -Destination "$Path.launcher-backup" }
    [IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding $false))
}

# --- Running VMs -----------------------------------------------------------------------------

# Return whether the process $Process may be the VirtualBox VM $VmUuid: its command line matches
# $VmUuid, which is read as a regular expression, or it cannot be read.
function Test-PvmVirtualBoxVmProcess {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Process,
        [string]$VmUuid
    )
    (-not $Process.CommandLine) -or ($Process.CommandLine -match $VmUuid)
}

# Return whether a VirtualBox VM process on this PC (VirtualBoxVM.exe or VBoxHeadless.exe) may be
# the VM $VmUuid (Test-PvmVirtualBoxVmProcess).
function Test-PvmRunningInVirtualBox {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VmUuid)
    $processes = @(Invoke-PvmGetProcess -Filter "Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'")
    [bool]($processes | Where-Object { Test-PvmVirtualBoxVmProcess -Process $_ -VmUuid $VmUuid })
}

# Return whether the process $Process may be the VMware VM $Vmx: its command line holds the path
# $Vmx, compared without case, or it cannot be read.
function Test-PvmVMwareVmProcess {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][string]$Vmx
    )
    (-not $Process.CommandLine) -or $Process.CommandLine.ToLower().Contains($Vmx.ToLower())
}

# Return whether a vmware-vmx.exe process on this PC may be the VM $Vmx (Test-PvmVMwareVmProcess).
function Test-PvmRunningInVMware {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Vmx)
    $processes = @(Invoke-PvmGetProcess -Filter "Name='vmware-vmx.exe'")
    [bool]($processes | Where-Object { Test-PvmVMwareVmProcess -Process $_ -Vmx $Vmx })
}

# --- Saved states ----------------------------------------------------------------------------
# A saved (VirtualBox) or suspended (VMware) VM still holds unwritten changes to the stick in its
# saved memory. Booting the stick any other way before resuming it can corrupt the guest's file
# system.

# Return whether the .vbox text $Text gives its Machine element a stateFile: the VM is saved.
function Test-PvmVirtualBoxSavedText {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $Text -match '<Machine\s[^>]*\bstateFile="[^"]+"'
}

# Return whether the .vmx text $Text has a checkpoint.vmState line: the VM is suspended.
function Test-PvmVMwareSuspendedText {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $Text -match '(?m)^\s*checkpoint\.vmState\s*=\s*"[^"]+"'
}

# Return whether the .vbox $Path says the VM is saved. A missing file counts as not saved.
function Test-PvmVirtualBoxSaved {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    (Test-Path -LiteralPath $Path) -and (Test-PvmVirtualBoxSavedText -Text ([IO.File]::ReadAllText($Path)))
}

# Return whether the .vmx $Path says the VM is suspended. A missing file counts as not suspended.
function Test-PvmVMwareSuspended {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    (Test-Path -LiteralPath $Path) -and (Test-PvmVMwareSuspendedText -Text ([IO.File]::ReadAllText($Path)))
}

# --- Hypervisor choice -----------------------------------------------------------------------

# Return the VMware Workstation folder from the registry, the 32-bit key first, or $null when no
# key names a folder that holds vmware.exe.
function Get-PvmVMwareDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation', 'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation') {
        $dir = Invoke-PvmGetRegistryValue -Path $key -Name 'InstallPath'
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'vmware.exe'))) { return $dir }
    }
    $null
}

# Return the VirtualBox folder from the registry, or $null when it names no folder that holds
# VBoxManage.exe.
function Get-PvmVirtualBoxDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir = Invoke-PvmGetRegistryValue -Path 'HKLM:\SOFTWARE\Oracle\VirtualBox' -Name 'InstallDir'
    if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'VBoxManage.exe'))) { return $dir }
    $null
}

# Return the hypervisor to use, 'VMware' or 'VirtualBox'. The setting $Setting 'VMware' or
# 'VirtualBox' decides, in any case; any other value is Auto: a VMware suspend or a VirtualBox save
# is resumed in the program that holds it if that program is installed, else VMware is used when
# it is installed and the .vmx exists, else VirtualBox. The caller checks that the chosen one is
# installed.
function Select-PvmHypervisor {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Setting,
        [bool]$VMwareInstalled,
        [bool]$VirtualBoxInstalled,
        [bool]$VMwareSuspended,
        [bool]$VirtualBoxSaved,
        [bool]$VMwareVmxExists
    )
    switch ($Setting) {
        'VMware' { return 'VMware' }
        'VirtualBox' { return 'VirtualBox' }
    }
    if ($VMwareInstalled -and $VMwareSuspended) { return 'VMware' }
    if ($VirtualBoxInstalled -and $VirtualBoxSaved) { return 'VirtualBox' }
    if ($VMwareInstalled -and $VMwareVmxExists) { return 'VMware' }
    'VirtualBox'
}

# --- VMware Workstation ----------------------------------------------------------------------

# Start the VM $Vmx in VMware Workstation from the folder $VMwareDir without waiting for it, in
# full screen when $View is 'FullScreen', else in a window, and log it to $LogPath.
function Start-PvmVMwareVm {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$VMwareDir,
        [Parameter(Mandatory)][string]$Vmx,
        [string]$View,
        [Parameter(Mandatory)][string]$LogPath
    )
    $viewSwitch = if ($View -eq 'FullScreen') { '-X' } else { '-x' }
    if (-not $PSCmdlet.ShouldProcess($Vmx, 'Start the VM in VMware Workstation')) { return }
    Invoke-PvmStartProcess -FilePath (Join-Path $VMwareDir 'vmware.exe') -ArgumentList @('-n', '-q', $viewSwitch, "`"$Vmx`"")
    Write-PvmLog -Path $LogPath -Message "Started with VMware Workstation ($VMwareDir)"
}

# Start the VM in VMware Workstation from the folder $VMwareDir on the raw disk $Drive, as
# $Context and its Settings describe. VMware always gets the stick with the Data partition blanked:
# while the VM runs, it takes every Windows volume in the disk area it gives the VM away from
# Windows, and it cannot do that for the Data partition, which holds the VM's own files. The disk
# stays 'fullDevice', because in 'partitionedDevice' mode VMware insists on its own partition-table
# copy and refuses this descriptor. Returns 'AlreadyRunning', 'DryRun' or 'Started'; throws a stop.
function Invoke-PvmVMware {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$VMwareDir,
        [Parameter(Mandatory)][string]$Drive
    )
    $settings = $Context.Settings
    $log = $Context.LogPath
    $layout = Get-PvmDiskLayout -Drive $Drive -VmSectors $settings['VmSectors'] -DataPartitionStart $settings['DataPartitionStart'] -HideData $true
    $layout.CreateType = 'fullDevice'
    $vmx = Join-Path $Context.Root $settings['VMwareVmx']
    if (Test-PvmRunningInVMware -Vmx $vmx) {
        Write-PvmLog -Path $log -Message 'Already running in VMware.'
        return 'AlreadyRunning'
    }
    if (Test-PvmRunningInVirtualBox -VmUuid $settings['VirtualBoxVmUuid']) {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message 'A VirtualBox VM is running, possibly this one. Close it before starting the VM in VMware - the stick must never be used by two VMs at once.'
    }
    if (Test-PvmVirtualBoxSaved -Path (Join-Path $Context.Root $settings['VirtualBoxVbox'])) {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message 'The VM has a saved state in VirtualBox. Resume it in VirtualBox (on a PC with VirtualBox) and shut the guest down normally before starting it in VMware - otherwise the guest''s disk can get corrupted.'
    }

    $disk = Join-Path $Context.Root $settings['VMwareDisk']
    if (Test-Path -LiteralPath $disk) { Set-PvmDiskDescriptor -Path $disk -Layout $layout -LogPath $log -WhatIf:$Context.DryRun }
    else { New-PvmVMwareDescriptor -Path $disk -Layout $layout -LogPath $log -WhatIf:$Context.DryRun }
    if ($Context.DryRun) {
        Write-PvmLog -Path $log -Message "DRY RUN - would start $vmx with VMware Workstation ($VMwareDir)"
        return 'DryRun'
    }

    Start-PvmVMwareVm -VMwareDir $VMwareDir -Vmx $vmx -View $settings['VMwareView'] -LogPath $log
    'Started'
}

# --- VirtualBox ------------------------------------------------------------------------------

# Wait up to $TimeoutSeconds for every process named $Name to end, checking once a second.
function Wait-PvmProcessExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Invoke-PvmTestProcess -Name $Name) -and (Get-Date) -lt $deadline) { Invoke-PvmSleep -Seconds 1 }
}

# Return the value of the VMState line, quotes included, in the output $Output of
# `VBoxManage showvminfo --machinereadable`, or nothing when there is no such line.
function Get-PvmVirtualBoxVmState {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Output)
    ($Output -split "`n" | Where-Object { $_ -like 'VMState=*' }) -replace '^VMState=', ''
}

# Start the VirtualBox VM $VmUuid with VBoxManage at $VBoxManage and log to $LogPath which version
# of VirtualBox started it. Throws a stop with VBoxManage's output when the start fails.
function Start-PvmVirtualBoxVm {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VmUuid,
        [Parameter(Mandatory)][string]$LogPath
    )
    if (-not $PSCmdlet.ShouldProcess($VmUuid, 'Start the VM in VirtualBox')) { return }
    $start = Invoke-PvmNative -FilePath $VBoxManage -ArgumentList @('startvm', $VmUuid, '--type', 'gui')
    if ($start.ExitCode -ne 0) { throw (Get-PvmStopException -Message "VirtualBox could not start the VM:`n`n$($start.Output)") }
    Write-PvmLog -Path $LogPath -Message "Started with VirtualBox $((Invoke-PvmNative -FilePath $VBoxManage -ArgumentList @('--version')).Output)"
}

# Start the VM in VirtualBox from the folder $VirtualBoxDir on the raw disk $Drive, as $Context and
# its Settings describe: VBOX_USER_HOME points at the stick's VirtualBox home, the stick's drive
# letter is set in the .vbox and in VirtualBox.xml, and the descriptor is pointed at the stick. All
# VirtualBox windows of a user share one background service (VBoxSVC), which keeps the VM list it
# was started with, so it has to be started fresh, by this launcher. Returns 'AlreadyRunning',
# 'DryRun' or 'Started'; throws a stop.
function Invoke-PvmVirtualBox {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$VirtualBoxDir,
        [Parameter(Mandatory)][string]$Drive
    )
    $settings = $Context.Settings
    $log = $Context.LogPath
    $layout = Get-PvmDiskLayout -Drive $Drive -VmSectors $settings['VmSectors'] -DataPartitionStart $settings['DataPartitionStart'] -HideData $settings['HideDataPartition']
    $vboxManage = Join-Path $VirtualBoxDir 'VBoxManage.exe'
    $uuid = $settings['VirtualBoxVmUuid']
    Invoke-PvmSetEnvironment -Name 'VBOX_USER_HOME' -Value (Join-Path $Context.Root $settings['VirtualBoxHome'])
    $vmx = Join-Path $Context.Root $settings['VMwareVmx']
    if (Test-PvmRunningInVMware -Vmx $vmx) {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message 'The VM is running in VMware. Close it before starting it in VirtualBox.'
    }
    if (Test-PvmVMwareSuspended -Path $vmx) {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message 'The VM is suspended in VMware. Resume it in VMware (on a PC with VMware Workstation) and shut the guest down normally before starting it in VirtualBox - otherwise the guest''s disk can get corrupted.'
    }

    $open = @(Invoke-PvmGetProcess -Filter "Name='VirtualBox.exe' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'")
    if ($open.Count) {
        # VirtualBox hides its VM processes' command lines, so VirtualBox is asked whether this VM is the one running.
        $info = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('showvminfo', $uuid, '--machinereadable')
        if ($info.Output -match 'VMState="(running|paused|starting|restoring)"') {
            Write-PvmLog -Path $log -Message 'Already running in VirtualBox.'
            return 'AlreadyRunning'
        }
        Invoke-PvmStopUnlessDryRun -Context $Context -Message 'VirtualBox is already open on this PC. Close all VirtualBox windows, then start the VM again.'
    }
    if (-not $Context.DryRun) { Wait-PvmProcessExit -Name 'VBoxSVC' -TimeoutSeconds 30 }
    if (Invoke-PvmTestProcess -Name 'VBoxSVC') {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message 'VirtualBox is still running in the background. Wait half a minute, then start the VM again.'
    }

    $letterChange = @{ Root = $Context.Root; Letter = $Context.Letter; LogPath = $log; WhatIf = $Context.DryRun }
    Set-PvmDriveLetterInFile -Path (Join-Path $Context.Root $settings['VirtualBoxVbox']) @letterChange
    Set-PvmDriveLetterInFile -Path (Join-Path (Join-Path $Context.Root $settings['VirtualBoxHome']) 'VirtualBox.xml') @letterChange
    Set-PvmDiskDescriptor -Path (Join-Path $Context.Root $settings['VirtualBoxDisk']) -Layout $layout -LogPath $log -WhatIf:$Context.DryRun
    if ($Context.DryRun) {
        Write-PvmLog -Path $log -Message "DRY RUN - would start VM {$uuid} with VirtualBox ($VirtualBoxDir)"
        return 'DryRun'
    }

    $list = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('list', 'vms')
    if ($list.Output -notmatch $uuid) { throw (Get-PvmStopException -Message "VirtualBox did not find the VM in the stick's VM list:`n`n$($list.Output)") }
    $info = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('showvminfo', $uuid, '--machinereadable')
    $state = Get-PvmVirtualBoxVmState -Output $info.Output
    Write-PvmLog -Path $log -Message "VirtualBox VM state: $state"
    if ($state -match 'running|paused|starting|restoring') { return 'AlreadyRunning' }

    Start-PvmVirtualBoxVm -VBoxManage $vboxManage -VmUuid $uuid -LogPath $log
    'Started'
}

# --- Launch ----------------------------------------------------------------------------------

# Check that the disk the launcher runs from is the configured stick, choose the hypervisor and
# start the VM, as $Context describes (Invoke-PortableVM builds it). Returns 'AlreadyRunning',
# 'DryRun' or 'Started'; throws a stop.
function Invoke-PvmLaunch {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $settings = $Context.Settings
    $log = $Context.LogPath

    # 1. Find the stick this launcher is on, and make sure it is the right one.
    $partition = Invoke-PvmGetPartition -DriveLetter $Context.Letter
    $disk = Invoke-PvmGetDisk -Number $partition.DiskNumber
    $problem = Get-PvmStickProblem -Disk $disk -Partition $partition -Settings $settings
    if ($problem) { throw (Get-PvmStopException -Message $problem) }
    $drive = "\\.\PhysicalDrive$($disk.Number)"
    Write-PvmLog -Path $log -Message "Stick found: disk $($disk.Number) ($drive), drive $($Context.Letter):, ID $(Get-PvmDiskSignature -Disk $disk)"

    $deviceGuard = Invoke-PvmGetDeviceGuard
    if ($deviceGuard -and ($deviceGuard.SecurityServicesRunning -contains 2)) {
        Write-PvmLog -Path $log -Message 'Note: Memory Integrity is on, so the VM runs on top of Hyper-V (slower than native).'
    }

    # 2. Pick the hypervisor.
    $vmwareDir = Get-PvmVMwareDir
    $virtualBoxDir = Get-PvmVirtualBoxDir
    $vmx = Join-Path $Context.Root $settings['VMwareVmx']
    # Each state is logged as soon as it is known, so a .vbox that cannot be read does not hide a
    # VMware suspend from the log.
    $vmwareSuspended = Test-PvmVMwareSuspended -Path $vmx
    if ($vmwareSuspended) { Write-PvmLog -Path $log -Message 'Saved state found: suspended in VMware' }
    $virtualBoxSaved = Test-PvmVirtualBoxSaved -Path (Join-Path $Context.Root $settings['VirtualBoxVbox'])
    if ($virtualBoxSaved) { Write-PvmLog -Path $log -Message 'Saved state found: saved in VirtualBox' }
    $choice = @{
        Setting             = $settings['Hypervisor']
        VMwareInstalled     = [bool]$vmwareDir
        VirtualBoxInstalled = [bool]$virtualBoxDir
        VMwareSuspended     = $vmwareSuspended
        VirtualBoxSaved     = $virtualBoxSaved
        VMwareVmxExists     = (Test-Path -LiteralPath $vmx)
    }
    $use = Select-PvmHypervisor @choice
    if ($use -eq 'VMware' -and -not $vmwareDir) { throw (Get-PvmStopException -Message 'VMware Workstation is not installed on this PC.') }
    if ($use -eq 'VirtualBox' -and -not $virtualBoxDir) { throw (Get-PvmStopException -Message 'Neither VMware Workstation nor VirtualBox is installed on this PC.') }
    Write-PvmLog -Path $log -Message "Using $use"

    # 3. Start.
    if ($use -eq 'VMware') { Invoke-PvmVMware -Context $Context -VMwareDir $vmwareDir -Drive $drive }
    else { Invoke-PvmVirtualBox -Context $Context -VirtualBoxDir $virtualBoxDir -Drive $drive }
}

# Run the launcher from the folder $LauncherPath, which holds settings.psd1, launcher.log and the
# VERSION that the deploy tool writes, and whose parent folder is the stick's root: check the
# stick, choose the hypervisor and start the VM. With -DryRun every check runs and the log says
# what would change, but nothing is changed or started. Returns ExitCode, 0 or 1, and the Message
# to show with its Icon, both empty when there is nothing to show. Stops and other errors are
# logged as "STOPPED: ..." and returned; only a log that cannot be written throws.
function Invoke-PortableVM {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [switch]$DryRun
    )
    $logPath = Join-Path $LauncherPath 'launcher.log'
    try {
        Write-PvmLog -Path $logPath -Message "----- Start VM$(if ($DryRun) { ' (dry run)' }) -----"
        # VERSION is only for the log, so a missing or unreadable one never stops a start.
        $versionPath = Join-Path $LauncherPath 'VERSION'
        $version = 'unknown'
        try { if (Test-Path -LiteralPath $versionPath -PathType Leaf) { $version = [IO.File]::ReadAllText($versionPath).Trim() } }
        catch { $version = 'unreadable' }
        Write-PvmLog -Path $logPath -Message "Launcher version $version"
        $context = [pscustomobject]@{
            Root     = Split-Path $LauncherPath
            LogPath  = $logPath
            Letter   = $LauncherPath.Substring(0, 1).ToUpper()
            DryRun   = [bool]$DryRun
            # Import-PowerShellDataFile belongs to another module, so a missing file must stop here.
            Settings = Import-PowerShellDataFile -LiteralPath (Join-Path $LauncherPath 'settings.psd1') -ErrorAction Stop
        }
        $outcome = Invoke-PvmLaunch -Context $context
        if ($outcome -eq 'AlreadyRunning') { return [pscustomobject]@{ ExitCode = 0; Message = 'The VM is already running.'; Icon = 'Information' } }
        [pscustomobject]@{ ExitCode = 0; Message = ''; Icon = '' }
    } catch {
        $stop = Get-PvmStopMessage -ErrorRecord $_
        $message = if ($null -ne $stop) { $stop } else { "Unexpected error: $($_.Exception.Message)" }
        Write-PvmLog -Path $logPath -Message "STOPPED: $message"
        [pscustomobject]@{ ExitCode = 1; Message = $message; Icon = 'Error' }
    }
}
