[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ParentPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ParentPlanSha256,
    [Parameter(Mandatory)][string]$OutputPath
)
# User may run this in an elevated shell. This script never requests elevation
# or starts a process. Only the small pinned plan and TWO registry values are read.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
. (Join-Path $PSScriptRoot 'Nll.UserValidationPreflight.ps1')
$plan=Read-RnJson $ParentPlanPath $ParentPlanSha256
Assert-Rn ($plan.contractId -ceq 'nll/native-fx-user-validation/v1') 'uv_diagnostic_plan_invalid'
Assert-RnPath $OutputPath
Assert-Rn (-not (Test-Path -LiteralPath $OutputPath)) 'uv_diagnostic_output_exists'
$watch=[Diagnostics.Stopwatch]::StartNew()
$snapshot=Get-UvVoicePreferences
$comparison=Compare-UvVoicePreferences $plan.preferencesBefore $snapshot
$watch.Stop()
$receipt=[ordered]@{contractId='nll/user-validation-preference-observation/v1';stage='standalone_readonly';
    parentPlanSha256=$ParentPlanSha256;observedAtUtc=[DateTimeOffset]::UtcNow;elapsedMilliseconds=$watch.Elapsed.TotalMilliseconds;
    environment=(Get-UvPreferenceEnvironment $plan.operatorSid);comparison=$comparison;
    gameStarted=$false;uacRequested=$false;systemChangesApplied=$false;largeFileReads=0;actualGameAcceptanceClaimed=$false}
Write-RnNewJson $OutputPath $receipt
$receipt|ConvertTo-Json -Depth 12
