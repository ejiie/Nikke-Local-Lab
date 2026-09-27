param([Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][int]$SeasonNumber,
    [Parameter(Mandatory = $true)][string]$WeaknessCode,
    [string]$RuntimeSelectionPath = 'C:\NLL\ControlCenter\runtime-selection.private.json')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDPreparation.ps1')
$preparation = Get-PhaseDPreparation -RepositoryRoot $RepositoryRoot -SeasonNumber $SeasonNumber `
    -WeaknessCode $WeaknessCode -RuntimeSelectionPath $RuntimeSelectionPath
try { Assert-PhaseDDatabaseBinding $preparation }
catch {
    $preparation.statusCode = 'blocked'
    $preparation.bindingSha256 = $null
    $code = $_.Exception.Message
    $preparation.failureCode = if ($code -cmatch '^phase_d_[a-z0-9_]{3,120}$') { $code } else { 'phase_d_boss_database_binding_unavailable' }
}
ConvertTo-PhaseDPreparationProjection $preparation | ConvertTo-Json -Depth 4 -Compress
