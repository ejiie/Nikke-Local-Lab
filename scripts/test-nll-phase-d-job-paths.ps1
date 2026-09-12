# Execute real capture and failure gate bodies with synthetic services only.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerOperations.ps1')
function Check-PathTest([bool]$Value) { if (-not $Value) { throw 'job_path_test_failed' } }
function Ast-PathTest($Name) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name),[ref]$tokens,[ref]$errors)
    Check-PathTest ($errors.Count -eq 0)
    $ast
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('nll-job-paths-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$count=0
function Invoke-TestMaterializer {
    $script:captureArguments=@($args)
    [IO.File]::WriteAllText($spec.soloRaidPendingPath,'synthetic')
    [IO.File]::WriteAllText($spec.soloRaidCaptureReceiptPath,'synthetic')
    $global:LASTEXITCODE=0
}
try {
    $spec=@{runtimeMaterializer='Invoke-TestMaterializer';soloRaidPendingPath=(Join-Path $root 'pending');soloRaidCaptureReceiptPath=(Join-Path $root 'capture')}
    foreach ($field in @('accountUid','accountRevisionSetSha256','seasonNumber','raidSnapshotUid','raidSnapshotSha256','clientBuildCode','clientExecutableSha256','launchContextUid','expectedSoloRaidHeadRevisionUid','secretEnvironmentVariable')) { $spec[$field]='synthetic' }
    foreach ($version in @(1,2,3)) {
        foreach ($weakness in @('fire','water','wind','electric','iron')) {
            $spec.contractId='nll/phase-d-runner-input/v'+$version; $spec.weaknessCode=$weakness
            Invoke-PhaseDRunnerCapture $spec (Join-Path $root 'synthetic-db')
            $index=[Array]::IndexOf($script:captureArguments,'--weakness-code')
            if ($version -eq 1) { Check-PathTest ($index -eq -1) }
            else { Check-PathTest ($index -ge 0 -and $script:captureArguments[$index+1] -ceq $weakness) }
            $count++
        }
    }
    # Execute recovery's separate capture function, not just the shared runner path.
    $recoveryAst=Ast-PathTest 'recover-nll-phase-d-orphaned-execution.ps1'
    $captureFunction=@($recoveryAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-SoloRaidCapture'},$true))[0]
    . ([scriptblock]::Create($captureFunction.Extent.Text))
    function Assert-Recovery { param($Condition,$Code) if (-not $Condition) { throw $Code } }
    $launchRoot=$root; $LaunchContextUid=[guid]::NewGuid().ToString('D'); $identitySecretEnvironmentVariable='SYNTHETIC_SECRET'
    $runtimeMaterializerPath=Join-Path $root 'synthetic-materializer.ps1'
    $SoloRaidPendingPayloadPath=Join-Path $root 'recovery-pending'; $soloRaidCaptureReceiptPath=Join-Path $root 'recovery-capture'
    $sourceDb=Join-Path $root 'synthetic-db'
    [IO.File]::WriteAllText($sourceDb,'synthetic')
    [IO.File]::WriteAllText($runtimeMaterializerPath, @'
$global:phaseDTestRecoveryArgs=@($args)
[IO.File]::WriteAllText($args[[Array]::IndexOf($args,'--pending-payload')+1],'synthetic')
[IO.File]::WriteAllText($args[[Array]::IndexOf($args,'--receipt')+1],'synthetic')
$global:LASTEXITCODE=0
'@)
    $context=@{contractId='nll/launch-context/v1';launchContextUid=$LaunchContextUid;accountUid='synthetic';accountRevisionSetSha256=('a'*64);seasonNumber=29;raidSnapshotUid='synthetic';raidSnapshotSha256=('b'*64);clientBuildCode='build_151.8.5';clientExecutableSha256=('c'*64);weaknessCode='iron'}
    $materialization=@{accountUid='synthetic';accountRevisionSetSha256=('a'*64);raidSeasonNumber=29;raidSnapshotUid='synthetic';raidSnapshotSha256=('b'*64);soloRaidStateHeadRevisionUid=$null}
    [IO.File]::WriteAllText((Join-Path $root 'materialization.receipt.json'),($materialization | ConvertTo-Json))
    foreach ($version in @(2,3)) {
        foreach ($weakness in @('fire','water','wind','electric','iron')) {
            $context.weaknessCode=$weakness
            [IO.File]::WriteAllText((Join-Path $root 'launch-context.json'),($context | ConvertTo-Json))
            $recoveryBundle=@{specification=@{contractId=('nll/phase-d-runner-input/v'+$version);weaknessCode=$weakness}}
            Invoke-SoloRaidCapture $sourceDb
            $index=[Array]::IndexOf($global:phaseDTestRecoveryArgs,'--weakness-code')
            Check-PathTest ($index -ge 0 -and $global:phaseDTestRecoveryArgs[$index+1] -ceq $weakness); $count++
            Remove-Item -LiteralPath $SoloRaidPendingPayloadPath,$soloRaidCaptureReceiptPath
        }
    }
    function Write-PhaseDFirstFailure { }
    function Set-ExecutionState { param($StatusCode,$FailureCode) $script:terminal=$StatusCode }
    function Stop-PhaseDExecutionJob { throw 'synthetic_job_zero_failure' }
    function Invoke-PhaseDEmergencyRollback { $script:rollbacks++; throw 'unexpected_rollback' }
    $launchRoot=$root; $runnerBundle=@{sha256=('a'*64)}; $jobAttempted=$true; $watcherOwnershipTransferred=$false; $watcherSpawned=$false; $coordinatorStage='start'
    $script:rollbacks=0; $script:terminal=$null
    $ast=Ast-PathTest 'invoke-nll-phase-d-execution.ps1'
    $outer=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    $action=[scriptblock]::Create("try { throw 'synthetic_start_failure' } " + $outer.CatchClauses[0].Extent.Text)
    try { & $action } catch { Check-PathTest ($_.Exception.Message -ceq 'phase_d_job_zero_unproven') }
    Check-PathTest ($script:terminal -ceq 'started' -and $script:rollbacks -eq 0); $count++
    # Spawned-but-uncommitted watcher must exit BEFORE coordinator attempts Job stop.
    $watcherSpawned=$true; $script:watcherKilled=$false
    $watcherProcess=[pscustomobject]@{HasExited=$false}
    $watcherProcess | Add-Member ScriptMethod Kill { $script:watcherKilled=$true }
    $watcherProcess | Add-Member ScriptMethod WaitForExit { param($ms) return $script:watcherKilled }
    function Test-PhaseDJobHandoffCommitted { return $script:committed }
    function Stop-PhaseDExecutionJob { Check-PathTest $script:watcherKilled; throw 'synthetic_job_zero_failure' }
    $script:committed=$false
    try { & $action } catch { Check-PathTest ($_.Exception.Message -ceq 'phase_d_job_zero_unproven') }
    Check-PathTest $script:watcherKilled; $count++
    $script:committed=$true; $script:watcherKilled=$false
    try { & $action } catch { Check-PathTest ($_.Exception.Message -ceq 'synthetic_start_failure') }
    Check-PathTest (-not $script:watcherKilled -and $watcherOwnershipTransferred -eq $false); $count++ # action-local ownership, no coordinator cleanup

    function Assert-PhaseDChildrenExited { }
    function Invoke-PhaseDStateLock { param($LaunchRoot,$Action) & $Action }
    function Write-AtomicJson { param($Path,$Value) [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8)) }
    $LaunchRoot=$root; $ExpectedRunnerBundleSha256='a'*64; $jobRequired=$true; $physicalCleanupCommitted=$false; $statePath=Join-Path $root 'state.json'
    Write-AtomicJson $statePath @{statusCode='started';failureCode=$null}
    $ast=Ast-PathTest 'watch-nll-phase-d-execution.ps1'
    $outer=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    $action=[scriptblock]::Create("try { throw 'synthetic_completion_failure' } " + $outer.CatchClauses[0].Extent.Text)
    try { & $action } catch { Check-PathTest ($_.Exception.Message -ceq 'phase_d_job_cleanup_unproven') }
    $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Check-PathTest ($state.statusCode -ceq 'started' -and $state.failureCode -ceq 'phase_d_job_cleanup_unproven'); $count++

    # The actual recovery branch must check non-start children BEFORE stop,
    # then check ALL children BEFORE FX cleanup. A late non-start child stops it.
    $ast=Ast-PathTest 'recover-nll-phase-d-orphaned-execution.ps1'
    $branch=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains('$executionJob = Open-PhaseDExecutionJob')},$true))[0]
    $action=[scriptblock]::Create($branch.Extent.Text)
    function Open-PhaseDExecutionJob { [pscustomobject]@{synthetic=$true} }
    function Assert-PhaseDChildrenExited { param($LaunchRoot,$RuntimeStartJob) if ($script:late) { throw 'late_child' }; $script:trace += $(if ($null -ne $RuntimeStartJob) {'pre'} else {'post'}) }
    function Stop-PhaseDExecutionJob { $script:trace+='stop' }
    function Invoke-PhaseDExecutionFxCleanup { $script:trace+='fx' }
    function Protect-PhaseDJobServerLog { $script:trace+='redact' }
    function Invoke-PhaseDWithJobZeroProof { $script:trace+='proof' }
    $recoveryBundle=@{sha256=('a'*64)}
    $cleanupCheckpoint=@{startIdentitySha256=$null}
    $replayOnly=$false
    $script:late=$false; $script:trace=@(); & $action
    Check-PathTest (($script:trace -join ',') -ceq 'pre,stop,pre,redact,fx,proof'); $count++
    $script:late=$true; $script:trace=@()
    try { & $action } catch { Check-PathTest ($_.Exception.Message -ceq 'late_child') }
    Check-PathTest ($script:trace.Count -eq 0); $count++
    $replayOnly=$true; $script:late=$false; $script:trace=@(); & $action
    Check-PathTest (($script:trace -join ',') -ceq 'post'); $count++ # replay-only never opens/stops Job or invokes physical FX cleanup
    # Run the actual PG-failure prefix from all three production owners. Stop
    # immediately at their PG boundary after checking durable checkpoint order.
    function Write-PhaseDRollbackCleanupCheckpoint { $script:checkpoint=$true }
    function Invoke-PhaseDPgCtl { Check-PathTest $script:checkpoint; throw 'synthetic_pg_failure' }
    function Invoke-RecoveryPgCtl { Check-PathTest $script:checkpoint; throw 'synthetic_pg_failure' }
    function Assert-Recovery { }
    $jobAttempted=$true; $jobRequired=$true; $replayOnly=$false; $physicalCleanupCommitted=$false
    $controlCenterPgCtl='synthetic';$controlCenterPgData=$root;$controlCenterPgLog='synthetic'
    $ControlCenterPgCtlPath='synthetic';$ControlCenterPgDataPath=$root;$ControlCenterPgLogPath='synthetic'
    foreach ($file in @('invoke-nll-phase-d-execution.ps1','watch-nll-phase-d-execution.ps1','recover-nll-phase-d-orphaned-execution.ps1')) {
        $ast=Ast-PathTest $file
        $write=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Write-PhaseDRollbackCleanupCheckpoint'},$true))[0]
        $pg=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.StartOffset -gt $write.Extent.StartOffset -and
            $n.Right.Extent.Text -match '^Invoke-(PhaseD|Recovery)PgCtl'},$true))[0]
        $start=$write.Parent
        while ($start -isnot [Management.Automation.Language.IfStatementAst]) { $start=$start.Parent }
        $prefix=$ast.Extent.Text.Substring($start.Extent.StartOffset,$pg.Extent.EndOffset-$start.Extent.StartOffset)
        $script:checkpoint=$false
        try { & ([scriptblock]::Create($prefix)) } catch { Check-PathTest ($_.Exception.Message -ceq 'synthetic_pg_failure') }
        Check-PathTest $script:checkpoint; $count++
        $script:trace=@(); $script:late=$false; $replayOnly=$true; & $action
        Check-PathTest (($script:trace -join ',') -ceq 'post'); $count++
        $replayOnly=$false
    }
    "Phase D Job paths: $count synthetic capture-version and production failure/order checks passed."
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notlike 'nll-job-paths-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
