[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AcquisitionAssessmentUid,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedAcquisitionReceiptSha256,

    [string]$AcquisitionRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\CatalogAcquisition',

    [string]$MicronDrive = 'E:\',

    [string]$ExpectedPreparationBootDisk = 'Samsung SSD 980 1TB',

    [string]$ExpectedTargetDisk = 'Micron_2200_MTFDHBA512TCK'
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

function Get-ContainedPath {
    param(
        [string]$Root,
        [string]$RelativePath,
        [string]$FailureCode
    )
    Assert-True (-not [string]::IsNullOrWhiteSpace($RelativePath)) $FailureCode
    $normalized = $RelativePath.Replace('/', '\')
    Assert-True (
        -not [IO.Path]::IsPathRooted($normalized) -and
        $normalized -notmatch '(^|\\)\.\.(\\|$)' -and
        $normalized -notmatch ':'
    ) $FailureCode
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath((Join-Path $fullRoot $normalized))
    Assert-True ($fullPath.StartsWith(
        $fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)) $FailureCode
    $fullPath
}

function Test-NkdbMagic {
    param([string]$Path)
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 4) { return $false }
        $magic = [byte[]]::new(4)
        return $stream.Read($magic, 0, 4) -eq 4 -and
            $magic[0] -eq 0x4e -and $magic[1] -eq 0x4b -and
            $magic[2] -eq 0x44 -and $magic[3] -eq 0x42
    }
    finally { $stream.Dispose() }
}

function Get-TableColumns {
    param(
        [Microsoft.Data.Sqlite.SqliteConnection]$Connection,
        [string]$Table
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = "PRAGMA table_info([$Table])"
        $reader = $command.ExecuteReader()
        try {
            @(
                while ($reader.Read()) {
                    [string]$reader.GetValue(1)
                }
            )
        }
        finally { $reader.Dispose() }
    }
    finally { $command.Dispose() }
}

function Get-ScalarInt64 {
    param(
        [Microsoft.Data.Sqlite.SqliteConnection]$Connection,
        [string]$Sql
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Sql
        [long]$command.ExecuteScalar()
    }
    finally { $command.Dispose() }
}

Assert-True ($PSVersionTable.PSEdition -ceq 'Core') `
    'phase3b2_catalog_stage_requires_powershell_core'
Assert-True ([Environment]::Is64BitProcess) `
    'phase3b2_catalog_stage_requires_x64_process'
$systemDriveLetter = $env:SystemDrive.TrimEnd(':')
$preparationDisk = Get-Disk -Number (
    Get-Partition -DriveLetter $systemDriveLetter).DiskNumber
$targetDriveLetter = $MicronDrive.Substring(0, 1)
$targetDisk = Get-Disk -Number (
    Get-Partition -DriveLetter $targetDriveLetter).DiskNumber
Assert-True ($preparationDisk.FriendlyName -ceq $ExpectedPreparationBootDisk) `
    'phase3b2_catalog_stage_wrong_preparation_boot_disk'
Assert-True ($targetDisk.FriendlyName -ceq $ExpectedTargetDisk) `
    'phase3b2_catalog_stage_wrong_target_disk'
Assert-True (-not $targetDisk.IsBoot -and -not $targetDisk.IsSystem) `
    'phase3b2_catalog_stage_target_os_not_offline'

$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
$runtimeProcessCount = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $runtimeNames -contains $_.ProcessName }
).Count
Assert-True ($runtimeProcessCount -eq 0) `
    'phase3b2_catalog_stage_runtime_not_cold'

$sealedRoot = Join-Path (Join-Path $AcquisitionRoot 'Sealed') `
    $AcquisitionAssessmentUid
$receiptPath = Join-Path $sealedRoot 'acquisition.receipt.json'
$transportPath = Join-Path $sealedRoot 'transport.private.json'
$canonicalPath = Join-Path $sealedRoot 'source-free.manifest.tsv'
$contentRoot = Join-Path $sealedRoot 'content'
Assert-True (Test-Path -LiteralPath $receiptPath -PathType Leaf) `
    'phase3b2_catalog_stage_acquisition_receipt_missing'
