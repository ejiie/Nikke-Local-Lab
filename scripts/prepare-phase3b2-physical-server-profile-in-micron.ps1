[CmdletBinding()]
param(
    [string]$StagingRoot = 'C:\NLL\Staging\PhysicalP0-v1',
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$AdapterWorkRoot = 'C:\NLL\Work\PhysicalProfileAdapter-v1',
    [string]$RuntimeRoot = 'C:\NLL\Runtime\LocalBootstrap-v1',
    [string]$LocalEvidenceRoot = 'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1',
    [string]$SamsungProtectedRoot = 'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0Materialization',
    [string]$SamsungRepositoryRoot = 'E:\Users\zih44\Documents\Github\Nikke-Local-Lab',
    [switch]$ResumeValidatedCleanBuild,
    [string]$ResumeAssessmentUid
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_MULTILEVEL_LOOKUP = '0'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = '1'

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

function Get-FileDigest {
    param([string]$Path)
    return [ordered]@{
        byteLength = (Get-Item -LiteralPath $Path).Length
        sha256 = Get-Sha256Hex $Path
    }
}

function Invoke-NativeLogged {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$LogPath
    )
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @ArgumentList 2>&1 |
            Tee-Object -FilePath $LogPath | Out-Null
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    return $exitCode
}

function Test-OptionalFeatureDisabled {
    param([string]$Name)
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
    return $feature.State -eq [Microsoft.Dism.Commands.FeatureState]::Disabled
}

$stageCode = 'initialization'
$assessmentUid = [Guid]::NewGuid().ToString('D')
$attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$latestPointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'
$envUpdated = $false
$envPath = Join-Path $SamsungRepositoryRoot '.env'
$envBackupPath = Join-Path $attemptRoot 'operator.env.before.bin'

