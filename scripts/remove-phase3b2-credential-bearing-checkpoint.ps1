[CmdletBinding()]
param(
    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
$vm = Get-VM -Name $VMName -ErrorAction Stop
$before = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
$target = @($before | Where-Object { $_.Name -like "NLL-P3B2-W1-SyntheticProfile-v2-*" })
Assert-True ($target.Count -eq 1) "phase3b2_credential_bearing_checkpoint_shape_invalid"
Assert-True ($before.Count -eq 2) "phase3b2_checkpoint_inventory_unexpected"

Remove-VMSnapshot -VMSnapshot $target[0]
$after = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
Assert-True ($after.Count -eq 1 -and
    @($after | Where-Object { $_.Name -like "NLL-P3B2-W1-SyntheticProfile-v2-*" }).Count -eq 0) `
    "phase3b2_credential_bearing_checkpoint_removal_not_verified"

$receiptPath = Join-Path $EvidenceRoot "synthetic-profile-checkpoint.json"
$invalidatedPath = Join-Path $EvidenceRoot "synthetic-profile-checkpoint.invalidated.json"
Assert-True (Test-Path -LiteralPath $receiptPath -PathType Leaf) "phase3b2_checkpoint_receipt_missing"
Assert-True (-not (Test-Path -LiteralPath $invalidatedPath)) "phase3b2_invalidated_receipt_already_exists"
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
$invalidated = [ordered]@{
    contractId = "nll/phase3b2-checkpoint-invalidation/v1"
    invalidatedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    invalidationReasonCode = "credential_bearing_staging_copy_present"
    invalidatedCheckpointIdentitySha256 = [string]$receipt.checkpointIdentitySha256
    checkpointRemoved = $true
    remainingCheckpointCount = $after.Count
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($invalidatedPath, (($invalidated | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
Remove-Item -LiteralPath $receiptPath -Force
$invalidated | ConvertTo-Json
