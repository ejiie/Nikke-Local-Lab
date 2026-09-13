$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ControlCenterMaintenance.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-maintenance-synthetic-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$checks = 0
function Check([bool]$Value) { if (-not $Value) { throw 'synthetic_maintenance_assertion_failed' }; $script:checks++ }
function Fails([scriptblock]$Action, [string]$Code) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message.Contains($Code)); return }
    throw 'synthetic_maintenance_expected_failure'
}
function Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), [Text.Encoding]::UTF8) }
try {
    $repository = Join-Path $root 'repository'
    $artifacts = Join-Path $repository 'artifacts'
    $null = [IO.Directory]::CreateDirectory($artifacts)
    Check ($null -eq (Get-NllBossPipelineActivation $root $repository))
    foreach ($mode in @('start','deploy')) {
        $lease = Enter-NllControlCenterMaintenance $root $mode
        try {
            Fails { Enter-NllControlCenterMaintenance $root start } 'maintenance_busy'
            Fails { Enter-NllControlCenterMaintenance $root deploy } 'maintenance_busy'
        } finally { $lease.Dispose() }
    }
    $pending = Join-Path $root 'app-update.pending.json'
    Json $pending @{ synthetic = $true }
    Fails { Enter-NllControlCenterMaintenance $root start } 'app_update_recovery_required'
    $lease = Enter-NllControlCenterMaintenance $root deploy
    $lease.Dispose()
    Check ($true)
    [IO.File]::Move($pending, (Join-Path $root 'synthetic-retired-pending.json'))
    $null = [IO.Directory]::CreateDirectory($pending)
    Fails { Enter-NllControlCenterMaintenance $root start } 'app_update_recovery_required'
    [IO.Directory]::Move($pending, (Join-Path $root 'synthetic-retired-directory'))
    $configuration = Join-Path $artifacts 'configuration.private.json'
    Json $configuration @{ schemaVersion = 1; contractId = 'nll/boss-pipeline-config/v1'; repositoryRoot = $repository }
    $activation = @{ schemaVersion = 1; contractId = 'nll/boss-pipeline-activation/v1'; configurationPath = $configuration;
        configurationSha256 = (Get-FileHash -LiteralPath $configuration).Hash.ToLowerInvariant() }
    $activePath = Join-Path $root 'boss-pipeline.active.json'
    Json $activePath $activation
    $read = Get-NllBossPipelineActivation $root $repository
    Check ($read.path -ceq $configuration -and $read.sha256 -ceq $activation.configurationSha256)
    Json $configuration @{ schemaVersion = 1; contractId = 'nll/boss-pipeline-config/v1'; repositoryRoot = 'changed' }
    Fails { Get-NllBossPipelineActivation $root $repository } 'boss_activation_configuration_drifted'
    $activation.configurationPath = Join-Path $root 'outside.json'
    Json $activePath $activation
    Fails { Get-NllBossPipelineActivation $root $repository } 'boss_activation_scope_invalid'
    $activation.configurationPath = $configuration
    $activation.unreviewed = $true
    Json $activePath $activation
    Fails { Get-NllBossPipelineActivation $root $repository } 'boss_activation_invalid'
    [ordered]@{ statusCode = 'passed'; assertions = $checks; syntheticFilesOnly = $true;
        databaseStarted = $false; nativeClientExecuted = $false; installedFilesModified = $false } | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^nll-maintenance-synthetic-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
