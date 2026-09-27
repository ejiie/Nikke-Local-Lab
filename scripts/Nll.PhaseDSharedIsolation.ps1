# Shared official programs are blocked only while a local game owns them.
# Importing this helper never changes firewall/service state.
function Test-PhaseDSharedIsolationPath([string]$Path) {
    $Path.StartsWith('C:\NIKKE\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path -ieq 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe'
}

function Get-PhaseDIsolationRules {
    $rules = @(Get-NetFirewallRule -Group 'NLL PhaseD 151 Client Isolation' -ErrorAction Stop)
    $filters=@{}
    foreach ($filter in @(Get-NetFirewallApplicationFilter -PolicyStore PersistentStore -ErrorAction Stop)) {
        $filters[[string]$filter.InstanceID]=$filter
    }
    foreach ($rule in $rules) {
        $apps = @($filters[[string]$rule.InstanceID] | Where-Object { $null -ne $_ })
        if ($apps.Count -ne 1 -or $rule.Direction -ne 'Outbound' -or $rule.Action -ne 'Block' -or
            $rule.Name -cnotmatch '^NLL\.PhaseD151\.Program\.[0-9]+$') { throw 'phase_d_isolation_rule_invalid' }
        [pscustomobject]@{name=[string]$rule.Name; program=[string]$apps[0].Program; enabled=([string]$rule.Enabled -eq 'True')}
    }
}

function Write-PhaseDIsolationJson([string]$Path, [object]$Value) {
    $temp=$Path+'.partial-'+[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-PhaseDIsolationServices([string[]]$Programs) {
    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
        $match=[regex]::Match([string]$service.PathName, '^(?:"(?<exe>[^"]+\.exe)"|(?<exe>\S+\.exe))(?:\s|$)', 'IgnoreCase')
        if ($match.Success -and $Programs -icontains $match.Groups['exe'].Value) {
            [pscustomobject]@{name=[string]$service.Name; program=$match.Groups['exe'].Value
                state=[string]$service.State; startMode=[string]$service.StartMode}
        }
    }
}

function Assert-PhaseDIsolationProcessesCold([string[]]$Programs) {
    $names=@($Programs | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object -Unique)
    # Names also catch protected official processes whose path is unavailable.
    $running=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $names -icontains $_.Name -or $Programs -icontains $_.ExecutablePath
    })
    if ($running.Count) { throw 'phase_d_shared_isolation_process_running' }
}

function Enter-PhaseDSharedIsolation {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256, [object]$RuntimeBundle)
    if ($null -eq $RuntimeBundle) { return }
    $all=@(Get-PhaseDIsolationRules)
    $expected=@(@($RuntimeBundle.clientPrograms.path)+@($RuntimeBundle.blockOnlyPrograms) | Sort-Object -Unique)
    if ($all.Count -ne $expected.Count -or @(Compare-Object $expected @($all.program)).Count) {
        throw 'phase_d_isolation_inventory_changed'
    }
    if (@($all | Where-Object { -not (Test-PhaseDSharedIsolationPath $_.program) -and -not $_.enabled }).Count) {
        throw 'phase_d_client_isolation_missing'
    }
    $shared=@($all | Where-Object { Test-PhaseDSharedIsolationPath $_.program })
    $path=Join-Path $LaunchRoot 'shared-isolation.before.json'
    if (Test-Path -LiteralPath $path) { throw 'phase_d_shared_isolation_already_owned' }
    Assert-PhaseDIsolationProcessesCold $expected
    $services=@(Get-PhaseDIsolationServices @($shared.program))
    foreach ($service in $services) {
        if ($service.state -cne 'Stopped') { throw 'phase_d_shared_isolation_service_running' }
        $service | Add-Member -NotePropertyName sha256 -NotePropertyValue ((Get-FileHash -LiteralPath $service.program).Hash.ToLowerInvariant())
    }
    # Durable before-image precedes even the first enable. Partial application is recoverable.
    Write-PhaseDIsolationJson $path ([ordered]@{contractId='nll/phase-d-shared-isolation/v1'
        launchRoot=[IO.Path]::GetFullPath($LaunchRoot);runnerBundleSha256=$ExpectedBundleSha256
        rules=$shared;services=$services})
    $enable=@($shared | Where-Object { -not $_.enabled } | ForEach-Object { $_.name })
    if ($enable.Count) { Enable-NetFirewallRule -Name $enable -ErrorAction Stop | Out-Null }
    $after=@(Get-PhaseDIsolationRules)
    if (@($after | Where-Object { -not $_.enabled }).Count -or
        $after.Count -ne $expected.Count -or @(Compare-Object $expected @($after.program)).Count) {
        throw 'phase_d_shared_isolation_apply_failed'
    }
}

