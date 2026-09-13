$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ControlCenterAppPackage.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-app-package-synthetic-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$checks = 0
function Check([bool]$Value) { if (-not $Value) { throw 'synthetic_app_package_assertion_failed' }; $script:checks++ }
function Fails([scriptblock]$Action, [string]$Code) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message.Contains($Code)); return }
    throw 'synthetic_app_package_expected_failure'
}
function TextFile([string]$Path, [string]$Text) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text)
}
function Fixture([string]$Name) {
    $case = Join-Path $root $Name
    $app = Join-Path $case 'app'
    $published = Join-Path $case 'published'
    foreach ($name in @('NikkeLocalLab.Admin.Api.dll','NikkeLocalLab.Admin.Api.deps.json',
        'NikkeLocalLab.Admin.Api.runtimeconfig.json','wwwroot/editor/index.html','wwwroot/editor/editor.js','wwwroot/editor/editor.css')) {
        TextFile (Join-Path $app $name) ('synthetic-before-' + $name)
        TextFile (Join-Path $published $name) ('synthetic-after-' + $name)
    }
    TextFile (Join-Path $app 'wwwroot/editor/presentation.json') 'synthetic-owned-presentation'
    TextFile (Join-Path $app 'wwwroot/editor/assets/portrait.png') 'synthetic-image-not-original'
    TextFile (Join-Path $published 'wwwroot/editor/presentation.json') 'must-not-replace'
    TextFile (Join-Path $published 'wwwroot/editor/assets/portrait.png') 'must-not-replace'
    TextFile (Join-Path $published 'wwwroot/editor/boss-seasons.js') 'synthetic-new-season-controller'
    TextFile (Join-Path $published 'wwwroot/editor/user-validation.js') 'synthetic-new-validation-controller'
    TextFile (Join-Path $published 'Synthetic.Added.dll') 'synthetic-new-dependency'
    [pscustomobject]@{ app = $app; published = $published; package = (Join-Path $case 'package') }
}
try {
    $f = Fixture 'round-trip'
    $before = @(Get-NllAppInventory $f.app)
    $prepared = New-NllControlCenterAppPackage $f.app $f.published $f.package
    Check (-not $prepared.installedFilesModified)
    Check (Test-NllAppInventory $before @(Get-NllAppInventory $f.app))
    $manifest = Read-NllControlCenterAppPackage $f.package $prepared.manifestSha256
    Check ($prepared.afterCount -eq $prepared.beforeCount + 3)
    foreach ($operation in @('apply','apply','restore','restore','apply','restore')) {
        $result = Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.app $operation
        Check ($result.statusCode -ceq 'verified' -and -not $result.nativeClientExecuted -and -not $result.operationalDatabaseTouched)
        $side = if ($operation -ceq 'apply') { 'after' } else { 'before' }
        Check (Test-NllAppInventory $manifest.$side @(Get-NllAppInventory $f.app))
        Check (([IO.File]::ReadAllText((Join-Path $f.app 'wwwroot/editor/presentation.json'))) -ceq 'synthetic-owned-presentation')
        Check (([IO.File]::ReadAllText((Join-Path $f.app 'wwwroot/editor/assets/portrait.png'))) -ceq 'synthetic-image-not-original')
    }
    Check (@(Get-ChildItem -LiteralPath (Join-Path $f.package 'retired-added') -File -Recurse).Count -eq 6)
    Check (-not (Test-Path -LiteralPath (Join-Path $f.app 'wwwroot/editor/boss-seasons.js')))
    Fails { Invoke-NllControlCenterAppPackage $f.package ('f' * 64) $f.app apply } 'manifest_drifted'
    Fails { Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.published apply } 'target_invalid'
    $lease = [IO.File]::Open((Join-Path $f.package '.operation.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Fails { Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.app apply } 'app_package_busy' }
    finally { $lease.Dispose() }

    $f = Fixture 'drift'
    $prepared = New-NllControlCenterAppPackage $f.app $f.published $f.package
    TextFile (Join-Path $f.app 'wwwroot/editor/editor.js') 'unrelated-local-change'
    $drifted = @(Get-NllAppInventory $f.app)
    Fails { Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.app apply } 'target_drifted'
    Fails { Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.app restore } 'target_drifted'
    Check (Test-NllAppInventory $drifted @(Get-NllAppInventory $f.app))

    $f = Fixture 'extra'
    $prepared = New-NllControlCenterAppPackage $f.app $f.published $f.package
    TextFile (Join-Path $f.app 'foreign.js') 'unrelated-file'
    Fails { Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.app apply } 'unexpected_target_file'
    Check (([IO.File]::ReadAllText((Join-Path $f.app 'foreign.js'))) -ceq 'unrelated-file')

    $f = Fixture 'partial'
    $prepared = New-NllControlCenterAppPackage $f.app $f.published $f.package
    # Simulate interruption between verified atomic replacements.
    $key = 'NikkeLocalLab.Admin.Api.dll'
    [IO.File]::Copy((Join-Path $f.package ('after/' + $key)), (Join-Path $f.app $key), $true)
    $null = Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.app restore
    $manifest = Read-NllControlCenterAppPackage $f.package $prepared.manifestSha256
    Check (Test-NllAppInventory $manifest.before @(Get-NllAppInventory $f.app))
    TextFile (Join-Path $f.package ('transfer-apply/' + $key)) 'foreign-partial'
    Fails { Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.app apply } 'partial_drifted'
    Check (([IO.File]::ReadAllText((Join-Path $f.package ('transfer-apply/' + $key)))) -ceq 'foreign-partial')

    $f = Fixture 'backup-drift'
    $prepared = New-NllControlCenterAppPackage $f.app $f.published $f.package
    TextFile (Join-Path $f.package 'before/NikkeLocalLab.Admin.Api.dll') 'bad-backup'
    Fails { Invoke-NllControlCenterAppPackage $f.package $prepared.manifestSha256 $f.app apply } 'package_drifted'

    $f = Fixture 'missing-ui'
    # Move only a newly created synthetic fixture to model an incomplete publish.
    [IO.File]::Move((Join-Path $f.published 'wwwroot/editor/boss-seasons.js'), (Join-Path $root 'synthetic-held.js'))
    Fails { New-NllControlCenterAppPackage $f.app $f.published $f.package } 'full_ui_bundle_required'
    Check (-not (Test-Path -LiteralPath $f.package))
    Fails { New-NllControlCenterAppPackage $f.app $f.published (Join-Path $f.app 'overlap') } 'output_overlaps_input'
    foreach ($relative in @('../outside','a/../b','/outside','a\b','a:stream','a//b','a./b')) {
        Fails { Get-NllAppMemberPath $f.app $relative } 'relative_path_invalid'
    }
    [ordered]@{ statusCode = 'passed'; assertions = $checks; syntheticFilesOnly = $true;
        nativeClientExecuted = $false; installedFilesModified = $false } | ConvertTo-Json
} finally {
    # This exact unique root was created by this test, never an installed tree.
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^nll-app-package-synthetic-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
