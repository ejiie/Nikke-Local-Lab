$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-ui-export-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'editor'
$target = Join-Path $root 'export'
$uid = '11111111-1111-4111-8111-111111111111'
$png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
$exporter = Join-Path $PSScriptRoot 'export-nll-ui-reuse-assets.ps1'
function Assert-ExportTest([bool]$Condition) { if (-not $Condition) { throw 'ui_export_test_failed' } }
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $source 'assets/characters'), (Join-Path $source 'assets/ui')
    foreach ($relative in @("assets/characters/$uid.png", 'assets/ui/star-empty.png', 'assets/ui/star-filled.png', 'assets/ui/evolve.png')) {
        [IO.File]::WriteAllBytes((Join-Path $source $relative), $png)
    }
    [IO.File]::WriteAllText((Join-Path $source 'account.private.json'), '{"mustNotBeExported":true}')
    $presentation = @{ contractId = 'nll/control-center-presentation/v1'; characters = @(@{ characterUid = $uid; displayName = 'Synthetic Character'; portraitPath = "/editor/assets/characters/$uid.png"; accountSecret = 'excluded-synthetic-field' }) }
    [IO.File]::WriteAllText((Join-Path $source 'presentation.json'), ($presentation | ConvertTo-Json -Depth 5))
    & $exporter -EditorRoot $source -OutputRoot $target
    $manifestText = Get-Content -Raw -LiteralPath (Join-Path $target 'manifest.private.json')
    $manifest = $manifestText | ConvertFrom-Json
    Assert-ExportTest (@($manifest.files).Count -eq 4 -and @($manifest.characters).Count -eq 1)
    Assert-ExportTest (@(Get-ChildItem -LiteralPath $target -Recurse -File).Count -eq 5 -and -not $manifestText.Contains('accountSecret'))
    $rejected = $false
    try { & $exporter -EditorRoot $source -OutputRoot $target } catch { $rejected = $_.Exception.Message -ceq 'ui_export_destination_must_be_new' }
    Assert-ExportTest $rejected
    [IO.File]::WriteAllText((Join-Path $source 'assets/ui/evolve.png'), 'not an image')
    $invalidTarget = Join-Path $root 'invalid'
    $rejected = $false
    try { & $exporter -EditorRoot $source -OutputRoot $invalidTarget } catch { $rejected = $_.Exception.Message -ceq 'ui_export_png_signature_invalid' }
    Assert-ExportTest ($rejected -and -not (Test-Path -LiteralPath $invalidTarget))
    Write-Output 'UI asset export: synthetic copy/hash, account exclusion, no overwrite and invalid-input checks passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Test-Path -LiteralPath $resolved) -and [IO.Path]::GetFileName($resolved).StartsWith('nll-ui-export-test-') -and
        [IO.Path]::GetDirectoryName($resolved) -eq [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
