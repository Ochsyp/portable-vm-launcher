# -------------------------------------------------------
#                  PORTABLE VM CHECKS
# -------------------------------------------------------
#
# Runs PSScriptAnalyzer 1.25.0 with PSScriptAnalyzerSettings.psd1 over src, tools, tests and
# examples, then Pester 6.2.0 over the *.Tests.ps1 files in tests, as CI does. Run it in Windows
# PowerShell 5.1:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-checks.ps1
# Any analyzer finding fails the run. Pester runs with $env:PVM_TEST set to '1', so a test that
# reaches one of the launcher's adapters without mocking it fails instead of touching the PC.
# -SkipAnalyzer or -SkipPester leaves that step out, and -Filter runs only the tests whose full
# name matches it, such as -Filter '*example*'. Exits 0 when nothing fails, else 1.

param(
    [switch]$SkipAnalyzer,
    [switch]$SkipPester,
    [string]$Filter
)

$ErrorActionPreference = 'Stop'

# Import the module $Name at exactly $Version, after unloading any other version of it from this
# session. Throws naming the Install-Module command when that version is not installed.
function Import-PinnedModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][version]$Version
    )
    $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq $Version })
    if ($installed.Count -eq 0) {
        throw ("$Name $Version is not installed. Install it with: " +
            "Install-Module -Name $Name -RequiredVersion $Version -Repository PSGallery -Scope CurrentUser -Force -SkipPublisherCheck")
    }
    Get-Module -Name $Name | Where-Object { $_.Version -ne $Version } | Remove-Module -Force
    Import-Module -Name $Name -RequiredVersion $Version -Force
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$exitCode = 1
Push-Location -LiteralPath $repoRoot
try {
    $failed = $false

    if (-not $SkipAnalyzer) {
        Import-PinnedModule -Name 'PSScriptAnalyzer' -Version '1.25.0'
        $settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
        # PSScriptAnalyzer 1.25.0 takes one folder per -Path.
        $folders = @('src', 'tools', 'tests', 'examples')
        $found = @($folders | ForEach-Object { Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $_) -Recurse -Settings $settings })
        Write-Output "Analyzer findings in $($folders -join ', '): $($found.Count)"
        if ($found.Count -gt 0) {
            $failed = $true
            $found | Format-Table -AutoSize -Wrap RuleName, Severity, ScriptName, Line, Message | Out-String -Width 220
        }
    }

    if (-not $SkipPester) {
        Import-PinnedModule -Name 'Pester' -Version '6.2.0'
        $config = New-PesterConfiguration
        # Pester runs only the *.Tests.ps1 files it finds there, so not this script.
        $config.Run.Path = Join-Path $repoRoot 'tests'
        $config.Run.PassThru = $true
        $config.Output.Verbosity = 'Normal'
        if ($Filter) { $config.Filter.FullName = $Filter }
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
    Pop-Location
}
exit $exitCode
