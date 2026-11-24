# Tests of tools\Deploy-PortableVM.ps1, tools\Get-StickInventory.ps1 and
# tools\Compare-StickDryRun.ps1 on a synthetic clone and stick in TestDrive. Each tool is dot-sourced for its functions, which skips its main block, and
# the functions that read the PC (processes, git, disks, registry) are mocked. The deploy tool
# imports the clone's src\PortableVM.psm1, so the fake clone holds a copy of the real module.

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:utf8 = New-Object System.Text.UTF8Encoding $false
    # A made-up name with letters outside ASCII that Windows-1252 holds too.
    $script:sampleName = 'K' + [char]0x00E9 + 'l' + [char]0x00F8 + 'n' + [char]0x00EF
    . (Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1')
    . (Join-Path $script:repoRoot 'tools\Get-StickInventory.ps1')
    . (Join-Path $script:repoRoot 'tools\Compare-StickDryRun.ps1')

    # Return the system's ANSI code page, read from the registry: the encoding of old settings
    # files, which Windows PowerShell 5.1 calls Default.
    function Get-TestAnsiEncoding {
        [Text.Encoding]::GetEncoding([int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').ACP)
    }

    # Write $Text to the file $Path as UTF-8 without a BOM, creating its folder.
    function Write-TestFile {
        param([string]$Path, [string]$Text)
        $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
        [IO.File]::WriteAllText($Path, $Text, $script:utf8)
    }

    # Return the schema 1 settings.psd1 text of the synthetic stick, with a comment and CRLF, as
    # the launcher before LauncherData read it.
    function Get-TestSettingsText {
        @("# The stick's settings", "@{", "    Hypervisor = 'Auto'", "    VMwareView = 'Window'", '    HideDataPartition = $false',
            "    StickMbrSignature = '5CA1AB1E'", '    StickSectors = 4000000', '    VmSectors = 3900000', '    DataPartitionStart = 2500000',
            "    VirtualBoxVmUuid = '5ca1ab1e-0000-4000-8000-000000000001'", "    VirtualBoxHome = 'VirtualBox'",
            "    VirtualBoxVbox = 'VirtualBox\Test VM\Test VM.vbox'", "    VirtualBoxDisk = 'VirtualBox\Test VM\stick.vmdk'",
            "    VMwareVmx = 'VMware\Test VM.vmx'", "    VMwareDisk = 'VMware\stick.vmdk'", '}', '') -join "`r`n"
    }

    # Return the schema 2 text that a migration makes of Get-TestSettingsText, with the lines in
    # $Add after SchemaVersion.
    function Get-TestSchema2Text {
        param([string[]]$Add = @())
        $lines = @('    SchemaVersion = 2') + @($Add | ForEach-Object { "    $_" })
        (Get-TestSettingsText).Replace("@{`r`n", "@{`r`n" + (($lines | ForEach-Object { "$_`r`n" }) -join ''))
    }

    # Return a descriptor text whose one extent names the raw disk $Device.
    function Get-TestDescriptorText {
        param([string]$Device = '\\.\PhysicalDrive3')
        @('# Disk DescriptorFile', 'createType="fullDevice"', "RW 3900000 FLAT `"$Device`" 0", 'ddb.adapterType = "ide"', '') -join "`r`n"
    }

    # Return every folder and file below $Root, a file with its SHA-256 hash, as sorted lines.
    function Get-TestTree {
        param([string]$Root)
        @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
                $relative = $_.FullName.Substring($Root.Length + 1)
                if ($_.PSIsContainer) { "$relative\" } else { "$relative $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
            })
    }

    # Create the fake clone TestDrive\clone: the real module, a stand-in launcher script and
    # Start VM.cmd.
    function Initialize-TestClone {
        $script:clone = Join-Path $TestDrive 'clone'
        Remove-Item -LiteralPath $script:clone -Recurse -Force -ErrorAction SilentlyContinue
        Write-TestFile -Path (Join-Path $script:clone 'src\Start-PortableVM.ps1') -Text "# new script`r`n"
        Copy-Item -LiteralPath (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Destination (Join-Path $script:clone 'src\PortableVM.psm1')
        Write-TestFile -Path (Join-Path $script:clone 'Start VM.cmd') -Text "@echo off`r`nstart `"`" -File `"%~dp0Launcher\Start-PortableVM.ps1`"`r`n"
    }

    # Return a .vbox text for the VM, with $Machine added to its Machine element and $Body inside it.
    function Get-TestVboxText {
        param([string]$Machine = '', [string]$Body = '')
        @('<?xml version="1.0"?>', '<VirtualBox xmlns="http://www.virtualbox.org/" version="1.19-windows">',
            "  <Machine uuid=`"{5ca1ab1e-0000-4000-8000-000000000001}`" name=`"Test VM`"$Machine>", $Body, '  </Machine>', '</VirtualBox>', '') -join "`n"
    }

    # Return the .vbox body that registers the descriptor (unless $Registered is false) and
    # attaches it on a controller with useHostIOCache $Cache and the AttachedDevice attributes
    # $Device.
    function Get-TestVboxBody {
        param([bool]$Registered = $true, [string]$Cache = 'true', [string]$Device = '')
        $registry = if ($Registered) { '<MediaRegistry><HardDisks><HardDisk uuid="{5ca1ab1e-0000-4000-8000-000000000002}" location="stick.vmdk" format="VMDK"/></HardDisks></MediaRegistry>' } else { '' }
        "    $registry<Hardware><StorageControllers><StorageController name=`"SATA`" type=`"AHCI`" useHostIOCache=`"$Cache`">" +
        "<AttachedDevice type=`"HardDisk`" port=`"0`" device=`"0`"$Device><Image uuid=`"{5ca1ab1e-0000-4000-8000-000000000002}`"/></AttachedDevice>" +
        '</StorageController></StorageControllers></Hardware>'
    }

    # Create the synthetic stick TestDrive\$Name for the inventory: the settings, a .vmx with the
    # lines $Vmx, both descriptors, the .vbox text $Vbox and the VirtualBox.xml text $Registry.
    # Returns its root.
    function Initialize-InventoryStick {
        param(
            [string]$Name,
            [string[]]$Vmx,
            [string]$Vbox,
            [string]$Registry
        )
        $root = Join-Path $TestDrive $Name
        Write-TestFile -Path (Join-Path $root 'Launcher\settings.psd1') -Text (Get-TestSettingsText)
        Write-TestFile -Path (Join-Path $root 'VMware\Test VM.vmx') -Text (($Vmx + '') -join "`r`n")
        $descriptor = @('# Disk DescriptorFile', 'createType="fullDevice"', 'RW 3900000 FLAT "\\.\PhysicalDrive3" 0', '') -join "`r`n"
        Write-TestFile -Path (Join-Path $root 'VMware\stick.vmdk') -Text $descriptor
        Write-TestFile -Path (Join-Path $root 'VirtualBox\Test VM\stick.vmdk') -Text $descriptor
        Write-TestFile -Path (Join-Path $root 'VirtualBox\Test VM\Test VM.vbox') -Text $Vbox
        Write-TestFile -Path (Join-Path $root 'VirtualBox\VirtualBox.xml') -Text $Registry
        $root
    }

    # Return the VirtualBox.xml text that lists the VM, with $Media added to its Global element.
    function Get-TestRegistryText {
        param([string]$Media = '')
        @('<?xml version="1.0"?>', '<VirtualBox xmlns="http://www.virtualbox.org/" version="1.12-windows">',
            "  <Global>$Media<MachineRegistry><MachineEntry uuid=`"{5ca1ab1e-0000-4000-8000-000000000001}`" src=`"Q:/VirtualBox/Test VM/Test VM.vbox`"/></MachineRegistry></Global>",
            '</VirtualBox>', '') -join "`n"
    }

    # Return the answers of the inventory of the stick at $Root as a hashtable of check name and
    # $true, $false or $null.
    function Get-TestAnswer {
        param([string]$Root, [string]$SettingsPath = (Join-Path $Root 'Launcher\settings.psd1'))
        $answers = @{}
        foreach ($check in Get-StickInventory -Root $Root -SettingsPath $SettingsPath) { $answers[$check.Name] = $check.Answer }
        $answers
    }
}

AfterAll {
    # The deploy tool imported the fake clone's copy of the module.
    Remove-Module PortableVM -ErrorAction SilentlyContinue
}

Describe 'Deploy-PortableVM' -Tag 'WindowsOnly' {
    BeforeEach {
        Initialize-TestClone
        $script:target = Join-Path $TestDrive 'target'
        Remove-Item -LiteralPath $script:target -Recurse -Force -ErrorAction SilentlyContinue
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\logs\launcher.log') -Text "old log line`r`n"
        Write-TestFile -Path (Join-Path $script:target 'Launcher\Old-Launcher.ps1') -Text "# old script`r`n"
        Write-TestFile -Path (Join-Path $script:target 'Start Old.cmd') -Text "@echo off`r`nstart `"`" -File `"%~dp0LAUNCHER\Old-Launcher.ps1`"`r`n"
        Write-TestFile -Path (Join-Path $script:target 'Other.cmd') -Text "@echo off`r`nrem reads %~dp0Launcher\launcher.log`r`n"
        Write-TestFile -Path (Join-Path $script:target 'VMware\Test VM.vmx') -Text "displayName = `"Test VM`"`r`n"
        Mock Get-DeployVmProcess { @() }
        Mock Get-DeployVersion { 'v0.0.0-test' }
    }

    It 'swaps in the new launcher, leaves LauncherData as it is, and moves the old .cmd away' {
        $data = Get-TestTree -Root (Join-Path $script:target 'LauncherData')
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        $result.Version | Should -BeExactly 'v0.0.0-test'
        $result.Mode | Should -BeExactly 'Update'
        $result.Applied | Should -BeTrue
        $result.MovedCmdCount | Should -Be 1
        $launcher = Join-Path $script:target 'Launcher'
        @(Get-ChildItem -LiteralPath $launcher -Name | Sort-Object) | Should -BeExactly @('PortableVM.psm1', 'SHA256SUMS', 'Start-PortableVM.ps1', 'VERSION')
        Get-TestTree -Root (Join-Path $script:target 'LauncherData') | Should -BeExactly $data
        [IO.File]::ReadAllText((Join-Path $launcher 'VERSION')) | Should -BeExactly "v0.0.0-test`n"
        $sums = @([IO.File]::ReadAllText((Join-Path $launcher 'SHA256SUMS')).TrimEnd("`n") -split "`n")
        $sums | Should -BeExactly @(
            "$((Get-FileHash -LiteralPath (Join-Path $script:clone 'src\Start-PortableVM.ps1') -Algorithm SHA256).Hash.ToLowerInvariant())  Start-PortableVM.ps1"
            "$((Get-FileHash -LiteralPath (Join-Path $script:clone 'src\PortableVM.psm1') -Algorithm SHA256).Hash.ToLowerInvariant())  PortableVM.psm1"
        )
        Join-Path $script:target 'Launcher.previous\Old-Launcher.ps1' | Should -Exist
        Join-Path $script:target 'Launcher.previous\Start Old.cmd' | Should -Exist
        Join-Path $script:target 'Start Old.cmd' | Should -Not -Exist
        Join-Path $script:target 'Other.cmd' | Should -Exist
        Join-Path $script:target 'Start VM.cmd.new' | Should -Not -Exist
        [IO.File]::ReadAllText((Join-Path $script:target 'Start VM.cmd')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $script:clone 'Start VM.cmd')))
        [IO.File]::ReadAllText((Join-Path $script:target 'VMware\Test VM.vmx')) | Should -BeExactly "displayName = `"Test VM`"`r`n"
        Format-DeployReport -Result $result | Should -BeExactly @('deployed v0.0.0-test (Update).', 'old launcher .cmd files moved into Launcher.previous: 1.', 'Launcher.previous holds version unknown.')
    }

    It 'stops before it changes anything at <Left>, which an earlier deploy left' -ForEach @(
        @{ Left = 'Start VM.cmd.new.pvm-tmp' }
        @{ Left = 'Start VM.cmd.new.pvm-old' }
    ) {
        Write-TestFile -Path (Join-Path $script:target $Left) -Text 'left'
        $before = Get-TestTree -Root $script:target
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } | Should -Throw -ExpectedMessage ("'$Left' is left from an earlier deploy whose write of " +
            "'Start VM.cmd.new' did not finish, and nothing the launcher uses was changed. Remove it, and Launcher.new and 'Start VM.cmd.new' if they are there, then run the same command again.")
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'installs the launcher on a stick without a Launcher folder' {
        Remove-Item -LiteralPath (Join-Path $script:target 'Launcher') -Recurse
        Remove-Item -LiteralPath (Join-Path $script:target 'Start Old.cmd')
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        $result.Mode | Should -BeExactly 'Install'
        @(Get-ChildItem -LiteralPath (Join-Path $script:target 'Launcher') -Name | Sort-Object) | Should -BeExactly @('PortableVM.psm1', 'SHA256SUMS', 'Start-PortableVM.ps1', 'VERSION')
        Join-Path $script:target 'Start VM.cmd' | Should -Exist
        Join-Path $script:target 'Launcher.previous' | Should -Not -Exist
        Format-DeployReport -Result $result | Should -BeExactly @('deployed v0.0.0-test (Install).')
    }

    It 'replaces a Start VM.cmd from an earlier deploy, keeping it in Launcher.previous' {
        Move-Item -LiteralPath (Join-Path $script:target 'Start Old.cmd') -Destination (Join-Path $script:target 'Start VM.cmd')
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        $result.MovedCmdCount | Should -Be 1
        [IO.File]::ReadAllText((Join-Path $script:target 'Launcher.previous\Start VM.cmd')) | Should -BeLike '*Old-Launcher.ps1*'
        [IO.File]::ReadAllText((Join-Path $script:target 'Start VM.cmd')) | Should -BeLike '*Start-PortableVM.ps1*'
    }

    It 'refuses <Case>, changing nothing' -ForEach @(
        @{ Case = 'while a VM runs'; Setup = { Mock Get-DeployVmProcess { 'vmware-vmx.exe' } }; Extra = @{}; Message = 'A VM runs on this PC (vmware-vmx.exe). Shut the guest down first.' }
        @{ Case = 'without the stick''s settings'; Setup = { Remove-Item -LiteralPath (Join-Path $script:target 'LauncherData\settings.psd1') }; Extra = @{}; Message = 'The new launcher reads LauncherData\settings.psd1, which must pass its checks first, so nothing was changed. LauncherData\settings.psd1 is missing.*' }
        @{ Case = 'with settings that fail the checks'; Setup = { Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text).Replace("'Auto'", "'VBox'") }; Extra = @{}; Message = "*LauncherData\settings.psd1 has 1 problem:`n- Hypervisor: must be*" }
        @{ Case = 'on an install without the stick''s settings'; Setup = { Remove-Item -LiteralPath (Join-Path $script:target 'LauncherData'), (Join-Path $script:target 'Launcher') -Recurse }; Extra = @{}; Message = 'The new launcher reads LauncherData\settings.psd1*is missing*' }
        @{ Case = 'on an install with a launcher .cmd at the target'; Setup = { Remove-Item -LiteralPath (Join-Path $script:target 'Launcher') -Recurse }; Extra = @{}; Message = 'A launcher .cmd is at the target, but there is no Launcher folder to keep it in.*' }
        @{ Case = 'with Launcher.new left over'; Setup = { $null = New-Item -ItemType Directory -Path (Join-Path $script:target 'Launcher.new') }; Extra = @{}; Message = 'Launcher.new is left from an earlier deploy*' }
        @{ Case = 'with Start VM.cmd.new left over'; Setup = { Write-TestFile -Path (Join-Path $script:target 'Start VM.cmd.new') -Text 'rem x' }; Extra = @{}; Message = "'Start VM.cmd.new' is left from an earlier deploy*" }
        @{ Case = 'with LauncherData.new left over'; Setup = { $null = New-Item -ItemType Directory -Path (Join-Path $script:target 'LauncherData.new') }; Extra = @{}; Message = 'LauncherData.new is left from a migration whose staging did not finish*' }
        @{ Case = 'with a Launcher.previous that is not its own copy'; Setup = { $null = New-Item -ItemType Directory -Path (Join-Path $script:target 'Launcher.previous') }; Extra = @{}; Message = 'Launcher.previous is not a launcher copy that a deploy wrote and nothing changed since*so nothing was changed.*' }
        @{ Case = 'with a Start VM.cmd that does not start the launcher'; Setup = { Write-TestFile -Path (Join-Path $script:target 'Start VM.cmd') -Text 'rem mine' }; Extra = @{}; Message = "'Start VM.cmd' at the target does not start the launcher.*" }
        @{ Case = 'when Launcher holds a file named like the old .cmd'; Setup = { Write-TestFile -Path (Join-Path $script:target 'Launcher\Start Old.cmd') -Text 'rem x' }; Extra = @{}; Message = 'Launcher holds a file with the name of an old launcher .cmd*' }
        @{ Case = 'with schema 2 settings in Launcher'; Setup = { Write-TestFile -Path (Join-Path $script:target 'Launcher\settings.psd1') -Text (Get-TestSchema2Text) }; Extra = @{}; Message = 'Launcher\settings.psd1 holds schema 2 settings, but the launcher reads them from LauncherData\settings.psd1.*' }
        @{ Case = 'with -MigrateSettings on a migrated stick'; Setup = {}; Extra = @{ MigrateSettings = $true }; Message = 'The settings are in LauncherData already, so there is nothing to migrate.*' }
        @{ Case = 'with a name but no -MigrateSettings'; Setup = {}; Extra = @{ VmDisplayName = 'Test VM' }; Message = '-VmDisplayName and -GuestName go only with -MigrateSettings, which writes them into the new LauncherData\settings.psd1.*' }
    ) {
        & $Setup
        $before = Get-TestTree -Root $script:target
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target @Extra } | Should -Throw -ExpectedMessage $Message
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'refuses without a Launcher folder while Launcher.previous holds the one an interrupted swap replaced' {
        Rename-Item -LiteralPath (Join-Path $script:target 'Launcher') -NewName 'Launcher.previous'
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'The target has no Launcher folder, but Launcher.previous holds*Rename Launcher.previous back to Launcher*'
    }

    It 'leaves the launcher as it was when Launcher cannot be renamed, and says so' {
        Mock Rename-DeployItem { throw 'in use' } -ParameterFilter { $NewName -eq 'Launcher.previous' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage "Launcher could not be renamed, so the stick's launcher is unchanged.*Launcher.new and 'Start VM.cmd.new'*"
        Join-Path $script:target 'Launcher\Old-Launcher.ps1' | Should -Exist
        Join-Path $script:target 'Start Old.cmd' | Should -Exist
    }

    It 'puts Launcher back when Launcher.new cannot take its place' {
        # Pester 6 calls no real command when no filter matches, so the default mock renames.
        Mock Rename-DeployItem { Rename-Item -LiteralPath $Path -NewName $NewName }
        Mock Rename-DeployItem { throw 'held' } -ParameterFilter { $NewName -eq 'Launcher' -and $Path -like '*Launcher.new' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'Launcher.new could not take the place of Launcher, so Launcher is back as it was.*'
        Join-Path $script:target 'Launcher\Old-Launcher.ps1' | Should -Exist
        Join-Path $script:target 'Launcher.previous' | Should -Not -Exist
        Join-Path $script:target 'Start Old.cmd' | Should -Exist
    }

    It 'says how to recover when Launcher cannot be put back either' {
        Mock Rename-DeployItem { Rename-Item -LiteralPath $Path -NewName $NewName }
        Mock Rename-DeployItem { throw 'held' } -ParameterFilter { $NewName -eq 'Launcher' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'Launcher is missing: Launcher.previous holds the launcher that was in use.*Rename Launcher.previous back to Launcher*'
        Join-Path $script:target 'Launcher.previous\Old-Launcher.ps1' | Should -Exist
    }

    It 'names the cause but no path when a program holds a file in Launcher, and shows the message from Windows with -Verbose' {
        $script:failure = $null
        $held = [IO.File]::Open((Join-Path $script:target 'Launcher\Old-Launcher.ps1'), 'Open', 'Read', 'Read')
        try { $verbose = @(& { try { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -Verbose } catch { $script:failure = $_ } } 4>&1) }
        finally { $held.Dispose() }
        $script:failure.Exception.Message | Should -BeExactly ("Launcher could not be renamed, so the stick's launcher is unchanged. A window, console or program probably has " +
            "the Launcher folder or a file in it open: close it, remove Launcher.new and 'Start VM.cmd.new', then deploy again. Cause: access is denied (-Verbose shows the details).")
        # The message from Windows names the Launcher folder, in quotes of its language; the copies
        # that staging made name Launcher.new.
        $named = [regex]::Escape((Join-Path $script:target 'Launcher')) + '[^.\\]'
        @($verbose | Where-Object { $_ -is [Management.Automation.VerboseRecord] -and $_.Message -match $named }) | Should -Not -BeNullOrEmpty
        Join-Path $script:target 'Launcher\Old-Launcher.ps1' | Should -Exist
        Join-Path $script:target 'Start Old.cmd' | Should -Exist
    }

    It 'names the cause of settings it cannot open, and shows the message from Windows with -Verbose' {
        $script:failure = $null
        $settings = Join-Path $script:target 'LauncherData\settings.psd1'
        $held = [IO.File]::Open($settings, 'Open', 'Read', 'None')
        try { $verbose = @(& { try { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -Verbose } catch { $script:failure = $_ } } 4>&1) }
        finally { $held.Dispose() }
        $script:failure.Exception.Message | Should -BeExactly ('The new launcher reads LauncherData\settings.psd1, which must pass its checks first, so nothing was changed. ' +
            'LauncherData\settings.psd1 cannot be read: it is open in another program (-Verbose shows the details).')
        @($verbose | Where-Object { $_ -is [Management.Automation.VerboseRecord] -and $_.Message.IndexOf($settings, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) |
            Should -Not -BeNullOrEmpty
    }

    It 'names the cause but no path when the clone''s module <Case>, and shows the message with -Verbose' -ForEach @(
        @{ Case = 'does not parse'; Cause = '. Cause: it does not parse'; Held = $false; Ansi = $false; Failure = $null
            Bytes = { [Text.Encoding]::ASCII.GetBytes("function {`r`n") } }
        # Windows PowerShell 5.1 reads a script without a byte order mark as ANSI: there a dash in
        # UTF-8 ends a string early, and the curly quotes of Windows-1252 make one. PowerShell 7
        # reads it as UTF-8, so the same bytes give the opposite results there.
        @{ Case = 'does not parse as ANSI, although it parses as UTF-8'; Cause = '. Cause: it does not parse'; Held = $false; Ansi = $true; Failure = $null; Engine = 'Desktop'
            Bytes = { (New-Object System.Text.UTF8Encoding $false).GetBytes("`$dash = `"a $([char]0x2014) b`"`r`n") } }
        @{ Case = 'stops while it loads, although it does not parse as UTF-8'; Cause = ''; Held = $false; Ansi = $true; Failure = $null; Engine = 'Desktop'
            Bytes = { [byte[]]([Text.Encoding]::ASCII.GetBytes('$m = ') + 0x93 + [Text.Encoding]::ASCII.GetBytes('a (b') + 0x94 + [Text.Encoding]::ASCII.GetBytes("`r`nthrow 'stopped while it loads'`r`n")) } }
        @{ Case = 'stops while it loads, although it does not parse as ANSI'; Cause = ''; Held = $false; Ansi = $false; Failure = $null; Engine = 'Core'
            Bytes = { (New-Object System.Text.UTF8Encoding $false).GetBytes("`$dash = `"a $([char]0x2014) b`"`r`nthrow 'stopped while it loads'`r`n") } }
        @{ Case = 'does not parse as UTF-8, although it parses as ANSI'; Cause = '. Cause: it does not parse'; Held = $false; Ansi = $false; Failure = $null; Engine = 'Core'
            Bytes = { [byte[]]([Text.Encoding]::ASCII.GetBytes('$m = ') + 0x93 + [Text.Encoding]::ASCII.GetBytes('a (b') + 0x94 + [Text.Encoding]::ASCII.GetBytes("`r`nthrow 'stopped while it loads'`r`n")) } }
        # With a byte order mark, PowerShell reads UTF-8, where a curly quote ends a string.
        @{ Case = 'does not parse as UTF-8 with a byte order mark'; Cause = '. Cause: it does not parse'; Held = $false; Ansi = $false; Failure = $null
            Bytes = { (New-Object System.Text.UTF8Encoding $true).GetPreamble() + (New-Object System.Text.UTF8Encoding $false).GetBytes("`$x = `"a $([char]0x201D) b`"`r`n") } }
        @{ Case = 'is open in another program'; Cause = '. Cause: it is open in another program'; Held = $true; Ansi = $false; Failure = $null; Bytes = $null }
        # Errors in the shape PowerShell gives, so that no test changes an ACL of the clone or the
        # execution policy, or sets off antivirus software.
        @{ Case = 'may not be read'; Cause = '. Cause: access is denied'; Held = $false; Ansi = $false; Bytes = $null
            Failure = { [Management.Automation.CommandNotFoundException]::new('X:\clone\src\PortableVM.psm1 may not be read.', [UnauthorizedAccessException]::new('Access is denied.')) } }
        @{ Case = 'is refused by the execution policy'; Cause = '. Cause: PowerShell''s execution policy blocks it'; Held = $false; Ansi = $false; Bytes = $null
            Failure = { [Management.Automation.PSSecurityException]::new('X:\clone\src\PortableVM.psm1 is not signed.', [UnauthorizedAccessException]::new('Access is denied.')) } }
        @{ Case = 'is refused by the execution policy and does not parse either'; Cause = '. Cause: PowerShell''s execution policy blocks it'; Held = $false; Ansi = $false
            Bytes = { [Text.Encoding]::ASCII.GetBytes("function {`r`n") }
            Failure = { [Management.Automation.PSSecurityException]::new('X:\clone\src\PortableVM.psm1 is not signed.', [UnauthorizedAccessException]::new('Access is denied.')) } }
        # A file that does not parse counts only when PowerShell reports a parse error.
        @{ Case = 'fails with another error and does not parse either'; Cause = ''; Held = $false; Ansi = $false
            Bytes = { [Text.Encoding]::ASCII.GetBytes("function {`r`n") }
            Failure = { [Management.Automation.CommandNotFoundException]::new('X:\clone\src\PortableVM.psm1 was not found.', [IO.FileNotFoundException]::new('Not found.')) } }
        @{ Case = 'fails with a parse error although it parses'; Cause = ''; Held = $false; Ansi = $false; Bytes = $null
            Failure = {
                $extent = [Management.Automation.Language.Parser]::ParseInput('x', [ref]$null, [ref]$null).Extent
                [Management.Automation.ParseException]::new([Management.Automation.Language.ParseError[]]@([Management.Automation.Language.ParseError]::new($extent, 'ContentBlocked', 'X:\clone\src\PortableVM.psm1 is blocked.')))
            } }
    ) {
        if ($_.Engine -and $_.Engine -ne $PSVersionTable.PSEdition) {
            Set-ItResult -Skipped -Because "the case is one of the $($_.Engine) edition of PowerShell"
            return
        }
        if ($Ansi -and (Get-TestAnsiEncoding).CodePage -ne 1252) {
            Set-ItResult -Skipped -Because 'the case needs Windows-1252 as the ANSI code page'
            return
        }
        $module = Join-Path $script:clone 'src\PortableVM.psm1'
        $script:failure = $null
        $holder = $null
        if ($Bytes) { [IO.File]::WriteAllBytes($module, [byte[]](& $Bytes)) }
        if ($Held) { $holder = [IO.File]::Open($module, 'Open', 'Read', 'None') }
        if ($Failure) {
            $script:loadFailure = & $Failure
            Mock Import-Module { throw $script:loadFailure }
        }
        try {
            # The message PowerShell gives for the same import, which -Verbose must show.
            $expected = try { Import-Module -Name $module -Force -Global -ErrorAction Stop } catch { $_.Exception.Message }
            $verbose = @(& { try { $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -Verbose } catch { $script:failure = $_ } } 4>&1)
        } finally {
            if ($holder) { $holder.Dispose() }
        }
        $script:failure.Exception.Message | Should -BeExactly "The clone's src\PortableVM.psm1 cannot be loaded, so the settings cannot be checked$Cause (-Verbose shows the details)."
        $expected | Should -Not -BeNullOrEmpty
        @($verbose | Where-Object { $_ -is [Management.Automation.VerboseRecord] -and $_.Message -eq $expected }) | Should -Not -BeNullOrEmpty
    }

    It 'only runs the checks under -WhatIf' {
        $before = Get-TestTree -Root $script:target
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -WhatIf
        $result.Applied | Should -BeFalse
        $result.Mode | Should -BeExactly 'Update'
        Get-TestTree -Root $script:target | Should -BeExactly $before
        Format-DeployReport -Result $result | Should -BeExactly @('would deploy v0.0.0-test (Update).', 'old launcher .cmd files to move into Launcher.previous: 1.', 'Launcher.previous would hold version unknown.')
        Mock Get-DeployVmProcess { 'VirtualBoxVM.exe' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -WhatIf } | Should -Throw -ExpectedMessage 'A VM runs on this PC*'
    }

    It 'finds only .cmd files that run a launcher script' {
        Write-TestFile -Path (Join-Path $script:target 'Start Slash.cmd') -Text 'start "" -File "%~dp0\Launcher\Old-Launcher.ps1"'
        Write-TestFile -Path (Join-Path $script:target 'Start Old.cmdx') -Text 'start "" -File "%~dp0Launcher\x.ps1"'
        @(Find-DeployLauncherCmd -Folder $script:target | ForEach-Object { $_.Name } | Sort-Object) | Should -BeExactly @('Start Old.cmd', 'Start Slash.cmd')
    }
}

Describe 'Deploy-PortableVM keeps one previous launcher' -Tag 'WindowsOnly' {
    BeforeAll {
        # Write the folder $Path as a deploy of version $Version leaves it, with the clone's .cmd
        # unless -NoCmd is given.
        function Initialize-TestOwnCopy {
            param([string]$Path, [string]$Version, [switch]$NoCmd)
            $null = New-Item -ItemType Directory -Path $Path -Force
            $lines = foreach ($name in 'Start-PortableVM.ps1', 'PortableVM.psm1') {
                $file = Join-Path $Path $name
                [IO.File]::WriteAllText($file, "# $name of $Version`r`n", $script:utf8)
                '{0}  {1}' -f (Get-DeployHash -Path $file), $name
            }
            [IO.File]::WriteAllText((Join-Path $Path 'SHA256SUMS'), (($lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
            [IO.File]::WriteAllText((Join-Path $Path 'VERSION'), "$Version`n", [Text.Encoding]::ASCII)
            if (-not $NoCmd) { [IO.File]::Copy((Join-Path $script:clone 'Start VM.cmd'), (Join-Path $Path 'Start VM.cmd')) }
        }

        # Return the sorted names directly in the target folder.
        function Get-TestTargetName {
            @(Get-ChildItem -LiteralPath $script:target -Force -Name | Sort-Object)
        }

        # Return the text of the VERSION file in the target's folder $Name, without its line end.
        function Get-TestVersion {
            param([string]$Name)
            [IO.File]::ReadAllText((Join-Path (Join-Path $script:target $Name) 'VERSION')).TrimEnd("`n")
        }

        # Point a junction at $Path to the folder $To, and remember it so it is removed after the
        # test without touching what it points at.
        function Add-TestJunction {
            param([string]$Path, [string]$To)
            $null = New-Item -ItemType Junction -Path $Path -Target $To
            $script:junctions += $Path
        }
    }

    BeforeEach {
        Initialize-TestClone
        $script:junctions = @()
        $script:target = Join-Path $TestDrive 'target'
        Remove-Item -LiteralPath $script:target -Recurse -Force -ErrorAction SilentlyContinue
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $script:target 'VMware\Test VM.vmx') -Text "displayName = `"Test VM`"`r`n"
        Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher') -Version 'v1' -NoCmd
        Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher.previous') -Version 'v0'
        [IO.File]::Copy((Join-Path $script:clone 'Start VM.cmd'), (Join-Path $script:target 'Start VM.cmd'))
        $script:previous = Join-Path $script:target 'Launcher.previous'
        $script:removal = Join-Path $script:target 'Launcher.previous.remove'
        Mock Get-DeployVmProcess { @() }
        Mock Get-DeployVersion { 'v2' }
    }

    AfterEach {
        foreach ($junction in $script:junctions) {
            if (Test-DeployEntry -Path $junction) { [IO.Directory]::Delete($junction) }
        }
    }

    It 'replaces the copy two versions old, and reports what it holds and what it removed' {
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        Get-TestTargetName | Should -BeExactly @('Launcher', 'Launcher.previous', 'LauncherData', 'Start VM.cmd', 'VMware')
        Get-TestVersion -Name 'Launcher' | Should -BeExactly 'v2'
        Get-TestVersion -Name 'Launcher.previous' | Should -BeExactly 'v1'
        Format-DeployReport -Result $result | Should -BeExactly @(
            'deployed v2 (Update).'
            'old launcher .cmd files moved into Launcher.previous: 1.'
            'Launcher.previous holds version v1.'
            'removed the older launcher copy, version v0.'
        )
    }

    It 'needs no hand step for two deploys in a row' {
        $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        Mock Get-DeployVersion { 'v3' }
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        $result.Applied | Should -BeTrue
        Get-TestTargetName | Should -BeExactly @('Launcher', 'Launcher.previous', 'LauncherData', 'Start VM.cmd', 'VMware')
        Get-TestVersion -Name 'Launcher' | Should -BeExactly 'v3'
        Get-TestVersion -Name 'Launcher.previous' | Should -BeExactly 'v2'
    }

    It 'leaves LauncherData, the VM files, hand-named launcher folders and other folders byte for byte' {
        Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher.before-abc') -Version 'v-1'
        Write-TestFile -Path (Join-Path $script:target 'Other\file.txt') -Text 'mine'
        $names = 'LauncherData', 'VMware', 'Launcher.before-abc', 'Other'
        $before = @($names | ForEach-Object { Get-TestTree -Root (Join-Path $script:target $_) })
        $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        @($names | ForEach-Object { Get-TestTree -Root (Join-Path $script:target $_) }) | Should -BeExactly $before
    }

    It 'stops before any change when Launcher.previous <Case>' -ForEach @(
        @{ Case = 'holds an extra file'; Damage = { Write-TestFile -Path (Join-Path $script:previous 'notes.txt') -Text 'x' } }
        @{ Case = 'holds a hidden extra file'; Damage = { $f = Join-Path $script:previous 'desktop.ini'; Write-TestFile -Path $f -Text 'x'; [IO.File]::SetAttributes($f, 'Hidden') } }
        @{ Case = 'holds a subfolder'; Damage = { $null = New-Item -ItemType Directory -Path (Join-Path $script:previous 'sub') } }
        @{ Case = 'holds an empty subfolder named like a code file'; Damage = { $f = Join-Path $script:previous 'PortableVM.psm1'; [IO.File]::Delete($f); $null = New-Item -ItemType Directory -Path $f } }
        @{ Case = 'holds a changed code file'; Damage = { [IO.File]::AppendAllText((Join-Path $script:previous 'PortableVM.psm1'), '# changed') } }
        @{ Case = 'lacks a code file'; Damage = { [IO.File]::Delete((Join-Path $script:previous 'PortableVM.psm1')) } }
        @{ Case = 'lacks SHA256SUMS'; Damage = { [IO.File]::Delete((Join-Path $script:previous 'SHA256SUMS')) } }
        @{ Case = 'lacks VERSION'; Damage = { [IO.File]::Delete((Join-Path $script:previous 'VERSION')) } }
        @{ Case = 'has a changed SHA256SUMS'; Damage = { $f = Join-Path $script:previous 'SHA256SUMS'; $t = [IO.File]::ReadAllText($f); [IO.File]::WriteAllText($f, $(if ($t[0] -eq 'a') { 'b' } else { 'a' }) + $t.Substring(1)) } }
        @{ Case = 'has SHA256SUMS with CRLF'; Damage = { $f = Join-Path $script:previous 'SHA256SUMS'; [IO.File]::WriteAllText($f, [IO.File]::ReadAllText($f).Replace("`n", "`r`n")) } }
        @{ Case = 'has SHA256SUMS that names a path outside it'; Damage = { $f = Join-Path $script:previous 'SHA256SUMS'; [IO.File]::WriteAllText($f, [IO.File]::ReadAllText($f).Replace('  PortableVM.psm1', '  ..\PortableVM.psm1')) } }
        @{ Case = 'has SHA256SUMS that names a file twice'; Damage = { $f = Join-Path $script:previous 'SHA256SUMS'; $t = [IO.File]::ReadAllText($f); [IO.File]::WriteAllText($f, $t + $t) } }
        @{ Case = 'has an empty SHA256SUMS'; Damage = { [IO.File]::WriteAllText((Join-Path $script:previous 'SHA256SUMS'), '') } }
        @{ Case = 'has a VERSION of two lines'; Damage = { [IO.File]::WriteAllText((Join-Path $script:previous 'VERSION'), "v0`nv1`n") } }
        @{ Case = 'has a VERSION with CRLF'; Damage = { [IO.File]::WriteAllText((Join-Path $script:previous 'VERSION'), "v0`r`n") } }
        @{ Case = 'has a VERSION without a line end'; Damage = { [IO.File]::WriteAllText((Join-Path $script:previous 'VERSION'), 'v0') } }
        @{ Case = 'has a VERSION with a space'; Damage = { [IO.File]::WriteAllText((Join-Path $script:previous 'VERSION'), "v 0`n") } }
        @{ Case = 'holds a changed Start VM.cmd'; Damage = { [IO.File]::AppendAllText((Join-Path $script:previous 'Start VM.cmd'), 'rem changed') } }
        @{ Case = 'holds an old settings.psd1'; Damage = { Write-TestFile -Path (Join-Path $script:previous 'settings.psd1') -Text (Get-TestSettingsText) } }
        @{ Case = 'holds a read-only file'; Damage = { [IO.File]::SetAttributes((Join-Path $script:previous 'VERSION'), 'ReadOnly') } }
        @{ Case = 'is itself read-only'; Damage = { [IO.File]::SetAttributes($script:previous, 'Directory, ReadOnly') } }
        @{ Case = 'holds a junction'; Damage = { Add-TestJunction -Path (Join-Path $script:previous 'link') -To (Join-Path $script:target 'VMware') } }
        @{ Case = 'is a junction to a copy'; Damage = {
                $real = Join-Path $script:target 'real'
                [IO.Directory]::Move($script:previous, $real)
                Add-TestJunction -Path $script:previous -To $real
            } }
        @{ Case = 'is a file'; Damage = { [IO.Directory]::Delete($script:previous, $true); Write-TestFile -Path $script:previous -Text 'x' } }
    ) {
        & $Damage
        $before = Get-TestTree -Root $script:target
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'Launcher.previous is not a launcher copy that a deploy wrote and nothing changed since*so nothing was changed.*'
        Get-TestTree -Root $script:target | Should -BeExactly $before
        # A read-only folder cannot be emptied by the next test's clean-up.
        if (Test-Path -LiteralPath $script:previous -PathType Container) { [IO.File]::SetAttributes($script:previous, 'Directory') }
    }

    It 'stops at a copy whose file another program holds, since it cannot be checked' {
        $before = Get-TestTree -Root $script:target
        $held = [IO.File]::Open((Join-Path $script:previous 'PortableVM.psm1'), 'Open', 'Read', 'None')
        try {
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
                Should -Throw -ExpectedMessage 'Launcher.previous is not a launcher copy that a deploy wrote and nothing changed since (it cannot be read)*'
        } finally { $held.Dispose() }
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'keeps the good copy and stops before any change when Launcher <Case>' -ForEach @(
        @{ Case = 'holds a changed code file'; Damage = { [IO.File]::AppendAllText((Join-Path $script:target 'Launcher\PortableVM.psm1'), '# changed') } }
        @{ Case = 'holds an extra file'; Damage = { Write-TestFile -Path (Join-Path $script:target 'Launcher\notes.txt') -Text 'x' } }
        @{ Case = 'lacks its VERSION'; Damage = { [IO.File]::Delete((Join-Path $script:target 'Launcher\VERSION')) } }
    ) {
        & $Damage
        $before = Get-TestTree -Root $script:target
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'Launcher is not a launcher copy that a deploy wrote and nothing changed since (*), so replacing it would cost the copy in Launcher.previous, and nothing was changed. Rename Launcher.previous to keep it, then deploy again. The changed Launcher then becomes Launcher.previous, which the next deploy refuses until it is moved away.'
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'replaces a damaged Launcher once Launcher.previous has another name, which it leaves alone' {
        [IO.File]::AppendAllText((Join-Path $script:target 'Launcher\PortableVM.psm1'), '# changed')
        $kept = Join-Path $script:target 'Launcher.kept'
        [IO.Directory]::Move($script:previous, $kept)
        $before = Get-TestTree -Root $kept
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        $result.Applied | Should -BeTrue
        Get-TestVersion -Name 'Launcher' | Should -BeExactly 'v2'
        Get-TestTree -Root $kept | Should -BeExactly $before
    }

    It 'keeps the good copy when a deploy that failed its last check is run again' {
        [IO.Directory]::Delete($script:previous, $true)
        Mock Test-DeployStagedCode { $false }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } | Should -Throw -ExpectedMessage 'The new launcher in Launcher does not match the clone*'
        [IO.File]::AppendAllText((Join-Path $script:target 'Launcher\PortableVM.psm1'), '# damaged')
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } | Should -Throw -ExpectedMessage 'Launcher is not a launcher copy*'
        Get-TestVersion -Name 'Launcher.previous' | Should -BeExactly 'v1'
    }

    It 'sees a junction whose target is gone as something at that name, and not as a copy' {
        $gone = Join-Path $script:target 'gone'
        $null = New-Item -ItemType Directory -Path $gone
        $link = Join-Path $script:target 'dangling'
        Add-TestJunction -Path $link -To $gone
        [IO.Directory]::Delete($gone)
        Test-DeployEntry -Path $link | Should -BeTrue
        Test-DeployEntry -Path (Join-Path $script:target 'nothing') | Should -BeFalse
        (Get-DeployOwnCopy -Folder $link -CmdSource (Join-Path $script:clone 'Start VM.cmd')).Problem | Should -Not -BeNullOrEmpty
    }

    It 'reads its own copy with its version and the files it may delete' {
        $copy = Get-DeployOwnCopy -Folder $script:previous -CmdSource (Join-Path $script:clone 'Start VM.cmd')
        $copy.Problem | Should -BeNullOrEmpty
        $copy.Version | Should -BeExactly 'v0'
        @($copy.Files | Sort-Object) | Should -BeExactly @('PortableVM.psm1', 'SHA256SUMS', 'Start VM.cmd', 'Start-PortableVM.ps1', 'VERSION')
    }

    It 'accepts a copy without a .cmd' {
        [IO.File]::Delete((Join-Path $script:previous 'Start VM.cmd'))
        (Get-DeployOwnCopy -Folder $script:previous -CmdSource (Join-Path $script:clone 'Start VM.cmd')).Problem | Should -BeNullOrEmpty
    }

    It 'lets a file that appears after the check survive with its folder' {
        [IO.Directory]::Move($script:previous, $script:removal)
        $copy = Get-DeployOwnCopy -Folder $script:removal -CmdSource (Join-Path $script:clone 'Start VM.cmd')
        Write-TestFile -Path (Join-Path $script:removal 'late.txt') -Text 'late'
        { Remove-DeployOwnCopy -Folder $script:removal -Files $copy.Files } | Should -Throw
        @(Get-ChildItem -LiteralPath $script:removal -Force -Name) | Should -BeExactly @('late.txt')
    }

    It 'deletes only a folder of the fixed name' {
        $copy = Get-DeployOwnCopy -Folder $script:previous -CmdSource (Join-Path $script:clone 'Start VM.cmd')
        $before = Get-TestTree -Root $script:previous
        { Remove-DeployOwnCopy -Folder $script:previous -Files $copy.Files } | Should -Throw -ExpectedMessage '*only*Launcher.previous.remove*'
        Get-TestTree -Root $script:previous | Should -BeExactly $before
    }

    It 'keeps the older copy and says so when a file appears in it before the last check' {
        # The check of the new launcher is the last step before the older copy's own check. The
        # same function first compares Launcher with the clone, before the older copy moves.
        Mock Test-DeployStagedCode {
            if (-not (Test-Path -LiteralPath $script:removal)) { return $false }
            Write-TestFile -Path (Join-Path $script:removal 'late.txt') -Text 'late'
            $true
        }
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
        $result.Applied | Should -BeTrue
        Join-Path $script:removal 'late.txt' | Should -Exist
        Join-Path $script:removal 'VERSION' | Should -Exist
        $lines = @(Format-DeployReport -Result $result)
        $lines | Should -Not -Contain 'removed the older launcher copy, version v0.'
        $lines[-1] | Should -BeLike 'the older launcher copy stays in Launcher.previous.remove: *Check what it holds, then move it away before the next deploy.'
    }

    It 'deletes nothing when the new launcher fails its last check' {
        Mock Test-DeployStagedCode { $false }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'The new launcher in Launcher does not match the clone*nothing was deleted*Launcher.previous.remove back to Launcher.previous*'
        Get-TestVersion -Name 'Launcher.previous.remove' | Should -BeExactly 'v0'
        Get-TestVersion -Name 'Launcher.previous' | Should -BeExactly 'v1'
        Get-TestVersion -Name 'Launcher' | Should -BeExactly 'v2'
    }

    It 'deletes nothing when the last check of the new launcher cannot read it' {
        Mock Test-DeployStagedCode { throw 'held' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'The new launcher in Launcher does not match the clone*nothing was deleted*'
        Get-TestVersion -Name 'Launcher.previous.remove' | Should -BeExactly 'v0'
    }

    It 'deletes nothing when the .cmd in place differs from the clone at the last check' {
        Mock Rename-DeployItem {
            [IO.Directory]::Move($Path, (Join-Path (Split-Path $Path) $NewName))
            if ($NewName -eq 'Start VM.cmd') { [IO.File]::AppendAllText((Join-Path (Split-Path $Path) $NewName), 'rem changed') }
        }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'The new launcher in Launcher does not match the clone*nothing was deleted*'
        Get-TestVersion -Name 'Launcher.previous.remove' | Should -BeExactly 'v0'
    }

    It 'puts everything back when the rename to <NewName> of <From> fails' -ForEach @(
        @{ From = 'Launcher.previous'; NewName = 'Launcher.previous.remove'; Message = "Launcher.previous could not be renamed, so the stick's launcher is unchanged.*" }
        @{ From = 'Launcher'; NewName = 'Launcher.previous'; Message = "Launcher could not be renamed, so the stick's launcher is unchanged.*" }
        @{ From = 'Launcher.new'; NewName = 'Launcher'; Message = 'Launcher.new could not take the place of Launcher, so Launcher is back as it was.*' }
    ) {
        $script:failFrom = $From
        $script:failName = $NewName
        Mock Rename-DeployItem {
            if ((Split-Path $Path -Leaf) -eq $script:failFrom -and $NewName -eq $script:failName) { throw 'held' }
            [IO.Directory]::Move($Path, (Join-Path (Split-Path $Path) $NewName))
        }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } | Should -Throw -ExpectedMessage $Message
        Get-TestVersion -Name 'Launcher' | Should -BeExactly 'v1'
        Get-TestVersion -Name 'Launcher.previous' | Should -BeExactly 'v0'
        $script:removal | Should -Not -Exist
        Join-Path $script:target 'Start VM.cmd' | Should -Exist
    }

    It 'names the exact renames when <Case>' -ForEach @(
        @{ Case = 'Launcher.previous.remove cannot go back after Launcher stayed'; Fail = @('Launcher>Launcher.previous', 'Launcher.previous.remove>Launcher.previous')
            Message = '*Rename Launcher.previous.remove back to Launcher.previous*Launcher.new and ''Start VM.cmd.new''*'; Left = @('Launcher', 'Launcher.new', 'Launcher.previous.remove') }
        @{ Case = 'Launcher cannot be put back'; Fail = @('Launcher.new>Launcher', 'Launcher.previous>Launcher')
            Message = 'Launcher is missing: Launcher.previous holds the launcher that was in use. Rename Launcher.previous back to Launcher, then Launcher.previous.remove back to Launcher.previous*'; Left = @('Launcher.new', 'Launcher.previous', 'Launcher.previous.remove') }
        @{ Case = 'Launcher went back but the older copy cannot'; Fail = @('Launcher.new>Launcher', 'Launcher.previous.remove>Launcher.previous')
            Message = 'Launcher is back as it was, but Launcher.previous.remove could not be renamed back. Rename Launcher.previous.remove back to Launcher.previous*'; Left = @('Launcher', 'Launcher.new', 'Launcher.previous.remove') }
    ) {
        $script:failRenames = $Fail
        Mock Rename-DeployItem {
            if ($script:failRenames -contains "$(Split-Path $Path -Leaf)>$NewName") { throw 'held' }
            [IO.Directory]::Move($Path, (Join-Path (Split-Path $Path) $NewName))
        }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } | Should -Throw -ExpectedMessage $Message
        @(Get-TestTargetName | Where-Object { $_ -like 'Launcher*' -and $_ -ne 'LauncherData' }) | Should -BeExactly $Left
    }

    It 'keeps the older copy and names the steps when the .cmd cannot be put in place' {
        Mock Move-Item { throw 'held' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage "The new launcher is in Launcher, but its .cmd is not in place yet.*The next deploy then removes Launcher.previous.remove.*"
        Get-TestVersion -Name 'Launcher.previous.remove' | Should -BeExactly 'v0'
    }

    Context 'after a deploy that was cut off' {
        It 'stops and names the renames, with <Case>' -ForEach @(
            @{ Case = 'the older copy renamed'; Step = {
                    [IO.Directory]::Move($script:previous, $script:removal)
                    Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher.new') -Version 'v2' -NoCmd
                    [IO.File]::Copy((Join-Path $script:clone 'Start VM.cmd'), (Join-Path $script:target 'Start VM.cmd.new'))
                }; Message = 'Launcher.previous.remove is left from a deploy that stopped, and Launcher.previous is missing. Rename Launcher.previous.remove back to Launcher.previous, remove Launcher.new and ''Start VM.cmd.new'' if they are there, then deploy again.' }
            @{ Case = 'Launcher renamed too'; Step = {
                    [IO.Directory]::Move($script:previous, $script:removal)
                    [IO.Directory]::Move((Join-Path $script:target 'Launcher'), $script:previous)
                    Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher.new') -Version 'v2' -NoCmd
                    [IO.File]::Copy((Join-Path $script:clone 'Start VM.cmd'), (Join-Path $script:target 'Start VM.cmd.new'))
                }; Message = 'The target has no Launcher folder, but Launcher.previous holds the launcher that a deploy that stopped replaced. Rename Launcher.previous back to Launcher, then Launcher.previous.remove back to Launcher.previous, remove Launcher.new and ''Start VM.cmd.new'' if they are there, then deploy again.' }
            @{ Case = 'only the older copy left'; Step = {
                    [IO.Directory]::Move($script:previous, $script:removal)
                    [IO.Directory]::Delete((Join-Path $script:target 'Launcher'), $true)
                }; Message = 'The target has no Launcher or Launcher.previous folder, but Launcher.previous.remove holds an older launcher. Rename Launcher.previous.remove to Launcher, remove Launcher.new and ''Start VM.cmd.new'' if they are there, then deploy again.' }
            @{ Case = 'the new launcher in place but not its .cmd'; Step = {
                    [IO.Directory]::Move($script:previous, $script:removal)
                    [IO.Directory]::Move((Join-Path $script:target 'Launcher'), $script:previous)
                    Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher') -Version 'v2' -NoCmd
                    [IO.File]::Copy((Join-Path $script:clone 'Start VM.cmd'), (Join-Path $script:target 'Start VM.cmd.new'))
                }; Message = "The new launcher is in Launcher, but its .cmd is not in place yet. Move the old launcher .cmd files at the stick's root into Launcher.previous, then rename 'Start VM.cmd.new' to 'Start VM.cmd', then deploy again." }
        ) {
            & $Step
            $before = Get-TestTree -Root $script:target
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } | Should -Throw -ExpectedMessage $Message
            Get-TestTree -Root $script:target | Should -BeExactly $before
        }

        It 'finishes the removal that was left, then deploys' {
            [IO.Directory]::Move($script:previous, $script:removal)
            [IO.Directory]::Move((Join-Path $script:target 'Launcher'), $script:previous)
            Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher') -Version 'v1b' -NoCmd
            [IO.File]::Copy((Join-Path $script:target 'Start VM.cmd'), (Join-Path $script:previous 'Start VM.cmd'))
            $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            Get-TestTargetName | Should -BeExactly @('Launcher', 'Launcher.previous', 'LauncherData', 'Start VM.cmd', 'VMware')
            Get-TestVersion -Name 'Launcher' | Should -BeExactly 'v2'
            Get-TestVersion -Name 'Launcher.previous' | Should -BeExactly 'v1b'
            $lines = @(Format-DeployReport -Result $result)
            $lines | Should -Contain 'removed the older launcher copy, version v0.'
            $lines | Should -Contain 'removed the older launcher copy, version v1.'
        }

        It 'stops at a removal cut off half way and asks to remove the rest by hand' {
            [IO.Directory]::Move($script:previous, $script:removal)
            [IO.Directory]::Move((Join-Path $script:target 'Launcher'), $script:previous)
            Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher') -Version 'v2' -NoCmd
            [IO.File]::Delete((Join-Path $script:removal 'PortableVM.psm1'))
            $before = Get-TestTree -Root $script:target
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
                Should -Throw -ExpectedMessage 'Launcher.previous.remove is not a launcher copy that a deploy wrote and nothing changed since*Check what it holds, remove it or move it away, then deploy again.'
            Get-TestTree -Root $script:target | Should -BeExactly $before
        }

        It 'finishes no removal while the launcher in use is not unchanged' {
            [IO.Directory]::Move($script:previous, $script:removal)
            [IO.Directory]::Move((Join-Path $script:target 'Launcher'), $script:previous)
            Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher') -Version 'v2' -NoCmd
            [IO.File]::AppendAllText((Join-Path $script:target 'Launcher\PortableVM.psm1'), '# changed')
            $before = Get-TestTree -Root $script:target
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
                Should -Throw -ExpectedMessage 'Launcher does not match its SHA256SUMS*Launcher.previous.remove*'
            Get-TestTree -Root $script:target | Should -BeExactly $before
        }

        It 'stops with the staged files named when the left removal fails, and keeps the launcher' {
            [IO.Directory]::Move($script:previous, $script:removal)
            [IO.Directory]::Move((Join-Path $script:target 'Launcher'), $script:previous)
            Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher') -Version 'v1b' -NoCmd
            Mock Remove-DeployOwnCopy { throw 'held' }
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
                Should -Throw -ExpectedMessage "Launcher.previous.remove could not be removed, so nothing the launcher uses was changed. Remove Launcher.new and 'Start VM.cmd.new', move Launcher.previous.remove away, then deploy again.*"
            Get-TestVersion -Name 'Launcher' | Should -BeExactly 'v1b'
            Get-TestVersion -Name 'Launcher.previous.remove' | Should -BeExactly 'v0'
        }

        It 'says under -WhatIf that it would remove both, and changes nothing' {
            [IO.Directory]::Move($script:previous, $script:removal)
            [IO.Directory]::Move((Join-Path $script:target 'Launcher'), $script:previous)
            Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher') -Version 'v1b' -NoCmd
            $before = Get-TestTree -Root $script:target
            $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -WhatIf
            Get-TestTree -Root $script:target | Should -BeExactly $before
            $lines = @(Format-DeployReport -Result $result)
            $lines | Should -Contain 'would remove the older launcher copy, version v0.'
            $lines | Should -Contain 'would remove the older launcher copy, version v1.'
        }
    }

    It 'changes nothing under -WhatIf and says what it would remove' {
        $before = Get-TestTree -Root $script:target
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -WhatIf
        $result.Applied | Should -BeFalse
        Get-TestTree -Root $script:target | Should -BeExactly $before
        Format-DeployReport -Result $result | Should -BeExactly @(
            'would deploy v2 (Update).'
            'old launcher .cmd files to move into Launcher.previous: 1.'
            'Launcher.previous would hold version v1.'
            'would remove the older launcher copy, version v0.'
        )
    }

    Context 'a repeated deploy of the commit that Launcher holds' {
        It 'stops and keeps the earlier version as Launcher.previous' {
            $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
                Should -Throw -ExpectedMessage 'Launcher already holds v2, file for file the commit this deploy would write, so nothing was changed and Launcher.previous keeps version v1.*'
            Get-TestVersion -Name 'Launcher.previous' | Should -BeExactly 'v1'
            Get-TestVersion -Name 'Launcher' | Should -BeExactly 'v2'
        }

        It 'leaves the whole scratch stick byte for byte as it was' {
            $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            $before = Get-TestTree -Root $script:target
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } | Should -Throw -ExpectedMessage 'Launcher already holds v2*'
            Get-TestTree -Root $script:target | Should -BeExactly $before
        }

        It 'stops also without a Launcher.previous, and says that nothing needs writing again' {
            $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            [IO.Directory]::Delete($script:previous, $true)
            $before = Get-TestTree -Root $script:target
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
                Should -Throw -ExpectedMessage 'Launcher already holds v2, file for file the commit this deploy would write, so nothing was changed. There is nothing to write again: a Launcher that differs from the clone in any file is replaced as usual.'
            Get-TestTree -Root $script:target | Should -BeExactly $before
        }

        It 'names the root .cmd when it is the one file that differs' {
            $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            [IO.File]::AppendAllText((Join-Path $script:target 'Start VM.cmd'), "rem changed`r`n")
            $before = Get-TestTree -Root $script:target
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
                Should -Throw -ExpectedMessage "Launcher already holds v2, file for file the commit this deploy would write, so nothing was changed and Launcher.previous keeps version v1. Only 'Start VM.cmd' at the stick's root differs from the clone's: copy the clone's 'Start VM.cmd' there by hand."
            Get-TestTree -Root $script:target | Should -BeExactly $before
        }

        It 'keeps a removal left over while the root .cmd differs from the clone' {
            $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            Initialize-TestOwnCopy -Path $script:removal -Version 'v0'
            [IO.File]::AppendAllText((Join-Path $script:target 'Start VM.cmd'), "rem changed`r`n")
            $before = Get-TestTree -Root $script:target
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
                Should -Throw -ExpectedMessage "Launcher already holds v2, but 'Start VM.cmd' at the stick's root differs from the clone's, so Launcher.previous.remove stays and nothing was changed. Copy the clone's 'Start VM.cmd' to the stick's root, then deploy again."
            Get-TestTree -Root $script:target | Should -BeExactly $before
        }

        It 'deploys over a Launcher with the same version but other code' {
            [IO.Directory]::Delete((Join-Path $script:target 'Launcher'), $true)
            Initialize-TestOwnCopy -Path (Join-Path $script:target 'Launcher') -Version 'v2' -NoCmd
            $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            $result.Applied | Should -BeTrue
            Get-TestVersion -Name 'Launcher.previous' | Should -BeExactly 'v2'
            [IO.File]::ReadAllText((Join-Path $script:target 'Launcher\Start-PortableVM.ps1')) | Should -BeExactly "# new script`r`n"
        }

        It 'only finishes a removal that a deploy of the same commit left, and keeps Launcher and Launcher.previous' {
            $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            Initialize-TestOwnCopy -Path $script:removal -Version 'v0'
            $launcherTree = Get-TestTree -Root (Join-Path $script:target 'Launcher')
            $previousTree = Get-TestTree -Root $script:previous
            $plan = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -WhatIf
            Format-DeployReport -Result $plan | Should -BeExactly @(
                'Launcher already holds v2; would finish the removal that an earlier deploy left.'
                'Launcher.previous would hold version v1.'
                'would remove the older launcher copy, version v0.'
            )
            $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target
            $script:removal | Should -Not -Exist
            Get-TestTree -Root (Join-Path $script:target 'Launcher') | Should -BeExactly $launcherTree
            Get-TestTree -Root $script:previous | Should -BeExactly $previousTree
            Format-DeployReport -Result $result | Should -BeExactly @(
                'Launcher already holds v2; finished the removal that an earlier deploy left.'
                'Launcher.previous holds version v1.'
                'removed the older launcher copy, version v0.'
            )
        }
    }

    It 'never deletes the Launcher.previous of a migration, which holds the old settings' {
        Remove-Item -LiteralPath (Join-Path $script:target 'LauncherData'), $script:previous -Recurse -Force
        Write-TestFile -Path (Join-Path $script:target 'Launcher\settings.psd1') -Text (Get-TestSettingsText)
        $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings
        Join-Path $script:previous 'settings.psd1' | Should -Exist
        $before = Get-TestTree -Root $script:target
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target } |
            Should -Throw -ExpectedMessage 'Launcher.previous is not a launcher copy that a deploy wrote and nothing changed since*'
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'still refuses a migration while Launcher.previous is there, whatever it holds' {
        Write-TestFile -Path (Join-Path $script:target 'Launcher\settings.psd1') -Text (Get-TestSettingsText)
        $before = Get-TestTree -Root $script:target
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } |
            Should -Throw -ExpectedMessage 'Launcher.previous holds the launcher that the last deploy replaced. A migration keeps the old settings there, so move it away first.'
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }
}

Describe 'Deploy-PortableVM -MigrateSettings' -Tag 'WindowsOnly' {
    BeforeEach {
        Initialize-TestClone
        $script:target = Join-Path $TestDrive 'target'
        Remove-Item -LiteralPath $script:target -Recurse -Force -ErrorAction SilentlyContinue
        # A stick as the launcher before LauncherData left it: settings and log in Launcher, and the
        # copies it kept beside the files it rewrote.
        Write-TestFile -Path (Join-Path $script:target 'Launcher\settings.psd1') -Text (Get-TestSettingsText)
        Write-TestFile -Path (Join-Path $script:target 'Launcher\launcher.log') -Text "old log line`r`n"
        Write-TestFile -Path (Join-Path $script:target 'Launcher\Start-PortableVM.ps1') -Text "# old script`r`n"
        Write-TestFile -Path (Join-Path $script:target 'Start VM.cmd') -Text "@echo off`r`nstart `"`" -File `"%~dp0Launcher\Start-PortableVM.ps1`"`r`n"
        Write-TestFile -Path (Join-Path $script:target 'VMware\Test VM.vmx') -Text "displayName = `"Test VM`"`r`n"
        Write-TestFile -Path (Join-Path $script:target 'VMware\stick.vmdk') -Text (Get-TestDescriptorText)
        Write-TestFile -Path (Join-Path $script:target 'VMware\stick.vmdk.orig') -Text (Get-TestDescriptorText -Device '\\.\PhysicalDrive1')
        Write-TestFile -Path (Join-Path $script:target 'VMware\Test VM.vmx.orig') -Text 'a copy made by hand'
        [IO.File]::WriteAllBytes((Join-Path $script:target 'VMware\big.vmdk.orig'), (New-Object byte[] 1048576))
        Write-TestFile -Path (Join-Path $script:target 'VirtualBox\VirtualBox.xml') -Text '<VirtualBox/>'
        Write-TestFile -Path (Join-Path $script:target 'VirtualBox\VirtualBox.xml.launcher-backup') -Text '<VirtualBox old="1"/>'
        Write-TestFile -Path (Join-Path $script:target 'VirtualBox\Test VM\Test VM.vbox') -Text '<VirtualBox/>'
        Write-TestFile -Path (Join-Path $script:target 'VirtualBox\Test VM\Test VM.vbox.launcher-backup') -Text '<VirtualBox old="2"/>'
        Write-TestFile -Path (Join-Path $script:target 'VirtualBox\Test VM\stick.vmdk') -Text (Get-TestDescriptorText)
        Write-TestFile -Path (Join-Path $script:target 'VirtualBox\Test VM\stick.vmdk.orig') -Text (Get-TestDescriptorText -Device '\\?\PhysicalDrive2').Replace("`r`n", "`n")
        $script:legacy = Join-Path $script:target 'LauncherData\backups\legacy'
        $script:vmFiles = @('VMware\Test VM.vmx', 'VMware\stick.vmdk', 'VirtualBox\VirtualBox.xml', 'VirtualBox\Test VM\Test VM.vbox', 'VirtualBox\Test VM\stick.vmdk')
        $script:vmHashes = @($script:vmFiles | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $script:target $_) -Algorithm SHA256).Hash })
        Mock Get-DeployVmProcess { @() }
        Mock Get-DeployVersion { 'v0.0.0-test' }
    }

    It 'moves the settings, the log and the old copies to LauncherData, disarms the descriptor copies, then swaps the code' {
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings
        $result.Mode | Should -BeExactly 'Migrate'
        $result.Applied | Should -BeTrue
        $result.Plan.Log | Should -BeTrue
        $result.Plan.Descriptors | Should -Be 2
        $result.Plan.VirtualBoxCopies | Should -Be 2
        $result.Plan.KeptCopies | Should -Be 2
        $data = Join-Path $script:target 'LauncherData'
        [IO.File]::ReadAllText((Join-Path $data 'settings.psd1')) | Should -BeExactly (Get-TestSchema2Text)
        $null = Import-PvmSetting -Path (Join-Path $data 'settings.psd1')
        [IO.File]::ReadAllText((Join-Path $script:legacy 'Launcher\settings.psd1')) | Should -BeExactly (Get-TestSettingsText)
        [IO.File]::ReadAllText((Join-Path $script:target 'Launcher.previous\settings.psd1')) | Should -BeExactly (Get-TestSettingsText)
        [IO.File]::ReadAllText((Join-Path $data 'logs\launcher.log')) | Should -BeExactly "old log line`r`n"
        Join-Path $script:target 'Launcher.previous\launcher.log' | Should -Not -Exist
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VMware\stick.vmdk.orig')) | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VirtualBox\Test VM\stick.vmdk.orig')) |
            Should -BeExactly (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed').Replace("`r`n", "`n")
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VirtualBox\VirtualBox.xml.launcher-backup')) | Should -BeExactly '<VirtualBox old="1"/>'
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VirtualBox\Test VM\Test VM.vbox.launcher-backup')) | Should -BeExactly '<VirtualBox old="2"/>'
        foreach ($moved in 'VMware\stick.vmdk.orig', 'VirtualBox\VirtualBox.xml.launcher-backup', 'VirtualBox\Test VM\Test VM.vbox.launcher-backup', 'VirtualBox\Test VM\stick.vmdk.orig') {
            Join-Path $script:target $moved | Should -Not -Exist
        }
        Join-Path $script:target 'VMware\Test VM.vmx.orig' | Should -Exist
        Join-Path $script:target 'VMware\big.vmdk.orig' | Should -Exist
        @(Get-ChildItem -LiteralPath $script:target -Recurse -Filter '*.pvm-tmp') | Should -BeNullOrEmpty
        @($script:vmFiles | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $script:target $_) -Algorithm SHA256).Hash }) | Should -BeExactly $script:vmHashes
        @(Get-ChildItem -LiteralPath (Join-Path $script:target 'Launcher') -Name | Sort-Object) | Should -BeExactly @('PortableVM.psm1', 'SHA256SUMS', 'Start-PortableVM.ps1', 'VERSION')
        Join-Path $script:target 'Launcher.previous\Start-PortableVM.ps1' | Should -Exist
        Join-Path $script:target 'Launcher.previous\Start VM.cmd' | Should -Exist
        Format-DeployReport -Result $result | Should -BeExactly @(
            'deployed v0.0.0-test (Migrate).'
            'settings: LauncherData\settings.psd1 holds them in schema 2, with a copy of the old file in LauncherData\backups\legacy\Launcher.'
            'log moved to LauncherData\logs: 1.'
            'descriptor copies moved to LauncherData\backups\legacy and disarmed: 2.'
            'VirtualBox copies moved to LauncherData\backups\legacy: 2.'
            'other copies left beside the VM files: 2.'
            'old launcher .cmd files moved into Launcher.previous: 1.'
            'Launcher.previous holds version unknown.'
        )
    }

    It 'adds the names when they are given' {
        $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings -VmDisplayName "Ann's VM" -GuestName 'Test OS'
        [IO.File]::ReadAllText((Join-Path $script:target 'LauncherData\settings.psd1')) |
            Should -BeExactly (Get-TestSchema2Text -Add "VmDisplayName = 'Ann''s VM'", "GuestName = 'Test OS'")
    }

    It 'changes nothing under -WhatIf and reports its plan' {
        $before = Get-TestTree -Root $script:target
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings -WhatIf
        Get-TestTree -Root $script:target | Should -BeExactly $before
        (Format-DeployReport -Result $result)[0..2] | Should -BeExactly @(
            'would deploy v0.0.0-test (Migrate).'
            'settings: LauncherData\settings.psd1 would hold them in schema 2, with a copy of the old file in LauncherData\backups\legacy\Launcher.'
            'log to move to LauncherData\logs: 1.'
        )
    }

    It 'runs as a script with -WhatIf, printing its plan and changing nothing' {
        $before = Get-TestTree -Root $script:target
        $tool = Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1'
        $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -Target $script:target -MigrateSettings -WhatIf 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
        if ($output -match 'A VM runs on this PC') {
            Set-ItResult -Skipped -Because 'a VM runs on this PC'
            return
        }
        $exitCode | Should -Be 0
        ($output -join "`n") | Should -Match 'Deploy-PortableVM: would deploy \S+ \(Migrate\)\.'
        ($output -join "`n") | Should -Match 'Deploy-PortableVM: descriptor copies to move to LauncherData\\backups\\legacy and disarmed: 2\.'
        $output | Where-Object { $_ -like 'What if:*' -and $_ -notlike '*"Deploy the launcher *" on target "the -Target folder".' } | Should -BeNullOrEmpty
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'runs as a script and prints the cause of an error from Windows, not its path' {
        $tool = Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1'
        $held = [IO.File]::Open((Join-Path $script:target 'Launcher\settings.psd1'), 'Open', 'Read', 'None')
        try { $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -Target $script:target -MigrateSettings 2>&1 | ForEach-Object { "$_" }) }
        finally { $held.Dispose() }
        $exitCode = $LASTEXITCODE
        if ($output -match 'A VM runs on this PC') {
            Set-ItResult -Skipped -Because 'a VM runs on this PC'
            return
        }
        $exitCode | Should -Be 1
        $output | Should -Contain 'Deploy-PortableVM: Launcher\settings.psd1 cannot be read: it is open in another program (-Verbose shows the details).'
        ($output -join "`n").IndexOf($script:target, [StringComparison]::OrdinalIgnoreCase) | Should -Be -1
    }

    It 'runs as a script and prints only the cause of an error from Windows that no step catches' {
        # A resume hashes a 'Start VM.cmd.new' that it could reuse, and another program holds it.
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        $cmd = Join-Path $script:target 'Start VM.cmd.new'
        Copy-Item -LiteralPath (Join-Path $script:repoRoot 'Start VM.cmd') -Destination $cmd
        $tool = Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1'
        $held = [IO.File]::Open($cmd, 'Open', 'Read', 'None')
        try { $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -Target $script:target -MigrateSettings 2>&1 | ForEach-Object { "$_" }) }
        finally { $held.Dispose() }
        $exitCode = $LASTEXITCODE
        if ($output -match 'A VM runs on this PC') {
            Set-ItResult -Skipped -Because 'a VM runs on this PC'
            return
        }
        $exitCode | Should -Be 1
        $output | Should -Contain 'Deploy-PortableVM: the deploy stopped: it is open in another program (-Verbose shows the details).'
        ($output -join "`n").IndexOf($script:target, [StringComparison]::OrdinalIgnoreCase) | Should -Be -1
    }

    It 'says which file it is when the settings a resume keeps cannot be read a second time' {
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        # The first read passes; then another program opens the file. A test before may have left
        # no module behind, and a mock needs the command it replaces.
        Import-Module (Join-Path $script:clone 'src\PortableVM.psm1') -Force -Global
        Mock Import-PvmSetting { @{} }
        $held = [IO.File]::Open((Join-Path $script:target 'LauncherData\settings.psd1'), 'Open', 'Read', 'None')
        try { $message = try { $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } catch { $_.Exception.Message } }
        finally { $held.Dispose() }
        $message | Should -BeExactly 'LauncherData\settings.psd1 cannot be read, so nothing was changed: it is open in another program (-Verbose shows the details).'
        Should -Invoke Import-PvmSetting -Times 1 -Exactly
    }

    It 'names the cause of <Case> that it cannot open, and shows the message from Windows with -Verbose' -ForEach @(
        @{ Case = 'the old settings'; File = 'Launcher\settings.psd1'; Resume = $false; Message = 'Launcher\settings.psd1 cannot be read: it is open in another program (-Verbose shows the details).' }
        @{ Case = 'the settings a resume keeps'; File = 'LauncherData\settings.psd1'; Resume = $true; Message = ('LauncherData\settings.psd1 is there from a migration that stopped, and this run keeps it, ' +
                'but it must pass the checks first, so nothing was changed. LauncherData\settings.psd1 cannot be read: it is open in another program (-Verbose shows the details).') }
    ) {
        if ($Resume) { Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text) }
        $script:failure = $null
        $settings = Join-Path $script:target $File
        $held = [IO.File]::Open($settings, 'Open', 'Read', 'None')
        try { $verbose = @(& { try { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings -Verbose } catch { $script:failure = $_ } } 4>&1) }
        finally { $held.Dispose() }
        $script:failure.Exception.Message | Should -BeExactly $Message
        @($verbose | Where-Object { $_ -is [Management.Automation.VerboseRecord] -and $_.Message.IndexOf($settings, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) |
            Should -Not -BeNullOrEmpty
    }

    It 'runs as a script and says so when the -Target folder does not exist, also when its name holds brackets' {
        $tool = Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1'
        $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -Target (Join-Path $TestDrive 'no stick [1]') 2>&1 | ForEach-Object { "$_" })
        $LASTEXITCODE | Should -Be 1
        $output | Should -Contain 'Deploy-PortableVM: The -Target folder does not exist. Give the folder on the stick that holds the Launcher and LauncherData folders.'
    }

    It 'refuses <Case>, changing nothing' -ForEach @(
        @{ Case = 'without -MigrateSettings'; Setup = {}; Extra = @{}; Message = 'The stick keeps its settings in Launcher\settings.psd1*-MigrateSettings*' }
        @{ Case = 'settings that fail the checks of schema 2'; Setup = { Write-TestFile -Path (Join-Path $script:target 'Launcher\settings.psd1') -Text (Get-TestSettingsText).Replace("'Auto'", "'VBox'") }; Extra = @{ MigrateSettings = $true }; Message = "*do not pass the checks of schema 2, so nothing was changed.*`n- Hypervisor: must be*" }
        @{ Case = 'a name that fails the checks'; Setup = {}; Extra = @{ MigrateSettings = $true; GuestName = ' Test OS' }; Message = "*`n- GuestName: must be 1 to 40 characters of text*" }
        @{ Case = 'a resume when the two settings files differ'; Setup = { Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text).Replace("'Window'", "'FullScreen'") }; Extra = @{ MigrateSettings = $true }; Message = 'Launcher\settings.psd1 and LauncherData\settings.psd1 differ in VMwareView, so nothing was changed. The new launcher reads LauncherData\settings.psd1: make the two files agree, then run the same command again.' }
        @{ Case = 'settings that run code'; Setup = { Write-TestFile -Path (Join-Path $script:target 'Launcher\settings.psd1') -Text '@{ Hypervisor = $(Get-Date) }' }; Extra = @{ MigrateSettings = $true }; Message = 'Launcher\settings.psd1 cannot be read: line 1 holds an expression*' }
        @{ Case = 'LauncherData without settings.psd1'; Setup = { $null = New-Item -ItemType Directory -Path (Join-Path $script:target 'LauncherData') }; Extra = @{ MigrateSettings = $true }; Message = 'LauncherData is there, but without settings.psd1*' }
        @{ Case = 'a resume whose LauncherData settings fail the checks'; Setup = { Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text).Replace("'Auto'", "'VBox'") }; Extra = @{ MigrateSettings = $true }; Message = "LauncherData\settings.psd1 is there from a migration that stopped, and this run keeps it, but it must pass the checks first*`n- Hypervisor: must be*" }
        @{ Case = 'a resume with a name that LauncherData does not hold'; Setup = { Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text -Add "GuestName = 'Test OS'") }; Extra = @{ MigrateSettings = $true; GuestName = 'Other OS' }; Message = '*but its GuestName is not the one given, so nothing was changed. Set VmDisplayName and GuestName in LauncherData\settings.psd1*' }
    ) {
        & $Setup
        $before = Get-TestTree -Root $script:target
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target @Extra } | Should -Throw -ExpectedMessage $Message
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'refuses, changing nothing, while another program holds a file it would move' {
        $before = Get-TestTree -Root $script:target
        $held = [IO.File]::Open((Join-Path $script:target 'VMware\stick.vmdk.orig'), 'Open', 'Read', 'Read')
        try {
            { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } |
                Should -Throw -ExpectedMessage 'A file that the migration moves is open in another program*'
        } finally {
            $held.Dispose()
        }
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'leaves the stick as it was when LauncherData.new cannot become LauncherData' {
        Mock Rename-DeployItem { Rename-Item -LiteralPath $Path -NewName $NewName }
        Mock Rename-DeployItem { throw 'held' } -ParameterFilter { $NewName -eq 'LauncherData' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } |
            Should -Throw -ExpectedMessage 'LauncherData.new could not become LauncherData, and nothing the launcher uses was changed.*'
        Join-Path $script:target 'LauncherData' | Should -Not -Exist
        Join-Path $script:target 'VMware\stick.vmdk.orig' | Should -Exist
        Join-Path $script:target 'Launcher\launcher.log' | Should -Exist
    }

    It 'finishes, when the same command runs again, a migration that stopped while it moved the copies' {
        $script:failMove = $true
        # A mock that calls Move-Item would call itself, so the default one moves with .NET.
        Mock Move-Item { [IO.File]::Move($LiteralPath, $Destination) }
        Mock Move-Item { throw 'held' } -ParameterFilter { $script:failMove -and $Destination -like '*VirtualBox.xml.launcher-backup' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } |
            Should -Throw -ExpectedMessage 'The migration stopped part way, but the launcher in Launcher still works with Launcher\settings.psd1. Run the same command again*'
        Join-Path $script:target 'Launcher\settings.psd1' | Should -Exist
        Join-Path $script:target 'Launcher.new' | Should -Exist

        $script:failMove = $false
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings
        $result.Mode | Should -BeExactly 'Resume'
        $result.Plan.Log | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $script:target 'LauncherData\logs\launcher.log')) | Should -BeExactly "old log line`r`n"
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VirtualBox\VirtualBox.xml.launcher-backup')) | Should -BeExactly '<VirtualBox old="1"/>'
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VMware\stick.vmdk.orig')) | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        @(Get-ChildItem -LiteralPath (Join-Path $script:target 'Launcher') -Name | Sort-Object) | Should -BeExactly @('PortableVM.psm1', 'SHA256SUMS', 'Start-PortableVM.ps1', 'VERSION')
        Join-Path $script:target 'Launcher.new' | Should -Not -Exist
    }

    It 'disarms, when the same command runs again, a copy that was moved but not disarmed, and keeps a copy the old launcher made since' {
        # The state after a stop: LauncherData is in place with a moved copy that is still armed,
        # and the old launcher has made a new copy with the same name beside the VM files.
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $script:legacy 'VMware\stick.vmdk.orig') -Text (Get-TestDescriptorText -Device '\\.\PhysicalDrive7')
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings
        $result.Mode | Should -BeExactly 'Resume'
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VMware\stick.vmdk.orig')) | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VMware\stick (2).vmdk.orig')) | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        [IO.File]::ReadAllText((Join-Path $script:legacy 'Launcher\settings.psd1')) | Should -BeExactly (Get-TestSettingsText)
        Join-Path $script:target 'VMware\stick.vmdk.orig' | Should -Not -Exist
    }

    It 'stops a resume at a copy whose disarm was cut off, naming no path, and changes that copy not' {
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        $copy = Join-Path $script:legacy 'VMware\stick.vmdk.orig'
        Write-TestFile -Path $copy -Text (Get-TestDescriptorText -Device '\\.\PhysicalDrive7')
        Write-TestFile -Path "$copy.pvm-tmp" -Text 'cut off'
        $thrown = try { $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } catch { $_ }
        $thrown.Exception.Message | Should -BeExactly ('The migration stopped part way at a copy below LauncherData\backups\legacy that needs a step by hand, but the launcher in Launcher ' +
            'still works with Launcher\settings.psd1. -Verbose names the copy and the step; take it, then run the same command again. ' +
            'Cause: An earlier write of the file did not finish, and its copy is still beside it (-Verbose shows the details).')
        $thrown.Exception.Message.Contains($script:target) | Should -BeFalse
        [IO.File]::ReadAllText($copy) | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PhysicalDrive7')
        [IO.File]::ReadAllText("$copy.pvm-tmp") | Should -BeExactly 'cut off'
    }

    It 'stops a resume, before it moves anything, at a legacy copy whose disarm stopped between its two renames' {
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        $copy = Join-Path $script:legacy 'VMware\stick.vmdk.orig'
        Write-TestFile -Path "$copy.pvm-old" -Text (Get-TestDescriptorText -Device '\\.\PhysicalDrive1')
        Write-TestFile -Path "$copy.pvm-tmp" -Text (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        # VMware\stick.vmdk.orig beside the VM files stands for a copy the old launcher made since.
        $thrown = try { $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } catch { $_ }
        $thrown.Exception.Message | Should -BeLike 'The migration stopped part way at a copy below LauncherData\backups\legacy that needs a step by hand*'
        $copy | Should -Not -Exist
        Join-Path $script:target 'VMware\stick.vmdk.orig' | Should -Exist
        [IO.File]::ReadAllText("$copy.pvm-old") | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PhysicalDrive1')
    }

    It 'names the step by hand when a disarm stops between its two renames, rather than say to run the same command again' {
        # The module stays as loaded here, so that its mocks hold during the deploy.
        Import-Module (Join-Path $script:clone 'src\PortableVM.psm1') -Force -Global
        Mock Import-DeployModule {}
        Mock -ModuleName PortableVM Switch-PvmFile { [IO.File]::Replace($Temp, $Path, $Old) }
        Mock -ModuleName PortableVM Switch-PvmFile { [IO.File]::Move($Path, $Old); throw [IO.IOException]::new('Unable to move the replacement file.', [int]0x80070499) } -ParameterFilter {
            $Path -like '*\backups\legacy\VMware\stick.vmdk.orig'
        }
        $thrown = try { $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } catch { $_ }
        $thrown.Exception.Message | Should -BeLike 'The migration stopped part way at a copy below LauncherData\backups\legacy that needs a step by hand*'
        Join-Path $script:legacy 'VMware\stick.vmdk.orig.pvm-old' | Should -Exist
    }

    It 'stops a resume at a copy of the old settings whose write did not finish, rather than take it for the copy' {
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $script:legacy 'Launcher\settings.psd1.pvm-tmp') -Text (Get-TestSettingsText)
        $thrown = try { $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } catch { $_ }
        $thrown.Exception.Message | Should -BeLike 'The migration stopped part way at a copy below LauncherData\backups\legacy that needs a step by hand*'
        Join-Path $script:legacy 'Launcher\settings.psd1' | Should -Not -Exist
    }

    It 'stops a resume at a disarmed copy whose armed version is still beside it, and changes neither' {
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        $copy = Join-Path $script:legacy 'VMware\stick.vmdk.orig'
        Write-TestFile -Path $copy -Text (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        Write-TestFile -Path "$copy.pvm-old" -Text (Get-TestDescriptorText -Device '\\.\PhysicalDrive7')
        $thrown = try { $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } catch { $_ }
        $thrown.Exception.Message | Should -BeLike 'The migration stopped part way at a copy below LauncherData\backups\legacy that needs a step by hand*'
        $thrown.Exception.Message.Contains($script:target) | Should -BeFalse
        [IO.File]::ReadAllText($copy) | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        [IO.File]::ReadAllText("$copy.pvm-old") | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PhysicalDrive7')
    }

    It 'stops when the armed version of a copy it disarmed cannot be removed from beside it' {
        # The module stays as loaded here, so that its mocks hold during the deploy.
        Import-Module (Join-Path $script:clone 'src\PortableVM.psm1') -Force -Global
        Mock Import-DeployModule {}
        Mock -ModuleName PortableVM Invoke-PvmSleep {}
        Mock -ModuleName PortableVM Remove-PvmWriteCopy { [IO.File]::Delete($Path) }
        Mock -ModuleName PortableVM Remove-PvmWriteCopy { throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) } -ParameterFilter {
            $Path -like '*\backups\legacy\VMware\stick.vmdk.orig.pvm-old'
        }
        $thrown = try { $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } catch { $_ }
        $thrown.Exception.Message | Should -BeLike ('The migration stopped part way at a copy below LauncherData\backups\legacy that needs a step by hand*' +
            'Cause: A copy was disarmed, but its armed version could not be removed from beside it (-Verbose shows the details).')
        $copy = Join-Path $script:legacy 'VMware\stick.vmdk.orig'
        [IO.File]::ReadAllText($copy) | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        [IO.File]::ReadAllText("$copy.pvm-old") | Should -BeLike '*"\\.\PhysicalDrive1"*'
    }

    It 'keeps LauncherData''s settings and names on a resume and finishes, <Case>' -ForEach @(
        @{ Case = 'with the same name given again'; Extra = @{ GuestName = 'Test OS' } }
        @{ Case = 'without names'; Extra = @{} }
    ) {
        $kept = Get-TestSchema2Text -Add "GuestName = 'Test OS'"
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text $kept
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings @Extra
        $result.Mode | Should -BeExactly 'Resume'
        (Format-DeployReport -Result $result)[1] | Should -BeExactly 'settings: LauncherData\settings.psd1 was kept as it is, with a copy of the old file in LauncherData\backups\legacy\Launcher.'
        [IO.File]::ReadAllText((Join-Path $script:target 'LauncherData\settings.psd1')) | Should -BeExactly $kept
        [IO.File]::ReadAllText((Join-Path $script:legacy 'VMware\stick.vmdk.orig')) | Should -BeExactly (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        @(Get-ChildItem -LiteralPath (Join-Path $script:target 'Launcher') -Name | Sort-Object) | Should -BeExactly @('PortableVM.psm1', 'SHA256SUMS', 'Start-PortableVM.ps1', 'VERSION')
    }

    It 'keeps, on a resume, the log and a settings file that the old launcher changed after the stop, beside the earlier ones' {
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\logs\launcher.log') -Text "old log line`r`n"
        Write-TestFile -Path (Join-Path $script:legacy 'Launcher\settings.psd1') -Text (Get-TestSettingsText)
        Write-TestFile -Path (Join-Path $script:target 'Launcher\launcher.log') -Text "line after the stop`r`n"
        $edited = (Get-TestSettingsText).Replace("# The stick's settings", "# The stick's settings, edited after the stop")
        Write-TestFile -Path (Join-Path $script:target 'Launcher\settings.psd1') -Text $edited
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings
        $result.Mode | Should -BeExactly 'Resume'
        $result.Plan.Log | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $script:target 'LauncherData\logs\launcher.log')) | Should -BeExactly "old log line`r`n"
        [IO.File]::ReadAllText((Join-Path $script:target 'LauncherData\logs\launcher (2).log')) | Should -BeExactly "line after the stop`r`n"
        [IO.File]::ReadAllText((Join-Path $script:legacy 'Launcher\settings.psd1')) | Should -BeExactly (Get-TestSettingsText)
        [IO.File]::ReadAllText((Join-Path $script:legacy 'Launcher\settings (2).psd1')) | Should -BeExactly $edited
        [IO.File]::ReadAllText((Join-Path $script:target 'LauncherData\settings.psd1')) | Should -BeExactly (Get-TestSchema2Text)
        Join-Path $script:target 'Launcher.previous\settings.psd1' | Should -Exist
    }

    It 'keeps comments outside ASCII of a schema 1 file that an editor saved as UTF-8 without a byte order mark' {
        $comment = "# $script:sampleName's stick"
        $text = (Get-TestSettingsText).Replace("# The stick's settings", $comment)
        [IO.File]::WriteAllBytes((Join-Path $script:target 'Launcher\settings.psd1'), (New-Object System.Text.UTF8Encoding $false).GetBytes($text))
        $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings
        $written = [IO.File]::ReadAllBytes((Join-Path $script:target 'LauncherData\settings.psd1'))
        @($written[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        (New-Object System.Text.UTF8Encoding $false).GetString($written, 3, $written.Length - 3) | Should -BeExactly (Get-TestSchema2Text).Replace("# The stick's settings", $comment)
    }

    It 'refuses, changing nothing, a schema 1 file without a byte order mark whose values read differently as UTF-8 and as ANSI' {
        $text = (Get-TestSettingsText).Replace("'VMware\Test VM.vmx'", "'VMware\$script:sampleName.vmx'")
        [IO.File]::WriteAllBytes((Join-Path $script:target 'Launcher\settings.psd1'), (New-Object System.Text.UTF8Encoding $false).GetBytes($text))
        $before = Get-TestTree -Root $script:target
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } |
            Should -Throw -ExpectedMessage 'Launcher\settings.psd1 has no byte order mark, and VMwareVmx read differently as UTF-8*save the file as UTF-8 with BOM or as ANSI*'
        Get-TestTree -Root $script:target | Should -BeExactly $before
    }

    It 'reads a schema 1 file in ANSI as the launcher before LauncherData did' {
        $text = (Get-TestSettingsText).Replace("# The stick's settings", "# $script:sampleName").Replace("'VMware\Test VM.vmx'", "'VMware\$script:sampleName.vmx'")
        [IO.File]::WriteAllBytes((Join-Path $script:target 'Launcher\settings.psd1'), (Get-TestAnsiEncoding).GetBytes($text))
        $null = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings
        (Import-PvmDataFile -Path (Join-Path $script:target 'LauncherData\settings.psd1'))['VMwareVmx'] | Should -BeExactly "VMware\$script:sampleName.vmx"
    }

    It 'refuses to resume with a Launcher.new that is not what this run would stage' {
        Write-TestFile -Path (Join-Path $script:target 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $script:target 'Launcher.new\PortableVM.psm1') -Text '# another module'
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -MigrateSettings } |
            Should -Throw -ExpectedMessage 'Launcher.new is left from an earlier deploy*'
    }
}

