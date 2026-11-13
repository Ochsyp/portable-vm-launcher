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

# Append the message $Message to the log file $Path as Format-PvmLogText gives it, with the time
# now and this process's ID, and show it on the console. The text goes in one write through an
# append-only handle that shares reading, writing and deletion, so that other launcher processes
# can neither break it up nor block it; -WhatIf does not affect it, so a dry run logs what it would
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
        $bytes = [Text.Encoding]::Default.GetBytes($text + "`r`n")
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Append, [Security.AccessControl.FileSystemRights]::AppendData,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete), 4096, [IO.FileOptions]::None)
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
# it; else the type of the error.
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

# Return the cause of the error $ErrorRecord of a write to the file $Path, as Get-PvmErrorCause
# words it, but 'a path is too long' when it says 'it is missing' and $Path has 260 characters or
# more, since Windows without long-path support names a missing part of such a path.
function Get-PvmPathCause {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    $cause = Get-PvmErrorCause -ErrorRecord $ErrorRecord
    if ($cause -eq 'it is missing' -and $Path.Length -ge 260) { return 'a path is too long' }
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
        Log         = Join-Path $data 'logs\launcher.log'
        Backups     = Join-Path $data 'backups'
        Legacy      = Join-Path $data 'backups\legacy'
        State       = Join-Path $data 'state'
        OldSettings = Join-Path $LauncherPath 'settings.psd1'
    }
}

# Return where the launcher keeps the first version of the file $Path, which lies below the stick
# folder $Root: at the same path relative to $Backups, with $Suffix added. Throws when $Path is not
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
    $below = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($below, [StringComparison]::OrdinalIgnoreCase)) { throw "$Path is not below $Root." }
    Join-Path $Backups ($full.Substring($below.Length) + $Suffix)
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

# Return the message of a run that finds another run holding the lock.
function Get-PvmBusyMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'Another run of the launcher is in progress on this PC: a start of the VM or a dry run. Wait until it has finished, then start the VM again if it is not running. Nothing was started.'
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

# --- Settings --------------------------------------------------------------------------------
# LauncherData\settings.psd1 holds one hashtable of plain values. The launcher parses it without
# running anything in it, checks every value against schema 2 before it reads the PC, and fills
# in the defaults. A file with problems stops the launcher with one message that names each bad
# key and never a value from the file.

# Return settings schema 2, one entry per key, in the order the checks report them: its Name,
# whether it is Required, the Default a missing key gets, the Kind of value it holds and the
# Values that kind allows: the words of a Choice, or the extension of a Path, none for a folder.
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
    [pscustomobject]@{ Name = 'HideDataPartition'; Required = $false; Default = $false; Kind = 'Bool'; Values = @() }
    [pscustomobject]@{ Name = 'StickMbrSignature'; Required = $true; Default = $null; Kind = 'Signature'; Values = @() }
    [pscustomobject]@{ Name = 'StickSectors'; Required = $true; Default = $null; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'VmSectors'; Required = $true; Default = $null; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'DataPartitionStart'; Required = $true; Default = $null; Kind = 'Count'; Values = @() }
    [pscustomobject]@{ Name = 'VirtualBoxVmUuid'; Required = $true; Default = $null; Kind = 'Uuid'; Values = @() }
    [pscustomobject]@{ Name = 'VirtualBoxHome'; Required = $true; Default = $null; Kind = 'Path'; Values = @() }
    [pscustomobject]@{ Name = 'VirtualBoxVbox'; Required = $true; Default = $null; Kind = 'Path'; Values = @('.vbox') }
    [pscustomobject]@{ Name = 'VirtualBoxDisk'; Required = $true; Default = $null; Kind = 'Path'; Values = @('.vmdk') }
    [pscustomobject]@{ Name = 'VMwareVmx'; Required = $true; Default = $null; Kind = 'Path'; Values = @('.vmx') }
    [pscustomobject]@{ Name = 'VMwareDisk'; Required = $true; Default = $null; Kind = 'Path'; Values = @('.vmdk') }
}

