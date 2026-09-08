[CmdletBinding()]
param(
    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $algorithm.Dispose() }
}

function Get-FileSha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"

$checkpointReceiptPath = Join-Path $EvidenceRoot "p0-isolated-checkpoint-v3.json"
$priorFailurePath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\compatibility\evidence\phase3b2-wave2\b2363a75-89b5-48fa-9007-c7abb4fee333\attempt-1.controlled-failure.json"
$receiptPath = Join-Path $EvidenceRoot "private-switch-reset-v1.receipt.json"
Assert-True (Test-Path -LiteralPath $checkpointReceiptPath -PathType Leaf) `
    "phase3b2_private_reset_checkpoint_receipt_missing"
Assert-True ((Get-Item -LiteralPath $checkpointReceiptPath).Length -eq 1178 -and
    (Get-FileSha256Hex $checkpointReceiptPath) -ceq
        "cbe57b9a5914a9c8fe3fee31f7140fe8d2f58e1e07ae9c7c7a3260b5c2b5210d") `
    "phase3b2_private_reset_checkpoint_receipt_drift"
Assert-True (Test-Path -LiteralPath $priorFailurePath -PathType Leaf) `
    "phase3b2_private_reset_prior_failure_missing"
Assert-True ((Get-Item -LiteralPath $priorFailurePath).Length -eq 1068 -and
    (Get-FileSha256Hex $priorFailurePath) -ceq
        "21961790f50a669b7a8043cd3a3f3ce1226d36a1992d304302abfde361ca7b85") `
    "phase3b2_private_reset_prior_failure_drift"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_private_reset_receipt_exists"

$vm = Get-VM -Name $VMName -ErrorAction Stop
Assert-True ([string]$vm.Id -ceq "77d6f113-2f74-49e4-8fbf-0dc381232810") `
    "phase3b2_private_reset_vm_identity_mismatch"
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_private_reset_vm_not_running"
$adapters = @(Get-VMNetworkAdapter -VM $vm)
Assert-True ($adapters.Count -eq 1 -and $null -eq $adapters[0].SwitchName) `
    "phase3b2_private_reset_vm_not_disconnected"
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_private_reset_guest_service_enabled"

$snapshots = @(
    Get-VMSnapshot -VM $vm -ErrorAction Stop |
        Where-Object { $_.Name -like "NLL-P3B2-W1-P0-Isolated-v3-*" }
)
Assert-True ($snapshots.Count -eq 1 -and
    [string]$snapshots[0].Id -ceq "d0864b22-6f49-485b-89e8-d67275ac5db9" -and
    $snapshots[0].Name -ceq "NLL-P3B2-W1-P0-Isolated-v3-20260821T193408Z") `
    "phase3b2_private_reset_checkpoint_identity_mismatch"

$existingSwitch = @(Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)
Assert-True ($existingSwitch.Count -le 1) "phase3b2_private_reset_switch_shape_invalid"
if ($existingSwitch.Count -eq 1) {
    Assert-True ($existingSwitch[0].SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private) `
        "phase3b2_private_reset_existing_switch_not_private"
    $existingConnections = @(
        Get-VM | Get-VMNetworkAdapter |
            Where-Object { $_.SwitchName -ceq $SwitchName }
    )
    Assert-True ($existingConnections.Count -eq 0) `
        "phase3b2_private_reset_existing_switch_in_use"
}

Restore-VMSnapshot -VMSnapshot $snapshots[0] -Confirm:$false
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) { break }
    if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Off) {
        Start-VM -VM $vm | Out-Null
    }
    Start-Sleep -Seconds 1
}
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_private_reset_vm_not_running_after_restore"

$restoredAdapters = @(Get-VMNetworkAdapter -VM $vm)
$restoredGuestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($restoredAdapters.Count -eq 1 -and $null -eq $restoredAdapters[0].SwitchName) `
    "phase3b2_private_reset_checkpoint_network_mismatch"
Assert-True ($restoredGuestService.Count -eq 1 -and -not $restoredGuestService[0].Enabled) `
    "phase3b2_private_reset_checkpoint_guest_service_mismatch"

if ($existingSwitch.Count -eq 0) {
    $privateSwitch = New-VMSwitch -Name $SwitchName -SwitchType Private
}
else {
    $privateSwitch = $existingSwitch[0]
}
Assert-True ($privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private) `
    "phase3b2_private_reset_switch_not_private"
Connect-VMNetworkAdapter -VMNetworkAdapter $restoredAdapters[0] -SwitchName $SwitchName

$vmAfter = Get-VM -Name $VMName -ErrorAction Stop
$switchAfter = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapterAfter = @(Get-VMNetworkAdapter -VM $vmAfter)
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vmAfter |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
$connectedAdapters = @(
    Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
Assert-True ($vmAfter.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $switchAfter.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapterAfter.Count -eq 1 -and $adapterAfter[0].SwitchName -ceq $SwitchName -and
    $connectedAdapters.Count -eq 1 -and
    [string]$connectedAdapters[0].VMId -ceq [string]$vmAfter.Id -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_private_reset_postcondition_failed"

$identityText = @(
    "contractId=nll/phase3b2-private-switch-identity/v1"
    "vmId=$($vmAfter.Id)"
    "checkpointId=$($snapshots[0].Id)"
    "switchId=$($switchAfter.Id)"
    "switchType=$($switchAfter.SwitchType)"
    "connectedAdapterCount=$($connectedAdapters.Count)"
) -join "`n"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-private-switch-reset/v1"
    completedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    priorAttemptFailureReceiptSha256 = "21961790f50a669b7a8043cd3a3f3ce1226d36a1992d304302abfde361ca7b85"
    rollbackStatusCode = "snapshot_restored_verified"
    restoredCheckpointReceiptSha256 = "cbe57b9a5914a9c8fe3fee31f7140fe8d2f58e1e07ae9c7c7a3260b5c2b5210d"
    isolatedNetworkIdentitySha256 = Get-Sha256Hex ([Text.UTF8Encoding]::new($false).GetBytes($identityText + "`n"))
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    hostVirtualAdapterPresent = $false
    externalUplinkPresent = $false
    natConfigured = $false
    vmRunning = $true
    guestServiceEnabled = $false
    p0AppliedStateRestored = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json

