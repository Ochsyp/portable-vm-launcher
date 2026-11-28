# -------------------------------------------------------
#                      PORTABLE VM
# -------------------------------------------------------
#
# The launcher's checks and start steps, used by Start-PortableVM.ps1 in the same folder: read
# and check the settings, find the stick the launcher runs from and check that it is the
# configured one, choose VMware Workstation or VirtualBox, point the VM's raw-disk descriptor at
# the stick and start the VM. The decisions, messages and log lines are those of the launcher
# before the redesign, apart from the changes that CHANGELOG.md lists, such as the suspend guard
# of phase 2 and the settings checks of phase 3.
#
# The launcher's code lives in the Launcher folder, which each deploy replaces as a whole. What it
# keeps between runs lives beside it in LauncherData: settings.psd1, logs\launcher.log with the
# older logs moved aside beside it, and, below backups\, the first version of each file it
# rewrites (Get-PvmDataPath).
#
# Importing the module runs nothing. Functions take what they need as parameters and throw, and
# Invoke-PortableVM turns a stop into the exit code and the message for the script to show.
# Everything the launcher reads from or starts on the PC goes through an Invoke-Pvm* adapter.
# With $env:PVM_TEST set to '1', as tests\run-checks.ps1 sets it, an adapter that a test did not
# mock throws, so no test reaches a disk, a process or a VM. Files are read and written directly;
# the tests keep theirs in TestDrive. tools\Deploy-PortableVM.ps1 imports the module too, for the
# settings checks and to turn schema 1 settings into schema 2.
#
# Invoke-PortableVM runs one start or dry run at a time on this PC: it holds the named mutex
# Global\PortableVM-Launcher (Invoke-PvmEnterLock) from before its first log line until it
# returns. Write-PvmLog writes every line of a message as "<local time with milliseconds and UTC
# offset> [<process ID>]  <message>", in one append that other launcher processes cannot break up,
# and never throws. A run that holds the lock first moves a full log, or one in the format before
# phase 4, aside as launcher-<yyyyMMdd-HHmmss>.log, and every run ends with a Timings line and an
# End line with its exit code.

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

# Return the system's message that the stop in $ErrorRecord keeps in Data['PvmDetail'], as for a
# settings file that cannot be opened, or '' when the stop keeps none or there is no stop.
function Get-PvmStopDetail {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    for ($exception = $ErrorRecord.Exception; $null -ne $exception; $exception = $exception.InnerException) {
        if ($exception.Data['PvmStop']) { return "$($exception.Data['PvmDetail'])" }
    }
    ''
}

# Return the time now with its UTC offset. It is the log's clock, which the tests mock.
function Get-PvmNow {
    [CmdletBinding()]
    [OutputType([DateTimeOffset])]
    param()
    [DateTimeOffset]::Now
}

# Return the message $Message as log text: each of its lines, split at CRLF, CR or LF, after the
# prefix "<Time as yyyy-MM-ddTHH:mm:ss.fff+hh:mm> [<ProcessId>]  ", joined with CRLF. The prefix
# uses the invariant culture, since another culture can change the time separator. The message
# starts after the first two consecutive spaces of a line, as it did before this format.
function Format-PvmLogText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][DateTimeOffset]$Time,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $prefix = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:yyyy-MM-dd''T''HH:mm:ss.fffzzz} [{1}]  ', $Time, $ProcessId)
    (@($Message -split '\r\n|\r|\n') | ForEach-Object { $prefix + $_ }) -join "`r`n"
}

# Return the cause of the first log failure of this run, or '' while there was none: the logs
# folder that Invoke-PortableVM could not create, in its words, or else the first write that
# failed, in Get-PvmPathCause's words. Invoke-PortableVM clears it when a run starts.
function Get-PvmLogProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    "$(Get-Variable -Name PvmLogProblem -Scope Script -ValueOnly -ErrorAction SilentlyContinue)"
}

# Return the system's ANSI code page, in which the log and old settings files are written. Windows
# PowerShell 5.1 calls it Default; PowerShell 7 calls UTF-8 Default and gives the ANSI code page
# for code page 0. Outside Windows there is no ANSI code page, and code page 0 is UTF-8.
function Get-PvmAnsiEncoding {
    [CmdletBinding()]
    [OutputType([Text.Encoding])]
    param()
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return [Text.Encoding]::Default }
    [Text.Encoding]::GetEncoding(0)
}

# Open the file $Path to append, sharing reading, writing and deletion. On Windows the handle may
# only append, so Windows puts each write at the file's end in one piece and other launcher
# processes cannot break a log text up; .NET Framework and .NET name that handle differently.
# Elsewhere the file is opened for writing at its end, without that promise.
function Open-PvmAppendStream {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'FileSystemAclExtensions is used only under PowerShell 7.')]
    [CmdletBinding()]
    [OutputType([IO.FileStream])]
    param([Parameter(Mandatory)][string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return [IO.FileStream]::new($Path, [IO.FileMode]::Append, [Security.AccessControl.FileSystemRights]::AppendData, $share, 4096, [IO.FileOptions]::None)
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return [System.IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path), [IO.FileMode]::Append,
            [Security.AccessControl.FileSystemRights]::AppendData, $share, 4096, [IO.FileOptions]::None, $null)
    }
    [IO.FileStream]::new($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, $share, 4096, [IO.FileOptions]::None)
}

# Append the message $Message to the log file $Path as Format-PvmLogText gives it, with the time
# now and this process's ID, and show it on the console. The text goes in one write through
# Open-PvmAppendStream, which on Windows makes sure that other launcher processes can neither break
# it up nor block it; -WhatIf does not affect it, so a dry run logs what it would
# do. It never throws: a failed write keeps its cause for Get-PvmLogProblem and says so on the
# console, unless an earlier failure of this run, the logs folder's included, is kept already.
function Write-PvmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $text = Format-PvmLogText -Time (Get-PvmNow) -ProcessId $PID -Message $Message
    Write-Host $text
    try {
        $bytes = (Get-PvmAnsiEncoding).GetBytes($text + "`r`n")
        $stream = Open-PvmAppendStream -Path $Path
        try { $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
    } catch {
        if (-not (Get-PvmLogProblem)) {
            # Windows denies the write to a folder of the log's name, which is the cause to name.
            $script:PvmLogProblem = if ([IO.Directory]::Exists($Path)) { 'it is a folder, not a file' } else { Get-PvmPathCause -Path $Path -ErrorRecord $_ }
            Write-Host "launcher.log could not be written: $script:PvmLogProblem"
        }
    }
}

# Return a short cause for the error $ErrorRecord that quotes no path, for a message that must not
# name a file on the stick: it is open in another program, access is denied, it is missing, an item
# of that name exists already, the disk is full, a path is too long, the drive is write-protected,
# not ready or not connected, the drive reported a read or write error, or Windows cannot access
# it; else the type of the error. Outside Windows, .NET puts the system's error number in HResult
# as it is, which Get-PvmErrnoCause reads; on Windows such a small number is no Windows code.
function Get-PvmErrorCause {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $record = $ErrorRecord
    $exception = $record.Exception
    if ($exception -is [System.Management.Automation.ActionPreferenceStopException] -and $null -ne $exception.ErrorRecord) {
        $record = $exception.ErrorRecord
        $exception = $record.Exception
    }
    while (($exception -is [System.Management.Automation.MethodInvocationException] -or $exception -is [System.Reflection.TargetInvocationException]) -and
        $null -ne $exception.InnerException) {
        $exception = $exception.InnerException
    }
    # An HRESULT from Windows (facility 7) holds the Windows error code in its low word.
    $code = if (($exception.HResult -band 0xFFFF0000) -eq 0x80070000) { $exception.HResult -band 0xFFFF } else { 0 }
    if ($code -eq 0 -and $exception.HResult -gt 0 -and -not (Test-PvmWindowsHost)) {
        $cause = Get-PvmErrnoCause -Errno $exception.HResult
        if ($cause) { return $cause }
    }
    if ($code -eq 32 -or $code -eq 33) { return 'it is open in another program' }
    if ($exception -is [UnauthorizedAccessException] -or $code -eq 5) { return 'access is denied' }
    if ($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException] -or
        $exception -is [System.Management.Automation.ItemNotFoundException] -or $code -eq 2 -or $code -eq 3) { return 'it is missing' }
    # New-Item reports a folder that is there already as an IOException without a Windows code.
    if ($code -eq 80 -or $code -eq 183 -or "$($record.FullyQualifiedErrorId)" -like 'DirectoryExist,*') { return 'an item of that name exists already' }
    if ($code -eq 39 -or $code -eq 112) { return 'the disk is full' }
    if ($exception -is [IO.PathTooLongException] -or $code -eq 206) { return 'a path is too long' }
    if ($code -eq 19) { return 'the drive is write-protected' }
    if ($code -eq 21) { return 'the drive is not ready' }
    if ($code -eq 1167) { return 'the drive is not connected' }
    if (@(23, 31, 121, 483, 1117, 1392) -contains $code) { return 'the drive reported a read or write error' }
    if ($code -eq 1920) { return 'Windows cannot access it' }
    "an error of type $($exception.GetType().Name)"
}

# Return the cause, in Get-PvmErrorCause's words, of the Linux error number $Errno, or '' for a
# number it does not know: the file is locked (EAGAIN, EBUSY, ETXTBSY), access is denied (EPERM,
# EACCES), it is missing (ENOENT), it exists (EEXIST), the disk or the quota is full (ENOSPC,
# EDQUOT), a name is too long (ENAMETOOLONG), the file system is read-only (EROFS), there is no
# medium (ENOMEDIUM), the device is gone (ENXIO, ENODEV) or reported an I/O error (EIO).
function Get-PvmErrnoCause {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Errno)
    switch ($Errno) {
        { $_ -in 11, 16, 26 } { return 'it is open in another program' }
        { $_ -in 1, 13 } { return 'access is denied' }
        2 { return 'it is missing' }
        17 { return 'an item of that name exists already' }
        { $_ -in 28, 122 } { return 'the disk is full' }
        36 { return 'a path is too long' }
        30 { return 'the drive is write-protected' }
        123 { return 'the drive is not ready' }
        { $_ -in 6, 19 } { return 'the drive is not connected' }
        5 { return 'the drive reported a read or write error' }
    }
    ''
}

# Return the cause of the error $ErrorRecord of a write to the file $Path, as Get-PvmErrorCause
# words it, but on Windows 'a path is too long' when it says 'it is missing' and $Path has 260
# characters or more, since Windows without long-path support names a missing part of such a path.
function Get-PvmPathCause {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    $cause = Get-PvmErrorCause -ErrorRecord $ErrorRecord
    if ($cause -eq 'it is missing' -and $Path.Length -ge 260 -and (Test-PvmWindowsHost)) { return 'a path is too long' }
    $cause
}

# Return the cause $Cause as it reads after "because" in a sentence: a cause that names only the
# type of an error, as Get-PvmErrorCause words an error it does not know, gets "of" before it.
function Format-PvmBecause {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Cause)
    if ($Cause.StartsWith('an error of type ')) { return "of $Cause" }
    $Cause
}

# Return the message of the innermost error in $ErrorRecord that PowerShell did not add, below an
# ActionPreferenceStopException and the wrappers of a .NET method call, as Get-PvmErrorCause
# unwraps them.
function Get-PvmErrorText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $exception = $ErrorRecord.Exception
    if ($exception -is [System.Management.Automation.ActionPreferenceStopException] -and $null -ne $exception.ErrorRecord) { $exception = $exception.ErrorRecord.Exception }
    while (($exception -is [System.Management.Automation.MethodInvocationException] -or $exception -is [System.Reflection.TargetInvocationException]) -and
        $null -ne $exception.InnerException) {
        $exception = $exception.InnerException
    }
    $exception.Message.Trim()
}

# Return the log lines that describe the unexpected error $ErrorRecord: "Error detail: <type>:
# <message>" for its exception and up to three inner ones, each on one line, "Error ID: <its
# FullyQualifiedErrorId>", and "Error trace: <frame>" for the first 10 frames of its script stack.
# They can name paths on the stick, so they go to the log only.
function Format-PvmErrorDetail {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $exception = $ErrorRecord.Exception
    for ($depth = 0; $null -ne $exception -and $depth -le 3; $depth++) {
        "Error detail: $($exception.GetType().FullName): $(($exception.Message -replace '\s*[\r\n]+\s*', ' ').Trim())"
        $exception = $exception.InnerException
    }
    "Error ID: $($ErrorRecord.FullyQualifiedErrorId)"
    foreach ($frame in @("$($ErrorRecord.ScriptStackTrace)" -split '\r\n|\r|\n' | Where-Object { $_.Trim() } | Select-Object -First 10)) {
        "Error trace: $($frame.Trim())"
    }
}

# Return the words for the step $Step of a run (Enter-PvmStep), as in "Unexpected error while
# <them>".
function Get-PvmStepText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Step)
    switch ($Step) {
        'setup' { 'starting the launcher' }
        'settings' { 'reading the settings' }
        'stick' { 'finding the stick' }
        'choice' { 'checking this PC and the saved states' }
        'checks' { 'checking for running VMs' }
        'question' { 'asking whether to resume the saved state' }
        'wait' { "waiting for VirtualBox's background service to end" }
        'files' { 'pointing the VM files at the stick' }
        'start' { 'starting the VM' }
        'verify' { 'checking that the VM runs' }
        'watch' { 'watching the VM' }
        'disarm' { 'pointing the disk file away from the stick' }
        default { 'running the launcher' }
    }
}

# End the current step of the run $Context (Invoke-PortableVM), adding its time to
# $Context.Times, and begin the step $Name; '' ends the last one. A step entered again adds up.
function Enter-PvmStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )
    if ($Context.Step) { $Context.Times[$Context.Step] = [int64]$Context.Times[$Context.Step] + $Context.Clock.ElapsedMilliseconds }
    $Context.Clock.Restart()
    $Context.Step = $Name
}

# Return the log line for the step durations $Times (step -> milliseconds, in the order the steps
# began): "Timings: <step> <n> ms, ..., total <n> ms", the total being their sum.
function Format-PvmTiming {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Times)
    $total = [int64]0
    $parts = foreach ($key in $Times.Keys) {
        $total += [int64]$Times[$key]
        "$key $([int64]$Times[$key]) ms"
    }
    'Timings: ' + ((@($parts) + "total $total ms") -join ', ')
}

# In a dry run ($Context.DryRun), log that a real start would stop here with $Message and carry
# on with the checks; the first such message becomes the dry run's result ($Context.WouldStop).
# Otherwise throw the stop.
function Invoke-PvmStopUnlessDryRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Context.DryRun) {
        Write-PvmLog -Path $Context.LogPath -Message "DRY RUN - a real start would stop here: $Message"
        if (-not $Context.WouldStop) { $Context.WouldStop = $Message }
    } else {
        throw (Get-PvmStopException -Message $Message)
    }
}

# --- Host ------------------------------------------------------------------------------------

# Return whether this PC runs Windows. The rules that differ between systems ask this one function,
# so that tests can take either side of them on any system.
function Test-PvmWindowsHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
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

# Return this PC's size, for the VM's size (request r9): Cores and Threads, the processors' cores
# and logical processors, MemoryMB, the memory installed, and FreeMB, the memory free now; outside
# Windows nothing yet, which the step "Linux host" adds.
function Invoke-PvmGetHostSize {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    if (-not (Test-PvmWindowsHost)) { return $null }
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    [uint64]$installed = 0
    foreach ($module in @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)) { $installed += [uint64]$module.Capacity }
    if (-not $installed) { $installed = [uint64](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory }
    $system = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{
        Cores    = [int](($processors | Measure-Object -Property NumberOfCores -Sum).Sum)
        Threads  = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        MemoryMB = [int64][Math]::Floor($installed / 1MB)
        FreeMB   = [int64][Math]::Floor([uint64]$system.FreePhysicalMemory / 1024)
    }
}

# Return the bytes free for this account on the drive that holds the path $Path.
function Invoke-PvmGetFreeSpace {
    [CmdletBinding()]
    [OutputType([int64])]
    param([Parameter(Mandatory)][string]$Path)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))).AvailableFreeSpace
}

# Return the partitions of the disk with the number $Number.
function Invoke-PvmGetDiskPartition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Number)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Get-Partition -DiskNumber $Number -ErrorAction Stop
}

# Return the disk with the number $Number.
function Invoke-PvmGetDisk {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Number)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Get-Disk -Number $Number -ErrorAction Stop
}

# Return the processes of the programs named $Name, without .exe, each with its Name and
# CommandLine; CommandLine is empty where this process may not read it. Windows PowerShell's
# Get-Process has no command line, so on Windows they come from Win32_Process
# (ConvertTo-PvmProcessFilter), with .exe in their names.
function Invoke-PvmGetProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    if (Test-PvmWindowsHost) { return (Get-CimInstance -ClassName Win32_Process -Filter (ConvertTo-PvmProcessFilter -Name $Name)) }
    Get-Process -Name $Name -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.ProcessName; CommandLine = $_.CommandLine } }
}

# Return the WQL condition that selects the Win32_Process instances of the programs named $Name,
# without .exe, in that order: Name='<name>.exe' OR ...
function ConvertTo-PvmProcessFilter {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Name)
    (@($Name | ForEach-Object { "Name='$_.exe'" })) -join ' OR '
}

# Return whether a process named $Name runs in this Windows session, so that another signed-in
# user's VirtualBox background service does not count.
function Invoke-PvmTestProcess {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    $session = (Get-Process -Id $PID).SessionId
    [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
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

# Return whether this process runs with administrator rights, as the script checks before it asks
# for them.
function Invoke-PvmTestAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Take the named mutex $Name for this run without waiting (Enter-PvmMutex).
function Invoke-PvmEnterLock {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Name)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Enter-PvmMutex -Name $Name
}

# Release the run's lock $Lock (Exit-PvmMutex).
function Invoke-PvmExitLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Lock)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    Exit-PvmMutex -Lock $Lock
}

# Return the Authenticode signature of the program $Path: its Status, 'Valid' when Windows trusts
# it, and the Signer, the common name of the certificate that signed it ('' when there is none).
function Invoke-PvmGetSignature {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    Assert-PvmNotUnderTest -Name $MyInvocation.MyCommand.Name
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } else { '' }
    [pscustomobject]@{ Status = "$($signature.Status)"; Signer = "$signer" }
}

# --- Data folder -----------------------------------------------------------------------------

# Return the paths that the launcher in the folder $LauncherPath uses. Root is the stick folder
# that holds Launcher and LauncherData, and the folder the path settings start from. Data is
# LauncherData, with Settings (settings.psd1), Logs and Log (logs\launcher.log), Backups (the
# first versions of the files the launcher rewrites), Legacy (backups\legacy, the copies that
# deploy -MigrateSettings moved there from the VM folders) and State (kept free for later
# phases). OldSettings is Launcher\settings.psd1, where the launcher read its settings before.
function Get-PvmDataPath {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$LauncherPath)
    $root = Split-Path $LauncherPath
    $data = Join-Path $root 'LauncherData'
    [pscustomobject]@{
        Root        = $root
        Data        = $data
        Settings    = Join-Path $data 'settings.psd1'
        Logs        = Join-Path $data 'logs'
        Log         = Join-Path (Join-Path $data 'logs') 'launcher.log'
        Backups     = Join-Path $data 'backups'
        Legacy      = Join-Path (Join-Path $data 'backups') 'legacy'
        State       = Join-Path $data 'state'
        OldSettings = Join-Path $LauncherPath 'settings.psd1'
    }
}

# Return where the launcher keeps the first version of the file $Path, which lies below the stick
# folder $Root: at the same path relative to $Backups, with $Suffix added. Names compare in any
# case on Windows and exactly elsewhere, as the file systems there do. Throws when $Path is not
# below $Root, which the path settings rule out.
function Get-PvmBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Backups,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Suffix
    )
    $below = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    $comparison = if (Test-PvmWindowsHost) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.StartsWith($below, $comparison)) { throw "$Path is not below $Root." }
    Join-Path $Backups ($full.Substring($below.Length) + $Suffix)
}

# Return the path setting $Path, written with \ or / between its names, joined to the stick folder
# $Root. On Windows that is what Join-Path gives; elsewhere each \ becomes /, since only / parts
# names there.
function Join-PvmStickPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    if ([IO.Path]::DirectorySeparatorChar -eq '\') { return (Join-Path $Root $Path) }
    $Root.TrimEnd('/') + '/' + $Path.Replace('\', '/')
}

# --- Run lock and log files ------------------------------------------------------------------

# Return the name of the mutex that one run of the launcher at a time holds on this PC, in every
# Windows session, since the stick's raw disk belongs to the PC.
function Get-PvmLockName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'Global\PortableVM-Launcher'
}

# Return the message of a run on a system other than Windows, where the launcher cannot find the
# stick's disk yet (Get-PvmStickLocation).
function Get-PvmOtherSystemMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'On this system the launcher cannot tell yet which disk is the USB stick; so far it starts the VM only on Windows. Nothing was started.'
}

# Return the message of a run that finds another run holding the lock, which may be a start
# that watches the VM while it runs (Watch-PvmVm).
function Get-PvmBusyMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'Another run of the launcher is in progress on this PC: a start of the VM or a dry run, or the launcher watching the VM while it runs. If the VM runs, nothing needs doing; otherwise wait until that run has finished, then start the VM again. Nothing was started.'
}

# Take the named mutex $Name without waiting. Returns State 'Acquired', or 'Abandoned' when an
# earlier holder ended without releasing it, with the Mutex that this thread now owns; or State
# 'Busy' and no Mutex when another holder has it or this process may not open it. Throws when the
# name belongs to another kind of object, so that the run stops.
function Enter-PvmMutex {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Name)
    try { $mutex = [System.Threading.Mutex]::new($false, $Name) }
    catch [System.UnauthorizedAccessException] { return [pscustomobject]@{ State = 'Busy'; Mutex = $null } }
    try {
        if ($mutex.WaitOne(0)) { return [pscustomobject]@{ State = 'Acquired'; Mutex = $mutex } }
    } catch [System.Threading.AbandonedMutexException] {
        return [pscustomobject]@{ State = 'Abandoned'; Mutex = $mutex }
    }
    $mutex.Dispose()
    [pscustomobject]@{ State = 'Busy'; Mutex = $null }
}

# Release and close the mutex of the lock $Lock (Enter-PvmMutex). The thread that took it must
# release it.
function Exit-PvmMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Lock)
    try { $Lock.Mutex.ReleaseMutex() }
    finally { $Lock.Mutex.Dispose() }
}

# Return whether the log file $Path is empty or starts with a line in the format of Write-PvmLog,
# reading at most its first 64 bytes while others may write or move it. Throws when the file
# cannot be read.
function Test-PvmLogFormat {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $buffer = New-Object byte[] 64
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $count = $stream.Read($buffer, 0, $buffer.Length) }
    finally { $stream.Dispose() }
    if ($count -eq 0) { return $true }
    [Text.Encoding]::ASCII.GetString($buffer, 0, $count) -match '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d \[\d+\]  '
}

# Move the log file $Path aside in its folder as <name>-<Time as yyyyMMdd-HHmmss><extension> when
# it holds $MaxBytes or more, or when it starts with a line in another format (Test-PvmLogFormat),
# as the log of a launcher before phase 4 does. Returns $null when there is nothing to move, else
# Name, the new file name, or Problem, the cause in Get-PvmPathCause's words when the move failed.
# It never throws, and it never replaces a file: a move onto a name that exists fails.
function Move-PvmOldLog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][DateTimeOffset]$Time,
        [int64]$MaxBytes = 1MB
    )
    $target = $Path
    try {
        $file = [IO.FileInfo]::new($Path)
        if (-not $file.Exists -or $file.Length -eq 0) { return $null }
        if ($file.Length -lt $MaxBytes -and (Test-PvmLogFormat -Path $Path)) { return $null }
        $name = [IO.Path]::GetFileNameWithoutExtension($Path) + '-' + $Time.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + [IO.Path]::GetExtension($Path)
        $target = Join-Path (Split-Path $Path) $name
        [IO.File]::Move($Path, $target)
        [pscustomobject]@{ Name = $name; Problem = '' }
    } catch {
        [pscustomobject]@{ Name = ''; Problem = (Get-PvmPathCause -Path $target -ErrorRecord $_) }
    }
}

# Return the drive letter, in upper case, of the path $Path when its root is "<letter>:\", or
# $null for any other root: a share, a \\?\ or \\.\ path, or a path relative to a drive.
function Get-PvmDriveLetter {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    if ($root -match '\A[A-Za-z]:\\\z') { $root.Substring(0, 1).ToUpperInvariant() } else { $null }
}

# --- Stick location --------------------------------------------------------------------------
# Where the stick is mounted decides how the launcher finds its disk. On Windows that is the drive
# letter of the launcher folder; the step "Linux host" adds the Linux kind. The launcher asks only
# these functions, so the rest of it does not depend on drive letters.

# Return the location of the stick folder $Root, which holds the launcher folder $LauncherPath:
# on Windows Kind 'DriveLetter', with the Letter in upper case (Get-PvmDriveLetter) and the Path
# $Root; or $null where the launcher cannot find the stick's disk from it: a launcher folder
# without a drive letter, or a system other than Windows.
function Get-PvmStickLocation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][string]$Root
    )
    if (-not (Test-PvmWindowsHost)) { return $null }
    $letter = Get-PvmDriveLetter -Path $LauncherPath
    if (-not $letter) { return $null }
    [pscustomobject]@{ Kind = 'DriveLetter'; Letter = $letter; Path = $Root }
}

# Return the raw device by which a hypervisor opens the whole disk $Disk on Windows.
function Get-PvmRawDevice {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Disk)
    "\\.\PhysicalDrive$($Disk.Number)"
}

# Return the Partition the stick folder at $Location (Get-PvmStickLocation) is on, its Disk and the
# raw Device of that disk (Get-PvmRawDevice), through the adapters. Throws a stop, naming the VM
# as $Names says (Format-PvmMessage), when Windows has no partition with the location's drive
# letter, as for a network drive or one made with subst.
function Get-PvmStickDevice {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Location,
        [Parameter(Mandatory)][hashtable]$Names
    )
    try { $partition = Invoke-PvmGetPartition -DriveLetter $Location.Letter }
    catch {
        if ("$($_.FullyQualifiedErrorId)" -like 'CmdletizationQuery_NotFound_DriveLetter,*') {
            throw (Get-PvmStopException -Message (Format-PvmMessage -Names $Names -Template 'Windows has no partition with the drive letter {Letter}:, so the launcher cannot tell which disk is the USB stick; a network drive or a drive made with subst has none. Start it with Start VM.cmd on the stick''s own drive. Nothing was started.' -Values @{
                        Letter = $Location.Letter
                    }))
        }
        throw
    }
    $disk = Invoke-PvmGetDisk -Number $partition.DiskNumber
    [pscustomobject]@{ Partition = $partition; Disk = $disk; Device = (Get-PvmRawDevice -Disk $disk) }
}

# --- Settings --------------------------------------------------------------------------------
# LauncherData\settings.psd1 holds one hashtable of plain values. The launcher parses it without
# running anything in it, checks every value against schema 2 before it reads the PC, and fills
# in the defaults. A file with problems stops the launcher with one message that names each bad
# key and never a value from the file.

