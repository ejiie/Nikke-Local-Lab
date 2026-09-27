[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [switch]$OfflineVariants,
    [string]$SourceDatabasePath = '',
    [string]$StaticDataPackPath = '',
    [string]$PythonPath = 'python'
)

# Local-only: new ignored outputs, no deployment, listeners, client or PostgreSQL.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repository 'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer'
function Require([bool]$Value, [string]$Code) { if (-not $Value) { throw $Code } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256) 'boss_qte_bundle_drifted'
$bundle = Get-Content -LiteralPath $BundlePath -Raw | ConvertFrom-Json
Require ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1') 'boss_qte_bundle_invalid'
$referenceRoot = [IO.Path]::GetFullPath([string]$bundle.serverRoot)
Require (-not $referenceRoot.StartsWith('C:\NIKKE', [StringComparison]::OrdinalIgnoreCase)) 'boss_qte_official_path_rejected'
foreach ($pin in $bundle.files) {
    Require ((Hash $pin.path) -ceq $pin.sha256 -and
        (Get-Item -LiteralPath $pin.path).Length -eq $pin.length) 'boss_qte_bundle_file_drifted'
}
[xml]$project = Get-Content (Join-Path $projectRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.csproj') -Raw
foreach ($reference in $project.SelectNodes('//Reference')) {
    $path = Join-Path $referenceRoot ($reference.Include + '.dll')
    Require (@($bundle.files | Where-Object { [string]$_.path -ieq $path }).Count -eq 1) 'boss_qte_reference_unpinned'
}
$inputPins = @()
if ($OfflineVariants) {
    $configPath = Join-Path $referenceRoot 'gameconfig.json'
    foreach ($path in @($SourceDatabasePath, $StaticDataPackPath, $configPath)) {
        Require (-not [string]::IsNullOrWhiteSpace($path)) 'boss_qte_offline_input_missing'
        $resolved = (Get-Item -LiteralPath $path).FullName
        Require (-not $resolved.StartsWith('C:\NIKKE', [StringComparison]::OrdinalIgnoreCase)) 'boss_qte_official_path_rejected'
        $inputPins += @{ path = $resolved; sha256 = Hash $resolved }
    }
    foreach ($path in @($StaticDataPackPath, $configPath)) {
        $resolved = [IO.Path]::GetFullPath($path)
        Require (@($bundle.files | Where-Object { [string]$_.path -ieq $resolved }).Count -eq 1) 'boss_qte_offline_input_unpinned'
    }
}
$outputRoot = Join-Path $repository ('artifacts\boss-qte-checks\' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $outputRoot
$receipt = [ordered]@{
    contractId = 'nll/boss-qte-local-check/v1'; status = 'failed'
    bundleSha256 = $ExpectedBundleSha256; behavior = $null; shieldPatterns = $null; offlineVariants = @()
    originalClientExecuted = $false; operatingDatabaseTouched = $false; deployed = $false
}
try {
    Push-Location $projectRoot
    try {
        & dotnet build -c Release --no-restore "-p:EpinelReferenceRoot=$referenceRoot" -o (Join-Path $outputRoot 'materializer')
        Require ($LASTEXITCODE -eq 0) 'boss_qte_build_failed'
    } finally { Pop-Location }
    $exe = Join-Path $outputRoot 'materializer\NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
    $bindingLines = @(& $PythonPath -B (Join-Path $PSScriptRoot 'test-nll-boss-profile-binding.py') --materializer $exe)
    Require ($LASTEXITCODE -eq 0 -and $bindingLines.Count -eq 1) 'boss_profile_binding_behavior_failed'
    $receipt.profileBinding = $bindingLines[0] | ConvertFrom-Json
    $lines = @(& $exe --verify-boss-qte true)
    Require ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) 'boss_qte_behavior_failed'
    $receipt.behavior = $lines[0] | ConvertFrom-Json
    Require ($receipt.behavior.contractId -ceq 'nll/boss-qte-behavior-check/v1' -and
        $receipt.behavior.syntheticOnly -eq $true -and $receipt.behavior.passed -eq 37 -and
        $receipt.behavior.failed -eq 0) 'boss_qte_behavior_invalid'
    $patternLines = @(& $exe --verify-boss-shield-patterns true)
    Require ($LASTEXITCODE -eq 0 -and $patternLines.Count -eq 1) 'boss_shield_pattern_behavior_failed'
    $receipt.shieldPatterns = $patternLines[0] | ConvertFrom-Json
    Require ($receipt.shieldPatterns.contractId -ceq 'nll/boss-shield-pattern-check/v1' -and
        $receipt.shieldPatterns.syntheticOnly -eq $true -and $receipt.shieldPatterns.passed -eq 13 -and
        $receipt.shieldPatterns.failed -eq 0) 'boss_shield_pattern_behavior_invalid'
    if ($OfflineVariants) {
        foreach ($season in @(26, 29)) {
            $name = if ($season -eq 26) { 'providence' } else { 'mother-whale' }
            $profilePath = Join-Path $repository "config\boss-runtime-variants\season-$season-$name.json"
            $profileHash = Hash $profilePath
            foreach ($weakness in @('fire', 'water', 'wind', 'electric', 'iron')) {
                $prefix = Join-Path $outputRoot "s$season-$weakness"
                & $exe --create-static-data-variant ($prefix + '.pack') `
                    --source-db $SourceDatabasePath --game-config $configPath `
                    --boss-variant-profile $profilePath --weakness-code $weakness `
                    --source-static-pack $StaticDataPackPath --variant-static-pack ($prefix + '.pack') `
                    --variant-static-data-receipt ($prefix + '.receipt.json') | Out-Null
                Require ($LASTEXITCODE -eq 0) 'boss_qte_offline_variant_failed'
                $variant = Get-Content -LiteralPath ($prefix + '.receipt.json') -Raw | ConvertFrom-Json
                $changed = $weakness -cne 'iron'
                $expectedQte = if ($season -eq 29 -and $changed) { 5 } else { 0 }
                $expectedTables = if (-not $changed) { 0 } elseif ($season -eq 29) { 3 } else { 1 }
                $expectedOverlay = if ($season -eq 29 -and $weakness -cin @('fire', 'water', 'wind')) {
                    'pending_isolated_asset_overlay'
                } else { 'not_required' }
                Require ($variant.contractId -ceq 'nll/boss-affinity-static-data-variant/v1' -and
                    $variant.variantProfileSha256 -ceq $profileHash -and $variant.seasonNumber -eq $season -and
                    $variant.weaknessCode -ceq $weakness -and $variant.variantRequired -eq $changed -and
                    $variant.quickTimeEventAffinityContractVerified -eq ($season -eq 29) -and
                    $variant.modifiedQuickTimeEventRecordCount -eq $expectedQte -and
                    $variant.modifiedTableCount -eq $expectedTables -and
                    $variant.shieldFxTransformStatusCode -ceq $expectedOverlay -and
                    $variant.runtimeAdmissionStatusCode -ceq 'not_assessed' -and
                    $variant.modifiedElementRecordCount -eq 0 -and $variant.elementTablePreserved -eq $true -and
                    $variant.officialInstallModified -eq $false -and $variant.rawSourceIdentifierPersisted -eq $false -and
                    (Test-Path -LiteralPath ($prefix + '.pack')) -eq $changed) 'boss_qte_offline_receipt_invalid'
                if ($changed) {
                    Require ((Hash ($prefix + '.pack')) -ceq $variant.variantStaticDataSha256) 'boss_qte_variant_drifted'
                }
                $receipt.offlineVariants += @{
                    seasonNumber = $season; weaknessCode = $weakness; modifiedQteCount = $expectedQte
                    receiptSha256 = Hash ($prefix + '.receipt.json'); status = 'passed'
                }
            }
        }
    }
    foreach ($pin in $inputPins + @($bundle.files)) {
        Require ((Hash $pin.path) -ceq $pin.sha256) 'boss_qte_input_changed'
    }
    Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256) 'boss_qte_bundle_changed'
    $receipt.status = 'passed'
} finally {
    $receiptPath = Join-Path $outputRoot 'receipt.json'
    [IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Output "Boss QTE local receipt: $receiptPath"
}
