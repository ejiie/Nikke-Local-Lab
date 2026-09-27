[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EntryPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$EntrySha256,
    [ValidateSet('Inspect','Start','Recover')][string]$Mode='Inspect',
    [string]$DiagnosticRoot
)
# Start/Recover are USER-owned elevated entry points. Inspect never launches a
# server/game or changes hosts, registry, firewall, services, drivers or the CDB.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if((Get-FileHash -LiteralPath $EntryPath).Hash.ToLowerInvariant() -cne $EntrySha256){throw 'uv_entry_drift'}
$entry=Get-Content -LiteralPath $EntryPath -Raw | ConvertFrom-Json
if($entry.contractId -cne 'nll/user-validation-entry/v1' -or
    $entry.controller.path -cne $PSCommandPath -or
    (Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() -cne $entry.controller.sha256){throw 'uv_controller_drift'}
# Verify the COMPLETE local helper closure before dot-sourcing any helper.
$names=@('Nll.ResourceNative.ps1','Nll.NativeFxManagedService.ps1','Nll.NativeFxManagedDriver.ps1',
    'Nll.UserValidationController.ps1','Nll.UserValidationPreflight.ps1','Nll.PhaseDJob.cs','Nll.FxProcessIdentity.cs','NikkeLocalLab.NativeFxUserValidationStore.dll')
if($entry.tools.Count -ne $names.Count){throw 'uv_tool_inventory_invalid'}
foreach($name in $names){
    $pins=@($entry.tools | Where-Object path -CEQ (Join-Path $PSScriptRoot $name))
    if($pins.Count -ne 1 -or (Get-FileHash -LiteralPath $pins[0].path).Hash.ToLowerInvariant() -cne $pins[0].sha256){throw 'uv_tool_drift'}
}
. (Join-Path $PSScriptRoot 'Nll.NativeFxManagedDriver.ps1')
. (Join-Path $PSScriptRoot 'Nll.UserValidationController.ps1')
. (Join-Path $PSScriptRoot 'Nll.UserValidationPreflight.ps1')
Assert-Rn ($entry.preflightContractId -ceq 'nll/user-validation-preflight/v1' -and $entry.preflightMode -ceq 'deep') 'uv_preflight_contract_invalid'
foreach($pin in @($entry.controller,$entry.parentPlan,$entry.bootstrapPlan,$entry.stagingReceipt,$entry.storePlan)+@($entry.tools)){Assert-RnPin $pin}
$plan=Read-RnJson $entry.parentPlan.path $entry.parentPlan.sha256
$bootstrap=Read-RnJson $entry.bootstrapPlan.path $entry.bootstrapPlan.sha256
$staging=Read-RnJson $entry.stagingReceipt.path $entry.stagingReceipt.sha256
$storePlan=Read-RnJson $entry.storePlan.path $entry.storePlan.sha256
Assert-UvBinding $plan $bootstrap $staging $storePlan
$run=$plan.runRoot
if($DiagnosticRoot){
    Assert-RnPath $DiagnosticRoot
    $actionUid=[guid]::ParseExact((Split-Path -Leaf $DiagnosticRoot),'D').ToString('D')
    Assert-Rn ($DiagnosticRoot -ceq (Join-Path $run ('ui-actions\'+$actionUid))) 'uv_diagnostic_path_invalid'
    $requestPath=Join-Path $DiagnosticRoot 'request.json'
    Assert-RnPath $requestPath
    Assert-Rn ((Get-Item -LiteralPath $requestPath).Length -le 16384) 'uv_diagnostic_request_invalid'
    $request=Get-Content -LiteralPath $requestPath -Raw|ConvertFrom-Json
    Assert-Rn ($request.operationUid -ceq $actionUid -and $request.entrySha256 -ceq $EntrySha256 -and $request.mode -ceq $Mode) 'uv_diagnostic_request_invalid'
}
Start-UvTrace $DiagnosticRoot $EntrySha256 $Mode
Assert-Rn ($plan.clientRollbackManifest.path -ceq ('C:\NLL\Staging\NativeFxUserValidation\'+$plan.trialUid+'\client-pins.private.json')) 'uv_client_rollback_path'
$clientManifest=Read-RnJson $plan.clientRollbackManifest.path $plan.clientRollbackManifest.sha256
Assert-Rn ($clientManifest.trialUid -ceq $plan.trialUid -and $clientManifest.clientRoot -ceq $plan.clientRoot -and
    $clientManifest.contractId -ceq 'nll/user-validation-client-pins/v1') 'uv_client_rollback_binding'
$plan|Add-Member NoteProperty clientRollback @($clientManifest.rollback)
Assert-Rn ($PSScriptRoot -ceq (Join-Path $run 'controller') -and $EntryPath -ceq (Join-Path $run 'entry.private.json') -and
    $entry.parentPlan.path -ceq (Join-Path $run 'validation.private.json') -and
    $entry.bootstrapPlan.path -ceq (Join-Path $plan.bootstrapRoot 'bootstrap.private.json') -and
    $entry.stagingReceipt.path -ceq (Join-Path $run 'runtime-staging.receipt.json') -and
    $entry.storePlan.path -ceq (Join-Path $run 'native-store.private.json') -and
    $plan.runtimeStagingSha256 -ceq $entry.stagingReceipt.sha256 -and
    $bootstrap.parentPlanSha256 -ceq $entry.parentPlan.sha256 -and
    $plan.nativeStorePlanSha256 -ceq $entry.storePlan.sha256) 'uv_entry_binding_invalid'
foreach($root in @($run,$plan.clientRoot,$plan.serverRoot,$plan.bootstrapRoot,$plan.childRoot)){Assert-RnPath $root}
Assert-Rn ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ceq $plan.operatorSid) 'uv_operator_invalid'
Assert-Rn ([IntPtr]::Size -eq 8) 'uv_x64_shell_required'
if($Mode -cne 'Inspect'){
    Assert-Rn ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'uv_administrator_required'
}
Assert-FxValidationDriverPolicy $plan.driverPolicy
$executionPins=@($plan.programs)+@($plan.blockOnlyPrograms)+@($plan.childFiles)+@($plan.protectedFiles)+@($plan.serviceImage)
$deepPins=$executionPins+
    @($staging.serverFiles)+@($staging.bootstrapFiles)+@($plan.clientFiles)+@($plan.serviceImage)+@($plan.clientRollback|ForEach-Object backup)
foreach($set in @($deepPins|Group-Object path)){
    Assert-Rn (@($set.Group.sha256|Sort-Object -Unique).Count -eq 1 -and @($set.Group.length|Sort-Object -Unique).Count -eq 1) 'uv_conflicting_file_pins'
}
$deepPins=@($deepPins|Sort-Object path -Unique)
foreach($pin in @($plan.publicRoot,$plan.hostsChange.backup,$plan.hostsChange.replacement)){Assert-RnPin $pin}
Assert-Rn ($plan.hostsChange.backup.path -ceq (Join-Path $run 'rollback/hosts.before') -and
    $plan.hostsChange.replacement.path -ceq (Join-Path $run 'rollback/hosts.after') -and
    $plan.hostsChange.before.path -ceq 'C:\Windows\System32\drivers\etc\hosts' -and
    $plan.hostsChange.before.sha256 -ceq $plan.hostsChange.backup.sha256 -and
    $plan.serviceImage.path -ceq 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe' -and
    $plan.serviceImage.sha256 -ceq '6cfed38df64fcbb4a9863c4684ff7b1ccc1baa1ac45923f603f4969ad8a96777') 'uv_restore_or_service_invalid'
$expected=@(Get-ChildItem -LiteralPath $plan.clientRoot -Recurse -File -Filter '*.exe' | ForEach-Object FullName)+
    @((Join-Path $plan.serverRoot 'EpinelPS.exe'),(Join-Path $plan.bootstrapRoot 'NikkeLocalLab.NativeFxUserValidationBootstrap.exe'),
    (Join-Path $plan.childRoot 'NikkeLocalLab.NativeFxUserValidationChild.exe'))
Assert-Rn (@(Compare-Object ($expected|Sort-Object) ($plan.programs.path|Sort-Object)).Count -eq 0) 'uv_program_inventory_invalid'
$programs=@($plan.programs.path)+@($plan.blockOnlyPrograms.path)
Assert-Rn (@($programs|Sort-Object -Unique).Count -eq $programs.Count) 'uv_duplicate_program'
Add-Type -Path (Join-Path $PSScriptRoot 'Nll.FxProcessIdentity.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'Nll.PhaseDJob.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'NikkeLocalLab.NativeFxUserValidationStore.dll')
$relatedParents=@{}
function Get-UvScoped([string]$JobName) {
    $names=@($programs | ForEach-Object {[IO.Path]::GetFileName($_)})
    $all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
    $related=[Collections.Generic.HashSet[int]]::new()
    foreach($p in $all){
        if($p.ExecutablePath -in $programs -or $p.Name -in $names -or
            ($relatedParents.ContainsKey([int]$p.ParentProcessId) -and $p.CreationDate.ToUniversalTime().ToFileTimeUtc() -ge $relatedParents[[int]$p.ParentProcessId])){
            $null=$related.Add([int]$p.ProcessId)
        }
    }
    do{$added=$false;foreach($p in $all){if($related.Contains([int]$p.ParentProcessId) -and $related.Add([int]$p.ProcessId)){$added=$true}}}while($added)
    $rows=@(foreach($p in $all){if($related.Contains([int]$p.ProcessId)){
        $identity=[Nll.Fx.ProcessIdentity]::Read([int]$p.ProcessId,$JobName)
        if($null -eq $identity){continue}
        $created=[datetime]::FromFileTimeUtc($identity.CreatedFileTime)
        Assert-Rn (($created.Ticks-($created.Ticks%10)) -eq $p.CreationDate.ToUniversalTime().Ticks -and
            (-not $p.ExecutablePath -or $p.ExecutablePath -ieq $identity.ImagePath)) 'uv_process_identity_drift'
        $relatedParents[[int]$p.ProcessId]=$identity.CreatedFileTime
        [pscustomobject]@{ProcessId=$p.ProcessId;ParentProcessId=$p.ParentProcessId;CreationDate=$created;
            ExecutablePath=$identity.ImagePath;Name=$p.Name;JobMember=$identity.JobMember}
    }})
    return ,$rows
}
$group='NLL User Validation '+$plan.assessmentUid
function Assert-UvFirewall {
    Assert-Rn (@(Get-NetFirewallProfile -ErrorAction Stop | Where-Object {-not $_.Enabled}).Count -eq 0) 'uv_firewall_disabled'
    $rules=@(Get-NetFirewallRule -Group $group -PolicyStore ActiveStore -ErrorAction Stop)
    Assert-Rn ($rules.Count -eq $programs.Count) 'uv_firewall_count'
    $seen=@()
    foreach($rule in $rules){
        $app=(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop).Program
        $addresses=@((Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop).RemoteAddress)
        Assert-Rn ($rule.Enabled -eq 'True' -and $rule.Direction -eq 'Outbound' -and $rule.Action -eq 'Block' -and
            $app -in $programs -and $app -notin $seen -and $addresses.Count -eq 1 -and $addresses[0] -eq 'Any') 'uv_firewall_drift'
        $seen+=$app
    }
}
function Assert-UvSystemApplied {
    Assert-Rn ((Get-RnHash $plan.hostsChange.before.path) -ceq $plan.hostsChange.replacement.sha256 -and
        (Compare-UvVoicePreferences $plan.preferencesAfter (Get-UvVoicePreferences)).equal) 'uv_system_drift'
}
function Assert-UvQuickState {
    Invoke-UvPreferenceCheck $plan.preferencesBefore $script:UvTrace.stage {Get-UvVoicePreferences} {
        param($evidence)
        if($DiagnosticRoot){Write-RnNewJson (Join-Path $DiagnosticRoot ('preferences-'+$script:UvTrace.sequence+'.json')) ([ordered]@{
            contractId='nll/user-validation-preference-observation/v1';entrySha256=$EntrySha256;stage=$evidence.stage;
            environment=(Get-UvPreferenceEnvironment $plan.operatorSid);comparison=$evidence.comparison;actualGameAcceptanceClaimed=$false})}
    }
    Assert-RnPin $plan.hostsChange.before
    Assert-Rn ((Get-UvScoped).Count -eq 0) 'uv_runtime_not_cold'
    Assert-FxManagedServiceSnapshot (Get-FxManagedServiceSnapshot) before
    Assert-FxManagedServiceNoDependents
    Assert-FxValidationDrivers $plan.driverPolicy (Get-FxValidationDriverSnapshot) before
    Assert-Rn (@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -in 80,443,8443).Count -eq 0) 'uv_listener_present'
    Assert-Rn (@(Get-NetFirewallProfile -ErrorAction Stop|Where-Object {-not $_.Enabled}).Count -eq 0) 'uv_firewall_disabled'
    Assert-Rn (@(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count -eq 0) 'uv_stale_firewall'
    $ca=[Security.Cryptography.X509Certificates.X509Certificate2]::new($plan.publicRoot.path)
    $trust=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine');$trust.Open('ReadOnly')
    try{Assert-Rn (@($trust.Certificates|Where-Object Thumbprint -eq $ca.Thumbprint).Count -eq 1 -and
        -not $ca.HasPrivateKey -and $ca.NotAfter.ToUniversalTime() -gt [datetime]::UtcNow) 'uv_existing_trust_invalid'}finally{$trust.Dispose();$ca.Dispose()}
}
function Invoke-UvMeasuredStore([string]$Operation,[bool]$Cold) {
    try{
        $result=[NikkeLocalLab.Phase3B2.UserValidation.NativeStoreOperations]::Execute($entry.storePlan.path,$entry.storePlan.sha256,$Operation,$Cold)|ConvertFrom-Json
        $script:UvTrace.completedBytes+=[long]$result.storeBytesRead
        return $result
    }catch{
        for($errorValue=$_.Exception;$null -ne $errorValue;$errorValue=$errorValue.InnerException){
            if($errorValue.Data.Contains('userValidationStoreBytesRead')){
                $script:UvTrace.completedBytes+=[long]$errorValue.Data['userValidationStoreBytesRead'];break
            }
        }
        throw
    }
}
function Write-UvMarker([string]$Name,[string]$Contract,$Extra) {
    $value=[ordered]@{contractId=$Contract;assessmentUid=$plan.assessmentUid;trialUid=$plan.trialUid;executionOwnerCode='user';
        jobName=$plan.jobName;parentPlanSha256=$entry.parentPlan.sha256;bootstrapPlanSha256=$entry.bootstrapPlan.sha256;
        runtimeStagingSha256=$entry.stagingReceipt.sha256;verifiedAtUtc=[DateTimeOffset]::UtcNow}
    foreach($key in $Extra.Keys){$value[$key]=$Extra[$key]}
    Write-RnNewJson (Join-Path $run $Name) $value
}
$mutex=[Threading.Mutex]::new($false,'Global\NLL.NativeFxUserValidation')
$locked=$false;$job=$null;$child=$null;$claimed=$false;$cleanup=$null;$failure=$null;$cleanupFailure=$null;$stage='preflight'
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    Assert-Rn $locked 'uv_another_controller_active'
    Set-UvStage 'quick_check'
    if($Mode -ceq 'Recover'){
        $startedPath=Join-Path $run 'execution.started.json'
        Assert-RnPath $startedPath
        Assert-Rn ((Get-Item -LiteralPath $startedPath).Length -le 65536) 'uv_recovery_receipt_invalid'
        $started=Get-Content -LiteralPath $startedPath -Raw|ConvertFrom-Json
        Assert-Rn ($started.entrySha256 -ceq $EntrySha256 -and $started.assessmentUid -ceq $plan.assessmentUid -and
            -not (Test-Path -LiteralPath (Join-Path $run 'cleanup.receipt.json'))) 'uv_recovery_binding'
        Set-UvStage 'deep_check' ([long](($executionPins|Measure-Object length -Sum).Sum))
        foreach($pin in $executionPins){Assert-UvMeasuredPin $pin}
    } else {
        Assert-Rn (-not (Test-Path -LiteralPath (Join-Path $run 'execution.started.json'))) 'uv_run_already_used'
        foreach($marker in @(Get-ChildItem -LiteralPath 'C:\NLL\Staging\NativeFxUserValidation' -Recurse -File -Filter 'execution.started.json')){
            $done=Join-Path $marker.DirectoryName 'cleanup.receipt.json'
            Assert-Rn (Test-Path -LiteralPath $done) 'uv_previous_recovery_required'
            $receipt=Get-Content -LiteralPath $done -Raw|ConvertFrom-Json
            Assert-Rn ($receipt.isolationReleased -eq $true -and $receipt.driverBaselineRestored -eq $true -and $receipt.ownedInputsRestored -eq $true) 'uv_previous_recovery_required'
        }
        $blockOnly=@(Get-RnBlockOnlyProgramPaths)+@(Get-ChildItem -LiteralPath 'C:\Program Files\AntiCheatExpert' -Recurse -File -Filter '*.exe'|ForEach-Object FullName)
        Assert-Rn (@(Compare-Object ($blockOnly|Sort-Object -Unique) ($plan.blockOnlyPrograms.path|Sort-Object)).Count -eq 0) 'uv_block_inventory_drift'
        Invoke-UvPreflightSequence -Quick {Assert-UvQuickState} -Deep {
            Set-UvStage 'deep_check' ([long](($deepPins|Measure-Object length -Sum).Sum)+[long]$storePlan.originalStore.length)
            foreach($pin in $deepPins){Assert-UvMeasuredPin $pin}
            $inspected=Invoke-UvMeasuredStore 'inspect' $false
            Assert-Rn ($inspected.storeSha256 -ceq $storePlan.originalStore.sha256) 'uv_store_not_original'
        } -Recheck {Set-UvStage 'shared_state_recheck';Assert-UvQuickState}
        if($Mode -ceq 'Inspect'){
            Set-UvStage 'complete'
            [ordered]@{statusCode='offline_inputs_verified';weaknessCode=$plan.weaknessCode;gameStarted=$false;systemChangesApplied=$false;actualGameAcceptanceClaimed=$false}|ConvertTo-Json -Compress
            return
        }
        Write-RnNewJson (Join-Path $run 'execution.started.json') ([ordered]@{entrySha256=$EntrySha256;assessmentUid=$plan.assessmentUid;startedAtUtc=[DateTimeOffset]::UtcNow})
    }
    $claimed=$true
    if($Mode -ceq 'Start'){
        $job=[Nll.PhaseD.ExecutionJob]::Create($plan.jobName)
        Write-RnNewJson (Join-Path $run 'job-owned.json') ([ordered]@{entrySha256=$EntrySha256;jobName=$plan.jobName;createdBeforeLaunch=$true})
        $stage='isolation'
        Set-UvStage 'isolation'
        for($i=0;$i -lt $programs.Count;$i++){
            New-NetFirewallRule -Name ('NLL-UserValidation-'+$plan.assessmentUid+'-'+$i) -DisplayName ($group+' '+$i) -Group $group `
                -Direction Outbound -Action Block -Enabled True -Profile Any -Program $programs[$i] -RemoteAddress Any -ErrorAction Stop|Out-Null
        }
        Assert-UvFirewall
        $stage='native_store_apply'
        Set-UvStage 'native_store_apply' ([long]$storePlan.originalStore.length*2)
        Assert-Rn ((Get-UvScoped).Count -eq 0 -and $job.ActiveProcesses -eq 0) 'uv_apply_scope_not_cold'
        $null=Invoke-UvMeasuredStore 'apply' $true
        $stage='system_apply'
        Set-UvStage 'system_apply'
        Set-RnPinnedFile $plan.hostsChange.before $plan.hostsChange.replacement
        Set-UvVoicePreferences $plan.preferencesBefore $plan.preferencesAfter
        Clear-DnsClientCache
        Assert-UvSystemApplied;Assert-UvFirewall
        Assert-FxManagedServiceSnapshot (Get-FxManagedServiceSnapshot) before
        Assert-FxValidationDrivers $plan.driverPolicy (Get-FxValidationDriverSnapshot) before
        foreach($pin in $plan.protectedFiles){Assert-RnPin $pin}
        Write-UvMarker 'isolation.armed.json' 'nll/native-fx-user-validation-armed/v1' @{
            allProgramsBlocked=$true;rollbackPrepared=$true;systemChangesVerified=$true;managedServiceBaselineVerified=$true;
            managedDriverBaselineVerified=$true;protectedInputsUnchanged=$true}
        $stage='child_start'
        Set-UvStage 'bootstrap_check'
        $child=$job.Start((Join-Path $plan.childRoot 'NikkeLocalLab.NativeFxUserValidationChild.exe'),
            ('--user-start '+$plan.trialUid+' '+$plan.assessmentUid+' '+$entry.parentPlan.sha256+' '+$entry.bootstrapPlan.sha256+' '+$entry.stagingReceipt.sha256))
        $ready=$false;$watch=[Diagnostics.Stopwatch]::StartNew();$checkWatch=[Diagnostics.Stopwatch]::StartNew()
        while(-not $child.HasExited -and $watch.Elapsed.TotalSeconds -lt ($plan.durationSeconds+300)){
            $stage='observing'
            $scoped=Get-UvScoped $plan.jobName
            foreach($p in $scoped){
                if($p.ExecutablePath -ieq $plan.serviceImage.path){
                    Assert-FxManagedServiceEntry (Get-FxManagedServiceSnapshot) $p ([Nll.Fx.ProcessIdentity]::Read([int]$p.ParentProcessId))
                }else{Assert-Rn ($p.ExecutablePath -in $plan.programs.path -and $p.JobMember) 'uv_process_outside_boundary'}
            }
            if($script:UvTrace.stage -ceq 'bootstrap_check'){
                $proofs=@(Get-ChildItem -LiteralPath $run -File -Filter 'bootstrap-preflight-*.json')
                Assert-Rn ($proofs.Count -le 1) 'uv_bootstrap_preflight_duplicate'
                if($proofs.Count -eq 1){
                    Assert-RnPath $proofs[0].FullName
                    Assert-Rn ($proofs[0].Length -le 16384) 'uv_bootstrap_preflight_invalid'
                    $proof=Get-Content -LiteralPath $proofs[0].FullName -Raw|ConvertFrom-Json
                    Assert-Rn ($proof.contractId -ceq 'nll/user-validation-process-preflight/v1' -and
                        $proof.parentPlanSha256 -ceq $entry.parentPlan.sha256 -and -not $proof.actualGameAcceptanceClaimed) 'uv_bootstrap_preflight_invalid'
                    Assert-Rn ($proof.statusCode -ceq 'verified') 'uv_bootstrap_preflight_failed'
                    Set-UvStage 'game_start'
                }
            }
            if($script:UvTrace.stage -ceq 'game_start' -and @($scoped|Where-Object {$_.ExecutablePath -ieq (Join-Path $plan.clientRoot 'NIKKE\game\nikke.exe') -and $_.JobMember}).Count -eq 1){Set-UvStage 'running'}
            $ids=@($scoped|ForEach-Object ProcessId)
            $connections=@(Get-NetTCPConnection -ErrorAction Stop|Where-Object OwningProcess -in $ids)
            Assert-Rn (@($connections|Where-Object {$_.State -eq 'Established' -and $_.RemoteAddress -notin '127.0.0.1','::1'}).Count -eq 0) 'uv_nonloopback_connection'
            Assert-Rn (@($connections|Where-Object {$_.State -eq 'Listen' -and $_.LocalAddress -cne '127.0.0.1'}).Count -eq 0) 'uv_nonloopback_listener'
            if($checkWatch.Elapsed.TotalSeconds -ge 3){
                Assert-UvFirewall;Assert-UvSystemApplied
                Assert-FxValidationDrivers $plan.driverPolicy (Get-FxValidationDriverSnapshot) runtime
                $checkWatch.Restart()
            }
            $identityPath=Join-Path $run 'server-identity.private.json'
            if(-not $ready -and (Test-Path -LiteralPath $identityPath)){
                $identity=Get-Content -LiteralPath $identityPath -Raw|ConvertFrom-Json
                $actual=[Nll.Fx.ProcessIdentity]::Read([int]$identity.processId,$plan.jobName)
                Assert-Rn ($null -ne $actual -and $actual.JobMember -and $actual.CreatedFileTime -eq $identity.createdFileTime -and
                    $actual.ImagePath -ceq (Join-Path $plan.serverRoot 'EpinelPS.exe') -and $identity.jobName -ceq $plan.jobName) 'uv_server_identity_invalid'
                $listeners=@($connections|Where-Object {$_.OwningProcess -eq $identity.processId -and $_.State -eq 'Listen'})
                if(@($listeners|Where-Object LocalPort -eq 443).Count -eq 1 -and @($listeners|Where-Object LocalPort -eq 80).Count -eq 1){
                    Assert-Rn ($listeners.Count -eq 2) 'uv_server_listener_set'
                    Assert-UvFirewall;Assert-UvSystemApplied
                    Write-UvMarker 'isolation.ready.json' 'nll/native-fx-user-validation-isolation/v1' @{
                        nativeStoreSha256=$bootstrap.nativeStore.sha256;caseCode=$plan.caseCode;driverPolicyCode=$plan.driverPolicy.contractId;
                        driverAuthorizationId=$plan.driverPolicy.authorizationId;allProgramsBlocked=$true;rollbackPrepared=$true;
                        systemChangesVerified=$true;managedServiceBaselineVerified=$true;managedDriverBaselineVerified=$true;
                        preparedAccountVerified=$true;independentServerVerified=$true;protectedInputsUnchanged=$true}
                    Write-UvMarker 'server.ready.json' 'nll/native-fx-user-validation-server-ready/v1' @{
                        processId=$identity.processId;createdFileTime=$identity.createdFileTime;loopbackListenersVerified=$true}
                    $ready=$true
                }
            }
            if(-not $ready -and $watch.Elapsed.TotalSeconds -gt 240){throw 'uv_server_ready_timeout'}
            Start-Sleep -Milliseconds 250
        }
        Assert-Rn ($child.HasExited -and $child.ExitCode -eq 0 -and $ready) 'uv_child_failed_or_timed_out'
        $stage='user_execution_ended'
    }
}catch{
    $failure='uv_execution_failed'
    if($_.Exception.Message -cmatch '^(uv_|resource_native_)[a-z_]+$'){$failure=$_.Exception.Message}
}finally{
    if($claimed){
        # Diagnostics must never prevent mandatory recovery after ownership.
        try{Set-UvStage 'cleanup'}catch{Write-Warning 'uv_progress_write_failed'}
        try{
            $cleanup=Invoke-UvCleanup $plan.driverPolicy -StopJob {
                if($null -eq $job){
                    $ownedPath=Join-Path $run 'job-owned.json'
                    if($Mode -ceq 'Recover' -and (Test-Path -LiteralPath $ownedPath)){
                      Assert-RnPath $ownedPath
                      Assert-Rn ((Get-Item -LiteralPath $ownedPath).Length -le 65536) 'uv_job_owner_invalid'
                      $owned=Get-Content -LiteralPath $ownedPath -Raw|ConvertFrom-Json
                      Assert-Rn ($owned.entrySha256 -ceq $EntrySha256 -and $owned.jobName -ceq $plan.jobName -and $owned.createdBeforeLaunch -eq $true) 'uv_job_owner_invalid'
                      try{$script:job=[Nll.PhaseD.ExecutionJob]::Open($plan.jobName)}catch{
                        $errorValue=$_.Exception;while($errorValue.InnerException){$errorValue=$errorValue.InnerException}
                        Assert-Rn ($errorValue -is [ComponentModel.Win32Exception] -and $errorValue.NativeErrorCode -eq 2) 'uv_job_query_failed'
                        # Absent Job is acceptable only with no remaining game/server/child.
                        Assert-Rn (@((Get-UvScoped)|Where-Object ExecutablePath -ne $plan.serviceImage.path).Count -eq 0) 'uv_absent_job_scope_alive'
                      }
                    }else{
                        # A failed Create must NEVER authorize opening/killing a
                        # colliding Job which this invocation did not create.
                        Assert-Rn ((Get-UvScoped).Count -eq 0) 'uv_unowned_job_scope_alive'
                    }
                }
                if($null -ne $job){$job.TerminateAndWait(10000);Assert-Rn ($job.ActiveProcesses -eq 0) 'uv_job_not_zero'}
                $true
            } -VerifyScopeCold { (Get-UvScoped).Count -eq 0 } -RestoreInputs {
                try{
                    Assert-Rn ((Get-UvScoped).Count -eq 0) 'uv_restore_scope_alive'
                    $null=Invoke-UvMeasuredStore 'restore' $true
                    Restore-UvClientFiles $plan
                }finally{
                    # A damaged client must not prevent independent safe system
                    # restoration. Any failure still prevents isolation release.
                    Assert-Rn ((Get-UvScoped).Count -eq 0) 'uv_restore_scope_alive'
                    try{Restore-UvHosts $plan.hostsChange;Clear-DnsClientCache}
                    finally{Restore-UvVoicePreferences $plan.preferencesBefore $plan.preferencesAfter}
                }
                foreach($pin in $plan.protectedFiles){Assert-RnPin $pin}
                $true
            } -ReleaseIsolation {
                foreach($rule in @(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue)){
                    Assert-Rn ($rule.Name -clike ('NLL-UserValidation-'+$plan.assessmentUid+'-*')) 'uv_rule_not_owned'
                    Remove-NetFirewallRule -InputObject $rule -ErrorAction Stop
                }
                Assert-Rn (@(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count -eq 0) 'uv_isolation_not_released'
                $true
            }
            Write-RnNewJson (Join-Path $run 'cleanup.receipt.json') $cleanup
        }catch{$cleanupFailure='uv_cleanup_unproven';if($_.Exception.Message -cmatch '^(uv_|resource_native_)[a-z_]+$'){$cleanupFailure=$_.Exception.Message}}
        Write-RnNewJson (Join-Path $run ('execution-'+[guid]::NewGuid().ToString('N')+'.receipt.json')) ([ordered]@{
            contractId='nll/user-validation-execution/v1';assessmentUid=$plan.assessmentUid;entrySha256=$EntrySha256;mode=$Mode;
            lastStage=$stage;failureCode=$failure;cleanupFailureCode=$cleanupFailure;cleanupVerified=($null -ne $cleanup -and $null -eq $cleanupFailure);
            nativeAdmission='not_assessed';actualGameAcceptanceClaimed=$false})
    }
    if($null -ne $child){$child.Dispose()};if($null -ne $job){$job.Dispose()}
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
    try{Set-UvStage $(if($failure -or $cleanupFailure){'failed'}else{'complete'})}catch{Write-Warning 'uv_progress_write_failed'}
}
if($failure){throw $failure};if($cleanupFailure){throw $cleanupFailure}
