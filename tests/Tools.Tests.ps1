# Tests of tools\Deploy-PortableVM.ps1 and tools\Get-StickInventory.ps1 on a synthetic clone and
# stick in TestDrive. Each tool is dot-sourced for its functions, which skips its main block, and
# the functions that read the PC (processes, git, disks, registry) are mocked. The deploy tool
# imports the clone's src\PortableVM.psm1, so the fake clone holds a copy of the real module.

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:utf8 = New-Object System.Text.UTF8Encoding $false
    # A made-up name with letters outside ASCII that Windows-1252 holds too.
    $script:sampleName = 'K' + [char]0x00E9 + 'l' + [char]0x00F8 + 'n' + [char]0x00EF
    . (Join-Path $script:repoRoot 'tools\Deploy-PortableVM.ps1')
    . (Join-Path $script:repoRoot 'tools\Get-StickInventory.ps1')

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

Describe 'Deploy-PortableVM' {
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
        Format-DeployReport -Result $result | Should -BeExactly @('deployed v0.0.0-test (Update).', 'old launcher .cmd files moved into Launcher.previous: 1.')
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
        @{ Case = 'with Launcher.previous in place'; Setup = { $null = New-Item -ItemType Directory -Path (Join-Path $script:target 'Launcher.previous') }; Extra = @{}; Message = 'Launcher.previous holds the launcher that the last deploy replaced.*' }
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

    It 'only runs the checks under -WhatIf' {
        $before = Get-TestTree -Root $script:target
        $result = Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -WhatIf
        $result.Applied | Should -BeFalse
        $result.Mode | Should -BeExactly 'Update'
        Get-TestTree -Root $script:target | Should -BeExactly $before
        Format-DeployReport -Result $result | Should -BeExactly @('would deploy v0.0.0-test (Update).', 'old launcher .cmd files to move into Launcher.previous: 1.')
        Mock Get-DeployVmProcess { 'VirtualBoxVM.exe' }
        { Invoke-PvmDeploy -RepositoryPath $script:clone -Target $script:target -WhatIf } | Should -Throw -ExpectedMessage 'A VM runs on this PC*'
    }

    It 'finds only .cmd files that run a launcher script' {
        Write-TestFile -Path (Join-Path $script:target 'Start Slash.cmd') -Text 'start "" -File "%~dp0\Launcher\Old-Launcher.ps1"'
        Write-TestFile -Path (Join-Path $script:target 'Start Old.cmdx') -Text 'start "" -File "%~dp0Launcher\x.ps1"'
        @(Find-DeployLauncherCmd -Folder $script:target | ForEach-Object { $_.Name } | Sort-Object) | Should -BeExactly @('Start Old.cmd', 'Start Slash.cmd')
    }
}

Describe 'Deploy-PortableVM -MigrateSettings' {
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

    It 'runs as a script and leaves out a path below -Target that an error quotes' {
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
        $text = $output -join "`n"
        $text | Should -Match 'Deploy-PortableVM: Launcher\\settings\.psd1 cannot be read: .*<a path below -Target, which -Verbose shows>'
        $text.IndexOf($script:target, [StringComparison]::OrdinalIgnoreCase) | Should -Be -1
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
        [IO.File]::WriteAllBytes((Join-Path $script:target 'Launcher\settings.psd1'), [Text.Encoding]::Default.GetBytes($text))
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

Describe 'Get-DeployVmProcess' {
    It 'looks for every VMware and VirtualBox VM process' {
        Mock Get-CimInstance {}
        $null = Get-DeployVmProcess
        Should -Invoke -CommandName Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $Filter -ceq "Name LIKE 'vmware-vmx%' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'"
        }
    }
}

Describe 'Hide-DeployTargetPath' {
    It 'leaves out a quoted path below -Target <Target> and keeps every other word: <Case>' -ForEach @(
        @{ Case = 'a settings problem'; Target = 'X:\'; Message = "LauncherData\settings.psd1 has 1 problem:`n- VMwareVmx: must name a .vmx file below the folder that holds Launcher and LauncherData, without a drive, '.' or '..'"; Expected = $null }
        @{ Case = 'a name problem'; Target = 'E:\'; Message = "- GuestName: must be 1 to 40 characters of text that shows"; Expected = $null }
        @{ Case = 'a path in a .NET error'; Target = 'X:\'; Message = "Access to the path 'X:\VMware\a.vmdk.orig' is denied."; Expected = "Access to the path '<a path below -Target, which -Verbose shows>' is denied." }
        @{ Case = 'a path in another case'; Target = 'X:\Stick'; Message = "Cannot rename because item at 'x:\stick\Launcher' does not exist."; Expected = "Cannot rename because item at '<a path below -Target, which -Verbose shows>' does not exist." }
        @{ Case = 'an apostrophe in a name'; Target = 'X:\Stick'; Message = "The process cannot access the file 'X:\Stick\VMware\Ann's VM\a.vmdk' because it is being used by another process."; Expected = "The process cannot access the file '<a path below -Target, which -Verbose shows>' because it is being used by another process." }
        @{ Case = 'a path in nested quotes'; Target = 'X:\Stick'; Message = 'Exception calling "ReadAllText" with "1" argument(s): "Could not find file ''X:\Stick\Start Old.cmd''."'; Expected = 'Exception calling "ReadAllText" with "1" argument(s): "Could not find file ''<a path below -Target, which -Verbose shows>''."' }
        @{ Case = 'the folder itself'; Target = 'X:\Stick'; Message = "Cannot find path 'X:\Stick' because it does not exist."; Expected = "Cannot find path '<a path below -Target, which -Verbose shows>' because it does not exist." }
        @{ Case = 'a folder beside it'; Target = 'X:\Stick'; Message = "Access to the path 'X:\Sticky\a' is denied."; Expected = $null }
        @{ Case = 'a -Target with regex characters'; Target = 'Q:\st.ck [1] (a+b) $x'; Message = "Access to the path 'Q:\st.ck [1] (a+b) `$x\Launcher' is denied. Not 'Q:\stack [1] (a+b) `$x\Launcher'."; Expected = "Access to the path '<a path below -Target, which -Verbose shows>' is denied. Not 'Q:\stack [1] (a+b) `$x\Launcher'." }
    ) {
        $want = if ($null -eq $Expected) { $Message } else { $Expected }
        Hide-DeployTargetPath -Message $Message -Target $Target | Should -BeExactly $want
    }
}

Describe 'Get-DeployVersion' {
    It 'calls a folder that is no git clone version unknown' {
        $folder = Join-Path $TestDrive 'not-a-clone'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Get-DeployVersion -RepositoryPath $folder | Should -BeExactly 'unknown'
    }

    It 'reads the version of this clone' {
        Get-DeployVersion -RepositoryPath $script:repoRoot | Should -Not -BeExactly 'unknown'
    }
}

Describe 'Get-StickInventory' {
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
