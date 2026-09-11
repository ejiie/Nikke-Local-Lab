[CmdletBinding(DefaultParameterSetName='Prepare')]
param(
    [Parameter(ParameterSetName='Prepare')][switch]$Prepare,
    [Parameter(Mandatory, ParameterSetName='Apply')][switch]$Apply,
    [Parameter(Mandatory, ParameterSetName='Apply')][ValidatePattern('^[0-9a-f]{32}$')][string]$PackageUid,
    [Parameter(Mandatory, ParameterSetName='Apply')][ValidatePattern('^[0-9a-f]{64}$')][string]$ManifestSha256,
    [Parameter(Mandatory, ParameterSetName='Apply')][ValidatePattern('^[0-9a-f]{32}$')][string]$AuditUid,
    [Parameter(Mandatory, ParameterSetName='Apply')][ValidatePattern('^[0-9a-f]{32}$')][string]$VerificationUid
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.OfflinePackage.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$repository = Split-Path -Parent $PSScriptRoot
$install = 'C:\NLL\ControlCenter'
function Pin([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-Cold {
    if (@(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(postgres|pg_ctl|nikke|EpinelPS|NLL Control Center|NikkeLocalLab.*)\.exe$' -or
        $_.CommandLine -match 'NikkeLocalLab.Admin.Api.dll|watch-nll-phase-d-execution.ps1|invoke-nll-phase-d-execution.ps1|recover-nll-phase-d-orphaned-execution.ps1|Start-NLL-ControlCenter.ps1'
    }).Count -gt 0 -or (Test-Path -LiteralPath (Join-Path $install 'postgresql/data/postmaster.pid'))) { throw 'stabilization_release_runtime_not_cold' }
    if (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in @(55433,17878) }).Count) { throw 'stabilization_release_port_in_use' }
}
function Plain-Ancestors([string]$Path) {
    for ($item = [IO.Path]::GetFullPath($Path); $item; $item = Split-Path -Parent $item) {
        if ((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'stabilization_release_reparse_rejected' }
    }
}
function Target([string]$Relative) {
    if ($Relative -notmatch '^(app/|desktop/|Start-NLL-ControlCenter\.ps1$)' -or $Relative.Contains('..') -or $Relative.Contains(':') -or $Relative.Contains('\')) { throw 'stabilization_release_target_invalid' }
    $path = [IO.Path]::GetFullPath((Join-Path $install $Relative))
    if (-not $path.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'stabilization_release_target_invalid' }
    Plain-Ancestors $path
    $path
}
function Replace-Pinned([string]$Source, [string]$Destination, [string]$Before, [string]$After) {
    if ((Pin $Source) -cne $After) { throw 'stabilization_release_candidate_drift' }
    if ($Before) {
        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or (Pin $Destination) -cne $Before) { throw 'stabilization_release_installed_drift' }
    } elseif (Test-Path -LiteralPath $Destination) { throw 'stabilization_release_add_conflict' }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force
    $partial = $Destination + '.partial-' + [guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $partial
        if ((Pin $partial) -cne $After) { throw 'stabilization_release_copy_drift' }
        if ($Before) { [IO.File]::Replace($partial, $Destination, [NullString]::Value) }
        else { [IO.File]::Move($partial, $Destination) }
    } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial } }
}
if ($PSCmdlet.ParameterSetName -eq 'Prepare') {
    $PackageUid = [guid]::NewGuid().ToString('N')
    $package = Join-Path $repository ('artifacts/stabilization/release/' + $PackageUid)
    $candidate = Join-Path $package 'candidate'
    $null = New-Item -ItemType Directory -Path $candidate
    $env:DOTNET_CLI_HOME = Join-Path $repository '.dotnet-cli-home'
    $env:NUGET_PACKAGES = Join-Path $repository '.nuget-packages'
    dotnet publish (Join-Path $repository 'src/NikkeLocalLab.Admin.Api') -c Release --no-restore -o (Join-Path $candidate 'app') --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'stabilization_release_app_build_failed' }
    dotnet publish (Join-Path $repository 'tools/NikkeLocalLab.ControlCenter.Desktop') -c Release --no-restore -o (Join-Path $candidate 'desktop') --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'stabilization_release_desktop_build_failed' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-nll-phase-d-control-center.ps1') -Destination (Join-Path $candidate 'Start-NLL-ControlCenter.ps1')
    $tree = @(Get-NllPackageTree $candidate)
    $delta = @()
    foreach ($row in $tree) {
        if ($row.relativePath -ceq 'app/web.config') { continue }
        $path = Target $row.relativePath
        $before = if (Test-Path -LiteralPath $path -PathType Leaf) { Pin $path } else { $null }
        if ($before -cne $row.sha256) { $delta += [ordered]@{ relativePath=$row.relativePath; before=$before; after=$row.sha256 } }
    }
    $manifest = [ordered]@{
        contractId='nll/stabilization-app-release/v1'; packageUid=$PackageUid
        sourceHead=(& git -C $repository rev-parse HEAD).Trim(); candidate=$tree; changes=$delta
        schemaVersion=18; migrationExecutionAllowed=$false; gameRuntimeChanged=$false
        installedOnlyFiles='preserve'; actualPlay='operator_pending'
    }
    Write-AtomicJson (Join-Path $package 'manifest.json') $manifest
    [pscustomobject]@{ packageUid=$PackageUid; manifestSha256=(Pin (Join-Path $package 'manifest.json')); changedFiles=$delta.Count }
    exit 0
}

