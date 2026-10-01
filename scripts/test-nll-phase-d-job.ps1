# Synthetic Windows processes/files only. No installed client, DB, hosts or firewall.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test-nll-phase-d-runner-contract.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDJob.ps1')
function Require-Test([bool]$Value, [string]$Code) { if (-not $Value) { throw $Code } }
function Reject-Test([scriptblock]$Action) { $rejected=$false; try { & $Action | Out-Null } catch { $rejected=$true }; Require-Test $rejected 'job_test_expected_rejection' }
function Encode-Test([string]$Code) { [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code)) }
function Write-Test([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
$powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$jobs = [Collections.Generic.List[object]]::new()
$processes = [Collections.Generic.List[object]]::new()
function Get-NetFirewallRule { [CmdletBinding()]param($Name,$Group) @() }
function Get-NetFirewallApplicationFilter { [CmdletBinding()]param($PolicyStore,[Parameter(ValueFromPipeline=$true)]$InputObject) }
function Get-CimInstance { param($ClassName,$ErrorAction) @() }
$count=0
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $spec.launchRoot 'runtime') -Force
    $spec.contractId='nll/phase-d-runner-input/v3'; $spec.jobNonce=[guid]::NewGuid().ToString('N'); $spec.executionFx=$null; $spec.weaknessCode='water'
    $spec.runtimeMaterializer=Join-Path $spec.launchRoot 'runtime/NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
    Write-Test $spec.runtimeMaterializer 'synthetic-not-executable'
    Write-Test $spec.bossRuntimeVariantProfile '{"synthetic":true}'
    $spec.bossRuntimeVariantProfileSha256=Get-PhaseDRunnerHash $spec.bossRuntimeVariantProfile
    $bundle=New-PhaseDRunnerBundle $spec $PSScriptRoot
    $tool=Join-Path $spec.launchRoot 'tool.manifest.tsv'
    Write-Test $tool ("role_code`tbyte_length`tsha256`nrunner_bundle`t1`t" + $bundle.sha256 + "`n")
    Write-AtomicJson (Join-Path $spec.launchRoot 'launch-context.json') ([ordered]@{
        contractId='nll/launch-context/v1'; launchContextUid=$id; toolManifestSha256=(Get-PhaseDRunnerHash $tool)
    })
    Require-Test ((Read-PhaseDRunnerBundle $spec.launchRoot).specification.jobNonce -ceq $spec.jobNonce) 'job_seal_binding'; $count++
    $before=Get-PhaseDRunnerHash (Join-Path $bundle.root 'Nll.PhaseDJob.cs')
    $sourceBytes=[IO.File]::ReadAllBytes((Join-Path $bundle.root 'Nll.PhaseDJob.cs'))
    Write-Test (Join-Path $bundle.root 'Nll.PhaseDJob.cs') 'changed'
    Reject-Test { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
    [IO.File]::WriteAllBytes((Join-Path $bundle.root 'Nll.PhaseDJob.cs'),$sourceBytes)
    Reject-Test { Get-PhaseDJobBinding $spec.launchRoot ('0'*64) }; $count++
    Reject-Test { Get-PhaseDJobBinding (Join-Path $root 'different-run') $bundle.sha256 }; $count++
    $job=New-PhaseDExecutionJob $spec.launchRoot $bundle.sha256; $jobs.Add($job)
    Require-Test (-not $job.Contains($PID)) 'coordinator_in_job'; $count++
    Reject-Test { New-PhaseDExecutionJob $spec.launchRoot $bundle.sha256 }; $count++
    $emptyReservation=Join-Path $spec.launchRoot 'phase-d-child-start.identity.json'
    Write-PhaseDChildReservation -OwnershipPath $emptyReservation -ExecutablePath $powershell
    Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot }; $count++
    Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot -RuntimeStartJob $job; $count++
    $unknownPg=Join-Path $spec.launchRoot 'phase-d-child-pg.identity.json'
    Write-PhaseDChildReservation -OwnershipPath $unknownPg -ExecutablePath $powershell
    Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot -RuntimeStartJob $job }; $count++
    Remove-Item -LiteralPath $unknownPg
    $outside=Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-EncodedCommand',(Encode-Test 'Start-Sleep -Seconds 90')) -WindowStyle Hidden -PassThru
    $processes.Add($outside)
    Require-Test (-not $job.Contains($outside.Id)) 'pg_sibling_in_job'; $count++
    $pidPath=Join-Path $root 'descendant.pid'
    $leafCode='Start-Sleep -Seconds 90'
    $middleCode='$p=Start-Process -FilePath ' + (ConvertTo-PhaseDPowerShellLiteral $powershell) + ' -ArgumentList @(''-NoProfile'',''-EncodedCommand'',''' + (Encode-Test $leafCode) + ''') -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText(' + (ConvertTo-PhaseDPowerShellLiteral $pidPath) + ',[string]$p.Id)'
    $startScript=Join-Path $root 'synthetic-start.ps1'
    Write-Test $startScript ('Start-Process -FilePath ' + (ConvertTo-PhaseDPowerShellLiteral $powershell) + ' -ArgumentList @(''-NoProfile'',''-EncodedCommand'',''' + (Encode-Test $middleCode) + ''') -WindowStyle Hidden | Out-Null')
    $result=Invoke-PhaseDChildScript -ScriptPath $startScript -Arguments ([ordered]@{}) -ExecutionJob $job -TimeoutSeconds 15 `
        -OwnershipPath (Join-Path $spec.launchRoot 'phase-d-child-start.identity.json') `
        -StandardOutputPath (Join-Path $root 'stdout') -StandardErrorPath (Join-Path $root 'stderr')
    Require-Test ($result.ExitCode -eq 0) 'start_child_failed'
    $wait=[Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $pidPath) -and $wait.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 50 }
    $descendant=Get-Process -Id ([int](Get-Content -LiteralPath $pidPath -Raw)); $processes.Add($descendant)
    Require-Test ($job.Contains($descendant.Id) -and $job.ActiveProcesses -gt 0) 'grandchild_escaped'; $count++
    Reject-Test { Assert-PhaseDJobMember $spec.launchRoot $bundle.sha256 }; $count++
    Reject-Test { Invoke-PhaseDWithJobZeroProof $spec.launchRoot $bundle.sha256 { throw 'consumer_should_not_run' } }; $count++
    Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot; $count++ # exact child exited, descendant still owned by Job
    Stop-PhaseDExecutionJob $spec.launchRoot $bundle.sha256
    Require-Test ($descendant.WaitForExit(10000) -and -not $outside.HasExited) 'job_stop_scope_failed'; $count++
    $receiptPath=Join-Path $spec.launchRoot 'job-zero.receipt.json'
    $receiptHash=Get-PhaseDRunnerHash $receiptPath
    Stop-PhaseDExecutionJob $spec.launchRoot $bundle.sha256
    Require-Test ((Get-PhaseDRunnerHash $receiptPath) -ceq $receiptHash) 'job_receipt_changed_on_retry'; $count++
    $script:consumed=0
    Invoke-PhaseDWithJobZeroProof $spec.launchRoot $bundle.sha256 {
        param($proof,$verify,$sha)
        $verify.Invoke(); $verify.Invoke()
        Require-Test ($sha -ceq $receiptHash -and $proof.activeProcesses -eq 0) 'callback_binding_failed'
        $script:consumed++
    }
    Require-Test ($script:consumed -eq 1) 'callback_not_executed'; $count++
    function Test-NestedJobConsumer($Launch, $Hash) {
        Invoke-PhaseDWithJobZeroProof $Launch $Hash {
            param($proof,$verify,$sha)
            $verify.Invoke(); $verify.Invoke()
        }
    }
    Test-NestedJobConsumer $spec.launchRoot $bundle.sha256
    $count++ # A nested helper must not lose the .NET callback's script scope.
    $completionRoot=Join-Path $spec.launchRoot ('evidence/' + [guid]::NewGuid().ToString('D'))
    $null=New-Item -ItemType Directory -Path $completionRoot
    $completionFile=Join-Path $completionRoot 'completion.receipt.json'
    Write-AtomicJson $completionFile @{databaseRestored=$true;hostsRestored=$true;extensionFirewallRemoved=$false}
    $hostsReceipt=Join-Path $spec.launchRoot 'hosts-restoration.receipt.json'
    Write-AtomicJson $hostsReceipt @{contractId='nll/phase-d-hosts-restoration/v1';restoredToCapturedBaseline=$true}
    Write-PhaseDPhysicalCleanupCheckpoint $spec.launchRoot $bundle.sha256 $completionFile
    $completion=Get-Content -LiteralPath $completionFile -Raw | ConvertFrom-Json
    $checkpoint=Read-PhaseDPhysicalCleanupCheckpoint $spec.launchRoot $bundle.sha256
    Require-Test ($completion.extensionFirewallRemoved -and $checkpoint.completionSha256 -ceq (Get-PhaseDRunnerHash $completionFile)) 'checkpoint_did_not_bind_final_firewall_receipt'; $count++
    $job.Dispose()
    Require-Test ($null -ne (Read-PhaseDPhysicalCleanupCheckpoint $spec.launchRoot $bundle.sha256)) 'replay_checkpoint_lost_after_job_close'; $count++
    $hostsBytes=[IO.File]::ReadAllBytes($hostsReceipt)
    Write-Test $hostsReceipt 'changed'
    Reject-Test { Read-PhaseDPhysicalCleanupCheckpoint $spec.launchRoot $bundle.sha256 }; $count++
    [IO.File]::WriteAllBytes($hostsReceipt,$hostsBytes)
    Reject-Test { Invoke-PhaseDWithJobZeroProof $spec.launchRoot $bundle.sha256 { $script:consumed++ } }
    Require-Test ($script:consumed -eq 1) 'absent_job_authorized_cleanup'; $count++
    $script:PhaseDAllowAbsentJobRecovery=$true
    Invoke-PhaseDWithJobZeroProof $spec.launchRoot $bundle.sha256 { param($proof,$verify) $verify.Invoke(); $script:consumed++ }
    Require-Test ($script:consumed -eq 2) 'absent_job_recovery_not_consumed'; $count++
    $liveIdentity=Join-Path $spec.launchRoot 'runtime-processes.identity.json'
    Write-AtomicJson $liveIdentity @{contractId='nll/phase-d-runtime-process-identities/v1';launchContextUid=$spec.launchContextUid
        client=@{processId=$outside.Id;processStartedAtUtc=$outside.StartTime.ToUniversalTime().ToString('o');executablePath=$powershell};bootstrap=$null;server=$null}
    Reject-Test { Invoke-PhaseDWithJobZeroProof $spec.launchRoot $bundle.sha256 { $script:consumed++ } }; $count++
    Require-Test ($script:consumed -eq 2) 'live_recorded_identity_authorized_cleanup'
    Remove-Item -LiteralPath $liveIdentity
    $script:PhaseDAllowAbsentJobRecovery=$false

    # Retirement runs directly so its recorded child identity is the actual
    # consumer, not an enclosing PowerShell process that remains alive.
    $native=Join-Path $root 'synthetic-consumer.exe'
    Add-Type -TypeDefinition 'public static class SyntheticConsumer { public static void Main(string[] args) { System.Console.WriteLine(System.Diagnostics.Process.GetCurrentProcess().Id); System.Console.WriteLine(string.Join("|", args)); } }' -OutputAssembly $native -OutputType ConsoleApplication
    $nativeIdentity=Join-Path $root 'native-child.identity.json'
    $result=Invoke-PhaseDChildScript -ScriptPath $native -DirectExecutable -Arguments ([ordered]@{'-synthetic'='value with spaces'}) `
        -OwnershipPath $nativeIdentity -TimeoutSeconds 15 -StandardOutputPath (Join-Path $root 'native.stdout') -StandardErrorPath (Join-Path $root 'native.stderr')
    $nativeOwner=Get-Content -LiteralPath $nativeIdentity -Raw | ConvertFrom-Json
    $nativeOutput=@($result.StandardOutput.Trim() -split '\r?\n')
    Require-Test ($result.ExitCode -eq 0 -and $nativeOwner.processId -eq [int]$nativeOutput[0] -and
        $nativeOwner.executablePath -ceq $native -and $nativeOutput[1] -ceq '--synthetic|value with spaces') 'native_retirement_identity_or_arguments_invalid'; $count++

    # A separately sealed execution exercises real watcher acquisition and commit.
    $spec.launchContextUid=[guid]::NewGuid().ToString('D'); $spec.launchRoot=Join-Path $root $spec.launchContextUid
    $spec.jobNonce=[guid]::NewGuid().ToString('N')
    $null=New-Item -ItemType Directory -Path (Join-Path $spec.launchRoot 'runtime')
    $spec.runtimeMaterializer=Join-Path $spec.launchRoot 'runtime/NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
    Write-Test $spec.runtimeMaterializer 'synthetic-not-executable'
    $bundle=New-PhaseDRunnerBundle $spec $PSScriptRoot
    $tool=Join-Path $spec.launchRoot 'tool.manifest.tsv'
    Write-Test $tool ("role_code`tbyte_length`tsha256`nrunner_bundle`t1`t" + $bundle.sha256 + "`n")
    Write-AtomicJson (Join-Path $spec.launchRoot 'launch-context.json') ([ordered]@{contractId='nll/launch-context/v1'; launchContextUid=$spec.launchContextUid; toolManifestSha256=(Get-PhaseDRunnerHash $tool)})
    $job=New-PhaseDExecutionJob $spec.launchRoot $bundle.sha256; $jobs.Add($job)
    $child=$job.Start($powershell,('-NoProfile -EncodedCommand ' + (Encode-Test $leafCode))); $processes.Add($child)
    $startIdentity=Join-Path $spec.launchRoot 'phase-d-child-start.identity.json'
    Write-AtomicJson $startIdentity ([ordered]@{
        contractId='nll/phase-d-child-deadline/v1'; processId=$child.Id
        processStartedAtUtc=$child.StartTime.ToUniversalTime().ToString('o'); executablePath=$powershell
    })
    Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot }; $count++
    Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot -RuntimeStartJob $job; $count++
    $pgIdentity=Join-Path $spec.launchRoot 'phase-d-child-pg.identity.json'
    Write-AtomicJson $pgIdentity ([ordered]@{
        contractId='nll/phase-d-child-deadline/v1'; processId=$outside.Id
        processStartedAtUtc=$outside.StartTime.ToUniversalTime().ToString('o'); executablePath=$powershell
    })
    Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot -RuntimeStartJob $job }; $count++
    Remove-Item -LiteralPath $pgIdentity
    # Start-Process from PS7 may inherit only PS7 module roots. This watcher is
    # WinPS5, like production, and needs its own built-in module directory.
    $watcherCode='$env:PSModulePath=Join-Path $PSHOME ''Modules''; '
    foreach ($file in @('Nll.PhaseDRunnerContract.ps1','Nll.PhaseDRunnerSeal.ps1','Nll.PhaseDProcessIdentity.ps1','Nll.PhaseDJob.ps1')) {
        $watcherCode += '. ' + (ConvertTo-PhaseDPowerShellLiteral (Join-Path $bundle.root $file)) + '; '
    }
    $watcherCode += '$script:PhaseDVerifiedRunnerBundle=Read-PhaseDRunnerBundle ' + (ConvertTo-PhaseDPowerShellLiteral $spec.launchRoot) + '; Assert-PhaseDRunnerSpecification $script:PhaseDVerifiedRunnerBundle.specification; '
    $watcherCode += '$j=Receive-PhaseDJobHandoff ' + (ConvertTo-PhaseDPowerShellLiteral $spec.launchRoot) + ' ' + (ConvertTo-PhaseDPowerShellLiteral $bundle.sha256) + '; try { Start-Sleep -Seconds 90 } finally { $j.Dispose() }'
    $watcherCode='try { '+$watcherCode+' } catch { $Error | ForEach-Object { [Console]::Error.WriteLine($_.ToString()+" at "+$_.ScriptStackTrace) }; exit 1 }'
    $watcherError=Join-Path $root 'watcher.stderr.log'
    $watcher=Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',(Encode-Test $watcherCode)) -WindowStyle Hidden -PassThru -RedirectStandardError $watcherError
    $processes.Add($watcher)
    Require-Test (-not (Test-PhaseDJobHandoffCommitted $spec.launchRoot $bundle.sha256 $watcher)) 'spawn_implicitly_committed'; $count++
    try { Confirm-PhaseDJobHandoff $spec.launchRoot $bundle.sha256 $watcher }
    catch { if (Test-Path -LiteralPath $watcherError) { Write-Output (Get-Content -LiteralPath $watcherError -Raw) }; throw }
    Require-Test (Test-PhaseDJobHandoffCommitted $spec.launchRoot $bundle.sha256 $watcher) 'commit_not_recognized'; $count++
    Require-Test (-not $job.Contains($watcher.Id)) 'watcher_in_job'
    $job.Dispose()
    Require-Test (-not $child.HasExited) 'handoff_dropped_last_handle'; $count++
    $watcher.Kill(); Require-Test ($watcher.WaitForExit(10000) -and $child.WaitForExit(10000)) 'last_owner_crash_not_contained'; $count++
    Reject-Test { Open-PhaseDExecutionJob $spec.launchRoot $bundle.sha256 }; $count++
    # Each failure owner uses the SAME rollback checkpoint publisher before PG.
    # Host/firewall boundaries are synthetic, not the installed OS resources.
    function Get-PhaseDJobSystemHostsPath { Join-Path $root 'synthetic-system-hosts' }
    function Get-NetFirewallRule { param($ErrorAction) @() }
    Write-Test (Get-PhaseDJobSystemHostsPath) 'synthetic-clean-hosts'
    foreach ($owner in @('coordinator','watcher','recovery')) {
        $spec.launchContextUid=[guid]::NewGuid().ToString('D'); $spec.launchRoot=Join-Path $root $spec.launchContextUid
        $spec.jobNonce=[guid]::NewGuid().ToString('N')
        $null=New-Item -ItemType Directory -Path (Join-Path $spec.launchRoot 'runtime'),(Join-Path $spec.launchRoot 'evidence')
        $spec.runtimeMaterializer=Join-Path $spec.launchRoot 'runtime/NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
        Write-Test $spec.runtimeMaterializer 'synthetic-not-executable'
        Write-Test (Join-Path $spec.launchRoot 'runtime/db.json') 'synthetic-restored-db'
        $spec.runtimeDbSha256=Get-PhaseDRunnerHash (Join-Path $spec.launchRoot 'runtime/db.json')
        Write-Test (Join-Path $spec.launchRoot 'control-center-hosts.before.bin') 'synthetic-clean-hosts'
        $bundle=New-PhaseDRunnerBundle $spec $PSScriptRoot
        $tool=Join-Path $spec.launchRoot 'tool.manifest.tsv'
        Write-Test $tool ("role_code`tbyte_length`tsha256`nrunner_bundle`t1`t"+$bundle.sha256+"`n")
        Write-AtomicJson (Join-Path $spec.launchRoot 'launch-context.json') @{contractId='nll/launch-context/v1';launchContextUid=$spec.launchContextUid;toolManifestSha256=(Get-PhaseDRunnerHash $tool)}
        $job=New-PhaseDExecutionJob $spec.launchRoot $bundle.sha256; $jobs.Add($job)
        Stop-PhaseDExecutionJob $spec.launchRoot $bundle.sha256
        $startReservation=Join-Path $spec.launchRoot 'phase-d-child-start.identity.json'
        Write-PhaseDChildReservation $startReservation $powershell
        Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot -RuntimeStartJob $job
        Write-PhaseDRollbackCleanupCheckpoint $spec.launchRoot $bundle.sha256
        $job.Dispose() # owner lost after a PG failure
        $checkpoint=Read-PhaseDPhysicalCleanupCheckpoint $spec.launchRoot $bundle.sha256
        Require-Test ($checkpoint.cleanupKind -ceq 'rollback') ($owner+'_rollback_replay_lost'); $count++
        Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot -CheckpointStartIdentitySha256 $checkpoint.startIdentitySha256; $count++
        Write-PhaseDChildReservation (Join-Path $spec.launchRoot 'phase-d-child-pg.identity.json') $powershell
        Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot -CheckpointStartIdentitySha256 $checkpoint.startIdentitySha256 }; $count++
        Remove-Item -LiteralPath (Join-Path $spec.launchRoot 'phase-d-child-pg.identity.json')
        [IO.File]::AppendAllText($startReservation,' ')
        Reject-Test { Read-PhaseDPhysicalCleanupCheckpoint $spec.launchRoot $bundle.sha256 }; $count++
        Reject-Test { Assert-PhaseDChildrenExited -LaunchRoot $spec.launchRoot -CheckpointStartIdentitySha256 $checkpoint.startIdentitySha256 }; $count++
        Reject-Test { Invoke-PhaseDWithJobZeroProof $spec.launchRoot $bundle.sha256 { throw 'unexpected_physical_replay' } }; $count++
    }
    # The v2 cleanup consumer binds range-only receipts without accepting a v1
    # whole-store hash as a substitute. Metadata only; no client file is present.
    $fxLaunch=Join-Path $root ([guid]::NewGuid().ToString('D'))
    $fxRoot=Join-Path $fxLaunch 'runtime/execution-fx'
    $null=New-Item -ItemType Directory -Path $fxRoot
    $fxManifest=Join-Path $fxRoot 'manifest.private.json'
    $fxRetired=Join-Path $fxRoot 'retired.json'
    Write-Test (Join-Path $fxLaunch 'job-zero.receipt.json') 'synthetic-zero-proof'
    Write-AtomicJson $fxManifest @{contractId='nll/common-native-fx-execution/v2';rangePlanSha256=('a'*64);patches=@(@{before=@{length=60}})}
    $fxSpec=[pscustomobject]@{launchContextUid=(Split-Path -Leaf $fxLaunch);executionFx=@{manifestSha256=(Get-PhaseDRunnerHash $fxManifest)}}
    $fxValue=@{contractId='nll/common-native-fx-retired/v2';manifestSha256=$fxSpec.executionFx.manifestSha256;
        terminationReceiptSha256=(Get-PhaseDRunnerHash (Join-Path $fxLaunch 'job-zero.receipt.json'));actualGameAcceptanceClaimed=$false;
        rangeReceipt=@{contractId='nll/common-native-fx-range-receipt/v2';executionUid=$fxSpec.launchContextUid;
            planSha256=('a'*64);state='restored';validationScope='patched_ranges';selectedBytes=60;bytesRead=120;bytesWritten=60}}
    Write-AtomicJson $fxRetired $fxValue
    Assert-PhaseDNativeFxRetirement $fxLaunch $fxSpec; $count++
    foreach ($field in @('validationScope','state','executionUid','planSha256','selectedBytes','bytesRead','bytesWritten')) {
        $old=$fxValue.rangeReceipt[$field]
        $fxValue.rangeReceipt[$field]=$(if ($field -in @('selectedBytes','bytesRead','bytesWritten')) { -1 } else { 'invalid' })
        Write-AtomicJson $fxRetired $fxValue
        Reject-Test { Assert-PhaseDNativeFxRetirement $fxLaunch $fxSpec }; $count++
        $fxValue.rangeReceipt[$field]=$old
    }
    $fxValue.terminationReceiptSha256='b'*64
    Write-AtomicJson $fxRetired $fxValue
    Reject-Test { Assert-PhaseDNativeFxRetirement $fxLaunch $fxSpec }; $count++
    Write-AtomicJson $fxRetired @{contractId='nll/common-native-fx-retired/v1';storeSha256=('a'*64)}
    Reject-Test { Assert-PhaseDNativeFxRetirement $fxLaunch $fxSpec }; $count++
    "Phase D Job: $count synthetic Windows checks passed (atomic descendants, exclusions, explicit handoff, crash, immutable same-job proof, closure, v2 range receipts)."
} finally {
    foreach ($job in $jobs) { $job.Dispose() }
    foreach ($process in $processes) {
        try { if (-not $process.HasExited) { $process.Kill(); $null=$process.WaitForExit(10000) } } finally { $process.Dispose() }
    }
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notlike 'nll-runner-contract-*') { throw 'unsafe_test_cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
