param([Parameter(Mandatory)][string]$PlanPath)
# CLIENT_UPDATE steps 6/8a: inputs read from the sealed clone before the bundle is staged.
#  1. catalog tool published into plan.pipelineInputsRoot (against the new server publish and candidate source),
#  2. the four server locale files from the clone's saus catalog (original bytes) into plan.localeStagingRoot,
#  3. the native FX input plan for the clone.
# Writes only those folders; the clone is read, nothing is started.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ClientUpdate.ps1')
$plan = Read-NllClientUpdatePlan $PlanPath
$activation = Get-Content 'C:\NLL\ControlCenter\boss-pipeline.active.json' -Raw | ConvertFrom-Json
$python = [string](Get-Content $activation.configurationPath -Raw | ConvertFrom-Json).pythonPath
$tool = Join-Path $plan.pipelineInputsRoot 'catalog-tool'
$patch = Join-Path $plan.clientRoot 'Unity\com_proximabeta_NIKKE\com.shiftup.patch'
Assert-NllClientUpdate (Test-Path (Join-Path $plan.clientRoot 'NIKKE\game\nikke.exe')) 'clone_missing'

if (-not (Test-Path $tool)) {
    Push-Location (Join-Path $plan.repositoryRoot 'tools\Phase3B2\ResourceCatalogPreflight')
    try {
        & dotnet publish '.\ResourceCatalogPreflight.csproj' -c Release ('-p:EpinelSourceRoot=' + (Join-Path $plan.serverSourceRoot 'EpinelPS')) `
            ('-p:EpinelRuntimeRoot=' + $plan.serverPublishRoot) -o $tool *> (Join-Path $plan.stagingRoot 'catalog-tool-publish.log')
        Assert-NllClientUpdate ($LASTEXITCODE -eq 0) 'catalog_tool_publish_failed'
    } finally { Pop-Location }
    Get-ChildItem $tool -File -Filter '*.pdb' | Remove-Item
}
$toolDll = Join-Path $tool 'ResourceCatalogPreflight.dll'

if (-not (Test-Path $plan.localeStagingRoot)) {
    $saus = Join-Path $patch 'saus'
    & dotnet $toolDll stage-probe-server-locales $saus $plan.localeStagingRoot (Get-NllClientUpdateHash "$saus\catalog.ndb") (Get-NllClientUpdateHash "$saus\catalog.ndb.nds")
    Assert-NllClientUpdate ($LASTEXITCODE -eq 0) 'locale_staging_failed'
}

$nativePlan = Join-Path $plan.pipelineInputsRoot 'native-input-plan.private.json'
if (-not (Test-Path $nativePlan)) {
    & $python -I (Join-Path $PSScriptRoot 'write-nll-native-input-plan.py') $plan.clientRoot $nativePlan
    Assert-NllClientUpdate ($LASTEXITCODE -eq 0) 'native_plan_failed'
}
$index = & dotnet $toolDll inspect-index-digest (Join-Path $patch 'core') | Out-String | ConvertFrom-Json
Assert-NllClientUpdate ($index.indexSha256 -ceq (Get-Content $nativePlan -Raw | ConvertFrom-Json).indexSha256) 'native_plan_index_mismatch'
[ordered]@{ catalogTool = (Get-NllClientUpdateHash $toolDll); localeStagingRoot = $plan.localeStagingRoot
    nativePlan = $nativePlan; nativePlanSha256 = (Get-NllClientUpdateHash $nativePlan); indexMatches = @($index.matches) } | ConvertTo-Json
