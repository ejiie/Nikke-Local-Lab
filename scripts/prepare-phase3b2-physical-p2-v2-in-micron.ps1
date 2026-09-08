[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$RuntimeRoot = 'C:\NLL\Runtime\PhysicalBootstrap-v2',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-preparation-v2',
    [string]$TransferReceiptPath =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\deployment.receipt.json',
    [string]$OperatorProfileReceiptPath =
        'C:\NLL\Evidence\Phase3B2\Physical\operator-profile-v1\profile-isolation.receipt.json',
    [string]$BackupRoot =
        'C:\NLL\Backups\Phase3B2\PhysicalP2-v2',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\PreparationV2'
)

$ErrorActionPreference = 'Stop'
$hostsBackupCreated = $false
$hostsApplied = $false
$extensionFirewallGroup = 'NLL Phase3B2 Physical P2 V2 Extension'

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

function Write-AtomicUtf8Bom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($true))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

try {
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_physical_p2_v2_prepare_requires_administrator'
    $bootDisk = Get-Partition -DriveLetter C | Get-Disk
    $samsungDisk = Get-Partition -DriveLetter E | Get-Disk
    Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem -and
        $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
        'phase3b2_physical_p2_v2_micron_boot_required'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $profileRoot = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile)
    Assert-True ((($identity.Name -split '\\')[-1] -ceq 'nlloperator') -and
        [IO.Path]::GetFullPath($profileRoot).TrimEnd('\') -ceq
            'C:\Users\nlloperator') `
        'phase3b2_physical_p2_v2_operator_profile_required'
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p2_v2_runtime_not_cold'
    Assert-True (-not (Test-Path -LiteralPath $EvidenceRoot) -and
        -not (Test-Path -LiteralPath $BackupRoot) -and
        -not (Test-Path -LiteralPath $SamsungProtectedRoot)) `
        'phase3b2_physical_p2_v2_destination_already_exists'

    Assert-True (Test-Path -LiteralPath $OperatorProfileReceiptPath `
        -PathType Leaf) 'phase3b2_physical_p2_v2_profile_receipt_missing'
    $operatorProfile = Get-Content -LiteralPath $OperatorProfileReceiptPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($operatorProfile.contractId -ceq
            'nll/phase3b2-micron-operator-profile-isolation/v1' -and
        $operatorProfile.accountName -ceq 'nlloperator' -and
        $operatorProfile.currentUserVerified -and
        [int]$operatorProfile.localLowCandidateCacheDirectoryCountBeforeFirstRun `
            -eq 0 -and
        -not $operatorProfile.existingOperatorNikkeCacheMutationPerformed -and
        -not $operatorProfile.clientExecutionStarted) `
        'phase3b2_physical_p2_v2_profile_receipt_invalid'

    Assert-True (Test-Path -LiteralPath $TransferReceiptPath -PathType Leaf) `
        'phase3b2_physical_p2_v2_transfer_receipt_missing'
    $transfer = Get-Content -LiteralPath $TransferReceiptPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($transfer.contractId -ceq
            'nll/phase3b2-physical-p2-v2-offline-deployment/v1' -and
        $transfer.targetDisk -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $transfer.targetOsOfflineDuringDeployment -and
        $transfer.requestStageObservationEnabled -and
        $transfer.endpointAdmissionCode -ceq
            'global_match_returned_by_local_get_server_info' -and
        -not $transfer.clientExecutionStarted) `
        'phase3b2_physical_p2_v2_transfer_receipt_invalid'
    foreach ($tool in @($transfer.tools)) {
        $toolPath = Join-Path 'C:\NLL\Tools' ([string]$tool.name)
        Assert-True (Test-PathDigest $toolPath ([long]$tool.byteLength) `
            ([string]$tool.sha256)) `
            'phase3b2_physical_p2_v2_tool_pin_mismatch'
    }

    $artifactRoot = Join-Path $RuntimeRoot 'artifact'
    $artifactManifestPath = Join-Path $RuntimeRoot `
        'evidence\artifact.manifest.tsv'
    $bootstrapPath = Join-Path $artifactRoot `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
    $serverDllPath = Join-Path $EpinelRoot `
        'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
    $clientRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical'
    $clientPath = Join-Path $clientRoot 'NIKKE\game\nikke.exe'
    $certificatePath = Join-Path $clientRoot `
        'NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem'
    $sodiumPath = Join-Path $clientRoot `
        'NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'
    Assert-True ((Test-PathDigest $artifactManifestPath `
            ([long]$transfer.artifactManifestByteLength) `
            ([string]$transfer.artifactManifestSha256)) -and
        (Test-PathDigest $bootstrapPath `
            ([long]$transfer.physicalBootstrapExeByteLength) `
            ([string]$transfer.physicalBootstrapExeSha256)) -and
        (Test-PathDigest $serverDllPath `
            ([long]$transfer.appliedServerDllByteLength) `
            ([string]$transfer.appliedServerDllSha256)) -and
        (Test-PathDigest $clientPath 794152L `
            '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30') -and
        (Test-PathDigest $certificatePath 213860L `
            '1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9') -and
        (Test-PathDigest $sodiumPath 358400L `
            '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662')) `
        'phase3b2_physical_p2_v2_runtime_pin_mismatch'

    $serverInfoPath = Join-Path $EpinelRoot `
        'EpinelPS\LobbyServer\Misc\GetServerInfo.cs'
    $serverInfoText = Get-Content -LiteralPath $serverInfoPath -Raw `
        -Encoding UTF8
    Assert-True ($serverInfoText -cmatch
        'MatchUrl\s*=\s*"https://global-match\.nikke-kr\.com"') `
        'phase3b2_physical_p2_v2_endpoint_admission_source_missing'

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    Assert-True (Test-PathDigest $hostsPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') `
        'phase3b2_physical_p2_v2_base_hosts_pin_mismatch'
    $baseFirewallGroup = 'NLL Phase3B2 Physical Isolation'
    $baseRules = @(Get-NetFirewallRule -Group $baseFirewallGroup `
        -ErrorAction SilentlyContinue)
    Assert-True ($baseRules.Count -eq 17 -and
        @(Get-NetFirewallRule -Group $extensionFirewallGroup `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p2_v2_firewall_precondition_invalid'

    New-Item -ItemType Directory -Path $EvidenceRoot, $BackupRoot,
        $SamsungProtectedRoot -Force | Out-Null
    $hostsBackupPath = Join-Path $BackupRoot 'hosts.before.bin'
    [IO.File]::WriteAllBytes($hostsBackupPath,
        [IO.File]::ReadAllBytes($hostsPath))
    Assert-True (Test-PathDigest $hostsBackupPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') `
        'phase3b2_physical_p2_v2_hosts_backup_failed'
    $hostsBackupCreated = $true

    $hostsText = [Text.UTF8Encoding]::new($true, $true).GetString(
        [IO.File]::ReadAllBytes($hostsPath)).TrimStart([char]0xFEFF)
    Assert-True ($hostsText.IndexOf('global-match.nikke-kr.com',
            [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        ([regex]::Matches($hostsText,
            '(?m)^# end NLL Phase3B2 Physical entries\r?$')).Count -eq 1) `
        'phase3b2_physical_p2_v2_endpoint_already_mapped_or_block_missing'
    $hostsAppliedText = $hostsText.Replace(
        '# end NLL Phase3B2 Physical entries',
        "127.0.0.1 global-match.nikke-kr.com`r`n# end NLL Phase3B2 Physical entries")
    Write-AtomicUtf8Bom $hostsPath $hostsAppliedText
    $hostsApplied = $true
    $hostsAppliedLength = (Get-Item -LiteralPath $hostsPath).Length
    $hostsAppliedSha256 = Get-Sha256Hex $hostsPath
    Assert-True (@(Get-Content -LiteralPath $hostsPath | Where-Object {
            $_ -ceq '127.0.0.1 global-match.nikke-kr.com'
        }).Count -eq 1) `
        'phase3b2_physical_p2_v2_endpoint_apply_failed'

    New-NetFirewallRule -Name 'NLL.Phase3B2.PhysicalP2V2.BootstrapBlock' `
        -DisplayName 'NLL Phase3B2 P2-v2 Bootstrap Outbound Block' `
        -Group $extensionFirewallGroup -Direction Outbound -Action Block `
        -Enabled True -Profile Any -Program $bootstrapPath | Out-Null
    $extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup)
    $extensionPrograms = @($extensionRules | Get-NetFirewallApplicationFilter)
    Assert-True ($extensionRules.Count -eq 1 -and
        $extensionRules[0].Direction -eq 'Outbound' -and
        $extensionRules[0].Action -eq 'Block' -and
        $extensionPrograms.Count -eq 1 -and
        $extensionPrograms[0].Program -ceq $bootstrapPath) `
        'phase3b2_physical_p2_v2_firewall_apply_failed'

    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-v2-rollback-plan/v1'
        createdAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        hostsBackupByteLength = (Get-Item $hostsBackupPath).Length
        hostsBackupSha256 = Get-Sha256Hex $hostsBackupPath
        hostsAppliedByteLength = $hostsAppliedLength
        hostsAppliedSha256 = $hostsAppliedSha256
        extensionFirewallGroup = $extensionFirewallGroup
        existingOperatorCacheRollbackActionCode = 'none_not_read_or_modified'
        rollbackActionCode = 'restore_exact_hosts_and_remove_extension_firewall'
    }
    $rollbackPlanPath = Join-Path $EvidenceRoot 'rollback-plan.json'
    Write-AtomicUtf8NoBom $rollbackPlanPath `
        (($rollbackPlan | ConvertTo-Json -Depth 6) + "`n")

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-v2-preparation/v1'
        preparedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        operatorProfileReceiptSha256 =
            Get-Sha256Hex $OperatorProfileReceiptPath
        dedicatedWindowsAccountVerified = $true
        dedicatedLocalLowVerifiedCleanBeforeFirstRun = $true
        existingOperatorNikkeCacheMutationPerformed = $false
        endpointAdmissionCode = 'global_match_returned_by_local_get_server_info'
        endpointAddedCount = 1
        mappedDomainCount = 18
        hostsBeforeSha256 = Get-Sha256Hex $hostsBackupPath
        hostsAppliedByteLength = $hostsAppliedLength
        hostsAppliedSha256 = $hostsAppliedSha256
        baseFirewallRuleCount = 17
        extensionFirewallRuleCount = 1
        extensionFirewallProgram = $bootstrapPath
        externalHead = [string]$transfer.externalHead
        externalTree = [string]$transfer.externalTree
        serverDllByteLength = (Get-Item $serverDllPath).Length
        serverDllSha256 = Get-Sha256Hex $serverDllPath
        requestStageObservationEnabled = $true
        minimumMeasurementSeconds = 600
        dnsObservationPlanned = $true
        wfpObservationPlanned = $true
        primaryInstallModified = $false
        officialLauncherModified = $false
        officialLauncherExecutionStarted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'run_p2_v2_once_and_observe_for_ten_minutes'
    }
    $receiptPath = Join-Path $EvidenceRoot 'preparation.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath `
        (($receipt | ConvertTo-Json -Depth 7) + "`n")
    foreach ($path in @($rollbackPlanPath, $receiptPath)) {
        Copy-Item -LiteralPath $path -Destination $SamsungProtectedRoot
        $copy = Join-Path $SamsungProtectedRoot (Split-Path -Leaf $path)
        Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
            'phase3b2_physical_p2_v2_protected_copy_failed'
    }
    $receipt | ConvertTo-Json -Depth 8
}
catch {
    Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue | Remove-NetFirewallRule `
        -ErrorAction SilentlyContinue
    if ($hostsBackupCreated -and $hostsApplied) {
        [IO.File]::WriteAllBytes($hostsPath,
            [IO.File]::ReadAllBytes($hostsBackupPath))
    }
    throw
}

