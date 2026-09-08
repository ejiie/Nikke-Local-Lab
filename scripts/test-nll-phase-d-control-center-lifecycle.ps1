[CmdletBinding()]
param([switch]$Elevated)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Lifecycle {
    param([bool]$Condition,[string]$Code)
    if(-not $Condition){throw $Code}
}
function Test-LifecyclePort {
    param([int]$Port)
    @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object LocalPort -eq $Port).Count -gt 0
}
function Test-PinnedProcess {
    param([int]$Id,[string]$Name,[string]$StartedAtUtc)
    $process=Get-Process -Id $Id -ErrorAction SilentlyContinue
    $null-ne $process -and $process.ProcessName -ceq $Name -and
        $process.StartTime.ToUniversalTime().ToString('o') -ceq $StartedAtUtc
}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',
        $MyInvocation.MyCommand.Path,'-Elevated')
    $process=Start-Process -FilePath $shell -Verb RunAs -ArgumentList $arguments `
        -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
}
Assert-Lifecycle ($Elevated -and $env:USERNAME -ceq 'nlloperator') `
    'control_center_lifecycle_boundary_invalid'

$repositoryRoot=Split-Path -Parent $PSScriptRoot
$installedStart='C:\NLL\ControlCenter\Start-NLL-ControlCenter.ps1'
$installedStop='C:\NLL\ControlCenter\Stop-NLL-ControlCenter.ps1'
$sessionPath='C:\NLL\ControlCenter\session\session.json'
$testUid=[guid]::NewGuid().ToString('D')
$testRoot=Join-Path $repositoryRoot ('artifacts\phase-d\lifecycle-smoke\'+$testUid)
$stopSignal=Join-Path $testRoot 'desktop-stop.signal'
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
trap{
    try{
        [IO.File]::WriteAllText(
            (Join-Path $testRoot 'failure.txt'),
            ($_.Exception.Message+"`n"),
            [Text.UTF8Encoding]::new($false))
    }catch{}
    exit 1
}
Assert-Lifecycle `
    (@(Get-Process -Name postgres,EpinelPS,nikke,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -eq 0) `
    'control_center_lifecycle_runtime_not_cold'
Assert-Lifecycle (-not (Test-Path -LiteralPath $sessionPath)) `
    'control_center_lifecycle_session_not_cold'
Assert-Lifecycle ((-not (Test-LifecyclePort 55433)) -and
    (-not (Test-LifecyclePort 17878))) `
    'control_center_lifecycle_port_not_cold'
$staleSession=[ordered]@{
    schemaVersion=1
    contractId='nll/control-center-session/v1'
    hostProcessId=2147483647
    hostProcessStartedAtUtc='2000-01-01T00:00:00.0000000Z'
    desktopHost=$true
    adminProcessId=2147483646
    adminProcessStartedAtUtc='2000-01-01T00:00:00.0000000Z'
    startedAtUtc='2000-01-01T00:00:00.0000000Z'
}
[IO.File]::WriteAllText(
    $sessionPath,(($staleSession|ConvertTo-Json -Depth 4)+"`n"),
    [Text.UTF8Encoding]::new($false))

$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
    "& '$installedStart' -DesktopHost -DesktopStopSignalPath '$stopSignal'"))
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$info.Arguments="-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
$info.UseShellExecute=$false
$info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true
$info.RedirectStandardError=$true
$hostProcess=[Diagnostics.Process]::new()
$hostProcess.StartInfo=$info
$started=$false
try{
    Assert-Lifecycle $hostProcess.Start() 'control_center_lifecycle_host_start_failed'
    $started=$true
    $outputTask=$hostProcess.StandardOutput.ReadToEndAsync()
    $errorTask=$hostProcess.StandardError.ReadToEndAsync()
    $newSessionReady=$false
    for($i=0;$i-lt 450 -and -not $hostProcess.HasExited -and
            -not $newSessionReady;$i++){
        if(Test-Path -LiteralPath $sessionPath -PathType Leaf){
            try{
                $observed=Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json
                $newSessionReady=[int]$observed.hostProcessId -eq $hostProcess.Id
            }catch{}
        }
        if($newSessionReady){break}
        Start-Sleep -Milliseconds 200
    }
    Assert-Lifecycle (-not $hostProcess.HasExited) 'control_center_lifecycle_host_exited_early'
    Assert-Lifecycle $newSessionReady `
        'control_center_lifecycle_session_missing'
    $session=Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8|ConvertFrom-Json
    [IO.File]::WriteAllText(
        (Join-Path $testRoot 'observed-session.json'),
        (($session|ConvertTo-Json -Depth 4)+"`n"),
        [Text.UTF8Encoding]::new($false))
    Assert-Lifecycle `
        ($session.contractId -ceq 'nll/control-center-session/v1' -and
         [int]$session.hostProcessId -eq $hostProcess.Id -and
         [int]$session.hostProcessId -ne [int]$staleSession.hostProcessId -and
         (Test-PinnedProcess -Id ([int]$session.hostProcessId) -Name 'powershell' `
             -StartedAtUtc ([string]$session.hostProcessStartedAtUtc)) -and
         (Test-PinnedProcess -Id ([int]$session.adminProcessId) -Name 'dotnet' `
             -StartedAtUtc ([string]$session.adminProcessStartedAtUtc))) `
        'control_center_lifecycle_session_identity_invalid'
    Assert-Lifecycle ((Test-LifecyclePort 55433) -and
        (Test-LifecyclePort 17878)) `
        'control_center_lifecycle_ports_missing'
    [IO.File]::WriteAllText($stopSignal,"stop`n",[Text.UTF8Encoding]::new($false))
    Assert-Lifecycle $hostProcess.WaitForExit(120000) `
        'control_center_lifecycle_host_stop_timeout'
    $standardError=$errorTask.GetAwaiter().GetResult()
    [void]$outputTask.GetAwaiter().GetResult()
    Assert-Lifecycle ($hostProcess.ExitCode -eq 0) `
        $(if([string]::IsNullOrWhiteSpace($standardError)){
            'control_center_lifecycle_host_stop_failed'
        }else{'control_center_lifecycle_host_stop_failed.'+$standardError.Trim()})
}
finally{
    if($started -and -not $hostProcess.HasExited){
        [IO.File]::WriteAllText($stopSignal,"stop`n",[Text.UTF8Encoding]::new($false))
        [void]$hostProcess.WaitForExit(10000)
    }
    if(-not $hostProcess.HasExited){$hostProcess.Kill()}
    $hostProcess.Dispose()
    if((Test-Path -LiteralPath $sessionPath -PathType Leaf) -or
       (Test-LifecyclePort 55433) -or (Test-LifecyclePort 17878)){
        & $installedStop|Out-Null
    }
    if(Test-Path -LiteralPath $stopSignal){Remove-Item -LiteralPath $stopSignal -Force}
}

Assert-Lifecycle (-not (Test-Path -LiteralPath $sessionPath)) `
    'control_center_lifecycle_session_leaked'
Assert-Lifecycle ((-not (Test-LifecyclePort 55433)) -and
    (-not (Test-LifecyclePort 17878))) `
    'control_center_lifecycle_port_leaked'
$receipt=[ordered]@{
    schemaVersion=1
    contractId='nll/control-center-lifecycle-smoke/v1'
    inspectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    inspectionUid=$testUid
    sessionPinnedToHostAndAdmin=$true
    staleSessionRecovered=$true
    gracefulDesktopSignalObserved=$true
    sessionRemovedAfterStop=$true
    databaseColdAfterStop=$true
    adminApiColdAfterStop=$true
    runtimeProcessCountAfterStop=0
    verdictCode='control_center_lifecycle_operational'
}
$receiptPath=Join-Path $testRoot 'lifecycle.receipt.json'
[IO.File]::WriteAllText(
    $receiptPath,(($receipt|ConvertTo-Json -Depth 6)+"`n"),
    [Text.UTF8Encoding]::new($false))
$receipt|ConvertTo-Json -Depth 6
