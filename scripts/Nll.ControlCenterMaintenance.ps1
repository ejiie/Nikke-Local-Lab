# Windows PowerShell 5.1-compatible startup/deployment interlock. Import is inert.
Set-StrictMode -Version Latest
function Assert-NllMaintenance([bool]$Value, [string]$Code) {
    if (-not $Value) { throw ('control_center_' + $Code) }
}
function Get-NllMaintenancePath([string]$Path) {
    Assert-NllMaintenance ([IO.Path]::IsPathRooted($Path) -and -not $Path.StartsWith('\\')) 'maintenance_path_invalid'
    $full = [IO.Path]::GetFullPath($Path)
    Assert-NllMaintenance (-not $full.Substring([IO.Path]::GetPathRoot($full).Length).Contains(':')) 'maintenance_path_invalid'
    for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        try { $attributes = [IO.File]::GetAttributes($cursor) }
        catch [IO.FileNotFoundException] { continue }
        catch [IO.DirectoryNotFoundException] { continue }
        Assert-NllMaintenance (($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'maintenance_reparse_forbidden'
    }
    $full
}
function Enter-NllControlCenterMaintenance([string]$Root, [ValidateSet('start','deploy')][string]$Mode) {
    $root = Get-NllMaintenancePath $Root
    Assert-NllMaintenance ([IO.Directory]::Exists($root)) 'maintenance_root_missing'
    $lockPath = Get-NllMaintenancePath (Join-Path $root 'app-maintenance.lock')
    try { $lease = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { throw 'control_center_maintenance_busy' }
    try {
        $pending = Get-NllMaintenancePath (Join-Path $root 'app-update.pending.json')
        Assert-NllMaintenance ($Mode -cne 'start' -or (-not [IO.File]::Exists($pending) -and
            -not [IO.Directory]::Exists($pending))) 'app_update_recovery_required'
        return $lease
    } catch { $lease.Dispose(); throw }
}
function Get-NllBossPipelineActivation([string]$Root, [string]$RepositoryRoot) {
    $root = Get-NllMaintenancePath $Root
    $repositoryRoot = (Get-NllMaintenancePath $RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $path = Get-NllMaintenancePath (Join-Path $root 'boss-pipeline.active.json')
    if (-not [IO.File]::Exists($path)) { return $null }
    Assert-NllMaintenance (([IO.FileInfo]::new($path)).Length -le 16384) 'boss_activation_invalid'
    $activation = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-NllMaintenance ($activation.schemaVersion -eq 1 -and
        $activation.contractId -ceq 'nll/boss-pipeline-activation/v1' -and
        @($activation.PSObject.Properties).Count -eq 4 -and
        $activation.configurationSha256 -cmatch '^[a-f0-9]{64}$') 'boss_activation_invalid'
    $configuration = Get-NllMaintenancePath ([string]$activation.configurationPath)
    Assert-NllMaintenance ($configuration.StartsWith((Join-Path $repositoryRoot 'artifacts') + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists($configuration)) 'boss_activation_scope_invalid'
    $bytes = [IO.File]::ReadAllBytes($configuration)
    Assert-NllMaintenance ($bytes.Length -gt 0 -and $bytes.Length -le 1048576) 'boss_activation_configuration_invalid'
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    Assert-NllMaintenance ($hash -ceq $activation.configurationSha256) 'boss_activation_configuration_drifted'
    $data = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff) | ConvertFrom-Json
    Assert-NllMaintenance ($data.schemaVersion -eq 1 -and $data.contractId -ceq 'nll/boss-pipeline-config/v1' -and
        (Get-NllMaintenancePath ([string]$data.repositoryRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar) -ceq $repositoryRoot) 'boss_activation_configuration_invalid'
    [pscustomobject]@{ path = $configuration; sha256 = $hash }
}
