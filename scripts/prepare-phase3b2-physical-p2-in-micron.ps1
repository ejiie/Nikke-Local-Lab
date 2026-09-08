[CmdletBinding()]
param(
    [string]$RuntimeRoot = 'C:\NLL\Runtime\PhysicalBootstrap-v1',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-preparation-v1',
    [string]$TransferReceiptPath =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v1\deployment.receipt.json',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\Preparation'
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

function Get-RootCaCount {
    param([string]$CaPath)
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $CaPath)
    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        @($store.Certificates | Where-Object {
            $_.Thumbprint -ceq $certificate.Thumbprint
        }).Count
    }
    finally { $store.Close() }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p2_prepare_requires_administrator'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK') `
    'phase3b2_physical_p2_prepare_must_run_from_micron'
$samsungDisk = Get-Partition -DriveLetter E | Get-Disk
Assert-True ($samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB') `
    'phase3b2_physical_p2_samsung_protected_volume_missing'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p2_prepare_runtime_not_cold'
Assert-True (-not (Test-Path -LiteralPath $EvidenceRoot) -and
    -not (Test-Path -LiteralPath $SamsungProtectedRoot)) `
    'phase3b2_physical_p2_prepare_evidence_already_exists'

$p0WorkflowPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p0-v1\workflow.receipt.json'
$p0VerificationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p0-v1\post-apply-verification.receipt.json'
$p1WorkflowPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p1-server-only-v1\workflow.receipt.json'
$p1VerificationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p1-server-only-v1\post-measurement-verification.receipt.json'
Assert-True ((Test-PathDigest $p0WorkflowPath 814L `
            '879fe329353f477b8dec3e4216cd5d397f7a1de0c2284a301b86f19f8b52518d') -and
    (Test-PathDigest $p0VerificationPath 1617L `
            '3c966bbb23a19e9e8251172eddf498c7afe541bb13f50df64fd7d8e570a778c5') -and
    (Test-PathDigest $p1WorkflowPath 1287L `
            '7491036d9fbd5ddc7e0bc7067ebb85ad10f5a3b0da32284c228d9233933ba17b') -and
    (Test-PathDigest $p1VerificationPath 1208L `
            '2b340350603596fc851e05f5a29f32836cbe83cd8acbea78e1c00193129583ef')) `
    'phase3b2_physical_p2_prior_receipt_pin_mismatch'

$p0 = Get-Content -LiteralPath $p0VerificationPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$p1 = Get-Content -LiteralPath $p1WorkflowPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($p0.p0AppliedVerified -and $p1.physicalBoundaryVerified -and
    $p1.serverOnlyMeasurementVerified -and
    $p1.controlledSyntheticLoginAccepted -and
    $p1.sqliteCredentialBindingVerified -and
    $p1.serverStoppedAfterMeasurement -and $p1.databaseRestored -and
    $p1.sqliteRuntimeRemoved -and $p1.p0StillApplied -and
    -not $p1.clientExecutionStarted) `
    'phase3b2_physical_p2_prior_state_not_admitted'

Assert-True (Test-Path -LiteralPath $TransferReceiptPath -PathType Leaf) `
    'phase3b2_physical_p2_transfer_receipt_missing'
$transfer = Get-Content -LiteralPath $TransferReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($transfer.contractId -ceq
        'nll/phase3b2-physical-p2-offline-deployment/v1' -and
    $transfer.targetDisk -ceq 'Micron_2200_MTFDHBA512TCK' -and
    $transfer.targetOsOfflineDuringDeployment -and
    $transfer.dotnetSdkVersion -ceq '10.0.400' -and
    -not $transfer.serverExecutionStarted -and
    -not $transfer.clientExecutionStarted) `
    'phase3b2_physical_p2_transfer_receipt_invalid'
$toolRoot = 'C:\NLL\Tools'
foreach ($tool in @($transfer.tools)) {
    $toolPath = Join-Path $toolRoot ([string]$tool.name)
    Assert-True (Test-PathDigest $toolPath ([long]$tool.byteLength) `
        ([string]$tool.sha256)) `
        'phase3b2_physical_p2_transferred_tool_pin_mismatch'
}

$artifactRoot = Join-Path $RuntimeRoot 'artifact'
$artifactManifestPath = Join-Path $RuntimeRoot 'evidence\artifact.manifest.tsv'
Assert-True (Test-PathDigest $artifactManifestPath `
        ([long]$transfer.artifactManifestByteLength) `
        ([string]$transfer.artifactManifestSha256)) `
    'phase3b2_physical_p2_artifact_manifest_pin_mismatch'
