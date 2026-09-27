[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [Parameter(Mandatory)][string]$MaterializerPath,
    [Parameter(Mandatory)][string]$CatalogPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedCatalogSha256,
    [Parameter(Mandatory)][string]$PythonPath,
    [Parameter(Mandatory)][string]$UnityPyRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [string]$NativeInputPlanPath = '',
    [string]$ExpectedNativeInputPlanSha256 = '',
    [string]$CatalogToolPath = '',
    [switch]$AllowLegacyPublication
)
# Creates a new private configuration only. Never installs, launches a game,
# connects to an account DB, changes the selected bundle or enables a worker.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Require([bool]$Value, [string]$Code) { if (-not $Value) { throw ('boss_pipeline_prepare_' + $Code) } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Plain([string]$Path) {
    Require ([IO.Path]::IsPathFullyQualified($Path) -and -not $Path.StartsWith('\\')) 'path_invalid'
    $value = [IO.Path]::GetFullPath($Path)
    Require (-not $value.Substring([IO.Path]::GetPathRoot($value).Length).Contains(':')) 'path_invalid'
    Require (-not ($value -imatch '^C:[\\/]NIKKE([\\/]|$)')) 'official_path_forbidden'
    for ($cursor = $value; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            Require (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse_forbidden'
        }
    }
    $value
}
Require ($PSVersionTable.PSVersion.Major -ge 7 -and $IsWindows) 'host_invalid'
$repository = Plain (Split-Path -Parent $PSScriptRoot)
$OutputRoot = Plain $OutputRoot
Require (-not (Test-Path -LiteralPath $OutputRoot)) 'output_exists'
Require ($OutputRoot.StartsWith($repository + '\artifacts\', [StringComparison]::OrdinalIgnoreCase)) 'output_scope_invalid'
$BundlePath = Plain $BundlePath
$MaterializerPath = Plain $MaterializerPath
$CatalogPath = Plain $CatalogPath
$PythonPath = Plain $PythonPath
$UnityPyRoot = Plain $UnityPyRoot
Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256 -and (Hash $CatalogPath) -ceq $ExpectedCatalogSha256) 'input_drifted'
$bundle = Get-Content -LiteralPath $BundlePath -Raw -Encoding UTF8 | ConvertFrom-Json
Require ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1') 'bundle_invalid'
$pins = @{}
function Add-Pin([string]$Path) {
    $path = Plain $Path
    if (-not $pins.ContainsKey($path)) { $pins[$path] = Hash $path }
}
foreach ($pin in $bundle.files) {
    $path = Plain ([string]$pin.path)
    Require ((Hash $path) -ceq $pin.sha256 -and (Get-Item -LiteralPath $path).Length -eq $pin.length) 'bundle_file_drifted'
}
$configPath = Plain (Join-Path $bundle.serverRoot 'gameconfig.json')
$staticPins = @($bundle.files | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ceq 'StaticData.pack' })
Require ($staticPins.Count -eq 1 -and @($bundle.files | Where-Object { $_.path -ieq $configPath }).Count -eq 1) 'bundle_inputs_ambiguous'
$staticPack = Plain ([string]$staticPins[0].path)
$catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
Require ($catalog.contractId -ceq 'nll/boss-season-catalog/v1' -and
    $catalog.sourceStaticDataSha256 -ceq (Hash $staticPack)) 'catalog_binding_invalid'
