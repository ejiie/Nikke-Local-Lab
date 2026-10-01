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
    foreach ($name in Get-PhaseDRunnerCodeMembers -Version 2) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $sourceRoot }
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
    foreach ($name in @('runner.input.json','runner.profile.json') + @(Get-PhaseDRunnerCodeMembers -Version 2)) {
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
    # Historical input shapes are interpreted by their own sealed closure, before
    # current v3-only validation. Execute just the real dispatch prefix, never recovery.
    $tokens=$null; $errors=$null
    $recoveryAst=[Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'recover-nll-phase-d-orphaned-execution.ps1'),[ref]$tokens,[ref]$errors)
    Assert-Test ($errors.Count -eq 0)
    $statements=@($recoveryAst.EndBlock.Statements)
    $begin=@($statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -ceq '$recoveryBundle' })[0].Extent.StartOffset
    $end=@($statements | Where-Object { $_.Extent.Text -ceq ". (Join-Path `$PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')" })[0].Extent.StartOffset
    $testScriptsRoot=$PSScriptRoot
    $dispatch=[scriptblock]::Create('$PSScriptRoot=$testScriptsRoot;' + $recoveryAst.Extent.Text.Substring($begin,$end-$begin))
    $ExecutionRoot=Split-Path -Parent $spec.launchRoot; $LaunchContextUid=$id; $ConfigurationPath='synthetic-config'
    $historicalEntry=Join-Path $bundle.root 'recover-nll-phase-d-orphaned-execution.ps1'
    [IO.File]::WriteAllText($historicalEntry, 'param($ExecutionRoot,$LaunchContextUid,$ConfigurationPath) $global:phaseDDispatch=@($ExecutionRoot,$LaunchContextUid,$ConfigurationPath)')
    foreach ($oldVersion in @(1,2,3,4)) {
        $oldSpec=$spec | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $oldSpec.contractId='nll/phase-d-runner-input/v'+[Math]::Min($oldVersion,3)
        if ($oldVersion -lt 3) { $oldSpec.PSObject.Properties.Remove('jobNonce'); $oldSpec.PSObject.Properties.Remove('executionFx') }
        if ($oldVersion -eq 1) { $oldSpec.PSObject.Properties.Remove('weaknessCode') }
        if ($oldVersion -lt 4) { $oldSpec | Add-Member resourcePreflightRequired $false }
        Write-TestJson (Join-Path $bundle.root 'runner.input.json') $oldSpec
        $oldManifest=[Text.Encoding]::UTF8.GetString($originalManifest) | ConvertFrom-Json
        $bundleVersion=if ($oldVersion -lt 3) {1} else {2}
        $oldManifest.contractId='nll/phase-d-runner-bundle/v'+$bundleVersion
        $members=@(Get-PhaseDRunnerCodeMembers -Version $bundleVersion)+@('runner.input.json','runner.profile.json')
        $oldManifest.members=@($oldManifest.members | Where-Object { $_.name -cin $members })
        foreach ($member in $oldManifest.members) { $member.sha256=Get-PhaseDRunnerHash (Join-Path $bundle.root $member.name) }
        Write-TestJson $bundle.manifestPath $oldManifest
        Pin-TestBundle
        $global:phaseDDispatch=$null
        & $dispatch
        if ($oldVersion -lt 4) {
            Assert-Test (($global:phaseDDispatch -join '|') -ceq (@($ExecutionRoot,$id,$ConfigurationPath) -join '|'))
        } else {
            Assert-Test ($null -eq $global:phaseDDispatch -and $script:PhaseDVerifiedRunnerBundle.sha256 -ceq (Get-PhaseDRunnerHash $bundle.manifestPath))
        }
        $count++
    }
    $LaunchContextUid='44444444-4444-4444-8444-444444444444'
    $global:phaseDDispatch=$null; $rejected=$false
    try { & $dispatch } catch { $rejected=$_.Exception.Message -ceq 'phase_d_runner_binding_missing' }
    Assert-Test ($rejected -and $null -eq $global:phaseDDispatch); $count++
    Remove-Variable phaseDDispatch -Scope Global
    [IO.File]::WriteAllText($toolPath, 'invalid')
    Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
    Assert-Test ($null -eq (Read-PhaseDRunnerBundle (Join-Path $root 'legacy-run'))); $count++
    # Real NTFS links and copies, synthetic bytes only. Exercise the coordinator's
    # staging helper and both sides of the seal without starting any process.
    . (Join-Path $PSScriptRoot 'Nll.PhaseDRuntimeBundle.ps1')
    $server = Join-Path $root 'installed server'
    $null = New-Item -ItemType Directory -Path $server
    $immutable = @('EpinelPS.exe','library.dll','EpinelPS.deps.json','EpinelPS.runtimeconfig.json')
    $copied = @('EpinelPS.dll','gameconfig.json','appsettings.json','site.pfx',
        'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll',
        'NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json','NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json',
        'static-data-variant/StaticData.pack','execution-fx/retired.json','nested/library.dll','unsealed.dll')
    $generated = @('db.json','epinelps.db','epinelps.db-shm','epinelps.db-wal','logs/app-test.log')
    $snapshots = @{}
    foreach ($name in $immutable + $copied + $generated + @('cache/sentinel')) {
        $path = Join-Path $server $name
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        [IO.File]::WriteAllText($path, 'synthetic:'+$name)
        $snapshots[$name] = [pscustomobject]@{path=$path;length=(Get-Item $path).Length;sha256=(Get-PhaseDRunnerHash $path);attributes=(Get-Item $path).Attributes}
    }
    $installed = [pscustomobject]@{serverRoot=$server;files=@($snapshots.Values | Where-Object { (Split-Path -Leaf $_.path) -ne 'unsealed.dll' })}
    $id = '55555555-5555-4555-8555-555555555555'
    $spec.launchContextUid=$id; $spec.launchRoot=Join-Path $root $id
    $runtimeRoot=Join-Path $spec.launchRoot 'runtime'
    $linked=Copy-PdRuntimeFiles $installed $runtimeRoot (Join-Path $root 'copy.log')
    Assert-Test ($linked.Count -eq $immutable.Count); $count++
    foreach ($name in $immutable) {
        Assert-Test (Test-PhaseDRunnerHardlink (Join-Path $runtimeRoot $name) $snapshots[$name].path $snapshots[$name].length); $count++
    }
    foreach ($name in $copied) {
        $path=Join-Path $runtimeRoot $name
        Assert-Test ((Get-PhaseDRunnerHash $path) -ceq $snapshots[$name].sha256 -and
            -not (Test-PhaseDRunnerHardlink $path $snapshots[$name].path $snapshots[$name].length)); $count++
        # Includes the variant DLL overwrite, config saves and FX retirement.
        [IO.File]::WriteAllText($path, 'execution-only mutation')
    }
    Assert-Test (-not (Test-Path (Join-Path $runtimeRoot 'cache'))); $count++
    foreach ($name in $generated) {
        $path=Join-Path $runtimeRoot $name
        Assert-Test (-not (Test-Path $path)); $count++
        $null=New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        [IO.File]::WriteAllText($path, 'materialized database or log')
        Assert-Test (-not (Test-PhaseDRunnerHardlink $path $snapshots[$name].path $snapshots[$name].length)); $count++
        [IO.File]::WriteAllText($path, 'restored baseline')
        Remove-Item -LiteralPath $path -Force
    }
    # Force an actual link-creation failure: an excluded destination already exists.
    # The existing bytes must survive, rather than a silent fallback copy.
    $collision=Join-Path $root 'collision'
    $null=New-Item -ItemType Directory -Path $collision
    [IO.File]::WriteAllText((Join-Path $collision 'library.dll'), 'collision')
    $failed=$false
    try { Copy-PdRuntimeFiles $installed $collision (Join-Path $root 'collision.log') | Out-Null } catch { $failed=$true }
    Assert-Test ($failed -and [IO.File]::ReadAllText((Join-Path $collision 'library.dll')) -ceq 'collision'); $count++

    $spec.runtimeMaterializer=Join-Path $runtimeRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
    [IO.File]::WriteAllText($spec.runtimeMaterializer, 'copied materializer')
    $toolPath=Join-Path $spec.launchRoot 'tool.manifest.tsv'
    $contextPath=Join-Path $spec.launchRoot 'launch-context.json'
    $originalHash=${function:Get-PhaseDRunnerHash}
    $hashReads=[Collections.Generic.List[string]]::new()
    function Get-PhaseDRunnerHash([string]$Path) {
        $hashReads.Add($Path)
        if ((Split-Path -Parent $Path) -eq $runtimeRoot -and (Split-Path -Leaf $Path) -in $immutable) { throw 'linked_code_was_rehashed' }
        & $originalHash $Path
    }
    $bundle=New-PhaseDRunnerBundle $spec $PSScriptRoot -RuntimeCodePins $linked
    Pin-TestBundle
    $null=Read-PhaseDRunnerBundle $spec.launchRoot
    Assert-Test ($hashReads.Contains((Join-Path $runtimeRoot 'EpinelPS.dll')) -and $hashReads.Contains($spec.runtimeMaterializer)); $count++
    $manifest=Get-Content $bundle.manifestPath -Raw | ConvertFrom-Json
    foreach ($member in $manifest.runtimeCode | Where-Object { $_.name -in $immutable }) {
        Assert-Test ($member.sha256 -ceq $linked[$member.name].sha256); $count++
    }
    # Identical bytes in an independent replacement still cannot reuse a source pin.
    $path=Join-Path $runtimeRoot 'library.dll'
    Remove-Item -LiteralPath $path
    Copy-Item -LiteralPath $snapshots['library.dll'].path -Destination $path
    Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
    Remove-Item -LiteralPath $path
    $null=New-Item -ItemType HardLink -Path $path -Target $snapshots['library.dll'].path
    $null=Read-PhaseDRunnerBundle $spec.launchRoot
    # A copied runtime code member still uses the ordinary hash guard.
    [IO.File]::WriteAllText($spec.runtimeMaterializer, 'modified materializer')
    Assert-Rejected { Read-PhaseDRunnerBundle $spec.launchRoot }; $count++
    ${function:Get-PhaseDRunnerHash}=$originalHash

    $deleteRoot=[IO.Path]::GetFullPath($spec.launchRoot)
    if ([IO.Path]::GetDirectoryName($deleteRoot) -ine [IO.Path]::GetFullPath($root)) { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $deleteRoot -Recurse -Force
    foreach ($pin in $snapshots.Values) {
        Assert-Test ((Get-PhaseDRunnerHash $pin.path) -ceq $pin.sha256 -and (Get-Item $pin.path).Attributes -eq $pin.attributes); $count++
    }

}
finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-runner-contract-*') { throw 'unsafe_test_cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
"Runner seal: $count closure, drift, version, no-fallback and pre-import rejection checks passed; synthetic files only."