try {
    $stageCode = 'physical_boot_and_path_preflight'
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_physical_materialization_administrator_required'

    $normalizedPaths = [ordered]@{
        staging = [IO.Path]::GetFullPath($StagingRoot).TrimEnd('\')
        epinel = [IO.Path]::GetFullPath($EpinelRoot).TrimEnd('\')
        adapter = [IO.Path]::GetFullPath($AdapterWorkRoot).TrimEnd('\')
        runtime = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
        localEvidence = [IO.Path]::GetFullPath($LocalEvidenceRoot).TrimEnd('\')
        protected = [IO.Path]::GetFullPath($SamsungProtectedRoot).TrimEnd('\')
        repository = [IO.Path]::GetFullPath($SamsungRepositoryRoot).TrimEnd('\')
    }
    Assert-True ($normalizedPaths.staging -ceq 'C:\NLL\Staging\PhysicalP0-v1') `
        'phase3b2_physical_materialization_staging_path_invalid'
    Assert-True ($normalizedPaths.epinel -ceq 'C:\NLL\EpinelPS') `
        'phase3b2_physical_materialization_epinel_path_invalid'
    Assert-True ($normalizedPaths.adapter -ceq 'C:\NLL\Work\PhysicalProfileAdapter-v1') `
        'phase3b2_physical_materialization_adapter_path_invalid'
    Assert-True ($normalizedPaths.runtime -ceq 'C:\NLL\Runtime\LocalBootstrap-v1') `
        'phase3b2_physical_materialization_runtime_path_invalid'
    Assert-True ($normalizedPaths.localEvidence -ceq 'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1') `
        'phase3b2_physical_materialization_evidence_path_invalid'
    Assert-True ($normalizedPaths.protected -ceq
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0Materialization') `
        'phase3b2_physical_materialization_protected_path_invalid'
    Assert-True ($normalizedPaths.repository -ceq
        'E:\Users\zih44\Documents\Github\Nikke-Local-Lab') `
        'phase3b2_physical_materialization_repository_path_invalid'

    $bootDisk = Get-DiskForDriveLetter 'C'
    $samsungDisk = Get-DiskForDriveLetter 'E'
    Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem) `
        'phase3b2_physical_materialization_micron_boot_required'
    Assert-True ($samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
        'phase3b2_physical_materialization_samsung_data_disk_required'

    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $deviceGuard = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard
    $runningSecurityServices = @(
        $deviceGuard.SecurityServicesRunning |
            Where-Object { $null -ne $_ -and [int]$_ -ne 0 }
    )
    Assert-True (-not [bool]$computerSystem.HypervisorPresent -and
        [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 0 -and
        $runningSecurityServices.Count -eq 0) `
        'phase3b2_physical_materialization_virtualization_boundary_invalid'
    Assert-True ((Test-OptionalFeatureDisabled 'Microsoft-Hyper-V-All') -and
        (Test-OptionalFeatureDisabled 'Containers-DisposableClientVM')) `
        'phase3b2_physical_materialization_optional_feature_boundary_invalid'

    Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.LocalBootstrap' -ErrorAction SilentlyContinue)) `
        'phase3b2_physical_materialization_runtime_not_cold'
    Assert-True ((Test-Path -LiteralPath $StagingRoot -PathType Container) -and
        (Test-Path -LiteralPath (Split-Path -Parent $SamsungProtectedRoot) -PathType Container) -and
        (Test-Path -LiteralPath $SamsungRepositoryRoot -PathType Container)) `
        'phase3b2_physical_materialization_required_root_missing'
    if ($ResumeValidatedCleanBuild) {
        Assert-True ($ResumeAssessmentUid -ceq
                '83a280d0-7568-4ced-9133-a500ae65b3d7' -and
            (Test-Path -LiteralPath $EpinelRoot -PathType Container) -and
            (Test-Path -LiteralPath $LocalEvidenceRoot -PathType Container) -and
            -not (Test-Path -LiteralPath $AdapterWorkRoot) -and
            -not (Test-Path -LiteralPath $RuntimeRoot)) `
            'phase3b2_physical_materialization_resume_shape_invalid'
    }
    else {
        Assert-True (-not (Test-Path -LiteralPath $EpinelRoot) -and
            -not (Test-Path -LiteralPath $AdapterWorkRoot) -and
            -not (Test-Path -LiteralPath $RuntimeRoot) -and
            -not (Test-Path -LiteralPath $LocalEvidenceRoot)) `
            'phase3b2_physical_materialization_destination_not_cold'
    }
    Assert-True (-not (Test-Path -LiteralPath $attemptRoot)) `
        'phase3b2_physical_materialization_attempt_exists'
    New-Item -ItemType Directory -Path $SamsungProtectedRoot, $attemptRoot -Force |
        Out-Null
    if (-not $ResumeValidatedCleanBuild) {
        New-Item -ItemType Directory -Path $LocalEvidenceRoot -Force | Out-Null
    }

    $stageCode = 'sealed_prerequisite_verification'
    $cloneBootReceiptPath = Join-Path (Split-Path -Parent $SamsungProtectedRoot) `
        'ClientClone\physical-client-clone-boot-verification.receipt.json'
    $physicalBootReceiptPath = Join-Path (Split-Path -Parent $SamsungProtectedRoot) `
        'BCD\physical-test-current-loader-verification-v3.receipt.json'
    $stagingReceiptPath = Join-Path (Split-Path -Parent $SamsungProtectedRoot) `
        'P0Staging\offline-p0-input-staging.receipt.json'
    $stagingManifestPath = Join-Path (Split-Path -Parent $SamsungProtectedRoot) `
        'P0Staging\offline-p0-input-staging.manifest.tsv'
    $pins = @(
        [pscustomobject]@{ Path = $cloneBootReceiptPath; Length = 1999L; Sha256 = '6dc5a79941b8eeabefcbc0a7c4f6b2bfbd59e7081a8147abad041bc50fae37b4' },
        [pscustomobject]@{ Path = $physicalBootReceiptPath; Length = 1375L; Sha256 = '07a45ab10cddc37caf97e84ee29137f19b26fb18a064fea2093a9f860cdbf9ba' },
        [pscustomobject]@{ Path = $stagingReceiptPath; Length = 1510L; Sha256 = 'e06438b3bff05b67a648e3c59f940408a988aa3d7ac32244961daafb48bc9ca8' },
        [pscustomobject]@{ Path = $stagingManifestPath; Length = 2140L; Sha256 = 'b348b579a1d69a92e30d00fd605808aa965b77440ec901e7e5ef955dabcd3028' }
    )
    foreach ($pin in $pins) {
        Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
            (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
            (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
            'phase3b2_physical_materialization_prerequisite_pin_mismatch'
    }
    $cloneBootReceipt = Get-Content -LiteralPath $cloneBootReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $stagingReceipt = Get-Content -LiteralPath $stagingReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($cloneBootReceipt.contractId -ceq
            'nll/micron-physical-client-clone-boot-verification/v1' -and
        $cloneBootReceipt.readyForPhysicalP0Staging -and
        -not $cloneBootReceipt.clientExecutionStarted) `
        'phase3b2_physical_materialization_clone_receipt_invalid'
    Assert-True ($stagingReceipt.contractId -ceq
            'nll/phase3b2-physical-p0-input-staging-offline/v1' -and
        $stagingReceipt.stagedMemberCount -eq 18 -and
        $stagingReceipt.stagingManifestSha256 -ceq
            'b348b579a1d69a92e30d00fd605808aa965b77440ec901e7e5ef955dabcd3028' -and
        -not $stagingReceipt.credentialBearingSourceCopiedToMicron -and
        -not $stagingReceipt.serverExecutionStarted -and
        -not $stagingReceipt.clientExecutionStarted) `
        'phase3b2_physical_materialization_staging_receipt_invalid'

    $manifestRows = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $stagingManifestPath -Encoding UTF8) {
        $parts = $line -split "`t", 3
        Assert-True ($parts.Count -eq 3 -and $parts[1] -cmatch '^[0-9]+$' -and
            $parts[2] -cmatch '^[0-9a-f]{64}$') `
            'phase3b2_physical_materialization_staging_manifest_invalid'
        $relativePath = $parts[0].Replace('/', '\')
        Assert-True (-not [IO.Path]::IsPathRooted($relativePath) -and
            -not $relativePath.Contains('..')) `
            'phase3b2_physical_materialization_staging_member_path_invalid'
        $path = Join-Path $StagingRoot $relativePath
        Assert-True ((Test-Path -LiteralPath $path -PathType Leaf) -and
            (Get-Item -LiteralPath $path).Length -eq [long]$parts[1] -and
            (Get-Sha256Hex $path) -ceq $parts[2]) `
            'phase3b2_physical_materialization_staging_member_mismatch'
        $manifestRows.Add([pscustomobject]@{
            RelativePath = $parts[0]
            ByteLength = [long]$parts[1]
            Sha256 = $parts[2]
        })
    }
    Assert-True ($manifestRows.Count -eq 18 -and
        @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File -Force).Count -eq 18) `
        'phase3b2_physical_materialization_staging_shape_invalid'

    $rawProfilePath = 'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PrivateRuntime\NikkeLocalLabImports\credential-bearing\phase3b2-26f65275-2f62-49d4-ba3f-7f50558b1575\credential-bearing-source.json'
    Assert-True ((Test-Path -LiteralPath $rawProfilePath -PathType Leaf) -and
        (Get-Item -LiteralPath $rawProfilePath).Length -eq 964036L -and
        (Get-Sha256Hex $rawProfilePath) -ceq
            'efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605') `
        'phase3b2_physical_materialization_raw_profile_pin_mismatch'
    $clientCloneRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical'
    $clientExePath = Join-Path $clientCloneRoot 'NIKKE\game\nikke.exe'
    Assert-True ((Test-Path -LiteralPath $clientExePath -PathType Leaf) -and
        (Get-Sha256Hex $clientExePath) -ceq
            '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30') `
        'phase3b2_physical_materialization_client_clone_pin_mismatch'

    $stageCode = 'toolchain_and_bundle_verification'
    $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    $git = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    Assert-True ((Test-Path -LiteralPath $dotnet -PathType Leaf) -and
        (Test-Path -LiteralPath $git -PathType Leaf)) `
        'phase3b2_physical_materialization_toolchain_missing'
    $dotnetSdkVersion = (& $dotnet --version).Trim()
    $bundlePath = Join-Path $StagingRoot `
        'EpinelPS\EpinelPS-519c3db51ec24ca19307e93e85acde7885928a72.bundle'
    $gitSafeDirectory = 'C:/NLL/EpinelPS'
    Assert-True ((Get-Item -LiteralPath $bundlePath).Length -eq 23410136L -and
        (Get-Sha256Hex $bundlePath) -ceq
            'b56305e10adc57b94832bd6e80e112906c7ed9143f4507c548c298fa1860bb71') `
        'phase3b2_physical_materialization_bundle_pin_mismatch'
    $dotnetCliHome = Join-Path $LocalEvidenceRoot 'dotnet-home'
    $env:DOTNET_CLI_HOME = $dotnetCliHome
    $env:NUGET_PACKAGES = Join-Path $env:USERPROFILE '.nuget\packages'
    New-Item -ItemType Directory -Path $dotnetCliHome -Force | Out-Null

    $selectedLog = Join-Path $LocalEvidenceRoot 'selected-manager-tests.log'
    $isolationLog = Join-Path $LocalEvidenceRoot 'handler-isolation-tests.log'
    if ($ResumeValidatedCleanBuild) {
        $stageCode = 'validated_clean_build_resume'
        $resumeFailurePath = Join-Path (Join-Path $SamsungProtectedRoot $ResumeAssessmentUid) `
            'physical-server-profile-materialization.failure.receipt.json'
        Assert-True ((Test-Path -LiteralPath $resumeFailurePath -PathType Leaf) -and
            (Get-Item -LiteralPath $resumeFailurePath).Length -eq 687L -and
            (Get-Sha256Hex $resumeFailurePath) -ceq
                '0394a2da3fe78d10e7c29aa61817d3c2b25f37e3ff6fe7afe8d58315d49aab5d') `
            'phase3b2_physical_materialization_resume_receipt_mismatch'
        $resumeFailure = Get-Content -LiteralPath $resumeFailurePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        Assert-True ($resumeFailure.failedStageCode -ceq 'external_build_manifest_seal' -and
            $resumeFailure.failureCode -ceq
                'phase3b2_physical_materialization_build_manifest_mismatch' -and
            $resumeFailure.operatorEnvRestored -and
            -not $resumeFailure.clientOrSystemMutationPerformed -and
            -not $resumeFailure.serverExecutionStarted -and
            -not $resumeFailure.clientExecutionStarted) `
            'phase3b2_physical_materialization_resume_receipt_invalid'
        $resumeEvidencePins = @(
            [pscustomobject]@{ Name = 'epinel-clone.log'; Length = 730L; Sha256 = '84d1947ec7504ff6215541dbe63890617544cffe107c71b32a2e7abf92662ddf' },
            [pscustomobject]@{ Name = 'bundle-verify.log'; Length = 1262L; Sha256 = 'b17e0a6394019deb61f168cddf8986363c85e670a4e1f52365d784a463512eab' },
            [pscustomobject]@{ Name = 'epinel-restore.log'; Length = 1164L; Sha256 = 'cde1acc1ae3b189d828e6cecab4a202eb996bf19ee74247cdfab9a653d630e6d' },
            [pscustomobject]@{ Name = 'epinel-build.log'; Length = 17242L; Sha256 = 'b255806c7b926b14ef7e39f343f67751abc3b346c55b5c29af4ca30f1018d339' },
            [pscustomobject]@{ Name = 'selected-manager-tests.log'; Length = 586L; Sha256 = '909a8e1f086d0c371a3f4d6de2292e68f507b3cb21d914aa642858bdad98f828' },
            [pscustomobject]@{ Name = 'handler-isolation-tests.log'; Length = 586L; Sha256 = '2c4622183c01659d905e799df1b4747fc597e3c4bd4112b6b8996ccce89b1aca' },
            [pscustomobject]@{ Name = 'server-build.manifest.tsv'; Length = 63280L; Sha256 = '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3' }
        )
        foreach ($pin in $resumeEvidencePins) {
            $path = Join-Path $LocalEvidenceRoot $pin.Name
            Assert-True ((Test-Path -LiteralPath $path -PathType Leaf) -and
                (Get-Item -LiteralPath $path).Length -eq $pin.Length -and
                (Get-Sha256Hex $path) -ceq $pin.Sha256) `
                'phase3b2_physical_materialization_resume_evidence_mismatch'
        }
        $externalHead = (& $git -c "safe.directory=$gitSafeDirectory" `
            -C $EpinelRoot rev-parse HEAD).Trim()
        $externalTree = (& $git -c "safe.directory=$gitSafeDirectory" `
            -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim()
        $dotnetSdkVersion = (& $dotnet --version).Trim()
    }
    else {
        $stageCode = 'external_checkout_and_offline_restore'
        $cloneExitCode = Invoke-NativeLogged $git @(
            'clone',
            '--branch', 'codex/phase3b2-live-preflight',
            '--single-branch',
            $bundlePath,
            $EpinelRoot
        ) (Join-Path $LocalEvidenceRoot 'epinel-clone.log')
        Assert-True ($cloneExitCode -eq 0) `
            'phase3b2_physical_materialization_clone_failed'
        $bundleVerifyExitCode = Invoke-NativeLogged $git @(
            '-c', "safe.directory=$gitSafeDirectory",
            '-C', $EpinelRoot,
            'bundle', 'verify', $bundlePath
        ) (Join-Path $LocalEvidenceRoot 'bundle-verify.log')
        Assert-True ($bundleVerifyExitCode -eq 0) `
            'phase3b2_physical_materialization_bundle_verify_failed'
        $externalHead = (& $git -c "safe.directory=$gitSafeDirectory" `
            -C $EpinelRoot rev-parse HEAD).Trim()
        $externalTree = (& $git -c "safe.directory=$gitSafeDirectory" `
            -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim()
    }
    Assert-True ($externalHead -ceq '519c3db51ec24ca19307e93e85acde7885928a72' -and
        $externalTree -ceq 'b9e8bfb1b1e065427a48d40cb2bcf2f30215436a' -and
        (& $git -c "safe.directory=$gitSafeDirectory" -C $EpinelRoot `
            branch --show-current).Trim() -ceq
            'codex/phase3b2-live-preflight') `
        'phase3b2_physical_materialization_checkout_pin_mismatch'
    foreach ($ancestor in @(
            '28b2f5413a0a1e3521a11ae162f91851335c8b40',
            '92a6ca228aeb580988907b96189b2857dff2c62d',
            'e32e5f900775974d5736e7fb2b50f8c62638a004',
            '4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f',
            '6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6',
            '9d22e68d069ec3d832bc3ece084952906c169d79')) {
        & $git -c "safe.directory=$gitSafeDirectory" -C $EpinelRoot `
            merge-base --is-ancestor $ancestor $externalHead
        Assert-True ($LASTEXITCODE -eq 0) `
            'phase3b2_physical_materialization_ancestor_mismatch'
    }
    Assert-True (@(& $git -c "safe.directory=$gitSafeDirectory" -C $EpinelRoot `
            status --porcelain=v1 --untracked-files=all).Count -eq 0) `
        'phase3b2_physical_materialization_checkout_not_clean'

    $nugetConfig = Join-Path $StagingRoot 'ProfileAdapter\NuGet.config'
    Assert-True ($dotnetSdkVersion -ceq '10.0.400') `
        'phase3b2_physical_materialization_sdk_mismatch'
    if (-not $ResumeValidatedCleanBuild) {
        Push-Location $EpinelRoot
        try {
            $dotnetSdkVersion = (& $dotnet --version).Trim()
            Assert-True ($dotnetSdkVersion -ceq '10.0.400') `
                'phase3b2_physical_materialization_sdk_mismatch'
            $restoreExitCode = Invoke-NativeLogged $dotnet @(
                'restore', '.\EpinelPS.sln',
                '--locked-mode', '--nologo',
                '--configfile', $nugetConfig
            ) (Join-Path $LocalEvidenceRoot 'epinel-restore.log')
            Assert-True ($restoreExitCode -eq 0) `
                'phase3b2_physical_materialization_offline_restore_failed'
        }
        finally { Pop-Location }

        $stageCode = 'external_release_build_and_focused_tests'
        Push-Location $EpinelRoot
        try {
            $buildExitCode = Invoke-NativeLogged $dotnet @(
                'build', '.\EpinelPS.sln',
                '-c', 'Release', '--no-restore', '--nologo'
            ) (Join-Path $LocalEvidenceRoot 'epinel-build.log')
            Assert-True ($buildExitCode -eq 0) `
                'phase3b2_physical_materialization_release_build_failed'
            $selectedExitCode = Invoke-NativeLogged $dotnet @(
                'test', '.\tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj',
                '-c', 'Release', '--no-build', '--nologo'
            ) $selectedLog
            Assert-True ($selectedExitCode -eq 0) `
                'phase3b2_physical_materialization_selected_manager_tests_failed'
            $isolationExitCode = Invoke-NativeLogged $dotnet @(
                'test', '.\tests\EpinelPS.HandlerIsolation.Tests\EpinelPS.HandlerIsolation.Tests.csproj',
                '-c', 'Release', '--no-build', '--nologo'
            ) $isolationLog
            Assert-True ($isolationExitCode -eq 0) `
                'phase3b2_physical_materialization_handler_isolation_tests_failed'
        }
        finally { Pop-Location }
    }

    $stageCode = 'external_build_manifest_seal'
    $serverRoot = Join-Path $EpinelRoot 'EpinelPS\bin\Release\net10.0\win-x64'
    Assert-True (Test-Path -LiteralPath $serverRoot -PathType Container) `
        'phase3b2_physical_materialization_server_output_missing'
    $serverRootPrefix = $serverRoot.TrimEnd('\') + '\'
    $relativePaths = [Collections.Generic.List[string]]::new()
    foreach ($path in [IO.Directory]::EnumerateFiles(
            $serverRoot, '*', [IO.SearchOption]::AllDirectories)) {
        Assert-True ($path.StartsWith($serverRootPrefix,
                [StringComparison]::OrdinalIgnoreCase)) `
            'phase3b2_physical_materialization_build_member_outside_root'
        $relative = $path.Substring($serverRootPrefix.Length).Replace('\', '/')
        if (-not $relative.StartsWith('cache/', [StringComparison]::OrdinalIgnoreCase) -and
            $relative -cne 'db.json') {
            $relativePaths.Add($relative)
        }
    }
    $relativePaths.Sort([StringComparer]::Ordinal)
    $buildManifestLines = foreach ($relative in $relativePaths) {
        $file = Get-Item -LiteralPath (Join-Path $serverRoot $relative)
        "$relative`t$($file.Length)`t$(Get-Sha256Hex $file.FullName)"
    }
    $buildManifestPath = Join-Path $LocalEvidenceRoot 'server-build.manifest.tsv'
    Write-AtomicUtf8NoBom $buildManifestPath (($buildManifestLines -join "`n") + "`n")
    $buildContentByteLength = [long](($relativePaths | ForEach-Object {
                (Get-Item -LiteralPath (Join-Path $serverRoot $_)).Length
            } | Measure-Object -Sum).Sum)
    Assert-True ($relativePaths.Count -eq 577 -and
        $buildContentByteLength -eq 193937818L -and
        (Get-Item -LiteralPath $buildManifestPath).Length -eq 63280L -and
        (Get-Sha256Hex $buildManifestPath) -ceq
            '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3' -and
        -not (Test-Path -LiteralPath (Join-Path $serverRoot 'epinelps.db')) -and
        -not (Test-Path -LiteralPath (Join-Path $serverRoot 'epinelps.db-shm')) -and
        -not (Test-Path -LiteralPath (Join-Path $serverRoot 'epinelps.db-wal'))) `
        'phase3b2_physical_materialization_build_manifest_mismatch'
    Assert-True (@(& $git -c "safe.directory=$gitSafeDirectory" -C $EpinelRoot `
            status --porcelain=v1 --untracked-files=all).Count -eq 0) `
        'phase3b2_physical_materialization_checkout_drift_after_build'

    $stageCode = 'runtime_inputs_and_bootstrap_materialization'
    $staticSource = Join-Path $StagingRoot 'Inputs\staticdata\553116\StaticData.pack'
    $staticTarget = Join-Path $serverRoot `
        'cache\prdenv\150-cebfae1ecb\staticdata\data\qa-260813-08b\553116\mpk\StaticData.pack'
    New-Item -ItemType Directory -Path (Split-Path -Parent $staticTarget) -Force | Out-Null
    Copy-Item -LiteralPath $staticSource -Destination $staticTarget
    $localeTarget = Join-Path $serverRoot 'cache\local-locale'
    New-Item -ItemType Directory -Path $localeTarget -Force | Out-Null
    foreach ($name in @(
            'Locale_Bgm.lsc',
            'Locale_Character.lsc',
            'Locale_CharacterCostume.lsc',
            'Locale_Item.lsc')) {
        Copy-Item -LiteralPath (Join-Path $StagingRoot "Inputs\locale\$name") `
            -Destination (Join-Path $localeTarget $name)
    }
    Assert-True ((Get-Item -LiteralPath $staticTarget).Length -eq 17177168L -and
        (Get-Sha256Hex $staticTarget) -ceq
            '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3') `
        'phase3b2_physical_materialization_staticdata_mismatch'

    New-Item -ItemType Directory -Path (Split-Path -Parent $RuntimeRoot) -Force |
        Out-Null
    Copy-Item -LiteralPath (Join-Path $StagingRoot 'LocalBootstrap-v1') `
        -Destination $RuntimeRoot -Recurse
    $bootstrapManifestPath = Join-Path $RuntimeRoot 'evidence\artifact.manifest.tsv'
    $bootstrapReceiptPath = Join-Path $RuntimeRoot 'local-bootstrap-build.receipt.json'
    Assert-True (@(Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -File -Force).Count -eq 7 -and
        (Get-Sha256Hex $bootstrapManifestPath) -ceq
            'b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70' -and
        (Get-Sha256Hex $bootstrapReceiptPath) -ceq
            '5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11') `
        'phase3b2_physical_materialization_bootstrap_mismatch'

    $stageCode = 'profile_adapter_offline_build'
    New-Item -ItemType Directory -Path (Split-Path -Parent $AdapterWorkRoot) -Force |
        Out-Null
    Copy-Item -LiteralPath (Join-Path $StagingRoot 'ProfileAdapter') `
        -Destination $AdapterWorkRoot -Recurse
    $adapterProject = Join-Path $AdapterWorkRoot `
        'NikkeLocalLab.Phase3B2.ProfileAdapter.csproj'
    $adapterProgram = Join-Path $AdapterWorkRoot 'Program.cs'
    $adapterOutput = Join-Path $AdapterWorkRoot 'out'
    $epinelProject = Join-Path $EpinelRoot 'EpinelPS\EpinelPS.csproj'
    $adapterSource = Get-Content -LiteralPath $adapterProgram -Raw -Encoding UTF8
    Assert-True ($adapterSource.Contains('NewLauncherPassword()') -and
        $adapterSource.Contains('LauncherPasswordHash(launcherPassword)') -and
        $adapterSource.Contains('Password = launcherPasswordHash') -and
        $adapterSource.Contains('password = launcherPassword') -and
        $adapterSource.Contains('md5_lower_hex_legacy_launcher_compatibility') -and
        -not $adapterSource.Contains('Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))')) `
        'phase3b2_physical_materialization_adapter_source_shape_invalid'
    Push-Location $AdapterWorkRoot
    try {
        $adapterRestoreExitCode = Invoke-NativeLogged $dotnet @(
            'restore', $adapterProject,
            '--nologo', '--configfile', $nugetConfig,
            "-p:EpinelProjectPath=$epinelProject"
        ) (Join-Path $LocalEvidenceRoot 'adapter-restore.log')
        Assert-True ($adapterRestoreExitCode -eq 0) `
            'phase3b2_physical_materialization_adapter_restore_failed'
        $adapterBuildExitCode = Invoke-NativeLogged $dotnet @(
            'build', $adapterProject,
            '-c', 'Release', '--no-restore', '--nologo',
            '-o', $adapterOutput,
            "-p:EpinelProjectPath=$epinelProject"
        ) (Join-Path $LocalEvidenceRoot 'adapter-build.log')
        Assert-True ($adapterBuildExitCode -eq 0) `
            'phase3b2_physical_materialization_adapter_build_failed'
    }
    finally { Pop-Location }
    $adapterDll = Join-Path $adapterOutput 'NikkeLocalLab.Phase3B2.ProfileAdapter.dll'
    Assert-True (Test-Path -LiteralPath $adapterDll -PathType Leaf) `
        'phase3b2_physical_materialization_adapter_output_missing'
    Copy-Item -LiteralPath (Join-Path $serverRoot 'gameconfig.json') `
        -Destination $adapterOutput -Force
    Copy-Item -LiteralPath (Join-Path $serverRoot 'cache') `
        -Destination $adapterOutput -Recurse -Force

    $stageCode = 'synthetic_profile_materialization'
    $identityRoot = Join-Path $LocalEvidenceRoot 'identity'
    $contextPath = Join-Path $identityRoot 'synthetic-context.json'
    $profileReceiptPath = Join-Path $identityRoot 'offline-synthetic-profile.receipt.json'
    $dbPath = Join-Path $serverRoot 'db.json'
    New-Item -ItemType Directory -Path $identityRoot -Force | Out-Null
    Push-Location $adapterOutput
    try {
        $adapterExecutionExitCode = Invoke-NativeLogged $dotnet @(
            $adapterDll,
            '--source', $rawProfilePath,
            '--server-root', $serverRoot,
            '--context', $contextPath,
            '--receipt', $profileReceiptPath,
            '--expected-source-length', '964036',
            '--expected-source-sha256',
                'efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605'
        ) (Join-Path $LocalEvidenceRoot 'adapter-execution.log')
        Assert-True ($adapterExecutionExitCode -eq 0) `
            'phase3b2_physical_materialization_adapter_execution_failed'
    }
    finally { Pop-Location }
    Assert-True ((Test-Path -LiteralPath $dbPath -PathType Leaf) -and
        (Test-Path -LiteralPath $contextPath -PathType Leaf) -and
        (Test-Path -LiteralPath $profileReceiptPath -PathType Leaf)) `
        'phase3b2_physical_materialization_profile_output_missing'

    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profileReceipt = Get-Content -LiteralPath $profileReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
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
        @($db.Users).Count -eq 1 -and
        [string]$db.Users[0].Username -ceq $username -and
        [string]$db.Users[0].Password -ceq $passwordHash -and
        $null -eq $db.Users[0].SelectedClassicSoloRaidManagerId) `
        'phase3b2_physical_materialization_synthetic_credential_invalid'
    Assert-True ($profileReceipt.contractId -ceq
            'nll/phase3b2-offline-synthetic-profile/v1' -and
        $profileReceipt.characterCount -eq 193 -and
        $profileReceipt.consoleCount -eq 9 -and
        $profileReceipt.launcherPasswordStorageSchemeCode -ceq
            'md5_lower_hex_legacy_launcher_compatibility' -and
        -not $profileReceipt.officialIdentityPersisted -and
        -not $profileReceipt.officialCredentialPersisted -and
        -not $profileReceipt.serverExecutionStarted -and
        -not $profileReceipt.clientExecutionStarted) `
        'phase3b2_physical_materialization_profile_receipt_invalid'

    $rawProfileCopyCount = 0
    foreach ($candidate in Get-ChildItem -LiteralPath 'C:\NLL' -Recurse -File -Force |
            Where-Object Length -EQ 964036L) {
        if ((Get-Sha256Hex $candidate.FullName) -ceq
            'efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605') {
            $rawProfileCopyCount++
        }
    }
    Assert-True ($rawProfileCopyCount -eq 0) `
        'phase3b2_physical_materialization_raw_profile_copied_to_micron'

    $stageCode = 'operator_env_rotation'
    Assert-True ((Test-Path -LiteralPath $envPath -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $SamsungRepositoryRoot '.gitignore') -PathType Leaf) -and
        (Get-Content -LiteralPath (Join-Path $SamsungRepositoryRoot '.gitignore') -Encoding UTF8 |
            Where-Object { $_.Trim() -ceq '.env' }).Count -ge 1) `
        'phase3b2_physical_materialization_operator_env_boundary_invalid'
    $envAclBefore = Get-Acl -LiteralPath $envPath
    Assert-True ($envAclBefore.AreAccessRulesProtected) `
        'phase3b2_physical_materialization_operator_env_acl_not_protected'
    Copy-Item -LiteralPath $envPath -Destination $envBackupPath
    $envBeforeDigest = Get-FileDigest $envBackupPath
    $newEnvText = @(
        "NLL_PHASE3B2_ASSESSMENT_UID=$assessmentUid"
        "NLL_PHASE3B2_SYNTHETIC_USERNAME=$username"
        "NLL_PHASE3B2_SYNTHETIC_PASSWORD=$password"
    ) -join "`n"
    [IO.File]::WriteAllText($envPath, $newEnvText + "`n",
        [Text.UTF8Encoding]::new($false))
    $envUpdated = $true
    $envAclAfter = Get-Acl -LiteralPath $envPath
    Assert-True ($envAclAfter.AreAccessRulesProtected -and
        $envAclAfter.Sddl -ceq $envAclBefore.Sddl -and
        (Get-Content -LiteralPath $envPath -Encoding UTF8).Count -eq 3) `
        'phase3b2_physical_materialization_operator_env_postcondition_failed'
    $envAfterDigest = Get-FileDigest $envPath

    $stageCode = 'success_seal'
    $buildManifestExternalPath = Join-Path $attemptRoot 'server-build.manifest.tsv'
    Copy-Item -LiteralPath $buildManifestPath -Destination $buildManifestExternalPath
    Assert-True ((Get-Sha256Hex $buildManifestExternalPath) -ceq
        '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3') `
        'phase3b2_physical_materialization_external_manifest_copy_mismatch'
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-server-profile-materialization/v1'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        executionBootDisk = 'Micron_2200_MTFDHBA512TCK'
        evidenceDisk = 'Samsung SSD 980 1TB'
        hypervisorPresent = $false
        virtualizationBasedSecurityStatus = 0
        externalHead = $externalHead
        externalTree = $externalTree
        externalCheckoutClean = $true
        dotnetSdkVersion = $dotnetSdkVersion
        gitVersion = (& $git --version).Trim()
        offlinePackageSourcesCleared = $true
        selectedManagerPassedCount = 64
        handlerIsolationPassedCount = 5
        focusedTestFailedCount = 0
        cleanBuildResumeUsed = [bool]$ResumeValidatedCleanBuild
        resumedFromAssessmentUid = if ($ResumeValidatedCleanBuild) {
            $ResumeAssessmentUid
        }
        else { $null }
        buildProvenanceCode = 'clean_clone_offline_release_build'
        historicalVmBuildManifestStatusCode =
            'rejected_runtime_contaminated_incremental_output'
        historicalVmBuildManifestSha256 =
            'ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37'
        localOnlyHttp3Enabled = $false
        localOnlyAssetCachePathLoggingEnabled = $false
        buildFileCount = $relativePaths.Count
        buildContentByteLength = $buildContentByteLength
        buildManifestByteLength = (Get-Item -LiteralPath $buildManifestExternalPath).Length
        buildManifestSha256 = Get-Sha256Hex $buildManifestExternalPath
        staticDataPackSha256 = Get-Sha256Hex $staticTarget
        localeInputCount = 4
        localBootstrapReceiptSha256 = Get-Sha256Hex $bootstrapReceiptPath
        localBootstrapManifestSha256 = Get-Sha256Hex $bootstrapManifestPath
        profileAdapterSourceByteLength = (Get-Item -LiteralPath $adapterProgram).Length
        profileAdapterSourceSha256 = Get-Sha256Hex $adapterProgram
        profileAdapterOutputByteLength = (Get-Item -LiteralPath $adapterDll).Length
        profileAdapterOutputSha256 = Get-Sha256Hex $adapterDll
        syntheticProfileReceiptByteLength = (Get-Item -LiteralPath $profileReceiptPath).Length
        syntheticProfileReceiptSha256 = Get-Sha256Hex $profileReceiptPath
        syntheticContextByteLength = (Get-Item -LiteralPath $contextPath).Length
        syntheticContextSha256 = Get-Sha256Hex $contextPath
        syntheticDatabaseByteLength = (Get-Item -LiteralPath $dbPath).Length
        syntheticDatabaseSha256 = Get-Sha256Hex $dbPath
        characterCount = [int]$profileReceipt.characterCount
        consoleCount = [int]$profileReceipt.consoleCount
        launcherPasswordRepresentation =
            'md5_lower_hex_legacy_launcher_compatibility'
        oldOperatorEnvBackupByteLength = [long]$envBeforeDigest.byteLength
        oldOperatorEnvBackupSha256 = [string]$envBeforeDigest.sha256
        newOperatorEnvByteLength = [long]$envAfterDigest.byteLength
        newOperatorEnvSha256 = [string]$envAfterDigest.sha256
        operatorEnvTracked = $false
        operatorEnvIgnored = $true
        operatorEnvAclPreserved = $true
        protectedRawProfileReadFromSamsung = $true
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
        receiptRelativePath = "$assessmentUid/physical-server-profile-materialization.receipt.json"
        receiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        receiptSha256 = Get-Sha256Hex $receiptPath
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $latestPointerPath (($pointer | ConvertTo-Json) + "`n")
    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $receiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $receiptPath
    } | ConvertTo-Json -Depth 10
}
catch {
    $caughtException = $_
    $safeFailureCode = if ($caughtException.Exception.Message -cmatch
        '^phase3b2_[a-z0-9_:-]+$') {
        $caughtException.Exception.Message
    }
    else {
        'phase3b2_physical_materialization_unexpected_error_redacted'
    }
    if ($envUpdated -and (Test-Path -LiteralPath $envBackupPath -PathType Leaf)) {
        try {
            [IO.File]::WriteAllBytes($envPath, [IO.File]::ReadAllBytes($envBackupPath))
            $envUpdated = $false
        }
        catch { }
    }
    try {
        if (-not (Test-Path -LiteralPath $SamsungProtectedRoot)) {
            New-Item -ItemType Directory -Path $SamsungProtectedRoot -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $attemptRoot)) {
            New-Item -ItemType Directory -Path $attemptRoot -Force | Out-Null
        }
        $failure = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-server-profile-materialization-failure/v1'
            failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            assessmentUid = $assessmentUid
            failedStageCode = $stageCode
            failureCode = $safeFailureCode
            exceptionType = $caughtException.Exception.GetType().FullName
            operatorEnvRestored = -not $envUpdated
            clientOrSystemMutationPerformed = $false
            serverExecutionStarted = $false
            clientExecutionStarted = $false
            nextStepCode = 'inspect_physical_materialization_failure_without_client_rollback'
        }
        $failurePath = Join-Path $attemptRoot `
            'physical-server-profile-materialization.failure.receipt.json'
        Write-AtomicUtf8NoBom $failurePath (($failure | ConvertTo-Json) + "`n")
        $pointer = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-server-profile-materialization-pointer/v1'
            assessmentUid = $assessmentUid
            statusCode = 'failed'
            receiptRelativePath = "$assessmentUid/physical-server-profile-materialization.failure.receipt.json"
            receiptByteLength = (Get-Item -LiteralPath $failurePath).Length
            receiptSha256 = Get-Sha256Hex $failurePath
            serverExecutionStarted = $false
            clientExecutionStarted = $false
        }
        Write-AtomicUtf8NoBom $latestPointerPath (($pointer | ConvertTo-Json) + "`n")
    }
    catch { }
    throw "phase3b2_physical_materialization_failed:$stageCode"
}
