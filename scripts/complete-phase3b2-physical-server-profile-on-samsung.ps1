[CmdletBinding()]
param(
    [string]$MicronNllRoot = 'E:\NLL',
    [string]$SamsungProtectedRoot = 'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0Materialization',
    [string]$SamsungRepositoryRoot = 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    return (Get-Partition -DriveLetter $DriveLetter | Get-Disk)
}

function Get-AceSignature {
    param([System.Security.AccessControl.FileSystemSecurity]$Acl)
    return @($Acl.Access | ForEach-Object {
            '{0}|{1}|{2}|{3}|{4}' -f
                $_.IdentityReference.Value,
                [int]$_.FileSystemRights,
                [int]$_.AccessControlType,
                [int]$_.InheritanceFlags,
                [int]$_.PropagationFlags
        } | Sort-Object)
}

$stageCode = 'initialization'
$assessmentUid = [Guid]::NewGuid().ToString('D')
$attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$latestPointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'
$envPath = Join-Path $SamsungRepositoryRoot '.env'
$envBackupPath = Join-Path $attemptRoot 'operator.env.before.bin'
$envUpdated = $false
$envBytesBefore = $null
$aclBefore = $null
$aclProtected = $null

try {
    $stageCode = 'cross_boot_boundary_preflight'
    Assert-True ($env:USERNAME -ceq 'zih44') `
        'phase3b2_physical_finalization_samsung_operator_required'
    $bootDisk = Get-DiskForDriveLetter 'C'
    $micronDisk = Get-DiskForDriveLetter 'E'
    Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem -and
        $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
        'phase3b2_physical_finalization_samsung_boot_required'
    Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.LocalBootstrap' -ErrorAction SilentlyContinue)) `
        'phase3b2_physical_finalization_runtime_not_cold'
    Assert-True (-not (Test-Path -LiteralPath $attemptRoot)) `
        'phase3b2_physical_finalization_attempt_exists'
    New-Item -ItemType Directory -Path $attemptRoot -Force | Out-Null

    $stageCode = 'failed_attempt_and_clean_build_verification'
    $failedUid = '11ce14c5-40a2-4577-bf07-138789b08c3d'
    $failedReceiptPath = Join-Path (Join-Path $SamsungProtectedRoot $failedUid) `
        'physical-server-profile-materialization.failure.receipt.json'
    $classificationPath = Join-Path (Join-Path $SamsungProtectedRoot `
            '83a280d0-7568-4ced-9133-a500ae65b3d7') `
        'clean-physical-build-classification.receipt.json'
    Assert-True ((Get-Item -LiteralPath $failedReceiptPath).Length -eq 687L -and
        (Get-Sha256Hex $failedReceiptPath) -ceq
            'f0babc992a1b6235b8541b971bbe99acedd72eafbca683a0845301cafc2fe466') `
        'phase3b2_physical_finalization_failure_receipt_mismatch'
    Assert-True ((Get-Item -LiteralPath $classificationPath).Length -eq 1638L -and
        (Get-Sha256Hex $classificationPath) -ceq
            '9cc58a8b1d85096b25f16006f106cb80ea6d1a5fc92469ec35770ebc4b51e355') `
        'phase3b2_physical_finalization_classification_receipt_mismatch'
    $failedReceipt = Get-Content -LiteralPath $failedReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($failedReceipt.failedStageCode -ceq 'operator_env_rotation' -and
        $failedReceipt.failureCode -ceq
            'phase3b2_physical_materialization_operator_env_acl_not_protected' -and
        $failedReceipt.operatorEnvRestored -and
        -not $failedReceipt.clientOrSystemMutationPerformed -and
        -not $failedReceipt.serverExecutionStarted -and
        -not $failedReceipt.clientExecutionStarted) `
        'phase3b2_physical_finalization_failure_receipt_invalid'

    $evidenceRoot = Join-Path $MicronNllRoot `
        'Evidence\Phase3B2\Physical\server-profile-v1'
    $epinelRoot = Join-Path $MicronNllRoot 'EpinelPS'
    $serverRoot = Join-Path $epinelRoot 'EpinelPS\bin\Release\net10.0\win-x64'
    $adapterRoot = Join-Path $MicronNllRoot 'Work\PhysicalProfileAdapter-v1'
    $runtimeRoot = Join-Path $MicronNllRoot 'Runtime\LocalBootstrap-v1'
    $buildManifestPath = Join-Path $evidenceRoot 'server-build.manifest.tsv'
    $contextPath = Join-Path $evidenceRoot 'identity\synthetic-context.json'
    $profileReceiptPath = Join-Path $evidenceRoot `
        'identity\offline-synthetic-profile.receipt.json'
    $dbPath = Join-Path $serverRoot 'db.json'
    $adapterDll = Join-Path $adapterRoot `
        'out\NikkeLocalLab.Phase3B2.ProfileAdapter.dll'
    $artifactPins = @(
        [pscustomobject]@{ Path = $buildManifestPath; Length = 63280L; Sha256 = '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3' },
        [pscustomobject]@{ Path = (Join-Path $evidenceRoot 'adapter-restore.log'); Length = 568L; Sha256 = 'fd74057ca8d4a14ffa9a8d539afa42f224ba6f7b14c393fdc1736c47a56eb265' },
        [pscustomobject]@{ Path = (Join-Path $evidenceRoot 'adapter-build.log'); Length = 688L; Sha256 = '07870a18a9f23a9ad19a47073637e11d7a196047271757486dcfcfb8a1166a7a' },
        [pscustomobject]@{ Path = (Join-Path $evidenceRoot 'adapter-execution.log'); Length = 864L; Sha256 = 'fb803c03d30d26761f3b6af3276dca8a28855bbcc0094918005e4b475860f058' },
        [pscustomobject]@{ Path = $contextPath; Length = 279L; Sha256 = 'cc84781bc0df8d8705ac237f19763808e8925c7706de231b24470469ca446cc2' },
        [pscustomobject]@{ Path = $profileReceiptPath; Length = 1260L; Sha256 = 'bca519531ead1c3d360e28d5b1515acb48d6681a3162d2e5bff67884a1678701' },
        [pscustomobject]@{ Path = $dbPath; Length = 413327L; Sha256 = 'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' },
        [pscustomobject]@{ Path = $adapterDll; Length = 79360L; Sha256 = '90b0eeb78682ce4fb2b977bc9cece75b519bd9c96d4b0f286bfc83ecf4464950' },
        [pscustomobject]@{ Path = (Join-Path $runtimeRoot 'local-bootstrap-build.receipt.json'); Length = 1200L; Sha256 = '5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11' },
        [pscustomobject]@{ Path = (Join-Path $runtimeRoot 'evidence\artifact.manifest.tsv'); Length = 561L; Sha256 = 'b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70' }
    )
    foreach ($pin in $artifactPins) {
        Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
            (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
            (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
            'phase3b2_physical_finalization_artifact_pin_mismatch'
    }
    Assert-True (@(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File -Force).Count -eq 7) `
        'phase3b2_physical_finalization_bootstrap_shape_invalid'

    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    Assert-True ($null -ne $gitCommand -and
        (Test-Path -LiteralPath $gitCommand.Source -PathType Leaf)) `
        'phase3b2_physical_finalization_git_missing'
    $git = $gitCommand.Source
    $safeDirectory = 'E:/NLL/EpinelPS'
    $externalHead = (& $git -c "safe.directory=$safeDirectory" -C $epinelRoot `
        rev-parse HEAD).Trim()
    $externalTree = (& $git -c "safe.directory=$safeDirectory" -C $epinelRoot `
        rev-parse 'HEAD^{tree}').Trim()
    Assert-True ($externalHead -ceq '519c3db51ec24ca19307e93e85acde7885928a72' -and
        $externalTree -ceq 'b9e8bfb1b1e065427a48d40cb2bcf2f30215436a' -and
        @(& $git -c "safe.directory=$safeDirectory" -C $epinelRoot `
            status --porcelain=v1 --untracked-files=all).Count -eq 0) `
        'phase3b2_physical_finalization_checkout_invalid'

    $stageCode = 'synthetic_profile_verification'
    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $profileReceipt = Get-Content -LiteralPath $profileReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $username = [string]$context.username
    $password = [string]$context.password
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $passwordHash = (($md5.ComputeHash([Text.Encoding]::ASCII.GetBytes($password)) |
                    ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $md5.Dispose() }
    Assert-True ($context.contractId -ceq 'nll/phase3b2-synthetic-runtime-context/v1' -and
        $username -cmatch '^synthetic-[0-9a-f]{32}@invalid\.local$' -and
        $password -cmatch '^[0-9a-f]{20}$' -and
        -not $context.selectedManagerPersisted -and
        $profileReceipt.contractId -ceq 'nll/phase3b2-offline-synthetic-profile/v1' -and
        $profileReceipt.characterCount -eq 193 -and
        $profileReceipt.consoleCount -eq 9 -and
        $profileReceipt.launcherPasswordStorageSchemeCode -ceq
            'md5_lower_hex_legacy_launcher_compatibility' -and
        -not $profileReceipt.officialIdentityPersisted -and
        -not $profileReceipt.officialCredentialPersisted -and
        @($db.Users).Count -eq 1 -and
        [string]$db.Users[0].Username -ceq $username -and
        [string]$db.Users[0].Password -ceq $passwordHash -and
        $null -eq $db.Users[0].SelectedClassicSoloRaidManagerId) `
        'phase3b2_physical_finalization_synthetic_profile_invalid'

    $rawProfileCopyCount = 0
    foreach ($candidate in Get-ChildItem -LiteralPath $MicronNllRoot -Recurse -File -Force |
            Where-Object Length -EQ 964036L) {
        if ((Get-Sha256Hex $candidate.FullName) -ceq
            'efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605') {
            $rawProfileCopyCount++
        }
    }
    Assert-True ($rawProfileCopyCount -eq 0) `
        'phase3b2_physical_finalization_raw_profile_on_micron'

    $stageCode = 'operator_env_acl_repair_and_rotation'
    $gitignorePath = Join-Path $SamsungRepositoryRoot '.gitignore'
    Assert-True ((Test-Path -LiteralPath $envPath -PathType Leaf) -and
        (Get-Item -LiteralPath $envPath).Length -eq 207L -and
        (Get-Sha256Hex $envPath) -ceq
            'bb9344de9454638b3005f5051452d58ff20191a32613cdf0148a4fa6dc2af639' -and
        (Get-Content -LiteralPath $gitignorePath -Encoding UTF8 |
            Where-Object { $_.Trim() -ceq '.env' }).Count -ge 1 -and
        @(& $git -C $SamsungRepositoryRoot ls-files -- .env).Count -eq 0) `
        'phase3b2_physical_finalization_operator_env_boundary_invalid'
    $envBytesBefore = [IO.File]::ReadAllBytes($envPath)
    $aclBefore = Get-Acl -LiteralPath $envPath
    $aceSignatureBefore = Get-AceSignature $aclBefore
    Assert-True (@($aclBefore.Access | Where-Object {
            $_.IdentityReference.Value -ceq
                'S-1-5-21-2788911686-4009826172-3089669253-1003'
        }).Count -eq 1) `
        'phase3b2_physical_finalization_expected_inherited_acl_missing'
    if (-not $aclBefore.AreAccessRulesProtected) {
        $aclProtected = Get-Acl -LiteralPath $envPath
        $aclProtected.SetAccessRuleProtection($true, $true)
        Set-Acl -LiteralPath $envPath -AclObject $aclProtected
        $aclProtected = Get-Acl -LiteralPath $envPath
    }
    else {
        Assert-True (@($aclBefore.Access | Where-Object IsInherited).Count -eq 0) `
            'phase3b2_physical_finalization_partially_protected_acl_invalid'
        $aclProtected = $aclBefore
    }
    $aceSignatureProtected = Get-AceSignature $aclProtected
    Assert-True ($aclProtected.AreAccessRulesProtected -and
        @($aclProtected.Access | Where-Object IsInherited).Count -eq 0 -and
        (($aceSignatureBefore -join "`n") -ceq ($aceSignatureProtected -join "`n"))) `
        'phase3b2_physical_finalization_acl_repair_failed'

    Copy-Item -LiteralPath $envPath -Destination $envBackupPath
    $newEnvText = @(
        "NLL_PHASE3B2_ASSESSMENT_UID=$assessmentUid"
        "NLL_PHASE3B2_SYNTHETIC_USERNAME=$username"
        "NLL_PHASE3B2_SYNTHETIC_PASSWORD=$password"
    ) -join "`n"
    [IO.File]::WriteAllText($envPath, $newEnvText + "`n",
        [Text.UTF8Encoding]::new($false))
    $envUpdated = $true
    $aclAfter = Get-Acl -LiteralPath $envPath
    Assert-True ($aclAfter.AreAccessRulesProtected -and
        $aclAfter.Sddl -ceq $aclProtected.Sddl -and
        @(Get-Content -LiteralPath $envPath -Encoding UTF8).Count -eq 3) `
        'phase3b2_physical_finalization_operator_env_postcondition_failed'

    $stageCode = 'success_seal'
    $manifestExternalPath = Join-Path $attemptRoot 'server-build.manifest.tsv'
    Copy-Item -LiteralPath $buildManifestPath -Destination $manifestExternalPath
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-server-profile-materialization/v2'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        resumedFromAssessmentUid = $failedUid
        aclRepairResumedFromAssessmentUid =
            '10c10ae9-f076-45ad-9b8f-fa852a5a56c9'
        materializationExecutionBootDisk = 'Micron_2200_MTFDHBA512TCK'
        operatorEnvFinalizationBootDisk = 'Samsung SSD 980 1TB'
        splitFinalizationReasonCode = 'operator_env_acl_inheritance_repair'
        externalHead = $externalHead
        externalTree = $externalTree
        externalCheckoutClean = $true
        cleanBuildFileCount = 577
        cleanBuildContentByteLength = 193937818L
        cleanBuildManifestByteLength = (Get-Item $manifestExternalPath).Length
        cleanBuildManifestSha256 = Get-Sha256Hex $manifestExternalPath
        buildProvenanceCode = 'clean_clone_offline_release_build'
        selectedManagerPassedCount = 64
        handlerIsolationPassedCount = 5
        focusedTestFailedCount = 0
        localBootstrapReceiptSha256 = Get-Sha256Hex `
            (Join-Path $runtimeRoot 'local-bootstrap-build.receipt.json')
        profileAdapterOutputByteLength = (Get-Item $adapterDll).Length
        profileAdapterOutputSha256 = Get-Sha256Hex $adapterDll
        syntheticProfileReceiptByteLength = (Get-Item $profileReceiptPath).Length
        syntheticProfileReceiptSha256 = Get-Sha256Hex $profileReceiptPath
        syntheticContextByteLength = (Get-Item $contextPath).Length
        syntheticContextSha256 = Get-Sha256Hex $contextPath
        syntheticDatabaseByteLength = (Get-Item $dbPath).Length
        syntheticDatabaseSha256 = Get-Sha256Hex $dbPath
        characterCount = 193
        consoleCount = 9
        launcherPasswordRepresentation =
            'md5_lower_hex_legacy_launcher_compatibility'
        oldOperatorEnvBackupByteLength = (Get-Item $envBackupPath).Length
        oldOperatorEnvBackupSha256 = Get-Sha256Hex $envBackupPath
        newOperatorEnvByteLength = (Get-Item $envPath).Length
        newOperatorEnvSha256 = Get-Sha256Hex $envPath
        operatorEnvAclInheritanceDisabled = $true
        operatorEnvEffectiveAccessPreserved = $true
        operatorEnvTracked = $false
        operatorEnvIgnored = $true
        credentialBearingSourceCopiedToMicron = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        primaryInstallModified = $false
        physicalClientCloneModified = $false
        systemTrustModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'prepare_physical_p0_mutations_on_clone_only'
    }
    $receiptPath = Join-Path $attemptRoot `
        'physical-server-profile-materialization.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath (($receipt | ConvertTo-Json -Depth 8) + "`n")
    $pointer = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-server-profile-materialization-pointer/v1'
        assessmentUid = $assessmentUid
        statusCode = 'succeeded'
        receiptRelativePath =
            "$assessmentUid/physical-server-profile-materialization.receipt.json"
        receiptByteLength = (Get-Item $receiptPath).Length
        receiptSha256 = Get-Sha256Hex $receiptPath
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $latestPointerPath (($pointer | ConvertTo-Json) + "`n")
    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $receiptPath
        ReceiptByteLength = (Get-Item $receiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $receiptPath
    } | ConvertTo-Json -Depth 10
}
catch {
    $caughtException = $_
    $safeFailureCode = if ($caughtException.Exception.Message -cmatch
        '^phase3b2_[a-z0-9_:-]+$') {
        $caughtException.Exception.Message
    }
    else { 'phase3b2_physical_finalization_unexpected_error_redacted' }
    if ($envUpdated -and $null -ne $envBytesBefore) {
        try {
            [IO.File]::WriteAllBytes($envPath, $envBytesBefore)
            if ($null -ne $aclProtected) {
                Set-Acl -LiteralPath $envPath -AclObject $aclProtected
            }
            $envUpdated = $false
        }
        catch { }
    }
    try {
        if (-not (Test-Path -LiteralPath $attemptRoot)) {
            New-Item -ItemType Directory -Path $attemptRoot -Force | Out-Null
        }
        $failure = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-server-profile-finalization-failure/v1'
            failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            assessmentUid = $assessmentUid
            resumedFromAssessmentUid = '11ce14c5-40a2-4577-bf07-138789b08c3d'
            failedStageCode = $stageCode
            failureCode = $safeFailureCode
            operatorEnvRestored = -not $envUpdated
            clientOrSystemMutationPerformed = $false
            serverExecutionStarted = $false
            clientExecutionStarted = $false
        }
        $failurePath = Join-Path $attemptRoot `
            'physical-server-profile-finalization.failure.receipt.json'
        Write-AtomicUtf8NoBom $failurePath (($failure | ConvertTo-Json) + "`n")
        $pointer = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-server-profile-materialization-pointer/v1'
            assessmentUid = $assessmentUid
            statusCode = 'failed'
            receiptRelativePath =
                "$assessmentUid/physical-server-profile-finalization.failure.receipt.json"
            receiptByteLength = (Get-Item $failurePath).Length
            receiptSha256 = Get-Sha256Hex $failurePath
            serverExecutionStarted = $false
            clientExecutionStarted = $false
        }
        Write-AtomicUtf8NoBom $latestPointerPath (($pointer | ConvertTo-Json) + "`n")
    }
    catch { }
    throw "phase3b2_physical_server_profile_finalization_failed:$stageCode"
}