Describe 'Get-DeployVmProcess' -Tag 'WindowsOnly' {
    It 'looks for every VMware and VirtualBox VM process' {
        Mock Get-CimInstance {}
        $null = Get-DeployVmProcess
        Should -Invoke -CommandName Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $Filter -ceq "Name LIKE 'vmware-vmx%' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'"
        }
    }
}

Describe 'Get-DeployCause' -Tag 'WindowsOnly' {
    BeforeAll {
        # Get-DeployCause asks the launcher's module for the cause of an error from Windows.
        Import-Module (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Force -Global
        $script:cause = Join-Path $TestDrive "cause\Ann's VM (old)"
        $null = New-Item -ItemType Directory -Path $script:cause -Force
    }

    It 'passes on a message this tool wrote' {
        $record = try { throw 'The copy of PortableVM.psm1 does not match the clone.' } catch { $_ }
        Get-DeployCause -ErrorRecord $record | Should -BeExactly 'The copy of PortableVM.psm1 does not match the clone.'
    }

    It 'gives the cause of an error from Windows without its path: <Case>' -ForEach @(
        @{ Case = 'a file open in another program'; Cause = 'it is open in another program' }
        @{ Case = 'a missing file'; Cause = 'it is missing' }
        @{ Case = 'a move onto an existing file'; Cause = 'an item of that name exists already' }
    ) {
        $file = Join-Path $script:cause 'stick.vmdk.orig'
        Set-Content -LiteralPath $file -Value 'x'
        $record = switch ($Case) {
            'a file open in another program' {
                $held = [IO.File]::Open($file, 'Open', 'Read', 'None')
                try { try { $null = [IO.File]::ReadAllBytes($file) } catch { $_ } } finally { $held.Dispose() }
            }
            'a missing file' { try { $null = [IO.File]::ReadAllBytes((Join-Path $script:cause 'none.vmdk')) } catch { $_ } }
            'a move onto an existing file' {
                Set-Content -LiteralPath "$file.2" -Value 'y'
                try { Move-Item -LiteralPath "$file.2" -Destination $file -ErrorAction Stop } catch { $_ }
            }
        }
        $text = Get-DeployCause -ErrorRecord $record
        $text | Should -BeExactly "$Cause (-Verbose shows the details)"
        $text | Should -Not -Match 'Ann'
    }

    It 'passes on a message of the module and sends the message from Windows behind it to -Verbose' {
        $exception = [Management.Automation.RuntimeException]::new('it is open in another program')
        $exception.Data['PvmDetail'] = "The process cannot access the file 'X:\Ann's VM\settings.psd1'."
        $record = try { throw $exception } catch { $_ }
        $output = @(Get-DeployCause -ErrorRecord $record -Verbose 4>&1)
        @($output | Where-Object { $_ -is [string] }) | Should -BeExactly @('it is open in another program (-Verbose shows the details)')
        @($output | Where-Object { $_ -is [Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message }) |
            Should -BeExactly @("The process cannot access the file 'X:\Ann's VM\settings.psd1'.")
        # A stop's message ends with a full stop, which stays at the end.
        Get-DeployOwnMessage -ErrorRecord $record -Message 'LauncherData\settings.psd1 cannot be read: it is open in another program.' |
            Should -BeExactly 'LauncherData\settings.psd1 cannot be read: it is open in another program (-Verbose shows the details).'
    }

    It 'ends a message with the cause as a sentence of its own' {
        $record = try { throw 'in use' } catch { $_ }
        Format-DeployCause -ErrorRecord $record | Should -BeExactly 'Cause: in use.'
        $record = try { throw 'The copy of PortableVM.psm1 does not match the clone.' } catch { $_ }
        Format-DeployCause -ErrorRecord $record | Should -BeExactly 'Cause: The copy of PortableVM.psm1 does not match the clone.'
        $record = try { $null = [IO.File]::ReadAllBytes((Join-Path $script:cause 'none.vmdk')) } catch { $_ }
        Format-DeployCause -ErrorRecord $record | Should -BeExactly 'Cause: it is missing (-Verbose shows the details).'
    }
}

Describe 'Rename-DeployItem' -Tag 'WindowsOnly' {
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Force -Global
    }

    BeforeEach {
        $script:folder = Join-Path $TestDrive "rename\Ann's VM [3]"
        Remove-Item -LiteralPath (Join-Path $TestDrive 'rename') -Recurse -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Path (Join-Path $script:folder 'Launcher')
        Set-Content -LiteralPath (Join-Path $script:folder 'Launcher\a.ps1') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:folder 'Start VM.cmd.new') -Value 'x'
    }

    It 'renames a folder and a file whose paths hold brackets and an apostrophe, also given a relative path' {
        # Should -Exist would read the brackets as a wildcard.
        Rename-DeployItem -Path (Join-Path $script:folder 'Launcher') -NewName 'Launcher.previous'
        Test-Path -LiteralPath (Join-Path $script:folder 'Launcher.previous\a.ps1') | Should -BeTrue
        Push-Location -LiteralPath $script:folder
        try { Rename-DeployItem -Path 'Start VM.cmd.new' -NewName 'Start VM.cmd' }
        finally { Pop-Location }
        Test-Path -LiteralPath (Join-Path $script:folder 'Start VM.cmd') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:folder 'Start VM.cmd.new') | Should -BeFalse
    }

    It 'fails with an error whose cause Get-DeployCause names, without the path, when <Case>' -ForEach @(
        @{ Case = 'a program holds a file in the folder'; Cause = 'access is denied' }
        @{ Case = 'a program holds the file'; Cause = 'it is open in another program' }
        @{ Case = 'the item is missing'; Cause = 'it is missing' }
        @{ Case = 'the new name is taken'; Cause = 'an item of that name exists already' }
    ) {
        $launcher = Join-Path $script:folder 'Launcher'
        $record = switch ($Case) {
            'a program holds a file in the folder' {
                $held = [IO.File]::Open((Join-Path $launcher 'a.ps1'), 'Open', 'Read', 'Read')
                try { try { Rename-DeployItem -Path $launcher -NewName 'Launcher.previous' } catch { $_ } } finally { $held.Dispose() }
            }
            'a program holds the file' {
                $file = Join-Path $script:folder 'Start VM.cmd.new'
                $held = [IO.File]::Open($file, 'Open', 'Read', 'None')
                try { try { Rename-DeployItem -Path $file -NewName 'Start VM.cmd' } catch { $_ } } finally { $held.Dispose() }
            }
            'the item is missing' { try { Rename-DeployItem -Path (Join-Path $script:folder 'none') -NewName 'Launcher.previous' } catch { $_ } }
            'the new name is taken' {
                $null = New-Item -ItemType Directory -Path (Join-Path $script:folder 'Launcher.previous')
                try { Rename-DeployItem -Path $launcher -NewName 'Launcher.previous' } catch { $_ }
            }
        }
        $text = Get-DeployCause -ErrorRecord $record
        $text | Should -BeExactly "$Cause (-Verbose shows the details)"
        $text | Should -Not -Match 'Ann'
    }

    It 'gives the cause from Windows, not a missing item, when Windows cannot read the attributes of the <Kind>' -ForEach @(
        @{ Kind = 'folder'; Name = 'Launcher' }
        @{ Kind = 'file'; Name = 'Start VM.cmd.new' }
    ) {
        $item = Join-Path $script:folder $Name
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # Without the item's attributes and the folder's list, Directory.Exists and File.Exists
        # answer false although the item is there.
        $null = & icacls.exe $item /deny "*${sid}:(RA)"
        $null = & icacls.exe $script:folder /deny "*${sid}:(RD)"
        try {
            ([IO.Directory]::Exists($item) -or [IO.File]::Exists($item)) | Should -BeFalse
            $record = try { Rename-DeployItem -Path $item -NewName 'renamed' } catch { $_ }
        } finally {
            $null = & icacls.exe $script:folder /reset /Q
            $null = & icacls.exe $item /reset /Q
        }
        Get-DeployCause -ErrorRecord $record | Should -BeExactly 'access is denied (-Verbose shows the details)'
        Test-Path -LiteralPath $item | Should -BeTrue
    }
}

