# Import has no operational side effects. Call only after verifying the runner closure.
. (Join-Path $PSScriptRoot 'Nll.PhaseDSharedIsolation.ps1')
function Initialize-PhaseDJobType {
    if (-not ('Nll.PhaseD.ExecutionJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Nll.PhaseDJob.cs') }
}

function Get-PhaseDJobBinding {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    # Set only by entrypoint verification or by this coordinator's bundle publisher.
    $bundle = Get-Variable -Name PhaseDVerifiedRunnerBundle -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $bundle -or $bundle.specification.contractId -cne 'nll/phase-d-runner-input/v3' -or
        $bundle.sha256 -cne $ExpectedBundleSha256 -or
        [IO.Path]::GetFullPath($bundle.specification.launchRoot) -cne [IO.Path]::GetFullPath($LaunchRoot)) {
        throw 'phase_d_job_binding_invalid'
    }
    [pscustomobject]@{ bundle=$bundle; name=('Local\NLL.PhaseD.' + $bundle.specification.jobNonce) }
}

function New-PhaseDExecutionJob {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    $binding = Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
    # The nonce belongs to one sealed execution; never reuse even an empty job.
    $reservation = Join-Path $LaunchRoot 'job-reservation.json'
    $stream = [IO.File]::Open($reservation, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Dispose()
    Initialize-PhaseDJobType
    [Nll.PhaseD.ExecutionJob]::Create($binding.name)
}

function Open-PhaseDExecutionJob {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256, [switch]$AllowAbsent)
    $binding = Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
    if (-not (Test-Path -LiteralPath (Join-Path $LaunchRoot 'job-reservation.json') -PathType Leaf)) { throw 'phase_d_job_reservation_missing' }
    Initialize-PhaseDJobType
    try { [Nll.PhaseD.ExecutionJob]::Open($binding.name) }
    catch {
        for ($nativeException = $_.Exception; $null -ne $nativeException; $nativeException = $nativeException.InnerException) {
            if ($AllowAbsent -and $nativeException -is [ComponentModel.Win32Exception] -and $nativeException.NativeErrorCode -eq 2) { return $null }
        }
        throw 'phase_d_job_owner_unresolved'
    }
}

function Test-PhaseDAbsentJobRecovery {
    $enabled = Get-Variable PhaseDAllowAbsentJobRecovery -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    return $enabled -eq $true
}

function Assert-PhaseDRecordedProcessesExited {
    param([string]$LaunchRoot)
    Assert-PhaseDChildrenExited -LaunchRoot $LaunchRoot
    $path = Join-Path $LaunchRoot 'runtime-processes.identity.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $identities = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($identities.contractId -cne 'nll/phase-d-runtime-process-identities/v1' -or
        $identities.launchContextUid -cne (Split-Path -Leaf $LaunchRoot)) { throw 'phase_d_process_identity_unresolved' }
    foreach ($role in @('client','bootstrap','server')) {
        # Capture can stop partway through; check every identity that was recorded.
        if ($null -eq $identities.$role) { continue }
        $process = Get-PhaseDVerifiedProcess $identities.$role
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { throw 'phase_d_process_still_running' } }
            finally { $process.Dispose() }
        }
    }
}

