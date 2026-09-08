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

function Assert-PowerShellSyntax {
    param([string]$Path, [string]$FailureCode)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors
    ) | Out-Null
    Assert-True (@($errors).Count -eq 0) $FailureCode
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
            (($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
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

function Get-NormalizedText {
    param([string]$Path)
    ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace "`r`n", "`n")
}

function Assert-ExactReverseProjection {
    param(
        [string]$GoldenPath,
        [string]$DerivedPath,
        [hashtable]$ReverseReplacements,
        [string]$FailureCode
    )
    $golden = Get-NormalizedText $GoldenPath
    $candidate = Get-NormalizedText $DerivedPath
    foreach ($newValue in $ReverseReplacements.Keys) {
        $oldValue = [string]$ReverseReplacements[$newValue]
        $count = ([regex]::Matches(
                $candidate, [regex]::Escape([string]$newValue)
            )).Count
        Assert-True ($count -eq 1) $FailureCode
        $candidate = $candidate.Replace([string]$newValue, $oldValue)
    }
    Assert-True ($candidate -ceq $golden) $FailureCode
}

$expectedGoldenDatabaseLength = 413327L
$expectedGoldenDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedCandidateDatabaseLength = 1396707L
$expectedCandidateDatabaseSha256 =
    'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
$expectedCandidateReceiptLength = 3117L
$expectedCandidateReceiptSha256 =
    'e63cec5246967c5b4c66fe95e23325d574a1c8bb356e3719bbd3022c4ffbf479'
$expectedStrictAuditReceiptLength = 4231L
$expectedStrictAuditReceiptSha256 =
    'a3e4b02f6b97d4b7699b2b2420b4165af419b77dbc3b967cf5c1d3bb4d08a548'
$expectedCandidateAssessmentUid =
    'a69002f5-14e9-4f05-b9ab-9ca58b13925a'
$expectedStrictAuditUid =
    '8bd0bb59-0a75-44f8-8143-a689497486a8'
$expectedBaseHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedGoldenOuterLength = 15183L
$expectedGoldenOuterSha256 =
    '50ead5cce82a602d67ee3edd114449c8ceb19a178fa8ce921d3d42d565a6646c'
$expectedGoldenInnerStartLength = 39526L
$expectedGoldenInnerStartSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedGoldenCompletionWrapperLength = 576L
$expectedGoldenCompletionWrapperSha256 =
    '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1'
$expectedGoldenCompletionInnerLength = 9968L
$expectedGoldenCompletionInnerSha256 =
    '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
$expectedDerivedOuterLength = 19352L
$expectedDerivedOuterSha256 =
    'dad26036cf2f9bb364c40869a0056c043ca6439352a36f08f456085f93f016f1'
$expectedDerivedInnerStartLength = 39525L
$expectedDerivedInnerStartSha256 =
    '6a503087ffa89d45631d13783351810f2633fb1e51b18faef44f1f9771eee8de'
$expectedDerivedCompletionWrapperLength = 578L
$expectedDerivedCompletionWrapperSha256 =
    'a3521aa2c5b2ffec2e80068e2ead03b5c8976fe4d2d747c2c0990f09180d83f3'
$expectedDerivedCompletionInnerLength = 9966L
$expectedDerivedCompletionInnerSha256 =
    '96155783acae84d4dc3296f692a3227d485fec090a503c1782db535da2790356'
$expectedCacheFileCount = 40113
$expectedCacheByteLength = 39031656543L
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_progression_v2_deploy_wrong_samsung_boundary'
$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (Join-Path $micronDrive `
            'NLL\Tools\Start-Phase3B2-Epinel-LocaleOverlay-en-v2.ps1') `
        -PathType Leaf)
) 'phase3b2_progression_v2_deploy_physical_boundary_invalid'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_progression_v2_deploy_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceToolRoot = Join-Path $repositoryRoot 'scripts'
$protectedRoot =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2'
$candidateRoot = Join-Path $protectedRoot `
    ('EpinelUserProgressionCandidate-v2\' + $expectedCandidateAssessmentUid)
$candidateDatabasePath = Join-Path $candidateRoot `
    'candidate\candidate-db.json'
