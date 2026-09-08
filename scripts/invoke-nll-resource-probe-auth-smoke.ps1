[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$AssessmentUid,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$PreparationSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedScriptSha256
)
# Elevated, bounded server/auth-only run. No native game/hosts/root-CA changes.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Require([bool]$Value, [string]$Code) { if (-not $Value) { throw ('resource_probe_smoke_' + $Code) } }
function Hash-File([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-NewJson([string]$Path, [object]$Value) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8))
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function No-Reparse([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) { Require (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse' }
        $parent=Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }; $cursor=$parent
    }
}
Require ((Hash-File $PSCommandPath) -ceq $ExpectedScriptSha256) 'script_drift'
Require ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'administrator_required'
$uid=[Guid]::Empty
Require ([Guid]::TryParseExact($AssessmentUid,'D',[ref]$uid)) 'assessment_invalid'
$serverRoot=Join-Path 'C:\NLL\Runtime\EpinelPS-151-ResourceProbe' $AssessmentUid
$bootstrapRoot=Join-Path 'C:\NLL\Runtime\ResourceProbeBootstrap' $AssessmentUid
$evidence=Join-Path 'C:\NLL\Staging\ResourceProbeRuns' $AssessmentUid
foreach ($directory in @($serverRoot,$bootstrapRoot,$evidence)) { No-Reparse $directory }
$preparationPath=Join-Path $evidence 'auth-preparation.receipt.json'
Require ((Hash-File $preparationPath) -ceq $PreparationSha256) 'preparation_drift'
$preparation=Get-Content -LiteralPath $preparationPath -Raw | ConvertFrom-Json
Require ($preparation.contractId -ceq 'nll/resource-probe-auth-preparation/v2' -and $preparation.assessmentUid -ceq $AssessmentUid) 'preparation_invalid'
$serverManifest=Join-Path $serverRoot 'resource-probe-runtime.private.json'
$bootstrapManifest=Join-Path $bootstrapRoot 'bootstrap.private.json'
Require ((Hash-File $serverManifest) -ceq $preparation.serverManifestSha256 -and (Hash-File $bootstrapManifest) -ceq $preparation.bootstrapManifestSha256) 'manifest_drift'
$serverPlan=Get-Content -LiteralPath $serverManifest -Raw | ConvertFrom-Json
Require ($serverPlan.contractId -ceq 'nll/epinel-resource-probe-runtime/v2' -and
    $serverPlan.assessmentUid -ceq $AssessmentUid -and $serverPlan.durationSeconds -eq 60 -and
    @(Compare-Object @('contractId','assessmentUid','durationSeconds','files') @($serverPlan.PSObject.Properties.Name)).Count -eq 0) 'server_plan_invalid'
