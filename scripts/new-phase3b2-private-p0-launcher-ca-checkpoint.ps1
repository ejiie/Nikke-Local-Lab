[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [long]$GuestP0V2ReceiptByteLength,

    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$GuestP0V2ReceiptSha256,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

trap {
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $errorPath = Join-Path $EvidenceRoot `
        "p0-private-launcher-ca-checkpoint-v1.error.log"
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
        return (($algorithm.ComputeHash($bytes) |
                ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $algorithm.Dispose()
    }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True ($GuestP0V2ReceiptByteLength -gt 0) `
    "phase3b2_p0_launcher_ca_checkpoint_guest_receipt_length_invalid"

$restoreReceiptPath = Join-Path $EvidenceRoot `
    "private-reference-failure-restore-v1.receipt.json"
$toolTransferReceiptPath = Join-Path $EvidenceRoot `
    "launcher-ca-verification-tool-transfer-v1.receipt.json"
$receiptPath = Join-Path $EvidenceRoot `
    "p0-private-launcher-ca-checkpoint-v1.json"
Assert-True ((Get-Item -LiteralPath $restoreReceiptPath).Length -eq 1159 -and
    (Get-Sha256Hex $restoreReceiptPath) -ceq
        "6c7c4f3796bd3a64efd1d577dd7595bb61dbb459f60797ada1e519cb954bdf2a") `
    "phase3b2_p0_launcher_ca_checkpoint_restore_receipt_drift"
Assert-True ((Get-Item -LiteralPath $toolTransferReceiptPath).Length -eq 1456 -and
    (Get-Sha256Hex $toolTransferReceiptPath) -ceq
        "f08df38a5dbf77d30347f19b65d95a6e7395dd5e93c0061457f33d270c3c7a41") `
    "phase3b2_p0_launcher_ca_checkpoint_tool_transfer_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_p0_launcher_ca_checkpoint_receipt_exists"

$vm = Get-VM -Name $VMName -ErrorAction Stop
Assert-True ([string]$vm.Id -ceq "77d6f113-2f74-49e4-8fbf-0dc381232810") `
    "phase3b2_p0_launcher_ca_checkpoint_vm_identity_mismatch"
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(
    Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
$managementAdapters = @(
    Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $vm.CheckpointType -eq [Microsoft.HyperV.PowerShell.CheckpointType]::Standard -and
    -not $vm.AutomaticCheckpointsEnabled -and
    $privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0) `
    "phase3b2_p0_launcher_ca_checkpoint_environment_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_p0_launcher_ca_checkpoint_guest_service_enabled"

$before = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
$created = @(
    $before | Where-Object { $_.Name -like "NLL-P3B2-W1-P0-Private-LauncherCA-v1-*" }
)
Assert-True ($created.Count -le 1) `
    "phase3b2_p0_launcher_ca_checkpoint_resume_shape_invalid"
$checkpointCreationResumed = $created.Count -eq 1
if ($created.Count -eq 0) {
    $stamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $snapshotName = "NLL-P3B2-W1-P0-Private-LauncherCA-v1-$stamp"
    Checkpoint-VM -VM $vm -SnapshotName $snapshotName
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $after = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
        $created = @($after | Where-Object Name -CEQ $snapshotName)
        if ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert-True ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) `
        "phase3b2_p0_launcher_ca_checkpoint_creation_not_verified"
    $previousCheckpointCount = $before.Count
}
else {
    $snapshotName = $created[0].Name
    $after = $before
    $previousCheckpointCount = $after.Count - 1
}

$vmAfter = Get-VM -Name $VMName -ErrorAction Stop
$adaptersAfter = @(Get-VMNetworkAdapter -VM $vmAfter)
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vmAfter |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($vmAfter.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $adaptersAfter.Count -eq 1 -and $adaptersAfter[0].SwitchName -ceq $SwitchName -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_p0_launcher_ca_checkpoint_postcondition_failed"

$identityText = @(
    "contractId=nll/phase3b2-hyperv-private-launcher-ca-checkpoint-identity/v1"
    "vmId=$($vmAfter.Id)"
    "checkpointId=$($created[0].Id)"
    "checkpointName=$snapshotName"
    "creationTimeUtc=$($created[0].CreationTime.ToUniversalTime().ToString('o'))"
    "networkModeCode=private_vm_only_no_gateway"
    "switchName=$SwitchName"
    "switchType=Private"
    "guestP0V2ReceiptByteLength=$GuestP0V2ReceiptByteLength"
    "guestP0V2ReceiptSha256=$GuestP0V2ReceiptSha256"
    "launcherCertificateAppliedSha256=6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c"
    "compositeRollbackScriptSha256=83df6aac274fe78960032eead2d1f2da418d0d2969ee57d430132c0c5b248586"
    "externalHead=519c3db51ec24ca19307e93e85acde7885928a72"
    "externalTree=b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    "externalBuildManifestSha256=ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
) -join "`n"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-launcher-ca-checkpoint/v1"
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
    externalBuildManifestSha256 =
        "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    guestP0V2ReceiptByteLength = $GuestP0V2ReceiptByteLength
    guestP0V2ReceiptSha256 = $GuestP0V2ReceiptSha256
    launcherCertificateOriginalSha256 =
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65"
    launcherCertificateAppliedSha256 =
        "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c"
    clientCertificateBundleMemberCount = 2
    baseBackupManifestSha256 =
        "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a"
    baseAppliedManifestSha256 =
        "582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46"
    launcherBackupManifestSha256 =
        "6078cccf2e79fdf89b39a464f9b22d604057a66a300734eb81141c95cabd7d93"
    launcherAppliedManifestSha256 =
        "dfcd10d06f09c3348e5578ceb3ac4328ca3e6d2cb70e35bd0dd662f42c9cc14d"
    compositeRollbackScriptSha256 =
        "83df6aac274fe78960032eead2d1f2da418d0d2969ee57d430132c0c5b248586"
    restoredFailureReceiptSha256 =
        "6c7c4f3796bd3a64efd1d577dd7595bb61dbb459f60797ada1e519cb954bdf2a"
    verificationToolTransferReceiptSha256 =
        "f08df38a5dbf77d30347f19b65d95a6e7395dd5e93c0061457f33d270c3c7a41"
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    hostVirtualAdapterPresent = $false
    externalUplinkPresent = $false
    natConfigured = $false
    guestServiceEnabled = $false
    credentialBearingGuestCopyPresent = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