function Restore-PhaseDSharedIsolation {
    # Caller must retain the live same-Job zero proof until this function returns.
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    $path=Join-Path $LaunchRoot 'shared-isolation.before.json'
    if (-not (Test-Path -LiteralPath $path)) { return } # no acquisition / historical run
    $before=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($before.contractId -cne 'nll/phase-d-shared-isolation/v1' -or
        $before.launchRoot -cne [IO.Path]::GetFullPath($LaunchRoot) -or
        $before.runnerBundleSha256 -cne $ExpectedBundleSha256 -or
        @($before.rules).Count -eq 0 -or
        @($before.rules.name | Sort-Object -Unique).Count -ne @($before.rules).Count) {
        throw 'phase_d_shared_isolation_journal_invalid'
    }
    $current=@(Get-PhaseDIsolationRules)
    $shared=@($current | Where-Object { Test-PhaseDSharedIsolationPath $_.program })
    if ($shared.Count -ne @($before.rules).Count) { throw 'phase_d_shared_isolation_rule_changed' }
    foreach ($row in $before.rules) {
        if ($row.enabled -isnot [bool] -or -not (Test-PhaseDSharedIsolationPath $row.program) -or
            @($shared | Where-Object { $_.name -ceq $row.name -and $_.program -ieq $row.program }).Count -ne 1) {
            throw 'phase_d_shared_isolation_rule_changed'
        }
    }
    $restoredPath=Join-Path $LaunchRoot 'shared-isolation.restored.json'
    if (Test-Path -LiteralPath $restoredPath) {
        $restored=Get-Content -LiteralPath $restoredPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($restored.contractId -cne 'nll/phase-d-shared-isolation-restored/v1' -or
            $restored.runnerBundleSha256 -cne $ExpectedBundleSha256 -or $restored.restored -ne $true -or
            $restored.beforeSha256 -cne (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()) {
            throw 'phase_d_shared_isolation_receipt_invalid'
        }
        foreach ($row in $before.rules) {
            if (@($shared | Where-Object { $_.name -ceq $row.name -and $_.enabled -eq $row.enabled }).Count -ne 1) {
                throw 'phase_d_shared_isolation_state_changed'
            }
        }
        return # A retried completion must not stop a subsequent official session.
    }
    $services=@(Get-PhaseDIsolationServices @($shared.program))
    if ($services.Count -ne @($before.services).Count) { throw 'phase_d_shared_isolation_service_changed' }
    foreach ($baseline in $before.services) {
        $service=@($services | Where-Object { $_.name -ceq $baseline.name -and $_.program -ieq $baseline.program })
        if ($service.Count -ne 1 -or $baseline.state -cne 'Stopped' -or
            $service[0].startMode -cne $baseline.startMode -or
            (Get-FileHash -LiteralPath $baseline.program).Hash.ToLowerInvariant() -cne $baseline.sha256) {
            throw 'phase_d_shared_isolation_service_changed'
        }
        if ($service[0].state -cne 'Stopped') {
            # Only the previously approved shared ACE service, through normal SCM stop.
            if ($baseline.name -cne 'AntiCheatExpert Protection' -or
                $baseline.program -ine 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe') {
                throw 'phase_d_shared_isolation_service_running'
            }
            Stop-Service -Name $baseline.name -ErrorAction Stop
            $controller=Get-Service -Name $baseline.name -ErrorAction Stop
            try { $controller.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10)) } finally { $controller.Dispose() }
        }
    }
    # Service stop alone is not process-tree proof: retain blocks while a helper lives.
    Assert-PhaseDIsolationProcessesCold @($current.program)
    $enable=@($before.rules | Where-Object enabled | ForEach-Object { $_.name })
    $disable=@($before.rules | Where-Object { -not $_.enabled } | ForEach-Object { $_.name })
    if ($enable.Count) { Enable-NetFirewallRule -Name $enable -ErrorAction Stop | Out-Null }
    if ($disable.Count) { Disable-NetFirewallRule -Name $disable -ErrorAction Stop | Out-Null }
    $after=@(Get-PhaseDIsolationRules)
    foreach ($row in $before.rules) {
        if (@($after | Where-Object { $_.name -ceq $row.name -and $_.program -ieq $row.program -and $_.enabled -eq $row.enabled }).Count -ne 1) {
            throw 'phase_d_shared_isolation_restore_failed'
        }
    }
    Write-PhaseDIsolationJson (Join-Path $LaunchRoot 'shared-isolation.restored.json') ([ordered]@{
        contractId='nll/phase-d-shared-isolation-restored/v1';runnerBundleSha256=$ExpectedBundleSha256
        beforeSha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();restored=$true})
}
