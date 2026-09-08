#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [switch]$AuditOnly,
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelLobbyGoldenRestore-v1'
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
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.
        ToLowerInvariant()
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
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Copy-Atomic {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-GoldenTargetAudit {
    param(
        [object]$Manifest,
        [string]$RuntimeRoot,
        [hashtable]$ToolMap
    )
    @(
        foreach ($member in @($Manifest.members)) {
            $target = $null
            if ([string]$member.roleCode -like 'runtime_top_level/*') {
                $target = Join-Path $RuntimeRoot (
                    ([string]$member.roleCode).Substring(18)
                )
            }
            elseif ([string]$member.roleCode -like 'tool/*') {
                $target = $ToolMap[
                    ([string]$member.roleCode).Substring(5)
                ]
            }
            if ($null -ne $target) {
                $exists = Test-Path -LiteralPath $target -PathType Leaf
                $observedLength = if ($exists) {
                    [long](Get-Item -LiteralPath $target).Length
                } else { -1L }
                $observedSha256 = if ($exists) {
                    Get-Sha256Hex $target
                } else { '' }
                [pscustomobject]@{
                    roleCode = [string]$member.roleCode
                    path = $target
                    expectedLength = [long]$member.byteLength
                    observedLength = $observedLength
                    expectedSha256 = [string]$member.sha256
                    observedSha256 = $observedSha256
                    matched = $exists -and
                        $observedLength -eq [long]$member.byteLength -and
                        $observedSha256 -ceq [string]$member.sha256
                }
            }
        }
    )
}

$goldenSealUid = '15089f3e-92f2-4833-ab1b-348d1463f9fc'
$failedAssessmentUid = 'de00aafb-bab3-48ca-8caf-49261a49a654'
$expectedGoldenReceiptSha256 =
    'ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c'
$expectedManifestSha256 =
    '25a3a7696c486098bedf5184c31d80380543c3ab4809467e71b0a4594c332be7'
$expectedGoldenDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedGoldenWrapperSha256 =
    'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
$expectedGoldenInnerStartSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedServerDllSha256 =
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedCurrentDatabaseSha256 =
    'c09bc7e15709e24ba9d5a3528ee3c1ce0f1cb1e4ea790a2b957969020a18ea8d'
$expectedCurrentWrapperSha256 =
    '26dccd12c7f0daaa35ac225b0fbdb0abf7767cd0ab529a0958663efaaccf2fbc'
$expectedCurrentInnerStartSha256 =
    '00270a38140f4ace8e77192e285731909a172e4e587c80394bac7bb55650e7ae'
$expectedRunStartSha256 =
    '8b65a237ca2ef5b680e8d20cc5cb1c8f090023ab32a7ced3fae092d35fa9c2e8'
$expectedRunBindingSha256 =
    '36030fca4e0e5775ff072b96714f4cc413813084236251864d970e617075b98b'
$expectedActivePointerSha256 =
    '0fcb0a83740a67fcd4f1c1380e8c004b3610c07109da4af3e97a922d3283e7fa'
$expectedV2CorrectionReceiptSha256 =
    '8ad2a714e8aefaa67c231c50af5c3d2539d7bc1a124be686940b032183529ab9'
$expectedAppliedHostsSha256 =
    '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
$expectedBaseHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedCacheFileCount = 40111
$expectedCacheByteLength = 39030643658L

$micronDrive = $MicronDriveLetter + ':'
if ($AuditOnly) {
    Assert-True (
        $env:SystemDrive -ceq 'C:' -and
        (Test-Path -LiteralPath (
                Join-Path $micronDrive 'Windows\System32'
            ) -PathType Container)
    ) 'phase3b2_epinel_golden_restore_audit_boundary_invalid'
}
else {
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
    Assert-True (
        $env:SystemDrive -ceq 'C:' -and
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*' -and
        (Test-Path -LiteralPath (
                Join-Path $micronDrive 'Windows\System32'
            ) -PathType Container)
    ) 'phase3b2_epinel_golden_restore_wrong_disk_boundary'
}
Assert-True (@(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_epinel_golden_restore_runtime_not_cold'

$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$cacheRoot = Join-Path $runtimeRoot 'cache'
$databasePath = Join-Path $runtimeRoot 'db.json'
$serverDllPath = Join-Path $runtimeRoot 'EpinelPS.dll'
$wrapperPath = Join-Path $micronDrive `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$innerStartPath = Join-Path $micronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$completionWrapperPath = Join-Path $micronDrive `
    'NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1'
$completionInnerPath = Join-Path $micronDrive `
    'NLL\Tools\complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$bootstrapPath = Join-Path $micronDrive (
    'NLL\Runtime\PhysicalBootstrap-v2\artifact\' +
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
)
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$activePointerPath = Join-Path (
    $physicalRoot + '\epinel-minimal-reference-v1'
) 'active-run.pointer.json'
$runRoot = Join-Path (
    $physicalRoot + '\epinel-minimal-reference-v1'
) $failedAssessmentUid
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$runBindingPath = Join-Path $runRoot 'native-cache.binding.receipt.json'
$dbBeforePath = Join-Path $runRoot 'db.before.bin'
$hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
$archivedActivePointerPath = Join-Path $runRoot `
    'active-run.pointer.archived-by-golden-restore.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $runtimeRoot $_ })
$v2ReceiptPath = Join-Path (
    $physicalRoot +
    '\epinel-tutorial-native-cache-wrapper-correction-v2\' +
    '8ba2fb71-913c-4eaf-a56e-55c10c79d5c1'
) 'repair.receipt.json'

$goldenEvidenceRoot = Join-Path (
    $physicalRoot + '\epinel-lobby-golden-baseline-v1'
) $goldenSealUid
$goldenReceiptPath = Join-Path $goldenEvidenceRoot `
    'golden-baseline.receipt.json'
$goldenBackupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\' +
    $goldenSealUid
)
$goldenManifestPath = Join-Path $goldenBackupRoot 'artifact.manifest.json'
$goldenDatabasePath = Join-Path $goldenBackupRoot `
    'runtime-top-level\db.json'
$goldenWrapperPath = Join-Path $goldenBackupRoot `
    'tools\native_cache_start.ps1'
$goldenInnerStartPath = Join-Path $goldenBackupRoot `
    'tools\minimal_start.ps1'
$protectedGoldenRoot = (
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
    'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
    'EpinelLobbyGoldenBaseline-v1\' + $goldenSealUid
)
$protectedGoldenReceiptPath = Join-Path $protectedGoldenRoot `
    'golden-baseline.receipt.json'
$protectedGoldenArtifactRoot = Join-Path $protectedGoldenRoot 'artifacts'

$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$finalizerTemplatePath = Join-Path $PSScriptRoot `
    'Finalize-Phase3B2-Epinel-Lobby-Golden-Restore.ps1'
$activeFinalizerPath = Join-Path $micronDrive `
    'NLL\Tools\Finalize-Phase3B2-Epinel-Lobby-Golden-Restore.ps1'

$requiredFiles = @(
    $goldenReceiptPath, $goldenManifestPath, $goldenDatabasePath,
    $goldenWrapperPath, $goldenInnerStartPath,
    $databasePath, $serverDllPath, $wrapperPath, $innerStartPath,
    $completionWrapperPath, $completionInnerPath, $bootstrapPath,
    $hostsPath, $activePointerPath, $runStartPath, $runBindingPath,
    $dbBeforePath, $hostsBeforePath, $v2ReceiptPath,
    $verifierManifestPath, $verifierDllPath, $dotnetPath,
    $finalizerTemplatePath
)
Assert-True (@($requiredFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_epinel_golden_restore_input_missing'
if (-not $AuditOnly) {
    $protectedRequiredFiles = @(
        $protectedGoldenReceiptPath,
        (Join-Path $protectedGoldenArtifactRoot 'artifact.manifest.json'),
        (Join-Path $protectedGoldenArtifactRoot 'runtime-top-level\db.json'),
        (Join-Path $protectedGoldenArtifactRoot `
            'tools\native_cache_start.ps1'),
        (Join-Path $protectedGoldenArtifactRoot 'tools\minimal_start.ps1')
    )
    Assert-True (@($protectedRequiredFiles | Where-Object {
                -not (Test-Path -LiteralPath $_ -PathType Leaf)
            }).Count -eq 0) `
        'phase3b2_epinel_golden_restore_protected_input_missing'
}
Assert-True (
    (Get-Item -LiteralPath $goldenReceiptPath).Length -eq 2596L -and
    (Get-Sha256Hex $goldenReceiptPath) -ceq
        $expectedGoldenReceiptSha256 -and
    (Get-Item -LiteralPath $goldenManifestPath).Length -eq 86796L -and
    (Get-Sha256Hex $goldenManifestPath) -ceq
        $expectedManifestSha256 -and
    (Get-Sha256Hex $goldenDatabasePath) -ceq
        $expectedGoldenDatabaseSha256 -and
    (Get-Sha256Hex $goldenWrapperPath) -ceq
        $expectedGoldenWrapperSha256 -and
    (Get-Sha256Hex $goldenInnerStartPath) -ceq
        $expectedGoldenInnerStartSha256
) 'phase3b2_epinel_golden_restore_golden_artifact_invalid'
if (-not $AuditOnly) {
    Assert-True (
        (Get-Sha256Hex $protectedGoldenReceiptPath) -ceq
            $expectedGoldenReceiptSha256 -and
        (Get-Sha256Hex (Join-Path $protectedGoldenArtifactRoot `
                    'artifact.manifest.json')) -ceq
            $expectedManifestSha256 -and
        (Get-Sha256Hex (Join-Path $protectedGoldenArtifactRoot `
                    'runtime-top-level\db.json')) -ceq
            $expectedGoldenDatabaseSha256 -and
        (Get-Sha256Hex (Join-Path $protectedGoldenArtifactRoot `
                    'tools\native_cache_start.ps1')) -ceq
            $expectedGoldenWrapperSha256 -and
        (Get-Sha256Hex (Join-Path $protectedGoldenArtifactRoot `
                    'tools\minimal_start.ps1')) -ceq
            $expectedGoldenInnerStartSha256
    ) 'phase3b2_epinel_golden_restore_protected_artifact_invalid'
}

$goldenReceipt = Get-Content -LiteralPath $goldenReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $goldenManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runBinding = Get-Content -LiteralPath $runBindingPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$v2Receipt = Get-Content -LiteralPath $v2ReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $goldenReceipt.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-baseline/v1' -and
    $goldenReceipt.sealUid -ceq $goldenSealUid -and
    $goldenReceipt.lobbyReached -and
    $goldenReceipt.databaseSha256 -ceq
        $expectedGoldenDatabaseSha256 -and
    $manifest.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-artifact-manifest/v1' -and
    $manifest.sealUid -ceq $goldenSealUid -and
    $manifest.memberCount -eq 433 -and
    @($manifest.members).Count -eq 433 -and
    $pointer.contractId -ceq
        'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -and
    $pointer.assessmentUid -ceq $failedAssessmentUid -and
    $pointer.runStartReceiptSha256 -ceq $expectedRunStartSha256 -and
    $runStart.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    $runStart.assessmentUid -ceq $failedAssessmentUid -and
    $runStart.tutorialOnlyRevisionVerified -and
    $runStart.clientExecutionStarted -and
    $runBinding.assessmentUid -ceq $failedAssessmentUid -and
    $runBinding.tutorialOnlyRevisionVerified -and
    $v2Receipt.contractId -ceq
        'nll/phase3b2-epinel-tutorial-native-cache-wrapper-correction/v2'
) 'phase3b2_epinel_golden_restore_contract_invalid'
Assert-True (
    (Get-Sha256Hex $activePointerPath) -ceq
        $expectedActivePointerSha256 -and
    (Get-Sha256Hex $runStartPath) -ceq $expectedRunStartSha256 -and
    (Get-Sha256Hex $runBindingPath) -ceq $expectedRunBindingSha256 -and
    (Get-Sha256Hex $v2ReceiptPath) -ceq
        $expectedV2CorrectionReceiptSha256 -and
    (Get-Sha256Hex $dbBeforePath) -ceq
        'e8c6c7d299be04c91435391bd44e346ad3dd84f31697654f18b1aa8a47052330' -and
    (Get-Sha256Hex $hostsBeforePath) -ceq $expectedBaseHostsSha256 -and
    (Get-Sha256Hex $databasePath) -ceq
        $expectedCurrentDatabaseSha256 -and
    (Get-Sha256Hex $wrapperPath) -ceq
        $expectedCurrentWrapperSha256 -and
    (Get-Sha256Hex $innerStartPath) -ceq
        $expectedCurrentInnerStartSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedAppliedHostsSha256
) 'phase3b2_epinel_golden_restore_current_state_drifted'

$toolMap = @{
    native_cache_start = $wrapperPath
    minimal_start = $innerStartPath
    completion_wrapper = $completionWrapperPath
    completion_inner = $completionInnerPath
    physical_bootstrap = $bootstrapPath
}
$beforeAudit = Get-GoldenTargetAudit -Manifest $manifest `
    -RuntimeRoot $runtimeRoot -ToolMap $toolMap
$beforeDrift = @($beforeAudit | Where-Object { -not $_.matched })
$expectedDriftRoles = @(
    'runtime_top_level/db.json',
    'tool/minimal_start',
    'tool/native_cache_start'
)
Assert-True (
    $beforeAudit.Count -eq 427 -and
    $beforeDrift.Count -eq 3 -and
    @($beforeDrift | Where-Object {
            $_.roleCode -notin $expectedDriftRoles
        }).Count -eq 0
) 'phase3b2_epinel_golden_restore_unexpected_target_drift'

$verifierManifest = Get-Content -LiteralPath $verifierManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $verifierManifest.contractId -ceq
        'nll/phase3b2-native-cache-long-path-verifier-manifest/v1' -and
    $verifierManifest.memberCount -eq 8 -and
    @($verifierManifest.members).Count -eq 8
) 'phase3b2_epinel_golden_restore_verifier_manifest_invalid'
foreach ($member in @($verifierManifest.members)) {
    $memberPath = Join-Path $verifierRoot ([string]$member.relativePath)
    Assert-True (
        (Test-Path -LiteralPath $memberPath -PathType Leaf) -and
        (Get-Item -LiteralPath $memberPath).Length -eq
            [long]$member.byteLength -and
        (Get-Sha256Hex $memberPath) -ceq [string]$member.sha256
    ) 'phase3b2_epinel_golden_restore_verifier_member_invalid'
}
$inspectionOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_epinel_golden_restore_cache_inspection_failed'
$inspection = (($inspectionOutput | Out-String) | ConvertFrom-Json)
Assert-True (
    $inspection.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $inspection.longPathSafeEnumerationUsed -and
    $inspection.fileCount -eq $expectedCacheFileCount -and
    [long]$inspection.contentByteLength -eq $expectedCacheByteLength -and
    $inspection.partialMemberCount -eq 0
) 'phase3b2_epinel_golden_restore_cache_shape_invalid'

if ($AuditOnly) {
    [pscustomobject]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-lobby-golden-restore-audit/v1'
        auditedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        goldenSealUid = $goldenSealUid
        failedAssessmentUid = $failedAssessmentUid
        comparableTargetCount = $beforeAudit.Count
        expectedDriftCount = 3
        observedDriftCount = $beforeDrift.Count
        observedDriftRoleCodes = @($beforeDrift.roleCode | Sort-Object)
        activePointerVerified = $true
        appliedHostsVerified = $true
        sqliteRuntimeMemberCount = @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count
        cacheFileCount = [int]$inspection.fileCount
        cacheContentByteLength = [long]$inspection.contentByteLength
        cachePartialMemberCount = [int]$inspection.partialMemberCount
        mutationPerformed = $false
        verdictCode =
            'exact_three_file_drift_and_abandoned_run_recovery_ready'
    } | ConvertTo-Json -Depth 7
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_epinel_golden_restore_requires_administrator'

$restoreUid = [Guid]::NewGuid().ToString('D')
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenRestore-v1\' + $restoreUid
)
$evidenceRoot = Join-Path (
    $physicalRoot + '\epinel-lobby-golden-restore-v1'
) $restoreUid
$pendingPointerPath = Join-Path (
    $physicalRoot + '\epinel-lobby-golden-restore-v1'
) 'pending-firewall-cleanup.pointer.json'
$protectedRestoreRoot = Join-Path $ProtectedRoot $restoreUid
Assert-True (
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $evidenceRoot) -and
    -not (Test-Path -LiteralPath $protectedRestoreRoot) -and
    -not (Test-Path -LiteralPath $pendingPointerPath) -and
    -not (Test-Path -LiteralPath $archivedActivePointerPath) -and
    -not (Test-Path -LiteralPath $activeFinalizerPath)
) 'phase3b2_epinel_golden_restore_destination_collision'

