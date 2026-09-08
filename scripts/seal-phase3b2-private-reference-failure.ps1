[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Assert-OutsideRepository {
    param([string]$CandidatePath, [string]$RepositoryRoot)
    $candidate = [IO.Path]::GetFullPath($CandidatePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $prefix = $repository + [IO.Path]::DirectorySeparatorChar
    Assert-True (-not $candidate.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) `
        "phase3b2_reference_failure_output_inside_repository"
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
Assert-OutsideRepository $outputFullPath $repositoryRoot
Assert-True (-not (Test-Path -LiteralPath $outputFullPath)) `
    "phase3b2_reference_failure_output_exists"
$outputDirectory = Split-Path -Parent $outputFullPath
$outputParent = Split-Path -Parent $outputDirectory
Assert-True (Test-Path -LiteralPath $outputParent -PathType Container) `
    "phase3b2_reference_failure_output_parent_missing"
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$receipt = [ordered]@{
    contractId = "nll/phase3b2-private-reference-run-failure/v1"
    failedAtUtc = "2026-08-22T01:00:28Z"
    assessmentUid = "5478649b-327f-4f38-a0b8-84862db1d1b2"
    failedTransitionCode = "local_login_submission"
    reasonCode = "launcher_certificate_bundle_not_patched"
    displayedResultCode = 4
    displayedThirdPartyCode = 60
    thirdPartyCodeMeaning = "curl_peer_failed_verification"
    retryPerformed = $false
    systemNetworkAvailable = $true
    networkProfileConnectivityCode = "no_traffic"
    ipv4DefaultRouteCount = 0
    launcherLoopbackConnectionObserved = $true
    launcherAllowedLoopbackEventCount = 26
    launcherBlockedLoopbackEventCount = 0
    launcherAllowedNonLoopbackEventCount = 0
    launcherBlockedNonLoopbackEventCount = 0
    localTlsControlSucceeded = $true
    controlledSyntheticLoginAccepted = $true
    controlledResponseMediaTypeCode = "text_plain"
    controlledExpireSemanticCode = "dotnet_ticks_not_unix_seconds"
    actualLauncherUpdatedSyntheticDatabase = $false
    actualLauncherReachedLevelInfiniteAuth = $false
    launcherCertificateBundleByteLength = 209309
    launcherCertificateBundleSha256 = "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65"
    launcherCertificateBundlePatched = $false
    screenshotEvidence = @(
        [ordered]@{
            roleCode = "login_error_ui"
            byteLength = 815894
            sha256 = "2d1b1d4f3657d579cb673b1f34c482b7bc999238f3898ba56d7fd618b7bb3a67"
            rawSyntheticIdentifierExternalOnly = $true
        },
        [ordered]@{
            roleCode = "windows_no_internet_indicator"
            byteLength = 9109
            sha256 = "6694166ef9a2eba1f188f900d621d74f9b96586782bd611bb40e959e0fa30e3f"
            rawSyntheticIdentifierExternalOnly = $false
        }
    )
    serverRunning = $true
    launcherExecutionStarted = $true
    clientExecutionStarted = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    nextStepCode = "restore_private_p0_patch_launcher_ca_reseal"
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($outputFullPath, (($receipt | ConvertTo-Json -Depth 6) + "`n"), $utf8)
$item = Get-Item -LiteralPath $outputFullPath
[pscustomobject]@{
    contractId = "nll/phase3b2-private-reference-run-failure-seal/v1"
    assessmentUid = $receipt.assessmentUid
    receiptByteLength = $item.Length
    receiptSha256 = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    rawScreenshotCopied = $false
    repositoryWritePerformed = $false
    nextStepCode = $receipt.nextStepCode
} | ConvertTo-Json