# Return settings schema 2, one entry per key, in the order the checks report them: its Name,
# whether it is Required, the Default a missing key gets, the Kind of value it holds and the
# Values that kind allows: the words of a Choice, or the extension of a Path, none for a folder.
# A key of the Kind Unused is no longer used: any value passes, and a start notes the key.
function Get-PvmSettingSchema {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{ Name = 'SchemaVersion'; Required = $true; Default = $null; Kind = 'Schema'; Values = @() }
    [pscustomobject]@{ Name = 'IsExample'; Required = $false; Default = $false; Kind = 'Bool'; Values = @() }
    [pscustomobject]@{ Name = 'VmDisplayName'; Required = $false; Default = 'the VM'; Kind = 'Name'; Values = @() }
    [pscustomobject]@{ Name = 'GuestName'; Required = $false; Default = 'the guest'; Kind = 'Name'; Values = @() }
    [pscustomobject]@{ Name = 'Hypervisor'; Required = $false; Default = 'Auto'; Kind = 'Choice'; Values = @('Auto', 'VMware', 'VirtualBox') }
    [pscustomobject]@{ Name = 'VMwareView'; Required = $false; Default = 'Window'; Kind = 'Choice'; Values = @('Window', 'FullScreen') }
    [pscustomobject]@{ Name = 'SavedStatePolicy'; Required = $false; Default = 'Ask'; Kind = 'Choice'; Values = @('Ask', 'Refuse') }
    [pscustomobject]@{ Name = 'HideDataPartition'; Required = $false; Default = $null; Kind = 'Unused'; Values = @() }
    [pscustomobject]@{ Name = 'ProtectBootArea'; Required = $false; Default = $null; Kind = 'Unused'; Values = @() }
    [pscustomobject]@{ Name = 'StickMbrSignature'; Required = $true; Default = $null; Kind = 'Signature'; Values = @() }
    [pscustomobject]@{ Name = 'StickSectors'; Required = $true; Default = $null; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'VmSectors'; Required = $true; Default = $null; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'DataPartitionStart'; Required = $true; Default = $null; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'VirtualBoxVmUuid'; Required = $false; Default = $null; Kind = 'Uuid'; Values = @() }
    [pscustomobject]@{ Name = 'VirtualBoxHome'; Required = $true; Default = $null; Kind = 'Path'; Values = @() }
    [pscustomobject]@{ Name = 'VirtualBoxVbox'; Required = $true; Default = $null; Kind = 'Path'; Values = @('.vbox') }
    [pscustomobject]@{ Name = 'VirtualBoxDisk'; Required = $false; Default = $null; Kind = 'Path'; Values = @('.vmdk') }
    [pscustomobject]@{ Name = 'VMwareVmx'; Required = $true; Default = $null; Kind = 'Path'; Values = @('.vmx') }
    [pscustomobject]@{ Name = 'VMwareDisk'; Required = $false; Default = $null; Kind = 'Path'; Values = @('.vmdk') }
    [pscustomobject]@{ Name = 'VmSizing'; Required = $false; Default = 'Auto'; Kind = 'Choice'; Values = @('Auto', 'Off', 'Fixed') }
    [pscustomobject]@{ Name = 'VmCpus'; Required = $false; Default = $null; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'VmMemoryGB'; Required = $false; Default = $null; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'VmMaxCpus'; Required = $false; Default = 8; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'VmMaxMemoryGB'; Required = $false; Default = 16; Kind = 'Count'; Values = @() }
}

# Return what is wrong with the path setting $Value, or nothing when it names a file that ends in
# $Extension, or a folder when $Extension is empty, below the stick folder. Such a path is
# relative, uses \ or / as separator and has no blank at either end, and each of its parts is a
# real name: not empty, '.' or '..', not ending in a dot or a blank, no device name such as CON
# or NUL, and no character Windows forbids in a name, such as ':' (Get-PvmForbiddenNameChar), on
# every system, so that settings that pass on one system pass on the other. Joined to the stick
# folder, it gives the path that [IO.Path]::GetFullPath gives, so the launcher compares and logs
# the path Windows uses.
function Get-PvmPathProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [AllowEmptyString()][string]$Extension
    )
    $what = if ($Extension) { "a $Extension file" } else { 'a folder' }
    $problem = "must name $what below the folder that holds Launcher and LauncherData, without a drive, '.' or '..'"
    if (-not $Value -or $Value -ne $Value.Trim() -or $Value -match '\A[\\/]') { return $problem }
    $forbidden = [char[]]@(Get-PvmForbiddenNameChar)
    foreach ($part in ($Value -split '[\\/]')) {
        if (-not $part -or $part -match '[. ]\z' -or $part.IndexOfAny($forbidden) -ge 0 -or
            $part -match '\A(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9]|LPT[1-9])(\.|\z)') { return $problem }
    }
    if ($Extension -and -not $Value.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { return $problem }
}

# Return the characters Windows forbids in a file name, which [IO.Path]::GetInvalidFileNameChars
# gives on Windows: the control characters and " < > | : * ? \ /. Outside Windows that call gives
# only NUL and /.
function Get-PvmForbiddenNameChar {
    [CmdletBinding()]
    [OutputType([char], [char[]])]
    param()
    [char[]](@(0..31 | ForEach-Object { [char]$_ }) + [char[]]'"<>|:*?\/')
}

# Return whether $Value can name the VM or the guest in a message or a dialog title: 1 to 40
# characters, a surrogate pair such as an emoji counting as one; no control, format or private-use
# character, line or paragraph separator or lone surrogate, apart from the zero-width joiners that
# some scripts and emoji need inside a name; no blank or joiner at either end; and at least one
# letter, number, punctuation mark or symbol that shows, not a filler such as U+3164. Categories
# come from CharUnicodeInfo, whose tables are complete, unlike those of .NET's regular expressions
# (which take U+00AD for a dash); a character those tables do not know yet counts as one that shows,
# but a noncharacter such as U+FFFF, which will never be assigned, does not.
function Test-PvmNameText {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $joiners = @(0x200C, 0x200D)
    if ($Value.Length -eq 0 -or $Value -cne $Value.Trim() -or $joiners -contains [int]$Value[0] -or $joiners -contains [int]$Value[$Value.Length - 1]) { return $false }
    $refused = 'Control', 'Format', 'PrivateUse', 'Surrogate', 'LineSeparator', 'ParagraphSeparator'
    $fillers = @(0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800)
    $count = 0
    $shows = $false
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $category = "$([Globalization.CharUnicodeInfo]::GetUnicodeCategory($Value, $i))"
        $pair = [char]::IsSurrogatePair($Value, $i)
        $code = if ($pair) { [char]::ConvertToUtf32($Value, $i) } else { [int]$Value[$i] }
        if ($refused -contains $category -and -not ($category -eq 'Format' -and $joiners -contains $code)) { return $false }
        $noncharacter = ($code -band 0xFFFE) -eq 0xFFFE -or ($code -ge 0xFDD0 -and $code -le 0xFDEF)
        if ($category -match 'Letter|Number|Punctuation|Symbol|OtherNotAssigned' -and $fillers -notcontains $code -and -not $noncharacter) { $shows = $true }
        $count++
        if ($pair) { $i++ }
    }
    $shows -and $count -le 40
}

# Return what is wrong with $Value as the value of the schema entry $Entry (Get-PvmSettingSchema),
# or nothing when it is good. Values are not converted: 'false' is no $false, and '42' and 42.0
# are no whole numbers. The formats are anchored with \A and \z, since $ also matches before a
# final line feed.
function Get-PvmValueProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [AllowNull()]$Value
    )
    $text = $Value -is [string]
    switch ($Entry.Kind) {
        'Schema' { if (-not ($Value -is [int] -and $Value -eq 2)) { return 'must be 2, the only schema this launcher reads' } }
        'Bool' { if ($Value -isnot [bool]) { return 'must be $true or $false' } }
        # A key that is no longer used changes nothing, so no value of it stops a start.
        'Unused' { }
        'Name' {
            if (-not ($text -and (Test-PvmNameText -Value $Value))) {
                return 'must be 1 to 40 characters of text that shows, without control or formatting characters, and without a blank or a joiner at either end'
            }
        }
        'Choice' {
            if (-not ($text -and $Entry.Values -contains $Value)) {
                $words = @($Entry.Values | ForEach-Object { "'$_'" })
                return "must be $($words[0..($words.Count - 2)] -join ', ') or $($words[-1])"
            }
        }
        'Signature' {
            if (-not ($text -and $Value -match '\A[0-9A-Fa-f]{8}\z' -and $Value -ne '00000000')) { return 'must be the disk signature as 8 hex digits, not 00000000' }
        }
        'Count' { if (-not (($Value -is [int] -or $Value -is [long]) -and $Value -gt 0)) { return 'must be a whole number above 0' } }
        'Uuid' {
            if (-not ($text -and $Value -match '\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z')) {
                return "must be the VM's UUID as VBoxManage list vms shows it, without braces"
            }
        }
        'Path' {
            $extension = if ($Entry.Values.Count) { $Entry.Values[0] } else { '' }
            $value = if ($text) { $Value } else { '' }
            return (Get-PvmPathProblem -Value $value -Extension $extension)
        }
        default { throw "The schema has no rule for the kind $($Entry.Kind)." }
    }
}

# Return the problems of $Settings, the hashtable read from a settings file, against
# Get-PvmSettingSchema: one '<Key>: <what it must be>' line per bad key, never its value. Unknown
# keys come first, then the schema's keys in its order, then the rule that ties the three sector
# values together, checked only when each of them is good. A file still marked IsExample = $true,
# or one without SchemaVersion, gets that one problem only.
function Test-PvmSetting {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Settings)
    # Keys match without case, as in any PowerShell hashtable.
    $values = @{}
    foreach ($key in $Settings.Keys) { $values["$key"] = $Settings[$key] }
    if ($values['IsExample'] -is [bool] -and $values['IsExample']) {
        return 'IsExample: the file is still the example; fill in your values, then delete the IsExample line'
    }
    if (-not $values.ContainsKey('SchemaVersion')) { return 'SchemaVersion: missing; add SchemaVersion = 2 (see examples\settings.example.psd1)' }
    $schema = @(Get-PvmSettingSchema)
    $names = @($schema | ForEach-Object { $_.Name })
    foreach ($key in @($values.Keys | Sort-Object)) {
        if ($names -notcontains $key) { "${key}: unknown setting; compare it with examples\settings.example.psd1" }
    }
    $good = @{}
    foreach ($entry in $schema) {
        if (-not $values.ContainsKey($entry.Name)) {
            if ($entry.Required) { "$($entry.Name): missing" }
            continue
        }
        $problem = Get-PvmValueProblem -Entry $entry -Value $values[$entry.Name]
        if ($problem) { "$($entry.Name): $problem" } else { $good[$entry.Name] = $true }
    }
    if ($good['StickSectors'] -and $good['VmSectors'] -and $good['DataPartitionStart'] -and
        -not ($values['DataPartitionStart'] -lt $values['VmSectors'] -and $values['VmSectors'] -le $values['StickSectors'])) {
        'VmSectors: must be above DataPartitionStart and at most StickSectors'
    }
    # The VM's size (Get-PvmVmSizeTarget): Fixed needs both numbers, and the upper bounds of the
    # rule are not below its floors of 2 CPUs and 4 GB.
    if ($good['VmSizing'] -and $values['VmSizing'] -eq 'Fixed') {
        foreach ($key in 'VmCpus', 'VmMemoryGB') { if (-not $values.ContainsKey($key)) { "${key}: needed when VmSizing is Fixed" } }
    }
    if ($good['VmMaxCpus'] -and $values['VmMaxCpus'] -lt 2) { 'VmMaxCpus: must be at least 2' }
    if ($good['VmMaxMemoryGB'] -and $values['VmMaxMemoryGB'] -lt 4) { 'VmMaxMemoryGB: must be at least 4' }
}

# Return the checked settings $Settings with the Default of each missing key filled in and the
# three sector values as [int64].
function Merge-PvmSetting {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Settings)
    $merged = @{}
    foreach ($key in $Settings.Keys) { $merged["$key"] = $Settings[$key] }
    foreach ($entry in Get-PvmSettingSchema) {
        if (-not $merged.ContainsKey($entry.Name) -and -not $entry.Required) { $merged[$entry.Name] = $entry.Default }
    }
    foreach ($name in 'StickSectors', 'VmSectors', 'DataPartitionStart') { $merged[$name] = [int64]$merged[$name] }
    $merged
}

# Return the text of a settings file from its bytes $Bytes, decoded strictly. A byte order mark
# chooses UTF-8 or UTF-16. Without one the file must be ASCII: Windows PowerShell 5.1 reads such a
# file as ANSI, and the launcher and the tools must see the same text. -Legacy, for a schema 1
# file that deploy migrates, reads a file without a byte order mark as ANSI, as the launcher
# before schema 2 read it. Throws the reason, which quotes nothing from the file.
function ConvertFrom-PvmDataFileByte {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [switch]$Legacy
    )
    $name = ''
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $name = 'UTF-8'
        $encoding = New-Object System.Text.UTF8Encoding $false, $true
        $skip = 3
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $name = 'UTF-16'
        $encoding = New-Object System.Text.UnicodeEncoding $false, $false, $true
        $skip = 2
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $name = 'UTF-16'
        $encoding = New-Object System.Text.UnicodeEncoding $true, $false, $true
        $skip = 2
    } elseif ($Legacy) {
        return (Get-PvmAnsiEncoding).GetString($Bytes)
    } else {
        if (@($Bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0) {
            throw 'it holds characters outside ASCII but no byte order mark; save it as UTF-8 with BOM'
        }
        return [Text.Encoding]::ASCII.GetString($Bytes)
    }
    try { $encoding.GetString($Bytes, $skip, $Bytes.Length - $skip) }
    catch { throw "it is no valid $name" }
}

# Return the HashtableAst of the PowerShell data text $Text, which must hold that one hashtable
# and nothing else: no param, begin or process block, no trap, no second statement and no
# redirection. Its values must be literals: text without $ expressions, numbers, $true, $false and
# $null, and arrays or hashtables of them, so not even a type conversion such as [int]'5' runs
# when the values are read. Parsing runs nothing. Throws the reason, with the line and the
# parser's error ID but nothing quoted from the text.
function Get-PvmDataFileHashtable {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.HashtableAst])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "line $($errors[0].Extent.StartLineNumber) is no valid PowerShell data ($($errors[0].ErrorId))" }
    $element = $null
    if ($null -ne $ast.EndBlock -and $ast.EndBlock.Statements.Count -eq 1 -and $null -eq $ast.EndBlock.Traps -and
        $ast.EndBlock.Statements[0] -is [System.Management.Automation.Language.PipelineAst] -and
        $ast.EndBlock.Statements[0].PipelineElements.Count -eq 1) {
        $element = $ast.EndBlock.Statements[0].PipelineElements[0]
    }
    if ($null -ne $ast.ParamBlock -or $null -ne $ast.DynamicParamBlock -or $null -ne $ast.BeginBlock -or $null -ne $ast.ProcessBlock -or
        $element -isnot [System.Management.Automation.Language.CommandExpressionAst] -or $element.Redirections.Count -gt 0 -or
        $element.Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
        throw 'it must hold one hashtable, @{ ... }, and nothing else'
    }
    $literals = 'HashtableAst', 'PipelineAst', 'CommandExpressionAst', 'ConstantExpressionAst', 'StringConstantExpressionAst',
    'ArrayLiteralAst', 'ArrayExpressionAst', 'StatementBlockAst', 'VariableExpressionAst'
    foreach ($node in $element.Expression.FindAll({ $true }, $true)) {
        $name = $node.GetType().Name
        if ($literals -notcontains $name -or
            ($name -eq 'VariableExpressionAst' -and @('true', 'false', 'null') -notcontains $node.VariablePath.UserPath)) {
            throw "line $($node.Extent.StartLineNumber) holds an expression; use plain text, numbers, `$true, `$false or `$null"
        }
    }
    $element.Expression
}

# Return the hashtable in the PowerShell data file $Path, read without running anything in it:
# decoded by ConvertFrom-PvmDataFileByte (-Legacy for a schema 1 file), parsed by
# Get-PvmDataFileHashtable, and turned into values only when each value is a constant: text, a
# number, $true, $false or $null, or an array or hashtable of them. Throws the reason, which
# quotes nothing from the file and names no path. When the file cannot be opened, the reason is the
# cause (Get-PvmErrorCause), and the message from Windows, which can quote the path, is in the
# exception's Data['PvmDetail'] for a tool that shows it on request.
function Import-PvmDataFile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Legacy
    )
    try { $bytes = [IO.File]::ReadAllBytes($Path) }
    catch {
        $reason = [System.Management.Automation.RuntimeException]::new((Get-PvmErrorCause -ErrorRecord $_))
        $reason.Data['PvmDetail'] = $_.Exception.Message
        throw $reason
    }
    $hashtable = Get-PvmDataFileHashtable -Text (ConvertFrom-PvmDataFileByte -Bytes $bytes -Legacy:$Legacy)
    try { $hashtable.SafeGetValue() }
    catch { throw 'a value is an expression; use plain text, numbers, $true, $false or $null' }
}

# Return the settings in the file $Path, LauncherData\settings.psd1, checked by Test-PvmSetting
# and with the defaults filled in (Merge-PvmSetting). Throws a stop that names every problem, or
# says why the file cannot be read; that stop keeps the Data['PvmDetail'] of Import-PvmDataFile.
function Import-PvmSetting {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    $name = 'LauncherData\settings.psd1'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (Get-PvmStopException -Message "$name is missing. Copy examples\settings.example.psd1 there and fill it in.")
    }
    try { $raw = Import-PvmDataFile -Path $Path }
    catch {
        $stop = Get-PvmStopException -Message "$name cannot be read: $($_.Exception.Message)."
        if ($_.Exception.Data['PvmDetail']) { $stop.Data['PvmDetail'] = $_.Exception.Data['PvmDetail'] }
        throw $stop
    }
    $problems = @(Test-PvmSetting -Settings $raw)
    if ($problems.Count -gt 0) {
        $noun = if ($problems.Count -eq 1) { 'problem' } else { 'problems' }
        throw (Get-PvmStopException -Message ("$name has $($problems.Count) ${noun}:`n" + (($problems | ForEach-Object { "- $_" }) -join "`n")))
    }
    Merge-PvmSetting -Settings $raw
}

# Return the schema 1 settings text $Text as schema 2: 'SchemaVersion = 2', and the names when
# $VmDisplayName or $GuestName is given, each on a line of its own right after the '@{' that
# opens the hashtable, with the text's own line ending. Every other character stays, comments
# too. Throws when $Text holds no single hashtable of plain values, or has SchemaVersion already.
function ConvertTo-PvmSchema2Text {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$VmDisplayName,
        [string]$GuestName
    )
    $hashtable = Get-PvmDataFileHashtable -Text $Text
    try { $values = $hashtable.SafeGetValue() }
    catch { throw 'a value is an expression; use plain text, numbers, $true, $false or $null' }
    if (@($values.Keys | Where-Object { "$_" -eq 'SchemaVersion' }).Count -gt 0) { throw 'it has SchemaVersion already' }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @('SchemaVersion = 2')
    if ($VmDisplayName) { $lines += "VmDisplayName = '$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($VmDisplayName))'" }
    if ($GuestName) { $lines += "GuestName = '$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($GuestName))'" }
    $block = ($lines | ForEach-Object { "    $_$newline" }) -join ''
    # After '@{' and, when the rest of that line is blank or a comment, after that line too.
    $at = $hashtable.Extent.StartOffset + 2
    if ($Text.Substring($at) -match '\A[ \t]*(#[^\r\n]*)?\r?\n') { $at += $Matches[0].Length }
    else { $block = $newline + $block }
    $Text.Substring(0, $at) + $block + $Text.Substring($at)
}

# --- Messages --------------------------------------------------------------------------------

# Return $Template with each {Token} filled in, in one pass, so that nothing filled in is read as
# a token again: {VM} and {vm} get the VM's display name, $Names.VM, {Guest} and {guest} the
# guest's name, $Names.Guest, and any other {Token} the value of that key in $Values. {VM} and
# {Guest} start a sentence, so the name's first letter is capitalised there. A token with no
# value stays as it is.
function Format-PvmMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Names,
        [hashtable]$Values = @{}
    )
    $message = New-Object System.Text.StringBuilder
    $done = 0
    foreach ($match in [regex]::Matches($Template, '\{(\w+)\}')) {
        $token = $match.Groups[1].Value
        $text = $null
        if ($token -ceq 'VM' -or $token -ceq 'vm') { $text = $Names['VM'] }
        elseif ($token -ceq 'Guest' -or $token -ceq 'guest') { $text = $Names['Guest'] }
        elseif ($Values.ContainsKey($token)) { $text = "$($Values[$token])" }
        if ($null -eq $text) { continue }
        if (($token -ceq 'VM' -or $token -ceq 'Guest') -and $text) { $text = $text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1) }
        [void]$message.Append($Template, $done, $match.Index - $done).Append($text)
        $done = $match.Index + $match.Length
    }
    [void]$message.Append($Template, $done, $Template.Length - $done)
    $message.ToString()
}

# Return the title of the launcher's dialogs for the settings $Settings: VmDisplayName when it is
# anything but the neutral default 'the VM', in any case, else 'Portable VM'.
function Get-PvmCaption {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Settings)
    $name = $Settings['VmDisplayName']
    if ($name -and $name -ne 'the VM') { $name } else { 'Portable VM' }
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

# --- Safe writes -----------------------------------------------------------------------------
# A VM file that a crash or a pulled stick leaves half-written opens in no hypervisor. So every
# file the launcher and the deploy tool write on the stick goes through Write-PvmFile: the new
# version is written beside the file, forced onto the disk and read back, and only then takes
# the file's place. The log, which is only appended to, stays apart (Write-PvmLog).

# Return whether the byte arrays $Left and $Right hold the same bytes.
function Test-PvmSameContent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Right
    )
    $Left.Length -eq $Right.Length -and [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

# Return the copies that a write of the file $Path keeps beside it while it runs: Temp, the new
# version, and Old, the version it replaces, during the swap.
function Get-PvmWriteCopyPath {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    [pscustomobject]@{ Temp = "$Path.pvm-tmp"; Old = "$Path.pvm-old" }
}

# Return the one step that sets right a write of the file $Path that did not finish, as when a
# crash or a pulled stick cut it off, which the copies left beside it show (Get-PvmWriteCopyPath),
# or '' when there are none. The step keeps the version from before that write: the file itself,
# or the old version beside it, which the write found unchanged. So it is right also when the new
# version did not read back from its place, and the next run makes its change again. $Current, for
# a copy below the backups, is that copy as it would be made of its file now: an old version that
# holds exactly that is from a copy put back after a failed rewrite, so the copy put back stays,
# also when its swap stopped between the two renames. An old version that cannot be read then
# gets a step that does not guess. Get-PvmLeftoverStep returns the same step as data.
function Get-PvmLeftoverProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyCollection()][byte[]]$Current
    )
    $step = Get-PvmLeftoverStep -Path $Path -Current $Current
    if ($step) { $step.Problem } else { '' }
}

# Return the step of Get-PvmLeftoverProblem for the file $Path as data, or $null when there is
# none: its Path; the Problem, the sentence that names the step; PutAside, which says what a Yes
# to it moves aside and what it keeps; and its Actions in the order that a fix takes them, each a
# Remove of one Path or a Rename of one Path To another. A fix cut off between two actions leaves
# a step of another kind, whose own actions finish it. A step without actions is one the launcher
# does not take by itself.
function Get-PvmLeftoverStep {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyCollection()][byte[]]$Current
    )
    $copies = Get-PvmWriteCopyPath -Path $Path
    $temp = [IO.File]::Exists($copies.Temp)
    $old = [IO.File]::Exists($copies.Old)
    if (-not $temp -and -not $old) { return $null }
    $name = [IO.Path]::GetFileName($Path)
    $repeats = $false
    if ($null -ne $Current -and $old) {
        try { $repeats = Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($copies.Old)) -Right $Current }
        catch {
            return (New-PvmLeftoverStep -Path $Path -Problem "A write of $Path did not finish, and $name.pvm-old beside it cannot be read. Close the program that holds it, then start again.")
        }
    }
    $removeTemp = @{ Do = 'Remove'; Path = $copies.Temp }
    $removeOld = @{ Do = 'Remove'; Path = $copies.Old }
    $whole = "$name stays as it is."
    $kind = if ([IO.File]::Exists($Path)) {
        # The old version goes first, so that a fix cut off after it leaves the new one alone.
        if ($temp -and $old) { @{ Step = "remove $name.pvm-tmp and $name.pvm-old; $name itself is whole"; PutAside = $whole; Actions = @($removeOld, $removeTemp) } }
        elseif ($temp) { @{ Step = "remove $name.pvm-tmp; $name itself is whole"; PutAside = $whole; Actions = @($removeTemp) } }
        elseif ($repeats) { @{ Step = "remove $name.pvm-old, which holds a copy of the file as it is now; $name itself is whole"; PutAside = $whole; Actions = @($removeOld) } }
        else {
            @{ Step = "remove $name, then rename $name.pvm-old back to $name, which holds the version before the write"
                PutAside = "A Yes puts aside $name as it is now, with all that was written to it since that write."
                Actions = @(@{ Do = 'Remove'; Path = $Path }, @{ Do = 'Rename'; Path = $copies.Old; To = $Path })
            }
        }
    } elseif ($old -and $temp) {
        # The new copy was read back before the swap began, so it is whole.
        if ($repeats) {
            $of = [IO.Path]::GetFileName($Path) -replace '\.(previous\.)?(orig|launcher-backup)\z', ''
            @{ Step = "rename $name.pvm-tmp to $name and remove $name.pvm-old, which holds a copy of the file as it is now"
                PutAside = "A Yes puts aside $name.pvm-old, which holds the same as a copy of $of made now."
                Actions = @(@{ Do = 'Rename'; Path = $copies.Temp; To = $Path }, $removeOld)
            }
        } else {
            @{ Step = "rename $name.pvm-old back to $name and remove $name.pvm-tmp"
                PutAside = "A Yes puts aside $name.pvm-tmp, the new version that was not in place yet."
                Actions = @(@{ Do = 'Rename'; Path = $copies.Old; To = $Path }, $removeTemp)
            }
        }
    } elseif ($old) {
        @{ Step = "rename $name.pvm-old back to $name"; PutAside = 'Nothing is put aside.'; Actions = @(@{ Do = 'Rename'; Path = $copies.Old; To = $Path }) }
    } else {
        @{ Step = "remove $name.pvm-tmp, which may be incomplete"; PutAside = "A Yes puts aside $name.pvm-tmp, which may be incomplete; $name stays missing."; Actions = @($removeTemp) }
    }
    New-PvmLeftoverStep -Path $Path -Problem "A write of $Path did not finish. To set it right, $($kind.Step)." -PutAside $kind.PutAside -Actions $kind.Actions
}

