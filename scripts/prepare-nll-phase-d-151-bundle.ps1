[CmdletBinding()]
param([switch]$Stage, [ValidateRange(1,99)] [int]$Revision = 2)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$repo = 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab'
$root = 'C:\NLL\Runtime\PhaseD151-v' + $Revision
$reference = 'C:\NLL\Staging\ResourceProbeRuns\6cebd498-5b56-4eb5-95cd-488e40de418d'
$plan = Read-RnJson (Join-Path $reference 'native.private.json') '73e43f1cf7453c2e4b6f13c7928c800bfacdf6ea54a34e62851d3e33e9ea1aa2'
$serverPlan = Read-RnJson (Join-Path $plan.serverRoot 'resource-probe-runtime.private.json') $plan.serverPlanSha256
$seed = 'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9\db.json'
Assert-Rn ((Get-RnHash $seed) -ceq 'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019') 'phase_d_seed_drift'
$materializerSource = Join-Path $repo 'artifacts\phase-d\runtime-materializer-151'
$bootstrapSource = Join-Path $repo 'artifacts\phase-d\physical-bootstrap-151'
$client = Join-Path $plan.clientRoot 'NIKKE\game\nikke.exe'
Assert-Rn ((Get-RnHash $client) -ceq '36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732') 'phase_d_client_drift'
foreach ($file in $serverPlan.files) {
    Assert-RnPin ([pscustomobject]@{path=(Join-Path $plan.serverRoot $file.path);length=$file.length;sha256=$file.sha256})
}
foreach ($leaf in @('NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll','NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json','NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')) {
    Assert-Rn (Test-Path -LiteralPath (Join-Path $materializerSource $leaf)) 'phase_d_materializer_missing'
}
Assert-Rn (Test-Path -LiteralPath (Join-Path $bootstrapSource 'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll')) 'phase_d_bootstrap_missing'
$materializerRuntime = Get-Content -LiteralPath (Join-Path $materializerSource 'NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json') -Raw | ConvertFrom-Json
Assert-Rn ($null -ne $materializerRuntime.runtimeOptions.PSObject.Properties['frameworks']) 'phase_d_materializer_must_use_installed_framework'
Assert-Rn (@($materializerRuntime.runtimeOptions.frameworks.name) -ccontains 'Microsoft.AspNetCore.App') 'phase_d_materializer_web_dependencies_missing'
if (-not $Stage) { '{"status":"bundle_inputs_verified_not_staged"}'; return }
New-RnPrivateDirectory $root
$server = Join-Path $root 'server'
$bootstrapRoot = Join-Path $root 'bootstrap'
$bootstrapArtifact = Join-Path $bootstrapRoot 'artifact'
$materializer = Join-Path $root 'materializer'
foreach ($dir in @($server,$bootstrapRoot,$bootstrapArtifact,$materializer,(Join-Path $root 'overlay'))) { New-RnPrivateDirectory $dir }
foreach ($file in $serverPlan.files) {
    $dest = Join-Path $server $file.path
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $plan.serverRoot $file.path) -Destination $dest
    Assert-RnPin ([pscustomobject]@{path=$dest;length=$file.length;sha256=$file.sha256})
}
# Do NOT copy the successful probe's db.json/SQLite database or its credentials.
# The coordinator uses its existing selected-account materialization instead.
$legacyCache = Get-Item -LiteralPath 'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9\cache' -Force
$legacyCacheRoot = [string]@($legacyCache.Target)[0]
$legacyFiles = @(Get-ChildItem -LiteralPath $legacyCacheRoot -Recurse -File)
$registry = Get-Content -LiteralPath (Join-Path $repo 'config\boss-runtime-variants\registry.json') -Raw | ConvertFrom-Json
$assetPins = @()
foreach ($entry in $registry.profiles) {
    $profile = Get-Content -LiteralPath (Join-Path (Join-Path $repo 'config\boss-runtime-variants') $entry.profileRelativePath) -Raw | ConvertFrom-Json
    if ($null -ne $profile.PSObject.Properties['behaviorAssembly']) {
        $assetPins += [pscustomobject]@{sha256=$profile.behaviorAssembly.bundleSha256;byteLength=$profile.behaviorAssembly.bundleByteLength}
    }
    if ($null -ne $profile.elementShield.PSObject.Properties['fxVariants']) {
      foreach ($variant in $profile.elementShield.fxVariants) {
          foreach ($mapping in $variant.mappings) { $assetPins += @($mapping.assetBundles) }
      }
    }
}
foreach ($asset in $assetPins | Group-Object sha256 | ForEach-Object { $_.Group[0] }) {
    $match = @($legacyFiles | Where-Object Length -EQ $asset.byteLength | Where-Object { (Get-RnHash $_.FullName) -ceq $asset.sha256 })
    Assert-Rn ($match.Count -gt 0) 'phase_d_existing_boss_asset_missing'
    # Preserve the exact old cache-relative key; static pack and version header
    # remain 151. This copies only named boss/FX dependencies, not the old cache.
    foreach ($source in $match) {
        $relative = [IO.Path]::GetRelativePath($legacyCacheRoot, $source.FullName)
        $dest = Join-Path (Join-Path $server 'cache') $relative
        Assert-Rn (-not (Test-Path -LiteralPath $dest)) 'phase_d_asset_collision'
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath $source.FullName -Destination $dest
        Assert-Rn ((Get-RnHash $dest) -ceq $asset.sha256) 'phase_d_asset_copy_drift'
    }
}
foreach ($file in Get-ChildItem -LiteralPath $bootstrapSource -File | Where-Object Extension -In '.exe','.dll','.json') {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $bootstrapArtifact $file.Name)
}
Copy-Item -LiteralPath 'C:\NLL\Runtime\PhysicalBootstrap-v2\artifact\sail_api_impl64.dll' -Destination (Join-Path $bootstrapArtifact 'sail_api_impl64.dll')
foreach ($leaf in @('NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll','NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json','NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')) {
    Copy-Item -LiteralPath (Join-Path $materializerSource $leaf) -Destination (Join-Path $materializer $leaf)
}
$overlay = @()
foreach ($change in $plan.fileChanges | Where-Object { $_.before.path.StartsWith($plan.clientRoot + '\', [StringComparison]::OrdinalIgnoreCase) }) {
    Assert-RnPin $change.before
    Assert-RnPin $change.replacement
    $leaf = Split-Path -Leaf $change.before.path
    $backup = Join-Path $root ('overlay\' + $leaf + '.original')
    $replacement = Join-Path $root ('overlay\' + $leaf + '.replacement')
    Copy-Item -LiteralPath $change.before.path -Destination $backup
    Copy-Item -LiteralPath $change.replacement.path -Destination $replacement
    $overlay += [ordered]@{before=$change.before;backup=(Get-RnPin $backup);replacement=(Get-RnPin $replacement)}
}
Assert-Rn ($overlay.Count -eq 2) 'phase_d_overlay_invalid'
$programs = @($plan.programs | Where-Object { $_.path.StartsWith($plan.clientRoot + '\', [StringComparison]::OrdinalIgnoreCase) })
$blockOnly = @(Get-RnBlockOnlyProgramPaths)
$sourceManifest = Join-Path $root 'server-source.manifest.tsv'
$sourceLines = @(Get-Content -LiteralPath (Join-Path $repo 'scripts\phase-d-weakness-variant-v10.source.manifest.tsv') | ForEach-Object {
    $name = ($_ -split "`t")[0]
    $source = Join-Path (Join-Path $repo '.external\EpinelPS-151-candidate') $name
    $name + "`t" + (Get-Item -LiteralPath $source).Length + "`t" + (Get-RnHash $source)
})
Write-RnNewBytes $sourceManifest ([Text.Encoding]::UTF8.GetBytes(($sourceLines -join "`n") + "`n"))
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {Get-RnPin $_.FullName})
$native = Get-RnPin ($overlay | Where-Object {$_.before.path.EndsWith('\sodium.dll')}).replacement.path
$native.path = ($overlay | Where-Object {$_.before.path.EndsWith('\sodium.dll')}).before.path
$certificate = Get-RnPin ($overlay | Where-Object {$_.before.path.EndsWith('\intl_cacert.pem')}).replacement.path
$certificate.path = ($overlay | Where-Object {$_.before.path.EndsWith('\intl_cacert.pem')}).before.path
$bundle = [ordered]@{contractId='nll/phase-d-runtime-bundle/v1';clientBuildCode='build_151.8.5';
    serverRoot=$server;bootstrapRoot=$bootstrapRoot;materializerRoot=$materializer;
    referenceAssessmentUid=$plan.assessmentUid;client=(Get-RnPin $client);native=$native;certificate=$certificate;
    serverExe=(Get-RnPin (Join-Path $server 'EpinelPS.exe'));serverDll=(Get-RnPin (Join-Path $server 'EpinelPS.dll'));
    serverSourceManifest=(Get-RnPin $sourceManifest);
    bootstrap=(Get-RnPin (Join-Path $bootstrapArtifact 'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'));
    files=$files;overlay=$overlay;clientPrograms=$programs;blockOnlyPrograms=$blockOnly;
    preserveExistingAccount=$true;syntheticRegistration=$false;httpDiagnosticLayer=$false;
    progressionSourceSha256=(Get-RnHash $seed);nativeGameplayValidated=$false}
Write-RnNewJson (Join-Path $root 'bundle.private.json') $bundle
[ordered]@{status='bundle_staged_not_activated';manifest=Get-RnPin (Join-Path $root 'bundle.private.json');productionDbChanged=$false;clientChanged=$false;clientStarted=$false} | ConvertTo-Json -Depth 4
