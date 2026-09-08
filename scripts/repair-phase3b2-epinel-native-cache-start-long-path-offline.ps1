[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$ProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\NativeCacheMaterialization-v2\MicronOfflineDeployment-v1'
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

function Get-TextSha256Hex {
    param([string]$Text)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ($algorithm.ComputeHash($bytes) | ForEach-Object {
                $_.ToString('x2')
            }) -join ''
    }
    finally {
        $algorithm.Dispose()
    }
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)

    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary,
        $Text,
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

$expectedDeploymentReceiptSha256 =
    '14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d'
$expectedPriorToolBindingReceiptSha256 =
    '68d1a7f44036c41cc67522d6d29e8958c6e72973baa6cdef952f6c2affeb230d'
$expectedPriorStartToolSha256 =
    '360c8e3aa0b1a8881a4297290e5fa3d3facc391dbcb072703703998174c63346'
$expectedSafeStartTemplateSha256 =
    '6a5bd06726a2264919094b10851285672c37c49fac0da047af09ac2711b6318b'
$expectedVerifierSdkVersion = '10.0.400'
$expectedVerifierCompileInputCount = 11
$expectedVerifierCompileInputCanonicalSha256 =
    'eaf339d04519010b8379ad2c30ef4321d5e6e2623a5d90116f350f0eac32bba3'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
) 'phase3b2_native_cache_start_repair_requires_administrator'

$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (Join-Path $micronDrive 'Windows\System32') `
        -PathType Container)
) 'phase3b2_native_cache_start_repair_wrong_disk_boundary'
Assert-True (
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_native_cache_start_repair_runtime_not_cold'

$deploymentEvidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1'
$deploymentReceiptPath = Join-Path $deploymentEvidenceRoot `
    'deployment.receipt.json'
$priorToolBindingReceiptPath = Join-Path $deploymentEvidenceRoot `
    'tool-binding.receipt.json'
$activeCacheRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$activeStartToolPath = Join-Path $micronDrive `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$safeStartTemplatePath = Join-Path $PSScriptRoot `
    'Start-Phase3B2-Epinel-NativeCache-LongPath.ps1'
$verifierWorkingRoot = Join-Path $PSScriptRoot '..\.external\EpinelPS'
$verifierProject = Join-Path $verifierWorkingRoot `
    'tools\Phase3B2.NativeCacheMaterializer\Phase3B2.NativeCacheMaterializer.csproj'
$verifierBuildRoot = Join-Path $verifierWorkingRoot `
    'tools\Phase3B2.NativeCacheMaterializer\bin\Release\net10.0'
$verifierRuntimeRoot = Join-Path $verifierWorkingRoot `
    'EpinelPS\bin\Release\net10.0\win-x64'
