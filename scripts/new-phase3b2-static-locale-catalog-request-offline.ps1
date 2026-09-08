[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VersionMapPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedVersionMapSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z]{2}(?:-[a-z]{2})?$')]
    [string]$LocaleCode,

    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$ClientBuild = '150.6.9',

    [ValidatePattern('^[a-z0-9-]{1,64}$')]
    [string]$ClientBuildRoot = '150-b059c3f36c',

    [ValidatePattern('^[0-9]{1,12}$')]
    [string]$LatestPostfix = '651',

    [string]$OutputRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\LocaleCatalogAcquisition\Requests'
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
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

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-NoReparseAncestor {
    param([string]$Path, [string]$FailureCode)
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = Split-Path -Parent $cursor
        Assert-True (-not [string]::IsNullOrWhiteSpace($parent)) $FailureCode
        $cursor = $parent
    }
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force
        Assert-True (
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
        ) $FailureCode
        $parent = Split-Path -Parent $cursor
        if ($parent -ceq $cursor) { break }
        $cursor = $parent
    }
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

$versionMapFullPath = [IO.Path]::GetFullPath($VersionMapPath)
Assert-True (Test-Path -LiteralPath $versionMapFullPath -PathType Leaf) `
    'phase3b2_static_locale_request_version_map_missing'
Assert-NoReparseAncestor $versionMapFullPath `
    'phase3b2_static_locale_request_version_map_reparse_invalid'
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
Assert-True (-not $versionMapFullPath.StartsWith(
    $repositoryRoot.TrimEnd('\') + '\',
    [StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_static_locale_request_version_map_must_be_git_external'

$versionMapBytes = [IO.File]::ReadAllBytes($versionMapFullPath)
Assert-True ($versionMapBytes.Length -gt 0 -and
    $versionMapBytes.Length -le 32768 -and
    -not ($versionMapBytes.Length -ge 3 -and
        $versionMapBytes[0] -eq 0xef -and
        $versionMapBytes[1] -eq 0xbb -and
        $versionMapBytes[2] -eq 0xbf)) `
    'phase3b2_static_locale_request_version_map_encoding_invalid'
$versionMapSha256 = Get-BytesSha256Hex $versionMapBytes
Assert-True ($versionMapSha256 -ceq $ExpectedVersionMapSha256) `
    'phase3b2_static_locale_request_version_map_hash_mismatch'
Assert-True ((Split-Path -Leaf $versionMapFullPath) -ceq
    ('latest-' + $LatestPostfix + '.txt')) `
    'phase3b2_static_locale_request_version_map_filename_mismatch'
try {
    $versionMapText =
        [Text.UTF8Encoding]::new($false, $true).GetString($versionMapBytes)
}
catch { throw 'phase3b2_static_locale_request_version_map_utf8_invalid' }

$selected = [Collections.Generic.List[object]]::new()
foreach ($line in ($versionMapText -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    Assert-True ($line -cmatch
        '^([a-z]{2,8}(?:-[a-z]{2})?):([0-9]{1,12}),([A-Za-z0-9.]{1,64})$') `
        'phase3b2_static_locale_request_version_map_line_invalid'
    if ($Matches[1] -ceq $LocaleCode) {
        $selected.Add([pscustomobject]@{
            ContentVersion = [long]$Matches[2]
            RevisionCode = $Matches[3]
        })
    }
}
Assert-True ($selected.Count -eq 1) `
    'phase3b2_static_locale_request_version_map_locale_missing_or_ambiguous'
Assert-True ($selected[0].RevisionCode -cmatch '^[0-9a-f]{7}$') `
    'phase3b2_static_locale_request_version_map_locale_revision_invalid'

$requiredOutputRoot = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\LocaleCatalogAcquisition\Requests')
$fullOutputRoot = [IO.Path]::GetFullPath($OutputRoot)
Assert-True ($fullOutputRoot -ceq $requiredOutputRoot) `
    'phase3b2_static_locale_request_output_root_invalid'
Assert-NoReparseAncestor $fullOutputRoot `
    'phase3b2_static_locale_request_output_root_reparse_invalid'

$requestSetUid = [Guid]::NewGuid().ToString('D')
$requestDirectory = Join-Path (Join-Path $fullOutputRoot $LocaleCode) `
    $requestSetUid
Assert-True (-not (Test-Path -LiteralPath $requestDirectory)) `
    'phase3b2_static_locale_request_output_already_present'
New-Item -ItemType Directory -Path $requestDirectory -Force | Out-Null

$revisionCode = $selected[0].RevisionCode
$contentVersion = $selected[0].ContentVersion
$baseUri = 'https://cloud.nikke-kr.com/prdenv/' + $ClientBuildRoot +
    '/StandaloneWindows64/pck/' + $LocaleCode + '/' + $revisionCode +
    '/asset-catalog.cat'
$manifest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-approved-static-locale-catalog-request/v1'
    requestSetUid = $requestSetUid
    clientBuild = $ClientBuild
    clientBuildRoot = $ClientBuildRoot
    latestPostfix = $LatestPostfix
    localeCode = $LocaleCode
    revisionCode = $revisionCode
    contentVersion = $contentVersion
    members = @(
        [ordered]@{
            roleCode = 'locale_catalog_body'
            kindCode = 'nkdb_body'
            uri = $baseUri
        },
        [ordered]@{
            roleCode = 'locale_catalog_signature'
            kindCode = 'detached_signature_96'
            uri = $baseUri + '.nds'
        }
    )
}
$manifestPath = Join-Path $requestDirectory 'request.manifest.json'
Write-AtomicUtf8NoBom $manifestPath `
    (($manifest | ConvertTo-Json -Depth 6) + "`n")

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-static-locale-catalog-request-preparation/v1'
    preparedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    requestSetUid = $requestSetUid
    clientBuild = $ClientBuild
    clientBuildRoot = $ClientBuildRoot
    latestPostfix = $LatestPostfix
    localeCode = $LocaleCode
    revisionCode = $revisionCode
    contentVersion = $contentVersion
    versionMapByteLength = $versionMapBytes.Length
    versionMapSha256 = $versionMapSha256
    requestManifestByteLength = (Get-Item -LiteralPath $manifestPath).Length
    requestManifestSha256 = Get-Sha256Hex $manifestPath
    requestedMemberCount = 2
    networkRequestStarted = $false
    micronMutationPerformed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'review_and_validate_manifest_before_explicit_acquisition'
}
$receiptPath = Join-Path $requestDirectory 'preparation.receipt.json'
Write-AtomicUtf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")

[pscustomobject]@{
    Receipt = $receipt
    RequestManifestPath = $manifestPath
    PreparationReceiptPath = $receiptPath
    PreparationReceiptSha256 = Get-Sha256Hex $receiptPath
} | ConvertTo-Json -Depth 6
