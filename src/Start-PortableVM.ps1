<#
  Starts the VM straight from this USB stick, using the hypervisor installed
  on this PC: VMware Workstation if present, otherwise VirtualBox. No VM list is shown.
  Double-click "Start VM.cmd" (one folder up) to run it.

  The VM boots this stick itself (raw disk). Before every start the launcher:
    - asks for administrator rights (needed to give a VM a physical disk),
    - checks the settings and names every setting that is wrong,
    - finds which disk number the stick has on this PC and checks that it really is
      this stick (MBR signature, size, partition layout) - otherwise nothing starts,
    - points the VM's raw-disk file at that disk number,
    - fixes the stick's drive letter in the VirtualBox files,
    - refuses to start the VM in one program while it has a saved state in the other.
  One run at a time: a start or a dry run holds the lock Global\PortableVM-Launcher, and a
  second double-click meanwhile says so before it asks for administrator rights.

  The checks and start steps are in PortableVM.psm1 next to this script.
  Settings: ..\LauncherData\settings.psd1. Log: ..\LauncherData\logs\launcher.log, as the
  README's Log section describes it.
  -DryRun takes a real start's decisions and logs what would change, without changing or
  starting anything. It needs administrator rights, as a real start has them.
#>
# Show-Dialog and Show-Question load System.Windows.Forms with Add-Type before they use the
# types, which the analyzer's compatibility profile cannot see: it lists only the assemblies that
# load by default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'Show-Dialog and Show-Question load System.Windows.Forms with Add-Type first.')]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$script:AskingForRights = $false

# --- Log and dialogs -------------------------------------------------------------------------
# The script logs what happens before the module runs and when the module cannot run, in the
# module's format (Format-PvmLogText, Write-PvmLog); tests\StartScript.Tests.ps1 pins the two
# equal.

# Return $Message as log text: each of its lines after the prefix "<Time as
# yyyy-MM-ddTHH:mm:ss.fff+hh:mm> [<ProcessId>]  ", joined with CRLF.
function Format-LogText([DateTimeOffset]$Time, [int]$ProcessId, [string]$Message) {
    $prefix = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:yyyy-MM-dd''T''HH:mm:ss.fffzzz} [{1}]  ', $Time, $ProcessId)
    (@($Message -split '\r\n|\r|\n') | ForEach-Object { $prefix + $_ }) -join "`r`n"
}

# Append $Message in the log's format to LauncherData\logs\launcher.log beside the Launcher
# folder, in one write as Write-PvmLog does, creating the logs folder, and show it on the console.
# Returns '' when the text is written, or when there is no LauncherData and so no log; else the
# reason it could not be written. It never throws.
function Add-LogLine([string]$Message) {
    $data = Join-Path (Split-Path $Here) 'LauncherData'
    if (-not (Test-Path -LiteralPath $data -PathType Container)) { return '' }
    $text = Format-LogText -Time ([DateTimeOffset]::Now) -ProcessId $PID -Message $Message
    Write-Host $text
    try {
        $logs = Join-Path $data 'logs'
        $null = [IO.Directory]::CreateDirectory($logs)
        $bytes = [Text.Encoding]::Default.GetBytes($text + "`r`n")
        $stream = [IO.FileStream]::new((Join-Path $logs 'launcher.log'), [IO.FileMode]::Append, [Security.AccessControl.FileSystemRights]::AppendData,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete), 4096, [IO.FileOptions]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
        ''
    } catch {
        $exception = $_.Exception
        while ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) { $exception = $exception.InnerException }
        Write-Host "launcher.log could not be written: $($exception.Message)"
        $exception.Message
    }
}

# Return the log lines that describe the error $ErrorRecord, as Format-PvmErrorDetail in the
# module gives them: "Error detail: <type>: <message>" for its exception and up to three inner
# ones, "Error ID: <id>", and "Error trace: <frame>" for the first 10 frames of its script stack.
function Get-ErrorDetail([System.Management.Automation.ErrorRecord]$ErrorRecord) {
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

# Log "STOPPED: $Message", with the lines of Get-ErrorDetail for $ErrorRecord when one is given, in
# one write (Add-LogLine), and return what Add-LogLine returns: '' or why the write failed.
function Add-StopLine([string]$Message, [System.Management.Automation.ErrorRecord]$ErrorRecord) {
    $lines = @("STOPPED: $Message")
    if ($null -ne $ErrorRecord) { $lines += @(Get-ErrorDetail -ErrorRecord $ErrorRecord) }
    Add-LogLine -Message ($lines -join "`n")
}

# Show $Message in a dialog titled $Caption, 'Portable VM' when empty, with the icon $Icon (Error,
# Warning or Information) on the default desktop, so it shows although the console is hidden.
function Show-Dialog([string]$Message, [string]$Icon, [string]$Caption) {
    if (-not $Caption) { $Caption = 'Portable VM' }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Message, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]$Icon,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1, [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
}

# Show $Message as Show-Dialog does; a dry run shows nothing. While the step below asks for
# administrator rights ($script:AskingForRights), the message is that step's warning: it is first
# logged with the error of the catch block that calls this function ($_), and the dialog says so
# when that write fails.
function Show-Message([string]$Message, [string]$Icon, [string]$Caption) {
    if ($script:AskingForRights) {
        $script:AskingForRights = $false
        $record = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_ } else { $null }
        $problem = Add-StopLine -Message $Message -ErrorRecord $record
        if ($problem) { $Message += "`n`nThe launcher could not write this message to its log, LauncherData\logs\launcher.log: $problem" }
    }
    if ($DryRun) { return }
    Show-Dialog -Message $Message -Icon $Icon -Caption $Caption
}

