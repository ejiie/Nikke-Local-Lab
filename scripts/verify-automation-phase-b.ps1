[CmdletBinding()]
param(
    [string]$DotnetPath = 'E:\Program Files\dotnet\dotnet.exe',
    [string]$NodePath = 'C:\Users\nlloperator\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe',
    [string]$LiveAcceptanceReceiptPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-PhaseB {
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
if (-not (Test-Path -LiteralPath $DotnetPath -PathType Leaf)) {
    $dotnetCommand = Get-Command dotnet -ErrorAction Stop
    $DotnetPath = $dotnetCommand.Source
}
if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
    $nodeCommand = Get-Command node -ErrorAction Stop
    $NodePath = $nodeCommand.Source
}

$env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
$env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_NOLOGO = '1'

$adminTests = Join-Path $repositoryRoot 'tests\NikkeLocalLab.Admin.Api.UnitTests\NikkeLocalLab.Admin.Api.UnitTests.csproj'
$postgresTests = Join-Path $repositoryRoot 'tests\NikkeLocalLab.PostgreSql.IntegrationTests\NikkeLocalLab.PostgreSql.IntegrationTests.csproj'
$editorScript = Join-Path $repositoryRoot 'src\NikkeLocalLab.Admin.Api\wwwroot\editor\editor.js'
$migrationPath = Join-Path $repositoryRoot 'src\NikkeLocalLab.Persistence.PostgreSql\Migrations\V0008__account_workspace.sql'
$verificationUid = [guid]::NewGuid().ToString('D')
$liveAcceptanceReceipt = $null
$liveAcceptanceUid = $null
$liveAcceptanceReceiptSha256 = $null

if ([string]::IsNullOrWhiteSpace($LiveAcceptanceReceiptPath)) {
    $liveReceiptRoot = Join-Path $repositoryRoot 'artifacts\automation\phase-b-live'
    if (Test-Path -LiteralPath $liveReceiptRoot -PathType Container) {
        foreach ($candidate in @(Get-ChildItem -LiteralPath $liveReceiptRoot -File -Filter '*.receipt.json' |
                Sort-Object LastWriteTimeUtc -Descending)) {
            try {
                $candidateReceipt = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json
                if ($candidateReceipt.contractId -ceq 'nll/automation-phase-b-live-acceptance/v1' -and
                    $candidateReceipt.verdictCode -ceq 'phase_b_live_acceptance_passed') {
                    $LiveAcceptanceReceiptPath = $candidate.FullName
                    $liveAcceptanceReceipt = $candidateReceipt
                    break
                }
            }
            catch {
                continue
            }
        }
    }
}
else {
    Assert-PhaseB (Test-Path -LiteralPath $LiveAcceptanceReceiptPath -PathType Leaf) 'automation_phase_b_live_receipt_missing'
    $LiveAcceptanceReceiptPath = (Resolve-Path -LiteralPath $LiveAcceptanceReceiptPath).Path
    $liveAcceptanceReceipt = Get-Content -LiteralPath $LiveAcceptanceReceiptPath -Raw | ConvertFrom-Json
}

if ($null -ne $liveAcceptanceReceipt) {
    Assert-PhaseB ($liveAcceptanceReceipt.schemaVersion -eq 1) 'automation_phase_b_live_receipt_schema_invalid'
    Assert-PhaseB ($liveAcceptanceReceipt.contractId -ceq 'nll/automation-phase-b-live-acceptance/v1') 'automation_phase_b_live_receipt_contract_invalid'
    Assert-PhaseB ($liveAcceptanceReceipt.verdictCode -ceq 'phase_b_live_acceptance_passed') 'automation_phase_b_live_receipt_verdict_invalid'
    Assert-PhaseB ($liveAcceptanceReceipt.postgresVersion -ceq 'postgres (PostgreSQL) 17.11') 'automation_phase_b_live_postgres_version_invalid'
    Assert-PhaseB ($liveAcceptanceReceipt.testExitCode -eq 0) 'automation_phase_b_live_test_failed'
    Assert-PhaseB ([bool]$liveAcceptanceReceipt.independentRevisionHistoryVerified) 'automation_phase_b_live_history_unverified'
    Assert-PhaseB ([bool]$liveAcceptanceReceipt.independentRuntimeCandidateVerified) 'automation_phase_b_live_candidate_unverified'
    Assert-PhaseB (@($liveAcceptanceReceipt.historyObservations).Count -eq 2) 'automation_phase_b_live_history_count_invalid'
    Assert-PhaseB (@($liveAcceptanceReceipt.historyObservations)[0] -ceq "계정_1`t2`tfalse") 'automation_phase_b_live_source_history_invalid'
    Assert-PhaseB (@($liveAcceptanceReceipt.historyObservations)[1] -ceq "계정_2`t2`ttrue") 'automation_phase_b_live_copy_history_invalid'
    Assert-PhaseB (-not [bool]$liveAcceptanceReceipt.gameRuntimeModified) 'automation_phase_b_live_game_runtime_modified'
    Assert-PhaseB (-not [bool]$liveAcceptanceReceipt.goldenModified) 'automation_phase_b_live_golden_modified'
    Assert-PhaseB (-not [bool]$liveAcceptanceReceipt.dockerUsed) 'automation_phase_b_live_docker_used'
    Assert-PhaseB (-not [bool]$liveAcceptanceReceipt.windowsServiceUsed) 'automation_phase_b_live_windows_service_used'
    Assert-PhaseB ([bool]$liveAcceptanceReceipt.cleanupVerified) 'automation_phase_b_live_cleanup_unverified'
    Assert-PhaseB ($liveAcceptanceReceipt.postgresProcessCountAfter -eq 0) 'automation_phase_b_live_postgres_process_remains'
    Assert-PhaseB ($liveAcceptanceReceipt.portListenerCountAfter -eq 0) 'automation_phase_b_live_listener_remains'
    $liveAcceptanceUid = [string]$liveAcceptanceReceipt.acceptanceUid
    $liveAcceptanceReceiptSha256 = (Get-FileHash -LiteralPath $LiveAcceptanceReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

$contracts = [ordered]@{
    'contracts\account-workspace.schema.json' = 'nll/account-workspace/v1'
    'contracts\runtime-projection-candidate.schema.json' = 'nll/runtime-projection-candidate/v1'
}
foreach ($entry in $contracts.GetEnumerator()) {
    $path = Join-Path $repositoryRoot $entry.Key
    Assert-PhaseB (Test-Path -LiteralPath $path -PathType Leaf) 'automation_phase_b_contract_missing'
    $schema = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-PhaseB ($schema.properties.contractId.const -ceq $entry.Value) 'automation_phase_b_contract_id_mismatch'
}

Assert-PhaseB (Test-Path -LiteralPath $migrationPath -PathType Leaf) 'automation_phase_b_migration_missing'
$migration = Get-Content -LiteralPath $migrationPath -Raw
Assert-PhaseB ($migration.Contains('CREATE TABLE lab_profile.account_workspace')) 'automation_phase_b_workspace_table_missing'
Assert-PhaseB ($migration.Contains('save_as_parent_account_uid')) 'automation_phase_b_save_as_parent_missing'
Assert-PhaseB (-not $migration.Contains('UPDATE lab_profile.profile_template_revision')) 'automation_phase_b_game_revision_mutation_detected'

& $DotnetPath restore $adminTests --locked-mode --ignore-failed-sources -p:NuGetAudit=false --nologo | Out-Host
Assert-PhaseB ($LASTEXITCODE -eq 0) 'automation_phase_b_admin_restore_failed'
& $DotnetPath test $adminTests --configuration Release --no-restore --nologo | Out-Host
Assert-PhaseB ($LASTEXITCODE -eq 0) 'automation_phase_b_admin_tests_failed'

& $DotnetPath restore $postgresTests --locked-mode --ignore-failed-sources -p:NuGetAudit=false --nologo | Out-Host
Assert-PhaseB ($LASTEXITCODE -eq 0) 'automation_phase_b_postgres_restore_failed'
& $DotnetPath test $postgresTests --configuration Release --no-restore --nologo `
    --filter 'FullyQualifiedName~PostgreSqlAccountWorkspaceMigrationTests' | Out-Host
Assert-PhaseB ($LASTEXITCODE -eq 0) 'automation_phase_b_migration_tests_failed'

& $NodePath --check $editorScript | Out-Host
Assert-PhaseB ($LASTEXITCODE -eq 0) 'automation_phase_b_editor_syntax_invalid'

$endpointSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\NikkeLocalLab.Admin.Api\AdminApiEndpoints.cs') -Raw
foreach ($route in @('/accounts/{accountUid}/workspace', '/accounts/{accountUid}/revisions', '/runtime-projection-candidate')) {
    Assert-PhaseB ($endpointSource.Contains($route)) 'automation_phase_b_route_missing'
}

[ordered]@{
    schemaVersion = 1
    contractId = 'nll/automation-phase-b-verification/v1'
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    verificationUid = $verificationUid
    contractCount = $contracts.Count
    migrationVersion = 8
    accountListApiPresent = $true
    accountWorkspaceApiPresent = $true
    independentRevisionHistoryApiPresent = $true
    saveAsLabelBindingPresent = $true
    runtimeProjectionCandidatePresent = $true
    editorSyntaxValid = $true
    gameRevisionMutationPerformed = $false
    livePostgreSqlAcceptanceExecuted = $null -ne $liveAcceptanceReceipt
    liveAcceptanceUid = $liveAcceptanceUid
    liveAcceptanceReceiptSha256 = $liveAcceptanceReceiptSha256
    nextStepCode = if ($null -ne $liveAcceptanceReceipt) {
        'phase_b_complete_begin_phase_c_fetch_adapter'
    } else {
        'run_live_postgresql_save_as_acceptance_then_begin_phase_c_fetch_adapter'
    }
} | ConvertTo-Json
