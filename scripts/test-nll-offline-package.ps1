$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Nll.OfflinePackage.ps1')
$root = Join-Path (Split-Path -Parent $PSScriptRoot) ('artifacts/stabilization/package-tests/' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $root 'source/empty'), (Join-Path $root 'source/wwwroot/editor')
foreach ($name in @('index.html', 'editor.css', 'editor.js')) {
    [IO.File]::WriteAllText((Join-Path $root ('source/wwwroot/editor/' + $name)), 'synthetic-' + $name)
}
$tree = @(Get-NllPackageTree (Join-Path $root 'source'))
Copy-NllPackageTree (Join-Path $root 'source') (Join-Path $root 'copy') $tree
if ($tree.Count -ne 3 -or -not (Test-Path -LiteralPath (Join-Path $root 'copy/empty') -PathType Container)) { throw 'package_test_copy_failed' }
$delta = @(Get-NllPackageDelta $tree @())
if (@($delta | Where-Object { $_.action -ceq 'add' }).Count -ne 3) { throw 'package_test_add_failed' }
if (@(Get-NllPackageDelta $tree $tree | Where-Object { $_.action -cne 'unchanged' }).Count -ne 0) { throw 'package_test_unchanged_failed' }
$installedOnly = [ordered]@{ relativePath = 'local-only.png'; byteLength = 1; sha256 = 'a' * 64 }
if (@(Get-NllPackageDelta $tree (@($tree) + @($installedOnly))).Count -ne 3) { throw 'package_test_preservation_failed' }
[IO.File]::WriteAllText((Join-Path $root 'copy/wwwroot/editor/editor.css'), 'changed')
$changed = @(Get-NllPackageDelta @(Get-NllPackageTree (Join-Path $root 'copy')) $tree | Where-Object { $_.action -ceq 'replace' })
if ($changed.Count -ne 1 -or $changed[0].relativePath -cne 'wwwroot/editor/editor.css') { throw 'package_test_css_delta_failed' }
$caught = $false
try { Assert-NllPackageTree (Join-Path $root 'copy') $tree } catch { $caught = $_.Exception.Message -ceq 'offline_package_tree_changed' }
if (-not $caught) { throw 'package_test_tamper_not_detected' }
$caught = $false
try { Copy-NllPackageTree (Join-Path $root 'source') (Join-Path $root 'copy') $tree } catch { $caught = $_.Exception.Message -ceq 'offline_package_destination_exists' }
if (-not $caught) { throw 'package_test_overwrite_not_detected' }
$null = New-Item -ItemType Junction -Path (Join-Path $root 'source/junction') -Target (Join-Path $root 'copy')
$caught = $false
try { Get-NllPackageTree (Join-Path $root 'source') | Out-Null } catch { $caught = $_.Exception.Message -ceq 'offline_package_reparse_rejected' }
if (-not $caught) { throw 'package_test_reparse_not_detected' }
# Nonrecursive deletion of only the test junction itself; preserve both trees.
Remove-Item -LiteralPath (Join-Path $root 'source/junction')
Write-Output 'Offline package checks: 8 passed (synthetic files only).'