# Show the message of the run's result $Result, when it has one, and return $Result. A dialog that
# fails is logged with its details, and the exit code becomes 1.
function Show-Result($Result) {
    try {
        if ($Result.Message) { Show-Message -Message $Result.Message -Icon $Result.Icon -Caption $Result.Caption }
    } catch {
        $null = Add-StopLine -Message "Unexpected error while showing the message: $($_.Exception.Message)" -ErrorRecord $_
        $Result.ExitCode = 1
    }
    $Result
}

# Return whether this process runs with administrator rights.
function Test-Administrator {
    (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Return whether another run holds the lock named $Name: the mutex exists, or this process may not
# open it, as when an elevated run holds it. It never creates the mutex. When the check fails it
# says so and returns $false, and the elevated run checks again.
function Test-LockHeld([string]$Name) {
    $mutex = $null
    try { [System.Threading.Mutex]::TryOpenExisting($Name, [System.Security.AccessControl.MutexRights]::Synchronize, [ref]$mutex) }
    catch [System.UnauthorizedAccessException] { $true }
    catch {
        Write-Host "The check for another run of the launcher failed: $($_.Exception.Message)"
        $false
    } finally {
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

# Before the step below asks for administrator rights: when another run holds the lock, return the
# busy result (Get-PvmBusyMessage in the module), so that a second double-click gets no prompt;
# else log the request and let Show-Message log a declined or failed one. A dry run, or a process
# that has the rights, asks for nothing, and the module checks the lock itself.
function Invoke-RightsRequest {
    if ($DryRun -or (Test-Administrator)) { return }
    if (Test-LockHeld -Name 'Global\PortableVM-Launcher') {
        $message = 'Another run of the launcher is in progress on this PC: a start of the VM or a dry run. Wait until it has finished, then start the VM again if it is not running. Nothing was started.'
        $problem = Add-StopLine -Message $message
        if ($problem) { $message += "`n`nThe launcher could not write this message to its log, LauncherData\logs\launcher.log: $problem" }
        return [pscustomobject]@{ ExitCode = 1; Message = $message; Icon = 'Error'; Caption = 'Portable VM' }
    }
    $null = Add-LogLine -Message 'Asking for administrator rights'
    $script:AskingForRights = $true
}

# An error that no step of this script handles ends the run here: it is logged with its details
# and shown, and the exit code is 1.
trap {
    $script:AskingForRights = $false
    $message = "Unexpected error in Start-PortableVM.ps1: $($_.Exception.Message)"
    $problem = Add-StopLine -Message $message -ErrorRecord $_
    if ($problem) { $message += "`n`nThe launcher could not write this message to its log, LauncherData\logs\launcher.log: $problem" }
    try { Show-Message -Message $message -Icon 'Error' -Caption '' }
    catch { Write-Host "The message could not be shown: $($_.Exception.Message)" }
    exit 1
}

$busy = Invoke-RightsRequest
if ($null -ne $busy) {
    $busy = Show-Result -Result $busy
    exit $busy.ExitCode
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

# --- Start -------------------------------------------------------------------------------
# PortableVM.psm1 next to this script checks the settings and the stick and starts the VM. It logs
# to LauncherData\logs\launcher.log beside the Launcher folder and returns the exit code, the
# message to show and the dialog's title. Every message shows, with a note when its line could not
# be logged. A module that cannot be loaded or that fails, and a dialog that fails, are logged
# with their details as unexpected errors that name the step.

# Ask $Message as a question in a dialog titled $Caption, 'Portable VM' when empty, on the default
# desktop, with Yes and No and No as the default button, and return whether the answer is Yes.
function Show-Question([string]$Message, [string]$Caption) {
    if (-not $Caption) { $Caption = 'Portable VM' }
    Add-Type -AssemblyName System.Windows.Forms
    $answer = [System.Windows.Forms.MessageBox]::Show($Message, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2, [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
    $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

# Return the result of the unexpected error $ErrorRecord in the step $Step of this script, after
# logging it with its details: exit code 1 and "Unexpected error while <Step>: <message>".
function Get-UnexpectedResult([string]$Step, [System.Management.Automation.ErrorRecord]$ErrorRecord) {
    $message = "Unexpected error while ${Step}: $($ErrorRecord.Exception.Message)"
    $problem = Add-StopLine -Message $message -ErrorRecord $ErrorRecord
    if ($problem) { $message += "`n`nThe launcher could not write this message to its log, LauncherData\logs\launcher.log: $problem" }
    [pscustomobject]@{ ExitCode = 1; Message = $message; Icon = 'Error'; Caption = 'Portable VM' }
}

# Load PortableVM.psm1 from this folder and run the launcher (Invoke-PortableVM), which asks a
# resume question with Show-Question. Returns the run's result, or that of the error that ended it.
function Invoke-Launcher {
    try { Import-Module -Name (Join-Path $Here 'PortableVM.psm1') -Force -ErrorAction Stop }
    catch { return (Get-UnexpectedResult -Step 'loading PortableVM.psm1' -ErrorRecord $_) }
    try { Invoke-PortableVM -LauncherPath $Here -DryRun:$DryRun -AskResume { param([string]$Question, [string]$Caption) Show-Question -Message $Question -Caption $Caption } }
    catch { Get-UnexpectedResult -Step 'running the launcher' -ErrorRecord $_ }
}

# The tests set PVM_TEST so that the module's adapters refuse to run; a value left in this
# process's environment must not stop a real start.
Remove-Item -LiteralPath 'Env:\PVM_TEST' -ErrorAction SilentlyContinue
$result = Show-Result -Result (Invoke-Launcher)
exit $result.ExitCode