Assert-True ((Get-Sha256Hex $receiptPath) -ceq
    $ExpectedAcquisitionReceiptSha256) `
    'phase3b2_catalog_stage_acquisition_receipt_hash_mismatch'

$acquisition = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$transport = Get-Content -LiteralPath $transportPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $acquisition.contractId -ceq
        'nll/phase3b2-static-catalog-acquisition/v1' -and
    $acquisition.assessmentUid -ceq $AcquisitionAssessmentUid -and
    $acquisition.requestedMemberCount -eq 6 -and
    $acquisition.acquiredMemberCount -eq 6 -and
    $acquisition.nkdbBodyCount -eq 3 -and
    $acquisition.detachedSignatureCount -eq 3 -and
    $acquisition.verdictCode -ceq
        'exact_six_member_catalog_set_acquired_and_sealed'
) 'phase3b2_catalog_stage_acquisition_receipt_invalid'
Assert-True (
    (Get-Item -LiteralPath $transportPath).Length -eq
        $acquisition.privateTransportManifestByteLength -and
    (Get-Sha256Hex $transportPath) -ceq
        $acquisition.privateTransportManifestSha256 -and
    (Get-Item -LiteralPath $canonicalPath).Length -eq
        $acquisition.canonicalByteLength -and
    (Get-Sha256Hex $canonicalPath) -ceq
        $acquisition.canonicalSha256
) 'phase3b2_catalog_stage_acquisition_manifest_invalid'
Assert-True (
    $transport.contractId -ceq
        'nll/phase3b2-static-catalog-private-transport/v1' -and
    $transport.assessmentUid -ceq $AcquisitionAssessmentUid -and
    @($transport.members).Count -eq 6
) 'phase3b2_catalog_stage_private_transport_invalid'

$expectedRoleKinds = [ordered]@{
    core_body = 'nkdb_body'
    core_signature = 'detached_signature_96'
    dp_body = 'nkdb_body'
    dp_signature = 'detached_signature_96'
    fd_body = 'nkdb_body'
    fd_signature = 'detached_signature_96'
}
$members = @($transport.members | Sort-Object roleCode)
Assert-True (
    (($members.roleCode | Sort-Object) -join "`n") -ceq
    (($expectedRoleKinds.Keys | Sort-Object) -join "`n")
) 'phase3b2_catalog_stage_member_roles_invalid'

foreach ($member in $members) {
    Assert-True ($member.kindCode -ceq
        $expectedRoleKinds[[string]$member.roleCode]) `
        'phase3b2_catalog_stage_member_kind_invalid'
    $sourcePath = Get-ContainedPath $contentRoot `
        ([string]$member.relativePath) `
        'phase3b2_catalog_stage_member_relative_path_invalid'
    Assert-True (Test-Path -LiteralPath $sourcePath -PathType Leaf) `
        'phase3b2_catalog_stage_member_missing'
    Assert-True (
        (Get-Item -LiteralPath $sourcePath).Length -eq $member.byteLength -and
        (Get-Sha256Hex $sourcePath) -ceq $member.sha256
    ) 'phase3b2_catalog_stage_member_digest_mismatch'
    if ($member.kindCode -ceq 'nkdb_body') {
        Assert-True ((Split-Path -Leaf $sourcePath) -ceq 'catalog.db' -and
            (Test-NkdbMagic $sourcePath)) `
            'phase3b2_catalog_stage_nkdb_body_invalid'
    }
    else {
        Assert-True ((Split-Path -Leaf $sourcePath) -ceq 'catalog.db.nds' -and
            $member.byteLength -eq 96) `
            'phase3b2_catalog_stage_signature_invalid'
    }
    Add-Member -InputObject $member -NotePropertyName sourcePath `
        -NotePropertyValue $sourcePath
}

$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$serverCacheRoot = Join-Path $serverRoot 'cache'
$clientRoot = Join-Path $MicronDrive `
    'NLL\Clients\NIKKE-150.6.9-Physical'
Assert-True (Test-Path -LiteralPath $serverCacheRoot -PathType Container) `
    'phase3b2_catalog_stage_server_cache_missing'
Assert-True (Test-Path -LiteralPath $clientRoot -PathType Container) `
    'phase3b2_catalog_stage_physical_client_missing'

$env:PATH = "$serverRoot;$env:PATH"
@(
    'SQLitePCLRaw.core.dll',
    'SQLitePCLRaw.provider.e_sqlite3.dll',
    'SQLitePCLRaw.batteries_v2.dll',
    'Microsoft.Data.Sqlite.dll',
    'EpinelPS.dll'
) | ForEach-Object {
    $assemblyPath = Join-Path $serverRoot $_
    Assert-True (Test-Path -LiteralPath $assemblyPath -PathType Leaf) `
        'phase3b2_catalog_stage_parser_dependency_missing'
    [Reflection.Assembly]::LoadFrom($assemblyPath) | Out-Null
}
[SQLitePCL.Batteries_V2]::Init()

$localHashFiles = @{}
Get-ChildItem -LiteralPath $clientRoot -Recurse -File -Force |
    ForEach-Object {
        $name = $_.Name.ToLowerInvariant()
        if ($name -cmatch '^[0-9a-f]{32}$') {
            Assert-True (-not $localHashFiles.ContainsKey($name)) `
                'phase3b2_catalog_stage_duplicate_local_hash_file'
            $localHashFiles[$name] = [long]$_.Length
        }
    }

