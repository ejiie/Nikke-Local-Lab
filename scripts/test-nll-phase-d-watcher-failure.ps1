# The real watcher's outer catch, but with synthetic files and fake services.
$ErrorActionPreference = 'Stop'
$jobRequired = $false # Historical branch; new Job failure cases are tested separately.
$physicalCleanupCommitted = $false
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'watch-nll-phase-d-execution.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'watcher_parse_failed' }
$outerTry = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
$failureBlock = [scriptblock]::Create("try { throw 'synthetic_completion_failed' } " + $outerTry.CatchClauses[0].Extent.Text)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-watcher-failure-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
function Assert-Test([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
function Invoke-EmergencyRollback { if (-not $script:proof) { throw [ComponentModel.Win32Exception]::new(31, 'synthetic password=do-not-log') }; $true }
function Restore-ControlCenterHosts {
    $script:hostRestores++
    if ($script:hostsFail) { throw 'synthetic_hosts_failure' }
}
function Invoke-PhaseDPgCtl { $script:pgStarts++; $script:pgExitCode }
function Get-Sha256Lower { 'synthetic-hash' } # no reading actual hosts
function Write-AtomicJson { param($Path, $Value) [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8)) }
try {
    foreach ($case in @('unproven', 'rolled-back', 'pg-failure', 'hosts-failure')) {
        $script:proof = $case -ne 'unproven'
        $script:hostRestores = 0
        $script:pgStarts = 0
        $script:pgExitCode = if ($case -eq 'pg-failure') { 1 } else { 0 }
        $script:hostsFail = $case -eq 'hosts-failure'
        $completionApplied = $false
        $controlCenterHostsRestored = $false
        $databaseRestarted = $false
        $raidStatePersisted = $false
        $LaunchRoot = $testRoot
        $statePath = Join-Path $testRoot 'execution-state.json'
        $contextPath = Join-Path $testRoot 'launch-context.json'
        $watcherLogPath = Join-Path $testRoot 'watcher.log'
        $SoloRaidPendingPayloadPath = Join-Path $testRoot 'absent.pending.json'
        $SoloRaidCaptureReceiptPath = Join-Path $testRoot 'absent.capture.json'
        $ControlCenterHostsOriginalSha256 = 'synthetic-hash'
        $ControlCenterPgCtlPath = 'synthetic-pgctl'
        $ControlCenterPgDataPath = 'synthetic-data'
        $ControlCenterPgLogPath = 'synthetic-log'
        Write-AtomicJson $statePath ([ordered]@{ statusCode = 'started'; clientProcessId = 123; failureCode = $null; updatedAtUtc = $null })
        Write-AtomicJson $contextPath ([ordered]@{ statusCode = 'started' })
        & $failureBlock
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json
        $expectedState = if ($case -eq 'rolled-back') { 'rolled_back' } else { 'started' }
        Assert-Test ($state.statusCode -ceq $expectedState -and $context.statusCode -ceq $expectedState) 'watcher_failure_state_invalid'
        $expectedPgStarts = if ($case -in @('rolled-back', 'pg-failure')) { 1 } else { 0 }
        Assert-Test ($script:pgStarts -eq $expectedPgStarts) 'unproven_watcher_restarted_database'
        if ($case -eq 'unproven') { Assert-Test ($script:hostRestores -eq 0) 'unproven_watcher_restored_hosts' }
        if ($case -eq 'pg-failure') {
            Assert-Test ($state.failureCode -ceq 'phase_d_control_center_database_restart_failed') 'watcher_pg_failure_hidden'
        }
        $primary = Get-Content -LiteralPath (Join-Path $testRoot 'watcher-failure.detail.json') -Raw | ConvertFrom-Json
        Assert-Test ($primary.failureCode -ceq 'synthetic_completion_failed') 'watcher_primary_failure_overwritten'
        $cleanupStage = switch ($case) { 'unproven' { 'rollback' }; 'hosts-failure' { 'hosts_restore' }; 'pg-failure' { 'database_restart' } }
        if ($cleanupStage) {
            $secondaryText = Get-Content -LiteralPath (Join-Path $testRoot ('watcher-cleanup-' + $cleanupStage + '-failure.detail.json')) -Raw
            $secondary = $secondaryText | ConvertFrom-Json
            Assert-Test ($secondary.contractId -ceq 'nll/phase-d-cleanup-failure/v1' -and $secondary.stage -ceq $cleanupStage) 'watcher_secondary_failure_missing'
            Assert-Test (-not $secondaryText.Contains('do-not-log')) 'watcher_secondary_secret_leaked'
            if ($case -eq 'unproven') { Assert-Test ($secondary.nativeErrorCode -eq 31) 'watcher_secondary_native_code_lost' }
        }
    }
}
finally {
    $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-watcher-failure-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D watcher failure: 4 synthetic cases passed; no operational resources touched.'
