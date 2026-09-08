[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$repository=Split-Path -Parent $PSScriptRoot
$buildRoot=Join-Path $repository 'artifacts\resource-probe-151\native-key-compat-v1'
$binding=[ordered]@{libraryPin=(Get-RnPin (Join-Path $buildRoot 'local\sodium.dll'));buildReceiptPin=(Get-RnPin (Join-Path $buildRoot 'build.private.json'));testReceiptPin=(Get-RnPin (Join-Path $buildRoot 'synthetic.private.json'))}
Assert-RnLocalKeyBinding $binding
$checks=1
$scratch=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('nll-key-admission-'+[Guid]::NewGuid().ToString('D'))))
New-RnPrivateDirectory $scratch
try {
    $cases=@(
        @('build','contractId','unexpected/v1'), @('build','sourceCommit',('0'*40)),
        @('build','sourcePatchSha256',('0'*64)), @('build','exportCount',609),
        @('build','exportsMatchStock',$false), @('build','exportsMatchBaseline',$false),
        @('build','unreviewedImportsAbsent',$false), @('build','macValidationChanged',$true),
        @('test','status','failed'), @('test','checks',14), @('test','candidateChecked',$false),
        @('test','librarySha256',('0'*64)), @('test','buildReceiptSha256',('0'*64)),
        @('test','testScriptSha256',('0'*64)), @('test','tamperRejected',$false),
        @('test','differentStockPeerRejected',$false)
    )
    for ($i=0; $i -lt $cases.Count; $i++) {
        $case=$cases[$i]
        $sourcePin=if ($case[0] -ceq 'build') {$binding.buildReceiptPin} else {$binding.testReceiptPin}
        $document=Get-Content -LiteralPath $sourcePin.path -Raw | ConvertFrom-Json
        $document.($case[1])=$case[2]
        $path=Join-Path $scratch ($i.ToString()+'.json')
        Write-RnNewJson $path $document
        $candidate=[ordered]@{libraryPin=$binding.libraryPin;buildReceiptPin=$binding.buildReceiptPin;testReceiptPin=$binding.testReceiptPin}
        if ($case[0] -ceq 'build') {$candidate.buildReceiptPin=Get-RnPin $path} else {$candidate.testReceiptPin=Get-RnPin $path}
        $rejected=$false
        try {Assert-RnLocalKeyBinding $candidate} catch {
            if ($_.Exception.Message -notmatch '^resource_native_key_(build|test)_receipt_invalid$') {throw}
            $rejected=$true
        }
        Assert-Rn $rejected 'negative_key_admission_failed'
        $checks++
    }
    $nativeRegressionRejected=$false
    try { & (Join-Path $PSScriptRoot 'prepare-nll-resource-native-observation.ps1') -UseLocalKeyBinding | Out-Null } catch {
        if ($_.Exception.Message -cne 'resource_native_key_library_native_regression') {throw}
        $nativeRegressionRejected=$true
    }
    Assert-Rn $nativeRegressionRejected 'known_native_regression_admitted'
    $checks++
    $mixedRejected=$false
    try { & (Join-Path $PSScriptRoot 'prepare-nll-resource-native-observation.ps1') -UseLocalKeyBinding -UseSourceBaseline | Out-Null } catch {
        if ($_.Exception.Message -cne 'resource_native_key_library_native_regression') {throw}
        $mixedRejected=$true
    }
    Assert-Rn $mixedRejected 'mixed_native_regression_admitted'
    $checks++
    $control=[ordered]@{libraryPin=(Get-RnPin (Join-Path $buildRoot 'baseline\sodium.dll'));buildReceiptPin=$binding.buildReceiptPin;testReceiptPin=(Get-RnPin (Join-Path $buildRoot 'baseline-synthetic.private.json'))}
    Assert-RnSourceBaseline $control
    $checks++
    $baselineCases=@(
        @('contractId','unexpected/v1'), @('status','failed'), @('checks',13),
        @('sourceBaselineLibrary',$false), @('stockClientLibrary',$true),
        @('librarySha256',('0'*64)), @('testScriptSha256',('0'*64)),
        @('syntheticKeysOnly',$false), @('systemChangesApplied',$true),
        @('passed',@('stock_init'))
    )
    for ($i=0; $i -lt $baselineCases.Count; $i++) {
        $case=$baselineCases[$i]
        $document=Get-Content -LiteralPath $control.testReceiptPin.path -Raw | ConvertFrom-Json
        $document.($case[0])=$case[1]
        $path=Join-Path $scratch ('baseline-'+$i.ToString()+'.json')
        Write-RnNewJson $path $document
        $candidate=[ordered]@{libraryPin=$control.libraryPin;buildReceiptPin=$control.buildReceiptPin;testReceiptPin=(Get-RnPin $path)}
        $rejected=$false
        try {Assert-RnSourceBaseline $candidate} catch {
            if ($_.Exception.Message -cne 'resource_native_baseline_test_invalid') {throw}
            $rejected=$true
        }
        Assert-Rn $rejected 'negative_baseline_admission_failed'
        $checks++
    }
    $wrongLibraryRejected=$false
    try {Assert-RnSourceBaseline ([ordered]@{libraryPin=$binding.libraryPin;buildReceiptPin=$control.buildReceiptPin;testReceiptPin=$control.testReceiptPin})} catch {
        if ($_.Exception.Message -cne 'resource_native_baseline_package_unreviewed') {throw}
        $wrongLibraryRejected=$true
    }
    Assert-Rn $wrongLibraryRejected 'local_binding_admitted_as_control'
    $checks++
    foreach ($name in @('Nll.ResourceNative.ps1','build-nll-resource-key-compat.ps1','test-nll-resource-key-agreement.ps1','test-nll-resource-native-abi.ps1',
        'test-nll-resource-server-crypto.ps1','prepare-nll-resource-native-observation.ps1','invoke-nll-resource-native-observation.ps1','restore-nll-resource-native-observation.ps1')) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
        Assert-Rn ($errors.Count -eq 0) 'key_script_parse_failed'
        $checks++
    }
    [ordered]@{status='passed';checks=$checks;negativeCases=($cases.Count+$baselineCases.Count+3);nativeRegressionRejected=$nativeRegressionRejected;baselineVerified=$true;clientStarted=$false;serverStarted=$false;systemChangesApplied=$false} | ConvertTo-Json
} finally {
    # Only this fresh generated JSON fixture directory, never a runtime/source tree.
    $resolved=(Resolve-Path -LiteralPath $scratch).ProviderPath
    $expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    Assert-Rn ((Split-Path -Parent $resolved) -ceq $expectedParent -and (Split-Path -Leaf $resolved) -cmatch '^nll-key-admission-[a-f0-9-]{36}$') 'scratch_cleanup_boundary_invalid'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