# Return a step of Get-PvmLeftoverStep: the file $Path, the sentence $Problem, what a Yes puts
# aside ($PutAside) and the $Actions, hashtables with Do, Path and, for a Rename, To.
function New-PvmLeftoverStep {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes nothing.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Problem,
        [string]$PutAside = '',
        [hashtable[]]$Actions = @()
    )
    [pscustomobject]@{
        Path     = $Path
        Problem  = $Problem
        PutAside = $PutAside
        Actions  = @($Actions | ForEach-Object { [pscustomobject]@{ Do = $_.Do; Path = $_.Path; To = "$($_['To'])" } })
    }
}

# Return the exception for a refusal of Write-PvmFile: $Message names no path, so that the deploy
# tool can show it as it is; $Detail, which may, goes to Data['PvmDetail'], and $Code to
# Data['PvmWrite'].
function Get-PvmWriteException {
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Detail
    )
    $exception = [System.Management.Automation.RuntimeException]::new($Message)
    $exception.Data['PvmWrite'] = $Code
    $exception.Data['PvmDetail'] = $Detail
    $exception
}

# Put the new version $Temp in place of the file $Path and keep the file as $Old: two renames on
# one volume that keep the file's attributes, access rights and creation time. Windows' error
# 1177 can stop it between the two, with the file under $Old and the new version still under
# $Temp; Write-PvmFile then keeps both for the step by hand. Tests mock this for the errors
# Windows documents.
function Switch-PvmFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Temp,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Old
    )
    [IO.File]::Replace($Temp, $Path, $Old)
}

# Remove the file $Path, a copy that the same write made beside the file it wrote. Tests mock this.
function Remove-PvmWriteCopy {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'Remove the copy that a safe write made')) { [IO.File]::Delete($Path) }
}

# Write the bytes $Bytes to the file $Path so that a crash or a pulled stick leaves its old or its
# new version, never a mix. Without -Expected it creates the file, which must not exist; with
# -Expected it replaces the file, which must still hold exactly those bytes, as when the caller
# read them. The bytes go to <Path>.pvm-tmp beside it, are forced onto the disk and read back,
# and then take the file's place; a replaced version stays as <Path>.pvm-old until the new one
# reads back from its place, and when it does not, both stay for the step by hand
# (Get-PvmLeftoverProblem). It removes only those two copies of its own. A refusal throws a
# message that names no path, with the details in Data['PvmDetail'] and one of these codes in
# Data['PvmWrite']: Leftover, Exists, Missing, NotAFile, ReadOnly, Link, Changed or ReadBack.
# Errors of Windows pass on as they are. Returns '', or the name of the old version when three
# tries a second apart could not remove it, at which the next write of the file stops.
function Write-PvmFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [AllowEmptyCollection()][byte[]]$Expected
    )
    $replace = $PSBoundParameters.ContainsKey('Expected')
    $copies = Get-PvmWriteCopyPath -Path $Path
    $leftover = Get-PvmLeftoverProblem -Path $Path
    if ($leftover) { throw (Get-PvmWriteException -Code 'Leftover' -Message 'An earlier write of the file did not finish, and its copy is still beside it.' -Detail $leftover) }
    if ($replace) {
        if ([IO.Directory]::Exists($Path)) { throw (Get-PvmWriteException -Code 'NotAFile' -Message 'A folder has the name of the file to rewrite.' -Detail "$Path is a folder.") }
        if (-not [IO.File]::Exists($Path)) { throw (Get-PvmWriteException -Code 'Missing' -Message 'The file to rewrite is missing.' -Detail "$Path is missing.") }
        $attributes = [IO.File]::GetAttributes($Path)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw (Get-PvmWriteException -Code 'Link' -Message 'The file to rewrite is a link.' -Detail "$Path is a link.") }
        if ($attributes -band [IO.FileAttributes]::ReadOnly) { throw (Get-PvmWriteException -Code 'ReadOnly' -Message 'The file to rewrite is read-only.' -Detail "$Path is read-only.") }
    } elseif ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        throw (Get-PvmWriteException -Code 'Exists' -Message 'An item has the name of the new file, and a new file never replaces one.' -Detail "$Path exists.")
    }
    try {
        # Beside the file, so on the same volume, and forced onto the disk before it is read back.
        $stream = [IO.FileStream]::new($copies.Temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if (-not (Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($copies.Temp)) -Right $Bytes)) {
            throw (Get-PvmWriteException -Code 'ReadBack' -Message 'The new version did not read back as written, so the file was left as it was.' -Detail "$($copies.Temp) did not read back as written.")
        }
        if ($replace -and -not (Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($Path)) -Right $Expected)) {
            throw (Get-PvmWriteException -Code 'Changed' -Message 'The file changed while it was being rewritten, so it was left as it was.' -Detail "$Path changed after it was read.")
        }
        if ($replace) { Switch-PvmFile -Temp $copies.Temp -Path $Path -Old $copies.Old }
        else { [IO.File]::Move($copies.Temp, $Path) }
    } catch {
        # Only this call's new copy goes, and only while the file or no old version is there:
        # when a failed swap left the file missing, both versions stay for the step by hand.
        if ([IO.File]::Exists($copies.Temp) -and ([IO.File]::Exists($Path) -or -not [IO.File]::Exists($copies.Old))) { Remove-PvmWriteCopy -Path $copies.Temp }
        throw
    }
    if (-not $replace) { return '' }
    # The new version is in place: force it, read it back, and only then remove the old one.
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
    if (-not (Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($Path)) -Right $Bytes)) {
        throw (Get-PvmWriteException -Code 'ReadBack' -Message 'The new version did not read back as written; the version before is still beside it.' -Detail (
                "$Path did not read back as written after it took the file's place. $(Get-PvmLeftoverProblem -Path $Path)"))
    }
    # A program that looks at the renamed old version, such as a virus scanner, can hold it for a
    # moment, so the removal gets three tries a second apart.
    for ($try = 1; $true; $try++) {
        try {
            Remove-PvmWriteCopy -Path $copies.Old
            return ''
        } catch {
            if ($try -ge 3) { return $copies.Old }
        }
        Invoke-PvmSleep -Seconds 1
    }
}

# --- Raw-disk descriptors --------------------------------------------------------------------

# Return what the VM gets of the raw disk $Drive, as the CreateType and the Extents lines of a
# descriptor, the same in VMware and VirtualBox: sectors 0 to VmSectors-1 of the stick, writable,
# with the Data partition, from sector DataPartitionStart on, blanked: the guest reads zeros there,
# and its writes there are dropped. The stick is named in one extent only, and no part of it is
# read-only: VirtualBox opens a device that two extents name once, with the first extent's access,
# so a read-only boot area in front made it refuse every write of the guest. The createType is
# 'fullDevice', which VMware needs for this layout: in 'partitionedDevice' mode it insists on its
# own partition-table copy and refuses the descriptor.
function Get-PvmDiskLayout {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Drive,
        [int64]$VmSectors,
        [int64]$DataPartitionStart
    )
    @{
        CreateType = 'fullDevice'
        Extents    = @(('RW {0} FLAT "{1}" 0' -f $DataPartitionStart, $Drive), ('RW {0} ZERO' -f ($VmSectors - $DataPartitionStart)))
    }
}

# Return the raw-disk layout (Get-PvmDiskLayout) for a start in either program on the raw disk
# $Drive, as $Context and its Settings describe. Each of the settings HideDataPartition and
# ProtectBootArea, which are no longer used, gets a note in the log when the file names it.
function Get-PvmStartLayout {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Drive
    )
    $settings = $Context.Settings
    if ($null -ne $settings['HideDataPartition']) {
        Write-PvmLog -Path $Context.LogPath -Message (Format-PvmMessage -Names $Context.Names -Template 'Note: HideDataPartition is no longer used: in VMware and in VirtualBox, {guest} sees the Data partition as zeros.')
    }
    if ($null -ne $settings['ProtectBootArea']) {
        Write-PvmLog -Path $Context.LogPath -Message (Format-PvmMessage -Names $Context.Names -Template "Note: ProtectBootArea is no longer used: in VMware and in VirtualBox, {guest} can write the stick's boot area, as before phase 8.")
    }
    Get-PvmDiskLayout -Drive $Drive -VmSectors $settings['VmSectors'] -DataPartitionStart $settings['DataPartitionStart']
}

# Return the descriptor bytes $Bytes as text with one character per byte (ISO-8859-1), so that a
# rewrite keeps every byte it does not change, whatever encoding the descriptor names. Throws a
# FormatException with the reason when the bytes are no descriptor text: 1 MiB or more, a sparse
# disk image (KDMV or COWD), UTF-16 or UTF-32 text, or a NUL byte.
function ConvertFrom-PvmDescriptorData {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Length -ge 1MB) { throw [FormatException]::new('it holds 1 MiB or more, which no descriptor does') }
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $magic = $latin1.GetString($Bytes, 0, [Math]::Min(4, $Bytes.Length))
    if ($magic -ceq 'KDMV' -or $magic -ceq 'COWD') { throw [FormatException]::new('it is a disk image, not a descriptor') }
    $utf16 = $Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))
    $utf32 = $Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF
    if ($utf16 -or $utf32) { throw [FormatException]::new('it is UTF-16 or UTF-32 text, not descriptor text') }
    if ([Array]::IndexOf($Bytes, [byte]0) -ge 0) { throw [FormatException]::new('it holds a NUL byte, which descriptor text never has') }
    $latin1.GetString($Bytes)
}

# Return the lines of the descriptor text $Text, each with Text, Ending (CR LF, LF or none at the
# end), Number and Kind: Blank, Comment, Key (with Key) or Extent (with Access, Sectors, Type,
# Target and Offset).
# A UTF-8 byte order mark before the first line stays in its Text. Throws a FormatException with
# the reason, which names the line, when the launcher does not understand the descriptor: a line
# of no known kind, an extent other than '<access> <sectors> FLAT "<raw disk>" <offset>' or
# '<access> <sectors> ZERO', extents apart from each other, createType set twice, or no extent. A
# raw disk is a Windows device path or a device below /dev (Test-PvmRawDeviceTarget).
function ConvertFrom-PvmDescriptorText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = New-Object System.Collections.Generic.List[object]
    $position = 0
    while ($position -lt $Text.Length) {
        $next = $Text.IndexOf("`n", $position)
        if ($next -lt 0) { $line = $Text.Substring($position); $ending = ''; $position = $Text.Length }
        else {
            $line = $Text.Substring($position, $next - $position)
            $ending = "`n"
            if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1); $ending = "`r`n" }
            $position = $next + 1
        }
        $lines.Add([pscustomobject]@{ Text = $line; Ending = $ending; Number = $lines.Count + 1; Kind = ''; Key = ''; Access = ''; Sectors = ''; Type = ''; Target = ''; Offset = '' })
    }
    $bom = [string]::new([char[]](0xEF, 0xBB, 0xBF))
    $extentPattern = '^[ \t]*(?<access>RW|RDONLY|NOACCESS)[ \t]+(?<sectors>\d+)[ \t]+(?<type>[A-Za-z]+)(?:[ \t]+"(?<target>[^"]*)"(?:[ \t]+(?<offset>\d+))?)?[ \t]*$'
    $extentEnded = $false
    $sawExtent = $false
    $createTypes = 0
    foreach ($entry in $lines) {
        $text = if ($entry.Number -eq 1 -and $entry.Text.StartsWith($bom)) { $entry.Text.Substring(3) } else { $entry.Text }
        $where = "line $($entry.Number)"
        if ($text -match '^[ \t]*$') { $entry.Kind = 'Blank' }
        elseif ($text -match '^[ \t]*#') { $entry.Kind = 'Comment' }
        elseif ($text -match '^[ \t]*(RW|RDONLY|NOACCESS)([ \t]|$)') {
            $match = [regex]::Match($text, $extentPattern, 'IgnoreCase')
            if (-not $match.Success) { throw [FormatException]::new("$where is an extent line the launcher cannot read") }
            $type = $match.Groups['type'].Value.ToUpperInvariant()
            $target = $match.Groups['target']
            if ($type -ne 'FLAT' -and $type -ne 'ZERO') { throw [FormatException]::new("$where has a $type extent, and the launcher rewrites only FLAT and ZERO extents") }
            if ($type -eq 'FLAT') {
                if (-not $target.Success) { throw [FormatException]::new("$where is an extent line the launcher cannot read") }
                if (-not $match.Groups['offset'].Success) { throw [FormatException]::new("$where has a FLAT extent without an offset") }
                if (-not (Test-PvmRawDeviceTarget -Target $target.Value)) { throw [FormatException]::new("$where has a FLAT extent that names a file, not a raw disk") }
            } elseif ($target.Success) {
                throw [FormatException]::new("$where has a ZERO extent that names a target")
            }
            if ($extentEnded) { throw [FormatException]::new("$where is an extent apart from the others") }
            $sawExtent = $true
            $entry.Kind = 'Extent'
            $entry.Access = $match.Groups['access'].Value.ToUpperInvariant()
            $entry.Sectors = $match.Groups['sectors'].Value
            $entry.Type = $type
            $entry.Target = $target.Value
            $entry.Offset = $match.Groups['offset'].Value
        } elseif ($text -match '^[ \t]*(?<key>[A-Za-z][A-Za-z0-9_.]*)[ \t]*=') {
            $entry.Kind = 'Key'
            $entry.Key = $Matches['key']
            if ($entry.Key -eq 'createType') {
                $createTypes++
                if ($createTypes -gt 1) { throw [FormatException]::new("$where sets createType a second time") }
            }
        } else {
            throw [FormatException]::new("$where is no descriptor line")
        }
        if ($entry.Kind -ne 'Extent' -and $sawExtent) { $extentEnded = $true }
    }
    if (-not $sawExtent) { throw [FormatException]::new('no disk extent found') }
    $lines
}

# Return the descriptor text $Text with its extents (ConvertFrom-PvmDescriptorText) replaced by
# the Extents of $Layout, where they were, and its createType set to $Layout.CreateType, or
# inserted after the last key line above the extents when it has none. Every other line keeps its
# text and its ending; new lines take the ending of the extents they replace. The result is read
# again and must hold exactly the new layout. Throws a FormatException with the reason when the
# launcher does not understand $Text.
function ConvertTo-PvmDescriptorText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][hashtable]$Layout
    )
    $lines = @(ConvertFrom-PvmDescriptorText -Text $Text)
    $extents = @($lines | Where-Object { $_.Kind -eq 'Extent' })
    $first = $lines.IndexOf($extents[0])
    $last = $lines.IndexOf($extents[-1])
    $dominant = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $ending = if ($extents[0].Ending) { $extents[0].Ending } else { $dominant }
    $createType = 'createType="' + $Layout.CreateType + '"'
    $hasCreateType = @($lines | Where-Object { $_.Kind -eq 'Key' -and $_.Key -eq 'createType' }).Count -gt 0
    $after = -1
    if (-not $hasCreateType) {
        for ($index = 0; $index -lt $first; $index++) { if ($lines[$index].Kind -eq 'Key') { $after = $index } }
    }
    $builder = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($index -eq $first) {
            if (-not $hasCreateType -and $after -lt 0) { $null = $builder.Append($createType).Append($ending) }
            for ($number = 0; $number -lt $Layout.Extents.Count; $number++) {
                $end = if ($number -eq $Layout.Extents.Count - 1) { $lines[$last].Ending } else { $ending }
                $null = $builder.Append($Layout.Extents[$number]).Append($end)
            }
            $index = $last
            continue
        }
        if ($line.Kind -eq 'Key' -and $line.Key -eq 'createType') { $null = $builder.Append($createType).Append($line.Ending) }
        else { $null = $builder.Append($line.Text).Append($line.Ending) }
        if ($index -eq $after) { $null = $builder.Append($createType).Append($line.Ending) }
    }
    $result = $builder.ToString()
    # The rewrite must read back as the new layout, or it would write a broken descriptor.
    $check = @(ConvertFrom-PvmDescriptorText -Text $result)
    $written = @($check | Where-Object { $_.Kind -eq 'Extent' } | ForEach-Object { $_.Text.Trim() })
    $types = @($check | Where-Object { $_.Kind -eq 'Key' -and $_.Key -eq 'createType' } | ForEach-Object { $_.Text.Trim() })
    if (($written -join "`n") -cne (@($Layout.Extents) -join "`n") -or ($types -join "`n") -cne $createType) {
        throw [FormatException]::new('the rewritten descriptor did not read back as the new layout')
    }
    $result
}

# Return whether rewriting the descriptor text $Old as $New would change nothing that matters: case
# does not count, nor do blanks at the end of an extent or createType line, which VMware adds when
# it writes the file. Throws a FormatException when the launcher does not understand either text.
function Test-PvmSameDescriptorText {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Old,
        [Parameter(Mandatory)][AllowEmptyString()][string]$New
    )
    $blanks = [char[]]@(' ', "`t")
    $texts = foreach ($text in $Old, $New) {
        $builder = New-Object System.Text.StringBuilder
        foreach ($line in ConvertFrom-PvmDescriptorText -Text $text) {
            $rewritten = $line.Kind -eq 'Extent' -or ($line.Kind -eq 'Key' -and $line.Key -eq 'createType')
            $value = if ($rewritten) { $line.Text.TrimEnd($blanks) } else { $line.Text }
            $null = $builder.Append($value).Append($line.Ending)
        }
        $builder.ToString()
    }
    $texts[0] -eq $texts[1]
}

# Return why the descriptor text $New differs from $Old, as kinds that name no value, in this
# order: the disk device, a size, a start offset, the access mode, the extent type (for an extent
# whose type changes, its device and offset are not compared), the number of extents, no createType
# line, the createType line, and other line content when none of these explains the difference.
# Returns nothing when the two count as the same (Test-PvmSameDescriptorText). Throws a
# FormatException when the launcher does not understand either text.
function Get-PvmDescriptorDifference {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Old,
        [Parameter(Mandatory)][AllowEmptyString()][string]$New
    )
    if (Test-PvmSameDescriptorText -Old $Old -New $New) { return }
    $oldLines = @(ConvertFrom-PvmDescriptorText -Text $Old)
    $newLines = @(ConvertFrom-PvmDescriptorText -Text $New)
    $oldExtents = @($oldLines | Where-Object { $_.Kind -eq 'Extent' })
    $newExtents = @($newLines | Where-Object { $_.Kind -eq 'Extent' })
    $found = @{}
    for ($index = 0; $index -lt [Math]::Min($oldExtents.Count, $newExtents.Count); $index++) {
        $before = $oldExtents[$index]
        $after = $newExtents[$index]
        # Numbers compare by value, so leading zeros alone are other line content.
        if ([int64]$before.Sectors -ne [int64]$after.Sectors) { $found['a size'] = $true }
        if ($before.Access -ne $after.Access) { $found['the access mode'] = $true }
        if ($before.Type -ne $after.Type) { $found['the extent type'] = $true; continue }
        if ($before.Target -ne $after.Target) { $found['the disk device'] = $true }
        if ($before.Offset -ne $after.Offset -and -not ($before.Offset -and $after.Offset -and [int64]$before.Offset -eq [int64]$after.Offset)) { $found['a start offset'] = $true }
    }
    if ($oldExtents.Count -ne $newExtents.Count) { $found['the number of extents'] = $true }
    $blanks = [char[]]@(' ', "`t")
    $oldType = @($oldLines | Where-Object { $_.Kind -eq 'Key' -and $_.Key -eq 'createType' })
    $newType = @($newLines | Where-Object { $_.Kind -eq 'Key' -and $_.Key -eq 'createType' })
    if ($oldType.Count -eq 0 -and $newType.Count -gt 0) { $found['no createType line'] = $true }
    elseif ($oldType.Count -gt 0 -and $newType.Count -gt 0 -and $oldType[0].Text.Trim($blanks) -ne $newType[0].Text.Trim($blanks)) { $found['the createType line'] = $true }
    $order = @('the disk device', 'a size', 'a start offset', 'the access mode', 'the extent type', 'the number of extents', 'no createType line', 'the createType line')
    $kinds = @($order | Where-Object { $found.ContainsKey($_) })
    if ($kinds.Count -eq 0) { return 'other line content' }
    $kinds
}

# Return the kinds $Kinds (Get-PvmDescriptorDifference) as the end of a sentence after "because":
# "the disk device and the createType line differ", or "the createType line is missing".
function Format-PvmDescriptorReason {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Kinds)
    $subjects = @($Kinds | Where-Object { $_ -ne 'no createType line' })
    $differ = switch ($subjects.Count) {
        0 { '' }
        1 { "$($subjects[0]) differs" }
        default { "$(($subjects[0..($subjects.Count - 2)]) -join ', ') and $($subjects[-1]) differ" }
    }
    if ($Kinds -notcontains 'no createType line') { return $differ }
    if ($differ) { return "$differ, and the createType line is missing" }
    'the createType line is missing'
}

# Return the text of a new VMware descriptor for $Layout: a header, the Extents of $Layout and a
# disk database for an IDE disk of virtual hardware version 20, with CRLF line endings.
function Get-PvmVMwareDescriptorText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Layout,
        [ValidateSet('ide', 'buslogic', 'lsilogic')][string]$AdapterType = 'ide'
    )
    $lines = @('# Disk DescriptorFile', 'version=1', 'encoding="windows-1252"', 'CID=fffffffe', 'parentCID=ffffffff',
        ('createType="{0}"' -f $Layout.CreateType), '', '# Extent description') +
    $Layout.Extents +
    @('', '# The Disk Data Base', '#DDB', '', ('ddb.adapterType = "{0}"' -f $AdapterType), 'ddb.geometry.cylinders = "16383"',
        'ddb.geometry.heads = "16"', 'ddb.geometry.sectors = "63"', 'ddb.virtualHWVersion = "20"', '')
    $lines -join "`r`n"
}

# Return whether the FLAT extent target $Target names a raw device, as a descriptor of a raw disk
# does: a Windows device path, which starts with \\.\ or \\?\, or a device below /dev on Linux,
# such as /dev/sdb. Such a path names a file when a drive letter and a \ or UNC\ follow, as in
# \\?\C:\disk.img. A /dev path counts only when every name after /dev/ is there, is not . or ..
# and holds no \, so that no spelling of it leads out of /dev. Any other target names a file.
function Test-PvmRawDeviceTarget {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Target)
    if ($Target -match '\A\\\\[.?]\\') { return ($Target -notmatch '\A\\\\[.?]\\(?:[A-Za-z]:\\|UNC\\)') }
    if (-not $Target.StartsWith('/dev/', [StringComparison]::Ordinal)) { return $false }
    $names = $Target.Substring(5).Split('/')
    @($names | Where-Object { -not $_ -or $_ -eq '.' -or $_ -eq '..' -or $_.Contains('\') }).Count -eq 0
}

# Return the device that a disarmed descriptor copy names instead of the raw device $Target, in
# its spelling: /dev/PortableVM-disarmed for a device below /dev, else \\.\PortableVM-disarmed. No
# disk has this name, so a hypervisor that opens such a copy by mistake finds no disk, rather than
# whatever disk has the copy's old device now.
function Get-PvmDisarmedDevice {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Target)
    if ($Target.StartsWith('/')) { return '/dev/PortableVM-disarmed' }
    '\\.\PortableVM-disarmed'
}

# Return the descriptor text $Text with the target of every FLAT extent that names a raw device
# (Test-PvmRawDeviceTarget) set to the disarmed device in its spelling (Get-PvmDisarmedDevice), so
# a Windows descriptor stays a Windows one. Every other character stays, so a second pass changes
# nothing, and ConvertTo-PvmDescriptorText arms such a copy again.
function ConvertTo-PvmDisarmedDescriptorText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [regex]::Replace($Text, '(?im)^([ \t]*(?:RW|RDONLY|NOACCESS)[ \t]+\d+[ \t]+FLAT[ \t]+")([^"\r\n]*)(")', {
            param($match)
            $target = $match.Groups[2].Value
            if (-not (Test-PvmRawDeviceTarget -Target $target)) { return $match.Value }
            $device = Get-PvmDisarmedDevice -Target $target
            if ($target -eq $device) { $match.Value }
            else { $match.Groups[1].Value + $device + $match.Groups[3].Value }
        })
}

# Keep the bytes $Bytes, the first version of a file the launcher rewrites, at $BackupPath
# through a safe write (Write-PvmFile), creating its folder. A copy that is there already is
# never replaced. With -Disarm the bytes are a descriptor's, and the copy names the disarmed
# device (ConvertTo-PvmDisarmedDescriptorText); ISO-8859-1 maps each byte to one character and
# back, so only the device names change.
function Save-PvmFirstCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$BackupPath,
        [switch]$Disarm
    )
    if ([IO.File]::Exists($BackupPath)) { return }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($BackupPath))
    [byte[]]$copy = $Bytes
    if ($Disarm) {
        $latin1 = [Text.Encoding]::GetEncoding(28591)
        $copy = $latin1.GetBytes((ConvertTo-PvmDisarmedDescriptorText -Text $latin1.GetString($Bytes)))
    }
    $null = Write-PvmFile -Path $BackupPath -Bytes $copy
}

# Keep the bytes $Bytes, the version of a file before the launcher rewrites it, at $BackupPath
# through a safe write, creating its folder; the copy of an earlier rewrite there is replaced, so
# that the version before the latest rewrite is one copy away. A copy that holds those bytes
# already stays as it is. With -Disarm the bytes are a descriptor's, and the copy names the
# disarmed device. When it replaced a copy, it returns the bytes it replaced (Replaced) and wrote
# (Written), with which Restore-PvmPreviousCopy puts that copy back if the rewrite then fails. A
# version before of the copy that cannot be removed throws a Leftover refusal.
function Save-PvmPreviousCopy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$BackupPath,
        [switch]$Disarm
    )
    [byte[]]$copy = $Bytes
    if ($Disarm) {
        $latin1 = [Text.Encoding]::GetEncoding(28591)
        $copy = $latin1.GetBytes((ConvertTo-PvmDisarmedDescriptorText -Text $latin1.GetString($Bytes)))
    }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($BackupPath))
    if ([IO.File]::Exists($BackupPath)) {
        $current = [IO.File]::ReadAllBytes($BackupPath)
        if (Test-PvmSameContent -Left $current -Right $copy) { return }
        $left = Write-PvmFile -Path $BackupPath -Bytes $copy -Expected $current
        if ($left) {
            # The file is not rewritten then, so the step that puts the copy before back is right.
            throw (Get-PvmWriteException -Code 'Leftover' -Message 'The copy was written, but its version before could not be removed from beside it.' -Detail (Get-PvmLeftoverProblem -Path $BackupPath))
        }
        [pscustomobject]@{ Replaced = $current; Written = $copy }
    } else {
        $null = Write-PvmFile -Path $BackupPath -Bytes $copy
    }
}

# Put back the copy at $BackupPath that Save-PvmPreviousCopy replaced for a rewrite that then
# failed ($Previous, with the bytes it replaced and wrote), so that the copy still holds the
# version before the latest rewrite that took place. A failure only goes to the log at $LogPath,
# beside the stop for the failed rewrite.
function Restore-PvmPreviousCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Previous,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    try {
        $left = Write-PvmFile -Path $BackupPath -Bytes $Previous.Replaced -Expected $Previous.Written
        if ($left) { Write-PvmLog -Path $LogPath -Message "Note: $left could not be removed after the copy was put back; the next start stops at it and names the step to take." }
    } catch {
        Write-PvmLog -Path $LogPath -Message "Note: $BackupPath could not be put back as it was before the failed rewrite, because $(Get-PvmWriteCause -ErrorRecord $_ -Path $BackupPath)."
    }
}

