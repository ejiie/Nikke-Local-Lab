#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$ProtectedRecoveryRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelProgressionToGoldenDb-v1',
    [string]$ProtectedGoldenRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelLobbyGoldenBaseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc',
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    return $item.Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
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

function Get-GoldenBackupAudit {
    param([object]$Manifest, [string]$BackupRoot)
    $toolExtensions = @{
        native_cache_start = '.ps1'
        minimal_start = '.ps1'
        completion_wrapper = '.ps1'
        completion_inner = '.ps1'
        physical_bootstrap = '.exe'
    }
    @(
        foreach ($member in @($Manifest.members)) {
            $roleCode = [string]$member.roleCode
            $relativePath = ''
            if ($roleCode -like 'runtime_top_level/*') {
                $relativePath = 'runtime-top-level\' +
                    $roleCode.Substring(18)
            }
            elseif ($roleCode -like 'tool/*') {
                $toolName = $roleCode.Substring(5)
                if ($toolExtensions.ContainsKey($toolName)) {
                    $relativePath = 'tools\' + $toolName +
                        $toolExtensions[$toolName]
                }
            }
            elseif ($roleCode -like 'receipt/*') {
                $relativePath = 'success-receipts\' +
                    $roleCode.Substring(8) + '.json'
            }
            elseif ($roleCode -ceq 'source/epinel_bundle') {
                $relativePath = 'epinel-source.bundle'
            }
            $path = if ($relativePath) {
                Join-Path $BackupRoot $relativePath
            } else { '' }
            $present = [bool]($path -and
                (Test-Path -LiteralPath $path -PathType Leaf))
            $observedLength = if ($present) {
                [long](Get-Item -LiteralPath $path).Length
            } else { -1L }
            $observedSha256 = if ($present) {
                Get-Sha256Hex $path
            } else { '' }
            [pscustomobject]@{
                roleCode = $roleCode
                mapped = [bool]$relativePath
                present = $present
                lengthMatched = $present -and
                    $observedLength -eq [long]$member.byteLength
                sha256Matched = $present -and
                    $observedSha256 -ceq [string]$member.sha256
            }
        }
    )
}

function Get-GoldenTargetAudit {
    param(
        [object]$Manifest,
        [string]$RuntimeRoot,
        [hashtable]$ToolMap
    )
    @(
        foreach ($member in @($Manifest.members)) {
            $roleCode = [string]$member.roleCode
            $target = $null
            if ($roleCode -like 'runtime_top_level/*') {
                $target = Join-Path $RuntimeRoot $roleCode.Substring(18)
            }
            elseif ($roleCode -like 'tool/*') {
                $target = $ToolMap[$roleCode.Substring(5)]
            }
            if ($null -ne $target) {
                $present = Test-Path -LiteralPath $target -PathType Leaf
                $observedLength = if ($present) {
                    [long](Get-Item -LiteralPath $target).Length
                } else { -1L }
                $observedSha256 = if ($present) {
                    Get-Sha256Hex $target
                } else { '' }
                [pscustomobject]@{
                    roleCode = $roleCode
                    path = $target
                    expectedLength = [long]$member.byteLength
                    observedLength = $observedLength
                    expectedSha256 = [string]$member.sha256
                    observedSha256 = $observedSha256
                    matched = $present -and
                        $observedLength -eq [long]$member.byteLength -and
                        $observedSha256 -ceq [string]$member.sha256
                }
            }
        }
    )
}

$goldenSealUid = '15089f3e-92f2-4833-ab1b-348d1463f9fc'
$completedAssessmentUid = '3e6a398d-b79d-4a77-b049-732d576b264a'
$expectedGoldenReceiptByteLength = 2596L
$expectedGoldenReceiptSha256 =
    'ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c'
$expectedManifestByteLength = 86796L
$expectedManifestSha256 =
    '25a3a7696c486098bedf5184c31d80380543c3ab4809467e71b0a4594c332be7'
