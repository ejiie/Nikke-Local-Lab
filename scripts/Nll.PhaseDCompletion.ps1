# Completion helpers: pure legacy derivation and read-only persistence proof validation.
# Cleanup is operational; optional battle observations are not cleanup proof.
function ConvertTo-PhaseDCompletionText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $result = $Text.Replace("`r`n", "`n")
    $missingMarkerGuard = @'
else {
    Assert-True (Test-Path -LiteralPath $markerEvidencePath -PathType Leaf) `
        'phase3b2_ranking_prefix_v9_marker_missing_after_partial_completion'
'@
    $emptyEvidence = @'
else {
    # No application log and no previous observation receipt means unobserved,
    # not failed cleanup or successful gameplay verification. Never enable raw logging.
    $observations = @()
    $scoreObservations = @()
    $damageSourceObservations = @()
    $markerEvidence = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-marker-evidence/v9'
        assessmentUid = [string]$pointer.assessmentUid
        observationCount = 0; observations = @()
        scoreObservationCount = 0; scoreObservations = @()
        damageSourceObservationCount = 0; damageSourceObservations = @()
        diagnosticObservationStatus = 'not_observed'
        rawRequestPayloadPersisted = $false
    }
    Write-AtomicUtf8NoBom $markerEvidencePath `
        (($markerEvidence | ConvertTo-Json -Depth 6) + "`n")
}
'@
    $observationStatus = @'
    diagnosticObservationStatus = if ($observations.Count -gt 0 -or
        $scoreObservations.Count -gt 0 -or $damageSourceObservations.Count -gt 0) {
        'observed'
    } else { 'not_observed' }
'@
    $replacements = @(
        @($missingMarkerGuard, 'elseif (Test-Path -LiteralPath $markerEvidencePath -PathType Leaf) {'),
        @('$markerEvidenceSha256 = Get-Sha256Hex $markerEvidencePath',
            ($emptyEvidence + "`n" + '$markerEvidenceSha256 = Get-Sha256Hex $markerEvidencePath')),
        @('$battleResultClassificationValid = $unsupportedBattleResultCount -eq 0',
            '$battleResultClassificationValid = $observations.Count -gt 0 -and $unsupportedBattleResultCount -eq 0'),
        @('    markerOnlyEvidencePersisted = $true',
            ($observationStatus + "`n" + '    markerOnlyEvidencePersisted = $true'))
    )
    foreach ($pair in $replacements) {
        $old = $pair[0].Replace("`r`n", "`n")
        $new = $pair[1].Replace("`r`n", "`n")
        if ([regex]::Matches($result, [regex]::Escape($old)).Count -ne 1) {
            throw 'phase_d_completion_diagnostics_template_invalid'
        }
        $result = $result.Replace($old, $new)
    }
    $parseErrors = $null
    $tokens = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($result, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'phase_d_completion_diagnostics_derivation_invalid' }
    return $result
}

