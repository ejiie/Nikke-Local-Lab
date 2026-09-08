#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MicronDriveLetter = 'E',
    [string]$CandidateRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelUserProgressionCandidate-v2',
    [string]$AuditRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelUserProgressionStrictAudit-v1',
    [string]$ParentGoldenRoot =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-parent-golden-v1\0cd733dc-118d-49f2-9973-d0fbda47ef8c',
    [string]$SourceRoot =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-source-v1\344b4a0b-16f8-4921-a681-608818bb1e1d'
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
    param([string]$Path, [long]$Length, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $Length -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary,
            (($Value | ConvertTo-Json -Depth 24) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-NativeJson {
    param([object[]]$Output, [string]$FailureCode)
    $text = (($Output | Out-String).Trim())
    Assert-True (-not [string]::IsNullOrWhiteSpace($text)) $FailureCode
    try { $text | ConvertFrom-Json }
    catch { throw $FailureCode }
}

function Get-GoldenTargetAudit {
    param([object]$Manifest, [string]$RuntimeRoot, [hashtable]$ToolMap)
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
                $length = if ($present) {
                    [long](Get-Item -LiteralPath $target).Length
                } else { -1L }
                $sha256 = if ($present) { Get-Sha256Hex $target } else { '' }
                [pscustomobject]@{
                    roleCode = $roleCode
                    expectedLength = [long]$member.byteLength
                    observedLength = $length
                    expectedSha256 = [string]$member.sha256
                    observedSha256 = $sha256
                    matched = $present -and
                        $length -eq [long]$member.byteLength -and
                        $sha256 -ceq [string]$member.sha256
                }
            }
        }
    )
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
            $length = if ($present) {
                [long](Get-Item -LiteralPath $path).Length
            } else { -1L }
            $sha256 = if ($present) { Get-Sha256Hex $path } else { '' }
            [pscustomobject]@{
                roleCode = $roleCode
                matched = $present -and
                    $length -eq [long]$member.byteLength -and
                    $sha256 -ceq [string]$member.sha256
            }
        }
    )
}

$expectedCandidatePointerLength = 908L
$expectedCandidatePointerSha256 =
    '3d96f60a277eb8ed489b246ea4d1dea0310ba32a866d4b908ef6a203663d7ba0'
$expectedCandidateReceiptLength = 3117L
$expectedCandidateReceiptSha256 =
    'e63cec5246967c5b4c66fe95e23325d574a1c8bb356e3719bbd3022c4ffbf479'
$expectedCandidateDatabaseLength = 1396707L
$expectedCandidateDatabaseSha256 =
    'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
$expectedParentReceiptSha256 =
    'c4d5239fedf6520fd23043e963b704831689a3cf3baf35a533bd340a8cb5c3b0'
$expectedGoldenDatabaseLength = 413327L
$expectedGoldenDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedSourceSha256 =
    'a9aedc9fababd392a44c533821c5626806d6eafec7bea43fa2dd4c2e9a1fb695'
$expectedStaticPackSha256 =
    '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3'
$expectedGoldenManifestLength = 86796L
$expectedGoldenManifestSha256 =
    '25a3a7696c486098bedf5184c31d80380543c3ab4809467e71b0a4594c332be7'
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'
$expectedCacheFileCount = 40113
$expectedCacheByteLength = 39031656543L
$expectedLocaleOverlayDeploymentSha256 =
    'ad416ccbec40aba0246b2983fb8afb5b9475020ba06b34a8bfd0a01c521c8d5e'
$expectedLocaleOverlayCorrectionSha256 =
    '47c20effff53d164ef0d91fe97812de9c9b553375215cda725acdb0effc19909'
$expectedSuccessfulRunStartSha256 =
    '92a7c9448385bd169e8660ce2dd055bce639b3531a801e6eb96e985c52893c2c'
$expectedSuccessfulBindingSha256 =
    'f52e616c24db66dcb398bb5e02970d0581fb3010ebde3c6c7a587dc36a866249'
$expectedSuccessfulCompletionSha256 =
    'a61531eda97872eab2f600960d38d22eb69e4659772575057c846e4a0c63a8e8'
$expectedBaseHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_progression_strict_audit_wrong_samsung_boundary'
$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True ($micronDrive -cne $env:SystemDrive -and
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*' -and
        (Test-Path -LiteralPath (Join-Path $micronDrive `
                'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1') `
            -PathType Leaf)) `
    'phase3b2_progression_strict_audit_physical_boundary_invalid'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_progression_strict_audit_runtime_not_cold'

$protectedBoundary = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
    'Micron-PrePhysicalLane-20260823\PhysicalP2') +
    [IO.Path]::DirectorySeparatorChar
$CandidateRoot = [IO.Path]::GetFullPath($CandidateRoot)
$AuditRoot = [IO.Path]::GetFullPath($AuditRoot)
$ParentGoldenRoot = [IO.Path]::GetFullPath($ParentGoldenRoot)
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
Assert-True ($CandidateRoot.StartsWith($protectedBoundary,
            [StringComparison]::OrdinalIgnoreCase) -and
        $AuditRoot.StartsWith($protectedBoundary,
            [StringComparison]::OrdinalIgnoreCase) -and
        $ParentGoldenRoot.StartsWith('D:\NikkeLocalLab\Backups\',
            [StringComparison]::OrdinalIgnoreCase) -and
        $SourceRoot.StartsWith('D:\NikkeLocalLab\Backups\',
            [StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_strict_audit_path_boundary_invalid'

$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$cacheRoot = Join-Path $runtimeRoot 'cache'
$runtimeDatabasePath = Join-Path $runtimeRoot 'db.json'
$staticPackPath = Join-Path $runtimeRoot `
    'cache\prdenv\150-cebfae1ecb\staticdata\data\qa-260813-08b\553116\mpk\StaticData.pack'
$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$goldenManifestPath = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\' +
    '15089f3e-92f2-4833-ab1b-348d1463f9fc\artifact.manifest.json')
$goldenBackupRoot = Split-Path -Parent $goldenManifestPath
$protectedGoldenRoot =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
    'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
    'EpinelLobbyGoldenBaseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\artifacts'
$candidatePointerPath = Join-Path $CandidateRoot `
    'latest-candidate.pointer.json'
$candidatePointer = Get-Content -LiteralPath $candidatePointerPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$candidateReceiptPath = [string]$candidatePointer.receiptPath
$candidateDatabasePath = [string]$candidatePointer.candidateDatabasePath
$parentReceiptPath = Join-Path $ParentGoldenRoot 'seal.receipt.json'
$goldenDatabasePath = Join-Path $ParentGoldenRoot 'db.json'
$sourcePath = Join-Path $SourceRoot 'progression.source.private.json'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot `
    'tools\Phase3B2.UserProgressionCandidateV2'
$projectPath = Join-Path $projectRoot `
    'Phase3B2.UserProgressionCandidateV2.csproj'
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$toolsRoot = Join-Path $micronDrive 'NLL\Tools'
$toolMap = @{
    native_cache_start = Join-Path $toolsRoot `
        'Start-Phase3B2-Epinel-NativeCache.ps1'
    minimal_start = Join-Path $toolsRoot `
        'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
    completion_wrapper = Join-Path $toolsRoot `
        'Complete-Phase3B2-Epinel-Minimal.ps1'
    completion_inner = Join-Path $toolsRoot `
        'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
    physical_bootstrap = Join-Path $micronDrive (
        'NLL\Runtime\PhysicalBootstrap-v2\artifact\' +
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')
}
$activePointers = @(
    Join-Path $physicalRoot `
        'epinel-minimal-reference-v1\active-run.pointer.json'
    Join-Path $physicalRoot `
        'epinel-user-progression-reference-v1\active-run.pointer.json'
)
$localeOverlayRoot = Join-Path $physicalRoot (
    'epinel-locale-catalog-overlay-v1\' +
    'd1087737-eae7-4e88-9fb5-9ced3e35aede')
$localeOverlayDeploymentPath = Join-Path $localeOverlayRoot `
    'deployment.receipt.json'
$localeOverlayCorrectionPath = Join-Path $localeOverlayRoot `
    'start-correction.receipt.json'
$successfulRunRoot = Join-Path (
    Join-Path $physicalRoot 'epinel-minimal-reference-v1'
) 'd830a90d-3596-4df5-8404-2bbb2e50a1f9'
$successfulRunStartPath = Join-Path $successfulRunRoot `
    'run-start.receipt.json'
$successfulBindingPath = Join-Path $successfulRunRoot `
    'native-cache.binding.receipt.json'
$successfulCompletionPath = Join-Path $successfulRunRoot `
    'completion.receipt.json'