Describe 'Get-DeployVersion' -Tag 'WindowsOnly' {
    It 'calls a folder that is no git clone version unknown' {
        $folder = Join-Path $TestDrive 'not-a-clone'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Get-DeployVersion -RepositoryPath $folder | Should -BeExactly 'unknown'
    }

    It 'reads the version of this clone' {
        Get-DeployVersion -RepositoryPath $script:repoRoot | Should -Not -BeExactly 'unknown'
    }
}

Describe 'Get-StickInventory' -Tag 'WindowsOnly' {
    BeforeAll {
        # The stick is disk 3: a guest partition, then the Data partition.
        Mock Get-InventoryPartition { [pscustomobject]@{ DiskNumber = 3; Offset = [uint64]2500000 * 512; Size = [uint64]1400000 * 512; DriveLetter = [char]'Q' } }
        Mock Get-InventoryDisk {
            [pscustomobject]@{ Number = 3; PartitionStyle = 'MBR'; Signature = [uint32]0x5CA1AB1E; LogicalSectorSize = 512; Size = [uint64]4000000 * 512; IsBoot = $false; IsSystem = $false }
        }
        Mock Get-InventoryDiskPartition {
            [pscustomobject]@{ DiskNumber = 3; Offset = [uint64]2048 * 512; Size = [uint64]2400000 * 512; DriveLetter = [char]0 }
            [pscustomobject]@{ DiskNumber = 3; Offset = [uint64]2500000 * 512; Size = [uint64]1400000 * 512; DriveLetter = [char]'Q' }
        }
        Mock Get-InventoryVolume { $null }
        Mock Get-InventoryRegistryValue { $null }
        $vmx = @('.encoding = "windows-1252"', 'displayName = "Test VM"', 'suspend.disabled = "FALSE"', 'suspend.disabled = "TRUE"',
            'uuid.action = "keep"', 'scsi0.present = "TRUE"', 'scsi0:0.present = "TRUE"', 'scsi0:0.fileName = "stick.vmdk"')
        $script:clean = Initialize-InventoryStick -Name 'clean-stick' -Vmx $vmx -Vbox (Get-TestVboxText -Body (Get-TestVboxBody)) -Registry (Get-TestRegistryText)
        $script:answers = Get-TestAnswer -Root $script:clean
    }

    It 'answers "<Name>" with <Answer> for a clean stick' -ForEach @(
        @{ Name = 'settings file read'; Answer = $true }
        @{ Name = 'LauncherData folder found'; Answer = $false }
        @{ Name = 'settings file has SchemaVersion 2'; Answer = $false }
        @{ Name = 'Launcher folder holds a settings file'; Answer = $true }
        @{ Name = 'LauncherData log found'; Answer = $false }
        @{ Name = 'LauncherData backups hold legacy copies'; Answer = $false }
        @{ Name = 'a legacy descriptor copy names a raw device'; Answer = $false }
        @{ Name = 'stick disk found from the drive letter'; Answer = $true }
        @{ Name = 'stick is MBR'; Answer = $true }
        @{ Name = 'stick signature matches StickMbrSignature'; Answer = $true }
        @{ Name = 'stick has 512-byte sectors'; Answer = $true }
        @{ Name = 'stick size matches StickSectors'; Answer = $true }
        @{ Name = 'Data partition starts at DataPartitionStart'; Answer = $true }
        @{ Name = 'Data partition ends at VmSectors'; Answer = $true }
        @{ Name = "stick is not this PC's boot or system disk"; Answer = $true }
        @{ Name = 'a partition before Data has a drive letter'; Answer = $false }
        @{ Name = 'a partition before Data has a Windows file system'; Answer = $false }
        @{ Name = 'VMware .vmx found'; Answer = $true }
        @{ Name = 'VMware .vmx has a suspended state'; Answer = $false }
        @{ Name = 'VMware .vmx has suspend.disabled = "TRUE"'; Answer = $true }
        @{ Name = 'VMware .vmx has uuid.action = "keep"'; Answer = $true }
        @{ Name = 'VMware .vmx has mainMem.useNamedFile = "FALSE"'; Answer = $false }
        @{ Name = 'VMware .vmx attaches the VMwareDisk descriptor'; Answer = $true }
        @{ Name = 'VMware folder has a .lck lock folder'; Answer = $false }
        @{ Name = 'VMware descriptor found'; Answer = $true }
        @{ Name = 'VMware descriptor names a PhysicalDrive'; Answer = $true }
        @{ Name = 'VMware descriptor has createType fullDevice'; Answer = $true }
        @{ Name = 'VMware folder has another descriptor that names a PhysicalDrive'; Answer = $false }
        @{ Name = 'VMware folder has a -pt.vmdk file'; Answer = $false }
        @{ Name = 'VMware descriptor has a .orig copy'; Answer = $false }
        @{ Name = 'VirtualBox .vbox found'; Answer = $true }
        @{ Name = 'VirtualBox .vbox parses as XML'; Answer = $true }
        @{ Name = 'VirtualBox .vbox has a saved state'; Answer = $false }
        @{ Name = 'VirtualBox .vbox attaches the VirtualBoxDisk descriptor'; Answer = $true }
        @{ Name = "VirtualBox host I/O cache is on for the descriptor's controller"; Answer = $true }
        @{ Name = 'VirtualBox descriptor has a bandwidth group'; Answer = $false }
        @{ Name = 'VirtualBox .vbox holds paths with a drive letter'; Answer = $false }
        @{ Name = 'VirtualBox.xml found'; Answer = $true }
        @{ Name = 'VirtualBox.xml parses as XML'; Answer = $true }
        @{ Name = 'VirtualBox.xml lists the VM'; Answer = $true }
        @{ Name = "VirtualBox.xml lists the VM's .vbox with a drive letter"; Answer = $true }
        @{ Name = 'VirtualBox descriptor found'; Answer = $true }
        @{ Name = 'VirtualBox descriptor has a .orig copy'; Answer = $false }
        @{ Name = 'VirtualBox files have .launcher-backup copies'; Answer = $false }
        @{ Name = 'VMware Workstation installed'; Answer = $false }
        @{ Name = 'VirtualBox installed'; Answer = $false }
    ) {
        $script:answers.ContainsKey($Name) | Should -BeTrue
        $script:answers[$Name] | Should -Be $Answer
    }

    It 'answers "<Name>" with <Answer> for a stick that has it' -ForEach @(
        @{ Name = 'a partition before Data has a drive letter'; Answer = $true }
        @{ Name = 'a partition before Data has a Windows file system'; Answer = $true }
        @{ Name = 'VMware .vmx has a suspended state'; Answer = $true }
        @{ Name = 'VMware .vmx has mainMem.useNamedFile = "FALSE"'; Answer = $true }
        @{ Name = 'VMware folder has a .lck lock folder'; Answer = $true }
        @{ Name = 'VMware folder has another descriptor that names a PhysicalDrive'; Answer = $true }
        @{ Name = 'VMware folder has a -pt.vmdk file'; Answer = $true }
        @{ Name = 'VMware descriptor has a .orig copy'; Answer = $true }
        @{ Name = 'VirtualBox .vbox has a saved state'; Answer = $true }
        @{ Name = "VirtualBox host I/O cache is on for the descriptor's controller"; Answer = $false }
        @{ Name = 'VirtualBox descriptor has a bandwidth group'; Answer = $true }
        @{ Name = 'VirtualBox .vbox holds paths with a drive letter'; Answer = $true }
        @{ Name = 'VirtualBox descriptor has a .orig copy'; Answer = $true }
        @{ Name = 'VirtualBox files have .launcher-backup copies'; Answer = $true }
        @{ Name = 'VMware Workstation installed'; Answer = $true }
        @{ Name = 'VirtualBox installed'; Answer = $true }
    ) {
        $vmx = @('checkpoint.vmState = "Test VM.vmss"', 'mainMem.useNamedFile = "FALSE"', 'scsi0:0.present = "TRUE"', 'scsi0:0.fileName = "stick.vmdk"')
        $vbox = Get-TestVboxText -Machine ' stateFile="Snapshots\x.sav" snapshotFolder="Q:\Snapshots"' -Body (Get-TestVboxBody -Cache 'false' -Device ' bandwidthGroup="Limit"')
        $root = Initialize-InventoryStick -Name 'flagged-stick' -Vmx $vmx -Vbox $vbox -Registry (Get-TestRegistryText)
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'VMware\Test VM.vmx.lck') -Force
        Write-TestFile -Path (Join-Path $root 'VMware\old.vmdk') -Text 'RW 9 FLAT "\\.\PhysicalDrive1" 0'
        Write-TestFile -Path (Join-Path $root 'VMware\stick-pt.vmdk') -Text 'partition table'
        Write-TestFile -Path (Join-Path $root 'VMware\stick.vmdk.orig') -Text 'old'
        Write-TestFile -Path (Join-Path $root 'VirtualBox\Test VM\stick.vmdk.orig') -Text 'old'
        Write-TestFile -Path (Join-Path $root 'VirtualBox\VirtualBox.xml.launcher-backup') -Text 'old'
        Write-TestFile -Path (Join-Path $root 'Programs\vmware.exe') -Text ''
        Write-TestFile -Path (Join-Path $root 'Programs\VBoxManage.exe') -Text ''
        Mock Get-InventoryDiskPartition {
            [pscustomobject]@{ DiskNumber = 3; Offset = [uint64]2048 * 512; Size = [uint64]2400000 * 512; DriveLetter = [char]'F' }
            [pscustomobject]@{ DiskNumber = 3; Offset = [uint64]2500000 * 512; Size = [uint64]1400000 * 512; DriveLetter = [char]'Q' }
        }
        Mock Get-InventoryVolume { [pscustomobject]@{ FileSystem = 'NTFS' } }
        Mock Get-InventoryRegistryValue { Join-Path $TestDrive 'flagged-stick\Programs' }
        (Get-TestAnswer -Root $root)[$Name] | Should -Be $Answer
    }

    It 'reads the settings from LauncherData, else from Launcher' {
        $root = Join-Path $TestDrive 'settings-stick'
        Get-InventorySettingsPath -Root $root | Should -BeExactly (Join-Path $root 'LauncherData\settings.psd1')
        Write-TestFile -Path (Join-Path $root 'Launcher\settings.psd1') -Text (Get-TestSettingsText)
        Get-InventorySettingsPath -Root $root | Should -BeExactly (Join-Path $root 'Launcher\settings.psd1')
        Write-TestFile -Path (Join-Path $root 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Get-InventorySettingsPath -Root $root | Should -BeExactly (Join-Path $root 'LauncherData\settings.psd1')
    }

    It 'answers the LauncherData checks for a migrated stick, and finds a legacy copy that still names a raw device' {
        $root = Initialize-InventoryStick -Name 'migrated-stick' -Vmx @() -Vbox (Get-TestVboxText -Body (Get-TestVboxBody)) -Registry (Get-TestRegistryText)
        Remove-Item -LiteralPath (Join-Path $root 'Launcher\settings.psd1')
        Write-TestFile -Path (Join-Path $root 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $root 'LauncherData\logs\launcher.log') -Text "a line`r`n"
        Write-TestFile -Path (Join-Path $root 'LauncherData\backups\legacy\VMware\stick.vmdk.orig') -Text (Get-TestDescriptorText -Device '\\.\PortableVM-disarmed')
        Write-TestFile -Path (Join-Path $root 'LauncherData\backups\legacy\VirtualBox\VirtualBox.xml.launcher-backup') -Text '<VirtualBox/>'
        $answers = Get-TestAnswer -Root $root -SettingsPath (Get-InventorySettingsPath -Root $root)
        $answers['settings file read'] | Should -BeTrue
        $answers['LauncherData folder found'] | Should -BeTrue
        $answers['settings file has SchemaVersion 2'] | Should -BeTrue
        $answers['Launcher folder holds a settings file'] | Should -BeFalse
        $answers['LauncherData log found'] | Should -BeTrue
        $answers['LauncherData backups hold legacy copies'] | Should -BeTrue
        $answers['a legacy descriptor copy names a raw device'] | Should -BeFalse
        Write-TestFile -Path (Join-Path $root 'LauncherData\backups\legacy\VirtualBox\Test VM\stick.vmdk.orig') -Text (Get-TestDescriptorText -Device '\\?\PhysicalDrive2')
        (Get-TestAnswer -Root $root -SettingsPath (Get-InventorySettingsPath -Root $root))['a legacy descriptor copy names a raw device'] | Should -BeTrue
    }

    It 'counts a disk entry as attached only when it is switched on' {
        $vbox = Get-TestVboxText -Body (Get-TestVboxBody)
        $off = Initialize-InventoryStick -Name 'off-stick' -Vmx @('scsi0:0.present = "FALSE"', 'scsi0:0.fileName = "stick.vmdk"') -Vbox $vbox -Registry (Get-TestRegistryText)
        (Get-TestAnswer -Root $off)['VMware .vmx attaches the VMwareDisk descriptor'] | Should -BeFalse
        $controllerOff = Initialize-InventoryStick -Name 'controller-off-stick' -Vmx @('scsi0.present = "FALSE"', 'scsi0:0.present = "TRUE"', 'scsi0:0.fileName = "stick.vmdk"') -Vbox $vbox -Registry (Get-TestRegistryText)
        (Get-TestAnswer -Root $controllerOff)['VMware .vmx attaches the VMwareDisk descriptor'] | Should -BeFalse
        $unsaid = Initialize-InventoryStick -Name 'unsaid-stick' -Vmx @('scsi0:0.fileName = "stick.vmdk"') -Vbox $vbox -Registry (Get-TestRegistryText)
        (Get-TestAnswer -Root $unsaid)['VMware .vmx attaches the VMwareDisk descriptor'] | Should -BeNullOrEmpty
    }

    It 'reads the VirtualBox attachment from the current state, not from a snapshot' {
        $snapshot = "<Snapshot uuid=`"{5ca1ab1e-0000-4000-8000-000000000003}`" name=`"x`">$(Get-TestVboxBody -Registered $false)</Snapshot>"
        $body = '    <MediaRegistry><HardDisks><HardDisk uuid="{5ca1ab1e-0000-4000-8000-000000000002}" location="stick.vmdk" format="VMDK"/></HardDisks></MediaRegistry>' + $snapshot
        $root = Initialize-InventoryStick -Name 'snapshot-stick' -Vmx @() -Vbox (Get-TestVboxText -Body $body) -Registry (Get-TestRegistryText)
        $answers = Get-TestAnswer -Root $root
        $answers['VirtualBox .vbox attaches the VirtualBoxDisk descriptor'] | Should -BeFalse
        $answers["VirtualBox host I/O cache is on for the descriptor's controller"] | Should -BeNullOrEmpty
    }

    It 'finds a descriptor registered in the global media registry of VirtualBox.xml' {
        $media = '<MediaRegistry><HardDisks><HardDisk uuid="{5ca1ab1e-0000-4000-8000-000000000002}" location="Test VM\stick.vmdk" format="VMDK"/></HardDisks></MediaRegistry>'
        $root = Initialize-InventoryStick -Name 'global-stick' -Vmx @() -Vbox (Get-TestVboxText -Body (Get-TestVboxBody -Registered $false)) -Registry (Get-TestRegistryText -Media $media)
        (Get-TestAnswer -Root $root)['VirtualBox .vbox attaches the VirtualBoxDisk descriptor'] | Should -BeTrue
    }

    It 'skips a medium location that is no file path and carries on' {
        $body = '    <MediaRegistry><HardDisks><HardDisk uuid="{5ca1ab1e-0000-4000-8000-000000000004}" location="host|target" format="iSCSI"/>' +
        '<HardDisk uuid="{5ca1ab1e-0000-4000-8000-000000000002}" location="stick.vmdk" format="VMDK"/></HardDisks></MediaRegistry>' + (Get-TestVboxBody -Registered $false)
        $root = Initialize-InventoryStick -Name 'iscsi-stick' -Vmx @() -Vbox (Get-TestVboxText -Body $body) -Registry (Get-TestRegistryText)
        $answers = Get-TestAnswer -Root $root
        $answers['VirtualBox .vbox attaches the VirtualBoxDisk descriptor'] | Should -BeTrue
        $answers.ContainsKey('VirtualBox installed') | Should -BeTrue
    }

    It 'reports only names and yes, no or unknown, never a value from the stick' {
        $lines = @(Get-StickInventory -Root $script:clean -SettingsPath (Join-Path $script:clean 'Launcher\settings.psd1') | ForEach-Object { Format-InventoryLine -Check $_ })
        $lines.Count | Should -BeGreaterThan 30
        $lines | Where-Object { $_ -notmatch '^Get-StickInventory: [^:]+: (yes|no|unknown)$' } | Should -BeNullOrEmpty
        $text = $lines -join "`n"
        foreach ($value in '5CA1AB1E', '5ca1ab1e', 'Test VM', 'stick.vmdk', $script:clean) { $text.Contains($value) | Should -BeFalse }
    }

    It 'answers no for a drive letter that no partition has, and unknown for what it cannot read' {
        Mock Get-InventoryPartition { Write-Error -Message 'No partition has that drive letter.' -Category ObjectNotFound -ErrorAction Stop }
        $answers = Get-TestAnswer -Root (Join-Path $TestDrive 'no-such-stick') -SettingsPath (Join-Path $TestDrive 'missing.psd1')
        $answers['settings file read'] | Should -BeFalse
        $answers['stick disk found from the drive letter'] | Should -BeFalse
        $answers['stick is MBR'] | Should -BeNullOrEmpty
        $answers['VMware .vmx found'] | Should -BeNullOrEmpty
        $answers['VirtualBox .vbox found'] | Should -BeNullOrEmpty

        Mock Get-InventoryPartition { throw 'The storage service is not available.' }
        (Get-TestAnswer -Root $script:clean)['stick disk found from the drive letter'] | Should -BeNullOrEmpty
    }
}

