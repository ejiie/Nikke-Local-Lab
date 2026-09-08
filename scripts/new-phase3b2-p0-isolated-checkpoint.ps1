[CmdletBinding()]
param(
    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

trap {
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $errorPath = Join-Path $EvidenceRoot "p0-isolated-checkpoint-v3.error.log"
    [IO.File]::WriteAllText($errorPath, ($_.Exception.Message + "`n"), [Text.UTF8Encoding]::new($false))
    exit 1
}

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
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

$vm = Get-VM -Name $VMName -ErrorAction Stop
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) "phase3b2_vm_not_running"
Assert-True ($vm.CheckpointType -eq [Microsoft.HyperV.PowerShell.CheckpointType]::Standard) `
    "phase3b2_checkpoint_type_mismatch"
Assert-True (-not $vm.AutomaticCheckpointsEnabled) "phase3b2_automatic_checkpoints_enabled"
$networkAdapters = @(Get-VMNetworkAdapter -VM $vm)
Assert-True ($networkAdapters.Count -eq 1 -and $null -eq $networkAdapters[0].SwitchName) `
    "phase3b2_vm_network_not_isolated"
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_guest_service_not_disabled"

$before = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
$created = @($before | Where-Object { $_.Name -like "NLL-P3B2-W1-P0-Isolated-v3-*" })
Assert-True ($created.Count -le 1) "phase3b2_p0_checkpoint_resume_shape_invalid"
$checkpointCreationResumed = $created.Count -eq 1
if ($created.Count -eq 0) {
    $stamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $snapshotName = "NLL-P3B2-W1-P0-Isolated-v3-$stamp"
    Checkpoint-VM -VM $vm -SnapshotName $snapshotName
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $after = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
        $created = @($after | Where-Object Name -CEQ $snapshotName)
        if ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert-True ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) `
        "phase3b2_p0_checkpoint_creation_not_verified"
    $previousCheckpointCount = $before.Count
}
else {
    $snapshotName = $created[0].Name
    $after = $before
    $previousCheckpointCount = $after.Count - 1
}

$vmAfter = Get-VM -Name $VMName -ErrorAction Stop
$networkAdaptersAfter = @(Get-VMNetworkAdapter -VM $vmAfter)
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vmAfter |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($vmAfter.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_vm_state_changed_by_checkpoint"
Assert-True ($networkAdaptersAfter.Count -eq 1 -and $null -eq $networkAdaptersAfter[0].SwitchName) `
    "phase3b2_vm_network_reconnected_by_checkpoint"
Assert-True ($guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_guest_service_enabled_by_checkpoint"

$identityText = @(
    "contractId=nll/phase3b2-hyperv-checkpoint-identity/v1"
    "vmId=$($vmAfter.Id)"
    "checkpointId=$($created[0].Id)"
    "checkpointName=$snapshotName"
    "creationTimeUtc=$($created[0].CreationTime.ToUniversalTime().ToString('o'))"
    "externalHead=519c3db51ec24ca19307e93e85acde7885928a72"
    "externalTree=b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    "externalBuildManifestSha256=ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    "p0AppliedManifestSha256=582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46"
) -join "`n"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-isolated-checkpoint/v3"
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
    mappedDomainCount = 17
    firewallRuleCount = 16
    connectedSwitchCount = 0
    guestServiceEnabled = $false
    credentialBearingGuestCopyPresent = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$receiptPath = Join-Path $EvidenceRoot "p0-isolated-checkpoint-v3.json"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) "phase3b2_p0_checkpoint_receipt_already_exists"
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
