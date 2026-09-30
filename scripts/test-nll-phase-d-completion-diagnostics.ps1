# Source-free completion adapter fixture; synthetic paths and fake firewall cmdlets only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDCompletion.ps1')
function Assert-Test([bool]$Value, [string]$Code) { if (-not $Value) { throw $Code } }
function Assert-True([bool]$Condition, [string]$FailureCode) { Assert-Test $Condition $FailureCode }
function Get-Sha256Hex([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Write-AtomicUtf8NoBom([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text) }
function Get-NetFirewallRule { param($Group, $ErrorAction) } # No OS firewall access.
function Remove-NetFirewallRule {
    [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process { if ($null -ne $InputObject) { throw 'test_must_not_remove_real_firewall' } }
}
$template = @'
$appLogRoot = Join-Path $ServerRoot 'logs'
$markerEvidencePath = Join-Path $runRoot 'regroup.observations.json'
$appLogPaths = @(Get-ChildItem -LiteralPath $appLogRoot -Filter 'app-*.log' -File -ErrorAction SilentlyContinue)
if ($appLogPaths.Count -gt 0) {
    $observations = @([ordered]@{ battleResult = 1 })
    $scoreObservations = @(); $damageSourceObservations = @()
    Write-AtomicUtf8NoBom $markerEvidencePath '{}'
}
else {
    Assert-True (Test-Path -LiteralPath $markerEvidencePath -PathType Leaf) `
        'phase3b2_ranking_prefix_v9_marker_missing_after_partial_completion'
    $markerEvidence = Get-Content -LiteralPath $markerEvidencePath -Raw | ConvertFrom-Json
    Assert-True ($markerEvidence.contractId -ceq 'nll/phase3b2-epinel-solo-raid-ranking-prefix-marker-evidence/v9' -and
        $markerEvidence.assessmentUid -ceq $pointer.assessmentUid -and -not $markerEvidence.rawRequestPayloadPersisted) 'phase3b2_ranking_prefix_v9_existing_marker_invalid'
    $observations = @($markerEvidence.observations)
    $scoreObservations = @($markerEvidence.scoreObservations)
    $damageSourceObservations = @($markerEvidence.damageSourceObservations)
}
$markerEvidenceSha256 = Get-Sha256Hex $markerEvidencePath
$unsupportedBattleResultCount = @($observations | Where-Object { $_.battleResult -notin @(1,4,6) }).Count
$battleResultClassificationValid = $unsupportedBattleResultCount -eq 0
$scoreProjectionRequired = $OutcomeCode -ceq 'success' -and $ObservedStageCode -ceq 'battle_result'
if ($scoreProjectionRequired) { throw 'phase3b2_ranking_prefix_v9_projection_verification_failed' }
$receipt = [ordered]@{
    markerOnlyEvidencePersisted = $true
    battleResultClassificationValid = $battleResultClassificationValid
    scoreProjectionVerified = $false; regroupNonConsumptionVerified = $false
    damageSourceObservationComplete = $false
    databaseRestored = $true; hostsRestored = $true
}
[IO.File]::WriteAllBytes($dbPath, [IO.File]::ReadAllBytes($dbBeforePath))
[IO.File]::WriteAllBytes($hostsPath, [IO.File]::ReadAllBytes($hostsBeforePath))
Write-AtomicUtf8NoBom $completionPath ($receipt | ConvertTo-Json -Depth 6)
Move-Item -LiteralPath $activePointerPath -Destination (Join-Path $runRoot 'active-run.pointer.archived.json')
'@
$derived = ConvertTo-PhaseDCompletionText $template
Assert-Test ($derived -ceq (ConvertTo-PhaseDCompletionText ($template.Replace("`r`n", "`n").Replace("`n", "`r`n")))) 'completion_newline_derivation_differs'
foreach ($invalid in @($derived, $template.Replace('    markerOnlyEvidencePersisted = $true', ''),
    ($template + "`n" + '    markerOnlyEvidencePersisted = $true'))) {
    $rejected = $false
    try { $null = ConvertTo-PhaseDCompletionText $invalid } catch { $rejected = $_.Exception.Message -ceq 'phase_d_completion_diagnostics_template_invalid' }
    Assert-Test $rejected 'changed_template_accepted'
}
$body = $derived
$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-completion-diagnostics-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $taskRoot
$previousProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $taskRoot # Player.log metadata must also remain synthetic.
    foreach ($case in @('missing', 'empty-directory', 'existing', 'bad-contract', 'wrong-run', 'raw-marker', 'malformed', 'battle-success', 'logged')) {
        $runRoot = Join-Path $taskRoot $case
        $ServerRoot = Join-Path $runRoot 'runtime'
        $null = New-Item -ItemType Directory -Path $ServerRoot
        $dbPath = Join-Path $ServerRoot 'db.json'
        $dbBeforePath = Join-Path $runRoot 'db.before.bin'
        $hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
        $hostsPath = Join-Path $runRoot 'synthetic.hosts'
        $stdoutPath = Join-Path $runRoot 'server.stdout.log'
        $stderrPath = Join-Path $runRoot 'server.stderr.log'
        $activePointerPath = Join-Path $runRoot 'active-run.pointer.json'
        $completionPath = Join-Path $runRoot 'completion.receipt.json'
        $markerPath = Join-Path $runRoot 'regroup.observations.json'
        [IO.File]::WriteAllText($dbBeforePath, '{"Users":[]}')
        [IO.File]::WriteAllText($dbPath, '{"Users":[],"syntheticChanged":true}')
        [IO.File]::WriteAllText($hostsBeforePath, 'synthetic-baseline')
        [IO.File]::WriteAllText($hostsPath, 'synthetic-applied')
        [IO.File]::WriteAllText($activePointerPath, 'synthetic-pointer')
        $expectedDbSha256 = Get-Sha256Hex $dbBeforePath
        $expectedBaseHostsSha256 = Get-Sha256Hex $hostsBeforePath
        $pointer = [pscustomobject]@{ assessmentUid = 'synthetic-run'; runStartReceiptSha256 = ('a' * 64) }
        $runStart = [pscustomobject]@{ runIntentCode = 'challenge' }
        $bootstrapForcedStop = $false; $serverForcedStop = $true
        $extensionFirewallGroup = 'synthetic-only'
        $OutcomeCode = if ($case -eq 'battle-success') { 'success' } else { 'client_exit' }
        $ObservedStageCode = if ($case -eq 'battle-success') { 'battle_result' } else { 'startup_only' }
        if ($case -in @('empty-directory', 'logged')) { $null = New-Item -ItemType Directory -Path (Join-Path $ServerRoot 'logs') }
        if ($case -eq 'logged') {
            [IO.File]::WriteAllText((Join-Path $ServerRoot 'logs/app-synthetic.log'), 'NLL_BATTLE_RESULT_OBSERVATION/v1 utc=2026-09-07T00:00:00Z sequence=1 route=soloraid_trial_setdamage battleResult=1')
        }
        if ($case -in @('existing','bad-contract','wrong-run','raw-marker')) {
            $marker = [ordered]@{
                contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-marker-evidence/v9'
                assessmentUid = 'synthetic-run'; rawRequestPayloadPersisted = $false
                observations = @([ordered]@{ battleResult = 1 }); scoreObservations = @(); damageSourceObservations = @()
            }
            if ($case -eq 'bad-contract') { $marker.contractId = 'invalid' }
            if ($case -eq 'wrong-run') { $marker.assessmentUid = 'different-run' }
            if ($case -eq 'raw-marker') { $marker.rawRequestPayloadPersisted = $true }
            [IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Depth 6))
        }
        if ($case -eq 'malformed') { [IO.File]::WriteAllText($markerPath, '{') }
        $failed = $false
        $shouldFail = $case -in @('bad-contract','wrong-run','raw-marker','malformed','battle-success')
        try { & ([scriptblock]::Create($body)) | Out-Null } catch { if (-not $shouldFail) { throw }; $failed = $true }
        Assert-Test ($failed -eq $shouldFail) ('completion_case_failed_' + $case)
        if ($shouldFail) {
            Assert-Test (-not (Test-Path -LiteralPath $completionPath)) 'invalid_diagnostics_claimed_completion'
            Assert-Test (Test-Path -LiteralPath $activePointerPath) 'failed_completion_lost_recovery_pointer'
            continue
        }
        $receipt = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
        Assert-Test ((Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256) 'completion_restore_not_verified'
        Assert-Test (-not (Test-Path -LiteralPath $activePointerPath)) 'completion_pointer_not_archived'
        $observed = $case -in @('existing','logged')
        Assert-Test ($receipt.diagnosticObservationStatus -ceq $(if ($observed) { 'observed' } else { 'not_observed' })) 'observation_status_incorrect'
        Assert-Test ($receipt.battleResultClassificationValid -eq $observed) 'empty_observations_claimed_classification'
        Assert-Test (-not $receipt.scoreProjectionVerified -and -not $receipt.damageSourceObservationComplete -and -not $receipt.regroupNonConsumptionVerified) 'missing_gameplay_proof_promoted'
    }
}
finally {
    $env:USERPROFILE = $previousProfile
    $resolved = [IO.Path]::GetFullPath($taskRoot)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-completion-diagnostics-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D completion: 9 diagnostic/cleanup cases, exact-template guards and CRLF/LF derivation passed; synthetic resources only.'