# Throw a stop when a write of one of the files $Paths did not finish (Get-PvmLeftoverProblem),
# with the one step to take, before the launcher changes any file.
function Assert-PvmNoLeftover {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Paths)
    foreach ($path in $Paths) {
        $problem = Get-PvmLeftoverProblem -Path $path
        if ($problem) { throw (Get-PvmStopException -Message "$problem Nothing was started.") }
    }
}

# Return what a copy of the file $Path made now would hold, as Save-PvmPreviousCopy makes it
# (disarmed with -Disarm), for Get-PvmLeftoverProblem -Current: the Bytes, or a Reason why there
# are none: Missing, Folder (a folder has the name) or Unreadable. A descriptor of 1 MiB or more,
# which the launcher refuses, is not read and gets an empty copy.
function Get-PvmCopyNow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Disarm
    )
    [byte[]]$bytes = @()
    try {
        if ([IO.Directory]::Exists($Path)) { return [pscustomobject]@{ Reason = 'Folder'; Bytes = $bytes } }
        $file = [IO.FileInfo]::new($Path)
        if (-not $file.Exists) { return [pscustomobject]@{ Reason = 'Missing'; Bytes = $bytes } }
        if ($Disarm -and $file.Length -ge 1MB) { return [pscustomobject]@{ Reason = ''; Bytes = $bytes } }
        $bytes = [IO.File]::ReadAllBytes($Path)
    } catch {
        return [pscustomobject]@{ Reason = 'Unreadable'; Bytes = [byte[]]@() }
    }
    if ($Disarm) {
        $latin1 = [Text.Encoding]::GetEncoding(28591)
        $bytes = $latin1.GetBytes((ConvertTo-PvmDisarmedDescriptorText -Text $latin1.GetString($bytes)))
    }
    [pscustomobject]@{ Reason = ''; Bytes = $bytes }
}

# Return the step for a write that did not finish of the copy $Path of the file $Of below the
# backups (Get-PvmLeftoverProblem, with the copy that would be made of $Of now, disarmed with
# -Disarm), or '' when there is none. $Of is read only where it decides the step: an old version
# beside the copy, with the copy there and no new one, or the other way round. When it is
# missing, a folder or cannot be read then, the step asks for the file rather than guess which
# version of the copy to keep.
function Get-PvmCopyLeftoverProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Of,
        [switch]$Disarm
    )
    $step = Get-PvmCopyLeftoverStep -Path $Path -Of $Of -Disarm:$Disarm
    if ($step) { $step.Problem } else { '' }
}

# Return the step of Get-PvmCopyLeftoverProblem as data, as Get-PvmLeftoverStep does, or $null.
# Where the launcher cannot tell which version of the copy to keep, the step has no actions.
function Get-PvmCopyLeftoverStep {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Of,
        [switch]$Disarm
    )
    $copies = Get-PvmWriteCopyPath -Path $Path
    if (-not [IO.File]::Exists($copies.Old) -or [IO.File]::Exists($Path) -eq [IO.File]::Exists($copies.Temp)) { return (Get-PvmLeftoverStep -Path $Path) }
    $now = Get-PvmCopyNow -Path $Of -Disarm:$Disarm
    $problem = switch ($now.Reason) {
        'Missing' {
            "A write of $Path did not finish, and $Of, which it is a copy of, is missing, so the launcher cannot tell which version of the copy to keep. " +
            "Put $Of back, for example from its copies below LauncherData\backups, then start again."
        }
        'Folder' {
            "A write of $Path did not finish, and a folder has the name of $Of, which it is a copy of, so the launcher cannot tell which version of the copy " +
            "to keep. Move that folder away and put $Of back, then start again."
        }
        'Unreadable' {
            "A write of $Path did not finish, and the launcher cannot read $Of to tell which version of the copy to keep. " +
            "Make $Of readable again, for example by closing the program that holds it, then start again."
        }
    }
    if ($problem) { return (New-PvmLeftoverStep -Path $Path -Problem $problem) }
    Get-PvmLeftoverStep -Path $Path -Current $now.Bytes
}

# Throw a stop when the file $Path is read-only or a link, which the launcher does not rewrite.
function Assert-PvmRewritable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $attributes = [IO.File]::GetAttributes($Path)
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw (Get-PvmStopException -Message "$Path is a link, so the launcher does not rewrite it. Put the file itself in its place, then start again. Nothing was started.")
    }
    if ($attributes -band [IO.FileAttributes]::ReadOnly) {
        throw (Get-PvmStopException -Message "$Path is read-only, so the launcher does not rewrite it. Clear that attribute, then start again. Nothing was started.")
    }
}

# Return the cause of the failed safe write of the file $Path in $ErrorRecord as it reads after
# "because": the reason for a refusal of Write-PvmFile, else Get-PvmPathCause's words.
function Get-PvmWriteCause {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][string]$Path
    )
    switch ("$($ErrorRecord.Exception.Data['PvmWrite'])") {
        'Leftover' { return 'an earlier write of it did not finish' }
        'Exists' { return 'an item of that name is in the way' }
        'Missing' { return 'it is missing' }
        'NotAFile' { return 'a folder has its name' }
        'ReadOnly' { return 'it is read-only' }
        'Link' { return 'it is a link' }
        'Changed' { return 'another program changed it after the launcher read it' }
        'ReadBack' { return 'the new version did not read back as written' }
    }
    Format-PvmBecause -Cause (Get-PvmPathCause -Path $Path -ErrorRecord $ErrorRecord)
}

# Return whether the error $ErrorRecord comes from a safe write: a refusal of Write-PvmFile, or a
# file error of Windows. Any other error is unexpected and passes on as it is.
function Test-PvmWriteError {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    if ($ErrorRecord.Exception.Data['PvmWrite']) { return $true }
    $exception = $ErrorRecord.Exception
    while ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) { $exception = $exception.InnerException }
    $exception -is [IO.IOException] -or $exception -is [UnauthorizedAccessException]
}

# Return the stop for the failed safe write in $ErrorRecord: the Format-PvmMessage template
# $Template, with {Cause} filled in by Get-PvmWriteCause for the file $Path and its other tokens
# by $Values, in one pass, so that a brace in a path is never read as a token. The system's
# message stays for the log.
function Get-PvmWriteStop {
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Template,
        [hashtable]$Values = @{}
    )
    $filled = @{ Cause = (Get-PvmWriteCause -ErrorRecord $ErrorRecord -Path $Path) }
    foreach ($key in $Values.Keys) { $filled[$key] = $Values[$key] }
    $exception = Get-PvmStopException -Message (Format-PvmMessage -Template $Template -Names @{ VM = $null; Guest = $null } -Values $filled)
    $detail = $ErrorRecord.Exception.Data['PvmDetail']
    $exception.Data['PvmDetail'] = if ($detail) { "$detail" } else { Get-PvmErrorText -ErrorRecord $ErrorRecord }
    $exception
}

# Prepare pointing the existing descriptor $Path at the stick: its extents and createType become
# those of $Layout (ConvertTo-PvmDescriptorText), every other byte stays, and today's line goes to
# $LogPath. Stops, before any file changes, at a cut-off write of it or of its copies $BackupPath
# and $PreviousPath, at a descriptor the launcher does not understand, and at one it may not
# rewrite. Returns the change for Save-PvmFileChange, or $null when it points at the stick already.
function Get-PvmDescriptorChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Layout,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$PreviousPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    Assert-PvmNoLeftover -Paths $Path, $BackupPath
    $problem = Get-PvmCopyLeftoverProblem -Path $PreviousPath -Of $Path -Disarm
    if ($problem) { throw (Get-PvmStopException -Message "$problem Nothing was started.") }
    $bytes = [IO.File]::ReadAllBytes($Path)
    try {
        $text = ConvertFrom-PvmDescriptorData -Bytes $bytes
        $new = ConvertTo-PvmDescriptorText -Text $text -Layout $Layout
        $same = Test-PvmSameDescriptorText -Old $text -New $new
    } catch [FormatException] {
        throw (Get-PvmStopException -Message "Unexpected content in $Path - $($_.Exception.Message). Nothing was started.")
    }
    $name = [IO.Path]::GetFileName($Path)
    if ($same) {
        Write-PvmLog -Path $LogPath -Message "$name already points at the stick"
        return $null
    }
    Write-PvmLog -Path $LogPath -Message "$name -> $($Layout.Extents -join ' | ')"
    # The reason names kinds only, so the log holds no more of the stick than the line above.
    Write-PvmLog -Path $LogPath -Message "${name}: rewritten because $(Format-PvmDescriptorReason -Kinds @(Get-PvmDescriptorDifference -Old $text -New $new))"
    Assert-PvmRewritable -Path $Path
    if ([IO.File]::Exists($PreviousPath)) { Assert-PvmRewritable -Path $PreviousPath }
    [pscustomobject]@{
        Path           = $Path
        Old            = $bytes
        New            = [Text.Encoding]::GetEncoding(28591).GetBytes($new)
        FirstBackup    = $BackupPath
        PreviousBackup = $PreviousPath
        Disarm         = $true
        Action         = 'Point the raw-disk descriptor at the stick'
    }
}

# Write the change $Change (Get-PvmDescriptorChange, Get-PvmDriveLetterChange) through safe
# writes, unless -WhatIf: first the copies of the version before it (Save-PvmFirstCopy, which
# keeps the first version, and Save-PvmPreviousCopy), then the file itself, which must still hold
# the bytes read. A failed write stops the launcher, naming the file or the copy and the cause,
# or the step that sets a write right that did not finish, and puts back the copy of the version
# before the latest rewrite. So does an old version of the file that cannot be removed: the VM
# must not start and write the file while the step would put that version back.
function Save-PvmFileChange {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Change,
        [Parameter(Mandatory)][string]$LogPath
    )
    if (-not $PSCmdlet.ShouldProcess($Change.Path, $Change.Action)) { return }
    $values = @{ Path = $Change.Path }
    $copy = $Change.FirstBackup
    try {
        Save-PvmFirstCopy -Bytes $Change.Old -BackupPath $Change.FirstBackup -Disarm:$Change.Disarm
        $copy = $Change.PreviousBackup
        $previous = Save-PvmPreviousCopy -Bytes $Change.Old -BackupPath $Change.PreviousBackup -Disarm:$Change.Disarm
    } catch {
        if (-not (Test-PvmWriteError -ErrorRecord $_)) { throw }
        $leftover = Get-PvmLeftoverProblem -Path $copy
        if ($leftover) { throw (Get-PvmWriteStop -ErrorRecord $_ -Path $copy -Template '{Leftover} Nothing was started.' -Values @{ Leftover = $leftover }) }
        throw (Get-PvmWriteStop -ErrorRecord $_ -Path $copy -Values @{ Copy = $copy; Path = $Change.Path } -Template (
                'The launcher could not write the copy {Copy}, because {Cause}, so it did not rewrite {Path}. Nothing was started.'))
    }
    try {
        $left = Write-PvmFile -Path $Change.Path -Bytes $Change.New -Expected $Change.Old
    } catch {
        if (-not (Test-PvmWriteError -ErrorRecord $_)) { throw }
        $failure = $_
        # No rewrite took place, so the copy of the version before the latest one goes back.
        if ($previous) { Restore-PvmPreviousCopy -Previous $previous -BackupPath $Change.PreviousBackup -LogPath $LogPath }
        $leftover = Get-PvmLeftoverProblem -Path $Change.Path
        if ($leftover) { throw (Get-PvmWriteStop -ErrorRecord $failure -Path $Change.Path -Template '{Leftover} Nothing was started.' -Values @{ Leftover = $leftover }) }
        # A refusal of Write-PvmFile comes before the swap, so the file is as the launcher found it.
        $code = "$($failure.Exception.Data['PvmWrite'])"
        # A file that cannot be read now counts as changed, so the stop still forms.
        try { $unchanged = [IO.File]::Exists($Change.Path) -and (Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($Change.Path)) -Right $Change.Old) }
        catch { $unchanged = $false }
        $values.State = if ($code -eq 'Changed') { 'the launcher left it as that program wrote it. Close that program, then start again' }
        elseif ($code) { 'the launcher left it as it is' }
        elseif ($unchanged) { 'the file is unchanged' }
        else { 'check the file against its copies below LauncherData\backups' }
        throw (Get-PvmWriteStop -ErrorRecord $failure -Path $Change.Path -Values $values -Template 'The launcher could not rewrite {Path}, because {Cause}; {State}. Nothing was started.')
    }
    if ($left) {
        # The step puts the version before back, so that copy goes back as it was too.
        if ($previous) { Restore-PvmPreviousCopy -Previous $previous -BackupPath $Change.PreviousBackup -LogPath $LogPath }
        $problem = Get-PvmLeftoverProblem -Path $Change.Path
        # Both files are gone when the stick went away meanwhile.
        if (-not $problem) { $problem = "The launcher could not remove $left after it rewrote $($Change.Path). Check both, then start again." }
        throw (Get-PvmStopException -Message "$problem Nothing was started.")
    }
}

# Point the existing descriptor $Path at the stick (Get-PvmDescriptorChange, then
# Save-PvmFileChange), keeping its first version at $BackupPath and the version before the latest
# rewrite at $PreviousPath, both disarmed, and logging to $LogPath.
function Set-PvmDiskDescriptor {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Layout,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$PreviousPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    $change = Get-PvmDescriptorChange -Path $Path -Layout $Layout -BackupPath $BackupPath -PreviousPath $PreviousPath -LogPath $LogPath
    if ($null -ne $change) { Save-PvmFileChange -Change $change -LogPath $LogPath }
}

# Create the VMware descriptor $Path for $Layout (Get-PvmVMwareDescriptorText) as ASCII through a
# safe write, and log it to $LogPath. Stops at a write of it that did not finish, which also
# shows when the descriptor is missing because a rewrite was cut off, and, a dry run too, when
# its folder is missing.
function New-PvmVMwareDescriptor {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Layout,
        [Parameter(Mandatory)][string]$LogPath,
        [ValidateSet('ide', 'buslogic', 'lsilogic')][string]$AdapterType = 'ide'
    )
    Assert-PvmNoLeftover -Paths $Path
    Write-PvmLog -Path $LogPath -Message "Creating $(Split-Path $Path -Leaf) -> $($Layout.Extents -join ' | ')"
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($Path))) {
        throw (Get-PvmStopException -Message "The launcher could not create $Path, because its folder is missing. Nothing was started.")
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create the raw-disk descriptor')) { return }
    try {
        $null = Write-PvmFile -Path $Path -Bytes ([Text.Encoding]::ASCII.GetBytes((Get-PvmVMwareDescriptorText -Layout $Layout -AdapterType $AdapterType)))
    } catch {
        if (-not (Test-PvmWriteError -ErrorRecord $_)) { throw }
        throw (Get-PvmWriteStop -ErrorRecord $_ -Path $Path -Values @{ Path = $Path } -Template 'The launcher could not create {Path}, because {Cause}. Nothing was started.')
    }
}

# --- Drive letters ---------------------------------------------------------------------------
# VirtualBox stores some paths on the stick with a drive letter, such as the VM's entry in
# VirtualBox.xml, and the stick's letter differs between PCs.

# Return $Text with the drive letter of each quoted path on the stick set to $Letter. When the
# stick folder $Root lies below a drive root, those are the paths below it. When $Root is a drive
# root, they are the paths on the letters that the quoted paths to the stick's own files $Known
# show in $Text, so a path on another drive never moves, and with no such path nothing moves.
# Folders match in any case, \ and / both count, an & matches only as XML writes it (&amp;), and
# only the letter changes, so the rest of each path stays as written.
function ConvertTo-PvmDriveLetterText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Letter,
        [string[]]$Known = @()
    )
    $separator = '[\\/]'
    $options = [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
    $quotedLetter = '"' + $Letter
    $evaluator = [Text.RegularExpressions.MatchEvaluator] { param($match) $quotedLetter + $match.Value.Substring(2) }
    $below = if ($Root.Length -gt 3) { $Root.Substring(3) } else { '' }
    $folders = @($below.Split([char[]]'\/', [StringSplitOptions]::RemoveEmptyEntries))
    # VirtualBox's files are XML, which always writes an & as &amp;.
    if ($folders.Count) {
        $pattern = '"[A-Za-z]:' + (($folders | ForEach-Object { $separator + [regex]::Escape($_.Replace('&', '&amp;')) }) -join '') + $separator
        return [regex]::Replace($Text, $pattern, $evaluator, $options)
    }
    $letters = @(foreach ($file in $Known) {
            $parts = @($file.Substring([Math]::Min(3, $file.Length)).Split([char[]]'\/', [StringSplitOptions]::RemoveEmptyEntries))
            if (-not $parts.Count) { continue }
            $pattern = '"(?<letter>[A-Za-z]):' + (($parts | ForEach-Object { $separator + [regex]::Escape($_.Replace('&', '&amp;')) }) -join '') + '"'
            foreach ($match in [regex]::Matches($Text, $pattern, $options)) { $match.Groups['letter'].Value.ToUpperInvariant() }
        }) | Sort-Object -Unique
    if (-not @($letters).Count) { return $Text }
    [regex]::Replace($Text, '"[' + (@($letters) -join '') + ']:' + $separator, $evaluator, $options)
}

# Return whether the text $New differs from $Old only in drive letters: the same length, and at
# each place where they differ a letter right after a double quote and before a colon. A rewrite
# that would change more is refused.
function Test-PvmLetterChangeOnly {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Old,
        [Parameter(Mandatory)][AllowEmptyString()][string]$New
    )
    if ($Old.Length -ne $New.Length) { return $false }
    for ($index = 0; $index -lt $Old.Length; $index++) {
        if ($Old[$index] -ceq $New[$index]) { continue }
        $letters = [char]::IsLetter($Old[$index]) -and [char]::IsLetter($New[$index]) -and [int]$Old[$index] -lt 128 -and [int]$New[$index] -lt 128
        if (-not $letters -or $index -eq 0 -or $index + 1 -ge $Old.Length -or $Old[$index - 1] -ne '"' -or $Old[$index + 1] -ne ':') { return $false }
    }
    $true
}

# Prepare setting the stick's drive letter $Letter in the paths on the stick in the VirtualBox
# file $Path (ConvertTo-PvmDriveLetterText with $Root and $Known), and log to $LogPath whether
# anything changes. The file is read as strict UTF-8, as VirtualBox writes it, and every byte but
# the letters stays, a byte order mark too. Stops, before any file changes, at a cut-off write of
# it or of its copies $BackupPath and $PreviousPath, at a file that is not UTF-8, at a change that
# would be more than drive letters, and at a file it may not rewrite. Returns the change for
# Save-PvmFileChange, or $null when the letters fit already.
function Get-PvmDriveLetterChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Letter,
        [string[]]$Known = @(),
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$PreviousPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    Assert-PvmNoLeftover -Paths $Path, $BackupPath
    $problem = Get-PvmCopyLeftoverProblem -Path $PreviousPath -Of $Path
    if ($problem) { throw (Get-PvmStopException -Message "$problem Nothing was started.") }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $strict = New-Object System.Text.UTF8Encoding $false, $true
    try { $text = $strict.GetString($bytes) }
    catch { throw (Get-PvmStopException -Message "$Path is not UTF-8 text, as VirtualBox writes it, so the launcher does not change its drive letters. Nothing was started.") }
    $new = ConvertTo-PvmDriveLetterText -Text $text -Root $Root -Letter $Letter -Known $Known
    $name = [IO.Path]::GetFileName($Path)
    # -eq ignores case, as before the redesign, so a letter that differs only in case stays.
    if ($new -eq $text) {
        Write-PvmLog -Path $LogPath -Message "${name}: drive letter OK"
        return $null
    }
    Write-PvmLog -Path $LogPath -Message "${name}: paths moved to drive ${Letter}:"
    if (-not (Test-PvmLetterChangeOnly -Old $text -New $new)) {
        throw (Get-PvmStopException -Message "The launcher would change more than drive letters in $Path, so it leaves the file as it is. Nothing was started.")
    }
    Assert-PvmRewritable -Path $Path
    if ([IO.File]::Exists($PreviousPath)) { Assert-PvmRewritable -Path $PreviousPath }
    [pscustomobject]@{
        Path           = $Path
        Old            = $bytes
        New            = $strict.GetBytes($new)
        FirstBackup    = $BackupPath
        PreviousBackup = $PreviousPath
        Disarm         = $false
        Action         = "Move the stick's paths to drive ${Letter}:"
    }
}

# Set the stick's drive letter $Letter in the VirtualBox file $Path (Get-PvmDriveLetterChange,
# then Save-PvmFileChange), keeping its first version at $BackupPath and the version before the
# latest rewrite at $PreviousPath, and logging to $LogPath.
function Set-PvmDriveLetterInFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Letter,
        [string[]]$Known = @(),
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$PreviousPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    $change = Get-PvmDriveLetterChange -Path $Path -Root $Root -Letter $Letter -Known $Known -BackupPath $BackupPath -PreviousPath $PreviousPath -LogPath $LogPath
    if ($null -ne $change) { Save-PvmFileChange -Change $change -LogPath $LogPath }
}

# --- Running VMs -----------------------------------------------------------------------------

# Return the GUIDs written in $Text as 8-4-4-4-12 hex digits, with or without braces, as [guid]
# values.
function Find-PvmGuid {
    [CmdletBinding()]
    [OutputType([guid])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    foreach ($match in [regex]::Matches($Text, '(?<![0-9A-Fa-f-])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Fa-f-])')) {
        [guid]$match.Value
    }
}

# Return whether the process $Process may be the VirtualBox VM $VmUuid: a GUID in its command line
# (Find-PvmGuid) equals $VmUuid, or the command line cannot be read.
function Test-PvmVirtualBoxVmProcess {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][string]$VmUuid
    )
    if (-not $Process.CommandLine) { return $true }
    @(Find-PvmGuid -Text $Process.CommandLine) -contains [guid]$VmUuid
}

# Return whether the output $Output of `VBoxManage list vms` lists the VM $VmUuid: a line that
# ends in that UUID in braces. The UUID anywhere else on a line, such as in another VM's name,
# does not count.
function Test-PvmVirtualBoxVmListed {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][string]$Output,
        [Parameter(Mandatory)][string]$VmUuid
    )
    foreach ($line in ($Output -split "`n")) {
        if ($line -match '\{([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\}\s*\z' -and [guid]$Matches[1] -eq [guid]$VmUuid) {
            return $true
        }
    }
    $false
}

# Return how the output $Output of `VBoxManage list vms` lists the VM $VmUuid: 'Listed', 'Inaccessible'
# when VirtualBox cannot read its .vbox and shows "<inaccessible>" for its name, or 'Missing'
# (Test-PvmVirtualBoxVmListed).
function Get-PvmVirtualBoxListing {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Output,
        [Parameter(Mandatory)][string]$VmUuid
    )
    foreach ($line in ($Output -split "`n")) {
        if ($line -match '\{([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\}\s*\z' -and [guid]$Matches[1] -eq [guid]$VmUuid) {
            if ($line -match '\A\s*"<inaccessible>"') { return 'Inaccessible' }
            return 'Listed'
        }
    }
    'Missing'
}

# Return whether a VirtualBox VM process on this PC (VirtualBoxVM or VBoxHeadless) may be
# the VM $VmUuid (Test-PvmVirtualBoxVmProcess).
function Test-PvmRunningInVirtualBox {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VmUuid)
    $processes = @(Invoke-PvmGetProcess -Name 'VirtualBoxVM', 'VBoxHeadless')
    # Without the VM's UUID, any VirtualBox VM may be this one.
    if (-not $VmUuid) { return [bool]$processes.Count }
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

# Return whether a vmware-vmx process on this PC may be the VM $Vmx (Test-PvmVMwareVmProcess).
function Test-PvmRunningInVMware {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Vmx)
    $processes = @(Invoke-PvmGetProcess -Name 'vmware-vmx')
    [bool]($processes | Where-Object { Test-PvmVMwareVmProcess -Process $_ -Vmx $Vmx })
}

# --- Saved states ----------------------------------------------------------------------------
# A saved (VirtualBox) or suspended (VMware) VM still holds unwritten changes to the stick in its
# saved memory. Booting the stick any other way before resuming it can corrupt the guest's file
# system.

# Return the settings in the .vmx text $Text as a hashtable with lowercase keys and the values
# without their quotes. A key that appears twice keeps its last value, as VMware reads it; comment
# lines and lines without an = are skipped.
function ConvertFrom-PvmVmxText {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $values = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        # VMware allows a # comment after the value, as in: key = "value" # note.
        if ($line -match '^\s*([^#=\s][^=]*?)\s*=\s*(?:"([^"]*)"|([^"#\s]*))\s*(?:#.*)?$') {
            $value = if ($Matches.ContainsKey(2)) { $Matches[2] } else { $Matches[3] }
            $values[$Matches[1].ToLowerInvariant()] = $value
        }
    }
    $values
}

# Return why a file the settings name is missing, for Assert-PvmKnownState: outside Windows the
# name in settings.psd1 must also match the file's case, which a setting that works on Windows may
# not.
function Get-PvmMissingReason {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Test-PvmWindowsHost) { return 'the file does not exist' }
    'the file does not exist, and on this system the name in settings.psd1 must match its case'
}

# Return what the .vmx $Path says about a VMware suspend: State 'Saved' when checkpoint.vmState
# has a value, 'NotSaved' when it has none, or 'Unknown' with the Reason when the file is missing,
# cannot be read or is no complete .vmx, which always holds config.version. Values holds the
# file's settings (ConvertFrom-PvmVmxText) when it could be read, else an empty hashtable.
function Get-PvmVMwareState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return [pscustomobject]@{ State = 'Unknown'; Reason = 'the path is a folder, not a file'; Values = @{} }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'Unknown'; Reason = (Get-PvmMissingReason); Values = @{} }
    }
    try { $text = [IO.File]::ReadAllText($Path) }
    catch { return [pscustomobject]@{ State = 'Unknown'; Reason = "the file cannot be read ($($_.Exception.Message))"; Values = @{} } }
    $values = ConvertFrom-PvmVmxText -Text $text
    if (-not $values.ContainsKey('config.version')) {
        return [pscustomobject]@{ State = 'Unknown'; Reason = 'the file is no complete .vmx: it has no config.version line'; Values = $values }
    }
    # Which of two values VMware uses is not documented, so a safety key set twice is unknown.
    foreach ($key in 'checkpoint.vmState', 'suspend.disabled', 'uuid.action') {
        if (@($text -split "`r?`n" | Where-Object { $_ -match ('^\s*' + [regex]::Escape($key) + '\s*=') }).Count -gt 1) {
            return [pscustomobject]@{ State = 'Unknown'; Reason = "the file sets $key more than once"; Values = $values }
        }
    }
    $state = if ($values['checkpoint.vmstate']) { 'Saved' } else { 'NotSaved' }
    [pscustomobject]@{ State = $state; Reason = ''; Values = $values }
}

