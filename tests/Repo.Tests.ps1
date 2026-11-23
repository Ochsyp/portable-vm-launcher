# Repository rules that keep private data out and the files usable on Windows: what git tracks,
# how it stores text, that the sources are ASCII and parse in Windows PowerShell 5.1, static
# guards on what the launcher and the tools may do, and that the privacy guard rails refuse what
# they should. The file checks read git's index, so a new file counts once it is staged. The
# guard-rail checks build small sample repositories in TestDrive; their private-looking values
# are put together at run time, so this file itself passes privacy-scan and gitleaks.

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:tracked = @(& git -C $script:repoRoot -c core.quotePath=false ls-files)
    $script:launcher = Join-Path $script:repoRoot 'src\Start-PortableVM.ps1'
    $script:module = Join-Path $script:repoRoot 'src\PortableVM.psm1'
    $script:example = Join-Path $script:repoRoot 'examples\settings.example.psd1'
    # The PowerShell sources of the launcher and the tools, as full paths.
    $script:sources = @($script:tracked | Where-Object { $_ -match '^(src|tools)/[^/]+\.(ps1|psm1)$' } |
            ForEach-Object { Join-Path $script:repoRoot $_ })
    $script:utf8 = New-Object System.Text.UTF8Encoding $false
    # A name with a letter outside ASCII, as a denylisted name can have.
    $script:sampleName = 'K' + [char]0x00E9 + 'l' + [char]0x00F8 + 'n' + [char]0x00EF

    # Git for Windows' sh, which runs the hooks: the one on the path, as in Git Bash, or the one
    # in a folder above git.exe, which sits in cmd\ or mingw64\bin\ of the Git folder.
    $script:sh = (Get-Command -Name sh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $script:sh) {
        $folder = Split-Path (Get-Command -Name git -CommandType Application | Select-Object -First 1).Source -Parent
        while ($folder -and -not $script:sh) {
            $script:sh = @('bin\sh.exe', 'usr\bin\sh.exe') | ForEach-Object { Join-Path $folder $_ } |
                Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            $folder = Split-Path $folder -Parent
        }
    }

    # Return the syntax tree of the PowerShell file $Path.
    function Get-SourceAst {
        param([string]$Path)
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    }

    # Return the name of the innermost function around the syntax tree node $Ast, or '' at the top
    # level.
    function Get-SourceFunctionName {
        param($Ast)
        for ($parent = $Ast.Parent; $null -ne $parent; $parent = $parent.Parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $parent.Name }
        }
        ''
    }

    # Return where the syntax tree $Ast deletes, moves, copies or swaps a file or folder by itself,
    # as '<member> in <function>': a member named Delete, MoveTo, CopyTo, Encrypt or Decrypt on
    # anything, as on an item from Get-Item, and Move, Copy or Replace on a File or Directory type.
    function Get-SourceFileChange {
        param($Ast)
        foreach ($member in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            $name = $member.Member.Extent.Text
            $type = if ($member.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) { $member.Expression.TypeName.FullName } else { '' }
            $anywhere = @('Delete', 'MoveTo', 'CopyTo', 'Encrypt', 'Decrypt') -contains $name
            $onType = $type -match '(?i)(^|\.)(File|Directory|FileInfo|DirectoryInfo)$' -and @('Move', 'Copy', 'Replace') -contains $name
            if ($anywhere -or $onType) { "$name in $(Get-SourceFunctionName -Ast $member)" }
        }
    }

    # Return where the syntax tree $Ast writes a file other than through the module's safe write,
    # as '<what> in <function>': a member of a File or FileInfo type that writes or opens a file, a
    # FileStream, StreamWriter or BinaryWriter made with ::new or New-Object, the cmdlets that write
    # files, and a redirection to a file.
    function Get-SourceFileWrite {
        param($Ast)
        foreach ($member in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            $name = $member.Member.Extent.Text
            $type = if ($member.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) { $member.Expression.TypeName.FullName } else { '' }
            if ($type -match '(?i)(^|\.)(File|FileInfo)$' -and $name -match '(?i)^((Write|Append)All(Text|Lines|Bytes)|Create|CreateText|AppendText|OpenWrite|Open|Copy)$') {
                "$name in $(Get-SourceFunctionName -Ast $member)"
            } elseif ($name -eq 'new' -and $type -match '(?i)(^|\.)(FileStream|StreamWriter|BinaryWriter)$') {
                "$($Matches[2]) in $(Get-SourceFunctionName -Ast $member)"
            } elseif ($name -eq 'Create' -and $type -match '(?i)(^|\.)FileSystemAclExtensions$') {
                "FileSystemAclExtensions in $(Get-SourceFunctionName -Ast $member)"
            }
        }
        foreach ($command in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if (@('Set-Content', 'Add-Content', 'Out-File', 'Copy-Item', 'Tee-Object', 'Export-Clixml', 'Export-Csv') -contains $name) {
                "$name in $(Get-SourceFunctionName -Ast $command)"
            } elseif ($name -eq 'New-Object' -and $command.Extent.Text -match '(?i)\b(FileStream|StreamWriter|BinaryWriter)\b') {
                "$($Matches[1]) in $(Get-SourceFunctionName -Ast $command)"
            }
        }
        foreach ($redirection in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)) {
            $target = $redirection.Location
            if ($target -is [System.Management.Automation.Language.VariableExpressionAst] -and $target.VariablePath.UserPath -eq 'null') { continue }
            "redirection in $(Get-SourceFunctionName -Ast $redirection)"
        }
    }

    # Return the commands that the syntax tree $Ast calls, each with its Name, Line and Function,
    # the innermost function around the call ('' at the top level).
    function Get-SourceCommand {
        param($Ast)
        foreach ($command in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $function = ''
            for ($parent = $command.Parent; $null -ne $parent; $parent = $parent.Parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $parent.Name; break }
            }
            [pscustomobject]@{
                Name     = $command.GetCommandName()
                Operator = $command.InvocationOperator
                Line     = $command.Extent.StartLineNumber
                Function = $function
            }
        }
    }

    # Run git with $Arguments in the repository at $Path; throw when git fails.
    function Invoke-SampleGit {
        param([string]$Path, [string[]]$Arguments)
        $output = & git -C $Path -c core.autocrlf=false -c commit.gpgsign=false @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($Arguments[0]) failed: $output" }
    }

    # Create an empty repository at $Path with a test identity, and write the files in $Files
    # (relative path = content) as UTF-8 without a BOM.
    function Initialize-SampleRepository {
        param([string]$Path, [hashtable]$Files)
        $null = New-Item -ItemType Directory -Path $Path -Force
        Invoke-SampleGit -Path $Path -Arguments @('init', '-q')
        Invoke-SampleGit -Path $Path -Arguments @('config', 'user.name', 'Test')
        Invoke-SampleGit -Path $Path -Arguments @('config', 'user.email', 'test@example.com')
        foreach ($name in $Files.Keys) {
            [IO.File]::WriteAllText((Join-Path $Path $name), $Files[$name], $script:utf8)
        }
    }

    # Run .githooks/privacy-scan --staged in the repository at $Path; return its exit code and
    # its lines.
    function Invoke-PrivacyScan {
        param([string]$Path)
        $scanner = (Join-Path $script:repoRoot '.githooks\privacy-scan') -replace '\\', '/'
        Push-Location -LiteralPath $Path
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $lines = @(& $script:sh $scanner --staged 2>&1 | ForEach-Object { "$_" }) }
        finally {
            $ErrorActionPreference = $previous
            Pop-Location
        }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
    }

    # Run tools/Find-PrivateData.ps1 -History on the repository at $Path in a new Windows
    # PowerShell; return its exit code and its lines.
    function Invoke-FindPrivateData {
        param([string]$Path)
        $tool = Join-Path $script:repoRoot 'tools\Find-PrivateData.ps1'
        $lines = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -RepositoryPath $Path -History 2>&1 |
            ForEach-Object { "$_" })
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
    }
}

