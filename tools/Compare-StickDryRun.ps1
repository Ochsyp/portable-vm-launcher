# -------------------------------------------------------
#                  COMPARE STICK DRY RUN
# -------------------------------------------------------
#
# The first part of a stick check for a pull request. It lists the stick's top folders, runs a dry
# run with the launcher on the stick, deploys this clone with tools\Deploy-PortableVM.ps1, runs the
# same dry run again and compares the two. Run it in Windows PowerShell 5.1 from a clone that is
# clean at its pushed commit:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Compare-StickDryRun.ps1 -Target X:\
# -Target is the folder that holds Launcher and LauncherData. Without it the tool takes the one
# such folder at a drive's root or one level below, and stops when it finds none or several. It
# asks for administrator rights in a second window when it lacks them, and prints that window's
# result here.
#
# Any difference between the two dry runs fails the check, apart from the version line, the
# Timings line, a wait line, the note on a log moved aside and the note on little free memory. -ExpectChange names each difference
# a pull request expects, by the kinds of its two lines: 'stick found => stick found' for a changed
# line, '=> <kind>' for an added one and '<kind> =>' for a removed one. Each expected change must
# happen, on one line per pair of dry runs at most. -AlsoVirtualBox adds a pair of dry runs with
# Hypervisor set to VirtualBox. -ListOnly only lists the stick's top folders. Several expected
# changes need -Command, since through -File Windows PowerShell gives -ExpectChange only the first
# value and binds the next ones by position to -Target, -OutputFolder and -RunFolder, which the
# tool then refuses:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -Command "& '.\tools\Compare-StickDryRun.ps1' -ExpectChange '=> a', 'b => c'"
#
# It refuses, changing nothing, while a VM runs, when a write on the stick was left unfinished,
# when the clone is not clean at its pushed commit or that commit is on the stick already, and
# while the settings of a cut-off -AlsoVirtualBox run wait to be put back. It changes the stick
# only through the deploy and, for -AlsoVirtualBox, the launcher's safe write of the settings,
# which it puts back byte for byte; it checks afterwards that no other file changed. It prints
# kinds of log lines, counts and the deploy's own lines with paths masked, never a value read from
# the stick, and saves its listing and output outside the repository, below
# %LOCALAPPDATA%\PortableVM\stick-checks or -OutputFolder. Raw log lines stay in memory. The last
# line is "RESULT: PASSED - ..." or "RESULT: FAILED - <reason>"; it exits 0 or 1.

[CmdletBinding()]
param(
    [string]$Target,
    [string[]]$ExpectChange = @(),
    [switch]$AlsoVirtualBox,
    [switch]$ListOnly,
    [string]$OutputFolder,
    # Set only by the tool itself, for the window with administrator rights.
    [string]$RunFolder,
    # Values with no parameter of their own, as when powershell -File passed more expected changes
    # than there are parameters to bind them to by position; the tool refuses them.
    [Parameter(ValueFromRemainingArguments)][string[]]$Unbound = @()
)

$ErrorActionPreference = 'Stop'

# vmware-vmx% also covers the debug and stats builds of VMware's VM process.
$CompareVmProcessFilter = "Name LIKE 'vmware-vmx%' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'"
# A .cmd that starts the launcher, as tools\Deploy-PortableVM.ps1 finds it.
$CompareLauncherCmdPattern = '(?i)%~dp0\\?Launcher\\[^"\r\n]*\.ps1'
$CompareCodeFiles = @('Start-PortableVM.ps1', 'PortableVM.psm1')
$CompareCmdName = 'Start VM.cmd'
# Top-level names the listing shows as they are; any other name could be private.
$CompareKnownNames = @('Launcher', 'Launcher.previous', 'Launcher.previous.remove', 'Launcher.new', 'LauncherData', 'LauncherData.new',
    'Start VM.cmd', 'Start VM.cmd.new', 'VMware', 'VirtualBox', 'System Volume Information', '$RECYCLE.BIN')
# Folders Windows keeps at a drive's root, which nobody else may read.
$CompareSkippedNames = @('System Volume Information', '$RECYCLE.BIN')
# What an earlier deploy or migration leaves when it stops.
$CompareLeftoverNames = @('Launcher.new', 'Launcher.previous.remove', 'LauncherData.new', 'Start VM.cmd.new')
# Files of this size or more are compared by length and write time, not hashed.
$CompareHashLimit = 64MB
# The Hypervisor line of the settings, as -AlsoVirtualBox rewrites it.
$CompareHypervisorPattern = "(?m)^([ \t]*Hypervisor[ \t]*=[ \t]*)'[^'\r\n]*'"
$ComparePendingName = 'virtualbox-settings.original'

# --- Adapters: every read of the PC and every program the tool runs ------------------------------

# Throw when the tests run ($env:PVM_TEST is '1') and reached the adapter $Name unmocked.
function Assert-CompareNotUnderTest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if ($env:PVM_TEST -eq '1') { throw "$Name reached this PC during a test; mock it." }
}

# Return whether this process runs with administrator rights.
function Test-CompareAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    Assert-CompareNotUnderTest -Name $MyInvocation.MyCommand.Name
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Return the names of the VM processes, VMware's or VirtualBox's, that run on this PC.
function Get-CompareVmProcess {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Assert-CompareNotUnderTest -Name $MyInvocation.MyCommand.Name
    Get-CimInstance -ClassName Win32_Process -Filter $CompareVmProcessFilter | ForEach-Object { $_.Name }
}

# Return the root folders of the drives that are ready, such as C:\.
function Get-CompareDriveRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Assert-CompareNotUnderTest -Name $MyInvocation.MyCommand.Name
    [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName }
}

# Run git with $Arguments in the clone $RepositoryPath; return its Exit code and its Lines.
function Invoke-CompareGit {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Assert-CompareNotUnderTest -Name $MyInvocation.MyCommand.Name
    # git's stderr would stop the script under $ErrorActionPreference Stop.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& git -C $RepositoryPath @Arguments 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Lines = $lines }
}

# Run the launcher on the stick folder $Target as a dry run in Windows PowerShell 5.1, with this
# process's rights, and return its exit code. Its lines go to the stick's log, which the caller
# reads; what it prints is dropped, since it can name the stick.
function Invoke-CompareLauncher {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Target)
    Assert-CompareNotUnderTest -Name $MyInvocation.MyCommand.Name
    $script = Join-Path $Target 'Launcher\Start-PortableVM.ps1'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File $script -DryRun *>&1 }
    finally { $ErrorActionPreference = $previous }
    $LASTEXITCODE
}

# Run tools\Deploy-PortableVM.ps1 of the clone $RepositoryPath on the stick folder $Target; return
# its Exit code and its Lines.
function Invoke-CompareDeploy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Target
    )
    Assert-CompareNotUnderTest -Name $MyInvocation.MyCommand.Name
    $tool = Join-Path $RepositoryPath 'tools\Deploy-PortableVM.ps1'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File $tool -Target $Target 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Lines = $lines }
}