$verifierCompileInputs = [ordered]@{
    program = Join-Path $verifierWorkingRoot `
        'tools\Phase3B2.NativeCacheMaterializer\Program.cs'
    project = $verifierProject
    global_json = Join-Path $verifierWorkingRoot 'global.json'
    nkdb_decryptor = Join-Path $verifierWorkingRoot `
        'EpinelPS\Data\NkdbDecryptor.cs'
    ofb_stream = Join-Path $verifierWorkingRoot `
        'EpinelPS\Data\OfbStream.cs'
    zero_stream = Join-Path $verifierWorkingRoot `
        'EpinelPS\Data\ZeroStream.cs'
    microsoft_data_sqlite = Join-Path $verifierRuntimeRoot `
        'Microsoft.Data.Sqlite.dll'
    sqlitepclraw_core = Join-Path $verifierRuntimeRoot `
        'SQLitePCLRaw.core.dll'
    sqlitepclraw_batteries_v2 = Join-Path $verifierRuntimeRoot `
        'SQLitePCLRaw.batteries_v2.dll'
    sqlitepclraw_provider_e_sqlite3 = Join-Path $verifierRuntimeRoot `
        'SQLitePCLRaw.provider.e_sqlite3.dll'
    e_sqlite3 = Join-Path $verifierRuntimeRoot 'e_sqlite3.dll'
}
$bundleSources = [ordered]@{
    verifier = Join-Path $verifierBuildRoot `
        'Phase3B2.NativeCacheMaterializer.dll'
    dependencies = Join-Path $verifierBuildRoot `
        'Phase3B2.NativeCacheMaterializer.deps.json'
    runtime_configuration = Join-Path $verifierBuildRoot `
        'Phase3B2.NativeCacheMaterializer.runtimeconfig.json'
    microsoft_data_sqlite = Join-Path $verifierBuildRoot `
        'Microsoft.Data.Sqlite.dll'
    sqlitepclraw_batteries_v2 = Join-Path $verifierBuildRoot `
        'SQLitePCLRaw.batteries_v2.dll'
    sqlitepclraw_core = Join-Path $verifierBuildRoot `
        'SQLitePCLRaw.core.dll'
    sqlitepclraw_provider_e_sqlite3 = Join-Path $verifierBuildRoot `
        'SQLitePCLRaw.provider.e_sqlite3.dll'
    e_sqlite3 = Join-Path $verifierBuildRoot 'e_sqlite3.dll'
}
$dotnetCandidates = @(
    (Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'),
    (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
)
$dotnetPath = @($dotnetCandidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1)

$verifierDestinationRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierStagingRoot = Join-Path (Split-Path -Parent `
        $verifierDestinationRoot) (
    '.Phase3B2.NativeCacheVerifier-v1-staging-' +
    [Guid]::NewGuid().ToString('N')
)
$verifierManifestPath = Join-Path $verifierStagingRoot `
    'bundle.manifest.json'
$backupRoot = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelNativeCacheStartLongPath-v1'
$priorStartBackupPath = Join-Path $backupRoot `
    'Start-Phase3B2-Epinel-NativeCache.before.ps1'
$rollbackPlanPath = Join-Path $backupRoot 'rollback.plan.json'
$repairEvidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-start-long-path-repair-v1'
$repairReceiptPath = Join-Path $repairEvidenceRoot 'repair.receipt.json'
$protectedReceiptPath = Join-Path $ProtectedRoot `
    'start-long-path-repair.receipt.json'

Assert-True (
    @(@($deploymentReceiptPath, $priorToolBindingReceiptPath,
            $activeStartToolPath, $safeStartTemplatePath,
            @($verifierCompileInputs.GetEnumerator() | ForEach-Object {
                    $_.Value
                })) | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    (Test-Path -LiteralPath $activeCacheRoot -PathType Container) -and
    (Test-Path -LiteralPath $ProtectedRoot -PathType Container) -and
    $dotnetPath.Count -eq 1
) 'phase3b2_native_cache_start_repair_input_missing'
Assert-True (
    (Get-Sha256Hex $deploymentReceiptPath) -ceq `
        $expectedDeploymentReceiptSha256 -and
    (Get-Sha256Hex $priorToolBindingReceiptPath) -ceq `
        $expectedPriorToolBindingReceiptSha256 -and
    (Get-Sha256Hex $activeStartToolPath) -ceq `
        $expectedPriorStartToolSha256 -and
    (Get-Sha256Hex $safeStartTemplatePath) -ceq `
        $expectedSafeStartTemplateSha256
) 'phase3b2_native_cache_start_repair_input_digest_invalid'
Assert-True (
    -not (Test-Path -LiteralPath $verifierDestinationRoot) -and
    -not (Test-Path -LiteralPath $verifierStagingRoot) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $repairEvidenceRoot) -and
    -not (Test-Path -LiteralPath $protectedReceiptPath)
) 'phase3b2_native_cache_start_repair_destination_exists'

$deployment = Get-Content -LiteralPath $deploymentReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$priorToolBinding = Get-Content -LiteralPath $priorToolBindingReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq `
        'nll/phase3b2-epinel-native-cache-offline-deployment/v1' -and
    $deployment.nativeCacheDeploymentVerified -and
    $deployment.activeCacheFileCount -eq 40108 -and
    [long]$deployment.activeCacheContentByteLength -eq 39030629947L -and
    -not $deployment.serverExecutionStarted -and
    -not $deployment.clientExecutionStarted -and
    $priorToolBinding.contractId -ceq `
        'nll/phase3b2-epinel-native-cache-tool-binding/v1' -and
    $priorToolBinding.deploymentReceiptSha256 -ceq `
        $expectedDeploymentReceiptSha256 -and
    $priorToolBinding.boundStartToolSha256 -ceq `
        $expectedPriorStartToolSha256
) 'phase3b2_native_cache_start_repair_contract_invalid'

$compileInputRecords = @(
    $verifierCompileInputs.GetEnumerator() | ForEach-Object {
        $item = Get-Item -LiteralPath $_.Value
        [pscustomobject]@{
            roleCode = $_.Key
            byteLength = $item.Length
            sha256 = Get-Sha256Hex $item.FullName
        }
    }
)
$compileInputCanonicalText = (
    @($compileInputRecords | Sort-Object roleCode | ForEach-Object {
            $_.roleCode + "`t" + $_.byteLength + "`t" + $_.sha256
        }) -join "`n"
) + "`n"
$compileInputCanonicalSha256 = Get-TextSha256Hex `
    $compileInputCanonicalText
Assert-True (
    $compileInputRecords.Count -eq $expectedVerifierCompileInputCount -and
    $compileInputCanonicalSha256 -ceq `
        $expectedVerifierCompileInputCanonicalSha256
) 'phase3b2_native_cache_start_repair_verifier_source_invalid'