$requiredTables = @(
    'entries', 'entry_data', 'hashes_by_label', 'internal_ids',
    'key_entries', 'keys', 'provider_ids', 'resource_prov', 'types'
)
$requiredEntryDataColumns = @(
    'type_rowid', 'hash', 'crc', 'timeout', 'chunked_transfer',
    'redirect_limit', 'retry_count', 'bundle_name', 'asset_load_mode',
    'bundle_size', 'use_crc_cache', 'uwr_local',
    'clear_other_cache_version'
)
$parseResults = @()
$decryptedByteLength = [long]0
foreach ($body in @($members | Where-Object kindCode -CEQ 'nkdb_body')) {
    $roleCode = ([string]$body.roleCode).Substring(
        0, ([string]$body.roleCode).Length - '_body'.Length)
    $encrypted = [IO.File]::ReadAllBytes($body.sourcePath)
    $decrypted = [EpinelPS.Data.NkdbDecryptor]::Decrypt($encrypted)
    [Array]::Clear($encrypted, 0, $encrypted.Length)
    Assert-True ($decrypted.Length -ge 16 -and
        [Text.Encoding]::ASCII.GetString($decrypted, 0, 16) -ceq
            "SQLite format 3`0") `
        'phase3b2_catalog_stage_decrypted_sqlite_header_invalid'
    $decryptedByteLength += $decrypted.Length
    $decryptedSha256 = Get-BytesSha256Hex $decrypted
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal(
        $decrypted.Length)
    try {
        [Runtime.InteropServices.Marshal]::Copy(
            $decrypted, 0, $pointer, $decrypted.Length)
        $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new(
            'Data Source=:memory:')
        $connection.Open()
        try {
            $deserializeCode = [SQLitePCL.raw]::sqlite3_deserialize(
                $connection.Handle, 'main', $pointer,
                [long]$decrypted.Length, [long]$decrypted.Length, 4)
            Assert-True ($deserializeCode -eq 0) `
                'phase3b2_catalog_stage_sqlite_deserialize_failed'
            $tableCommand = $connection.CreateCommand()
            try {
                $tableCommand.CommandText =
                    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
                $tableReader = $tableCommand.ExecuteReader()
                try {
                    $tables = @(
                        while ($tableReader.Read()) {
                            [string]$tableReader.GetValue(0)
                        }
                    )
                }
                finally { $tableReader.Dispose() }
            }
            finally { $tableCommand.Dispose() }
            Assert-True (($tables -join "`n") -ceq
                ($requiredTables -join "`n")) `
                'phase3b2_catalog_stage_sqlite_tables_invalid'
            $entryDataColumns = Get-TableColumns $connection 'entry_data'
            Assert-True (($entryDataColumns -join "`n") -ceq
                ($requiredEntryDataColumns -join "`n")) `
                'phase3b2_catalog_stage_entry_data_schema_invalid'

            $entryCount = Get-ScalarInt64 $connection `
                'SELECT COUNT(*) FROM entries'
            $entryDataCount = Get-ScalarInt64 $connection `
                'SELECT COUNT(*) FROM entry_data'
            $command = $connection.CreateCommand()
            try {
                $command.CommandText =
                    'SELECT hash, bundle_size FROM entry_data ORDER BY rowid'
                $reader = $command.ExecuteReader()
                try {
                    $localExactCount = 0
                    $localMissingCount = 0
                    $localSizeMismatchCount = 0
                    $localMissingDeclaredByteLength = [long]0
                    while ($reader.Read()) {
                        $hash = ([string]$reader.GetValue(0)).ToLowerInvariant()
                        $size = [long]$reader.GetValue(1)
                        Assert-True ($hash -cmatch '^[0-9a-f]{32}$' -and
                            $size -ge 0) `
                            'phase3b2_catalog_stage_entry_data_value_invalid'
                        if (-not $localHashFiles.ContainsKey($hash)) {
                            $localMissingCount++
                            $localMissingDeclaredByteLength += $size
                        }
                        elseif ($localHashFiles[$hash] -ne $size) {
                            $localSizeMismatchCount++
                        }
                        else { $localExactCount++ }
                    }
                }
                finally { $reader.Dispose() }
            }
            finally { $command.Dispose() }

            $internalHashCount = Get-ScalarInt64 $connection @'