# Run this script again in a window with administrator rights, which Windows asks the owner for,
# for the request in the folder $Folder, and wait for it; return its exit code. Throws when the
# prompt is answered No or closed.
function Invoke-CompareElevated {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Folder
    )
    Assert-CompareNotUnderTest -Name $MyInvocation.MyCommand.Name
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"' + $ScriptPath + '"'), '-RunFolder', ('"' + $Folder + '"'))
    $process.ExitCode
}

# --- Output -----------------------------------------------------------------------------------

# Return an exception whose message, which names nothing from the stick, ends the check as its
# reason.
function ConvertTo-CompareStop {
    [CmdletBinding()]
    [OutputType([Exception])]
    param([Parameter(Mandatory)][string]$Reason)
    $exception = New-Object InvalidOperationException $Reason
    $exception.Data['CompareStop'] = $true
    $exception
}

# Print the line $Text and keep it for output.txt.
function Add-CompareLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $script:CompareOutput.Add($Text)
    Write-Host $Text
}

# Write the lines $Lines, or the bytes $Bytes, to the file $Path below the tool's output folder,
# which is on the PC, outside the repository and the stick. The one place the tool writes a file
# by itself.
function Save-CompareFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$Lines,
        [AllowEmptyCollection()][byte[]]$Bytes
    )
    if ($PSBoundParameters.ContainsKey('Bytes')) { [IO.File]::WriteAllBytes($Path, $Bytes) }
    else { [IO.File]::WriteAllLines($Path, [string[]]@($Lines), (New-Object System.Text.UTF8Encoding $false)) }
}

# Return $Text with what could name the PC, the account or the stick masked: the strings in
# $Private, paths with a drive letter, device and network paths, user folders, UUIDs and long
# numbers. For the deploy's own lines, which name no path, as a second line of defence.
function Format-CompareSafe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$Private = @(),
        [string]$Version
    )
    # The clone's version is no value from the stick, so it stays readable.
    $t = if ($Version) { $Text.Replace($Version, "`0") } else { $Text }
    foreach ($value in @($Private | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending)) {
        $t = [regex]::Replace($t, [regex]::Escape($value), '<private>', 'IgnoreCase')
    }
    $t = [regex]::Replace($t, '(?i)\b[a-z]:[\\/][^\s"'']*', '<path>')
    $t = [regex]::Replace($t, '\\\\[^\s"'']*', '<path>')
    $t = [regex]::Replace($t, '(?i)users[\\/][^\s"'']*', '<path>')
    $t = [regex]::Replace($t, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<uuid>')
    $t = [regex]::Replace($t, '\d{7,}', '<number>')
    if ($Version) { $t = $t.Replace("`0", $Version) }
    $t
}

# --- Log lines ---------------------------------------------------------------------------------

# Return the message of the launcher log line $Line: what follows the first two consecutive spaces.
function Get-CompareLogMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $Line -replace '^.*?  ', ''
}

# Return the kind of the launcher log message $Message from a fixed list, with no text the message
# holds; any other message is 'other line'. $Version, the clone's version, tells its version line
# apart.
function Get-CompareKind {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string]$Version
    )
    switch -Regex -CaseSensitive ($Message) {
        '^STOPPED: ' { return 'STOPPED line' }
        '^Error (detail|ID|trace): ' { return "error $($Matches[1]) line" }
        '^----- Start VM( \(dry run\))? -----$' { return "start line$($Matches[1])" }
        '^----- End( \(dry run\))?: exit code (\d{1,3}) -----$' { return "end line$($Matches[1]), exit code $($Matches[2])" }
        '^Launcher version (.*)$' {
            if ($Version -and $Matches[1] -ceq $Version) { return 'version line: this clone' }
            return 'version line: another version'
        }
        '^Timings: ' { return 'timings line' }
        '^Note: the earlier lines of the log are in launcher-\d{8}-\d{6}\.log\.$' { return 'note: the earlier lines were moved aside' }
        '^Note: the log could not be moved aside, ' { return 'note: the log could not be moved aside' }
        '^Note: an earlier run of the launcher ended without releasing its lock' { return 'note: lock taken over' }
        '^Note: the launcher could not release its lock' { return 'note: lock not released' }
        '^Note: Memory Integrity ' { return 'note: Memory Integrity' }
        '^Note: .* could not be (removed|put back)' { return 'note: a copy of a rewrite could not be removed or put back' }
        '^Asking for administrator rights$' { return 'asking for administrator rights' }
        '^Waiting up to 30 s for ' { return 'waiting for VBoxSVC' }
        '^Stick found: ' { return 'stick found' }
        '^VM size OK: ' { return 'VM size OK' }
        '^VM size: ' { return 'VM size changes' }
        '^VM size left as it is, because ' { return 'VM size left as it is' }
        '^Note: this PC is small for the VM' { return 'note: a PC small for the VM' }
        '^Note: this PC has less free memory' { return 'note: little free memory' }
        '^Note: HideDataPartition is no longer used' { return 'note: HideDataPartition no longer used' }
        '^Note: ProtectBootArea is no longer used' { return 'note: ProtectBootArea no longer used' }
        '^Saved state found: (suspended in VMware|saved in VirtualBox)$' { return "saved state found: $($Matches[1])" }
        '^Using (VMware|VirtualBox)$' { return "using $($Matches[1])" }
        '^Already running in (VMware|VirtualBox)\.$' { return "already running in $($Matches[1])" }
        '^VirtualBox VM state: "?([a-z]{1,20})"?$' { return "VirtualBox VM state: $($Matches[1])" }
        '^Resume of the saved state in (VMware|VirtualBox) confirmed\.$' { return "resume confirmed in $($Matches[1])" }
        '^DRY RUN - would start .* with (VMware Workstation|VirtualBox) \(' { return "would start with $($Matches[1])" }
        '^DRY RUN - a real start would ask whether to resume ' { return 'a real start would ask whether to resume' }
        '^DRY RUN - a real start would stop here: ' { return 'a real start would stop here' }
        '^DRY RUN - a real start would ask whether to set it right: ' { return 'a real start would ask whether to set right a write that did not finish' }
        '^Fix confirmed: ' { return 'fix of a write that did not finish confirmed' }
        '^Moved aside: ' { return 'a file the fix moved aside' }
        '^Renamed: ' { return 'a file the fix renamed' }
        '^Started with (VMware Workstation|VirtualBox)\b' { return "started with $($Matches[1])" }
        '^Creating .+ -> ' { return 'descriptor would be created' }
        '^[^:]+: rewritten because ' { return 'reason for the descriptor rewrite' }
        '\.vbox: drive letter OK$' { return 'the .vbox file: drive letter OK' }
        '^VirtualBox\.xml: drive letter OK$' { return 'VirtualBox.xml: drive letter OK' }
        '\.vbox: paths moved to drive [A-Za-z]:$' { return 'the .vbox file: paths would move to the drive letter' }
        '^VirtualBox\.xml: paths moved to drive [A-Za-z]:$' { return 'VirtualBox.xml: paths would move to the drive letter' }
        ' already points at the stick$' { return 'descriptor already points at the stick' }
        ' -> ' { return 'descriptor would be pointed at the stick' }
    }
    'other line'
}

