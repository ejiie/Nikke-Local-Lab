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
    "phase3b2_private_v5_checkpoint_receipt_length_invalid"
$toolRoot = "C:\NLL\Tools"
$measurePath = Join-Path $toolRoot `
    "measure-phase3b2-p1-server-in-vm.ps1"
$projectionPath = Join-Path $toolRoot `
    "new-phase3b2-hyperv-ready-projection-in-vm.ps1"
Assert-True ((Test-Path -LiteralPath $measurePath -PathType Leaf) -and
    (Test-Path -LiteralPath $projectionPath -PathType Leaf)) `
    "phase3b2_private_v5_measurement_tool_missing"
Assert-True (@(Get-Process -Name EpinelPS, nikke_launcher, nikke,
        NikkeLocalLab.Phase3B2.LocalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    "phase3b2_private_v5_runtime_not_cold"

& $measurePath `
    -NetworkModeCode private_vm_only_no_gateway `
    -ClientBootstrapModeCode source_built_sail_abi_local_bootstrap |
    Out-Null
& $projectionPath `
    -NetworkModeCode private_vm_only_no_gateway `
    -ClientBootstrapModeCode source_built_sail_abi_local_bootstrap `
    -PrivateCheckpointReceiptByteLength $CheckpointReceiptByteLength `
    -PrivateCheckpointReceiptSha256 $CheckpointReceiptSha256
