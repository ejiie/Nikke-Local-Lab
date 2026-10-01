# Shared exact-child invocation; importing this file has no side effects.
function Wait-PhaseDChildDeadline {
    param(
        [Diagnostics.Process]$Process,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds,
        [string]$OwnershipPath,
        [string]$ExecutablePath
    )
    try {
        if ($OwnershipPath) {
            $identity = [ordered]@{
                contractId = 'nll/phase-d-child-deadline/v1'
                processId = $Process.Id
                processStartedAtUtc = $Process.StartTime.ToUniversalTime().ToString('o')
                executablePath = [IO.Path]::GetFullPath($(if ($ExecutablePath) { $ExecutablePath } else { $Process.StartInfo.FileName }))
                timeoutSeconds = $TimeoutSeconds
            }
            Write-AtomicJson $OwnershipPath $identity
        }
        if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
            throw 'phase_d_child_deadline_unproven'
        }
        [int]$Process.ExitCode
    }
    catch {
        # The child can still mutate hosts/runtime/DB. Neither timeout nor a
        # failed identity write grants ownership to a concurrent rollback.
        throw 'phase_d_child_deadline_unproven'
    }
}

function Assert-PhaseDChildrenExited {
    param([string]$LaunchRoot, [switch]$RequireEvidence, [object]$RuntimeStartJob = $null,
        [string]$CheckpointStartIdentitySha256 = '')
    $files = @(Get-ChildItem -LiteralPath $LaunchRoot -Filter 'phase-d-child-*.identity.json' -File)
    if ($CheckpointStartIdentitySha256) {
        $startFiles=@($files | Where-Object Name -CEQ 'phase-d-child-start.identity.json')
        if ($CheckpointStartIdentitySha256 -cnotmatch '^[0-9a-f]{64}$' -or $startFiles.Count -ne 1 -or
            (Get-FileHash -LiteralPath $startFiles[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CheckpointStartIdentitySha256) {
            throw 'phase_d_child_checkpoint_identity_drifted'
        }
    }
    if ($RequireEvidence -and $files.Count -eq 0) { throw 'phase_d_child_identity_unresolved' }
    foreach ($file in $files) {
        # Only replay-only recovery passes this pin from a verified physical
        # cleanup checkpoint. It cannot excuse any PG/completion/FX child.
        if ($CheckpointStartIdentitySha256 -and $file.Name -ceq 'phase-d-child-start.identity.json') { continue }
        $identity = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($identity.contractId -cne 'nll/phase-d-child-deadline/v1') { throw 'phase_d_child_identity_unresolved' }
        # Only the sealed v3 start is atomically assigned at creation. A blank
        # reservation for that child is safe after observing the SAME live Job
        # empty. PG/completion/FX reservations NEVER get this exception.
        if ($file.Name -ceq 'phase-d-child-start.identity.json' -and $null -ne $RuntimeStartJob -and
            [int]$identity.processId -eq 0 -and $null -eq $identity.processStartedAtUtc -and
            $identity.executablePath -ieq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -and
            $RuntimeStartJob.ActiveProcesses -eq 0) { continue }
        $child = Get-PhaseDVerifiedProcess -Identity $identity
        if ($null -ne $child) {
            try {
                if ($file.Name -ceq 'phase-d-child-start.identity.json' -and $null -ne $RuntimeStartJob -and
                    $RuntimeStartJob.Contains([int]$identity.processId)) { continue }
                if (-not $child.HasExited) { throw 'phase_d_child_still_running' }
            }
            finally { $child.Dispose() }
        }
    }
}

function Write-PhaseDChildReservation {
    param([string]$OwnershipPath, [string]$ExecutablePath)
    if ($OwnershipPath) {
        # Persist BEFORE launch. If start/identity capture is interrupted, an
        # incomplete reservation blocks recovery instead of trusting an old PID.
        Write-AtomicJson $OwnershipPath ([ordered]@{
            contractId = 'nll/phase-d-child-deadline/v1'
            processId = 0; processStartedAtUtc = $null
            executablePath = [IO.Path]::GetFullPath($ExecutablePath)
        })
    }
}

function Invoke-PhaseDPgCtl {
    param([string]$PgCtlPath, [string[]]$Arguments, [string]$OwnershipPath,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 90)
    # Keep pg_ctl's own -w/-t. The outer deadline preserves ownership evidence
    # and NEVER kills PostgreSQL descendants or implies database shutdown.
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $PgCtlPath
    $info.Arguments = (($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    Write-PhaseDChildReservation -OwnershipPath $OwnershipPath -ExecutablePath $PgCtlPath
    try { $process = [Diagnostics.Process]::Start($info) }
    catch { if ($OwnershipPath) { throw 'phase_d_child_deadline_unproven' }; throw }
    try { Wait-PhaseDChildDeadline -Process $process -TimeoutSeconds $TimeoutSeconds -OwnershipPath $OwnershipPath -ExecutablePath $PgCtlPath }
    finally { $process.Dispose() }
}

function Assert-PhaseDPostgresRunning {
    param([string]$PgCtlPath, [string]$DataPath, [string]$OwnershipPath)
    $status = Invoke-PhaseDPgCtl -PgCtlPath $PgCtlPath -Arguments @('status', '-D', $DataPath) `
        -OwnershipPath $OwnershipPath
    if ($status -ne 0) { throw 'phase_d_control_center_database_not_running' }
}

function Ensure-PhaseDPostgresRunning {
    param([string]$PgCtlPath, [string]$DataPath, [string]$LogPath, [string]$OwnershipPath)
    # Runtime APIs commit to this cluster. Never stop/restart a healthy cluster.
    # Status 3 is the only stopped state; other failures must not trigger start.
    $status = Invoke-PhaseDPgCtl -PgCtlPath $PgCtlPath -Arguments @('status', '-D', $DataPath) `
        -OwnershipPath $OwnershipPath
    if ($status -eq 0) { return }
    if ($status -ne 3) { throw 'phase_d_control_center_database_status_failed' }
    $started = Invoke-PhaseDPgCtl -PgCtlPath $PgCtlPath `
        -Arguments @('start', '-D', $DataPath, '-l', $LogPath, '-w', '-t', '60') `
        -OwnershipPath $OwnershipPath
    if ($started -ne 0) { throw 'phase_d_control_center_database_restart_failed' }
    Assert-PhaseDPostgresRunning -PgCtlPath $PgCtlPath -DataPath $DataPath -OwnershipPath $OwnershipPath
}

function Assert-PhaseDPostgresStopped {
    param([string]$PgCtlPath, [string]$DataPath, [string]$OwnershipPath)
    # pg_ctl -w has finished stopping this cluster. Check its status, not the
    # system-wide process-name list, which can retain exited Windows objects or
    # include a different PostgreSQL installation.
    $status = Invoke-PhaseDPgCtl -PgCtlPath $PgCtlPath -Arguments @('status', '-D', $DataPath) `
        -OwnershipPath $OwnershipPath
    if ($status -ne 3 -or (Test-Path -LiteralPath (Join-Path $DataPath 'postmaster.pid'))) {
        throw 'phase_d_postgresql_not_cold'
    }
}

function ConvertTo-PhaseDPowerShellLiteral {
    param([string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-PhaseDChildScript {
    param(
        [string]$ScriptPath,
        [Collections.IDictionary]$Arguments,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 300,
        [string]$OwnershipPath,
        [object]$ExecutionJob = $null,
        [switch]$DirectExecutable
    )
    $commandParts = @('& ' + (ConvertTo-PhaseDPowerShellLiteral $ScriptPath))
    foreach ($key in $Arguments.Keys) {
        $commandParts += ('-' + [string]$key)
        $commandParts += ConvertTo-PhaseDPowerShellLiteral ([string]$Arguments[$key])
    }
    $stdoutLiteral = ConvertTo-PhaseDPowerShellLiteral $StandardOutputPath
    $stderrLiteral = ConvertTo-PhaseDPowerShellLiteral $StandardErrorPath
    # Redirect inside the exact child PowerShell process. Start-Process -Wait
    # can wait for EpinelPS/bootstrap descendants and prevent the coordinator
    # from ever creating its completion watcher.
    $childCommand = (
        '$ErrorActionPreference = ''Stop''; $LASTEXITCODE = 0; try { ' +
        ($commandParts -join ' ') +
        ' 1> ' + $stdoutLiteral + ' 2> ' + $stderrLiteral +
        '; exit $LASTEXITCODE } catch { [IO.File]::AppendAllText(' + $stderrLiteral +
        ', ($_ | Out-String), [Text.UTF8Encoding]::new($false)); exit 1 }')
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($childCommand))
    $powershell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($DirectExecutable) {
        if ($null -ne $ExecutionJob -or [IO.Path]::GetExtension($ScriptPath) -ine '.exe') { throw 'phase_d_child_executable_invalid' }
        $powershell = $ScriptPath
    }
    Write-PhaseDChildReservation -OwnershipPath $OwnershipPath -ExecutablePath $powershell
    try {
        if ($DirectExecutable) {
            $nativeArguments = foreach ($key in $Arguments.Keys) {
                '-' + [string]$key
                '"' + ([string]$Arguments[$key]).Replace('"', '\"') + '"'
            }
            $process = Start-Process -FilePath $ScriptPath -ArgumentList $nativeArguments -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $StandardOutputPath -RedirectStandardError $StandardErrorPath
        } elseif ($null -ne $ExecutionJob) {
            $process = $ExecutionJob.Start($powershell, ('-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand))
        } else {
        $process = Start-Process -FilePath $powershell `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-EncodedCommand', $encodedCommand) `
            -WindowStyle Hidden -PassThru
        }
    }
    catch { if ($OwnershipPath) { throw 'phase_d_child_deadline_unproven' }; throw }
    try { $exitCode = Wait-PhaseDChildDeadline -Process $process -TimeoutSeconds $TimeoutSeconds -OwnershipPath $OwnershipPath -ExecutablePath $powershell }
    finally { $process.Dispose() }
    [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = if (Test-Path -LiteralPath $StandardOutputPath) {
            [IO.File]::ReadAllText($StandardOutputPath, [Text.Encoding]::UTF8)
        } else { '' }
        StandardError = if (Test-Path -LiteralPath $StandardErrorPath) {
            [IO.File]::ReadAllText($StandardErrorPath, [Text.Encoding]::UTF8)
        } else { '' }
    }
}
