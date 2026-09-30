$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test-nll-phase-d-runner-contract.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
$original=$spec; $count=0
try {
    foreach ($build in @('build_151.8.5','build_152.8.11')) {
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
"Runner dependencies: $count build/variant/hash checks passed; no transport or registry access."
