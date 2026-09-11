[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MaterializerRoot,
    [Parameter(Mandatory)][string]$ServerAssembly,
    [ValidateRange(6,99)][int]$Revision=6
)
# Stage a new immutable sibling; never activate, launch, or touch a client/DB.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRuntimeBundle.ps1')
$repo=Split-Path -Parent $PSScriptRoot
$selection='C:\NLL\ControlCenter\runtime-selection.private.json'
$parent=Read-PdRuntimeBundle $selection -FilePinsOnly
Assert-Rn ($null -ne $parent) 'persistence_parent_missing'
$oldRoot=Split-Path -Parent $parent.manifestPath
$root='C:\NLL\Runtime\PhaseD151-v'+$Revision
Assert-Rn ($oldRoot -cne $root) 'persistence_parent_equals_target'
Assert-RnPath $MaterializerRoot
Assert-RnPath $ServerAssembly
$runtime=Get-Content -LiteralPath (Join-Path $MaterializerRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json') -Raw | ConvertFrom-Json
Assert-Rn (@($runtime.runtimeOptions.frameworks.name) -ccontains 'Microsoft.AspNetCore.App') 'persistence_framework_missing'
$sourceRoot=Join-Path $repo '.external/EpinelPS-151-candidate'
$patchRows=@(Import-Csv -LiteralPath (Join-Path $repo 'patches/epinel-runtime-persistence.manifest.tsv') -Delimiter "`t")
foreach($row in $patchRows){
    Assert-Rn ($row.relative_path -match '^EpinelPS/|^tests/' -and -not $row.relative_path.Contains('..')) 'persistence_source_path_invalid'
    $text=[IO.File]::ReadAllText((Join-Path $sourceRoot $row.relative_path)).Replace("`r`n","`n")
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
    Assert-Rn ($hash -ceq $row.candidate_lf_sha256) 'persistence_source_drift'
}
New-RnPrivateDirectory $root
foreach($pin in $parent.files){
    Assert-Rn ($pin.path.StartsWith($oldRoot+'\',[StringComparison]::OrdinalIgnoreCase)) 'persistence_parent_file_outside'
    $relative=[IO.Path]::GetRelativePath($oldRoot,$pin.path)
    Assert-Rn ($relative -notmatch '(^|[\\/])db\.json$|\.sqlite[0-9]*$') 'persistence_database_copy_rejected'
    $dest=Join-Path $root $relative
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
    Copy-Item -LiteralPath $pin.path -Destination $dest
    Assert-Rn ((Get-RnHash $dest) -ceq $pin.sha256) 'persistence_parent_copy_drift'
}
Copy-Item -LiteralPath $ServerAssembly -Destination (Join-Path $root 'server/EpinelPS.dll') -Force
foreach($leaf in @('NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll','NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json','NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')){
    Copy-Item -LiteralPath (Join-Path $MaterializerRoot $leaf) -Destination (Join-Path $root ('materializer/'+$leaf)) -Force
    Assert-Rn ((Get-RnHash (Join-Path $root ('materializer/'+$leaf))) -ceq (Get-RnHash (Join-Path $MaterializerRoot $leaf))) 'persistence_materializer_copy_drift'
}
# Retain earlier source pins; update only the reviewed persistence patch set.
$sourceRows=[ordered]@{}
foreach($line in Get-Content -LiteralPath $parent.serverSourceManifest.path){
    $parts=$line.Split("`t"); Assert-Rn ($parts.Count -eq 3) 'persistence_parent_source_shape'
    $sourceRows[$parts[0]]=$line
}
foreach($row in $patchRows){
    $path=Join-Path $sourceRoot $row.relative_path
    $sourceRows[$row.relative_path]=$row.relative_path+"`t"+(Get-Item -LiteralPath $path).Length+"`t"+(Get-RnHash $path)
}
$sourceManifest=Join-Path $root 'server-source.manifest.tsv'
[IO.File]::WriteAllText($sourceManifest,(($sourceRows.Values | Sort-Object)-join "`n")+"`n",[Text.UTF8Encoding]::new($false))
# Remap only old bundle paths. Client and existing isolation pins remain exact.
$raw=[IO.File]::ReadAllText($parent.manifestPath)
$raw=$raw.Replace($oldRoot.Replace('\','\\'),$root.Replace('\','\\'))
$bundle=$raw | ConvertFrom-Json
$bundle.files=@(Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName | ForEach-Object { Get-RnPin $_.FullName })
$bundle.serverDll=Get-RnPin (Join-Path $root 'server/EpinelPS.dll')
$bundle.serverSourceManifest=Get-RnPin $sourceManifest
$bundle.nativeGameplayValidated=$false
$bundle | Add-Member -NotePropertyName runtimePersistenceContractId -NotePropertyValue 'nll/runtime-persistence/v2' -Force
$bundle | Add-Member -NotePropertyName parentManifest -NotePropertyValue (Get-RnPin $parent.manifestPath) -Force
Write-RnNewJson (Join-Path $root 'bundle.private.json') $bundle
$pointer=[ordered]@{contractId='nll/phase-d-runtime-selection/v1';manifest=Get-RnPin (Join-Path $root 'bundle.private.json')}
$probe=Join-Path $root 'selection.probe.private.json'
Write-RnNewJson $probe $pointer
$null=Read-PdRuntimeBundle $probe -FilePinsOnly
$null=Read-PdRuntimeBundle $selection -FilePinsOnly
[ordered]@{status='persistence_bundle_staged_not_activated';manifest=$pointer.manifest;clientChanged=$false;databaseChanged=$false;gameExecuted=$false} | ConvertTo-Json -Depth 5