Describe 'Compare-StickDryRun: kinds of log lines' {
    It 'calls <Message> "<Kind>"' -ForEach @(
        @{ Message = '----- Start VM (dry run) -----'; Kind = 'start line (dry run)' }
        @{ Message = '----- Start VM -----'; Kind = 'start line' }
        @{ Message = '----- End (dry run): exit code 0 -----'; Kind = 'end line (dry run), exit code 0' }
        @{ Message = '----- End: exit code 1 -----'; Kind = 'end line, exit code 1' }
        @{ Message = 'Launcher version v2'; Kind = 'version line: this clone' }
        @{ Message = 'Launcher version v1'; Kind = 'version line: another version' }
        @{ Message = 'Timings: setup 4 ms, total 9 ms'; Kind = 'timings line' }
        @{ Message = 'Note: the earlier lines of the log are in launcher-20260102-030405.log.'; Kind = 'note: the earlier lines were moved aside' }
        @{ Message = 'Note: the log could not be moved aside, because access is denied; this run adds to it.'; Kind = 'note: the log could not be moved aside' }
        @{ Message = 'Note: an earlier run of the launcher ended without releasing its lock; this run took the lock over.'; Kind = 'note: lock taken over' }
        @{ Message = 'Note: Memory Integrity is on, so the VM runs on top of Hyper-V (slower than native).'; Kind = 'note: Memory Integrity' }
        @{ Message = 'Waiting up to 30 s for VirtualBox''s background service (VBoxSVC) to end'; Kind = 'waiting for VBoxSVC' }
        @{ Message = 'Stick found: disk 3 (\\.\PhysicalDrive3), drive Q:, ID 5CA1AB1E'; Kind = 'stick found' }
        @{ Message = 'Saved state found: suspended in VMware'; Kind = 'saved state found: suspended in VMware' }
        @{ Message = 'Using VirtualBox'; Kind = 'using VirtualBox' }
        @{ Message = 'Already running in VMware.'; Kind = 'already running in VMware' }
        @{ Message = 'VirtualBox VM state: poweroff'; Kind = 'VirtualBox VM state: poweroff' }
        @{ Message = 'stick.vmdk already points at the stick'; Kind = 'descriptor already points at the stick' }
        @{ Message = 'stick.vmdk -> RW 2500000 FLAT "\\.\PhysicalDrive3" 0 | RW 1400000 ZERO'; Kind = 'descriptor would be pointed at the stick' }
        @{ Message = 'Creating stick.vmdk -> RW 2500000 FLAT "\\.\PhysicalDrive3" 0'; Kind = 'descriptor would be created' }
        @{ Message = 'Test VM.vbox: drive letter OK'; Kind = 'the .vbox file: drive letter OK' }
        @{ Message = 'VirtualBox.xml: paths moved to drive Q:'; Kind = 'VirtualBox.xml: paths would move to the drive letter' }
        @{ Message = 'DRY RUN - would start Q:\VMware\Test VM.vmx with VMware Workstation (Q:\Programs\VMware)'; Kind = 'would start with VMware Workstation' }
        @{ Message = 'DRY RUN - a real start would ask whether to resume the saved state in VMware.'; Kind = 'a real start would ask whether to resume' }
        @{ Message = 'Started with VirtualBox 7.1.4r165100'; Kind = 'started with VirtualBox' }
    ) {
        Get-CompareKind -Message $Message -Version 'v2' | Should -BeExactly $Kind
    }

    It 'shows no text of an unknown line, a stop, an error line or a would-stop' {
        foreach ($message in @('Hello Kelda from the guest', 'STOPPED: the disk Kelda-7 is not the stick', 'Error detail: System.IO.IOException: Kelda',
                'DRY RUN - a real start would stop here: Kelda is gone', 'VirtualBox VM state: "Kelda is running"', 'Launcher version Kelda')) {
            Get-CompareKind -Message $message | Should -Not -Match 'Kelda'
        }
        Get-CompareKind -Message 'Hello Kelda' | Should -BeExactly 'other line'
        Get-CompareKind -Message 'STOPPED: Kelda' | Should -BeExactly 'STOPPED line'
    }

    It 'reads the message after the first two spaces, and keeps only the lines two launchers must log alike' {
        Get-CompareLogMessage -Line '2026-01-02T03:04:05.678+01:00 [42]  Using VMware' | Should -BeExactly 'Using VMware'
        $lines = @('Launcher version v1', 'Using VMware', 'Waiting up to 30 s for VBoxSVC', 'Timings: total 3 ms', 'Note: the earlier lines of the log are in launcher-20260102-030405.log.', 'Stick found: x') |
            ForEach-Object { "2026-01-02T03:04:05.678+01:00 [42]  $_" }
        Get-CompareDecision -Lines $lines | Should -BeExactly @('Using VMware', 'Stick found: x')
    }
}

