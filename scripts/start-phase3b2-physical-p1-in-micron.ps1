[CmdletBinding()]
param(
    [string]$ToolRoot = 'C:\NLL\Tools',
    [string]$P1EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p1-server-only-v1',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP1'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, $Text,
            [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

$measurePath = Join-Path $ToolRoot 'Measure-Phase3B2-Physical-P1.ps1'
$verifyPath = Join-Path $ToolRoot 'Verify-Phase3B2-Physical-P1.ps1'
$toolPins = @(
    [pscustomobject]@{
        Path = $measurePath
        Length = 46004L
        Sha256 = '66c4d41867927cec5f69cab6c75b2b5c984661195a25a477b224f528e3623470'
    },
    [pscustomobject]@{
        Path = $verifyPath
        Length = 26046L
        Sha256 = '38076797f0331d6d1212bee4d3dc8c052fb7ed0c8aac404c83d8887f88c84d1e'
    }
)
foreach ($pin in $toolPins) {
    Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
        (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
        (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
        'phase3b2_physical_p1_workflow_tool_pin_mismatch'
}

$stageCode = 'server_only_measurement'
$assessmentUid = $null
$attemptRoot = $null
try {
    $measureText = & $measurePath
    $measure = ($measureText | Out-String) | ConvertFrom-Json
    Assert-True ($measure.Receipt.contractId -ceq
            'nll/phase3b2-physical-p1-server-only-measurement/v1' -and
        $measure.Receipt.serverExecutionStarted -and
        $measure.Receipt.serverStoppedAfterMeasurement -and
        $measure.Receipt.databaseRestored -and
        $measure.Receipt.sqliteRuntimeRemoved -and
        $measure.Receipt.p0StillApplied -and
        -not $measure.Receipt.clientExecutionStarted) `
        'phase3b2_physical_p1_workflow_measurement_output_invalid'
    $assessmentUid = [string]$measure.Receipt.assessmentUid
    $attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid

    $stageCode = 'independent_post_measurement_verification'
    $verifyText = & $verifyPath
    $verification = ($verifyText | Out-String) | ConvertFrom-Json
    Assert-True ($verification.Receipt.contractId -ceq
            'nll/phase3b2-physical-p1-post-measurement-verification/v1' -and
        $verification.Receipt.assessmentUid -ceq $assessmentUid -and
        $verification.Receipt.serverOnlyMeasurementVerified -and
        $verification.Receipt.serverExecutionStarted -and
        $verification.Receipt.serverStoppedAfterMeasurement -and
        $verification.Receipt.databaseRestored -and
        $verification.Receipt.sqliteRuntimeRemoved -and
        $verification.Receipt.p0StillApplied -and
        -not $verification.Receipt.clientExecutionStarted) `
        'phase3b2_physical_p1_workflow_verification_output_invalid'

    $stageCode = 'workflow_seal'
    $workflow = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p1-workflow/v1'
        completedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
        measurementReceiptByteLength =
            [long]$measure.ProtectedReceiptByteLength
        measurementReceiptSha256 =
            [string]$measure.ProtectedReceiptSha256
        postMeasurementVerificationReceiptByteLength =
            [long]$verification.ProtectedReceiptByteLength
        postMeasurementVerificationReceiptSha256 =
            [string]$verification.ProtectedReceiptSha256
        physicalBoundaryVerified = $true
        serverOnlyMeasurementVerified = $true
        controlledSyntheticLoginAccepted = $true
        sqliteCredentialBindingVerified = $true
        serverExecutionStarted = $true
        serverStoppedAfterMeasurement = $true
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        p0StillApplied = $true
        primaryInstallModified = $false
        officialLauncherModified = $false
        officialLauncherExecutionPermitted = $false
        clientExecutionStarted = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        nextStepCode = 'return_to_samsung_and_prepare_physical_p2_client_start'
    }
    $localWorkflowPath = Join-Path $P1EvidenceRoot 'workflow.receipt.json'
    $protectedWorkflowPath = Join-Path $attemptRoot 'workflow.receipt.json'
    Assert-True (-not (Test-Path -LiteralPath $localWorkflowPath) -and
        -not (Test-Path -LiteralPath $protectedWorkflowPath)) `
        'phase3b2_physical_p1_workflow_destination_not_cold'
    Write-AtomicUtf8NoBom $localWorkflowPath `
        (($workflow | ConvertTo-Json -Depth 8) + "`n")
    Copy-Item -LiteralPath $localWorkflowPath -Destination $protectedWorkflowPath
    Assert-True ((Get-Item -LiteralPath $localWorkflowPath).Length -eq
            (Get-Item -LiteralPath $protectedWorkflowPath).Length -and
        (Get-Sha256Hex $localWorkflowPath) -ceq
            (Get-Sha256Hex $protectedWorkflowPath)) `
        'phase3b2_physical_p1_workflow_receipt_protection_failed'
    [pscustomobject]@{
        Receipt = $workflow
        ProtectedReceiptPath = $protectedWorkflowPath
        ProtectedReceiptByteLength =
            (Get-Item -LiteralPath $protectedWorkflowPath).Length
        ProtectedReceiptSha256 = Get-Sha256Hex $protectedWorkflowPath
    } | ConvertTo-Json -Depth 10
}
catch {
    $safeFailureCode = if ($_.Exception.Message -cmatch
        '^phase3b2_[a-z0-9_:-]+$') {
        $_.Exception.Message
    }
    else { 'phase3b2_physical_p1_workflow_unexpected_error_redacted' }
    try {
        if (-not $attemptRoot) {
            $pointerPath = Join-Path $SamsungProtectedRoot `
                'latest-attempt.pointer.json'
            if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
                $pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json
                $assessmentUid = [string]$pointer.assessmentUid
                $attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid
            }
        }
        if ($attemptRoot -and
            (Test-Path -LiteralPath $attemptRoot -PathType Container)) {
            $failure = [ordered]@{
                schemaVersion = 1
                contractId = 'nll/phase3b2-physical-p1-workflow-failure/v1'
                failedAtUtc =
                    [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                assessmentUid = $assessmentUid
                failedStageCode = $stageCode
                failureCode = $safeFailureCode
                p0RollbackPerformed = $false
                clientExecutionStarted = $false
                nextStepCode =
                    'return_to_samsung_and_inspect_physical_p1_workflow_failure'
            }
            $failurePath = Join-Path $attemptRoot 'workflow.failure.receipt.json'
            if (-not (Test-Path -LiteralPath $failurePath)) {
                Write-AtomicUtf8NoBom $failurePath `
                    (($failure | ConvertTo-Json -Depth 6) + "`n")
            }
        }
    }
    catch { }
    throw "phase3b2_physical_p1_workflow_failed:$stageCode"
}