$manifestRows = @(Get-Content -LiteralPath $artifactManifestPath -Encoding UTF8 |
    Where-Object { $_ } | ForEach-Object {
        $parts = $_ -split "`t", 3
        Assert-True ($parts.Count -eq 3 -and
            $parts[0] -notmatch '(^|/)\.\.(/|$)' -and
            $parts[0] -notmatch '^[A-Za-z]:') `
            'phase3b2_physical_p2_artifact_manifest_row_invalid'
        $path = Join-Path $artifactRoot ($parts[0].Replace('/', '\'))
        Assert-True (Test-PathDigest $path ([long]$parts[1]) $parts[2]) `
            'phase3b2_physical_p2_artifact_member_mismatch'
        [pscustomobject]@{ Path = $path; ByteLength = [long]$parts[1]; Sha256 = $parts[2] }
    })
Assert-True ($manifestRows.Count -eq 5) `
    'phase3b2_physical_p2_artifact_member_count_invalid'
$serverDllPath =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
Assert-True ($transfer.revisionCode -ceq
        'pid_pinned_observation_and_token_log_safety' -and
    $transfer.externalHead -ceq
        '1b2434c3c6ab4a7400177f4287aa451bd2aa5745' -and
    $transfer.externalTree -ceq
        '519fbe3c6c010a66602ca4d3837fde39fdabc487' -and
    (Test-PathDigest $serverDllPath `
        ([long]$transfer.appliedServerDllByteLength) `
        ([string]$transfer.appliedServerDllSha256))) `
    'phase3b2_physical_p2_server_log_safety_pin_mismatch'
$bootstrapPath = Join-Path $artifactRoot `
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
Assert-True (Test-PathDigest $bootstrapPath `
        ([long]$transfer.physicalBootstrapExeByteLength) `
        ([string]$transfer.physicalBootstrapExeSha256)) `
    'phase3b2_physical_p2_bootstrap_pin_mismatch'

$clientRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical'
$clientPath = Join-Path $clientRoot 'NIKKE\game\nikke.exe'
$certificatePath = Join-Path $clientRoot `
    'NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem'
$sodiumPath = Join-Path $clientRoot `
    'NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'
