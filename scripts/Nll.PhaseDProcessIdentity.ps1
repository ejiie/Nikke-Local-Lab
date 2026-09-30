# Pure identity helpers. Importing this file neither starts nor stops a process.
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessHandle.ps1')
# State files are replaced on the same volume. A failed replacement must leave
# the previous complete JSON intact; never delete the destination first.
function Write-AtomicJson {
    param([string]$Path, [object]$Value, [int]$Depth = 8)
    $target = [IO.Path]::GetFullPath($Path)
    $temporary = $target + '.partial-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth $Depth) + "`n"), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($target)) { [IO.File]::Replace($temporary, $target, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $target) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function New-PhaseDProcessIdentity {
    param([int]$Id, [string]$ExecutablePath, [DateTime]$NotBeforeUtc,
        [DateTime]$NotAfterUtc)
    if ($Id -le 0 -or -not [IO.Path]::IsPathRooted($ExecutablePath)) {
        throw 'phase_d_process_identity_unresolved'
    }
    $process = Open-PhaseDProcess -Id $Id
    if ($null -eq $process) {
        return [pscustomobject]@{
            processId = $Id; processStartedAtUtc = $null
            executablePath = [IO.Path]::GetFullPath($ExecutablePath)
            exitedBeforeCapture = $true
        }
    }
    try {
        $started = $process.StartTime.ToUniversalTime()
        if (-not [IO.Path]::IsPathRooted($ExecutablePath) -or
            -not [string]::Equals($process.Path, $ExecutablePath,
                [StringComparison]::OrdinalIgnoreCase) -or
            $started -lt $NotBeforeUtc.ToUniversalTime() -or $started -gt $NotAfterUtc.ToUniversalTime()) {
            throw 'phase_d_process_identity_mismatch'
        }
        [pscustomobject]@{
            processId = $Id
            processStartedAtUtc = $started.ToString('o')
            executablePath = [IO.Path]::GetFullPath($ExecutablePath)
        }
    }
    finally { $process.Dispose() }
}

