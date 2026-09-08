[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [long]$GuestPrivateNetworkReceiptByteLength,

    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$GuestPrivateNetworkReceiptSha256,

    [Parameter(Mandatory)]
    [long]$GuestPrivateP0ReceiptByteLength,

    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$GuestPrivateP0ReceiptSha256,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

trap {
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $errorPath = Join-Path $EvidenceRoot "p0-private-checkpoint-v1.error.log"
    [IO.File]::WriteAllText($errorPath, ($_.Exception.Message + "`n"),
        [Text.UTF8Encoding]::new($false))
    exit 1
}

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
    param([string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $algorithm.Dispose()
    }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True ($GuestPrivateNetworkReceiptByteLength -gt 0 -and
    $GuestPrivateP0ReceiptByteLength -gt 0) "phase3b2_private_checkpoint_guest_receipt_length_invalid"

$resetReceiptPath = Join-Path $EvidenceRoot "private-switch-reset-v1.receipt.json"
$transferReceiptPath = Join-Path $EvidenceRoot "private-network-tool-transfer-v1.receipt.json"
$receiptPath = Join-Path $EvidenceRoot "p0-private-checkpoint-v1.json"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_private_checkpoint_receipt_already_exists"
Assert-True ((Get-Item -LiteralPath $resetReceiptPath).Length -eq 814 -and
    (Get-Sha256Hex $resetReceiptPath) -ceq
        "780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748") `
    "phase3b2_private_checkpoint_reset_receipt_drift"

$transferReceiptItem = Get-Item -LiteralPath $transferReceiptPath
$transferReceiptSha256 = Get-Sha256Hex $transferReceiptPath
$transferReceipt = Get-Content -LiteralPath $transferReceiptPath -Raw | ConvertFrom-Json
Assert-True ($transferReceipt.contractId -ceq "nll/phase3b2-private-network-tool-transfer/v1" -and
    $transferReceipt.hostPrivateSwitchReceiptSha256 -ceq
        "780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748" -and
    [int]$transferReceipt.transferredMemberCount -eq 3 -and
    $transferReceipt.switchTypeCode -ceq "private_vm_only" -and
    [int]$transferReceipt.connectedVmAdapterCount -eq 1 -and
    [bool]$transferReceipt.vmRunning -and
    -not [bool]$transferReceipt.guestServiceEnabled) `
    "phase3b2_private_checkpoint_transfer_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$vmAdapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(
    Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
$managementAdapters = @(
    Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_private_checkpoint_vm_not_running"
Assert-True ($vm.CheckpointType -eq [Microsoft.HyperV.PowerShell.CheckpointType]::Standard -and
    -not $vm.AutomaticCheckpointsEnabled) "phase3b2_private_checkpoint_configuration_mismatch"
Assert-True ($privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $vmAdapters.Count -eq 1 -and $vmAdapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0) "phase3b2_private_checkpoint_isolation_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_private_checkpoint_guest_service_enabled"

$before = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
$created = @($before | Where-Object { $_.Name -like "NLL-P3B2-W1-P0-Private-v1-*" })
Assert-True ($created.Count -le 1) "phase3b2_private_checkpoint_resume_shape_invalid"
$checkpointCreationResumed = $created.Count -eq 1
if ($created.Count -eq 0) {
    $stamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $snapshotName = "NLL-P3B2-W1-P0-Private-v1-$stamp"
    Checkpoint-VM -VM $vm -SnapshotName $snapshotName
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $after = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
        $created = @($after | Where-Object Name -CEQ $snapshotName)
        if ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert-True ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) `
        "phase3b2_private_checkpoint_creation_not_verified"
    $previousCheckpointCount = $before.Count
}
else {
    $snapshotName = $created[0].Name
    $after = $before
    $previousCheckpointCount = $after.Count - 1
}

$vmAfter = Get-VM -Name $VMName -ErrorAction Stop
$vmAdaptersAfter = @(Get-VMNetworkAdapter -VM $vmAfter)
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vmAfter |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($vmAfter.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $vmAdaptersAfter.Count -eq 1 -and $vmAdaptersAfter[0].SwitchName -ceq $SwitchName -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_private_checkpoint_postcondition_failed"

$identityText = @(
    "contractId=nll/phase3b2-hyperv-private-checkpoint-identity/v1"
    "vmId=$($vmAfter.Id)"
    "checkpointId=$($created[0].Id)"
    "checkpointName=$snapshotName"
    "creationTimeUtc=$($created[0].CreationTime.ToUniversalTime().ToString('o'))"
    "networkModeCode=private_vm_only_no_gateway"
    "switchName=$SwitchName"
    "switchType=Private"
    "hostPrivateSwitchReceiptSha256=780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748"
    "guestPrivateNetworkReceiptByteLength=$GuestPrivateNetworkReceiptByteLength"
    "guestPrivateNetworkReceiptSha256=$GuestPrivateNetworkReceiptSha256"
    "guestPrivateP0ReceiptByteLength=$GuestPrivateP0ReceiptByteLength"
    "guestPrivateP0ReceiptSha256=$GuestPrivateP0ReceiptSha256"
    "externalHead=519c3db51ec24ca19307e93e85acde7885928a72"
    "externalTree=b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    "externalBuildManifestSha256=ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    "p0AppliedManifestSha256=582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46"
) -join "`n"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-checkpoint/v1"
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    environmentKindCode = "snapshot_capable_disposable_vm"
    checkpointTypeCode = "standard"
    checkpointIdentitySha256 = Get-TextSha256 ($identityText + "`n")
    checkpointCreationResumed = $checkpointCreationResumed
    previousCheckpointCount = $previousCheckpointCount
    currentCheckpointCount = $after.Count
    clientBuild = "150.6.9"
    externalHead = "519c3db51ec24ca19307e93e85acde7885928a72"
    externalTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    externalBuildManifestSha256 = "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    localOnlyHttp3Enabled = $false
    localOnlyAssetCachePathLoggingEnabled = $false
    backupManifestSha256 = "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a"
    appliedManifestSha256 = "582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46"
    hostPrivateSwitchReceiptSha256 =
        "780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748"
    hostToolTransferReceiptByteLength = $transferReceiptItem.Length
    hostToolTransferReceiptSha256 = $transferReceiptSha256
    guestPrivateNetworkReceiptByteLength = $GuestPrivateNetworkReceiptByteLength
    guestPrivateNetworkReceiptSha256 = $GuestPrivateNetworkReceiptSha256
    guestPrivateP0ReceiptByteLength = $GuestPrivateP0ReceiptByteLength
    guestPrivateP0ReceiptSha256 = $GuestPrivateP0ReceiptSha256
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    hostVirtualAdapterPresent = $false
    mappedDomainCount = 17
    firewallRuleCount = 16
    guestServiceEnabled = $false
    credentialBearingGuestCopyPresent = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