$candidateReceiptPath = Join-Path $candidateRoot 'staging.receipt.json'
$strictAuditPath = Join-Path $protectedRoot `
    ('EpinelUserProgressionStrictAudit-v1\' + $expectedStrictAuditUid +
        '\audit.receipt.json')
$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$runtimeDatabasePath = Join-Path $runtimeRoot 'db.json'
$cacheRoot = Join-Path $runtimeRoot 'cache'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$goldenOuterPath = Join-Path $toolRoot `
    'Start-Phase3B2-Epinel-LocaleOverlay-en-v2.ps1'
$goldenInnerStartPath = Join-Path $toolRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$goldenCompletionWrapperPath = Join-Path $toolRoot `
    'Complete-Phase3B2-Epinel-Minimal.ps1'
$goldenCompletionInnerPath = Join-Path $toolRoot `
    'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$derivedSourceOuterPath = Join-Path $sourceToolRoot `
    'Start-Phase3B2-Epinel-UserProgression-v2.ps1'
$derivedSourceInnerStartPath = Join-Path $sourceToolRoot `
    'start-phase3b2-epinel-user-progression-v2-in-micron.ps1'
$derivedSourceCompletionWrapperPath = Join-Path $sourceToolRoot `
    'Complete-Phase3B2-Epinel-UserProgression-v2.ps1'
$derivedSourceCompletionInnerPath = Join-Path $sourceToolRoot `
    'complete-phase3b2-epinel-user-progression-v2-in-micron.ps1'
$derivedTargetOuterPath = Join-Path $toolRoot `
    'Start-Phase3B2-Epinel-UserProgression-v2.ps1'
$derivedTargetInnerStartPath = Join-Path $toolRoot `
    'start-phase3b2-epinel-user-progression-v2-in-micron.ps1'
$derivedTargetCompletionWrapperPath = Join-Path $toolRoot `
    'Complete-Phase3B2-Epinel-UserProgression-v2.ps1'
$derivedTargetCompletionInnerPath = Join-Path $toolRoot `
    'complete-phase3b2-epinel-user-progression-v2-in-micron.ps1'
$evidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-v2'
$minimalActivePointerPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\active-run.pointer.json'
$newActivePointerPath = Join-Path $evidenceRoot 'active-run.pointer.json'
$hostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'

$dSuccessfulRoot =
    'D:\NikkeLocalLab\Backups\phase3b2-lobby-en-d830a90d-20260826T103327Z\runtime\E_NLL'
$dGoldenDatabasePath = Join-Path $dSuccessfulRoot `
    'EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'
$dGoldenOuterPath = Join-Path $dSuccessfulRoot `
    'Tools\Start-Phase3B2-Epinel-LocaleOverlay-en-v2.ps1'
$dGoldenInnerStartPath = Join-Path $dSuccessfulRoot `
    'Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$dGoldenCompletionWrapperPath = Join-Path $dSuccessfulRoot `
    'Tools\Complete-Phase3B2-Epinel-Minimal.ps1'
