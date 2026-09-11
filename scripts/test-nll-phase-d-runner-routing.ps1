# Execute the current coordinator's real data mapping and publication statements
# against synthetic inputs. No parent templates, OS, DB or game are accessed.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test-nll-phase-d-runner-contract.ps1')
function Assert-Route($Value) { if (-not $Value) { throw ('runner_route_test_failed_line_' + $MyInvocation.ScriptLineNumber) } }
$tokens=$null; $errors=$null
$path=Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Route ($errors.Count -eq 0)
$text=$ast.Extent.Text
foreach ($retired in @('parentStart','parentCompletion','New-PhaseDLaunchToolText','Nll.PhaseDLaunchTools.ps1',
    'Start-PhaseD-Derived.ps1','Complete-PhaseD-Derived.ps1','Convert-PdBundleStart','$startText','$completionText')) {
    Assert-Route (-not $text.Contains($retired))
}
$runtimeText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Nll.PhaseDRuntimeBundle.ps1'))
Assert-Route (-not $runtimeText.Contains('Convert-PdBundleStart') -and -not $runtimeText.Contains('.Replace('))
$parameter=@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'RunnerEngine' })[0]
$engineGate=[scriptblock]::Create('param(' + $parameter.Extent.Text + ') $RunnerEngine')
Assert-Route ((& $engineGate) -ceq 'parameterized/v1')
Assert-Route ((& $engineGate -RunnerEngine 'parameterized/v1') -ceq 'parameterized/v1')
foreach ($engine in @('legacy/v1','unknown/v1')) {
    $rejected=$false
    try { $null=& $engineGate -RunnerEngine $engine } catch { $rejected=$_.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*' }
    Assert-Route $rejected
}
$mapping=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -ceq '$runnerLaunchInput'},$true))
$publication=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -ceq '$watcher' -and $n.Right.Extent.Text.Contains('$runnerBundle.root')},$true))
Assert-Route ($mapping.Count -eq 1 -and $publication.Count -eq 1)
$begin=$mapping[0].Extent.StartOffset; $end=$publication[0].Extent.EndOffset
$testScriptsRoot=$PSScriptRoot
$body=[scriptblock]::Create('$PSScriptRoot=$testScriptsRoot;' + $text.Substring($begin,$end-$begin) +
    '; [pscustomobject]@{spec=$runnerSpec;bundle=$runnerBundle;start=$derivedStart;completion=$derivedCompletion;watcher=$watcher}')
$script:bundleCalls=0; $script:rejectBundle=$false
function New-PhaseDRunnerBundle {
    param($Specification,$ScriptsRoot)
    Assert-PhaseDRunnerSpecification $Specification
    Assert-Route ($ScriptsRoot -ceq $testScriptsRoot)
    $script:bundleCalls++
    if ($script:rejectBundle) { throw 'phase_d_runner_bundle_invalid' }
    @{root=(Join-Path $Specification.launchRoot 'tools/runner');sha256=('d'*64)}
}
$count=0
foreach ($build in @('build_150.6.9','build_151.8.5')) {
    foreach ($variant in @($false,$true)) {
        $expected=[ordered]@{}; foreach ($key in $spec.Keys) { $expected[$key]=$spec[$key] }
        $expected.clientBuildCode=$build
        $expected.contractId='nll/phase-d-runner-input/v2'
        $expected.weaknessCode='iron'
        $expected.staticDataVariantRequired=$variant
        if ($variant) { $expected.variantStaticDataPack=Join-Path $root 'pack'; $expected.variantStaticDataSha256='6'*64 }
        $expected.resourcePreflightRequired=$build -ceq 'build_150.6.9'
        if ($expected.resourcePreflightRequired) {
            foreach ($field in @('resourcePreflightHelper','resourcePreflightTool','resourceCatalogReceiptPath')) { $expected[$field]=Join-Path $root $field }
            foreach ($field in @('resourcePreflightHelperSha256','resourcePreflightToolSha256','resourceCatalogReceiptSha256')) { $expected[$field]='5'*64 }
            $expected.bootstrapRoot='C:\NLL\Runtime\PhysicalBootstrap-v2'
            $expected.bootstrapSha256='ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f'
            $expected.serverExeSha256='a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
        }
        $invokeMapping={
            foreach ($key in $expected.Keys) { Set-Variable -Name $key -Value $expected[$key] -Scope Local }
            $candidate=@{accountUid=$expected.accountUid;baseRevisions=@{revisionSetSha256=$expected.accountRevisionSetSha256}}
            $materialization=@{raidSnapshotUid=$expected.raidSnapshotUid;raidSnapshotSha256=$expected.raidSnapshotSha256}
            $preparation=@{bindingSha256=$expected.preparationBindingSha256}
            $expectedWeaknessVariantServerDllSha256=$expected.serverDllSha256
            $sourceManifestSha256=$expected.derivedSourceManifestSha256
            $ValidationKind=$expected.runIntentCode
            $runtimeBundle=if ($build -ceq 'build_151.8.5') {
                @{bootstrapRoot=$expected.bootstrapRoot;bootstrap=@{sha256=$expected.bootstrapSha256};serverExe=@{sha256=$expected.serverExeSha256}}
            } else { $null }
            & $body
        }
        $actual=& $invokeMapping
        foreach ($key in $expected.Keys) { Assert-Route ($actual.spec[$key] -ceq $expected[$key]) }
        Assert-Route ($actual.start -ceq $actual.completion -and
            $actual.start -ceq (Join-Path $actual.bundle.root 'invoke-nll-phase-d-runner.ps1') -and
            $actual.watcher -ceq (Join-Path $actual.bundle.root 'watch-nll-phase-d-execution.ps1'))
        $count++
    }
}
Assert-Route ($script:bundleCalls -eq 4)
$script:rejectBundle=$true; $rejected=$false
try { $null=& $invokeMapping } catch { $rejected=$_.Exception.Message -ceq 'phase_d_runner_bundle_invalid' }
Assert-Route ($rejected -and $script:bundleCalls -eq 5) # no fallback or retry
Assert-Route (-not (Test-Path $root))
'Runner routing: 4 real coordinator mappings, fixed-only engine, retired-template independence and no fallback passed.'