function Invoke-PhaseDJobProofLock {
    param([string]$LaunchRoot, [scriptblock]$LockedOperation)
    $lock = [IO.File]::Open((Join-Path $LaunchRoot '.job-proof.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { & $LockedOperation } finally { $lock.Dispose() }
}

function Stop-PhaseDExecutionJob {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    Invoke-PhaseDJobProofLock $LaunchRoot {
        $binding = Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
        $job = Open-PhaseDExecutionJob $LaunchRoot $ExpectedBundleSha256 -AllowAbsent:(Test-PhaseDAbsentJobRecovery)
        try {
            if ($null -eq $job) { Assert-PhaseDRecordedProcessesExited $LaunchRoot }
            else {
                if ($job.Contains($PID)) { throw 'phase_d_job_cleanup_owner_inside_job' }
                $job.TerminateAndWait(10000)
            }
            $path = Join-Path $LaunchRoot 'job-zero.receipt.json'
            if (Test-Path -LiteralPath $path) {
                $prior = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($prior.contractId -cne 'nll/phase-d-job-zero/v1' -or $prior.jobNonce -cne $binding.bundle.specification.jobNonce -or
                    $prior.runnerBundleSha256 -cne $binding.bundle.sha256 -or $prior.launchContextUid -cne $binding.bundle.specification.launchContextUid -or
                    $prior.activeProcesses -ne 0 -or $prior.runtimeRoot -cne (Join-Path $LaunchRoot 'runtime')) { throw 'phase_d_job_proof_invalid' }
                return
            }
            # Atomic first publication under the exclusive proof lock; never rewrite a receipt.
            Write-AtomicJson $path ([ordered]@{
                contractId='nll/phase-d-job-zero/v1'; launchContextUid=$binding.bundle.specification.launchContextUid
                runnerBundleSha256=$binding.bundle.sha256; jobNonce=$binding.bundle.specification.jobNonce
                activeProcesses=0; observedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
                runtimeRoot=(Join-Path $LaunchRoot 'runtime')
            })
        } finally { if ($null -ne $job) { $job.Dispose() } }
    }
}

function Invoke-PhaseDWithJobZeroProof {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256, [scriptblock]$Action)
    Invoke-PhaseDJobProofLock $LaunchRoot {
        $binding = Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
        $receipt = Get-Content -LiteralPath (Join-Path $LaunchRoot 'job-zero.receipt.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($receipt.contractId -cne 'nll/phase-d-job-zero/v1' -or
            $receipt.launchContextUid -cne $binding.bundle.specification.launchContextUid -or
            $receipt.runnerBundleSha256 -cne $binding.bundle.sha256 -or
            $receipt.jobNonce -cne $binding.bundle.specification.jobNonce -or $receipt.activeProcesses -ne 0 -or
            $receipt.runtimeRoot -cne (Join-Path $LaunchRoot 'runtime')) { throw 'phase_d_job_proof_invalid' }
        # Live cleanup retains the same kernel object. Recovery alone accepts
        # native NOT_FOUND plus independently verified exited process identities.
        $job = Open-PhaseDExecutionJob $LaunchRoot $ExpectedBundleSha256 -AllowAbsent:(Test-PhaseDAbsentJobRecovery)
        try {
            if ($null -eq $job) { Assert-PhaseDRecordedProcessesExited $LaunchRoot }
            elseif ($job.Contains($PID) -or $job.ActiveProcesses -ne 0) { throw 'phase_d_job_zero_unproven' }
            $receiptPath = Join-Path $LaunchRoot 'job-zero.receipt.json'
            $receiptSha = (Get-FileHash -LiteralPath $receiptPath).Hash.ToLowerInvariant()
            $verifyJob = $job
            $verifyPath = $receiptPath
            $verifySha = $receiptSha
            # Retain the SAME live Job and receipt under the proof lock. The
            # immutable code closure was checked once at process entry.
            $verifyLaunchRoot = $LaunchRoot
            $verifyBundleSha = $ExpectedBundleSha256
            $verify = [Action]{
                if ($null -eq $verifyJob) {
                    $unexpected = Open-PhaseDExecutionJob $verifyLaunchRoot $verifyBundleSha -AllowAbsent
                    if ($null -ne $unexpected) { $unexpected.Dispose(); throw 'phase_d_job_zero_unproven' }
                    Assert-PhaseDRecordedProcessesExited $verifyLaunchRoot
                } else {
                    $verifyJob.Validate()
                    if ($verifyJob.ActiveProcesses -ne 0) { throw 'phase_d_job_zero_unproven' }
                }
                if ((Get-FileHash -LiteralPath $verifyPath).Hash.ToLowerInvariant() -cne $verifySha) { throw 'phase_d_job_zero_unproven' }
            }.GetNewClosure()
            & $Action $receipt $verify $receiptSha
        } finally { if ($null -ne $job) { $job.Dispose() } }
    }
}

function Assert-PhaseDJobMember {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    $job = Open-PhaseDExecutionJob $LaunchRoot $ExpectedBundleSha256
    try {
        if (-not $job.Contains($PID) -or (Test-Path -LiteralPath (Join-Path $LaunchRoot 'job-zero.receipt.json'))) { throw 'phase_d_job_assignment_unproven' }
    } finally { $job.Dispose() }
}

function Invoke-PhaseDExecutionFxCleanup {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    $binding = Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
    $fx = $binding.bundle.specification.executionFx
    if ($null -eq $fx) {
        if (Test-Path -LiteralPath (Join-Path $LaunchRoot 'runtime/execution-fx')) { throw 'phase_d_job_unbound_fx_delivery' }
        return
    }
    Invoke-PhaseDWithJobZeroProof $LaunchRoot $ExpectedBundleSha256 {
        param($proof, $verifyProcessTreeExit, $terminationReceiptSha256)
        $verifyProcessTreeExit.Invoke()
        # The CLI verifies the sealed execution independently. Recovery uses the
        # installed consumer and permits only NOT_FOUND + exited recorded identities.
        # Keep the proof lock (and the live Job, when present) throughout the call.
        Write-PhaseDProgress $LaunchRoot 'fx_restore'
        $materializer = $binding.bundle.specification.runtimeMaterializer
        if (Test-PhaseDAbsentJobRecovery) { $materializer = $script:PhaseDRecoveryMaterializer }
        $result = Invoke-PhaseDChildScript -ScriptPath $materializer -DirectExecutable `
            -Arguments ([ordered]@{
                '-retire-execution-fx'='true'; '-launch-root'=$LaunchRoot
                '-expected-bundle-sha256'=$ExpectedBundleSha256; '-expected-termination-sha256'=$terminationReceiptSha256
                '-allow-absent-job'=([string](Test-PhaseDAbsentJobRecovery)).ToLowerInvariant()
            }) -TimeoutSeconds 300 -OwnershipPath (Join-Path $LaunchRoot 'phase-d-child-fx-retirement.identity.json') `
            -StandardOutputPath (Join-Path $LaunchRoot 'fx-retirement.stdout.log') `
            -StandardErrorPath (Join-Path $LaunchRoot 'fx-retirement.stderr.log')
        if ($result.ExitCode -ne 0) { throw 'phase_d_job_fx_retirement_failed' }
        Assert-PhaseDNativeFxRetirement $LaunchRoot $binding.bundle.specification
        $verifyProcessTreeExit.Invoke()
    }
}

function Protect-PhaseDJobServerLog {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    Invoke-PhaseDWithJobZeroProof $LaunchRoot $ExpectedBundleSha256 {
        $pointerPath=Join-Path $LaunchRoot 'evidence/active-run.pointer.json'
        if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) { return }
        $pointer=Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $evidence=[IO.Path]::GetFullPath((Join-Path $LaunchRoot 'evidence')).TrimEnd('\')
        $run=[IO.Path]::GetFullPath([string]$pointer.runRoot)
        if ($pointer.contractId -cne 'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -or
            -not $run.StartsWith($evidence+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'phase_d_job_log_path_invalid' }
        $path=Join-Path $run 'server.stdout.log'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $item=Get-Item -LiteralPath $path
        while ($null -ne $item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'phase_d_job_log_path_invalid' }
            if ($item.FullName -ieq [IO.Path]::GetFullPath($LaunchRoot)) { break }
            $item=Get-Item -LiteralPath (Split-Path -Parent $item.FullName)
        }
        $text=[IO.File]::ReadAllText($path)
        $protected=[regex]::Replace($text,'(?m)^(?<prefix>\s*authtoken:\s*)\S+\s*$','${prefix}[REDACTED]')
        if ($protected -cne $text) { [IO.File]::WriteAllText($path,$protected,[Text.UTF8Encoding]::new($false)) }
    }
}

function Receive-PhaseDJobHandoff {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    $binding = Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
    $job = Open-PhaseDExecutionJob $LaunchRoot $ExpectedBundleSha256
    try {
        if ($job.Contains($PID)) { throw 'phase_d_job_watcher_inside_job' }
        $self = Get-Process -Id $PID
        try { $started = $self.StartTime.ToUniversalTime().ToString('o') } finally { $self.Dispose() }
        Write-AtomicJson (Join-Path $LaunchRoot 'job-handoff.ready.json') ([ordered]@{
            runnerBundleSha256=$binding.bundle.sha256; jobNonce=$binding.bundle.specification.jobNonce
            processId=$PID; processStartedAtUtc=$started
        })
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        do {
            $path = Join-Path $LaunchRoot 'job-handoff.commit.json'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $commit = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($commit.runnerBundleSha256 -cne $binding.bundle.sha256 -or
                    $commit.jobNonce -cne $binding.bundle.specification.jobNonce -or
                    $commit.processId -ne $PID -or -not (Test-PhaseDProcessStartInstant $commit.processStartedAtUtc ([DateTime]$started))) { throw 'phase_d_job_handoff_invalid' }
                return $job
            }
            Start-Sleep -Milliseconds 50
        } while ($deadline.Elapsed.TotalSeconds -lt 20)
        throw 'phase_d_job_handoff_unproven'
    } catch { $job.Dispose(); throw }
}

function Confirm-PhaseDJobHandoff {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256, [Diagnostics.Process]$Watcher)
    $binding = Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($Watcher.HasExited) { throw 'phase_d_job_handoff_unproven' }
        $path = Join-Path $LaunchRoot 'job-handoff.ready.json'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $ready = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($ready.runnerBundleSha256 -cne $binding.bundle.sha256 -or
                $ready.jobNonce -cne $binding.bundle.specification.jobNonce -or
                $ready.processId -ne $Watcher.Id -or
                -not (Test-PhaseDProcessStartInstant $ready.processStartedAtUtc $Watcher.StartTime)) { throw 'phase_d_job_handoff_invalid' }
            Write-AtomicJson (Join-Path $LaunchRoot 'job-handoff.commit.json') $ready
            return
        }
        Start-Sleep -Milliseconds 50
    } while ($deadline.Elapsed.TotalSeconds -lt 15)
    throw 'phase_d_job_handoff_unproven'
}

function Test-PhaseDJobHandoffCommitted {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256, [Diagnostics.Process]$Watcher)
    $path=Join-Path $LaunchRoot 'job-handoff.commit.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $binding=Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
    $commit=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($commit.runnerBundleSha256 -cne $binding.bundle.sha256 -or $commit.jobNonce -cne $binding.bundle.specification.jobNonce -or
        $commit.processId -ne $Watcher.Id -or -not (Test-PhaseDProcessStartInstant $commit.processStartedAtUtc $Watcher.StartTime)) { throw 'phase_d_job_handoff_invalid' }
    return $true
}

function Read-PhaseDPhysicalCleanupCheckpoint {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    $binding=Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
    Read-PhaseDRunnerCleanupCheckpoint $LaunchRoot $binding.bundle
}

function Write-PhaseDPhysicalCleanupCheckpoint {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256, [string]$CompletionPath)
    Invoke-PhaseDWithJobZeroProof $LaunchRoot $ExpectedBundleSha256 {
        $binding=Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
        $fullRoot=[IO.Path]::GetFullPath($LaunchRoot).TrimEnd('\')
        Assert-PhaseDNativeFxRetirement $LaunchRoot $binding.bundle.specification
        $fullCompletion=[IO.Path]::GetFullPath($CompletionPath)
        if (-not $fullCompletion.StartsWith($fullRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'phase_d_job_checkpoint_invalid' }
        $relative=$fullCompletion.Substring($fullRoot.Length+1).Replace('\','/')
        if ($relative -cnotmatch '^evidence/[0-9a-f-]{36}/completion\.receipt\.json$' -or
            (Test-Path -LiteralPath (Join-Path $LaunchRoot 'evidence/active-run.pointer.json'))) { throw 'phase_d_job_checkpoint_invalid' }
        $completion=Get-Content -LiteralPath $fullCompletion -Raw -Encoding UTF8 | ConvertFrom-Json
        $hostsPath=Join-Path $LaunchRoot 'hosts-restoration.receipt.json'
        $hosts=Get-Content -LiteralPath $hostsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $completion.databaseRestored -or -not $completion.hostsRestored -or
            $hosts.contractId -cne 'nll/phase-d-hosts-restoration/v1' -or -not $hosts.restoredToCapturedBaseline) { throw 'phase_d_job_cleanup_not_complete' }
        $path=Join-Path $LaunchRoot 'physical-cleanup.receipt.json'
        if (Test-Path -LiteralPath $path) { $null=Read-PhaseDPhysicalCleanupCheckpoint $LaunchRoot $ExpectedBundleSha256; return }
        Restore-PhaseDSharedIsolation $LaunchRoot $ExpectedBundleSha256
        $completion | Add-Member -NotePropertyName extensionFirewallRemoved -NotePropertyValue $true -Force
        Write-AtomicJson $fullCompletion $completion
        Write-AtomicJson $path ([ordered]@{
            contractId='nll/phase-d-physical-cleanup/v1';cleanupKind='completion';launchContextUid=$binding.bundle.specification.launchContextUid
            runnerBundleSha256=$binding.bundle.sha256;jobNonce=$binding.bundle.specification.jobNonce
            terminationSha256=(Get-PhaseDRunnerHash (Join-Path $LaunchRoot 'job-zero.receipt.json'))
            startIdentitySha256=$(if (Test-Path -LiteralPath (Join-Path $LaunchRoot 'phase-d-child-start.identity.json') -PathType Leaf) { Get-PhaseDRunnerHash (Join-Path $LaunchRoot 'phase-d-child-start.identity.json') } else { $null })
            completionRelativePath=$relative;completionSha256=(Get-PhaseDRunnerHash $fullCompletion)
            hostsSha256=(Get-PhaseDRunnerHash $hostsPath)
            fxRetiredSha256=$(if ($null -ne $binding.bundle.specification.executionFx) { Get-PhaseDRunnerHash (Join-Path $LaunchRoot 'runtime/execution-fx/retired.json') } else { $null })
        })
    }
}

function Write-PhaseDRollbackCleanupCheckpoint {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    Invoke-PhaseDWithJobZeroProof $LaunchRoot $ExpectedBundleSha256 {
        $binding=Get-PhaseDJobBinding $LaunchRoot $ExpectedBundleSha256
        Assert-PhaseDNativeFxRetirement $LaunchRoot $binding.bundle.specification
        $path=Join-Path $LaunchRoot 'physical-cleanup.receipt.json'
        if (Test-Path -LiteralPath $path) { $null=Read-PhaseDPhysicalCleanupCheckpoint $LaunchRoot $ExpectedBundleSha256; return }
        $db=Join-Path $LaunchRoot 'runtime/db.json'
        $backup=Join-Path $LaunchRoot 'control-center-hosts.before.bin'
        $hosts=Get-PhaseDJobSystemHostsPath
        if ((Get-PhaseDRunnerHash $db) -cne $binding.bundle.specification.runtimeDbSha256 -or
            (Get-PhaseDRunnerHash $hosts) -cne (Get-PhaseDRunnerHash $backup) -or
            (Test-Path -LiteralPath (Join-Path $LaunchRoot 'evidence/active-run.pointer.json'))) { throw 'phase_d_job_rollback_not_complete' }
        foreach ($name in @('epinelps.db','epinelps.db-shm','epinelps.db-wal')) {
            if (Test-Path -LiteralPath (Join-Path $LaunchRoot ('runtime/'+$name))) { throw 'phase_d_job_rollback_not_complete' }
        }
        $archives=@(Get-ChildItem -LiteralPath (Join-Path $LaunchRoot 'evidence') -Recurse -File -Filter 'active-run.pointer.*.json')
        if ($archives.Count -gt 1) { throw 'phase_d_job_rollback_archive_ambiguous' }
        $relative=$null; $archiveSha=$null
        if ($archives.Count -eq 1) {
            $relative=$archives[0].FullName.Substring([IO.Path]::GetFullPath($LaunchRoot).TrimEnd('\').Length+1).Replace('\','/')
            if ($relative -cnotmatch '^evidence/[0-9a-f-]{36}/active-run\.pointer\.[a-z0-9T.Z-]+\.json$') { throw 'phase_d_job_checkpoint_invalid' }
            $archiveSha=Get-PhaseDRunnerHash $archives[0].FullName
        }
        Restore-PhaseDSharedIsolation $LaunchRoot $ExpectedBundleSha256
        Write-AtomicJson $path ([ordered]@{
            contractId='nll/phase-d-physical-cleanup/v1';cleanupKind='rollback';launchContextUid=$binding.bundle.specification.launchContextUid
            runnerBundleSha256=$binding.bundle.sha256;jobNonce=$binding.bundle.specification.jobNonce
            terminationSha256=(Get-PhaseDRunnerHash (Join-Path $LaunchRoot 'job-zero.receipt.json'))
            startIdentitySha256=$(if (Test-Path -LiteralPath (Join-Path $LaunchRoot 'phase-d-child-start.identity.json') -PathType Leaf) { Get-PhaseDRunnerHash (Join-Path $LaunchRoot 'phase-d-child-start.identity.json') } else { $null })
            runtimeDatabaseSha256=(Get-PhaseDRunnerHash $db);hostsBackupSha256=(Get-PhaseDRunnerHash $backup)
            archiveRelativePath=$relative;archiveSha256=$archiveSha
            fxRetiredSha256=$(if ($null -ne $binding.bundle.specification.executionFx) { Get-PhaseDRunnerHash (Join-Path $LaunchRoot 'runtime/execution-fx/retired.json') } else { $null })
        })
    }
}

function Get-PhaseDJobSystemHostsPath { Join-Path $env:SystemRoot 'System32/drivers/etc/hosts' }