$dGoldenCompletionInnerPath = Join-Path $dSuccessfulRoot `
    'Tools\complete-phase3b2-epinel-minimal-reference-in-micron.ps1'

Assert-True (Test-Digest $candidateDatabasePath `
        $expectedCandidateDatabaseLength $expectedCandidateDatabaseSha256) `
    'phase3b2_progression_v2_deploy_candidate_database_invalid'
Assert-True (Test-Digest $candidateReceiptPath `
        $expectedCandidateReceiptLength $expectedCandidateReceiptSha256) `
    'phase3b2_progression_v2_deploy_candidate_receipt_invalid'
Assert-True (Test-Digest $strictAuditPath `
        $expectedStrictAuditReceiptLength $expectedStrictAuditReceiptSha256) `
    'phase3b2_progression_v2_deploy_strict_audit_invalid'
$candidateReceipt = Get-Content -LiteralPath $candidateReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$strictAudit = Get-Content -LiteralPath $strictAuditPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $candidateReceipt.contractId -ceq
        'nll/phase3b2-user-progression-offline-candidate-staging/v2' -and
    $candidateReceipt.assessmentUid -ceq $expectedCandidateAssessmentUid -and
    $candidateReceipt.candidateDatabaseSha256 -ceq
        $expectedCandidateDatabaseSha256 -and
    $strictAudit.contractId -ceq
        'nll/phase3b2-user-progression-strict-offline-audit/v1' -and
    $strictAudit.auditUid -ceq $expectedStrictAuditUid -and
    $strictAudit.candidateAssessmentUid -ceq $expectedCandidateAssessmentUid -and
    $strictAudit.candidateDatabaseSha256 -ceq
        $expectedCandidateDatabaseSha256 -and
    $strictAudit.allowedJsonChangeBoundaryVerified -and
    $strictAudit.sqliteOnlyTriggerRowsAndSequenceChanged -and
    [int]$strictAudit.foreignKeyViolationCount -eq 0 -and
    $strictAudit.verdictCode -ceq
        'strict_static_json_and_relational_gates_passed'
) 'phase3b2_progression_v2_deploy_candidate_contract_invalid'

$goldenChecks = @(
    @( $runtimeDatabasePath, $expectedGoldenDatabaseLength,
        $expectedGoldenDatabaseSha256 ),
    @( $goldenOuterPath, $expectedGoldenOuterLength,
        $expectedGoldenOuterSha256 ),
    @( $goldenInnerStartPath, $expectedGoldenInnerStartLength,
        $expectedGoldenInnerStartSha256 ),
    @( $goldenCompletionWrapperPath, $expectedGoldenCompletionWrapperLength,
        $expectedGoldenCompletionWrapperSha256 ),
    @( $goldenCompletionInnerPath, $expectedGoldenCompletionInnerLength,
        $expectedGoldenCompletionInnerSha256 )
)
$goldenToolChecks = @($goldenChecks[1..4])
foreach ($check in $goldenChecks) {
    Assert-True (Test-Digest ([string]$check[0]) ([long]$check[1]) `
            ([string]$check[2])) `
        'phase3b2_progression_v2_deploy_micron_golden_drifted'
}
$dChecks = @(
    @( $dGoldenDatabasePath, $expectedGoldenDatabaseLength,
        $expectedGoldenDatabaseSha256 ),
    @( $dGoldenOuterPath, $expectedGoldenOuterLength,
        $expectedGoldenOuterSha256 ),
    @( $dGoldenInnerStartPath, $expectedGoldenInnerStartLength,
        $expectedGoldenInnerStartSha256 ),
    @( $dGoldenCompletionWrapperPath, $expectedGoldenCompletionWrapperLength,
        $expectedGoldenCompletionWrapperSha256 ),
    @( $dGoldenCompletionInnerPath, $expectedGoldenCompletionInnerLength,
        $expectedGoldenCompletionInnerSha256 )
)
foreach ($check in $dChecks) {
    Assert-True (Test-Digest ([string]$check[0]) ([long]$check[1]) `
            ([string]$check[2])) `
        'phase3b2_progression_v2_deploy_d_golden_backup_invalid'
}
Assert-True ((Get-Sha256Hex $runtimeDatabasePath) -ceq
        (Get-Sha256Hex $dGoldenDatabasePath) -and
    (Get-Sha256Hex $goldenOuterPath) -ceq
        (Get-Sha256Hex $dGoldenOuterPath) -and
    (Get-Sha256Hex $goldenInnerStartPath) -ceq
        (Get-Sha256Hex $dGoldenInnerStartPath) -and
    (Get-Sha256Hex $goldenCompletionWrapperPath) -ceq
        (Get-Sha256Hex $dGoldenCompletionWrapperPath) -and
    (Get-Sha256Hex $goldenCompletionInnerPath) -ceq
        (Get-Sha256Hex $dGoldenCompletionInnerPath)) `
    'phase3b2_progression_v2_deploy_e_and_d_golden_mismatch'