$partialBackupRoot = $backupRoot + '.partial-' +
    [Guid]::NewGuid().ToString('N')
try {
    New-Item -ItemType Directory -Path $partialBackupRoot -Force |
        Out-Null
    Copy-Item -LiteralPath $databasePath -Destination (
        Join-Path $partialBackupRoot 'db.before.bin'
    )
    Copy-Item -LiteralPath $wrapperPath -Destination (
        Join-Path $partialBackupRoot 'outer-wrapper.before.ps1'
    )
    Copy-Item -LiteralPath $innerStartPath -Destination (
        Join-Path $partialBackupRoot 'inner-start.before.ps1'
    )
    Copy-Item -LiteralPath $hostsPath -Destination (
        Join-Path $partialBackupRoot 'hosts.before.bin'
    )
    Copy-Item -LiteralPath $activePointerPath -Destination (
        Join-Path $partialBackupRoot 'active-run.pointer.before.json'
    )
    foreach ($path in $sqlitePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Copy-Item -LiteralPath $path -Destination (
                Join-Path $partialBackupRoot (
                    'sqlite-' + [IO.Path]::GetFileName($path)
                )
            )
        }
    }
    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-lobby-golden-restore-rollback-plan/v1'
        restoreUid = $restoreUid
        requiresSamsungBoot = $true
        requiresMicronOffline = $true
        runtimeMustBeCold = $true
        restorePreGoldenFilesFromThisDirectory = $true
        cacheRollbackRequired = $false
        serverBinaryRollbackRequired = $false
        automaticRollbackPerformed = $false
    }
    Write-AtomicUtf8NoBom (
        Join-Path $partialBackupRoot 'rollback.plan.json'
    ) (($rollbackPlan | ConvertTo-Json -Depth 5) + "`n")
    Move-Item -LiteralPath $partialBackupRoot -Destination $backupRoot
}
finally {
    if (Test-Path -LiteralPath $partialBackupRoot) {
        Remove-Item -LiteralPath $partialBackupRoot -Recurse -Force
    }
}

