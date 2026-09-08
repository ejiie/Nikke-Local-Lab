[CmdletBinding()]
param([string]$InstallRoot = 'C:\NLL\ControlCenter')

# Preparation only. Never run a candidate host: its startup can migrate the DB.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Nll.OfflinePackage.ps1')
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') -ine 'C:\NLL\ControlCenter') { throw 'workspace_package_install_root_invalid' }
$packageRoot = Join-Path $repositoryRoot ('artifacts\stabilization\workspace-package\' + [guid]::NewGuid().ToString('N'))
$candidateRoot = Join-Path $packageRoot 'candidate-app'
$null = New-Item -ItemType Directory -Path $candidateRoot
$env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
$env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$installedRoot = Join-Path $InstallRoot 'app'
$installedTree = @(Get-NllPackageTree $installedRoot)

# Freeze exact runtime-consumed repository inputs. Measured, not game-validated.
$scriptsTree = @(Get-NllPackageTree $PSScriptRoot)
Copy-NllPackageTree $PSScriptRoot (Join-Path $packageRoot 'repository-before/scripts') $scriptsTree
$cliRoot = Join-Path $repositoryRoot 'src/NikkeLocalLab.Import.Cli/bin/Release/net8.0'
$cliTree = @(Get-NllPackageTree $cliRoot)
Copy-NllPackageTree $cliRoot (Join-Path $packageRoot 'repository-before/import-cli') $cliTree
$config = Join-Path $repositoryRoot 'config/appsettings.example.json'
$configSha = (Get-FileHash -LiteralPath $config).Hash.ToLowerInvariant()
Copy-Item -LiteralPath $config -Destination (Join-Path $packageRoot 'repository-before/appsettings.example.json')
if ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'repository-before/appsettings.example.json')).Hash.ToLowerInvariant() -cne $configSha) { throw 'workspace_package_config_copy_changed' }

dotnet publish (Join-Path $repositoryRoot 'src/NikkeLocalLab.Admin.Api') --configuration Release --no-restore --output $candidateRoot --verbosity quiet
if ($LASTEXITCODE -ne 0) { throw 'workspace_package_publish_failed' }
$candidateTree = @(Get-NllPackageTree $candidateRoot)
$delta = @(Get-NllPackageDelta $candidateTree $installedTree)
# The desktop launcher hosts dotnet directly; IIS metadata is not deployed.
foreach ($row in $delta) {
    if ($row.relativePath -ceq 'web.config') { $row.action = 'preserve_installed_not_consumed' }
}
$changed = @($delta | Where-Object { $_.action -in @('replace', 'add') })
$backupRoot = Join-Path $packageRoot 'installed-before'
$rehearsalRoot = Join-Path $packageRoot 'rollback-rehearsal'
$null = New-Item -ItemType Directory -Path $backupRoot, $rehearsalRoot
foreach ($row in $changed) {
    $rehearsal = Join-Path $rehearsalRoot $row.relativePath
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $rehearsal) -Force
    Copy-Item -LiteralPath (Join-Path $candidateRoot $row.relativePath) -Destination $rehearsal
    if ($row.action -ceq 'replace') {
        $backup = Join-Path $backupRoot $row.relativePath
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force
        Copy-Item -LiteralPath (Join-Path $installedRoot $row.relativePath) -Destination $backup
        if ((Get-FileHash -LiteralPath $backup).Hash.ToLowerInvariant() -cne $row.installed.sha256) { throw 'workspace_package_backup_changed' }
        Copy-Item -LiteralPath $backup -Destination $rehearsal -Force
    }
    else {
        # Delete ONLY a file created above in this new rehearsal directory.
        $resolved = (Resolve-Path -LiteralPath $rehearsal).ProviderPath
        if (-not $resolved.StartsWith([IO.Path]::GetFullPath($rehearsalRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'workspace_package_rehearsal_path_invalid' }
        Remove-Item -LiteralPath $resolved
    }
}
$expectedBackups = @($changed | Where-Object { $_.action -ceq 'replace' } | ForEach-Object { $_.installed } | Sort-Object { $_.relativePath })
Assert-NllPackageTree $backupRoot $expectedBackups
Assert-NllPackageTree $rehearsalRoot $expectedBackups
Assert-NllPackageTree $installedRoot $installedTree
Assert-NllPackageTree $candidateRoot $candidateTree
Assert-NllPackageTree $PSScriptRoot $scriptsTree
Assert-NllPackageTree $cliRoot $cliTree
if ((Get-FileHash -LiteralPath $config).Hash.ToLowerInvariant() -cne $configSha) { throw 'workspace_package_config_changed' }
$migrations = @(Get-NllPackageTree (Join-Path $repositoryRoot 'src/NikkeLocalLab.Persistence.PostgreSql/Migrations'))
$manifest = [ordered]@{
    schemaVersion = 1; kind = 'workspace_offline_candidate_not_deployable/v1'
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    deploymentAllowed = $false; installedFilesChanged = $false; operationalDatabaseTouched = $false
    appBackupRestoreRehearsalPassed = $true; completeRuntimeRollbackReady = $false
    blockers = @('candidate_final_verification_binding_required', 'cold_database_backup_and_restore_receipt_required', 'deployment_approval_pending', 'installed_runtime_acceptance_not_executed')
    candidateApp = $candidateTree; appDelta = $delta
    installedByteExactBackups = $expectedBackups
    repositoryConsumedScripts = $scriptsTree; repositoryConsumedImportCli = $cliTree; repositoryConfigSha256 = $configSha
    migrationSources = $migrations; candidateSchemaVersion = 18
    installedOnlyFilesPolicy = 'preserve_never_delete'
    rollbackOrder = @('stop manager and prove all runtime processes cold',
        'quarantine failed-state DB before restoring the verified full pre-migration cold backup',
        'restore changed installed app files; remove only added files with exact candidate hashes',
        'restore matching repository scripts/config/import CLI; verify all pins',
        'verify schema and explicit admin smoke before allowing game launch')
    exclusions = @('game clients', 'Epinel runtime', 'materializer', 'operational database writes', 'account/config/secrets mutation', 'hosts/firewall', 'S29', 'desktop shell replacement')
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $packageRoot 'manifest.json') -Encoding UTF8
Write-Output $packageRoot
