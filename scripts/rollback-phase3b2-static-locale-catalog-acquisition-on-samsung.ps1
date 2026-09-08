[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AssessmentUid,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedReceiptSha256
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

$parsedUid = [Guid]::Empty
Assert-True ([Guid]::TryParseExact($AssessmentUid, 'D', [ref]$parsedUid)) `
    'phase3b2_static_locale_rollback_assessment_uid_invalid'
$canonicalUid = $parsedUid.ToString('D')

$isAdministrator = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-True $isAdministrator `
    'phase3b2_static_locale_rollback_requires_administrator'

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter E | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_static_locale_rollback_disk_boundary_invalid'

$runtimeCount = @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
    -ErrorAction SilentlyContinue).Count
Assert-True ($runtimeCount -eq 0) `
    'phase3b2_static_locale_rollback_runtime_not_cold'

$sealedParent =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\LocaleCatalogAcquisition\Sealed'
$quarantineParent =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\Quarantine\Phase3B2StaticLocaleCatalogAcquisition'
$sourceRoot = Join-Path $sealedParent $canonicalUid
$destinationRoot = Join-Path $quarantineParent $canonicalUid
$receiptPath = Join-Path $sourceRoot 'acquisition.receipt.json'
Assert-True ((Test-Path -LiteralPath $sourceRoot -PathType Container) -and
    (Test-Path -LiteralPath $receiptPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $destinationRoot)) `
    'phase3b2_static_locale_rollback_source_shape_invalid'
Assert-True ((Get-Sha256Hex $receiptPath) -ceq
    $ExpectedReceiptSha256) `
    'phase3b2_static_locale_rollback_receipt_hash_mismatch'

$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($receipt.contractId -ceq
        'nll/phase3b2-static-locale-catalog-acquisition/v1' -and
    $receipt.assessmentUid -ceq $canonicalUid -and
    $receipt.verdictCode -ceq
        'exact_locale_catalog_pair_acquired_and_sealed' -and
    $receipt.requestedMemberCount -eq 2 -and
    $receipt.acquiredMemberCount -eq 2 -and
    -not $receipt.micronMutationPerformed) `
    'phase3b2_static_locale_rollback_receipt_invalid'

New-Item -ItemType Directory -Path $quarantineParent -Force | Out-Null
Move-Item -LiteralPath $sourceRoot -Destination $destinationRoot

$rollbackReceipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-static-locale-catalog-acquisition-rollback/v1'
    rolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $canonicalUid
    localeCode = [string]$receipt.localeCode
    acquisitionReceiptSha256 = $ExpectedReceiptSha256
    activeAcquisitionRemoved = $true
    recoverableQuarantinePreserved = $true
    contentDeleted = $false
    micronMutationPerformed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$rollbackPath = Join-Path $destinationRoot 'rollback.receipt.json'
Write-AtomicUtf8NoBom $rollbackPath `
    (($rollbackReceipt | ConvertTo-Json) + "`n")

[pscustomobject]@{
    Receipt = $rollbackReceipt
    ReceiptByteLength = (Get-Item -LiteralPath $rollbackPath).Length
    ReceiptSha256 = Get-Sha256Hex $rollbackPath
} | ConvertTo-Json -Depth 5