$expectedGoldenDatabaseByteLength = 413327L
$expectedGoldenDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedCandidateDatabaseByteLength = 545413L
$expectedCandidateDatabaseSha256 =
    '3009a738fa809d16e4b5026c70ff39fbd71a6c95e5ad1270727aaff02e277f96'
$expectedServerDllSha256 =
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedGoldenWrapperSha256 =
    'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
$expectedGoldenInnerStartSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedGoldenCompletionWrapperSha256 =
    '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1'
$expectedGoldenInnerCompletionSha256 =
    '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
$expectedPhysicalBootstrapSha256 =
    'ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f'
$expectedCompletionReceiptByteLength = 1747L
$expectedCompletionReceiptSha256 =
    'bb486bee608f4381002b94433676531706978c125f0a00b36cdd2964326e2852'
$expectedRunStartReceiptSha256 =
    'f419a30e49e7d627be395f2aadb2e662957d895af45e92519d831f1bdc752219'
$expectedArchivedPointerSha256 =
    '9687db34c5000a1e17c2ab61cd35fd10b4be6db742800442acd2bb9879c767a9'
$expectedApplicationReceiptSha256 =
    'c6bfdc4a982d8341b88b03509a9e1252896031b75061388d039539efd95f1fce'
$expectedLaneRepairReceiptSha256 =
    '96ece9662a89df47fa3e08f012a5e635be780c0c05e5bfaabcd48e25891e1826'
$expectedBaseHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'
$expectedCacheFileCount = 40111
$expectedCacheByteLength = 39030643658L

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $AuditOnly) {
    Assert-True ($principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )) 'phase3b2_progression_to_golden_requires_administrator'
}
$protectedBoundary = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
    'Micron-PrePhysicalLane-20260823\PhysicalP2'
) + [IO.Path]::DirectorySeparatorChar
$expectedProtectedRecoveryRoot = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
    'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
    'EpinelProgressionToGoldenDb-v1'
)
$expectedProtectedGoldenRoot = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
    'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
    'EpinelLobbyGoldenBaseline-v1\' +
    '15089f3e-92f2-4833-ab1b-348d1463f9fc'
)
$normalizedProtectedRecoveryRoot =
    [IO.Path]::GetFullPath($ProtectedRecoveryRoot)
$normalizedProtectedGoldenRoot =
    [IO.Path]::GetFullPath($ProtectedGoldenRoot)
