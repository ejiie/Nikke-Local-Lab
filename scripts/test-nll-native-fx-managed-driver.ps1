$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.NativeFxManagedDriver.ps1')
$script:checks = 0; $script:stops = 0; $script:disposals = 0
$script:serviceCold = $true; $script:failStop = $false; $script:keepRunning = $false
function Check([bool]$Value) { if (-not $Value) { throw ('driver_assertion_' + ($script:checks + 1)) }; $script:checks++ }
function Reject([scriptblock]$Action, [string]$Code) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Check ($failure -ceq ('resource_native_fx_validation_' + $Code))
}
$script:drivers = @(
    [pscustomobject]@{ name='ACE-ADVT'; pathName='\??\C:\Windows\system32\drivers\ACE-ADVT.sys';
        state='Stopped'; startMode='Manual'; serviceType='Kernel Driver'; byteLength=100;
        sha256='0986239726d91e276881dfb24e78498b77073b80f56fb8c34afe53621d14649b' },
    [pscustomobject]@{ name='ACE-BASE'; pathName='\??\C:\Windows\system32\drivers\ACE-BASE.sys';
        state='Running'; startMode='Manual'; serviceType='Kernel Driver'; byteLength=200;
        sha256='b97d3998020bba5c51c71c288088eed6efeb261af6d2266d381c7754a75fa6da' }
)
function Get-FxValidationDriverSnapshot { return ,@($script:drivers | ForEach-Object { $_.PSObject.Copy() }) }
function Get-FxManagedServiceSnapshot {
    [pscustomobject]@{name='AntiCheatExpert Protection';pathName='"C:\Program Files\AntiCheatExpert\ACE-Service64.exe"  -autorun';
        startName='LocalSystem';startMode='Manual';serviceType='Own Process';
        state=$(if ($script:serviceCold) {'Stopped'} else {'Running'});
        processId=$(if ($script:serviceCold) {0} else {12345})}
}
$script:controller = [pscustomobject]@{ Status='Running'; CanStop=$true; DependentServices=@() }
$controller | Add-Member ScriptMethod Refresh {}
$controller | Add-Member ScriptMethod Dispose { $script:disposals++ }
$controller | Add-Member ScriptMethod Stop {
    param([bool]$StopDependents)
    Check (-not $StopDependents)
    $script:stops++
    if ($script:failStop) { throw 'synthetic_scm_denial' }
    if (-not $script:keepRunning) { $script:drivers[0].state = 'Stopped' }
}
function New-FxValidationDriverController { return $script:controller }
function Wait-FxValidationDriverPoll { Start-Sleep -Milliseconds 1 }

$policy = New-FxValidationDriverPolicy (Get-FxValidationDriverSnapshot)
Assert-FxValidationDrivers $policy (Get-FxValidationDriverSnapshot) before
Check ($stops -eq 0)
$drivers[0].state = 'Running'
Check ($policy.baseline[0].state -ceq 'Stopped')
Assert-FxValidationDrivers $policy (Get-FxValidationDriverSnapshot) runtime
Check $true
Reject { Assert-FxValidationDrivers $policy (Get-FxValidationDriverSnapshot) restored } 'driver_state_invalid'
Reject { Restore-FxValidationDriver $null $true $true $true } 'driver_authorization_missing'
foreach ($flag in 0..2) {
    $flags = @($true,$true,$true); $flags[$flag] = $false
    Reject { Restore-FxValidationDriver $policy $flags[0] $flags[1] $flags[2] } 'driver_stop_without_scope_zero'
}
Check ($stops -eq 0)
$serviceCold = $false
Reject { Restore-FxValidationDriver $policy $true $true $true } 'service_not_cold'
$serviceCold = $true
foreach ($index in 0..1) {
    foreach ($field in @('pathName','startMode','serviceType','sha256')) {
        $prior = $drivers[$index].$field; $drivers[$index].$field = 'wrong'
        Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_identity_drift'
        $drivers[$index].$field = $prior
    }
    $drivers[$index].byteLength++
    Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_baseline_drift'
    $drivers[$index].byteLength--
}
$drivers[1].state = 'Stopped'
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_state_invalid'
$drivers[1].state = 'Running'
$drivers[0].state = 'Paused'
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_state_invalid'
$drivers[0].state = 'Running'
$originalDrivers = $drivers; $drivers = @($drivers[0])
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_set_changed'
$drivers = @($originalDrivers) + @($originalDrivers[0])
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_set_changed'
$drivers = $originalDrivers
Check ($stops -eq 0)

$policy.executionOwnerCode = 'agent'
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_authorization_invalid'
$policy.executionOwnerCode = 'user'
$policy.authorizationId = 'old-one-time-restoration'
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_authorization_invalid'
$policy.authorizationId = 'operator-2026-09-13-user-launched-ace-advt/v1'

