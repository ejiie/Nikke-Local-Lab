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
function Invoke-PhaseDPgCtl {
    param($PgCtlPath,$Arguments,$OwnershipPath)
    if($script:pgMode -ceq 'restart') {
        if($Arguments[0] -cne 'start'){throw 'prestart_test_restart_not_called'}
        $script:restartCalls++; return $script:restartExit
    }
    if(($Arguments -join '|') -cne ('status|-D|'+$launchRoot)){throw 'pg_status_target_changed'}
    return $script:pgStatus
}
function Get-Process {throw 'prestart_test_global_process_scan_forbidden'}
function Ensure-PhaseDPostgresRunning {
    $script:restartCalls++
    if ($script:restartExit) { throw 'synthetic_db_unavailable' }
}
$script:pgMode='status'
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
    $script:pgStatus=3
    Assert-PhaseDPostgresStopped 'synthetic-pgctl' $launchRoot 'synthetic-identity'; $checks++
    foreach($status in @(0,1,4)) {
        $script:pgStatus=$status
        Rejected {Assert-PhaseDPostgresStopped 'synthetic-pgctl' $launchRoot 'synthetic-identity'} 'phase_d_postgresql_not_cold'
    }
    $script:pgStatus=3
    [IO.File]::WriteAllText((Join-Path $launchRoot 'postmaster.pid'),'synthetic-running-cluster')
    Rejected {Assert-PhaseDPostgresStopped 'synthetic-pgctl' $launchRoot 'synthetic-identity'} 'phase_d_postgresql_not_cold'
    # Run the coordinator's real failure tail: a pre-Job failure must restore
    # hosts/restart the management DB, preserving the first error on success.
    $catchBody=$ast.FindAll({param($node) $node -is [Management.Automation.Language.CatchClauseAst] -and
        $node.Body.Extent.Text.Contains('$coordinatorRollbackProven = -not $runtimeLifecycleEntered')},$true)[0].Body
    $tail=$catchBody.Extent.Text
    $tail=$tail.Substring($tail.IndexOf('$coordinatorRollbackProven = -not $runtimeLifecycleEntered'))
    $tail=$tail.Substring(0,$tail.LastIndexOf('}'))
    $failureTail=[scriptblock]::Create($tail)
    function Test-PhaseDDerivedStartRollbackProof {return $false}
    function Write-PhaseDFirstFailure {}
    function Write-AtomicJson {param($Path,$Value) [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 6))}
    function Set-ExecutionState {param($StatusCode,$FailureCode) $script:finalState=$StatusCode; $script:finalFailure=$FailureCode}
    $hostsPath=Join-Path $launchRoot 'synthetic-hosts'
    $controlCenterHostsBackupPath=Join-Path $launchRoot 'synthetic-hosts-before'
    [IO.File]::WriteAllText($controlCenterHostsBackupPath,'synthetic-original-hosts')
    $controlCenterHostsOriginalSha256=Get-Sha256Lower $controlCenterHostsBackupPath
    $expectedCleanHostsSha256=$controlCenterHostsOriginalSha256; $expectedPostDockerUninstallCleanHostsSha256='b'*64
    $controlCenterPgCtl='synthetic-pgctl'; $controlCenterPgData=$launchRoot; $controlCenterPgLog='synthetic-log'
    $LaunchContextUid=[guid]::NewGuid().ToString('D'); $script:pgMode='restart'; $jobAttempted=$false
    foreach($exitCode in @(0,1)) {
        [IO.File]::WriteAllText($hostsPath,'synthetic-prepared-hosts')
        $runtimeLifecycleEntered=$true; $controlCenterHostsPrepared=$true
        $failureCode='phase_d_postgresql_not_cold'; $script:restartCalls=0; $script:restartExit=$exitCode
        $expectedFailure=if($exitCode -eq 0){$failureCode}else{'phase_d_control_center_database_restart_failed'}
        Rejected {& $failureTail} $expectedFailure
        $expectedState=if($exitCode -eq 0){'failed'}else{'started'}
        if($script:finalState -cne $expectedState -or $script:finalFailure -cne $expectedFailure -or
            $script:restartCalls -ne 1 -or (Get-Sha256Lower $hostsPath) -cne $controlCenterHostsOriginalSha256) {
            throw 'prestart_test_cleanup_outcome_invalid'
        }
    }
    Write-Output "Pre-start recovery: $checks synthetic checks passed; no DB/game started."
} finally {
    $full=[IO.Path]::GetFullPath($launchRoot)
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($full) -cnotmatch '^nll-prestart-[a-f0-9]{32}$'){throw 'prestart_test_cleanup_invalid'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
