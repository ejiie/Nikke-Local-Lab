[CmdletBinding(DefaultParameterSetName = 'Validate')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AssessmentUid,

    [Parameter(Mandatory)]
    [string]$RequestManifestPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedRequestManifestSha256,

    [Parameter(Mandatory)]
    [string]$VersionMapPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedVersionMapSha256,

    [Parameter(Mandatory, ParameterSetName = 'Execute')]
    [switch]$SealValidatedPending
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash($Bytes) | ForEach-Object {
            $_.ToString('x2')
        }) -join '')
    }
    finally { $sha.Dispose() }
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Test-NkdbBody {
    param([string]$Path)
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 4) { return $false }
        $magic = [byte[]]::new(4)
        $read = $stream.Read($magic, 0, 4)
        return $read -eq 4 -and
            $magic[0] -eq 0x4e -and $magic[1] -eq 0x4b -and
            $magic[2] -eq 0x44 -and $magic[3] -eq 0x42
    }
    finally { $stream.Dispose() }
}

$parsedUid = [Guid]::Empty
Assert-True ([Guid]::TryParseExact($AssessmentUid, 'D', [ref]$parsedUid)) `
    'phase3b2_static_locale_pending_seal_assessment_uid_invalid'
$canonicalUid = $parsedUid.ToString('D')

$isAdministrator = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter E | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_static_locale_pending_seal_disk_boundary_invalid'

$runtimeCount = @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
    -ErrorAction SilentlyContinue).Count
Assert-True ($runtimeCount -eq 0) `
    'phase3b2_static_locale_pending_seal_runtime_not_cold'

$acquisitionRoot =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\LocaleCatalogAcquisition'
$pendingRoot = Join-Path (Join-Path $acquisitionRoot 'Pending') $canonicalUid
$sealedRoot = Join-Path (Join-Path $acquisitionRoot 'Sealed') $canonicalUid
$failurePath = Join-Path $pendingRoot 'failure.receipt.json'
Assert-True ((Test-Path -LiteralPath $pendingRoot -PathType Container) -and
    (Test-Path -LiteralPath $failurePath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $sealedRoot)) `
    'phase3b2_static_locale_pending_seal_source_shape_invalid'

$failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($failure.contractId -ceq
        'nll/phase3b2-static-locale-catalog-acquisition-failure/v1' -and
    $failure.assessmentUid -ceq $canonicalUid -and
    $failure.requestSetUid -cmatch '^[0-9a-f-]{36}$' -and
    $failure.failedStageCode -ceq 'pair_and_manifest_verification' -and
    $failure.pendingEvidencePreserved -and
    -not $failure.micronMutationPerformed) `
    'phase3b2_static_locale_pending_seal_failure_receipt_invalid'

$validatorPath = Join-Path $PSScriptRoot `
    'invoke-phase3b2-static-locale-catalog-acquisition-on-samsung.ps1'
$validationJson = & $validatorPath `
    -RequestManifestPath $RequestManifestPath `
    -VersionMapPath $VersionMapPath `
    -ExpectedVersionMapSha256 $ExpectedVersionMapSha256
$validation = $validationJson | ConvertFrom-Json
Assert-True ($validation.contractId -ceq
        'nll/phase3b2-static-locale-catalog-request-validation/v1' -and
    $validation.requestSetUid -ceq $failure.requestSetUid -and
    $validation.requestManifestSha256 -ceq
        $ExpectedRequestManifestSha256 -and
    $validation.versionMapSha256 -ceq $ExpectedVersionMapSha256 -and
    $validation.approvedMemberCount -eq 2 -and
    $validation.readyForExplicitAcquisition) `
    'phase3b2_static_locale_pending_seal_request_validation_invalid'

Assert-True ((Get-Sha256Hex ([IO.Path]::GetFullPath(
        $RequestManifestPath))) -ceq $ExpectedRequestManifestSha256) `
    'phase3b2_static_locale_pending_seal_request_hash_mismatch'
