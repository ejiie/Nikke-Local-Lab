[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TranscriptPath,

    [string]$OutputPath =
        "$env:LOCALAPPDATA\NikkeLocalLab\compatibility\evidence\phase3b2-wave1-hyperv\812c585b-2849-474f-a9ff-dfb59feaea87\reference-run-password-failure.receipt.json"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Assert-OutsideRepository {
    param([string]$CandidatePath, [string]$RepositoryRoot, [string]$FailureCode)
    $candidate = [IO.Path]::GetFullPath($CandidatePath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar)
    $repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar)
    $prefix = $repository + [IO.Path]::DirectorySeparatorChar
    Assert-True (-not $candidate.Equals($repository,
            [StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($prefix,
            [StringComparison]::OrdinalIgnoreCase)) $FailureCode
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$transcriptFullPath = [IO.Path]::GetFullPath($TranscriptPath)
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
Assert-OutsideRepository $transcriptFullPath $repositoryRoot `
    "phase3b2_password_failure_transcript_inside_repository"
Assert-OutsideRepository $outputFullPath $repositoryRoot `
    "phase3b2_password_failure_output_inside_repository"
Assert-True (Test-Path -LiteralPath $transcriptFullPath -PathType Leaf) `
    "phase3b2_password_failure_transcript_missing"
Assert-True (-not (Test-Path -LiteralPath $outputFullPath)) `
    "phase3b2_password_failure_output_exists"

$utf8 = [Text.UTF8Encoding]::new($false, $true)
$transcript = [IO.File]::ReadAllText($transcriptFullPath, $utf8)
$jsonStart = $transcript.IndexOf('{')
$jsonEnd = $transcript.LastIndexOf('}')
Assert-True ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) `
    "phase3b2_password_failure_json_not_found"
$document = $transcript.Substring($jsonStart, $jsonEnd - $jsonStart + 1) |
    ConvertFrom-Json

Assert-True ($document.contractId -ceq
    "nll/phase3b2-private-reference-run-failure/v3" -and
    $document.assessmentUid -ceq "812c585b-2849-474f-a9ff-dfb59feaea87" -and
    $document.failedTransitionCode -ceq "local_login_submission" -and
    $document.reasonCode -ceq "launcher_password_representation_mismatch" -and
    [int]$document.displayedResultCode -eq 5 -and
    [int]$document.displayedBackendCode -eq 2002 -and
    -not [bool]$document.retryPerformed -and
    $document.networkModeCode -ceq "private_vm_only_no_gateway" -and
    [int]$document.ipv4DefaultRouteCount -eq 0 -and
    [int]$document.ipv6DefaultRouteCount -eq 0 -and
    [int]$document.launcherCurrentNonLoopbackConnectionCount -eq 0 -and
    [int]$document.launcherAllowedNonLoopbackEventCount -eq 0 -and
    [int]$document.launcherBlockedNonLoopbackEventCount -eq 0 -and
    [int]$document.priorP1ReceiptByteLength -eq 2761 -and
    $document.priorP1ReceiptSha256 -ceq
        "bae2087dcca0ce6645a5079418301ced1eff7d1df5546fccf04e0e4e913bf342" -and
    [bool]$document.priorP1ServerRunning -and
    [int]$document.priorP1HttpLoopbackListenerCount -eq 1 -and
    [int]$document.priorP1HttpsLoopbackListenerCount -eq 1 -and
    [int]$document.currentServerProcessCount -eq 0 -and
    [int]$document.currentServerHttpLoopbackListenerCount -eq 0 -and
    [int]$document.currentServerHttpsLoopbackListenerCount -eq 0 -and
    [bool]$document.serverContinuityLostAfterDisplayedFailure -and
    [bool]$document.launcherCertificateBundlePatched -and
    [bool]$document.actualLauncherReachedLocalAccountLogin -and
    [int]$document.syntheticContextPasswordLength -eq 44 -and
    [int]$document.syntheticContextPasswordDecodesToByteLength -eq 32 -and
    [bool]$document.databasePasswordEqualsContextPlaintext -and
    -not [bool]$document.databasePasswordMatchesLauncherMd5 -and
    $document.diagnosedStorageSchemeCode -ceq "plaintext_instead_of_md5_lower_hex" -and
    -not [bool]$document.serverRunning -and [bool]$document.launcherExecutionStarted -and
    -not [bool]$document.clientExecutionStarted -and
    -not [bool]$document.officialIdentityPersisted -and
    -not [bool]$document.officialCredentialPersisted -and
    $document.nextStepCode -ceq
        "restore_launcher_ca_p0_repair_synthetic_credential_reseal") `
    "phase3b2_password_failure_transcript_invalid"

$controlled = [ordered]@{
    contractId = [string]$document.contractId
    failedAtUtc = [string]$document.failedAtUtc
    assessmentUid = [string]$document.assessmentUid
    failedTransitionCode = [string]$document.failedTransitionCode
    reasonCode = [string]$document.reasonCode
    displayedResultCode = 5
    displayedBackendCode = 2002
    retryPerformed = $false
    networkModeCode = [string]$document.networkModeCode
    ipv4DefaultRouteCount = 0
    ipv6DefaultRouteCount = 0
    launcherProcessTreeMemberCount = [int]$document.launcherProcessTreeMemberCount
    launcherCurrentLoopbackConnectionCount =
        [int]$document.launcherCurrentLoopbackConnectionCount
    launcherCurrentNonLoopbackConnectionCount = 0
    launcherAllowedLoopbackEventCount = [int]$document.launcherAllowedLoopbackEventCount
    launcherBlockedLoopbackEventCount = [int]$document.launcherBlockedLoopbackEventCount
    launcherAllowedNonLoopbackEventCount = 0
    launcherBlockedNonLoopbackEventCount = 0
    priorP1ReceiptByteLength = 2761
    priorP1ReceiptSha256 = [string]$document.priorP1ReceiptSha256
    priorP1ServerRunning = $true
    priorP1HttpLoopbackListenerCount = 1
    priorP1HttpsLoopbackListenerCount = 1
    currentServerProcessCount = 0
    currentServerHttpLoopbackListenerCount = 0
    currentServerHttpsLoopbackListenerCount = 0
    serverContinuityLostAfterDisplayedFailure = $true
    launcherCertificateBundlePatched = $true
    actualLauncherReachedLocalAccountLogin = $true
    syntheticContextPasswordLength = 44
    syntheticContextPasswordDecodesToByteLength = 32
    databasePasswordEqualsContextPlaintext = $true
    databasePasswordMatchesLauncherMd5 = $false
    diagnosedStorageSchemeCode = "plaintext_instead_of_md5_lower_hex"
    operatorScreenshotAttachedExternally = $true
    serverRunning = $false
    launcherExecutionStarted = $true
    clientExecutionStarted = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    nextStepCode = [string]$document.nextStepCode
}
$outputDirectory = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
[IO.File]::WriteAllText($outputFullPath,
    (($controlled | ConvertTo-Json -Depth 5) + "`n"), [Text.UTF8Encoding]::new($false))
$item = Get-Item -LiteralPath $outputFullPath
[pscustomobject]@{
    contractId = "nll/phase3b2-private-password-failure-seal/v1"
    assessmentUid = $controlled.assessmentUid
    receiptByteLength = $item.Length
    receiptSha256 = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    rawSecretPersisted = $false
    rawScreenshotCopied = $false
    repositoryWritePerformed = $false
    nextStepCode = $controlled.nextStepCode
} | ConvertTo-Json
