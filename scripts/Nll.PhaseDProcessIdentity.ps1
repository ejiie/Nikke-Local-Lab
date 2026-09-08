# Pure identity helpers. Importing this file neither starts nor stops a process.
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessHandle.ps1')
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

function Get-PhaseDVerifiedProcess {
    param([object]$Identity, [switch]$ForTermination)
    $started = [DateTime]::MinValue
    if ($null -ne $Identity -and $Identity.PSObject.Properties.Name -contains 'exitedBeforeCapture' -and
        $Identity.exitedBeforeCapture -eq $true -and [int]$Identity.processId -gt 0) {
        $candidate = Get-Process -Id ([int]$Identity.processId) -ErrorAction SilentlyContinue
        if ($null -eq $candidate) { return $null }
        $candidate.Dispose()
        throw 'phase_d_process_identity_unresolved'
    }
    if ($null -eq $Identity -or [int]$Identity.processId -le 0 -or
        -not [IO.Path]::IsPathRooted([string]$Identity.executablePath) -or
        -not [DateTime]::TryParse([string]$Identity.processStartedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$started)) {
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

function Stop-PhaseDResidualServer {
    param([string]$LaunchRoot)
    # Caller must have excluded live coordinator/watcher owners. Recheck client
    # coldness here as well; this path NEVER terminates a client or bootstrap.
    if (@(Get-Process -Name nikke,nikke_launcher,'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'phase_d_orphan_recovery_runtime_not_cold'
    }
    $servers = @(Get-Process -Name EpinelPS -ErrorAction SilentlyContinue)
    try {
        if ($servers.Count -eq 0) { return $false }
        if ($servers.Count -ne 1) { throw 'phase_d_process_identity_unresolved' }
        $root = [IO.Path]::GetFullPath($LaunchRoot).TrimEnd('\')
        $pointerPath = Join-Path $root 'evidence\active-run.pointer.json'
        $identityPath = Join-Path $root 'runtime-processes.identity.json'
        if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { throw 'phase_d_process_identity_unresolved' }
        $pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $identities = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $runRoot = [IO.Path]::GetFullPath([string]$pointer.runRoot)
        if ($pointer.contractId -cne 'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -or
            -not $runRoot.StartsWith((Join-Path $root 'evidence') + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $identities.schemaVersion -ne 1 -or
            $identities.contractId -cne 'nll/phase-d-runtime-process-identities/v1' -or
            $identities.launchContextUid -cne (Split-Path -Leaf $root) -or
            $null -eq $identities.server -or
            [int]$identities.server.processId -ne [int]$pointer.serverProcessId -or
            [int]$identities.server.processId -ne $servers[0].Id -or
            -not [string]::Equals([string]$identities.server.executablePath, (Join-Path $root 'runtime\EpinelPS.exe'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'phase_d_process_identity_mismatch'
        }
        $receiptHash = (Get-FileHash -LiteralPath (Join-Path $runRoot 'run-start.receipt.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($identities.startReceiptSha256 -cne $receiptHash) { throw 'phase_d_process_identity_mismatch' }
        Stop-PhaseDVerifiedProcess -Identity $identities.server
        return $true
    }
    finally { foreach ($process in $servers) { $process.Dispose() } }
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
    param([string]$LaunchRoot, [scriptblock]$Action)
    $lockPath = Join-Path $LaunchRoot 'execution-state.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
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
