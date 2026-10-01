param(
    [switch]$SkipIntegration
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)

    Write-Output ("> $Command " + ($Arguments -join ' '))
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

$ScriptDirectory = $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $ScriptDirectory
$Solution = Join-Path $RepositoryRoot 'NikkeLocalLab.sln'
$GlobalJsonPath = Join-Path $RepositoryRoot 'global.json'
$IntegrationTests = Join-Path $RepositoryRoot 'tests/NikkeLocalLab.PostgreSql.IntegrationTests/NikkeLocalLab.PostgreSql.IntegrationTests.csproj'
$EditorScript = Join-Path $RepositoryRoot 'src/NikkeLocalLab.Admin.Api/wwwroot/editor/editor.js'

# Refuse an unreviewed database before running any checks. Never infer a local DB.
if (-not $SkipIntegration) {
    if ([string]::IsNullOrWhiteSpace($env:NIKKE_LAB_TEST_DB)) {
        throw 'NIKKE_LAB_TEST_DB is required for PostgreSQL integration verification.'
    }
    if ($env:NIKKE_LAB_TEST_RESET_TOKEN -ne 'allow-phase1a-disposable-schema-reset') {
        throw 'The disposable PostgreSQL reset token is required for integration verification.'
    }
}

$RepositoryMode = if ($env:GITHUB_ACTIONS -eq 'true') { 'tracked' } else { 'working' }
Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory 'verify-repository.ps1'), '-Mode', $RepositoryMode, '-AllowRemote')
Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory 'verify-phase0-contract.ps1'))
Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory 'verify-actions-contract.ps1'))

function Assert-FileContains {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$FailureCode
    )

    $content = [System.IO.File]::ReadAllText($Path)
    if ($content -notmatch $Pattern) {
        throw $FailureCode
    }
}

$IntegrationTestDirectory = Split-Path -Parent $IntegrationTests
$PrivateServerProgram = Join-Path $RepositoryRoot 'src/NikkeLocalLab.PrivateServer.Api/Program.cs'
$AdminProgram = Join-Path $RepositoryRoot 'src/NikkeLocalLab.Admin.Api/Program.cs'

foreach ($program in @($PrivateServerProgram, $AdminProgram)) {
    Assert-FileContains $program "configuration\.ChallengeOperationalPolicy" "phase2b_configured_policy_configuration_missing"
    Assert-FileContains $program "ChallengeOperationalPolicy[\s\S]*CreateFromControlledCodes" "phase2b_configured_policy_materialization_missing"
    Assert-FileContains $program "PostgreSqlPrivateServerRuntime\.CreateAsync\(\s*connectionString,\s*initialPolicy\s*\)" "phase2b_configured_policy_composition_missing"
    Assert-FileContains $program "PrivateServerApplicationException" "phase2b_controlled_startup_error_mapping_missing"
}

$migrationIntegrationTestFiles = @(
    Get-ChildItem -LiteralPath $IntegrationTestDirectory -Recurse -Filter "*.cs" -File |
        Where-Object {
            $_.FullName -notmatch "[\\/](bin|obj)[\\/]" -and
            [System.IO.File]::ReadAllText($_.FullName) -match "\bMigrateAsync\s*\("
        }
)

if ($migrationIntegrationTestFiles.Count -eq 0) {
    throw "phase2b_integration_migration_tests_missing"
}