$worker = Join-Path $PSScriptRoot 'invoke-nll-boss-onboarding-job.ps1'
$shell = Plain (Join-Path $PSHOME 'pwsh.exe')
# No account data is needed: an unset synthetic manager uses exact unique
# profile observation resolution. This file is never a game/runtime account DB.
$seed = Join-Path $repository 'tests\fixtures\synthetic\boss-variant-discovery-seed.json'
foreach ($path in @($BundlePath, $CatalogPath, $staticPack, $configPath, $PythonPath, $shell, $worker, $seed, $PSCommandPath)) { Add-Pin $path }
foreach ($name in @('invoke-nll-boss-onboarding.ps1', 'Nll.BossPublication.ps1', 'inspect-nll-boss-behavior-assets.py',
        'materialize-nll-boss-runtime-profile.py', 'materialize-nll-shield-fx-candidate.py',
        'materialize-nll-shield-fx-transform-variant.py', 'verify-nll-boss-onboarding-candidate.py',
        'nll-shield-fx-assessment.py', 'nll-shield-fx-recipes.py', 'Nll.CommonBossDelivery.ps1')) {
    Add-Pin (Join-Path $PSScriptRoot $name)
}
$native = $null
$inventoryRoots = @((Split-Path -Parent $MaterializerPath), $UnityPyRoot)
if ($NativeInputPlanPath -or $ExpectedNativeInputPlanSha256 -or $CatalogToolPath) {
    $NativeInputPlanPath = Plain $NativeInputPlanPath
    $CatalogToolPath = Plain $CatalogToolPath
    Require ((Hash $NativeInputPlanPath) -ceq $ExpectedNativeInputPlanSha256) 'native_plan_drifted'
    $dotnet = Plain ((Get-Command dotnet -CommandType Application).Source)
    foreach ($path in @($NativeInputPlanPath, $CatalogToolPath, $dotnet)) { Add-Pin $path }
    foreach ($name in @('Nll.BossNativeCandidate.ps1', 'stage-nll-native-fx.py', 'materialize-nll-native-fx-layout.py',
            'acquire-nll-boss-fx.py', 'acquire-nll-boss-behavior.py')) {
        Add-Pin (Join-Path $PSScriptRoot $name)
    }
    $inventoryRoots += Split-Path -Parent $CatalogToolPath
    $native = [ordered]@{ inputPlanPath = $NativeInputPlanPath; inputPlanSha256 = $ExpectedNativeInputPlanSha256
        catalogToolPath = $CatalogToolPath; catalogToolSha256 = $pins[$CatalogToolPath]
        dotnetPath = $dotnet; dotnetSha256 = $pins[$dotnet] }
}
foreach ($root in $inventoryRoots) {
    $null = Plain $root
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        $null = Plain $item.FullName
        if (-not $item.PSIsContainer -and $item.Extension -cne '.pyc') { Add-Pin $item.FullName }
    }
}
Require ($pins.ContainsKey($MaterializerPath)) 'materializer_pin_missing'
foreach ($path in $pins.Keys) { Require ((Hash $path) -ceq $pins[$path]) 'input_drifted' }
$configuration = [ordered]@{
    schemaVersion = 1; contractId = 'nll/boss-pipeline-config/v1'; repositoryRoot = $repository
    catalogPath = $CatalogPath; catalogSha256 = $ExpectedCatalogSha256
    jobsRoot = Join-Path $OutputRoot 'jobs'; registryRoot = Join-Path $repository 'config\boss-runtime-variants'
    powerShellPath = $shell; powerShellSha256 = $pins[$shell]; workerSha256 = $pins[$worker]; timeoutSeconds = 1800
    materializerPath = $MaterializerPath; pythonPath = $PythonPath; staticDataPackPath = $staticPack
    gameConfigPath = $configPath; sourceDatabasePath = $seed; assetCacheRoot = Join-Path $bundle.serverRoot 'cache'
    unityPyRoot = $UnityPyRoot; allowLegacyPublication = [bool]$AllowLegacyPublication
    nativePipeline = $native
    inputPins = @($pins.Keys | Sort-Object | ForEach-Object { [ordered]@{ path = $_; sha256 = $pins[$_] } })
}
if ($bundle.PSObject.Properties.Name -contains 'commonBossRegistryRoot') {
    Require ($bundle.commonBossRegistryRoot -ceq 'C:\NLL\RuntimeInputs\CommonBossExecution\profiles') 'common_registry_invalid'
    $configuration.registryRoot = $bundle.commonBossRegistryRoot
    $configuration.commonDelivery = [ordered]@{ nativeStore = $bundle.commonNativeStore }
    $configuration.databaseConnectionStringEnvironmentVariable = 'NIKKE_LAB_DB'
}
$bytes = [Text.UTF8Encoding]::new($false).GetBytes(($configuration | ConvertTo-Json -Depth 8) + "`n")
Require ($bytes.Length -le 1048576) 'configuration_too_large'
$null = New-Item -ItemType Directory -Path $OutputRoot
$destination = Join-Path $OutputRoot 'configuration.private.json'
$stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
[ordered]@{ contractId = 'nll/boss-pipeline-configuration-preparation/v1'; configurationSha256 = Hash $destination
    inputFileCount = $pins.Count; originalClientExecuted = $false; operatingDatabaseTouched = $false
    workerEnabled = $false; registryModified = $false } | ConvertTo-Json -Compress
