# Exact, operator-approved SCM lifecycle; importing this file has no OS side effects.
Set-StrictMode -Version Latest

function Merge-FxManagedProgramPins {
    param([object[]]$Pins)
    $unique=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($pin in $Pins){
        if($unique.ContainsKey($pin.path)){
            $existing=$unique[$pin.path]
            Assert-Rn ($existing.sha256 -ceq $pin.sha256 -and $existing.length -eq $pin.length) 'fx_managed_duplicate_pin_conflict'
        }else{$unique.Add($pin.path,$pin)}
    }
    # OrderedDictionary pins need an explicit expression; Sort-Object path can collapse them.
    return ,@($unique.Values | Sort-Object { $_.path })
}

function Get-FxManagedServiceSnapshot {
    $items = @(Get-CimInstance Win32_Service -Filter "Name='AntiCheatExpert Protection'")
    Assert-Rn ($items.Count -eq 1) 'fx_managed_service_ambiguous'
    $item = $items[0]
    [pscustomobject]@{
        name=$item.Name; pathName=$item.PathName; startName=$item.StartName
        startMode=$item.StartMode; state=$item.State; processId=[int]$item.ProcessId
        serviceType=$item.ServiceType; acceptStop=[bool]$item.AcceptStop
    }
}

function Assert-FxManagedServiceSnapshot {
    param($Snapshot, [ValidateSet('before','runtime','cleanup','restored')][string]$Phase)
    Assert-Rn ($Snapshot.name -ceq 'AntiCheatExpert Protection' -and
        $Snapshot.pathName -ceq '"C:\Program Files\AntiCheatExpert\ACE-Service64.exe"  -autorun' -and
        $Snapshot.startName -ceq 'LocalSystem' -and $Snapshot.serviceType -ceq 'Own Process') 'fx_managed_service_identity_drift'
    $modes = if ($Phase -ceq 'cleanup') { @('Manual','Disabled') } else { @('Manual') }
    Assert-Rn ($Snapshot.startMode -cin $modes) 'fx_managed_service_mode_drift'
    Assert-Rn ($Snapshot.state -cin @('Stopped','Start Pending','Running','Stop Pending')) 'fx_managed_service_state_invalid'
    Assert-Rn ($Snapshot.processId -ge 0 -and
        ($Snapshot.state -cne 'Stopped' -or $Snapshot.processId -eq 0) -and
        ($Snapshot.state -cne 'Running' -or $Snapshot.processId -gt 0)) 'fx_managed_service_pid_invalid'
    if ($Phase -cin @('before','restored')) {
        Assert-Rn ($Snapshot.state -ceq 'Stopped' -and $Snapshot.processId -eq 0) 'fx_managed_service_not_cold'
    }
}

function Assert-FxManagedServiceEntry {
    param($Snapshot, $Entry, $ParentIdentity)
    Assert-FxManagedServiceSnapshot $Snapshot runtime
    Assert-Rn ($Snapshot.processId -gt 0 -and $Entry.ProcessId -eq $Snapshot.processId -and
        $Entry.ExecutablePath -ieq 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe' -and
        -not $Entry.JobMember -and $null -ne $ParentIdentity -and
        $ParentIdentity.ImagePath -ieq 'C:\Windows\System32\services.exe' -and
        $ParentIdentity.CreatedFileTime -lt $Entry.CreationDate.ToFileTimeUtc()) 'fx_managed_service_process_unbound'
}

function Assert-FxManagedServiceNoDependents {
    $controller = [System.ServiceProcess.ServiceController]::new('AntiCheatExpert Protection','.')
    try {
        $dependents = @($controller.DependentServices)
        try { Assert-Rn ($dependents.Count -eq 0) 'fx_managed_service_dependents_changed' }
        finally { foreach ($dependent in $dependents) { $dependent.Dispose() } }
    } finally { $controller.Dispose() }
}

function Request-FxManagedServiceStop {
    # Stop(false) never stops dependent services; no process kill or security mutation.
    Assert-FxManagedServiceNoDependents
    $controller = [System.ServiceProcess.ServiceController]::new('AntiCheatExpert Protection','.')
    try {
        $controller.Refresh()
        if ($controller.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped -or
            $controller.Status -eq [System.ServiceProcess.ServiceControllerStatus]::StopPending) { return }
        Assert-Rn $controller.CanStop 'fx_managed_service_stop_not_accepted'
        $controller.Stop($false)
    } finally { $controller.Dispose() }
}

function Stop-FxManagedService {
    param([bool]$JobZeroVerified=$false)
    Assert-Rn $JobZeroVerified 'fx_managed_service_stop_without_job_zero'
    $snapshot = Get-FxManagedServiceSnapshot
    Assert-FxManagedServiceSnapshot $snapshot cleanup
    Assert-FxManagedServiceNoDependents
    if ($snapshot.startMode -cne 'Disabled') {
        Set-Service -Name 'AntiCheatExpert Protection' -StartupType Disabled -ErrorAction Stop
    }
    # Capture partial mutation before any stop error; the caller retains isolation on failure.
    $snapshot = Get-FxManagedServiceSnapshot
    Assert-FxManagedServiceSnapshot $snapshot cleanup
    Assert-Rn ($snapshot.startMode -ceq 'Disabled') 'fx_managed_service_disable_failed'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $requested = $false
    do {
        $snapshot = Get-FxManagedServiceSnapshot
        Assert-FxManagedServiceSnapshot $snapshot cleanup
        Assert-Rn ($snapshot.startMode -ceq 'Disabled') 'fx_managed_service_cleanup_drift'
        if ($snapshot.state -ceq 'Stopped' -and $snapshot.processId -eq 0) { return $snapshot }
        if (-not $requested -and $snapshot.state -ceq 'Running') {
            Request-FxManagedServiceStop
            $requested = $true
        }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt 20)
    throw 'fx_managed_service_stop_timeout'
}

function Restore-FxManagedService {
    param([bool]$ScopeZeroVerified=$false)
    Assert-Rn $ScopeZeroVerified 'fx_managed_service_restore_without_scope_zero'
    $snapshot = Get-FxManagedServiceSnapshot
    Assert-FxManagedServiceSnapshot $snapshot cleanup
    Assert-Rn ($snapshot.state -ceq 'Stopped' -and $snapshot.processId -eq 0) 'fx_managed_service_restore_while_running'
    if ($snapshot.startMode -cne 'Manual') {
        Set-Service -Name 'AntiCheatExpert Protection' -StartupType Manual -ErrorAction Stop
    }
    $snapshot = Get-FxManagedServiceSnapshot
    Assert-FxManagedServiceSnapshot $snapshot restored
    return $snapshot
}

function Get-FxManagedDriverSnapshot {
    $drivers = @(Get-CimInstance Win32_SystemDriver | Where-Object {
        $_.Name -match '^ACE|AntiCheat' -or $_.PathName -match 'AntiCheatExpert'
    } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{name=$_.Name;pathName=$_.PathName;state=$_.State;startMode=$_.StartMode}
    })
    return ,$drivers
}

function Assert-FxManagedDriverBaseline {
    param($Before)
    $current = Get-FxManagedDriverSnapshot
    Assert-Rn (($current | ConvertTo-Json -Compress) -ceq ($Before | ConvertTo-Json -Compress)) 'fx_managed_driver_state_drift'
}