$privateServerSchemaReset = [System.Text.RegularExpressions.Regex]::Escape(
    "DROP SCHEMA IF EXISTS lab_private_server CASCADE;"
)
foreach ($testFile in $migrationIntegrationTestFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($RepositoryRoot, $testFile.FullName)
    Assert-FileContains `
        $testFile.FullName `
        $privateServerSchemaReset `
        "phase2b_integration_reset_missing_private_server_schema:$relativePath"
}

$GlobalJson = Get-Content -Raw -LiteralPath $GlobalJsonPath | ConvertFrom-Json
if ($GlobalJson.sdk.version -ne "8.0.407" -or
    $GlobalJson.sdk.rollForward -ne "disable" -or
    [bool]$GlobalJson.sdk.allowPrerelease) {
    throw "global.json must pin SDK 8.0.407 with rollForward disabled and prereleases denied."
}

$SdkVersion = (& dotnet --version).Trim()
if ($LASTEXITCODE -ne 0 -or $SdkVersion -ne "8.0.407") {
    throw "Verification requires the SDK pinned by global.json (8.0.407). Found: $SdkVersion"
}

Invoke-Checked dotnet @("restore", $Solution, "--locked-mode")
Invoke-Checked dotnet @("build", $Solution, "--configuration", "Release", "--no-restore")
Invoke-Checked dotnet @("format", $Solution, "--verify-no-changes", "--no-restore")
foreach ($project in @(
    'NikkeLocalLab.UnitTests',
    'NikkeLocalLab.Character.UnitTests',
    'NikkeLocalLab.Raid.UnitTests',
    'NikkeLocalLab.CombatSupport.UnitTests',
    'NikkeLocalLab.Profile.UnitTests',
    'NikkeLocalLab.ProfileImport.UnitTests',
    'NikkeLocalLab.Admin.Api.UnitTests',
    'NikkeLocalLab.Automation.UnitTests',
    'NikkeLocalLab.PrivateServer.UnitTests',
    'NikkeLocalLab.PrivateServer.Api.UnitTests'
)) {
    $path = Join-Path $RepositoryRoot ('tests/' + $project + '/' + $project + '.csproj')
    Invoke-Checked dotnet @('test', $path, '-c', 'Release', '--no-build', '--no-restore')
}

Invoke-Checked node @("--check", $EditorScript)
Invoke-Checked node @('--check', (Join-Path $ScriptDirectory 'measure-nll-editor-dom.cjs'))
Invoke-Checked node @((Join-Path $ScriptDirectory 'measure-nll-editor-dom.cjs'), '--self-test')
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/workspace-save-retry.test.cjs"))
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/raid-launch-status.test.cjs"))
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/boss-seasons.test.cjs"))
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/user-validation.test.cjs"))
Invoke-Checked node @("--test", (Join-Path $RepositoryRoot "tests/editor/union-raid.test.cjs"))
Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory 'test-nll-user-validation-diagnostics.ps1'))
Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory 'test-nll-user-validation-preflight.ps1'))
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
$GenerationProbe = Join-Path $RepositoryRoot 'tools/Phase3B2/UserValidationGenerationProbe/NikkeLocalLab.UserValidationGenerationProbe.csproj'
Invoke-Checked dotnet @('restore', $GenerationProbe, '--locked-mode')
Invoke-Checked dotnet @('build', $GenerationProbe, '-c', 'Release', '--no-restore')
Invoke-Checked dotnet @('format', $GenerationProbe, '--verify-no-changes', '--no-restore')
Write-Output 'Generation feasibility probe source built; elevated NTFS experiments are a separate synthetic local gate.'
Invoke-Checked node @((Join-Path $ScriptDirectory "test-nll-phase-d-lifecycle-ui.cjs"))
$MaterializerChecks = Join-Path $RepositoryRoot 'tests/NikkeLocalLab.Materializer.BehaviorChecks/NikkeLocalLab.Materializer.BehaviorChecks.csproj'
# Source-only CI compiles the checker without Epinel/SDK/client inputs. Actual
# output tests + separate deployment builds require the explicit pinned local gate.
Invoke-Checked dotnet @('restore', $MaterializerChecks, '--locked-mode')
Invoke-Checked dotnet @('build', $MaterializerChecks, '-c', 'Release', '--no-restore')
Invoke-Checked dotnet @('format', $MaterializerChecks, '--verify-no-changes', '--no-restore')
$NativeFxEvidence = Join-Path $RepositoryRoot ('artifacts/native-fx-process-checks/' + [guid]::NewGuid().ToString('N'))
Invoke-Checked dotnet @((Join-Path $RepositoryRoot 'tests/NikkeLocalLab.Materializer.BehaviorChecks/bin/Release/net8.0/NikkeLocalLab.Materializer.BehaviorChecks.dll'), '--native-fx', $NativeFxEvidence, '5')
Write-Output 'Materializer checker source build passed; pinned output checks/bootstrap151/desktop local gate NOT executed by CI.'
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
    foreach ($test in @('test-nll-phase-d-preparation.ps1',
        'test-nll-phase-d-runner-contract.ps1', 'test-nll-phase-d-runner-seal.ps1', 'test-nll-phase-d-job.ps1', 'test-nll-phase-d-job-paths.ps1',
        'test-nll-phase-d-startup-cleanup.ps1', 'test-nll-phase-d-runner-behavior.ps1',
        'test-nll-phase-d-runner-routing.ps1', 'test-nll-phase-d-runner-dependencies.ps1',
        'test-nll-phase-d-shared-state.ps1', 'test-nll-phase-d-shared-isolation.ps1', 'test-nll-phase-d-progress.ps1', 'test-nll-phase-d-prestart-recovery.ps1',
        'test-nll-phase-d-database-lifecycle.ps1',
        'test-nll-phase-d-materializer-errors.ps1', 'test-nll-stabilization-release.ps1')) {
        Invoke-Checked $WindowsPowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ScriptDirectory $test))
    }
    Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory 'test-nll-execution-fx-retirement.ps1'))
    # Preparation resolves Windows runtime paths; before S2 only the Windows job ran this gate.
    Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory 'verify-automation-boss-weakness-variant.ps1'))
} else {
    Write-Output 'Phase D Windows preparation/legacy-template behavior tests require the Windows local gate.'
}

# Source-only behavior checks shared by the Windows and PostgreSQL jobs.
foreach ($test in @(
    'test-nll-boss-publication.ps1',
    'test-nll-boss-native-composition.ps1',
    'test-nll-control-center-app-package.ps1',
    'test-nll-control-center-maintenance.ps1',
    'test-nll-control-center-delivery.ps1',
    'test-nll-native-fx-managed-driver.ps1',
    'test-nll-user-validation-controller.ps1',
    'test-nll-native-fx-managed-service.ps1'
)) {
    Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $ScriptDirectory $test))
}

foreach ($test in @(
    'test-nll-boss-catalog-images.py',
    'test-nll-boss-profile-qte.py',
    'test-nll-shield-fx-recipes.py',
    'test-nll-boss-fx-acquisition.py',
    'test-nll-boss-behavior-acquisition.py',
    'test-nll-boss-onboarding-candidate.py',
    'test-nll-shield-fx-candidate.py',
    'test-nll-execution-fx.py',
    'test-nll-native-fx.py',
    'test-nll-native-fx-layout.py',
    'test-nll-native-fx-store.py',
    'test-nll-actions-merge.py'
)) {
    Invoke-Checked python @('-B', (Join-Path $ScriptDirectory $test))
}

if (-not $SkipIntegration) {
    Invoke-Checked dotnet @('test', $IntegrationTests, '-c', 'Release', '--no-build', '--no-restore')
} else {
    Write-Output 'PostgreSQL integration explicitly skipped; this is not a complete integration result.'
}
Write-Output 'Current verification passed.'
