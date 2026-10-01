# Execute production coordinator failure and recovery bodies against synthetic resources.
# Real Job/identity/proof/checkpoint code runs; firewall, PG and native store are test adapters.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDCompletion.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDJob.ps1')
function Check([bool]$ok,[string]$code) { if (-not $ok) { throw $code } }
function Parse([string]$name) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'parse_failed'; return $ast
}
$coordinator=Parse 'invoke-nll-phase-d-execution.ps1'
$recovery=Parse 'recover-nll-phase-d-orphaned-execution.ps1'
foreach ($ast in @($coordinator,$recovery)) {
    foreach ($name in @('Assert-PhaseD','Assert-Recovery','Get-Sha256Lower','Invoke-PhaseDEmergencyRollback','Test-PinnedProcess')) {
        $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
        if ($null -ne $definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
    }
}
$outer=@($coordinator.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
$failure=[scriptblock]::Create("try { throw 'synthetic_start_failure' } "+$outer.CatchClauses[0].Extent.Text)
$outer=@($recovery.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
$root=Join-Path ([IO.Path]::GetTempPath()) ('nll-startup-cleanup-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
# Redirect only the fixed pending-state location to this disposable fixture.
$recover=[scriptblock]::Create($outer.Body.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}').Replace('C:\NLL\ControlCenter\state\phase-d-solo-raid',(Join-Path $root 'pending')).Replace("Join-Path `$env:SystemRoot 'System32\drivers\etc\hosts'",'Get-PhaseDJobSystemHostsPath'))
$oldSystemRoot=$env:SystemRoot
$envNames=@('NLL_SYNTHETIC_CONNECTION','NLL_SYNTHETIC_SECRET','NLL_CONTROL_CENTER_PG_CTL','NLL_CONTROL_CENTER_PG_DATA','NLL_CONTROL_CENTER_PG_LOG')
$oldEnv=@{};foreach($name in $envNames){$oldEnv[$name]=[Environment]::GetEnvironmentVariable($name)}
function Get-PhaseDJobSystemHostsPath { $hostsPath }
function Get-NetFirewallRule { param($Group,$ErrorAction) @() }
function Get-PhaseDIsolationRules { param($Name) [pscustomobject]@{name='NLL.PhaseD151.Program.1';program='C:\NIKKE\synthetic.exe';enabled=$script:blocked} }
function Get-CimInstance { param($ClassName,$ErrorAction) @() }
function Disable-NetFirewallRule { param($Name,$ErrorAction) $script:blocked=$false; $script:trace.Add('isolation') }
function Enable-NetFirewallRule { throw 'unexpected_enable' }
function Get-Process { param($Name,$ErrorAction) @() } # The recovery name scan; identity checks still use native handles.
function Write-PhaseDProgress { param($LaunchRoot,$Stage) }
function Invoke-RecoveryPgCtl { param($PgCtlPath,$Arguments) Check (-not $script:blocked) 'pg_before_isolation';$script:trace.Add('pg');0 }
function Ensure-PhaseDPostgresRunning { param($OwnershipPath,$PgCtlPath,$DataPath,$LogPath) Check (-not $script:blocked) 'pg_before_isolation';$script:trace.Add('pg') }
function Set-ExecutionState { param($StatusCode,$FailureCode) $script:finalState=$StatusCode }
function Invoke-PhaseDExecutionFxCleanup {
    param($LaunchRoot,$ExpectedBundleSha256)
    Invoke-PhaseDWithJobZeroProof $LaunchRoot $ExpectedBundleSha256 {
        param($proof,$verify,$sha)
        $verify.Invoke();$script:trace.Add('fx')
        $written=if ([IO.File]::ReadAllText($storePath) -ceq 'after!') {6} else {0}
        [IO.File]::WriteAllText($storePath,'before')
        Write-AtomicJson (Join-Path $fxRoot 'retired.json') @{
            contractId='nll/common-native-fx-retired/v2';manifestSha256=$spec.executionFx.manifestSha256
            terminationReceiptSha256=$sha;actualGameAcceptanceClaimed=$false
            rangeReceipt=@{contractId='nll/common-native-fx-range-receipt/v2';validationScope='patched_ranges';state='restored'
                executionUid=$LaunchContextUid;planSha256=('c'*64);selectedBytes=6;bytesRead=6;bytesWritten=$written}
        }
        $verify.Invoke()
    }
}
$count=0
try {
    foreach ($case in @('coordinator','unapplied','applied','runtime-alive','child-alive')) {
        $LaunchContextUid=[guid]::NewGuid().ToString('D');$ExecutionRoot=$root;$launchRoot=Join-Path $root $LaunchContextUid
        $runtimeRoot=Join-Path $launchRoot 'runtime';$evidenceRoot=Join-Path $launchRoot 'evidence';$fxRoot=Join-Path $runtimeRoot 'execution-fx'
        $null=New-Item -ItemType Directory -Path $fxRoot,$evidenceRoot
        $syntheticWindows=Join-Path $launchRoot 'synthetic-windows'
        $null=New-Item -ItemType Directory -Path (Join-Path $syntheticWindows 'System32/drivers/etc')
        $hostsPath=Join-Path $syntheticWindows 'System32/drivers/etc/hosts'
        $controlCenterHostsBackupPath=Join-Path $launchRoot 'control-center-hosts.before.bin'
        [IO.File]::WriteAllText($hostsPath,'hosts-before');[IO.File]::WriteAllText($controlCenterHostsBackupPath,'hosts-before')
        $controlCenterHostsOriginalSha256=Get-Sha256Lower $hostsPath
        $expectedCleanHostsSha256=$controlCenterHostsOriginalSha256;$expectedPostDockerUninstallCleanHostsSha256=$controlCenterHostsOriginalSha256
        $runtimeDbPath=Join-Path $runtimeRoot 'db.json';[IO.File]::WriteAllText($runtimeDbPath,'baseline');$runtimeDbSha256=Get-Sha256Lower $runtimeDbPath
        $storePath=Join-Path $launchRoot 'synthetic-store';[IO.File]::WriteAllText($storePath,$(if($case -ceq 'applied'){'after!'}else{'before'}))
        Write-AtomicJson (Join-Path $fxRoot 'manifest.private.json') @{contractId='nll/common-native-fx-execution/v2';rangePlanSha256=('c'*64);patches=@(@{before=@{length=6}})}
        $spec=@{contractId='nll/phase-d-runner-input/v3';launchRoot=$launchRoot;launchContextUid=$LaunchContextUid;jobNonce=[guid]::NewGuid().ToString('N')
            runtimeDbSha256=$runtimeDbSha256;executionFx=@{manifestSha256=(Get-Sha256Lower (Join-Path $fxRoot 'manifest.private.json'))}}
        $runnerBundle=@{sha256=('a'*64);specification=$spec};$recoveryBundle=$runnerBundle;$script:PhaseDVerifiedRunnerBundle=$runnerBundle
        $script:PhaseDAllowAbsentJobRecovery=$case -cne 'coordinator'
        $job=New-PhaseDExecutionJob $launchRoot $runnerBundle.sha256
        Stop-PhaseDExecutionJob $launchRoot $runnerBundle.sha256
        $executionJob=$job
        if($case -cne 'coordinator'){$job.Dispose();$executionJob=$null}
        $script:blocked=$true;$script:trace=[Collections.Generic.List[string]]::new()
        Write-PhaseDIsolationJson (Join-Path $launchRoot 'shared-isolation.before.json') @{contractId='nll/phase-d-shared-isolation/v1';launchRoot=$launchRoot
            runnerBundleSha256=$runnerBundle.sha256;rules=@(@{name='NLL.PhaseD151.Program.1';program='C:\NIKKE\synthetic.exe';enabled=$false});services=@()}
        $statePath=Join-Path $launchRoot 'execution-state.json'
        Write-AtomicJson $statePath @{contractId='nll/phase-d-execution-state/v1';launchContextUid=$LaunchContextUid;statusCode='started';clientProcessId=$null;failureCode=$null;updatedAtUtc='synthetic'}
        if($case -in @('runtime-alive','child-alive')) {
            $self=[Diagnostics.Process]::GetCurrentProcess()
            try{$identity=@{processId=$PID;processStartedAtUtc=$self.StartTime.ToUniversalTime().ToString('o');executablePath=$self.MainModule.FileName}}finally{$self.Dispose()}
            if($case -ceq 'runtime-alive') {Write-AtomicJson (Join-Path $launchRoot 'runtime-processes.identity.json') @{contractId='nll/phase-d-runtime-process-identities/v1';launchContextUid=$LaunchContextUid;client=$identity;bootstrap=$null;server=$null}}
            else {$identity.contractId='nll/phase-d-child-deadline/v1';Write-AtomicJson (Join-Path $launchRoot 'phase-d-child-start.identity.json') $identity}
        }
        $ConfigurationPath=Join-Path $launchRoot 'synthetic-config.json'
        Write-AtomicJson $ConfigurationPath @{database=@{connectionStringEnvironmentVariable='NLL_SYNTHETIC_CONNECTION'};identity=@{hmacSecretEnvironmentVariable='NLL_SYNTHETIC_SECRET'}}
        foreach($name in $envNames){[Environment]::SetEnvironmentVariable($name,$launchRoot)}
        $env:NLL_CONTROL_CENTER_PG_CTL=$storePath
        $replayOnly=$false;$script:finalState=$null;$failureCode=$null
        try {
            if($case -ceq 'coordinator') {
                $jobAttempted=$true;$watcherSpawned=$false;$watcherOwnershipTransferred=$false;$runtimeLifecycleEntered=$true
                $controlCenterHostsPrepared=$true;$coordinatorStage='shared_isolation';$script:PhaseDRunnerIsolationOwned=$false
                $controlCenterPgCtl=$storePath;$controlCenterPgData=$launchRoot;$controlCenterPgLog=$storePath
                try{& $failure}catch{Check ($_.Exception.Message -ceq 'synthetic_start_failure') 'coordinator_cleanup_failed'}
                Check ($script:finalState -ceq 'failed') 'coordinator_not_terminal'
            }else{& $recover | Out-Null}
        } catch {$failureCode=$_.Exception.Message}
        finally {if($null -ne $executionJob){$executionJob.Dispose()}}
        if($case -in @('runtime-alive','child-alive')) {
            Check ($failureCode -cin @('phase_d_process_still_running','phase_d_child_still_running')) 'live_identity_not_rejected'
            Check ($script:blocked -and $script:trace.Count -eq 0) 'live_identity_permitted_cleanup'
            Check ((Get-Content $statePath -Raw | ConvertFrom-Json).statusCode -ceq 'started') 'failed_recovery_became_terminal'
        } else {
            if($failureCode){throw $failureCode}
            Check (($script:trace -join ',') -ceq 'fx,isolation,pg') 'cleanup_order_changed'
            Check (Test-Path (Join-Path $launchRoot 'physical-cleanup.receipt.json')) 'checkpoint_missing'
            $retired=Get-Content (Join-Path $fxRoot 'retired.json') -Raw | ConvertFrom-Json
            Check ($retired.rangeReceipt.bytesWritten -eq $(if($case -ceq 'applied'){6}else{0})) 'unapplied_wrote_bytes'
            if($case -cne 'coordinator'){Check ((Get-Content $statePath -Raw | ConvertFrom-Json).statusCode -ceq 'rolled_back') 'recovery_not_terminal'}
        }
        $count++
    }
    "Startup failure cleanup: $count production coordinator/recovery cases passed with synthetic resources."
} finally {
    $env:SystemRoot=$oldSystemRoot
    foreach($name in $envNames){[Environment]::SetEnvironmentVariable($name,$oldEnv[$name])}
    $full=[IO.Path]::GetFullPath($root)
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($full) -notlike 'nll-startup-cleanup-*'){throw 'unsafe_test_cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
