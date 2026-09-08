# Run the real DB-readiness block with fake pg_ctl and temporary bindings only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'recover-nll-phase-d-orphaned-execution.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) { throw 'recovery_parse_failed' }
$block = $ast.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$runtimeRolledBack -or $hasPendingPayload' },$true)
if ($null -eq $block) { throw 'database_restart_still_depends_only_on_pending' }
$action = [scriptblock]::Create($block.Extent.Text)
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-recovery-db-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$names = @('NLL_CONTROL_CENTER_PG_CTL','NLL_CONTROL_CENTER_PG_DATA','NLL_CONTROL_CENTER_PG_LOG')
$before = @{}
foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name) }
function Assert-Recovery([bool]$Condition,[string]$Code) { if (-not $Condition) { throw $Code } }
function Invoke-RecoveryPgCtl {
    param($PgCtlPath,$Arguments)
    $script:commands += $Arguments[0]
    if ($Arguments[0] -eq 'start') { if ($script:failStart) { return 1 }; $script:ready = $true; return 0 }
    if ($script:ready) { return 0 }; return 3
}
try {
    $fakeTool = Join-Path $root 'fake-pgctl'
    [IO.File]::WriteAllText($fakeTool,'never-executed')
    $env:NLL_CONTROL_CENTER_PG_CTL = $fakeTool
    $env:NLL_CONTROL_CENTER_PG_DATA = $root
    $env:NLL_CONTROL_CENTER_PG_LOG = Join-Path $root 'unused.log'
    foreach ($case in @('unchanged','pending','already-ready','start-failed')) {
        $runtimeRolledBack = $case -ne 'pending'
        $hasPendingPayload = $case -eq 'pending'
        $script:commands = @(); $script:ready = $case -eq 'already-ready'; $script:failStart = $case -eq 'start-failed'
        $failed = $false
        try { & $action } catch {
            if ($_.Exception.Message -cne 'phase_d_orphan_recovery_database_start_failed') { throw }
            $failed = $true
        }
        if ($failed -ne $script:failStart) { throw 'restart_failure_not_preserved' }
        $expected = switch ($case) { 'already-ready' { 'status' }; 'start-failed' { 'status,start' }; default { 'status,start,status' } }
        if (($script:commands -join ',') -cne $expected) { throw 'database_restart_sequence_invalid' }
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$before[$name],'Process') }
    $resolved = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-recovery-db-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D recovery DB: unchanged/pending/already-ready/start-failure cases passed without a DB process.'
