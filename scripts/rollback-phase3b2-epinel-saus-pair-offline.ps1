#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$StagingUid = '91e926f1-1073-4bb1-a0ae-6ad70dbab935',
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelSausPairStaging-v1'
    )
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

function Test-Digest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$micronDrive = $MicronDriveLetter + ':'
$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$cacheRoot = Join-Path $serverRoot 'cache'
$targetRoot = Join-Path $cacheRoot (
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\' +
    'saus\19e939d'
)
$targetBodyPath = Join-Path $targetRoot 'asset-catalog.cat'
$targetSignaturePath = $targetBodyPath + '.nds'
$laneRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-saus-pair-staging-v1'
)
$stagingReceiptPath = Join-Path $laneRoot 'staging.receipt.json'
$contractPath = Join-Path $laneRoot 'saus-http-pair.contract.json'
$toolBindingPath = Join-Path $laneRoot 'tool-binding.receipt.json'
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-minimal-reference-v1\active-run.pointer.json'
)
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelSausPair-v1\' + $StagingUid
)
$backupMinimalStartPath = Join-Path $backupRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$backupWrapperPath = Join-Path $backupRoot `
    'Start-Phase3B2-Epinel-NativeCache.ps1'
$minimalStartTargetPath = Join-Path $micronDrive (
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
)
$wrapperTargetPath = Join-Path $micronDrive (
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
)
$verifierDllPath = Join-Path $micronDrive (
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1\' +
    'Phase3B2.NativeCacheMaterializer.dll'
)
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$rollbackReceiptPath = Join-Path $laneRoot 'rollback.receipt.json'
$protectedLaneRoot = Join-Path $ProtectedRoot $StagingUid
$protectedRollbackPath = Join-Path $protectedLaneRoot `
    'rollback.receipt.json'

$expectedBodySha256 =
    'a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df'
$expectedSignatureSha256 =
    '01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2'
$expectedPriorMinimalStartSha256 =
    '385b5c41c1102e67cb31cd5372462933d22e0c7d26fda8b5dde659ec3637e5c9'
$expectedPriorWrapperSha256 =
    '310659582f0571f53c2a87789ab855ac8000931b618f585f02f5e7fb0c471e00'

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*'
) 'phase3b2_saus_rollback_wrong_disk_boundary'
Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0
) 'phase3b2_saus_rollback_runtime_not_cold'
foreach ($path in @(
        $stagingReceiptPath, $contractPath, $toolBindingPath,
        $targetBodyPath, $targetSignaturePath, $backupMinimalStartPath,
        $backupWrapperPath, $minimalStartTargetPath, $wrapperTargetPath,
        $verifierDllPath, $dotnetPath
    )) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase3b2_saus_rollback_input_missing'
}
Assert-True (
    -not (Test-Path -LiteralPath $rollbackReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedRollbackPath) -and
    (Test-Digest $targetBodyPath 13476L $expectedBodySha256) -and
    (Test-Digest $targetSignaturePath 96L $expectedSignatureSha256) -and
    (Get-Sha256Hex $backupMinimalStartPath) -ceq
        $expectedPriorMinimalStartSha256 -and
    (Get-Sha256Hex $backupWrapperPath) -ceq $expectedPriorWrapperSha256
) 'phase3b2_saus_rollback_shape_or_digest_invalid'

$staging = Get-Content -LiteralPath $stagingReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$binding = Get-Content -LiteralPath $toolBindingPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $staging.contractId -ceq
        'nll/phase3b2-epinel-saus-pair-staging/v1' -and
    $staging.stagingUid -ceq $StagingUid -and
    $staging.bodyStaged -and $staging.signatureStaged -and
    $binding.contractId -ceq
        'nll/phase3b2-epinel-saus-pair-tool-binding/v1' -and
    $binding.stagingUid -ceq $StagingUid -and
    (Get-Sha256Hex $minimalStartTargetPath) -ceq
        [string]$binding.minimalStartToolSha256 -and
    (Get-Sha256Hex $wrapperTargetPath) -ceq
        [string]$binding.wrapperToolSha256
) 'phase3b2_saus_rollback_contract_invalid'

$stagingReceiptSha256 = Get-Sha256Hex $stagingReceiptPath
$bindingSha256 = Get-Sha256Hex $toolBindingPath
Remove-Item -LiteralPath $targetSignaturePath -Force
Remove-Item -LiteralPath $targetBodyPath -Force
Copy-Item -LiteralPath $backupMinimalStartPath `
    -Destination $minimalStartTargetPath -Force
Copy-Item -LiteralPath $backupWrapperPath -Destination $wrapperTargetPath -Force
Assert-True (
    -not (Test-Path -LiteralPath $targetBodyPath) -and
    -not (Test-Path -LiteralPath $targetSignaturePath) -and
    (Get-Sha256Hex $minimalStartTargetPath) -ceq
        $expectedPriorMinimalStartSha256 -and
    (Get-Sha256Hex $wrapperTargetPath) -ceq $expectedPriorWrapperSha256
) 'phase3b2_saus_rollback_restore_failed'

$inspectionOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_saus_rollback_cache_inspection_failed'
$inspection = ($inspectionOutput | Out-String) | ConvertFrom-Json
Assert-True (
    $inspection.fileCount -eq 40109 -and
    [long]$inspection.contentByteLength -eq 39030630086L -and
    $inspection.partialMemberCount -eq 0
) 'phase3b2_saus_rollback_cache_shape_invalid'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-saus-pair-rollback/v1'
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    stagingUid = $StagingUid
    stagingReceiptSha256 = $stagingReceiptSha256
    toolBindingSha256 = $bindingSha256
    bodyRemoved = $true
    signatureRemoved = $true
    minimalStartToolRestored = $true
    wrapperToolRestored = $true
    cacheFileCountAfter = [int]$inspection.fileCount
    cacheContentByteLengthAfter = [long]$inspection.contentByteLength
    runtimeCold = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$receiptText = ($receipt | ConvertTo-Json -Depth 5) + "`n"
Write-AtomicUtf8NoBom $rollbackReceiptPath $receiptText
Write-AtomicUtf8NoBom $protectedRollbackPath $receiptText
$receiptSha256 = Get-Sha256Hex $rollbackReceiptPath
Assert-True (
    $receiptSha256 -ceq (Get-Sha256Hex $protectedRollbackPath)
) 'phase3b2_saus_rollback_dual_seal_invalid'

[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $rollbackReceiptPath
    ReceiptByteLength = (Get-Item $rollbackReceiptPath).Length
    ReceiptSha256 = $receiptSha256
} | ConvertTo-Json -Depth 7
