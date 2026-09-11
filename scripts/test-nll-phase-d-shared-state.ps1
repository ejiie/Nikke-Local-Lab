$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDCompletion.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-shared-state-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$script:checks = 0
function Assert-Test([bool]$Value) {
    if (-not $Value) { throw 'shared_state_behavior_failed' }
    $script:checks++
}
function Reject-Test([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-Test $failed
}
$contextUid = [guid]::NewGuid().ToString()
$path = Join-Path $root 'state.json'
$capturePath = Join-Path $root 'capture.json'
$pendingPath = Join-Path $root 'pending.json'
$receiptPath = Join-Path $root 'receipt.json'
$contextPath = Join-Path $root 'launch-context.json'
function Read-Proof {
    Read-PhaseDSoloRaidPersistenceReceipt -Path $receiptPath -LaunchRoot $root -LaunchContextUid $contextUid `
        -PendingPayloadPath $pendingPath -CaptureReceiptPath $capturePath
}
try {
    $childInfo = [Diagnostics.ProcessStartInfo]::new()
    $childInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childInfo.Arguments = '-NoLogo -NoProfile -Command "Start-Sleep -Seconds 30"'
    $childInfo.UseShellExecute = $false; $childInfo.CreateNoWindow = $true
    $child = [Diagnostics.Process]::Start($childInfo)
    $ownedPath = Join-Path $root 'phase-d-child-test.identity.json'
    try {
        Reject-Test { Wait-PhaseDChildDeadline -Process $child -TimeoutSeconds 1 -OwnershipPath $ownedPath }
        Assert-Test (-not $child.HasExited)
        Assert-Test ((Get-Content -LiteralPath $ownedPath -Raw | ConvertFrom-Json).processId -eq $child.Id)
        Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $root -RequireEvidence }
        Assert-Test (-not $child.HasExited)
    } finally {
        # Exact synthetic fixture only; never the production timeout policy.
        if (-not $child.HasExited) { $child.Kill() }
        $child.WaitForExit(); $child.Dispose()
    }
    Assert-PhaseDChildrenExited -LaunchRoot $root -RequireEvidence
    Assert-Test $true
    $stubPath = Join-Path $root 'synthetic-child.ps1'
    [IO.File]::WriteAllText($stubPath, 'param([string]$Text) Write-Output $Text; exit 7', [Text.UTF8Encoding]::new($false))
    $childResult = Invoke-PhaseDChildScript -ScriptPath $stubPath -Arguments @{Text="synthetic ' quote"} `
        -StandardOutputPath (Join-Path $root 'out.log') -StandardErrorPath (Join-Path $root 'err.log') `
        -TimeoutSeconds 10 -OwnershipPath (Join-Path $root 'phase-d-child-stub.identity.json')
    Assert-Test ($childResult.ExitCode -eq 7 -and $childResult.StandardOutput.Trim() -ceq "synthetic ' quote")
    Assert-PhaseDChildrenExited -LaunchRoot $root -RequireEvidence
    Assert-Test $true
    Write-PhaseDChildReservation -OwnershipPath $ownedPath -ExecutablePath $childInfo.FileName
    Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $root -RequireEvidence }
    $missingExecutable = Join-Path $root 'nonexistent-synthetic-child.exe'
    $startFailure = $null
    try { Invoke-PhaseDPgCtl -PgCtlPath $missingExecutable -Arguments @() -OwnershipPath $ownedPath | Out-Null }
    catch { $startFailure = $_.Exception.Message }
    Assert-Test ($startFailure -ceq 'phase_d_child_deadline_unproven')
    Assert-Test ((Get-Content -LiteralPath $ownedPath -Raw | ConvertFrom-Json).processId -eq 0)
    Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $root -RequireEvidence }
    Write-AtomicJson $path @{ revision=1; text='synthetic Unicode: \u2603' }
    $before = [IO.File]::ReadAllBytes($path)
    Assert-Test ($before[0] -ne 239 -and $before[-1] -eq 10)
    Write-AtomicJson $path @{ revision=2 }
    Assert-Test ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).revision -eq 2)
    $before = [IO.File]::ReadAllBytes($path)
    $locked = [IO.File]::Open($path, 'Open', 'Read', 'Read')
    try { Reject-Test { Write-AtomicJson $path @{revision=3} } }
    finally { $locked.Dispose() }
    Assert-Test ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)))
    Assert-Test (@(Get-ChildItem -LiteralPath $root -Filter '*.partial-*').Count -eq 0)
    $unrelated = Join-Path $root 'unrelated.partial-keep'
    [IO.File]::WriteAllText($unrelated, 'retain')
    Reject-Test { Write-AtomicJson (Join-Path $root 'missing/state.json') @{revision=1} }
    Assert-Test ([IO.File]::ReadAllText($unrelated) -ceq 'retain')

    $context = [ordered]@{ accountUid=[guid]::NewGuid().ToString(); accountRevisionSetSha256=('a'*64)
        seasonNumber=26; raidSnapshotUid=[guid]::NewGuid().ToString(); raidSnapshotSha256=('b'*64)
        clientBuildCode='synthetic'; clientExecutableSha256=('c'*64) }
    $capture = [ordered]@{ contractId='nll/phase-d-classic-solo-raid-state-capture/v1'
        launchContextUid=$contextUid; expectedHeadRevisionUid=$null; protectedPayloadSha256=('d'*64)
        requestSha256=('e'*64); stateContentSha256=('f'*64) }
    foreach ($key in $context.Keys) { $capture[$key] = $context[$key] }
    $pending = @{ contractId='nll/phase-d-classic-solo-raid-state-pending/v1'; capture=@{launchContextUid=$contextUid} }
    Write-AtomicJson $contextPath $context
    Write-AtomicJson $capturePath $capture
    Write-AtomicJson $pendingPath $pending
    $receipt = [ordered]@{}
    foreach ($key in $capture.Keys) { $receipt[$key] = $capture[$key] }
    $receipt.contractId = 'nll/phase-d-classic-solo-raid-state-persistence/v1'
    $receipt.quarantined = $false
    $receipt.pendingPayloadSha256 = Get-PhaseDPersistenceProofHash $pendingPath
    $receipt.captureReceiptSha256 = Get-PhaseDPersistenceProofHash $capturePath
    $receipt.resultStateContentSha256 = $receipt.stateContentSha256
    $receipt.resultCode = 'no_state'
    $receipt.headRevisionUid = $null
    foreach ($code in @('no_state','state_unchanged','state_advanced')) {
        $receipt.resultCode = $code
        $receipt.headRevisionUid = if ($code -eq 'no_state') { $null } else { [guid]::NewGuid().ToString() }
        Write-AtomicJson $receiptPath $receipt
        Assert-Test ((Read-Proof).resultCode -ceq $code)
    }
    foreach ($key in @('contractId','launchContextUid','accountUid','accountRevisionSetSha256','raidSnapshotUid',
        'raidSnapshotSha256','clientBuildCode','clientExecutableSha256','protectedPayloadSha256',
        'requestSha256','stateContentSha256','resultStateContentSha256','pendingPayloadSha256','captureReceiptSha256')) {
        $saved = $receipt[$key]; $receipt[$key] = 'invalid'
        Write-AtomicJson $receiptPath $receipt
        Reject-Test { Read-Proof }
        $receipt[$key] = $saved
    }
    foreach ($mutation in @(
        {param($r) $r.quarantined=$true}, {param($r) $r.seasonNumber=29},
        {param($r) $r.expectedHeadRevisionUid=[guid]::NewGuid().ToString()},
        {param($r) $r.resultCode='STATE_ADVANCED'},
        {param($r) $r.resultCode='NO_STATE'},
        {param($r) $r.resultCode='no_state'; $r.headRevisionUid='malformed'},
        {param($r) $r.resultCode='no_state'; $r.headRevisionUid=[guid]::Empty.ToString()},
        {param($r) $r.headRevisionUid=$null}, {param($r) $r.headRevisionUid='invalid'}
    )) {
        $changed = ($receipt | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        & $mutation $changed
        Write-AtomicJson $receiptPath $changed
        Reject-Test { Read-Proof }
    }
    # Negative controls restore the two permissive predicates in an isolated
    # function copy. They must admit the bad fixture that the real helper rejects.
    $validator = (Get-Command Read-PhaseDSoloRaidPersistenceReceipt).ScriptBlock.ToString()
    $permissive = $validator.Replace('$resultCode -cin @', '$resultCode -in @').Replace(
        '$resultCode -ceq ''no_state'' -and $null -eq $receipt.headRevisionUid',
        '$resultCode -ceq ''no_state'' -and -not $headRevisionPresent')
    Assert-Test ($permissive -cne $validator)
    foreach ($case in @('uppercase','malformed_no_state')) {
        $changed = ($receipt | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        if ($case -eq 'uppercase') { $changed.resultCode='STATE_ADVANCED' }
        else { $changed.resultCode='no_state'; $changed.headRevisionUid='malformed' }
        Write-AtomicJson $receiptPath $changed
        Reject-Test { Read-Proof }
        $admitted = & ([scriptblock]::Create($permissive)) -Path $receiptPath -LaunchRoot $root -LaunchContextUid $contextUid `
            -PendingPayloadPath $pendingPath -CaptureReceiptPath $capturePath
        Assert-Test ($admitted.resultCode -ceq $changed.resultCode)
    }
    Write-AtomicJson $receiptPath $receipt
    # Exercise the real consumer wrappers without importing their runtime entry
    # points (which can alter hosts/DB). Missing shared-helper binding must fail.
    foreach ($consumer in @('watch-nll-phase-d-execution.ps1','recover-nll-phase-d-orphaned-execution.ps1')) {
        $tokens=$null; $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $consumer),[ref]$tokens,[ref]$parseErrors)
        Assert-Test ($parseErrors.Count -eq 0)
        $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-SoloRaidPersistenceReceipt'},$false)
        . ([scriptblock]::Create($definition.Extent.Text))
        $LaunchRoot=$root; $LaunchContextUid=$contextUid
        $argsForWrapper=@{Path=$receiptPath; PendingPayloadPath=$pendingPath; CaptureReceiptPath=$capturePath}
        if ($consumer.StartsWith('watch-')) { $argsForWrapper.LaunchContextUid=$contextUid }
        Assert-Test ((Read-SoloRaidPersistenceReceipt @argsForWrapper).resultCode -ceq 'state_advanced')
        $savedHash=$receipt.pendingPayloadSha256; $receipt.pendingPayloadSha256='invalid'
        Write-AtomicJson $receiptPath $receipt
        Reject-Test { Read-SoloRaidPersistenceReceipt @argsForWrapper }
        $receipt.pendingPayloadSha256=$savedHash; Write-AtomicJson $receiptPath $receipt
    }
    $pending.capture.launchContextUid = [guid]::NewGuid().ToString()
    Write-AtomicJson $pendingPath $pending
    # Re-pin the bytes so this tests context binding, not just a stale file hash.
    $receipt.pendingPayloadSha256 = Get-PhaseDPersistenceProofHash $pendingPath
    Write-AtomicJson $receiptPath $receipt
    Reject-Test { Read-Proof }
    $pending.capture.launchContextUid = $contextUid
    Write-AtomicJson $pendingPath $pending
    $receipt.pendingPayloadSha256 = Get-PhaseDPersistenceProofHash $pendingPath
    Write-AtomicJson $receiptPath $receipt
    Remove-Item -LiteralPath $capturePath
    Reject-Test { Read-Proof }

    $child = Join-Path $root 'synthetic pg child.ps1'
    [IO.File]::WriteAllText($child, 'param([string]$Value) if ($Value -cne "with spaces") { exit 9 }; exit 7')
    $ps = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    Assert-Test ((Invoke-PhaseDPgCtl $ps @('-NoProfile','-NonInteractive','-File',$child,'-Value','with spaces')) -eq 7)
    foreach ($name in @('invoke-nll-phase-d-execution.ps1','watch-nll-phase-d-execution.ps1','recover-nll-phase-d-orphaned-execution.ps1')) {
        $body = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))
        Assert-Test (-not $body.Contains('function Write-AtomicJson') -and -not $body.Contains('function Invoke-PhaseDPgCtl'))
        Assert-Test ($body.Contains("'Nll.PhaseDProcessIdentity.ps1'") -and $body.Contains("'Nll.PhaseDChildProcess.ps1'"))
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-shared-state-*') { throw 'unsafe_test_cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
"Shared state: $checks atomic replacement/failure retention, proof mutation and exact-child exit checks passed; synthetic files only."