function Test-PhaseDProcessStartInstant {
    param([object]$Value, [DateTime]$ExpectedUtc)
    $parsed=[DateTime]::MinValue
    if ($Value -is [DateTime]) { $parsed=$Value }
    elseif (-not [DateTime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $false }
    return $parsed.ToUniversalTime().Ticks -eq $ExpectedUtc.ToUniversalTime().Ticks
}

function Get-PhaseDVerifiedProcess {
    param([object]$Identity, [switch]$ForTermination)
    $started = [DateTime]::MinValue
    $timestampValid = $false
    if ($null -ne $Identity) {
        # PS 7.5 ConvertFrom-Json can decode ISO timestamps as DateTime. Casting
        # that value back to a culture-formatted string loses fractional ticks.
        # Keep the exact timestamp; the retained kernel handle comparison below
        # continues to reject every real start-time mismatch.
        if ($Identity.processStartedAtUtc -is [DateTime]) {
            $started = $Identity.processStartedAtUtc
            $timestampValid = $true
        } else {
            $timestampValid = [DateTime]::TryParse([string]$Identity.processStartedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$started)
        }
    }
    if ($null -ne $Identity -and $Identity.PSObject.Properties.Name -contains 'exitedBeforeCapture' -and
        $Identity.exitedBeforeCapture -eq $true -and [int]$Identity.processId -gt 0) {
        $candidate = Get-Process -Id ([int]$Identity.processId) -ErrorAction SilentlyContinue
        if ($null -eq $candidate) { return $null }
        $candidate.Dispose()
        throw 'phase_d_process_identity_unresolved'
    }
    if ($null -eq $Identity -or [int]$Identity.processId -le 0 -or
        -not [IO.Path]::IsPathRooted([string]$Identity.executablePath) -or
        -not $timestampValid) {
        throw 'phase_d_process_identity_unresolved'
    }
    $process = Open-PhaseDProcess -Id ([int]$Identity.processId) -ForTermination:$ForTermination
    if ($null -eq $process) { return $null }
    $retainHandle = $false
    try {
        # The opened limited-access kernel handle is retained through identity
        # verification and Wait/Kill; never reopen the PID after verification.
        if ($process.StartTime.ToUniversalTime().Ticks -ne $started.ToUniversalTime().Ticks) {
            throw 'phase_d_process_identity_mismatch'
        }
        # An exited, still-open kernel object no longer necessarily has an
        # image path. It needs no termination; do not mistake it for PID reuse.
        if ($process.HasExited) { return $null }
        try {
            # Explicit getter preserves Win32 exceptions which PowerShell's
            # property adapter can otherwise turn into an empty Path.
            $path = $process.get_Path()
        }
        catch {
            if ($process.HasExited) { return $null }
            throw
        }
        if ($process.HasExited) { return $null }
        if (-not [string]::Equals($path, [string]$Identity.executablePath,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'phase_d_process_identity_mismatch'
        }
        $retainHandle = $true
        return $process
    }
    finally { if (-not $retainHandle) { $process.Dispose() } }
}

function Stop-PhaseDVerifiedProcess {
    param([object]$Identity)
    $process = Get-PhaseDVerifiedProcess -Identity $Identity -ForTermination
    if ($null -eq $process) { return }
    try {
        $process.Kill()
        if (-not $process.WaitForExit(10000)) { throw 'phase_d_process_stop_unproven' }
    }
    finally { $process.Dispose() }
}

function Stop-PhaseDVerifiedProcessSet {
    param([object]$Pointer, [object]$Identities)
    if ($null -eq $Pointer -or $null -eq $Identities) { throw 'phase_d_process_identity_unresolved' }
    $verifiedProcesses = [Collections.Generic.List[object]]::new()
    try {
        # Prove ALL identities before stopping any. Retain the same handles
        # across verification and termination, even if a PID gets reused later.
        foreach ($role in @('client', 'bootstrap', 'server')) {
            $identity = $Identities.$role
            if ($null -eq $identity -or [int]$identity.processId -ne [int]$Pointer.($role + 'ProcessId')) {
                throw 'phase_d_process_identity_mismatch'
            }
            $process = Get-PhaseDVerifiedProcess -Identity $identity -ForTermination
            if ($null -ne $process) { $verifiedProcesses.Add($process) }
        }
        foreach ($process in $verifiedProcesses) {
            if (-not $process.HasExited) { $process.Kill() }
            if (-not $process.WaitForExit(10000)) { throw 'phase_d_process_stop_unproven' }
        }
    }
    finally { foreach ($process in $verifiedProcesses) { $process.Dispose() } }
}

function Initialize-PhaseDProcessIdentitySet {
    param([Collections.IDictionary]$Document, [object]$Pointer,
        [Collections.IDictionary]$ExecutablePaths, [DateTime]$NotBeforeUtc,
        [DateTime]$NotAfterUtc, [scriptblock]$Publish)
    # Preserve server ownership first. An inaccessible/exited client must not
    # erase the independent proof needed to clean up its server after client exit.
    foreach ($role in @('server', 'bootstrap', 'client')) {
        try {
            $Document[$role] = New-PhaseDProcessIdentity -Id ([int]$Pointer.($role + 'ProcessId')) `
                -ExecutablePath $ExecutablePaths[$role] -NotBeforeUtc $NotBeforeUtc -NotAfterUtc $NotAfterUtc
            & $Publish $Document
        }
        catch { $_.Exception.Data['phaseDProcessRole'] = $role; throw }
    }
}

function Write-PhaseDFirstFailure {
    param([string]$LaunchRoot, [ValidateSet('coordinator','watcher')][string]$Owner,
        [string]$Stage, [Management.Automation.ErrorRecord]$Failure,
        [ValidateSet('', 'rollback', 'hosts_restore', 'database_restart')][string]$CleanupStage = '')
    # Keep the first primary error AND the first error of each cleanup stage.
    # A replay must neither overwrite the original cause nor hide a secondary failure.
    $suffix = if ($CleanupStage) { '-cleanup-' + $CleanupStage } else { '' }
    $path = Join-Path $LaunchRoot ($Owner + $suffix + '-failure.detail.json')
    if (Test-Path -LiteralPath $path) { return }
    $exception = $Failure.Exception
    $nativeError = $null
    for ($inner = $exception; $null -ne $inner; $inner = $inner.InnerException) {
        if ($inner -is [ComponentModel.Win32Exception]) { $nativeError = $inner.NativeErrorCode; break }
    }
    $role = [string]$exception.Data['phaseDProcessRole']
    $detail = [ordered]@{
        schemaVersion = 1
        contractId = if ($CleanupStage) { 'nll/phase-d-cleanup-failure/v1' } else { 'nll/phase-d-first-failure/v1' }
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); owner = $Owner
        stage = if ($Stage -cmatch '^[a-z_]{3,64}$') { $Stage } else { 'unknown' }
        processRole = if ($role -in @('client','bootstrap','server')) { $role } else { $null }
        failureCode = if ($exception.Message -cmatch '^[a-z0-9._-]{3,128}$') { $exception.Message } else { 'phase_d_uncontrolled_failure' }
        exceptionType = $exception.GetType().FullName; nativeErrorCode = $nativeError
        scriptLineNumber = $Failure.InvocationInfo.ScriptLineNumber
    }
    # Never persist exception text/stack/arguments: those can contain account data.
    $temporary = $path + '.partial-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary, ($detail | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path
}

function Invoke-PhaseDStateLock {
    param([string]$LaunchRoot, [scriptblock]$Action, [int]$TimeoutMilliseconds = 10000)
    $lockPath = Join-Path $LaunchRoot 'execution-state.lock'
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $lease = $null
    while ($null -eq $lease) {
        try {
            $lease = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'phase_d_state_lock_timeout' }
            [Threading.Thread]::Sleep(10)
        }
    }
    try { & $Action } finally { $lease.Dispose() }
}

function Write-PhaseDProgress {
    param([string]$LaunchRoot, [string]$StageCode, [Nullable[DateTimeOffset]]$OccurredAtUtc = $null)
    # Telemetry never changes admission or interrupts an owned cleanup.
    if (-not (Test-Path -LiteralPath $LaunchRoot -PathType Container)) { return }
    $stages=@('api_preparation','account_snapshot','coordinator_preparation','fx_stage','runtime_preparation',
        'fx_apply','server_start','server_created','resource_check','game_start','game_spawned','health_observation',
        'running','game_exited','runtime_stopping','fx_restore','runtime_restore','database_restart','progress_save',
        'finalizing','ready','recovery_required')
    try {
        if ($StageCode -cnotin $stages) { throw 'phase_d_progress_stage_invalid' }
        Invoke-PhaseDStateLock $LaunchRoot -TimeoutMilliseconds 250 -Action {
            $path=Join-Path $LaunchRoot 'execution-progress.json'
            $uid=Split-Path -Leaf $LaunchRoot
            $observed=[DateTimeOffset]::UtcNow
            $at=if ($null -ne $OccurredAtUtc) { [DateTimeOffset]$OccurredAtUtc } else { $observed }
            if (Test-Path -LiteralPath $path) {
                $progress=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($progress.contractId -cne 'nll/phase-d-execution-progress/v1' -or $progress.launchContextUid -cne $uid -or
                    $progress.stageCode -cnotin $stages -or @($progress.events).Count -ge 128) { throw 'phase_d_progress_invalid' }
            } else {
                $stateFile=Join-Path $LaunchRoot 'execution-state.json'
                if (-not (Test-Path -LiteralPath $stateFile)) { return }
                $stateValue=Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $progress=[pscustomobject]@{contractId='nll/phase-d-execution-progress/v1';launchContextUid=$uid;
                    requestReceivedAtUtc=$stateValue.createdAtUtc;stageCode=$StageCode;updatedAtUtc=$observed.ToString('o');events=@()}
            }
            $origin=[DateTimeOffset]$progress.requestReceivedAtUtc
            if ($at -lt $origin -or $at -gt $observed) { throw 'phase_d_progress_clock_invalid' }
            # Duplicate or late owners must not restart the displayed phase or close it twice.
            if (@($progress.events).Count) {
                if ([array]::IndexOf($stages,$StageCode) -le [array]::IndexOf($stages,[string]$progress.stageCode)) { return }
                $previous=$progress.events[-1]
                $previous.intervalMilliseconds=[math]::Max(0,($at-([DateTimeOffset]$previous.occurredAtUtc)).TotalMilliseconds)
            }
            $progress.events=@($progress.events)+@([ordered]@{stageCode=$StageCode;occurredAtUtc=$at.ToString('o');
                observedAtUtc=$observed.ToString('o');cumulativeMilliseconds=[math]::Max(0,($at-$origin).TotalMilliseconds);
                intervalMilliseconds=0})
            $progress.stageCode=$StageCode
            $progress.updatedAtUtc=$observed.ToString('o')
            Write-AtomicJson $path $progress
        }
    } catch { Write-Verbose 'phase_d_progress_write_failed' }
}

function Invoke-PhaseDStartedTransition {
    param([string]$LaunchRoot, [scriptblock]$Action)
    $startedAction = $Action
    Invoke-PhaseDStateLock -LaunchRoot $LaunchRoot -Action {
        $current = Get-Content -LiteralPath (Join-Path $LaunchRoot 'execution-state.json') `
            -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($current.statusCode -in @('started', 'completed', 'rolled_back', 'failed')) { return }
        if ($current.statusCode -notin @('draft', 'validated')) { throw 'phase_d_state_transition_invalid' }
        & $startedAction
    }
}
