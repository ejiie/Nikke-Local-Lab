# Exercise the production coordinator/watcher DB handoff with synthetic pg_ctl.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
# Call the production helpers; do not depend on coordinator/watcher source layout.
$start = { Assert-PhaseDPostgresRunning 'synthetic' 'synthetic-cluster' 'synthetic-identity' }
$complete = { Ensure-PhaseDPostgresRunning 'synthetic' 'synthetic-cluster' 'synthetic-log' 'synthetic-identity' }
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
& $start # just before server/game start
& $complete # normal completion; must preserve the same running cluster
& $complete # replay must also be a read-only status check
if(($commands -join ',') -cne 'status,status,status'){throw 'healthy_cluster_restarted'}
Reset 3
Reject $start 'phase_d_control_center_database_not_running'
if(($commands -join ',') -cne 'status'){throw 'startup_silently_repaired_database'}
Reset 3
& $complete
if(($commands -join ',') -cne 'status,start,status'){throw 'stopped_cluster_not_recovered'}
Reset 1
Reject $complete 'phase_d_control_center_database_status_failed'
if(($commands -join ',') -cne 'status'){throw 'unknown_status_started_database'}
Reset 3;$script:startFails=$true
Reject $complete 'phase_d_control_center_database_restart_failed'
Reset 3;$script:statusAfterStart=3
Reject $complete 'phase_d_control_center_database_not_running'
'Runtime database handoff checks passed.'
# Closing the desktop must not stop a live runtime or unfinished completion.
# The host is an entrypoint, not a dot-sourceable library. Execute its complete
# cleanup block selected structurally, with process/DB boundaries mocked below.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'start-nll-phase-d-control-center.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'desktop_close_parse_failed'}
$owners=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.TryStatementAst] -and $null -ne $node.Finally -and
    $null -ne $node.Finally.Find({param($child)
        $child -is [Management.Automation.Language.CommandAst] -and $child.GetCommandName() -ceq 'Test-ControlCenterRuntimeActive'
    },$false)
},$true))
if($owners.Count -ne 1){throw 'desktop_close_owner_ambiguous'}
$close=[scriptblock]::Create(($owners[0].Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`n")
# No real process or file is changed. Environment cleanup affects this test process only.
$admin=$null; $session='synthetic-session'; $bootstrap='synthetic-bootstrap'
function Test-Path {param($LiteralPath) return $false}
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
