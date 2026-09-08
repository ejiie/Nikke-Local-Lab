[CmdletBinding()]
param([switch]$StageInputs)
# Offline, create-only staging for the no-game synthetic authentication smoke.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceHeader.ps1')
function Require([bool]$Condition, [string]$Code) { if (-not $Condition) { throw ('resource_probe_stage_' + $Code) } }
function Hash-File([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function No-Reparse([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) { Require (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse' }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function New-PrivateDirectory([string]$Path) {
    No-Reparse $Path
    Require (-not (Test-Path -LiteralPath $Path)) 'destination_exists'
    New-Item -ItemType Directory -Path $Path | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid)
    foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-New([string]$Path, [byte[]]$Bytes) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Write-Json([string]$Path, [object]$Value) { Write-New $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 10))) }
function Copy-New([string]$Source, [string]$Target) {
    No-Reparse $Source
    Require (-not (Test-Path -LiteralPath $Target)) 'file_exists'
    $expected = Hash-File $Source
    Copy-Item -LiteralPath $Source -Destination $Target
    Require ((Hash-File $Target) -ceq $expected -and (Hash-File $Source) -ceq $expected) 'copy_drift'
}
function Pin([string]$Path) { [ordered]@{ path=$Path; length=(Get-Item -LiteralPath $Path).Length; sha256=(Hash-File $Path) } }

$repository = 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab'
$serverSource = Join-Path $repository 'artifacts\resource-probe-151\epinel-server-v2'
$bootstrapSource = Join-Path $repository 'artifacts\resource-probe-151\bootstrap'
$sourceConfig = Join-Path $repository '.external\EpinelPS-151-candidate\EpinelPS\gameconfig.json'
$versionInputs = 'C:\NLL\Staging\ResourceVersionInputs\1f4366d1-b809-4260-9b9c-91b19a948254'
$versionInputReceiptSha256 = '3bba700167a804673689618298f67faa3aee9af4971b7dfd185a8491c2c5cd2e'
$localeSource = 'C:\NLL\Staging\ResourceProbeServerInputs\b32d5bae-bed8-4e82-b0ff-88530d8675a8'
$certificateSource = 'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9\site.pfx'
$publicRootSource = 'C:\NLL\EpinelPS\ServerSelector\myCA.cer'
$sailSource = 'C:\NLL\Runtime\PhysicalBootstrap-v2\artifact\sail_api_impl64.dll'
$pins = @(
    @($sourceConfig,'4e588fd4c51953d5eb99e6ec2def8bada6130458b8cdef35538ca58321f07d2e'),
    @((Join-Path $versionInputs 'StaticData.pack'),'6ba9b5302ff355d88a998eaec568fbe7a28ea483fe30ef84c05a68f1d3deb6bc'),
    @((Join-Path $versionInputs 'version-metadata.txt'),'df1d7403a5a24f16fb5eb59ba436c1f04236b691f95ef30634f22b92ed306856'),
    @($certificateSource,'2f330431fa83c68ae7a613cd0c7a1f35c51d54a66771c75073035c52a8e545df'),
    @($publicRootSource,'6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda'),
    @($sailSource,'8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d')
)
foreach ($pin in $pins) { No-Reparse $pin[0]; Require ((Hash-File $pin[0]) -ceq $pin[1]) 'source_hash_drift' }
foreach ($source in @($serverSource,$bootstrapSource,$localeSource)) { No-Reparse $source; Require (Test-Path -LiteralPath $source -PathType Container) 'build_missing' }
$localeNames = @('Locale_Bgm.lsc','Locale_Character.lsc','Locale_CharacterCostume.lsc','Locale_Item.lsc')
$localeHashes = @('069143db0a70be3947d8bb68ff19a4815efbd3a35fc00401bd0bf93d460fd925','d98b2a39cb8f198e3cb3766323965d94ac93941d3431abcd1c8b81cfddfb81bf','e7494e8de75bd5c249ec4c41a608988ed7850e14786de769c5e6a9437cd0dd11','f79f39dc15b9d783988328603871dc8dda947ee76cce350c402f0b4f6fa4859d')
for ($i=0; $i -lt 4; $i++) { Require ((Hash-File (Join-Path $localeSource $localeNames[$i])) -ceq $localeHashes[$i]) 'locale_drift' }
$config = Get-Content -LiteralPath $sourceConfig -Raw | ConvertFrom-Json
Require ($config.TargetVersion -ceq '151.8.5') 'build_invalid'
$coreLine = @(Get-Content -LiteralPath (Join-Path $versionInputs 'version-metadata.txt') | Where-Object { $_ -cmatch '^core:' })
Require ($coreLine.Count -eq 1) 'metadata_invalid'
$core = ($coreLine[0].Substring(5) -split ',')[0]
Require ($core -cmatch '^151\.[0-9]+\.b[0-9]+$') 'metadata_core_invalid'
$headerPlan = Get-NllResourceHeaderPlan -Config $config -SourceConfigSha256 (Hash-File $sourceConfig) `
    -InputDirectory $versionInputs -ExpectedAcquisitionReceiptSha256 $versionInputReceiptSha256 `
    -ExpectedMetadataSha256 (Hash-File (Join-Path $versionInputs 'version-metadata.txt')) -Platform 'StandaloneWindows64'
if (-not $StageInputs) { [ordered]@{status='auth_smoke_inputs_verified_not_staged'; clientStarted=$false; serverStarted=$false} | ConvertTo-Json; return }

$uid = [Guid]::NewGuid().ToString('D')
$server = Join-Path 'C:\NLL\Runtime\EpinelPS-151-ResourceProbe' $uid
$bootstrap = Join-Path 'C:\NLL\Runtime\ResourceProbeBootstrap' $uid
$evidence = Join-Path 'C:\NLL\Staging\ResourceProbeRuns' $uid
foreach ($directory in @($server,$bootstrap,$evidence)) { New-PrivateDirectory $directory }
foreach ($file in Get-ChildItem -LiteralPath $serverSource -File) {
    if ($file.Extension -in '.dll','.exe' -or $file.Name -in 'EpinelPS.deps.json','EpinelPS.runtimeconfig.json','gameversion.json','appsettings.json') {
        Copy-New $file.FullName (Join-Path $server $file.Name)
    }
}
foreach ($file in Get-ChildItem -LiteralPath $bootstrapSource -File) { if ($file.Extension -in '.dll','.exe','.json') { Copy-New $file.FullName (Join-Path $bootstrap $file.Name) } }
Copy-New $certificateSource (Join-Path $server 'site.pfx')
Copy-New $sailSource (Join-Path $bootstrap 'sail_api_impl64.dll')
Copy-New $publicRootSource (Join-Path $bootstrap 'trust-root.cer')
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateSource,'',[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
try { Write-New (Join-Path $bootstrap 'server.cer') $certificate.RawData } finally { $certificate.Dispose() }
# This diagnostic mapping comes from the acquired header, not an installed-version admission.
$config.ResourceCoreVersion = $core
$resourceUri = [UriBuilder]::new($config.ResourceBaseURL.Replace('{Platform}','StandaloneWindows64'))
$resourceUri.Port = 8443
$config.ResourceBaseURL = $resourceUri.Uri.AbsoluteUri.Replace('StandaloneWindows64','{Platform}')
Write-Json (Join-Path $server 'gameconfig.json') $config
$staticUri = [Uri]$config.StaticDataMpk.Url
$packTarget = Join-Path (Join-Path $server 'cache') $staticUri.AbsolutePath.TrimStart('/')
New-Item -ItemType Directory -Path (Split-Path -Parent $packTarget) | Out-Null
Copy-New (Join-Path $versionInputs 'StaticData.pack') $packTarget
Copy-NllResourceHeader -RuntimeRoot $server -Plan $headerPlan
$localeTarget = Join-Path $server 'cache\local-locale'
New-Item -ItemType Directory -Path $localeTarget | Out-Null
foreach ($name in $localeNames) { Copy-New (Join-Path $localeSource $name) (Join-Path $localeTarget $name) }
$secret = [byte[]]::new(15)
[Security.Cryptography.RandomNumberGenerator]::Fill($secret)
Write-Json (Join-Path $bootstrap 'synthetic-context.json') ([ordered]@{username=('synthetic-probe-' + $uid); password=[Convert]::ToBase64String($secret)})
[Array]::Clear($secret,0,$secret.Length)
$serverPins = @(Get-ChildItem -LiteralPath $server -Recurse -File | Sort-Object FullName | ForEach-Object { $pin=Pin $_.FullName; $pin.path=[IO.Path]::GetRelativePath($server,$_.FullName).Replace('\','/'); $pin })
Assert-NllResourceHeaderManifest -RuntimeRoot $server -Plan $headerPlan -Files $serverPins
Write-Json (Join-Path $server 'resource-probe-runtime.private.json') ([ordered]@{contractId='nll/epinel-resource-probe-runtime/v2'; assessmentUid=$uid; durationSeconds=60; files=$serverPins})
$bootstrapPins = @(Get-ChildItem -LiteralPath $bootstrap -File | Sort-Object FullName | ForEach-Object { Pin $_.FullName })
$clientExe = 'C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke.exe'
Require ((Hash-File $clientExe) -ceq '36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732') 'client_drift'
Write-Json (Join-Path $bootstrap 'bootstrap.private.json') ([ordered]@{contractId='nll/resource-probe-bootstrap/v1'; assessmentUid=$uid; durationSeconds=60; authOnly=$true; runtimeFiles=$bootstrapPins; clientFiles=@((Pin $clientExe))})
$receipt = [ordered]@{contractId='nll/resource-probe-auth-preparation/v2'; assessmentUid=$uid; status='auth_only_staged_not_started'
    sourceConfigSha256=(Hash-File $sourceConfig); versionInputReceiptSha256=$versionInputReceiptSha256
    versionHeaderSha256=$headerPlan.sha256; versionHeaderBytes=$headerPlan.length; versionHeaderCacheVerified=$true
    serverManifestSha256=(Hash-File (Join-Path $server 'resource-probe-runtime.private.json')); bootstrapManifestSha256=(Hash-File (Join-Path $bootstrap 'bootstrap.private.json'))
    serverFileCount=$serverPins.Count; bootstrapFileCount=$bootstrapPins.Count; clientStarted=$false; serverStarted=$false; productionDbModified=$false; nativeAdmission='not_evaluated'}
Write-Json (Join-Path $evidence 'auth-preparation.receipt.json') $receipt
$receipt | ConvertTo-Json
