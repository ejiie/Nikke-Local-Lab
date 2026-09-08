[CmdletBinding()]
param(
    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence",
    [string]$FailureReceiptPath =
        "C:\Users\ccccc\AppData\Local\NikkeLocalLab\compatibility\evidence\phase3b2-wave1-hyperv\5478649b-327f-4f38-a0b8-84862db1d1b2\reference-run-failure.receipt.json"
)

$ErrorActionPreference = "Stop"

trap {
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $errorPath = Join-Path $EvidenceRoot "private-reference-failure-restore-v1.error.log"
    [IO.File]::WriteAllText($errorPath, ($_.Exception.Message + "`n"),
        [Text.UTF8Encoding]::new($false))
    exit 1
}

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-FileSha256Hex {
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

$checkpointReceiptPath = Join-Path $EvidenceRoot "p0-private-checkpoint-v1.json"
$restoreReceiptPath = Join-Path $EvidenceRoot "private-reference-failure-restore-v1.receipt.json"
Assert-True (Test-Path -LiteralPath $FailureReceiptPath -PathType Leaf) `
    "phase3b2_private_restore_failure_receipt_missing"
Assert-True ((Get-Item -LiteralPath $FailureReceiptPath).Length -eq 2483 -and
    (Get-FileSha256Hex $FailureReceiptPath) -ceq
        "9a3c0e3388f4dec07b8a3f90c61f28343538f44a15b798bd9b7ddf4216db4a94") `
    "phase3b2_private_restore_failure_receipt_drift"
Assert-True (Test-Path -LiteralPath $checkpointReceiptPath -PathType Leaf) `
    "phase3b2_private_restore_checkpoint_receipt_missing"
Assert-True ((Get-Item -LiteralPath $checkpointReceiptPath).Length -eq 1967 -and
    (Get-FileSha256Hex $checkpointReceiptPath) -ceq
        "7efbe1fee480ab95412439c2a3b7f80ab0996511c375ca6eadda7746e50aedce") `
    "phase3b2_private_restore_checkpoint_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $restoreReceiptPath)) `
    "phase3b2_private_restore_receipt_exists"

$failureReceipt = Get-Content -LiteralPath $FailureReceiptPath -Raw | ConvertFrom-Json
$checkpointReceipt = Get-Content -LiteralPath $checkpointReceiptPath -Raw | ConvertFrom-Json
Assert-True ($failureReceipt.contractId -ceq
        "nll/phase3b2-private-reference-run-failure/v1" -and
    $failureReceipt.assessmentUid -ceq "5478649b-327f-4f38-a0b8-84862db1d1b2" -and
    $failureReceipt.reasonCode -ceq "launcher_certificate_bundle_not_patched" -and
    -not [bool]$failureReceipt.retryPerformed -and
    -not [bool]$failureReceipt.clientExecutionStarted -and
    -not [bool]$failureReceipt.officialIdentityPersisted -and
    -not [bool]$failureReceipt.officialCredentialPersisted -and
    $failureReceipt.nextStepCode -ceq "restore_private_p0_patch_launcher_ca_reseal") `
    "phase3b2_private_restore_failure_receipt_invalid"
Assert-True ($checkpointReceipt.contractId -ceq
        "nll/phase3b2-p0-private-checkpoint/v1" -and
    $checkpointReceipt.environmentKindCode -ceq "snapshot_capable_disposable_vm" -and
    $checkpointReceipt.checkpointTypeCode -ceq "standard" -and
    $checkpointReceipt.networkModeCode -ceq "private_vm_only_no_gateway" -and
    $checkpointReceipt.switchTypeCode -ceq "private_vm_only" -and
    [int]$checkpointReceipt.connectedVmAdapterCount -eq 1 -and
    -not [bool]$checkpointReceipt.hostVirtualAdapterPresent -and
    -not [bool]$checkpointReceipt.guestServiceEnabled -and
    -not [bool]$checkpointReceipt.serverExecutionStarted -and
    -not [bool]$checkpointReceipt.clientExecutionStarted) `
    "phase3b2_private_restore_checkpoint_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
Assert-True ([string]$vm.Id -ceq "77d6f113-2f74-49e4-8fbf-0dc381232810") `
    "phase3b2_private_restore_vm_identity_mismatch"
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_private_restore_vm_not_running"
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
Assert-True ($privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $vmAdapters.Count -eq 1 -and $vmAdapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0) "phase3b2_private_restore_network_precondition_failed"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_private_restore_guest_service_enabled"

$snapshots = @(
    Get-VMSnapshot -VM $vm -ErrorAction Stop |
        Where-Object { $_.Name -like "NLL-P3B2-W1-P0-Private-v1-*" }
)
Assert-True ($snapshots.Count -eq 1) "phase3b2_private_restore_checkpoint_shape_invalid"
$snapshot = $snapshots[0]
$identityText = @(
    "contractId=nll/phase3b2-hyperv-private-checkpoint-identity/v1"
    "vmId=$($vm.Id)"
    "checkpointId=$($snapshot.Id)"
    "checkpointName=$($snapshot.Name)"
    "creationTimeUtc=$($snapshot.CreationTime.ToUniversalTime().ToString('o'))"
    "networkModeCode=private_vm_only_no_gateway"
    "switchName=$SwitchName"
    "switchType=Private"
    "hostPrivateSwitchReceiptSha256=780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748"
    "guestPrivateNetworkReceiptByteLength=$($checkpointReceipt.guestPrivateNetworkReceiptByteLength)"
    "guestPrivateNetworkReceiptSha256=$($checkpointReceipt.guestPrivateNetworkReceiptSha256)"
    "guestPrivateP0ReceiptByteLength=$($checkpointReceipt.guestPrivateP0ReceiptByteLength)"
    "guestPrivateP0ReceiptSha256=$($checkpointReceipt.guestPrivateP0ReceiptSha256)"
    "externalHead=519c3db51ec24ca19307e93e85acde7885928a72"
    "externalTree=b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    "externalBuildManifestSha256=ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    "p0AppliedManifestSha256=582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46"
) -join "`n"
Assert-True ((Get-TextSha256 ($identityText + "`n")) -ceq
    [string]$checkpointReceipt.checkpointIdentitySha256) `
    "phase3b2_private_restore_checkpoint_identity_mismatch"

Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) { break }
    if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Off) {
        Start-VM -VM $vm | Out-Null
    }
    Start-Sleep -Seconds 1
}
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_private_restore_vm_not_running_after_restore"

$switchAfter = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapterAfter = @(Get-VMNetworkAdapter -VM $vm)
$switchMembersAfter = @(
    Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
$managementAdaptersAfter = @(
    Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) }
)
$snapshotAfter = @(
    Get-VMSnapshot -VM $vm -ErrorAction Stop |
        Where-Object { [string]$_.Id -ceq [string]$snapshot.Id }
)
Assert-True ($switchAfter.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapterAfter.Count -eq 1 -and $adapterAfter[0].SwitchName -ceq $SwitchName -and
    $switchMembersAfter.Count -eq 1 -and
    [string]$switchMembersAfter[0].VMId -ceq [string]$vm.Id -and
    $managementAdaptersAfter.Count -eq 0 -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled -and
    $snapshotAfter.Count -eq 1) "phase3b2_private_restore_postcondition_failed"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-private-reference-failure-restore/v1"
    restoredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedAssessmentUid = "5478649b-327f-4f38-a0b8-84862db1d1b2"
    failureReceiptByteLength = 2483
    failureReceiptSha256 =
        "9a3c0e3388f4dec07b8a3f90c61f28343538f44a15b798bd9b7ddf4216db4a94"
    restoredCheckpointReceiptByteLength = 1967
    restoredCheckpointReceiptSha256 =
        "7efbe1fee480ab95412439c2a3b7f80ab0996511c375ca6eadda7746e50aedce"
    restoredCheckpointIdentitySha256 = [string]$checkpointReceipt.checkpointIdentitySha256
    rollbackStatusCode = "private_p0_checkpoint_restored_verified"
    checkpointPreserved = $true
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    hostVirtualAdapterPresent = $false
    externalUplinkPresent = $false
    natConfigured = $false
    vmRunning = $true
    guestServiceEnabled = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = "patch_launcher_ca_and_create_new_assessment"
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[IO.File]::WriteAllText($restoreReceiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
