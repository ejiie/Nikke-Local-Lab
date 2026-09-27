[CmdletBinding()]
param([Parameter(Mandatory)][string]$BaseBundlePath,
    [Parameter(Mandatory)][string]$BaseBundleSha256,
    [Parameter(Mandatory)][string]$MaterializerRoot,
    [Parameter(Mandatory)][string]$ServerBuildReceiptPath,
    [Parameter(Mandatory)][string]$ServerBuildReceiptSha256,
    [Parameter(Mandatory)][object]$NativeStorePin,
    [ValidateRange(7,99)][int]$Revision = 7)
# New pinned runtime only. Activation and game acceptance are separate operations.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$base = Read-RnJson $BaseBundlePath $BaseBundleSha256
$build = Read-RnJson $ServerBuildReceiptPath $ServerBuildReceiptSha256
Assert-Rn ($base.contractId -ceq 'nll/phase-d-runtime-bundle/v1' -and
    $build.bundleSha256 -ceq $BaseBundleSha256 -and $build.originalSourcePreserved -eq $true -and
    $build.installedBundlePreserved -eq $true -and $build.serverStarted -eq $false) 'common_runtime_source_invalid'
foreach ($pin in $base.files) { Assert-RnPin $pin }
Assert-RnPin $build.candidateServerDll
$oldRoot = Split-Path -Parent $BaseBundlePath
$newRoot = 'C:\NLL\Runtime\PhaseD151-v' + $Revision
Assert-Rn ($oldRoot -cne $newRoot -and -not (Test-Path -LiteralPath $newRoot)) 'common_runtime_output_exists'
New-RnPrivateDirectory $newRoot
$copyPins = @{}
function Collect-Pins($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        foreach ($row in $Value) { Collect-Pins $row }; return
    }
    if ($Value.PSObject.Properties.Name -contains 'path' -and $Value.PSObject.Properties.Name -contains 'sha256' -and
        ([string]$Value.path).StartsWith($oldRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { $copyPins[$Value.path] = $Value }
    foreach ($property in $Value.PSObject.Properties) { Collect-Pins $property.Value }
}
Collect-Pins $base
foreach ($pin in $copyPins.Values) {
    Assert-RnPin $pin
    $target = Join-Path $newRoot $pin.path.Substring($oldRoot.Length + 1)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
    Copy-RnNew $pin.path $target
}
# Only the reviewed profile-reader assembly changes in the server. Its existing
# dependency/config/cache and the successful S26 bootstrap bytes are retained.
$serverDll = Join-Path $newRoot 'server/EpinelPS.dll'
[IO.File]::WriteAllBytes($serverDll, [IO.File]::ReadAllBytes($build.candidateServerDll.path))
foreach ($name in @('NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll',
    'NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json','NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')) {
    $source = Join-Path $MaterializerRoot $name
    $target = Join-Path $newRoot ('materializer/' + $name)
    [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($source))
    Assert-Rn ((Get-RnHash $target) -ceq (Get-RnHash $source)) 'common_runtime_copy_drift'
}
# Read-only preparation now invokes the materializer before a per-run server is
# copied. Supply the same pinned runtime dependencies in its own directory too.
$dependencyPins = @()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $newRoot 'server') -File -Filter '*.dll') {
    $target = Join-Path $newRoot ('materializer/' + $file.Name)
    if (-not (Test-Path -LiteralPath $target)) { Copy-RnNew $file.FullName $target; $dependencyPins += Get-RnPin $target }
}
$text = ($base | ConvertTo-Json -Depth 30).Replace($oldRoot.Replace('\','\\'), $newRoot.Replace('\','\\'))
$next = $text | ConvertFrom-Json
$next.parentManifest = Get-RnPin $BaseBundlePath
$next.serverDll = Get-RnPin $serverDll
$next.files = @($next.files | ForEach-Object { Get-RnPin $_.path })
$next.files += $dependencyPins
$receiptTarget = Join-Path $newRoot 'common-server-build.private.json'
Copy-RnNew $ServerBuildReceiptPath $receiptTarget
$next.files += Get-RnPin $receiptTarget
$next | Add-Member commonBossRegistryRoot 'C:\NLL\RuntimeInputs\CommonBossExecution\profiles'
$next | Add-Member commonNativeStore $NativeStorePin
$next.nativeGameplayValidated = $false
$path = Join-Path $newRoot 'bundle.private.json'
Write-RnNewJson $path $next
foreach ($pin in $base.files) { Assert-RnPin $pin }
foreach ($pin in $next.files) { Assert-RnPin $pin }
[ordered]@{contractId='nll/common-runtime-preparation/v1';bundle=(Get-RnPin $path);
    previousBundle=(Get-RnPin $BaseBundlePath);bootstrapPreserved=$true;voiceSettingsWritten=$false;
    installedSelectionChanged=$false;gameStarted=$false} | ConvertTo-Json -Depth 8
