# -------------------------------------------------------
#                    TEST STICK STATE
# -------------------------------------------------------
#
# A read-only check of the stick that can run at any time, needs no administrator rights and
# changes nothing anywhere: it reads with the launcher's own module and writes no file. Run it in
# Windows PowerShell 5.1 from a clone:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Test-StickState.ps1 -Target X:\
# -Target is the folder that holds Launcher and LauncherData; without it the tool takes the one
# such folder at a drive's root or one level below, as tools\Compare-StickDryRun.ps1 does.
#
# It reports whether the settings pass the launcher's checks, whether the stick is the configured
# one, writes that did not finish and what a deploy left, the four files a start may write (the
# VMware and VirtualBox disk files, the .vbox file and VirtualBox.xml) with their copies, whether
# each disk file points at the stick and why the next start would rewrite it, saved states, and
# the last run in the log by the kinds of its lines. Each line names a check and a kind, a yes or
# no, or a count, never a value from the stick, so the output can go into a report as it is. The
# last line is "RESULT: OK - ...", "RESULT: ATTENTION - <what needs it>" or "RESULT: FAILED -
# <reason>", with exit code 0, 1 or 2.

[CmdletBinding()]
param([string]$Target)

$ErrorActionPreference = 'Stop'
# The stick-check tool's line kinds and stick search are shared; dot-sourcing it sets its own
# parameters to their defaults, so this script's are kept aside.
$stateTarget = $Target
. (Join-Path $PSScriptRoot 'Compare-StickDryRun.ps1')
$Target = $stateTarget

# Print the line $Text and keep it for the result.
function Add-StateLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $script:StateOutput.Add($Text)
    Write-Host $Text
}

# Return the summary lines of the last run in the launcher log $Path, at the time $Now: whether it
# was a start or a dry run and how long ago, the program it used, its end, whether it stopped, and
# the kinds of its lines (Get-CompareKind). A run is what one process logged from its start line.
function Get-StateLastRun {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][datetimeoffset]$Now
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '  last run in the log: none' }
    $all = @([IO.File]::ReadAllLines($Path, (Get-PvmAnsiEncoding)))
    $start = -1
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        if ((Get-CompareLogMessage -Line $all[$i]) -match '^----- Start VM( \(dry run\))? -----$') { $start = $i; break }
    }
    if ($start -lt 0) { return '  last run in the log: none' }
    $process = if ($all[$start] -match '^\S+ \[(\d+)\]  ') { $Matches[1] } else { '' }
    $run = @($all[$start..($all.Count - 1)] | Where-Object { -not $process -or $_ -match ('^\S+ \[' + $process + '\]  ') })
    $messages = @($run | ForEach-Object { Get-CompareLogMessage -Line $_ })
    $what = if ($messages[0] -like '*(dry run)*') { 'a dry run' } else { 'a start' }
    $when = 'at a time the log does not show'
    if ($all[$start] -match '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d) ') {
        $time = [datetimeoffset]::ParseExact($Matches[1], 'yyyy-MM-ddTHH:mm:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture)
        $when = "$([Math]::Max(0, [Math]::Floor(($Now - $time).TotalDays))) day(s) ago"
    }
    "  last run in the log: $what, $when"
    $used = @($messages | Where-Object { $_ -match '^Using (VMware|VirtualBox)$' } | ForEach-Object { $_.Substring(6) })
    "  last run used: $(if ($used.Count) { $used[-1] } else { 'no program logged' })"
    $end = @($messages | Where-Object { $_ -match '^----- End( \(dry run\))?: exit code (\d{1,3}) -----$' })
    if ($end.Count) { "  last run ended: yes, with exit code $([regex]::Match($end[-1], 'exit code (\d+)').Groups[1].Value)" }
    else { '  last run ended: no; its End line is missing, as when it was cut off' }
    $stopped = @($messages | Where-Object { $_ -match '^STOPPED: |^DRY RUN - a real start would stop here: ' }).Count -gt 0
    "  last run stopped, or a real start would have: $(if ($stopped) { 'yes' } else { 'no' })"
    # A request for administrator rights that was declined, or a stop before a run, logs no start.
    $later = @($all[$start..($all.Count - 1)] | Where-Object { $process -and $_ -notmatch ('^\S+ \[' + $process + '\]  ') } |
            ForEach-Object { Get-CompareLogMessage -Line $_ } | Where-Object { $_ -match '^Asking for administrator rights$|^STOPPED: ' })
    if ($later.Count) { '  after the last run, the log holds a request or a stop of no run: yes' }
    '  last run''s lines, by kind:'
    foreach ($message in $messages) { "    $((Get-CompareKind -Message $message) -replace '^version line: another version$', 'version line')" }
}

