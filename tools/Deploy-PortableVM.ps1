# -------------------------------------------------------
#                  DEPLOY PORTABLE VM
# -------------------------------------------------------
#
# Copies the launcher from this clone to a stick. -Target is the folder on the stick's Data
# partition that holds the Launcher and LauncherData folders, for example X:\. Run it in Windows
# PowerShell 5.1:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Deploy-PortableVM.ps1 -Target X:\
# The launcher's code lives in Launcher, which each deploy replaces as a whole; the settings, the
# log and the launcher's backups live in LauncherData, which a deploy leaves alone. A deploy needs
# a LauncherData\settings.psd1 that passes the clone's settings checks. Without a Launcher folder
# it installs the launcher. Otherwise it builds Launcher.new from src\ with a VERSION from git
# describe and a SHA256SUMS of the code, and checks every copy against the clone; then
# Launcher.previous becomes Launcher.previous.remove, Launcher becomes Launcher.previous,
# Launcher.new becomes Launcher, the old launcher .cmd files at -Target move into Launcher.previous
# and "Start VM.cmd" takes their place. Once the new launcher is checked again,
# Launcher.previous.remove is deleted, so one earlier launcher stays. Only a copy that a deploy
# wrote and nothing changed since is ever deleted (Get-DeployOwnCopy); any other Launcher.previous
# stops the deploy before its first change.
#
# A stick that still keeps its settings in Launcher\settings.psd1, as the launcher before
# LauncherData did (schema 1), needs one run with -MigrateSettings. It checks everything first and
# prints its plan. Then it writes LauncherData\settings.psd1 as schema 2 with every value and
# comment kept, adding the names -VmDisplayName and -GuestName when given; keeps a copy of the old
# file in LauncherData\backups\legacy\Launcher; moves Launcher\launcher.log to LauncherData\logs;
# and moves the copies the old launcher kept beside the VM files (*.vmdk.orig,
# *.vbox.launcher-backup, VirtualBox.xml.launcher-backup) to LauncherData\backups\legacy, where
# each descriptor copy names a disarmed device instead of a raw disk. The code swap comes last, so
# the old launcher works until then, and the same command finishes a migration that stopped.
#
# It refuses, changing nothing, while a VM runs on this PC, when the settings fail the checks, when
# Launcher.new, "Start VM.cmd.new" or LauncherData.new is left from an earlier deploy, when
# Launcher.previous, or the Launcher that would replace it, is not its own unchanged copy, when
# Launcher holds file for file the commit it would write, or when a .cmd at -Target is in the way.
# A migration also refuses while Launcher.previous exists, an old settings file without a byte
# order mark whose values read differently as UTF-8 and as ANSI, and, when it resumes, two settings
# files that differ. A deploy cut off in the swap leaves Launcher.previous.remove: the next one
# finishes its removal, or stops and names the renames to do. It deletes nothing else, changes no
# VM file, and its messages name no full path, so that no folder name from the stick or above the
# clone shows: of an error from Windows or PowerShell, which can quote one, it prints only the
# cause, and -Verbose shows the message and the copies a migration moves. PowerShell's own errors
# about the command line, such as an unknown parameter, come before the script runs and name its
# path. When a step fails it says what is left to fix by hand.
# -WhatIf runs the checks and prints the plan only. Exits 0 when done, 1 when it refused or failed.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Target,
    [switch]$MigrateSettings,
    [string]$VmDisplayName,
    [string]$GuestName
)

$ErrorActionPreference = 'Stop'

$CodeFiles = @('Start-PortableVM.ps1', 'PortableVM.psm1')
$CmdName = 'Start VM.cmd'
# vmware-vmx% also covers the debug and stats builds of VMware's VM process.
$VmProcessFilter = "Name LIKE 'vmware-vmx%' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'"
# A .cmd that starts the launcher runs a .ps1 below %~dp0Launcher\, with or without a backslash
# after %~dp0.
$LauncherCmdPattern = '(?i)%~dp0\\?Launcher\\[^"\r\n]*\.ps1'
# A *.vmdk.orig of this size or more holds disk data, not a copy of a descriptor, and stays.
$MaxDescriptorBytes = 1MB
# The one folder this tool may delete.
$RemovalFolderName = 'Launcher.previous.remove'
# VERSION and each SHA256SUMS line exactly as a deploy writes them. A listed name holds no path, so
# a deletion cannot leave the folder.
$OwnCopyVersionPattern = '\A[0-9A-Za-z][0-9A-Za-z._+-]{0,127}\n\z'
$OwnCopySumPattern = '\A([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*\.(?:ps1|psm1))\z'

# Return the version of the clone at $RepositoryPath as git describe gives it: the nearest tag,
# else the commit, with -dirty for uncommitted changes; 'unknown' when git cannot tell.
function Get-DeployVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepositoryPath)
    $output = @()
    $exitCode = 1
    # git's stderr would stop the script under $ErrorActionPreference Stop.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $RepositoryPath describe --tags --always --dirty 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Verbose "git describe could not run: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -eq 0 -and $output.Count -eq 1 -and $output[0].Trim()) { return $output[0].Trim() }
    'unknown'
}

# Return the names of the VM processes, VMware's or VirtualBox's, that run on this PC.
function Get-DeployVmProcess {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Get-CimInstance -ClassName Win32_Process -Filter $VmProcessFilter | ForEach-Object { $_.Name }
}

# Return the SHA-256 hash of the file $Path in lowercase hex. It hashes with .NET, since
# Get-FileHash returns nothing while -WhatIf is in effect, and the checks run under -WhatIf too.
function Get-DeployHash {
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

# Return the .cmd files directly in the folder $Folder that start the launcher, which their text
# shows by running a .ps1 below %~dp0Launcher\. Throws when one cannot be read.
function Find-DeployLauncherCmd {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param([Parameter(Mandatory)][string]$Folder)
    Get-ChildItem -LiteralPath $Folder -Filter '*.cmd' -File | Where-Object {
        $_.Extension -eq '.cmd' -and [IO.File]::ReadAllText($_.FullName) -match $LauncherCmdPattern
    }
}

# Copy the file $Source to $Destination through the launcher's safe write (Write-PvmFile), which
# forces the copy onto the stick and never replaces a file, and throw when the copy's SHA-256
# differs from the source's. Returns the hash.
function Copy-DeployFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $null = Write-PvmFile -Path $Destination -Bytes ([IO.File]::ReadAllBytes($Source))
    $hash = Get-DeployHash -Path $Source
    if ((Get-DeployHash -Path $Destination) -ne $hash) { throw "The copy of $(Split-Path $Source -Leaf) does not match the clone." }
    $hash
}

# Rename the folder or file $Path to $NewName in the same folder. It renames with .NET's
# Directory.Move, which moves a file too and whose errors keep the code from Windows that
# Get-PvmErrorCause turns into a cause: Rename-Item reports a folder that holds an open file as an
# IOException without one. A virus scanner often holds a fresh file for a moment, so a failed
# rename is tried twice more, half a second apart, before it throws.
function Rename-DeployItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$NewName
    )
    # .NET reads a relative path from the process's folder, not from PowerShell's.
    $full = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $destination = Join-Path ([IO.Path]::GetDirectoryName($full)) $NewName
    for ($attempt = 1; ; $attempt++) {
        try {
            [IO.Directory]::Move($full, $destination)
            return
        } catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

# Return whether anything has the name $Path, also a link whose target is gone, which Test-Path
# does not see.
function Test-DeployEntry {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    [int](New-Object IO.DirectoryInfo $Path).Attributes -ne -1
}

# Return the version in the VERSION file of the launcher folder $Folder, or 'unknown' when it has
# none in the form a deploy writes.
function Get-DeployFolderVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Folder)
    try {
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $Folder 'VERSION')))
        if ($text -cmatch $OwnCopyVersionPattern) { return $text.TrimEnd("`n") }
    } catch {
        Write-Verbose "VERSION cannot be read: $($_.Exception.Message)"
    }
    'unknown'
}