SELECT COUNT(*)
FROM entry_data ed
JOIN entries e ON e.data_rowid + 1 = ed.rowid
JOIN internal_ids ii ON ii.rowid = e.internal_id_rowid + 1
WHERE instr(lower(ii.internal_id), lower(ed.hash)) > 0
'@
            $parseResults += [ordered]@{
                roleCode = $roleCode
                encryptedByteLength = [long]$body.byteLength
                encryptedSha256 = [string]$body.sha256
                decryptedByteLength = $decrypted.Length
                decryptedSha256 = $decryptedSha256
                tableCount = $tables.Count
                entryCount = $entryCount
                entryDataCount = $entryDataCount
                internalIdContainsHashCount = $internalHashCount
                localExactHashAndSizeCount = $localExactCount
                localMissingHashCount = $localMissingCount
                localSizeMismatchCount = $localSizeMismatchCount
                localMissingDeclaredByteLength =
                    $localMissingDeclaredByteLength
            }
        }
        finally {
            if ($null -ne $connection) { $connection.Dispose() }
        }
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
        [Array]::Clear($decrypted, 0, $decrypted.Length)
    }
}

$analysisUid = [Guid]::NewGuid().ToString()
$analysisRoot = Join-Path (Join-Path $AcquisitionRoot 'Analysis') $analysisUid
Assert-True (-not (Test-Path -LiteralPath $analysisRoot)) `
    'phase3b2_catalog_stage_analysis_root_already_exists'
New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null
$analysisReceipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-sealed-catalog-offline-parse/v1'
    parsedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    analysisUid = $analysisUid
    acquisitionAssessmentUid = $AcquisitionAssessmentUid
    acquisitionReceiptByteLength = (Get-Item $receiptPath).Length
    acquisitionReceiptSha256 = Get-Sha256Hex $receiptPath
    privateTransportManifestByteLength = (Get-Item $transportPath).Length
    privateTransportManifestSha256 = Get-Sha256Hex $transportPath
    canonicalManifestByteLength = (Get-Item $canonicalPath).Length
    canonicalManifestSha256 = Get-Sha256Hex $canonicalPath
    encryptedMemberCount = $members.Count
    parsedCatalogCount = $parseResults.Count
    decryptedContentByteLength = $decryptedByteLength
    sqliteHeaderVerifiedCount = $parseResults.Count
    sqliteSchemaVerifiedCount = $parseResults.Count
    localHashFileCount = $localHashFiles.Count
    localExactHashAndSizeCount = [int](
        $parseResults.localExactHashAndSizeCount |
            Measure-Object -Sum).Sum
    localMissingHashCount = [int](
        $parseResults.localMissingHashCount |
            Measure-Object -Sum).Sum
    localSizeMismatchCount = [int](
        $parseResults.localSizeMismatchCount |
            Measure-Object -Sum).Sum
    localMissingDeclaredByteLength = [long](
        $parseResults.localMissingDeclaredByteLength |
            Measure-Object -Sum).Sum
    fullCatalogResourceClosureComplete =
        ([int]($parseResults.localMissingHashCount |
            Measure-Object -Sum).Sum -eq 0 -and
        [int]($parseResults.localSizeMismatchCount |
            Measure-Object -Sum).Sum -eq 0)
    parseResults = $parseResults
    rawCatalogContentPersisted = $false
    rawCatalogEntryPersisted = $false
    rawInternalIdPersisted = $false
    rawOfficialUrlPersisted = $false
    sourceClientModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    verdictCode = 'exact_six_member_catalog_set_parsed_in_memory'
    nextStepCode = 'stage_exact_catalog_set_into_offline_micron_server_cache'
}
$analysisReceiptPath = Join-Path $analysisRoot 'parse.receipt.json'
Write-AtomicUtf8NoBom $analysisReceiptPath `
    (($analysisReceipt | ConvertTo-Json -Depth 10) + "`n")