$sqliteMembers = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $runtimeRoot $_ }

$required = @(
    $runtimeDatabasePath, $staticPackPath, $goldenManifestPath,
    $candidatePointerPath, $candidateReceiptPath, $candidateDatabasePath,
    $parentReceiptPath, $goldenDatabasePath, $sourcePath, $dotnetPath,
    $projectPath, $verifierManifestPath, $verifierDllPath, $hostsPath
) + @(
    $localeOverlayDeploymentPath, $localeOverlayCorrectionPath,
    $successfulRunStartPath, $successfulBindingPath,
    $successfulCompletionPath
) + @($toolMap.Values)
Assert-True (@($required | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_progression_strict_audit_input_missing'
Assert-True (@($activePointers + $sqliteMembers | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }).Count -eq 0) `
    'phase3b2_progression_strict_audit_runtime_residue_present'
Assert-True ((Test-Digest $candidatePointerPath `
            $expectedCandidatePointerLength $expectedCandidatePointerSha256) -and
        (Test-Digest $candidateReceiptPath $expectedCandidateReceiptLength `
            $expectedCandidateReceiptSha256) -and
        (Test-Digest $candidateDatabasePath $expectedCandidateDatabaseLength `
            $expectedCandidateDatabaseSha256) -and
        (Get-Sha256Hex $parentReceiptPath) -ceq
            $expectedParentReceiptSha256 -and
        (Test-Digest $goldenDatabasePath $expectedGoldenDatabaseLength `
            $expectedGoldenDatabaseSha256) -and
        (Test-Digest $runtimeDatabasePath $expectedGoldenDatabaseLength `
            $expectedGoldenDatabaseSha256) -and
        (Get-Sha256Hex $sourcePath) -ceq $expectedSourceSha256 -and
        (Get-Sha256Hex $staticPackPath) -ceq $expectedStaticPackSha256 -and
        (Test-Digest $goldenManifestPath $expectedGoldenManifestLength `
            $expectedGoldenManifestSha256) -and
        (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
        (Get-Sha256Hex $localeOverlayDeploymentPath) -ceq
            $expectedLocaleOverlayDeploymentSha256 -and
        (Get-Sha256Hex $localeOverlayCorrectionPath) -ceq
            $expectedLocaleOverlayCorrectionSha256 -and
        (Get-Sha256Hex $successfulRunStartPath) -ceq
            $expectedSuccessfulRunStartSha256 -and
        (Get-Sha256Hex $successfulBindingPath) -ceq
            $expectedSuccessfulBindingSha256 -and
        (Get-Sha256Hex $successfulCompletionPath) -ceq
            $expectedSuccessfulCompletionSha256) `
    'phase3b2_progression_strict_audit_input_digest_invalid'

$candidateReceipt = Get-Content -LiteralPath $candidateReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$parentReceipt = Get-Content -LiteralPath $parentReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $goldenManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$localeOverlayDeployment = Get-Content -LiteralPath `
    $localeOverlayDeploymentPath -Raw -Encoding UTF8 | ConvertFrom-Json
$localeOverlayCorrection = Get-Content -LiteralPath `
    $localeOverlayCorrectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$successfulRunStart = Get-Content -LiteralPath $successfulRunStartPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$successfulBinding = Get-Content -LiteralPath $successfulBindingPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$successfulCompletion = Get-Content -LiteralPath $successfulCompletionPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($candidatePointer.contractId -ceq
        'nll/phase3b2-user-progression-offline-candidate-pointer/v2' -and
        $candidateReceipt.contractId -ceq
        'nll/phase3b2-user-progression-offline-candidate-staging/v2' -and
        $parentReceipt.contractId -ceq
        'nll/phase3b2-user-progression-parent-golden-seal/v1' -and
        [bool]$parentReceipt.runtimeCold -and
        [bool]$parentReceipt.sqliteAbsenceSealed -and
        $manifest.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-artifact-manifest/v1' -and
        @($manifest.members).Count -eq 433 -and
        $localeOverlayDeployment.contractId -ceq
        'nll/phase3b2-epinel-locale-catalog-overlay/v1' -and
        $localeOverlayDeployment.localeCode -ceq 'en' -and
        [int]$localeOverlayDeployment.activeCacheFileCountAfter -eq
            $expectedCacheFileCount -and
        [long]$localeOverlayDeployment.activeCacheContentByteLengthAfter -eq
            $expectedCacheByteLength -and
        $localeOverlayCorrection.contractId -ceq
        'nll/phase3b2-epinel-locale-overlay-start-correction/v1' -and
        $successfulRunStart.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
        $successfulBinding.contractId -ceq
        'nll/phase3b2-epinel-native-cache-run-binding/v5' -and
        [int]$successfulBinding.activeCacheFileCount -eq
            $expectedCacheFileCount -and
        [long]$successfulBinding.activeCacheContentByteLength -eq
            $expectedCacheByteLength -and
        $successfulCompletion.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-completion/v1' -and
        $successfulCompletion.observedStageCode -ceq 'lobby' -and
        $successfulCompletion.outcomeCode -ceq 'success' -and
        [bool]$successfulCompletion.runtimeColdAfterCompletion) `
    'phase3b2_progression_strict_audit_contract_invalid'

$expectedRuntimeNames = @($manifest.members | Where-Object {
        ([string]$_.roleCode) -like 'runtime_top_level/*'
    } | ForEach-Object {
        ([string]$_.roleCode).Substring(18)
    } | Sort-Object -CaseSensitive)
$observedRuntimeNames = @(Get-ChildItem -LiteralPath $runtimeRoot -File `
    -Force | Select-Object -ExpandProperty Name | Sort-Object -CaseSensitive)