# Check whether $Folder is a launcher copy that a deploy wrote and nothing changed since: a real
# folder with only SHA256SUMS, VERSION, the code files SHA256SUMS names with those hashes, and at
# most a Start VM.cmd equal to $CmdSource, none of them a link, read-only, hidden or a system file.
# Returns Problem ('' for such a copy, else a reason that names no file), Version and Files, the
# names a deletion may remove. What cannot be read counts as a problem.
function Get-DeployOwnCopy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$CmdSource
    )
    try {
        $blocked = [IO.FileAttributes]'ReadOnly, Hidden, System, ReparsePoint'
        $attributes = (New-Object IO.DirectoryInfo $Folder).Attributes
        if ([int]$attributes -eq -1 -or -not $attributes.HasFlag([IO.FileAttributes]::Directory)) { throw 'it is no folder' }
        if ([int]($attributes -band $blocked) -ne 0) { throw 'it is a link, or marked read-only, hidden or system' }
        $items = @(Get-ChildItem -LiteralPath $Folder -Force)
        foreach ($item in $items) {
            if ($item.PSIsContainer) { throw 'it holds a subfolder' }
            if ([int]($item.Attributes -band $blocked) -ne 0) { throw 'it holds a link, or a file marked read-only, hidden or system' }
        }
        $names = @($items | ForEach-Object { $_.Name })
        foreach ($name in 'SHA256SUMS', 'VERSION') {
            if ($names -cnotcontains $name) { throw "it has no $name" }
        }
        # Any byte outside ASCII decodes to a question mark, which neither pattern allows.
        $versionText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $Folder 'VERSION')))
        if ($versionText -cnotmatch $OwnCopyVersionPattern) { throw 'its VERSION is not one line with a version' }
        $lines = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $Folder 'SHA256SUMS'))).Split([char]10)
        if ($lines.Count -lt 2 -or $lines[-1] -cne '') { throw 'its SHA256SUMS is not in the form a deploy writes' }
        $listed = @{}
        foreach ($line in $lines[0..($lines.Count - 2)]) {
            if ($line -cnotmatch $OwnCopySumPattern) { throw 'its SHA256SUMS is not in the form a deploy writes' }
            $hash = $Matches[1]
            $name = $Matches[2]
            if ($listed.ContainsKey($name)) { throw 'its SHA256SUMS names a file twice' }
            $listed[$name] = $hash
        }
        $code = @($listed.Keys)
        $hasCmd = $names -ccontains $CmdName
        $allowed = $code + 'SHA256SUMS', 'VERSION' + @(if ($hasCmd) { $CmdName })
        foreach ($name in $names) {
            if ($allowed -cnotcontains $name) { throw 'it holds a file that a deploy did not write' }
        }
        foreach ($name in $code) {
            if ($names -cnotcontains $name) { throw 'a code file that its SHA256SUMS names is missing' }
            if ((Get-DeployHash -Path (Join-Path $Folder $name)) -cne $listed[$name]) { throw 'a code file differs from its SHA256SUMS' }
        }
        if ($hasCmd -and (Get-DeployHash -Path (Join-Path $Folder $CmdName)) -cne (Get-DeployHash -Path $CmdSource)) {
            throw "its '$CmdName' differs from the clone's"
        }
        [pscustomobject]@{ Problem = ''; Version = $versionText.TrimEnd("`n"); Files = @($code + @(if ($hasCmd) { $CmdName }) + 'VERSION', 'SHA256SUMS') }
    } catch {
        $reason = if (Test-DeployOwnMessage -ErrorRecord $_) { $_.Exception.Message } else { 'it cannot be read' }
        Write-Verbose "Launcher copy check: $($_.Exception.Message)"
        [pscustomobject]@{ Problem = $reason; Version = ''; Files = @() }
    }
}

# Delete the launcher copy $Folder through the names in $Files, then the empty folder without
# recursion, so a file that appeared after the check survives with its folder. This is the only
# place where the tool deletes anything, and it serves only the fixed folder name.
function Remove-DeployOwnCopy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string[]]$Files
    )
    if ((Split-Path $Folder -Leaf) -cne $RemovalFolderName) { throw "Remove-DeployOwnCopy deletes only $RemovalFolderName." }
    if (-not $PSCmdlet.ShouldProcess($RemovalFolderName, 'Delete the older launcher copy')) { return }
    foreach ($name in $Files) { [IO.File]::Delete((Join-Path $Folder $name)) }
    [IO.Directory]::Delete($Folder, $false)
}

# Check Launcher.previous.remove at $Target once more, delete it and return the version it held.
# Throws with the reason, deleting nothing, when the check fails.
function Complete-DeployRemoval {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$CmdSource
    )
    $folder = Join-Path $Target $RemovalFolderName
    $copy = Get-DeployOwnCopy -Folder $folder -CmdSource $CmdSource
    if ($copy.Problem) { throw $copy.Problem }
    Remove-DeployOwnCopy -Folder $folder -Files $copy.Files
    $copy.Version
}

# Import the launcher's module from the clone at $RepositoryPath, whose settings checks and
# settings migration the deploy uses. Throws when it cannot be loaded.
function Import-DeployModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryPath)
    $module = Join-Path $RepositoryPath 'src\PortableVM.psm1'
    try { Import-Module -Name $module -Force -Global -ErrorAction Stop }
    catch {
        # The message can quote the clone's full path, so it goes to -Verbose. Get-PvmErrorCause is
        # in the module that did not load, so the likely causes are told apart here; PowerShell
        # wraps each in an error of its own. A refusal of the execution policy wraps an access
        # error, and content that antivirus software blocks comes as a parse error, so a parse
        # error counts only when the file itself does not parse either.
        Write-Verbose $_.Exception.Message
        $record = $_
        if ($record.Exception -is [System.Management.Automation.ActionPreferenceStopException] -and $null -ne $record.Exception.ErrorRecord) {
            $record = $record.Exception.ErrorRecord
        }
        $exception = $record.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        $code = if (($exception.HResult -band 0xFFFF0000) -eq 0x80070000) { $exception.HResult -band 0xFFFF } else { 0 }
        # ParseFile would report a file it cannot read as a parse error, so the text is read first,
        # decoded as the running engine reads a script: by its byte order mark, else as ANSI in
        # Windows PowerShell 5.1 and as UTF-8 in PowerShell 7.
        $parseErrors = @()
        try {
            $encoding = if ($PSVersionTable.PSEdition -eq 'Desktop') { [Text.Encoding]::Default } else { New-Object System.Text.UTF8Encoding $false }
            $text = [IO.File]::ReadAllText($module, $encoding)
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
            $parseErrors = @($errors)
        } catch {
            Write-Verbose "The module cannot be read to parse it: $($_.Exception.Message)"
        }
        $cause = if ($record.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::SecurityError) { "PowerShell's execution policy blocks it" }
        elseif ($record.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ParserError -and $parseErrors.Count -gt 0) { 'it does not parse' }
        elseif ($code -eq 32 -or $code -eq 33) { 'it is open in another program' }
        elseif ($exception -is [UnauthorizedAccessException] -or $code -eq 5) { 'access is denied' }
        $because = if ($cause) { ". Cause: $cause" } else { '' }
        throw "The clone's src\PortableVM.psm1 cannot be loaded, so the settings cannot be checked$because (-Verbose shows the details)."
    }
}

# Return whether the error $ErrorRecord carries a message this tool or the launcher's module wrote,
# which names no file on the stick, rather than one from Windows or PowerShell, which can.
function Test-DeployOwnMessage {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $exception = $ErrorRecord.Exception
    $exception.GetType() -eq [System.Management.Automation.RuntimeException] -and $null -eq $exception.InnerException
}

