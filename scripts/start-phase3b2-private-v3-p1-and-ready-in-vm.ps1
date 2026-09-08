[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [long]$CheckpointReceiptByteLength,

    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$CheckpointReceiptSha256
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

Assert-True ($CheckpointReceiptByteLength -gt 0) `
    "phase3b2_private_v3_checkpoint_receipt_length_invalid"
$toolRoot = "C:\NLL\Tools"
$measurePath = Join-Path $toolRoot "measure-phase3b2-p1-server-in-vm.ps1"
$projectionPath = Join-Path $toolRoot `
    "new-phase3b2-hyperv-ready-projection-in-vm.ps1"
Assert-True (Test-Path -LiteralPath $measurePath -PathType Leaf) `
    "phase3b2_private_v3_measurement_tool_missing"
Assert-True (Test-Path -LiteralPath $projectionPath -PathType Leaf) `
    "phase3b2_private_v3_projection_tool_missing"
Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke_launcher, nikke `
        -ErrorAction SilentlyContinue)) "phase3b2_private_v3_runtime_not_cold"

& $measurePath -NetworkModeCode private_vm_only_no_gateway | Out-Null
& $projectionPath -NetworkModeCode private_vm_only_no_gateway `
    -PrivateCheckpointReceiptByteLength $CheckpointReceiptByteLength `
    -PrivateCheckpointReceiptSha256 $CheckpointReceiptSha256
