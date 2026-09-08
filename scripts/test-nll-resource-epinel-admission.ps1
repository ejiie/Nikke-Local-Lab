[CmdletBinding()]
param()
# File/provenance and source checks only. Never load the DLL into this process.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$repository=Split-Path -Parent $PSScriptRoot
$library=Join-Path $repository '.external\EpinelPS-151-candidate\ServerSelector.Desktop\sodium.dll'
$binding=[ordered]@{libraryPin=(Get-RnPin $library);authorizationId='operator-2026-09-06-epinel-provided-151/v1'}
Assert-RnEpinelProvided $binding
$checks=1; $negativeCases=0
foreach ($field in @('sha256','length','authorizationId')) {
    $candidate=$binding | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    if ($field -ceq 'authorizationId') {$candidate.authorizationId='unreviewed'}
    elseif ($field -ceq 'sha256') {$candidate.libraryPin.sha256='0'*64}
    else {$candidate.libraryPin.length=358401}
    $rejected=$false
    try {Assert-RnEpinelProvided $candidate} catch {
        if ($_.Exception.Message -cne 'resource_native_epinel_package_unreviewed') {throw}
        $rejected=$true
    }
    Assert-Rn $rejected 'epinel_negative_admission_failed'
    $checks++; $negativeCases++
}
$wrongFile=$binding | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$wrongFile.libraryPin.path=Join-Path $repository 'AGENTS.md'
$rejected=$false
try {Assert-RnEpinelProvided $wrongFile} catch {
    if ($_.Exception.Message -cne 'resource_native_file_drift') {throw}
    $rejected=$true
}
Assert-Rn $rejected 'epinel_wrong_file_admitted'
$checks++; $negativeCases++
foreach ($mode in @('UseSourceBaseline','UseLocalKeyBinding')) {
    $switches=@{UseEpinelProvided=$true}; $switches[$mode]=$true
    $rejected=$false
    try {& (Join-Path $PSScriptRoot 'prepare-nll-resource-native-observation.ps1') @switches | Out-Null} catch {
        $expected=if ($mode -ceq 'UseSourceBaseline') {'resource_native_native_mode_conflict'} else {'resource_native_key_library_native_regression'}
        if ($_.Exception.Message -cne $expected) {throw}
        $rejected=$true
    }
    Assert-Rn $rejected 'epinel_mixed_mode_admitted'
    $checks++; $negativeCases++
}
foreach ($name in @('Nll.ResourceNative.ps1','prepare-nll-resource-native-observation.ps1','invoke-nll-resource-native-observation.ps1','restore-nll-resource-native-observation.ps1','test-nll-resource-epinel-admission.ps1')) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
    Assert-Rn ($errors.Count -eq 0) 'epinel_script_parse_failed'
    $checks++
}
$runner=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'invoke-nll-resource-native-observation.ps1') -Raw
$restore=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'restore-nll-resource-native-observation.ps1') -Raw
foreach ($text in @($runner,$restore)) {
    Assert-Rn ($text.Contains('nll/resource-native-observation-plan/v5') -and $text.Contains('epinel_provided_library_control') -and $text.Contains('Assert-RnPin $plan.stockNativePin')) 'epinel_recovery_contract_missing'
    $checks++
}
Assert-Rn ($runner.Contains('Assert-RnEpinelProvided $plan.nativeKeyBinding') -and $runner.Contains('key_mutation_invalid') -and $runner.Contains('key_binding_path_invalid')) 'epinel_binding_boundary_missing'
$checks++
[ordered]@{status='passed';checks=$checks;negativeCases=$negativeCases;libraryLoaded=$false;clientStarted=$false;serverStarted=$false;systemChangesApplied=$false} | ConvertTo-Json