# Return the messages of the dry-run lines $Lines that two launchers must log alike: all but the
# version line, the Timings line, a wait for VirtualBox's background service, the note on a log
# moved aside and the note on little free memory, which changes from minute to minute.
function Get-CompareDecision {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][string[]]$Lines = @())
    $Lines | ForEach-Object { Get-CompareLogMessage -Line $_ } | Where-Object {
        $_ -notmatch '^Launcher version ' -and $_ -notmatch '^Timings: ' -and $_ -notmatch '^Waiting up to 30 s for ' -and
        $_ -notmatch '^Note: the earlier lines of the log are in launcher-\d{8}-\d{6}\.log\.$' -and $_ -notmatch '^Note: this PC has less free memory '
    }
}

# Return how the lines $After differ from the lines $Before, compared exactly, as a list of
# Before and After: a changed line has both, a removed line only Before ($null After) and an added
# line only After. Lines in common stay aligned, so one added line is one difference. Between two
# common lines, removed and added lines pair up in order, and the rest stay removed or added.
function Get-CompareDifference {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()][string[]]$Before = @(),
        [AllowEmptyCollection()][string[]]$After = @()
    )
    $n = $Before.Count
    $m = $After.Count
    # $common[i, j]: the length of the longest common run of $Before from i and $After from j.
    $common = New-Object 'int[,]' ($n + 1), ($m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($Before[$i] -ceq $After[$j]) { $common[$i, $j] = $common[($i + 1), ($j + 1)] + 1; continue }
            $down = $common[($i + 1), $j]
            $right = $common[$i, ($j + 1)]
            $common[$i, $j] = if ($down -ge $right) { $down } else { $right }
        }
    }
    $removed = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.Generic.List[string]
    $differences = New-Object System.Collections.Generic.List[object]
    # A block of removed and added lines between two common ones pairs up as changed lines.
    $flush = {
        for ($k = 0; $k -lt [Math]::Max($removed.Count, $added.Count); $k++) {
            $differences.Add([pscustomobject]@{
                    Before = if ($k -lt $removed.Count) { $removed[$k] } else { $null }
                    After  = if ($k -lt $added.Count) { $added[$k] } else { $null }
                })
        }
        $removed.Clear()
        $added.Clear()
    }
    $i = 0
    $j = 0
    while ($i -lt $n -or $j -lt $m) {
        if ($i -lt $n -and $j -lt $m -and $Before[$i] -ceq $After[$j]) {
            . $flush
            $i++
            $j++
        } elseif ($j -ge $m -or ($i -lt $n -and $common[($i + 1), $j] -ge $common[$i, ($j + 1)])) {
            $removed.Add($Before[$i])
            $i++
        } else {
            $added.Add($After[$j])
            $j++
        }
    }
    . $flush
    $differences.ToArray()
}

# Return the expected change $Text, '<kind before> => <kind after>', as its Text, Before and After
# kinds, an empty side meaning a line added or removed. Throws a stop when it has another form.
function ConvertFrom-CompareExpectation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parts = @($Text -split ' ?=> ?', 0, 'RegexMatch')
    if ($parts.Count -ne 2 -or -not ($parts[0].Trim() -or $parts[1].Trim())) {
        throw (ConvertTo-CompareStop -Reason "-ExpectChange '$Text' is not of the form '<kind before> => <kind after>'; nothing was changed")
    }
    [pscustomobject]@{ Text = "$($parts[0].Trim()) => $($parts[1].Trim())".Trim(); Before = $parts[0].Trim(); After = $parts[1].Trim() }
}

# Compare the dry-run pairs $Pairs, each with its Name, the Before and After log lines and their
# BeforeExit and AfterExit codes, against the expected changes $Expected
# (ConvertFrom-CompareExpectation). Every difference must be expected, each expectation may match
# one line per pair and must match at least one in all, and the exit codes must agree. Returns
# Problems, the reasons it fails, and Lines, a summary per pair; both name kinds and counts only.
function Test-CompareChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object[]]$Pairs,
        [AllowEmptyCollection()][object[]]$Expected = @(),
        [string]$Version
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $lines = New-Object System.Collections.Generic.List[string]
    $total = @(0) * $Expected.Count
    foreach ($pair in $Pairs) {
        $before = @(Get-CompareDecision -Lines $pair.Before)
        $after = @(Get-CompareDecision -Lines $pair.After)
        $differences = @(Get-CompareDifference -Before $before -After $after)
        $used = @($false) * $Expected.Count
        $unexpected = 0
        foreach ($difference in $differences) {
            $kinds = @($difference.Before, $difference.After | ForEach-Object { if ($null -eq $_) { '' } else { Get-CompareKind -Message $_ -Version $Version } })
            $text = "$($kinds[0]) => $($kinds[1])".Trim()
            $match = -1
            for ($k = 0; $k -lt $Expected.Count; $k++) {
                if (-not $used[$k] -and $Expected[$k].Text -ceq $text) { $match = $k; break }
            }
            if ($match -ge 0) {
                $used[$match] = $true
                $total[$match]++
                $lines.Add("  $($pair.Name): expected change: '$text'")
            } else {
                $unexpected++
                $lines.Add("  $($pair.Name): unexpected change: '$text'")
            }
        }
        $lines.Add("  $($pair.Name): lines that differ, apart from the version, Timings and a wait line: $($differences.Count) of $($before.Count)/$($after.Count); exit codes $($pair.BeforeExit) and $($pair.AfterExit)")
        if ($unexpected) { $problems.Add("the dry runs ($($pair.Name)) differ in $unexpected line(s) that no -ExpectChange names") }
        if ($pair.BeforeExit -ne $pair.AfterExit) { $problems.Add("the dry runs ($($pair.Name)) ended with different exit codes") }
    }
    for ($k = 0; $k -lt $Expected.Count; $k++) {
        if ($total[$k] -eq 0) { $problems.Add("the expected change '$($Expected[$k].Text)' did not happen") }
    }
    [pscustomobject]@{ Problems = $problems.ToArray(); Lines = $lines.ToArray() }
}

# --- The stick ---------------------------------------------------------------------------------

