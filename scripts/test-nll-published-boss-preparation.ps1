# Source-only regression: no installed runtime, account, game or database is read.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDPreparation.ps1')
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$absentSelection = Join-Path ([IO.Path]::GetTempPath()) ('nll-ci-no-selection-' + [guid]::NewGuid().ToString('N') + '.json')
if (Test-Path -LiteralPath $absentSelection) { throw 'published_preparation_selection_must_be_absent' }
foreach ($weakness in @('fire', 'water', 'wind', 'electric', 'iron')) {
    $ready = Get-PhaseDPreparation $repositoryRoot 26 $weakness $absentSelection
    if ($ready.statusCode -cne 'ready' -or $null -ne $ready.failureCode -or
        $ready.bindingSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'published_s26_source_preparation_not_ready'
    }
    $blocked = Get-PhaseDPreparation $repositoryRoot 29 $weakness $absentSelection
    if ($blocked.statusCode -cne 'blocked' -or
        $blocked.failureCode -cne 'phase_d_boss_variant_profile_drifted' -or
        $null -ne $blocked.bindingSha256 -or $null -ne $blocked.plan) {
        throw 'published_s29_draft_must_remain_blocked'
    }
}
Write-Output 'Published source preparation: S26 ready / S29 draft blocked for all five weaknesses; not a runtime admission.'
