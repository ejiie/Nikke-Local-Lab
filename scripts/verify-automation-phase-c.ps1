[CmdletBinding()]
param(
    [string]$DotnetPath = 'E:\Program Files\dotnet\dotnet.exe',
    [string]$NodePath = 'C:\Users\nlloperator\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe',
    [string]$LiveAcceptanceReceiptPath = '',
    [string]$OperatorAcceptanceReceiptPath = '',
    [string]$ReceiptPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-PhaseC {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$verificationUid = [guid]::NewGuid().ToString('D')
if (-not (Test-Path -LiteralPath $DotnetPath -PathType Leaf)) {
    $DotnetPath = (Get-Command dotnet -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
    $NodePath = (Get-Command node -ErrorAction Stop).Source
}
$env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
$env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_NOLOGO = '1'

if ([string]::IsNullOrWhiteSpace($LiveAcceptanceReceiptPath)) {
    $root = Join-Path $repositoryRoot 'artifacts\automation\phase-c-live'
    Assert-PhaseC (Test-Path -LiteralPath $root -PathType Container) `
        'automation_phase_c_live_receipt_missing'
    $candidates = @(Get-ChildItem -LiteralPath $root -File -Filter '*.receipt.json' |
        Sort-Object LastWriteTimeUtc -Descending)
    Assert-PhaseC ($candidates.Count -gt 0) 'automation_phase_c_live_receipt_missing'
    $candidate = $candidates[0]
    $LiveAcceptanceReceiptPath = $candidate.FullName
}
Assert-PhaseC (Test-Path -LiteralPath $LiveAcceptanceReceiptPath -PathType Leaf) `
    'automation_phase_c_live_receipt_missing'
$live = Get-Content -LiteralPath $LiveAcceptanceReceiptPath -Raw | ConvertFrom-Json
Assert-PhaseC ($live.contractId -ceq 'nll/automation-phase-c-live-acceptance/v1') `
    'automation_phase_c_live_contract_invalid'
Assert-PhaseC ($live.verdictCode -ceq 'phase_c_snapshot_storage_live_acceptance_passed') `
    'automation_phase_c_live_verdict_invalid'
Assert-PhaseC ($live.postgresVersion -ceq 'postgres (PostgreSQL) 17.11') `
    'automation_phase_c_live_postgres_invalid'
Assert-PhaseC ([bool]$live.completeSnapshotBecameCurrent) `
    'automation_phase_c_complete_pointer_unverified'
Assert-PhaseC ([bool]$live.incompleteSnapshotPreservedWithoutCurrentReplacement) `
    'automation_phase_c_incomplete_replacement_unverified'
Assert-PhaseC ([bool]$live.selectiveImportDiffVerified) `
    'automation_phase_c_selective_diff_unverified'
Assert-PhaseC ($live.snapshotCount -eq 3 -and
    $live.progressionSidecarCount -eq 1 -and
    [bool]$live.progressionSidecarVerified) `
    'automation_phase_c_progression_sidecar_live_unverified'
Assert-PhaseC (-not [bool]$live.rawSourcePersisted) `
    'automation_phase_c_raw_source_persisted'
Assert-PhaseC (-not [bool]$live.credentialOrSessionPersisted) `
    'automation_phase_c_credential_persisted'
Assert-PhaseC ([bool]$live.cleanupVerified -and
    $live.postgresProcessCountAfter -eq 0 -and $live.portListenerCountAfter -eq 0) `
    'automation_phase_c_live_cleanup_unverified'

if ([string]::IsNullOrWhiteSpace($OperatorAcceptanceReceiptPath)) {
    $operatorRoot = Join-Path $repositoryRoot 'artifacts\automation\phase-c-operator'
    Assert-PhaseC (Test-Path -LiteralPath $operatorRoot -PathType Container) `
        'automation_phase_c_operator_receipt_missing'
    $operatorCandidates = @(Get-ChildItem -LiteralPath $operatorRoot -File -Recurse `
        -Filter 'operator-acceptance.receipt.json' | Sort-Object LastWriteTimeUtc -Descending)
    Assert-PhaseC ($operatorCandidates.Count -gt 0) `
        'automation_phase_c_operator_receipt_missing'
    $OperatorAcceptanceReceiptPath = $operatorCandidates[0].FullName
}
Assert-PhaseC (Test-Path -LiteralPath $OperatorAcceptanceReceiptPath -PathType Leaf) `
    'automation_phase_c_operator_receipt_missing'
$operator = Get-Content -LiteralPath $OperatorAcceptanceReceiptPath -Raw | ConvertFrom-Json
Assert-PhaseC ($operator.contractId -ceq 'nll/phase-c-operator-fetch-acceptance/v1') `
    'automation_phase_c_operator_contract_invalid'
Assert-PhaseC ($operator.snapshotCompleteness -ceq 'incomplete' -and
    @($operator.snapshotReasonCodes) -ccontains 'stage_clear_historys_unavailable' -and
    @($operator.snapshotReasonCodes) -cnotcontains 'progression_summary_missing' -and
    [bool]$operator.progressionSidecarRegistered -and
    $operator.progressionTriggerCount -eq 4773) `
    'automation_phase_c_operator_completeness_invalid'
Assert-PhaseC ($operator.rosterCount -eq 193 -and $operator.detailCount -eq 193 -and
    $operator.characterCount -eq 193) 'automation_phase_c_operator_coverage_invalid'
Assert-PhaseC ($operator.localEditSynchroLevel -eq ($operator.sourceSynchroLevel + 1) -and
    $operator.detectedDiffCount -eq 1 -and
    [bool]$operator.selectedApplyRestoredSourceValue -and
    $operator.sameCaptureSecondObservationDiffCount -eq 0) `
    'automation_phase_c_operator_diff_apply_invalid'
Assert-PhaseC ($operator.sourceCommanderLevel -eq 896 -and
    $operator.localCommanderLevel -eq ($operator.sourceCommanderLevel + 1) -and
    $operator.commanderLobbyDiffCount -eq 1 -and
    [bool]$operator.commanderLobbySelectedApplyVerified -and
    [bool]$operator.unselectedLobbyFieldsPreserved) `
    'automation_phase_c_operator_commander_lobby_apply_invalid'
Assert-PhaseC (-not [bool]$operator.freshExternalRefetchPerformed -and
    -not [bool]$operator.rawSourcePersisted -and
    -not [bool]$operator.officialUserIdentifierPersisted -and
    -not [bool]$operator.credentialOrSessionPersisted) `
    'automation_phase_c_operator_source_boundary_invalid'
Assert-PhaseC (-not [bool]$operator.goldenModified -and
    -not [bool]$operator.gameRuntimeModified) `
    'automation_phase_c_operator_runtime_mutation_detected'
$operatorOrchestrationPath = Join-Path `
    (Split-Path -Parent $OperatorAcceptanceReceiptPath) 'orchestration.receipt.json'
Assert-PhaseC (Test-Path -LiteralPath $operatorOrchestrationPath -PathType Leaf) `
    'automation_phase_c_operator_orchestration_receipt_missing'
$operatorOrchestration = Get-Content -LiteralPath $operatorOrchestrationPath -Raw |
    ConvertFrom-Json
Assert-PhaseC ($operatorOrchestration.contractId -ceq
    'nll/phase-c-operator-fetch-orchestration/v1' -and
    $operatorOrchestration.verdictCode -ceq
    'phase_c_operator_fresh_same_capture_progression_acceptance_passed' -and
    $operatorOrchestration.testExitCode -eq 0 -and
    [bool]$operatorOrchestration.progressionSameCaptureRequested -and
    [bool]$operatorOrchestration.progressionObservationPersisted -and
    [bool]$operatorOrchestration.freshExternalRefetchObserved -and
    [bool]$operatorOrchestration.controlCenterBrowserAcceptanceRequested -and
    [bool]$operatorOrchestration.controlCenterBrowserAcceptanceVerified -and
    [bool]$operatorOrchestration.cleanupVerified -and
    $operatorOrchestration.postgresProcessCountAfter -eq 0 -and
    $operatorOrchestration.portListenerCountAfter -eq 0 -and
    [bool]$operatorOrchestration.decodedStaticDataRemoved) `
    'automation_phase_c_operator_orchestration_invalid'
$operatorArtifactRoot = Split-Path -Parent $OperatorAcceptanceReceiptPath
$browserReceiptPath = Join-Path $operatorArtifactRoot 'control-center-browser.receipt.json'
$browserScreenshotPath = Join-Path $operatorArtifactRoot 'control-center-after-apply.png'
Assert-PhaseC ((Test-Path -LiteralPath $browserReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $browserScreenshotPath -PathType Leaf)) `
    'automation_phase_c_control_center_browser_artifact_missing'
$browser = Get-Content -LiteralPath $browserReceiptPath -Raw | ConvertFrom-Json
$browserReceiptSha256 = (Get-FileHash -LiteralPath $browserReceiptPath `
    -Algorithm SHA256).Hash.ToLowerInvariant()
$browserScreenshotSha256 = (Get-FileHash -LiteralPath $browserScreenshotPath `
    -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-PhaseC ($browser.contractId -ceq
    'nll/phase-c-control-center-browser-acceptance/v1' -and
    $browser.verdictCode -ceq 'control_center_register_diff_selective_apply_passed' -and
    [bool]$browser.registeredThroughControlCenter -and
    $browser.sourceCommanderLevel -eq 896 -and
    $browser.localCommanderLevelBeforeDiff -eq 897 -and
    $browser.commanderDiffCount -eq 1 -and
    [bool]$browser.commanderSelectedApplyVerified -and
    [bool]$browser.unselectedLobbyFieldsPreserved -and
    $browser.browserEngine -ceq 'playwright_chromium' -and
    [bool]$browser.browserHeadless -and
    $browser.screenshotSha256 -ceq $browserScreenshotSha256 -and
    $operatorOrchestration.controlCenterBrowserReceiptSha256 -ceq $browserReceiptSha256 -and
    $operatorOrchestration.controlCenterScreenshotSha256 -ceq $browserScreenshotSha256) `
    'automation_phase_c_control_center_browser_acceptance_invalid'

$contracts = [ordered]@{
    'contracts\fetched-account-snapshot.schema.json' =
        'nll/fetched-account-snapshot/v1'
    'contracts\fetched-progression-observation.schema.json' =
        'nll/fetched-progression-observation/v1'
    'contracts\fetched-progression-observation-v2.schema.json' =
        'nll/fetched-progression-observation/v2'
    'contracts\phase-c-same-capture-request.schema.json' =
        'nll/phase-c-same-capture-request/v1'
    'contracts\phase-c-same-capture-input-inspection.schema.json' =
        'nll/phase-c-same-capture-input-inspection/v1'
    'contracts\phase-c-same-capture-input-inspection-v2.schema.json' =
        'nll/phase-c-same-capture-input-inspection/v2'
}
foreach ($entry in $contracts.GetEnumerator()) {
    $schema = Get-Content -LiteralPath (Join-Path $repositoryRoot $entry.Key) -Raw |
        ConvertFrom-Json
    Assert-PhaseC ($schema.properties.contractId.const -ceq $entry.Value) `
        'automation_phase_c_contract_invalid'
}

$migrationPath = Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Persistence.PostgreSql\Migrations\V0009__fetched_account_snapshot.sql'
$migration = Get-Content -LiteralPath $migrationPath -Raw
Assert-PhaseC ($migration.Contains('CREATE TABLE lab_profile.fetched_account_snapshot')) `
    'automation_phase_c_snapshot_table_missing'
Assert-PhaseC ($migration.Contains('credentialOrSessionPersisted')) `
    'automation_phase_c_credential_guard_missing'
Assert-PhaseC ($migration.Contains('trg_fetched_account_snapshot_immutable')) `
    'automation_phase_c_immutability_guard_missing'
Assert-PhaseC (-not $migration.Contains('UPDATE lab_profile.profile_template_revision')) `
    'automation_phase_c_game_revision_mutation_detected'

$progressionMigrationPath = Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Persistence.PostgreSql\Migrations\V0010__fetched_progression_observation.sql'
$progressionMigration = Get-Content -LiteralPath $progressionMigrationPath -Raw
Assert-PhaseC ($progressionMigration.Contains(
    'CREATE TABLE lab_profile.fetched_progression_observation')) `
    'automation_phase_c_progression_table_missing'
foreach ($guard in @(
        'credentialOrSessionPersisted',
        'officialUserIdentifierPersisted',
        'rawSourcePersisted',
        'rawSourcePathPersisted',
        'rawSourceHashPersisted',
        'trg_fetched_progression_observation_immutable')) {
    Assert-PhaseC ($progressionMigration.Contains($guard)) `
        'automation_phase_c_progression_storage_guard_missing'
}
Assert-PhaseC (-not $progressionMigration.Contains(
    'UPDATE lab_profile.profile_template_revision')) `
    'automation_phase_c_progression_game_revision_mutation_detected'

$profileTests = Join-Path $repositoryRoot `
    'tests\NikkeLocalLab.ProfileImport.UnitTests\NikkeLocalLab.ProfileImport.UnitTests.csproj'
$adminTests = Join-Path $repositoryRoot `
    'tests\NikkeLocalLab.Admin.Api.UnitTests\NikkeLocalLab.Admin.Api.UnitTests.csproj'
$postgresTests = Join-Path $repositoryRoot `
    'tests\NikkeLocalLab.PostgreSql.IntegrationTests\NikkeLocalLab.PostgreSql.IntegrationTests.csproj'
foreach ($project in @($profileTests, $adminTests, $postgresTests)) {
    & $DotnetPath restore $project --locked-mode --ignore-failed-sources `
        -p:NuGetAudit=false --nologo | Out-Host
    Assert-PhaseC ($LASTEXITCODE -eq 0) 'automation_phase_c_restore_failed'
}
& $DotnetPath test $profileTests --configuration Release --no-restore --nologo | Out-Host
Assert-PhaseC ($LASTEXITCODE -eq 0) 'automation_phase_c_profile_tests_failed'
& $DotnetPath test $adminTests --configuration Release --no-restore --nologo | Out-Host
Assert-PhaseC ($LASTEXITCODE -eq 0) 'automation_phase_c_admin_tests_failed'
& $DotnetPath test $postgresTests --configuration Release --no-restore --nologo `
    --filter 'FullyQualifiedName~PostgreSqlAccountWorkspaceMigrationTests' | Out-Host
Assert-PhaseC ($LASTEXITCODE -eq 0) 'automation_phase_c_migration_tests_failed'

$editorScript = Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Admin.Api\wwwroot\editor\editor.js'
& $NodePath --check $editorScript | Out-Host
Assert-PhaseC ($LASTEXITCODE -eq 0) 'automation_phase_c_editor_syntax_invalid'

$endpointSource = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Admin.Api\AdminApiEndpoints.cs') -Raw
foreach ($route in @(
        '/accounts/{accountUid}/fetched-snapshots',
        '/fetched-snapshots/{snapshotUid}',
        '/fetched-snapshots/{snapshotUid}/lobby/diff',
        '/fetched-snapshots/{snapshotUid}/lobby/apply',
        '/import-drafts/{draftUid}/diff',
        '/import-drafts/{draftUid}/apply')) {
    Assert-PhaseC ($endpointSource.Contains($route)) 'automation_phase_c_route_missing'
}
$cliSource = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Import.Cli\Program.cs') -Raw
Assert-PhaseC ($cliSource.Contains('fetched-account-snapshot-materialize')) `
    'automation_phase_c_materializer_command_missing'
Assert-PhaseC ($cliSource.Contains('fetched-progression-observation-materialize')) `
    'automation_phase_c_progression_materializer_command_missing'
$progressionSource = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Import.Profile\FetchedProgressionObservationV2.cs') -Raw
foreach ($guard in @(
        'RawSourcePersisted: false',
        'RawSourcePathPersisted: false',
        'RawSourceHashPersisted: false',
        'stage_clear_historys_unavailable',
        'progression_candidate_main_quest_drift',
        'progression_candidate_trigger_drift')) {
    Assert-PhaseC ($progressionSource.Contains($guard)) `
        'automation_phase_c_progression_boundary_missing'
}
$sameCaptureScriptPath = Join-Path $repositoryRoot `
    'scripts\test-nll-phase-c-same-capture-inputs.ps1'
Assert-PhaseC (Test-Path -LiteralPath $sameCaptureScriptPath -PathType Leaf) `
    'automation_phase_c_same_capture_preflight_missing'
$sameCaptureSource = Get-Content -LiteralPath $sameCaptureScriptPath -Raw
foreach ($guard in @(
        'raw_fetch_predates_request',
        'trigger_archive_predates_request',
        'matching_trigger_archive_not_unique',
        'operator_selected_progression_template',
        'ProgressionTemplateArchivePath',
        'reused_stable_progression',
        'RequireFreshTriggerArchive',
        'same_capture_inputs_ready_for_offline_materialization',
        'officialLoginAutomated = $false',
        'officialFetchAutomated = $false',
        'rawSourcePathPersisted = $false',
        'rawSourceHashPersisted = $false')) {
    Assert-PhaseC ($sameCaptureSource.Contains($guard)) `
        'automation_phase_c_same_capture_guard_missing'
}
$fixedRawFetchPath =
    'C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json'
$fixedTriggerRoot =
    'C:\Users\nlloperator\AppData\LocalLow\com_proximabeta\NIKKE'
$staleMigratedRawPath =
    'C:\Users\nlloperator\Downloads\NLL-Imported-Samsung\nikke_full_scroll_result.json'
$wrongDotTriggerRoot =
    'C:\Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE'
Assert-PhaseC ($sameCaptureSource.Contains($fixedRawFetchPath) -and
    $sameCaptureSource.Contains($fixedTriggerRoot) -and
    -not $sameCaptureSource.Contains($staleMigratedRawPath) -and
    -not $sameCaptureSource.Contains($wrongDotTriggerRoot)) `
    'automation_phase_c_same_capture_fixed_path_drift'
$operatorOrchestratorSource = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'scripts\invoke-nll-phase-c-operator-fetch-acceptance.ps1') -Raw
foreach ($guard in @(
        'SameCaptureInputReceiptPath',
        'RunControlCenterBrowserAcceptance',
        'fetched-progression-observation-materialize',
        '--progression-observation',
        '([DateTimeOffset]$sourceReceipt.extractedAtUtc).ToUniversalTime()',
        'phase_c_operator_fresh_same_capture_progression_acceptance_passed')) {
    Assert-PhaseC ($operatorOrchestratorSource.Contains($guard)) `
        'automation_phase_c_same_capture_orchestration_missing'
}
$adminHostSource = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Admin.Api\AdminApiHost.cs') -Raw
Assert-PhaseC ($adminHostSource.Contains(
    'MaximumRequestBodyBytes { get; init; } = 4_194_304')) `
    'automation_phase_c_complete_registration_body_limit_missing'
Assert-PhaseC `
    (-not $operatorOrchestratorSource.Contains('[string]$sourceReceipt.extractedAtUtc')) `
    'automation_phase_c_progression_capture_time_precision_regressed'
Assert-PhaseC ($operatorOrchestratorSource.Contains($fixedRawFetchPath) -and
    $operatorOrchestratorSource.Contains($fixedTriggerRoot) -and
    -not $operatorOrchestratorSource.Contains($staleMigratedRawPath) -and
    -not $operatorOrchestratorSource.Contains($wrongDotTriggerRoot)) `
    'automation_phase_c_acceptance_fixed_path_drift'
$freshFetchLauncherPath = Join-Path $repositoryRoot `
    'scripts\invoke-nll-phase-c-fresh-account-fetch.ps1'
$fixedPathDocumentPath = Join-Path $repositoryRoot `
    'docs\operations\PHASE_C_FRESH_CAPTURE_PATHS.md'
$envExamplePath = Join-Path $repositoryRoot '.env.example'
foreach ($requiredPath in @(
        $freshFetchLauncherPath,
        $fixedPathDocumentPath,
        $envExamplePath)) {
    Assert-PhaseC (Test-Path -LiteralPath $requiredPath -PathType Leaf) `
        'automation_phase_c_fresh_fetch_path_authority_missing'
}
$freshFetchLauncher = Get-Content -LiteralPath $freshFetchLauncherPath -Raw
foreach ($fixedValue in @(
        $fixedRawFetchPath,
        'C:\Users\nlloperator\Downloads\NLL-Imported-Samsung\getFromBlaLink.py',
        'C:\Users\nlloperator\Downloads\NLL-Imported-Samsung\.venv\Scripts\python.exe',
        "Join-Path `$repositoryRoot '.env'",
        '[Microsoft.VisualBasic.Interaction]::InputBox',
        'playwright install --dry-run chromium',
        'playwright install chromium',
        'chrome-win64\chrome.exe',
        'uidAcceptedFromRuntimeInput = $true',
        'uidPersistedByLauncher = $false')) {
    Assert-PhaseC ($freshFetchLauncher.Contains($fixedValue)) `
        'automation_phase_c_fresh_fetch_launcher_path_drift'
}
$fixedPathDocument = Get-Content -LiteralPath $fixedPathDocumentPath -Raw
Assert-PhaseC ($fixedPathDocument.Contains($fixedRawFetchPath) -and
    $fixedPathDocument.Contains($fixedTriggerRoot) -and
    $fixedPathDocument.Contains('com.proximabeta') -and
    $fixedPathDocument.Contains('com_proximabeta')) `
    'automation_phase_c_fixed_path_document_invalid'
$envExample = Get-Content -LiteralPath $envExamplePath -Raw
foreach ($envName in @(
        'NIKKE_BLABLA_ID=',
        'NIKKE_BLABLA_PW=',
        'NIKKE_REGION=JP/KR/NA/SEA/Global')) {
    Assert-PhaseC ($envExample.Contains($envName)) `
        'automation_phase_c_env_example_field_missing'
}
Assert-PhaseC (-not $envExample.Contains('NIKKE_UID=')) `
    'automation_phase_c_uid_must_be_runtime_input'
$progressionAcceptancePath = Join-Path $repositoryRoot `
    'artifacts\automation\phase-c-progression\1d689f54-4d8b-453f-b0f0-ef0ded6133eb.receipt.json'
Assert-PhaseC (Test-Path -LiteralPath $progressionAcceptancePath -PathType Leaf) `
    'automation_phase_c_progression_acceptance_missing'
$progressionAcceptance = Get-Content -LiteralPath $progressionAcceptancePath -Raw |
    ConvertFrom-Json
Assert-PhaseC ($progressionAcceptance.contractId -ceq
    'nll/phase-c-progression-read-only-acceptance/v1' -and
    $progressionAcceptance.progressionContractId -ceq
    'nll/fetched-progression-observation/v2' -and
    $progressionAcceptance.observedComponentCount -eq 2 -and
    $progressionAcceptance.derivedComponentCount -eq 2 -and
    $progressionAcceptance.unavailableComponentCount -eq 1 -and
    $progressionAcceptance.mainQuestCompletedCount -eq 595 -and
    $progressionAcceptance.triggerCount -eq 4786 -and
    [bool]$progressionAcceptance.crossCaptureBindingRejected -and
    -not [bool]$progressionAcceptance.currentFetchedSnapshotMerged -and
    -not [bool]$progressionAcceptance.officialOutboundUsed) `
    'automation_phase_c_progression_acceptance_invalid'
$profileDraftCliSource = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Import.Cli\ProfileDraftImportCli.cs') -Raw
Assert-PhaseC ($profileDraftCliSource.Contains('output-draft') -and
    $profileDraftCliSource.Contains('sanitized_draft_exported=true')) `
    'automation_phase_c_draft_export_missing'
$profileServiceSource = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Persistence.PostgreSql\PostgreSqlProfileManagementService.cs') -Raw
Assert-PhaseC ($profileServiceSource.Contains('LoadCoreLevelNotApplicableAsync') -and
    $profileServiceSource.Contains('LocalProfileFact<int>.NotApplicable()')) `
    'automation_phase_c_core_not_applicable_mapping_missing'
$snapshotStoreSource = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Persistence.PostgreSql\PostgreSqlFetchedAccountSnapshotStore.cs') -Raw
Assert-PhaseC ($snapshotStoreSource.Contains('COALESCE(') -and
    $snapshotStoreSource.Contains('workspace.fetched_snapshot_uid') -and
    $snapshotStoreSource.Contains('fetched_progression_observation')) `
    'automation_phase_c_incomplete_snapshot_null_guard_missing'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/automation-phase-c-foundation-verification/v1'
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    verificationUid = $verificationUid
    contractCount = $contracts.Count
    migrationVersion = 10
    sourceFreeMaterializerPresent = $true
    basicInfoWhitelistPresent = $true
    immutableSnapshotStoragePresent = $true
    completeOnlyCurrentPointerPresent = $true
    existingSelectiveDiffApplyReused = $true
    controlCenterRegistrationPresent = $true
    commanderLobbyProjectionPresent = $true
    commanderLobbyDiffCount = [int]$operator.commanderLobbyDiffCount
    commanderLobbySelectedApplyVerified = [bool]$operator.commanderLobbySelectedApplyVerified
    unselectedLobbyFieldsPreserved = [bool]$operator.unselectedLobbyFieldsPreserved
    controlCenterBrowserAcceptanceVerified = $true
    controlCenterBrowserReceiptSha256 = $browserReceiptSha256
    controlCenterScreenshotSha256 = $browserScreenshotSha256
    liveAcceptanceUid = [string]$live.acceptanceUid
    liveAcceptanceReceiptSha256 =
        (Get-FileHash -LiteralPath $LiveAcceptanceReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    operatorAcceptanceUid = [string]$operatorOrchestration.acceptanceUid
    operatorAcceptanceReceiptSha256 =
        (Get-FileHash -LiteralPath $OperatorAcceptanceReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    operatorOrchestrationReceiptSha256 =
        (Get-FileHash -LiteralPath $operatorOrchestrationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    gameRuntimeModified = $false
    goldenModified = $false
    phaseCOperatorRefetchExecuted = [bool]$operatorOrchestration.freshExternalRefetchObserved
    phaseCOperatorSameCaptureAcceptanceExecuted = $true
    freshExternalRefetchPerformed = $false
    freshExternalRefetchObserved = [bool]$operatorOrchestration.freshExternalRefetchObserved
    stableProgressionTemplateAccepted = $true
    detailedProgressionSidecarRegistered = [bool]$operator.progressionSidecarRegistered
    verdictCode = 'phase_c_completed'
    progressionV2ContractPresent = $true
    progressionV2PostgreSqlStoragePresent = $true
    progressionV2ControlCenterRegistrationPresent = $true
    sameCaptureRequestContractPresent = $true
    sameCaptureInputInspectionContractPresent = $true
    sameCaptureFailClosedPreflightPresent = $true
    sameCaptureProgressionOrchestrationPresent = $true
    fixedCapturePathAuthorityPresent = $true
    freshFetchEnvLauncherPresent = $true
    progressionHistoricalReadOnlyAcceptanceUid = [string]$progressionAcceptance.acceptanceUid
    progressionHistoricalReadOnlyAcceptanceReceiptSha256 =
        (Get-FileHash -LiteralPath $progressionAcceptancePath -Algorithm SHA256).Hash.ToLowerInvariant()
    crossCaptureProgressionBindingRejected = $true
    nextStepCode = 'begin_phase_d_execution_program'
}
$receiptJson = $receipt | ConvertTo-Json -Depth 6
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $receiptRoot = Join-Path $repositoryRoot 'artifacts\automation\phase-c'
    New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
    $ReceiptPath = Join-Path $receiptRoot ($verificationUid + '.receipt.json')
}
[IO.File]::WriteAllText(
    $ReceiptPath, $receiptJson, [Text.UTF8Encoding]::new($false))
$receiptJson