# Return what the .vbox $Path says about a VirtualBox save: State 'Saved' when its Machine element
# has a stateFile, 'NotSaved' when it has none, or 'Unknown' with the Reason when the file is
# missing, cannot be read, is no XML or has no Machine element. DTDs are refused. A file that was
# read also gives its StateFile, as the .vbox names it.
function Get-PvmVirtualBoxState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return [pscustomobject]@{ State = 'Unknown'; Reason = 'the path is a folder, not a file' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'Unknown'; Reason = (Get-PvmMissingReason) }
    }
    try { $text = [IO.File]::ReadAllText($Path) }
    catch { return [pscustomobject]@{ State = 'Unknown'; Reason = "the file cannot be read ($($_.Exception.Message))" } }
    $readerSettings = New-Object System.Xml.XmlReaderSettings
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    try {
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($text), $readerSettings)
        try {
            $document = New-Object System.Xml.XmlDocument
            $document.Load($reader)
        } finally {
            $reader.Close()
        }
    } catch {
        return [pscustomobject]@{ State = 'Unknown'; Reason = "the file is no valid XML ($($_.Exception.Message))" }
    }
    $machine = $document.SelectSingleNode("/*[local-name()='VirtualBox']/*[local-name()='Machine']")
    if ($null -eq $machine) { return [pscustomobject]@{ State = 'Unknown'; Reason = 'the file has no Machine element' } }
    $state = if ($machine.GetAttribute('stateFile')) { 'Saved' } else { 'NotSaved' }
    [pscustomobject]@{ State = $state; Reason = ''; StateFile = $machine.GetAttribute('stateFile') }
}

# --- The VM's own files ----------------------------------------------------------------------
# The .vmx and the .vbox say which disk file the VM uses, and the .vbox holds the VM's UUID. The
# launcher points exactly those files at the stick; settings that name them too must agree.

# Return the disk files that the .vmx settings $Values (ConvertFrom-PvmVmxText) of the .vmx $Vmx
# attach: each <bus><n>:<m>.fileName on an ide, sata, scsi or nvme bus whose device is present,
# on a controller that is not switched off, is no CD drive and names a .vmdk. Each has its Key, such as scsi0:0, its Bus, the controller's
# VirtualDev and the File as the .vmx names it, with its Path (Resolve-PvmVmFilePath) relative
# to the .vmx folder.
function Get-PvmVmxDisk {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Vmx
    )
    foreach ($key in @($Values.Keys | Sort-Object)) {
        if ($key -notmatch '\A(ide|sata|scsi|nvme)(\d+):(\d+)\.filename\z') { continue }
        $bus = $Matches[1]
        $controller = $Matches[1] + $Matches[2]
        $device = $key.Substring(0, $key.Length - '.filename'.Length)
        if ("$($Values["$device.present"])" -ne 'TRUE' -or "$($Values["$controller.present"])" -eq 'FALSE') { continue }
        if ("$($Values["$device.devicetype"])" -match 'cdrom|floppy') { continue }
        $file = "$($Values[$key])"
        if (-not $file.EndsWith('.vmdk', [StringComparison]::OrdinalIgnoreCase)) { continue }
        [pscustomobject]@{
            Key        = $device
            Bus        = $bus
            VirtualDev = "$($Values["$controller.virtualdev"])"
            File       = $file
            Path       = Resolve-PvmVmFilePath -Folder (Split-Path $Vmx) -File $file
        }
    }
}

# Return the full path of the file $File that a VM file in the folder $Folder names: relative to
# that folder, or absolute; either slash is a separator. A path with a drive letter is absolute on
# every system; outside Windows it names no file there and stays as written. A name that the
# system cannot make a path of gives ''.
function Resolve-PvmVmFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$File
    )
    if ($File -match '\A[A-Za-z]:[\\/]' -and [IO.Path]::DirectorySeparatorChar -ne '\') { return $File }
    $separator = [IO.Path]::DirectorySeparatorChar
    $name = $File.Replace('\', $separator).Replace('/', $separator)
    try {
        if ([IO.Path]::IsPathRooted($name)) { return [IO.Path]::GetFullPath($name) }
        [IO.Path]::GetFullPath([IO.Path]::Combine($Folder, $name))
    } catch {
        ''
    }
}

# Return whether the full path $Path lies below the stick folder $Root: without case on Windows.
function Test-PvmBelowStick {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    if (-not $Path) { return $false }
    $below = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $comparison = if (Test-PvmWindowsHost) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $Path.StartsWith($below, $comparison)
}

# Return whether the disk file $Path is one the launcher points at the stick: $null when it is
# missing, else whether one of its FLAT extents names a raw device (Test-PvmRawDeviceTarget). A
# file of 1 MiB or more, a folder, or one that cannot be read, is none.
function Test-PvmRawDiskFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    if ([IO.Directory]::Exists($Path)) { return $false }
    try {
        $file = [IO.FileInfo]::new($Path)
        if (-not $file.Exists) { return $null }
        if ($file.Length -ge 1MB) { return $false }
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    } catch {
        return $false
    }
    foreach ($match in [regex]::Matches($text, '(?im)^[ \t]*(?:RW|RDONLY|NOACCESS)[ \t]+\d+[ \t]+FLAT[ \t]+"([^"]*)"')) {
        if (Test-PvmRawDeviceTarget -Target $match.Groups[1].Value) { return $true }
    }
    $false
}

# Return the disk file among $Disks, each with its Path, that the launcher points at the stick,
# for the VM file $File of the program $Program: the one the setting $SettingName names, as the
# full path $Setting, when it is set; else the one raw disk (Test-PvmRawDiskFile), or the one that
# is missing. Returns Path, Disk, Problem, the stop's message, or '', and its Kind, which names no
# file: Setting, None, Several or Outside. With a problem, Path is $Setting, which a dry run goes
# on with.
function Select-PvmVmDisk {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [AllowEmptyCollection()][object[]]$Disks = @(),
        [Parameter(Mandatory)][AllowEmptyString()][string]$Setting,
        [Parameter(Mandatory)][string]$SettingName,
        [Parameter(Mandatory)][string]$Program,
        [Parameter(Mandatory)][string]$File
    )
    $values = @{ Program = $Program; File = $File; Setting = $SettingName; Root = $Context.Root }
    $attached = if ($Disks.Count) { (@($Disks | ForEach-Object { if ($_.Path) { $_.Path } else { $_.File } }) -join ', ') } else { 'no disk file' }
    $chosen = $null
    if ($Setting) {
        $comparison = if (Test-PvmWindowsHost) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $chosen = @($Disks | Where-Object { [string]::Equals($_.Path, $Setting, $comparison) }) | Select-Object -First 1
        if ($null -eq $chosen) {
            $values['Path'] = $Setting
            $values['Attached'] = $attached
            return [pscustomobject]@{ Path = $Setting; Disk = $null; Kind = 'Setting'; Problem = (Format-PvmMessage -Names $Context.Names -Values $values -Template (
                        '{Setting} in settings.psd1 names {Path}, but {vm}''s {Program} file {File} does not attach it; it attaches {Attached}. ' +
                        'Correct {Setting}, or remove it so that the launcher takes the disk file from {File}. Nothing was started.')) }
        }
    } else {
        $raw = @($Disks | Where-Object { $false -ne (Test-PvmRawDiskFile -Path $_.Path) })
        if ($raw.Count -ne 1) {
            $values['Attached'] = $attached
            $template = if ($raw.Count) {
                '{VM}''s {Program} file {File} attaches more than one raw-disk file ({Attached}). Set {Setting} in settings.psd1 to the one the launcher should point at the stick. Nothing was started.'
            } else {
                '{VM}''s {Program} file {File} attaches no raw-disk file, so the launcher cannot tell which file to point at the stick; it attaches {Attached}. Attach the stick''s disk file in {Program}, then start {vm} again. Nothing was started.'
            }
            $kind = if ($raw.Count) { 'Several' } else { 'None' }
            return [pscustomobject]@{ Path = ''; Disk = $null; Kind = $kind; Problem = (Format-PvmMessage -Names $Context.Names -Values $values -Template $template) }
        }
        $chosen = $raw[0]
    }
    if (-not (Test-PvmBelowStick -Root $Context.Root -Path $chosen.Path)) {
        $values['Path'] = $chosen.Path
        return [pscustomobject]@{ Path = $Setting; Disk = $null; Kind = 'Outside'; Problem = (Format-PvmMessage -Names $Context.Names -Values $values -Template (
                    '{VM}''s {Program} file {File} attaches the disk file {Path}, which is not below the stick folder {Root}, so the launcher does not point it at the stick. ' +
                    'Attach the stick''s disk file from below the stick folder in {Program}, then start {vm} again. Nothing was started.')) }
    }
    [pscustomobject]@{ Path = $chosen.Path; Disk = $chosen; Kind = ''; Problem = '' }
}

# Return a new record of the VM's own files for $Context.VmFiles, with the paths and the UUID that
# the settings in $Context name, until Resolve-PvmVMwareFile and Resolve-PvmVirtualBoxFile read
# them from the VM's files: VMwareDisk, VMwareAdapter, VMwareProblem, VirtualBoxDisk,
# VirtualBoxVmUuid, VirtualBoxProblem, and the stick disk's Controller, HostIOCache and
# BandwidthGroup in VirtualBox. VMwareKind and VirtualBoxKind name each problem's kind
# (Select-PvmVmDisk's, or Uuid, NoMachine or Unlisted); VMwareRead and VirtualBoxRead say whether
# the file was read. A path that is not set is ''.
function New-PvmVmFileRecord {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes nothing.')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $settings = $Context.Settings
    $vmwareDisk = if ($settings['VMwareDisk']) { Join-PvmStickPath -Root $Context.Root -Path $settings['VMwareDisk'] } else { '' }
    $virtualBoxDisk = if ($settings['VirtualBoxDisk']) { Join-PvmStickPath -Root $Context.Root -Path $settings['VirtualBoxDisk'] } else { '' }
    [pscustomobject]@{
        VMwareDisk        = $vmwareDisk
        VMwareAdapter     = 'ide'
        VMwareProblem     = ''
        VMwareKind        = ''
        VMwareRead        = $false
        VirtualBoxDisk    = $virtualBoxDisk
        VirtualBoxVmUuid  = "$($settings['VirtualBoxVmUuid'])"
        VirtualBoxProblem = ''
        VirtualBoxKind    = ''
        VirtualBoxRead    = $false
        Controller        = ''
        HostIOCache       = ''
        BandwidthGroup    = ''
    }
}

# Read which disk file the .vmx that the settings in $Context name attaches (Get-PvmVmxDisk,
# Select-PvmVmDisk) into $Context.VmFiles: its path and the adapter type a new descriptor gets
# from its bus, or VMwareProblem. A .vmx that cannot be read leaves the record as it is, since the
# start stops at it anyway (Assert-PvmKnownState).
function Resolve-PvmVMwareFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $files = $Context.VmFiles
    $vmx = Join-PvmStickPath -Root $Context.Root -Path $Context.Settings['VMwareVmx']
    $state = Get-PvmVMwareState -Path $vmx
    if ($state.State -eq 'Unknown') { return }
    $choice = Select-PvmVmDisk -Context $Context -Disks @(Get-PvmVmxDisk -Values $state.Values -Vmx $vmx) -Setting $files.VMwareDisk -SettingName 'VMwareDisk' -Program 'VMware' -File $vmx
    $files.VMwareRead = $true
    $files.VMwareDisk = $choice.Path
    $files.VMwareProblem = $choice.Problem
    $files.VMwareKind = $choice.Kind
    if ($choice.Disk) {
        $files.VMwareAdapter = if ($choice.Disk.Bus -ne 'scsi') { 'ide' } elseif ($choice.Disk.VirtualDev -eq 'buslogic') { 'buslogic' } else { 'lsilogic' }
    }
}

# Return the .vbox $Path as an XmlDocument in Document, or a Reason why it cannot be read: it is
# missing, a folder, unreadable or no XML. DTDs are refused.
function Read-PvmXmlFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) { return [pscustomobject]@{ Document = $null; Reason = 'the path is a folder, not a file' } }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Document = $null; Reason = (Get-PvmMissingReason) } }
    try { $text = [IO.File]::ReadAllText($Path) }
    catch { return [pscustomobject]@{ Document = $null; Reason = "the file cannot be read ($($_.Exception.Message))" } }
    $readerSettings = New-Object System.Xml.XmlReaderSettings
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    try {
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($text), $readerSettings)
        try {
            $document = New-Object System.Xml.XmlDocument
            $document.Load($reader)
        } finally {
            $reader.Close()
        }
    } catch {
        return [pscustomobject]@{ Document = $null; Reason = "the file is no valid XML ($($_.Exception.Message))" }
    }
    [pscustomobject]@{ Document = $document; Reason = '' }
}

# Return what the .vbox document $Document of the file $Vbox says about its disks: the Machine's
# Uuid without braces, and Disks, each hard disk that a storage controller attaches outside the
# snapshots, with its Path (a location relative to the .vbox folder, or with a drive letter, read
# as on the stick when it names a path below the stick's folder as $Location spells it), the
# Controller's name, its useHostIOCache and the device's bandwidthGroup as written; or a Reason
# and its Kind, NoMachine or Unlisted. When the stick folder is a drive root, every lettered path
# is below it, so such a path counts as on the stick only with the stick's letter now, or when its
# file is there, as the old letter of another PC leaves it; a path on another drive stays as it is.
function Get-PvmVboxDisk {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$Vbox,
        [Parameter(Mandatory)][string]$Root,
        [AllowNull()]$Location
    )
    $machine = $Document.SelectSingleNode("/*[local-name()='VirtualBox']/*[local-name()='Machine']")
    if ($null -eq $machine) { return [pscustomobject]@{ Uuid = ''; Disks = @(); Reason = 'it has no Machine element'; Kind = 'NoMachine' } }
    $uuid = $machine.GetAttribute('uuid').Trim('{', '}')
    $media = @{}
    foreach ($disk in @($machine.SelectNodes(".//*[local-name()='MediaRegistry']//*[local-name()='HardDisk']"))) {
        $media[$disk.GetAttribute('uuid').Trim('{', '}').ToLowerInvariant()] = $disk.GetAttribute('location')
    }
    $below = if ($null -ne $Location -and $Location.Path -match '\A[A-Za-z]:') { $Location.Path.Substring(2).Replace('/', '\').TrimEnd('\') } else { $null }
    $unlisted = $false
    $disks = foreach ($controller in @($machine.SelectNodes(".//*[local-name()='StorageController'][not(ancestor::*[local-name()='Snapshot'])]"))) {
        foreach ($device in @($controller.SelectNodes("*[local-name()='AttachedDevice']"))) {
            if ($device.GetAttribute('type') -ne 'HardDisk') { continue }
            $image = $device.SelectSingleNode("*[local-name()='Image']")
            $key = if ($null -ne $image) { $image.GetAttribute('uuid').Trim('{', '}').ToLowerInvariant() } else { '' }
            if (-not $media.ContainsKey($key)) {
                $unlisted = $true
                continue
            }
            $named = $media[$key]
            $path = if ($null -ne $below -and $named -match '\A[A-Za-z]:[\\/]') {
                $rest = $named.Substring(2).Replace('/', '\')
                $onStick = if ($rest.StartsWith($below + '\', [StringComparison]::OrdinalIgnoreCase)) { Join-PvmStickPath -Root $Root -Path $rest.Substring($below.Length + 1) } else { '' }
                if ($onStick -and ($below -or [string]::Equals($named.Substring(0, 1), "$($Location.Letter)", [StringComparison]::OrdinalIgnoreCase) -or [IO.File]::Exists($onStick))) { $onStick }
                else { Resolve-PvmVmFilePath -Folder (Split-Path $Vbox) -File $named }
            } else {
                Resolve-PvmVmFilePath -Folder (Split-Path $Vbox) -File $named
            }
            [pscustomobject]@{
                Path           = $path
                File           = $named
                Controller     = $controller.GetAttribute('name')
                HostIOCache    = $controller.GetAttribute('useHostIOCache')
                BandwidthGroup = $device.GetAttribute('bandwidthGroup')
            }
        }
    }
    if ($unlisted) { return [pscustomobject]@{ Uuid = $uuid; Disks = @(); Reason = 'it attaches a hard disk that its media registry does not list'; Kind = 'Unlisted' } }
    [pscustomobject]@{ Uuid = $uuid; Disks = @($disks); Reason = ''; Kind = '' }
}

# Read the VM's UUID and which disk file the .vbox that the settings in $Context name attaches
# (Get-PvmVboxDisk, Select-PvmVmDisk), with the storage settings of that disk, into
# $Context.VmFiles, or VirtualBoxProblem. A VirtualBoxVmUuid in the settings must equal the
# .vbox's. A .vbox that cannot be read leaves the record as it is, since the start stops at it
# anyway (Assert-PvmKnownState).
function Resolve-PvmVirtualBoxFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $files = $Context.VmFiles
    $vbox = Join-PvmStickPath -Root $Context.Root -Path $Context.Settings['VirtualBoxVbox']
    $xml = Read-PvmXmlFile -Path $vbox
    if ($null -eq $xml.Document) { return }
    $read = Get-PvmVboxDisk -Document $xml.Document -Vbox $vbox -Root $Context.Root -Location $Context.Location
    $values = @{ Vbox = $vbox; Reason = $read.Reason; Setting = $files.VirtualBoxVmUuid; Uuid = $read.Uuid }
    $files.VirtualBoxRead = $true
    if ($read.Reason) {
        $files.VirtualBoxKind = $read.Kind
        $files.VirtualBoxProblem = Format-PvmMessage -Names $Context.Names -Values $values -Template 'The launcher cannot tell which disk file {vm}''s .vbox file {Vbox} uses, because {Reason}. Nothing was started.'
        return
    }
    if ($files.VirtualBoxVmUuid -and -not [string]::Equals($files.VirtualBoxVmUuid, $read.Uuid, [StringComparison]::OrdinalIgnoreCase)) {
        $files.VirtualBoxKind = 'Uuid'
        $files.VirtualBoxProblem = Format-PvmMessage -Names $Context.Names -Values $values -Template (
            'VirtualBoxVmUuid in settings.psd1 is {Setting}, but {vm}''s .vbox file {Vbox} has the UUID {Uuid}. ' +
            'Correct VirtualBoxVmUuid, or remove it so that the launcher takes the UUID from the .vbox file. Nothing was started.')
        return
    }
    $files.VirtualBoxVmUuid = $read.Uuid
    $choice = Select-PvmVmDisk -Context $Context -Disks $read.Disks -Setting $files.VirtualBoxDisk -SettingName 'VirtualBoxDisk' -Program 'VirtualBox' -File $vbox
    $files.VirtualBoxDisk = $choice.Path
    $files.VirtualBoxProblem = $choice.Problem
    $files.VirtualBoxKind = $choice.Kind
    if ($choice.Disk) {
        $files.Controller = $choice.Disk.Controller
        $files.HostIOCache = $choice.Disk.HostIOCache
        $files.BandwidthGroup = $choice.Disk.BandwidthGroup
    }
}

# Return the messages of the stops for VirtualBox's storage settings of the stick's disk in
# $Context.VmFiles: host I/O cache must be on and no bandwidth group set, or VirtualBox takes the
# stick's volumes away from Windows, the Data partition with the launcher's own files too; then
# the stop for a mounted partition in the VM's part of the stick (Get-PvmMountedStop).
function Get-PvmVirtualBoxStorageProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)]$Disk
    )
    $files = $Context.VmFiles
    $values = @{ Controller = $files.Controller; Group = $files.BandwidthGroup }
    if ($files.Controller -and $files.HostIOCache -ne 'true') {
        Format-PvmMessage -Names $Context.Names -Values $values -Template (
            'Host I/O cache is off for the storage controller {Controller} in VirtualBox, which holds {vm}''s stick disk. Then VirtualBox takes the stick''s volumes away ' +
            'from Windows, the launcher''s own folder too. Turn on "Use Host I/O Cache" for that controller in {vm}''s storage settings in VirtualBox, then start {vm} again. Nothing was started.')
    }
    if ($files.BandwidthGroup) {
        Format-PvmMessage -Names $Context.Names -Values $values -Template (
            '{VM}''s stick disk in VirtualBox has the bandwidth group {Group}, with which VirtualBox takes the stick''s volumes away from Windows. ' +
            'Set its bandwidth group to none in VirtualBox, then start {vm} again. Nothing was started.')
    }
    Get-PvmMountedStop -Context $Context -Disk $Disk -Program 'VirtualBox'
}

# Return the message of the stop for a start in $Program, VMware or VirtualBox, when, on Windows,
# a partition of the stick other than Data is mounted before the Data partition, in the part of the
# stick the VM uses (Get-PvmMountedVmPartition), or when the partitions cannot be read; else
# nothing. VirtualBox would take such a partition away from Windows, and in either program
# Windows refuses the guest's writes into it while it is mounted.
function Get-PvmMountedStop {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)][ValidateSet('VMware', 'VirtualBox')][string]$Program
    )
    if (-not (Test-PvmWindowsHost)) { return }
    $mounted = Get-PvmMountedVmPartition -Disk $Disk -DataPartitionStart $Context.Settings['DataPartitionStart']
    if ($mounted.Problem) {
        return (Format-PvmMessage -Names $Context.Names -Values @{ Cause = $mounted.Problem } -Template 'The launcher cannot tell which partitions of the stick Windows has mounted, because {Cause}. Nothing was started.')
    }
    if (-not $mounted.Mounts.Count) { return }
    $why = if ($Program -eq 'VirtualBox') { '. VirtualBox would take it away from Windows, or {guest} would write into it while Windows uses it.' }
    else { ', and {guest} could not write to it while Windows uses it.' }
    Format-PvmMessage -Names $Context.Names -Values @{ Mounts = ($mounted.Mounts -join ', ') } -Template (
        'Windows has mounted a partition in the part of the stick that {vm} uses ({Mounts})' + $why +
        ' Remove its drive letter or folder path in Disk Management, then start {vm} again. Nothing was started.')
}

# Return the places, such as E:\, where Windows has mounted a partition of the disk $Disk that
# starts before the sector $DataPartitionStart, which is the VM's own part of the stick, in Mounts;
# or Problem, the cause, when the partitions cannot be read. A volume's \\?\Volume{...}\ path is
# no mount.
function Get-PvmMountedVmPartition {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)][int64]$DataPartitionStart
    )
    try { $partitions = @(Invoke-PvmGetDiskPartition -Number $Disk.Number) }
    catch { return [pscustomobject]@{ Mounts = @(); Problem = (Format-PvmBecause -Cause (Get-PvmErrorCause -ErrorRecord $_)) } }
    $mounts = foreach ($partition in $partitions) {
        if ([int64]($partition.Offset / 512) -ge $DataPartitionStart) { continue }
        $names = $partition.PSObject.Properties.Name
        if ($names -contains 'DriveLetter' -and $partition.DriveLetter -and [int][char]$partition.DriveLetter -ne 0) { "$([char]$partition.DriveLetter):\" }
        if ($names -contains 'AccessPaths') { @($partition.AccessPaths) | Where-Object { $_ -and -not $_.StartsWith('\\?\') -and $_ -notmatch '\A[A-Za-z]:\\?\z' } }
    }
    [pscustomobject]@{ Mounts = @($mounts | Select-Object -Unique); Problem = '' }
}

# Return the files a start may write, each followed by its first copy and the copy of the version
# before its latest rewrite below the backups folder: the .vmx, the VMware descriptor, the .vbox,
# VirtualBox.xml and the VirtualBox descriptor, the descriptors as $Context.VmFiles names them, or
# else as the settings do; one that neither names is left out. Each has its Kind (Vmx, VMwareDisk,
# Vbox, VirtualBoxXml, VirtualBoxDisk) and Path; a copy also the file it is Of, whether its copies
# are disarmed (Disarm), and whether it is the copy of the version before (Previous). With $Kind,
# only the files of those kinds.
function Get-PvmWrittenPath {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [string[]]$Kind = @('Vmx', 'VMwareDisk', 'Vbox', 'VirtualBoxXml', 'VirtualBoxDisk')
    )
    $settings = $Context.Settings
    $backup = @{ Root = $Context.Root; Backups = $Context.Backups }
    $vmFiles = if ($Context.PSObject.Properties.Name -contains 'VmFiles' -and $null -ne $Context.VmFiles) { $Context.VmFiles } else { New-PvmVmFileRecord -Context $Context }
    $files = @(
        @{ Kind = 'Vmx'; Path = (Join-PvmStickPath -Root $Context.Root -Path $settings['VMwareVmx']); Suffix = '.launcher-backup' }
        @{ Kind = 'VMwareDisk'; Path = $vmFiles.VMwareDisk; Suffix = '.orig' }
        @{ Kind = 'Vbox'; Path = (Join-PvmStickPath -Root $Context.Root -Path $settings['VirtualBoxVbox']); Suffix = '.launcher-backup' }
        @{ Kind = 'VirtualBoxXml'; Path = (Join-Path (Join-PvmStickPath -Root $Context.Root -Path $settings['VirtualBoxHome']) 'VirtualBox.xml'); Suffix = '.launcher-backup' }
        @{ Kind = 'VirtualBoxDisk'; Path = $vmFiles.VirtualBoxDisk; Suffix = '.orig' }
    )
    foreach ($file in $files) {
        if ($Kind -notcontains $file.Kind -or -not $file.Path) { continue }
        $disarm = $file.Suffix -eq '.orig'
        [pscustomobject]@{ Kind = $file.Kind; Path = $file.Path; Of = ''; Disarm = $disarm; Previous = $false }
        [pscustomobject]@{ Kind = $file.Kind; Path = (Get-PvmBackupPath @backup -Path $file.Path -Suffix $file.Suffix); Of = $file.Path; Disarm = $disarm; Previous = $false }
        [pscustomobject]@{ Kind = $file.Kind; Path = (Get-PvmBackupPath @backup -Path $file.Path -Suffix ('.previous' + $file.Suffix)); Of = $file.Path; Disarm = $disarm; Previous = $true }
    }
}

# At a write that did not finish of a file the start may write or of a copy of one
# (Get-PvmWrittenPath), ask whether to take the step that sets it right (Confirm-PvmLeftoverFix),
# and take it on Yes (Repair-PvmLeftover); else stop the start with that step, as for a step the
# launcher does not take by itself, which a dry run logs as a stop. While VMware, VirtualBox or
# its background service runs (Test-PvmHypervisorOpen), which may hold or rewrite these files, it
# offers no fix and stops with the step. A dry run goes on with the files as they are, so its
# later lines are those of a start that was not set right. A file's own step comes before its
# copies', which are checked against the file as it is then: after its fix, or, while it is not
# fixed, not at all.
function Assert-PvmNoWrittenLeftover {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [string[]]$Kind = @('Vmx', 'VMwareDisk', 'Vbox', 'VirtualBoxXml', 'VirtualBoxDisk')
    )
    $broken = @{}
    $open = $null
    foreach ($entry in @(Get-PvmWrittenPath -Context $Context -Kind $Kind)) {
        if ($entry.Of -and $broken.ContainsKey($entry.Of)) { continue }
        $step = Get-PvmWrittenLeftoverStep -Entry $entry
        if (-not $step) { continue }
        if ($step.Actions.Count -and $null -eq $open) { $open = Test-PvmHypervisorOpen }
        if (-not $step.Actions.Count -or $open) {
            if (-not $entry.Of) { $broken[$entry.Path] = $true }
            $why = if ($step.Actions.Count) { ' The launcher offers to do this only while VMware and VirtualBox are closed.' } else { '' }
            Invoke-PvmStopUnlessDryRun -Context $Context -Message "$($step.Problem)$why Nothing was started."
            continue
        }
        if (-not (Confirm-PvmLeftoverFix -Context $Context -Step $step)) {
            if (-not $entry.Of) { $broken[$entry.Path] = $true }
            continue
        }
        try { Repair-PvmLeftover -Context $Context -Step $step }
        catch {
            if (-not (Test-PvmWriteError -ErrorRecord $_)) { throw }
            $cause = Format-PvmBecause -Cause (Get-PvmPathCause -Path $step.Path -ErrorRecord $_)
            $left = Get-PvmWrittenLeftoverStep -Entry $entry
            $rest = if ($left) { " $($left.Problem)" } else { '' }
            throw (Get-PvmStopException -Message "The launcher could not finish setting right the write of $($step.Path), because $cause.$rest Nothing was started.")
        }
        $left = Get-PvmWrittenLeftoverStep -Entry $entry
        if ($left) { throw (Get-PvmStopException -Message "$($left.Problem) Nothing was started.") }
    }
}

# Return whether VMware Workstation, VirtualBox, a VM of either, or VirtualBox's background
# service in this Windows session runs, any of which may hold or rewrite the files a fix changes.
function Test-PvmHypervisorOpen {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (@(Invoke-PvmGetProcess -Name 'vmware', 'vmware-vmx').Count) { return $true }
    Test-PvmVirtualBoxOpen
}

# Return whether VirtualBox, a VM of VirtualBox, or VirtualBox's background service in this Windows
# session runs, any of which may hold or rewrite the VM's .vbox. Another session's VBoxSVC uses
# that user's own VirtualBox home, not the stick's, so it is not counted, as at a start.
function Test-PvmVirtualBoxOpen {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (@(Invoke-PvmGetProcess -Name 'VirtualBox', 'VirtualBoxVM', 'VBoxHeadless').Count) { return $true }
    [bool](Invoke-PvmTestProcess -Name 'VBoxSVC')
}

# Return the step for a write that did not finish of the file or copy $Entry of Get-PvmWrittenPath,
# or $null.
function Get-PvmWrittenLeftoverStep {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Entry)
    if ($Entry.Previous) { Get-PvmCopyLeftoverStep -Path $Entry.Path -Of $Entry.Of -Disarm:$Entry.Disarm }
    else { Get-PvmLeftoverStep -Path $Entry.Path }
}

