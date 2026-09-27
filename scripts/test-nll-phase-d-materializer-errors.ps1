# Run the coordinator's native invocation and failure parser against a synthetic
# executable. No account, database, game, registry, or installed runtime is used.
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$true
Set-StrictMode -Version Latest
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'materializer_test_parse_failed'}
$assignments=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$materializerInvocation'},$true))
$branches=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$materializerExitCode -ne 0'},$true))
if($assignments.Count -ne 1 -or $branches.Count -ne 1){throw 'materializer_test_invocation_missing'}
$invoke=[scriptblock]::Create($assignments[0].Extent.Text)
$parse=[scriptblock]::Create($branches[0].Extent.Text)
$launchRoot=Join-Path ([IO.Path]::GetTempPath()) ('nll-materializer-errors-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $launchRoot
$runtimeMaterializer=Join-Path $launchRoot 'synthetic-materializer.cmd'
foreach($name in @('RuntimeCandidatePath','LobbyProjectionPath','parentRoot','runtimeDbPath','materializationReceiptPath',
 'connectionEnvironmentVariable','secretEnvironmentVariable','SeasonNumber','bossRuntimeVariantProfile','WeaknessCode',
 'sourceStaticDataPack','variantStaticDataPack','variantStaticDataReceiptPath','clientBuildCode','clientExecutableSha256')){
 Set-Variable -Name $name -Value 'synthetic'
}
$checks=0
try{
 foreach($case in @(
  @{code='phase_d_raid_state_operational_binding_missing';exit=1;expected='phase_d_raid_state_operational_binding_missing'},
  @{code='synthetic unsafe diagnostic';exit=1;expected='phase_d_materialization_failed'},
  @{code='synthetic warning';exit=0;expected=''})){
  $body="@echo off`r`n1>&2 echo {`"preparationExceptionType`":`"SyntheticFailure`"}`r`n1>&2 echo $($case.code)`r`nexit /b $($case.exit)`r`n"
  [IO.File]::WriteAllText($runtimeMaterializer,$body,[Text.Encoding]::ASCII)
  . $invoke
  if($materializerInvocation.ExitCode -ne $case.exit -or @($materializerInvocation.Output).Count -lt 2){throw 'materializer_test_capture_failed'}
  if($ErrorActionPreference -ne 'Stop' -or $PSNativeCommandUseErrorActionPreference -ne $true){throw 'materializer_test_preference_leaked'}
  $materializerExitCode=$materializerInvocation.ExitCode
  $materializerOutput=@($materializerInvocation.Output)
  $observed=''
  try{. $parse}catch{$observed=$_.Exception.Message}
  if($observed -cne $case.expected){throw ('materializer_test_code_lost: ' + $observed)}
  $diagnostic=Join-Path $launchRoot 'materializer-failure.types.jsonl'
  if($case.exit -ne 0 -and ([IO.File]::ReadAllText($diagnostic)).Trim() -cne '{"preparationExceptionType":"SyntheticFailure"}'){
   throw 'materializer_test_unsafe_diagnostic'
  }
  $checks++
 }
 Write-Output "Materializer errors: $checks native stderr cases passed; caller preferences preserved."
}finally{
 $full=[IO.Path]::GetFullPath($launchRoot)
 if([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
    [IO.Path]::GetFileName($full) -cnotmatch '^nll-materializer-errors-[a-f0-9]{32}$'){throw 'materializer_test_cleanup_invalid'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