# Return whether every FLAT extent of the descriptor copy $Path names the disarmed device rather
# than a raw disk: 'yes', 'no', or 'unknown' when the launcher cannot read the copy.
function Get-StateCopyDisarmed {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $lines = @(ConvertFrom-PvmDescriptorText -Text (ConvertFrom-PvmDescriptorData -Bytes ([IO.File]::ReadAllBytes($Path))))
    } catch {
        return 'unknown'
    }
    $armed = @($lines | Where-Object { $_.Kind -eq 'Extent' -and $_.Type -eq 'FLAT' -and $_.Target -ne (Get-PvmDisarmedDevice -Target $_.Target) })
    if ($armed.Count) { 'no' } else { 'yes' }
}

# Return whether the file $Path lies below LauncherData\backups\removed of the stick folder
# $Target, where the launcher's guided fix puts aside what it removes.
function Test-StatePutAside {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )
    $removed = (Join-Path $Target 'LauncherData\backups\removed').TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $Path.StartsWith($removed, [StringComparison]::OrdinalIgnoreCase)
}

# Check the stick folder $Target ('' to find it) with the launcher's module from the clone
# $RepositoryPath, as the header of this file describes, at the time $Now. Returns ExitCode (0 when
# nothing needs attention, 1 when something does, 2 when the check cannot run) and Lines, what it
# printed. It reads only.
function Invoke-StickState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [AllowEmptyString()][string]$Target = '',
        [datetimeoffset]$Now = [datetimeoffset]::Now
    )
    $script:StateOutput = New-Object System.Collections.Generic.List[string]
    $attention = New-Object System.Collections.Generic.List[string]
    $exitCode = 2
    try {
        # Without -Force, so a module the caller loaded (and its test doubles) stays as it is.
        $null = Import-Module -Name (Join-Path $RepositoryPath 'src\PortableVM.psm1') -Global -DisableNameChecking
        if (-not $Target) {
            $found = @(Find-CompareStick | Where-Object { -not (Test-CompareBelow -Path $_ -Folder $RepositoryPath) })
            if ($found.Count -ne 1) { throw (ConvertTo-CompareStop -Reason "found $($found.Count) folders with Launcher and LauncherData at a drive's root or one level below; give -Target") }
            $Target = $found[0]
            Add-StateLine '  stick folder: found by its Launcher and LauncherData folders'
        } else {
            if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw (ConvertTo-CompareStop -Reason 'the -Target folder does not exist') }
            Add-StateLine '  stick folder: given'
        }
        $Target = [IO.Path]::GetFullPath($Target)
        if ($Target.Length -gt 3) { $Target = $Target.TrimEnd('\') }
        $launcher = Join-Path $Target 'Launcher'
        $paths = Get-PvmDataPath -LauncherPath $launcher

        # The settings and the stick.
        $settings = $null
        try { $settings = Import-PvmSetting -Path $paths.Settings } catch { Write-Verbose 'The settings do not pass the launcher''s checks.' }
        Add-StateLine "  settings pass the launcher's checks: $(if ($settings) { 'yes' } else { 'no' })"
        if (-not $settings) { $attention.Add('settings that do not pass') }
        $device = $null
        $stickDisk = $null
        $noDevice = ''
        $location = $null
        if ($settings) {
            $location = Get-PvmStickLocation -LauncherPath $launcher -Root $Target
            if (-not $location) {
                $noDevice = 'since the launcher finds the stick''s disk only by a drive letter on Windows'
            } else {
                try {
                    $stick = Get-PvmStickDevice -Location $location -Names @{ VM = $null; Guest = $null }
                    if (Get-PvmStickProblem -Disk $stick.Disk -Partition $stick.Partition -Settings $settings) { $noDevice = 'since the stick is not the configured one' }
                    else {
                        $device = $stick.Device
                        $stickDisk = $stick.Disk
                    }
                } catch {
                    $noDevice = 'since Windows did not say which disk the stick is'
                }
            }
            $identity = if ($device) { 'yes' } elseif ($noDevice -eq 'since the stick is not the configured one') { 'no' } elseif ($noDevice -like '*Windows did not say*') { 'unknown, since Windows did not say which disk it is' } else { "unknown, $noDevice" }
            Add-StateLine "  the stick is the configured one: $identity"
            if ($identity -eq 'no') { $attention.Add('not the configured stick') }
        }

        # What a write or a deploy that did not finish left.
        # A folder that cannot be read is passed over, and the count says so.
        $unread = @()
        $pending = @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue -ErrorVariable +unread | Where-Object { $CompareSkippedNames -notcontains $_.Name } | ForEach-Object {
                if ($_.PSIsContainer) { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable +unread } else { $_ }
            } | Where-Object { ($_.Name -like '*.pvm-tmp' -or $_.Name -like '*.pvm-old') -and -not (Test-StatePutAside -Path $_.FullName -Target $Target) })
        Add-StateLine "  writes that did not finish (.pvm-tmp or .pvm-old files): $($pending.Count)$(if ($unread.Count) { ', but some folders could not be read' })"
        $stops = $false
        # The disk files and the UUID as the VM's own files have them, as a start reads them.
        $context = $null
        if ($settings) {
            $context = [pscustomobject]@{
                Settings = $settings; Root = $Target; Backups = $paths.Backups; Location = $location
                Names = @{ VM = 'the VM'; Guest = 'the guest' }; VmFiles = $null
            }
            $context.VmFiles = New-PvmVmFileRecord -Context $context
            Resolve-PvmVMwareFile -Context $context
            Resolve-PvmVirtualBoxFile -Context $context
        }
        if ($settings) {
            $answer = 'no'
            try {
                foreach ($entry in @(Get-PvmWrittenPath -Context $context)) {
                    $problem = if ($entry.Previous) { Get-PvmCopyLeftoverProblem -Path $entry.Path -Of $entry.Of -Disarm:$entry.Disarm } else { Get-PvmLeftoverProblem -Path $entry.Path }
                    if ($problem) { $stops = $true }
                }
                if ($stops) { $answer = 'yes' }
            } catch {
                $answer = 'unknown, since a file cannot be read now'
            }
            Add-StateLine "  the next start would ask about or stop at a write that did not finish: $answer"
        }
        if ($pending.Count -or $stops) { $attention.Add('writes that did not finish') }
        $deployLeft = @($CompareLeftoverNames | Where-Object { Test-Path -LiteralPath (Join-Path $Target $_) })
        Add-StateLine "  left by a deploy that did not finish: $(if ($deployLeft.Count) { $deployLeft -join ', ' } else { 'nothing' })"
        if ($deployLeft.Count) { $attention.Add('what a deploy left') }

        # Whether the VM's own files agree with the settings, and VirtualBox's storage settings of
        # the stick's disk, which a start checks (phase 7).
        if ($context) {
            $files = $context.VmFiles
            $words = @{
                Setting = 'the settings name another file'; None = 'no raw-disk file is attached'; Several = 'more than one raw-disk file is attached'
                Outside = 'it is not below the stick folder'; Uuid = 'the settings name another UUID'; Unlisted = 'it attaches a disk that its media registry does not list'
                NoMachine = 'it has no Machine element'
            }
            $vmware = if (-not $files.VMwareRead) { 'unknown, since the .vmx cannot be read or is not complete' } elseif ($files.VMwareKind) { "no, $($words[$files.VMwareKind])" } else { 'yes' }
            Add-StateLine "  VMware disk file as the .vmx attaches it: $vmware"
            $virtualBox = if (-not $files.VirtualBoxRead) { 'unknown, since the .vbox cannot be read' } elseif ($files.VirtualBoxKind) { "no, $($words[$files.VirtualBoxKind])" } else { 'yes' }
            Add-StateLine "  VirtualBox disk file and UUID as the .vbox has them: $virtualBox"
            if ($vmware -like 'no*' -or $virtualBox -like 'no*') { $attention.Add('VM files that disagree with the settings') }
            $known = $files.VirtualBoxRead -and -not $files.VirtualBoxKind
            $cache = if (-not $known) { 'unknown' } elseif ($files.HostIOCache -eq 'true') { 'yes' } else { 'no' }
            $group = if (-not $known) { 'unknown' } elseif ($files.BandwidthGroup) { 'set' } else { 'none' }
            Add-StateLine "  VirtualBox host I/O cache on for the stick disk: $cache"
            Add-StateLine "  VirtualBox bandwidth group on the stick disk: $group"
            $mounts = if (-not $stickDisk) { "unknown, $noDevice" } else {
                $mounted = Get-PvmMountedVmPartition -Disk $stickDisk -DataPartitionStart $settings['DataPartitionStart']
                if ($mounted.Problem) { 'unknown, since Windows did not list the stick''s partitions' } else { "$(@($mounted.Mounts).Count)" }
            }
            Add-StateLine "  partitions mounted in the VM's part of the stick: $mounts"
            if ($cache -eq 'no' -or $group -eq 'set' -or ($mounts -match '\A\d+\z' -and $mounts -ne '0')) { $attention.Add('VirtualBox storage settings') }
        }

        # The files a start may write, their copies, and where each disk file points.
        if (-not $settings) {
            Add-StateLine '  the VM files: not checked, since the settings do not pass'
        } else {
            $files = @(
                @{ Label = 'VMware disk file'; Path = $context.VmFiles.VMwareDisk; Suffix = '.orig'; Program = 'VMware'; HideData = $true }
                @{ Label = 'VirtualBox disk file'; Path = $context.VmFiles.VirtualBoxDisk; Suffix = '.orig'; Program = 'VirtualBox'; HideData = [bool]$settings['HideDataPartition'] }
                @{ Label = 'VirtualBox .vbox file'; Path = (Join-PvmStickPath -Root $Target -Path $settings['VirtualBoxVbox']); Suffix = '.launcher-backup' }
                @{ Label = 'VirtualBox.xml'; Path = (Join-Path (Join-PvmStickPath -Root $Target -Path $settings['VirtualBoxHome']) 'VirtualBox.xml'); Suffix = '.launcher-backup' }
            )
            foreach ($file in $files) {
                $label = $file.Label
                if (-not $file.Path) {
                    Add-StateLine "  ${label}: unknown, since neither the settings nor the VM's file name it"
                    continue
                }
                $found = [IO.File]::Exists($file.Path)
                Add-StateLine "  ${label}: $(if ($found) { 'found' } else { 'missing' })"
                if ($file.Suffix -eq '.orig') {
                    $points = if (-not $found) { 'unknown, since the file is missing' } else {
                        try {
                            # A program, such as a hypervisor, can hold the file; the rest of the report still shows.
                            try { $bytes = [IO.File]::ReadAllBytes($file.Path) }
                            catch { throw [IO.IOException]::new('unreadable now') }
                            $text = ConvertFrom-PvmDescriptorData -Bytes $bytes
                            $null = ConvertFrom-PvmDescriptorText -Text $text
                            if (-not $device) { "unknown, $noDevice" } else {
                                $layout = Get-PvmDiskLayout -Drive $device -VmSectors $settings['VmSectors'] -DataPartitionStart $settings['DataPartitionStart'] -HideData $file.HideData
                                # A VMware start keeps fullDevice with the Data partition blanked (Invoke-PvmVMware).
                                if ($file.Program -eq 'VMware') { $layout.CreateType = 'fullDevice' }
                                $new = ConvertTo-PvmDescriptorText -Text $text -Layout $layout
                                if (Test-PvmSameDescriptorText -Old $text -New $new) { 'yes' }
                                else { "no; the next start rewrites it because $(Format-PvmDescriptorReason -Kinds @(Get-PvmDescriptorDifference -Old $text -New $new))" }
                            }
                        } catch [IO.IOException] {
                            'unknown, since it cannot be read now'
                        } catch [FormatException] {
                            $attention.Add('a disk file the launcher cannot read')
                            "unknown; the launcher cannot read it, so the next start with $($file.Program) stops"
                        }
                    }
                    Add-StateLine "  $label points at the stick: $points"
                }
                $backup = @{ Root = $Target; Backups = $paths.Backups; Path = $file.Path }
                $copies = @((Get-PvmBackupPath @backup -Suffix $file.Suffix), (Get-PvmBackupPath @backup -Suffix ('.previous' + $file.Suffix)))
                Add-StateLine "  $label, first copy: $(if ([IO.File]::Exists($copies[0])) { 'yes' } else { 'no' })"
                Add-StateLine "  $label, copy of the version before the latest rewrite: $(if ([IO.File]::Exists($copies[1])) { 'yes' } else { 'no' })"
                $present = @($copies | Where-Object { [IO.File]::Exists($_) })
                if ($file.Suffix -eq '.orig' -and $present.Count) {
                    $answers = @($present | ForEach-Object { Get-StateCopyDisarmed -Path $_ })
                    $disarmed = if ($answers -contains 'no') { 'no' } elseif ($answers -contains 'unknown') { 'unknown, since the launcher cannot read one' } else { 'yes' }
                    Add-StateLine "  $label, its copies name no raw disk: $disarmed"
                    if ($disarmed -eq 'no') { $attention.Add('a copy that names a raw disk') }
                }
            }

            # Saved states, which the next start asks about or refuses.
            $vmware = (Get-PvmVMwareState -Path (Join-PvmStickPath -Root $Target -Path $settings['VMwareVmx'])).State
            $virtualBox = (Get-PvmVirtualBoxState -Path (Join-PvmStickPath -Root $Target -Path $settings['VirtualBoxVbox'])).State
            foreach ($state in @(@('VMware', $vmware), @('VirtualBox', $virtualBox))) {
                $answer = switch ($state[1]) { 'Saved' { 'yes' } 'NotSaved' { 'no' } default { 'unknown' } }
                Add-StateLine "  $($state[0]) saved state: $answer"
                if ($answer -eq 'yes') { $attention.Add('a saved state') }
            }
        }

        foreach ($line in @(Get-StateLastRun -Path $paths.Log -Now $Now)) { Add-StateLine $line }

        $needs = @($attention | Select-Object -Unique)
        if ($needs.Count) {
            Add-StateLine "RESULT: ATTENTION - $($needs -join ', ')"
            $exitCode = 1
        } else {
            Add-StateLine 'RESULT: OK - nothing needs attention'
            $exitCode = 0
        }
    } catch {
        $reason = if ($_.Exception.Data['CompareStop']) { $_.Exception.Message }
        elseif (Get-Command -Name Get-PvmErrorCause -ErrorAction SilentlyContinue) { "unexpected error: $(Get-PvmErrorCause -ErrorRecord $_)" }
        else { "unexpected error of type $($_.Exception.GetType().Name)" }
        Add-StateLine "RESULT: FAILED - $reason"
        $exitCode = 2
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $script:StateOutput.ToArray() }
}

# Run only when started as a script, not when a test dot-sources this file for its functions.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Target -and (Test-Path -LiteralPath $Target -PathType Container)) { $Target = Convert-Path -LiteralPath $Target }
    $result = Invoke-StickState -RepositoryPath (Split-Path $PSScriptRoot -Parent) -Target $Target
    exit $result.ExitCode
}