$derivedChecks = @(
    @( $derivedSourceOuterPath, $expectedDerivedOuterLength,
        $expectedDerivedOuterSha256 ),
    @( $derivedSourceInnerStartPath, $expectedDerivedInnerStartLength,
        $expectedDerivedInnerStartSha256 ),
    @( $derivedSourceCompletionWrapperPath,
        $expectedDerivedCompletionWrapperLength,
        $expectedDerivedCompletionWrapperSha256 ),
    @( $derivedSourceCompletionInnerPath,
        $expectedDerivedCompletionInnerLength,
        $expectedDerivedCompletionInnerSha256 )
)
foreach ($check in $derivedChecks) {
    Assert-True (Test-Digest ([string]$check[0]) ([long]$check[1]) `
            ([string]$check[2])) `
        'phase3b2_progression_v2_deploy_derived_tool_drifted'
    Assert-PowerShellSyntax ([string]$check[0]) `
        'phase3b2_progression_v2_deploy_derived_tool_syntax_invalid'
}
Assert-ExactReverseProjection $goldenInnerStartPath `
    $derivedSourceInnerStartPath @{
        'epinel-user-progression-v2' = 'epinel-minimal-reference-v1'
        $expectedCandidateDatabaseSha256 = $expectedGoldenDatabaseSha256
    } 'phase3b2_progression_v2_deploy_inner_start_delta_invalid'
Assert-ExactReverseProjection $goldenCompletionWrapperPath `
    $derivedSourceCompletionWrapperPath @{
        'complete-phase3b2-epinel-user-progression-v2-in-micron.ps1' =
            'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
    } 'phase3b2_progression_v2_deploy_completion_wrapper_delta_invalid'
Assert-ExactReverseProjection $goldenCompletionInnerPath `
    $derivedSourceCompletionInnerPath @{
        'epinel-user-progression-v2' = 'epinel-minimal-reference-v1'
        $expectedCandidateDatabaseSha256 = $expectedGoldenDatabaseSha256
        'nll/phase3b2-epinel-user-progression-completion/v2' =
            'nll/phase3b2-epinel-minimal-reference-completion/v1'
    } 'phase3b2_progression_v2_deploy_completion_inner_delta_invalid'
$derivedOuterText = Get-NormalizedText $derivedSourceOuterPath
Assert-True (
    $derivedOuterText.Contains(
        "start-phase3b2-epinel-user-progression-v2-in-micron.ps1") -and
    $derivedOuterText.Contains($expectedCandidateDatabaseSha256) -and
    $derivedOuterText.Contains($expectedCandidateAssessmentUid) -and
    $derivedOuterText.Contains($expectedStrictAuditUid) -and
    -not $derivedOuterText.Contains(
        '(Get-Sha256Hex $minimalStartPath) -ceq') -and
    -not $derivedOuterText.Contains(
        'Get-Sha256Hex $PSCommandPath')
) 'phase3b2_progression_v2_deploy_outer_delta_invalid'
$targetChecks = @(
    @( $derivedTargetOuterPath, $expectedDerivedOuterLength,
        $expectedDerivedOuterSha256 ),
    @( $derivedTargetInnerStartPath, $expectedDerivedInnerStartLength,
        $expectedDerivedInnerStartSha256 ),
    @( $derivedTargetCompletionWrapperPath,
        $expectedDerivedCompletionWrapperLength,
        $expectedDerivedCompletionWrapperSha256 ),
    @( $derivedTargetCompletionInnerPath,
        $expectedDerivedCompletionInnerLength,
        $expectedDerivedCompletionInnerSha256 )
)
$preexistingTargetCount = @($targetChecks | Where-Object {
    Test-Path -LiteralPath ([string]$_[0]) -PathType Leaf
}).Count
$preexistingTargetsValid = $preexistingTargetCount -eq 0 -or
    ($preexistingTargetCount -eq 4 -and
        @($targetChecks | Where-Object {
            -not (Test-Digest ([string]$_[0]) ([long]$_[1]) `
                ([string]$_[2]))
        }).Count -eq 0)
$preexistingEvidenceValid = if (-not (Test-Path -LiteralPath $evidenceRoot)) {
    $true
}
else {
    $evidenceMembers = @(Get-ChildItem -LiteralPath $evidenceRoot -Force)
    $evidenceMembers.Count -eq 2 -and
        (Test-Digest (Join-Path $evidenceRoot `
            'candidate-staging.receipt.json') `
            $expectedCandidateReceiptLength `
            $expectedCandidateReceiptSha256) -and
        (Test-Digest (Join-Path $evidenceRoot 'strict-audit.receipt.json') `
            $expectedStrictAuditReceiptLength `
            $expectedStrictAuditReceiptSha256)
}

Assert-True ((Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
    -not (Test-Path -LiteralPath $minimalActivePointerPath) -and
    -not (Test-Path -LiteralPath $newActivePointerPath) -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $runtimeRoot $_) }
    ).Count -eq 0 -and
    $preexistingTargetsValid -and $preexistingEvidenceValid) `
    'phase3b2_progression_v2_deploy_runtime_shape_invalid'
Assert-True ((Get-Sha256Hex $verifierManifestPath) -ceq
        $expectedVerifierManifestSha256 -and
    (Test-Path -LiteralPath $verifierDllPath -PathType Leaf) -and
    (Test-Path -LiteralPath $dotnetPath -PathType Leaf)) `
    'phase3b2_progression_v2_deploy_verifier_invalid'
$inspectionOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_v2_deploy_cache_inspection_failed'
$inspection = (($inspectionOutput | Out-String).Trim()) | ConvertFrom-Json
Assert-True ($inspection.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $inspection.longPathSafeEnumerationUsed -and
    [int]$inspection.fileCount -eq $expectedCacheFileCount -and
    [long]$inspection.contentByteLength -eq $expectedCacheByteLength -and
    [int]$inspection.partialMemberCount -eq 0) `
    'phase3b2_progression_v2_deploy_cache_shape_invalid'

$audit = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-user-progression-v2-deployment-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    micronGoldenSourceVerified = $true
    dGoldenBackupReadOnlyComparisonVerified = $true
    goldenDatabaseSha256 = $expectedGoldenDatabaseSha256
    candidateDatabaseSha256 = $expectedCandidateDatabaseSha256
    strictAuditUid = $expectedStrictAuditUid
    candidateAssessmentUid = $expectedCandidateAssessmentUid
    goldenToolCount = 4
    derivedToolCount = 4
    innerStartExactReverseProjectionVerified = $true
    completionExactReverseProjectionVerified = $true
    derivedSelfHashBindingPresent = $false
    cacheFileCount = [int]$inspection.fileCount
    cacheContentByteLength = [long]$inspection.contentByteLength
    cachePartialMemberCount = [int]$inspection.partialMemberCount
    runtimeCold = $true
    dDriveWritePerformed = $false
    localLowInspected = $false
    localLowModified = $false
    readyToApply = $true
}
if ($AuditOnly) {
    $audit | ConvertTo-Json -Depth 8
    return
}

$applicationUid = [Guid]::NewGuid().ToString('D')
$protectedApplicationRoot = Join-Path $protectedRoot `
    ('EpinelUserProgressionDerivedLane-v2\' + $applicationUid)
Assert-True (-not (Test-Path -LiteralPath $protectedApplicationRoot)) `
    'phase3b2_progression_v2_deploy_application_collision'
New-Item -ItemType Directory -Path $protectedApplicationRoot | Out-Null
$goldenDatabaseBackupPath = Join-Path $protectedApplicationRoot `
    'micron-golden-db.before.json'
Copy-Item -LiteralPath $runtimeDatabasePath `
    -Destination $goldenDatabaseBackupPath
Assert-True (Test-Digest $goldenDatabaseBackupPath `
        $expectedGoldenDatabaseLength $expectedGoldenDatabaseSha256) `
    'phase3b2_progression_v2_deploy_local_rollback_copy_invalid'
$rollbackPlanPath = Join-Path $protectedApplicationRoot 'rollback.plan.json'
$rollbackPlan = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-user-progression-v2-rollback-plan/v1'
    applicationUid = $applicationUid
    micronDatabasePath = $runtimeDatabasePath
    micronGoldenDatabaseBackupPath = $goldenDatabaseBackupPath
    dGoldenDatabaseReadOnlyFallbackPath = $dGoldenDatabasePath
    goldenDatabaseByteLength = $expectedGoldenDatabaseLength
    goldenDatabaseSha256 = $expectedGoldenDatabaseSha256
    candidateDatabaseByteLength = $expectedCandidateDatabaseLength
    candidateDatabaseSha256 = $expectedCandidateDatabaseSha256
    goldenToolsModified = $false
    derivedToolsMayRemainInertAfterDatabaseRollback = $true
    dDriveWritePermitted = $false
}
Write-AtomicJson $rollbackPlanPath $rollbackPlan

$databaseReplaced = $false
try {
    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    Copy-Atomic $candidateReceiptPath `
        (Join-Path $evidenceRoot 'candidate-staging.receipt.json')
    Copy-Atomic $strictAuditPath `
        (Join-Path $evidenceRoot 'strict-audit.receipt.json')
    Copy-Atomic $derivedSourceOuterPath $derivedTargetOuterPath
    Copy-Atomic $derivedSourceInnerStartPath $derivedTargetInnerStartPath
    Copy-Atomic $derivedSourceCompletionWrapperPath `
        $derivedTargetCompletionWrapperPath
    Copy-Atomic $derivedSourceCompletionInnerPath `
        $derivedTargetCompletionInnerPath
    Copy-Atomic $candidateDatabasePath $runtimeDatabasePath
    $databaseReplaced = $true

    foreach ($check in $goldenToolChecks) {
        Assert-True (Test-Digest ([string]$check[0]) ([long]$check[1]) `
                ([string]$check[2])) `
            'phase3b2_progression_v2_deploy_golden_modified'
    }
    foreach ($check in $targetChecks) {
        Assert-True (Test-Digest ([string]$check[0]) ([long]$check[1]) `
                ([string]$check[2])) `
            'phase3b2_progression_v2_deploy_target_tool_invalid'
    }
    Assert-True (Test-Digest $runtimeDatabasePath `
            $expectedCandidateDatabaseLength $expectedCandidateDatabaseSha256) `
        'phase3b2_progression_v2_deploy_target_database_invalid'
    Assert-True ((Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
        @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
            Where-Object {
                Test-Path -LiteralPath (Join-Path $runtimeRoot $_)
            }).Count -eq 0) `
        'phase3b2_progression_v2_deploy_post_apply_runtime_invalid'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-v2-offline-application/v1'
        appliedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        applicationUid = $applicationUid
        candidateAssessmentUid = $expectedCandidateAssessmentUid
        strictAuditUid = $expectedStrictAuditUid
        goldenDatabaseBeforeSha256 = $expectedGoldenDatabaseSha256
        appliedDatabaseByteLength = $expectedCandidateDatabaseLength
        appliedDatabaseSha256 = $expectedCandidateDatabaseSha256
        micronGoldenSourceVerifiedBeforeDerivation = $true
        dGoldenBackupReadOnlyComparisonVerified = $true
        goldenToolCountVerifiedUnchanged = 4
        derivedToolCountAdded = 4
        derivedSelfHashBindingPresent = $false
        goldenToolsModified = $false
        serverBinaryModified = $false
        cacheModified = $false
        hostsModified = $false
        localLowInspected = $false
        localLowModified = $false
        dDriveWritePerformed = $false
        runtimeCold = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        nextStepCode =
            'boot_micron_nlloperator_run_user_progression_v2_once'
    }
    $protectedReceiptPath = Join-Path $protectedApplicationRoot `
        'application.receipt.json'
    Write-AtomicJson $protectedReceiptPath $receipt
    $micronReceiptPath = Join-Path $evidenceRoot `
        'application.receipt.json'
    Copy-Atomic $protectedReceiptPath $micronReceiptPath
    $latestPointerPath = Join-Path (Split-Path -Parent `
        $protectedApplicationRoot) 'latest-application.pointer.json'
    $latestPointer = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-v2-application-pointer/v1'
        applicationUid = $applicationUid
        protectedApplicationRoot = $protectedApplicationRoot
        applicationReceiptPath = $protectedReceiptPath
        applicationReceiptSha256 = Get-Sha256Hex $protectedReceiptPath
        rollbackPlanPath = $rollbackPlanPath
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        micronEvidenceRoot = $evidenceRoot
        active = $true
    }
    Write-AtomicJson $latestPointerPath $latestPointer

    [pscustomobject]@{
        Receipt = $receipt
        ProtectedReceiptPath = $protectedReceiptPath
        ProtectedReceiptSha256 = Get-Sha256Hex $protectedReceiptPath
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-UserProgression-v2.ps1'"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-UserProgression-v2.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
    } | ConvertTo-Json -Depth 10
}
catch {
    if ($databaseReplaced -and
        (Test-Digest $goldenDatabaseBackupPath `
            $expectedGoldenDatabaseLength $expectedGoldenDatabaseSha256)) {
        Copy-Atomic $goldenDatabaseBackupPath $runtimeDatabasePath
    }
    throw
}
