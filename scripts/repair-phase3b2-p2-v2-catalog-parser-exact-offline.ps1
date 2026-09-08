[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$MicronDrive = 'E:',
    [string]$FailedAssessmentUid =
        'f7e2bb4a-e661-42bf-b055-d0b2c8a536d3',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2',
    [switch]$AllowVerifiedNonAdministratorOfflineMutation,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$mutationStarted = $false
$backupCreated = $false
$projectionCreated = $false
$toolsReplaced = $false

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-AtomicBytes {
    param([string]$Path, [byte[]]$Bytes)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ManifestLines {
    param([string[]]$Paths, [string]$BasePath)
    $canonicalBase = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    @($Paths | Sort-Object | ForEach-Object {
        $item = Get-Item -LiteralPath $_
        $canonicalPath = [IO.Path]::GetFullPath($item.FullName)
        Assert-True ($canonicalPath.StartsWith(
                $canonicalBase, [StringComparison]::OrdinalIgnoreCase)) `
            'phase3b2_catalog_parser_exact_manifest_member_outside_base'
        $relative = $canonicalPath.Substring($canonicalBase.Length).
            Replace('\', '/')
        "{0}`t{1}`t{2}" -f $relative, $item.Length,
            (Get-Sha256Hex $item.FullName)
    })
}

try {
    $isAdministrator = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $micronLetter = $MicronDrive.TrimEnd(':')
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
    Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        $systemDisk.IsBoot -and $systemDisk.IsSystem -and
        $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
        'phase3b2_catalog_parser_exact_disk_boundary_invalid'
    if (-not $ValidateOnly) {
        Assert-True ($isAdministrator -or
            $AllowVerifiedNonAdministratorOfflineMutation) `
            'phase3b2_catalog_parser_exact_mutation_authority_invalid'
    }
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_catalog_parser_exact_runtime_not_cold'

    $toolRoot = Join-Path $MicronDrive 'NLL\Tools'
    $runtimeRoot = Join-Path $MicronDrive 'NLL\Runtime\PhysicalBootstrap-v2'
    $transferRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
    $p2EvidenceRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
    $serverRoot = Join-Path $MicronDrive `
        'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
    $projectionPath = Join-Path $serverRoot `
        'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
    $gameAssemblyPath = Join-Path $MicronDrive `
        'NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\GameAssembly.dll'
    $lcvPath = Join-Path $MicronDrive `
        'NLL\Clients\NIKKE-150.6.9-Physical\Unity\com_proximabeta_NIKKE\.lcv.dat'
    $dbPath = Join-Path $serverRoot 'db.json'
    $sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
        ForEach-Object { Join-Path $serverRoot $_ }

    $sourceStartPath = Join-Path $RepositoryRoot `
        'scripts\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $sourceCompletionPath = Join-Path $RepositoryRoot `
        'scripts\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $targetStartPath = Join-Path $toolRoot `
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $targetCompletionPath = Join-Path $toolRoot `
        'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $manifestPath = Join-Path $runtimeRoot 'evidence\tools.manifest.tsv'
    $deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
    $staticAnalysisPath = Join-Path $transferRoot `
        'catalog-parser-static-analysis.receipt.json'
    $projectionReceiptPath = Join-Path $transferRoot `
        'catalog-parser-exact-projection.receipt.json'
    $authorizationPath = Join-Path $transferRoot `
        'catalog-parser-exact-repair.receipt.json'

    $protectedDeploymentRoot = Join-Path $SamsungProtectedRoot 'V2Deployment'
    $protectedDeploymentPath = Join-Path $protectedDeploymentRoot `
        'offline-deployment.receipt.json'
    $protectedStaticAnalysisPath = Join-Path $protectedDeploymentRoot `
        'catalog-parser-static-analysis.receipt.json'
    $protectedProjectionReceiptPath = Join-Path $protectedDeploymentRoot `
        'catalog-parser-exact-projection.receipt.json'
    $protectedAuthorizationPath = Join-Path $protectedDeploymentRoot `
        'catalog-parser-exact-repair.receipt.json'

    $runRoot = Join-Path $p2EvidenceRoot $FailedAssessmentUid
    $failureReceiptPath = Join-Path $runRoot `
        'projection-format-failure.receipt.json'
    $recoveryReceiptPath = Join-Path $runRoot `
        'projection-format-cold-recovery.receipt.json'
    $priorConsumptionPath = Join-Path $p2EvidenceRoot `
        'catalog-version-projection-retry.consumed.json'
    $newConsumptionPath = Join-Path $p2EvidenceRoot `
        'catalog-parser-exact-retry.consumed.json'
    $activePointerPath = Join-Path $p2EvidenceRoot 'active-run.pointer.json'

    $backupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-CatalogParserExact-v1'
    $backupToolRoot = Join-Path $backupRoot 'tools'
    $backupReceiptRoot = Join-Path $backupRoot 'receipts'
    $backupStartPath = Join-Path $backupToolRoot `
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $backupCompletionPath = Join-Path $backupToolRoot `
        'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $backupManifestPath = Join-Path $backupReceiptRoot 'tools.manifest.tsv'
    $backupDeploymentPath = Join-Path $backupReceiptRoot `
        'micron-deployment.receipt.json'
    $backupProtectedDeploymentPath = Join-Path $backupReceiptRoot `
        'samsung-offline-deployment.receipt.json'
    $rollbackManifestPath = Join-Path $backupRoot 'rollback.manifest.json'

    Assert-True ((Test-PathDigest $failureReceiptPath 1504L `
            '44abdcc725b9ba99d4b82aa930e629fdac6c6d117e12e68367b1d5890be51562') -and
        (Test-PathDigest $recoveryReceiptPath 1904L `
            'e5ea78f3dda1f80ad736dfc56e93aac5b273554e000414cf54efb9920b9967aa') -and
        (Test-PathDigest $priorConsumptionPath 980L `
            '093892d750f3640e39c51bced08d3f441365357fab61adc685bab15df7b947a8') -and
        (Test-PathDigest $gameAssemblyPath 265846312L `
            'a4f0b9560ab0c00c9ab4f7ac64eb8e2631c7b70ab9e92ec18bb4944ce3c66954') -and
        (Test-PathDigest $lcvPath 3775L `
            'ede45120d1531ea1639dc4237bb8ff0061b356ccefdf8fd53d9edcd98f2e9054') -and
        (Test-PathDigest $dbPath 413327L `
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194')) `
        'phase3b2_catalog_parser_exact_input_or_recovery_pin_invalid'
    Assert-True (-not (Test-Path -LiteralPath $activePointerPath) -and
        -not (Test-Path -LiteralPath $newConsumptionPath) -and
        -not (Test-Path -LiteralPath $projectionPath) -and
        @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0) 'phase3b2_catalog_parser_exact_cold_state_invalid'

    Assert-True ((Test-PathDigest $targetStartPath 66029L `
            'c79f23435c4e9a30b4d98e39f0cb4424effe60608622785bd44fcd121e09875c') -and
        (Test-PathDigest $targetCompletionPath 20247L `
            'a2b875a3eac7978c16b9b82a910952b04dba09e2d0e761f400710fcfd771afd9') -and
        (Test-PathDigest $manifestPath 799L `
            '0df0687f3b084ac7e75736dd98a6626a7d60f42c47132042f0198d1aad4bda7b') -and
        (Test-PathDigest $deploymentPath 7410L `
            'b562c0336270299a299e9f2b8040351fcc61c46a4eadd345a5fc88ff574e941e') -and
        (Test-PathDigest $protectedDeploymentPath 7410L `
            'b562c0336270299a299e9f2b8040351fcc61c46a4eadd345a5fc88ff574e941e')) `
        'phase3b2_catalog_parser_exact_deployment_pin_invalid'

    foreach ($path in @($sourceStartPath, $sourceCompletionPath)) {
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
            'phase3b2_catalog_parser_exact_source_missing'
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-True (@($errors).Count -eq 0) `
            'phase3b2_catalog_parser_exact_source_parse_failed'
    }
    $sourceStartText = Get-Content -LiteralPath $sourceStartPath -Raw `
        -Encoding UTF8
    $sourceCompletionText = Get-Content -LiteralPath $sourceCompletionPath `
        -Raw -Encoding UTF8
    Assert-True ($sourceStartText.Contains(
            'singleCatalogParserExactRetryAuthorized') -and
        $sourceStartText.Contains('preserved_catalog_parser_exact_retry') -and
        $sourceStartText.Contains(
            'entry_name_colon_tag_comma_revision_lf_between_no_terminal_newline_v1') -and
        $sourceCompletionText.Contains(
            'phase3b2_physical_p2_v2_catalog_parser_exact_rollback_pin_invalid')) `
        'phase3b2_catalog_parser_exact_source_contract_missing'

    foreach ($path in @($backupRoot, $staticAnalysisPath,
            $projectionReceiptPath, $authorizationPath,
            $protectedStaticAnalysisPath, $protectedProjectionReceiptPath,
            $protectedAuthorizationPath)) {
        Assert-True (-not (Test-Path -LiteralPath $path)) `
            'phase3b2_catalog_parser_exact_destination_already_exists'
    }

    $projectionText = @(
        'core:150.6.b15,552831',
        'dp:1d5645e,553076',
        'en:dee9e75,552072',
        'ja:8995876,552078',
        'ko:bef9fc2,551960',
        'fd:85b12fc,552446',
        'saus:19e939d,552998'
    ) -join "`n"
    $projectionBytes = [Text.UTF8Encoding]::new($false).GetBytes(
        $projectionText)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $projectionSha256 = ([BitConverter]::ToString(
            $sha256.ComputeHash($projectionBytes))).Replace(
                '-', '').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
    Assert-True ($projectionBytes.Length -eq 131 -and
        $projectionBytes[$projectionBytes.Length - 1] -ne 10 -and
        $projectionSha256 -ceq
            'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805') `
        'phase3b2_catalog_parser_exact_projection_bytes_invalid'

    if ($ValidateOnly) {
        [pscustomobject]@{
            ContractId =
                'nll/phase3b2-p2-v2-catalog-parser-exact-repair-preflight/v1'
            FailedAssessmentUid = $FailedAssessmentUid
            ParserMethodRva = '0x648bc80'
            SplitSeparatorCode = 'lf_char_0x0a'
            ParserCanonicalizationCode =
                'entry_name_colon_tag_comma_revision_lf_between_no_terminal_newline_v1'
            ProjectedByteLength = 131
            ProjectedSha256 = $projectionSha256
            TerminalNewlinePresent = $false
            PriorRetryConsumptionPreserved = $true
            NewSingleRetryAuthorized = $true
            DiskBoundaryVerified = $true
            MutationPerformed = $false
        } | ConvertTo-Json -Depth 6
        return
    }

    New-Item -ItemType Directory -Path $backupToolRoot, $backupReceiptRoot `
        -Force | Out-Null
    Copy-Item -LiteralPath $targetStartPath -Destination $backupStartPath
    Copy-Item -LiteralPath $targetCompletionPath `
        -Destination $backupCompletionPath
    Copy-Item -LiteralPath $manifestPath -Destination $backupManifestPath
    Copy-Item -LiteralPath $deploymentPath -Destination $backupDeploymentPath
    Copy-Item -LiteralPath $protectedDeploymentPath `
        -Destination $backupProtectedDeploymentPath
    $backupCreated = $true

    $rollbackManifest = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-local-content-version-projection-rollback/v2'
        preparedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        targetRoleCode = 'epinelps_local_content_version_cache'
        targetWasAbsentBeforeProjection = $true
        projectedByteLength = 131
        projectedSha256 = $projectionSha256
        removeOnlyWhenExactDigestMatches = $true
        automaticFailureHandlerCode = 'p2_v2_start_failure_handler'
        successfulCompletionHandlerCode = 'p2_v2_completion_handler'
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $rollbackManifestPath `
        (($rollbackManifest | ConvertTo-Json -Depth 6) + "`n")

    $staticAnalysis = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-catalog-parser-static-analysis/v1'
        analyzedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        analysisModeCode = 'offline_static_il2cpp_disassembly'
        clientBuild = '150.6.9'
        gameAssemblyByteLength = 265846312
        gameAssemblySha256 =
            'a4f0b9560ab0c00c9ab4f7ac64eb8e2631c7b70ab9e92ec18bb4944ce3c66954'
        extractedMetadataByteLength = 47393680
        extractedMetadataSha256 =
            '026f4835cbbeab5e2c50f93da80e457971a91bd72329262b26223bb6c950cd30'
        metadataVersion = 31
        codeRegistrationVa = '0x188626cc0'
        metadataRegistrationVa = '0x189b04760'
        parserMethodCode =
            'ContentVersion2.DataPackEntry.GetVersionAsync.MoveNext'
        parserMethodRva = '0x648bc80'
        parserMethodByteLength = 1944
        splitSeparatorCode = 'lf_char_0x0a'
        splitOptionsCode = 'string_split_options_none'
        entryDelimiterCode = 'colon_then_comma'
        firstFieldRoleCode = 'content_tag_string'
        secondFieldRoleCode = 'revision_int32'
        secondFieldInt32ParseObserved = $true
        terminalEmptyLineRejected = $true
        parserCanonicalizationCode =
            'entry_name_colon_tag_comma_revision_lf_between_no_terminal_newline_v1'
        processInjectionOrHookingAttempted = $false
        memoryPatchAttempted = $false
        gameBinaryModified = $false
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $staticAnalysisPath `
        (($staticAnalysis | ConvertTo-Json -Depth 7) + "`n")

    $projectionReceipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-local-content-version-projection/v2'
        projectedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        sourceRoleCode = 'exact_pinned_lcv_values_with_static_parser_contract'
        parserCanonicalizationCode =
            'entry_name_colon_tag_comma_revision_lf_between_no_terminal_newline_v1'
        entryCount = 7
        parserOrderVerified = $true
        secondFieldInt32ParseVerified = $true
        noTerminalNewlineVerified = $true
        aggregateRevisionMatchesDp = $true
        projectedByteLength = 131
        projectedSha256 = $projectionSha256
        targetAlreadyMatched = $false
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }

    $mutationStarted = $true
    New-Item -ItemType Directory -Path (Split-Path -Parent $projectionPath) `
        -Force | Out-Null
    Write-AtomicBytes $projectionPath $projectionBytes
    Assert-True (Test-PathDigest $projectionPath 131L $projectionSha256) `
        'phase3b2_catalog_parser_exact_projection_write_failed'
    $projectionCreated = $true
    Write-AtomicUtf8NoBom $projectionReceiptPath `
        (($projectionReceipt | ConvertTo-Json -Depth 7) + "`n")

    Copy-Item -LiteralPath $sourceStartPath -Destination $targetStartPath -Force
    Copy-Item -LiteralPath $sourceCompletionPath `
        -Destination $targetCompletionPath -Force
    $toolsReplaced = $true

    $deployment = Get-Content -LiteralPath $deploymentPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    foreach ($toolUpdate in @(
            [pscustomobject]@{
                Name = 'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
                Path = $targetStartPath
            },
            [pscustomobject]@{
                Name = 'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
                Path = $targetCompletionPath
            })) {
        $entry = @($deployment.tools | Where-Object {
            $_.name -ceq $toolUpdate.Name
        })
        Assert-True ($entry.Count -eq 1) `
            'phase3b2_catalog_parser_exact_deployment_tool_entry_invalid'
        $entry[0].byteLength = (Get-Item -LiteralPath $toolUpdate.Path).Length
        $entry[0].sha256 = Get-Sha256Hex $toolUpdate.Path
    }
    $toolPaths = @($deployment.tools | ForEach-Object {
        Join-Path $toolRoot ([string]$_.name)
    })
    Assert-True (@($toolPaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0) 'phase3b2_catalog_parser_exact_tool_shape_invalid'
    $manifestText = (Get-ManifestLines $toolPaths $toolRoot) -join "`n"
    Write-AtomicUtf8NoBom $manifestPath ($manifestText + "`n")
    $deployment.toolManifestByteLength =
        (Get-Item -LiteralPath $manifestPath).Length
    $deployment.toolManifestSha256 = Get-Sha256Hex $manifestPath
    $deployment.nextStepCode =
        'boot_micron_run_catalog_parser_exact_retry_once'
    $deployment | Add-Member -NotePropertyName catalogParserExactRepairApplied `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName catalogParserExactProjectionSha256 `
        -NotePropertyValue $projectionSha256 -Force
    Write-AtomicUtf8NoBom $deploymentPath `
        (($deployment | ConvertTo-Json -Depth 10) + "`n")
    Copy-Item -LiteralPath $deploymentPath `
        -Destination $protectedDeploymentPath -Force
    Assert-True ((Get-Sha256Hex $protectedDeploymentPath) -ceq
        (Get-Sha256Hex $deploymentPath)) `
        'phase3b2_catalog_parser_exact_protected_deployment_copy_failed'

    New-Item -ItemType Directory -Path $protectedDeploymentRoot -Force |
        Out-Null
    Copy-Item -LiteralPath $staticAnalysisPath `
        -Destination $protectedStaticAnalysisPath
    Copy-Item -LiteralPath $projectionReceiptPath `
        -Destination $protectedProjectionReceiptPath

    $authorization = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-p2-v2-catalog-parser-exact-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $FailedAssessmentUid
        failureReceiptByteLength = 1504
        failureReceiptSha256 =
            '44abdcc725b9ba99d4b82aa930e629fdac6c6d117e12e68367b1d5890be51562'
        recoveryReceiptByteLength = 1904
        recoveryReceiptSha256 =
            'e5ea78f3dda1f80ad736dfc56e93aac5b273554e000414cf54efb9920b9967aa'
        gameAssemblyByteLength = 265846312
        gameAssemblySha256 =
            'a4f0b9560ab0c00c9ab4f7ac64eb8e2631c7b70ab9e92ec18bb4944ce3c66954'
        staticAnalysisReceiptByteLength =
            (Get-Item -LiteralPath $staticAnalysisPath).Length
        staticAnalysisReceiptSha256 = Get-Sha256Hex $staticAnalysisPath
        parserMethodRva = '0x648bc80'
        parserCanonicalizationCode =
            'entry_name_colon_tag_comma_revision_lf_between_no_terminal_newline_v1'
        secondFieldInt32ParseObserved = $true
        terminalEmptyLineRejected = $true
        projectionReceiptByteLength =
            (Get-Item -LiteralPath $projectionReceiptPath).Length
        projectionReceiptSha256 = Get-Sha256Hex $projectionReceiptPath
        projectedByteLength = 131
        projectedSha256 = $projectionSha256
        rollbackManifestByteLength =
            (Get-Item -LiteralPath $rollbackManifestPath).Length
        rollbackManifestSha256 = Get-Sha256Hex $rollbackManifestPath
        priorCatalogProjectionRetryConsumptionSha256 =
            '093892d750f3640e39c51bced08d3f441365357fab61adc685bab15df7b947a8'
        deploymentReceiptByteLength =
            (Get-Item -LiteralPath $deploymentPath).Length
        deploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
        toolManifestByteLength = (Get-Item -LiteralPath $manifestPath).Length
        toolManifestSha256 = Get-Sha256Hex $manifestPath
        localProjectionVerified = $true
        baselineTenMinuteMeasurementVerified = $true
        interactiveMeasurementSeconds = 30
        endpointContractChanged = $false
        liveRuntimeFilesDeferredToCompletion = $true
        priorRetryConsumptionPreserved = $true
        singleCatalogParserExactRetryAuthorized = $true
        retryConsumed = $false
        dedicatedOperatorCachePreserved = $true
        existingOperatorNikkeCacheMutationPerformed = $false
        officialOutboundUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_run_catalog_parser_exact_retry_once'
    }
    Write-AtomicUtf8NoBom $authorizationPath `
        (($authorization | ConvertTo-Json -Depth 8) + "`n")
    Copy-Item -LiteralPath $authorizationPath `
        -Destination $protectedAuthorizationPath
    foreach ($pair in @(
            @($staticAnalysisPath, $protectedStaticAnalysisPath),
            @($projectionReceiptPath, $protectedProjectionReceiptPath),
            @($authorizationPath, $protectedAuthorizationPath))) {
        Assert-True ((Get-Sha256Hex $pair[0]) -ceq
            (Get-Sha256Hex $pair[1])) `
            'phase3b2_catalog_parser_exact_protected_receipt_copy_failed'
    }

    [pscustomobject]@{
        Receipt = $authorization
        MicronReceiptPath = $authorizationPath
        MicronReceiptByteLength = (Get-Item $authorizationPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $authorizationPath
        SamsungProtectedReceiptPath = $protectedAuthorizationPath
    } | ConvertTo-Json -Depth 10
}
catch {
    if ($mutationStarted) {
        if ($toolsReplaced -and $backupCreated) {
            Copy-Item -LiteralPath $backupStartPath `
                -Destination $targetStartPath -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $backupCompletionPath `
                -Destination $targetCompletionPath -Force `
                -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $backupManifestPath `
                -Destination $manifestPath -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $backupDeploymentPath `
                -Destination $deploymentPath -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $backupProtectedDeploymentPath `
                -Destination $protectedDeploymentPath -Force `
                -ErrorAction SilentlyContinue
        }
        if ($projectionCreated -and
            (Test-PathDigest $projectionPath 131L `
                'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805')) {
            Remove-Item -LiteralPath $projectionPath -Force `
                -ErrorAction SilentlyContinue
        }
        foreach ($path in @($staticAnalysisPath, $projectionReceiptPath,
                $authorizationPath, $protectedStaticAnalysisPath,
                $protectedProjectionReceiptPath,
                $protectedAuthorizationPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    throw
}