Assert-True ((Test-PathDigest $clientPath 794152L `
            '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30') -and
    (Test-PathDigest $certificatePath 213860L `
            '1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9') -and
    (Test-PathDigest $sodiumPath 358400L `
            '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662')) `
    'phase3b2_physical_p2_clone_p0_state_invalid'

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$caPath = 'C:\NLL\EpinelPS\ServerSelector\myCA.cer'
Assert-True ((Test-PathDigest $hostsPath 1690L `
            'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
    (Test-PathDigest $caPath 1266L `
            '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda') -and
    (Get-RootCaCount $caPath) -eq 1) `
    'phase3b2_physical_p2_hosts_or_root_ca_state_invalid'

$baseFirewallGroup = 'NLL Phase3B2 Physical Isolation'
$extensionFirewallGroup = 'NLL Phase3B2 Physical Bootstrap Extension'
$baseRules = @(Get-NetFirewallRule -Group $baseFirewallGroup `
    -ErrorAction SilentlyContinue)
Assert-True ($baseRules.Count -eq 17 -and
    @($baseRules | Where-Object {
            $_.Direction -ne 'Outbound' -or $_.Action -ne 'Block' -or
            $_.Enabled -ne 'True'
        }).Count -eq 0) 'phase3b2_physical_p2_base_firewall_state_invalid'
$serverPath =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.exe'
$localBootstrapPath =
    'C:\NLL\Runtime\LocalBootstrap-v1\artifact\NikkeLocalLab.Phase3B2.LocalBootstrap.exe'
$relativePrograms = @(
    'Launcher\Assistant.exe',
    'Launcher\common_apps\dependency_shared(999998)\vc2015-2022x64\VC_redist.x64.exe',
    'Launcher\intl_service\intl_service.exe',
    'Launcher\intl_service\INTLWebViewHelper.exe',
    'Launcher\intl_service\tbs_browser.exe',
    'Launcher\nikke_launcher.exe',
    'Launcher\startup_runner.exe',
    'Launcher\uninst.exe',
    'Launcher\VersionService.exe',
    'NIKKE\game\AntiCheatExpert\ACE-Service64.exe',
    'NIKKE\game\AntiCheatExpert\ACE-Setup64.exe',
    'NIKKE\game\nikke_Data\Plugins\x86_64\INTLWebViewHelper.exe',
    'NIKKE\game\nikke.exe',
    'NIKKE\game\TQM64\TQMCenter_64.exe',
    'NIKKE\game\UnityCrashHandler64.exe'
)
$expectedPrograms = @(
    @($relativePrograms | ForEach-Object { Join-Path $clientRoot $_ }) +
        @($serverPath, $localBootstrapPath) |
        ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique
)
$actualPrograms = @($baseRules | ForEach-Object {
    (Get-NetFirewallApplicationFilter `
        -AssociatedNetFirewallRule $_).Program
} | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
Assert-True ($expectedPrograms.Count -eq 17 -and
    $actualPrograms.Count -eq 17) `
    'phase3b2_physical_p2_base_firewall_program_count_invalid'
foreach ($program in $expectedPrograms) {
    Assert-True (@($actualPrograms | Where-Object {
        $_.Equals($program, [StringComparison]::OrdinalIgnoreCase)
    }).Count -eq 1) 'phase3b2_physical_p2_base_firewall_program_invalid'
}
Assert-True (@(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p2_extension_firewall_already_present'

New-Item -ItemType Directory -Path $EvidenceRoot, $SamsungProtectedRoot |
    Out-Null
$rollbackPlanPath = Join-Path $EvidenceRoot 'rollback-plan.json'
$rollbackPlan = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-bootstrap-extension-rollback-plan/v1'
    createdAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    firewallGroup = $extensionFirewallGroup
    expectedPreApplyRuleCount = 0
    rollbackActionCode = 'remove_exact_extension_firewall_group'
    baseP0RollbackTool = 'C:\NLL\Tools\rollback-phase3b2-physical-p0-in-micron.ps1'
    primaryInstallMutationPlanned = $false
    officialLauncherMutationPlanned = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-AtomicUtf8NoBom $rollbackPlanPath `
    (($rollbackPlan | ConvertTo-Json -Depth 6) + "`n")

$ruleName = 'NLL Phase3B2 Physical Bootstrap Outbound Block'
try {
    New-NetFirewallRule -Name 'NLL.Phase3B2.PhysicalBootstrap.OutboundBlock' `
        -DisplayName $ruleName -Group $extensionFirewallGroup `
        -Direction Outbound -Action Block -Enabled True -Profile Any `
        -Program $bootstrapPath | Out-Null
    $extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup)
    $programFilters = @($extensionRules | Get-NetFirewallApplicationFilter)
    Assert-True ($extensionRules.Count -eq 1 -and
        $extensionRules[0].Direction -eq 'Outbound' -and
        $extensionRules[0].Action -eq 'Block' -and
        $extensionRules[0].Enabled -eq 'True' -and
        $programFilters.Count -eq 1 -and
        $programFilters[0].Program -ceq $bootstrapPath) `
        'phase3b2_physical_p2_extension_firewall_apply_invalid'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-preparation/v1'
        preparedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
        p1AssessmentUid = '0e71964a-f07b-49e1-81de-78439e4b5b9e'
        p0WorkflowSha256 = Get-Sha256Hex $p0WorkflowPath
        p1WorkflowSha256 = Get-Sha256Hex $p1WorkflowPath
        deploymentReceiptByteLength = (Get-Item $TransferReceiptPath).Length
        deploymentReceiptSha256 = Get-Sha256Hex $TransferReceiptPath
        artifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
        physicalBootstrapExeByteLength = (Get-Item $bootstrapPath).Length
        physicalBootstrapExeSha256 = Get-Sha256Hex $bootstrapPath
        externalHead = [string]$transfer.externalHead
        externalTree = [string]$transfer.externalTree
        serverDllByteLength = (Get-Item $serverDllPath).Length
        serverDllSha256 = Get-Sha256Hex $serverDllPath
        clientProcessObservationModeCode =
            'bootstrap_process_start_returned_pid'
        clientBuild = '150.6.9'
        clientExeSha256 = Get-Sha256Hex $clientPath
        baseFirewallRuleCount = $baseRules.Count
        extensionFirewallRuleCount = 1
        extensionFirewallProgram = $bootstrapPath
        rollbackPlanByteLength = (Get-Item $rollbackPlanPath).Length
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        primaryInstallModified = $false
        officialLauncherModified = $false
        officialLauncherExecutionStarted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'start_physical_p2_server_and_bootstrap_once'
    }
    $receiptPath = Join-Path $EvidenceRoot 'preparation.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath `
        (($receipt | ConvertTo-Json -Depth 7) + "`n")
    foreach ($path in @($rollbackPlanPath, $receiptPath)) {
        Copy-Item -LiteralPath $path -Destination $SamsungProtectedRoot
        $copy = Join-Path $SamsungProtectedRoot (Split-Path -Leaf $path)
        Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
            'phase3b2_physical_p2_preparation_protected_copy_failed'
    }
    $receipt | ConvertTo-Json -Depth 8
}
catch {
    Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue | Remove-NetFirewallRule `
        -ErrorAction SilentlyContinue
    throw
}