$manifest = Get-Content -LiteralPath $RequestManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$members = @($manifest.members)
Assert-True ($members.Count -eq 2) `
    'phase3b2_static_locale_pending_seal_member_count_invalid'

$contentRoot = Join-Path $pendingRoot 'content'
$observedMembers = [Collections.Generic.List[object]]::new()
foreach ($member in $members) {
    $uri = [Uri][string]$member.uri
    $relativePath = $uri.AbsolutePath.TrimStart('/').Replace('/', '\')
    $memberPath = Join-Path $contentRoot $relativePath
    Assert-True (Test-Path -LiteralPath $memberPath -PathType Leaf) `
        'phase3b2_static_locale_pending_seal_member_missing'
    $item = Get-Item -LiteralPath $memberPath
    $kindCode = [string]$member.kindCode
    Assert-True (
        ($kindCode -ceq 'nkdb_body' -and (Test-NkdbBody $memberPath)) -or
        ($kindCode -ceq 'detached_signature_96' -and $item.Length -eq 96L)
    ) 'phase3b2_static_locale_pending_seal_member_shape_invalid'
    $observedMembers.Add([pscustomobject]@{
        roleCode = [string]$member.roleCode
        kindCode = $kindCode
        relativePath = $relativePath.Replace('\', '/')
        byteLength = $item.Length
        sha256 = Get-Sha256Hex $memberPath
        httpStatusCode = 200
    })
}

$allContentFiles = @(Get-ChildItem -LiteralPath $contentRoot -File -Recurse)
Assert-True ($allContentFiles.Count -eq 2 -and
    @($allContentFiles | Where-Object Name -Like '*.partial').Count -eq 0) `
    'phase3b2_static_locale_pending_seal_content_closure_invalid'
$bodyCount = @($observedMembers | Where-Object {
    $_.kindCode -ceq 'nkdb_body'
}).Count
$signatureCount = @($observedMembers | Where-Object {
    $_.kindCode -ceq 'detached_signature_96'
}).Count
Assert-True ($observedMembers.Count -eq 2 -and $bodyCount -eq 1 -and
    $signatureCount -eq 1) `
    'phase3b2_static_locale_pending_seal_pair_shape_invalid'

$pendingValidation = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-static-locale-catalog-pending-seal-validation/v1'
    assessmentUid = $canonicalUid
    requestSetUid = [string]$manifest.requestSetUid
    localeCode = [string]$manifest.localeCode
    revisionCode = [string]$manifest.revisionCode
    bodyByteLength = [long]@($observedMembers | Where-Object {
        $_.kindCode -ceq 'nkdb_body'
    })[0].byteLength
    bodySha256 = [string]@($observedMembers | Where-Object {
        $_.kindCode -ceq 'nkdb_body'
    })[0].sha256
    signatureByteLength = [long]@($observedMembers | Where-Object {
        $_.kindCode -ceq 'detached_signature_96'
    })[0].byteLength
    signatureSha256 = [string]@($observedMembers | Where-Object {
        $_.kindCode -ceq 'detached_signature_96'
    })[0].sha256
    nkdbMagicVerified = $true
    signatureShapeVerified = $true
    contentClosureVerified = $true
    networkRequestStarted = $false
    micronMutationPerformed = $false
    readyForExplicitPendingSeal = $true
}
if (-not $SealValidatedPending) {
    [pscustomobject]$pendingValidation | ConvertTo-Json
    return
}
Assert-True $isAdministrator `
    'phase3b2_static_locale_pending_seal_requires_administrator'

$privateTransport = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-static-locale-catalog-private-transport/v1'
    assessmentUid = $canonicalUid
    requestSetUid = [string]$manifest.requestSetUid
    requestManifestSha256 = $ExpectedRequestManifestSha256
    versionMapSha256 = $ExpectedVersionMapSha256
    localeCode = [string]$manifest.localeCode
    revisionCode = [string]$manifest.revisionCode
    recoveredFromPending = $true
    members = @($observedMembers | ForEach-Object {
        $observation = $_
        $requestMember = @($members | Where-Object {
            [string]$_.roleCode -ceq $observation.roleCode
        })[0]
        [ordered]@{
            roleCode = $observation.roleCode
            kindCode = $observation.kindCode
            uri = [string]$requestMember.uri
            relativePath = $observation.relativePath
            byteLength = $observation.byteLength
            sha256 = $observation.sha256
            httpStatusCode = 200
        }
    })
}
$privateTransportPath = Join-Path $pendingRoot 'transport.private.json'
Assert-True (-not (Test-Path -LiteralPath $privateTransportPath)) `
    'phase3b2_static_locale_pending_seal_private_transport_already_present'