# Return the message $Message, by default the error's own, of the error $ErrorRecord, which this
# tool or the module wrote. When the module kept the message from Windows behind it in
# Data['PvmDetail'], which can quote a path on the stick, that goes to -Verbose, and the message
# says so before its final full stop.
function Get-DeployOwnMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Message
    )
    if (-not $PSBoundParameters.ContainsKey('Message')) { $Message = $ErrorRecord.Exception.Message }
    for ($exception = $ErrorRecord.Exception; $null -ne $exception; $exception = $exception.InnerException) {
        if ($exception.Data['PvmDetail']) {
            Write-Verbose $exception.Data['PvmDetail']
            if ($Message.EndsWith('.')) { return $Message.Substring(0, $Message.Length - 1) + ' (-Verbose shows the details).' }
            return "$Message (-Verbose shows the details)"
        }
    }
    $Message
}

# Return the reason for the error $ErrorRecord that a message of this tool can quote: its own text
# when this tool or the module wrote it (Get-DeployOwnMessage), else the cause without any path
# (Get-PvmErrorCause), since the stick's folder and file names can be private. The message from
# Windows or PowerShell goes to -Verbose.
function Get-DeployCause {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    if (Test-DeployOwnMessage -ErrorRecord $ErrorRecord) { return (Get-DeployOwnMessage -ErrorRecord $ErrorRecord) }
    Write-Verbose $ErrorRecord.Exception.Message
    "$(Get-PvmErrorCause -ErrorRecord $ErrorRecord) (-Verbose shows the details)"
}

# Return "Cause: <reason>." for the error $ErrorRecord (Get-DeployCause): the sentence that ends a
# message saying what is left to fix by hand.
function Format-DeployCause {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    "Cause: $((Get-DeployCause -ErrorRecord $ErrorRecord).TrimEnd('.'))."
}

# Return whether the hashtables $Left and $Right hold the same keys, compared without case, with
# values of the same type and text.
function Test-DeploySameValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Left,
        [Parameter(Mandatory)][hashtable]$Right
    )
    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($key in $Left.Keys) {
        $other = @($Right.Keys | Where-Object { "$_" -eq "$key" })
        if ($other.Count -ne 1) { return $false }
        $a = $Left[$key]
        $b = $Right[$other[0]]
        if ($null -eq $a -or $null -eq $b) {
            if ($null -ne $a -or $null -ne $b) { return $false }
        } elseif ($a.GetType() -ne $b.GetType() -or "$a" -cne "$b") {
            return $false
        }
    }
    $true
}

# Return, sorted, the keys of the hashtables $Left and $Right, matched without case and other than
# those in $Ignore, whose values differ in type or text, or that only one of them holds.
function Get-DeployDifferentKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Left,
        [Parameter(Mandatory)][hashtable]$Right,
        [string[]]$Ignore = @()
    )
    $names = @(@($Left.Keys) + @($Right.Keys) | ForEach-Object { "$_" } | Sort-Object -Unique | Where-Object { $Ignore -notcontains $_ })
    foreach ($name in $names) {
        $a = Get-DeployValue -Values $Left -Key $name
        $b = Get-DeployValue -Values $Right -Key $name
        if ($null -eq $a -and $null -eq $b) { continue }
        if ($null -eq $a -or $null -eq $b -or $a.GetType() -ne $b.GetType() -or "$a" -cne "$b") { $name }
    }
}

# Return the text of the schema 1 settings file whose bytes are $Bytes, as the migration writes it
# on. Without a byte order mark the launcher before LauncherData read the file as ANSI, while an
# editor such as Notepad or VS Code saves it as UTF-8. When the two readings differ only in
# comments, the UTF-8 text keeps them as the editor wrote them; when a value differs, the
# migration cannot tell which one the stick uses, and this throws, naming the keys.
function Get-DeployLegacyText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $text = ConvertFrom-PvmDataFileByte -Bytes $Bytes -Legacy
    $ansi = (Get-PvmDataFileHashtable -Text $text).SafeGetValue()
    $bom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) -or
    ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF)))
    if ($bom -or @($Bytes | Where-Object { $_ -gt 0x7F }).Count -eq 0) { return $text }
    try { $utf8 = (New-Object System.Text.UTF8Encoding $false, $true).GetString($Bytes) }
    catch { return $text }
    $keys = @()
    try { $keys = @(Get-DeployDifferentKey -Left $ansi -Right (Get-PvmDataFileHashtable -Text $utf8).SafeGetValue()) }
    catch { $keys = @('the whole file') }
    if ($keys.Count -eq 0) { return $utf8 }
    throw ("Launcher\settings.psd1 has no byte order mark, and $($keys -join ', ') read differently as UTF-8, as an editor saves it, than as ANSI, as the launcher before LauncherData read it, so nothing was changed. " +
        'Check with a dry run of that launcher which files it uses, save the file as UTF-8 with BOM or as ANSI to match, then run the same command again.')
}

# Return the value of the key $Key in the hashtable $Values, with the key matched without case, or
# $null when it has none.
function Get-DeployValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Key
    )
    foreach ($name in $Values.Keys) { if ("$name" -eq $Key) { return $Values[$name] } }
    $null
}

# Return the copies that the launcher before LauncherData kept beside the files it rewrote, in the
# folders that the path settings of each table in $Settings name below $Target; a value that
# breaks the path rule (Get-PvmPathProblem) names no folder. Move holds the copies a migration
# moves, each with its Path, its Relative path below $Target and its Kind, Descriptor (a
# *.vmdk.orig under $MaxDescriptorBytes) or VirtualBox (a *.vbox.launcher-backup or
# VirtualBox.xml.launcher-backup); Keep is the number of other *.orig and *.launcher-backup files
# there, which stay.
function Find-DeployLegacyCopy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][hashtable[]]$Settings
    )
    $root = [IO.Path]::GetFullPath($Target).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    # The extension each path setting needs; the folder setting names its folder itself.
    $rules = [ordered]@{ VMwareDisk = '.vmdk'; VirtualBoxDisk = '.vmdk'; VirtualBoxVbox = '.vbox'; VirtualBoxHome = '' }
    $folders = @(foreach ($table in $Settings) {
            foreach ($key in $rules.Keys) {
                $value = Get-DeployValue -Values $table -Key $key
                if ($value -isnot [string] -or (Get-PvmPathProblem -Value $value -Extension $rules[$key])) { continue }
                $path = Join-PvmStickPath -Root $Target -Path $value
                if ($rules[$key]) { Split-Path $path } else { $path }
            }
        }) | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique
    $move = @()
    $keep = 0
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Name -like '*.orig' -or $_.Name -like '*.launcher-backup' })) {
            $kind = ''
            if ($file.Name -like '*.vmdk.orig' -and $file.Length -lt $MaxDescriptorBytes) { $kind = 'Descriptor' }
            elseif ($file.Name -like '*.vbox.launcher-backup' -or $file.Name -eq 'VirtualBox.xml.launcher-backup') { $kind = 'VirtualBox' }
            if (-not $kind) {
                $keep++
                continue
            }
            $move += [pscustomobject]@{ Path = $file.FullName; Relative = $file.FullName.Substring($root.Length); Kind = $kind }
        }
    }
    [pscustomobject]@{ Move = $move; Keep = $keep }
}

# Return a path for the file $Path that nothing has yet: $Path itself, or its name with ' (2)',
# ' (3)' and so on before the first dot, as Explorer names copies.
function Get-DeployFreePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $folder = Split-Path $Path
    $name = Split-Path $Path -Leaf
    $dot = $name.IndexOf('.')
    $stem = if ($dot -gt 0) { $name.Substring(0, $dot) } else { $name }
    $rest = if ($dot -gt 0) { $name.Substring($dot) } else { '' }
    for ($number = 2; ; $number++) {
        $candidate = Join-Path $folder "$stem ($number)$rest"
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
}

