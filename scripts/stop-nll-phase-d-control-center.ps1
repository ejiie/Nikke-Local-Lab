$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root='C:\NLL\ControlCenter'
$session=Join-Path $root 'session\session.json'
$data=Join-Path $root 'postgresql\data'
$pgCtl='C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
function Invoke-ControlCenterPgCtl {
    param([string[]]$Arguments)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$pgCtl
    $info.Arguments=(($Arguments|ForEach-Object{'"'+$_.Replace('"','\"')+'"'})-join ' ')
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    $process.WaitForExit()
    $exitCode=[int]$process.ExitCode
    $process.Dispose()
    $exitCode
}
function Test-PinnedProcess {
    param([int]$Id,[string]$Name,[string]$StartedAtUtc)
    $process=Get-Process -Id $Id -ErrorAction SilentlyContinue
    if($null-eq $process -or $process.ProcessName -cne $Name -or
       [string]::IsNullOrWhiteSpace($StartedAtUtc)){return $false}
    $process.StartTime.ToUniversalTime().ToString('o') -ceq $StartedAtUtc
}
function Wait-ControlCenterCompletionWatchers {
    $executionRoot='C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\automation\phase-d-executions'
    foreach($identityPath in @(Get-ChildItem -LiteralPath $executionRoot -Recurse -File `
            -Filter 'completion-watcher.identity.json' -ErrorAction SilentlyContinue)){
        $watcher=Get-Content -LiteralPath $identityPath.FullName -Raw -Encoding UTF8 |
            ConvertFrom-Json
        if($watcher.contractId -cne 'nll/phase-d-completion-watcher-identity/v1'){continue}
        if(Test-PinnedProcess -Id ([int]$watcher.processId) -Name 'powershell' `
                -StartedAtUtc ([string]$watcher.processStartedAtUtc)){
            Wait-Process -Id ([int]$watcher.processId) -Timeout 60
        }
    }
}
if(@(Get-Process -Name nikke,EpinelPS,'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -gt 0){
    throw 'control_center_stop_game_still_running'
}
Wait-ControlCenterCompletionWatchers
if(Test-Path -LiteralPath $session -PathType Leaf){
    $state=$null
    try{$state=Get-Content -LiteralPath $session -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
    if($null-ne $state -and $state.contractId -ceq 'nll/control-center-session/v1'){
        $process=Get-Process -Id ([int]$state.adminProcessId) -ErrorAction SilentlyContinue
        if($null-ne $process -and $process.ProcessName -ceq 'dotnet' -and
           $process.StartTime.ToUniversalTime().ToString('o') -ceq
               [string]$state.adminProcessStartedAtUtc){
            Stop-Process -Id $process.Id -Force
            Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $session -Force
}
if((Invoke-ControlCenterPgCtl @('status','-D',$data)) -eq 0){
    $pgStop=Invoke-ControlCenterPgCtl @('stop','-D',$data,'-m','fast','-w','-t','60')
    if($pgStop -ne 0){throw 'control_center_postgresql_stop_failed'}
}
'NLL Control Center stopped.'