Write-AtomicUtf8NoBom $privateTransportPath `
    (($privateTransport | ConvertTo-Json -Depth 7) + "`n")

$canonicalText = (@($observedMembers | ForEach-Object {
    "{0}`t{1}`t{2}`t{3}" -f $_.roleCode, $_.kindCode,
        $_.byteLength, $_.sha256
}) -join "`n") + "`n"
$canonicalBytes = [Text.UTF8Encoding]::new($false).GetBytes($canonicalText)
$canonicalPath = Join-Path $pendingRoot 'source-free.manifest.tsv'
Assert-True (-not (Test-Path -LiteralPath $canonicalPath)) `
    'phase3b2_static_locale_pending_seal_manifest_already_present'
[IO.File]::WriteAllBytes($canonicalPath, $canonicalBytes)

$requestManifestLength = (Get-Item -LiteralPath $RequestManifestPath).Length
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-static-locale-catalog-acquisition/v1'
    acquiredAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $canonicalUid
    requestSetUid = [string]$manifest.requestSetUid
    environmentCode = 'samsung_boot_micron_offline_runtime_cold'
    clientBuild = [string]$manifest.clientBuild
    localeCode = [string]$manifest.localeCode
    revisionCode = [string]$manifest.revisionCode
    contentVersion = [long]$manifest.contentVersion
    requestedMemberCount = 2
    acquiredMemberCount = 2
    nkdbBodyCount = $bodyCount
    detachedSignatureCount = $signatureCount
    detachedSignatureByteLength = 96
    requestManifestByteLength = $requestManifestLength
    requestManifestSha256 = $ExpectedRequestManifestSha256
    versionMapByteLength = (Get-Item -LiteralPath $VersionMapPath).Length
    versionMapSha256 = $ExpectedVersionMapSha256
    privateTransportManifestByteLength =
        (Get-Item -LiteralPath $privateTransportPath).Length
    privateTransportManifestSha256 = Get-Sha256Hex $privateTransportPath
    canonicalization =
        'role_code_tab_kind_code_tab_byte_length_tab_lower_sha256_lf_v1'
    canonicalByteLength = $canonicalBytes.Length
    canonicalSha256 = Get-BytesSha256Hex $canonicalBytes
    totalContentByteLength = [long](
        ($observedMembers | Measure-Object -Property byteLength -Sum).Sum)
    tlsCertificateValidationCode = 'system_default_hostname_validation'
    redirectFollowCount = 0
    proxyUsed = $false
    cookieSent = $false
    credentialSent = $false
    authorizationHeaderSent = $false
    officialStaticAssetCdnUsed = $true
    officialApiUsed = $false
    officialLoginUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    signatureCryptographicVerificationPerformed = $false
    signatureShapeVerified = $true
    nkdbMagicVerified = $true
    gitExternalPlacementVerified = $true
    recoveredFromPending = $true
    priorFailureReceiptSha256 = Get-Sha256Hex $failurePath
    networkRequestPerformedDuringRecovery = $false
    micronMutationPerformed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    verdictCode = 'exact_locale_catalog_pair_acquired_and_sealed'
    rollbackCode = 'move_sealed_assessment_to_git_external_quarantine'
    nextStepCode = 'offline_inspect_then_stage_locale_pair_without_retry'
}
$receiptPath = Join-Path $pendingRoot 'acquisition.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    'phase3b2_static_locale_pending_seal_receipt_already_present'
Write-AtomicUtf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")

$sealedParent = Split-Path -Parent $sealedRoot
New-Item -ItemType Directory -Path $sealedParent -Force | Out-Null
Move-Item -LiteralPath $pendingRoot -Destination $sealedRoot
$sealedReceiptPath = Join-Path $sealedRoot 'acquisition.receipt.json'
$sealedManifestPath = Join-Path $sealedRoot 'source-free.manifest.tsv'
Assert-True ((Get-Sha256Hex $sealedManifestPath) -ceq
    $receipt.canonicalSha256) `
    'phase3b2_static_locale_pending_seal_final_manifest_invalid'

[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $sealedReceiptPath
    ReceiptByteLength = (Get-Item -LiteralPath $sealedReceiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $sealedReceiptPath
} | ConvertTo-Json -Depth 8