# Return why -Target $Target, -OutputFolder $OutputFolder or -RunFolder $RunFolder cannot be
# meant as given, or '' when none of them holds '=>', as an expected change does ('a => b', '=> b',
# 'a =>' or 'a=>b') and no Windows path can, and $Unbound, the values no parameter took, is empty:
# then the tool was started through powershell -File with several values after -ExpectChange,
# which bound the next ones to those three by position and left the rest unbound.
function Get-CompareArgumentProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Target = '',
        [AllowEmptyString()][string]$OutputFolder = '',
        [AllowEmptyString()][string]$RunFolder = '',
        [AllowEmptyCollection()][string[]]$Unbound = @()
    )
    $names = @(
        if ($Target.Contains('=>')) { '-Target' }
        if ($OutputFolder.Contains('=>')) { '-OutputFolder' }
        if ($RunFolder.Contains('=>')) { '-RunFolder' }
        if ($Unbound.Count) { 'values that no parameter takes' }
    )
    if (-not $names.Count) { return '' }
    $what = if ($names.Count -eq 1) { "$($names[0]) looks like an expected change" }
    else { "$($names[0..($names.Count - 2)] -join ', ') and $($names[-1]) look like expected changes" }
    ("$what. Through powershell -File, -ExpectChange gets only the first of several values, and the next ones go to -Target, -OutputFolder and -RunFolder, the rest to no parameter. " +
        "Pass several expected changes with powershell -Command `"& '<tool>' -ExpectChange 'a', 'b'`"; nothing was changed")
}

# Return the SHA-256 hash of the file $Path in lowercase hex.
function Get-CompareHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

# Return every file below the stick folder $Target, apart from the folders Windows keeps at a
# drive's root, with its Path below $Target and its Hash; a file of $CompareHashLimit or more has
# its length and write time instead. Throws when a folder or file cannot be read.
function Get-CompareManifest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Target)
    $root = $Target.TrimEnd('\') + '\'
    foreach ($item in @(Get-ChildItem -LiteralPath $Target -Force | Where-Object { $CompareSkippedNames -notcontains $_.Name })) {
        $files = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force) } else { @($item) }
        foreach ($file in $files) {
            $hash = if ($file.Length -lt $CompareHashLimit) { Get-CompareHash -Path $file.FullName } else { "length $($file.Length), written $($file.LastWriteTimeUtc.Ticks)" }
            [pscustomobject]@{ Path = $file.FullName.Substring($root.Length); Hash = $hash }
        }
    }
}

# Return the names of the .cmd files directly in $Target that start the launcher.
function Get-CompareLauncherCmd {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Target)
    Get-ChildItem -LiteralPath $Target -Filter '*.cmd' -File -Force | Where-Object {
        $_.Extension -eq '.cmd' -and [IO.File]::ReadAllText($_.FullName) -match $CompareLauncherCmdPattern
    } | ForEach-Object { $_.Name }
}

# Return the version in the VERSION file of the launcher folder $Folder, or '' when there is none.
function Get-CompareFolderVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Folder)
    $path = Join-Path $Folder 'VERSION'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path)).Trim()
}

# Return the listing of the stick folder $Target, whose files $Manifest holds (Get-CompareManifest):
# Labels, each top-level name with the label the output uses for it, and Lines, one per top-level
# folder or file with its kind and the kinds of the files it holds. A name not in
# $CompareKnownNames shows as "other folder <n>" or "other file <n>", so the listing names nothing
# private. $Version, the clone's version, tells a launcher copy of it apart.
function Get-CompareListing {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [AllowEmptyCollection()][object[]]$Manifest = @(),
        [string]$Version
    )
    $labels = @{}
    $lines = New-Object System.Collections.Generic.List[string]
    $folders = 0
    $others = 0
    $cmds = @(Get-CompareLauncherCmd -Target $Target)
    foreach ($item in @(Get-ChildItem -LiteralPath $Target -Force | Sort-Object Name)) {
        $known = $CompareKnownNames -contains $item.Name
        if ($item.PSIsContainer) {
            if (-not $known) { $folders++ }
            $label = if ($known) { $item.Name } else { "other folder $folders" }
            if ($CompareSkippedNames -contains $item.Name) {
                $lines.Add("  ${label}: folder of Windows, not read")
            } else {
                $prefix = $item.Name + '\'
                $names = @($Manifest | Where-Object { $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Split-Path $_.Path -Leaf })
                $groups = @($names | ForEach-Object {
                        $extension = [IO.Path]::GetExtension($_).ToLowerInvariant()
                        if (-not $extension) { 'no extension' } elseif ($extension -match '^\.[a-z0-9]{1,10}$') { $extension } else { 'other' }
                    } | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" })
                $what = if ($names.Count) { "$($names.Count) file(s): $($groups -join ', ')" } else { 'no files' }
                $launcher = ''
                if (Test-Path -LiteralPath (Join-Path $item.FullName 'Start-PortableVM.ps1') -PathType Leaf) {
                    $folderVersion = Get-CompareFolderVersion -Folder $item.FullName
                    $launcher = if (-not $folderVersion) { ', a launcher copy without VERSION' } elseif ($Version -and $folderVersion -ceq $Version) { ', a launcher copy of this clone' } else { ', a launcher copy of another version' }
                }
                $lines.Add("  ${label}: folder$launcher, $what")
            }
        } else {
            if (-not $known) { $others++ }
            $label = if ($known) { $item.Name } else { "other file $others" }
            $extension = [IO.Path]::GetExtension($item.Name).ToLowerInvariant()
            $kind = if (-not $extension) { 'no extension' } elseif ($extension -match '^\.[a-z0-9]{1,10}$') { $extension } else { 'other' }
            $starts = if ($cmds -contains $item.Name) { ', starts the launcher' } else { '' }
            $lines.Add("  ${label}: file ($kind$starts)")
        }
        $labels[$item.Name] = $label
    }
    [pscustomobject]@{ Labels = $labels; Lines = $lines.ToArray() }
}

# Return what a write or deploy that did not finish left on the stick folder $Target, whose files
# $Manifest holds: the leftover names at its top and a count of .pvm-tmp and .pvm-old files, but
# not of those that the launcher's guided fix put aside below LauncherData\backups\removed.
function Get-CompareLeftover {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [AllowEmptyCollection()][object[]]$Manifest = @()
    )
    foreach ($name in $CompareLeftoverNames) {
        if (Test-Path -LiteralPath (Join-Path $Target $name)) { $name }
    }
    $copies = @($Manifest | Where-Object { ($_.Path -like '*.pvm-tmp' -or $_.Path -like '*.pvm-old') -and $_.Path -notmatch '\ALauncherData[\\/]backups[\\/]removed[\\/]' }).Count
    if ($copies) { "$copies .pvm-tmp or .pvm-old file(s)" }
}

# Return the stick folders the tool can find by itself: each ready drive's root, or a folder
# directly in it, that holds Launcher\Start-PortableVM.ps1 and LauncherData\settings.psd1.
function Find-CompareStick {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($root in @(Get-CompareDriveRoot)) {
        $folders = @($root) + @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        foreach ($folder in $folders) {
            # A folder this account may not read is no stick folder.
            if ((Test-Path -LiteralPath (Join-Path $folder 'Launcher\Start-PortableVM.ps1') -PathType Leaf -ErrorAction SilentlyContinue) -and
                (Test-Path -LiteralPath (Join-Path $folder 'LauncherData\settings.psd1') -PathType Leaf -ErrorAction SilentlyContinue)) { $folder }
        }
    }
}

# Return whether the path $Path is the folder $Folder or below it.
function Test-CompareBelow {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Folder
    )
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    $f = [IO.Path]::GetFullPath($Folder).TrimEnd('\') + '\'
    $p.StartsWith($f, [StringComparison]::OrdinalIgnoreCase)
}

# Return the state of the clone $RepositoryPath: Version, as git describe gives it and the deploy
# writes it, and Problem, '' when it is clean and at its pushed commit, else the reason.
function Get-CompareClone {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepositoryPath)
    $status = Invoke-CompareGit -RepositoryPath $RepositoryPath -Arguments @('status', '--porcelain')
    $head = Invoke-CompareGit -RepositoryPath $RepositoryPath -Arguments @('rev-parse', 'HEAD')
    $pushed = Invoke-CompareGit -RepositoryPath $RepositoryPath -Arguments @('rev-parse', '@{u}')
    $describe = Invoke-CompareGit -RepositoryPath $RepositoryPath -Arguments @('describe', '--tags', '--always', '--dirty')
    $version = if ($describe.Exit -eq 0 -and $describe.Lines.Count -eq 1) { $describe.Lines[0].Trim() } else { '' }
    $problem = if ($status.Exit -ne 0 -or $head.Exit -ne 0 -or -not $version) { 'git could not read the clone' }
    elseif ($status.Lines.Count) { 'the clone has changes that are not committed' }
    elseif ($pushed.Exit -ne 0) { 'the clone''s branch has no pushed upstream' }
    elseif ("$($head.Lines)".Trim() -cne "$($pushed.Lines)".Trim()) { 'the clone is not at its pushed commit' }
    else { '' }
    [pscustomobject]@{ Version = $version; Problem = $problem }
}

# --- Settings for -AlsoVirtualBox ----------------------------------------------------------------

# Set the Hypervisor line of the settings file $SettingsPath to VirtualBox through the launcher's
# safe write, changing no other byte. The bytes before go to $PendingPath on the PC first, so a
# run that is cut off leaves the way back. Returns Original and Changed, the bytes before and
# after.
function Write-CompareHypervisor {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SettingsPath,
        [Parameter(Mandatory)][string]$PendingPath
    )
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $original = [IO.File]::ReadAllBytes($SettingsPath)
    $text = $latin1.GetString($original)
    if (([regex]::Matches($text, $CompareHypervisorPattern)).Count -ne 1) { throw (ConvertTo-CompareStop -Reason 'the settings file has no single Hypervisor line, so -AlsoVirtualBox cannot set it') }
    $changed = $latin1.GetBytes([regex]::Replace($text, $CompareHypervisorPattern, '${1}''VirtualBox'''))
    if (-not (Test-PvmSameContent -Left $original -Right $changed)) {
        Save-CompareFile -Path $PendingPath -Bytes $original
        $left = Write-PvmFile -Path $SettingsPath -Bytes $changed -Expected $original
        if ($left) { throw (ConvertTo-CompareStop -Reason 'the safe write of the settings left a .pvm-old copy beside them') }
    }
    [pscustomobject]@{ Original = $original; Changed = $changed }
}

# Put the bytes $Original back into the settings file $SettingsPath through the safe write, when it
# holds $Changed, and check them; then move $PendingPath into the run folder $Folder. Throws a stop
# when the file holds anything else, which it leaves as it is.
function Undo-CompareHypervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SettingsPath,
        [Parameter(Mandatory)][byte[]]$Original,
        [Parameter(Mandatory)][byte[]]$Changed,
        [Parameter(Mandatory)][string]$PendingPath,
        [Parameter(Mandatory)][string]$Folder
    )
    $current = [IO.File]::ReadAllBytes($SettingsPath)
    if (-not (Test-PvmSameContent -Left $current -Right $Original)) {
        if (-not (Test-PvmSameContent -Left $current -Right $Changed)) {
            throw (ConvertTo-CompareStop -Reason "the settings file changed during the VirtualBox dry run, so it was left as it is; its bytes before are in $ComparePendingName in the tool's output folder")
        }
        $left = Write-PvmFile -Path $SettingsPath -Bytes $Original -Expected $current
        if ($left) { throw (ConvertTo-CompareStop -Reason "the safe write that put the settings back left a .pvm-old copy beside them; the bytes before are in $ComparePendingName in the tool's output folder") }
    }
    if (-not (Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($SettingsPath)) -Right $Original)) {
        throw (ConvertTo-CompareStop -Reason "the settings file was not put back; its bytes before are in $ComparePendingName in the tool's output folder")
    }
    if (Test-Path -LiteralPath $PendingPath) {
        $kept = @(Get-ChildItem -LiteralPath $Folder -Filter "$ComparePendingName.*").Count
        Move-Item -LiteralPath $PendingPath -Destination (Join-Path $Folder "$ComparePendingName.$($kept + 1)")
    }
}

# --- Dry runs ----------------------------------------------------------------------------------

# Return the log's length and its first 64 bytes, to find later what a run added.
function Get-CompareLogMark {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Length = 0; Head = [byte[]]@() } }
    $bytes = [IO.File]::ReadAllBytes($Path)
    [pscustomobject]@{ Length = $bytes.Length; Head = [byte[]]@($bytes | Select-Object -First 64) }
}

# Return the lines the log $Path got after the mark $Mark (Get-CompareLogMark): all of it when it
# was moved aside and started anew, else what follows the marked length.
function Get-CompareLogAddition {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Mark
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $head = [byte[]]@($bytes | Select-Object -First $Mark.Head.Length)
    $same = $bytes.Length -ge $Mark.Length -and [Convert]::ToBase64String($head) -ceq [Convert]::ToBase64String($Mark.Head)
    $start = if ($same) { $Mark.Length } else { 0 }
    $text = (Get-PvmAnsiEncoding).GetString($bytes, $start, $bytes.Length - $start)
    $text -split "`r`n|`n" | Where-Object { $_ -ne '' }
}