# Shared completion/recovery proof validator. Explicit context inputs; no ambient
# launch variables, DB writes or process actions. Included in the existing seal member.
function Assert-PhaseDPersistenceProof([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw $Code }
}
function Get-PhaseDPersistenceProofHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-PhaseDSoloRaidPersistenceReceipt {
    param(
        [string]$Path,
        [string]$LaunchRoot,
        [string]$LaunchContextUid,
        [string]$PendingPayloadPath,
        [string]$CaptureReceiptPath
    )
    Assert-PhaseDPersistenceProof (Test-Path -LiteralPath $Path -PathType Leaf) `
        'phase_d_raid_state_persistence_receipt_missing'
    Assert-PhaseDPersistenceProof `
        ((Test-Path -LiteralPath $PendingPayloadPath -PathType Leaf) -and
         (Test-Path -LiteralPath $CaptureReceiptPath -PathType Leaf)) `
        'phase_d_raid_state_persistence_proof_missing'
    $receipt = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $pending = Get-Content -LiteralPath $PendingPayloadPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $capture = Get-Content -LiteralPath $CaptureReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $context = Get-Content -LiteralPath (Join-Path $LaunchRoot 'launch-context.json') `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    $headRevisionUid = [Guid]::Empty
    $headRevisionPresent = $null -ne $receipt.headRevisionUid -and
        [Guid]::TryParse([string]$receipt.headRevisionUid, [ref]$headRevisionUid) -and
        $headRevisionUid -ne [Guid]::Empty
    $resultCode = [string]$receipt.resultCode
    $expectedHeadReceipt = if ($null -eq $receipt.expectedHeadRevisionUid) {
        ''
    } else { [string]$receipt.expectedHeadRevisionUid }
    $expectedHeadCapture = if ($null -eq $capture.expectedHeadRevisionUid) {
        ''
    } else { [string]$capture.expectedHeadRevisionUid }
    $proofVersion = if ($capture.contractId -ceq 'nll/phase-d-classic-solo-raid-state-capture/v2') { 'v2' } else { 'v1' }
    if ($context.PSObject.Properties.Name -contains 'runtimePersistenceContractId') {
        Assert-PhaseDPersistenceProof ($context.runtimePersistenceContractId -ceq 'nll/runtime-persistence/v2' -and
            $proofVersion -ceq 'v2') 'phase_d_preferences_persistence_downgrade'
    }
    if ($proofVersion -ceq 'v2') {
        $preferencesHead = [guid]::Empty
        Assert-PhaseDPersistenceProof `
            ([string]$capture.selectedWeaknessCode -cin @('iron','water','fire','wind','electric') -and
             [string]$capture.selectedWeaknessCode -ceq [string]$context.weaknessCode -and
             [string]$receipt.selectedWeaknessCode -ceq [string]$capture.selectedWeaknessCode -and
             [string]$pending.capture.selectedWeaknessCode -ceq [string]$capture.selectedWeaknessCode -and
             [string]$capture.preferencesPendingSha256 -cmatch '^[0-9a-f]{64}$' -and
             [string]$receipt.preferencesPendingSha256 -ceq [string]$capture.preferencesPendingSha256 -and
             [string]$pending.capture.preferencesPendingSha256 -ceq [string]$capture.preferencesPendingSha256 -and
             [string]$pending.preferences.accountUid -ceq [string]$capture.accountUid -and
             [string]$pending.preferences.launchContextUid -ceq $LaunchContextUid -and
             [string]$pending.preferences.clientBuildCode -ceq [string]$capture.clientBuildCode -and
             [string]$pending.preferences.clientExecutableSha256 -ceq [string]$capture.clientExecutableSha256 -and
             [string]$receipt.preferencesResultCode -cin @('state_advanced','state_unchanged') -and
             [guid]::TryParse([string]$receipt.preferencesHeadRevisionUid, [ref]$preferencesHead) -and
             $preferencesHead -ne [guid]::Empty) 'phase_d_preferences_persistence_proof_invalid'
    }
    Assert-PhaseDPersistenceProof `
        ($receipt.contractId -ceq `
            "nll/phase-d-classic-solo-raid-state-persistence/$proofVersion" -and
         $pending.contractId -ceq `
            "nll/phase-d-classic-solo-raid-state-pending/$proofVersion" -and
         $capture.contractId -ceq `
            "nll/phase-d-classic-solo-raid-state-capture/$proofVersion" -and
         -not [bool]$receipt.quarantined -and
         [string]$receipt.launchContextUid -ceq $LaunchContextUid -and
         [string]$capture.launchContextUid -ceq $LaunchContextUid -and
         [string]$pending.capture.launchContextUid -ceq $LaunchContextUid -and
         [string]$receipt.pendingPayloadSha256 -ceq `
            (Get-PhaseDPersistenceProofHash $PendingPayloadPath) -and
         [string]$receipt.captureReceiptSha256 -ceq `
            (Get-PhaseDPersistenceProofHash $CaptureReceiptPath) -and
         [string]$receipt.accountUid -ceq [string]$capture.accountUid -and
         [string]$receipt.accountUid -ceq [string]$context.accountUid -and
         [string]$receipt.accountRevisionSetSha256 -ceq `
            [string]$capture.accountRevisionSetSha256 -and
         [string]$receipt.accountRevisionSetSha256 -ceq `
            [string]$context.accountRevisionSetSha256 -and
         [int]$receipt.seasonNumber -eq [int]$capture.seasonNumber -and
         [int]$receipt.seasonNumber -eq [int]$context.seasonNumber -and
         [string]$receipt.raidSnapshotUid -ceq `
            [string]$capture.raidSnapshotUid -and
         [string]$receipt.raidSnapshotUid -ceq `
            [string]$context.raidSnapshotUid -and
         [string]$receipt.raidSnapshotSha256 -ceq `
            [string]$capture.raidSnapshotSha256 -and
         [string]$receipt.raidSnapshotSha256 -ceq `
            [string]$context.raidSnapshotSha256 -and
         [string]$receipt.clientBuildCode -ceq `
            [string]$capture.clientBuildCode -and
         [string]$receipt.clientBuildCode -ceq `
            [string]$context.clientBuildCode -and
         [string]$receipt.clientExecutableSha256 -ceq `
            [string]$capture.clientExecutableSha256 -and
         [string]$receipt.clientExecutableSha256 -ceq `
            [string]$context.clientExecutableSha256 -and
         $expectedHeadReceipt -ceq $expectedHeadCapture -and
         [string]$receipt.protectedPayloadSha256 -ceq `
            [string]$capture.protectedPayloadSha256 -and
         [string]$receipt.requestSha256 -ceq [string]$capture.requestSha256 -and
         [string]$receipt.stateContentSha256 -ceq `
            [string]$capture.stateContentSha256 -and
         [string]$receipt.resultStateContentSha256 -ceq `
            [string]$receipt.stateContentSha256 -and
         $resultCode -cin @('no_state','state_unchanged','state_advanced') -and
         (($resultCode -ceq 'no_state' -and $null -eq $receipt.headRevisionUid) -or
          ($resultCode -cne 'no_state' -and $headRevisionPresent)) -and
         [string]$receipt.requestSha256 -cmatch '^[0-9a-f]{64}$' -and
         [string]$receipt.pendingPayloadSha256 -cmatch '^[0-9a-f]{64}$' -and
         [string]$receipt.captureReceiptSha256 -cmatch '^[0-9a-f]{64}$' -and
         [string]$receipt.stateContentSha256 -cmatch '^[0-9a-f]{64}$' -and
         [string]$receipt.resultStateContentSha256 -cmatch '^[0-9a-f]{64}$') `
        'phase_d_raid_state_persistence_receipt_invalid'
    $receipt
}
