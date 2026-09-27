# Exercise the production coordinator/watcher DB handoff with synthetic pg_ctl.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
function Get-DatabaseBlocks {
    $start=Get-Content (Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1') -Raw
    $offset=$start.IndexOf("'phase_d_control_center_database_binding_missing'")
    $offset=$start.IndexOf("`n",$offset)+1
    $end=$start.IndexOf('    # The sealed runner owns',$offset)
    $finish=Get-Content (Join-Path $PSScriptRoot 'watch-nll-phase-d-execution.ps1') -Raw
    $from=$finish.IndexOf("    Write-PhaseDProgress `$LaunchRoot 'database_restart'")
    $to=$finish.IndexOf("    Write-PhaseDProgress `$LaunchRoot 'progress_save'",$from)
    if($offset -le 0 -or $end -le $offset -or $from -lt 0 -or $to -le $from){throw 'database_lifecycle_blocks_missing'}
    @([scriptblock]::Create($start.Substring($offset,$end-$offset)),[scriptblock]::Create($finish.Substring($from,$to-$from)))
}
$blocks=Get-DatabaseBlocks
$launchRoot=$PSScriptRoot
$controlCenterPgCtl='synthetic';$controlCenterPgData='synthetic-cluster';$controlCenterPgLog='synthetic-log'
$ControlCenterPgCtlPath=$controlCenterPgCtl;$ControlCenterPgDataPath=$controlCenterPgData;$ControlCenterPgLogPath=$controlCenterPgLog
function Write-PhaseDProgress {}
function Invoke-PhaseDPgCtl {
    param($PgCtlPath,$Arguments,$OwnershipPath)
    if($Arguments[2] -cne 'synthetic-cluster'){throw 'cluster_scope_changed'}
    $script:commands.Add($Arguments[0])
    switch($Arguments[0]){
        'status' {return $script:status}
        'start' {if($script:startFails){return 1};$script:status=$script:statusAfterStart;return 0}
        default {throw 'healthy_runtime_database_was_stopped'}
    }
}
function Reset([int]$Status){$script:status=$Status;$script:commands=[Collections.Generic.List[string]]::new();$script:startFails=$false;$script:statusAfterStart=0}
function Reject([scriptblock]$Block,[string]$Expected){
    try{& $Block}catch{if($_.Exception.Message -ceq $Expected){return};throw};throw 'database_failure_not_rejected'
}
Reset 0
& $blocks[0] # just before server/game start
& $blocks[1] # normal completion; must preserve the same running cluster
& $blocks[1] # replay must also be a read-only status check
if(($commands -join ',') -cne 'status,status,status'){throw 'healthy_cluster_restarted'}
Reset 3
Reject $blocks[0] 'phase_d_control_center_database_not_running'
if(($commands -join ',') -cne 'status'){throw 'startup_silently_repaired_database'}
Reset 3
& $blocks[1]
if(($commands -join ',') -cne 'status,start,status'){throw 'stopped_cluster_not_recovered'}
Reset 1
Reject $blocks[1] 'phase_d_control_center_database_status_failed'
if(($commands -join ',') -cne 'status'){throw 'unknown_status_started_database'}
Reset 3;$script:startFails=$true
Reject $blocks[1] 'phase_d_control_center_database_restart_failed'
Reset 3;$script:statusAfterStart=3
Reject $blocks[1] 'phase_d_control_center_database_not_running'
'Runtime database handoff checks passed.'
# Closing the desktop must not stop a live runtime or unfinished completion.
$hostSource=Get-Content (Join-Path $PSScriptRoot 'start-nll-phase-d-control-center.ps1') -Raw
$from=$hostSource.IndexOf('    $databaseCanStop =')
$to=$hostSource.IndexOf('    foreach($name in @(', $from)
$close=[scriptblock]::Create($hostSource.Substring($from,$to-$from))
function Test-ControlCenterRuntimeActive {$script:active}
function Wait-ControlCenterCompletionWatchers {if($script:watcherPending){throw 'completion_still_pending'}}
function Invoke-ControlCenterPgCtl {param($Arguments) $script:closeCommands.Add($Arguments[0]);return 0}
$data='synthetic-cluster'
foreach($case in @('active','pending','closed')){
    $script:active=$case -ceq 'active';$script:watcherPending=$case -ceq 'pending'
    $script:closeCommands=[Collections.Generic.List[string]]::new()
    if($watcherPending){Reject $close 'completion_still_pending'}else{& $close}
    $expected=if($case -ceq 'closed'){'status,stop'}else{''}
    if(($closeCommands -join ',') -cne $expected){throw 'desktop_close_database_lifetime_invalid'}
}
'Phase D database lifecycle: healthy start/completion/replay, stopped startup, recovery, status/start/readiness failures passed.'
