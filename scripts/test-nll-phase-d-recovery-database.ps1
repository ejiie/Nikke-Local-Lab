# Run real DB-readiness and pointer recovery branches with synthetic resources only.
$ErrorActionPreference = 'Stop'
$jobRequired = $false
$replayOnly = $false
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'recover-nll-phase-d-orphaned-execution.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) { throw 'recovery_parse_failed' }
$block = $ast.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$runtimeRolledBack -or $hasPendingPayload' },$true)
if ($null -eq $block) { throw 'database_restart_still_depends_only_on_pending' }
$action = [scriptblock]::Create($block.Extent.Text)
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-recovery-db-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$launchRoot = $root
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
    # Exercise the complete pointer recovery branch. Capturing changed bytes is
    # a prerequisite for restoring the baseline and retiring the active pointer.
    $outerTry=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
    $restoreBlocks=@($outerTry.Body.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and
        $null -ne $_.Find({param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-SoloRaidCapture'
        },$false)
    })
    Assert-Recovery ($restoreBlocks.Count -eq 1) 'recovery_restore_branch_ambiguous'
    $restore=[scriptblock]::Create($restoreBlocks[0].Extent.Text)
    $hashFunction=$ast.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-Sha256Lower'
    },$false)
    . ([scriptblock]::Create($hashFunction.Extent.Text))
    function Invoke-SoloRaidCapture {
        param($SourceDatabasePath)
        $script:captureCalls++
        Assert-Recovery ([IO.File]::ReadAllText($SourceDatabasePath) -ceq 'changed') 'capture_after_baseline_restore'
        if($case -eq 'capture-failed'){throw 'synthetic_capture_failed'}
        if($case -ne 'missing-pending'){[IO.File]::WriteAllText($SoloRaidPendingPayloadPath,'captured')}
    }
    foreach($case in @('unchanged','changed','existing-pending','capture-failed','missing-pending','missing-baseline')) {
        $evidenceRoot=Join-Path $root $case
        $runRoot=Join-Path $evidenceRoot 'run'; $runtimeRoot=Join-Path $evidenceRoot 'runtime'
        $null=New-Item -ItemType Directory -Path $runRoot,$runtimeRoot
        $dbBefore=Join-Path $runRoot 'db.before.bin'; $runtimeDbPath=Join-Path $runtimeRoot 'db.json'
        if($case -ne 'missing-baseline'){[IO.File]::WriteAllText($dbBefore,'baseline')}
        $original=if($case -eq 'unchanged'){'baseline'}else{'changed'}
        [IO.File]::WriteAllText($runtimeDbPath,$original)
        $SoloRaidPendingPayloadPath=Join-Path $evidenceRoot 'pending'
        if($case -eq 'existing-pending'){[IO.File]::WriteAllText($SoloRaidPendingPayloadPath,'existing')}
        $pointerPath=Join-Path $runRoot 'active-run.pointer.json'
        [IO.File]::WriteAllText($pointerPath,(@{contractId='nll/phase3b2-epinel-minimal-active-run-pointer/v1';runRoot=$runRoot} | ConvertTo-Json))
        $pointer=Get-Item -LiteralPath $pointerPath
        $script:captureCalls=0; $failure=$null
        try { & $restore } catch { $failure=$_.Exception.Message }
        $expectedFailure=switch($case){
            'capture-failed' {'synthetic_capture_failed'}
            'missing-pending' {'phase_d_raid_state_capture_missing_before_rollback'}
            'missing-baseline' {'phase_d_orphan_recovery_baseline_missing'}
            default {$null}
        }
        Assert-Recovery ($failure -ceq $expectedFailure) 'recovery_capture_failure_not_preserved'
        Assert-Recovery ((Test-Path -LiteralPath $pointerPath) -eq ($null -ne $failure)) 'recovery_pointer_retired_before_capture'
        $archives=@(Get-ChildItem -LiteralPath $runRoot -Filter 'active-run.pointer.orphan-recovery-*.json')
        $expectedArchives=if($null -eq $failure){1}else{0}
        Assert-Recovery ($archives.Count -eq $expectedArchives) 'recovery_pointer_archive_missing'
        if($archives.Count){
            $archived=Get-Content -LiteralPath $archives[0].FullName -Raw | ConvertFrom-Json
            Assert-Recovery ($archived.runRoot -ceq $runRoot) 'recovery_pointer_archive_changed'
        }
        $expectedDb=if($null -eq $failure){'baseline'}else{$original}
        Assert-Recovery ([IO.File]::ReadAllText($runtimeDbPath) -ceq $expectedDb) 'recovery_database_lost_before_capture'
        $expectedCalls=if($case -in @('changed','capture-failed','missing-pending')){1}else{0}
        Assert-Recovery ($script:captureCalls -eq $expectedCalls) 'recovery_recaptured_existing_pending'
        if($case -in @('changed','existing-pending')){
            $expectedPending=if($case -eq 'changed'){'captured'}else{'existing'}
            Assert-Recovery ([IO.File]::ReadAllText($SoloRaidPendingPayloadPath) -ceq $expectedPending) 'recovery_pending_not_preserved'
        }
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$before[$name],'Process') }
    $resolved = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-recovery-db-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D recovery DB: 4 readiness and 6 capture/restore/pointer cases passed without a DB process.'
