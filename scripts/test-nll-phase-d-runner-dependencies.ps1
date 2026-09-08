$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test-nll-phase-d-runner-contract.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
. (Join-Path $PSScriptRoot 'Nll.ResourcePreflight.ps1')
$original=$spec; $count=0
try {
    foreach ($build in @('build_150.6.9','build_151.8.5')) {
      foreach ($variant in @($false,$true)) {
        $caseRoot=Join-Path $root "$build-$variant"
        $null=New-Item -ItemType Directory -Path $caseRoot
        $spec=[ordered]@{}; foreach ($key in $original.Keys) { $spec[$key]=$original[$key] }
        $spec.launchRoot=Join-Path $caseRoot $id
        $null=New-Item -ItemType Directory -Path $spec.launchRoot
        $spec.bossRuntimeVariantProfile=Join-Path $caseRoot 'profile.json'
        [IO.File]::WriteAllText($spec.bossRuntimeVariantProfile,'{}')
        $spec.bossRuntimeVariantProfileSha256=Get-PhaseDRunnerHash $spec.bossRuntimeVariantProfile
        $sourcePath=Join-Path $spec.launchRoot 'source.manifest.tsv'
        [IO.File]::WriteAllText($sourcePath,'synthetic-source')
        $spec.derivedSourceManifestSha256=Get-PhaseDRunnerHash $sourcePath
        $spec.staticDataVariantRequired=$variant
        $pinnedPaths=@($sourcePath,$spec.bossRuntimeVariantProfile)
        if ($variant) {
            $spec.variantStaticDataPack=Join-Path $caseRoot 'synthetic.pack'
            [IO.File]::WriteAllText($spec.variantStaticDataPack,'synthetic-not-game-data')
            $spec.variantStaticDataSha256=Get-PhaseDRunnerHash $spec.variantStaticDataPack
            $pinnedPaths+=$spec.variantStaticDataPack
        }
        $spec.clientBuildCode=$build
        $spec.resourcePreflightRequired=$build -ceq 'build_150.6.9'
        if ($spec.resourcePreflightRequired) {
            $spec.resourcePreflightHelper=Join-Path $caseRoot 'Nll.ResourcePreflight.ps1'
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Nll.ResourcePreflight.ps1') -Destination $spec.resourcePreflightHelper
            $spec.resourcePreflightHelperSha256=Get-PhaseDRunnerHash $spec.resourcePreflightHelper
            $toolRoot=Join-Path $caseRoot 'tool'; $null=New-Item -ItemType Directory -Path $toolRoot
            foreach ($name in @('tool.exe','tool.dll','a.dll','b.dll','tool.deps.json','tool.runtimeconfig.json')) {
                [IO.File]::WriteAllText((Join-Path $toolRoot $name),'not-executable')
            }
            $spec.resourcePreflightTool=Join-Path $toolRoot 'tool.exe'
            $spec.resourcePreflightToolSha256=Get-NllResourcePreflightToolSetSha256 $spec.resourcePreflightTool
            Assert-Test ($spec.resourcePreflightToolSha256 -cne (Get-PhaseDRunnerHash $spec.resourcePreflightTool))
            $spec.resourceCatalogReceiptPath=Join-Path $caseRoot 'catalog.receipt.json'
            [IO.File]::WriteAllText($spec.resourceCatalogReceiptPath,'{}')
            $spec.resourceCatalogReceiptSha256=Get-PhaseDRunnerHash $spec.resourceCatalogReceiptPath
            $pinnedPaths+=@($spec.resourcePreflightHelper,$spec.resourceCatalogReceiptPath,(Join-Path $toolRoot 'a.dll'))
        }
        Assert-PhaseDRunnerStartDependencies $spec; $count++
        foreach ($path in $pinnedPaths) {
            $before=[IO.File]::ReadAllBytes($path)
            [IO.File]::WriteAllText($path,'changed')
            $rejected=$false
            try { Assert-PhaseDRunnerStartDependencies $spec } catch { $rejected=$_.Exception.Message -ceq 'phase_d_runner_dependency_drifted' }
            Assert-Test $rejected; $count++
            [IO.File]::WriteAllBytes($path,$before)
        }
      }
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-runner-contract-*') { throw 'unsafe_test_cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
"Runner dependencies: $count build/variant/hash/tool-set checks passed; no transport or registry access."
