#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [switch]$AuditOnly
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

function Copy-Atomic {
    param([string]$Source, [string]$Destination)
    $temporary = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary,
            (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$expectedGoldenDatabaseLength = 413327L
$expectedGoldenDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedCandidateDatabaseLength = 1396707L
$expectedCandidateDatabaseSha256 =
    'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
$expectedGoldenOuterSha256 =
    '50ead5cce82a602d67ee3edd114449c8ceb19a178fa8ce921d3d42d565a6646c'
$expectedGoldenInnerStartSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedGoldenCompletionWrapperSha256 =
    '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1'
$expectedGoldenCompletionInnerSha256 =
    '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
$expectedBaseHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_progression_v2_rollback_wrong_samsung_boundary'
$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True ($micronDrive -cne $env:SystemDrive -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*') `
    'phase3b2_progression_v2_rollback_physical_boundary_invalid'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_progression_v2_rollback_runtime_not_cold'

$protectedLaneRoot =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelUserProgressionDerivedLane-v2'
$pointerPath = Join-Path $protectedLaneRoot `
    'latest-application.pointer.json'
Assert-True (Test-Path -LiteralPath $pointerPath -PathType Leaf) `
    'phase3b2_progression_v2_rollback_pointer_missing'
$pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-epinel-user-progression-v2-application-pointer/v1' -and
    $pointer.active -and
    [Guid]::Parse([string]$pointer.applicationUid) -ne [Guid]::Empty -and
    (Get-Sha256Hex ([string]$pointer.applicationReceiptPath)) -ceq
        [string]$pointer.applicationReceiptSha256 -and
    (Get-Sha256Hex ([string]$pointer.rollbackPlanPath)) -ceq
        [string]$pointer.rollbackPlanSha256) `
    'phase3b2_progression_v2_rollback_pointer_invalid'
$plan = Get-Content -LiteralPath ([string]$pointer.rollbackPlanPath) -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($plan.contractId -ceq
        'nll/phase3b2-epinel-user-progression-v2-rollback-plan/v1' -and
    $plan.applicationUid -ceq [string]$pointer.applicationUid -and
    $plan.goldenDatabaseSha256 -ceq $expectedGoldenDatabaseSha256 -and
    $plan.candidateDatabaseSha256 -ceq $expectedCandidateDatabaseSha256 -and
    -not $plan.goldenToolsModified -and
    -not $plan.dDriveWritePermitted) `
    'phase3b2_progression_v2_rollback_plan_invalid'

$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $runtimeRoot 'db.json'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$goldenToolPaths = @(
    @( (Join-Path $toolRoot `
            'Start-Phase3B2-Epinel-LocaleOverlay-en-v2.ps1'),
        $expectedGoldenOuterSha256 ),
    @( (Join-Path $toolRoot `
            'start-phase3b2-epinel-minimal-reference-in-micron.ps1'),
        $expectedGoldenInnerStartSha256 ),
    @( (Join-Path $toolRoot 'Complete-Phase3B2-Epinel-Minimal.ps1'),
        $expectedGoldenCompletionWrapperSha256 ),
    @( (Join-Path $toolRoot `
            'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'),
        $expectedGoldenCompletionInnerSha256 )
)
foreach ($check in $goldenToolPaths) {
    Assert-True ((Test-Path -LiteralPath ([string]$check[0]) `
            -PathType Leaf) -and
        (Get-Sha256Hex ([string]$check[0])) -ceq ([string]$check[1])) `
        'phase3b2_progression_v2_rollback_golden_tool_drifted'
}
$hostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$activePointerPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-v2\active-run.pointer.json'
Assert-True ((Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $runtimeRoot $_) }
    ).Count -eq 0) 'phase3b2_progression_v2_rollback_runtime_shape_invalid'
Assert-True ((Test-Digest $databasePath $expectedCandidateDatabaseLength `
        $expectedCandidateDatabaseSha256) -or
    (Test-Digest $databasePath $expectedGoldenDatabaseLength `
        $expectedGoldenDatabaseSha256)) `
    'phase3b2_progression_v2_rollback_database_unknown'
$capturedMicronGoldenPath =
    [string]$plan.micronGoldenDatabaseBackupPath
$dFallbackPath = [string]$plan.dGoldenDatabaseReadOnlyFallbackPath
Assert-True (Test-Digest $capturedMicronGoldenPath `
        $expectedGoldenDatabaseLength $expectedGoldenDatabaseSha256) `
    'phase3b2_progression_v2_rollback_captured_micron_golden_invalid'
Assert-True (Test-Digest $dFallbackPath $expectedGoldenDatabaseLength `
        $expectedGoldenDatabaseSha256) `
    'phase3b2_progression_v2_rollback_d_fallback_invalid'
Assert-True ((Get-Sha256Hex $capturedMicronGoldenPath) -ceq
        (Get-Sha256Hex $dFallbackPath)) `
    'phase3b2_progression_v2_rollback_golden_sources_mismatch'

$audit = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-user-progression-v2-rollback-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    applicationUid = [string]$pointer.applicationUid
    capturedMicronGoldenVerified = $true
    dGoldenFallbackReadOnlyVerified = $true
    goldenToolsVerifiedUnchanged = $true
    runtimeCold = $true
    activeRunPointerPresent = $false
    sqliteRuntimeMemberCount = 0
    dDriveWritePerformed = $false
    readyToRollback = $true
}
if ($AuditOnly) {
    $audit | ConvertTo-Json -Depth 8
    return
}

Copy-Atomic $capturedMicronGoldenPath $databasePath
Assert-True (Test-Digest $databasePath $expectedGoldenDatabaseLength `
        $expectedGoldenDatabaseSha256) `
    'phase3b2_progression_v2_rollback_restore_failed'
$rollbackRoot = Join-Path ([string]$pointer.protectedApplicationRoot) `
    ('rollback-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $rollbackRoot | Out-Null
$receiptPath = Join-Path $rollbackRoot 'rollback.receipt.json'
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-user-progression-v2-rollback/v1'
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    applicationUid = [string]$pointer.applicationUid
    restoredDatabaseByteLength = $expectedGoldenDatabaseLength
    restoredDatabaseSha256 = $expectedGoldenDatabaseSha256
    restoreSourceCode = 'captured_micron_golden_verified_against_d_backup'
    goldenToolsModified = $false
    derivedToolsRemoved = $false
    derivedToolsRemainInert = $true
    hostsModified = $false
    cacheModified = $false
    localLowInspected = $false
    localLowModified = $false
    dDriveWritePerformed = $false
    nextStepCode = 'golden_locale_overlay_control_available'
}
Write-AtomicJson $receiptPath $receipt
$pointer.active = $false
$pointer.rolledBack = $true
$pointer.rollbackReceiptPath = $receiptPath
$pointer.rollbackReceiptSha256 = Get-Sha256Hex $receiptPath
Write-AtomicJson $pointerPath $pointer
[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptSha256 = Get-Sha256Hex $receiptPath
} | ConvertTo-Json -Depth 8