$dependent = [pscustomobject]@{ disposed=$false }
$dependent | Add-Member ScriptMethod Dispose { $this.disposed = $true }
$controller.DependentServices = @($dependent)
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_dependents_changed'
Check ($dependent.disposed -and $stops -eq 0 -and $disposals -eq 1)
$controller.DependentServices = @(); $controller.CanStop = $false
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_stop_not_accepted'
Check ($stops -eq 0 -and $disposals -eq 2)
$controller.CanStop = $true; $failStop = $true
Reject { Restore-FxValidationDriver $policy $true $true $true } 'driver_stop_failed'
Check ($drivers[0].state -ceq 'Running' -and $disposals -eq 3)
$failStop = $false; $keepRunning = $true
Reject { Restore-FxValidationDriver $policy $true $true $true -TimeoutSeconds 1 } 'driver_stop_timeout'
Check ($drivers[0].state -ceq 'Running' -and $disposals -eq 4)
$keepRunning = $false
$receipt = Restore-FxValidationDriver $policy $true $true $true
Check ($receipt.driverBaselineRestored -and $receipt.normalStopRequested -and -not $receipt.isolationReleasePerformed)
Check ($drivers[0].state -ceq 'Stopped' -and $drivers[1].state -ceq 'Running')
$priorStops = $stops
$receipt = Restore-FxValidationDriver $policy $true $true $true
Check ($receipt.driverBaselineRestored -and -not $receipt.normalStopRequested -and $stops -eq $priorStops)
foreach ($state in @('Start Pending','Stop Pending')) {
    $drivers[0].state = $state
    Assert-FxValidationDrivers $policy (Get-FxValidationDriverSnapshot) runtime
    Check $true
}
# Historical callers still reject any driver transition, even though the new
# explicitly authorized policy admits this one driver's transition.
function Get-FxManagedDriverSnapshot { return ,@($script:drivers) }
try { Assert-FxManagedDriverBaseline $policy.baseline; throw 'historical_guard_weakened' }
catch { Check ($_.Exception.Message -ceq 'resource_native_fx_managed_driver_state_drift') }
# Full managed cleanup order: the callbacks are test-owned and all SCM/driver
# operations remain the fakes above. No real firewall/file/process operations.
$script:events = [Collections.Generic.List[string]]::new()
$script:cleanupCase = 'success'; $script:scopeChecks = 0
function Stop-FxManagedService {
    param([bool]$JobZeroVerified)
    Check $JobZeroVerified
    $script:events.Add('service-stop')
    if ($script:cleanupCase -ceq 'service-stop') { throw 'resource_native_fx_validation_synthetic_stop_failed' }
    Get-FxManagedServiceSnapshot
}
function Restore-FxManagedService {
    param([bool]$ScopeZeroVerified)
    Check $ScopeZeroVerified
    $script:events.Add('service-manual')
    Get-FxManagedServiceSnapshot
}
$verifyCold = {
    $script:events.Add('scope'); $script:scopeChecks++
    if ($script:cleanupCase -ceq 'scope-string') { return 'true' }
    if ($script:cleanupCase -ceq 'scope' -or ($script:cleanupCase -ceq 'final-scope' -and $script:scopeChecks -eq 3)) { return $false }
    return $true
}
$restoreInputs = {
    $script:events.Add('inputs')
    if ($script:cleanupCase -ceq 'inputs') { return $false }
    if ($script:cleanupCase -ceq 'inputs-throw') { throw 'resource_native_fx_validation_synthetic_inputs_failed' }
    if ($script:cleanupCase -ceq 'driver-stop') { $script:failStop = $true }
    return $true
}
$release = { $script:events.Add('release'); return ($script:cleanupCase -cne 'release') }
$drivers[0].state = 'Running'
Reject { Complete-FxValidationManagedScope $policy $false $verifyCold $restoreInputs $release } 'cleanup_without_job_zero'
Check ($events.Count -eq 0)
foreach ($case in @('service-stop','scope','scope-string','inputs','inputs-throw','driver-stop','final-scope','release','success')) {
    $cleanupCase = $case; $scopeChecks = 0; $events.Clear(); $failStop = $false; $drivers[0].state = 'Running'
    $result = $null; $errorCode = $null
    try { $result = Complete-FxValidationManagedScope $policy $true $verifyCold $restoreInputs $release }
    catch { $errorCode = $_.Exception.Message }
    if ($case -ceq 'success') {
        Check ($null -eq $errorCode -and $result.isolationReleased -and $result.driverBaselineRestored -and
            $result.nativeAdmission -ceq 'not_assessed' -and -not $result.actualGameAcceptanceClaimed)
        Check (($events -join ',') -ceq 'service-stop,scope,service-manual,scope,inputs,scope,release')
    } else {
        Check ($null -eq $result -and $errorCode -cmatch '^resource_native_fx_validation_')
        Check (($events -contains 'release') -eq ($case -ceq 'release'))
        if ($case -ceq 'driver-stop') { Check ($events -contains 'service-manual' -and $drivers[0].state -ceq 'Running') }
        if ($case -cin @('service-stop','scope','scope-string')) { Check (-not ($events -contains 'inputs')) }
    }
    Check ($drivers[1].state -ceq 'Running')
}
[ordered]@{statusCode='passed'; assertions=$checks; syntheticOnly=$true;
    nativeClientExecuted=$false; realServiceCalls=0; realDriverChanges=0} | ConvertTo-Json
