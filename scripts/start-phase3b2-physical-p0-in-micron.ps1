[CmdletBinding()]
param(
    [string]$ToolRoot = 'C:\NLL\Tools',
    [string]$BackupRoot = 'C:\NLL\Backups\Phase3B2\Physical-P0-v1',
    [string]$EvidenceRoot = 'C:\NLL\Evidence\Phase3B2\Physical\p0-v1',
    [string]$SamsungProtectedRoot = 'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0'
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

$preparePath = Join-Path $ToolRoot 'Prepare-Phase3B2-Physical-P0.ps1'
$verifyPath = Join-Path $ToolRoot 'Verify-Phase3B2-Physical-P0.ps1'
$rollbackPath = Join-Path $ToolRoot 'Rollback-Phase3B2-Physical-P0.ps1'
$toolPins = @(
    [pscustomobject]@{ Path = $preparePath; Length = 32665L; Sha256 = 'bd69c84df28dc6519c1bc717a95117c3943470d725fd5d2f5eb7776287b76c5e' },
    [pscustomobject]@{ Path = $verifyPath; Length = 19059L; Sha256 = '5ecb3cc57f2b035444853acf135e834f89ba53e49529b5f934a298d7e563ee04' },
    [pscustomobject]@{ Path = $rollbackPath; Length = 7822L; Sha256 = 'b75f68d1b948e9ffed21b02b86d3af71c8c76379bab51b98111ab1d5e451a81c' }
)
foreach ($pin in $toolPins) {
    Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
        (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
        (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
        'phase3b2_physical_p0_workflow_tool_pin_mismatch'
}

$backupExistedBefore = Test-Path -LiteralPath $BackupRoot
$stageCode = 'apply'
$assessmentUid = $null
$attemptRoot = $null
try {
    $applyText = & $preparePath
    $apply = ($applyText | Out-String) | ConvertFrom-Json
    Assert-True ($apply.Receipt.contractId -ceq
            'nll/phase3b2-physical-p0-applied-verification/v1' -and
        $apply.Receipt.p0AppliedVerified -and
        -not $apply.Receipt.serverExecutionStarted -and
        -not $apply.Receipt.clientExecutionStarted) `
        'phase3b2_physical_p0_workflow_apply_output_invalid'
    $assessmentUid = [string]$apply.Receipt.assessmentUid
    $attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid

    $stageCode = 'independent_post_apply_verification'
    $verifyText = & $verifyPath
    $verification = ($verifyText | Out-String) | ConvertFrom-Json
    Assert-True ($verification.Receipt.contractId -ceq
            'nll/phase3b2-physical-p0-post-apply-verification/v1' -and
        $verification.Receipt.assessmentUid -ceq $assessmentUid -and
        $verification.Receipt.p0AppliedVerified -and
        -not $verification.Receipt.serverExecutionStarted -and
        -not $verification.Receipt.clientExecutionStarted) `
        'phase3b2_physical_p0_workflow_verification_output_invalid'

    $stageCode = 'workflow_seal'
    $workflow = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-workflow/v1'
        completedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        appliedReceiptByteLength = [long]$apply.ProtectedReceiptByteLength
        appliedReceiptSha256 = [string]$apply.ProtectedReceiptSha256
        postApplyVerificationReceiptByteLength =
            [long]$verification.ProtectedReceiptByteLength
        postApplyVerificationReceiptSha256 =
            [string]$verification.ProtectedReceiptSha256
        p0AppliedVerified = $true
        protectedBackupVerified = $true
        primaryInstallModified = $false
        officialLauncherModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'return_to_samsung_and_prepare_physical_p1_server_only'
    }
    $localWorkflowPath = Join-Path $EvidenceRoot 'workflow.receipt.json'
    $protectedWorkflowPath = Join-Path $attemptRoot 'workflow.receipt.json'
    Write-AtomicUtf8NoBom $localWorkflowPath `
        (($workflow | ConvertTo-Json -Depth 8) + "`n")
    Copy-Item -LiteralPath $localWorkflowPath -Destination $protectedWorkflowPath
    Assert-True ((Get-Item -LiteralPath $localWorkflowPath).Length -eq
            (Get-Item -LiteralPath $protectedWorkflowPath).Length -and
        (Get-Sha256Hex $localWorkflowPath) -ceq
            (Get-Sha256Hex $protectedWorkflowPath)) `
        'phase3b2_physical_p0_workflow_receipt_protection_failed'
    [pscustomobject]@{
        Receipt = $workflow
        ProtectedReceiptPath = $protectedWorkflowPath
        ProtectedReceiptByteLength =
            (Get-Item -LiteralPath $protectedWorkflowPath).Length
        ProtectedReceiptSha256 = Get-Sha256Hex $protectedWorkflowPath
    } | ConvertTo-Json -Depth 10
}
catch {
    $caughtException = $_
    $rollbackCompleted = $false
    if (-not $backupExistedBefore -and
        (Test-Path -LiteralPath (Join-Path $BackupRoot `
                'trusted-backup-manifest.json') -PathType Leaf)) {
        try {
            & $rollbackPath -BackupRoot $BackupRoot -AutomaticFailureRollback |
                Out-Null
            $rollbackCompleted = $true
        }
        catch { $rollbackCompleted = $false }
    }
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
        if ($attemptRoot -and (Test-Path -LiteralPath $attemptRoot -PathType Container)) {
            $failure = [ordered]@{
                schemaVersion = 1
                contractId = 'nll/phase3b2-physical-p0-workflow-failure/v1'
                failedAtUtc =
                    [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                assessmentUid = $assessmentUid
                failedStageCode = $stageCode
                automaticRollbackCompleted = $rollbackCompleted
                primaryInstallModified = $false
                officialLauncherModified = $false
                serverExecutionStarted = $false
                clientExecutionStarted = $false
                nextStepCode = 'return_to_samsung_and_inspect_physical_p0_failure'
            }
            Write-AtomicUtf8NoBom (Join-Path $attemptRoot `
                'workflow.failure.receipt.json') `
                (($failure | ConvertTo-Json) + "`n")
        }
    }
    catch { }
    throw "phase3b2_physical_p0_workflow_failed:$stageCode"
}
