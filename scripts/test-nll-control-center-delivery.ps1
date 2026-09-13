$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ControlCenterDelivery.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-delivery-synthetic-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$checks = 0
function Check([bool]$Value) { if (-not $Value) { throw 'synthetic_delivery_assertion_failed' }; $script:checks++ }
function Fails([scriptblock]$Action, [string]$Code) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message.Contains($Code)); return }
    throw 'synthetic_delivery_expected_failure'
}
function TextFile([string]$Path, [string]$Text) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text)
}
try {
    $install = Join-Path $root 'installed'
    $app = Join-Path $install 'app'
    $published = Join-Path $root 'published'
    foreach ($key in @('NikkeLocalLab.Admin.Api.dll','NikkeLocalLab.Admin.Api.deps.json',
        'NikkeLocalLab.Admin.Api.runtimeconfig.json','wwwroot/editor/index.html','wwwroot/editor/editor.js','wwwroot/editor/editor.css')) {
        TextFile (Join-Path $app $key) ('synthetic-before-' + $key)
        TextFile (Join-Path $published $key) ('synthetic-after-' + $key)
    }
    TextFile (Join-Path $published 'wwwroot/editor/boss-seasons.js') 'synthetic-new-js'
    TextFile (Join-Path $published 'wwwroot/editor/user-validation.js') 'synthetic-validation-js'
    TextFile (Join-Path $install 'Start-NLL-ControlCenter.ps1') 'synthetic-old-start-not-executed'
    $start = Join-Path $root 'synthetic-start.ps1'
    TextFile $start 'synthetic-guarded-start-not-executed'
    $config = Join-Path $root 'inputs/configuration.private.json'
    TextFile $config '{"synthetic":"never executed"}'
    $guard = Join-Path $root 'protected.json'
    TextFile $guard 'synthetic-protected-baseline'
    $protected = @([ordered]@{ path = $guard; pin = Get-NllAppPin $guard })
    $package = New-NllControlCenterAppPackage $app $published (Join-Path $root 'package')
    $created = New-NllControlCenterDeliveryPlan $install $package.packageRoot $package.manifestSha256 $config (Get-NllAppPin $config).sha256 $start (Join-Path $root 'delivery') $protected
    Check (-not $created.installedFilesModified)
    $plan = Read-NllControlCenterDeliveryPlan $created.planRoot $created.planSha256
    foreach ($operation in @('apply','apply','restore','restore')) {
        $result = Invoke-NllControlCenterDelivery $created.planRoot $created.planSha256 $operation {}
        Check ($result.statusCode -ceq 'verified' -and -not $result.nativeClientExecuted)
        Check (-not (Test-Path -LiteralPath (Join-Path $install 'app-update.pending.json')))
        $side = if ($operation -ceq 'apply') { 'after' } else { 'before' }
        foreach ($row in $plan.controls) { Check (Test-NllAppPin (Get-NllAppPin (Join-Path $install $row.name)) $row.$side) }
        Check (Test-NllAppPin (Get-NllAppPin $guard) $protected[0].pin)
    }
    $before = @(Get-NllAppInventory $app)
    Fails { Invoke-NllControlCenterDelivery $created.planRoot $created.planSha256 apply { throw 'synthetic_runtime_not_cold' } } 'synthetic_runtime_not_cold'
    Check (Test-NllAppInventory $before @(Get-NllAppInventory $app))
    Check (-not (Test-Path -LiteralPath (Join-Path $install 'app-update.pending.json')))
    $script:coldCalls = 0
    Fails { Invoke-NllControlCenterDelivery $created.planRoot $created.planSha256 apply {
        $script:coldCalls++; if ($script:coldCalls -eq 2) { throw 'synthetic_interrupted_after_guard_install' }
    } } 'synthetic_interrupted_after_guard_install'
    Check (Test-Path -LiteralPath (Join-Path $install 'app-update.pending.json'))
    Fails { Enter-NllControlCenterMaintenance $install start } 'app_update_recovery_required'
    $null = Invoke-NllControlCenterDelivery $created.planRoot $created.planSha256 restore {}
    Check (Test-NllAppInventory $before @(Get-NllAppInventory $app))
    Check (([IO.File]::ReadAllText((Join-Path $install 'Start-NLL-ControlCenter.ps1'))) -ceq 'synthetic-old-start-not-executed')
    $lease = Enter-NllControlCenterMaintenance $install start
    try { Fails { Invoke-NllControlCenterDelivery $created.planRoot $created.planSha256 apply {} } 'maintenance_busy' }
    finally { $lease.Dispose() }
    TextFile $guard 'foreign-protected-change'
    Fails { Invoke-NllControlCenterDelivery $created.planRoot $created.planSha256 apply {} } 'delivery_input_drifted'
    Check (Test-NllAppInventory $before @(Get-NllAppInventory $app))
    [ordered]@{ statusCode = 'passed'; assertions = $checks; syntheticFilesOnly = $true;
        nativeClientExecuted = $false; installedFilesModified = $false } | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^nll-delivery-synthetic-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
