[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$PackageUid,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [ValidateRange(6,99)][int]$Revision=6
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRuntimeBundle.ps1')
. (Join-Path $PSScriptRoot 'Nll.OfflinePackage.ps1')
$repo=Split-Path -Parent $PSScriptRoot
$install='C:\NLL\ControlCenter'
$selection=Join-Path $install 'runtime-selection.private.json'
function Assert-Cold {
    Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(postgres|pg_ctl|nikke|EpinelPS|NLL Control Center|NikkeLocalLab.*)\.exe$' -or
        $_.CommandLine -match 'NikkeLocalLab.Admin.Api.dll|watch-nll-phase-d-execution.ps1|invoke-nll-phase-d-execution.ps1|Start-NLL-ControlCenter.ps1'
    }).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $install 'postgresql/data/postmaster.pid'))) 'persistence_activation_not_cold'
}
Assert-Cold
$package=Join-Path $repo ('artifacts/stabilization/release/'+$PackageUid)
$deployment=Get-Content -LiteralPath (Join-Path $package 'deployment.receipt.json') -Raw | ConvertFrom-Json
Assert-Rn ($deployment.status -ceq 'installed_manual_acceptance_pending' -and $deployment.packageUid -ceq $PackageUid -and $deployment.sourceHead -ceq (& git -C $repo rev-parse HEAD).Trim()) 'persistence_app_release_required'
Assert-Rn (@(& git -C $repo status --porcelain).Count -eq 0) 'persistence_source_not_committed'
$manifest=Read-RnJson (Join-Path $package 'manifest.json') $deployment.manifestSha256
Assert-Rn ($manifest.schemaVersion -eq 21) 'persistence_schema_release_invalid'
foreach($row in $manifest.changes){Assert-Rn ((Get-RnHash (Join-Path $install $row.relativePath)) -ceq $row.after) 'persistence_app_drift'}
$backup='D:\NikkeLocalLab\Backups\stabilization-audit-'+$deployment.auditUid
$tree=@(Get-Content -LiteralPath (Join-Path $backup 'cold-data.manifest.private.json') -Raw | ConvertFrom-Json)
Assert-NllPackageTree (Join-Path $install 'postgresql/data') $tree
Assert-NllPackageTree (Join-Path $backup 'cold-data') $tree
$before=Get-RnPin $selection
$old=Read-PdRuntimeBundle $selection
$root='C:\NLL\Runtime\PhaseD151-v'+$Revision
$bundlePath=Join-Path $root 'bundle.private.json'
Assert-Rn ((Get-RnHash $bundlePath) -ceq $ExpectedBundleSha256) 'persistence_candidate_drift'
$candidate=Read-PdRuntimeBundle (Join-Path $root 'selection.probe.private.json')
Assert-Rn ($candidate.runtimePersistenceContractId -ceq 'nll/runtime-persistence/v2' -and $candidate.parentManifest.path -ceq $old.manifestPath -and $candidate.parentManifest.sha256 -ceq (Get-RnHash $old.manifestPath)) 'persistence_parent_changed'
$saved=Join-Path $backup ('runtime-selection-before-'+$PackageUid+'.private.json')
Assert-Rn (-not (Test-Path -LiteralPath $saved)) 'persistence_activation_already_attempted'
Copy-Item -LiteralPath $selection -Destination $saved
Assert-Rn ((Get-RnHash $saved) -ceq $before.sha256) 'persistence_selection_backup_drift'
$partial=$selection+'.persistence-'+[guid]::NewGuid().ToString('N')
$status='not_activated'
try{
    Write-RnNewJson $partial ([ordered]@{contractId='nll/phase-d-runtime-selection/v1';manifest=Get-RnPin $bundlePath})
    Assert-Cold
    Assert-RnPin $before
    [IO.File]::Replace($partial,$selection,[NullString]::Value)
    $status='activated_verification_pending'
    $null=Read-PdRuntimeBundle $selection
    Assert-Cold
    Assert-NllPackageTree (Join-Path $install 'postgresql/data') $tree
    $status='installed_manual_acceptance_pending'
}finally{
    if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial}
    Write-RnNewJson (Join-Path $package 'runtime-activation.receipt.json') ([ordered]@{
        contractId='nll/runtime-persistence-activation/v1';status=$status;packageUid=$PackageUid
        before=$before;after=Get-RnPin $selection;bundleSha256=$ExpectedBundleSha256
        backupPath=$saved;oldRuntimePreserved=$true;clientChanged=$false;gameExecuted=$false
        databaseChanged=$false;firewallChanged=$false;trustStoreChanged=$false
    })
}
Write-Output $status