try {
    Copy-Atomic $goldenDatabasePath $databasePath
    Copy-Atomic $goldenWrapperPath $wrapperPath
    Copy-Atomic $goldenInnerStartPath $innerStartPath
    Copy-Atomic $hostsBeforePath $hostsPath
    foreach ($path in $sqlitePaths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Move-Item -LiteralPath $activePointerPath `
        -Destination $archivedActivePointerPath

    $afterAudit = Get-GoldenTargetAudit -Manifest $manifest `
        -RuntimeRoot $runtimeRoot -ToolMap $toolMap
    Assert-True (
        $afterAudit.Count -eq 427 -and
        @($afterAudit | Where-Object { -not $_.matched }).Count -eq 0 -and
        (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
        @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0 -and
        -not (Test-Path -LiteralPath $activePointerPath)
    ) 'phase3b2_epinel_golden_restore_post_restore_invalid'

    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-lobby-golden-restore/v1'
        restoredAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        restoreUid = $restoreUid
        goldenSealUid = $goldenSealUid
        goldenReceiptSha256 = $expectedGoldenReceiptSha256
        goldenManifestSha256 = $expectedManifestSha256
        abandonedAssessmentUid = $failedAssessmentUid
        abandonedRunStartReceiptSha256 = $expectedRunStartSha256
        abandonedRunBindingReceiptSha256 = $expectedRunBindingSha256
        abandonedActivePointerSha256 = $expectedActivePointerSha256
        abandonedRunPointerArchived = $true
        completionReceiptFabricated = $false
        priorDatabaseSha256 = $expectedCurrentDatabaseSha256
        restoredDatabaseSha256 = $expectedGoldenDatabaseSha256
        priorOuterWrapperSha256 = $expectedCurrentWrapperSha256
        restoredOuterWrapperSha256 = $expectedGoldenWrapperSha256
        priorInnerStartSha256 = $expectedCurrentInnerStartSha256
        restoredInnerStartSha256 = $expectedGoldenInnerStartSha256
        serverDllSha256 = $expectedServerDllSha256
        comparableGoldenTargetCount = 427
        preRestoreDriftCount = 3
        postRestoreDriftCount = 0
        hostsRestoredOffline = $true
        sqliteRuntimeRemovedOffline = $true
        activeRunPointerArchivedOffline = $true
        firewallCleanupPending = $true
        goldenBaselineActive = $true
        tutorialRevisionActive = $false
        tutorialEvidencePreserved = $true
        activeCacheFileCount = [int]$inspection.fileCount
        activeCacheContentByteLength = [long]$inspection.contentByteLength
        activeCachePartialMemberCount = [int]$inspection.partialMemberCount
        cacheMutationPerformed = $false
        serverBinaryMutationPerformed = $false
        targetOsOfflineDuringRestore = $true
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        nextStepCode =
            'boot_micron_nlloperator_finalize_firewall_cleanup_once'
    }
    $restoreReceiptPath = Join-Path $evidenceRoot 'restore.receipt.json'
    Write-AtomicUtf8NoBom $restoreReceiptPath (
        ($receipt | ConvertTo-Json -Depth 7) + "`n"
    )
    $restoreReceiptSha256 = Get-Sha256Hex $restoreReceiptPath

    $finalizerTemplateText = Get-Content -LiteralPath `
        $finalizerTemplatePath -Raw -Encoding UTF8
    Assert-True (
        ([regex]::Matches($finalizerTemplateText,
                '__GOLDEN_RESTORE_UID__')).Count -eq 1 -and
        ([regex]::Matches($finalizerTemplateText,
                '__GOLDEN_RESTORE_RECEIPT_SHA256__')).Count -eq 1
    ) 'phase3b2_epinel_golden_restore_finalizer_template_invalid'
    $finalizerText = $finalizerTemplateText.
        Replace('__GOLDEN_RESTORE_UID__', $restoreUid).
        Replace('__GOLDEN_RESTORE_RECEIPT_SHA256__',
            $restoreReceiptSha256)
    $parseTokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput(
        $finalizerText, [ref]$parseTokens, [ref]$parseErrors
    ) | Out-Null
    Assert-True (@($parseErrors).Count -eq 0) `
        'phase3b2_epinel_golden_restore_finalizer_candidate_invalid'
    Write-AtomicUtf8NoBom $activeFinalizerPath $finalizerText
    $finalizerSha256 = Get-Sha256Hex $activeFinalizerPath
    $binding = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-lobby-golden-restore-finalizer-binding/v1'
        boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        restoreUid = $restoreUid
        restoreReceiptSha256 = $restoreReceiptSha256
        finalizerTemplateSha256 = Get-Sha256Hex $finalizerTemplatePath
        activeFinalizerByteLength = [long](
            Get-Item -LiteralPath $activeFinalizerPath
        ).Length
        activeFinalizerSha256 = $finalizerSha256
        firewallGroup = 'NLL Phase3B2 Epinel Minimal Extension'
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode =
            'boot_micron_nlloperator_run_golden_restore_finalizer_once'
    }
    $bindingReceiptPath = Join-Path $evidenceRoot `
        'finalizer.binding.receipt.json'
    Write-AtomicUtf8NoBom $bindingReceiptPath (
        ($binding | ConvertTo-Json -Depth 6) + "`n"
    )
    $pending = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-lobby-golden-restore-pending-finalization/v1'
        restoreUid = $restoreUid
        restoreReceiptSha256 = $restoreReceiptSha256
        finalizerBindingReceiptSha256 = Get-Sha256Hex $bindingReceiptPath
        firewallCleanupPending = $true
        nextStepCode = 'run_golden_restore_finalizer_once'
    }
    Write-AtomicUtf8NoBom $pendingPointerPath (
        ($pending | ConvertTo-Json -Depth 5) + "`n"
    )

    New-Item -ItemType Directory -Path $protectedRestoreRoot -Force |
        Out-Null
    Copy-Item -LiteralPath $backupRoot -Destination (
        Join-Path $protectedRestoreRoot 'before-artifacts'
    ) -Recurse
    Copy-Item -LiteralPath $evidenceRoot -Destination (
        Join-Path $protectedRestoreRoot 'evidence'
    ) -Recurse
    Assert-True (
        (Get-Sha256Hex (Join-Path $protectedRestoreRoot `
                    'evidence\restore.receipt.json')) -ceq
            $restoreReceiptSha256 -and
        (Get-Sha256Hex (Join-Path $protectedRestoreRoot `
                    'evidence\finalizer.binding.receipt.json')) -ceq
            (Get-Sha256Hex $bindingReceiptPath)
    ) 'phase3b2_epinel_golden_restore_protected_copy_invalid'
}
catch {
    if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        Copy-Atomic (Join-Path $backupRoot 'db.before.bin') $databasePath
        Copy-Atomic (Join-Path $backupRoot 'outer-wrapper.before.ps1') `
            $wrapperPath
        Copy-Atomic (Join-Path $backupRoot 'inner-start.before.ps1') `
            $innerStartPath
        Copy-Atomic (Join-Path $backupRoot 'hosts.before.bin') $hostsPath
        if (-not (Test-Path -LiteralPath $activePointerPath) -and
            (Test-Path -LiteralPath (Join-Path $backupRoot `
                    'active-run.pointer.before.json'))) {
            Copy-Atomic (Join-Path $backupRoot `
                    'active-run.pointer.before.json') $activePointerPath
        }
        if (Test-Path -LiteralPath $archivedActivePointerPath) {
            Remove-Item -LiteralPath $archivedActivePointerPath -Force
        }
        foreach ($path in $sqlitePaths) {
            $backupPath = Join-Path $backupRoot (
                'sqlite-' + [IO.Path]::GetFileName($path)
            )
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Copy-Atomic $backupPath $path
            }
        }
    }
    if (Test-Path -LiteralPath $pendingPointerPath) {
        Remove-Item -LiteralPath $pendingPointerPath -Force
    }
    if (Test-Path -LiteralPath $activeFinalizerPath) {
        Remove-Item -LiteralPath $activeFinalizerPath -Force
    }
    throw
}

[pscustomobject]@{
    Receipt = $receipt
    RestoreReceiptPath = $restoreReceiptPath
    RestoreReceiptByteLength = (
        Get-Item -LiteralPath $restoreReceiptPath
    ).Length
    RestoreReceiptSha256 = $restoreReceiptSha256
    FinalizerBindingReceiptPath = $bindingReceiptPath
    FinalizerBindingReceiptSha256 = Get-Sha256Hex $bindingReceiptPath
    MicronFinalizationCommand =
        "& 'C:\NLL\Tools\Finalize-Phase3B2-Epinel-Lobby-Golden-Restore.ps1'"
} | ConvertTo-Json -Depth 8
