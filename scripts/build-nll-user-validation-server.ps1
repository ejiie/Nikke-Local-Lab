[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,64}$')][string]$OutputCode
)
# Offline build only. Preserve the installed v6 and its original external source
# tree; apply the reviewed patch to a new private build-overlay copy instead.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
Assert-RnPath $repository
$sourceRoot = Join-Path $repository '.external/EpinelPS-151-candidate'
$bundle = Read-RnJson $BundlePath $ExpectedBundleSha256
Assert-Rn ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1' -and
    $bundle.clientBuildCode -ceq 'build_151.8.5') 'user_validation_bundle_invalid'
foreach ($pin in $bundle.files) { Assert-RnPin $pin }
Assert-RnPin $bundle.serverSourceManifest
$sourcePins = foreach ($line in Get-Content -LiteralPath $bundle.serverSourceManifest.path) {
    $parts = $line -split "`t"
    Assert-Rn ($parts.Count -eq 3 -and $parts[0] -cmatch '^(EpinelPS|tests/EpinelPS\.SelectedManager\.Tests)/[A-Za-z0-9_./-]+\.cs$' -and
        -not $parts[0].Contains('..')) 'user_validation_source_manifest_invalid'
    $pin = [ordered]@{path=(Join-Path $sourceRoot $parts[0]);length=[long]$parts[1];sha256=$parts[2]}
    Assert-RnPin $pin
    $pin
}
$source = Join-Path $sourceRoot 'EpinelPS/SoloRaidSelection/ClassicSoloRaidTargetObservation.cs'
Assert-Rn ((Get-RnHash $source) -ceq '80864f78178ac947b8c4f7464746c13433abdd5d331cee0ff2b1b6fc187011d5') 'user_validation_loader_source_drift'
$patch = Join-Path $repository 'patches/epinel-user-validation-profile-version.patch'
$versionHelper = Join-Path $repository 'tools/Phase3B2/EpinelUserValidation/UserValidationProfileVersion.cs'
$patchPin = Get-RnPin $patch
$helperPin = Get-RnPin $versionHelper
$relative = 'artifacts/user-validation-server-builds/' + $OutputCode
$output = Join-Path $repository $relative
New-RnPrivateDirectory $output
$overlayRelative = $relative + '/source'
$overlay = Join-Path $repository $overlayRelative
$target = Join-Path $overlay 'EpinelPS/SoloRaidSelection/ClassicSoloRaidTargetObservation.cs'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $target)
Copy-RnNew $source $target
Push-Location $repository
try {
    & git apply --check ("--directory=" + $overlayRelative) -- $patch
    Assert-Rn ($LASTEXITCODE -eq 0) 'user_validation_loader_patch_check_failed'
    & git apply ("--directory=" + $overlayRelative) -- $patch
    Assert-Rn ($LASTEXITCODE -eq 0) 'user_validation_loader_patch_failed'
} finally { Pop-Location }
$targets = Join-Path $output 'Compile.targets'
$targetXml = [Security.SecurityElement]::Escape($target)
$helperXml = [Security.SecurityElement]::Escape($versionHelper)
# Generated build configuration only. Retain original compile-item order.
$xml = @'
<Project>
  <Target Name="NllUseUserValidationProfileLoader" BeforeTargets="CoreCompile" Condition="'$(MSBuildProjectName)' == 'EpinelPS'">
    <ItemGroup>
      <_NllCompile Include="@(Compile)">
        <Replacement>%(Identity)</Replacement>
        <Replacement Condition="'%(Identity)' == 'SoloRaidSelection\ClassicSoloRaidTargetObservation.cs'">TARGET</Replacement>
      </_NllCompile>
      <Compile Remove="@(Compile)" />
      <Compile Include="@(_NllCompile->'%(Replacement)')" />
      <Compile Include="HELPER" />
    </ItemGroup>
  </Target>
</Project>
'@
Write-RnNewBytes $targets ([Text.Encoding]::UTF8.GetBytes($xml.Replace('TARGET', $targetXml).Replace('HELPER', $helperXml)))
$buildOutput = Join-Path $output 'server'
Push-Location $sourceRoot
try {
    & dotnet build EpinelPS/EpinelPS.csproj -c Release --no-restore -r win-x64 --self-contained false `
        -p:PublishSingleFile=false ("-p:CustomAfterMicrosoftCommonTargets=" + $targets) -o $buildOutput `
        *> (Join-Path $output 'build.private.log')
    Assert-Rn ($LASTEXITCODE -eq 0) 'user_validation_server_build_failed'
} finally { Pop-Location }
foreach ($pin in $sourcePins) { Assert-RnPin $pin }
foreach ($pin in $bundle.files) { Assert-RnPin $pin }
Assert-RnPin $patchPin
Assert-RnPin $helperPin
$dll = Get-RnPin (Join-Path $buildOutput 'EpinelPS.dll')
$receipt = [ordered]@{
    contractId='nll/user-validation-server-build/v1'; bundleSha256=$ExpectedBundleSha256
    sourceManifest=$bundle.serverSourceManifest; sourceLoader=(Get-RnPin $source)
    patchedLoader=(Get-RnPin $target); versionHelper=$helperPin; patch=$patchPin
    buildConfiguration=(Get-RnPin $targets); candidateServerDll=$dll
    originalSourcePreserved=$true; installedBundlePreserved=$true; deployed=$false
    serverStarted=$false; gameStarted=$false; runtimeAdmissionStatusCode='not_assessed'
}
Write-RnNewJson (Join-Path $output 'build.receipt.json') $receipt
[ordered]@{contractId=$receipt.contractId;outputRoot=$output;serverDllSha256=$dll.sha256;deployed=$false;gameStarted=$false} | ConvertTo-Json -Compress