# Ask, through the script block $Context.AskFix, whether to take the step $Step of
# Get-PvmLeftoverStep, with the dialog's title $Context.Caption, and log a Yes. The question says
# what a Yes puts aside, and where. Returns $true on Yes. Throws the stop with the step when the
# answer is No, when there is no way to ask, or when the script block returns anything but a single
# $true. A dry run asks nothing: it logs that a real start would ask, takes the step as its result
# when it has none yet, as a real start answered No would end, and returns $false.
function Confirm-PvmLeftoverFix {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][pscustomobject]$Step
    )
    if ($Context.DryRun) {
        Write-PvmLog -Path $Context.LogPath -Message "DRY RUN - a real start would ask whether to set it right: $($Step.Problem)"
        if (-not $Context.WouldStop) { $Context.WouldStop = "$($Step.Problem) Nothing was started." }
        return $false
    }
    $aside = if (@($Step.Actions | Where-Object { $_.Do -eq 'Remove' }).Count) { " A Yes moves each file it removes to $(Get-PvmRemovedFolder -Context $Context) rather than delete it." } else { '' }
    $question = "$($Step.Problem)`n`n$($Step.PutAside)$aside`n`nDo it now?"
    $before = $Context.Step
    Enter-PvmStep -Context $Context -Name 'question'
    $answer = if ($null -ne $Context.AskFix) { $Context.AskFix.InvokeReturnAsIs($question, $Context.Caption) } else { $null }
    Enter-PvmStep -Context $Context -Name $before
    if (-not ($answer -is [bool] -and $answer)) { throw (Get-PvmStopException -Message "$($Step.Problem) Nothing was started.") }
    Write-PvmLog -Path $Context.LogPath -Message "Fix confirmed: $($Step.Problem)"
    $true
}

# Return the folder, below LauncherData\backups\removed and named for the time of the run's first
# fix to the millisecond, into which the guided fix moves what it removes; the same for every fix of the run.
function Get-PvmRemovedFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    if (-not $Context.RemovedFolder) {
        $Context.RemovedFolder = Join-Path (Join-Path $Context.Backups 'removed') (Get-PvmNow).ToString('yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture)
    }
    $Context.RemovedFolder
}

# Take the step $Step of Get-PvmLeftoverStep, one action at a time: a Remove moves the file into
# the run's folder below LauncherData\backups\removed (Get-PvmRemovedFolder), under its path below
# the stick folder, and a Rename gives a copy the file's name; neither replaces a file. Each action
# may touch only the file $Step.Path and its two copies, .pvm-tmp and .pvm-old, and a Rename only
# gives a copy the file's name; else it throws before it moves anything. Each move is logged.
function Repair-PvmLeftover {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][pscustomobject]$Step
    )
    $copies = Get-PvmWriteCopyPath -Path $Step.Path
    $own = @($Step.Path, $copies.Temp, $copies.Old)
    foreach ($action in $Step.Actions) {
        $fits = if ($action.Do -eq 'Remove') { $own -ccontains $action.Path }
        elseif ($action.Do -eq 'Rename') { ($action.Path -ceq $copies.Temp -or $action.Path -ceq $copies.Old) -and $action.To -ceq $Step.Path }
        else { $false }
        if (-not $fits) {
            $name = [IO.Path]::GetFileName($Step.Path)
            throw "A fix of the write of $($Step.Path) touches only $name, $name.pvm-tmp and $name.pvm-old, and renames a copy only to $name."
        }
    }
    $root = $Context.Root.TrimEnd('\', '/')
    foreach ($action in $Step.Actions) {
        if ($action.Do -eq 'Rename') {
            Move-PvmLeftoverFile -Path $action.Path -Destination $action.To
            Write-PvmLog -Path $Context.LogPath -Message "Renamed: $($action.Path) -> $($action.To)"
            continue
        }
        $below = if ($action.Path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $action.Path.Substring($root.Length + 1) } else { [IO.Path]::GetFileName($action.Path) }
        $target = Join-Path (Get-PvmRemovedFolder -Context $Context) $below
        $null = [IO.Directory]::CreateDirectory((Split-Path $target))
        Move-PvmLeftoverFile -Path $action.Path -Destination $target
        Write-PvmLog -Path $Context.LogPath -Message "Moved aside: $($action.Path) -> $target"
    }
}

# Move the file $Path to $Destination, which must not exist, for the guided fix. Tests mock this.
function Move-PvmLeftoverFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )
    [IO.File]::Move($Path, $Destination)
}

# Stop the launcher when $State, from Get-PvmVMwareState or Get-PvmVirtualBoxState, is Unknown:
# the message says what cannot be told ($What, a Format-PvmMessage template), why, and which
# setting ($Setting) names the file $Path. A dry run logs the stop and carries on.
function Assert-PvmKnownState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][string]$Path
    )
    if ($State.State -ne 'Unknown') { return }
    $message = Format-PvmMessage -Names $Context.Names -Template "The launcher cannot tell $What, because {Reason}: {Setting} in settings.psd1 names {Path}. Nothing was started." -Values @{
        Reason = $State.Reason; Setting = $Setting; Path = $Path
    }
    Invoke-PvmStopUnlessDryRun -Context $Context -Message $message
}

# Ask, through the script block $Context.AskResume, whether to resume the saved state in $Program
# with the question $Question, and log a Yes. The script block gets the question and the title
# for its dialog, $Context.Caption. A dry run logs that a real start would ask and carries on.
# Throws the stop when the answer is No, when there is no way to ask, or when SavedStatePolicy in
# the settings is Refuse.
function Confirm-PvmResume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Program,
        [Parameter(Mandatory)][string]$Question
    )
    $names = $Context.Names
    $policy = $Context.Settings['SavedStatePolicy']
    if ($policy -ne 'Ask') {
        $message = Format-PvmMessage -Names $names -Template "{VM} has a saved state in {Program}, and SavedStatePolicy in settings.psd1 is '{Policy}', so the launcher does not resume it. To resume it through the launcher, set SavedStatePolicy to 'Ask' and start {vm} again. Nothing was started." -Values @{
            Program = $Program; Policy = $policy
        }
        Invoke-PvmStopUnlessDryRun -Context $Context -Message $message
        return
    }
    if ($Context.DryRun) {
        Write-PvmLog -Path $Context.LogPath -Message "DRY RUN - a real start would ask whether to resume the saved state in $Program."
        return
    }
    # Only a single $true counts as Yes, so a stray output of the script block cannot resume. The
    # time the question waits for its answer is a step of its own.
    $before = $Context.Step
    Enter-PvmStep -Context $Context -Name 'question'
    $answer = if ($null -ne $Context.AskResume) { $Context.AskResume.InvokeReturnAsIs($Question, $Context.Caption) } else { $null }
    Enter-PvmStep -Context $Context -Name $before
    if (-not ($answer -is [bool] -and $answer)) {
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $names -Template 'The saved state in {Program} was not resumed. Nothing was started. Start {vm} again to be asked again, or discard the saved state in {Program} first, which loses what {guest} had not saved.' -Values @{
                    Program = $Program
                }))
    }
    Write-PvmLog -Path $Context.LogPath -Message "Resume of the saved state in $Program confirmed."
}

# Stop a VMware start unless the .vmx settings in $Context.VMwareState hold uuid.action = "keep"
# and suspend.disabled = "TRUE", naming the line to set. A suspend, which can only be from before
# suspend.disabled was set and which VMware still resumes with it, is resumed only after
# Confirm-PvmResume. A dry run logs each stop and carries on.
function Assert-PvmVMwareReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Vmx
    )
    $values = $Context.VMwareState.Values
    foreach ($key in @(@{ Name = 'uuid.action'; Value = 'keep'; Why = 'so VMware can stop the start to ask whether {vm} was moved or copied' },
            @{ Name = 'suspend.disabled'; Value = 'TRUE'; Why = 'and a suspended VM holds changes to the stick that booting the stick another way can overwrite; a VM that is suspended now still resumes with the line' })) {
        $current = $values[$key.Name]
        if ($current -eq $key.Value) { continue }
        $has = if ($null -eq $current) { "lacks $($key.Name) = ""$($key.Value)""" } else { "has $($key.Name) = ""$current"" instead of ""$($key.Value)""" }
        $message = Format-PvmMessage -Names $Context.Names -Template "{VM}'s .vmx {Has}, $($key.Why). With VMware closed, set the line {Line} in {Vmx}, then start {vm} again." -Values @{
            Has = $has; Line = "$($key.Name) = ""$($key.Value)"""; Vmx = $Vmx
        }
        Invoke-PvmStopUnlessDryRun -Context $Context -Message $message
    }
    if ($Context.VMwareState.State -eq 'Saved') {
        $question = Format-PvmMessage -Names $Context.Names -Template "{VM} is suspended in VMware. Resume it only if the stick has not been booted any other way since the suspend; otherwise the resume can corrupt {guest}'s disk.`n`nResume {vm} now?"
        Confirm-PvmResume -Context $Context -Program 'VMware' -Question $question
    }
}

# --- The VM's size ---------------------------------------------------------------------------
# Request r9: at each start the launcher sizes the VM to the PC, in the program that starts it,
# writing the VM's file only when the size differs, never while the VM has a saved state or VMware
# Workstation is open, with copies of the file as for any rewrite.

# Return the VM's size for a PC with $Cores cores, $Threads logical processors and $MemoryMB of
# memory: Cpus, the smaller of all but one core and all but two threads, at least 2, at most
# $MaxCpus and never more than the threads; MemoryMB, the smaller of half the memory and all but
# 6 GB, rounded down to 256 MB, at least 4 GB and at most $MaxMemoryGB; and Small, whether the PC
# then keeps less than 6 GB or no core of its own.
function Get-PvmVmSize {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Cores,
        [Parameter(Mandatory)][int]$Threads,
        [Parameter(Mandatory)][int64]$MemoryMB,
        [int]$MaxCpus = 8,
        [int]$MaxMemoryGB = 16
    )
    $cpus = [Math]::Min($Cores - 1, $Threads - 2)
    $cpus = [Math]::Min([Math]::Min([Math]::Max($cpus, 2), $MaxCpus), $Threads)
    [int64]$memory = [Math]::Min([Math]::Floor($MemoryMB / 2), $MemoryMB - 6144)
    $memory = [int64]([Math]::Floor($memory / 256) * 256)
    $memory = [Math]::Min([Math]::Max($memory, [int64]4096), [int64]$MaxMemoryGB * 1024)
    [pscustomobject]@{ Cpus = [int]$cpus; MemoryMB = [int64]$memory; Small = (($MemoryMB - $memory) -lt 6144) -or (($Cores - $cpus) -lt 1) }
}

# Return the size the VM gets now, as the settings in $Context say: Why, the reason to leave the
# size as it is, or Cpus, MemoryMB, Detail for the log line and Notes, the lines to log after it.
# VmSizing Off leaves it; Fixed gives VmCpus and VmMemoryGB; Auto, the default, gives the rule's
# size for this PC (Get-PvmVmSize, Invoke-PvmGetHostSize).
function Get-PvmVmSizeTarget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $settings = $Context.Settings
    if ($settings['VmSizing'] -eq 'Off') { return [pscustomobject]@{ Why = 'VmSizing in settings.psd1 is Off' } }
    if ($settings['VmSizing'] -eq 'Fixed') {
        return [pscustomobject]@{ Why = ''; Cpus = [int]$settings['VmCpus']; MemoryMB = [int64]$settings['VmMemoryGB'] * 1024; Detail = '(VmSizing Fixed)'; Notes = @() }
    }
    $pc = $null
    try { $pc = Invoke-PvmGetHostSize } catch { $pc = $null }
    if ($null -eq $pc -or $pc.Cores -lt 1 -or $pc.Threads -lt 1 -or $pc.MemoryMB -lt 1) { return [pscustomobject]@{ Why = 'this PC''s cores and memory cannot be read' } }
    $size = Get-PvmVmSize -Cores $pc.Cores -Threads $pc.Threads -MemoryMB $pc.MemoryMB -MaxCpus $settings['VmMaxCpus'] -MaxMemoryGB $settings['VmMaxMemoryGB']
    $notes = @(
        if ($size.Small) { 'Note: this PC is small for the VM; with it running, the PC keeps less than 6 GB of memory or no core of its own.' }
        if ($null -ne $pc.FreeMB -and $pc.FreeMB -lt $size.MemoryMB + 2048) { 'Note: this PC has less free memory than the VM''s size and 2 GB more; close other programs if the VM is slow.' }
    )
    [pscustomobject]@{ Why = ''; Cpus = $size.Cpus; MemoryMB = $size.MemoryMB; Detail = "(this PC: $($pc.Cores) cores, $($pc.Threads) threads, $($pc.MemoryMB) MB)"; Notes = $notes }
}

# Return whether each of the files $Path that exists may be rewritten (Assert-PvmRewritable): not
# read-only and no link. The VM's size, which can wait, leaves such a file as it is.
function Test-PvmRewritable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string[]]$Path)
    foreach ($file in $Path) {
        if (-not [IO.File]::Exists($file)) { continue }
        try { Assert-PvmRewritable -Path $file } catch { return $false }
    }
    $true
}

# Return the size $Cpus and $Memory, as the VM's file holds them, as the log shows it.
function Format-PvmVmSize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Cpus,
        [AllowEmptyString()][string]$Memory
    )
    "$Cpus CPUs, $(if ($Memory) { "$Memory MB" } else { 'memory not set' })"
}

# Return the .vmx text $Text with numvcpus and cpuid.coresPerSocket set to $Cpus, one socket, and
# memsize to $MemoryMB, as Text, each value changed in place and a missing key added at the end,
# so that every other byte stays; or Problem, why it is left, when a key is set more than once or
# not as a quoted value.
function ConvertTo-PvmVmxSizeText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Cpus,
        [Parameter(Mandatory)][int64]$MemoryMB
    )
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $new = $Text
    foreach ($pair in @(@('numvcpus', "$Cpus"), @('cpuid.coresPerSocket', "$Cpus"), @('memsize', "$MemoryMB"))) {
        $key = [regex]::Escape($pair[0])
        $lines = @([regex]::Matches($new, '(?im)^[ \t]*' + $key + '[ \t]*='))
        if ($lines.Count -gt 1) { return [pscustomobject]@{ Text = ''; Problem = "the .vmx sets $($pair[0]) more than once" } }
        if ($lines.Count -eq 1) {
            $value = [regex]::Match($new, '(?im)^([ \t]*' + $key + '[ \t]*=[ \t]*)"[^"\r\n]*"')
            if (-not $value.Success) { return [pscustomobject]@{ Text = ''; Problem = "the .vmx sets $($pair[0]) in a form the launcher does not change" } }
            $start = $value.Index + $value.Groups[1].Length
            $new = $new.Remove($start, $value.Length - $value.Groups[1].Length).Insert($start, '"' + $pair[1] + '"')
        } else {
            if ($new.Length -and -not $new.EndsWith("`n")) { $new += $newline }
            $new += $pair[0] + ' = "' + $pair[1] + '"' + $newline
        }
    }
    [pscustomobject]@{ Text = $new; Problem = '' }
}

# Return the .vbox text $Text with the Machine's CPU count set to $Cpus and its RAMSize to
# $MemoryMB, as Text, the attributes changed or added in place so that every other byte stays; or
# Problem, why it is left: snapshots, whose hardware stays as it was saved; not one CPU and one
# Memory element; or more than one CPU with IOAPIC off, which VirtualBox refuses.
function ConvertTo-PvmVboxSizeText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Cpus,
        [Parameter(Mandatory)][int64]$MemoryMB
    )
    if ($Text -match '<Snapshot\b') { return [pscustomobject]@{ Text = ''; Problem = 'the .vbox holds snapshots, whose hardware the launcher leaves as it is' } }
    $cpu = @([regex]::Matches($Text, '<CPU\b[^>]*>'))
    $memory = @([regex]::Matches($Text, '<Memory\b[^>]*>'))
    if ($cpu.Count -ne 1 -or $memory.Count -ne 1) { return [pscustomobject]@{ Text = ''; Problem = 'the .vbox has no CPU or Memory element of its own' } }
    if ($Cpus -gt 1 -and $Text -notmatch '<IOAPIC\b[^>]*\benabled="true"') { return [pscustomobject]@{ Text = ''; Problem = 'IOAPIC is off in the .vbox, which more than one CPU needs' } }
    $new = $Text
    # The later element first, so that the earlier one's position stays.
    foreach ($tag in @(@($cpu[0], 'count', "$Cpus", '<CPU'), @($memory[0], 'RAMSize', "$MemoryMB", '<Memory')) | Sort-Object { $_[0].Index } -Descending) {
        $match = $tag[0]
        $attribute = [regex]::Match($match.Value, '\s' + $tag[1] + '="[^"]*"')
        $value = if ($attribute.Success) { $match.Value.Remove($attribute.Index, $attribute.Length).Insert($attribute.Index, ' ' + $tag[1] + '="' + $tag[2] + '"') }
        else { $match.Value.Insert($tag[3].Length, ' ' + $tag[1] + '="' + $tag[2] + '"') }
        $new = $new.Remove($match.Index, $match.Length).Insert($match.Index, $value)
    }
    [pscustomobject]@{ Text = $new; Problem = '' }
}

# Log the VM's size line and its notes, or why the size stays, to the log of $Context, for the size
# $Old in the VM's file and the size $Target (Get-PvmVmSizeTarget), unless $Why is given. Returns
# whether the file is to change.
function Write-PvmVmSizeLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [AllowEmptyString()][string]$Why = '',
        [AllowNull()]$Target,
        [AllowEmptyString()][string]$Old = '',
        [switch]$Same
    )
    $log = $Context.LogPath
    if ($Why) {
        Write-PvmLog -Path $log -Message "VM size left as it is, because $Why."
        return $false
    }
    $new = Format-PvmVmSize -Cpus "$($Target.Cpus)" -Memory "$($Target.MemoryMB)"
    if ($Same) { Write-PvmLog -Path $log -Message "VM size OK: $new" }
    else { Write-PvmLog -Path $log -Message "VM size: $Old -> $new $($Target.Detail)" }
    foreach ($note in @($Target.Notes)) { Write-PvmLog -Path $log -Message $note }
    -not $Same
}

# Return the change of the .vmx $Vmx that sets the VMware VM's size (Get-PvmVmSizeTarget), for
# Save-PvmFileChange, or $null, after logging the size or why it stays: VmSizing Off, a saved state
# that a resume needs as it is, VMware Workstation open, which can write its own copy of the .vmx
# back, this PC's numbers unknown, a .vmx the launcher does not change, or, when VMware keeps the
# VM's memory in a file beside the .vmx, too little free space for the larger size.
function Get-PvmVMwareSizeChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Vmx
    )
    $line = @{ Context = $Context }
    if ($Context.Settings['VmSizing'] -eq 'Off') { $null = Write-PvmVmSizeLine @line -Why 'VmSizing in settings.psd1 is Off'; return $null }
    if ($Context.VMwareState.State -eq 'Saved') { $null = Write-PvmVmSizeLine @line -Why 'the VM has a saved state, which needs the same hardware to resume'; return $null }
    if (@(Invoke-PvmGetProcess -Name 'vmware').Count) { $null = Write-PvmVmSizeLine @line -Why 'VMware Workstation is open and could write its own copy of the .vmx back'; return $null }
    $target = Get-PvmVmSizeTarget -Context $Context
    if ($target.Why) { $null = Write-PvmVmSizeLine @line -Why $target.Why; return $null }
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $bytes = [IO.File]::ReadAllBytes($Vmx)
    $text = $latin1.GetString($bytes)
    $values = ConvertFrom-PvmVmxText -Text $text
    $cpus = if ($values['numvcpus']) { $values['numvcpus'] } else { '1' }
    $old = Format-PvmVmSize -Cpus $cpus -Memory "$($values['memsize'])"
    if ($cpus -eq "$($target.Cpus)" -and $values['cpuid.corespersocket'] -eq "$($target.Cpus)" -and $values['memsize'] -eq "$($target.MemoryMB)") {
        $null = Write-PvmVmSizeLine @line -Target $target -Same
        return $null
    }
    $converted = ConvertTo-PvmVmxSizeText -Text $text -Cpus $target.Cpus -MemoryMB $target.MemoryMB
    if ($converted.Problem) { $null = Write-PvmVmSizeLine @line -Why $converted.Problem; return $null }
    [int64]$memory = 0
    $null = [int64]::TryParse("$($values['memsize'])", [ref]$memory)
    if ($target.MemoryMB -gt $memory -and "$($values['mainmem.usenamedfile'])" -ne 'FALSE') {
        $free = $null
        try { $free = Invoke-PvmGetFreeSpace -Path $Vmx } catch { $free = $null }
        if ($null -eq $free) { $null = Write-PvmVmSizeLine @line -Why 'the free space on the stick cannot be read'; return $null }
        if ($free -lt $target.MemoryMB * 1MB) { $null = Write-PvmVmSizeLine @line -Why 'the stick has too little free space for VMware''s memory file of the larger size'; return $null }
    }
    $copies = @{ Root = $Context.Root; Backups = $Context.Backups; Path = $Vmx }
    $previous = Get-PvmBackupPath @copies -Suffix '.previous.launcher-backup'
    if (-not (Test-PvmRewritable -Path $Vmx, $previous)) { $null = Write-PvmVmSizeLine @line -Why 'the .vmx, or its copy below LauncherData\backups, is read-only or a link, which the launcher does not rewrite'; return $null }
    $null = Write-PvmVmSizeLine @line -Target $target -Old $old
    [pscustomobject]@{
        Path = $Vmx; Old = $bytes; New = $latin1.GetBytes($converted.Text); FirstBackup = (Get-PvmBackupPath @copies -Suffix '.launcher-backup'); PreviousBackup = $previous
        Disarm = $false; Action = 'Set the VM''s CPUs and memory'
    }
}

# Return the change $Change of the .vbox $Vbox (Get-PvmDriveLetterChange, or $null) with the
# VirtualBox VM's size (Get-PvmVmSizeTarget) set too, as one write with the copies $BackupPath and
# $PreviousPath, or $Change as it is, after logging the size or why it stays: VmSizing Off, a saved
# state, this PC's numbers unknown, or a .vbox the launcher does not change
# (ConvertTo-PvmVboxSizeText). VirtualBox and its background service are closed by then.
function Add-PvmVirtualBoxSizeChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Vbox,
        [AllowNull()]$Change,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$PreviousPath
    )
    $line = @{ Context = $Context }
    if ($Context.Settings['VmSizing'] -eq 'Off') { $null = Write-PvmVmSizeLine @line -Why 'VmSizing in settings.psd1 is Off'; return $Change }
    if ($Context.VirtualBoxState.State -eq 'Saved') { $null = Write-PvmVmSizeLine @line -Why 'the VM has a saved state, which needs the same hardware to resume'; return $Change }
    $target = Get-PvmVmSizeTarget -Context $Context
    if ($target.Why) { $null = Write-PvmVmSizeLine @line -Why $target.Why; return $Change }
    $strict = New-Object System.Text.UTF8Encoding $false, $true
    $bytes = if ($null -ne $Change) { $Change.New } else { [IO.File]::ReadAllBytes($Vbox) }
    try { $text = $strict.GetString($bytes) }
    catch { $null = Write-PvmVmSizeLine @line -Why 'the .vbox is not UTF-8 text, as VirtualBox writes it'; return $Change }
    $cpuTag = [regex]::Match($text, '<CPU\b[^>]*>')
    $count = [regex]::Match($cpuTag.Value, '\scount="([^"]*)"')
    $cpus = if ($count.Success) { $count.Groups[1].Value } else { '1' }
    $ram = [regex]::Match([regex]::Match($text, '<Memory\b[^>]*>').Value, '\sRAMSize="([^"]*)"')
    $memory = if ($ram.Success) { $ram.Groups[1].Value } else { '' }
    if ($cpus -eq "$($target.Cpus)" -and $memory -eq "$($target.MemoryMB)") { $null = Write-PvmVmSizeLine @line -Target $target -Same; return $Change }
    $converted = ConvertTo-PvmVboxSizeText -Text $text -Cpus $target.Cpus -MemoryMB $target.MemoryMB
    if ($converted.Problem) { $null = Write-PvmVmSizeLine @line -Why $converted.Problem; return $Change }
    # A drive-letter change has checked that both files may be rewritten.
    if ($null -eq $Change -and -not (Test-PvmRewritable -Path $Vbox, $PreviousPath)) {
        $null = Write-PvmVmSizeLine @line -Why 'the .vbox, or its copy below LauncherData\backups, is read-only or a link, which the launcher does not rewrite'
        return $Change
    }
    $null = Write-PvmVmSizeLine @line -Target $target -Old (Format-PvmVmSize -Cpus $cpus -Memory $memory)
    if ($null -ne $Change) {
        $Change.New = $strict.GetBytes($converted.Text)
        $Change.Action = "$($Change.Action), and set the VM's CPUs and memory"
        return $Change
    }
    [pscustomobject]@{
        Path = $Vbox; Old = $bytes; New = $strict.GetBytes($converted.Text); FirstBackup = $BackupPath; PreviousBackup = $PreviousPath
        Disarm = $false; Action = 'Set the VM''s CPUs and memory'
    }
}

