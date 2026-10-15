$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Synthetic checks of the measured voice preference values accepted before a Phase D launch. No registry access.
. (Join-Path $PSScriptRoot 'Nll.ResourcePreflight.ps1')
$count = 0
function Check([bool]$Value, [string]$Name) { if (-not $Value) { throw "voice_selection_test_failed_$Name" }; $script:count++ }
foreach ($row in @(@('ko', 'Minimal', 'ko', 'minimal'), @('ja', 'Full', 'ja', 'full'), @('en', 'Minimal', 'en', 'minimal'), @('None', 'Minimal', 'none', 'minimal'))) {
    $selection = ConvertTo-NllVoiceResourceSelection $row[0] $row[1]
    Check ($selection.language -ceq $row[2] -and $selection.scope -ceq $row[3]) ('accepts_' + $row[0] + '_' + $row[1])
}
foreach ($row in @(@('none', 'Minimal'), @('', 'Minimal'), @('kr', 'Minimal'), @('ko', 'None'), @('ko', ''), @('None', 'none'))) {
    $rejected = $false
    try { $null = ConvertTo-NllVoiceResourceSelection $row[0] $row[1] } catch { $rejected = $_.Exception.Message -ceq 'phase_d_resource_voice_selection_unresolved' }
    Check $rejected ('rejects_' + $row[0] + '_' + $row[1])
}
"Voice selection: $count measured-value checks passed; no registry access."