Describe 'Compare-StickDryRun: the comparison of two dry runs' {
    BeforeAll {
        # Return the messages $Messages as log lines.
        function ConvertTo-TestLogLine {
            param([string[]]$Messages)
            @($Messages | ForEach-Object { "2026-01-02T03:04:05.678+01:00 [42]  $_" })
        }

        # Return one pair named $Name with the messages $Before and $After and the exit codes.
        function Get-TestPair {
            param([string[]]$Before, [string[]]$After, [int]$BeforeExit = 0, [int]$AfterExit = 0, [string]$Name = 'as configured')
            [pscustomobject]@{ Name = $Name; Before = ConvertTo-TestLogLine $Before; After = ConvertTo-TestLogLine $After; BeforeExit = $BeforeExit; AfterExit = $AfterExit }
        }

        # Return the expectations $Text as the tool reads them.
        function Get-TestExpected {
            param([string[]]$Text)
            @($Text | ForEach-Object { ConvertFrom-CompareExpectation -Text $_ })
        }

        $script:run = @('----- Start VM (dry run) -----', 'Launcher version v1', 'Stick found: disk 3, ID 5CA1AB1E', 'Using VMware', 'stick.vmdk already points at the stick',
            'DRY RUN - would start x.vmx with VMware Workstation (y)', 'Timings: total 3 ms', '----- End (dry run): exit code 0 -----')
    }

    It 'passes runs that differ only in the version, Timings and a wait line' {
        $after = @($script:run[0], 'Launcher version v2') + $script:run[2..5] + @('Waiting up to 30 s for x', 'Timings: total 9 ms', $script:run[7])
        $result = Test-CompareChange -Pairs @(Get-TestPair -Before $script:run -After $after) -Version 'v2'
        $result.Problems | Should -BeNullOrEmpty
        $result.Lines | Should -Contain '  as configured: lines that differ, apart from the version, Timings and a wait line: 0 of 6/6; exit codes 0 and 0'
    }

    It 'fails on a changed, a missing and an extra line, and names only their kinds' -ForEach @(
        @{ Case = 'changed'; Edit = { param($r) $r[2] = 'Stick found: disk 4, ID 5CA1AB1E'; $r }; Kinds = 'stick found => stick found' }
        @{ Case = 'missing'; Edit = { param($r) @($r | Where-Object { $_ -ne 'Using VMware' }) }; Kinds = 'using VMware =>' }
        @{ Case = 'extra'; Edit = { param($r) @($r[0..3]) + @('Note: Memory Integrity is on.') + @($r[4..7]) }; Kinds = '=> note: Memory Integrity' }
    ) {
        $after = & $Edit @($script:run)
        $result = Test-CompareChange -Pairs @(Get-TestPair -Before $script:run -After $after)
        $result.Problems | Should -BeExactly @('the dry runs (as configured) differ in 1 line(s) that no -ExpectChange names')
        $result.Lines | Should -Contain "  as configured: unexpected change: '$Kinds'"
        ($result.Lines -join "`n") | Should -Not -Match '5CA1AB1E|disk 4'
    }

    It 'aligns the lines around an added one, so the lines after it do not count as changed' {
        $after = @($script:run[0..2]) + @('Note: Memory Integrity is on.') + @($script:run[3..7])
        @(Get-CompareDifference -Before (Get-CompareDecision -Lines (ConvertTo-TestLogLine $script:run)) -After (Get-CompareDecision -Lines (ConvertTo-TestLogLine $after))).Count | Should -Be 1
    }

    It 'passes an expected change on that one line, and fails it when it happens twice in one pair' {
        $after = @($script:run)
        $after[4] = 'stick.vmdk -> RW 2500000 FLAT "\\.\PhysicalDrive3" 0'
        $expected = Get-TestExpected 'descriptor already points at the stick => descriptor would be pointed at the stick'
        $result = Test-CompareChange -Pairs @(Get-TestPair -Before $script:run -After $after) -Expected $expected
        $result.Problems | Should -BeNullOrEmpty
        $result.Lines | Should -Contain "  as configured: expected change: 'descriptor already points at the stick => descriptor would be pointed at the stick'"

        $twice = @($script:run[0..4]) + @('other.vmdk already points at the stick') + @($script:run[5..7])
        $twiceAfter = @($after[0..4]) + @('other.vmdk -> RW 1 FLAT "x" 0') + @($after[5..7])
        (Test-CompareChange -Pairs @(Get-TestPair -Before $twice -After $twiceAfter) -Expected $expected).Problems |
            Should -BeExactly @('the dry runs (as configured) differ in 1 line(s) that no -ExpectChange names')
    }

    It 'lets an expectation match once in each pair, and fails one that did not happen' {
        $after = @($script:run)
        $after[4] = 'stick.vmdk -> RW 1 FLAT "x" 0'
        $expected = Get-TestExpected 'descriptor already points at the stick => descriptor would be pointed at the stick', '=> note: Memory Integrity'
        $pairs = @((Get-TestPair -Before $script:run -After $after), (Get-TestPair -Before $script:run -After $after -Name 'VirtualBox'))
        (Test-CompareChange -Pairs $pairs -Expected $expected).Problems | Should -BeExactly @("the expected change '=> note: Memory Integrity' did not happen")
    }

    It 'fails runs whose exit codes differ' {
        (Test-CompareChange -Pairs @(Get-TestPair -Before $script:run -After $script:run -AfterExit 1)).Problems | Should -BeExactly @('the dry runs (as configured) ended with different exit codes')
    }

    It 'reads an expectation for a changed, an added and a removed line, and refuses any other form' {
        (ConvertFrom-CompareExpectation -Text 'stick found => stick found').Text | Should -BeExactly 'stick found => stick found'
        $added = ConvertFrom-CompareExpectation -Text '=> note: Memory Integrity'
        $added.Before | Should -BeExactly ''
        $added.Text | Should -BeExactly '=> note: Memory Integrity'
        (ConvertFrom-CompareExpectation -Text 'using VMware =>').Text | Should -BeExactly 'using VMware =>'
        foreach ($bad in @('stick found', ' => ', 'a => b => c', '')) {
            { ConvertFrom-CompareExpectation -Text $bad } | Should -Throw '*is not of the form*'
        }
    }
}