# Return what is wrong with the path setting $Value, or nothing when it names a file that ends in
# $Extension, or a folder when $Extension is empty, below the stick folder. Such a path is
# relative, uses \ or / as separator and has no blank at either end, and each of its parts is a
# real name: not empty, '.' or '..', not ending in a dot or a blank, no device name such as CON
# or NUL, and no character Windows forbids in a name, such as ':'. Joined to the stick folder, it
# gives the path that [IO.Path]::GetFullPath gives, so the launcher compares and logs the path
# Windows uses.
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
    $forbidden = [IO.Path]::GetInvalidFileNameChars()
    foreach ($part in ($Value -split '[\\/]')) {
        if (-not $part -or $part -match '[. ]\z' -or $part.IndexOfAny($forbidden) -ge 0 -or
            $part -match '\A(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9]|LPT[1-9])(\.|\z)') { return $problem }
    }
    if ($Extension -and -not $Value.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { return $problem }
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
        return [Text.Encoding]::Default.GetString($Bytes)
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
# or '' when there are none. The step always keeps the version from before that write: the file
# itself, or the old version beside it, which the write found unchanged. So it is right also when
# the new version did not read back from its place, and the next run makes its change again.
function Get-PvmLeftoverProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $copies = Get-PvmWriteCopyPath -Path $Path
    $temp = [IO.File]::Exists($copies.Temp)
    $old = [IO.File]::Exists($copies.Old)
    if (-not $temp -and -not $old) { return '' }
    $name = [IO.Path]::GetFileName($Path)
    $step = if ([IO.File]::Exists($Path)) {
        if ($temp -and $old) { "remove $name.pvm-tmp and $name.pvm-old; $name itself is whole" }
        elseif ($temp) { "remove $name.pvm-tmp; $name itself is whole" }
        else { "remove $name, then rename $name.pvm-old back to $name, which holds the version before the write" }
    } elseif ($old -and $temp) {
        "rename $name.pvm-old back to $name and remove $name.pvm-tmp"
    } elseif ($old) {
        "rename $name.pvm-old back to $name"
    } else {
        "remove $name.pvm-tmp, which may be incomplete"
    }
    "A write of $Path did not finish. To set it right, $step."
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
# end), Number and Kind: Blank, Comment, Key (with Key) or Extent (with Type, Target and Offset).
# A UTF-8 byte order mark before the first line stays in its Text. Throws a FormatException with
# the reason, which names the line, when the launcher does not understand the descriptor: a line
# of no known kind, an extent other than '<access> <sectors> FLAT "<raw disk>" <offset>' or
# '<access> <sectors> ZERO', extents apart from each other, createType set twice, or no extent.
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
        $lines.Add([pscustomobject]@{ Text = $line; Ending = $ending; Number = $lines.Count + 1; Kind = ''; Key = ''; Type = ''; Target = ''; Offset = '' })
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
                if ($target.Value -notmatch '^\\\\[.?]\\') { throw [FormatException]::new("$where has a FLAT extent that names a file, not a raw disk") }
            } elseif ($target.Success) {
                throw [FormatException]::new("$where has a ZERO extent that names a target")
            }
            if ($extentEnded) { throw [FormatException]::new("$where is an extent apart from the others") }
            $sawExtent = $true
            $entry.Kind = 'Extent'
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

# Return the device that disarmed descriptor copies name instead of a raw disk. No disk has this
# name, so a hypervisor that opens such a copy by mistake finds no disk, rather than whatever disk
# has the copy's old number now.
function Get-PvmDisarmedDevice {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    '\\.\PortableVM-disarmed'
}