Assert-True (
    $normalizedProtectedRecoveryRoot.StartsWith(
        $protectedBoundary,
        [StringComparison]::OrdinalIgnoreCase
    ) -and
    $normalizedProtectedGoldenRoot.StartsWith(
        $protectedBoundary,
        [StringComparison]::OrdinalIgnoreCase
    ) -and
    $normalizedProtectedRecoveryRoot.Equals(
        $expectedProtectedRecoveryRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -and
    $normalizedProtectedGoldenRoot.Equals(
        $expectedProtectedGoldenRoot,
        [StringComparison]::OrdinalIgnoreCase
    )
) 'phase3b2_progression_to_golden_protected_boundary_invalid'
$ProtectedRecoveryRoot = $normalizedProtectedRecoveryRoot
$ProtectedGoldenRoot = $normalizedProtectedGoldenRoot
Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_progression_to_golden_wrong_samsung_boot_boundary'
$micronDrive = $MicronDriveLetter + ':'
$boundaryMarker = $(if ($AuditOnly) {
        Join-Path $micronDrive 'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
    } else {
        Join-Path $micronDrive 'Windows\System32\config\SYSTEM'
    })
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    (Test-Path -LiteralPath $boundaryMarker -PathType Leaf)
) 'phase3b2_progression_to_golden_micron_offline_boundary_invalid'
if (-not $AuditOnly) {
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
    Assert-True (
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*'
    ) 'phase3b2_progression_to_golden_physical_disk_identity_invalid'
}
Assert-True (@(Get-Process -Name @(
        'nikke', 'EpinelPS', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_progression_to_golden_runtime_not_cold'

$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$cacheRoot = Join-Path $runtimeRoot 'cache'
$databasePath = Join-Path $runtimeRoot 'db.json'
$serverDllPath = Join-Path $runtimeRoot 'EpinelPS.dll'
$toolsRoot = Join-Path $micronDrive 'NLL\Tools'
$goldenWrapperPath = Join-Path $toolsRoot `
    'Start-Phase3B2-Epinel-NativeCache.ps1'
$goldenInnerStartPath = Join-Path $toolsRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$goldenCompletionWrapperPath = Join-Path $toolsRoot `
    'Complete-Phase3B2-Epinel-Minimal.ps1'
$goldenInnerCompletionPath = Join-Path $toolsRoot `
    'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$physicalBootstrapPath = Join-Path $micronDrive (
    'NLL\Runtime\PhysicalBootstrap-v2\artifact\' +
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
)
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$activePointerPath = Join-Path $physicalRoot `
    'epinel-user-progression-reference-v1\active-run.pointer.json'
$goldenActivePointerPath = Join-Path $physicalRoot `
    'epinel-minimal-reference-v1\active-run.pointer.json'
$completedRunRoot = Join-Path (
    Join-Path $physicalRoot 'epinel-user-progression-reference-v1'
) $completedAssessmentUid
$runStartReceiptPath = Join-Path $completedRunRoot 'run-start.receipt.json'
$completionReceiptPath = Join-Path $completedRunRoot `
    'completion.receipt.json'
$archivedPointerPath = Join-Path $completedRunRoot `
    'active-run.pointer.archived.json'
$runDatabaseBeforePath = Join-Path $completedRunRoot 'db.before.bin'
$runHostsBeforePath = Join-Path $completedRunRoot 'hosts.before.bin'
$applicationReceiptPath = Join-Path $physicalRoot `
    'epinel-user-progression-active-v1\application.receipt.json'
$laneRepairReceiptPath = Join-Path $physicalRoot (
    'epinel-user-progression-bootstrap-lane-repair-v1\' +
    '87ec5d71-f321-4e2c-95b7-78aeead9b959\repair.receipt.json'
)
$goldenEvidenceRoot = Join-Path (
    Join-Path $physicalRoot 'epinel-lobby-golden-baseline-v1'
) $goldenSealUid
$goldenReceiptPath = Join-Path $goldenEvidenceRoot `
    'golden-baseline.receipt.json'
$goldenBackupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\' +
    $goldenSealUid
)
$goldenManifestPath = Join-Path $goldenBackupRoot `
    'artifact.manifest.json'
$goldenDatabasePath = Join-Path $goldenBackupRoot `
    'runtime-top-level\db.json'
$protectedGoldenReceiptPath = Join-Path $ProtectedGoldenRoot `
    'golden-baseline.receipt.json'
$protectedGoldenArtifactsRoot = Join-Path $ProtectedGoldenRoot 'artifacts'
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $runtimeRoot $_ })

$requiredPaths = @(
    $databasePath, $serverDllPath, $goldenWrapperPath,
    $goldenInnerStartPath, $goldenCompletionWrapperPath,
    $goldenInnerCompletionPath, $physicalBootstrapPath, $hostsPath,
    $runStartReceiptPath, $completionReceiptPath, $archivedPointerPath,
    $runDatabaseBeforePath, $runHostsBeforePath, $applicationReceiptPath,
    $laneRepairReceiptPath, $goldenReceiptPath, $goldenManifestPath,
    $goldenDatabasePath, $verifierManifestPath, $verifierDllPath,
    $dotnetPath
)
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_progression_to_golden_input_missing'
Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    -not (Test-Path -LiteralPath $goldenActivePointerPath) -and
    @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }).Count -eq 0
) 'phase3b2_progression_to_golden_runtime_residue_present'
Assert-True (
    (Test-Digest $databasePath $expectedCandidateDatabaseByteLength `
        $expectedCandidateDatabaseSha256) -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $goldenWrapperPath) -ceq
        $expectedGoldenWrapperSha256 -and
    (Get-Sha256Hex $goldenInnerStartPath) -ceq
        $expectedGoldenInnerStartSha256 -and
    (Get-Sha256Hex $goldenCompletionWrapperPath) -ceq
        $expectedGoldenCompletionWrapperSha256 -and
    (Get-Sha256Hex $goldenInnerCompletionPath) -ceq
        $expectedGoldenInnerCompletionSha256 -and
    (Get-Sha256Hex $physicalBootstrapPath) -ceq
        $expectedPhysicalBootstrapSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
    (Get-Sha256Hex $runStartReceiptPath) -ceq
        $expectedRunStartReceiptSha256 -and
    (Test-Digest $completionReceiptPath `
        $expectedCompletionReceiptByteLength `
        $expectedCompletionReceiptSha256) -and
    (Get-Sha256Hex $archivedPointerPath) -ceq
        $expectedArchivedPointerSha256 -and
    (Get-Sha256Hex $runDatabaseBeforePath) -ceq
        $expectedCandidateDatabaseSha256 -and
    (Get-Sha256Hex $runHostsBeforePath) -ceq $expectedBaseHostsSha256 -and
    (Get-Sha256Hex $applicationReceiptPath) -ceq
        $expectedApplicationReceiptSha256 -and
    (Get-Sha256Hex $laneRepairReceiptPath) -ceq
        $expectedLaneRepairReceiptSha256
) 'phase3b2_progression_to_golden_completed_state_drifted'

$completion = Get-Content -LiteralPath $completionReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$goldenReceipt = Get-Content -LiteralPath $goldenReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $goldenManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $completion.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-completion/v1' -and
    $completion.assessmentUid -ceq $completedAssessmentUid -and
    $completion.observedStageCode -ceq 'catalogue_path' -and
    $completion.outcomeCode -ceq 'system_error' -and
    $completion.databaseRestored -and
    $completion.sqliteRuntimeRemoved -and
    $completion.hostsRestored -and
    $completion.extensionFirewallRemoved -and
    $completion.runtimeColdAfterCompletion -and
    $goldenReceipt.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-baseline/v1' -and
    $goldenReceipt.sealUid -ceq $goldenSealUid -and
    $goldenReceipt.lobbyReached -and
    $goldenReceipt.databaseSha256 -ceq $expectedGoldenDatabaseSha256 -and
    $manifest.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-artifact-manifest/v1' -and
    $manifest.sealUid -ceq $goldenSealUid -and
    @($manifest.members).Count -eq 433
) 'phase3b2_progression_to_golden_contract_invalid'
Assert-True (
    (Test-Digest $goldenReceiptPath $expectedGoldenReceiptByteLength `
        $expectedGoldenReceiptSha256) -and
    (Test-Digest $goldenManifestPath $expectedManifestByteLength `
        $expectedManifestSha256) -and
    (Test-Digest $goldenDatabasePath $expectedGoldenDatabaseByteLength `
        $expectedGoldenDatabaseSha256)
) 'phase3b2_progression_to_golden_golden_source_invalid'