$stagingRoot = Join-Path $MicronDrive `
    'NLL\Staging\Phase3B2\ExactCatalogSet-v1'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-CatalogSet-v1'
$evidenceBase = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\catalog-set-v1'
$deploymentUid = [Guid]::NewGuid().ToString()
$evidenceRoot = Join-Path $evidenceBase $deploymentUid
Assert-True (-not (Test-Path -LiteralPath $stagingRoot)) `
    'phase3b2_catalog_stage_staging_root_already_exists'
Assert-True (-not (Test-Path -LiteralPath $backupRoot)) `
    'phase3b2_catalog_stage_backup_root_already_exists'
Assert-True (-not (Test-Path -LiteralPath $evidenceRoot)) `
    'phase3b2_catalog_stage_evidence_root_already_exists'
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null

$deploymentMembers = @()
$runtimeMutationStarted = $false
$appliedTargets = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($member in $members) {
        $relativePath = ([string]$member.relativePath).Replace('/', '\')
        $stagingPath = Get-ContainedPath $stagingRoot $relativePath `
            'phase3b2_catalog_stage_staging_path_invalid'
        $runtimePath = Get-ContainedPath $serverCacheRoot $relativePath `
            'phase3b2_catalog_stage_runtime_path_invalid'
        $backupPath = Get-ContainedPath $backupRoot $relativePath `
            'phase3b2_catalog_stage_backup_path_invalid'
        New-Item -ItemType Directory -Path (Split-Path -Parent $stagingPath) `
            -Force | Out-Null
        Copy-Item -LiteralPath $member.sourcePath -Destination $stagingPath
        Assert-True ((Get-Sha256Hex $stagingPath) -ceq $member.sha256) `
            'phase3b2_catalog_stage_staging_copy_invalid'

        $preexisting = Test-Path -LiteralPath $runtimePath -PathType Leaf
        if ($preexisting) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) `
                -Force | Out-Null
            Copy-Item -LiteralPath $runtimePath -Destination $backupPath
        }
        $deploymentMembers += [ordered]@{
            roleCode = [string]$member.roleCode
            relativePath = $relativePath
            byteLength = [long]$member.byteLength
            sha256 = [string]$member.sha256
            targetPreexisting = $preexisting
            backupByteLength = if ($preexisting) {
                (Get-Item -LiteralPath $backupPath).Length
            }
            else { 0 }
            backupSha256 = if ($preexisting) {
                Get-Sha256Hex $backupPath
            }
            else { '' }
        }
    }

    $privateManifest = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-exact-catalog-offline-deployment-private/v1'
        deploymentUid = $deploymentUid
        acquisitionAssessmentUid = $AcquisitionAssessmentUid
        analysisUid = $analysisUid
        serverCacheRoot = $serverCacheRoot
        stagingRoot = $stagingRoot
        backupRoot = $backupRoot
        members = $deploymentMembers
    }
    $privateManifestPath = Join-Path $evidenceRoot `
        'deployment.private.json'
    Write-AtomicUtf8NoBom $privateManifestPath `
        (($privateManifest | ConvertTo-Json -Depth 10) + "`n")

    $runtimeMutationStarted = $true
    foreach ($member in $deploymentMembers) {
        $stagingPath = Get-ContainedPath $stagingRoot $member.relativePath `
            'phase3b2_catalog_stage_staging_path_invalid'
        $runtimePath = Get-ContainedPath $serverCacheRoot $member.relativePath `
            'phase3b2_catalog_stage_runtime_path_invalid'
        New-Item -ItemType Directory -Path (Split-Path -Parent $runtimePath) `
            -Force | Out-Null
        Copy-Item -LiteralPath $stagingPath -Destination $runtimePath -Force
        $appliedTargets.Add($member)
        Assert-True (
            (Get-Item -LiteralPath $runtimePath).Length -eq
                $member.byteLength -and
            (Get-Sha256Hex $runtimePath) -ceq $member.sha256
        ) 'phase3b2_catalog_stage_runtime_copy_invalid'
    }

    $rollbackSource = Join-Path $PSScriptRoot `
        'rollback-phase3b2-sealed-catalog-set-in-micron.ps1'
    $rollbackDestination = Join-Path $MicronDrive `
        'NLL\Tools\Rollback-Phase3B2-Sealed-Catalog-Set.ps1'
    Assert-True (Test-Path -LiteralPath $rollbackSource -PathType Leaf) `
        'phase3b2_catalog_stage_rollback_tool_missing'
    Copy-Item -LiteralPath $rollbackSource -Destination $rollbackDestination `
        -Force

    $deploymentReceipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-exact-catalog-offline-deployment/v1'
        deployedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        deploymentUid = $deploymentUid
        acquisitionAssessmentUid = $AcquisitionAssessmentUid
        acquisitionReceiptSha256 = Get-Sha256Hex $receiptPath
        analysisUid = $analysisUid
        analysisReceiptByteLength = (Get-Item $analysisReceiptPath).Length
        analysisReceiptSha256 = Get-Sha256Hex $analysisReceiptPath
        privateDeploymentManifestByteLength =
            (Get-Item $privateManifestPath).Length
        privateDeploymentManifestSha256 = Get-Sha256Hex $privateManifestPath
        catalogBodyCount = 3
        detachedSignatureCount = 3
        appliedMemberCount = $deploymentMembers.Count
        appliedContentByteLength = [long](
            $deploymentMembers.byteLength | Measure-Object -Sum).Sum
        preexistingTargetCount = @(
            $deploymentMembers | Where-Object targetPreexisting).Count
        exactAppliedTargetCount = @(
            $deploymentMembers | Where-Object {
                $path = Get-ContainedPath $serverCacheRoot $_.relativePath `
                    'phase3b2_catalog_stage_runtime_path_invalid'
                (Get-Item -LiteralPath $path).Length -eq $_.byteLength -and
                    (Get-Sha256Hex $path) -ceq $_.sha256
            }).Count
        rollbackToolByteLength = (Get-Item $rollbackDestination).Length
        rollbackToolSha256 = Get-Sha256Hex $rollbackDestination
        targetOsOfflineDuringDeployment = $true
        runtimeCacheModified = $true
        physicalClientModified = $false
        primaryInstallModified = $false
        officialLauncherModified = $false
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        verdictCode = 'exact_six_member_catalog_set_staged_and_applied'
        nextStepCode = 'boot_micron_and_run_one_catalog_stage_retry'
    }
    $deploymentReceiptPath = Join-Path $evidenceRoot `
        'deployment.receipt.json'
    Write-AtomicUtf8NoBom $deploymentReceiptPath `
        (($deploymentReceipt | ConvertTo-Json -Depth 8) + "`n")
    $pointer = [ordered]@{
        contractId = 'nll/phase3b2-exact-catalog-offline-deployment-pointer/v1'
        deploymentUid = $deploymentUid
        deploymentReceiptPath = $deploymentReceiptPath
        deploymentReceiptRelativePath =
            "$deploymentUid\deployment.receipt.json"
        deploymentReceiptByteLength = (Get-Item $deploymentReceiptPath).Length
        deploymentReceiptSha256 = Get-Sha256Hex $deploymentReceiptPath
        privateManifestPath = $privateManifestPath
        privateManifestRelativePath =
            "$deploymentUid\deployment.private.json"
        privateManifestByteLength = (Get-Item $privateManifestPath).Length
        privateManifestSha256 = Get-Sha256Hex $privateManifestPath
    }
    New-Item -ItemType Directory -Path $evidenceBase -Force | Out-Null
    Write-AtomicUtf8NoBom (Join-Path $evidenceBase 'latest.pointer.json') `
        (($pointer | ConvertTo-Json -Depth 6) + "`n")

    [pscustomobject]@{
        Receipt = $deploymentReceipt
        ReceiptPath = $deploymentReceiptPath
        ReceiptByteLength = (Get-Item $deploymentReceiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $deploymentReceiptPath
        AnalysisReceiptPath = $analysisReceiptPath
        AnalysisReceiptSha256 = Get-Sha256Hex $analysisReceiptPath
    } | ConvertTo-Json -Depth 10
}
catch {
    $failureMessage = $_.Exception.Message
    if ($runtimeMutationStarted) {
        $reverseAppliedTargets = @($appliedTargets)
        [Array]::Reverse($reverseAppliedTargets)
        foreach ($member in $reverseAppliedTargets) {
            $runtimePath = Get-ContainedPath $serverCacheRoot `
                $member.relativePath `
                'phase3b2_catalog_stage_failure_runtime_path_invalid'
            $backupPath = Get-ContainedPath $backupRoot $member.relativePath `
                'phase3b2_catalog_stage_failure_backup_path_invalid'
            if ($member.targetPreexisting) {
                Copy-Item -LiteralPath $backupPath -Destination $runtimePath `
                    -Force
            }
            elseif (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
                Remove-Item -LiteralPath $runtimePath -Force
            }
        }
    }
    throw "phase3b2_catalog_stage_failed:$failureMessage"
}
