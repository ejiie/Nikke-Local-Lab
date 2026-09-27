# Exercise the coordinator's real resolver with synthetic assets only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDPreparation.ps1')
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'fx_closure_coordinator_parse_failed' }
foreach ($name in @('Assert-PhaseD', 'Get-Sha256Lower', 'Assert-PhaseDCacheArtifactIdentity')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-fx-closure-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $root 'candidate/acquired-fx'), (Join-Path $root 'cache')
$profile = 'a' * 64
$code = 'phase_d_boss_shield_fx_asset_closure_invalid'
function Pin([string]$Path) { [pscustomobject]@{ path=$Path; length=(Get-Item $Path).Length; sha256=Get-Sha256Lower $Path } }
function Save([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12)); Pin $Path }
function Publish($Rows) {
    $sealPin = Save (Join-Path $root 'candidate/seal.json') ([ordered]@{
        contractId='nll/boss-onboarding-verified-candidate/v1'; profileSha256=$profile; artifacts=@($Rows) })
    Save (Join-Path $root 'delivery.json') ([ordered]@{
        contractId='nll/common-boss-delivery/v1'; profileSha256=$profile; candidateSeal=$sealPin })
}
function Resolve($Bundle, $Delivery) {
    Assert-PhaseDCacheArtifactIdentity -CacheRoot (Join-Path $root 'cache') -ByteLength $Bundle.length `
        -Sha256 $Bundle.sha256 -FailureCode $code -CommonDelivery $Delivery -ProfileSha256 $profile
}
$script:checks = 0
function Rejected([scriptblock]$Action) {
    $caught = $false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -cne $code) { throw }; $caught = $true }
    if (-not $caught) { throw 'fx_closure_expected_rejection' }; $script:checks++
}
try {
    $rows = @([pscustomobject]@{ relativePath='fx-acquisition.receipt.json'; sha256=('b' * 64) })
    $bundles = @()
    foreach ($element in @('fire','water','wind','electric','iron')) {
        $path = Join-Path $root ('candidate/acquired-fx/' + $element + '.bundle')
        [IO.File]::WriteAllText($path, 'synthetic-' + $element)
        $pin = Pin $path; $bundles += $pin
        $rows += [pscustomobject]@{ relativePath=('acquired-fx/' + $element + '.bundle'); sha256=$pin.sha256 }
    }
    $delivery = Publish $rows
    # All five work with an empty legacy cache, including original reuse and
    # originals used to derive adjusted FX. No delivery/client writes occur.
    foreach ($bundle in $bundles) {
        if ((Resolve $bundle $delivery) -ne 1) { throw 'fx_closure_acquired_missing' }; $checks++
    }
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'candidate/acquired-behavior')
    $behaviorPath = Join-Path $root 'candidate/acquired-behavior/current.bundle'
    [IO.File]::WriteAllText($behaviorPath, 'synthetic-current-behavior')
    $behavior = Pin $behaviorPath
    $both = Publish @($rows + @(
        [pscustomobject]@{relativePath='behavior-acquisition.receipt.json';sha256=('d' * 64)},
        [pscustomobject]@{relativePath='acquired-behavior/current.bundle';sha256=$behavior.sha256}))
    $resolveBehavior = {
        Assert-PhaseDCacheArtifactIdentity -CacheRoot (Join-Path $root 'cache') -ByteLength $behavior.length `
            -Sha256 $behavior.sha256 -FailureCode $code -CommonDelivery $both -ProfileSha256 $profile -AssetRole behavior
    }
    if ((& $resolveBehavior) -ne 1 -or (Resolve $bundles[0] $both) -ne 1) { throw 'behavior_closure_acquired_missing' }
    $checks++
    Copy-Item $behaviorPath (Join-Path $root 'cache/old-behavior.bundle')
    [IO.File]::WriteAllText($behaviorPath, 'changed')
    Rejected $resolveBehavior
    # Even a valid legacy alias must not hide drift of a published acquisition.
    Copy-Item $bundles[0].path (Join-Path $root 'cache/legacy.bundle')
    $original = [IO.File]::ReadAllText($bundles[0].path)
    [IO.File]::WriteAllText($bundles[0].path, ('x' * $original.Length))
    Rejected { Resolve $bundles[0] $delivery }
    [IO.File]::WriteAllText($bundles[0].path, $original)
    $wrongSize = [pscustomobject]@{ sha256=$bundles[0].sha256; length=1 }
    Rejected { Resolve $wrongSize $delivery }
    $wrongPin = [pscustomobject]@{ path=$delivery.path; length=$delivery.length; sha256=('c' * 64) }
    Rejected { Resolve $bundles[0] $wrongPin }
    $delivery = Publish @($rows | Where-Object sha256 -CNE $bundles[0].sha256)
    Rejected { Resolve $bundles[0] $delivery }
    $rows[1].relativePath = 'acquired-fx/../../cache/legacy.bundle'
    $delivery = Publish $rows
    Rejected { Resolve $bundles[0] $delivery }
    $rows[1].relativePath = 'acquired-fx/fire.bundle'
    $delivery = Publish $rows
    [IO.File]::AppendAllText((Join-Path $root 'candidate/seal.json'), ' ')
    Rejected { Resolve $bundles[0] $delivery }
    $delivery = Publish $rows
    $script:profile = 'd' * 64
    Rejected { Resolve $bundles[0] $delivery }
    $script:profile = 'a' * 64
    # Pre-acquisition published profiles keep their exact cache identity path.
    $legacy = Publish @()
    if ((Resolve $bundles[0] $legacy) -ne 1 -or (Resolve $bundles[0] $null) -ne 1) { throw 'fx_closure_legacy_regressed' }
    $checks += 2
    Rejected { Resolve $bundles[1] $legacy }
    Write-Output "Coordinator FX closure: $checks synthetic checks passed."
}
finally {
    $full = [IO.Path]::GetFullPath($root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($full) -cnotmatch '^nll-fx-closure-[0-9a-f]{32}$') { throw 'fx_closure_cleanup_path_invalid' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
