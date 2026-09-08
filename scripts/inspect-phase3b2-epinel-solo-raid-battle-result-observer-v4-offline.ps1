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
    'phase3b2_battle_result_observer_v4_inspection_wrong_samsung_boundary'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_battle_result_observer_v4_inspection_runtime_not_cold'

$evidenceRoot = $MicronDriveLetter + ':\NLL\E\P3SROB4'
Assert-True (Test-Path -LiteralPath $evidenceRoot -PathType Container) `
    'phase3b2_battle_result_observer_v4_evidence_missing'

if ([string]::IsNullOrWhiteSpace($AssessmentUid)) {
    $runs = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory |
        Sort-Object LastWriteTimeUtc -Descending)
    Assert-True ($runs.Count -eq 1) `
        'phase3b2_battle_result_observer_v4_run_cardinality_invalid'
    $runRoot = $runs[0].FullName
}
else {
    $parsedUid = [Guid]::Empty
    Assert-True ([Guid]::TryParse($AssessmentUid, [ref]$parsedUid) -and
        $parsedUid -ne [Guid]::Empty) `
        'phase3b2_battle_result_observer_v4_assessment_uid_invalid'
    $runRoot = Join-Path $evidenceRoot $parsedUid.ToString('D')
}

$completionPath = Join-Path $runRoot 'completion.receipt.json'
$stdoutPath = Join-Path $runRoot 'server.stdout.log'
Assert-True (
    (Test-Path -LiteralPath $completionPath -PathType Leaf) -and
    (Test-Path -LiteralPath $stdoutPath -PathType Leaf)
) 'phase3b2_battle_result_observer_v4_completed_evidence_missing'

$completion = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $completion.contractId -ceq
        'nll/phase3b2-epinel-battle-result-observer-completion/v4' -and
    [Guid]::Parse([string]$completion.assessmentUid) -ne [Guid]::Empty -and
    $completion.runtimeColdAfterCompletion -and
    $completion.databaseRestored -and
    $completion.hostsRestored -and
    (Get-Sha256Hex $stdoutPath) -ceq [string]$completion.serverStdoutSha256
) 'phase3b2_battle_result_observer_v4_completion_invalid'

$pattern =
    '^NLL_BATTLE_RESULT_OBSERVATION/v1 ' +
    'utc=(?<utc>\S+) ' +
    'sequence=(?<sequence>\d+) ' +
    'route=(?<route>[a-z0-9_]+) ' +
    'battleResult=(?<battleResult>-?\d+)\s*$'
$observations = [Collections.Generic.List[object]]::new()
foreach ($line in [IO.File]::ReadLines($stdoutPath, [Text.Encoding]::UTF8)) {
    $match = [regex]::Match($line, $pattern)
    if (-not $match.Success) { continue }
    $utc = [DateTimeOffset]::MinValue
    Assert-True ([DateTimeOffset]::TryParseExact(
            $match.Groups['utc'].Value,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$utc
        )) 'phase3b2_battle_result_observer_v4_observation_time_invalid'
    $observations.Add([pscustomobject]@{
            utc = $utc.ToUniversalTime().ToString('o')
            sequence = [long]$match.Groups['sequence'].Value
            route = $match.Groups['route'].Value
            battleResult = [int]$match.Groups['battleResult'].Value
        })
}

$ordered = @($observations | Sort-Object sequence)
Assert-True (
    @($ordered | Group-Object sequence | Where-Object Count -ne 1).Count -eq 0
) 'phase3b2_battle_result_observer_v4_sequence_invalid'

[pscustomobject]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-battle-result-observer-inspection/v4'
    inspectedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = [string]$completion.assessmentUid
    completionReceiptSha256 = Get-Sha256Hex $completionPath
    serverStdoutSha256 = Get-Sha256Hex $stdoutPath
    observedStageCode = [string]$completion.observedStageCode
    outcomeCode = [string]$completion.outcomeCode
    observationCount = $ordered.Count
    observations = $ordered
    rawRequestPayloadPersisted = $false
    accountIdentityPersistedByObserver = $false
    verdictCode = if ($ordered.Count -eq 0) {
        'no_setdamage_request_observed'
    }
    elseif ($ordered.Count -eq 1) {
        'single_setdamage_battle_result_observed'
    }
    else {
        'multiple_setdamage_battle_results_observed'
    }
    nextStepCode = 'classify_observed_sequence_without_numeric_assumption'
} | ConvertTo-Json -Depth 8
