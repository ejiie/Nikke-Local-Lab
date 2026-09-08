[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$AssessmentUid,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$PlanSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedScriptSha256,
    [switch]$InspectInputs
)
# Elevated, bounded initialization run. No automated gameplay, old runtime or
# production DB. HTTP dispatch belongs exclusively to the existing Epinel pipeline.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedScriptSha256) { throw 'resource_native_runner_drift' }
$uid=[Guid]::Empty
if (-not [Guid]::TryParseExact($AssessmentUid,'D',[ref]$uid)) { throw 'resource_native_uid_invalid' }
$evidence=Join-Path 'C:\NLL\Staging\ResourceProbeRuns' $AssessmentUid
$planPath=Join-Path $evidence 'native.private.json'
if ((Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $PlanSha256) { throw 'resource_native_plan_drift' }
$plan=Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$helper=Join-Path $evidence 'Nll.ResourceNative.ps1'
if ((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant() -cne $plan.helperSha256) { throw 'resource_native_helper_drift' }
. $helper
Assert-RnPath $evidence
if (-not $InspectInputs) {
    Assert-Rn ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'administrator_required'
}
Assert-Rn ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ceq $plan.operatorSid) 'operator_changed'
$serverRoot=Join-Path 'C:\NLL\Runtime\EpinelPS-151-ResourceProbe' $AssessmentUid
$bootstrapRoot=Join-Path 'C:\NLL\Runtime\ResourceProbeBootstrap' $AssessmentUid
$clientRoot='C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe'
$localKeyBinding=$plan.contractId -ceq 'nll/resource-native-observation-plan/v3'
$sourceBaseline=$plan.contractId -ceq 'nll/resource-native-observation-plan/v4'
$epinelProvided=$plan.contractId -ceq 'nll/resource-native-observation-plan/v5'
$nativeReplacement=$localKeyBinding -or $sourceBaseline -or $epinelProvided
Assert-Rn ($plan.contractId -cin @('nll/resource-native-observation-plan/v2','nll/resource-native-observation-plan/v3','nll/resource-native-observation-plan/v4','nll/resource-native-observation-plan/v5') -and $plan.assessmentUid -ceq $AssessmentUid -and
    $plan.serverRoot -ceq $serverRoot -and $plan.bootstrapRoot -ceq $bootstrapRoot -and $plan.evidenceRoot -ceq $evidence -and
    $plan.clientRoot -ceq $clientRoot -and $plan.runnerSha256 -ceq $ExpectedScriptSha256 -and
    $plan.durationSeconds -eq 240 -and $plan.gameplayAllowed -eq $false) 'plan_boundary_invalid'
foreach ($directory in @($serverRoot,$bootstrapRoot)) {Assert-RnPath $directory}
Assert-Rn ($plan.nativeCompatibilityMode -ceq $(if ($epinelProvided) {'epinel_provided_library_control'} elseif ($sourceBaseline) {'source_built_unmodified_control'} elseif ($localKeyBinding) {'source_built_local_key_binding'} else {'stock_native_library_preserved'}) -and
    $plan.stockNativePin.path -ceq (Join-Path $clientRoot 'NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll') -and
    $plan.stockNativePin.sha256 -ceq '11a42045b328e74dc03e69be574c38f0004c515d364383f230ea4dba30414f6f') 'native_library_invalid'
Assert-RnPin $plan.stockNativePin
if ($nativeReplacement) {
    if ($epinelProvided) {Assert-RnEpinelProvided $plan.nativeKeyBinding}
    elseif ($sourceBaseline) {Assert-RnSourceBaseline $plan.nativeKeyBinding} else {Assert-RnLocalKeyBinding $plan.nativeKeyBinding}
    $bindingPins=@($plan.nativeKeyBinding.libraryPin)
    if (-not $epinelProvided) {$bindingPins += @($plan.nativeKeyBinding.buildReceiptPin,$plan.nativeKeyBinding.testReceiptPin)}
    foreach ($pin in $bindingPins) {
        Assert-Rn ($pin.path.StartsWith($evidence+'\rollback\',[StringComparison]::OrdinalIgnoreCase)) 'key_binding_path_invalid'
    }
}
$serverManifest=Join-Path $serverRoot 'resource-probe-runtime.private.json'
$bootstrapManifest=Join-Path $bootstrapRoot 'bootstrap.private.json'
$serverPlan=Read-RnJson $serverManifest $plan.serverPlanSha256
Assert-Rn ($serverPlan.contractId -ceq 'nll/epinel-resource-probe-runtime/v2' -and
    $serverPlan.assessmentUid -ceq $AssessmentUid -and $serverPlan.durationSeconds -eq 240 -and
    @(Compare-Object @('contractId','assessmentUid','durationSeconds','files') @($serverPlan.PSObject.Properties.Name)).Count -eq 0) 'server_plan_invalid'
$bootstrapPlan=Read-RnJson $bootstrapManifest $plan.bootstrapPlanSha256
Assert-Rn ($bootstrapPlan.authOnly -eq $false -and $bootstrapPlan.durationSeconds -eq 180) 'bootstrap_mode_invalid'
$serverExe=Join-Path $serverRoot 'EpinelPS.exe'
$bootstrapExe=Join-Path $bootstrapRoot 'NikkeLocalLab.Phase3B2.ResourceProbeBootstrap.exe'
$expectedPrograms=@(Get-ChildItem -LiteralPath $clientRoot -Recurse -File -Filter '*.exe' | Select-Object -ExpandProperty FullName) + @($serverExe,$bootstrapExe)
$programPins=@($plan.programs) + @($plan.blockOnlyPrograms)
$programs=@($programPins | ForEach-Object {$_.path})
Assert-Rn (@($programs | Sort-Object -Unique).Count -eq $programs.Count -and $expectedPrograms.Count -eq 8 -and
    @(Compare-Object ($expectedPrograms | Sort-Object) (@($plan.programs.path) | Sort-Object)).Count -eq 0) 'program_inventory_invalid'
$officialLauncher=@(Get-RnBlockOnlyProgramPaths)
Assert-Rn (@(Compare-Object ($officialLauncher | Sort-Object) (@($plan.blockOnlyPrograms.path) | Sort-Object)).Count -eq 0) 'launcher_inventory_changed'
foreach ($pin in $programPins) {Assert-RnPin $pin}
Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -in $programs -or $_.Name -match '^(nikke|nikke_launcher|EpinelPS|ACE-Service64|ACE-Setup64|TQMCenter_64|NikkeLocalLab\.Phase3B2\..*Bootstrap)\.exe$'}).Count -eq 0) 'runtime_not_cold'
Assert-Rn (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in 80,443,8443).Count -eq 0) 'listener_present'
Assert-Rn (@(Get-NetFirewallProfile | Where-Object {-not $_.Enabled}).Count -eq 0) 'firewall_disabled'
$allowedChanges=@((Join-Path $clientRoot 'NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem'),(Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'))
if ($nativeReplacement) { $allowedChanges += $plan.stockNativePin.path }
Assert-Rn ($plan.fileChanges.Count -eq $allowedChanges.Count -and @(Compare-Object ($allowedChanges | Sort-Object) (@($plan.fileChanges.before.path) | Sort-Object)).Count -eq 0) 'mutation_targets_invalid'
if ($nativeReplacement) {
    $keyChanges=@($plan.fileChanges | Where-Object {$_.before.path -ceq $plan.stockNativePin.path})
    Assert-Rn ($keyChanges.Count -eq 1 -and $keyChanges[0].before.sha256 -ceq $plan.stockNativePin.sha256 -and
        $keyChanges[0].replacement.sha256 -ceq $plan.nativeKeyBinding.libraryPin.sha256 -and
        $keyChanges[0].replacement.path -ceq $plan.nativeKeyBinding.libraryPin.path) 'key_mutation_invalid'
}
foreach ($change in $plan.fileChanges) {
    Assert-RnPin $change.before; Assert-RnPin $change.backup; Assert-RnPin $change.replacement
    Assert-Rn ($change.backup.path.StartsWith($evidence+'\rollback\',[StringComparison]::OrdinalIgnoreCase) -and
        $change.replacement.path.StartsWith($evidence+'\rollback\',[StringComparison]::OrdinalIgnoreCase) -and
        $change.before.sha256 -ceq $change.backup.sha256) 'backup_invalid'
}
Assert-RnPin $plan.publicRoot
$publicCa=[Security.Cryptography.X509Certificates.X509Certificate2]::new($plan.publicRoot.path)
Assert-Rn (-not $publicCa.HasPrivateKey -and $publicCa.NotAfter.ToUniversalTime() -gt [DateTime]::UtcNow) 'root_invalid'
$group='NLL Resource Native ' + $AssessmentUid
Assert-Rn (@(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count -eq 0) 'stale_firewall'
$receiptPath=Join-Path $evidence 'native-execution.receipt.json'
Assert-Rn (-not (Test-Path -LiteralPath $receiptPath) -and -not (Test-Path -LiteralPath (Join-Path $serverRoot 'probe-started.marker'))) 'attempt_reused'
if ($InspectInputs) {
    $publicCa.Dispose()
    [ordered]@{status='native_execution_inputs_verified_not_started';diagnosticHttpLayerPresent=$false;programCount=$programs.Count;systemChangesApplied=$false;clientStarted=$false;serverStarted=$false} | ConvertTo-Json
    return
}
$serverProcess=$null; $bootstrapProcess=$null
$oldEnv=$env:NLL_RESOURCE_PROBE_BOOTSTRAP_SHA256
$failure=$null; $stage='isolation'; $cleanup=$false; $isolation=$false; $rootAdded=$false; $preferencesTouched=$false; $cleanupFailureDetail=$null
$started=[DateTimeOffset]::UtcNow
$mutations=[Collections.Generic.List[object]]::new()
function Assert-NativeFirewall {
    $rules=@(Get-NetFirewallRule -Group $group -PolicyStore ActiveStore)
    Assert-Rn ($rules.Count -eq $programs.Count) 'firewall_count_invalid'
    $seen=@()
    foreach ($rule in $rules) {
        Assert-Rn ($rule.Enabled -eq 'True' -and $rule.Direction -eq 'Outbound' -and $rule.Action -eq 'Block') 'firewall_rule_invalid'
        $application=(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule).Program
        Assert-Rn ($application -in $programs -and $application -notin $seen) 'firewall_program_invalid'
        $seen += $application
        Assert-Rn (@((Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule).RemoteAddress).Count -eq 1 -and
            (Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule).RemoteAddress -eq 'Any') 'firewall_address_invalid'
    }
}
try {
    for ($i=0;$i -lt $programs.Count;$i++) {
        New-NetFirewallRule -Name ('NLL-ResourceNative-'+$AssessmentUid+'-'+$i) -DisplayName ($group+' '+$i) -Group $group -Direction Outbound -Action Block -Enabled True -Profile Any -Program $programs[$i] -RemoteAddress Any | Out-Null
    }
    Assert-NativeFirewall
    $isolation=$true
    $stage='mutations'
    Write-RnNewJson (Join-Path $evidence 'rollback-ready.receipt.json') ([ordered]@{contractId='nll/resource-native-rollback-preparation/v1';assessmentUid=$AssessmentUid;planSha256=$PlanSha256;backupHashesVerified=$true;restorationExecuted=$false})
    foreach ($change in $plan.fileChanges) {
        $mutations.Add($change)
        Set-RnPinnedFile $change.before $change.replacement
    }
    $preferencesTouched=$true
    Set-RnVoicePreferences $plan.preferencesBefore $plan.preferencesAfter
    $store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine')
    $store.Open('ReadWrite')
    try {
        $present=@($store.Certificates | Where-Object Thumbprint -eq $publicCa.Thumbprint)
        Write-RnNewJson (Join-Path $evidence 'trust-before.receipt.json') ([ordered]@{thumbprint=$publicCa.Thumbprint;previouslyPresent=($present.Count -gt 0)})
        if ($present.Count -eq 0) {$rootAdded=$true; $store.Add($publicCa)}
        Assert-Rn (@($store.Certificates | Where-Object Thumbprint -eq $publicCa.Thumbprint).Count -eq 1) 'root_apply_failed'
    } finally {$store.Dispose()}
    Clear-DnsClientCache
    Assert-NativeFirewall
    Write-RnNewJson (Join-Path $evidence 'isolation.ready.json') ([ordered]@{contractId='nll/resource-probe-isolation/v2';assessmentUid=$AssessmentUid;bootstrapPlanSha256=$plan.bootstrapPlanSha256
        allProgramsBlocked=$true;rollbackPrepared=$true;systemChangesVerified=$true;verifiedAtUtc=[DateTimeOffset]::UtcNow})
    $stage='server_start'
    $serverProcess=Start-Process -FilePath $serverExe -WorkingDirectory $serverRoot -ArgumentList @('--headless','--local-only','--resource-route-probe',$plan.serverPlanSha256) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $evidence 'native-server.stdout.private.log') -RedirectStandardError (Join-Path $evidence 'native-server.stderr.private.log')
    $null=$serverProcess.Handle
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $ready=$false
    while ($clock.Elapsed.TotalSeconds -lt 45 -and -not $serverProcess.HasExited) {
        $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $serverProcess.Id)
        Assert-Rn (@($listeners | Where-Object LocalAddress -ne '127.0.0.1').Count -eq 0) 'non_loopback_listener'
        if (@($listeners | Where-Object LocalPort -eq 443).Count -eq 1) {$ready=$true;break}
        Start-Sleep -Milliseconds 500
    }
    Assert-Rn $ready 'server_not_ready'
    Assert-NativeFirewall
    $stage='native_observation'
    $env:NLL_RESOURCE_PROBE_BOOTSTRAP_SHA256=$plan.bootstrapPlanSha256
    $bootstrapProcess=Start-Process -FilePath $bootstrapExe -WorkingDirectory $bootstrapRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $evidence 'native-bootstrap.stdout.private.log') -RedirectStandardError (Join-Path $evidence 'native-bootstrap.stderr.private.log')
    $null=$bootstrapProcess.Handle
    while (-not $bootstrapProcess.HasExited -and -not $serverProcess.HasExited -and $clock.Elapsed.TotalSeconds -lt 235) {
        $blocked=@(Get-CimInstance Win32_Process | Where-Object ExecutablePath -in @($plan.blockOnlyPrograms.path))
        if ($blocked.Count -gt 0) {
            # Observation only: keep the existing stop predicate and error code.
            Write-RnNewJson (Join-Path $evidence 'blocked-program.receipt.json') ([ordered]@{
                contractId='nll/resource-native-blocked-program-observation/v1';assessmentUid=$AssessmentUid
                observedAtUtc=[DateTimeOffset]::UtcNow
                programs=@(Get-RnBlockedProgramObservations @($plan.blockOnlyPrograms.path) $blocked)
                rawPathEmitted=$false;commandLineEmitted=$false})
        }
        Assert-Rn ($blocked.Count -eq 0) 'official_launcher_spawned'
        $scoped=@(Get-CimInstance Win32_Process | Where-Object ExecutablePath -in $programs)
        Assert-Rn (@(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object {$_.OwningProcess -in @($scoped.ProcessId) -and $_.RemoteAddress -notin '127.0.0.1','::1'}).Count -eq 0) 'non_loopback_connection'
        Start-Sleep -Milliseconds 500
    }
    Assert-Rn ($bootstrapProcess.HasExited) 'bootstrap_timeout'
    # Local-only Epinel may return 404 on cache misses. A bounded run completing
    # is not loading/lobby success; use private existing server logs for analysis.
    $stage='server_shutdown'
    while (-not $serverProcess.HasExited -and $clock.Elapsed.TotalSeconds -lt 250) {Start-Sleep -Milliseconds 500}
    Assert-Rn ($serverProcess.HasExited) 'server_timeout'
    Assert-Rn ($serverProcess.ExitCode -eq 0) 'server_failed'
}
catch {
    $failure=if ($_.Exception.Message -cmatch '^resource_native_[a-z_]+$') {$_.Exception.Message} else {'resource_native_unexpected_failure'}
    Write-RnNewJson (Join-Path $evidence 'native-failure.receipt.json') ([ordered]@{stage=$stage;code=$failure;type=$_.Exception.GetType().FullName;hresult=$_.Exception.HResult;line=$_.InvocationInfo.ScriptLineNumber})
}
finally {
    $env:NLL_RESOURCE_PROBE_BOOTSTRAP_SHA256=$oldEnv
    try {
        foreach ($process in @($bootstrapProcess,$serverProcess)) {
            if ($null -ne $process -and -not $process.HasExited) {$process.Kill($true); $null=$process.WaitForExit(10000)}
        }
        # Cold admission proved these exact programs absent. Recheck path +
        # creation time immediately before stopping a surviving owned descendant.
        foreach ($entry in @(Get-CimInstance Win32_Process | Where-Object ExecutablePath -in $programs)) {
            Assert-Rn ($entry.CreationDate.ToUniversalTime() -ge $started.UtcDateTime.AddSeconds(-1)) 'survivor_identity_uncertain'
            $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$entry.ProcessId)
            Assert-Rn ($again.ExecutablePath -ceq $entry.ExecutablePath -and $again.CreationDate -eq $entry.CreationDate) 'survivor_identity_changed'
            Stop-Process -Id $entry.ProcessId -Force
        }
        Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object ExecutablePath -in $programs).Count -eq 0) 'process_cleanup_failed'
        if ($rootAdded) {
            $store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine'); $store.Open('ReadWrite')
            try {
                foreach ($certificate in @($store.Certificates | Where-Object Thumbprint -eq $publicCa.Thumbprint)) {$store.Remove($certificate)}
                Assert-Rn (@($store.Certificates | Where-Object Thumbprint -eq $publicCa.Thumbprint).Count -eq 0) 'root_cleanup_failed'
            } finally {$store.Dispose()}
        }
        if ($preferencesTouched) {
            $current=@(Get-RnVoicePreferences)
            for ($i=0;$i -lt 2;$i++) {Assert-Rn ($current[$i].value -cin @($plan.preferencesBefore[$i].value,$plan.preferencesAfter[$i].value) -and $current[$i].kind -ceq $plan.preferencesBefore[$i].kind) 'preference_cleanup_conflict'}
            Set-RnVoicePreferences $current $plan.preferencesBefore
        }
        for ($i=$mutations.Count-1;$i -ge 0;$i--) {
            $change=$mutations[$i]
            if ((Get-RnHash $change.before.path) -ceq $change.before.sha256) {continue}
            $applied=[pscustomobject]@{path=$change.before.path;length=$change.replacement.length;sha256=$change.replacement.sha256}
            Set-RnPinnedFile $applied $change.backup
            Assert-RnPin $change.before
        }
        Clear-DnsClientCache
        Assert-RnPin $plan.stockNativePin
        Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        Assert-Rn (@(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count -eq 0) 'firewall_cleanup_failed'
        $cleanup=$true
    } catch {
        $cleanupFailureDetail=[ordered]@{type=$_.Exception.GetType().FullName;hresult=$_.Exception.HResult;line=$_.InvocationInfo.ScriptLineNumber}
        if (-not $failure) {$failure='resource_native_cleanup_unverified'}
    }
    # On uncertainty preserve program blocking and all recovery material.
    $startReceipt=Join-Path $evidence 'bootstrap-start.receipt.json'
    Write-RnNewJson $receiptPath ([ordered]@{contractId=$(if ($epinelProvided) {'nll/resource-native-observation-execution/v5'} elseif ($sourceBaseline) {'nll/resource-native-observation-execution/v4'} elseif ($localKeyBinding) {'nll/resource-native-observation-execution/v3'} else {'nll/resource-native-observation-execution/v2'});assessmentUid=$AssessmentUid
        nativeCompatibilityMode=$plan.nativeCompatibilityMode
        requestPipeline='epinel_existing_handlers';diagnosticHttpLayerPresent=$false
        status=$(if ($cleanup -and -not $failure -and (Test-Path -LiteralPath $startReceipt)) {'bounded_initialization_run_completed'} else {'native_observation_incomplete'})
        failureCode=$failure;cleanupFailureDetail=$cleanupFailureDetail;startedAtUtc=$started;finishedAtUtc=[DateTimeOffset]::UtcNow
        clientHandoffObserved=(Test-Path -LiteralPath $startReceipt)
        requestCount=$null;requestCountSource='not_collected';httpEvidenceSource='existing_server_private_logs'
        isolationVerified=$isolation;cleanupVerified=$cleanup;productionDbModified=$false;nativeAdmission='not_evaluated';gameplayValidated=$false})
    $publicCa.Dispose()
    foreach ($process in @($bootstrapProcess,$serverProcess)) {if ($null -ne $process) {$process.Dispose()}}
}
if ($failure -or -not $cleanup) {exit 1}