Assert-True ($expectedRuntimeNames.Count -eq 422 -and
        $observedRuntimeNames.Count -eq 422 -and
        ($expectedRuntimeNames -join "`n") -ceq
            ($observedRuntimeNames -join "`n")) `
    'phase3b2_progression_strict_audit_runtime_file_set_invalid'
$targetAudit = Get-GoldenTargetAudit -Manifest $manifest `
    -RuntimeRoot $runtimeRoot -ToolMap $toolMap
Assert-True ($targetAudit.Count -eq 427 -and
        @($targetAudit | Where-Object { -not $_.matched }).Count -eq 0) `
    'phase3b2_progression_strict_audit_active_golden_drifted'
$micronBackupAudit = Get-GoldenBackupAudit -Manifest $manifest `
    -BackupRoot $goldenBackupRoot
$protectedBackupAudit = Get-GoldenBackupAudit -Manifest $manifest `
    -BackupRoot $protectedGoldenRoot
Assert-True ($micronBackupAudit.Count -eq 433 -and
        @($micronBackupAudit | Where-Object { -not $_.matched }).Count -eq 0 -and
        $protectedBackupAudit.Count -eq 433 -and
        @($protectedBackupAudit | Where-Object {
                -not $_.matched
            }).Count -eq 0) `
    'phase3b2_progression_strict_audit_golden_backup_invalid'

$verifierManifest = Get-Content -LiteralPath $verifierManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ((Get-Sha256Hex $verifierManifestPath) -ceq
        $expectedVerifierManifestSha256 -and
        $verifierManifest.contractId -ceq
        'nll/phase3b2-native-cache-long-path-verifier-manifest/v1' -and
        @($verifierManifest.members).Count -eq 8) `
    'phase3b2_progression_strict_audit_cache_verifier_invalid'
foreach ($member in @($verifierManifest.members)) {
    $memberPath = Join-Path $verifierRoot ([string]$member.relativePath)
    Assert-True ((Test-Digest $memberPath ([long]$member.byteLength) `
            ([string]$member.sha256))) `
        'phase3b2_progression_strict_audit_cache_verifier_member_invalid'
}
$cacheOutput = & $dotnetPath $verifierDllPath inspect-cache-tree `
    $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_strict_audit_cache_inspection_failed'
$cacheInspection = Get-NativeJson $cacheOutput `
    'phase3b2_progression_strict_audit_cache_inspection_invalid'
Assert-True ($cacheInspection.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
        [bool]$cacheInspection.longPathSafeEnumerationUsed -and
        [int]$cacheInspection.fileCount -eq $expectedCacheFileCount -and
        [long]$cacheInspection.contentByteLength -eq
            $expectedCacheByteLength -and
        [int]$cacheInspection.partialMemberCount -eq 0) `
    'phase3b2_progression_strict_audit_cache_shape_invalid'

