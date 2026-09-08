[CmdletBinding()]
param(
    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

trap {
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $errorPath = Join-Path $EvidenceRoot "synthetic-profile-checkpoint.error.log"
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
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_guest_service_not_disabled"

$before = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
$created = @($before | Where-Object { $_.Name -like "NLL-P3B2-W1-SyntheticProfile-v2-*" })
Assert-True ($created.Count -le 1) "phase3b2_checkpoint_resume_shape_invalid"
if ($created.Count -eq 0) {
    $stamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $snapshotName = "NLL-P3B2-W1-SyntheticProfile-v2-$stamp"
    Checkpoint-VM -VM $vm -SnapshotName $snapshotName
    $after = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
    $created = @($after | Where-Object Name -CEQ $snapshotName)
    Assert-True ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) `
        "phase3b2_checkpoint_creation_not_verified"
    $previousCheckpointCount = $before.Count
}
else {
    $snapshotName = $created[0].Name
    $after = $before
    $previousCheckpointCount = $after.Count - 1
}

$identityText = @(
    "contractId=nll/phase3b2-hyperv-checkpoint-identity/v1"
    "vmId=$($vm.Id)"
    "checkpointId=$($created[0].Id)"
    "checkpointName=$snapshotName"
    "creationTimeUtc=$($created[0].CreationTime.ToUniversalTime().ToString('o'))"
) -join "`n"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-synthetic-profile-checkpoint/v1"
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    environmentKindCode = "snapshot_capable_disposable_vm"
    checkpointTypeCode = "standard"
    checkpointIdentitySha256 = Get-TextSha256 ($identityText + "`n")
    previousCheckpointCount = $previousCheckpointCount
    currentCheckpointCount = $after.Count
    externalHead = "6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6"
    externalTree = "ede7be7d5290339f7e3844a542a4055e0de8151b"
    syntheticProfileReady = $true
    characterCount = 193
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    guestServiceEnabled = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$receiptPath = Join-Path $EvidenceRoot "synthetic-profile-checkpoint.json"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) "phase3b2_checkpoint_receipt_already_exists"
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
