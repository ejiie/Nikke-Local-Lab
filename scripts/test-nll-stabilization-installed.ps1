[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$PackageUid)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
$install = 'C:\NLL\ControlCenter'
$package = Join-Path $repository ('artifacts/stabilization/release/' + $PackageUid)
$deployment = Get-Content -LiteralPath (Join-Path $package 'deployment.receipt.json') -Raw | ConvertFrom-Json
if ($deployment.status -cne 'installed_manual_acceptance_pending') { throw 'stabilization_smoke_deployment_required' }
$manifest = Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
foreach ($row in $manifest.changes) {
    if ((Get-FileHash -LiteralPath (Join-Path $install $row.relativePath)).Hash.ToLowerInvariant() -cne $row.after) { throw 'stabilization_smoke_installed_drift' }
}
if (@(Get-Process -Name postgres,pg_ctl,nikke,EpinelPS,'NLL Control Center' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'stabilization_smoke_runtime_not_cold' }
if (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in @(55433,17878) }).Count -gt 0) { throw 'stabilization_smoke_port_in_use' }
$uid = [guid]::NewGuid().ToString('N')
$private = Join-Path ('D:\NikkeLocalLab\Backups\stabilization-audit-' + $deployment.auditUid) ('installed-smoke-' + $uid)
$null = New-Item -ItemType Directory -Path $private
$stdout = Join-Path $private 'host.stdout.private.log'
$stderr = Join-Path $private 'host.stderr.private.log'
$signal = Join-Path ([IO.Path]::GetTempPath()) ('nll-control-center-stop-' + $uid + '.signal')
$hostProcess = $null; $passed=$false; $stopped=$false; $accountCount=0; $workspaceCount=0
$samples=[Collections.Generic.List[double]]::new()
try {
    $hostProcess = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $install 'Start-NLL-ControlCenter.ps1'),'-DesktopHost','-DesktopStopSignalPath',$signal) `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $deadline = [DateTime]::UtcNow.AddSeconds(90); $code=$null
    do {
        if (Test-Path -LiteralPath $stdout) {
            $lines = [IO.File]::ReadAllLines($stdout)
            $markers = @($lines | Where-Object { $_.StartsWith('NLL_DESKTOP_BOOTSTRAP:',[StringComparison]::Ordinal) })
            if ($markers.Count -eq 1) { $code = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($markers[0].Substring(22))) }
            if ($markers.Count -gt 1) { throw 'stabilization_smoke_bootstrap_invalid' }
        }
        if ($code) { break }
        if ($hostProcess.HasExited) { throw 'stabilization_smoke_host_exited' }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $code) { throw 'stabilization_smoke_bootstrap_timeout' }
    $origin='http://127.0.0.1:17878'
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $null = Invoke-WebRequest -Uri ($origin+'/admin-auth/v1/bootstrap') -Method Post -ContentType 'application/json' -Headers @{Origin=$origin} -Body (@{code=$code}|ConvertTo-Json -Compress) -WebSession $session -TimeoutSec 30 -NoProxy
    $code=$null; $lines=$null; $markers=$null
    for ($iteration=0; $iteration -lt 3; $iteration++) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $accounts = @(Invoke-RestMethod -Uri ($origin+'/admin-api/v1/accounts') -WebSession $session -TimeoutSec 30 -NoProxy | ForEach-Object { $_ })
        $watch.Stop(); $samples.Add($watch.Elapsed.TotalMilliseconds)
        if ($accounts.Count -lt 1) { throw 'stabilization_smoke_account_list_empty' }
        $accountCount=$accounts.Count
    }
    foreach ($account in $accounts) {
        $accountUid = [guid]::ParseExact([string]$account.accountUid,'D').ToString('D')
        $workspace = Invoke-RestMethod -Uri ($origin+'/admin-api/v1/accounts/'+$accountUid+'/workspace') -WebSession $session -TimeoutSec 30 -NoProxy
        if ($workspace.accountUid -cne $accountUid) { throw 'stabilization_smoke_workspace_mismatch' }
        $workspaceCount++
    }
    $editor=Invoke-WebRequest -Uri ($origin+'/editor/') -TimeoutSec 30 -NoProxy
    if ($editor.StatusCode -ne 200) { throw 'stabilization_smoke_editor_unavailable' }
    $passed=$true
}
catch { Write-Output 'stabilization_smoke_failed_private_evidence_retained' }
finally {
    $code=$null; $accounts=$null; $workspace=$null; $session=$null; $lines=$null; $markers=$null
    # Cooperative stop only. Never kill the host or its database descendants.
    [IO.File]::WriteAllText($signal,"stop`n",[Text.UTF8Encoding]::new($false))
    if ($null -ne $hostProcess) {
        $exited=$hostProcess.WaitForExit(100000)
        $stopped=$exited -and $hostProcess.ExitCode -eq 0 -and @(Get-Process -Name postgres,pg_ctl -ErrorAction SilentlyContinue).Count -eq 0
        $hostProcess.Dispose()
    }
    if ($stopped) {
        if (Test-Path -LiteralPath $signal) { Remove-Item -LiteralPath $signal }
        # Contains a one-time LOCAL bootstrap code: do not retain it in evidence.
        if (Test-Path -LiteralPath $stdout) { Remove-Item -LiteralPath $stdout }
    }
    [ordered]@{
        contractId='nll/stabilization-installed-api-smoke/v1'; packageUid=$PackageUid
        passed=($passed -and $stopped); safeHostStopVerified=$stopped
        accountCount=$accountCount; workspaceCount=$workspaceCount; accountReadMs=@($samples.ToArray())
        gameExecuted=$false; webViewUiExecuted=$false; saveOrImportRequested=$false
        finishedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $package 'installed-smoke.receipt.json') -Encoding UTF8
}
if (-not $passed -or -not $stopped) { throw 'stabilization_smoke_not_verified' }
'Installed API/bootstrap/read/cooperative-stop smoke passed; no original game or WebView UI execution.'