# Throw, naming no file, unless the file $Path can be opened to read, write and delete while no
# other program has it open. A migration checks each file it moves this way before its first
# change.
function Assert-DeployWriteAccess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'FileSystemAclExtensions is used only under PowerShell 7.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        # .NET Framework and .NET name the handle with these rights differently; other systems
        # have no delete right on a file, and their share modes only hold between .NET handles.
        $rights = [Security.AccessControl.FileSystemRights]'Read, Write, Delete'
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $stream = New-Object System.IO.FileStream $Path, ([IO.FileMode]::Open), $rights, ([IO.FileShare]::None), 4096, ([IO.FileOptions]::None)
        } elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $stream = [System.IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path), [IO.FileMode]::Open, $rights, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $null)
        } else {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        $stream.Dispose()
    } catch {
        Write-Verbose "Cannot open $Path to move it: $($_.Exception.Message)"
        throw 'A file that the migration moves is open in another program, or this account may not change it, so nothing was changed. Close what uses the stick and run the same command again; -Verbose names the file.'
    }
}

# Return the step (Get-PvmLeftoverProblem) for each write below the folder $Folder that did not
# finish, one per file that has a .pvm-tmp or .pvm-old beside its name.
function Get-DeployLeftoverStep {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return }
    $names = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force | Where-Object { $_.Name -like '*.pvm-tmp' -or $_.Name -like '*.pvm-old' } |
            ForEach-Object { $_.FullName.Substring(0, $_.FullName.Length - '.pvm-tmp'.Length) } | Sort-Object -Unique)
    foreach ($name in $names) { Get-PvmLeftoverProblem -Path $name }
}

# Disarm the descriptor copy $Path in place (ConvertTo-PvmDisarmedDescriptorText, every other
# byte kept) through the launcher's safe write (Write-PvmFile), and return whether it changed.
# Copies that an earlier write left beside it stop it, a disarmed copy too, as does an armed
# version that cannot be removed after the disarm, with the step to take behind -Verbose; the
# tool removes nothing it did not write in the same step.
function Set-DeployDisarmedCopy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $leftover = Get-PvmLeftoverProblem -Path $Path
    if ($leftover) { throw (Get-PvmWriteException -Code 'Leftover' -Message 'An earlier write of the file did not finish, and its copy is still beside it.' -Detail $leftover) }
    # ISO-8859-1 maps each byte to one character and back, so only the device names change.
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = $latin1.GetString($bytes)
    $disarmed = ConvertTo-PvmDisarmedDescriptorText -Text $text
    if ($disarmed -ceq $text) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Disarm the descriptor copy')) { return $false }
    $left = Write-PvmFile -Path $Path -Bytes $latin1.GetBytes($disarmed) -Expected $bytes
    if ($left) {
        # The same step as at the next run; running the command again then disarms the copy again.
        throw (Get-PvmWriteException -Code 'Leftover' -Message 'A copy was disarmed, but its armed version could not be removed from beside it.' -Detail (Get-PvmLeftoverProblem -Path $Path))
    }
    $true
}

# Return whether the staged launcher folder $Folder holds exactly the code files $Sources, the
# SHA256SUMS $Sums and the VERSION $Version, each as this run would write it, so that a resumed
# migration can use it.
function Test-DeployStagedCode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string[]]$Sources,
        [Parameter(Mandatory)][string]$Sums,
        [Parameter(Mandatory)][string]$Version
    )
    $expected = @($Sources | ForEach-Object { Split-Path $_ -Leaf }) + 'SHA256SUMS', 'VERSION'
    $names = @(Get-ChildItem -LiteralPath $Folder -Force | ForEach-Object { $_.Name })
    if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $names).Count -gt 0) { return $false }
    foreach ($source in $Sources) {
        if ((Get-DeployHash -Path (Join-Path $Folder (Split-Path $source -Leaf))) -ne (Get-DeployHash -Path $source)) { return $false }
    }
    ([IO.File]::ReadAllText((Join-Path $Folder 'SHA256SUMS')) -ceq $Sums) -and ([IO.File]::ReadAllText((Join-Path $Folder 'VERSION')) -ceq "$Version`n")
}

# Return the plan of a migration of the stick folder $Target from schema 1, checked before any
# change and refusing what it cannot do: Bytes, the new LauncherData\settings.psd1 (ASCII, or
# UTF-8 with a BOM when it holds other characters); Values, the settings the new launcher reads;
# Copies, the copies to move (Find-DeployLegacyCopy); Log, whether Launcher\launcher.log moves;
# and the counts that the report shows. The old file is read by Get-DeployLegacyText. With
# -Resume, LauncherData is there from a migration that stopped: its settings.psd1 stays as it is,
# so it must pass the checks, hold the names given, and agree with Launcher\settings.psd1 once
# both have their defaults, apart from SchemaVersion, IsExample and the names. The copies are then
# looked for in the folders of both settings files, and Bytes is $null.
function Get-DeployMigrationPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$VmDisplayName,
        [string]$GuestName,
        [switch]$Resume
    )
    $oldSettings = Join-Path $Target 'Launcher\settings.psd1'
    $data = Join-Path $Target 'LauncherData'
    $settings = Join-Path $data 'settings.psd1'
    try {
        $text = Get-DeployLegacyText -Bytes ([IO.File]::ReadAllBytes($oldSettings))
        $old = (Get-PvmDataFileHashtable -Text $text).SafeGetValue()
    } catch {
        $reason = Get-DeployCause -ErrorRecord $_
        if ($reason -like 'Launcher\settings.psd1 has no byte order mark*') { throw }
        throw "Launcher\settings.psd1 cannot be read, so nothing was changed: $($reason.TrimEnd('.'))."
    }
    $bytes = $null
    if ($Resume) {
        if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) {
            throw 'LauncherData is there, but without settings.psd1, so the migration cannot tell what happened. Rename LauncherData to another name, then run the same command again.'
        }
        try { $null = Import-PvmSetting -Path $settings }
        catch {
            $stop = Get-PvmStopMessage -ErrorRecord $_
            if ($null -eq $stop) { throw }
            throw "LauncherData\settings.psd1 is there from a migration that stopped, and this run keeps it, but it must pass the checks first, so nothing was changed. $(Get-DeployOwnMessage -ErrorRecord $_ -Message $stop)"
        }
        try { $values = Import-PvmDataFile -Path $settings }
        catch { throw "LauncherData\settings.psd1 cannot be read, so nothing was changed: $((Get-DeployCause -ErrorRecord $_).TrimEnd('.'))." }
        foreach ($name in 'VmDisplayName', 'GuestName') {
            $given = if ($name -eq 'VmDisplayName') { $VmDisplayName } else { $GuestName }
            if ($given -and "$(Get-DeployValue -Values $values -Key $name)" -cne $given) {
                throw "LauncherData\settings.psd1 is there from a migration that stopped, and this run keeps it, but its $name is not the one given, so nothing was changed. Set VmDisplayName and GuestName in LauncherData\settings.psd1, then run the same command without -VmDisplayName and -GuestName."
            }
        }
        # The old launcher may have run on Launcher\settings.psd1 since: a change there must not
        # be lost without a word. Defaults count as written, and the keys schema 2 added do not count.
        try { $different = @(Get-DeployDifferentKey -Left (Merge-PvmSetting -Settings $old) -Right (Merge-PvmSetting -Settings $values) -Ignore 'SchemaVersion', 'IsExample', 'VmDisplayName', 'GuestName') }
        catch { $different = @('sector values that are no whole numbers') }
        if ($different.Count -gt 0) {
            throw "Launcher\settings.psd1 and LauncherData\settings.psd1 differ in $($different -join ', '), so nothing was changed. The new launcher reads LauncherData\settings.psd1: make the two files agree, then run the same command again."
        }
    } else {
        try { $new = ConvertTo-PvmSchema2Text -Text $text -VmDisplayName $VmDisplayName -GuestName $GuestName }
        catch { throw "Launcher\settings.psd1 cannot be turned into schema 2, so nothing was changed: $((Get-DeployCause -ErrorRecord $_).TrimEnd('.'))." }
        $bytes = if ($new -match '[^\x00-\x7F]') {
            [byte[]]((New-Object System.Text.UTF8Encoding $true).GetPreamble() + (New-Object System.Text.UTF8Encoding $false).GetBytes($new))
        } else {
            [Text.Encoding]::ASCII.GetBytes($new)
        }
        # The new file is read back the way the launcher reads it, and must hold the old values
        # plus the new keys.
        $values = (Get-PvmDataFileHashtable -Text (ConvertFrom-PvmDataFileByte -Bytes $bytes)).SafeGetValue()
        $expected = @{}
        foreach ($key in $old.Keys) { $expected["$key"] = $old[$key] }
        $expected['SchemaVersion'] = 2
        if ($VmDisplayName) { $expected['VmDisplayName'] = $VmDisplayName }
        if ($GuestName) { $expected['GuestName'] = $GuestName }
        if (-not (Test-DeploySameValue -Left $values -Right $expected)) { throw 'The settings in schema 2 would not hold the values of Launcher\settings.psd1, so nothing was changed.' }
        $problems = @(Test-PvmSetting -Settings $values)
        if ($problems.Count -gt 0) {
            throw ("The settings in Launcher\settings.psd1, with the names given, do not pass the checks of schema 2, so nothing was changed. Fix them, then run the same command again:`n" +
                (($problems | ForEach-Object { "- $_" }) -join "`n"))
        }
    }
    $copies = Find-DeployLegacyCopy -Target $Target -Settings $values, $old
    $oldLog = Join-Path $Target 'Launcher\launcher.log'
    $log = Test-Path -LiteralPath $oldLog -PathType Leaf
    foreach ($copy in $copies.Move) { Write-Verbose "The migration moves $($copy.Relative) to LauncherData\backups\legacy." }
    foreach ($path in @(@($copies.Move | ForEach-Object { $_.Path }) + @(if ($log) { $oldLog }))) { Assert-DeployWriteAccess -Path $path }
    [pscustomobject]@{
        Bytes            = $bytes
        Values           = $values
        Copies           = $copies
        Log              = $log
        Descriptors      = @($copies.Move | Where-Object { $_.Kind -eq 'Descriptor' }).Count
        VirtualBoxCopies = @($copies.Move | Where-Object { $_.Kind -eq 'VirtualBox' }).Count
        KeptCopies       = $copies.Keep
    }
}