$expectedRuntimeTopLevelNames = @($manifest.members |
    Where-Object {
        ([string]$_.roleCode) -like 'runtime_top_level/*'
    } |
    ForEach-Object {
        ([string]$_.roleCode).Substring(18)
    } |
    Sort-Object -CaseSensitive)
$observedRuntimeTopLevelNames = @(Get-ChildItem -LiteralPath $runtimeRoot `
    -File -Force | Select-Object -ExpandProperty Name |
    Sort-Object -CaseSensitive)
Assert-True (
    $expectedRuntimeTopLevelNames.Count -eq 422 -and
    $observedRuntimeTopLevelNames.Count -eq 422 -and
    ($expectedRuntimeTopLevelNames -join "`n") -ceq
        ($observedRuntimeTopLevelNames -join "`n")
) 'phase3b2_progression_to_golden_runtime_top_level_set_invalid'

$backupAudit = Get-GoldenBackupAudit -Manifest $manifest `
    -BackupRoot $goldenBackupRoot
$backupMismatch = @($backupAudit | Where-Object {
        -not ($_.mapped -and $_.present -and
            $_.lengthMatched -and $_.sha256Matched)
    })
Assert-True (
    $backupAudit.Count -eq 433 -and $backupMismatch.Count -eq 0
) 'phase3b2_progression_to_golden_backup_manifest_mismatch'

$toolMap = @{
    native_cache_start = $goldenWrapperPath
    minimal_start = $goldenInnerStartPath
    completion_wrapper = $goldenCompletionWrapperPath
    completion_inner = $goldenInnerCompletionPath
    physical_bootstrap = $physicalBootstrapPath
}
$targetAudit = Get-GoldenTargetAudit -Manifest $manifest `
    -RuntimeRoot $runtimeRoot -ToolMap $toolMap
