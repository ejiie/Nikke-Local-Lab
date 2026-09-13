[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PythonPath,
    [Parameter(Mandatory)][string]$OwnedStoreRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ManifestSha256
)

# Only an already sealed OFFLINE artifacts copy may be verified/restored. This
# helper never launches a client/server or installs the store into any runtime.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tool = Join-Path $PSScriptRoot 'materialize-nll-native-fx-store.py'
$manifestPath = Join-Path $OwnedStoreRoot 'manifest.private.json'
if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ManifestSha256) {
    throw 'native_fx_store_test_manifest_drift'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.contractId -cnotin @('nll/native-fx-offline-store/v1', 'nll/native-fx-offline-selected-store/v1')) {
    throw 'native_fx_store_test_contract_invalid'
}
$selectedRole = if ($manifest.contractId -ceq 'nll/native-fx-offline-selected-store/v1') { $manifest.roleCode } else { $null }
$toolHash = (Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant()
$observations = [Collections.Generic.List[object]]::new()
foreach ($operation in @('verify', 'restore', 'restore')) {
    $output = @(& $PythonPath -B $tool $operation --root $OwnedStoreRoot --sha256 $ManifestSha256)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { throw 'native_fx_store_test_operation_failed' }
    $result = $output[0] | ConvertFrom-Json
    $expected = if ($operation -ceq 'verify') { 'offline_copy_verified' } else { 'offline_copy_restored' }
    if ($result.contractId -cne 'nll/native-fx-offline-store-inspection/v1' -or
        $result.statusCode -cne $expected -or $result.manifestSha256 -cne $ManifestSha256 -or
        $result.nativeClientExecuted -ne $false -or $result.installedFilesModified -ne $false -or
        $result.runtimeAdmissionStatusCode -cne 'not_assessed') { throw 'native_fx_store_test_projection_invalid' }
    $observations.Add([ordered]@{ operation = $operation; statusCode = $result.statusCode })
}
$rejected = @(& $PythonPath -B $tool verify --root $OwnedStoreRoot --sha256 $ManifestSha256 2>&1)
if ($LASTEXITCODE -eq 0 -or ($rejected -join '').Trim() -cne 'native_fx_store_candidate_not_ready') {
    throw 'native_fx_store_test_restored_candidate_accepted'
}
if ((Get-FileHash -LiteralPath (Join-Path $OwnedStoreRoot 'store.cdb') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.original.sha256 -or
    (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ManifestSha256 -or
    (Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant() -cne $toolHash) {
    throw 'native_fx_store_test_final_drift'
}
$receipt = [ordered]@{
    contractId = 'nll/native-fx-offline-store-local-test/v1'
    manifestSha256 = $ManifestSha256
    toolSha256 = $toolHash
    observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    original = $manifest.original
    candidate = $manifest.candidate
    observations = @($observations)
    wholeFileRoundTripVerified = $true
    repeatedRestoreVerified = $true
    restoredCandidateRejected = $true
    roleCode = $selectedRole
    allRolesApplied = $null -eq $selectedRole
    nativeClientExecuted = $false
    installedFilesModified = $false
    runtimeAdmissionStatusCode = 'not_assessed'
}
$receiptPath = Join-Path $OwnedStoreRoot ('test-' + [guid]::NewGuid().ToString('N') + '.receipt.json')
$bytes = [Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 8) + "`n")
$stream = [IO.File]::Open($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
$receipt | ConvertTo-Json -Depth 8