Describe 'Tracked files' {
    It 'include the launcher and its tools, so the other checks have something to check' {
        foreach ($path in 'src/Start-PortableVM.ps1', 'src/PortableVM.psm1', 'tools/Deploy-PortableVM.ps1',
            'tools/Get-StickInventory.ps1', 'examples/settings.example.psd1', 'tests/Settings.Tests.ps1') {
            $script:tracked | Should -Contain $path
        }
    }

    It 'include no real settings, logs, backups or VM files' {
        $private = '(^|/)settings[^/]*\.psd1|(^|/)LauncherData/|\.log$|\.log\.[0-9]|\.bak$|\.orig$|\.launcher-backup$|\.pvm-tmp$|' +
            '(^|/)VirtualBox\.xml|(^|/)VBox[^/]*\.log|\.(vmx|vmxf|vmsd|vmss|vmem|vmdk|nvram|vbox|vbox-prev|vbox-tmp|vdi|vhd|vhdx|sav)$'
        $script:tracked | Where-Object { $_ -match $private -and $_ -notmatch '(^|/)settings\.example\.psd1$' } |
            Should -BeNullOrEmpty
    }

    It 'store text with LF line endings' {
        $eol = @(& git -C $script:repoRoot -c core.quotePath=false ls-files --eol)
        $eol | Where-Object { $_ -match '^i/(crlf|mixed)\s' } | Should -BeNullOrEmpty
    }

    It 'keep PowerShell and batch sources ASCII, without a BOM' {
        $sources = $script:tracked | Where-Object { $_ -match '\.(ps1|psm1|psd1|cmd|bat)$' }
        $notAscii = foreach ($path in $sources) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $script:repoRoot $path))
            if (@($bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0) { $path }
        }
        $notAscii | Should -BeNullOrEmpty
    }
}

