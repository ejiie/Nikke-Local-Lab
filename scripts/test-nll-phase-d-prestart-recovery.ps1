# Exercise production pre-start rollback and scoped PG status without a DB/game.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'prestart_test_parse_failed'}
foreach($name in @('Assert-PhaseD','Get-Sha256Lower','Invoke-PhaseDEmergencyRollback')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$launchRoot=Join-Path ([IO.Path]::GetTempPath()) ('nll-prestart-' + [guid]::NewGuid().ToString('N'))
$runtimeRoot=Join-Path $launchRoot 'runtime'; $evidenceRoot=Join-Path $launchRoot 'evidence'
$null=New-Item -ItemType Directory -Path $runtimeRoot,$evidenceRoot
$runtimeDbPath=Join-Path $runtimeRoot 'db.json'
[IO.File]::WriteAllText($runtimeDbPath,'synthetic-runtime')
$runtimeDbSha256=Get-Sha256Lower $runtimeDbPath
$jobAttempted=$false; $runnerBundle=[pscustomobject]@{sha256=('a'*64)}
$checks=0
function Rejected([scriptblock]$Action,[string]$Code) {
    $caught=$false
    try{& $Action | Out-Null}catch{if($_.Exception.Message -cne $Code){throw};$caught=$true}
    if(-not $caught){throw 'prestart_test_expected_rejection'}
    $script:checks++
}
function Invoke-PhaseDWithJobZeroProof {throw 'existing_job_proof_required'}
function Invoke-PhaseDExecutionFxCleanup { Invoke-PhaseDWithJobZeroProof $launchRoot $runnerBundle.sha256 {} }
function Invoke-PhaseDPgCtl {
    param($PgCtlPath,$Arguments,$OwnershipPath)
    if(($Arguments -join '|') -cne ('status|-D|'+$launchRoot)){throw 'pg_status_target_changed'}
    return $script:pgStatus
}
function Get-Process {throw 'prestart_test_global_process_scan_forbidden'}
try {
    if(-not (Invoke-PhaseDEmergencyRollback $evidenceRoot $runtimeRoot)){throw 'prestart_test_rollback_not_proven'}; $checks++
    foreach($path in @((Join-Path $evidenceRoot 'active-run.pointer.json'),
        (Join-Path $launchRoot 'job-reservation.json'),(Join-Path $launchRoot 'phase-d-child-start.identity.json'))) {
        [IO.File]::WriteAllText($path,'synthetic-start-evidence')
        Rejected {Invoke-PhaseDEmergencyRollback $evidenceRoot $runtimeRoot} 'phase_d_prestart_runtime_drifted'
        Remove-Item -LiteralPath $path
    }
    [IO.File]::WriteAllText($runtimeDbPath,'different-runtime')
    Rejected {Invoke-PhaseDEmergencyRollback $evidenceRoot $runtimeRoot} 'phase_d_prestart_runtime_drifted'
    [IO.File]::WriteAllText($runtimeDbPath,'synthetic-runtime')
    $jobAttempted=$true
    Rejected {Invoke-PhaseDEmergencyRollback $evidenceRoot $runtimeRoot} 'existing_job_proof_required'
    function Invoke-PhaseDWithJobZeroProof { param($LaunchRoot,$ExpectedBundleSha256,$Action) & $Action }
    function Get-NetFirewallRule { param($Group,$ErrorAction) [pscustomobject]@{Name='synthetic-extension'} }
    function Remove-NetFirewallRule {
        [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
        process { $script:removed++ }
    }
    foreach($owned in @($false,$true)) {
        $script:PhaseDRunnerIsolationOwned=$owned; $script:removed=0
        if(-not (Invoke-PhaseDEmergencyRollback $evidenceRoot $runtimeRoot) -or
            $script:removed -ne [int]$owned){throw 'prestart_extension_ownership_lost'}
        $checks++
    }

    $script:pgStatus=3
    Assert-PhaseDPostgresStopped 'synthetic-pgctl' $launchRoot 'synthetic-identity'; $checks++
    foreach($status in @(0,1,4)) {
        $script:pgStatus=$status
        Rejected {Assert-PhaseDPostgresStopped 'synthetic-pgctl' $launchRoot 'synthetic-identity'} 'phase_d_postgresql_not_cold'
    }
    $script:pgStatus=3
    [IO.File]::WriteAllText((Join-Path $launchRoot 'postmaster.pid'),'synthetic-running-cluster')
    Rejected {Assert-PhaseDPostgresStopped 'synthetic-pgctl' $launchRoot 'synthetic-identity'} 'phase_d_postgresql_not_cold'
    Write-Output "Pre-start recovery: $checks synthetic checks passed; no DB/game started."
} finally {
    $full=[IO.Path]::GetFullPath($launchRoot)
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($full) -cnotmatch '^nll-prestart-[a-f0-9]{32}$'){throw 'prestart_test_cleanup_invalid'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