Describe 'Compare-StickDryRun: files and the listing' -Tag 'WindowsOnly' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive 'files'
        Remove-Item -LiteralPath $script:folder -Recurse -Force -ErrorAction SilentlyContinue
        Write-TestFile -Path (Join-Path $script:folder 'Launcher\Start-PortableVM.ps1') -Text '# script'
        Write-TestFile -Path (Join-Path $script:folder 'Launcher\VERSION') -Text "v1`n"
        Write-TestFile -Path (Join-Path $script:folder 'LauncherData\logs\launcher.log') -Text 'line'
        Write-TestFile -Path (Join-Path $script:folder 'VMware\Test VM.vmx') -Text 'displayName = "Test VM"'
        Write-TestFile -Path (Join-Path $script:folder 'Private Name\diary.txt') -Text 'mine'
        Write-TestFile -Path (Join-Path $script:folder 'Launcher.before-v0\Start-PortableVM.ps1') -Text '# old'
        Write-TestFile -Path (Join-Path $script:folder 'System Volume Information\tracking.log') -Text 'windows'
        Write-TestFile -Path (Join-Path $script:folder 'Start VM.cmd') -Text "start `"`" -File `"%~dp0Launcher\Start-PortableVM.ps1`"`r`n"
        Write-TestFile -Path (Join-Path $script:folder 'Old Start.cmd') -Text "start `"`" -File `"%~dp0Launcher\Start-PortableVM.ps1`"`r`n"
    }

    It 'finds a changed, an added and a removed file, apart from the folders and names it leaves out' {
        $before = @(Get-CompareManifest -Target $script:folder)
        @($before | Where-Object { $_.Path -like 'System Volume Information*' }) | Should -BeNullOrEmpty
        Write-TestFile -Path (Join-Path $script:folder 'VMware\Test VM.vmx') -Text 'changed'
        Write-TestFile -Path (Join-Path $script:folder 'VMware\new.vmdk') -Text 'new'
        Remove-Item -LiteralPath (Join-Path $script:folder 'Private Name\diary.txt')
        Write-TestFile -Path (Join-Path $script:folder 'Launcher\Start-PortableVM.ps1') -Text '# changed'
        Write-TestFile -Path (Join-Path $script:folder 'LauncherData\logs\launcher.log') -Text 'more'
        Write-TestFile -Path (Join-Path $script:folder 'Start VM.cmd') -Text 'changed'
        $after = @(Get-CompareManifest -Target $script:folder)
        $change = Get-CompareFileChange -Before $before -After $after -Prefixes @('Launcher\', 'LauncherData\logs\') -Names 'Start VM.cmd'
        $change.Changed | Should -BeExactly @('VMware\Test VM.vmx')
        $change.Added | Should -BeExactly @('VMware\new.vmdk')
        $change.Removed | Should -BeExactly @('Private Name\diary.txt')
        $change.Count | Should -Be 4
    }

    It 'lists every top-level name, shows only known names, and counts the kinds of files' {
        $listing = Get-CompareListing -Target $script:folder -Manifest @(Get-CompareManifest -Target $script:folder) -Version 'v1'
        $listing.Lines | Should -BeExactly @(
            '  Launcher: folder, a launcher copy of this clone, 2 file(s): .ps1 1, no extension 1'
            '  other folder 1: folder, a launcher copy without VERSION, 1 file(s): .ps1 1'
            '  LauncherData: folder, 1 file(s): .log 1'
            '  other file 1: file (.cmd, starts the launcher)'
            '  other folder 2: folder, 1 file(s): .txt 1'
            '  Start VM.cmd: file (.cmd, starts the launcher)'
            '  System Volume Information: folder of Windows, not read'
            '  VMware: folder, 1 file(s): .vmx 1'
        )
        $listing.Labels['Private Name'] | Should -BeExactly 'other folder 2'
        ($listing.Lines -join "`n") | Should -Not -Match 'Private|diary|before-v0|Old Start|Test VM'
    }

    It 'counts what a write or deploy that did not finish left' {
        Write-TestFile -Path (Join-Path $script:folder 'VMware\stick.vmdk.pvm-tmp') -Text 'x'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:folder 'Launcher.new')
        Get-CompareLeftover -Target $script:folder -Manifest @(Get-CompareManifest -Target $script:folder) | Should -BeExactly @('Launcher.new', '1 .pvm-tmp or .pvm-old file(s)')
    }

    It 'masks paths, numbers, UUIDs and the names it is given in the deploy''s lines' {
        Format-CompareSafe -Text 'Deploy-PortableVM: X:\Kelda\stick 12345678 5ca1ab1e-0000-4000-8000-000000000001 Kelda VM, \\server\share' -Private 'Kelda VM' |
            Should -BeExactly 'Deploy-PortableVM: <path> <number> <uuid> <private>, <path>'
    }
}