$targetDrift = @($targetAudit | Where-Object { -not $_.matched })
Assert-True (
    $targetAudit.Count -eq 427 -and
    $targetDrift.Count -eq 1 -and
    $targetDrift[0].roleCode -ceq 'runtime_top_level/db.json'
) 'phase3b2_progression_to_golden_unexpected_active_drift'

$verifierManifest = Get-Content -LiteralPath $verifierManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    (Get-Sha256Hex $verifierManifestPath) -ceq
        $expectedVerifierManifestSha256 -and
    $verifierManifest.contractId -ceq
        'nll/phase3b2-native-cache-long-path-verifier-manifest/v1' -and
    [int]$verifierManifest.memberCount -eq 8 -and
    @($verifierManifest.members).Count -eq 8
) 'phase3b2_progression_to_golden_verifier_manifest_invalid'
foreach ($member in @($verifierManifest.members)) {
    $memberPath = Join-Path $verifierRoot ([string]$member.relativePath)
    Assert-True (
        (Test-Path -LiteralPath $memberPath -PathType Leaf) -and
        (Get-Item -LiteralPath $memberPath).Length -eq
            [long]$member.byteLength -and
        (Get-Sha256Hex $memberPath) -ceq [string]$member.sha256
    ) 'phase3b2_progression_to_golden_verifier_member_invalid'
}
$inspectionOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_to_golden_cache_inspection_failed'
$inspection = (($inspectionOutput | Out-String) | ConvertFrom-Json)
Assert-True (
    $inspection.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $inspection.longPathSafeEnumerationUsed -and
    [int]$inspection.fileCount -eq $expectedCacheFileCount -and
    [long]$inspection.contentByteLength -eq $expectedCacheByteLength -and
    [int]$inspection.partialMemberCount -eq 0
) 'phase3b2_progression_to_golden_cache_shape_invalid'

