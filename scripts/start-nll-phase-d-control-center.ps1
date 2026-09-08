[CmdletBinding()]
param(
    [switch]$DesktopHost,
    [string]$DesktopStopSignalPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
function Assert-Start { param([bool]$Condition,[string]$Code) if(-not $Condition){throw $Code} }
function Test-PinnedProcess {
    param([int]$Id,[string]$Name,[string]$StartedAtUtc)
    $process=Get-Process -Id $Id -ErrorAction SilentlyContinue
    if($null-eq $process -or $process.ProcessName -cne $Name -or
       [string]::IsNullOrWhiteSpace($StartedAtUtc)){return $false}
    $process.StartTime.ToUniversalTime().ToString('o') -ceq $StartedAtUtc
}
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
function Wait-ControlCenterCompletionWatchers {
    $executionRoot=Join-Path $repositoryRoot 'artifacts\automation\phase-d-executions'
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
function Unprotect-Secret {
    param([string]$Path)
    $protected=[IO.File]::ReadAllBytes($Path); $entropy=[Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try { $plain=[Security.Cryptography.ProtectedData]::Unprotect($protected,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser); try { [Text.Encoding]::UTF8.GetString($plain) } finally { [Array]::Clear($plain,0,$plain.Length) } }
    finally { [Array]::Clear($protected,0,$protected.Length); [Array]::Clear($entropy,0,$entropy.Length) }
}
$root='C:\NLL\ControlCenter'; $repositoryRoot='C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab'
$pgCtl='C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'; $data=Join-Path $root 'postgresql\data'; $log=Join-Path $root 'logs\postgresql.log'
$bootstrap=Join-Path $root 'session\bootstrap.secret'; $session=Join-Path $root 'session\session.json'; $port=55433
$identity=[Security.Principal.WindowsIdentity]::GetCurrent(); $principal=[Security.Principal.WindowsPrincipal]::new($identity)
Assert-Start ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and $env:USERNAME -ceq 'nlloperator') 'control_center_start_boundary_invalid'
if(Test-Path -LiteralPath $session -PathType Leaf){
    $prior=$null
    try{$prior=Get-Content -LiteralPath $session -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
    $priorAdminLive=$false
    $priorHostLive=$false
    if($null-ne $prior -and $prior.contractId -ceq 'nll/control-center-session/v1'){
        $priorAdminLive=Test-PinnedProcess `
            -Id ([int]$prior.adminProcessId) -Name 'dotnet' `
            -StartedAtUtc ([string]$prior.adminProcessStartedAtUtc)
        if($prior.PSObject.Properties.Name -contains 'hostProcessId'){
            $priorHostLive=Test-PinnedProcess `
                -Id ([int]$prior.hostProcessId) -Name 'powershell' `
                -StartedAtUtc ([string]$prior.hostProcessStartedAtUtc)
        }
        elseif($priorAdminLive){
            throw 'control_center_already_running'
        }
    }
    if($priorAdminLive -and $priorHostLive){throw 'control_center_already_running'}
    if($priorAdminLive){
        Stop-Process -Id ([int]$prior.adminProcessId) -Force
        Wait-Process -Id ([int]$prior.adminProcessId) -Timeout 10 -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $session -Force
}
New-Item -ItemType Directory -Path (Split-Path -Parent $bootstrap) -Force | Out-Null
$databasePassword=Unprotect-Secret (Join-Path $root 'secrets\database-password.dpapi'); $identitySecret=Unprotect-Secret (Join-Path $root 'secrets\identity-secret.dpapi')
$env:NIKKE_LAB_DB="Host=127.0.0.1;Port=$port;Database=nll_control_center;Username=nll_control_center;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
$env:NIKKE_LAB_ID_SECRET=$identitySecret; $env:NIKKE_LAB_HOME=Join-Path $root 'runtime-home'; $env:NLL_CONTROL_CENTER_BOOTSTRAP_PATH=$bootstrap
$env:NLL_CONTROL_CENTER_PG_CTL=$pgCtl; $env:NLL_CONTROL_CENTER_PG_DATA=$data; $env:NLL_CONTROL_CENTER_PG_LOG=$log
$env:NLL_PHASE_D_CONTROL_CENTER='1'
$admin=$null
try {
    # Do not pipe pg_ctl output. On Windows, postgres descendants can inherit
    # the pipeline handle and keep Windows PowerShell waiting indefinitely.
    $pgStatus=Invoke-ControlCenterPgCtl @('status','-D',$data)
    if($pgStatus -eq 0){
        $pgStop=Invoke-ControlCenterPgCtl @('stop','-D',$data,'-m','fast','-w','-t','60')
        Assert-Start ($pgStop -eq 0) 'control_center_orphan_postgresql_stop_failed'
    }
    elseif(Test-Path -LiteralPath (Join-Path $data 'postmaster.pid') -PathType Leaf){
        $postmasterPid=[int](Get-Content -LiteralPath (Join-Path $data 'postmaster.pid') -TotalCount 1)
        $postmaster=Get-Process -Id $postmasterPid -ErrorAction SilentlyContinue
        Assert-Start ($null-eq $postmaster -or $postmaster.ProcessName -cne 'postgres') `
            'control_center_postgresql_identity_conflict'
        Remove-Item -LiteralPath (Join-Path $data 'postmaster.pid') -Force
    }
    $pgStart=Invoke-ControlCenterPgCtl @('start','-D',$data,'-l',$log,'-w','-t','60')
    Assert-Start ($pgStart -eq 0) 'control_center_postgresql_start_failed'
    $admin=Start-Process -FilePath 'C:\Program Files\dotnet\dotnet.exe' -ArgumentList @((Join-Path $root 'app\NikkeLocalLab.Admin.Api.dll'),'--config',(Join-Path $repositoryRoot 'config\appsettings.example.json'),'--repository-root',$repositoryRoot,'--phase-d-control-center','true') -RedirectStandardOutput (Join-Path $root 'logs\admin.stdout.log') -RedirectStandardError (Join-Path $root 'logs\admin.stderr.log') -WindowStyle Hidden -PassThru
    for($i=0;$i -lt 150 -and -not $admin.HasExited -and -not (Test-Path -LiteralPath $bootstrap);$i++){Start-Sleep -Milliseconds 200}
    Assert-Start (-not $admin.HasExited -and (Test-Path -LiteralPath $bootstrap -PathType Leaf)) 'control_center_admin_start_failed'
    $code=(Get-Content -LiteralPath $bootstrap -Raw).Trim(); Assert-Start (-not [string]::IsNullOrWhiteSpace($code)) 'control_center_bootstrap_missing'
    if ($DesktopHost) {
        Assert-Start (-not [string]::IsNullOrWhiteSpace($DesktopStopSignalPath)) `
            'control_center_desktop_stop_signal_missing'
        if (Test-Path -LiteralPath $DesktopStopSignalPath) {
            Remove-Item -LiteralPath $DesktopStopSignalPath -Force
        }
    }
    else { Set-Clipboard -Value $code }
    Remove-Item -LiteralPath $bootstrap -Force
    $hostProcess=Get-Process -Id $PID -ErrorAction Stop
    $state=[ordered]@{schemaVersion=1;contractId='nll/control-center-session/v1';hostProcessId=$PID;hostProcessStartedAtUtc=$hostProcess.StartTime.ToUniversalTime().ToString('o');desktopHost=[bool]$DesktopHost;adminProcessId=$admin.Id;adminProcessStartedAtUtc=$admin.StartTime.ToUniversalTime().ToString('o');startedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($session,(($state|ConvertTo-Json)+"`n"),[Text.UTF8Encoding]::new($false))
    if ($DesktopHost) {
        Write-Output ('NLL_DESKTOP_BOOTSTRAP:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($code)))
        while (-not $admin.HasExited -and -not (Test-Path -LiteralPath $DesktopStopSignalPath)) {
            Start-Sleep -Milliseconds 250
        }
    }
    else {
        Start-Process 'http://127.0.0.1:17878/editor/' | Out-Null
        Write-Host ''; Write-Host 'NLL Control Center is running.' -ForegroundColor Cyan
        Write-Host 'One-time login code was copied to the clipboard. Paste it into the login box.'
        Write-Host 'During game launch PostgreSQL is paused automatically and restored after completion.'
        [void](Read-Host 'Press Enter here only after all game/client work is finished')
    }
    Assert-Start (@(Get-Process -Name nikke,EpinelPS,'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -eq 0) 'control_center_game_still_running'
    Wait-ControlCenterCompletionWatchers
}
finally {
    if($null -ne $admin -and -not $admin.HasExited){Stop-Process -Id $admin.Id -Force -ErrorAction SilentlyContinue; $admin.WaitForExit(10000)}
    if(Test-Path -LiteralPath $session){Remove-Item -LiteralPath $session -Force}
    if(Test-Path -LiteralPath $bootstrap){Remove-Item -LiteralPath $bootstrap -Force}
    if($DesktopHost -and -not [string]::IsNullOrWhiteSpace($DesktopStopSignalPath) -and
       (Test-Path -LiteralPath $DesktopStopSignalPath)){
        Remove-Item -LiteralPath $DesktopStopSignalPath -Force -ErrorAction SilentlyContinue
    }
    if ((Invoke-ControlCenterPgCtl @('status','-D',$data)) -eq 0) {
        [void](Invoke-ControlCenterPgCtl @('stop','-D',$data,'-m','fast','-w','-t','60'))
    }
    foreach($name in @('NIKKE_LAB_DB','NIKKE_LAB_ID_SECRET','NIKKE_LAB_HOME','NLL_CONTROL_CENTER_BOOTSTRAP_PATH','NLL_CONTROL_CENTER_PG_CTL','NLL_CONTROL_CENTER_PG_DATA','NLL_CONTROL_CENTER_PG_LOG','NLL_PHASE_D_CONTROL_CENTER')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $databasePassword=$null; $identitySecret=$null
}
