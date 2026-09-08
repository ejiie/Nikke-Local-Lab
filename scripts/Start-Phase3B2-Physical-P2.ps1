[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$preparePath = 'C:\NLL\Tools\prepare-phase3b2-physical-p2-in-micron.ps1'
$startPath = 'C:\NLL\Tools\start-phase3b2-physical-p2-client-in-micron.ps1'
$preparationReceipt =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-preparation-v1\preparation.receipt.json'

if (-not (Test-Path -LiteralPath $preparationReceipt -PathType Leaf)) {
    & $preparePath
}

& $startPath