if ($AuditOnly) {
    [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-progression-to-golden-db-audit/v1'
        auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        auditOnly = $true
        deployable = $false
        micronSideReady = $true
        readinessCode =
            'conditional_on_admin_disk_and_protected_copy_verification'
        completedAssessmentUid = $completedAssessmentUid
        completionReceiptSha256 = $expectedCompletionReceiptSha256
        goldenSealUid = $goldenSealUid
        goldenManifestMemberCount = 433
        goldenBackupMatchedMemberCount = 433
        activeGoldenTargetCount = 427
        activeGoldenTargetMatchedCountBefore = 426
        activeGoldenDriftCountBefore = 1
        activeGoldenDriftRoleCode = 'runtime_top_level/db.json'
        runtimeTopLevelExpectedCount = 422
        runtimeTopLevelObservedCount = 422
        runtimeTopLevelUnexpectedCount = 0
        currentDatabaseSha256 = $expectedCandidateDatabaseSha256
        plannedDatabaseSha256 = $expectedGoldenDatabaseSha256
        plannedRuntimeFileMutationCount = 1
        wrapperMutationPlanned = $false
        completionToolMutationPlanned = $false
        serverBinaryMutationPlanned = $false
        cacheMutationPlanned = $false
        localLowMutationPlanned = $false
        progressionToolMutationPlanned = $false
        runtimeBindingMutationPlanned = $false
        startupPreflightMutationPlanned = $false
        cacheFileCount = $expectedCacheFileCount
        cacheContentByteLength = $expectedCacheByteLength
        cachePartialMemberCount = 0
        userProgressionActiveRunPointerPresent = $false
        goldenActiveRunPointerPresent = $false
        protectedGoldenCopyAuditDeferredToAdministrator = $true
        targetMutationPerformed = $false
        nextStepCode =
            'rerun_same_tool_as_samsung_administrator_without_audit_only'
    } | ConvertTo-Json -Depth 8
    return
}

$protectedManifestPath = Join-Path $protectedGoldenArtifactsRoot `
    'artifact.manifest.json'
$protectedDatabasePath = Join-Path $protectedGoldenArtifactsRoot `
    'runtime-top-level\db.json'