Describe 'Compare-StickDryRun: a check on a scratch stick' -Tag 'WindowsOnly' {
    BeforeAll {
        # Write-PvmFile and Get-PvmAnsiEncoding come from the launcher's module.
        Import-Module -Name (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Force -Global -DisableNameChecking

        # Write the folder $Path as a deploy of version $Version leaves it, without the .cmd.
        function Initialize-TestCompareCopy {
            param([string]$Path, [string]$Version)
            $null = New-Item -ItemType Directory -Path $Path -Force
            $lines = foreach ($name in 'Start-PortableVM.ps1', 'PortableVM.psm1') {
                $file = Join-Path $Path $name
                [IO.File]::WriteAllText($file, "# $name of $Version`r`n", $script:utf8)
                '{0}  {1}' -f (Get-DeployHash -Path $file), $name
            }
            [IO.File]::WriteAllText((Join-Path $Path 'SHA256SUMS'), (($lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
            [IO.File]::WriteAllText((Join-Path $Path 'VERSION'), "$Version`n", [Text.Encoding]::ASCII)
        }

        # Return the messages of a dry run with the launcher of version $Version and the hypervisor
        # $Hypervisor; $script:runEdit, when set, changes those of the version $script:editVersion.
        function Get-TestRunMessage {
            param([string]$Version, [string]$Hypervisor)
            $program = if ($Hypervisor -eq 'VirtualBox') { 'VirtualBox' } else { 'VMware Workstation' }
            $messages = @('----- Start VM (dry run) -----', "Launcher version $Version", 'Stick found: disk 3 (\\.\PhysicalDrive3), drive Q:, ID 5CA1AB1E',
                "Using $(if ($Hypervisor -eq 'VirtualBox') { 'VirtualBox' } else { 'VMware' })", 'stick.vmdk already points at the stick',
                "DRY RUN - would start Q:\Kelda\Test VM.vmx with $program (Q:\Programs)", 'Timings: setup 1 ms, total 9 ms', '----- End (dry run): exit code 0 -----')
            if ($script:runEdit -and $Version -eq $script:editVersion) { $messages = & $script:runEdit $messages }
            $messages
        }

        # Stand in for the launcher's dry run on the stick $Target: append the lines of a run to its
        # log as the launcher writes them, for the version in Launcher and the settings' Hypervisor.
        function Add-TestRun {
            param([string]$Target)
            $version = [IO.File]::ReadAllText((Join-Path $Target 'Launcher\VERSION')).Trim()
            $settings = [IO.File]::ReadAllText((Join-Path $Target 'LauncherData\settings.psd1'))
            $hypervisor = if ($settings -match "Hypervisor = 'VirtualBox'") { 'VirtualBox' } else { 'Auto' }
            $script:hypervisors += $hypervisor
            $log = Join-Path $Target 'LauncherData\logs\launcher.log'
            $null = New-Item -ItemType Directory -Path (Split-Path $log) -Force
            $text = (@(Get-TestRunMessage -Version $version -Hypervisor $hypervisor | ForEach-Object { "2026-01-02T03:04:05.678+01:00 [$PID]  $_" }) -join "`r`n") + "`r`n"
            [IO.File]::AppendAllText($log, $text, (Get-PvmAnsiEncoding))
        }

        # Run the check on the scratch stick with the arguments $Arguments; return its result.
        function Invoke-TestCompare {
            param([hashtable]$Arguments = @{})
            $script:run = Join-Path $script:out ('run-' + [Guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:run
            Invoke-StickCompare -RepositoryPath $script:clone -Target $script:stick -OutputFolder $script:out -Folder $script:run @Arguments
        }

        # Return every file below the scratch stick, other than its log, with its hash.
        function Get-TestStickState {
            @(Get-TestTree -Root $script:stick | Where-Object { $_ -notlike 'LauncherData\logs*' })
        }
    }

    BeforeEach {
        Initialize-TestClone
        $script:stick = Join-Path $TestDrive 'cstick'
        $script:out = Join-Path $TestDrive 'checks'
        foreach ($folder in $script:stick, $script:out) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
        $null = New-Item -ItemType Directory -Path $script:out
        Write-TestFile -Path (Join-Path $script:stick 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $script:stick 'VMware\Test VM.vmx') -Text "displayName = `"Test VM`"`r`n"
        Write-TestFile -Path (Join-Path $script:stick 'Kelda Private\diary.txt') -Text 'mine'
        Initialize-TestCompareCopy -Path (Join-Path $script:stick 'Launcher') -Version 'v1'
        [IO.File]::Copy((Join-Path $script:clone 'Start VM.cmd'), (Join-Path $script:stick 'Start VM.cmd'))
        $script:runEdit = $null
        $script:editVersion = 'v2'
        $script:hypervisors = @()
        Mock Write-Host {}
        Mock Test-CompareAdministrator { $true }
        Mock Get-CompareVmProcess { @() }
        Mock Get-CompareClone { [pscustomobject]@{ Version = 'v2'; Problem = '' } }
        Mock Get-DeployVmProcess { @() }
        Mock Get-DeployVersion { 'v2' }
        Mock Invoke-CompareLauncher { Add-TestRun -Target $Target; 0 }
        Mock Invoke-CompareDeploy {
            try {
                $done = Invoke-PvmDeploy -RepositoryPath $RepositoryPath -Target $Target
                [pscustomobject]@{ Exit = 0; Lines = @(Format-DeployReport -Result $done | ForEach-Object { "Deploy-PortableVM: $_" }) }
            } catch {
                [pscustomobject]@{ Exit = 1; Lines = @("Deploy-PortableVM: $($_.Exception.Message)") }
            }
        }
    }

    It 'passes when the dry runs agree, deploys the clone, and keeps what Launcher held in Launcher.previous' {
        $oldLauncher = @(Get-TestTree -Root (Join-Path $script:stick 'Launcher'))
        $result = Invoke-TestCompare
        $result.ExitCode | Should -Be 0
        $result.Lines[-1] | Should -BeExactly 'RESULT: PASSED - deployed v2; the dry runs show no difference, and no other file changed'
        $result.Lines | Should -Contain '    version line: another version'
        $result.Lines | Should -Contain '    version line: this clone'
        $result.Lines | Should -Contain '  Deploy-PortableVM: deployed v2 (Update).'
        $result.Lines | Should -Contain "  Launcher.previous holds what Launcher held, plus the launcher's .cmd: yes"
        Get-CompareFolderVersion -Folder (Join-Path $script:stick 'Launcher') | Should -BeExactly 'v2'
        @(Get-TestTree -Root (Join-Path $script:stick 'Launcher.previous') | Where-Object { $_ -notlike 'Start VM.cmd *' }) | Should -BeExactly $oldLauncher
        Should -Invoke Invoke-CompareLauncher -Times 2 -Exactly
        @(Get-ChildItem -LiteralPath $script:run -Name | Sort-Object) | Should -BeExactly @('listing.txt', 'output.txt')
        [IO.File]::ReadAllLines((Join-Path $script:run 'output.txt')) | Should -BeExactly $result.Lines
    }

    It 'prints and saves nothing from the stick: no path, name, number or ID' {
        $result = Invoke-TestCompare -Arguments @{ AlsoVirtualBox = $true }
        $result.ExitCode | Should -Be 0
        # The run folder also keeps the bytes of the settings from before -AlsoVirtualBox, which stay on the PC.
        $saved = @('listing.txt', 'output.txt' | ForEach-Object { [IO.File]::ReadAllText((Join-Path $script:run $_)) }) -join "`n"
        foreach ($text in @(($result.Lines -join "`n"), $saved)) {
            foreach ($value in @($script:stick, 'Kelda', 'diary', '5CA1AB1E', 'PhysicalDrive', 'Test VM', 'Q:\')) { $text.Contains($value) | Should -BeFalse -Because $value }
        }
    }

    It 'refuses, changing nothing, when <Case>' -ForEach @(
        @{ Case = 'it lacks administrator rights'; Set = { Mock Test-CompareAdministrator { $false } }; Reason = 'the check needs administrator rights; nothing was changed' }
        @{ Case = 'a VM runs'; Set = { Mock Get-CompareVmProcess { 'vmware-vmx.exe' } }; Reason = 'a VM runs on this PC*' }
        @{ Case = 'a write was left unfinished'; Set = { Write-TestFile -Path (Join-Path $script:stick 'VMware\Test VM.vmx.pvm-old') -Text 'x' }; Reason = '*left 1 .pvm-tmp or .pvm-old file(s); nothing was changed' }
        @{ Case = 'a deploy left Launcher.new'; Set = { $null = New-Item -ItemType Directory -Path (Join-Path $script:stick 'Launcher.new') }; Reason = '*left Launcher.new; nothing was changed' }
        @{ Case = 'the clone is not clean'; Set = { Mock Get-CompareClone { [pscustomobject]@{ Version = 'v2-dirty'; Problem = 'the clone has changes that are not committed' } } }; Reason = 'the clone has changes that are not committed; commit and push first. Nothing was changed' }
        @{ Case = 'the clone is not pushed'; Set = { Mock Get-CompareClone { [pscustomobject]@{ Version = 'v2'; Problem = 'the clone is not at its pushed commit' } } }; Reason = 'the clone is not at its pushed commit*' }
        @{ Case = 'the commit is on the stick already'; Set = { Mock Get-CompareClone { [pscustomobject]@{ Version = 'v1'; Problem = '' } } }; Reason = "the stick's Launcher holds the clone's commit already*" }
        @{ Case = 'the settings of a cut-off run wait to be put back'; Set = { Write-TestFile -Path (Join-Path $script:out $ComparePendingName) -Text 'other settings' }; Reason = 'an earlier run with -AlsoVirtualBox was cut off*' }
        @{ Case = 'an expected change has another form'; Set = { $script:extra = @{ ExpectChange = @('stick found') } }; Reason = "-ExpectChange 'stick found' is not of the form*" }
    ) {
        $script:extra = @{}
        & $Set
        $before = Get-TestStickState
        $result = Invoke-TestCompare -Arguments $script:extra
        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike "RESULT: FAILED - $Reason"
        Get-TestStickState | Should -BeExactly $before
        Should -Invoke Invoke-CompareLauncher -Times 0 -Exactly
        Should -Invoke Invoke-CompareDeploy -Times 0 -Exactly
    }

    It 'deploys nothing when the first dry run fails' {
        Mock Invoke-CompareLauncher { Add-TestRun -Target $Target; 1 }
        $before = Get-TestStickState
        $result = Invoke-TestCompare
        $result.Lines[-1] | Should -BeExactly 'RESULT: FAILED - the dry run (as configured) with the launcher on the stick ended with exit code 1; nothing was deployed'
        Get-TestStickState | Should -BeExactly $before
        Should -Invoke Invoke-CompareDeploy -Times 0 -Exactly
    }

    It 'fails without a second dry run when the deploy fails' {
        Write-TestFile -Path (Join-Path $script:stick 'Launcher.previous\notes.txt') -Text 'mine'
        $result = Invoke-TestCompare
        $result.Lines[-1] | Should -BeExactly 'RESULT: FAILED - the deploy did not pass'
        $result.Lines | Should -Contain '  deploy: exit code 1'
        Should -Invoke Invoke-CompareLauncher -Times 1 -Exactly
        Get-CompareFolderVersion -Folder (Join-Path $script:stick 'Launcher') | Should -BeExactly 'v1'
    }

    It 'fails when the second dry run fails' {
        $script:runEdit = { param($m) @($m[0..5]) + @('STOPPED: Kelda', '----- End (dry run): exit code 1 -----') }
        Mock Invoke-CompareLauncher { Add-TestRun -Target $Target; [int]([IO.File]::ReadAllText((Join-Path $Target 'Launcher\VERSION')).Trim() -eq 'v2') }
        $result = Invoke-TestCompare
        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike 'RESULT: FAILED - the dry runs (as configured) differ in 2 line(s) that no -ExpectChange names; the dry runs (as configured) ended with different exit codes'
        $result.Lines | Should -Contain "  as configured: unexpected change: 'end line (dry run), exit code 0 => STOPPED line'"
    }

    It 'fails on an unexpected difference, and passes it once -ExpectChange names it' {
        $script:runEdit = { param($m) $m[4] = 'stick.vmdk -> RW 2500000 FLAT "\\.\PhysicalDrive3" 0'; $m }
        $result = Invoke-TestCompare
        $result.Lines[-1] | Should -BeExactly 'RESULT: FAILED - the dry runs (as configured) differ in 1 line(s) that no -ExpectChange names'

        $result = Invoke-StickCompare -RepositoryPath $script:clone -Target $script:stick -OutputFolder $script:out -Folder $script:run `
            -ExpectChange 'descriptor already points at the stick => descriptor would be pointed at the stick'
        $result.Lines[-1] | Should -BeExactly "RESULT: FAILED - the stick's Launcher holds the clone's commit already, so there is nothing to compare; run the check once per commit. Nothing was changed"

        Mock Get-CompareClone { [pscustomobject]@{ Version = 'v3'; Problem = '' } }
        Mock Get-DeployVersion { 'v3' }
        $script:editVersion = 'v3'
        $script:runEdit = { param($m) $m[4] = 'stick.vmdk -> RW 1 FLAT "x" 0'; $m }
        $result = Invoke-TestCompare -Arguments @{ ExpectChange = @('descriptor already points at the stick => descriptor would be pointed at the stick') }
        $result.Lines[-1] | Should -BeExactly 'RESULT: PASSED - deployed v3; the dry runs show only the 1 expected change(s), and no other file changed'
    }

    It 'fails when a file outside the launcher folders changes, and names only its top-level label' {
        Mock Invoke-CompareDeploy {
            Write-TestFile -Path (Join-Path $Target 'Kelda Private\diary.txt') -Text 'changed'
            $done = Invoke-PvmDeploy -RepositoryPath $RepositoryPath -Target $Target
            [pscustomobject]@{ Exit = 0; Lines = @(Format-DeployReport -Result $done | ForEach-Object { "Deploy-PortableVM: $_" }) }
        }
        $result = Invoke-TestCompare
        $result.Lines[-1] | Should -BeExactly 'RESULT: FAILED - files outside the launcher folders changed, in: other folder 1'
    }

    It 'fails when the top-level folders after the deploy are not those of the listing' {
        Mock Invoke-CompareDeploy {
            $done = Invoke-PvmDeploy -RepositoryPath $RepositoryPath -Target $Target
            $null = New-Item -ItemType Directory -Path (Join-Path $Target 'Empty Kelda')
            [pscustomobject]@{ Exit = 0; Lines = @(Format-DeployReport -Result $done | ForEach-Object { "Deploy-PortableVM: $_" }) }
        }
        (Invoke-TestCompare).Lines[-1] | Should -BeExactly 'RESULT: FAILED - the top-level folders and files after the deploy are not those of the listing'
    }

    It 'fails when the dry runs before the deploy change a file other than the log' {
        Mock Invoke-CompareLauncher { Add-TestRun -Target $Target; Write-TestFile -Path (Join-Path $Target 'VMware\Test VM.vmx') -Text 'changed'; 0 }
        (Invoke-TestCompare).Lines[-1] | Should -BeExactly 'RESULT: FAILED - the dry runs with the launcher on the stick changed a file other than the log; nothing was deployed'
        Should -Invoke Invoke-CompareDeploy -Times 0 -Exactly
    }

    It 'with -AlsoVirtualBox runs a second pair with VirtualBox and puts the settings back byte for byte' {
        $settings = Join-Path $script:stick 'LauncherData\settings.psd1'
        $original = [IO.File]::ReadAllBytes($settings)
        $result = Invoke-TestCompare -Arguments @{ AlsoVirtualBox = $true }
        $result.Lines[-1] | Should -BeExactly 'RESULT: PASSED - deployed v2; the dry runs show no difference, and no other file changed'
        $script:hypervisors | Should -BeExactly @('Auto', 'VirtualBox', 'Auto', 'VirtualBox')
        $result.Lines | Should -Contain '    using VirtualBox'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($settings)) | Should -BeExactly ([Convert]::ToBase64String($original))
        Join-Path $script:out $ComparePendingName | Should -Not -Exist
        @(Get-ChildItem -LiteralPath $script:stick -Recurse -Force -Name | Where-Object { $_ -like '*.pvm-*' }) | Should -BeNullOrEmpty
    }

    It 'with -AlsoVirtualBox puts the settings back when the dry run fails' {
        $settings = Join-Path $script:stick 'LauncherData\settings.psd1'
        $original = [IO.File]::ReadAllBytes($settings)
        Mock Invoke-CompareLauncher {
            Add-TestRun -Target $Target
            if ($script:hypervisors[-1] -eq 'VirtualBox') { throw 'The dry run broke.' }
            0
        }
        $result = Invoke-TestCompare -Arguments @{ AlsoVirtualBox = $true }
        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike 'RESULT: FAILED - unexpected error*'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($settings)) | Should -BeExactly ([Convert]::ToBase64String($original))
        Join-Path $script:out $ComparePendingName | Should -Not -Exist
        Join-Path $script:run "$ComparePendingName.1" | Should -Exist
        Should -Invoke Invoke-CompareDeploy -Times 0 -Exactly
    }

    It 'after a cut-off -AlsoVirtualBox run, stops until the settings are back, then goes on' {
        $settings = Join-Path $script:stick 'LauncherData\settings.psd1'
        $original = [IO.File]::ReadAllBytes($settings)
        # A run cut off after its safe write: the bytes before are on the PC, the stick has VirtualBox.
        $null = Write-CompareHypervisor -SettingsPath $settings -PendingPath (Join-Path $script:out $ComparePendingName)
        [IO.File]::ReadAllText($settings) | Should -Match "Hypervisor = 'VirtualBox'"
        $result = Invoke-TestCompare
        $result.Lines[-1] | Should -BeLike 'RESULT: FAILED - an earlier run with -AlsoVirtualBox was cut off before it put the settings back. Copy virtualbox-settings.original*'
        [IO.File]::WriteAllBytes($settings, $original)
        $result = Invoke-TestCompare
        $result.Lines | Should -Contain '  the settings of an earlier -AlsoVirtualBox run were back in place already'
        $result.Lines[-1] | Should -BeLike 'RESULT: PASSED*'
        Join-Path $script:out $ComparePendingName | Should -Not -Exist
    }

    It 'with -ListOnly lists the stick and runs and changes nothing' {
        Mock Test-CompareAdministrator { $false }
        $before = Get-TestStickState
        $result = Invoke-TestCompare -Arguments @{ ListOnly = $true }
        $result.ExitCode | Should -Be 0
        $result.Lines[-1] | Should -BeExactly 'RESULT: PASSED - listed the stick; nothing was run or changed'
        $result.Lines | Should -Contain '  other folder 1: folder, 1 file(s): .txt 1'
        [IO.File]::ReadAllLines((Join-Path $script:run 'listing.txt')) | Should -BeExactly @($result.Lines | Where-Object { $_ -like '  *' })
        Get-TestStickState | Should -BeExactly $before
        Should -Invoke Invoke-CompareLauncher -Times 0 -Exactly
        Should -Invoke Invoke-CompareDeploy -Times 0 -Exactly
    }

    It 'finds the stick folder by itself one level below a drive''s root, and stops at none or two' {
        Mock Get-CompareDriveRoot { @($TestDrive) }
        $script:run = Join-Path $script:out 'found'
        $null = New-Item -ItemType Directory -Path $script:run
        $result = Invoke-StickCompare -RepositoryPath $script:clone -OutputFolder $script:out -Folder $script:run -ListOnly
        $result.Lines[0] | Should -BeExactly 'Compare-StickDryRun: the stick folder was found by its Launcher and LauncherData folders.'
        $result.ExitCode | Should -Be 0

        Copy-Item -LiteralPath $script:stick -Destination (Join-Path $TestDrive 'cstick2') -Recurse
        $result = Invoke-StickCompare -RepositoryPath $script:clone -OutputFolder $script:out -Folder $script:run -ListOnly
        $result.Lines[-1] | Should -BeLike 'RESULT: FAILED - found 2 folders with Launcher and LauncherData*'
        Remove-Item -LiteralPath (Join-Path $TestDrive 'cstick2') -Recurse -Force
    }

    It 'refuses an output folder on the stick or in the repository' {
        foreach ($out in @((Join-Path $script:stick 'checks'), (Join-Path $script:clone 'checks'))) {
            $null = New-Item -ItemType Directory -Path $out -Force
            $result = Invoke-StickCompare -RepositoryPath $script:clone -Target $script:stick -OutputFolder $out -Folder $out
            $result.Lines[-1] | Should -BeLike 'RESULT: FAILED - the output folder is on the stick or in the repository*'
            Join-Path $out 'output.txt' | Should -Not -Exist
            Should -Invoke Invoke-CompareLauncher -Times 0 -Exactly
            Remove-Item -LiteralPath $out -Recurse -Force
        }
    }
}

Describe 'Compare-StickDryRun: adapters' {
    It '<Name> throws when a test reaches it unmocked' -ForEach @(
        @{ Name = 'Test-CompareAdministrator'; Call = { Test-CompareAdministrator } }
        @{ Name = 'Get-CompareVmProcess'; Call = { Get-CompareVmProcess } }
        @{ Name = 'Get-CompareDriveRoot'; Call = { Get-CompareDriveRoot } }
        @{ Name = 'Invoke-CompareGit'; Call = { Invoke-CompareGit -RepositoryPath $TestDrive -Arguments 'status' } }
        @{ Name = 'Invoke-CompareLauncher'; Call = { Invoke-CompareLauncher -Target $TestDrive } }
        @{ Name = 'Invoke-CompareDeploy'; Call = { Invoke-CompareDeploy -RepositoryPath $TestDrive -Target $TestDrive } }
        @{ Name = 'Invoke-CompareElevated'; Call = { Invoke-CompareElevated -ScriptPath 'none.ps1' -Folder $TestDrive } }
    ) {
        $previous = $env:PVM_TEST
        $env:PVM_TEST = '1'
        try { $Call | Should -Throw "$Name reached this PC during a test; mock it." }
        finally { $env:PVM_TEST = $previous }
    }
}

Describe 'Compare-StickDryRun as a script' -Tag 'WindowsOnly' {
    BeforeAll {
        # Run the tool as the owner does, in Windows PowerShell 5.1, with $Arguments, in a process
        # that reaches the PC: -ListOnly reads the stick folder and this clone's git state only.
        function Invoke-TestCompareScript {
            param([string[]]$Arguments)
            $previous = $env:PVM_TEST
            $env:PVM_TEST = ''
            try { $lines = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:repoRoot 'tools\Compare-StickDryRun.ps1') @Arguments 2>&1 | ForEach-Object { "$_" }) }
            finally { $env:PVM_TEST = $previous }
            [pscustomobject]@{ Exit = $LASTEXITCODE; Lines = $lines }
        }
        $script:listStick = Join-Path $TestDrive 'list stick'
        Write-TestFile -Path (Join-Path $script:listStick 'LauncherData\settings.psd1') -Text (Get-TestSchema2Text)
        Write-TestFile -Path (Join-Path $script:listStick 'Launcher\Start-PortableVM.ps1') -Text '# script'
    }

    It 'lists the stick with -ListOnly, saves the listing below -OutputFolder and exits 0' {
        $out = Join-Path $TestDrive 'list checks'
        $result = Invoke-TestCompareScript -Arguments @('-Target', $script:listStick, '-ListOnly', '-OutputFolder', $out)
        $result.Exit | Should -Be 0
        $result.Lines[-1] | Should -BeExactly 'RESULT: PASSED - listed the stick; nothing was run or changed'
        $runs = @(Get-ChildItem -LiteralPath $out -Directory)
        $runs.Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $runs[0].FullName -Name | Sort-Object) | Should -BeExactly @('listing.txt', 'output.txt')
    }

    It 'refuses an output folder in the repository before it creates anything' {
        $out = Join-Path $script:repoRoot ('checks-' + [Guid]::NewGuid().ToString('N'))
        $result = Invoke-TestCompareScript -Arguments @('-Target', $script:listStick, '-ListOnly', '-OutputFolder', $out)
        $result.Exit | Should -Be 1
        $result.Lines[-1] | Should -BeLike 'RESULT: FAILED - the output folder is on the stick or in the repository*'
        $out | Should -Not -Exist
    }
}

Describe 'Compare-StickDryRun: a full run with a stand-in for the PC' -Tag 'WindowsOnly' {
    BeforeAll {
        # Run git with $Arguments in the repository $Path; throw when it fails. A sample repository
        # gets no hooks or settings of this PC's other clones, since its remote is a local folder.
        function Invoke-TestGit {
            param([string]$Path, [string[]]$Arguments)
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $output = & git -C $Path -c core.autocrlf=false -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.com @Arguments 2>&1 }
            finally { $ErrorActionPreference = $previous }
            if ($LASTEXITCODE -ne 0) { throw "git $($Arguments[0]) failed: $output" }
        }

        # The clone: the real launcher code and .cmd, committed and pushed to a bare repository.
        $script:gitClone = Join-Path $TestDrive 'gitclone'
        $script:remote = Join-Path $TestDrive 'remote.git'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:gitClone 'src') -Force
        foreach ($name in 'src\Start-PortableVM.ps1', 'src\PortableVM.psm1', 'Start VM.cmd') {
            [IO.File]::Copy((Join-Path $script:repoRoot $name), (Join-Path $script:gitClone $name))
        }
        Invoke-TestGit -Path $TestDrive -Arguments @('init', '-q', '--bare', $script:remote)
        Invoke-TestGit -Path $script:gitClone -Arguments @('init', '-q', '-b', 'work')
        Invoke-TestGit -Path $script:gitClone -Arguments @('add', '-A')
        Invoke-TestGit -Path $script:gitClone -Arguments @('commit', '-q', '-m', 'first')
        Invoke-TestGit -Path $script:gitClone -Arguments @('remote', 'add', 'origin', $script:remote)
        Invoke-TestGit -Path $script:gitClone -Arguments @('push', '-q', '-u', 'origin', 'work')

        # The scratch stick, as the real one is shaped, with the first commit deployed.
        $script:fullStick = Join-Path $TestDrive 'fullstick'
        Write-TestFile -Path (Join-Path $script:fullStick 'LauncherData\settings.psd1') -Text ((@('@{', '    SchemaVersion = 2', "    Hypervisor = 'VMware'", "    StickMbrSignature = '5CA1AB1E'",
                    '    StickSectors = 4000000', '    VmSectors = 3900000', '    DataPartitionStart = 2500000', "    VirtualBoxVmUuid = '5ca1ab1e-0000-4000-8000-000000000001'",
                    "    VirtualBoxHome = 'VirtualBox'", "    VirtualBoxVbox = 'VirtualBox\Test VM\Test VM.vbox'", "    VirtualBoxDisk = 'VirtualBox\Test VM\stick.vmdk'",
                    "    VMwareVmx = 'VMware\Test VM.vmx'", "    VMwareDisk = 'VMware\stick.vmdk'", '}', '') -join "`r`n"))
        Write-TestFile -Path (Join-Path $script:fullStick 'VMware\Test VM.vmx') -Text ((@('.encoding = "windows-1252"', 'config.version = "8"', 'displayName = "Test VM"', 'uuid.action = "keep"', 'suspend.disabled = "TRUE"', '') -join "`r`n"))
        $descriptor = @('# Disk DescriptorFile', 'version=1', 'encoding="windows-1252"', 'CID=fffffffe', 'parentCID=ffffffff', 'createType="fullDevice"', '', '# Extent description',
            'RW 2500000 FLAT "\\.\PhysicalDrive99" 0', 'RW 1400000 ZERO ', '', '# The Disk Data Base', '#DDB', '', 'ddb.adapterType = "ide"', '') -join "`r`n"
        Write-TestFile -Path (Join-Path $script:fullStick 'VMware\stick.vmdk') -Text $descriptor
        Write-TestFile -Path (Join-Path $script:fullStick 'VirtualBox\Test VM\stick.vmdk') -Text ($descriptor.Replace("`r`n", "`n"))
        $below = $script:fullStick.Substring(2)
        Write-TestFile -Path (Join-Path $script:fullStick 'VirtualBox\Test VM\Test VM.vbox') -Text ((@('<?xml version="1.0"?>', '<VirtualBox xmlns="http://www.virtualbox.org/" version="1.19-windows">',
                    '  <Machine uuid="{5ca1ab1e-0000-4000-8000-000000000001}" name="Test VM" OSType="Debian_64">', '    <MediaRegistry><HardDisks>',
                    "      <HardDisk uuid=`"{5ca1ab1e-0000-4000-8000-000000000002}`" location=`"Q:$below\VirtualBox\Test VM\stick.vmdk`" format=`"VMDK`"/>",
                    '    </HardDisks></MediaRegistry>', '  </Machine>', '</VirtualBox>', '') -join "`n"))
        Write-TestFile -Path (Join-Path $script:fullStick 'VirtualBox\VirtualBox.xml') -Text ((@('<?xml version="1.0"?>', '<VirtualBox xmlns="http://www.virtualbox.org/" version="1.12-windows">', '  <Global><MachineRegistry>',
                    "    <MachineEntry uuid=`"{5ca1ab1e-0000-4000-8000-000000000001}`" src=`"Q:$($below.Replace('\', '/'))/VirtualBox/Test VM/Test VM.vbox`"/>",
                    '  </MachineRegistry></Global>', '</VirtualBox>', '') -join "`n"))
        $script:programs = Join-Path $TestDrive 'programs'
        Write-TestFile -Path (Join-Path $script:programs 'VMware\vmware.exe') -Text ''
        Write-TestFile -Path (Join-Path $script:programs 'VirtualBox\VBoxManage.exe') -Text ''
        Mock Get-DeployVmProcess { @() }
        $null = Invoke-PvmDeploy -RepositoryPath $script:gitClone -Target $script:fullStick

        # The stand-in launcher: the stick's own module, in Windows PowerShell 5.1, with every
        # adapter replaced by the synthetic PC: disk 99 is the stick, both programs are installed,
        # nothing runs, and starting a program is an error.
        $script:standIn = Join-Path $TestDrive 'stand-in.ps1'
        Write-TestFile -Path $script:standIn -Text (@'
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Programs)
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $Root 'Launcher\PortableVM.psm1') -PassThru -Force -DisableNameChecking
& $module {
    param($Programs)
    $script:TestPrograms = $Programs
    function script:Invoke-PvmTestAdministrator { $true }
    function script:Invoke-PvmEnterLock { param($Name) [pscustomobject]@{ State = 'Acquired'; Mutex = $null } }
    function script:Invoke-PvmExitLock { param($Lock) }
    function script:Invoke-PvmGetPartition { param($DriveLetter) [pscustomobject]@{ DiskNumber = 99; Offset = [uint64]2500000 * 512; Size = [uint64]1400000 * 512 } }
    function script:Invoke-PvmGetDisk { param($Number) [pscustomobject]@{ Number = 99; PartitionStyle = 'MBR'; Signature = [uint32]0x5CA1AB1E; LogicalSectorSize = 512; Size = [uint64]4000000 * 512; IsBoot = $false; IsSystem = $false } }
    function script:Invoke-PvmGetProcess { param($Name) @() }
    function script:Invoke-PvmTestProcess { param($Name) $false }
    function script:Invoke-PvmGetDeviceGuard { $null }
    function script:Invoke-PvmGetRegistryValue {
        param($Path, $Name)
        if ($Path -like '*\Oracle\VirtualBox') { return (Join-Path $script:TestPrograms 'VirtualBox') }
        if ($Path -like '*\VMware Workstation' -and $Path -notlike '*WOW6432Node*') { return (Join-Path $script:TestPrograms 'VMware') }
        $null
    }
    function script:Invoke-PvmNative {
        param($FilePath, $ArgumentList)
        switch ($ArgumentList[0]) {
            'list' { [pscustomobject]@{ ExitCode = 0; Output = '"Test VM" {5ca1ab1e-0000-4000-8000-000000000001}' } }
            'showvminfo' { [pscustomobject]@{ ExitCode = 0; Output = "name=`"Test VM`"`nVMState=`"poweroff`"" } }
            default { throw "Unexpected VBoxManage call: $ArgumentList" }
        }
    }
    function script:Invoke-PvmStartProcess { param($FilePath, $ArgumentList) throw 'A dry run must start nothing.' }
    function script:Invoke-PvmSetEnvironment { param($Name, $Value) }
    function script:Invoke-PvmSleep { param($Seconds) }
} $Programs
$result = Invoke-PortableVM -LauncherPath (Join-Path $Root 'Launcher') -DryRun
exit $result.ExitCode
'@)
    }

    BeforeEach {
        Mock Write-Host {}
        Mock Test-CompareAdministrator { $true }
        Mock Get-CompareVmProcess { @() }
        Mock Get-DeployVmProcess { @() }
        Mock Invoke-CompareGit {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $lines = @(& git -C $RepositoryPath @Arguments 2>&1 | ForEach-Object { "$_" }) }
            finally { $ErrorActionPreference = $previous }
            [pscustomobject]@{ Exit = $LASTEXITCODE; Lines = $lines }
        }
        Mock Invoke-CompareLauncher {
            $null = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:standIn -Root $Target -Programs $script:programs *>&1
            $LASTEXITCODE
        }
        Mock Invoke-CompareDeploy {
            try {
                $done = Invoke-PvmDeploy -RepositoryPath $RepositoryPath -Target $Target
                [pscustomobject]@{ Exit = 0; Lines = @(Format-DeployReport -Result $done | ForEach-Object { "Deploy-PortableVM: $_" }) }
            } catch {
                [pscustomobject]@{ Exit = 1; Lines = @("Deploy-PortableVM: $($_.Exception.Message)") }
            }
        }
        $script:fullOut = Join-Path $TestDrive 'fullchecks'
        $script:fullRun = Join-Path $script:fullOut ('run-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:fullRun -Force
    }

    It 'reads whether the clone is clean at its pushed commit' {
        $clean = Get-CompareClone -RepositoryPath $script:gitClone
        $clean.Problem | Should -BeExactly ''
        $clean.Version | Should -Match '^[0-9a-f]{7,}$'
        Write-TestFile -Path (Join-Path $script:gitClone 'notes.txt') -Text 'x'
        (Get-CompareClone -RepositoryPath $script:gitClone).Problem | Should -BeExactly 'the clone has changes that are not committed'
        Invoke-TestGit -Path $script:gitClone -Arguments @('add', '-A')
        Invoke-TestGit -Path $script:gitClone -Arguments @('commit', '-q', '-m', 'notes')
        (Get-CompareClone -RepositoryPath $script:gitClone).Problem | Should -BeExactly 'the clone is not at its pushed commit'
        Invoke-TestGit -Path $script:gitClone -Arguments @('push', '-q')
        (Get-CompareClone -RepositoryPath $script:gitClone).Problem | Should -BeExactly ''
    }

    It 'passes on a scratch stick with the real launcher and deploy, in both programs' {
        Add-Content -LiteralPath (Join-Path $script:gitClone 'src\Start-PortableVM.ps1') -Value '# a later commit'
        Invoke-TestGit -Path $script:gitClone -Arguments @('commit', '-q', '-a', '-m', 'later')
        Invoke-TestGit -Path $script:gitClone -Arguments @('push', '-q')
        $previousVersion = Get-CompareFolderVersion -Folder (Join-Path $script:fullStick 'Launcher')
        $result = Invoke-StickCompare -RepositoryPath $script:gitClone -Target $script:fullStick -AlsoVirtualBox -OutputFolder $script:fullOut -Folder $script:fullRun
        $result.Lines[-1] | Should -BeLike 'RESULT: PASSED - deployed *; the dry runs show no difference, and no other file changed'
        $result.Lines | Should -Contain '    descriptor already points at the stick'
        $result.Lines | Should -Contain '    would start with VMware Workstation'
        $result.Lines | Should -Contain '    would start with VirtualBox'
        $result.Lines | Should -Not -Contain '    other line'
        Get-CompareFolderVersion -Folder (Join-Path $script:fullStick 'Launcher.previous') | Should -BeExactly $previousVersion
        Should -Invoke Invoke-CompareLauncher -Times 4 -Exactly
    }

    It 'fails when an expected change did not happen, after the deploy' {
        Add-Content -LiteralPath (Join-Path $script:gitClone 'src\Start-PortableVM.ps1') -Value '# another commit'
        Invoke-TestGit -Path $script:gitClone -Arguments @('commit', '-q', '-a', '-m', 'another')
        Invoke-TestGit -Path $script:gitClone -Arguments @('push', '-q')
        $result = Invoke-StickCompare -RepositoryPath $script:gitClone -Target $script:fullStick -ExpectChange 'stick found => stick found' -OutputFolder $script:fullOut -Folder $script:fullRun
        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeExactly "RESULT: FAILED - the expected change 'stick found => stick found' did not happen"
    }
}
