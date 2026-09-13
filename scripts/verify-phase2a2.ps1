param(
    [switch]$Integration
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$Phase2A1 = Join-Path $ScriptDirectory "verify-phase2a1.ps1"
$ProfileImportTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.ProfileImport.UnitTests/NikkeLocalLab.ProfileImport.UnitTests.csproj"
$AdminApiTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.Admin.Api.UnitTests/NikkeLocalLab.Admin.Api.UnitTests.csproj"
$IntegrationTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.PostgreSql.IntegrationTests/NikkeLocalLab.PostgreSql.IntegrationTests.csproj"
$EditorScript = Join-Path $RepositoryRoot "src/NikkeLocalLab.Admin.Api/wwwroot/editor/editor.js"

$Phase2A1Arguments = @("-NoProfile", "-File", $Phase2A1)
Invoke-Checked pwsh $Phase2A1Arguments
Invoke-Checked dotnet @(
    "test",
    $ProfileImportTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)
Invoke-Checked dotnet @(
    "test",
    $AdminApiTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)
Invoke-Checked node @("--check", $EditorScript)
Invoke-Checked node @('--check', (Join-Path $ScriptDirectory 'measure-nll-editor-dom.cjs'))
Invoke-Checked node @((Join-Path $ScriptDirectory 'measure-nll-editor-dom.cjs'), '--self-test')
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/workspace-save-retry.test.cjs"))
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/raid-launch-status.test.cjs"))
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/boss-seasons.test.cjs"))
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/user-validation.test.cjs"))
$BossPipelineChecks = Join-Path $RepositoryRoot 'tools/NikkeLocalLab.BossPipeline.Checks/NikkeLocalLab.BossPipeline.Checks.csproj'
Invoke-Checked dotnet @('restore', $BossPipelineChecks, '--locked-mode')
Invoke-Checked dotnet @('build', $BossPipelineChecks, '-c', 'Release', '--no-restore')
Invoke-Checked dotnet @('format', $BossPipelineChecks, '--verify-no-changes', '--no-restore')
Write-Output 'Boss pipeline local checker source build passed; real data pipeline requires explicit private configuration and is not run in CI.'
$ValidationChecker = Join-Path $RepositoryRoot 'tools/Phase3B2/UserValidationOfflineCheck/NikkeLocalLab.UserValidationOfflineCheck.csproj'
Invoke-Checked dotnet @('restore', $ValidationChecker, '--locked-mode')
Invoke-Checked dotnet @('build', $ValidationChecker, '-c', 'Release', '--no-restore')
Invoke-Checked dotnet @('format', $ValidationChecker, '--verify-no-changes', '--no-restore')
Write-Output 'User validation compiled-plan checker source built; no game, UAC or private inputs used in CI.'
Invoke-Checked node @((Join-Path $ScriptDirectory "test-nll-phase-d-lifecycle-ui.cjs"))
$MaterializerChecks = Join-Path $RepositoryRoot 'tests/NikkeLocalLab.Materializer.BehaviorChecks/NikkeLocalLab.Materializer.BehaviorChecks.csproj'
# Source-only CI compiles the checker without Epinel/SDK/client inputs. Actual
# output tests + separate deployment builds require the explicit pinned local gate.
Invoke-Checked dotnet @('restore', $MaterializerChecks, '--locked-mode')
Invoke-Checked dotnet @('build', $MaterializerChecks, '-c', 'Release', '--no-restore')
Invoke-Checked dotnet @('format', $MaterializerChecks, '--verify-no-changes', '--no-restore')
Write-Output 'Materializer checker source build passed; pinned output checks/bootstrap151/desktop local gate NOT executed by CI.'
# The source-linked HTTP bridge is tested with synthetic bytes on loopback only.
Invoke-Checked dotnet @('test', (Join-Path $RepositoryRoot 'tests/NikkeLocalLab.Automation.UnitTests'), '-c', 'Release', '--no-build', '--no-restore')
$AssetDeliveryProbe = Join-Path $RepositoryRoot 'tools/PhaseD/AssetDeliveryProbe/NikkeLocalLab.AssetDeliveryProbe.csproj'
Invoke-Checked dotnet @('restore', $AssetDeliveryProbe, '--locked-mode')
Invoke-Checked dotnet @('build', $AssetDeliveryProbe, '-c', 'Release', '--no-restore')
Invoke-Checked dotnet @('format', $AssetDeliveryProbe, '--verify-no-changes', '--no-restore')
Write-Output 'FX HTTP synthetic checks and local probe source build passed; installed Epinel/native client delivery NOT executed.'
$EpinelFxProbe = Join-Path $RepositoryRoot 'tools/PhaseD/EpinelFxProbe/EpinelFxProbe.csproj'
Invoke-Checked dotnet @('restore', $EpinelFxProbe, '--locked-mode')
Invoke-Checked dotnet @('build', $EpinelFxProbe, '-c', 'Release', '--no-restore')
Invoke-Checked dotnet @('format', $EpinelFxProbe, '--verify-no-changes', '--no-restore')
Write-Output 'External FX probe source build passed; no external DLL/catalog/game input executed in CI.'
$ReadBenchmarks = Join-Path $RepositoryRoot 'tests/NikkeLocalLab.ReadBenchmarks/NikkeLocalLab.ReadBenchmarks.csproj'
Invoke-Checked dotnet @('restore', $ReadBenchmarks, '--locked-mode')
Invoke-Checked dotnet @('build', $ReadBenchmarks, '-c', 'Release', '--no-restore')
Invoke-Checked dotnet @('format', $ReadBenchmarks, '--verify-no-changes', '--no-restore')
Invoke-Checked dotnet @((Join-Path $RepositoryRoot 'tests/NikkeLocalLab.ReadBenchmarks/bin/Release/net8.0/NikkeLocalLab.ReadBenchmarks.dll'), '--self-test')
Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory 'test-nll-ui-reuse-assets.ps1'))
if ($env:OS -eq 'Windows_NT') {
    $WindowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    foreach ($test in @('test-nll-phase-d-preparation.ps1', 'test-nll-phase-d-launch-tools.ps1',
        'test-nll-phase-d-runner-contract.ps1', 'test-nll-phase-d-runner-seal.ps1', 'test-nll-phase-d-job.ps1', 'test-nll-phase-d-job-paths.ps1',
        'test-nll-phase-d-runner-behavior.ps1', 'test-nll-phase-d-runner-differential.ps1',
        'test-nll-phase-d-runner-routing.ps1', 'test-nll-phase-d-runner-dependencies.ps1',
        'test-nll-phase-d-shared-state.ps1', 'test-nll-stabilization-release.ps1')) {
        Invoke-Checked $WindowsPowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ScriptDirectory $test))
    }
    Invoke-Checked $WindowsPowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ScriptDirectory 'test-nll-phase-d-runner-behavior.ps1'), '-JobContract')
} else {
    Write-Output 'Phase D Windows preparation/legacy-template behavior tests require the Windows local gate.'
}

if ($Integration) {
    if ([string]::IsNullOrWhiteSpace($env:NIKKE_LAB_TEST_DB)) {
        throw "NIKKE_LAB_TEST_DB is required for PostgreSQL integration verification."
    }

    if ($env:NIKKE_LAB_TEST_RESET_TOKEN -ne "allow-phase1a-disposable-schema-reset") {
        throw "The disposable PostgreSQL reset token is required for integration verification."
    }

    Invoke-Checked dotnet @(
        "test",
        $IntegrationTests,
        "--configuration",
        "Release",
        "--no-build",
        "--no-restore"
    )
}

$Mode = if ($Integration) { "unit and PostgreSQL integration" } else { "unit" }
Write-Output "Phase 2A2 $Mode verification passed."
