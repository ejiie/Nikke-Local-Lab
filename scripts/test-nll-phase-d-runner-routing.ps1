# Coordinator route selection only. Execute the actual branch with fake bundle
# publication/legacy compilation; no file, process, DB or game actions.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-Test($Value) { if (-not $Value) { throw ('runner_route_test_failed_line_' + $MyInvocation.ScriptLineNumber) } }
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1'),[ref]$tokens,[ref]$errors)
Assert-Test ($errors.Count -eq 0)
$branch=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
    $n.Clauses[0].Item1.Extent.Text -ceq "`$RunnerEngine -ceq 'parameterized/v1'"},$true))
Assert-Test ($branch.Count -eq 1)
# The legacy branch contains file writes; run only its first assignment to the
# adapter. The new branch contains only pure mapping + the mocked bundle publisher.
$testScriptsRoot=$PSScriptRoot
$newBody=[scriptblock]::Create('$PSScriptRoot=$testScriptsRoot;' + $branch[0].Clauses[0].Item2.Extent.Text.TrimStart('{').TrimEnd('}'))
$oldBody=[scriptblock]::Create($branch[0].ElseClause.Statements[0].Extent.Text)
$parameter=@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'RunnerEngine' })[0]
Assert-Test ($parameter.DefaultValue.Value -ceq 'legacy/v1') # rollout gate not yet accepted
$launchRoot=Join-Path ([IO.Path]::GetTempPath()) 'synthetic-not-created'
$launchToolInput=@{synthetic=$true}; $preparation=@{bindingSha256=('a'*64)}
$bossRuntimeVariantProfileSha256='b'*64; $sourceManifestSha256='c'*64; $ValidationKind='challenge'
function New-PhaseDRunnerSpecification {
    param($LaunchInput,$PreparationBindingSha256,$ProfileSha256,$SourceManifestSha256,$RunIntentCode)
    Assert-Test ($LaunchInput.synthetic -and $PreparationBindingSha256 -ceq $preparation.bindingSha256 -and
        $ProfileSha256 -ceq $bossRuntimeVariantProfileSha256 -and $SourceManifestSha256 -ceq $sourceManifestSha256 -and $RunIntentCode -ceq 'challenge')
    @{synthetic=$true}
}
function New-PhaseDRunnerBundle {
    param($Specification,$ScriptsRoot)
    Assert-Test ($Specification.synthetic -and $ScriptsRoot -ceq $PSScriptRoot)
    $script:bundleCalls++
    if ($script:rejectBundle) { throw 'phase_d_runner_bundle_invalid' }
    @{root=(Join-Path $launchRoot 'tools/runner');sha256=('d'*64)}
}
function New-PhaseDLaunchToolText { param($Specification) $script:legacyCalls++; @{startText='synthetic';completionText='synthetic'} }
$script:bundleCalls=0; $script:legacyCalls=0; $script:rejectBundle=$false
. $oldBody
Assert-Test ($script:legacyCalls -eq 1 -and $script:bundleCalls -eq 0)
. $newBody
Assert-Test ($script:legacyCalls -eq 1 -and $script:bundleCalls -eq 1)
Assert-Test ($derivedStart -ceq $derivedCompletion -and $watcher -ceq (Join-Path $runnerBundle.root 'watch-nll-phase-d-execution.ps1'))
$script:rejectBundle=$true; $failed=$false
try { . $newBody } catch { $failed=$_.Exception.Message -ceq 'phase_d_runner_bundle_invalid' }
Assert-Test ($failed -and $script:legacyCalls -eq 1) # must not retry another engine
Assert-Test (-not (Test-Path -LiteralPath $launchRoot))
'Runner routing: legacy default, explicit fixed engine, mapping bindings and no automatic fallback passed.'