# Run one dry run with the launcher on the stick in the context $Context, with Hypervisor set to
# VirtualBox for it when -VirtualBox is given, and return its Exit code and the log Lines it added.
function Invoke-CompareDryRun {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [switch]$VirtualBox
    )
    $mark = Get-CompareLogMark -Path $Context.Log
    $change = $null
    if ($VirtualBox) { $change = Write-CompareHypervisor -SettingsPath $Context.Settings -PendingPath $Context.Pending }
    try { $exit = Invoke-CompareLauncher -Target $Context.Target }
    finally {
        if ($change) { Undo-CompareHypervisor -SettingsPath $Context.Settings -Original $change.Original -Changed $change.Changed -PendingPath $Context.Pending -Folder $Context.RunFolder }
    }
    [pscustomobject]@{ Exit = $exit; Lines = @(Get-CompareLogAddition -Path $Context.Log -Mark $mark) }
}

# Run the dry runs of one step, as configured and, with $Context.AlsoVirtualBox, with VirtualBox,
# and print the kinds of their lines; return them by name.
function Invoke-CompareDryRunStep {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $runs = [ordered]@{}
    foreach ($name in $Context.PairNames) {
        $run = Invoke-CompareDryRun -Context $Context -VirtualBox:($name -eq 'VirtualBox')
        Add-CompareLine "  dry run $($name): exit code $($run.Exit), $($run.Lines.Count) log line(s)"
        foreach ($line in $run.Lines) { Add-CompareLine "    $(Get-CompareKind -Message (Get-CompareLogMessage -Line $line) -Version $Context.Version)" }
        $runs[$name] = $run
    }
    $runs
}

# Return whether the path $Path below the stick folder is one the file comparison leaves out: below
# one of the folders $Prefixes (each ending in a backslash), or one of the names $Names.
function Test-CompareSkipped {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$Prefixes = @(),
        [AllowEmptyCollection()][string[]]$Names = @()
    )
    foreach ($prefix in $Prefixes) { if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    foreach ($name in $Names) { if ($Path -eq $name) { return $true } }
    $false
}

