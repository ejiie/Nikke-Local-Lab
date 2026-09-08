# Execute the actual outer failure block with synthetic files and fake services.
# The coordinator body, game, hosts, firewall and real DB are NEVER executed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'coordinator_parse_failed' }
$outerTry = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
$failureBlock = [scriptblock]::Create("try { throw 'synthetic_start_failed' } " + $outerTry.CatchClauses[0].Extent.Text)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-coordinator-failure-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
function Assert-PhaseD([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
function Test-PhaseDDerivedStartRollbackProof { $script:proof }
function Invoke-PhaseDEmergencyRollback { throw [ComponentModel.Win32Exception]::new(5, 'synthetic password=do-not-log') }
function Invoke-PhaseDPgCtl { $script:pgStarts++; return $script:pgExitCode }
function Get-Sha256Lower { param([string]$Path) (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Write-AtomicJson { param($Path, $Value) $script:receipt = $Value }
function Set-ExecutionState { param($StatusCode, $FailureCode) $script:lastState = $StatusCode; $script:lastFailure = $FailureCode }
try {
    foreach ($case in @('unproven', 'proven', 'pg-failure', 'watcher-owner')) {
        $script:proof = $case -ne 'unproven'
        $script:pgStarts = 0
        $script:pgExitCode = if ($case -eq 'pg-failure') { 1 } else { 0 }
        $script:lastState = $null
        $script:lastFailure = $null
        $watcherOwnershipTransferred = $case -eq 'watcher-owner'
        $coordinatorStage = 'runtime_identity_capture'
        $controlCenterDatabaseStopped = $true
        $controlCenterHostsPrepared = $true
        $launchRoot = $testRoot
        $evidenceRoot = $testRoot
        $runtimeRoot = $testRoot
        $runtimeDbPath = Join-Path $testRoot 'synthetic-db.json'
        $runtimeDbSha256 = 'synthetic-unused'
        $hostsPath = Join-Path $testRoot 'synthetic-hosts.txt'
        $controlCenterHostsBackupPath = Join-Path $testRoot 'synthetic-hosts.before'
        [IO.File]::WriteAllText($hostsPath, 'isolated')
        [IO.File]::WriteAllText($controlCenterHostsBackupPath, 'baseline')
        $controlCenterHostsOriginalSha256 = Get-Sha256Lower $controlCenterHostsBackupPath
        $expectedCleanHostsSha256 = $controlCenterHostsOriginalSha256
        $expectedPostDockerUninstallCleanHostsSha256 = $controlCenterHostsOriginalSha256
        $LaunchContextUid = [guid]::NewGuid().ToString()
        $controlCenterPgCtl = 'synthetic-pgctl'
        $controlCenterPgData = 'synthetic-data'
        $controlCenterPgLog = 'synthetic-log'
        $thrown = $false
        try { & $failureBlock } catch {
            if ($_.Exception.Message -notin @('synthetic_start_failed', 'phase_d_emergency_rollback_failed', 'phase_d_control_center_database_restart_failed')) { throw }
            $thrown = $true
        }
        Assert-PhaseD $thrown 'expected_failure_not_thrown'
        $primary = Get-Content -LiteralPath (Join-Path $testRoot 'coordinator-failure.detail.json') -Raw | ConvertFrom-Json
        Assert-PhaseD ($primary.failureCode -ceq 'synthetic_start_failed') 'coordinator_primary_failure_overwritten'
        if ($case -in @('unproven','pg-failure')) {
            $cleanupStage = if ($case -eq 'unproven') { 'rollback' } else { 'database_restart' }
            $secondaryText = Get-Content -LiteralPath (Join-Path $testRoot ('coordinator-cleanup-' + $cleanupStage + '-failure.detail.json')) -Raw
            $secondary = $secondaryText | ConvertFrom-Json
            Assert-PhaseD ($secondary.contractId -ceq 'nll/phase-d-cleanup-failure/v1' -and $secondary.stage -ceq $cleanupStage) 'coordinator_secondary_failure_missing'
            Assert-PhaseD (-not $secondaryText.Contains('do-not-log')) 'coordinator_secondary_secret_leaked'
            if ($case -eq 'unproven') { Assert-PhaseD ($secondary.nativeErrorCode -eq 5) 'coordinator_secondary_native_code_lost' }
        }
        if ($case -in @('unproven', 'watcher-owner')) {
            Assert-PhaseD ($script:pgStarts -eq 0) 'unproven_runtime_restarted_database'
            Assert-PhaseD ([IO.File]::ReadAllText($hostsPath) -ceq 'isolated') 'unproven_runtime_restored_hosts'
            if ($case -eq 'unproven') { Assert-PhaseD ($script:lastState -ceq 'started') 'unproven_runtime_marked_terminal' }
            else { Assert-PhaseD ($null -eq $script:lastState) 'coordinator_overwrote_watcher' }
        }
        else {
            Assert-PhaseD ($script:pgStarts -eq 1) 'proven_rollback_did_not_restart_database'
            $expectedState = if ($case -eq 'pg-failure') { 'started' } else { 'failed' }
            Assert-PhaseD ($script:lastState -ceq $expectedState) 'cleanup_failure_not_reconcilable'
            Assert-PhaseD ([IO.File]::ReadAllText($hostsPath) -ceq 'baseline') 'proven_rollback_did_not_restore_hosts'
            if ($case -eq 'pg-failure') {
                Assert-PhaseD ($script:lastFailure -ceq 'phase_d_control_center_database_restart_failed') 'pg_failure_hidden'
            }
        }
    }
}
finally {
    $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-coordinator-failure-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D coordinator failure: 4 synthetic cases passed; no operational resources touched.'
