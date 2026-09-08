param([Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][int]$SeasonNumber,
    [Parameter(Mandatory = $true)][string]$WeaknessCode,
    [string]$RuntimeSelectionPath = 'C:\NLL\ControlCenter\runtime-selection.private.json')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDPreparation.ps1')
$preparation = Get-PhaseDPreparation -RepositoryRoot $RepositoryRoot -SeasonNumber $SeasonNumber `
    -WeaknessCode $WeaknessCode -RuntimeSelectionPath $RuntimeSelectionPath
ConvertTo-PhaseDPreparationProjection $preparation | ConvertTo-Json -Depth 4 -Compress