# Move what a migration moves into the stick folder $Target's LauncherData, which exists by then,
# as $Plan (Get-DeployMigrationPlan) says: a copy of Launcher\settings.psd1 to
# backups\legacy\Launcher unless one with its bytes is there, the log to logs, and each copy to
# the same path below backups\legacy. A name that is taken there gets a free one beside it
# (Get-DeployFreePath), so a log or a copy that the old launcher wrote after a migration stopped
# is kept too. Then every descriptor copy there is disarmed (Set-DeployDisarmedCopy), which
# repeats safely after a stop. Move-Item without -Force never replaces a file.
function Move-DeployLegacyData {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][pscustomobject]$Plan
    )
    $data = Join-Path $Target 'LauncherData'
    $legacy = Join-Path $data 'backups\legacy'
    if (-not $PSCmdlet.ShouldProcess($data, 'Move the legacy log and copies')) { return }
    # A disarm that stopped between its two renames leaves its copies without the name itself, which
    # a copy moved now would take; so such a write's step comes before anything moves.
    $steps = @(Get-DeployLeftoverStep -Folder $legacy)
    if ($steps.Count) { throw (Get-PvmWriteException -Code 'Leftover' -Message 'An earlier write of the file did not finish, and its copy is still beside it.' -Detail ($steps -join ' ')) }
    $null = New-Item -ItemType Directory -Path (Join-Path $data 'logs'), (Join-Path $legacy 'Launcher') -Force
    $oldSettings = Join-Path (Join-Path $Target 'Launcher') 'settings.psd1'
    $hash = Get-DeployHash -Path $oldSettings
    # A copy that a safe write left beside the file is no copy yet; the write stops at it instead.
    $copies = @(Get-ChildItem -LiteralPath (Join-Path $legacy 'Launcher') -File | Where-Object { $_.Name -notlike '*.pvm-tmp' -and $_.Name -notlike '*.pvm-old' })
    if (@($copies | Where-Object { (Get-DeployHash -Path $_.FullName) -eq $hash }).Count -eq 0) {
        $null = Copy-DeployFile -Source $oldSettings -Destination (Get-DeployFreePath -Path (Join-Path (Join-Path $legacy 'Launcher') 'settings.psd1'))
    }
    if ($Plan.Log) { Move-Item -LiteralPath (Join-Path (Join-Path $Target 'Launcher') 'launcher.log') -Destination (Get-DeployFreePath -Path (Join-Path (Join-Path $data 'logs') 'launcher.log')) }
    foreach ($copy in $Plan.Copies.Move) {
        $destination = Get-DeployFreePath -Path (Join-Path $legacy $copy.Relative)
        $null = New-Item -ItemType Directory -Path (Split-Path $destination) -Force
        Move-Item -LiteralPath $copy.Path -Destination $destination
    }
    foreach ($copy in @(Get-ChildItem -LiteralPath $legacy -Recurse -File | Where-Object { $_.Name -like '*.vmdk.orig' -and $_.Length -lt $MaxDescriptorBytes })) {
        $null = Set-DeployDisarmedCopy -Path $copy.FullName
    }
}

