# Opt-in policy for USER-launched isolated validation only. Import is inert.
# The historical read-only driver-baseline guard remains unchanged.
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
. (Join-Path $PSScriptRoot 'Nll.NativeFxManagedService.ps1')

function Assert-FxValidationDriverRows($Rows, [bool]$Baseline) {
    $items = @($Rows)
    Assert-Rn ($items.Count -eq 2 -and $items[0].name -ceq 'ACE-ADVT' -and
        $items[1].name -ceq 'ACE-BASE') 'fx_validation_driver_set_changed'
    $hashes = @('0986239726d91e276881dfb24e78498b77073b80f56fb8c34afe53621d14649b',
        'b97d3998020bba5c51c71c288088eed6efeb261af6d2266d381c7754a75fa6da')
    for ($index = 0; $index -lt 2; $index++) {
        $row = $items[$index]
        $names = if ($row -is [Collections.IDictionary]) { @($row.Keys) } else { @($row.PSObject.Properties.Name) }
        Assert-Rn ($names.Count -eq 7 -and @($names | Where-Object {
            $_ -cnotin @('name','pathName','state','startMode','serviceType','sha256','byteLength')
        }).Count -eq 0) 'fx_validation_driver_shape_invalid'
        Assert-Rn ($row.pathName -ieq ('\??\C:\Windows\system32\drivers\' + $row.name + '.sys') -and
            $row.startMode -ceq 'Manual' -and $row.serviceType -ceq 'Kernel Driver' -and
            $row.sha256 -ceq $hashes[$index] -and
            ($row.byteLength -is [int] -or $row.byteLength -is [long]) -and
            $row.byteLength -gt 0 -and $row.byteLength -le 67108864) 'fx_validation_driver_identity_drift'
        # BASE is observed and preserved, never started/stopped by this policy.
        # A reboot can legitimately leave this Manual driver stopped.
        $states = if ($index -eq 1) { @('Stopped','Running') } elseif ($Baseline) { @('Stopped') }
            else { @('Stopped','Start Pending','Running','Stop Pending') }
        Assert-Rn ($row.state -cin $states) 'fx_validation_driver_state_invalid'
    }
}

function Get-FxValidationDriverSnapshot {
    # No arbitrary path from SCM is opened. Unexpected names/paths fail first.
    $items = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop | Where-Object {
        $_.Name -match '^ACE|AntiCheat' -or $_.PathName -match 'AntiCheatExpert'
    } | Sort-Object Name)
    Assert-Rn ($items.Count -eq 2 -and $items[0].Name -ceq 'ACE-ADVT' -and
        $items[1].Name -ceq 'ACE-BASE') 'fx_validation_driver_set_changed'
    $rows = foreach ($item in $items) {
        $path = 'C:\Windows\System32\drivers\' + $item.Name + '.sys'
        Assert-Rn ($item.PathName -ieq ('\??\' + $path)) 'fx_validation_driver_identity_drift'
        $pin = Get-RnPin $path
        [pscustomobject]@{ name=$item.Name; pathName=$item.PathName; state=$item.State;
            startMode=$item.StartMode; serviceType=$item.ServiceType;
            sha256=$pin.sha256; byteLength=[long]$pin.length }
    }
    Assert-FxValidationDriverRows $rows $false
    return ,@($rows)
}

function New-FxValidationDriverPolicy($Before) {
    Assert-FxValidationDriverRows $Before $true
    # Copy values; the caller must seal this data inside its per-run plan.
    $copy = ($Before | ConvertTo-Json -Depth 8) | ConvertFrom-Json
    [pscustomobject]@{ contractId='nll/user-validation-ace-advt/v1';
        authorizationId='operator-2026-09-13-user-launched-ace-advt/v1';
        executionOwnerCode='user'; baseline=@($copy) }
}

function Assert-FxValidationDriverPolicy($Policy) {
    Assert-Rn ($null -ne $Policy) 'fx_validation_driver_authorization_missing'
    $names = if ($Policy -is [Collections.IDictionary]) { @($Policy.Keys) } else { @($Policy.PSObject.Properties.Name) }
    Assert-Rn ($names.Count -eq 4 -and @($names | Where-Object {
        $_ -cnotin @('contractId','authorizationId','executionOwnerCode','baseline')
    }).Count -eq 0 -and $Policy.contractId -ceq 'nll/user-validation-ace-advt/v1' -and
        $Policy.authorizationId -ceq 'operator-2026-09-13-user-launched-ace-advt/v1' -and
        $Policy.executionOwnerCode -ceq 'user') 'fx_validation_driver_authorization_invalid'
    Assert-FxValidationDriverRows $Policy.baseline $true
}

function Assert-FxValidationDrivers($Policy, $Current,
    [ValidateSet('before','runtime','cleanup','restored')][string]$Phase) {
    Assert-FxValidationDriverPolicy $Policy
    Assert-FxValidationDriverRows $Current ($Phase -cin @('before','restored'))
    for ($index = 0; $index -lt 2; $index++) {
        foreach ($field in @('name','pathName','startMode','serviceType','sha256','byteLength')) {
            Assert-Rn ($Current[$index].$field -ceq $Policy.baseline[$index].$field) 'fx_validation_driver_baseline_drift'
        }
        if ($index -eq 1 -or $Phase -cin @('before','restored')) {
            Assert-Rn ($Current[$index].state -ceq $Policy.baseline[$index].state) 'fx_validation_driver_baseline_drift'
        }
    }
}

function Assert-FxValidationServiceCold {
    $snapshot = Get-FxManagedServiceSnapshot
    Assert-FxManagedServiceSnapshot $snapshot cleanup
    Assert-Rn ($snapshot.state -ceq 'Stopped' -and $snapshot.processId -eq 0) 'fx_validation_service_not_cold'
}

function New-FxValidationDriverController {
    Add-Type -AssemblyName System.ServiceProcess
    [System.ServiceProcess.ServiceController]::new('ACE-ADVT','.')
}

function Request-FxValidationDriverStop {
    # SCM normal stop of this driver ONLY. Never Stop(true), Start, force unload,
    # Set-Service, ACL/config mutation or a fallback to ACE-BASE.
    $controller = New-FxValidationDriverController
    try {
        $controller.Refresh()
        $dependents = @($controller.DependentServices)
        try { Assert-Rn ($dependents.Count -eq 0) 'fx_validation_driver_dependents_changed' }
        finally { foreach ($dependent in $dependents) { $dependent.Dispose() } }
        if ($controller.Status.ToString() -cin @('Stopped','StopPending')) { return }
        Assert-Rn $controller.CanStop 'fx_validation_driver_stop_not_accepted'
        try { $controller.Stop($false) }
        catch { throw 'resource_native_fx_validation_driver_stop_failed' }
    } finally { $controller.Dispose() }
}

function Wait-FxValidationDriverPoll { Start-Sleep -Milliseconds 100 }

function Restore-FxValidationDriver {
    param($Policy, [bool]$JobZeroVerified=$false, [bool]$ServiceZeroVerified=$false,
        [bool]$ScopeZeroVerified=$false, [ValidateRange(1,60)][int]$TimeoutSeconds=20)
    Assert-FxValidationDriverPolicy $Policy
    Assert-Rn ($JobZeroVerified -and $ServiceZeroVerified -and $ScopeZeroVerified) 'fx_validation_driver_stop_without_scope_zero'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $requested = $false
    do {
        Assert-FxValidationServiceCold
        $current = Get-FxValidationDriverSnapshot
        Assert-FxValidationDrivers $Policy $current cleanup
        if ($current[0].state -ceq 'Stopped') {
            Assert-FxValidationDrivers $Policy $current restored
            return [pscustomobject]@{ contractId='nll/user-validation-ace-advt-restore/v1';
                statusCode='driver_baseline_restored'; normalStopRequested=$requested;
                driverBaselineRestored=$true; isolationReleasePerformed=$false }
        }
        if (-not $requested -and $current[0].state -ceq 'Running') {
            Request-FxValidationDriverStop
            $requested = $true
        }
        Wait-FxValidationDriverPoll
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    # Caller preserves isolation and the original failure on this exception.
    throw 'resource_native_fx_validation_driver_stop_timeout'
}

function Complete-FxValidationManagedScope {
    # Controller-owned callbacks, never executable text deserialized from a plan.
    # The caller first stops its exact Job and independently proves ActiveProcesses=0.
    # Throwing preserves the caller's original failure and unreleased isolation.
    param(
        [Parameter(Mandatory)]$Policy,
        [bool]$JobZeroVerified=$false,
        [Parameter(Mandatory)][scriptblock]$VerifyScopeCold,
        [Parameter(Mandatory)][scriptblock]$RestoreOwnedInputs,
        [Parameter(Mandatory)][scriptblock]$ReleaseIsolation
    )
    Assert-FxValidationDriverPolicy $Policy
    Assert-Rn $JobZeroVerified 'fx_validation_cleanup_without_job_zero'
    $stopped = Stop-FxManagedService -JobZeroVerified $JobZeroVerified
    Assert-FxManagedServiceSnapshot $stopped cleanup
    Assert-Rn ($stopped.state -ceq 'Stopped' -and $stopped.processId -eq 0) 'fx_validation_service_not_cold'
    $cold = @(& $VerifyScopeCold)
    Assert-Rn ($cold.Count -eq 1 -and $cold[0] -is [bool] -and $cold[0]) 'fx_validation_scope_not_cold'
    # Restore the shared service setting even if later driver restoration fails.
    # Driver failure must not silently leave Manual -> Disabled applied.
    $restored = Restore-FxManagedService -ScopeZeroVerified $true
    Assert-FxManagedServiceSnapshot $restored restored
    $cold = @(& $VerifyScopeCold)
    Assert-Rn ($cold.Count -eq 1 -and $cold[0] -is [bool] -and $cold[0]) 'fx_validation_scope_not_cold'
    $inputs = @(& $RestoreOwnedInputs)
    Assert-Rn ($inputs.Count -eq 1 -and $inputs[0] -is [bool] -and $inputs[0]) 'fx_validation_inputs_restore_unproven'
    $driver = Restore-FxValidationDriver -Policy $Policy -JobZeroVerified $true -ServiceZeroVerified $true -ScopeZeroVerified $true
    Assert-Rn $driver.driverBaselineRestored 'fx_validation_driver_restore_unproven'
    Assert-FxValidationServiceCold
    $cold = @(& $VerifyScopeCold)
    Assert-Rn ($cold.Count -eq 1 -and $cold[0] -is [bool] -and $cold[0]) 'fx_validation_scope_not_cold'
    Assert-FxValidationDrivers $Policy (Get-FxValidationDriverSnapshot) restored
    $released = @(& $ReleaseIsolation)
    Assert-Rn ($released.Count -eq 1 -and $released[0] -is [bool] -and $released[0]) 'fx_validation_isolation_release_unproven'
    [pscustomobject]@{ contractId='nll/user-validation-managed-scope-cleanup/v1';
        jobZeroVerified=$true; serviceZeroVerified=$true; scopeZeroVerified=$true;
        serviceStartModeRestored=$true; driverBaselineRestored=$true; ownedInputsRestored=$true;
        isolationReleased=$true; nativeAdmission='not_assessed'; actualGameAcceptanceClaimed=$false }
}
