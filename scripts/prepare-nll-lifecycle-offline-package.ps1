[CmdletBinding()]
param([string]$InstallRoot = 'C:\NLL\ControlCenter')

# Preparation only: write exclusively to a NEW ignored artifact directory.
# No deployment mode, game launch, DB access, hosts/firewall or DLL patching.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') -ine 'C:\NLL\ControlCenter') { throw 'lifecycle_package_install_root_invalid' }
$packageRoot = Join-Path $repositoryRoot ('artifacts\stabilization\lifecycle-package\' + [guid]::NewGuid().ToString('N'))
$candidateRoot = Join-Path $packageRoot 'candidate-app'
$backupRoot = Join-Path $packageRoot 'installed-before'
$sourceRoot = Join-Path $packageRoot 'candidate-source'
$null = New-Item -ItemType Directory -Path $candidateRoot, $backupRoot, $sourceRoot
$env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
$env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
dotnet publish (Join-Path $repositoryRoot 'src\NikkeLocalLab.Admin.Api') --configuration Release --no-restore --output $candidateRoot --verbosity quiet
if ($LASTEXITCODE -ne 0) { throw 'lifecycle_package_publish_failed' }
function Get-Pin([string]$Path) {
    [ordered]@{ sha256 = (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant(); byteLength = (Get-Item -LiteralPath $Path).Length }
}
$installedFiles = @('NikkeLocalLab.Admin.Api.dll', 'NikkeLocalLab.Admin.Api.pdb', 'wwwroot\editor\editor.js')
# Keep rebuilt dependencies and their matching symbols in the same app rollback set.
# An IL comparison is evidence for review, never a substitute for byte-exact file pins.
foreach ($file in Get-ChildItem -LiteralPath $candidateRoot -File -Filter '*.dll') {
    if ($file.Name -ceq 'NikkeLocalLab.Admin.Api.dll') { continue }
    $installed = Join-Path $InstallRoot ('app\' + $file.Name)
    if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
        throw 'lifecycle_package_dependency_baseline_missing'
    }
    if ((Get-Pin $installed).sha256 -ceq (Get-Pin $file.FullName).sha256) { continue }
    $installedFiles += $file.Name
    $symbols = [IO.Path]::ChangeExtension($file.Name, '.pdb')
    if (Test-Path -LiteralPath (Join-Path $candidateRoot $symbols) -PathType Leaf) {
        # A missing installed PDB is an unresolved rollback shape, not permission to
        # silently introduce an unbacked file. The preparation stays fail closed.
        $installedFiles += $symbols
    }
}
$backups = @()
foreach ($relative in $installedFiles) {
    $installed = Join-Path $InstallRoot ('app\' + $relative)
    if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) { throw 'lifecycle_package_installed_file_missing' }
    $destination = Join-Path $backupRoot $relative
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
    $before = Get-Pin $installed
    Copy-Item -LiteralPath $installed -Destination $destination
    if ((Get-Pin $installed).sha256 -cne $before.sha256 -or (Get-Pin $destination).sha256 -cne $before.sha256) { throw 'lifecycle_package_backup_changed' }
    $backups += [ordered]@{ relativePath = $relative; pin = $before; byteExact = $true }
}
$scriptFiles = @('invoke-nll-phase-d-execution.ps1', 'watch-nll-phase-d-execution.ps1',
    'recover-nll-phase-d-orphaned-execution.ps1', 'Nll.PhaseDProcessIdentity.ps1', 'Nll.PhaseDChildProcess.ps1')
$sources = @()
foreach ($name in $scriptFiles) {
    $path = Join-Path $PSScriptRoot $name
    Copy-Item -LiteralPath $path -Destination (Join-Path $sourceRoot $name)
    $pin = Get-Pin $path
    if ((Get-Pin (Join-Path $sourceRoot $name)).sha256 -cne $pin.sha256) { throw 'lifecycle_package_source_changed' }
    $sources += [ordered]@{ relativePath = 'scripts/' + $name; pin = $pin; consumedFromRepositoryAtRuntime = $true }
}
$dependencies = @()
foreach ($file in Get-ChildItem -LiteralPath $candidateRoot -File -Filter '*.dll') {
    if ($file.Name -ceq 'NikkeLocalLab.Admin.Api.dll') { continue }
    $installed = Join-Path $InstallRoot ('app\' + $file.Name)
    $matches = (Test-Path -LiteralPath $installed -PathType Leaf) -and
        (Get-Pin $installed).sha256 -ceq (Get-Pin $file.FullName).sha256
    $dependencies += [ordered]@{ name = $file.Name; matchesInstalled = $matches; candidatePin = (Get-Pin $file.FullName) }
}
$candidateFiles = @()
foreach ($relative in $installedFiles) {
    $candidateFiles += [ordered]@{ relativePath = $relative; pin = (Get-Pin (Join-Path $candidateRoot $relative)) }
}
$rehearsalRoot = Join-Path $packageRoot 'rollback-rehearsal'
foreach ($relative in $installedFiles) {
    $rehearsalPath = Join-Path $rehearsalRoot $relative
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $rehearsalPath) -Force
    Copy-Item -LiteralPath (Join-Path $candidateRoot $relative) -Destination $rehearsalPath
    # Overwrite ONLY our freshly created rehearsal copy, never an installed file.
    Copy-Item -LiteralPath (Join-Path $backupRoot $relative) -Destination $rehearsalPath -Force
    if ((Get-Pin $rehearsalPath).sha256 -cne (Get-Pin (Join-Path $backupRoot $relative)).sha256) {
        throw 'lifecycle_package_backup_restore_rehearsal_failed'
    }
}
$manifest = [ordered]@{
    schemaVersion = 1; kind = 'lifecycle_offline_candidate_not_deployable/v1'
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    deploymentAllowed = $false; installedFilesChanged = $false; operationalDatabaseTouched = $false
    appBackupRestoreRehearsalPassed = $true; completeRuntimeRollbackReady = $false
    blockers = @('candidate_full_verification_receipt_unsealed', 'repository_script_exact_rollback_baseline_unsealed', 'deployment_approval_pending') +
        @(if (@($dependencies | Where-Object { -not $_.matchesInstalled }).Count -gt 0) { 'candidate_dependencies_differ_from_installed' })
    candidateApp = $candidateFiles; installedByteExactBackups = $backups
    repositoryConsumedScripts = $sources; dependencyComparison = $dependencies
    priorSourceReference = 'artifacts/stabilization/2026-09-06-lifecycle/source-before (LF-normalized text; NOT byte-exact installed rollback)'
    rollbackOrder = @('stop manager and prove runtime cold', 'restore only hash-verified installed app files from installed-before',
        'restore approved matching repository script set; do not pair old app with arbitrary new scripts', 'verify hashes before restart')
    exclusions = @('game clients', 'Epinel runtime', 'materializer', 'database', 'account/config/secrets', 'hosts/firewall', 'S29')
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $packageRoot 'manifest.json') -Encoding UTF8
Write-Output $packageRoot