# --- Hypervisor choice -----------------------------------------------------------------------

# Return the VMware Workstation folder from the registry, the native key first, as a 64-bit
# installation writes it, or $null when no key names a folder that holds vmware.exe.
function Get-PvmVMwareDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($key in 'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation', 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation') {
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

# Return whether the program $Path of $Program ('VMware' or 'VirtualBox') is signed by its maker,
# as Signed, and Why not, in words that end a sentence: Windows does not trust its signature, it is
# signed by another publisher, or Windows could not read the signature. The launcher runs it with
# administrator rights, so a program put in its place must not run.
function Test-PvmSignedProgram {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('VMware', 'VirtualBox')][string]$Program,
        [Parameter(Mandatory)][string]$Path
    )
    # The common names in the makers' certificates; VMware Workstation is Broadcom's since 2023.
    $makers = if ($Program -eq 'VMware') { @('VMware, Inc.', 'Broadcom Inc', 'Broadcom Inc.') } else { @('Oracle America, Inc.', 'Oracle Corporation') }
    try { $signature = Invoke-PvmGetSignature -Path $Path }
    catch { return [pscustomobject]@{ Signed = $false; Why = 'Windows could not read its signature' } }
    if ($signature.Status -ne 'Valid') { return [pscustomobject]@{ Signed = $false; Why = "Windows reports its signature as $($signature.Status)" } }
    if ($makers -notcontains $signature.Signer) { return [pscustomobject]@{ Signed = $false; Why = "it is signed by $($signature.Signer)" } }
    [pscustomobject]@{ Signed = $true; Why = '' }
}

# Return what a start needs to know of this PC and the VM before it chooses, read once, as
# $Context describes them (Invoke-PvmLaunch reads the saved states into it first): each program's
# folder (Get-PvmVMwareDir, Get-PvmVirtualBoxDir), whether it is signed by its maker and why not,
# the two saved states, whether the .vmx is there, and whether the VM runs in either program. It
# runs no VirtualBox program, which would start VirtualBox's background service.
function Get-PvmStartSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $settings = $Context.Settings
    $vmwareDir = Get-PvmVMwareDir
    $virtualBoxDir = Get-PvmVirtualBoxDir
    $vmx = Join-PvmStickPath -Root $Context.Root -Path $settings['VMwareVmx']
    $vmware = if ($vmwareDir) { Test-PvmSignedProgram -Program 'VMware' -Path (Join-Path $vmwareDir 'vmware.exe') } else { [pscustomobject]@{ Signed = $false; Why = '' } }
    $virtualBox = if ($virtualBoxDir) { Test-PvmSignedProgram -Program 'VirtualBox' -Path (Join-Path $virtualBoxDir 'VBoxManage.exe') } else { [pscustomobject]@{ Signed = $false; Why = '' } }
    [pscustomobject]@{
        VMwareDir           = $vmwareDir
        VirtualBoxDir       = $virtualBoxDir
        VMwareSigned        = $vmware.Signed
        VMwareWhy           = $vmware.Why
        VirtualBoxSigned    = $virtualBox.Signed
        VirtualBoxWhy       = $virtualBox.Why
        VMwareSaved         = $Context.VMwareState.State -eq 'Saved'
        VirtualBoxSaved     = $Context.VirtualBoxState.State -eq 'Saved'
        VmxExists           = Test-Path -LiteralPath $vmx
        RunningInVMware     = Test-PvmRunningInVMware -Vmx $vmx
        RunningInVirtualBox = Test-PvmRunningInVirtualBox -VmUuid $Context.VmFiles.VirtualBoxVmUuid
    }
}

# Return the start decision for the snapshot $Snapshot (Get-PvmStartSnapshot) and the Hypervisor
# setting $Setting, as kinds that name no file: Use, the program to start (Select-PvmHypervisor);
# Stop, a stop that ends a dry run too, or '': BothSaved (saved states in both programs, of which
# the launcher resumes neither), VMwareNotInstalled, VirtualBoxNotInstalled (named in the setting
# while VMware is installed) or NoneInstalled; AlreadyRunning, when the VM runs in VMware and VMware
# is the one to use; and Stops, the stops a dry run logs and carries on past, in this order:
# Unsigned, then for VMware VirtualBoxVmRunning and VirtualBoxSaved, for VirtualBox VMwareRunning
# and VMwareSaved. Whether VirtualBox runs the VM, VirtualBox itself is asked later.
function Get-PvmStartDecision {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][string]$Setting = '',
        [Parameter(Mandatory)][pscustomobject]$Snapshot
    )
    if ($Snapshot.VMwareSaved -and $Snapshot.VirtualBoxSaved) {
        return [pscustomobject]@{ Use = ''; Stop = 'BothSaved'; AlreadyRunning = $false; Stops = @() }
    }
    $choice = @{
        Setting = $Setting; VMwareInstalled = [bool]$Snapshot.VMwareDir; VirtualBoxInstalled = [bool]$Snapshot.VirtualBoxDir
        VMwareSuspended = $Snapshot.VMwareSaved; VirtualBoxSaved = $Snapshot.VirtualBoxSaved; VMwareVmxExists = $Snapshot.VmxExists
    }
    $use = Select-PvmHypervisor @choice
    $stop = ''
    if ($use -eq 'VMware' -and -not $Snapshot.VMwareDir) { $stop = 'VMwareNotInstalled' }
    elseif ($use -eq 'VirtualBox' -and -not $Snapshot.VirtualBoxDir) { $stop = if ($Snapshot.VMwareDir) { 'VirtualBoxNotInstalled' } else { 'NoneInstalled' } }
    if ($stop) { return [pscustomobject]@{ Use = $use; Stop = $stop; AlreadyRunning = $false; Stops = @() } }
    if ($use -eq 'VMware' -and $Snapshot.RunningInVMware) { return [pscustomobject]@{ Use = $use; Stop = ''; AlreadyRunning = $true; Stops = @() } }
    $stops = New-Object System.Collections.Generic.List[string]
    if ($use -eq 'VMware') {
        if (-not $Snapshot.VMwareSigned) { $stops.Add('Unsigned') }
        if ($Snapshot.RunningInVirtualBox) { $stops.Add('VirtualBoxVmRunning') }
        if ($Snapshot.VirtualBoxSaved) { $stops.Add('VirtualBoxSaved') }
    } else {
        if (-not $Snapshot.VirtualBoxSigned) { $stops.Add('Unsigned') }
        if ($Snapshot.RunningInVMware) { $stops.Add('VMwareRunning') }
        if ($Snapshot.VMwareSaved) { $stops.Add('VMwareSaved') }
    }
    [pscustomobject]@{ Use = $use; Stop = ''; AlreadyRunning = $false; Stops = $stops.ToArray() }
}

# Return which program's saved state, as $Context's VMwareState and VirtualBoxState name its file,
# was written last: 'VMware' or 'VirtualBox', or '' when a file is not there or both have the
# same time.
function Get-PvmNewerSave {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $settings = $Context.Settings
    $vmx = Join-PvmStickPath -Root $Context.Root -Path $settings['VMwareVmx']
    $vbox = Join-PvmStickPath -Root $Context.Root -Path $settings['VirtualBoxVbox']
    # VirtualBox on Windows writes the name with backslashes, which .NET elsewhere reads as part of
    # a file name, so either slash counts as this system's separator.
    $separator = [string][IO.Path]::DirectorySeparatorChar
    $names = @("$($Context.VMwareState.Values['checkpoint.vmstate'])", "$($Context.VirtualBoxState.StateFile)" | ForEach-Object { $_.Replace('\', $separator).Replace('/', $separator) })
    if (-not $names[0] -or -not $names[1]) { return '' }
    # A relative name lies beside its .vmx or .vbox; Combine keeps a name with a root as it is. A
    # name that is no path only means the launcher cannot tell.
    try {
        $files = @([IO.Path]::Combine((Split-Path $vmx), $names[0]), [IO.Path]::Combine((Split-Path $vbox), $names[1]))
        if (-not ([IO.File]::Exists($files[0]) -and [IO.File]::Exists($files[1]))) { return '' }
        $times = @($files | ForEach-Object { [IO.File]::GetLastWriteTimeUtc($_) })
    } catch {
        return ''
    }
    if ($times[0] -gt $times[1]) { return 'VMware' }
    if ($times[1] -gt $times[0]) { return 'VirtualBox' }
    ''
}

# Return the message for the kind $Kind of a start decision (Get-PvmStartDecision) for the program
# $Use, naming the VM as $Context says, with why a program is not trusted from $Snapshot.
function Get-PvmDecisionMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][pscustomobject]$Snapshot,
        [AllowEmptyString()][string]$Use = ''
    )
    $names = $Context.Names
    switch ($Kind) {
        'BothSaved' {
            $newer = switch (Get-PvmNewerSave -Context $Context) {
                'VMware' { 'The one in VMware is newer.' }
                'VirtualBox' { 'The one in VirtualBox is newer.' }
                default { 'The launcher cannot tell which one is newer.' }
            }
            return Format-PvmMessage -Names $names -Template "{VM} has a saved state in VMware and one in VirtualBox, and only one of them can match {guest}'s disk; resuming the other can corrupt it. {Newer} Discard the saved state you do not want in the program that holds it (in VirtualBox: Discard Saved State), then start {vm} again. The launcher discards neither. Nothing was started." -Values @{ Newer = $newer }
        }
        'VMwareNotInstalled' { return 'VMware Workstation is not installed on this PC.' }
        'VirtualBoxNotInstalled' {
            if ($Context.Settings['Hypervisor'] -eq 'VirtualBox') { return "VirtualBox is not installed on this PC, and Hypervisor in settings.psd1 is 'VirtualBox'. Install VirtualBox, or set Hypervisor to 'Auto' to use VMware Workstation." }
            # Otherwise VMware was passed over because its .vmx is missing.
            $vmx = Join-PvmStickPath -Root $Context.Root -Path $Context.Settings['VMwareVmx']
            return Format-PvmMessage -Names $names -Template 'VirtualBox is not installed on this PC, and VMware Workstation cannot start {vm}, since its .vmx is missing: VMwareVmx in settings.psd1 names {Path}.' -Values @{ Path = $vmx }
        }
        'NoneInstalled' { return 'Neither VMware Workstation nor VirtualBox is installed on this PC.' }
        'Unsigned' {
            $program = if ($Use -eq 'VMware') { @{ Program = 'VMware Workstation'; File = 'vmware.exe'; Why = $Snapshot.VMwareWhy } } else { @{ Program = 'VirtualBox'; File = 'VBoxManage.exe'; Why = $Snapshot.VirtualBoxWhy } }
            return Format-PvmMessage -Names $names -Template "{Program}'s {File} is not signed by its maker: {Why}. The launcher would run it with administrator rights, so it starts nothing. Reinstall {Program} from its maker, then start {vm} again." -Values $program
        }
        'VirtualBoxVmRunning' { return Format-PvmMessage -Names $names -Template 'A VirtualBox VM is running, possibly this one. Close it before starting {vm} in VMware - the stick must never be used by two VMs at once.' }
        'VirtualBoxSaved' { return Format-PvmMessage -Names $names -Template '{VM} has a saved state in VirtualBox. Resume it in VirtualBox (on a PC with VirtualBox) and shut {guest} down normally before starting it in VMware - otherwise {guest}''s disk can get corrupted.' }
        'VMwareRunning' { return Format-PvmMessage -Names $names -Template '{VM} is running in VMware. Close it before starting it in VirtualBox.' }
        'VMwareSaved' { return Format-PvmMessage -Names $names -Template '{VM} is suspended in VMware. Resume it in VMware (on a PC with VMware Workstation) and shut {guest} down normally before starting it in VirtualBox - otherwise {guest}''s disk can get corrupted.' }
    }
    throw "Unknown kind of start decision: $Kind"
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
# $Context and its Settings describe, with the layout a VirtualBox start gives too
# (Get-PvmStartLayout): the Data partition blanked, since VMware takes every Windows volume in the
# disk area it gives the VM away from Windows while the VM runs, and cannot do that for the Data
# partition, which holds the VM's own files. Returns 'AlreadyRunning', 'DryRun' or 'Started';
# throws a stop.
function Invoke-PvmVMware {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$VMwareDir,
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][pscustomobject]$Decision,
        [Parameter(Mandatory)][pscustomobject]$Snapshot
    )
    Enter-PvmStep -Context $Context -Name 'checks'
    $settings = $Context.Settings
    $log = $Context.LogPath
    $vmx = Join-PvmStickPath -Root $Context.Root -Path $settings['VMwareVmx']
    if ($Decision.AlreadyRunning) {
        Write-PvmLog -Path $log -Message 'Already running in VMware.'
        return 'AlreadyRunning'
    }
    foreach ($kind in $Decision.Stops) { Invoke-PvmStopUnlessDryRun -Context $Context -Message (Get-PvmDecisionMessage -Kind $kind -Context $Context -Snapshot $Snapshot -Use 'VMware') }
    if ($Context.VmFiles.VMwareProblem) { Invoke-PvmStopUnlessDryRun -Context $Context -Message $Context.VmFiles.VMwareProblem }
    foreach ($problem in @(Get-PvmMountedStop -Context $Context -Disk $Context.StickDisk -Program 'VMware')) { Invoke-PvmStopUnlessDryRun -Context $Context -Message $problem }
    $layout = Get-PvmStartLayout -Context $Context -Drive $Drive
    Assert-PvmVMwareReady -Context $Context -Vmx $vmx

    Enter-PvmStep -Context $Context -Name 'files'
    Assert-PvmStickUnchanged -Context $Context
    # The VM's size (request r9), in the .vmx.
    $size = Get-PvmVMwareSizeChange -Context $Context -Vmx $vmx
    if ($null -ne $size) { Save-PvmFileChange -Change $size -LogPath $log -WhatIf:$Context.DryRun }
    # The disk file the .vmx attaches (Resolve-PvmVMwareFile); a dry run that found none has
    # nothing to point at the stick.
    $disk = $Context.VmFiles.VMwareDisk
    if (-not $disk) {
        Write-PvmLog -Path $log -Message 'DRY RUN - no VMware disk file to point at the stick'
    } elseif ([IO.File]::Exists($disk)) {
        $copies = @{ Root = $Context.Root; Backups = $Context.Backups; Path = $disk }
        $change = Get-PvmDescriptorChange -Path $disk -Layout $layout -BackupPath (Get-PvmBackupPath @copies -Suffix '.orig') -PreviousPath (Get-PvmBackupPath @copies -Suffix '.previous.orig') -LogPath $log
        if ($null -ne $change) { Save-PvmFileChange -Change $change -LogPath $log -WhatIf:$Context.DryRun }
    } else {
        New-PvmVMwareDescriptor -Path $disk -Layout $layout -LogPath $log -AdapterType $Context.VmFiles.VMwareAdapter -WhatIf:$Context.DryRun
    }
    Enter-PvmStep -Context $Context -Name 'start'
    if ($Context.DryRun) {
        Write-PvmLog -Path $log -Message "DRY RUN - would start $vmx with VMware Workstation ($VMwareDir)"
        return 'DryRun'
    }

    $copies = @{ Root = $Context.Root; Backups = $Context.Backups; Path = $disk }
    try { Start-PvmVMwareVm -VMwareDir $VMwareDir -Vmx $vmx -View $settings['VMwareView'] -LogPath $log }
    catch {
        $null = Invoke-PvmDisarm -Context $Context -Disk $disk -Copies $copies -Quiet
        throw
    }
    Watch-PvmVm -Context $Context -Program 'VMware' -Vmx $vmx -Disk $disk -Copies $copies
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

# Return what the VM state $State (Get-PvmVirtualBoxVmState, with or without its quotes) means for
# a start: 'Running' when the VM runs or is on its way there, 'Busy' while VirtualBox saves, stops,
# moves or snapshots it, 'Stuck' when it hangs, 'Off' when it can start, or 'Unknown' for any other
# state, also none.
function Get-PvmVirtualBoxActivity {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$State = '')
    $word = $State.Trim().Trim('"')
    if (@('running', 'paused', 'starting', 'restoring') -contains $word) { return 'Running' }
    if (@('saving', 'stopping', 'snapshotting', 'livesnapshotting', 'onlinesnapshotting', 'teleporting', 'teleportingpausedvm', 'teleportingin',
            'deletingsnapshot', 'deletingsnapshotlive', 'deletingsnapshotlivepaused', 'restoringsnapshot', 'settingup') -contains $word) { return 'Busy' }
    if (@('stuck', 'gurumeditation') -contains $word) { return 'Stuck' }
    if (@('poweroff', 'saved', 'aborted', 'aborted-saved') -contains $word) { return 'Off' }
    'Unknown'
}

# Return the stop message for the VM in the VirtualBox state $State when its activity
# (Get-PvmVirtualBoxActivity) is Busy, Stuck or Unknown, naming the VM as $Names says.
function Get-PvmVirtualBoxStateMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$State = '',
        [Parameter(Mandatory)][hashtable]$Names
    )
    $word = $State.Trim().Trim('"')
    $template = switch (Get-PvmVirtualBoxActivity -State $State) {
        'Busy' { 'VirtualBox is still busy with {vm} ({State}). Wait until it is done, then start {vm} again.' }
        'Stuck' { 'VirtualBox reports {vm} as stuck ({State}). Power it off in VirtualBox, then start {vm} again.' }
        default { 'VirtualBox reports a state of {vm} that the launcher does not know ({State}). Close VirtualBox, then start {vm} again.' }
    }
    Format-PvmMessage -Names $Names -Template $template -Values @{ State = $word }
}

# Start the VirtualBox VM $VmUuid with VBoxManage at $VBoxManage and log to $LogPath which version
# of VirtualBox started it. Throws a stop with VBoxManage's output when the start fails, naming
# the VM as $Names says (Format-PvmMessage).
function Start-PvmVirtualBoxVm {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VmUuid,
        [Parameter(Mandatory)][hashtable]$Names,
        [Parameter(Mandatory)][string]$LogPath
    )
    if (-not $PSCmdlet.ShouldProcess($VmUuid, 'Start the VM in VirtualBox')) { return }
    $start = Invoke-PvmNative -FilePath $VBoxManage -ArgumentList @('startvm', $VmUuid, '--type', 'gui')
    if ($start.ExitCode -ne 0) {
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $Names -Template "VirtualBox could not start {vm}:`n`n{Output}" -Values @{ Output = $start.Output }))
    }
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
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][pscustomobject]$Decision,
        [Parameter(Mandatory)][pscustomobject]$Snapshot
    )
    Enter-PvmStep -Context $Context -Name 'checks'
    $settings = $Context.Settings
    $log = $Context.LogPath
    $vboxManage = Join-Path $VirtualBoxDir 'VBoxManage.exe'
    $uuid = $Context.VmFiles.VirtualBoxVmUuid
    Invoke-PvmSetEnvironment -Name 'VBOX_USER_HOME' -Value (Join-PvmStickPath -Root $Context.Root -Path $settings['VirtualBoxHome'])
    $names = $Context.Names
    foreach ($kind in $Decision.Stops) { Invoke-PvmStopUnlessDryRun -Context $Context -Message (Get-PvmDecisionMessage -Kind $kind -Context $Context -Snapshot $Snapshot -Use 'VirtualBox') }
    if ($Context.VmFiles.VirtualBoxProblem) { Invoke-PvmStopUnlessDryRun -Context $Context -Message $Context.VmFiles.VirtualBoxProblem }
    foreach ($problem in @(Get-PvmVirtualBoxStorageProblem -Context $Context -Disk $Context.StickDisk)) { Invoke-PvmStopUnlessDryRun -Context $Context -Message $problem }
    $layout = Get-PvmStartLayout -Context $Context -Drive $Drive
    $open = @(Invoke-PvmGetProcess -Name 'VirtualBox', 'VirtualBoxVM', 'VBoxHeadless')
    if ($open.Count) {
        # VirtualBox hides its VM processes' command lines, so VirtualBox is asked whether this VM is
        # the one running; a VBoxManage not signed by its maker is not run, also in a dry run.
        $state = ''
        $activity = 'Unknown'
        if ($Snapshot.VirtualBoxSigned) {
            $info = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('showvminfo', $uuid, '--machinereadable')
            if ($info.ExitCode -eq 0) {
                $state = "$(Get-PvmVirtualBoxVmState -Output $info.Output)"
                $activity = Get-PvmVirtualBoxActivity -State $state
            }
        }
        if ($activity -eq 'Running') {
            Write-PvmLog -Path $log -Message 'Already running in VirtualBox.'
            return 'AlreadyRunning'
        }
        $message = if ($activity -eq 'Busy' -or $activity -eq 'Stuck') { Get-PvmVirtualBoxStateMessage -State $state -Names $names }
        else { Format-PvmMessage -Names $names -Template 'VirtualBox is already open on this PC. Close all VirtualBox windows, then start {vm} again.' }
        Invoke-PvmStopUnlessDryRun -Context $Context -Message $message
    }
    # A real start waits for VirtualBox's background service, so a dry run does too, unless it has
    # found a stop already, at which a real start would have ended before the wait.
    if (-not $Context.WouldStop -and (Invoke-PvmTestProcess -Name 'VBoxSVC')) {
        Enter-PvmStep -Context $Context -Name 'wait'
        Write-PvmLog -Path $log -Message "Waiting up to 30 s for VirtualBox's background service (VBoxSVC) to end"
        Wait-PvmProcessExit -Name 'VBoxSVC' -TimeoutSeconds 30
        Enter-PvmStep -Context $Context -Name 'checks'
    }
    if (Invoke-PvmTestProcess -Name 'VBoxSVC') {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message (Format-PvmMessage -Names $names -Template "VirtualBox's background service (VBoxSVC) is still running in this Windows session. Close every VirtualBox window, wait until it has ended, which can take a few minutes, then start {vm} again.")
    }

    # The launcher records no VirtualBox save yet, so every saved state asks before it is resumed,
    # after the checks that can still stop the start and before the first write.
    if ($Context.VirtualBoxState.State -eq 'Saved') {
        $question = Format-PvmMessage -Names $names -Template "{VM} has a saved state in VirtualBox that this launcher did not record. Resume it only if the stick has not been booted any other way since the save; otherwise the resume can corrupt {guest}'s disk.`n`nResume {vm} now?"
        Confirm-PvmResume -Context $Context -Program 'VirtualBox' -Question $question
    }

    Enter-PvmStep -Context $Context -Name 'files'
    Assert-PvmStickUnchanged -Context $Context
    $vbox = Join-PvmStickPath -Root $Context.Root -Path $settings['VirtualBoxVbox']
    $registry = Join-Path (Join-PvmStickPath -Root $Context.Root -Path $settings['VirtualBoxHome']) 'VirtualBox.xml'
    # The disk file the .vbox attaches (Resolve-PvmVirtualBoxFile); a dry run that found none has
    # nothing to point at the stick.
    $disk = $Context.VmFiles.VirtualBoxDisk
    if (-not $disk) { Write-PvmLog -Path $log -Message 'DRY RUN - no VirtualBox disk file to point at the stick' }
    $backup = @{ Root = $Context.Root; Backups = $Context.Backups }
    # At a drive root the paths to the VM's own files show the stick's old letter. The location
    # gives the stick folder as Windows spells it, which on Windows is $Context.Root.
    $letters = @{ Root = $Context.Location.Path; Letter = $Context.Location.Letter; Known = @(@($vbox, $disk) | Where-Object { $_ }); LogPath = $log }
    # Every file is checked first, so that a refusal leaves all of them as they are.
    # The VM's size (request r9) goes into the same write of the .vbox as its drive letters.
    $vboxCopies = @{ BackupPath = (Get-PvmBackupPath @backup -Path $vbox -Suffix '.launcher-backup'); PreviousPath = (Get-PvmBackupPath @backup -Path $vbox -Suffix '.previous.launcher-backup') }
    $vboxChange = Get-PvmDriveLetterChange -Path $vbox @vboxCopies @letters
    $vboxChange = Add-PvmVirtualBoxSizeChange -Context $Context -Vbox $vbox -Change $vboxChange @vboxCopies
    $changes = @(@(
            $vboxChange
            Get-PvmDriveLetterChange -Path $registry -BackupPath (Get-PvmBackupPath @backup -Path $registry -Suffix '.launcher-backup') -PreviousPath (Get-PvmBackupPath @backup -Path $registry -Suffix '.previous.launcher-backup') @letters
            if ($disk) { Get-PvmDescriptorChange -Path $disk -Layout $layout -BackupPath (Get-PvmBackupPath @backup -Path $disk -Suffix '.orig') -PreviousPath (Get-PvmBackupPath @backup -Path $disk -Suffix '.previous.orig') -LogPath $log }
        ) | Where-Object { $null -ne $_ })
    foreach ($change in $changes) { Save-PvmFileChange -Change $change -LogPath $log -WhatIf:$Context.DryRun }
    Enter-PvmStep -Context $Context -Name 'start'
    if ($Context.DryRun) {
        Write-PvmLog -Path $log -Message "DRY RUN - would start VM {$uuid} with VirtualBox ($VirtualBoxDir)"
        return 'DryRun'
    }

    # From here a stop leaves no disk file pointed at the stick.
    $copies = @{ Root = $Context.Root; Backups = $Context.Backups; Path = $disk }
    try { $started = Invoke-PvmVirtualBoxStart -Context $Context -VBoxManage $vboxManage -VmUuid $uuid }
    catch {
        $null = Invoke-PvmDisarm -Context $Context -Disk $disk -Copies $copies -Quiet
        throw
    }
    # A VM that VirtualBox says runs already, started in the seconds since the checks, runs from
    # the armed file too, so it is watched as well.
    if ($started -eq 'AlreadyRunning') { Write-PvmLog -Path $log -Message 'Already running in VirtualBox.' }
    Watch-PvmVm -Context $Context -Program 'VirtualBox' -Disk $disk -Copies $copies
    'Started'
}

