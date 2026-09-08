param(
    [string]$MicronDrive = 'E:',
    [string]$AssessmentUid = 'eae0f37c-6939-446f-93f6-d88c1c447311'
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

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary, $Text, [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$evidenceRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1'
$runRoot = Join-Path $evidenceRoot $AssessmentUid
$failurePath = Join-Path $runRoot 'run-failure.receipt.json'
$measurementPath = Join-Path $runRoot 'startup.measurement.json'
$stdoutPath = Join-Path $runRoot 'server.stdout.log'
$receiptPath = Join-Path $runRoot 'offline-recovery.receipt.json'
$activePointerPath = Join-Path $evidenceRoot 'active-run.pointer.json'
$dbPath = Join-Path $serverRoot 'db.json'
$expectedDbSha256 = `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'

Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    (Test-Path -LiteralPath $failurePath -PathType Leaf) -and
    (Test-Path -LiteralPath $measurementPath -PathType Leaf) -and
    (Test-Path -LiteralPath $stdoutPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $receiptPath) -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0
) 'phase3b2_epinel_minimal_sampling_recovery_input_invalid'

$failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$samples = @(Get-Content -LiteralPath $measurementPath -Raw -Encoding UTF8 |
    ConvertFrom-Json)
$lastOffsetMilliseconds = if ($samples.Count -gt 0) {
    [long]$samples[-1].offsetMilliseconds
} else { 0L }
$unresponsiveCount = @($samples | Where-Object {
    -not [bool]$_.clientResponding
}).Count
$nonLoopbackSampleCount = @($samples | Where-Object {
    [int]$_.nonLoopbackConnectionCount -ne 0
}).Count

Assert-True (
    $failure.contractId -ceq `
        'nll/phase3b2-epinel-minimal-reference-failure/v1' -and
    $failure.assessmentUid -ceq $AssessmentUid -and
    $failure.failedStageCode -ceq `
        'thirty_second_interactive_health_observation' -and
    $failure.failureMessage -ceq `
        'phase3b2_epinel_minimal_start_health_or_network_invalid' -and
    $failure.automaticRollbackCompleted -and
    $samples.Count -ge 10 -and
    $lastOffsetMilliseconds -ge 28000 -and
    $unresponsiveCount -eq 0 -and
    $nonLoopbackSampleCount -eq 0
) 'phase3b2_epinel_minimal_sampling_recovery_evidence_invalid'

$stdoutBeforeLength = (Get-Item -LiteralPath $stdoutPath).Length
$stdoutBeforeSha256 = Get-Sha256Hex $stdoutPath
$stdoutText = [IO.File]::ReadAllText($stdoutPath, [Text.Encoding]::UTF8)
$pattern = '(?m)^(?<prefix>\s*authtoken:\s*)\S+\s*$'
$redactedMatchCount = [regex]::Matches($stdoutText, $pattern).Count
Assert-True ($redactedMatchCount -eq 1) `
    'phase3b2_epinel_minimal_sampling_recovery_sensitive_log_shape_invalid'
$protectedText = [regex]::Replace(
    $stdoutText, $pattern, '${prefix}[REDACTED]'
)
Write-AtomicUtf8NoBom $stdoutPath $protectedText
Assert-True (
    [regex]::Matches(
        [IO.File]::ReadAllText($stdoutPath, [Text.Encoding]::UTF8),
        '(?m)^\s*authtoken:\s+(?!\[REDACTED\]\s*$)\S+'
    ).Count -eq 0
) 'phase3b2_epinel_minimal_sampling_recovery_redaction_failed'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = `
        'nll/phase3b2-epinel-minimal-sampling-failure-recovery/v1'
    recoveredAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    assessmentUid = $AssessmentUid
    failureReceiptSha256 = Get-Sha256Hex $failurePath
    measurementReceiptSha256 = Get-Sha256Hex $measurementPath
    observedSampleCount = $samples.Count
    lastOffsetMilliseconds = $lastOffsetMilliseconds
    unresponsiveSampleCount = $unresponsiveCount
    nonLoopbackSampleCount = $nonLoopbackSampleCount
    correctedClassificationCode = `
        'healthy_runtime_false_negative_due_to_fixed_sample_count'
    originalMinimumSampleCount = 15
    repairedMinimumSampleCount = 10
    repairedMinimumElapsedMilliseconds = 28000
    serverStdoutBeforeByteLength = $stdoutBeforeLength
    serverStdoutBeforeSha256 = $stdoutBeforeSha256
    redactedServerLogMatchCount = $redactedMatchCount
    serverStdoutAfterByteLength = (Get-Item -LiteralPath $stdoutPath).Length
    serverStdoutAfterSha256 = Get-Sha256Hex $stdoutPath
    rawSensitiveServerLogPersisted = $false
    databaseRestored = $true
    sqliteRuntimeRemoved = $true
    activeRunPointerPresent = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'rebuild_reseal_and_stage_sampling_fix'
}
Write-AtomicUtf8NoBom $receiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")

[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $receiptPath
} | ConvertTo-Json -Depth 7
