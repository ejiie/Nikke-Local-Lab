#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RuntimeRoot =
        'E:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$ToolRoot = 'E:\NLL\Tools',
    [string]$BackupRoot =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-parent-golden-v1',
    [string]$ExpectedDatabaseSha256 =
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [bool]$Condition,
        [string]$FailureCode
    )

    if (-not $Condition) {
        throw $FailureCode
    }
}

function Get-Sha256Hex {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).
        Hash.ToLowerInvariant()
}

function Write-JsonUtf8NoBom {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
}

$runtimeRootResolved = [System.IO.Path]::GetFullPath($RuntimeRoot)
$toolRootResolved = [System.IO.Path]::GetFullPath($ToolRoot)
$backupRootResolved = [System.IO.Path]::GetFullPath($BackupRoot)

Assert-True ($runtimeRootResolved.StartsWith(
        'E:\NLL\EpinelPS\',
        [System.StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_parent_runtime_root_invalid'
Assert-True ($toolRootResolved.StartsWith(
        'E:\NLL\Tools',
        [System.StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_parent_tool_root_invalid'
Assert-True ($backupRootResolved.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [System.StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_parent_backup_root_invalid'

$runtimeProcessNames = @(
    'NIKKE',
    'EpinelPS',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
$runningProcesses = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $runtimeProcessNames -contains $_.ProcessName }
)
Assert-True ($runningProcesses.Count -eq 0) `
    'phase3b2_progression_parent_runtime_not_cold'

$databasePath = Join-Path $runtimeRootResolved 'db.json'
Assert-True (Test-Path -LiteralPath $databasePath -PathType Leaf) `
    'phase3b2_progression_parent_database_missing'

$databaseItem = Get-Item -LiteralPath $databasePath
$databaseSha256 = Get-Sha256Hex $databasePath
Assert-True ($databaseSha256 -ceq $ExpectedDatabaseSha256.ToLowerInvariant()) `
    'phase3b2_progression_parent_database_not_golden'

$sqliteMembers = @(
    'epinelps.db',
    'epinelps.db-shm',
    'epinelps.db-wal'
)
$presentSqliteMembers = @(
    $sqliteMembers |
        Where-Object {
            Test-Path -LiteralPath (Join-Path $runtimeRootResolved $_) -PathType Leaf
        }
)
Assert-True ($presentSqliteMembers.Count -eq 0) `
    'phase3b2_progression_parent_sqlite_runtime_not_absent'

$toolContracts = @(
    [ordered]@{
        roleCode = 'successful_locale_overlay_start'
        leaf = 'Start-Phase3B2-Epinel-LocaleOverlay-en-v2.ps1'
        expectedSha256 =
            '50ead5cce82a602d67ee3edd114449c8ceb19a178fa8ce921d3d42d565a6646c'
    },
    [ordered]@{
        roleCode = 'golden_completion_wrapper'
        leaf = 'Complete-Phase3B2-Epinel-Minimal.ps1'
        expectedSha256 =
            '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1'
    },
    [ordered]@{
        roleCode = 'golden_inner_start'
        leaf = 'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
        expectedSha256 =
            'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
    },
    [ordered]@{
        roleCode = 'golden_inner_completion'
        leaf = 'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
        expectedSha256 =
            '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
    }
)

$toolMembers = @()
foreach ($contract in $toolContracts) {
    $path = Join-Path $toolRootResolved ([string]$contract.leaf)
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        ('phase3b2_progression_parent_tool_missing:' + $contract.roleCode)

    $item = Get-Item -LiteralPath $path
    $sha256 = Get-Sha256Hex $path
    Assert-True ($sha256 -ceq [string]$contract.expectedSha256) `
        ('phase3b2_progression_parent_tool_drifted:' + $contract.roleCode)

    $toolMembers += [ordered]@{
        roleCode = [string]$contract.roleCode
        leaf = [string]$contract.leaf
        byteLength = [long]$item.Length
        sha256 = $sha256
    }
}

Assert-True (Test-Path -LiteralPath (Split-Path -Parent $backupRootResolved) `
        -PathType Container) `
    'phase3b2_progression_parent_backup_parent_missing'

if (-not (Test-Path -LiteralPath $backupRootResolved -PathType Container)) {
    New-Item -ItemType Directory -Path $backupRootResolved | Out-Null
}

$sealUid = [guid]::NewGuid().ToString()
$sealRoot = Join-Path $backupRootResolved $sealUid
Assert-True (-not (Test-Path -LiteralPath $sealRoot)) `
    'phase3b2_progression_parent_seal_root_already_exists'
New-Item -ItemType Directory -Path $sealRoot | Out-Null

$backupDatabasePath = Join-Path $sealRoot 'db.json'
$partialDatabasePath = $backupDatabasePath + '.partial'
Copy-Item -LiteralPath $databasePath -Destination $partialDatabasePath
Assert-True ((Get-Sha256Hex $partialDatabasePath) -ceq $databaseSha256) `
    'phase3b2_progression_parent_database_copy_digest_invalid'
Move-Item -LiteralPath $partialDatabasePath -Destination $backupDatabasePath

$manifest = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-parent-golden-manifest/v1'
    sealUid = $sealUid
    database = [ordered]@{
        leaf = 'db.json'
        byteLength = [long]$databaseItem.Length
        sha256 = $databaseSha256
    }
    sqliteRuntime = @(
        $sqliteMembers | ForEach-Object {
            [ordered]@{
                leaf = $_
                present = $false
            }
        }
    )
    toolMembers = $toolMembers
}
$manifestPath = Join-Path $sealRoot 'baseline.manifest.json'
Write-JsonUtf8NoBom -Path $manifestPath -Value $manifest
$manifestItem = Get-Item -LiteralPath $manifestPath
$manifestSha256 = Get-Sha256Hex $manifestPath

$rollbackPlan = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-parent-golden-rollback/v1'
    sealUid = $sealUid
    allowedRestoreTarget = $databasePath
    backupDatabaseLeaf = 'db.json'
    backupDatabaseSha256 = $databaseSha256
    requiredColdState = $true
    requiredSqliteRuntimeAbsentBeforeRestore = $true
    cacheMutationAuthorized = $false
    toolMutationAuthorized = $false
    localLowMutationAuthorized = $false
}
$rollbackPlanPath = Join-Path $sealRoot 'rollback.plan.json'
Write-JsonUtf8NoBom -Path $rollbackPlanPath -Value $rollbackPlan
$rollbackPlanItem = Get-Item -LiteralPath $rollbackPlanPath
$rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-parent-golden-seal/v1'
    sealedAtUtc = [DateTime]::UtcNow.ToString('o')
    sealUid = $sealUid
    environmentCode = 'samsung_boot_micron_offline_runtime_cold'
    runtimeCold = $true
    databaseByteLength = [long]$databaseItem.Length
    databaseSha256 = $databaseSha256
    databaseBackupVerified = $true
    sqliteMainPresent = $false
    sqliteSharedMemoryPresent = $false
    sqliteWriteAheadLogPresent = $false
    sqliteAbsenceSealed = $true
    toolMemberCount = $toolMembers.Count
    toolMembersVerified = $true
    baselineManifestByteLength = [long]$manifestItem.Length
    baselineManifestSha256 = $manifestSha256
    rollbackPlanByteLength = [long]$rollbackPlanItem.Length
    rollbackPlanSha256 = $rollbackPlanSha256
    runtimeModified = $false
    databaseModified = $false
    toolModified = $false
    cacheInspected = $false
    cacheModified = $false
    localLowInspected = $false
    localLowModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode =
        'extract_progression_only_source_data_read_only_on_samsung'
}
$receiptPath = Join-Path $sealRoot 'seal.receipt.json'
Write-JsonUtf8NoBom -Path $receiptPath -Value $receipt
$receiptItem = Get-Item -LiteralPath $receiptPath
$receiptSha256 = Get-Sha256Hex $receiptPath

[ordered]@{
    Receipt = $receipt
    SealRoot = $sealRoot
    ReceiptPath = $receiptPath
    ReceiptByteLength = [long]$receiptItem.Length
    ReceiptSha256 = $receiptSha256
} | ConvertTo-Json -Depth 16
