[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$InputPlanSha256
)
# Stage NEW, independent inputs only. This is not a launch permit, controller,
# native FX delivery, system/service change or operating-registry publication.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
function Check([bool]$value, [string]$code) { Assert-Rn $value ('user_validation_stage_' + $code) }
function Read-Pin([object]$pin) {
    Check (-not $pin.path.StartsWith('C:\NIKKE', [StringComparison]::OrdinalIgnoreCase)) 'official_input_rejected'
    Assert-RnPin $pin
    Read-RnJson $pin.path $pin.sha256
}
$inputPlan = Read-RnJson $InputPlanPath $InputPlanSha256
Check ($inputPlan.contractId -ceq 'nll/user-validation-runtime-input/v1') 'input_invalid'
$trial = [guid]::ParseExact($inputPlan.trialUid, 'D')
Check ($trial -ne [guid]::Empty -and $trial.ToString('D') -ceq $inputPlan.trialUid) 'trial_invalid'
$trialRoot = 'C:\NLL\Staging\NativeFxUserValidation\' + $trial.ToString('D')
Check ($inputPlan.cloneReceipt.path -ceq (Join-Path $trialRoot 'clone.receipt.json')) 'clone_path_invalid'
$clone = Read-Pin $inputPlan.cloneReceipt
Check ($clone.contractId -ceq 'nll/native-fx-user-validation-clone/v1' -and
    $clone.assessmentUid -ceq $trial.ToString('D') -and
    $clone.status -ceq 'cloned_not_started' -and $clone.sourceUnchanged -eq $true -and
    $clone.physicalCopiesVerified -eq $true -and $clone.sharedLinksCreated -eq $false) 'clone_unverified'
$account = Read-Pin $inputPlan.accountReceipt
$candidate = Read-Pin $inputPlan.candidateReceipt
$build = Read-Pin $inputPlan.serverBuildReceipt
$bundle = Read-Pin $inputPlan.bundle
Check ($account.contractId -ceq 'nll/user-validation-prepared-account/v1' -and
    $account.executionOwnerCode -ceq 'user' -and $account.operatingPersistenceDetached -eq $true -and
    $account.allOtherFieldsPreserved -eq $true -and $account.gameStarted -eq $false) 'account_invalid'
Check ($candidate.contractId -ceq 'nll/boss-onboarding-verified-candidate/v1' -and
    $candidate.statusCode -ceq 'verified_candidate_pending_runtime_delivery' -and
    $candidate.fiveAffinityVariantStatusCode -ceq 'passed' -and $candidate.affinityVariantCount -eq 5 -and
    $candidate.clientStarted -eq $false -and $candidate.profileSha256 -ceq $account.profileSha256 -and
    $candidate.seasonNumber -eq $account.seasonNumber) 'candidate_invalid'
Check ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1' -and
    $bundle.clientBuildCode -ceq 'build_151.8.5' -and
    $build.contractId -ceq 'nll/user-validation-server-build/v1' -and
    $build.bundleSha256 -ceq $inputPlan.bundle.sha256 -and $build.originalSourcePreserved -eq $true -and
    $build.installedBundlePreserved -eq $true -and $build.serverStarted -eq $false) 'build_invalid'
foreach ($pin in $bundle.files) { Assert-RnPin $pin }
foreach ($pin in @($build.candidateServerDll, $build.sourceLoader, $build.patchedLoader,
    $build.versionHelper, $build.patch, $build.buildConfiguration)) { Assert-RnPin $pin }
$assessment = [guid]::ParseExact($account.assessmentUid, 'D')
Check ($assessment -ne [guid]::Empty -and $assessment -ne $trial -and
    $assessment.ToString('D') -ceq $account.assessmentUid) 'assessment_invalid'