# Ask VirtualBox at $VBoxManage once more whether it lists the VM $VmUuid and in which state, as
# $Context describes, and start it (Start-PvmVirtualBoxVm). Returns 'Started', or 'AlreadyRunning'
# when VirtualBox says the VM runs; throws a stop when VirtualBox cannot list or read it, or the
# VM is in a state it cannot start from.
function Invoke-PvmVirtualBoxStart {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$VBoxManage,
        [Parameter(Mandatory)][string]$VmUuid
    )
    $vboxManage = $VBoxManage
    $uuid = $VmUuid
    $names = $Context.Names
    $log = $Context.LogPath
    $list = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('list', 'vms')
    if ($list.ExitCode -ne 0) {
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $names -Template "VirtualBox could not list its VMs:`n`n{Output}" -Values @{ Output = $list.Output }))
    }
    $listing = Get-PvmVirtualBoxListing -Output $list.Output -VmUuid $uuid
    if ($listing -eq 'Inaccessible') {
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $names -Template "VirtualBox lists {vm} as inaccessible, so it cannot read {vm}'s .vbox file. Open VirtualBox to see why, then start {vm} again."))
    }
    if ($listing -eq 'Missing') {
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $names -Template "VirtualBox did not find {vm} in the stick's VM list:`n`n{Output}" -Values @{ Output = $list.Output }))
    }
    $info = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('showvminfo', $uuid, '--machinereadable')
    if ($info.ExitCode -ne 0) {
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $names -Template "VirtualBox could not tell {vm}'s state:`n`n{Output}" -Values @{ Output = $info.Output }))
    }
    $state = Get-PvmVirtualBoxVmState -Output $info.Output
    Write-PvmLog -Path $log -Message "VirtualBox VM state: $state"
    $activity = Get-PvmVirtualBoxActivity -State "$state"
    if ($activity -eq 'Running') { return 'AlreadyRunning' }
    if ($activity -ne 'Off') { throw (Get-PvmStopException -Message (Get-PvmVirtualBoxStateMessage -State "$state" -Names $names)) }
    Start-PvmVirtualBoxVm -VBoxManage $vboxManage -VmUuid $uuid -Names $names -LogPath $log
    'Started'
}

# --- Arm, verify, watch -----------------------------------------------------------------------
# At rest both disk files name the disarmed device (Get-PvmDisarmedDevice), so a VM started from a
# program's own window, or with another disk in the stick's place, finds no disk. A start reads
# the stick's identity once more (Assert-PvmStickUnchanged), arms the disk file of the program it
# starts (Get-PvmDescriptorChange), checks that the VM runs, waits while it runs and disarms the
# file again (Watch-PvmVm). A start that stops after the arm disarms the file before it ends.

# Read the stick's identity once more, right before a disk file is pointed at it: the drive the
# launcher runs from must still be on the disk $Context found, and that disk must still be the
# configured stick (Get-PvmStickProblem). Throws a stop, before any write, when either changed.
function Assert-PvmStickUnchanged {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $stick = Get-PvmStickDevice -Location $Context.Location -Names $Context.Names
    $problem = if ($stick.Disk.Number -ne $Context.StickDisk.Number) { "the drive {Letter}: is on disk $($stick.Disk.Number) now, not on disk $($Context.StickDisk.Number)" }
    else { Get-PvmStickProblem -Disk $stick.Disk -Partition $stick.Partition -Settings $Context.Settings }
    if ($problem) {
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $Context.Names -Values @{ Letter = $Context.Location.Letter; Problem = $problem } -Template (
                    "The stick changed while the launcher checked it, so no disk file was pointed at it. {Problem}`n`nNothing was started.")))
    }
}

# Prepare pointing the descriptor $Path away from the stick: every FLAT extent that names a raw
# device names the disarmed device instead (ConvertTo-PvmDisarmedDescriptorText), and every other
# byte stays. Returns the change for Save-PvmFileChange, with the copies $BackupPath and
# $PreviousPath, or $null when the file is missing or names no raw device any more.
function Get-PvmDisarmChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$PreviousPath,
        [Parameter(Mandatory)][string]$LogPath
    )
    if (-not [IO.File]::Exists($Path)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = ConvertFrom-PvmDescriptorData -Bytes $bytes
    $new = ConvertTo-PvmDisarmedDescriptorText -Text $text
    if ($new -ceq $text) { return $null }
    Write-PvmLog -Path $LogPath -Message "$([IO.Path]::GetFileName($Path)): pointed away from the stick"
    [pscustomobject]@{
        Path           = $Path
        Old            = $bytes
        New            = [Text.Encoding]::GetEncoding(28591).GetBytes($new)
        FirstBackup    = $BackupPath
        PreviousBackup = $PreviousPath
        Disarm         = $true
        Action         = 'Point the raw-disk descriptor away from the stick'
    }
}

# Point the disk file $Disk away from the stick (Get-PvmDisarmChange) through the safe write, with
# its copies $Copies (Root, Backups, Path for Get-PvmBackupPath), as $Context describes. Returns
# $true when the file names no raw device now. With -Quiet a failure only goes to the log, as a
# note, and returns $false; otherwise it throws a stop that says the VM has ended and the file
# still points at the stick.
function Invoke-PvmDisarm {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Disk,
        [Parameter(Mandatory)][hashtable]$Copies,
        [switch]$Quiet
    )
    $log = $Context.LogPath
    try {
        $change = Get-PvmDisarmChange -Path $Disk -BackupPath (Get-PvmBackupPath @Copies -Suffix '.orig') -PreviousPath (Get-PvmBackupPath @Copies -Suffix '.previous.orig') -LogPath $log
        if ($null -ne $change) { Save-PvmFileChange -Change $change -LogPath $log }
        $true
    } catch {
        $cause = Get-PvmStopMessage -ErrorRecord $_
        if (-not $cause) { $cause = Get-PvmErrorText -ErrorRecord $_ }
        $name = [IO.Path]::GetFileName($Disk)
        if ($Quiet) {
            Write-PvmLog -Path $log -Message "Note: $name could not be pointed away from the stick: $cause"
            return $false
        }
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $Context.Names -Values @{ Name = $name; Cause = $cause } -Template (
                    "{VM} has ended, but the launcher could not point {Name} away from the stick, so it still names the stick's disk. The next start sets it right.`n`n{Cause}")))
    }
}

# Return whether the VM runs in $Program, as $Context describes: in VMware a vmware-vmx process for
# its .vmx $Vmx (Test-PvmRunningInVMware), in VirtualBox a VM process for its UUID
# (Test-PvmRunningInVirtualBox).
function Test-PvmVmRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][ValidateSet('VMware', 'VirtualBox')][string]$Program,
        [string]$Vmx
    )
    if ($Program -eq 'VMware') { return (Test-PvmRunningInVMware -Vmx $Vmx) }
    Test-PvmRunningInVirtualBox -VmUuid $Context.VmFiles.VirtualBoxVmUuid
}

# Return whether the VM runs in $Program (Test-PvmVmRunning, with $Context and $Vmx), or $Assume
# when the check fails, as with a process list that Windows cannot give for a moment. The first
# failure of a row goes to the log as a note; $Row.Failures counts the row, and $Row.Cause holds
# its last cause.
function Test-PvmVmRunningOrAssume {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][ValidateSet('VMware', 'VirtualBox')][string]$Program,
        [string]$Vmx,
        [Parameter(Mandatory)][bool]$Assume,
        [Parameter(Mandatory)][hashtable]$Row
    )
    try {
        $running = Test-PvmVmRunning -Context $Context -Program $Program -Vmx $Vmx
        $Row.Failures = 0
        $running
    } catch {
        $Row.Failures = [int]$Row.Failures + 1
        $Row.Cause = Get-PvmErrorText -ErrorRecord $_
        if ($Row.Failures -eq 1) {
            Write-PvmLog -Path $Context.LogPath -Message "Note: the launcher could not check whether the VM runs, so it checks again: $($Row.Cause)"
        }
        $Assume
    }
}

# After a start in $Program, check that the VM runs within $StartSeconds, then wait while it runs,
# checking every $PollSeconds, and point its disk file $Disk away from the stick (Invoke-PvmDisarm,
# with $Copies) as soon as it has ended. VirtualBox's background service may still hold the VM's
# files, so for VirtualBox the launcher then waits up to 60 s for it to end and reads the disk
# file once more: should it point at the stick again, it is pointed away once more, and the log
# says so. Should the first try to point it away fail there, it tries once more after that wait.
# A check whether the VM runs that fails counts as not yet started, or as still running; after
# $FailedChecks failed checks in a row while it runs, the launcher stops watching and says so. A
# VM that does not start stops the launcher, after the disarm.
function Watch-PvmVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][ValidateSet('VMware', 'VirtualBox')][string]$Program,
        [string]$Vmx,
        [Parameter(Mandatory)][string]$Disk,
        [Parameter(Mandatory)][hashtable]$Copies,
        [int]$StartSeconds = 60,
        [int]$PollSeconds = 5,
        [int]$FailedChecks = 12
    )
    $log = $Context.LogPath
    Enter-PvmStep -Context $Context -Name 'verify'
    $running = $false
    $row = @{ Failures = 0; Cause = '' }
    for ($waited = 0; ; $waited += 2) {
        if (Test-PvmVmRunningOrAssume -Context $Context -Program $Program -Vmx $Vmx -Assume $false -Row $row) { $running = $true; break }
        if ($waited -ge $StartSeconds) { break }
        Invoke-PvmSleep -Seconds 2
    }
    if (-not $running) {
        Enter-PvmStep -Context $Context -Name 'disarm'
        $null = Invoke-PvmDisarm -Context $Context -Disk $Disk -Copies $Copies -Quiet
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $Context.Names -Values @{ Program = $Program; Seconds = $StartSeconds } -Template (
                    "{VM} did not start in {Program} within {Seconds} s, so the launcher pointed its disk file away from the stick again. {Program}'s window may say why; then start {vm} again.")))
    }
    Write-PvmLog -Path $log -Message "Running in $Program; the launcher watches the VM and points its disk file away from the stick when it ends"
    Enter-PvmStep -Context $Context -Name 'watch'
    $started = Get-Date
    $row = @{ Failures = 0; Cause = '' }
    while (Test-PvmVmRunningOrAssume -Context $Context -Program $Program -Vmx $Vmx -Assume $true -Row $row) {
        # A check that keeps failing would keep the launcher, and its lock, waiting for good.
        if ($row.Failures -ge $FailedChecks) {
            throw (Get-PvmStopException -Message (Format-PvmMessage -Names $Context.Names -Values @{ Seconds = $FailedChecks * $PollSeconds; Name = [IO.Path]::GetFileName($Disk); Cause = $row.Cause } -Template (
                        "For {Seconds} s the launcher could not check whether {vm} still runs, so it stopped watching it. {Name} names the stick's disk until the next start through the launcher sets it right.`n`n{Cause}")))
        }
        Invoke-PvmSleep -Seconds $PollSeconds
    }
    Write-PvmLog -Path $log -Message "The VM has ended, after $([int][Math]::Round(((Get-Date) - $started).TotalMinutes)) min"
    Enter-PvmStep -Context $Context -Name 'disarm'
    $name = [IO.Path]::GetFileName($Disk)
    # VirtualBox's background service may still hold the file, so a first try that fails there is
    # tried once more after it has ended.
    $disarmed = Invoke-PvmDisarm -Context $Context -Disk $Disk -Copies $Copies -Quiet:($Program -eq 'VirtualBox')
    if ($Program -ne 'VirtualBox') { return }
    Wait-PvmProcessExit -Name 'VBoxSVC' -TimeoutSeconds 60
    if (-not $disarmed) {
        $null = Invoke-PvmDisarm -Context $Context -Disk $Disk -Copies $Copies
        return
    }
    try { $text = ConvertFrom-PvmDescriptorData -Bytes ([IO.File]::ReadAllBytes($Disk)) }
    catch {
        Write-PvmLog -Path $log -Message "Note: $name could not be read once more after VirtualBox's background service ended: $(Get-PvmErrorText -ErrorRecord $_)"
        return
    }
    if ((ConvertTo-PvmDisarmedDescriptorText -Text $text) -cne $text) {
        Write-PvmLog -Path $log -Message "${name}: pointed at the stick again after the VM ended, so the launcher pointed it away once more"
        $null = Invoke-PvmDisarm -Context $Context -Disk $Disk -Copies $Copies
    }
}

# --- Launch ----------------------------------------------------------------------------------

# Check that the disk the launcher runs from is the configured stick, choose the hypervisor and
# start the VM, as $Context describes (Invoke-PortableVM builds it). Returns 'AlreadyRunning',
# 'DryRun' or 'Started'; throws a stop.
function Invoke-PvmLaunch {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    Enter-PvmStep -Context $Context -Name 'stick'
    $settings = $Context.Settings
    $log = $Context.LogPath

    # 1. Find the stick this launcher is on, and make sure it is the right one. A network drive or
    # a drive made with subst has a letter but no partition.
    $stick = Get-PvmStickDevice -Location $Context.Location -Names $Context.Names
    $disk = $stick.Disk
    $problem = Get-PvmStickProblem -Disk $disk -Partition $stick.Partition -Settings $settings
    if ($problem) { throw (Get-PvmStopException -Message $problem) }
    $drive = $stick.Device
    Write-PvmLog -Path $log -Message "Stick found: disk $($disk.Number) ($drive), drive $($Context.Location.Letter):, ID $(Get-PvmDiskSignature -Disk $disk)"

    Enter-PvmStep -Context $Context -Name 'choice'
    $deviceGuard = Invoke-PvmGetDeviceGuard
    if ($deviceGuard -and ($deviceGuard.SecurityServicesRunning -contains 2)) {
        Write-PvmLog -Path $log -Message 'Note: Memory Integrity is on, so the VM runs on top of Hyper-V (slower than native).'
    }

    # 2. Read the PC and the VM once, and decide.
    $vmx = Join-PvmStickPath -Root $Context.Root -Path $settings['VMwareVmx']
    # Each state is logged as soon as it is known, so a .vbox that cannot be read does not hide a
    # VMware suspend from the log. A state the launcher cannot tell stops it.
    $vbox = Join-PvmStickPath -Root $Context.Root -Path $settings['VirtualBoxVbox']
    # A write that did not finish, of any file a start may write or of a copy of one, stops a start
    # in either hypervisor before a file is read, with the step that sets it right. The .vmx, which
    # the launcher never writes, says which VMware disk file that is; the .vbox, once it is whole,
    # which VirtualBox disk file and the VM's UUID.
    $Context.StickDisk = $disk
    $Context.VmFiles = New-PvmVmFileRecord -Context $Context
    Assert-PvmNoWrittenLeftover -Context $Context -Kind 'Vmx'
    Resolve-PvmVMwareFile -Context $Context
    Assert-PvmNoWrittenLeftover -Context $Context -Kind 'VMwareDisk', 'Vbox', 'VirtualBoxXml'
    Resolve-PvmVirtualBoxFile -Context $Context
    Assert-PvmNoWrittenLeftover -Context $Context -Kind 'VirtualBoxDisk'
    $Context.VMwareState = Get-PvmVMwareState -Path $vmx
    if ($Context.VMwareState.State -eq 'Saved') { Write-PvmLog -Path $log -Message 'Saved state found: suspended in VMware' }
    Assert-PvmKnownState -Context $Context -State $Context.VMwareState -What 'whether {vm} is suspended in VMware' -Setting 'VMwareVmx' -Path $vmx
    $Context.VirtualBoxState = Get-PvmVirtualBoxState -Path $vbox
    if ($Context.VirtualBoxState.State -eq 'Saved') { Write-PvmLog -Path $log -Message 'Saved state found: saved in VirtualBox' }
    Assert-PvmKnownState -Context $Context -State $Context.VirtualBoxState -What 'whether {vm} has a saved state in VirtualBox' -Setting 'VirtualBoxVbox' -Path $vbox
    $snapshot = Get-PvmStartSnapshot -Context $Context
    $decision = Get-PvmStartDecision -Setting $settings['Hypervisor'] -Snapshot $snapshot
    if ($decision.Stop) { throw (Get-PvmStopException -Message (Get-PvmDecisionMessage -Kind $decision.Stop -Context $Context -Snapshot $snapshot -Use $decision.Use)) }
    $use = $decision.Use
    Write-PvmLog -Path $log -Message "Using $use"

    # 3. Start.
    $path = @{ Context = $Context; Drive = $drive; Decision = $decision; Snapshot = $snapshot }
    if ($use -eq 'VMware') { Invoke-PvmVMware @path -VMwareDir $snapshot.VMwareDir }
    else { Invoke-PvmVirtualBox @path -VirtualBoxDir $snapshot.VirtualBoxDir }
}

# Run the launcher from the folder $LauncherPath, which holds the code and the VERSION that the
# deploy tool writes, and whose parent folder, the stick folder, holds LauncherData as well
# (Get-PvmDataPath): read and check the settings, check the stick, choose the hypervisor and start
# the VM. One run at a time: it holds the lock (Get-PvmLockName) from before its first log line
# until it returns, and another run meanwhile stops as busy. It needs administrator rights, a dry
# run too. With -DryRun it takes a real start's decisions and logs what would change, but changes
# no VM file and starts nothing; where a real start would stop it logs so and carries on, and its
# result is the first such stop. Before a saved state is resumed, the script block $AskResume gets
# the question and the dialog's title and must return $true for Yes; without it the answer is No.
# $AskFix does the same before the launcher sets right a write that did not finish.
# Returns ExitCode, 0 or 1, the Message to show with its Icon, both empty when there is nothing to
# show, and the Caption for the dialog. Stops and unexpected errors, which name the step they
# happened in, are logged to LauncherData\logs\launcher.log as "STOPPED: ..." and returned; every
# run ends with a Timings line and an End line. A log that cannot be written when the run starts
# stops it; a later failure adds a note to the message. Without LauncherData there is no log and
# no lock, so the message is only returned and printed; a launcher folder that is gone, as when
# the stick was pulled, gets a message of its own. It throws only when PowerShell cannot build the
# launcher's paths, which can happen when the stick's drive is gone before the run begins.
function Invoke-PortableVM {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [switch]$DryRun,
        [scriptblock]$AskResume,
        [scriptblock]$AskFix
    )
    $paths = Get-PvmDataPath -LauncherPath $LauncherPath
    if (-not (Test-Path -LiteralPath $paths.Data -PathType Container)) {
        $message = if (-not [IO.Directory]::Exists($LauncherPath)) {
            'The launcher''s own folder cannot be found any more, as when the USB stick was removed. Plug the stick in, then start the VM again. Nothing was started.'
        } elseif (Test-Path -LiteralPath $paths.OldSettings -PathType Leaf) {
            'The settings are still in Launcher\settings.psd1, where the launcher read them before LauncherData. Move them to LauncherData with tools\Deploy-PortableVM.ps1 -MigrateSettings, run from a clone of the launcher. Nothing was started.'
        } else {
            'LauncherData, the folder beside Launcher that holds the settings and the log, is missing. Create it, copy examples\settings.example.psd1 into it as settings.psd1 and fill that in. Nothing was started.'
        }
        Write-Host $message
        return [pscustomobject]@{ ExitCode = 1; Message = $message; Icon = 'Error'; Caption = 'Portable VM' }
    }
    $script:PvmLogProblem = ''
    $runText = if ($DryRun) { ' (dry run)' } else { '' }
    $lock = $null
    $owned = $false
    $result = $null
    $logStop = $false
    # The steps below fill in the settings, the names, the caption and the stick's location
    # (Get-PvmStickLocation); Invoke-PvmLaunch fills in VMwareState and VirtualBoxState.
    $context = [pscustomobject]@{
        Root            = $paths.Root
        LogPath         = $paths.Log
        Backups         = $paths.Backups
        Location        = $null
        DryRun          = [bool]$DryRun
        AskResume       = $AskResume
        AskFix          = $AskFix
        RemovedFolder   = ''
        Names           = @{ VM = 'the VM'; Guest = 'the guest' }
        Caption         = 'Portable VM'
        VMwareState     = $null
        VirtualBoxState = $null
        VmFiles         = $null
        StickDisk       = $null
        Settings        = @{}
        Step            = 'setup'
        Clock           = [Diagnostics.Stopwatch]::StartNew()
        Times           = [ordered]@{}
        WouldStop       = ''
    }
    try {
        # Every run logs, a dry run too. New-Item -Force would accept a file named logs silently.
        try { $null = [IO.Directory]::CreateDirectory($paths.Logs) }
        catch {
            # An item that is in the way of the logs folder is a file of that name.
            $cause = Get-PvmErrorCause -ErrorRecord $_
            $script:PvmLogProblem = if ($cause -eq 'an item of that name exists already') { 'LauncherData\logs is a file, not a folder' } else { $cause }
        }
        # An error of the rights check or of the lock ends the run after its start and version
        # lines, as every run begins with them.
        $admin = $false
        $setupError = $null
        # The rights check and the lock exist on Windows only so far, and the rights check throws
        # elsewhere, so another system stops after the start and version lines with a plain message.
        $windows = Test-PvmWindowsHost
        try {
            if ($windows) { $admin = Invoke-PvmTestAdministrator }
            if ($admin) {
                $lock = Invoke-PvmEnterLock -Name (Get-PvmLockName)
                $owned = $lock.State -ne 'Busy'
            }
        } catch {
            $setupError = $_
        }
        # Only the run that holds the lock moves a full or old-format log aside.
        $moved = if ($owned -and -not (Get-PvmLogProblem)) { Move-PvmOldLog -Path $paths.Log -Time (Get-PvmNow) } else { $null }
        Write-PvmLog -Path $paths.Log -Message "----- Start VM$runText -----"
        # VERSION is only for the log, so a missing or unreadable one never stops a start.
        $versionPath = Join-Path $LauncherPath 'VERSION'
        $version = 'unknown'
        try { if (Test-Path -LiteralPath $versionPath -PathType Leaf) { $version = [IO.File]::ReadAllText($versionPath).Trim() } }
        catch { $version = 'unreadable' }
        Write-PvmLog -Path $paths.Log -Message "Launcher version $version"
        if ($null -ne $moved) {
            if ($moved.Name) { Write-PvmLog -Path $paths.Log -Message "Note: the earlier lines of the log are in $($moved.Name)." }
            else { Write-PvmLog -Path $paths.Log -Message "Note: the log could not be moved aside, because $(Format-PvmBecause -Cause $moved.Problem); this run adds to it." }
        }
        if ($owned -and $lock.State -eq 'Abandoned') {
            Write-PvmLog -Path $paths.Log -Message 'Note: an earlier run of the launcher ended without releasing its lock; this run took the lock over.'
        }
        if ($null -ne $setupError) { throw $setupError }
        if (-not $windows) { throw (Get-PvmStopException -Message (Get-PvmOtherSystemMessage)) }
        if (-not $admin) {
            $rights = if ($DryRun) {
                'A dry run needs administrator rights, as a real start has them, so that its checks see what a real start sees. Run it from an elevated PowerShell. Nothing was started.'
            } else {
                'The launcher needs administrator rights, because the VM boots this USB stick directly.'
            }
            throw (Get-PvmStopException -Message $rights)
        }
        if (-not $owned) { throw (Get-PvmStopException -Message (Get-PvmBusyMessage)) }
        $problem = Get-PvmLogProblem
        if ($problem) {
            $logStop = $true
            throw (Get-PvmStopException -Message "The launcher cannot write its log, LauncherData\logs\launcher.log, because $(Format-PvmBecause -Cause $problem). Nothing was started.")
        }

        Enter-PvmStep -Context $context -Name 'settings'
        if (Test-Path -LiteralPath $paths.OldSettings) {
            throw (Get-PvmStopException -Message 'Launcher\settings.psd1 is there, but the launcher reads its settings from LauncherData\settings.psd1. Move any change you made in it there, then remove it from Launcher. Nothing was started.')
        }
        try { $settings = Import-PvmSetting -Path $paths.Settings }
        catch {
            $stop = Get-PvmStopMessage -ErrorRecord $_
            if ($null -eq $stop) { throw }
            $exception = Get-PvmStopException -Message "$stop`n`nNothing was started."
            $detail = Get-PvmStopDetail -ErrorRecord $_
            if ($detail) { $exception.Data['PvmDetail'] = $detail }
            throw $exception
        }
        $context.Settings = $settings
        $context.Names = @{ VM = $settings['VmDisplayName']; Guest = $settings['GuestName'] }
        $context.Caption = Get-PvmCaption -Settings $settings
        $location = Get-PvmStickLocation -LauncherPath $LauncherPath -Root $paths.Root
        if (-not $location) {
            if (-not (Test-PvmWindowsHost)) {
                throw (Get-PvmStopException -Message (Get-PvmOtherSystemMessage))
            }
            throw (Get-PvmStopException -Message (Format-PvmMessage -Names $context.Names -Template 'The launcher runs from {Path}, which is not on a drive with a letter, so it cannot tell which disk is the USB stick. Start it with Start VM.cmd on the stick''s own drive. Nothing was started.' -Values @{
                        Path = $LauncherPath
                    }))
        }
        $context.Location = $location

        $outcome = Invoke-PvmLaunch -Context $context
        $result = if ($context.WouldStop) {
            [pscustomobject]@{ ExitCode = 1; Message = $context.WouldStop; Icon = 'Error'; Caption = $context.Caption }
        } elseif ($outcome -eq 'AlreadyRunning') {
            [pscustomobject]@{ ExitCode = 0; Message = (Format-PvmMessage -Names $context.Names -Template '{VM} is already running.'); Icon = 'Information'; Caption = $context.Caption }
        } else {
            [pscustomobject]@{ ExitCode = 0; Message = ''; Icon = ''; Caption = $context.Caption }
        }
    } catch {
        $stop = Get-PvmStopMessage -ErrorRecord $_
        $message = if ($null -ne $stop) { $stop } else { "Unexpected error while $(Get-PvmStepText -Step $context.Step): $(Get-PvmErrorText -ErrorRecord $_)" }
        $lines = @("STOPPED: $message")
        if ($null -eq $stop) { $lines += @(Format-PvmErrorDetail -ErrorRecord $_) }
        else {
            $detail = Get-PvmStopDetail -ErrorRecord $_
            if ($detail) { $lines += "Error detail: $detail" }
        }
        Write-PvmLog -Path $context.LogPath -Message ($lines -join "`n")
        # A dry run that found a stop earlier returns that one, as a real start would have.
        $shown = if ($context.WouldStop) { $context.WouldStop } else { $message }
        $result = [pscustomobject]@{ ExitCode = 1; Message = $shown; Icon = 'Error'; Caption = $context.Caption }
    } finally {
        Enter-PvmStep -Context $context -Name ''
        Write-PvmLog -Path $context.LogPath -Message (Format-PvmTiming -Times $context.Times)
        $exitCode = if ($null -ne $result) { $result.ExitCode } else { 1 }
        Write-PvmLog -Path $context.LogPath -Message "----- End$($runText): exit code $exitCode -----"
        if ($owned) {
            try { Invoke-PvmExitLock -Lock $lock }
            catch { Write-PvmLog -Path $context.LogPath -Message "Note: the launcher could not release its lock ($($_.Exception.Message)); Windows releases it when this process ends." }
        }
    }
    # A log that failed after the start line changed no decision, but the message says so. A run
    # without a message ended well, which the warning then says first.
    $problem = Get-PvmLogProblem
    if ($problem -and -not $logStop) {
        $note = "The launcher could not write all of this run to its log, LauncherData\logs\launcher.log, because $(Format-PvmBecause -Cause $problem)."
        if ($result.Message) { $result.Message += "`n`n$note" }
        else {
            $done = if ($DryRun) { 'The dry run found nothing that would stop a start.' } else { Format-PvmMessage -Names $context.Names -Template '{VM} was started.' }
            $result.Message = "$done`n`n$note"
            $result.Icon = 'Warning'
        }
    }
    $result
}
