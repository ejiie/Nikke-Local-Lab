[CmdletBinding()]
param(
    [string]$DotnetPath = 'E:\Program Files\dotnet\dotnet.exe',
    [string]$Season26CheckpointPath = 'D:\NikkeLocalLab\Backups\phase3b2-season26-challenge-damage-observer-v8-checkpoint-v1\9ce052ed-3f9d-4674-9025-b3852b51a2fe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-PhaseA {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$FailureCode
    )

    if (-not $Condition) {
        throw $FailureCode
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repositoryRoot 'tests\fixtures\automation\season26-v8.pipeline.json'
$testProjectPath = Join-Path $repositoryRoot 'tests\NikkeLocalLab.Automation.UnitTests\NikkeLocalLab.Automation.UnitTests.csproj'
$cliProjectPath = Join-Path $repositoryRoot 'src\NikkeLocalLab.Automation.Cli\NikkeLocalLab.Automation.Cli.csproj'
$cliAssemblyPath = Join-Path $repositoryRoot 'src\NikkeLocalLab.Automation.Cli\bin\Release\net8.0\NikkeLocalLab.Automation.Cli.dll'
$verificationUid = [guid]::NewGuid().ToString('D')
$outputDirectory = Join-Path ([IO.Path]::GetTempPath()) ("NLL-Automation-PhaseA-$verificationUid")

Assert-PhaseA (Test-Path -LiteralPath $DotnetPath -PathType Leaf) 'automation_phase_a_dotnet_missing'
Assert-PhaseA (Test-Path -LiteralPath $Season26CheckpointPath -PathType Container) 'automation_phase_a_season26_checkpoint_missing'
Assert-PhaseA (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'automation_phase_a_manifest_missing'

$contracts = [ordered]@{
    'contracts\fetched-account-snapshot.schema.json' = 'nll/fetched-account-snapshot/v1'
    'contracts\account-workspace.schema.json' = 'nll/account-workspace/v1'
    'contracts\update-assessment.schema.json' = 'nll/update-assessment/v1'
    'contracts\boss-candidate.schema.json' = 'nll/boss-candidate/v1'
    'contracts\launch-context.schema.json' = 'nll/launch-context/v1'
    'contracts\pipeline-run-manifest.schema.json' = 'nll/pipeline-run-manifest/v1'
}

foreach ($entry in $contracts.GetEnumerator()) {
    $path = Join-Path $repositoryRoot $entry.Key
    Assert-PhaseA (Test-Path -LiteralPath $path -PathType Leaf) 'automation_phase_a_contract_missing'
    $schema = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-PhaseA ($schema.properties.contractId.const -ceq $entry.Value) 'automation_phase_a_contract_id_mismatch'
}

& $DotnetPath restore $testProjectPath --locked-mode --ignore-failed-sources -p:NuGetAudit=false --nologo | Out-Host
Assert-PhaseA ($LASTEXITCODE -eq 0) 'automation_phase_a_test_restore_failed'

& $DotnetPath test $testProjectPath --configuration Release --no-restore --nologo | Out-Host
Assert-PhaseA ($LASTEXITCODE -eq 0) 'automation_phase_a_unit_tests_failed'

& $DotnetPath restore $cliProjectPath --locked-mode --ignore-failed-sources -p:NuGetAudit=false --nologo | Out-Host
Assert-PhaseA ($LASTEXITCODE -eq 0) 'automation_phase_a_cli_restore_failed'

& $DotnetPath build $cliProjectPath --configuration Release --no-restore --nologo | Out-Host
Assert-PhaseA ($LASTEXITCODE -eq 0) 'automation_phase_a_cli_build_failed'
Assert-PhaseA (Test-Path -LiteralPath $cliAssemblyPath -PathType Leaf) 'automation_phase_a_cli_assembly_missing'

$summaryText = & $DotnetPath $cliAssemblyPath dry-run $manifestPath $Season26CheckpointPath $outputDirectory
Assert-PhaseA ($LASTEXITCODE -eq 0) 'automation_phase_a_season26_dry_run_failed'
$summary = $summaryText | ConvertFrom-Json
$stagePlanPath = Join-Path $outputDirectory 'stage.plan.json'
Assert-PhaseA (Test-Path -LiteralPath $stagePlanPath -PathType Leaf) 'automation_phase_a_stage_plan_missing'
$stagePlan = Get-Content -LiteralPath $stagePlanPath -Raw | ConvertFrom-Json

Assert-PhaseA ($summary.inventoryMatched -eq $true) 'automation_phase_a_inventory_drift'
Assert-PhaseA ([int]$summary.inputCount -eq 12) 'automation_phase_a_inventory_count_mismatch'
Assert-PhaseA ($summary.stageReady -eq $true) 'automation_phase_a_stage_not_ready'
Assert-PhaseA ($summary.mutationPerformed -eq $false) 'automation_phase_a_dry_run_mutated'
Assert-PhaseA ($stagePlan.contractId -ceq 'nll/pipeline-stage-plan/v1') 'automation_phase_a_stage_plan_contract_mismatch'
Assert-PhaseA ($stagePlan.stageReady -eq $true) 'automation_phase_a_stage_plan_not_ready'
Assert-PhaseA ($stagePlan.mutationPerformed -eq $false) 'automation_phase_a_stage_plan_mutated'
Assert-PhaseA ($stagePlan.plannedActions.Count -eq 3) 'automation_phase_a_stage_action_count_mismatch'
Assert-PhaseA ($stagePlan.rollbackActions.Count -eq 3) 'automation_phase_a_rollback_action_count_mismatch'

[ordered]@{
    schemaVersion = 1
    contractId = 'nll/automation-phase-a-verification/v1'
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    verificationUid = $verificationUid
    contractCount = $contracts.Count
    unitTestCount = 12
    season26InputCount = [int]$summary.inputCount
    manifestSha256 = [string]$summary.manifestSha256
    inventoryMatched = [bool]$summary.inventoryMatched
    stageReady = [bool]$summary.stageReady
    plannedActionCount = $stagePlan.plannedActions.Count
    rollbackActionCount = $stagePlan.rollbackActions.Count
    mutationPerformed = $false
    checkpointReadOnly = $true
    nextStepCode = 'review_then_begin_account_workspace_core'
} | ConvertTo-Json
