[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$profileReceipt =
    'C:\NLL\Evidence\Phase3B2\Physical\operator-profile-v1\profile-isolation.receipt.json'
$preparationReceipt =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-preparation-v2\preparation.receipt.json'
$resourceHostAuthorization =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\resource-host-map-repair.receipt.json'
$coreRecoveryReceipt =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\cf8433fe-ea3d-4594-94d3-863bd0846cd3\core-key-cold-recovery.receipt.json'
$catalogSetPointer =
    'C:\NLL\Evidence\Phase3B2\Physical\catalog-set-v1\latest.pointer.json'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

if ((Test-Path -LiteralPath $resourceHostAuthorization -PathType Leaf) -and
    (Test-Path -LiteralPath $coreRecoveryReceipt -PathType Leaf) -and
    -not (Test-Path -LiteralPath $preparationReceipt -PathType Leaf)) {
    $extensionGroup = 'NLL Phase3B2 Physical P2 V2 Extension'
    $staleRules = @(Get-NetFirewallRule -Group $extensionGroup `
        -ErrorAction SilentlyContinue)
    if ($staleRules.Count -gt 0) {
        if ($staleRules.Count -ne 1) {
            throw 'phase3b2_resource_host_retry_stale_firewall_shape_invalid'
        }
        $staleRules | Remove-NetFirewallRule
    }
    if (@(Get-NetFirewallRule -Group $extensionGroup `
            -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'phase3b2_resource_host_retry_stale_firewall_remove_failed'
    }
}

if ((Test-Path -LiteralPath $catalogSetPointer -PathType Leaf) -and
    (Test-Path -LiteralPath $preparationReceipt -PathType Leaf) -and
    (Test-Path -LiteralPath $hostsPath -PathType Leaf) -and
    (Get-Item -LiteralPath $hostsPath).Length -eq 1690L -and
    (Get-FileHash -LiteralPath $hostsPath -Algorithm SHA256).Hash.ToLowerInvariant() `
        -ceq 'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') {
    & 'C:\NLL\Tools\rearm-phase3b2-exact-catalog-retry-in-micron.ps1'
}

if (-not (Test-Path -LiteralPath $profileReceipt -PathType Leaf)) {
    & 'C:\NLL\Tools\Test-Phase3B2-Micron-Operator-Profile.ps1'
}
if (-not (Test-Path -LiteralPath $preparationReceipt -PathType Leaf)) {
    & 'C:\NLL\Tools\prepare-phase3b2-physical-p2-v2-in-micron.ps1'
}
& 'C:\NLL\Tools\start-phase3b2-physical-p2-v2-client-in-micron.ps1' `
    -MeasurementSeconds 30 -SampleIntervalSeconds 2