$bootstrapPlan=Get-Content -LiteralPath $bootstrapManifest -Raw | ConvertFrom-Json
Require ($bootstrapPlan.authOnly -eq $true) 'native_execution_forbidden'
Require (@(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(nikke|nikke_launcher|EpinelPS|NikkeLocalLab\.Phase3B2\..*Bootstrap)\.exe$' }).Count -eq 0) 'runtime_not_cold'
Require (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in 80,443,8443).Count -eq 0) 'listener_present'
Require (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count -eq 0) 'firewall_disabled'
$group='NLL Resource Probe Auth ' + $AssessmentUid
Require (@(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count -eq 0) 'firewall_group_exists'
$receiptPath=Join-Path $evidence 'auth-execution.receipt.json'
Require (-not (Test-Path -LiteralPath $receiptPath)) 'execution_already_recorded'
$serverExe=Join-Path $serverRoot 'EpinelPS.exe'
$bootstrapExe=Join-Path $bootstrapRoot 'NikkeLocalLab.Phase3B2.ResourceProbeBootstrap.exe'
$programs=@($serverExe,$bootstrapExe)
# Do not construct address-range exceptions: Windows rejected the earlier prefix set.
# Block all destinations for these two exact programs and measure loopback TLS under it.
$remoteAddresses=@('Any')
$serverProcess=$null; $bootstrapProcess=$null
$failure=$null; $isolationVerified=$false; $cleanupVerified=$false; $authAccepted=$false
$failureStage='firewall_create'; $failureDetail=$null
$startedAt=[DateTimeOffset]::UtcNow
$originalEnv=$env:NLL_RESOURCE_PROBE_BOOTSTRAP_SHA256
try {
    for ($i=0; $i -lt $programs.Count; $i++) {
        New-NetFirewallRule -Name ('NLL-ResourceProbe-Auth-' + $AssessmentUid + '-' + $i) -DisplayName ('NLL Resource Probe Auth ' + $AssessmentUid + ' ' + $i) -Group $group -Direction Outbound -Action Block -Enabled True -Profile Any -Program $programs[$i] -RemoteAddress $remoteAddresses | Out-Null
    }
    $failureStage='firewall_verify'
    $rules=@(Get-NetFirewallRule -Group $group -PolicyStore ActiveStore)
    Require ($rules.Count -eq $programs.Count) 'firewall_count_invalid'
    foreach ($rule in $rules) {
        Require ($rule.Enabled -eq 'True' -and $rule.Action -eq 'Block' -and $rule.Direction -eq 'Outbound') 'firewall_rule_invalid'
        Require ((Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule).Program -in $programs) 'firewall_program_invalid'
        $actual=@((Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule).RemoteAddress)
        Require (@(Compare-Object ($actual | Sort-Object) ($remoteAddresses | Sort-Object)).Count -eq 0) 'firewall_addresses_invalid'
    }
    $isolationVerified=$true
    $failureStage='server_start'
    Write-NewJson (Join-Path $evidence 'auth-isolation.receipt.json') ([ordered]@{contractId='nll/resource-probe-auth-isolation/v1';assessmentUid=$AssessmentUid;programCount=$programs.Count;activeStoreVerified=$true;verifiedAtUtc=[DateTimeOffset]::UtcNow})
    $serverProcess=Start-Process -FilePath $serverExe -WorkingDirectory $serverRoot -ArgumentList @('--headless','--local-only','--resource-route-probe',$preparation.serverManifestSha256) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $evidence 'server.stdout.private.log') -RedirectStandardError (Join-Path $evidence 'server.stderr.private.log')
    $null=$serverProcess.Handle
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $ready=$false
    while ($timer.Elapsed.TotalSeconds -lt 45 -and -not $serverProcess.HasExited) {
        $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $serverProcess.Id })
        Require (@($listeners | Where-Object LocalAddress -ne '127.0.0.1').Count -eq 0) 'non_loopback_listener'
        if (@($listeners | Where-Object LocalPort -eq 443).Count -eq 1) { $ready=$true; break }
        Start-Sleep -Milliseconds 500
    }
    Require $ready 'server_not_ready'
    $failureStage='synthetic_auth'
    $env:NLL_RESOURCE_PROBE_BOOTSTRAP_SHA256=$preparation.bootstrapManifestSha256
    $bootstrapProcess=Start-Process -FilePath $bootstrapExe -WorkingDirectory $bootstrapRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $evidence 'bootstrap.stdout.private.log') -RedirectStandardError (Join-Path $evidence 'bootstrap.stderr.private.log')
    $null=$bootstrapProcess.Handle
    while (-not $bootstrapProcess.HasExited -and $timer.Elapsed.TotalSeconds -lt 80) { Start-Sleep -Milliseconds 500 }
    Require ($bootstrapProcess.HasExited -and $bootstrapProcess.ExitCode -eq 0) 'synthetic_auth_failed'
    $authReceipt=Get-Content -LiteralPath (Join-Path $evidence 'auth-smoke.receipt.json') -Raw | ConvertFrom-Json
    Require ($authReceipt.localSyntheticAuthAccepted -and -not $authReceipt.clientExecutionStarted) 'auth_receipt_invalid'
    $authAccepted=$true
    $failureStage='server_shutdown'
    while (-not $serverProcess.HasExited -and $timer.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Milliseconds 500 }
    Require ($serverProcess.HasExited -and $serverProcess.ExitCode -eq 0) 'server_shutdown_failed'
}
catch {
    $failure=if ($_.Exception.Message -cmatch '^resource_probe_smoke_[a-z_]+$') { $_.Exception.Message } else { 'resource_probe_smoke_unexpected_failure' }
    # No exception message, URL, credentials or body enters the public receipt.
    $failureDetail=[ordered]@{stage=$failureStage;exceptionType=$_.Exception.GetType().FullName;hresult=$_.Exception.HResult;line=$_.InvocationInfo.ScriptLineNumber}
    if ($failureStage -in 'firewall_create','firewall_verify') {
        # Private Windows-only setup diagnostics, before any authentication starts.
        Write-NewJson (Join-Path $evidence 'firewall-error.private.json') ([ordered]@{stage=$failureStage;errorId=$_.FullyQualifiedErrorId;message=$_.Exception.Message})
    }
}
finally {
    $env:NLL_RESOURCE_PROBE_BOOTSTRAP_SHA256=$originalEnv
    $processCleanupVerified=$true
    foreach ($process in @($bootstrapProcess,$serverProcess)) {
        try {
            if ($null -ne $process -and -not $process.HasExited) { $process.Kill($true); $null=$process.WaitForExit(10000) }
            if ($null -ne $process -and -not $process.HasExited) { $processCleanupVerified=$false }
        }
        catch { $processCleanupVerified=$false }
    }
    try {
        $survivors=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -in $programs })
        if ($processCleanupVerified -and $survivors.Count -eq 0) {
            Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            $cleanupVerified=@(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count -eq 0
        }
    }
    catch { $cleanupVerified=$false }
    if (-not $cleanupVerified -and -not $failure) { $failure='resource_probe_smoke_cleanup_unverified' }
    # Preserve blocking rules if cleanup could not prove all scoped processes exited.
    Write-NewJson $receiptPath ([ordered]@{contractId='nll/resource-probe-auth-execution/v1';assessmentUid=$AssessmentUid
        status=$(if ($authAccepted -and $cleanupVerified -and -not $failure) {'local_auth_smoke_passed'} else {'local_auth_smoke_failed'})
        startedAtUtc=$startedAt; finishedAtUtc=[DateTimeOffset]::UtcNow; failureCode=$failure; failureDetail=$failureDetail
        isolationVerified=$isolationVerified; localSyntheticAuthAccepted=$authAccepted; cleanupVerified=$cleanupVerified
        clientStarted=$false; hostsChanged=$false; systemTrustChanged=$false; productionDbModified=$false; nativeAdmission='not_evaluated'})
    foreach ($process in @($bootstrapProcess,$serverProcess)) { if ($null -ne $process) { $process.Dispose() } }
}
if ($failure -or -not $cleanupVerified) { exit 1 }
