#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[D-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$AssessmentUid = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_regroup_repair_v5_inspection_wrong_samsung_boundary'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_regroup_repair_v5_inspection_runtime_not_cold'

$micronDrive = $MicronDriveLetter + ':'
$evidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRGR5'
$deploymentPath = Join-Path $micronDrive `
    'NLL\E\P3SRGR5D\deployment.receipt.json'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidRegroupRepair-v5'
$activePointerPath = Join-Path $evidenceRoot 'active-run.pointer.json'

Assert-True (
    (Test-Path -LiteralPath $evidenceRoot -PathType Container) -and
    (Test-Path -LiteralPath $deploymentPath -PathType Leaf) -and
    (Test-Path -LiteralPath $runtimeRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $activePointerPath)
) 'phase3b2_regroup_repair_v5_inspection_boundary_invalid'

$deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-repair-deployment/v5' -and
    [int]$deployment.observedRegroupBattleResult -eq 6 -and
    [int]$deployment.legacyRetryBattleResultPreserved -eq 4 -and
    [int]$deployment.selectedManagerPassedCount -eq 101 -and
    [int]$deployment.selectedManagerFailedCount -eq 0 -and
    $deployment.infoOnlyRuntimeFileLogging -and
    $deployment.markerOnlyEvidenceEnabled -and
    -not $deployment.rawDebugRequestLoggingEnabled -and
    -not $deployment.practiceSemanticsModified -and
    (Get-Sha256Hex (Join-Path $runtimeRoot 'db.json')) -ceq
        [string]$deployment.baselineDatabaseSha256 -and
    (Get-Sha256Hex (Join-Path $runtimeRoot 'EpinelPS.exe')) -ceq
        [string]$deployment.serverExeSha256 -and
    (Get-Sha256Hex (Join-Path $runtimeRoot 'EpinelPS.dll')) -ceq
        [string]$deployment.appliedServerDllSha256 -and
    (Get-Sha256Hex (Join-Path $runtimeRoot 'log4net.config')) -ceq
        [string]$deployment.infoLogConfigSha256
) 'phase3b2_regroup_repair_v5_deployment_invalid'

if ([string]::IsNullOrWhiteSpace($AssessmentUid)) {
    $runs = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory |
        Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName `
                'completion.receipt.json') -PathType Leaf
        } | Sort-Object LastWriteTimeUtc -Descending)
    Assert-True ($runs.Count -eq 1) `
        'phase3b2_regroup_repair_v5_completed_run_cardinality_invalid'
    $runRoot = $runs[0].FullName
}
else {
    $parsedUid = [Guid]::Empty
    Assert-True ([Guid]::TryParse($AssessmentUid, [ref]$parsedUid) -and
        $parsedUid -ne [Guid]::Empty) `
        'phase3b2_regroup_repair_v5_assessment_uid_invalid'
    $runRoot = Join-Path $evidenceRoot $parsedUid.ToString('D')
}

$completionPath = Join-Path $runRoot 'completion.receipt.json'
$markerPath = Join-Path $runRoot 'regroup.observations.json'
Assert-True (
    (Test-Path -LiteralPath $completionPath -PathType Leaf) -and
    (Test-Path -LiteralPath $markerPath -PathType Leaf)
) 'phase3b2_regroup_repair_v5_completed_evidence_missing'

$completion = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$observations = @($marker.observations)

Assert-True (
    $completion.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-repair-completion/v5' -and
    $marker.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-marker-evidence/v5' -and
    [string]$completion.assessmentUid -ceq [string]$marker.assessmentUid -and
    [Guid]::Parse([string]$completion.assessmentUid) -ne [Guid]::Empty -and
    $completion.runtimeColdAfterCompletion -and
    $completion.databaseRestored -and
    $completion.hostsRestored -and
    $completion.extensionFirewallRemoved -and
    $completion.markerOnlyEvidencePersisted -and
    -not $completion.rawSensitiveServerLogPersisted -and
    -not $completion.rawRequestPayloadPersistedAfterCompletion -and
    $completion.runtimeAppLogsRemoved -and
    [int]$completion.debugRuntimeLogLineCount -eq 0 -and
    [int]$completion.rawRequestPayloadPatternCount -eq 0 -and
    -not $marker.rawRequestPayloadPersisted -and
    (Get-Sha256Hex $markerPath) -ceq
        [string]$completion.markerEvidenceSha256 -and
    [int]$marker.observationCount -eq $observations.Count -and
    [int]$completion.regroupObservationCount -eq $observations.Count
) 'phase3b2_regroup_repair_v5_completion_or_marker_invalid'

$invalidObservationCount = @($observations | Where-Object {
        [string]$_.route -cne 'soloraid_trial_setdamage' -or
        [int]$_.battleResult -notin @(4, 6)
    }).Count
$observedRegroupCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 6
    }).Count
$observedLegacyRetryCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 4
    }).Count
$duplicateSequenceCount = @($observations | Group-Object sequence |
    Where-Object Count -ne 1).Count
$metricsBefore = $completion.trialMetricsBefore
$metricsAfter = $completion.trialMetricsAfter
$joinDelta = [long]$metricsAfter.raidJoinCount -
    [long]$metricsBefore.raidJoinCount
$recordDelta = [long]$metricsAfter.recordCount -
    [long]$metricsBefore.recordCount
$damageDelta = [long]$metricsAfter.totalDamage -
    [long]$metricsBefore.totalDamage
$verified = $observedRegroupCount -gt 0 -and
    $invalidObservationCount -eq 0 -and
    $duplicateSequenceCount -eq 0 -and
    $joinDelta -eq 0 -and $recordDelta -eq 0 -and $damageDelta -eq 0 -and
    $completion.regroupNonConsumptionVerified

[pscustomobject]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-solo-raid-regroup-repair-inspection/v5'
    inspectedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = [string]$completion.assessmentUid
    deploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
    completionReceiptSha256 = Get-Sha256Hex $completionPath
    markerEvidenceSha256 = Get-Sha256Hex $markerPath
    observationCount = $observations.Count
    observations = $observations
    observedRegroupResultCount = $observedRegroupCount
    observedLegacyRetryResultCount = $observedLegacyRetryCount
    invalidObservationCount = $invalidObservationCount
    duplicateSequenceCount = $duplicateSequenceCount
    trialMetricsBefore = $metricsBefore
    trialMetricsAfter = $metricsAfter
    raidJoinCountDelta = $joinDelta
    recordCountDelta = $recordDelta
    totalDamageDelta = $damageDelta
    rawRequestPayloadPersisted = $false
    runtimeAppLogsRemoved = [bool]$completion.runtimeAppLogsRemoved
    regroupNonConsumptionVerified = $verified
    verdictCode = if ($verified) {
        'observed_regroup_6_is_non_consuming_and_reentry_safe'
    }
    elseif ($observations.Count -eq 0) {
        'no_regroup_observation_unresolved'
    }
    else {
        'regroup_non_consumption_not_verified'
    }
    nextStepCode = if ($verified) {
        'promote_v5_as_regroup_semantics_candidate_after_operator_review'
    }
    else {
        'preserve_v5_evidence_and_classify_without_retry'
    }
} | ConvertTo-Json -Depth 10