# Return how the files $After differ from $Before (both from Get-CompareManifest), apart from those
# Test-CompareSkipped leaves out for $Prefixes and $Names: the Changed, Added and Removed paths and
# the Count compared.
function Get-CompareFileChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()][object[]]$Before = @(),
        [AllowEmptyCollection()][object[]]$After = @(),
        [AllowEmptyCollection()][string[]]$Prefixes = @(),
        [AllowEmptyCollection()][string[]]$Names = @()
    )
    $old = @{}
    foreach ($row in $Before) { if (-not (Test-CompareSkipped -Path $row.Path -Prefixes $Prefixes -Names $Names)) { $old[$row.Path.ToLowerInvariant()] = $row } }
    $new = @{}
    foreach ($row in $After) { if (-not (Test-CompareSkipped -Path $row.Path -Prefixes $Prefixes -Names $Names)) { $new[$row.Path.ToLowerInvariant()] = $row } }
    [pscustomobject]@{
        Changed = @($old.Keys | Where-Object { $new.ContainsKey($_) -and $new[$_].Hash -cne $old[$_].Hash } | ForEach-Object { $old[$_].Path })
        Added   = @($new.Keys | Where-Object { -not $old.ContainsKey($_) } | ForEach-Object { $new[$_].Path })
        Removed = @($old.Keys | Where-Object { -not $new.ContainsKey($_) } | ForEach-Object { $old[$_].Path })
        Count   = $old.Count
    }
}

# Return the files of $Manifest below the folder $Prefix (ending in a backslash) as sorted
# "<path below it>|<hash>" lines.
function Get-CompareRow {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][object[]]$Manifest = @(),
        [Parameter(Mandatory)][string]$Prefix
    )
    $Manifest | Where-Object { $_.Path.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { "$($_.Path.Substring($Prefix.Length))|$($_.Hash)" } | Sort-Object
}

# Return the top-level labels (from $Labels, a listing's) of the paths $Paths, without repeats, so
# a message can say where files changed without naming them.
function Get-CompareWhere {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][string[]]$Paths = @(),
        [Parameter(Mandatory)][hashtable]$Labels
    )
    @($Paths | ForEach-Object {
            $top = ($_ -split '\\')[0]
            if ($Labels.ContainsKey($top)) { $Labels[$top] } else { 'a new top-level name' }
        } | Sort-Object -Unique) -join ', '
}

# --- The check ---------------------------------------------------------------------------------

