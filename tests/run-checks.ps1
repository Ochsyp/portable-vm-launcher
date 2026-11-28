# -------------------------------------------------------
#                  PORTABLE VM CHECKS
# -------------------------------------------------------
#
# Runs PSScriptAnalyzer with PSScriptAnalyzerSettings.psd1 over src, tools, tests, examples and
# ci, then Pester over the *.Tests.ps1 files in tests, as CI does. The versions are those the
# repository standard pins in .github/standard/bin/install-tools. Run it in Windows PowerShell
# 5.1, the launcher's own engine, or in PowerShell 7:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-checks.ps1
#   pwsh -NoProfile -File ./tests/run-checks.ps1
#   pwsh -NoProfile -File ./tests/run-checks.ps1 -SkipAnalyzer -ExcludeTag WindowsOnly   (on Linux)
# Any analyzer finding fails the run. Pester runs with $env:PVM_TEST set to '1', so a test that
# reaches one of the launcher's adapters without mocking it fails instead of touching the PC.
# -SkipAnalyzer or -SkipPester leaves that step out, -Filter runs only the tests whose full name
# matches it, such as -Filter '*example*', and -Tag or -ExcludeTag runs only, or all but, the
# tests with one of those tags. WindowsOnly marks a test that needs Windows; DesktopOnly and
# CoreOnly mark the cases of one edition of PowerShell, and each edition leaves out the other's.
# -FailOnSkip, which CI sets, fails the run on any skipped test; locally a test may skip, as one
# does while a VM runs on the PC. Exits 0 when nothing fails, else 1.

param(
    [switch]$SkipAnalyzer,
    [switch]$SkipPester,
    [string]$Filter,
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    [switch]$FailOnSkip
)

$ErrorActionPreference = 'Stop'

# Return the version that .github/standard/bin/install-tools pins for $Name, from its one line
# "readonly NAME_VERSION=X.Y.Z", as the standard's ci starters read it.
function Get-ToolPin {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $path = [IO.Path]::Combine($repoRoot, '.github', 'standard', 'bin', 'install-tools')
    $pattern = '^readonly {0}_VERSION=([0-9]+\.[0-9]+\.[0-9]+)$' -f $Name
    $found = @(Select-String -LiteralPath $path -Pattern $pattern -CaseSensitive)
    if ($found.Count -ne 1) { throw "install-tools does not pin ${Name}_VERSION in one line." }
    $found[0].Matches[0].Groups[1].Value
}

# Import the module $Name at exactly $Version, after unloading any other version of it from this
# session. PowerShell 7 on Windows does not look in Windows PowerShell's module folder of the
# current user, so there it also takes the version from that folder, for this run; both
# pinned modules work in either engine. Throws naming the Install-Module command for the running
# engine when that version is installed nowhere it looks.
function Import-PinnedModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][version]$Version
    )
    $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq $Version })
    if ($installed.Count -eq 0 -and $PSVersionTable.PSEdition -ne 'Desktop' -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $windowsModules = [IO.Path]::Combine([Environment]::GetFolderPath('MyDocuments'), 'WindowsPowerShell', 'Modules')
        if ([IO.Directory]::Exists([IO.Path]::Combine($windowsModules, $Name, "$Version"))) {
            $env:PSModulePath = $windowsModules + [IO.Path]::PathSeparator + $env:PSModulePath
            $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq $Version })
        }
    }
    if ($installed.Count -eq 0) {
        throw ("$Name $Version is not installed. Install it with: " +
            "Install-Module -Name $Name -RequiredVersion $Version -Repository PSGallery -Scope CurrentUser -Force -SkipPublisherCheck")
    }
    Get-Module -Name $Name | Where-Object { $_.Version -ne $Version } | Remove-Module -Force
    Import-Module -Name $Name -RequiredVersion $Version -Force
}

$repoRoot = Split-Path $PSScriptRoot -Parent
# Import-PinnedModule may add a folder to it; the session that ran this script gets it back as it was.
$previousModulePath = $env:PSModulePath
$exitCode = 1
Push-Location -LiteralPath $repoRoot
try {
    $failed = $false

    if (-not $SkipAnalyzer) {
        Import-PinnedModule -Name 'PSScriptAnalyzer' -Version (Get-ToolPin -Name 'PSSCRIPTANALYZER')
        $settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
        # PSScriptAnalyzer 1.25.0 takes one folder per -Path.
        $folders = @('src', 'tools', 'tests', 'examples', 'ci')
        $found = @($folders | ForEach-Object { Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $_) -Recurse -Settings $settings })
        Write-Output "Analyzer findings in $($folders -join ', '): $($found.Count)"
        if ($found.Count -gt 0) {
            $failed = $true
            $found | Format-Table -AutoSize -Wrap RuleName, Severity, ScriptName, Line, Message | Out-String -Width 220
        }
    }

    if (-not $SkipPester) {
        Import-PinnedModule -Name 'Pester' -Version (Get-ToolPin -Name 'PESTER')
        $config = New-PesterConfiguration
        # Pester runs only the *.Tests.ps1 files it finds there, so not this script.
        $config.Run.Path = Join-Path $repoRoot 'tests'
        $config.Run.PassThru = $true
        $config.Output.Verbosity = 'Normal'
        if ($Filter) { $config.Filter.FullName = $Filter }
        if ($Tag) { $config.Filter.Tag = $Tag }
        # Each edition of PowerShell leaves out the other edition's cases.
        $otherEdition = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'CoreOnly' } else { 'DesktopOnly' }
        $config.Filter.ExcludeTag = @(@($ExcludeTag | Where-Object { $_ }) + $otherEdition)
        # Splatted, since the analyzer's 5.1 profile knows only the in-box Pester 3.4, whose Invoke-Pester has no -Configuration.
        $pesterArguments = @{ Configuration = $config }
        $previousTestFlag = $env:PVM_TEST
        $env:PVM_TEST = '1'
        try { $result = Invoke-Pester @pesterArguments }
        finally { $env:PVM_TEST = $previousTestFlag }
        Write-Output "Pester: Passed=$($result.PassedCount) Failed=$($result.FailedCount) Skipped=$($result.SkippedCount) NotRun=$($result.NotRunCount)"
        # A test file that does not load, or a BeforeAll that throws, fails no single test.
        $broken = $result.FailedBlocksCount + $result.FailedContainersCount
        if ($broken -gt 0) {
            Write-Output "Pester: FailedBlocks=$($result.FailedBlocksCount) FailedContainers=$($result.FailedContainersCount)"
        }
        if ($result.FailedCount -gt 0 -or $broken -gt 0) { $failed = $true }
        if ($FailOnSkip -and $result.SkippedCount -gt 0) {
            Write-Output "Pester: $($result.SkippedCount) test(s) skipped, which -FailOnSkip does not allow."
            $failed = $true
        }
        # A run in which no test passed proves nothing, for example after a -Filter that matched none.
        if ($result.PassedCount -eq 0) {
            Write-Output 'Pester: no test passed.'
            $failed = $true
        }
    }

    if (-not $failed) { $exitCode = 0 }
} catch {
    Write-Host "The checks stopped: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
} finally {
    $env:PSModulePath = $previousModulePath
    Pop-Location
}
exit $exitCode