$weakness = [string]$account.weaknessCode
Check ($weakness -cin @('fire','water','wind','electric','iron')) 'weakness_invalid'
$runRoot = Join-Path $trialRoot ('runs/' + $assessment.ToString('D'))
$serverRoot = 'C:\NLL\Runtime\EpinelPS-151-UserValidation\' + $assessment.ToString('D')
$bootstrapRoot = 'C:\NLL\Runtime\NativeFxUserValidationBootstrap\' + $assessment.ToString('D')
foreach ($root in @($runRoot, $serverRoot, $bootstrapRoot)) {
    Assert-RnPath $root
    Check (-not (Test-Path -LiteralPath $root)) 'output_exists'
}
$accountRoot = Split-Path -Parent $inputPlan.accountReceipt.path
$candidateRoot = Split-Path -Parent $inputPlan.candidateReceipt.path
$db = Join-Path $accountRoot 'db.json'
$context = Join-Path $accountRoot 'synthetic-context.json'
Check ((Get-RnHash $db) -ceq $account.runtimeDatabaseSha256 -and
    (Get-RnHash $context) -ceq $account.syntheticContextSha256) 'account_input_drift'
foreach ($name in @('boss-runtime-variant.profile.json', ('five-affinity-variants/' + $weakness + '.receipt.json'))) {
    $matches = @($candidate.artifacts | Where-Object {$_.relativePath -ceq $name})
    Check ($matches.Count -eq 1 -and (Get-RnHash (Join-Path $candidateRoot $name)) -ceq $matches[0].sha256) 'variant_input_drift'
}
$variantReceiptPath = Join-Path $candidateRoot ('five-affinity-variants/' + $weakness + '.receipt.json')
$variant = Get-Content -LiteralPath $variantReceiptPath -Raw | ConvertFrom-Json
Check ($variant.contractId -ceq 'nll/boss-affinity-static-data-variant/v1' -and
    $variant.weaknessCode -ceq $weakness -and $variant.variantProfileSha256 -ceq $account.profileSha256 -and
    $variant.runtimeAdmissionStatusCode -ceq 'not_assessed') 'variant_invalid'
$variantPath = $null
if ($variant.variantRequired) {
    $variantPath = Join-Path $candidateRoot ('five-affinity-variants/' + $weakness + '.pack')
    Check ((Get-RnHash $variantPath) -ceq $variant.variantStaticDataSha256) 'variant_pack_drift'
}
$bootNames = @($inputPlan.bootstrapFiles | ForEach-Object {Split-Path -Leaf $_.path})
Check ($bootNames.Count -eq 4 -and @($bootNames | Sort-Object -Unique).Count -eq 4) 'bootstrap_inventory_invalid'
foreach ($name in @('NikkeLocalLab.NativeFxUserValidationBootstrap.exe', 'NikkeLocalLab.NativeFxUserValidationBootstrap.dll',
    'NikkeLocalLab.NativeFxUserValidationBootstrap.deps.json', 'NikkeLocalLab.NativeFxUserValidationBootstrap.runtimeconfig.json')) {
    Check ($name -cin $bootNames) 'bootstrap_inventory_invalid'
}
foreach ($pin in $inputPlan.bootstrapFiles) { Assert-RnPin $pin }
Assert-RnPin $inputPlan.sail
Assert-RnPin $inputPlan.trustRoot
Check ($inputPlan.sail.sha256 -ceq '8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d' -and
    $inputPlan.trustRoot.sha256 -ceq '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda') 'native_input_invalid'
