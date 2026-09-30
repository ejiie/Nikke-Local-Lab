$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test-nll-phase-d-runner-contract.ps1') # supplies synthetic $spec and assertion helper
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
function Write-TestJson($Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10)) }
function Pin-TestBundle {
    $manifestHash = Get-PhaseDRunnerHash $bundle.manifestPath
    [IO.File]::WriteAllText($toolPath, "role_code`tbyte_length`tsha256`nrunner_bundle`t1`t$manifestHash`n")
    Write-TestJson $contextPath ([ordered]@{ contractId='nll/launch-context/v1'; launchContextUid=$id; toolManifestSha256=(Get-PhaseDRunnerHash $toolPath) })
}
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $_.Exception.Message -eq 'phase_d_runner_bundle_invalid' }
    Assert-Test $rejected
}
$count = 0
try {
    $runtimeRoot = Join-Path $spec.launchRoot 'runtime'
    $sourceRoot = Join-Path $root 'source'
    $null = New-Item -ItemType Directory -Path $runtimeRoot, $sourceRoot
    foreach ($name in Get-PhaseDRunnerCodeMembers) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $sourceRoot }
    $spec.runtimeMaterializer = Join-Path $runtimeRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
    [IO.File]::WriteAllText($spec.bossRuntimeVariantProfile,'{"synthetic":true}')
    $spec.bossRuntimeVariantProfileSha256=Get-PhaseDRunnerHash $spec.bossRuntimeVariantProfile
    foreach ($name in @('EpinelPS.dll','NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll')) {
        [IO.File]::WriteAllText((Join-Path $runtimeRoot $name), 'synthetic-not-executable')
    }
    $bundle = New-PhaseDRunnerBundle $spec $sourceRoot
    $toolPath = Join-Path $spec.launchRoot 'tool.manifest.tsv'
    $contextPath = Join-Path $spec.launchRoot 'launch-context.json'
    Pin-TestBundle
    $read = Read-PhaseDRunnerBundle $spec.launchRoot
    Assert-Test ($read.sha256 -ceq $bundle.sha256); $count++
    # Modifying the repository AFTER sealing cannot change the active run's code.
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'Nll.PhaseDRunnerStart.ps1'), 'throw "unpublished-next-version"')
    Assert-Test ((Read-PhaseDRunnerBundle $spec.launchRoot).sha256 -ceq $bundle.sha256); $count++
    foreach ($name in @('runner.input.json','runner.profile.json') + @(Get-PhaseDRunnerCodeMembers)) {
        $path = Join-Path $bundle.root $name
        $before = [IO.File]::ReadAllBytes($path)
        [IO.File]::WriteAllText($path, 'tampered')
        Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
        [IO.File]::WriteAllBytes($path, $before)
    }
    foreach ($file in Get-PhaseDRunnerRuntimeCode $spec.launchRoot) {
        $before = [IO.File]::ReadAllBytes($file.FullName)
        [IO.File]::WriteAllText($file.FullName, 'changed')
        Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
        [IO.File]::WriteAllBytes($file.FullName, $before)
    }
    $extra = Join-Path $runtimeRoot 'unexpected.dll'
    [IO.File]::WriteAllText($extra, 'extra')
    Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
    Remove-Item -LiteralPath $extra
    # Even a correctly re-hashed manifest cannot authorize path traversal, missing
    # or duplicate code members, an unknown engine, or a different execution.
    $originalManifest = [IO.File]::ReadAllBytes($bundle.manifestPath)
    foreach ($mutation in @(
        {param($m) $m.members[0].name='../escape.ps1'},
        {param($m) $m.members[0].name=$m.members[1].name},
        {param($m) $m.members=@($m.members | Select-Object -Skip 1)},
        {param($m) $m.engineCode='unknown/v2'},
        {param($m) $m.launchContextUid='different'},
        {param($m) $m.runtimeCode[0].name='../escape.dll'},
        {param($m) $m.runtimeCode[0].name=$m.runtimeCode[1].name}
    )) {
        $manifest = [Text.Encoding]::UTF8.GetString($originalManifest) | ConvertFrom-Json
        & $mutation $manifest
        Write-TestJson $bundle.manifestPath $manifest
        Pin-TestBundle
        Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
        [IO.File]::WriteAllBytes($bundle.manifestPath, $originalManifest)
    }
    Pin-TestBundle
    Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot ('0' * 64) }; $count++
    # Entry rejects a bad pin before importing any module or doing runtime work.
    $failed = $false
    try { & (Join-Path $bundle.root 'invoke-nll-phase-d-runner.ps1') -Phase start -LaunchRoot $spec.launchRoot -ExpectedBundleSha256 ('0' * 64) }
    catch { $failed = $_.Exception.Message -ceq 'phase_d_runner_bundle_invalid' }
    Assert-Test $failed; $count++
    [IO.File]::WriteAllText($toolPath, 'invalid')
    Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
    Assert-Test ($null -eq (Read-PhaseDRunnerBundle (Join-Path $root 'legacy-run'))); $count++
}
finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-runner-contract-*') { throw 'unsafe_test_cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
"Runner seal: $count closure, drift, version, no-fallback and pre-import rejection checks passed; synthetic files only."