# Return the descriptor text $Text with the target of every FLAT extent that names a raw device,
# a path that starts with \\.\ or \\?\, set to the disarmed device (Get-PvmDisarmedDevice).
# Every other character stays, so a second pass changes nothing, and ConvertTo-PvmDescriptorText
# arms such a copy again.
function ConvertTo-PvmDisarmedDescriptorText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $device = Get-PvmDisarmedDevice
    [regex]::Replace($Text, '(?im)^([ \t]*(?:RW|RDONLY|NOACCESS)[ \t]+\d+[ \t]+FLAT[ \t]+")(\\\\[.?]\\[^"\r\n]*)(")', {
            param($match)
            if ($match.Groups[2].Value -eq $device) { $match.Value }
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

# Throw a stop when a write of one of the files $Paths was cut off (Get-PvmLeftoverProblem), with
# the one step to take, before the launcher changes any file.
function Assert-PvmNoLeftover {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Paths)
    foreach ($path in $Paths) {
        $problem = Get-PvmLeftoverProblem -Path $path
        if ($problem) { throw (Get-PvmStopException -Message "$problem Nothing was started.") }
    }
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
    Assert-PvmNoLeftover -Paths $Path, $BackupPath, $PreviousPath
    $bytes = [IO.File]::ReadAllBytes($Path)
    try {
        $text = ConvertFrom-PvmDescriptorData -Bytes $bytes
        $new = ConvertTo-PvmDescriptorText -Text $text -Layout $Layout
    } catch [FormatException] {
        throw (Get-PvmStopException -Message "Unexpected content in $Path - $($_.Exception.Message). Nothing was started.")
    }
    $name = [IO.Path]::GetFileName($Path)
    # -eq ignores case, as before the redesign, so a change of case alone is not written.
    if ($new -eq $text) {
        Write-PvmLog -Path $LogPath -Message "$name already points at the stick"
        return $null
    }
    Write-PvmLog -Path $LogPath -Message "$name -> $($Layout.Extents -join ' | ')"
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
        $unchanged = [IO.File]::Exists($Change.Path) -and (Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($Change.Path)) -Right $Change.Old)
        $values.State = if ($code -eq 'Changed') { 'the launcher left it as that program wrote it. Close that program, then start again' }
        elseif ($code) { 'the launcher left it as it is' }
        elseif ($unchanged) { 'the file is unchanged' }
        else { 'check the file against its copies below LauncherData\backups' }
        throw (Get-PvmWriteStop -ErrorRecord $failure -Path $Change.Path -Values $values -Template 'The launcher could not rewrite {Path}, because {Cause}; {State}. Nothing was started.')
    }
    if ($left) {
        # The step puts the version before back, so that copy goes back as it was too.
        if ($previous) { Restore-PvmPreviousCopy -Previous $previous -BackupPath $Change.PreviousBackup -LogPath $LogPath }
        throw (Get-PvmStopException -Message "$(Get-PvmLeftoverProblem -Path $Change.Path) Nothing was started.")
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
        [Parameter(Mandatory)][string]$LogPath
    )
    Assert-PvmNoLeftover -Paths $Path
    Write-PvmLog -Path $LogPath -Message "Creating $(Split-Path $Path -Leaf) -> $($Layout.Extents -join ' | ')"
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($Path))) {
        throw (Get-PvmStopException -Message "The launcher could not create $Path, because its folder is missing. Nothing was started.")
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create the raw-disk descriptor')) { return }
    try {
        $null = Write-PvmFile -Path $Path -Bytes ([Text.Encoding]::ASCII.GetBytes((Get-PvmVMwareDescriptorText -Layout $Layout)))
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
    Assert-PvmNoLeftover -Paths $Path, $BackupPath, $PreviousPath
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
        return [pscustomobject]@{ State = 'Unknown'; Reason = 'the file does not exist'; Values = @{} }
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
# missing, cannot be read, is no XML or has no Machine element. DTDs are refused.
function Get-PvmVirtualBoxState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return [pscustomobject]@{ State = 'Unknown'; Reason = 'the path is a folder, not a file' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'Unknown'; Reason = 'the file does not exist' }
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
    [pscustomobject]@{ State = $state; Reason = '' }
}

# Return the files a start may write, as the settings in $Context name them, each followed by its
# first copy and the copy of the version before its latest rewrite below the backups folder: the
# VMware descriptor, the .vbox, VirtualBox.xml and the VirtualBox descriptor.
function Get-PvmWrittenPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $settings = $Context.Settings
    $backup = @{ Root = $Context.Root; Backups = $Context.Backups }
    $files = @(
        @{ Path = (Join-Path $Context.Root $settings['VMwareDisk']); Suffix = '.orig' }
        @{ Path = (Join-Path $Context.Root $settings['VirtualBoxVbox']); Suffix = '.launcher-backup' }
        @{ Path = (Join-Path (Join-Path $Context.Root $settings['VirtualBoxHome']) 'VirtualBox.xml'); Suffix = '.launcher-backup' }
        @{ Path = (Join-Path $Context.Root $settings['VirtualBoxDisk']); Suffix = '.orig' }
    )
    foreach ($file in $files) {
        $file.Path
        Get-PvmBackupPath @backup -Path $file.Path -Suffix $file.Suffix
        Get-PvmBackupPath @backup -Path $file.Path -Suffix ('.previous' + $file.Suffix)
    }
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
    Enter-PvmStep -Context $Context -Name 'checks'
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
        Invoke-PvmStopUnlessDryRun -Context $Context -Message (Format-PvmMessage -Names $Context.Names -Template 'A VirtualBox VM is running, possibly this one. Close it before starting {vm} in VMware - the stick must never be used by two VMs at once.')
    }
    if ($Context.VirtualBoxState.State -eq 'Saved') {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message (Format-PvmMessage -Names $Context.Names -Template '{VM} has a saved state in VirtualBox. Resume it in VirtualBox (on a PC with VirtualBox) and shut {guest} down normally before starting it in VMware - otherwise {guest}''s disk can get corrupted.')
    }
    Assert-PvmVMwareReady -Context $Context -Vmx $vmx

    Enter-PvmStep -Context $Context -Name 'files'
    $disk = Join-Path $Context.Root $settings['VMwareDisk']
    if ([IO.File]::Exists($disk)) {
        $copies = @{ Root = $Context.Root; Backups = $Context.Backups; Path = $disk }
        $change = Get-PvmDescriptorChange -Path $disk -Layout $layout -BackupPath (Get-PvmBackupPath @copies -Suffix '.orig') -PreviousPath (Get-PvmBackupPath @copies -Suffix '.previous.orig') -LogPath $log
        if ($null -ne $change) { Save-PvmFileChange -Change $change -LogPath $log -WhatIf:$Context.DryRun }
    } else {
        New-PvmVMwareDescriptor -Path $disk -Layout $layout -LogPath $log -WhatIf:$Context.DryRun
    }
    Enter-PvmStep -Context $Context -Name 'start'
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
        [Parameter(Mandatory)][string]$Drive
    )
    Enter-PvmStep -Context $Context -Name 'checks'
    $settings = $Context.Settings
    $log = $Context.LogPath
    $layout = Get-PvmDiskLayout -Drive $Drive -VmSectors $settings['VmSectors'] -DataPartitionStart $settings['DataPartitionStart'] -HideData $settings['HideDataPartition']
    $vboxManage = Join-Path $VirtualBoxDir 'VBoxManage.exe'
    $uuid = $settings['VirtualBoxVmUuid']
    Invoke-PvmSetEnvironment -Name 'VBOX_USER_HOME' -Value (Join-Path $Context.Root $settings['VirtualBoxHome'])
    $names = $Context.Names
    $vmx = Join-Path $Context.Root $settings['VMwareVmx']
    if (Test-PvmRunningInVMware -Vmx $vmx) {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message (Format-PvmMessage -Names $names -Template '{VM} is running in VMware. Close it before starting it in VirtualBox.')
    }
    if ($Context.VMwareState.State -eq 'Saved') {
        Invoke-PvmStopUnlessDryRun -Context $Context -Message (Format-PvmMessage -Names $names -Template '{VM} is suspended in VMware. Resume it in VMware (on a PC with VMware Workstation) and shut {guest} down normally before starting it in VirtualBox - otherwise {guest}''s disk can get corrupted.')
    }

    $open = @(Invoke-PvmGetProcess -Filter "Name='VirtualBox.exe' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'")
    if ($open.Count) {
        # VirtualBox hides its VM processes' command lines, so VirtualBox is asked whether this VM is the one running.
        $info = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('showvminfo', $uuid, '--machinereadable')
        if ($info.Output -match 'VMState="(running|paused|starting|restoring)"') {
            Write-PvmLog -Path $log -Message 'Already running in VirtualBox.'
            return 'AlreadyRunning'
        }
        Invoke-PvmStopUnlessDryRun -Context $Context -Message (Format-PvmMessage -Names $names -Template 'VirtualBox is already open on this PC. Close all VirtualBox windows, then start {vm} again.')
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
        Invoke-PvmStopUnlessDryRun -Context $Context -Message (Format-PvmMessage -Names $names -Template 'VirtualBox is still running in the background. Wait half a minute, then start {vm} again.')
    }

    # The launcher records no VirtualBox save yet, so every saved state asks before it is resumed,
    # after the checks that can still stop the start and before the first write.
    if ($Context.VirtualBoxState.State -eq 'Saved') {
        $question = Format-PvmMessage -Names $names -Template "{VM} has a saved state in VirtualBox that this launcher did not record. Resume it only if the stick has not been booted any other way since the save; otherwise the resume can corrupt {guest}'s disk.`n`nResume {vm} now?"
        Confirm-PvmResume -Context $Context -Program 'VirtualBox' -Question $question
    }

    Enter-PvmStep -Context $Context -Name 'files'
    $vbox = Join-Path $Context.Root $settings['VirtualBoxVbox']
    $registry = Join-Path (Join-Path $Context.Root $settings['VirtualBoxHome']) 'VirtualBox.xml'
    $disk = Join-Path $Context.Root $settings['VirtualBoxDisk']
    $backup = @{ Root = $Context.Root; Backups = $Context.Backups }
    # At a drive root the paths to the VM's own files show the stick's old letter.
    $letters = @{ Root = $Context.Root; Letter = $Context.Letter; Known = @($vbox, $disk); LogPath = $log }
    # Every file is checked first, so that a refusal leaves all of them as they are.
    $changes = @(@(
            Get-PvmDriveLetterChange -Path $vbox -BackupPath (Get-PvmBackupPath @backup -Path $vbox -Suffix '.launcher-backup') -PreviousPath (Get-PvmBackupPath @backup -Path $vbox -Suffix '.previous.launcher-backup') @letters
            Get-PvmDriveLetterChange -Path $registry -BackupPath (Get-PvmBackupPath @backup -Path $registry -Suffix '.launcher-backup') -PreviousPath (Get-PvmBackupPath @backup -Path $registry -Suffix '.previous.launcher-backup') @letters
            Get-PvmDescriptorChange -Path $disk -Layout $layout -BackupPath (Get-PvmBackupPath @backup -Path $disk -Suffix '.orig') -PreviousPath (Get-PvmBackupPath @backup -Path $disk -Suffix '.previous.orig') -LogPath $log
        ) | Where-Object { $null -ne $_ })
    foreach ($change in $changes) { Save-PvmFileChange -Change $change -LogPath $log -WhatIf:$Context.DryRun }
    Enter-PvmStep -Context $Context -Name 'start'
    if ($Context.DryRun) {
        Write-PvmLog -Path $log -Message "DRY RUN - would start VM {$uuid} with VirtualBox ($VirtualBoxDir)"
        return 'DryRun'
    }

    $list = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('list', 'vms')
    if (-not (Test-PvmVirtualBoxVmListed -Output $list.Output -VmUuid $uuid)) {
        throw (Get-PvmStopException -Message (Format-PvmMessage -Names $names -Template "VirtualBox did not find {vm} in the stick's VM list:`n`n{Output}" -Values @{ Output = $list.Output }))
    }
    $info = Invoke-PvmNative -FilePath $vboxManage -ArgumentList @('showvminfo', $uuid, '--machinereadable')
    $state = Get-PvmVirtualBoxVmState -Output $info.Output
    Write-PvmLog -Path $log -Message "VirtualBox VM state: $state"
    if ($state -match 'running|paused|starting|restoring') { return 'AlreadyRunning' }

    Start-PvmVirtualBoxVm -VBoxManage $vboxManage -VmUuid $uuid -Names $names -LogPath $log
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
    Enter-PvmStep -Context $Context -Name 'stick'
    $settings = $Context.Settings
    $log = $Context.LogPath

    # 1. Find the stick this launcher is on, and make sure it is the right one. A network drive or
    # a drive made with subst has a letter but no partition.
    try { $partition = Invoke-PvmGetPartition -DriveLetter $Context.Letter }
    catch {
        if ("$($_.FullyQualifiedErrorId)" -like 'CmdletizationQuery_NotFound_DriveLetter,*') {
            throw (Get-PvmStopException -Message (Format-PvmMessage -Names $Context.Names -Template 'Windows has no partition with the drive letter {Letter}:, so the launcher cannot tell which disk is the USB stick; a network drive or a drive made with subst has none. Start it with Start VM.cmd on the stick''s own drive. Nothing was started.' -Values @{
                        Letter = $Context.Letter
                    }))
        }
        throw
    }
    $disk = Invoke-PvmGetDisk -Number $partition.DiskNumber
    $problem = Get-PvmStickProblem -Disk $disk -Partition $partition -Settings $settings
    if ($problem) { throw (Get-PvmStopException -Message $problem) }
    $drive = "\\.\PhysicalDrive$($disk.Number)"
    Write-PvmLog -Path $log -Message "Stick found: disk $($disk.Number) ($drive), drive $($Context.Letter):, ID $(Get-PvmDiskSignature -Disk $disk)"

    Enter-PvmStep -Context $Context -Name 'choice'
    $deviceGuard = Invoke-PvmGetDeviceGuard
    if ($deviceGuard -and ($deviceGuard.SecurityServicesRunning -contains 2)) {
        Write-PvmLog -Path $log -Message 'Note: Memory Integrity is on, so the VM runs on top of Hyper-V (slower than native).'
    }

    # 2. Pick the hypervisor.
    $vmwareDir = Get-PvmVMwareDir
    $virtualBoxDir = Get-PvmVirtualBoxDir
    $vmx = Join-Path $Context.Root $settings['VMwareVmx']
    # Each state is logged as soon as it is known, so a .vbox that cannot be read does not hide a
    # VMware suspend from the log. A state the launcher cannot tell stops it.
    $vbox = Join-Path $Context.Root $settings['VirtualBoxVbox']
    # A write that did not finish, of any file a start may write or of a copy of one, stops a start
    # in either hypervisor before a file is read, with the step that sets it right.
    foreach ($path in @(Get-PvmWrittenPath -Context $Context)) {
        $problem = Get-PvmLeftoverProblem -Path $path
        if ($problem) { Invoke-PvmStopUnlessDryRun -Context $Context -Message "$problem Nothing was started." }
    }
    $Context.VMwareState = Get-PvmVMwareState -Path $vmx
    if ($Context.VMwareState.State -eq 'Saved') { Write-PvmLog -Path $log -Message 'Saved state found: suspended in VMware' }
    Assert-PvmKnownState -Context $Context -State $Context.VMwareState -What 'whether {vm} is suspended in VMware' -Setting 'VMwareVmx' -Path $vmx
    $Context.VirtualBoxState = Get-PvmVirtualBoxState -Path $vbox
    if ($Context.VirtualBoxState.State -eq 'Saved') { Write-PvmLog -Path $log -Message 'Saved state found: saved in VirtualBox' }
    Assert-PvmKnownState -Context $Context -State $Context.VirtualBoxState -What 'whether {vm} has a saved state in VirtualBox' -Setting 'VirtualBoxVbox' -Path $vbox
    $choice = @{
        Setting             = $settings['Hypervisor']
        VMwareInstalled     = [bool]$vmwareDir
        VirtualBoxInstalled = [bool]$virtualBoxDir
        VMwareSuspended     = ($Context.VMwareState.State -eq 'Saved')
        VirtualBoxSaved     = ($Context.VirtualBoxState.State -eq 'Saved')
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

# Run the launcher from the folder $LauncherPath, which holds the code and the VERSION that the
# deploy tool writes, and whose parent folder, the stick folder, holds LauncherData as well
# (Get-PvmDataPath): read and check the settings, check the stick, choose the hypervisor and start
# the VM. One run at a time: it holds the lock (Get-PvmLockName) from before its first log line
# until it returns, and another run meanwhile stops as busy. It needs administrator rights, a dry
# run too. With -DryRun it takes a real start's decisions and logs what would change, but changes
# no VM file and starts nothing; where a real start would stop it logs so and carries on, and its
# result is the first such stop. Before a saved state is resumed, the script block $AskResume gets
# the question and the dialog's title and must return $true for Yes; without it the answer is No.
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
        [scriptblock]$AskResume
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
    # The steps below fill in the settings, the names, the caption and the drive letter;
    # Invoke-PvmLaunch fills in VMwareState and VirtualBoxState.
    $context = [pscustomobject]@{
        Root            = $paths.Root
        LogPath         = $paths.Log
        Backups         = $paths.Backups
        Letter          = ''
        DryRun          = [bool]$DryRun
        AskResume       = $AskResume
        Names           = @{ VM = 'the VM'; Guest = 'the guest' }
        Caption         = 'Portable VM'
        VMwareState     = $null
        VirtualBoxState = $null
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
        try {
            $admin = Invoke-PvmTestAdministrator
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
        $letter = Get-PvmDriveLetter -Path $LauncherPath
        if (-not $letter) {
            throw (Get-PvmStopException -Message (Format-PvmMessage -Names $context.Names -Template 'The launcher runs from {Path}, which is not on a drive with a letter, so it cannot tell which disk is the USB stick. Start it with Start VM.cmd on the stick''s own drive. Nothing was started.' -Values @{
                        Path = $LauncherPath
                    }))
        }
        $context.Letter = $letter

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