Describe 'Launcher sources' {
    It 'parse in Windows PowerShell 5.1, every tracked PowerShell file' {
        $files = @($script:tracked | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' })
        $files | Should -Contain 'src/PortableVM.psm1'
        $broken = foreach ($path in $files) {
            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoRoot $path), [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors) { "${path}: $($parseErrors[0].Message)" }
        }
        $broken | Should -BeNullOrEmpty
    }

    It 'include the script Start VM.cmd starts, which the deploy tool puts in Launcher' {
        $cmd = Get-Content -LiteralPath (Join-Path $script:repoRoot 'Start VM.cmd') -Raw
        $cmd | Should -Match ([regex]::Escape('-File "%~dp0Launcher\Start-PortableVM.ps1"'))
    }

    It 'ask before a resume with No as the default answer' {
        $text = [IO.File]::ReadAllText($script:launcher)
        $text | Should -Match 'function Show-Question[\s\S]*MessageBoxButtons\]::YesNo[\s\S]*MessageBoxDefaultButton\]::Button2'
        $text | Should -Match ([regex]::Escape('Invoke-PortableVM -LauncherPath $Here -DryRun:$DryRun -AskResume { param([string]$Question, [string]$Caption) Show-Question -Message $Question -Caption $Caption }'))
    }

    It 'keep the administrator-rights block of the script exactly as it was before the redesign' {
        # The 12 lines from '# --- Administrator rights', joined with LF, as of commit b19dbff.
        $adminBlockSha256 = 'c0a699741785a202c42dec700de4091aab912c898ae66800d6708502c354efa7'
        $lines = [IO.File]::ReadAllLines($script:launcher)
        $first = [Array]::IndexOf($lines, '# --- Administrator rights -------------------------------------------------------------')
        $first | Should -BeGreaterThan 0
        $block = [Text.Encoding]::ASCII.GetBytes(($lines[$first..($first + 11)] -join "`n"))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = ($sha.ComputeHash($block) | ForEach-Object { $_.ToString('x2') }) -join '' }
        finally { $sha.Dispose() }
        $actual | Should -BeExactly $adminBlockSha256
    }

    It 'keep the start line of Start VM.cmd as it was before the redesign' {
        $lines = [IO.File]::ReadAllLines((Join-Path $script:repoRoot 'Start VM.cmd'))
        $lines[-1] | Should -BeExactly 'start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Launcher\Start-PortableVM.ps1"'
    }

    It 'give every function a comment on the line above it' {
        $missing = foreach ($path in $script:sources) {
            $lines = [IO.File]::ReadAllLines($path)
            foreach ($function in (Get-SourceAst -Path $path).FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $line = $function.Extent.StartLineNumber
                if ($line -lt 2 -or $lines[$line - 2] -notmatch '^\s*#') { "$(Split-Path $path -Leaf): $($function.Name)" }
            }
        }
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'Static guards' {
    It 'let the module define functions only, so importing it runs nothing, after it sets strict mode' {
        $statements = (Get-SourceAst -Path $script:module).EndBlock.Statements
        $statements[0].Extent.Text | Should -BeExactly 'Set-StrictMode -Version 3.0'
        $other = $statements | Where-Object {
            $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $_.Extent.Text -notin @('Set-StrictMode -Version 3.0', "`$ErrorActionPreference = 'Stop'")
        }
        $other | ForEach-Object { $_.Extent.Text } | Should -BeNullOrEmpty
    }

    It 'leave exits, dialogs and prompts in src, and the administrator prompt anywhere, to Start-PortableVM.ps1' {
        $others = @($script:sources | Where-Object { $_ -like (Join-Path $script:repoRoot 'src\*') -and $_ -ne $script:launcher })
        $others | Should -Contain $script:module
        foreach ($path in $others) {
            (Get-SourceAst -Path $path).FindAll({ $args[0] -is [System.Management.Automation.Language.ExitStatementAst] }, $true) | Should -BeNullOrEmpty
        }
        $dialogs = 'System\.Windows\.Forms|System\.Windows\.MessageBox|PresentationFramework|Microsoft\.VisualBasic|WScript\.Shell|Read-Host|\.UI\.Prompt|Out-GridView|RunAs'
        $script:sources | Where-Object { $_ -ne $script:launcher -and [IO.File]::ReadAllText($_) -match $dialogs } | Should -BeNullOrEmpty
    }

    It 'let only the adapters in the module read the PC or run programs' {
        $adapters = 'Invoke-PvmGetPartition', 'Invoke-PvmGetDisk', 'Invoke-PvmGetProcess', 'Invoke-PvmTestProcess', 'Invoke-PvmGetDeviceGuard',
        'Invoke-PvmGetRegistryValue', 'Invoke-PvmNative', 'Invoke-PvmStartProcess', 'Invoke-PvmSetEnvironment', 'Invoke-PvmSleep',
        'Invoke-PvmTestAdministrator', 'Invoke-PvmEnterLock', 'Invoke-PvmExitLock'
        $reads = 'Get-Partition', 'Get-Disk', 'Get-Volume', 'Get-PhysicalDisk', 'Get-CimInstance', 'Get-WmiObject', 'Get-Process',
        'Get-ItemProperty', 'Get-ItemPropertyValue', 'Start-Process', 'Start-Sleep', 'Invoke-CimMethod', 'Invoke-WmiMethod'
        $ast = Get-SourceAst -Path $script:module
        $outside = Get-SourceCommand -Ast $ast | Where-Object {
            (($reads -contains $_.Name) -and $adapters -notcontains $_.Function) -or
            ($_.Operator -eq 'Ampersand' -and $_.Function -ne 'Invoke-PvmNative')
        }
        $outside | ForEach-Object { "$($_.Name) at line $($_.Line) in $($_.Function)" } | Should -BeNullOrEmpty
        # .NET types that reach processes, the registry or WMI directly.
        $types = $ast.FindAll({
                $args[0] -is [System.Management.Automation.Language.TypeExpressionAst] -or
                $args[0] -is [System.Management.Automation.Language.TypeConstraintAst]
            }, $true) | ForEach-Object { $_.TypeName.FullName }
        $types | Where-Object { $_ -match '(?i)Diagnostics\.Process|Win32\.Registry|^System\.Management(?!\.Automation)' } | Should -BeNullOrEmpty
    }

    It 'never change disks, partitions or volumes, nor delete VirtualBox media' -Tag 'WindowsOnly' {
        # Every Storage command that is not a Get, and the generic CIM and WMI writers.
        $storage = @(Get-Command -Module Storage -ErrorAction SilentlyContinue | Where-Object { $_.Verb -ne 'Get' } | ForEach-Object { $_.Name })
        $storage.Count | Should -BeGreaterThan 20
        $changes = $storage + @('Invoke-CimMethod', 'Invoke-WmiMethod', 'Set-CimInstance', 'Set-WmiInstance', 'Remove-CimInstance', 'Remove-WmiObject')
        $found = foreach ($path in $script:sources) {
            Get-SourceCommand -Ast (Get-SourceAst -Path $path) | Where-Object { $changes -contains $_.Name } |
                ForEach-Object { "$(Split-Path $path -Leaf): $($_.Name)" }
            if ([IO.File]::ReadAllText($path) -match '(?i)\b(diskpart|mountvol|bcdedit)(\.exe)?\b|--delete') { "$(Split-Path $path -Leaf): a disk tool or --delete" }
        }
        $found | Should -BeNullOrEmpty
    }

    It 'keep the inventory tool read-only' {
        $ast = Get-SourceAst -Path (Join-Path $script:repoRoot 'tools\Get-StickInventory.ps1')
        $writers = 'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Set-Item',
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Clear-Content', 'Clear-Item', 'Start-Process', 'Invoke-Expression',
        'Export-Csv', 'Export-Clixml', 'Tee-Object', 'Start-Transcript', 'Set-Acl'
        Get-SourceCommand -Ast $ast | Where-Object { $writers -contains $_.Name } | ForEach-Object { $_.Name } | Should -BeNullOrEmpty
        $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FileRedirectionAst] }, $true) | Should -BeNullOrEmpty
        # The .NET members the tool calls, all of which only read; a new one is added here on purpose.
        $allowed = 'Close', 'Create', 'Equals', 'GetAttribute', 'GetFullPath', 'GetInvalidPathChars', 'GetType', 'IndexOfAny', 'IsPathRooted',
        'Load', 'Matches', 'new', 'ReadAllText', 'SelectNodes', 'ToLowerInvariant', 'Trim', 'TrimEnd'
        $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
            ForEach-Object { $_.Member.Extent.Text } | Where-Object { $allowed -cnotcontains $_ } | Should -BeNullOrEmpty
    }

    It 'let the deploy tool delete only its own older copy, in one function, one file at a time and without recursion' {
        $ast = Get-SourceAst -Path (Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1')
        $deletes = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $args[0].Member.Extent.Text -eq 'Delete' }, $true))
        @($deletes | ForEach-Object { $_.Extent.Text -replace '\(.*', '' } | Sort-Object) | Should -BeExactly @('[IO.Directory]::Delete', '[IO.File]::Delete')
        @($deletes | ForEach-Object { Get-SourceFunctionName -Ast $_ } | Sort-Object -Unique) | Should -BeExactly @('Remove-DeployOwnCopy')
        $folderDelete = $deletes | Where-Object { $_.Extent.Text -like '`[IO.Directory`]*' }
        $folderDelete.Arguments.Count | Should -Be 2
        $folderDelete.Arguments[1].Extent.Text | Should -BeExactly '$false'
        # One caller, which names the folder only through the one fixed name.
        $calls = @(Get-SourceCommand -Ast $ast | Where-Object { $_.Name -eq 'Remove-DeployOwnCopy' })
        $calls.Count | Should -Be 1
        $calls[0].Function | Should -BeExactly 'Complete-DeployRemoval'
        $caller = $ast.Find({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Complete-DeployRemoval' }, $true)
        $caller.Extent.Text | Should -Match ([regex]::Escape('$folder = Join-Path $Target $RemovalFolderName'))
        $names = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$RemovalFolderName' }, $true))
        $names.Count | Should -Be 1
        $names[0].Right.Extent.Text | Should -BeExactly "'Launcher.previous.remove'"
    }

    It 'keep the deploy tool from any other delete: no Remove-Item, Clear-* or -Force that replaces, and files written only through the safe write' {
        $ast = Get-SourceAst -Path (Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1')
        Get-SourceCommand -Ast $ast | Where-Object { $_.Name -in 'Remove-Item', 'Clear-Content', 'Clear-Item' } | Should -BeNullOrEmpty
        # Besides the guarded delete above, a rename is the one change the tool makes by itself.
        @(Get-SourceFileChange -Ast $ast | Sort-Object) | Should -BeExactly @('Delete in Remove-DeployOwnCopy', 'Delete in Remove-DeployOwnCopy', 'Move in Rename-DeployItem')
        # Move-Item -Force would replace, and so delete, an existing file.
        $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandParameterAst] -and $args[0].ParameterName -eq 'Force' }, $true) |
            Where-Object { $_.Parent.GetCommandName() -ne 'Import-Module' -and $_.Parent.GetCommandName() -ne 'New-Item' -and $_.Parent.GetCommandName() -ne 'Get-ChildItem' } |
            ForEach-Object { "$($_.Parent.GetCommandName()) at line $($_.Extent.StartLineNumber)" } | Should -BeNullOrEmpty
        # The tool writes files only through the module's safe write; the one stream it opens, in
        # one of three ways for the engine and the system, checks access.
        @(Get-SourceFileWrite -Ast $ast | Sort-Object -Unique) |
            Should -BeExactly @('FileStream in Assert-DeployWriteAccess', 'FileSystemAclExtensions in Assert-DeployWriteAccess', 'Open in Assert-DeployWriteAccess')
        @(Get-SourceCommand -Ast $ast | Where-Object { $_.Name -eq 'Write-PvmFile' }).Count | Should -BeGreaterThan 0
    }

    It 'catch the ways a source could change or write a file past the safe write: <Code>' -ForEach @(
        @{ Code = 'function F { ([IO.FileInfo]$p).Delete() }'; Change = 'Delete in F'; Write = '' }
        @{ Code = 'function F { (Get-Item -LiteralPath $p).Delete() }'; Change = 'Delete in F'; Write = '' }
        @{ Code = 'function F { $item.MoveTo($q) }'; Change = 'MoveTo in F'; Write = '' }
        @{ Code = 'function F { [IO.Directory]::Move($p, $q) }'; Change = 'Move in F'; Write = '' }
        @{ Code = 'function F { [System.IO.File]::Replace($a, $b, $c) }'; Change = 'Replace in F'; Write = '' }
        @{ Code = 'function F { [IO.File]::Open($p, ''Create'') }'; Change = ''; Write = 'Open in F' }
        @{ Code = 'function F { [System.IO.File]::WriteAllText($p, ''x'') }'; Change = ''; Write = 'WriteAllText in F' }
        @{ Code = 'function F { New-Object IO.FileStream $p, Create }'; Change = ''; Write = 'FileStream in F' }
        @{ Code = 'function F { [System.IO.FileStream]::new($p, ''Create'') }'; Change = ''; Write = 'FileStream in F' }
        @{ Code = 'function F { [IO.StreamWriter]::new($p) }'; Change = ''; Write = 'StreamWriter in F' }
        @{ Code = 'function F { [System.IO.FileSystemAclExtensions]::Create($i, ''Create'', $r, ''None'', 4096, ''None'', $null) }'; Change = ''; Write = 'FileSystemAclExtensions in F' }
        @{ Code = 'function F { ''x'' > $p }'; Change = ''; Write = 'redirection in F' }
        @{ Code = 'function F { ''x'' | Set-Content -LiteralPath $p }'; Change = ''; Write = 'Set-Content in F' }
        @{ Code = 'function F { ''x'' > $null; $text.Replace(''a'', ''b'') }'; Change = ''; Write = '' }
    ) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
        @(Get-SourceFileChange -Ast $ast) | Should -BeExactly @(@($Change) | Where-Object { $_ })
        @(Get-SourceFileWrite -Ast $ast) | Should -BeExactly @(@($Write) | Where-Object { $_ })
    }

    It 'branch on -DryRun in the module only where a dry run must differ' {
        # A new branch needs a change of this map on purpose.
        $counts = @{}
        foreach ($node in (Get-SourceAst -Path $script:module).FindAll({
                    ($args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and $args[0].VariablePath.UserPath -eq 'DryRun' -and
                    $args[0].Parent -isnot [System.Management.Automation.Language.ParameterAst]) -or
                    ($args[0] -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $args[0].Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $args[0].Member.Value -eq 'DryRun')
                }, $true)) {
            for ($parent = $node.Parent; $null -ne $parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]; $parent = $parent.Parent) {}
            $name = if ($parent) { $parent.Name } else { '' }
            $counts[$name] = 1 + [int]$counts[$name]
        }
        $expected = @{ 'Invoke-PvmStopUnlessDryRun' = 1; 'Confirm-PvmResume' = 1; 'Invoke-PvmVMware' = 3; 'Invoke-PvmVirtualBox' = 2; 'Invoke-PortableVM' = 4 }
        @($counts.Keys | Sort-Object | ForEach-Object { "$_=$($counts[$_])" }) | Should -BeExactly @($expected.Keys | Sort-Object | ForEach-Object { "$_=$($expected[$_])" })
    }

    It 'keep the mutex and the rights check in their helpers' {
        foreach ($case in @(
                @{ Path = $script:module; Pattern = 'Threading\.Mutex|MutexRights|AbandonedMutexException'; Allowed = @('Enter-PvmMutex') }
                @{ Path = $script:module; Pattern = 'Security\.Principal'; Allowed = @('Invoke-PvmTestAdministrator') }
                @{ Path = $script:launcher; Pattern = 'Threading\.Mutex|MutexRights'; Allowed = @('Test-LockHeld') }
                # '' is the administrator-rights block at the script's top level.
                @{ Path = $script:launcher; Pattern = 'Security\.Principal'; Allowed = @('Test-Administrator', '') }
            )) {
            $places = foreach ($type in (Get-SourceAst -Path $case.Path).FindAll({
                        $args[0] -is [System.Management.Automation.Language.TypeExpressionAst] -or $args[0] -is [System.Management.Automation.Language.TypeConstraintAst]
                    }, $true)) {
                if ($type.TypeName.FullName -notmatch $case.Pattern) { continue }
                for ($parent = $type.Parent; $null -ne $parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]; $parent = $parent.Parent) {}
                if ($parent) { $parent.Name } else { '' }
            }
            @($places).Count | Should -BeGreaterThan 0
            @($places | Where-Object { $case.Allowed -notcontains $_ }) | Should -BeNullOrEmpty
        }
    }

    It 'let the module delete only the copies of its safe writes, and move or swap a file only to put the log aside and in the safe write' {
        $ast = Get-SourceAst -Path $script:module
        Get-SourceCommand -Ast $ast | Where-Object { $_.Name -in 'Remove-Item', 'Move-Item', 'Rename-Item', 'Clear-Content', 'Clear-Item' } |
            ForEach-Object { "$($_.Name) at line $($_.Line)" } | Should -BeNullOrEmpty
        # A new place that deletes, moves, copies or swaps a file needs a change of this map on purpose.
        @(Get-SourceFileChange -Ast $ast | Sort-Object) | Should -BeExactly @('Delete in Remove-PvmWriteCopy', 'Move in Move-PvmOldLog', 'Move in Write-PvmFile', 'Replace in Switch-PvmFile')
    }

    It 'let the module write files only through Write-PvmFile, the log aside' {
        # The streams of the log, of the check of its format and of the safe write itself.
        @(Get-SourceFileWrite -Ast (Get-SourceAst -Path $script:module) | Sort-Object -Unique) |
            Should -BeExactly @('FileStream in Open-PvmAppendStream', 'FileStream in Test-PvmLogFormat', 'FileStream in Write-PvmFile',
                'FileSystemAclExtensions in Open-PvmAppendStream')
    }

    It 'end in the script''s one trap, logged with its details and shown, with exit code 1, what no step of the script handles' {
        $traps = @((Get-SourceAst -Path $script:launcher).EndBlock.Traps | Where-Object { $_ })
        $traps.Count | Should -Be 1
        $last = $traps[0].Body.Statements[-1]
        $last | Should -BeOfType ([System.Management.Automation.Language.ExitStatementAst])
        $last.Pipeline.Extent.Text | Should -BeExactly '1'
        $traps[0].Body.Statements[0].Extent.Text | Should -BeExactly '$script:AskingForRights = $false'
        $traps[0].Body.Statements[1].Extent.Text | Should -BeExactly '$message = "Unexpected error in Start-PortableVM.ps1: $($_.Exception.Message)"'
        # The error is logged with its details, the message says when that failed, and a failure of
        # the log line itself cannot end the trap before its message and exit code.
        $traps[0].Body.Statements[2].Extent.Text | Should -BeExactly '$problem = try { Add-StopLine -Message $message -ErrorRecord $_ } catch { Get-ErrorCause -Exception $_.Exception }'
        $traps[0].Body.Statements[3].Extent.Text | Should -BeExactly '$message = Add-LogNote -Message $message -Problem $problem'
        $commands = @($traps[0].Body.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
        @($commands | Where-Object { $_.GetCommandName() -eq 'Show-Message' }).Count | Should -Be 1
    }

    It 'word every log cause after "because" in the module through Format-PvmBecause' {
        # A new sentence with a cause after "because" needs a change of these counts on purpose.
        # Get-PvmWriteCause words a cause of Windows through Format-PvmBecause too.
        $text = [IO.File]::ReadAllText($script:module)
        [regex]::Matches($text, 'because \$').Count | Should -Be 4
        [regex]::Matches($text, 'because \$\((Format-PvmBecause -Cause|Get-PvmWriteCause -ErrorRecord) ').Count | Should -Be 4
    }

    It 'check the lock in the script before its administrator-rights block, and end the script there when another run holds it' {
        $statements = @((Get-SourceAst -Path $script:launcher).EndBlock.Statements)
        $texts = @($statements | ForEach-Object { $_.Extent.Text })
        $request = @(0..($texts.Count - 1) | Where-Object { $texts[$_] -ceq '$busy = Invoke-RightsRequest' })
        $identity = @(0..($texts.Count - 1) | Where-Object { $texts[$_] -clike '$identity = *' })
        $request.Count | Should -Be 1
        $identity.Count | Should -Be 1
        $request[0] | Should -BeLessThan $identity[0]
        $check = $statements[$request[0] + 1]
        $check | Should -BeOfType ([System.Management.Automation.Language.IfStatementAst])
        $check.Clauses[0].Item1.Extent.Text | Should -BeExactly '$null -ne $busy'
        $end = $check.Clauses[0].Item2.Statements[-1]
        $end | Should -BeOfType ([System.Management.Automation.Language.ExitStatementAst])
        $end.Pipeline.Extent.Text | Should -BeExactly '$busy.ExitCode'
    }

    It 'append a log text in one write that other launcher processes cannot break up: <Function>' -ForEach @(
        @{ File = 'src\PortableVM.psm1'; Function = 'Write-PvmLog'; Open = 'Open-PvmAppendStream'; Encoding = 'Get-PvmAnsiEncoding' }
        @{ File = 'src\Start-PortableVM.ps1'; Function = 'Add-LogLine'; Open = 'Open-AppendStream'; Encoding = 'Get-AnsiEncoding' }
    ) {
        $name = $Function
        $definition = (Get-SourceAst -Path (Join-Path $script:repoRoot $File)).Find({
                $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $name
            }, $true)
        $definition | Should -Not -BeNullOrEmpty
        $members = @($definition.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
        @(Get-SourceCommand -Ast $definition | Where-Object { $_.Name -eq $Open }).Count | Should -Be 1
        @(Get-SourceFileWrite -Ast $definition) | Should -BeNullOrEmpty
        $writes = @($members | Where-Object { $_.Member.Extent.Text -match '^(Write|WriteByte|BeginWrite|WriteAsync|Flush|(Append|Write)All(Text|Lines|Bytes))$' })
        @($writes | ForEach-Object { $_.Extent.Text }) | Should -BeExactly @('$stream.Write($bytes, 0, $bytes.Length)')
        # The one write runs once: no loop and no script block lies around it.
        for ($parent = $writes[0].Parent; -not [object]::ReferenceEquals($parent, $definition); $parent = $parent.Parent) {
            $parent | Should -Not -BeOfType ([System.Management.Automation.Language.LoopStatementAst])
            $parent | Should -Not -BeOfType ([System.Management.Automation.Language.ScriptBlockExpressionAst])
        }
        # The text of all lines of the message becomes the bytes of that write.
        @($members | Where-Object { $_.Member.Extent.Text -eq 'GetBytes' } | ForEach-Object { $_.Extent.Text }) | Should -BeExactly @("($Encoding).GetBytes(`$text + `"``r``n`")")
        Get-SourceCommand -Ast $definition | Where-Object { $_.Name -in 'Add-Content', 'Set-Content', 'Out-File', 'Tee-Object' } | Should -BeNullOrEmpty
    }

    It 'open the log only to append, sharing it with other writers and with the move aside: <Function>' -ForEach @(
        @{ File = 'src\PortableVM.psm1'; Function = 'Open-PvmAppendStream' }
        @{ File = 'src\Start-PortableVM.ps1'; Function = 'Open-AppendStream' }
    ) {
        $name = $Function
        $definition = (Get-SourceAst -Path (Join-Path $script:repoRoot $File)).Find({
                $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $name
            }, $true)
        $definition | Should -Not -BeNullOrEmpty
        # Other writers may append, and a run may move the log aside, while the file is open.
        @($definition.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$share' }, $true) |
                ForEach-Object { $_.Right.Extent.Text }) | Should -BeExactly @('[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete')
        $opens = @($definition.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $args[0].Member.Extent.Text -in 'new', 'Create' }, $true) |
                Where-Object { $_.Expression.TypeName.FullName -in 'IO.FileStream', 'System.IO.FileSystemAclExtensions' })
        # .NET Framework, .NET on Windows, and .NET elsewhere.
        @($opens | ForEach-Object { $_.Expression.TypeName.FullName }) | Should -BeExactly @('IO.FileStream', 'System.IO.FileSystemAclExtensions', 'IO.FileStream')
        foreach ($open in $opens) {
            $open.Arguments[1].Extent.Text | Should -BeExactly '[IO.FileMode]::Append'
            $open.Arguments[3].Extent.Text | Should -BeExactly '$share'
        }
        # On Windows the handle may only append, so Windows writes each write at the end in one piece.
        $opens[0].Arguments[2].Extent.Text | Should -BeExactly '[Security.AccessControl.FileSystemRights]::AppendData'
        $opens[1].Arguments[2].Extent.Text | Should -BeExactly '[Security.AccessControl.FileSystemRights]::AppendData'
    }

    It 'remove PVM_TEST in the script only at its top level, so that a test that calls one of its functions keeps it' {
        $removes = @(Get-SourceCommand -Ast (Get-SourceAst -Path $script:launcher) | Where-Object { $_.Name -eq 'Remove-Item' })
        $removes.Count | Should -BeGreaterThan 0
        $removes | Where-Object { $_.Function -ne '' } | ForEach-Object { "Remove-Item in $($_.Function)" } | Should -BeNullOrEmpty
    }

    It 'show dialogs in the script only from Show-Dialog and Show-Question' {
        $places = foreach ($node in (Get-SourceAst -Path $script:launcher).FindAll({
                    (($args[0] -is [System.Management.Automation.Language.TypeExpressionAst] -or $args[0] -is [System.Management.Automation.Language.TypeConstraintAst]) -and
                    $args[0].TypeName.FullName -match 'Windows\.Forms') -or
                    ($args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Add-Type')
                }, $true)) {
            for ($parent = $node.Parent; $null -ne $parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]; $parent = $parent.Parent) {}
            if ($parent) { $parent.Name } else { '' }
        }
        @($places).Count | Should -BeGreaterThan 0
        @($places | Where-Object { $_ -notin 'Show-Dialog', 'Show-Question' }) | Should -BeNullOrEmpty
    }
}

Describe 'Example settings' {
    BeforeAll {
        $script:settings = Import-PowerShellDataFile -LiteralPath $script:example
        Import-Module $script:module -Force
        $script:schema = @(Get-PvmSettingSchema | ForEach-Object { $_.Name })
        Remove-Module PortableVM
    }

    It 'has exactly the keys of settings schema 2' {
        (@($script:settings.Keys | Sort-Object) -join ', ') | Should -BeExactly (@($script:schema | Sort-Object) -join ', ')
    }

    It 'names only keys of the schema where the module reads a setting' {
        # The module reads every setting as $settings['Key'].
        $source = Get-Content -LiteralPath $script:module -Raw
        $read = @([regex]::Matches($source, "(?i)\`$settings\['(\w+)'\]") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $read.Count | Should -BeGreaterThan 10
        $read | Where-Object { $script:schema -notcontains $_ } | Should -BeNullOrEmpty
    }

    It 'holds a signature no disk can match, which the settings check refuses until real values are in' {
        # The launcher compares the setting with the disk's signature as 8 hex digits, or 'none'.
        $script:settings.StickMbrSignature | Should -Not -Match '^([0-9A-Fa-f]{8}|none)$'
    }

    It 'uses the synthetic 5ca1ab1e UUID' {
        $script:settings.VirtualBoxVmUuid | Should -Match '^5ca1ab1e-'
    }
}

Describe 'privacy-scan' -Tag 'WindowsOnly' {
    It 'runs in the sh of Git for Windows' {
        $script:sh | Should -Not -BeNullOrEmpty
    }

    It 'refuses home paths, e-mail and MAC addresses, and denylisted names in contents and file names' {
        $sample = Join-Path $TestDrive 'scan-refuses'
        $mac = @('02', '00', '5e', '10', '20', '30') -join ':'
        Initialize-SampleRepository -Path $sample -Files @{
            'path.txt'               = 'log at C:/Us' + 'ers/someone/notes.txt'
            'mail.txt'               = 'write to someone' + '@' + 'mail.invalid'
            'mac.txt'                = "adapter $mac"
            'name.txt'               = "made by $script:sampleName"
            "$script:sampleName.txt" = 'nothing private inside'
        }
        [IO.File]::WriteAllText((Join-Path $sample '.git\info\privacy-denylist'), "# test`n  $script:sampleName  `n", $script:utf8)
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        $result = Invoke-PrivacyScan -Path $sample
        $result.ExitCode | Should -Be 1
        $text = $result.Lines -join "`n"
        $text | Should -Match 'path\.txt:1: user home path'
        $text | Should -Match 'mail\.txt:1: e-mail address'
        $text | Should -Match 'mac\.txt:1: MAC address'
        $text | Should -Match 'name\.txt:1: denylisted value'
        $text | Should -Match 'file name \d+ of the scanned paths: denylisted value'
        $text.Contains($script:sampleName) | Should -BeFalse
    }

    It 'lets the synthetic UUID and GitHub no-reply e-mail addresses through' {
        $sample = Join-Path $TestDrive 'scan-passes'
        Initialize-SampleRepository -Path $sample -Files @{
            'ok.txt' = "id 5ca1ab1e-0000-4000-8000-000000000001`nby someone" + '@users.noreply.github.com'
        }
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        $result = Invoke-PrivacyScan -Path $sample
        $result.Lines | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }
}

Describe 'pre-push' -Tag 'WindowsOnly' {
    BeforeAll {
        # Run .githooks/pre-push in the repository at $Path for a push of a feature branch, with only
        # git and the folder $Tools on the path, and $Exit as the exit code of a pwsh stub there.
        # Returns the hook's exit code and lines, and the arguments the stub got, if it ran.
        function Invoke-PrePush {
            param([string]$Path, [string]$Tools, [string]$Exit = '0')
            $hook = (Join-Path $script:repoRoot '.githooks\pre-push') -replace '\\', '/'
            $git = Split-Path (Get-Command -Name git -CommandType Application | Select-Object -First 1).Source
            $calls = Join-Path $Path 'pwsh-calls.txt'
            $previousPath = $env:PATH
            $previousExit = $env:PVM_STUB_EXIT
            $previous = $ErrorActionPreference
            Push-Location -LiteralPath $Path
            try {
                $env:PATH = "$Tools;$git"
                $env:PVM_STUB_EXIT = $Exit
                $ErrorActionPreference = 'Continue'
                $lines = @('refs/heads/feature 0 refs/heads/feature 0' | & $script:sh $hook 2>&1 | ForEach-Object { "$_" })
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previous
                $env:PATH = $previousPath
                $env:PVM_STUB_EXIT = $previousExit
                Pop-Location
            }
            $called = if (Test-Path -LiteralPath $calls) { [IO.File]::ReadAllText($calls) } else { $null }
            [pscustomobject]@{ ExitCode = $code; Lines = $lines; Called = $called }
        }
    }

    BeforeEach {
        $script:sample = Join-Path $TestDrive "push-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        Initialize-SampleRepository -Path $script:sample -Files @{ 'a.txt' = 'text' }
        $null = New-Item -ItemType Directory -Path (Join-Path $script:sample 'LauncherData')
        [IO.File]::WriteAllText((Join-Path $script:sample 'LauncherData\settings.psd1'), '@{}', $script:utf8)
        $script:tools = Join-Path $script:sample 'tools-on-path'
        $null = New-Item -ItemType Directory -Path $script:tools
    }

    It 'runs the privacy check in pwsh where powershell.exe is missing, and lets the push through when it passes' {
        [IO.File]::WriteAllText((Join-Path $script:tools 'pwsh'), "#!/bin/sh`necho `"`$*`" > pwsh-calls.txt`nexit `"`$PVM_STUB_EXIT`"`n", $script:utf8)
        $result = Invoke-PrePush -Path $script:sample -Tools $script:tools
        $result.ExitCode | Should -Be 0
        $result.Called | Should -Match '-File \S*tools/Find-PrivateData\.ps1 -History'
    }

    It 'refuses the push when the privacy check in pwsh finds something' {
        [IO.File]::WriteAllText((Join-Path $script:tools 'pwsh'), "#!/bin/sh`necho `"`$*`" > pwsh-calls.txt`nexit `"`$PVM_STUB_EXIT`"`n", $script:utf8)
        $result = Invoke-PrePush -Path $script:sample -Tools $script:tools -Exit '1'
        $result.ExitCode | Should -Be 1
        $result.Called | Should -Not -BeNullOrEmpty
    }

    It 'refuses the push when neither powershell.exe nor pwsh can run the privacy check' {
        $result = Invoke-PrePush -Path $script:sample -Tools $script:tools
        $result.ExitCode | Should -Be 1
        ($result.Lines -join "`n") | Should -Match 'neither powershell\.exe nor pwsh'
    }
}

Describe 'Find-PrivateData' -Tag 'WindowsOnly' {
    It 'finds a denylisted name outside ASCII in contents, file names, messages and ref names, and never prints it' {
        $sample = Join-Path $TestDrive 'find-name'
        Initialize-SampleRepository -Path $sample -Files @{
            'notes.txt'              = "made by $script:sampleName"
            "$script:sampleName.txt" = 'nothing private inside'
        }
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        Invoke-SampleGit -Path $sample -Arguments @('commit', '-q', '-m', "note for $script:sampleName")
        Invoke-SampleGit -Path $sample -Arguments @('branch', "feat/$script:sampleName")
        [IO.File]::WriteAllText((Join-Path $sample '.git\info\privacy-denylist'), "$script:sampleName`n", $script:utf8)
        $result = Invoke-FindPrivateData -Path $sample
        $result.ExitCode | Should -Be 1
        $text = $result.Lines -join "`n"
        $text | Should -Match 'is in index: notes\.txt'
        $text | Should -Match 'is in index path: <value>\.txt'
        $text | Should -Match 'is in message of commit [0-9a-f]+'
        $text | Should -Match 'is in a ref name'
        $text.Contains($script:sampleName) | Should -BeFalse
    }

    It 'matches a number from the settings only as a whole number, and skips short ones' {
        $sample = Join-Path $TestDrive 'find-number'
        Initialize-SampleRepository -Path $sample -Files @{
            'whole.txt'  = 'size 1234567890 sectors'
            'longer.txt' = 'id 912345678901 and start 2048'
        }
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        # Written after the add, so the settings file stays untracked, as the real one does.
        $null = New-Item -ItemType Directory -Path (Join-Path $sample 'Launcher')
        [IO.File]::WriteAllText((Join-Path $sample 'Launcher\settings.psd1'), '@{ StickSectors = 1234567890; DataPartitionStart = 2048 }', $script:utf8)
        $result = Invoke-FindPrivateData -Path $sample
        $result.ExitCode | Should -Be 1
        $text = $result.Lines -join "`n"
        $text | Should -Match 'a value of StickSectors is in index: whole\.txt'
        $text | Should -Not -Match 'longer\.txt'
        $text | Should -Not -Match 'DataPartitionStart'
    }

    It 'reads LauncherData\settings.psd1 too, and finds the VM''s and the guest''s names but not the neutral defaults' {
        $sample = Join-Path $TestDrive 'find-names'
        Initialize-SampleRepository -Path $sample -Files @{
            'vm.txt'      = 'started Test Machine today'
            'guest.txt'   = 'the guest is Sample OS'
            'neutral.txt' = 'the VM and the guest'
        }
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        $null = New-Item -ItemType Directory -Path (Join-Path $sample 'LauncherData')
        [IO.File]::WriteAllText((Join-Path $sample 'LauncherData\settings.psd1'), "@{ SchemaVersion = 2; VmDisplayName = 'Test Machine'; GuestName = 'Sample OS' }", $script:utf8)
        $result = Invoke-FindPrivateData -Path $sample
        $result.ExitCode | Should -Be 1
        $text = $result.Lines -join "`n"
        $text | Should -Match 'a value of VmDisplayName is in index: vm\.txt'
        $text | Should -Match 'a value of GuestName is in index: guest\.txt'
        $text | Should -Not -Match 'neutral\.txt'

        [IO.File]::WriteAllText((Join-Path $sample 'LauncherData\settings.psd1'), "@{ SchemaVersion = 2; VmDisplayName = 'the VM'; GuestName = 'the guest' }", $script:utf8)
        (Invoke-FindPrivateData -Path $sample).ExitCode | Should -Be 0
    }

    It 'reads a settings file saved as UTF-8 without a byte order mark as UTF-8, so a name outside ASCII is found' {
        $sample = Join-Path $TestDrive 'find-utf8'
        Initialize-SampleRepository -Path $sample -Files @{ 'guest.txt' = "the guest is $script:sampleName OS" }
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        $null = New-Item -ItemType Directory -Path (Join-Path $sample 'LauncherData')
        [IO.File]::WriteAllText((Join-Path $sample 'LauncherData\settings.psd1'), "@{ SchemaVersion = 2; GuestName = '$script:sampleName OS' }", $script:utf8)
        $result = Invoke-FindPrivateData -Path $sample
        $result.ExitCode | Should -Be 1
        ($result.Lines -join "`n") | Should -Match 'a value of GuestName is in index: guest\.txt'
    }

    It 'stops with exit code 2 when -SettingsPath names a file that is not there' {
        $sample = Join-Path $TestDrive 'find-missing'
        Initialize-SampleRepository -Path $sample -Files @{ 'a.txt' = 'text' }
        $tool = Join-Path $script:repoRoot 'tools\Find-PrivateData.ps1'
        $lines = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -RepositoryPath $sample -SettingsPath (Join-Path $sample 'none.psd1') 2>&1 | ForEach-Object { "$_" })
        $LASTEXITCODE | Should -Be 2
        ($lines -join "`n") | Should -Match '-SettingsPath names no file'
    }

    It 'reads a relative -SettingsPath from PowerShell''s location, not from the process''s folder' {
        $sample = Join-Path $TestDrive 'find-relative'
        Initialize-SampleRepository -Path $sample -Files @{ 'guest.txt' = 'the guest is Sample OS' }
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        # Written after the add, so the settings file stays untracked.
        [IO.File]::WriteAllText((Join-Path $sample 's.psd1'), "@{ GuestName = 'Sample OS' }", $script:utf8)
        $tool = Join-Path $script:repoRoot 'tools\Find-PrivateData.ps1'
        $command = "Set-Location -LiteralPath '$sample'; & '$tool' -RepositoryPath . -SettingsPath .\s.psd1; exit `$LASTEXITCODE"
        $lines = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { "$_" })
        $LASTEXITCODE | Should -Be 1
        ($lines -join "`n") | Should -Match 'a value of GuestName is in index: guest\.txt'
    }

    It 'runs on its own clone when no -RepositoryPath is given, as pre-push calls it' {
        $tool = Join-Path $script:repoRoot 'tools\Find-PrivateData.ps1'
        $null = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool 2>&1
        # 0 or 1 depend on this clone's settings file and denylist; 2 means the check could not run.
        $LASTEXITCODE | Should -BeIn @(0, 1)
    }

    It 'has nothing to look for without a settings file or a denylist' {
        $sample = Join-Path $TestDrive 'find-nothing'
        Initialize-SampleRepository -Path $sample -Files @{ 'a.txt' = 'text' }
        $result = Invoke-FindPrivateData -Path $sample
        $result.ExitCode | Should -Be 0
        ($result.Lines -join "`n") | Should -Match 'nothing to look for'
    }
}