Assert-True (
    (Test-Digest $protectedGoldenReceiptPath `
        $expectedGoldenReceiptByteLength $expectedGoldenReceiptSha256) -and
    (Test-Digest $protectedManifestPath $expectedManifestByteLength `
        $expectedManifestSha256) -and
    (Test-Digest $protectedDatabasePath $expectedGoldenDatabaseByteLength `
        $expectedGoldenDatabaseSha256)
) 'phase3b2_progression_to_golden_protected_source_invalid'
$protectedBackupAudit = Get-GoldenBackupAudit -Manifest $manifest `
    -BackupRoot $protectedGoldenArtifactsRoot
$protectedMismatch = @($protectedBackupAudit | Where-Object {
        -not ($_.mapped -and $_.present -and
            $_.lengthMatched -and $_.sha256Matched)
    })
Assert-True (
    $protectedBackupAudit.Count -eq 433 -and
    $protectedMismatch.Count -eq 0
) 'phase3b2_progression_to_golden_protected_manifest_mismatch'

$recoveryUid = [Guid]::NewGuid().ToString('D')
$protectedRecovery = Join-Path $ProtectedRecoveryRoot $recoveryUid
$micronRecovery = Join-Path (
    Join-Path $physicalRoot 'epinel-progression-to-golden-db-v1'
) $recoveryUid
Assert-True (
    -not (Test-Path -LiteralPath $protectedRecovery) -and
    -not (Test-Path -LiteralPath $micronRecovery)
) 'phase3b2_progression_to_golden_recovery_collision'
New-Item -ItemType Directory -Path $protectedRecovery -Force | Out-Null
New-Item -ItemType Directory -Path $micronRecovery -Force | Out-Null
$protectedDatabaseBeforePath = Join-Path $protectedRecovery `
    'db.before.json'
$micronDatabaseBeforePath = Join-Path $micronRecovery 'db.before.json'
Copy-Item -LiteralPath $databasePath `
    -Destination $protectedDatabaseBeforePath
Copy-Item -LiteralPath $databasePath -Destination $micronDatabaseBeforePath
Assert-True (
    (Get-Sha256Hex $protectedDatabaseBeforePath) -ceq
        $expectedCandidateDatabaseSha256 -and
    (Get-Sha256Hex $micronDatabaseBeforePath) -ceq
        $expectedCandidateDatabaseSha256
) 'phase3b2_progression_to_golden_database_backup_invalid'

$rollbackPlan = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-progression-to-golden-db-detached-rollback-plan/v1'
    recoveryUid = $recoveryUid
    activeDatabasePath =
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'
    detachedBackupRelativePath = 'db.before.json'
    expectedBackupSha256 = $expectedCandidateDatabaseSha256
    expectedAppliedSha256 = $expectedGoldenDatabaseSha256
    runtimeBinding = $false
    startupPreflightBinding = $false
}
$protectedRollbackPlanPath = Join-Path $protectedRecovery `
    'rollback.plan.json'
$micronRollbackPlanPath = Join-Path $micronRecovery 'rollback.plan.json'
Write-AtomicUtf8NoBom $protectedRollbackPlanPath `
    (($rollbackPlan | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
Copy-Item -LiteralPath $protectedRollbackPlanPath `
    -Destination $micronRollbackPlanPath
$rollbackPlanSha256 = Get-Sha256Hex $protectedRollbackPlanPath
Assert-True ((Get-Sha256Hex $micronRollbackPlanPath) -ceq
        $rollbackPlanSha256) `
    'phase3b2_progression_to_golden_rollback_plan_copy_invalid'

$databaseModified = $false
$transactionCommitted = $false
$protectedReceiptPath = Join-Path $protectedRecovery `
    'recovery.receipt.json'
$micronReceiptPath = Join-Path $micronRecovery `
    'recovery.receipt.json'
$protectedPendingReceiptPath = Join-Path $protectedRecovery `
    'recovery.receipt.pending.json'
$micronPendingReceiptPath = Join-Path $micronRecovery `
    'recovery.receipt.pending.json'
try {
    Copy-Atomic $goldenDatabasePath $databasePath
    $databaseModified = $true
    Assert-True ((Get-Sha256Hex $databasePath) -ceq
            $expectedGoldenDatabaseSha256) `
        'phase3b2_progression_to_golden_database_restore_failed'

    $afterAudit = Get-GoldenTargetAudit -Manifest $manifest `
        -RuntimeRoot $runtimeRoot -ToolMap $toolMap
    $afterDrift = @($afterAudit | Where-Object { -not $_.matched })
    Assert-True (
        $afterAudit.Count -eq 427 -and $afterDrift.Count -eq 0 -and
        (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
        -not (Test-Path -LiteralPath $activePointerPath) -and
        -not (Test-Path -LiteralPath $goldenActivePointerPath) -and
        @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count -eq 0
    ) 'phase3b2_progression_to_golden_postcondition_invalid'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-progression-to-golden-db-recovery/v1'
        recoveredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        recoveryUid = $recoveryUid
        completedAssessmentUid = $completedAssessmentUid
        completionReceiptSha256 = $expectedCompletionReceiptSha256
        goldenSealUid = $goldenSealUid
        goldenReceiptSha256 = $expectedGoldenReceiptSha256
        goldenManifestSha256 = $expectedManifestSha256
        goldenManifestMemberCount = 433
        micronGoldenBackupMatchedMemberCount = 433
        protectedGoldenBackupMatchedMemberCount = 433
        activeGoldenTargetCount = 427
        activeGoldenTargetMatchedCountBefore = 426
        activeGoldenTargetMatchedCountAfter = 427
        activeGoldenDriftCountBefore = 1
        activeGoldenDriftCountAfter = 0
        databaseBeforeByteLength = $expectedCandidateDatabaseByteLength
        databaseBeforeSha256 = $expectedCandidateDatabaseSha256
        databaseAfterByteLength = $expectedGoldenDatabaseByteLength
        databaseAfterSha256 = $expectedGoldenDatabaseSha256
        runtimeFileMutationCount = 1
        databaseModified = $true
        goldenStartWrapperModified = $false
        goldenInnerStartModified = $false
        goldenCompletionWrapperModified = $false
        goldenInnerCompletionModified = $false
        progressionToolsModified = $false
        serverBinaryModified = $false
        cacheModified = $false
        localLowInspected = $false
        localLowModified = $false
        hostsModified = $false
        runtimeBindingModified = $false
        startupPreflightModified = $false
        detachedRecoveryReceipt = $true
        recoveryReceiptUsedByRuntime = $false
        cacheFileCount = $expectedCacheFileCount
        cacheContentByteLength = $expectedCacheByteLength
        cachePartialMemberCount = 0
        activeRunPointerPresent = $false
        goldenActiveRunPointerPresent = $false
        sqliteRuntimeMemberCount = 0
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        rollbackPlanSha256 = $rollbackPlanSha256
        nextStepCode =
            'boot_micron_nlloperator_run_existing_golden_native_cache_control_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 8) +
        [Environment]::NewLine
    Write-AtomicUtf8NoBom $protectedPendingReceiptPath $receiptText
    Write-AtomicUtf8NoBom $micronPendingReceiptPath $receiptText
    $receiptSha256 = Get-Sha256Hex $protectedPendingReceiptPath
    Assert-True ((Get-Sha256Hex $micronPendingReceiptPath) -ceq
            $receiptSha256) `
        'phase3b2_progression_to_golden_receipt_copy_invalid'
    Move-Item -LiteralPath $protectedPendingReceiptPath `
        -Destination $protectedReceiptPath
    Move-Item -LiteralPath $micronPendingReceiptPath `
        -Destination $micronReceiptPath
    Assert-True (
        (Get-Sha256Hex $protectedReceiptPath) -ceq $receiptSha256 -and
        (Get-Sha256Hex $micronReceiptPath) -ceq $receiptSha256
    ) 'phase3b2_progression_to_golden_receipt_publish_invalid'
    $transactionCommitted = $true

    [ordered]@{
        Receipt = $receipt
        ProtectedReceiptPath = $protectedReceiptPath
        ProtectedReceiptByteLength =
            (Get-Item -LiteralPath $protectedReceiptPath).Length
        ProtectedReceiptSha256 = $receiptSha256
        MicronReceiptPath = $micronReceiptPath
        GoldenStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
    } | ConvertTo-Json -Depth 8
}
catch {
    $failure = $_
    if ($transactionCommitted) {
        throw $failure
    }
    $rollbackVerified = -not $databaseModified
    if ($databaseModified) {
        foreach ($rollbackSource in @(
                $protectedDatabaseBeforePath,
                $micronDatabaseBeforePath
            )) {
            if (-not (Test-Digest $rollbackSource `
                    $expectedCandidateDatabaseByteLength `
                    $expectedCandidateDatabaseSha256)) {
                continue
            }
            try {
                Copy-Atomic $rollbackSource $databasePath
                $rollbackVerified = Test-Digest $databasePath `
                    $expectedCandidateDatabaseByteLength `
                    $expectedCandidateDatabaseSha256
            }
            catch {
                $rollbackVerified = $false
            }
            if ($rollbackVerified) { break }
        }
    }
    $receiptCleanupVerified = $true
    foreach ($uncommittedReceiptPath in @(
            $protectedReceiptPath,
            $micronReceiptPath,
            $protectedPendingReceiptPath,
            $micronPendingReceiptPath
        )) {
        if (Test-Path -LiteralPath $uncommittedReceiptPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $uncommittedReceiptPath -Force
            }
            catch {
                $receiptCleanupVerified = $false
            }
            if (Test-Path -LiteralPath $uncommittedReceiptPath -PathType Leaf) {
                $receiptCleanupVerified = $false
            }
        }
    }
    Assert-True $rollbackVerified `
        'phase3b2_progression_to_golden_database_rollback_failed'
    Assert-True $receiptCleanupVerified `
        'phase3b2_progression_to_golden_uncommitted_receipt_cleanup_failed'
    throw $failure
}
