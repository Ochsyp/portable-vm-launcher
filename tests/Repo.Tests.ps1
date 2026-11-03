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
    $script:umlautName = 'J' + [char]0x00FC + 'rgen'

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
            'tools/Get-StickInventory.ps1', 'examples/settings.example.psd1') {
            $script:tracked | Should -Contain $path
        }
    }

    It 'include no real settings, logs, backups or VM files' {
        $private = '(^|/)settings[^/]*\.psd1|\.log$|\.log\.[0-9]|\.bak$|\.orig$|\.launcher-backup$|' +
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
    It 'let the module define functions only, so importing it runs nothing' {
        $statements = (Get-SourceAst -Path $script:module).EndBlock.Statements
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
        'Invoke-PvmGetRegistryValue', 'Invoke-PvmNative', 'Invoke-PvmStartProcess', 'Invoke-PvmSetEnvironment', 'Invoke-PvmSleep'
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

    It 'never change disks, partitions or volumes, nor delete VirtualBox media' {
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
        'Load', 'new', 'ReadAllText', 'SelectNodes', 'ToLowerInvariant', 'Trim', 'TrimEnd'
        $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
            ForEach-Object { $_.Member.Extent.Text } | Where-Object { $allowed -cnotcontains $_ } | Should -BeNullOrEmpty
    }

    It 'keep the deploy tool from deleting anything' {
        $ast = Get-SourceAst -Path (Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1')
        Get-SourceCommand -Ast $ast | Where-Object { $_.Name -in 'Remove-Item', 'Clear-Content', 'Clear-Item' } | Should -BeNullOrEmpty
        $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
            Where-Object { $_.Member.Extent.Text -eq 'Delete' } | Should -BeNullOrEmpty
    }
}

Describe 'Example settings' {
    BeforeAll {
        $script:settings = Import-PowerShellDataFile -LiteralPath $script:example
    }

    It 'has exactly the keys the launcher reads' {
        # The module reads every setting as $settings['Key'].
        $source = Get-Content -LiteralPath $script:module -Raw
        $read = @([regex]::Matches($source, "(?i)\`$settings\['(\w+)'\]") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        (@($script:settings.Keys | Sort-Object) -join ', ') | Should -BeExactly ($read -join ', ')
    }

    It 'holds a signature no disk can match, so the launcher stops at its identity check' {
        # The launcher compares the setting with the disk's signature as 8 hex digits, or 'none'.
        $script:settings.StickMbrSignature | Should -Not -Match '^([0-9A-Fa-f]{8}|none)$'
    }

    It 'uses the synthetic 5ca1ab1e UUID' {
        $script:settings.VirtualBoxVmUuid | Should -Match '^5ca1ab1e-'
    }
}

Describe 'privacy-scan' {
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
            'name.txt'               = "made by $script:umlautName"
            "$script:umlautName.txt" = 'nothing private inside'
        }
        [IO.File]::WriteAllText((Join-Path $sample '.git\info\privacy-denylist'), "# test`n  $script:umlautName  `n", $script:utf8)
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        $result = Invoke-PrivacyScan -Path $sample
        $result.ExitCode | Should -Be 1
        $text = $result.Lines -join "`n"
        $text | Should -Match 'path\.txt:1: user home path'
        $text | Should -Match 'mail\.txt:1: e-mail address'
        $text | Should -Match 'mac\.txt:1: MAC address'
        $text | Should -Match 'name\.txt:1: denylisted value'
        $text | Should -Match 'file name \d+ of the scanned paths: denylisted value'
        $text.Contains($script:umlautName) | Should -BeFalse
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

Describe 'Find-PrivateData' {
    It 'finds a denylisted name outside ASCII in contents, file names, messages and ref names, and never prints it' {
        $sample = Join-Path $TestDrive 'find-name'
        Initialize-SampleRepository -Path $sample -Files @{
            'notes.txt'              = "made by $script:umlautName"
            "$script:umlautName.txt" = 'nothing private inside'
        }
        Invoke-SampleGit -Path $sample -Arguments @('add', '-A')
        Invoke-SampleGit -Path $sample -Arguments @('commit', '-q', '-m', "note for $script:umlautName")
        Invoke-SampleGit -Path $sample -Arguments @('branch', "feat/$script:umlautName")
        [IO.File]::WriteAllText((Join-Path $sample '.git\info\privacy-denylist'), "$script:umlautName`n", $script:utf8)
        $result = Invoke-FindPrivateData -Path $sample
        $result.ExitCode | Should -Be 1
        $text = $result.Lines -join "`n"
        $text | Should -Match 'is in index: notes\.txt'
        $text | Should -Match 'is in index path: <value>\.txt'
        $text | Should -Match 'is in message of commit [0-9a-f]+'
        $text | Should -Match 'is in a ref name'
        $text.Contains($script:umlautName) | Should -BeFalse
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
