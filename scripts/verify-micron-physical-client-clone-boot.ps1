[CmdletBinding()]
param(
    [string]$SourceRoot = 'C:\NIKKE',
    [string]$CloneRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical',
    [string]$ProtectedRoot = 'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\ClientClone'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp'
    [IO.File]::WriteAllText($temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    $partition = Get-Partition -DriveLetter $DriveLetter
    return $partition | Get-Disk
}

function Get-FileInventory {
    param([string]$Root)
    [long]$contentByteLength = 0
    [int]$fileCount = 0
    foreach ($path in [IO.Directory]::EnumerateFiles(
        $Root,
        '*',
        [IO.SearchOption]::AllDirectories
    )) {
        $contentByteLength += ([IO.FileInfo]::new($path)).Length
        $fileCount++
    }
    return [ordered]@{
        fileCount = $fileCount
        contentByteLength = $contentByteLength
    }
}

function Get-OptionalFeatureState {
    param([string]$FeatureName)
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName
    return [string]$feature.State
}

$expectedCloneReceiptSha256 = '83a12e9af853be03f7e40e7683c7777e074f20f5b6807991f4be8da4b87c2f7f'
$expectedManifestSha256 = '0e9aaf9c69399e81bc3887660f360bd97ae78d0f6a41a5f339fb629e6fa574b4'
$expectedFileCount = 38670
[long]$expectedContentByteLength = 26745978753
$expectedRootNames = @('.tiny_cache', 'Launcher', 'NIKKE', 'sail_files', 'Unity')

$source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$clone = [IO.Path]::GetFullPath($CloneRoot).TrimEnd('\')
$protected = [IO.Path]::GetFullPath($ProtectedRoot).TrimEnd('\')
Assert-True ($source -ceq 'C:\NIKKE') 'micron_physical_clone_boot_source_path_invalid'
Assert-True ($clone -ceq 'C:\NLL\Clients\NIKKE-150.6.9-Physical') 'micron_physical_clone_boot_clone_path_invalid'
Assert-True ($protected -ceq 'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\ClientClone') 'micron_physical_clone_boot_protected_root_invalid'

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
Assert-True (
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
) 'micron_physical_clone_boot_administrator_required'

$cloneReceiptPath = Join-Path $protected 'physical-client-clone.receipt.json'
$stableVerificationPath = Join-Path $protected 'physical-client-clone-boot-verification.receipt.json'
Assert-True (Test-Path -LiteralPath $cloneReceiptPath -PathType Leaf) 'micron_physical_clone_boot_receipt_missing'
Assert-True (-not (Test-Path -LiteralPath $stableVerificationPath)) 'micron_physical_clone_boot_verification_already_exists'
$cloneReceiptSha256 = (
    Get-FileHash -LiteralPath $cloneReceiptPath -Algorithm SHA256
).Hash.ToLowerInvariant()
Assert-True (
    $cloneReceiptSha256 -ceq $expectedCloneReceiptSha256
) 'micron_physical_clone_boot_receipt_hash_mismatch'
$cloneReceipt = Get-Content -LiteralPath $cloneReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $cloneReceipt.contractId -ceq 'nll/micron-physical-client-clone-offline/v1' -and
    $cloneReceipt.assessmentUid -ceq '8c739dc2-60ae-410c-a513-0bc3bd3fc20e' -and
    $cloneReceipt.sourceManifestSha256 -ceq $expectedManifestSha256 -and
    $cloneReceipt.destinationManifestSha256 -ceq $expectedManifestSha256 -and
    $cloneReceipt.sourceManifestPinned -and
    $cloneReceipt.destinationManifestMatched
) 'micron_physical_clone_boot_receipt_invalid'

$assessmentRoot = Join-Path $protected ([string]$cloneReceipt.assessmentUid)
Assert-True (Test-Path -LiteralPath $assessmentRoot -PathType Container) 'micron_physical_clone_boot_assessment_root_missing'
$failurePath = Join-Path $assessmentRoot 'boot-verification.failure.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $failurePath)) 'micron_physical_clone_boot_prior_failure_present'

$stageCode = 'physical_boot_context'
try {
    $bootDisk = Get-DiskForDriveLetter 'C'
    $backupDisk = Get-DiskForDriveLetter 'E'
    Assert-True (
        $bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem
    ) 'micron_physical_clone_boot_micron_context_required'
    Assert-True (
        $backupDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not $backupDisk.IsBoot -and -not $backupDisk.IsSystem
    ) 'micron_physical_clone_boot_samsung_backup_context_invalid'

    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    Assert-True (-not [bool]$computerSystem.HypervisorPresent) 'micron_physical_clone_boot_hypervisor_present'

    $deviceGuard = Get-CimInstance `
        -Namespace 'root\Microsoft\Windows\DeviceGuard' `
        -ClassName Win32_DeviceGuard
    $runningSecurityServices = @(
        $deviceGuard.SecurityServicesRunning |
            Where-Object { $null -ne $_ -and [int]$_ -ne 0 }
    )
    Assert-True (
        [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 0 -and
        $runningSecurityServices.Count -eq 0
    ) 'micron_physical_clone_boot_vbs_still_running'

    $hyperVAllState = Get-OptionalFeatureState 'Microsoft-Hyper-V-All'
    $hyperVHypervisorState = Get-OptionalFeatureState 'Microsoft-Hyper-V-Hypervisor'
    $sandboxState = Get-OptionalFeatureState 'Containers-DisposableClientVM'
    Assert-True (
        $hyperVAllState -ceq 'Disabled' -and
        $hyperVHypervisorState -ceq 'Disabled' -and
        $sandboxState -ceq 'Disabled'
    ) 'micron_physical_clone_boot_virtualization_feature_enabled'

    $stageCode = 'client_placement_inventory'
    Assert-True (Test-Path -LiteralPath $source -PathType Container) 'micron_physical_clone_boot_source_missing'
    Assert-True (Test-Path -LiteralPath $clone -PathType Container) 'micron_physical_clone_boot_clone_missing'

    $runtimeProcesses = @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -in @('EpinelPS', 'nikke_launcher', 'nikke') }
    )
    Assert-True ($runtimeProcesses.Count -eq 0) 'micron_physical_clone_boot_runtime_process_present'

    $sourceRootNames = @(
        Get-ChildItem -LiteralPath $source -Force |
            Where-Object { $_.PSIsContainer } |
            Sort-Object Name |
            ForEach-Object { $_.Name }
    )
    $cloneRootNames = @(
        Get-ChildItem -LiteralPath $clone -Force |
            Where-Object { $_.PSIsContainer } |
            Sort-Object Name |
            ForEach-Object { $_.Name }
    )
    Assert-True (
        $sourceRootNames.Count -eq $expectedRootNames.Count -and
        $cloneRootNames.Count -eq $expectedRootNames.Count
    ) 'micron_physical_clone_boot_root_count_mismatch'
    for ($index = 0; $index -lt $expectedRootNames.Count; $index++) {
        Assert-True (
            $sourceRootNames[$index] -ceq $expectedRootNames[$index] -and
            $cloneRootNames[$index] -ceq $expectedRootNames[$index]
        ) 'micron_physical_clone_boot_root_name_mismatch'
    }

    Write-Host '[ 45%] Measuring source inventory without rehashing content...'
    $sourceInventory = Get-FileInventory $source
    Write-Host '[ 65%] Measuring physical clone inventory without rehashing content...'
    $cloneInventory = Get-FileInventory $clone
    Assert-True (
        $sourceInventory.fileCount -eq $expectedFileCount -and
        $sourceInventory.contentByteLength -eq $expectedContentByteLength -and
        $cloneInventory.fileCount -eq $expectedFileCount -and
        $cloneInventory.contentByteLength -eq $expectedContentByteLength
    ) 'micron_physical_clone_boot_inventory_mismatch'

    $sourceClientPath = Join-Path $source 'NIKKE\game\nikke.exe'
    $cloneClientPath = Join-Path $clone 'NIKKE\game\nikke.exe'
    $sourceLauncherPath = Join-Path $source 'Launcher\nikke_launcher.exe'
    $cloneLauncherPath = Join-Path $clone 'Launcher\nikke_launcher.exe'
    foreach ($path in @(
        $sourceClientPath,
        $cloneClientPath,
        $sourceLauncherPath,
        $cloneLauncherPath
    )) {
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) 'micron_physical_clone_boot_key_executable_missing'
    }

    $sourceClient = Get-Item -LiteralPath $sourceClientPath
    $cloneClient = Get-Item -LiteralPath $cloneClientPath
    Assert-True (
        $sourceClient.Length -eq 794152 -and
        $cloneClient.Length -eq 794152 -and
        $sourceClient.VersionInfo.FileVersion -ceq '150.6.9' -and
        $cloneClient.VersionInfo.FileVersion -ceq '150.6.9'
    ) 'micron_physical_clone_boot_client_build_mismatch'

    $sourceClientSha256 = (
        Get-FileHash -LiteralPath $sourceClientPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $cloneClientSha256 = (
        Get-FileHash -LiteralPath $cloneClientPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $sourceLauncherSha256 = (
        Get-FileHash -LiteralPath $sourceLauncherPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $cloneLauncherSha256 = (
        Get-FileHash -LiteralPath $cloneLauncherPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    Assert-True (
        $sourceClientSha256 -ceq $cloneClientSha256 -and
        $sourceLauncherSha256 -ceq $cloneLauncherSha256
    ) 'micron_physical_clone_boot_key_executable_hash_mismatch'

    $stageCode = 'boot_verification_seal'
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/micron-physical-client-clone-boot-verification/v1'
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = [string]$cloneReceipt.assessmentUid
        bootDisk = 'Micron_2200_MTFDHBA512TCK'
        backupDisk = 'Samsung SSD 980 1TB'
        hypervisorPresent = $false
        virtualizationBasedSecurityStatus = [int]$deviceGuard.VirtualizationBasedSecurityStatus
        runningSecurityServiceCount = $runningSecurityServices.Count
        hyperVAllState = $hyperVAllState
        hyperVHypervisorState = $hyperVHypervisorState
        windowsSandboxState = $sandboxState
        sourcePath = $source
        clonePath = $clone
        clientBuild = '150.6.9'
        sourceFileCount = $sourceInventory.fileCount
        sourceContentByteLength = $sourceInventory.contentByteLength
        cloneFileCount = $cloneInventory.fileCount
        cloneContentByteLength = $cloneInventory.contentByteLength
        sourceClientSha256 = $sourceClientSha256
        cloneClientSha256 = $cloneClientSha256
        sourceLauncherSha256 = $sourceLauncherSha256
        cloneLauncherSha256 = $cloneLauncherSha256
        sourceManifestSha256 = $expectedManifestSha256
        cloneManifestSha256 = $expectedManifestSha256
        manifestAuthorityCode = 'sealed_offline_full_sha256_manifest'
        fullContentRehashRepeatedAtBoot = $false
        cloneReceiptByteLength = (Get-Item -LiteralPath $cloneReceiptPath).Length
        cloneReceiptSha256 = $cloneReceiptSha256
        primarySourcePreserved = $true
        runtimeProcessCount = $runtimeProcesses.Count
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        readyForPhysicalP0Staging = $true
        nextStepCode = 'stage_hash_pinned_physical_p0_inputs'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 8) + "`n"
    $assessmentVerificationPath = Join-Path $assessmentRoot 'physical-client-clone-boot-verification.receipt.json'
    Write-AtomicUtf8NoBom $assessmentVerificationPath $receiptText
    Write-AtomicUtf8NoBom $stableVerificationPath $receiptText

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $stableVerificationPath
        ReceiptByteLength = (Get-Item -LiteralPath $stableVerificationPath).Length
        ReceiptSha256 = (
            Get-FileHash -LiteralPath $stableVerificationPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 10
}
catch {
    $failure = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/micron-physical-client-clone-boot-verification-failure/v1'
        failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = [string]$cloneReceipt.assessmentUid
        failedStageCode = $stageCode
        exceptionType = $_.Exception.GetType().FullName
        failureMessage = $_.Exception.Message
        sourcePath = $source
        clonePath = $clone
        sourceDeletionPerformed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'return_to_samsung_and_inspect_boot_verification_failure'
    }
    Write-AtomicUtf8NoBom $failurePath (($failure | ConvertTo-Json -Depth 6) + "`n")
    throw "micron_physical_client_clone_boot_verification_failed:${stageCode}:$($_.Exception.Message)"
}