$previousLocation = Get-Location
try {
    Set-Location -LiteralPath $verifierWorkingRoot
    $sdkVersion = (& $dotnetPath[0] --version 2>&1 | Out-String).Trim()
    $sdkExitCode = $LASTEXITCODE
    if (
        $sdkExitCode -eq 0 -and
        $sdkVersion -ceq $expectedVerifierSdkVersion
    ) {
        & $dotnetPath[0] build $verifierProject -c Release --no-restore `
            --nologo | Out-Null
        $buildExitCode = $LASTEXITCODE
    }
    else {
        $buildExitCode = -1
    }
}
finally {
    Set-Location -LiteralPath $previousLocation
}
Assert-True (
    $sdkExitCode -eq 0 -and
    $sdkVersion -ceq $expectedVerifierSdkVersion
) 'phase3b2_native_cache_start_repair_verifier_sdk_invalid'
Assert-True (
    $buildExitCode -eq 0 -and
    @(@($bundleSources.GetEnumerator() | ForEach-Object { $_.Value }) |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    ).Count -eq 0
) 'phase3b2_native_cache_start_repair_verifier_build_failed'

$stagingCreated = $false
$verifierInstalled = $false
$backupCreated = $false
$startReplaced = $false
$evidenceCreated = $false
$protectedReceiptCreated = $false
try {
    New-Item -ItemType Directory -Path $verifierStagingRoot -Force |
        Out-Null
    $stagingCreated = $true
    foreach ($entry in $bundleSources.GetEnumerator()) {
        Copy-Item -LiteralPath $entry.Value `
            -Destination (Join-Path $verifierStagingRoot `
                ([IO.Path]::GetFileName($entry.Value)))
    }

    $bundleMembers = @(
        $bundleSources.GetEnumerator() | ForEach-Object {
            $sourceName = [IO.Path]::GetFileName($_.Value)
            $stagedPath = Join-Path $verifierStagingRoot $sourceName
            [ordered]@{
                roleCode = $_.Key
                relativePath = $sourceName
                byteLength = (Get-Item -LiteralPath $stagedPath).Length
                sha256 = Get-Sha256Hex $stagedPath
            }
        }
    )
    $bundleCanonicalText = (
        @($bundleMembers | Sort-Object roleCode | ForEach-Object {
                $_.roleCode + "`t" + $_.relativePath + "`t" +
                $_.byteLength + "`t" + $_.sha256
            }) -join "`n"
    ) + "`n"
    $bundleManifest = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-native-cache-long-path-verifier-manifest/v1'
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        sdkVersion = $sdkVersion
        compileInputCount = $compileInputRecords.Count
        compileInputCanonicalSha256 = $compileInputCanonicalSha256
        memberCount = $bundleMembers.Count
        canonicalization = `
            'role_code_tab_relative_path_tab_byte_length_tab_lower_sha256_lf_v1'
        canonicalByteLength = `
            [Text.UTF8Encoding]::new($false).GetByteCount(
                $bundleCanonicalText
            )
        canonicalSha256 = Get-TextSha256Hex $bundleCanonicalText
        members = $bundleMembers
    }
    $bundleManifestText = ($bundleManifest | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $verifierManifestPath $bundleManifestText
    $bundleManifestSha256 = Get-Sha256Hex $verifierManifestPath

    $stagedVerifierDll = Join-Path $verifierStagingRoot `
        'Phase3B2.NativeCacheMaterializer.dll'
    $inspectionOutput = & $dotnetPath[0] $stagedVerifierDll `
        'inspect-cache-tree' $activeCacheRoot 2>&1
    $inspectionExitCode = $LASTEXITCODE
    Assert-True ($inspectionExitCode -eq 0) `
        'phase3b2_native_cache_start_repair_cache_inspection_failed'
    $inspection = (($inspectionOutput | Out-String) | ConvertFrom-Json)
    Assert-True (
        $inspection.contractId -ceq `
            'nll/phase3b2-native-cache-tree-inspection/v1' -and
        $inspection.longPathSafeEnumerationUsed -and
        $inspection.fileCount -eq 40108 -and
        [long]$inspection.contentByteLength -eq 39030629947L -and
        $inspection.partialMemberCount -eq 0
    ) 'phase3b2_native_cache_start_repair_cache_shape_invalid'

    $safeStartText = Get-Content -LiteralPath $safeStartTemplatePath `
        -Raw -Encoding UTF8
    $deploymentPlaceholder = `
        '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__'
    $verifierPlaceholder = `
        '__NATIVE_CACHE_VERIFIER_MANIFEST_SHA256__'
    Assert-True (
        ([regex]::Matches($safeStartText,
            [regex]::Escape($deploymentPlaceholder))).Count -eq 1 -and
        ([regex]::Matches($safeStartText,
            [regex]::Escape($verifierPlaceholder))).Count -eq 1
    ) 'phase3b2_native_cache_start_repair_template_invalid'
    $boundStartText = $safeStartText.
        Replace($deploymentPlaceholder, $expectedDeploymentReceiptSha256).
        Replace($verifierPlaceholder, $bundleManifestSha256)
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseInput(
        $boundStartText,
        [ref]$null,
        [ref]$parseErrors
    ) | Out-Null
    Assert-True (@($parseErrors).Count -eq 0) `
        'phase3b2_native_cache_start_repair_bound_tool_parse_failed'

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupCreated = $true
    Copy-Item -LiteralPath $activeStartToolPath `
        -Destination $priorStartBackupPath
    $rollbackPlan = [ordered]@{
        contractId = 'nll/phase3b2-native-cache-start-repair-rollback-plan/v1'
        priorStartToolPath = $priorStartBackupPath
        priorStartToolSha256 = $expectedPriorStartToolSha256
        activeStartToolPath = $activeStartToolPath
        verifierDestinationRoot = $verifierDestinationRoot
        rollbackCode = `
            'restore_prior_start_tool_and_remove_verifier_bundle'
    }
    Write-AtomicUtf8NoBom $rollbackPlanPath `
        (($rollbackPlan | ConvertTo-Json -Depth 5) + "`n")

    Move-Item -LiteralPath $verifierStagingRoot `
        -Destination $verifierDestinationRoot
    $stagingCreated = $false
    $verifierInstalled = $true
    Write-AtomicUtf8NoBom $activeStartToolPath $boundStartText
    $startReplaced = $true

    Assert-True (
        (Get-Sha256Hex (Join-Path $verifierDestinationRoot `
            'bundle.manifest.json')) -ceq $bundleManifestSha256 -and
        (Get-Sha256Hex $priorStartBackupPath) -ceq `
            $expectedPriorStartToolSha256
    ) 'phase3b2_native_cache_start_repair_post_apply_invalid'

    New-Item -ItemType Directory -Path $repairEvidenceRoot -Force |
        Out-Null
    $evidenceCreated = $true
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-native-cache-start-long-path-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        deploymentReceiptSha256 = $expectedDeploymentReceiptSha256
        priorToolBindingReceiptSha256 = `
            $expectedPriorToolBindingReceiptSha256
        priorStartToolByteLength = `
            (Get-Item -LiteralPath $priorStartBackupPath).Length
        priorStartToolSha256 = $expectedPriorStartToolSha256
        repairedStartToolByteLength = `
            (Get-Item -LiteralPath $activeStartToolPath).Length
        repairedStartToolSha256 = Get-Sha256Hex $activeStartToolPath
        verifierSdkVersion = $sdkVersion
        verifierCompileInputCount = $compileInputRecords.Count
        verifierCompileInputCanonicalSha256 = `
            $compileInputCanonicalSha256
        verifierBundleMemberCount = $bundleMembers.Count
        verifierBundleManifestByteLength = `
            (Get-Item -LiteralPath (Join-Path $verifierDestinationRoot `
                'bundle.manifest.json')).Length
        verifierBundleManifestSha256 = $bundleManifestSha256
        activeCacheFileCount = [int]$inspection.fileCount
        activeCacheContentByteLength = [long]$inspection.contentByteLength
        activeCacheLongPathInspectionVerified = $true
        activeCacheMemberDigestVerificationPreviouslySealed = $true
        cacheRecopyPerformed = $false
        cacheMutationPerformed = $false
        priorStartToolBackedUp = $true
        rollbackPlanByteLength = `
            (Get-Item -LiteralPath $rollbackPlanPath).Length
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        targetOsOfflineDuringRepair = $true
        officialApiUsed = $false
        officialLoginUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = `
            'boot_micron_nlloperator_run_epinel_native_cache_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $repairReceiptPath $receiptText
    New-Item -ItemType Directory -Path $ProtectedRoot -Force | Out-Null
    Copy-Item -LiteralPath $repairReceiptPath `
        -Destination $protectedReceiptPath
    $protectedReceiptCreated = $true

    [pscustomobject]@{
        Receipt = $receipt
        RepairReceiptPath = $repairReceiptPath
        RepairReceiptByteLength = `
            (Get-Item -LiteralPath $repairReceiptPath).Length
        RepairReceiptSha256 = Get-Sha256Hex $repairReceiptPath
        MicronStartCommand = `
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
    } | ConvertTo-Json -Depth 8
}
catch {
    if ($startReplaced -and (Test-Path -LiteralPath $priorStartBackupPath)) {
        Copy-Item -LiteralPath $priorStartBackupPath `
            -Destination $activeStartToolPath -Force
    }
    if ($verifierInstalled -and
        (Test-Path -LiteralPath $verifierDestinationRoot)) {
        Remove-Item -LiteralPath $verifierDestinationRoot -Recurse -Force
    }
    if ($stagingCreated -and
        (Test-Path -LiteralPath $verifierStagingRoot)) {
        Remove-Item -LiteralPath $verifierStagingRoot -Recurse -Force
    }
    if ($evidenceCreated -and (Test-Path -LiteralPath $repairEvidenceRoot)) {
        Remove-Item -LiteralPath $repairEvidenceRoot -Recurse -Force
    }
    if ($protectedReceiptCreated -and
        (Test-Path -LiteralPath $protectedReceiptPath)) {
        Remove-Item -LiteralPath $protectedReceiptPath -Force
    }
    throw
}