# Deploy the launcher from the clone at $RepositoryPath to the stick folder $Target, as the header
# describes; -MigrateSettings, with the optional -VmDisplayName and -GuestName, moves schema 1
# settings to LauncherData first. Throws with the reason, before any change, when a check fails; a
# failure after the first change says what is left to do. Returns Version; Mode, which is Install
# (no Launcher folder), Update (settings in LauncherData), Migrate (schema 1 settings), Resume (a
# migration that stopped after it created LauncherData) or Finish (Launcher holds this commit
# already, and only a removal left by an earlier deploy is done); MovedCmdCount, the old launcher .cmd files
# moved into Launcher.previous; Plan, a migration's plan (Get-DeployMigrationPlan); Applied, $false
# under -WhatIf; PreviousVersion, what Launcher.previous holds afterwards; Removing and Removed,
# the versions of the older copies it would delete and did delete; and RemovalProblem, why an older
# copy stayed after a deploy that otherwise worked.
function Invoke-PvmDeploy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Target,
        [switch]$MigrateSettings,
        [string]$VmDisplayName,
        [string]$GuestName
    )
    $launcher = Join-Path $Target 'Launcher'
    $staged = Join-Path $Target 'Launcher.new'
    $previous = Join-Path $Target 'Launcher.previous'
    $removal = Join-Path $Target $RemovalFolderName
    $data = Join-Path $Target 'LauncherData'
    $dataStaged = Join-Path $Target 'LauncherData.new'
    $oldSettings = Join-Path $launcher 'settings.psd1'
    $cmdTarget = Join-Path $Target $CmdName
    $cmdStaged = Join-Path $Target "$CmdName.new"
    $leftovers = "Launcher.new and '$CmdName.new'"
    $sources = @($CodeFiles | ForEach-Object { Join-Path (Join-Path $RepositoryPath 'src') $_ })
    $cmdSource = Join-Path $RepositoryPath $CmdName

    # The clone, the parameters and the PC.
    foreach ($source in $sources + $cmdSource) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "The clone has no $(Split-Path $source -Leaf)." }
    }
    if (($VmDisplayName -or $GuestName) -and -not $MigrateSettings) {
        throw '-VmDisplayName and -GuestName go only with -MigrateSettings, which writes them into the new LauncherData\settings.psd1. Where that file is there already, set VmDisplayName and GuestName in it.'
    }
    Import-DeployModule -RepositoryPath $RepositoryPath
    $running = @(Get-DeployVmProcess)
    if ($running.Count -gt 0) { throw "A VM runs on this PC ($($running -join ', ')). Shut the guest down first." }

    # What an earlier deploy left.
    $hasLauncher = Test-Path -LiteralPath $launcher -PathType Container
    $hasPrevious = Test-DeployEntry -Path $previous
    $hasRemoval = Test-DeployEntry -Path $removal
    if (-not $hasLauncher) {
        if ($hasPrevious -and $hasRemoval) {
            throw "The target has no Launcher folder, but Launcher.previous holds the launcher that a deploy that stopped replaced. Rename Launcher.previous back to Launcher, then Launcher.previous.remove back to Launcher.previous, remove $leftovers if they are there, then deploy again."
        }
        if ($hasPrevious) {
            throw "The target has no Launcher folder, but Launcher.previous holds the launcher that an interrupted deploy replaced. Rename Launcher.previous back to Launcher, remove $leftovers if they are there, then deploy again."
        }
        if ($hasRemoval) {
            throw "The target has no Launcher or Launcher.previous folder, but Launcher.previous.remove holds an older launcher. Rename Launcher.previous.remove to Launcher, remove $leftovers if they are there, then deploy again."
        }
    } elseif ($hasRemoval) {
        if (-not $hasPrevious) {
            throw "Launcher.previous.remove is left from a deploy that stopped, and Launcher.previous is missing. Rename Launcher.previous.remove back to Launcher.previous, remove $leftovers if they are there, then deploy again."
        }
        if ((Test-Path -LiteralPath $cmdStaged) -and -not (Test-Path -LiteralPath $staged)) {
            throw "The new launcher is in Launcher, but its .cmd is not in place yet. Move the old launcher .cmd files at the stick's root into Launcher.previous, then rename '$CmdName.new' to '$CmdName', then deploy again."
        }
    }
    if (Test-Path -LiteralPath $dataStaged) {
        throw "LauncherData.new is left from a migration whose staging did not finish, and nothing the launcher uses was changed. Remove LauncherData.new, and $leftovers if they are there, then run the same command again."
    }
    # The copies a safe write of the staged .cmd keeps beside it; Launcher.new is new each time.
    foreach ($copy in @((Get-PvmWriteCopyPath -Path $cmdStaged).PSObject.Properties.Value)) {
        if (Test-Path -LiteralPath $copy) {
            throw "'$(Split-Path $copy -Leaf)' is left from an earlier deploy whose write of '$CmdName.new' did not finish, and nothing the launcher uses was changed. Remove it, and $leftovers if they are there, then run the same command again."
        }
    }

    # Where the settings are decides what the deploy does.
    $hasOldSettings = Test-Path -LiteralPath $oldSettings -PathType Leaf
    if (-not $hasLauncher) {
        if ($MigrateSettings) { throw 'The target has no Launcher folder, so there are no settings to migrate. Deploy without -MigrateSettings.' }
        $mode = 'Install'
    } elseif ($hasOldSettings) {
        try { $oldValues = Import-PvmDataFile -Path $oldSettings -Legacy }
        catch { throw "Launcher\settings.psd1 cannot be read: $((Get-DeployCause -ErrorRecord $_).TrimEnd('.'))." }
        if (@($oldValues.Keys | Where-Object { "$_" -eq 'SchemaVersion' }).Count -gt 0) {
            throw 'Launcher\settings.psd1 holds schema 2 settings, but the launcher reads them from LauncherData\settings.psd1. Move the file there, then deploy again.'
        }
        if (-not $MigrateSettings) {
            throw 'The stick keeps its settings in Launcher\settings.psd1, as the launcher before LauncherData did. Deploy once with -MigrateSettings, which moves them to LauncherData; add -WhatIf first to see what it would do.'
        }
        $mode = if (Test-Path -LiteralPath $data -PathType Container) { 'Resume' } else { 'Migrate' }
    } else {
        if ($MigrateSettings) { throw 'The settings are in LauncherData already, so there is nothing to migrate. Deploy without -MigrateSettings.' }
        $mode = 'Update'
    }

    # Only the tool's own unchanged copies may be replaced. A migration keeps the old settings in
    # Launcher.previous, so it never replaces one.
    $removing = @()
    $finishRemoval = $false
    if ($hasPrevious) {
        if ($mode -ne 'Update') { throw 'Launcher.previous holds the launcher that the last deploy replaced. A migration keeps the old settings there, so move it away first.' }
        $previousCopy = Get-DeployOwnCopy -Folder $previous -CmdSource $cmdSource
        if ($previousCopy.Problem) {
            throw "Launcher.previous is not a launcher copy that a deploy wrote and nothing changed since ($($previousCopy.Problem)), so nothing was changed. Check what it holds, remove it or move it away, then deploy again."
        }
        if ($hasRemoval) {
            $removalCopy = Get-DeployOwnCopy -Folder $removal -CmdSource $cmdSource
            if ($removalCopy.Problem) {
                throw "Launcher.previous.remove is not a launcher copy that a deploy wrote and nothing changed since ($($removalCopy.Problem)), so nothing was changed. Check what it holds, remove it or move it away, then deploy again."
            }
        }
        # Launcher becomes the only way back, so an older copy goes only when Launcher is intact.
        $launcherCopy = Get-DeployOwnCopy -Folder $launcher -CmdSource $cmdSource
        if ($launcherCopy.Problem) {
            if ($hasRemoval) {
                throw ("Launcher does not match its SHA256SUMS ($($launcherCopy.Problem)), so the older copy in Launcher.previous.remove stays and nothing was changed. " +
                    "To go back, rename Launcher to another name, Launcher.previous to Launcher and Launcher.previous.remove to Launcher.previous, and move '$CmdName' from the new Launcher to the stick's root, over the one there. Then deploy again.")
            }
            throw "Launcher is not a launcher copy that a deploy wrote and nothing changed since ($($launcherCopy.Problem)), so replacing it would cost the copy in Launcher.previous, and nothing was changed. Rename Launcher.previous to keep it, then deploy again."
        }
        if ($hasRemoval) {
            $finishRemoval = $true
            $removing += $removalCopy.Version
        }
        $removing += $previousCopy.Version
    }
    $plan = $null
    if ($mode -eq 'Install' -or $mode -eq 'Update') {
        try { $null = Import-PvmSetting -Path (Join-Path $data 'settings.psd1') }
        catch {
            $stop = Get-PvmStopMessage -ErrorRecord $_
            if ($null -eq $stop) { throw }
            throw "The new launcher reads LauncherData\settings.psd1, which must pass its checks first, so nothing was changed. $(Get-DeployOwnMessage -ErrorRecord $_ -Message $stop)"
        }
    } else {
        $plan = Get-DeployMigrationPlan -Target $Target -VmDisplayName $VmDisplayName -GuestName $GuestName -Resume:($mode -eq 'Resume')
    }

    # The .cmd files are checked now, so that nothing they hold can stop the last step after the swap.
    try { $oldCmds = @(Find-DeployLauncherCmd -Folder $Target) }
    catch { throw "A .cmd file at the target cannot be read, so the old launcher .cmd cannot be found. $(Format-DeployCause -ErrorRecord $_)" }
    if ($mode -eq 'Install' -and $oldCmds.Count -gt 0) {
        throw 'A launcher .cmd is at the target, but there is no Launcher folder to keep it in. Move the .cmd files that start a launcher away first.'
    }
    if ((Test-Path -LiteralPath $cmdTarget) -and @($oldCmds | Where-Object { $_.Name -eq $CmdName }).Count -eq 0) {
        throw "'$CmdName' at the target does not start the launcher. Move it away first."
    }
    foreach ($old in $oldCmds) {
        if (Test-Path -LiteralPath (Join-Path $launcher $old.Name)) {
            throw 'Launcher holds a file with the name of an old launcher .cmd, which would block moving the .cmd into Launcher.previous. Move that file out of Launcher first.'
        }
    }

    # A resumed migration uses what its first run staged, when it is what this run would stage.
    $version = Get-DeployVersion -RepositoryPath $RepositoryPath
    $hashes = @{}
    foreach ($source in $sources) { $hashes[$source] = Get-DeployHash -Path $source }
    $sums = (@($sources | ForEach-Object { '{0}  {1}' -f $hashes[$_], (Split-Path $_ -Leaf) }) -join "`n") + "`n"
    # Deploying the commit that Launcher holds would only push the earlier version out, so it
    # stops. A removal that such a deploy left is still finished.
    if ($mode -eq 'Update') {
        $same = $false
        try { $same = Test-DeployStagedCode -Folder $launcher -Sources $sources -Sums $sums -Version $version }
        catch { Write-Verbose "Launcher cannot be compared with the clone: $($_.Exception.Message)" }
        if ($same) {
            if (-not $finishRemoval) {
                $keeps = if ($hasPrevious) { " and Launcher.previous keeps version $($previousCopy.Version)" } else { '' }
                throw "Launcher already holds $version, file for file the commit this deploy would write, so nothing was changed$keeps. There is nothing to write again: a Launcher that differs from the clone in any file is replaced as usual."
            }
            $mode = 'Finish'
            $removing = @($removalCopy.Version)
        }
    }
    $reuseCode = $false
    $reuseCmd = $false
    if (Test-Path -LiteralPath $staged) {
        $reuseCode = $mode -eq 'Resume' -and (Test-Path -LiteralPath $staged -PathType Container) -and
        (Test-DeployStagedCode -Folder $staged -Sources $sources -Sums $sums -Version $version)
        if (-not $reuseCode) { throw 'Launcher.new is left from an earlier deploy and holds only copies. Remove it first.' }
    }
    if (Test-Path -LiteralPath $cmdStaged) {
        $reuseCmd = $mode -eq 'Resume' -and (Test-Path -LiteralPath $cmdStaged -PathType Leaf) -and
        (Get-DeployHash -Path $cmdStaged) -eq (Get-DeployHash -Path $cmdSource)
        if (-not $reuseCmd) { throw "'$CmdName.new' is left from an earlier deploy and holds only copies. Remove it first." }
    }

    $previousVersion = if ($mode -eq 'Finish') { $previousCopy.Version } elseif ($hasLauncher) { Get-DeployFolderVersion -Folder $launcher } else { '' }
    $result = [pscustomobject]@{
        Version = $version; Mode = $mode; MovedCmdCount = $oldCmds.Count; Plan = $plan; Applied = $false
        PreviousVersion = $previousVersion; Removing = $removing; Removed = @(); RemovalProblem = ''
    }
    # The target is not named, since the stick's folder names can be private.
    if (-not $PSCmdlet.ShouldProcess('the -Target folder', "Deploy the launcher $version")) { return $result }
    # That was the one question -Confirm asks: the steps below run as one unit, without asking again.
    $ConfirmPreference = 'None'

    if ($mode -eq 'Finish') {
        try { $result.Removed = @(Complete-DeployRemoval -Target $Target -CmdSource $cmdSource) }
        catch { throw "Launcher already holds $version, but Launcher.previous.remove could not be removed, and nothing else was changed. Check what it holds, remove it or move it away. $(Format-DeployCause -ErrorRecord $_)" }
        $result.Applied = $true
        return $result
    }

    # Everything is staged and checked first, so a failed copy changes nothing the launcher uses.
    try {
        if (-not $reuseCode) {
            $null = New-Item -ItemType Directory -Path $staged
            foreach ($source in $sources) { $null = Copy-DeployFile -Source $source -Destination (Join-Path $staged (Split-Path $source -Leaf)) }
            $null = Write-PvmFile -Path (Join-Path $staged 'SHA256SUMS') -Bytes ([Text.Encoding]::ASCII.GetBytes($sums))
            $null = Write-PvmFile -Path (Join-Path $staged 'VERSION') -Bytes ([Text.Encoding]::ASCII.GetBytes("$version`n"))
        }
        if (-not $reuseCmd) { $null = Copy-DeployFile -Source $cmdSource -Destination $cmdStaged }
        if ($mode -eq 'Migrate') {
            $null = New-Item -ItemType Directory -Path (Join-Path $dataStaged 'logs'), (Join-Path $dataStaged 'backups\legacy\Launcher')
            $newSettings = Join-Path $dataStaged 'settings.psd1'
            $null = Write-PvmFile -Path $newSettings -Bytes $plan.Bytes
            if (-not (Test-DeploySameValue -Left (Import-PvmDataFile -Path $newSettings) -Right $plan.Values)) { throw 'The new settings.psd1 did not read back as written.' }
            $null = Copy-DeployFile -Source $oldSettings -Destination (Join-Path $dataStaged 'backups\legacy\Launcher\settings.psd1')
        }
    } catch {
        $remove = if ($mode -eq 'Migrate') { "LauncherData.new, $leftovers" } else { $leftovers }
        throw "Staging failed and nothing the launcher uses was changed. Remove $remove, then run the same command again. $(Format-DeployCause -ErrorRecord $_)"
    }

    # The data first: until the code swap, the old launcher in Launcher keeps working with
    # Launcher\settings.psd1, which stays there.
    if ($mode -eq 'Migrate') {
        try { Rename-DeployItem -Path $dataStaged -NewName 'LauncherData' }
        catch { throw "LauncherData.new could not become LauncherData, and nothing the launcher uses was changed. Remove LauncherData.new, $leftovers, then run the same command again. $(Format-DeployCause -ErrorRecord $_)" }
    }
    if ($plan) {
        try { Move-DeployLegacyData -Target $Target -Plan $plan }
        catch {
            # Running again would stop at the same copy, so the step comes first. A write that
            # failed between its two renames leaves such copies without saying so itself.
            $leftover = "$($_.Exception.Data['PvmWrite'])" -eq 'Leftover'
            $steps = @(Get-DeployLeftoverStep -Folder (Join-Path $Target 'LauncherData\backups\legacy'))
            if (-not $leftover) { foreach ($step in $steps) { Write-Verbose $step } }
            if ($leftover -or $steps.Count) {
                throw ('The migration stopped part way at a copy below LauncherData\backups\legacy that needs a step by hand, but the launcher in Launcher still works with ' +
                    "Launcher\settings.psd1. -Verbose names the copy and the step; take it, then run the same command again. $(Format-DeployCause -ErrorRecord $_)")
            }
            throw "The migration stopped part way, but the launcher in Launcher still works with Launcher\settings.psd1. Run the same command again to finish it. $(Format-DeployCause -ErrorRecord $_)"
        }
    }

    if ($mode -eq 'Install') {
        try {
            Rename-DeployItem -Path $staged -NewName 'Launcher'
            Rename-DeployItem -Path $cmdStaged -NewName $CmdName
        } catch {
            throw "The launcher could not be put in place. Rename Launcher.new to Launcher and '$CmdName.new' to '$CmdName' if they are still there. $(Format-DeployCause -ErrorRecord $_)"
        }
        $result.Applied = $true
        return $result
    }

    # A removal left by a deploy that stopped makes room for this one. Staging came first, so a
    # failed copy costs no earlier launcher.
    if ($finishRemoval) {
        try { $result.Removed = @(Complete-DeployRemoval -Target $Target -CmdSource $cmdSource) }
        catch { throw "Launcher.previous.remove could not be removed, so nothing the launcher uses was changed. Remove $leftovers, move Launcher.previous.remove away, then deploy again. $(Format-DeployCause -ErrorRecord $_)" }
    }

    # Until the last check passes, the older copy waits as Launcher.previous.remove, so a deploy
    # that fails or is cut off never costs the way back.
    $rotate = $hasPrevious
    $backToPrevious = if ($rotate) { ', then Launcher.previous.remove back to Launcher.previous' } else { '' }
    if ($rotate) {
        try { Rename-DeployItem -Path $previous -NewName $RemovalFolderName }
        catch { throw "Launcher.previous could not be renamed, so the stick's launcher is unchanged. A window, console or program probably has the folder or a file in it open: close it, remove $leftovers, then deploy again. $(Format-DeployCause -ErrorRecord $_)" }
    }
    try {
        Rename-DeployItem -Path $launcher -NewName 'Launcher.previous'
    } catch {
        $reason = Format-DeployCause -ErrorRecord $_
        if ($rotate) {
            try { Rename-DeployItem -Path $removal -NewName 'Launcher.previous' }
            catch { throw "Launcher could not be renamed, so the stick's launcher is unchanged, but Launcher.previous.remove could not be renamed back. Rename Launcher.previous.remove back to Launcher.previous, remove $leftovers, then deploy again. $reason" }
        }
        throw "Launcher could not be renamed, so the stick's launcher is unchanged. A window, console or program probably has the Launcher folder or a file in it open: close it, remove $leftovers, then deploy again. $reason"
    }
    try {
        Rename-DeployItem -Path $staged -NewName 'Launcher'
    } catch {
        $reason = Format-DeployCause -ErrorRecord $_
        try {
            Rename-DeployItem -Path $previous -NewName 'Launcher'
        } catch {
            throw "Launcher is missing: Launcher.previous holds the launcher that was in use. Rename Launcher.previous back to Launcher$backToPrevious, remove $leftovers, then deploy again. $reason"
        }
        if ($rotate) {
            try { Rename-DeployItem -Path $removal -NewName 'Launcher.previous' }
            catch { throw "Launcher is back as it was, but Launcher.previous.remove could not be renamed back. Rename Launcher.previous.remove back to Launcher.previous, remove $leftovers, then deploy again. $reason" }
        }
        throw "Launcher.new could not take the place of Launcher, so Launcher is back as it was. Remove $leftovers, then deploy again. $reason"
    }
    try {
        foreach ($old in $oldCmds) { Move-Item -LiteralPath $old.FullName -Destination (Join-Path $previous $old.Name) }
        Rename-DeployItem -Path $cmdStaged -NewName $CmdName
    } catch {
        $next = if ($rotate) { ' The next deploy then removes Launcher.previous.remove.' } else { '' }
        throw "The new launcher is in Launcher, but its .cmd is not in place yet. Move the old launcher .cmd files at the stick's root into Launcher.previous, then rename '$CmdName.new' to '$CmdName'.$next $(Format-DeployCause -ErrorRecord $_)"
    }

    # The last check: nothing older is deleted unless the launcher in place is the clone's.
    $checked = $false
    try {
        $checked = (Test-DeployStagedCode -Folder $launcher -Sources $sources -Sums $sums -Version $version) -and
        (Get-DeployHash -Path $cmdTarget) -eq (Get-DeployHash -Path $cmdSource)
    } catch {
        Write-Verbose "The new launcher cannot be read back: $($_.Exception.Message)"
    }
    if (-not $checked) {
        throw ("The new launcher in Launcher does not match the clone, so nothing was deleted. To go back, rename Launcher to another name and Launcher.previous back to Launcher$backToPrevious, " +
            "and move '$CmdName' from the restored Launcher to the stick's root, over the one there. Then deploy again.")
    }
    $result.Applied = $true
    if ($rotate) {
        # The new launcher works by now, so a copy that cannot go is a note, not a failed deploy.
        try { $result.Removed = @($result.Removed) + @(Complete-DeployRemoval -Target $Target -CmdSource $cmdSource) }
        catch { $result.RemovalProblem = (Get-DeployCause -ErrorRecord $_).TrimEnd('.') }
    }
    $result
}