foreach ($root in @($runRoot, $serverRoot, $bootstrapRoot)) { New-RnPrivateDirectory $root }
$sourcePrefix = [IO.Path]::GetFullPath($bundle.serverRoot).TrimEnd('\') + '\'
foreach ($pin in $bundle.files) {
    if (-not $pin.path.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $name = $pin.path.Substring($sourcePrefix.Length)
    Check (-not $name.Contains('..') -and $name -cnotin @('db.json','epinelps.db')) 'source_member_invalid'
    $target = Join-Path $serverRoot $name
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    $source = if ($name -ceq 'EpinelPS.dll') {$build.candidateServerDll.path} else {$pin.path}
    Copy-RnNew $source $target
}
Copy-RnNew $db (Join-Path $serverRoot 'db.json')
Copy-RnNew (Join-Path $candidateRoot 'boss-runtime-variant.profile.json') (Join-Path $serverRoot 'boss-runtime-variant.profile.json')
if ($variantPath) { Copy-RnNew $variantPath (Join-Path $serverRoot 'client-static-data-variant.pack') }
foreach ($pin in $inputPlan.bootstrapFiles) { Copy-RnNew $pin.path (Join-Path $bootstrapRoot (Split-Path -Leaf $pin.path)) }
Copy-RnNew $context (Join-Path $bootstrapRoot 'synthetic-context.json')
Copy-RnNew $inputPlan.sail.path (Join-Path $bootstrapRoot 'sail_api_impl64.dll')
Copy-RnNew $inputPlan.trustRoot.path (Join-Path $bootstrapRoot 'trust-root.cer')
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $serverRoot 'site.pfx'), '',
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
try { Write-RnNewBytes (Join-Path $bootstrapRoot 'server.cer') $certificate.RawData } finally {$certificate.Dispose()}
foreach ($pin in @($inputPlan.accountReceipt, $inputPlan.candidateReceipt, $inputPlan.serverBuildReceipt)) {
    Copy-RnNew $pin.path (Join-Path $runRoot (Split-Path -Leaf $pin.path))
}
foreach ($pin in $bundle.files) { Assert-RnPin $pin }
Check ((Get-RnHash $InputPlanPath) -ceq $InputPlanSha256 -and (Get-RnHash $db) -ceq $account.runtimeDatabaseSha256 -and
    (Get-RnHash $context) -ceq $account.syntheticContextSha256) 'protected_input_drift'
foreach ($pin in @($inputPlan.cloneReceipt, $inputPlan.accountReceipt, $inputPlan.candidateReceipt,
    $inputPlan.serverBuildReceipt, $inputPlan.bundle, $inputPlan.sail, $inputPlan.trustRoot) + @($inputPlan.bootstrapFiles)) {
    Assert-RnPin $pin
}
$receipt = [ordered]@{
    contractId='nll/user-validation-runtime-staging/v1'; inputPlanSha256=$InputPlanSha256
    trialUid=$trial.ToString('D'); assessmentUid=$assessment.ToString('D'); executionOwnerCode='user'
    seasonNumber=$account.seasonNumber; weaknessCode=$weakness; profileSha256=$account.profileSha256
    candidateReceiptSha256=$inputPlan.candidateReceipt.sha256; accountReceiptSha256=$inputPlan.accountReceipt.sha256
    serverRoot=$serverRoot; bootstrapRoot=$bootstrapRoot; runRoot=$runRoot
    staticDataVariantRequired=[bool]$variant.variantRequired; variantStaticDataSha256=$variant.variantStaticDataSha256
    serverFiles=@(Get-ChildItem -LiteralPath $serverRoot -Recurse -File | Sort-Object FullName | ForEach-Object {Get-RnPin $_.FullName})
    bootstrapFiles=@(Get-ChildItem -LiteralPath $bootstrapRoot -Recurse -File | Sort-Object FullName | ForEach-Object {Get-RnPin $_.FullName})
    installedBundlePreserved=$true; preparedAccountPreserved=$true; clientModified=$false
    serverStarted=$false; gameStarted=$false; systemChangesApplied=$false; readyForGameLaunch=$false
    runtimeAdmissionStatusCode='not_assessed'
}
Write-RnNewJson (Join-Path $runRoot 'runtime-staging.receipt.json') $receipt
[ordered]@{contractId=$receipt.contractId;assessmentUid=$receipt.assessmentUid;weaknessCode=$weakness
    receiptSha256=(Get-RnHash (Join-Path $runRoot 'runtime-staging.receipt.json'))
    serverFileCount=$receipt.serverFiles.Count;bootstrapFileCount=$receipt.bootstrapFiles.Count;readyForGameLaunch=$false} | ConvertTo-Json -Compress