Assert-Cold
Plain-Ancestors $install
$package = Join-Path $repository ('artifacts/stabilization/release/' + $PackageUid)
Plain-Ancestors $package
$manifestPath = Join-Path $package 'manifest.json'
if ((Pin $manifestPath) -cne $ManifestSha256) { throw 'stabilization_release_manifest_drift' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.contractId -cne 'nll/stabilization-app-release/v1' -or $manifest.packageUid -cne $PackageUid -or $manifest.migrationExecutionAllowed -ne $false -or $manifest.sourceHead -cne (& git -C $repository rev-parse HEAD).Trim()) { throw 'stabilization_release_binding_invalid' }
if (@(& git -C $repository status --porcelain).Count -ne 0) { throw 'stabilization_release_source_not_committed' }
$verificationPath = Join-Path $repository ('artifacts/stabilization/final-verification/' + $VerificationUid + '/receipt.json')
$verification = Get-Content -LiteralPath $verificationPath -Raw | ConvertFrom-Json
if ($verification.contractId -cne 'nll/stabilization-verification/v1' -or $verification.passed -ne $true -or $verification.sourceHead -cne $manifest.sourceHead) { throw 'stabilization_release_verification_binding_invalid' }
$candidate = Join-Path $package 'candidate'
Assert-NllPackageTree $candidate @($manifest.candidate)
$auditPath = Join-Path $repository ('artifacts/stabilization/workspace-backup/' + $AuditUid + '/receipt.json')
$audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
if ($audit.passed -ne $true -or $audit.schemaVersionObserved -ne 18 -or $audit.readOnlyAudit.integrityMismatchCount -ne 0 -or $audit.legacyPendingCount -ne 0 -or $audit.readOnlyAudit.encryptedPendingFiles -ne 0) { throw 'stabilization_release_database_audit_required' }
$backup = Join-Path 'D:\NikkeLocalLab\Backups' ('stabilization-audit-' + $AuditUid)
Plain-Ancestors $backup
$coldTree = Get-Content -LiteralPath (Join-Path $backup 'cold-data.manifest.private.json') -Raw | ConvertFrom-Json
Assert-NllPackageTree (Join-Path $install 'postgresql/data') @($coldTree)
Assert-NllPackageTree (Join-Path $backup 'cold-data') @($coldTree)
$backupFiles = Join-Path $backup ('app-release-' + $PackageUid)
if (Test-Path -LiteralPath $backupFiles) { throw 'stabilization_release_already_attempted' }
$null = New-Item -ItemType Directory -Path $backupFiles
foreach ($row in $manifest.changes) {
    $path = Target $row.relativePath
    if ($row.before) {
        if ((Pin $path) -cne $row.before) { throw 'stabilization_release_baseline_drift' }
        $saved = Join-Path $backupFiles $row.relativePath
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force
        Copy-Item -LiteralPath $path -Destination $saved
        if ((Pin $saved) -cne $row.before) { throw 'stabilization_release_backup_drift' }
    } elseif (Test-Path -LiteralPath $path) { throw 'stabilization_release_add_conflict' }
}
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $backupFiles 'manifest.json')
$applied = [Collections.Generic.List[object]]::new()
$status = 'failed_before_apply'
try {
    $status = 'applying'
    foreach ($row in $manifest.changes) {
        Assert-Cold
        Replace-Pinned (Join-Path $candidate $row.relativePath) (Target $row.relativePath) $row.before $row.after
        $applied.Add($row)
    }
    foreach ($row in $manifest.changes) { if ((Pin (Target $row.relativePath)) -cne $row.after) { throw 'stabilization_release_final_drift' } }
    Assert-Cold
    Assert-NllPackageTree (Join-Path $install 'postgresql/data') @($coldTree)
    $status = 'installed_manual_acceptance_pending'
}
catch {
    $status = 'rollback_unproven'
    Assert-Cold
    # Roll back only the exact changes successfully applied by this attempt.
    for ($index = $applied.Count - 1; $index -ge 0; $index--) {
        $row = $applied[$index]; $path = Target $row.relativePath
        if ($row.before) { Replace-Pinned (Join-Path $backupFiles $row.relativePath) $path $row.after $row.before }
        else {
            if ((Pin $path) -cne $row.after) { throw 'stabilization_release_rollback_drift' }
            Remove-Item -LiteralPath $path
        }
    }
    $status = 'failed_app_files_rolled_back'
    throw
}
finally {
    Write-AtomicJson (Join-Path $package 'deployment.receipt.json') ([ordered]@{
        contractId='nll/stabilization-app-deployment/v1'; packageUid=$PackageUid; manifestSha256=$ManifestSha256
        status=$status; sourceHead=$manifest.sourceHead; auditUid=$AuditUid; verificationUid=$VerificationUid; changedFiles=$applied.Count
        operationalDatabaseModified=$false; gameExecuted=$false; gameRuntimeModified=$false
        installedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    })
}
Write-Output $status
