# Real atomic progress writer; watcher exit/identity cases live in watcher-completion.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
function Check-Progress([bool]$Value) {
    if (-not $Value) { throw ('phase_d_progress_test_failed_at_line_' + (Get-PSCallStack)[1].ScriptLineNumber) }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-progress-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$statePath = Join-Path $root 'execution-state.json'
$progressPath = Join-Path $root 'execution-progress.json'
$jobs = @()
try {
    Write-AtomicJson $statePath @{statusCode='started';createdAtUtc=[DateTimeOffset]::UtcNow.AddSeconds(-20).ToString('o')}
    $original = [IO.File]::ReadAllText($statePath)
    Write-PhaseDProgress $root 'running'
    $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
    Check-Progress ($progress.stageCode -ceq 'running' -and $progress.events.Count -eq 1)
    Check-Progress ($progress.events[0].cumulativeMilliseconds -ge 20000)
    # Writers share the existing state lock. A delayed startup event cannot undo exit.
    foreach ($stage in @('running','game_exited')) {
        $jobs += Start-Job -ArgumentList (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1'),$root,$stage -ScriptBlock {
            param($helper,$launch,$code)
            . $helper
            1..8 | ForEach-Object { Write-PhaseDProgress $launch $code }
        }
    }
    $null = $jobs | Wait-Job -Timeout 30
    foreach ($job in $jobs) { Check-Progress ($job.State -eq 'Completed'); $job | Receive-Job -ErrorAction Stop }
    $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
    # Contended display writes may be skipped at the documented 250ms deadline.
    # Check atomicity here, then prove the late-start rule without contention.
    Check-Progress ($progress.events.Count -ge 1 -and $progress.events.Count -le 17)
    Write-PhaseDProgress $root 'game_exited'
    Write-PhaseDProgress $root 'running'
    $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
    Check-Progress ($progress.stageCode -ceq 'game_exited' -and $progress.events[-1].stageCode -ceq 'running')
    Check-Progress (([IO.File]::ReadAllText($statePath)) -ceq $original)
    # Telemetry cannot wait ten seconds on admission ownership or damage the last record.
    $before = [IO.File]::ReadAllText($progressPath)
    $lease = [IO.File]::Open((Join-Path $root 'execution-state.lock'),'Open','ReadWrite','None')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try { Write-PhaseDProgress $root 'fx_restore' } finally { $lease.Dispose() }
    Check-Progress ($timer.ElapsedMilliseconds -lt 2000)
    Check-Progress (([IO.File]::ReadAllText($progressPath)) -ceq $before)
    [IO.File]::WriteAllText($progressPath,'{')
    Write-PhaseDProgress $root 'ready'
    Check-Progress (([IO.File]::ReadAllText($progressPath)) -ceq '{')
    [IO.File]::WriteAllText($progressPath,$before)
    'Phase D progress: concurrent writers, late startup, bounded lock wait, corrupt telemetry and admission preservation passed.'
} finally {
    foreach ($job in $jobs) { $job | Stop-Job; $job | Remove-Job }
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-progress-*') { throw 'unsafe_progress_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