# Return the report lines for the deploy result $Result (Invoke-PvmDeploy): what was deployed, or
# would be under -WhatIf, and what a migration moved. They name no file from the stick.
function Format-DeployReport {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $done = $Result.Applied
    $moved = if ($done) { 'moved' } else { 'to move' }
    if ($Result.Mode -eq 'Finish') {
        "Launcher already holds $($Result.Version); $(if ($done) { 'finished' } else { 'would finish' }) the removal that an earlier deploy left."
    } else {
        "$(if ($done) { 'deployed' } else { 'would deploy' }) $($Result.Version) ($($Result.Mode))."
    }
    $plan = $Result.Plan
    if ($plan) {
        if ($Result.Mode -eq 'Resume') {
            "settings: LauncherData\settings.psd1 $(if ($done) { 'was kept' } else { 'would be kept' }) as it is, with a copy of the old file in LauncherData\backups\legacy\Launcher."
        } else {
            "settings: LauncherData\settings.psd1 $(if ($done) { 'holds' } else { 'would hold' }) them in schema 2, with a copy of the old file in LauncherData\backups\legacy\Launcher."
        }
        "log $moved to LauncherData\logs: $(if ($plan.Log) { 1 } else { 0 })."
        "descriptor copies $moved to LauncherData\backups\legacy and disarmed: $($plan.Descriptors)."
        "VirtualBox copies $moved to LauncherData\backups\legacy: $($plan.VirtualBoxCopies)."
        "other copies left beside the VM files: $($plan.KeptCopies)."
    }
    if ($Result.Mode -ne 'Install') {
        if ($Result.Mode -ne 'Finish') { "old launcher .cmd files $moved into Launcher.previous: $($Result.MovedCmdCount)." }
        "Launcher.previous $(if ($done) { 'holds' } else { 'would hold' }) version $($Result.PreviousVersion)."
    }
    foreach ($older in @(if ($done) { $Result.Removed } else { $Result.Removing })) {
        "$(if ($done) { 'removed' } else { 'would remove' }) the older launcher copy, version $older."
    }
    if ($Result.RemovalProblem) {
        "the older launcher copy stays in Launcher.previous.remove: $($Result.RemovalProblem). Check what it holds, then move it away before the next deploy."
    }
}

