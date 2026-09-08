# Pure derivation of the hash-pinned v9 completion template. No runtime I/O.
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