# Run the steps after the listing on the stick folder $Target, as the header of this file
# describes: the checks before any change, the dry runs, the deploy and the comparison. $Clone is
# Get-CompareClone's, $First and $Listing the files and the listing before anything ran, and
# $Folder the run folder. Throws a stop with the reason when the check fails; returns what passed.
function Invoke-CompareCheck {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Target,
        [AllowEmptyCollection()][object[]]$Expected = @(),
        [switch]$AlsoVirtualBox,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][pscustomobject]$Clone,
        [AllowEmptyCollection()][object[]]$First = @(),
        [Parameter(Mandatory)][pscustomobject]$Listing
    )
    Add-CompareLine '--- Checks before any change'
    if (-not (Test-CompareAdministrator)) { throw (ConvertTo-CompareStop -Reason 'the check needs administrator rights; nothing was changed') }
    if (@(Get-CompareVmProcess).Count) { throw (ConvertTo-CompareStop -Reason 'a VM runs on this PC; shut the guest down first. Nothing was changed') }
    $left = @(Get-CompareLeftover -Target $Target -Manifest $First)
    if ($left.Count) { throw (ConvertTo-CompareStop -Reason "a write or deploy that did not finish left $($left -join ', '); nothing was changed") }
    foreach ($required in @('Launcher\Start-PortableVM.ps1', 'LauncherData\settings.psd1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Target $required) -PathType Leaf)) { throw (ConvertTo-CompareStop -Reason "the stick folder has no $required; nothing was changed") }
    }
    $settings = Join-Path $Target 'LauncherData\settings.psd1'
    $pending = Join-Path $OutputFolder $ComparePendingName
    if (Test-Path -LiteralPath $pending) {
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($pending)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($settings))) {
            throw (ConvertTo-CompareStop -Reason ("an earlier run with -AlsoVirtualBox was cut off before it put the settings back. Copy $ComparePendingName from the tool's output folder " +
                    'over LauncherData\settings.psd1 on the stick, move it out of that folder, then run the check again. Nothing was changed'))
        }
        Move-Item -LiteralPath $pending -Destination (Join-Path $Folder "$ComparePendingName.earlier")
        Add-CompareLine '  the settings of an earlier -AlsoVirtualBox run were back in place already'
    }
    if ($Clone.Problem) { throw (ConvertTo-CompareStop -Reason "$($Clone.Problem); commit and push first. Nothing was changed") }
    if ((Get-CompareFolderVersion -Folder (Join-Path $Target 'Launcher')) -ceq $Clone.Version) {
        throw (ConvertTo-CompareStop -Reason "the stick's Launcher holds the clone's commit already, so there is nothing to compare; run the check once per commit. Nothing was changed")
    }
    if ($AlsoVirtualBox -and ([regex]::Matches([Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($settings)), $CompareHypervisorPattern)).Count -ne 1) {
        throw (ConvertTo-CompareStop -Reason 'the settings file has no single Hypervisor line, so -AlsoVirtualBox cannot set it; nothing was changed')
    }
    Add-CompareLine "  no VM runs, no write was left unfinished, and the clone is clean at its pushed commit $($Clone.Version)"
    $null = Import-Module -Name (Join-Path $RepositoryPath 'src\PortableVM.psm1') -Force -Global -DisableNameChecking
    $context = [pscustomobject]@{
        Target    = $Target
        Settings  = $settings
        Log       = Join-Path $Target 'LauncherData\logs\launcher.log'
        Pending   = $pending
        RunFolder = $Folder
        Version   = $Clone.Version
        PairNames = if ($AlsoVirtualBox) { @('as configured', 'VirtualBox') } else { @('as configured') }
    }

    Add-CompareLine '--- Step 1: the dry run with the launcher on the stick'
    $before = Invoke-CompareDryRunStep -Context $context
    foreach ($name in $context.PairNames) {
        $run = $before[$name]
        if ($run.Exit -ne 0) { throw (ConvertTo-CompareStop -Reason "the dry run ($name) with the launcher on the stick ended with exit code $($run.Exit); nothing was deployed") }
        if (-not @($run.Lines | Where-Object { (Get-CompareLogMessage -Line $_) -like '----- End*' }).Count) { throw (ConvertTo-CompareStop -Reason "the dry run ($name) added no End line to the log; nothing was deployed") }
    }
    $logs = 'LauncherData\logs\'
    $beforeDeploy = @(Get-CompareManifest -Target $Target)
    $drift = Get-CompareFileChange -Before $First -After $beforeDeploy -Prefixes $logs
    if ($drift.Changed.Count + $drift.Added.Count + $drift.Removed.Count) { throw (ConvertTo-CompareStop -Reason 'the dry runs with the launcher on the stick changed a file other than the log; nothing was deployed') }
    $cmds = @(Get-CompareLauncherCmd -Target $Target)
    $topBefore = @(Get-ChildItem -LiteralPath $Target -Force -Name)

    Add-CompareLine '--- Step 2: the deploy of this clone'
    $private = @($Target) + @($Target.Substring([Math]::Min(3, $Target.Length)) -split '\\' | Where-Object { $_.Length -ge 3 }) + @($env:COMPUTERNAME, $env:USERNAME)
    try {
        $values = Import-PowerShellDataFile -LiteralPath $settings
        $private += @($values['VmDisplayName'], $values['GuestName'])
    } catch {
        Write-Verbose 'The names in the settings cannot be read to mask them.'
    }
    $deploy = Invoke-CompareDeploy -RepositoryPath $RepositoryPath -Target $Target
    Add-CompareLine "  deploy: exit code $($deploy.Exit)"
    foreach ($line in $deploy.Lines) { Add-CompareLine "  $(Format-CompareSafe -Text $line -Private $private -Version $Clone.Version)" }
    if ($deploy.Exit -ne 0 -or @($deploy.Lines | Where-Object { $_ -ceq "Deploy-PortableVM: deployed $($Clone.Version) (Update)." }).Count -ne 1) {
        throw (ConvertTo-CompareStop -Reason 'the deploy did not pass')
    }
    if ((Get-CompareFolderVersion -Folder (Join-Path $Target 'Launcher')) -cne $Clone.Version) { throw (ConvertTo-CompareStop -Reason 'after the deploy, Launcher does not hold the clone''s commit') }

    Add-CompareLine '--- Step 3: the same dry run with the deployed launcher'
    $after = Invoke-CompareDryRunStep -Context $context

    Add-CompareLine '--- Step 4: the comparison of the dry runs'
    $pairs = @(foreach ($name in $context.PairNames) {
            [pscustomobject]@{ Name = $name; Before = $before[$name].Lines; After = $after[$name].Lines; BeforeExit = $before[$name].Exit; AfterExit = $after[$name].Exit }
        })
    $comparison = Test-CompareChange -Pairs $pairs -Expected $Expected -Version $Clone.Version
    foreach ($line in $comparison.Lines) { Add-CompareLine $line }
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($problem in $comparison.Problems) { $problems.Add($problem) }

    Add-CompareLine '--- Step 5: the folders and files'
    $afterDeploy = @(Get-CompareManifest -Target $Target)
    $files = Get-CompareFileChange -Before $beforeDeploy -After $afterDeploy -Prefixes @('Launcher\', 'Launcher.previous\', $logs) -Names (@($CompareCmdName) + $cmds)
    $changes = @($files.Changed) + @($files.Added) + @($files.Removed)
    Add-CompareLine "  files outside the launcher folders, the launcher's .cmd and the logs: $($files.Changed.Count) changed, $($files.Added.Count) added, $($files.Removed.Count) removed, of $($files.Count)"
    if ($changes.Count) { $problems.Add("files outside the launcher folders changed, in: $(Get-CompareWhere -Paths $changes -Labels $Listing.Labels)") }

    # Launcher.previous holds what Launcher held, plus the launcher's .cmd files from the root.
    $wanted = @(@(Get-CompareRow -Manifest $beforeDeploy -Prefix 'Launcher\') + @($beforeDeploy | Where-Object { $cmds -contains $_.Path } | ForEach-Object { "$($_.Path)|$($_.Hash)" }) | Sort-Object)
    $previousSame = (@(Get-CompareRow -Manifest $afterDeploy -Prefix 'Launcher.previous\') -join "`n") -ceq ($wanted -join "`n")
    Add-CompareLine "  Launcher.previous holds what Launcher held, plus the launcher's .cmd: $(if ($previousSame) { 'yes' } else { 'no' })"
    if (-not $previousSame) { $problems.Add('Launcher.previous does not hold what Launcher held before the deploy') }

    # Launcher and the .cmd at the root are the clone's.
    $launcherNames = @(Get-CompareRow -Manifest $afterDeploy -Prefix 'Launcher\' | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object)
    $launcherSame = ($launcherNames -join '|') -ceq (@('PortableVM.psm1', 'SHA256SUMS', 'Start-PortableVM.ps1', 'VERSION') -join '|')
    foreach ($name in $CompareCodeFiles) {
        $row = @($afterDeploy | Where-Object { $_.Path -eq "Launcher\$name" })
        if ($row.Count -ne 1 -or $row[0].Hash -cne (Get-CompareHash -Path (Join-Path $RepositoryPath "src\$name"))) { $launcherSame = $false }
    }
    $cmdRow = @($afterDeploy | Where-Object { $_.Path -eq $CompareCmdName })
    $cmdSame = $cmdRow.Count -eq 1 -and $cmdRow[0].Hash -ceq (Get-CompareHash -Path (Join-Path $RepositoryPath $CompareCmdName))
    Add-CompareLine "  Launcher and $CompareCmdName are the clone's: $(if ($launcherSame -and $cmdSame) { 'yes' } else { 'no' })"
    if (-not ($launcherSame -and $cmdSame)) { $problems.Add("Launcher or $CompareCmdName is not the clone's after the deploy") }

    # The top-level names are those of the listing, apart from the launcher's .cmd files and
    # Launcher.previous.
    $expectedTop = @(@($topBefore | Where-Object { $cmds -notcontains $_ }) + @($CompareCmdName, 'Launcher.previous') | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $topAfter = @(Get-ChildItem -LiteralPath $Target -Force -Name | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $topSame = ($expectedTop -join '|') -ceq ($topAfter -join '|')
    Add-CompareLine "  the top-level folders and files are those of the listing, apart from Launcher.previous and the launcher's .cmd: $(if ($topSame) { 'yes' } else { 'no' })"
    if (-not $topSame) { $problems.Add('the top-level folders and files after the deploy are not those of the listing') }
    $leftAfter = @(Get-CompareLeftover -Target $Target -Manifest $afterDeploy)
    if ($leftAfter.Count) { $problems.Add("the deploy left $($leftAfter -join ', ')") }

    if ($problems.Count) { throw (ConvertTo-CompareStop -Reason ($problems -join '; ')) }
    $what = if ($Expected.Count) { "only the $($Expected.Count) expected change(s)" } else { 'no difference' }
    "deployed $($Clone.Version); the dry runs show $what, and no other file changed"
}

# Run the check on the stick folder $Target ('' to find it) with the clone $RepositoryPath, as the
# header of this file describes. The run folder $Folder, below $OutputFolder, gets listing.txt and
# output.txt. Returns ExitCode, 0 or 1, and Lines, what it printed.
function Invoke-StickCompare {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [AllowEmptyString()][string]$Target = '',
        [AllowEmptyCollection()][string[]]$ExpectChange = @(),
        [switch]$AlsoVirtualBox,
        [switch]$ListOnly,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][string]$Folder
    )
    $script:CompareOutput = New-Object System.Collections.Generic.List[string]
    $exitCode = 1
    # output.txt is saved unless the run folder is in the repository or on the stick, so a refusal
    # before the stick is known still reaches the first window.
    $canSave = -not (Test-CompareBelow -Path $Folder -Folder $RepositoryPath)
    try {
        $expected = @($ExpectChange | Where-Object { $null -ne $_ } | ForEach-Object { ConvertFrom-CompareExpectation -Text $_ })
        if (-not $Target) {
            $found = @(Find-CompareStick | Where-Object { -not (Test-CompareBelow -Path $_ -Folder $RepositoryPath) })
            if ($found.Count -ne 1) { throw (ConvertTo-CompareStop -Reason "found $($found.Count) folders with Launcher and LauncherData at a drive's root or one level below; give -Target. Nothing was changed") }
            $Target = $found[0]
            Add-CompareLine 'Compare-StickDryRun: the stick folder was found by its Launcher and LauncherData folders.'
        }
        if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw (ConvertTo-CompareStop -Reason 'the -Target folder does not exist; nothing was changed') }
        $Target = [IO.Path]::GetFullPath($Target)
        if ($Target.Length -gt 3) { $Target = $Target.TrimEnd('\') }
        if (Test-CompareBelow -Path $Target -Folder $RepositoryPath) { throw (ConvertTo-CompareStop -Reason 'the -Target folder is in the repository; nothing was changed') }
        foreach ($path in $OutputFolder, $Folder) {
            if ((Test-CompareBelow -Path $path -Folder $Target) -or (Test-CompareBelow -Path $path -Folder $RepositoryPath)) {
                $canSave = $false
                throw (ConvertTo-CompareStop -Reason 'the output folder is on the stick or in the repository, where the check must not write; nothing was changed')
            }
        }
        $clone = Get-CompareClone -RepositoryPath $RepositoryPath

        # The listing comes first, so that what the check expects of the folders is read from the
        # stick, not guessed.
        $first = @(Get-CompareManifest -Target $Target)
        $listing = Get-CompareListing -Target $Target -Manifest $first -Version $clone.Version
        Add-CompareLine "--- The stick's top folders and files, saved as listing.txt in the run folder"
        foreach ($line in $listing.Lines) { Add-CompareLine $line }
        Save-CompareFile -Path (Join-Path $Folder 'listing.txt') -Lines $listing.Lines
        if ($ListOnly) { $passed = 'listed the stick; nothing was run or changed' }
        else {
            $check = @{
                RepositoryPath = $RepositoryPath; Target = $Target; Expected = $expected; AlsoVirtualBox = $AlsoVirtualBox
                OutputFolder = $OutputFolder; Folder = $Folder; Clone = $clone; First = $first; Listing = $listing
            }
            $passed = Invoke-CompareCheck @check
        }
        Add-CompareLine "RESULT: PASSED - $passed"
        $exitCode = 0
    } catch {
        $reason = if ($_.Exception.Data['CompareStop']) { $_.Exception.Message }
        elseif (Get-Command -Name Get-PvmErrorCause -ErrorAction SilentlyContinue) { "unexpected error: $(Get-PvmErrorCause -ErrorRecord $_)" }
        else { "unexpected error of type $($_.Exception.GetType().Name)" }
        Add-CompareLine "RESULT: FAILED - $reason"
    } finally {
        if ($canSave) { Save-CompareFile -Path (Join-Path $Folder 'output.txt') -Lines $script:CompareOutput.ToArray() }
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $script:CompareOutput.ToArray() }
}

# Return a new run folder below $OutputFolder, named for the time now, creating both.
function Get-CompareRunFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$OutputFolder)
    $name = Get-Date -Format 'yyyyMMdd-HHmmss'
    $folder = Join-Path $OutputFolder $name
    for ($n = 2; Test-Path -LiteralPath $folder; $n++) { $folder = Join-Path $OutputFolder "$name-$n" }
    $null = New-Item -ItemType Directory -Path $folder -Force
    $folder
}

# Run only when started as a script, not when a test dot-sources this file for its functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $repository = Split-Path $PSScriptRoot -Parent
        $argumentProblem = Get-CompareArgumentProblem -Target $Target -OutputFolder $OutputFolder -RunFolder $RunFolder -Unbound $Unbound
        if ($argumentProblem) { throw (ConvertTo-CompareStop -Reason $argumentProblem) }
        if ($RunFolder) {
            # The window with administrator rights: the first window left the request here.
            $request = [IO.File]::ReadAllText((Join-Path $RunFolder 'request.json')) | ConvertFrom-Json
            $result = Invoke-StickCompare -RepositoryPath $repository -Target "$($request.Target)" -ExpectChange @($request.ExpectChange) -AlsoVirtualBox:([bool]$request.AlsoVirtualBox) -OutputFolder "$($request.OutputFolder)" -Folder $RunFolder
            exit $result.ExitCode
        }
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw (ConvertTo-CompareStop -Reason 'the check runs on Windows only') }
        # Relative paths are read from PowerShell's location here; the window with administrator
        # rights starts in another folder.
        if ($Target -and (Test-Path -LiteralPath $Target -PathType Container)) { $Target = Convert-Path -LiteralPath $Target }
        $base = if ($OutputFolder) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFolder) } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PortableVM\stick-checks' }
        if ((Test-CompareBelow -Path $base -Folder $repository) -or ($Target -and (Test-CompareBelow -Path $base -Folder $Target))) {
            throw (ConvertTo-CompareStop -Reason 'the output folder is on the stick or in the repository, where the check must not write; give another -OutputFolder. Nothing was changed')
        }
        $folder = Get-CompareRunFolder -OutputFolder $base
        if ($ListOnly -or (Test-CompareAdministrator)) {
            $result = Invoke-StickCompare -RepositoryPath $repository -Target $Target -ExpectChange $ExpectChange -AlsoVirtualBox:$AlsoVirtualBox -ListOnly:$ListOnly -OutputFolder $base -Folder $folder
            exit $result.ExitCode
        }
        $request = [ordered]@{ Target = "$Target"; ExpectChange = @($ExpectChange); AlsoVirtualBox = [bool]$AlsoVirtualBox; OutputFolder = $base }
        Save-CompareFile -Path (Join-Path $folder 'request.json') -Lines @(ConvertTo-Json -InputObject $request)
        Write-Output 'Compare-StickDryRun: Windows asks for administrator rights now; answer Yes. The check runs in its own window, starts no VM, and its result comes here.'
        try { $code = Invoke-CompareElevated -ScriptPath $PSCommandPath -Folder $folder }
        catch {
            Write-Output 'RESULT: FAILED - the check did not start, because the Windows prompt for administrator rights was answered No or closed; nothing was changed'
            exit 1
        }
        $output = Join-Path $folder 'output.txt'
        if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
            Write-Output "RESULT: FAILED - the window with administrator rights ended with exit code $code before it saved a result"
            exit 1
        }
        [IO.File]::ReadAllLines($output) | ForEach-Object { Write-Output $_ }
        exit $code
    } catch {
        $reason = if ($_.Exception.Data['CompareStop']) { $_.Exception.Message } else { "unexpected error of type $($_.Exception.GetType().Name)" }
        Write-Output "RESULT: FAILED - $reason"
        exit 1
    }
}
