[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [Parameter(Mandatory)][string]$CandidateRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$CandidateSealSha256,
    [Parameter(Mandatory)][string]$StaticDataPackPath,
    [Parameter(Mandatory)][string]$PythonPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
function Require([bool]$Value, [string]$Code) { if (-not $Value) { throw $Code } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Save([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
}
Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256) 'execution_fx_bundle_drifted'
$bundle = Get-Content -LiteralPath $BundlePath -Raw | ConvertFrom-Json
Require ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1') 'execution_fx_bundle_invalid'
$cache = Join-Path ([string]$bundle.serverRoot) 'cache'
Require (-not $cache.StartsWith('C:\NIKKE', [StringComparison]::OrdinalIgnoreCase)) 'execution_fx_official_path_rejected'
Require (@($bundle.files | Where-Object {
    [IO.Path]::GetFullPath([string]$_.path) -ieq [IO.Path]::GetFullPath($StaticDataPackPath)
}).Count -eq 1) 'execution_fx_pack_not_pinned'
$before = @{}
foreach ($pin in $bundle.files) {
    Require ((Hash $pin.path) -ceq $pin.sha256 -and (Get-Item -LiteralPath $pin.path).Length -eq $pin.length) 'execution_fx_bundle_file_drifted'
    $before[[string]$pin.path] = [string]$pin.sha256
}
foreach ($file in Get-ChildItem (Join-Path $repository 'config/boss-runtime-variants') -File) { $before[$file.FullName] = Hash $file.FullName }
$before[$BundlePath] = $ExpectedBundleSha256
$root = Join-Path $repository ('artifacts/execution-fx-checks/' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$receipt = [ordered]@{
    contractId = 'nll/execution-fx-local-check/v1'; statusCode = 'failed'
    bundleSha256 = $ExpectedBundleSha256; candidateSealSha256 = $CandidateSealSha256
    bundleFileCount = @($bundle.files).Count; probes = @()
    originalClientExecuted = $false; operatingDatabaseTouched = $false; deployed = $false
    runtimeAdmissionStatusCode = 'not_assessed'
}
try {
    $project = Join-Path $repository 'tools/PhaseD/AssetDeliveryProbe/NikkeLocalLab.AssetDeliveryProbe.csproj'
    & dotnet restore $project --locked-mode
    Require ($LASTEXITCODE -eq 0) 'execution_fx_probe_restore_failed'
    & dotnet build $project -c Release --no-restore
    Require ($LASTEXITCODE -eq 0) 'execution_fx_probe_build_failed'
    $probe = Join-Path (Split-Path $project) 'bin/Release/net8.0/NikkeLocalLab.AssetDeliveryProbe.dll'
    foreach ($weakness in @('water', 'fire', 'wind')) {
        $output = Join-Path $root $weakness
        $lines = @(& $PythonPath -B (Join-Path $PSScriptRoot 'stage-nll-execution-fx.py') `
            --candidate-root $CandidateRoot --candidate-seal-sha256 $CandidateSealSha256 `
            --source-static-pack $StaticDataPackPath --asset-cache-root $cache --output-root $output `
            --execution-code ([guid]::NewGuid().ToString('N')) --weakness-code $weakness)
        Require ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) 'execution_fx_local_stage_failed'
        $stage = $lines[0] | ConvertFrom-Json
        $stagePath = Join-Path $root ($weakness + '.staging.receipt.json')
        Save $stagePath $stage
        $lines = @(& dotnet $probe $output $stagePath (Hash $stagePath))
        Require ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) 'execution_fx_local_http_failed'
        $result = $lines[0] | ConvertFrom-Json
        Require ($result.statusCode -ceq 'passed' -and $result.manifestSha256 -ceq $stage.manifestSha256) 'execution_fx_local_probe_invalid'
        $receipt.probes += $result
    }
    $receipt.statusCode = 'passed'
}
finally {
    try {
        foreach ($path in $before.Keys) { Require ((Hash $path) -ceq $before[$path]) 'execution_fx_local_input_changed' }
    }
    catch { $receipt.statusCode = 'failed'; throw }
    finally {
        Save (Join-Path $root 'receipt.json') $receipt
        Write-Output "Execution FX local receipt: $root\receipt.json"
    }
}
