[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateServerRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedServerSha256,
    [Parameter(Mandatory)][string]$CandidateRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$CandidateSealSha256,
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [Parameter(Mandatory)][string]$StaticDataPackPath,
    [Parameter(Mandatory)][string]$PythonPath,
    [Parameter(Mandatory)][string]$ProbePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedProbeSha256,
    [Parameter(Mandatory)][string[]]$CatalogPaths
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
function Require([bool]$Value, [string]$Code) { if (-not $Value) { throw $Code } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Save([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 16) + "`n"), [Text.UTF8Encoding]::new($false))
}
Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256 -and (Hash $ProbePath) -ceq $ExpectedProbeSha256) 'epinel_fx_input_drifted'
$bundle = Get-Content -LiteralPath $BundlePath -Raw | ConvertFrom-Json
Require ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1') 'epinel_fx_bundle_invalid'
$cache = Join-Path ([string]$bundle.serverRoot) 'cache'
$sourceRoot = [IO.Path]::GetFullPath($CandidateServerRoot).TrimEnd('\')
Require ($sourceRoot.StartsWith((Join-Path $repository 'artifacts\'), [StringComparison]::OrdinalIgnoreCase) -and
    (Hash (Join-Path $sourceRoot 'EpinelPS.dll')) -ceq $ExpectedServerSha256) 'epinel_fx_candidate_not_isolated'
Require (@($bundle.files | Where-Object { $_.path -ieq $StaticDataPackPath }).Count -eq 1) 'epinel_fx_pack_not_pinned'
$before = @{}
foreach ($pin in $bundle.files) {
    Require ((Hash $pin.path) -ceq $pin.sha256 -and (Get-Item -LiteralPath $pin.path).Length -eq $pin.length) 'epinel_fx_bundle_drifted'
    $before[[string]$pin.path] = [string]$pin.sha256
}
$before[$BundlePath] = $ExpectedBundleSha256
$before[$ProbePath] = $ExpectedProbeSha256
foreach ($path in $CatalogPaths) { $before[$path] = Hash $path }
foreach ($file in Get-ChildItem (Join-Path $repository 'config/boss-runtime-variants') -File) { $before[$file.FullName] = Hash $file.FullName }
$serverPins = @{}
foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
    $serverPins[$file.FullName.Substring($sourceRoot.Length + 1)] = Hash $file.FullName
}
Require (-not (Test-Path (Join-Path $sourceRoot 'execution-fx')) -and
    @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -eq 0) 'epinel_fx_source_links_or_delivery'
$root = Join-Path $repository ('artifacts/epinel-fx-checks/' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$receipt = [ordered]@{
    contractId = 'nll/epinel-fx-local-check/v1'; statusCode = 'failed'; probes = @(); catalogs = @()
    candidateServerSha256 = $ExpectedServerSha256; candidateSealSha256 = $CandidateSealSha256
    bundleSha256 = $ExpectedBundleSha256; bundleFileCount = @($bundle.files).Count
    productionProcessTreeVerified = $false; nativeClientExecuted = $false; deployed = $false
    operatingDatabaseTouched = $false; runtimeAdmissionStatusCode = 'not_assessed'
}
$oldPath = $env:PATH
try {
    foreach ($weakness in @('water', 'fire', 'wind')) {
        $runtime = Join-Path $root $weakness
        & robocopy $sourceRoot $runtime /E /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
        Require ($LASTEXITCODE -le 7) 'epinel_fx_copy_failed'
        foreach ($relative in $serverPins.Keys) { Require ((Hash (Join-Path $runtime $relative)) -ceq $serverPins[$relative]) 'epinel_fx_copy_drifted' }
        $delivery = Join-Path $runtime 'execution-fx'
        $lines = @(& $PythonPath -B (Join-Path $PSScriptRoot 'stage-nll-execution-fx.py') `
            --candidate-root $CandidateRoot --candidate-seal-sha256 $CandidateSealSha256 `
            --source-static-pack $StaticDataPackPath --asset-cache-root $cache --output-root $delivery `
            --execution-code ([guid]::NewGuid().ToString('N')) --weakness-code $weakness)
        Require ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) 'epinel_fx_stage_failed'
        $stage = $lines[0] | ConvertFrom-Json
        Save (Join-Path $root ($weakness + '.staging.json')) $stage
        $env:PATH=$runtime+';'+$oldPath
        $lines = @(& dotnet $ProbePath http $runtime $ExpectedServerSha256 $stage.manifestSha256)
        Require ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) 'epinel_fx_http_failed'
        $receipt.probes += ($lines[0] | ConvertFrom-Json)
        foreach ($catalog in $CatalogPaths) {
            $lines = @(& dotnet $ProbePath catalog $runtime $ExpectedServerSha256 $catalog $before[$catalog] `
                (Join-Path $delivery 'manifest.private.json') $stage.manifestSha256)
            Require ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) 'epinel_fx_catalog_failed'
            $receipt.catalogs += ($lines[0] | ConvertFrom-Json)
        }
        # This synchronous lab probe starts no child processes. Its exit is NOT a production tree proof.
        foreach ($attempt in 1..2) {
            $lines = @(& dotnet $ProbePath retire $runtime $ExpectedServerSha256 $stage.manifestSha256)
            Require ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) 'epinel_fx_retire_failed'
        }
        Require (-not (Test-Path (Join-Path $delivery '.lease')) -and
            @(Get-ChildItem -LiteralPath $delivery -Filter '*.bundle' -File).Count -eq 0) 'epinel_fx_cleanup_failed'
        foreach ($relative in $serverPins.Keys) { Require ((Hash (Join-Path $runtime $relative)) -ceq $serverPins[$relative]) 'epinel_fx_runtime_drifted' }
    }
    $receipt.statusCode = 'passed'
} finally {
    $env:PATH = $oldPath
    foreach ($path in $before.Keys) { Require ((Hash $path) -ceq $before[$path]) 'epinel_fx_installed_input_changed' }
    foreach ($relative in $serverPins.Keys) { Require ((Hash (Join-Path $sourceRoot $relative)) -ceq $serverPins[$relative]) 'epinel_fx_source_changed' }
    Save (Join-Path $root 'receipt.json') $receipt
}
Write-Output ('Epinel FX candidate checks: ' + $receipt.statusCode + '; receipt=' + (Join-Path $root 'receipt.json'))