# Run only when started as a script, not when a test dot-sources this file for its functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $Target) { throw 'Give -Target, the folder on the stick that holds the Launcher and LauncherData folders.' }
        # Convert-Path returns nothing for a missing folder whose name holds [ or ], so the folder
        # is checked first.
        if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw 'The -Target folder does not exist. Give the folder on the stick that holds the Launcher and LauncherData folders.' }
        $Target = Convert-Path -LiteralPath $Target
        # -WhatIf and -Confirm go to Invoke-PvmDeploy alone: left in effect for the whole script,
        # they also reach the modules PowerShell loads on the way, which then skip or ask about
        # parts of their setup. For the same reason CimCmdlets, which the VM check needs, is loaded
        # before the deploy.
        $whatIf = [bool]$WhatIfPreference
        $confirm = $PSBoundParameters.ContainsKey('Confirm') -and [bool]$PSBoundParameters['Confirm']
        $WhatIfPreference = $false
        $ConfirmPreference = 'High'
        Import-Module -Name CimCmdlets
        $deploy = @{ RepositoryPath = (Split-Path $PSScriptRoot -Parent); Target = $Target; MigrateSettings = $MigrateSettings; VmDisplayName = $VmDisplayName; GuestName = $GuestName }
        $done = Invoke-PvmDeploy @deploy -WhatIf:$whatIf -Confirm:$confirm
        foreach ($line in Format-DeployReport -Result $done) { Write-Output "Deploy-PortableVM: $line" }
        exit 0
    } catch {
        # A message from Windows or PowerShell can quote a path on the stick, whose folder and file
        # names can be private, so only its cause is printed; -Verbose shows the message.
        if (Test-DeployOwnMessage -ErrorRecord $_) { $message = Get-DeployOwnMessage -ErrorRecord $_ }
        else {
            Write-Verbose $_.Exception.Message
            $cause = if (Get-Command -Name Get-PvmErrorCause -ErrorAction SilentlyContinue) { Get-PvmErrorCause -ErrorRecord $_ } else { "an error of type $($_.Exception.GetType().Name)" }
            $message = "the deploy stopped: $cause (-Verbose shows the details)."
        }
        Write-Output "Deploy-PortableVM: $message"
        exit 1
    }
}