Push-Location $projectRoot
try {
    $sdkVersion = (& $dotnetPath --version 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $sdkVersion -ceq '10.0.400') `
        'phase3b2_progression_strict_audit_sdk_invalid'
    & $dotnetPath restore '.\Phase3B2.UserProgressionCandidateV2.csproj' `
        --locked-mode --ignore-failed-sources | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_progression_strict_audit_restore_failed'
    & $dotnetPath build '.\Phase3B2.UserProgressionCandidateV2.csproj' `
        -c Release --no-restore | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_progression_strict_audit_build_failed'
}
finally { Pop-Location }
$toolOutputRoot = Join-Path $projectRoot 'bin\Release\net10.0'
$toolDllName = 'Phase3B2.UserProgressionCandidateV2.dll'
$toolDllPath = Join-Path $toolOutputRoot $toolDllName
Assert-True (Test-Path -LiteralPath $toolDllPath -PathType Leaf) `
    'phase3b2_progression_strict_audit_tool_missing'

if (-not (Test-Path -LiteralPath $AuditRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $AuditRoot | Out-Null
}
$auditUid = [Guid]::NewGuid().ToString('D')
$assessmentRoot = Join-Path $AuditRoot $auditUid
Assert-True (-not (Test-Path -LiteralPath $assessmentRoot)) `
    'phase3b2_progression_strict_audit_collision'
New-Item -ItemType Directory -Path $assessmentRoot | Out-Null
$bundleRoot = Join-Path $assessmentRoot 'verifier-bundle'
$goldenVerifierRoot = Join-Path $assessmentRoot 'golden-materialization'
$candidateVerifierRoot = Join-Path $assessmentRoot `
    'candidate-materialization'
New-Item -ItemType Directory -Path @(
    $bundleRoot, $goldenVerifierRoot, $candidateVerifierRoot
) | Out-Null
Copy-Item -Path (Join-Path $toolOutputRoot '*') -Destination $bundleRoot `
    -Recurse -Force
Copy-Item -Path (Join-Path $toolOutputRoot '*') `
    -Destination $goldenVerifierRoot -Recurse -Force
Copy-Item -Path (Join-Path $toolOutputRoot '*') `
    -Destination $candidateVerifierRoot -Recurse -Force
Copy-Item -LiteralPath $goldenDatabasePath `
    -Destination (Join-Path $goldenVerifierRoot 'db.json') -Force
Copy-Item -LiteralPath $candidateDatabasePath `
    -Destination (Join-Path $candidateVerifierRoot 'db.json') -Force

$staticSummaryPath = Join-Path $assessmentRoot `
    'static-integrity.summary.json'
$staticOutput = & $dotnetPath $toolDllPath verify-static $staticPackPath `
    $sourcePath $goldenDatabasePath $candidateDatabasePath `
    $staticSummaryPath 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_strict_audit_static_gate_failed'
$staticSummary = Get-NativeJson $staticOutput `
    'phase3b2_progression_strict_audit_static_summary_invalid'
Assert-True ($staticSummary.contractId -ceq
        'nll/phase3b2-user-progression-static-integrity/v1' -and
        [bool]$staticSummary.stageAndMapReferencesVerified -and
        [bool]$staticSummary.scenarioReferencesVerifiedAgainstExactStageIndex -and
        [bool]$staticSummary.mainQuestReferencesVerified -and
        [bool]$staticSummary.contentsOpenReferencesVerified -and
        [bool]$staticSummary.allowedJsonChangeBoundaryVerified -and
        [int]$staticSummary.stageClearHistoryCount -eq 0) `
    'phase3b2_progression_strict_audit_static_contract_invalid'

$goldenSqlitePath = Join-Path $assessmentRoot 'golden-proof.db'
$candidateSqlitePath = Join-Path $assessmentRoot 'candidate-proof.db'
$goldenMaterializationOutput = & $dotnetPath `
    (Join-Path $goldenVerifierRoot $toolDllName) materialize-sqlite `
    $goldenSqlitePath 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_strict_audit_golden_migration_failed'
$goldenMaterialization = Get-NativeJson $goldenMaterializationOutput `
    'phase3b2_progression_strict_audit_golden_migration_invalid'
$candidateMaterializationOutput = & $dotnetPath `
    (Join-Path $candidateVerifierRoot $toolDllName) materialize-sqlite `
    $candidateSqlitePath 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_strict_audit_candidate_migration_failed'
$candidateMaterialization = Get-NativeJson $candidateMaterializationOutput `
    'phase3b2_progression_strict_audit_candidate_migration_invalid'
Assert-True ($goldenMaterialization.sourceDatabaseSha256 -ceq
        $expectedGoldenDatabaseSha256 -and
        [int]$goldenMaterialization.triggerRowCount -eq 0 -and
        $candidateMaterialization.sourceDatabaseSha256 -ceq
        $expectedCandidateDatabaseSha256 -and
        [int]$candidateMaterialization.triggerRowCount -eq 4786 -and
        $goldenMaterialization.sqliteIntegrityCode -ceq 'ok' -and
        $candidateMaterialization.sqliteIntegrityCode -ceq 'ok' -and
        [int]$goldenMaterialization.foreignKeyViolationCount -eq 0 -and
        [int]$candidateMaterialization.foreignKeyViolationCount -eq 0) `
    'phase3b2_progression_strict_audit_migration_contract_invalid'
$goldenMaterializationPath = Join-Path $assessmentRoot `
    'golden-materialization.summary.json'
$candidateMaterializationPath = Join-Path $assessmentRoot `
    'candidate-materialization.summary.json'
Write-AtomicJson $goldenMaterializationPath $goldenMaterialization
Write-AtomicJson $candidateMaterializationPath $candidateMaterialization

$strictDiffPath = Join-Path $assessmentRoot 'strict-diff.summary.json'
$diffOutput = & $dotnetPath (Join-Path $bundleRoot $toolDllName) `
    compare-strict $sourcePath $goldenDatabasePath $candidateDatabasePath `
    $goldenSqlitePath $candidateSqlitePath $strictDiffPath 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_strict_audit_relational_diff_failed'
$strictDiff = Get-NativeJson $diffOutput `
    'phase3b2_progression_strict_audit_relational_diff_invalid'
Assert-True ($strictDiff.contractId -ceq
        'nll/phase3b2-user-progression-strict-diff/v1' -and
        [bool]$strictDiff.allowedJsonChangeBoundaryVerified -and
        [bool]$strictDiff.onlyTriggerRowsAndTriggerSequenceChanged -and
        [int]$strictDiff.comparedTableCount -eq 6 -and
        [int]$strictDiff.identicalTableCount -eq 4 -and
        [int]$strictDiff.candidateTriggerRowCount -eq 4786 -and
        $strictDiff.sourceTriggerCanonicalSha256 -ceq
            $strictDiff.migratedTriggerCanonicalSha256 -and
        $strictDiff.goldenSqliteIntegrityCode -ceq 'ok' -and
        $strictDiff.candidateSqliteIntegrityCode -ceq 'ok' -and
        [int]$strictDiff.foreignKeyViolationCount -eq 0) `
    'phase3b2_progression_strict_audit_relational_contract_invalid'

$postTargetAudit = Get-GoldenTargetAudit -Manifest $manifest `
    -RuntimeRoot $runtimeRoot -ToolMap $toolMap
Assert-True ($postTargetAudit.Count -eq 427 -and
        @($postTargetAudit | Where-Object { -not $_.matched }).Count -eq 0 -and
        @($activePointers + $sqliteMembers | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count -eq 0 -and
        (Get-Sha256Hex $runtimeDatabasePath) -ceq
            $expectedGoldenDatabaseSha256 -and
        (Get-Sha256Hex $candidateDatabasePath) -ceq
            $expectedCandidateDatabaseSha256) `
    'phase3b2_progression_strict_audit_postcondition_invalid'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-strict-offline-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    auditUid = $auditUid
    candidateAssessmentUid = [string]$candidatePointer.assessmentUid
    candidatePointerSha256 = $expectedCandidatePointerSha256
    candidateReceiptSha256 = $expectedCandidateReceiptSha256
    parentGoldenReceiptSha256 = $expectedParentReceiptSha256
    goldenManifestSha256 = $expectedGoldenManifestSha256
    goldenManifestMemberCount = 433
    activeGoldenTargetCount = 427
    activeGoldenTargetMatchedCount = 427
    micronGoldenBackupMatchedMemberCount = 433
    protectedGoldenBackupMatchedMemberCount = 433
    goldenDatabaseSha256 = $expectedGoldenDatabaseSha256
    candidateDatabaseByteLength = $expectedCandidateDatabaseLength
    candidateDatabaseSha256 = $expectedCandidateDatabaseSha256
    localeOverlayDeploymentReceiptSha256 =
        $expectedLocaleOverlayDeploymentSha256
    localeOverlayCorrectionReceiptSha256 =
        $expectedLocaleOverlayCorrectionSha256
    successfulLobbyRunStartReceiptSha256 =
        $expectedSuccessfulRunStartSha256
    successfulLobbyCacheBindingReceiptSha256 =
        $expectedSuccessfulBindingSha256
    successfulLobbyCompletionReceiptSha256 =
        $expectedSuccessfulCompletionSha256
    staticDataPackSha256 = $expectedStaticPackSha256
    privateSourceSha256 = $expectedSourceSha256
    verifierToolSha256 = Get-Sha256Hex $toolDllPath
    staticIntegritySummarySha256 = Get-Sha256Hex $staticSummaryPath
    completedStageReferenceCount =
        [int]$staticSummary.completedStageReferenceCount
    completedScenarioCount = [int]$staticSummary.completedScenarioCount
    albumCrossReferencedScenarioCount =
        [int]$staticSummary.albumCrossReferencedScenarioCount
    albumUnindexedScenarioCount =
        [int]$staticSummary.albumUnindexedScenarioCount
    albumUnindexedScenarioCanonicalSha256 =
        [string]$staticSummary.albumUnindexedScenarioCanonicalSha256
    scenarioReferencesVerifiedAgainstExactStageIndex = $true
    mainQuestCount = [int]$staticSummary.mainQuestCount
    mainQuestReferencesVerified = $true
    contentsOpenUiStateCount =
        [int]$staticSummary.contentsOpenUiStateCount
    contentsOpenReferencesVerified = $true
    preservedUnresolvedCampaignTriggerCount =
        [int]$staticSummary.preservedUnresolvedCampaignTriggerCount
    preservedUnresolvedCampaignTriggerCanonicalSha256 =
        [string]$staticSummary.preservedUnresolvedCampaignTriggerCanonicalSha256
    allowedJsonChangedPropertyCount =
        @($strictDiff.changedUserProperties).Count
    allowedJsonChangeBoundaryVerified = $true
    goldenSqliteProofSha256 = Get-Sha256Hex $goldenSqlitePath
    candidateSqliteProofSha256 = Get-Sha256Hex $candidateSqlitePath
    strictDiffSummarySha256 = Get-Sha256Hex $strictDiffPath
    sqliteComparedTableCount = [int]$strictDiff.comparedTableCount
    sqliteIdenticalTableCount = [int]$strictDiff.identicalTableCount
    sqliteOnlyTriggerRowsAndSequenceChanged = $true
    triggerRowCount = [int]$strictDiff.candidateTriggerRowCount
    triggerCanonicalSha256 =
        [string]$strictDiff.migratedTriggerCanonicalSha256
    goldenSqliteIntegrityCode =
        [string]$strictDiff.goldenSqliteIntegrityCode
    candidateSqliteIntegrityCode =
        [string]$strictDiff.candidateSqliteIntegrityCode
    foreignKeyViolationCount = 0
    cacheFileCount = [int]$cacheInspection.fileCount
    cacheContentByteLength = [long]$cacheInspection.contentByteLength
    cachePartialMemberCount = 0
    runtimeCold = $true
    runtimeDatabaseModified = $false
    wrapperModified = $false
    wrapperBindingPerformed = $false
    innerStartModified = $false
    completionToolModified = $false
    serverBinaryModified = $false
    cacheModified = $false
    hostsModified = $false
    localLowInspected = $false
    localLowModified = $false
    dDriveWritePerformed = $false
    dDriveBackupCreated = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    verdictCode = 'strict_static_json_and_relational_gates_passed'
    nextStepCode =
        'apply_candidate_db_json_only_to_offline_micron_without_binding'
}
$receiptPath = Join-Path $assessmentRoot 'audit.receipt.json'
Write-AtomicJson $receiptPath $receipt
$pointer = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-strict-offline-audit-pointer/v1'
    auditUid = $auditUid
    receiptPath = $receiptPath
    receiptSha256 = Get-Sha256Hex $receiptPath
    candidateDatabasePath = $candidateDatabasePath
    candidateDatabaseSha256 = $expectedCandidateDatabaseSha256
    nextStepCode = [string]$receipt.nextStepCode
}
$pointerPath = Join-Path $AuditRoot 'latest-audit.pointer.json'
Write-AtomicJson $pointerPath $pointer

[ordered]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $receiptPath
    PointerPath = $pointerPath
    PointerSha256 = Get-Sha256Hex $pointerPath
} | ConvertTo-Json -Depth 24
