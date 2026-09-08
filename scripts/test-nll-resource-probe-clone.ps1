$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'new-nll-resource-probe-clone.ps1')
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $tempBase ('nll-clone-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'NIKKE/game'),
    (Join-Path $fixtureRoot 'Unity/com_proximabeta_NIKKE/com.shiftup.patch/core'),
    (Join-Path $fixtureRoot 'Launcher') | Out-Null
try {
    $body = Join-Path $fixtureRoot 'NIKKE/game/synthetic.bin'
    [IO.File]::WriteAllBytes($body, [byte[]](1,2,3))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'NIKKE/game/debug.log'), 'synthetic excluded')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'Launcher/excluded.txt'), 'synthetic excluded')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'Unity/com_proximabeta_NIKKE/.lcv.dat'), 'synthetic excluded')
    $first = Get-NllClonePlan $fixtureRoot '151.8.5'
    Assert-NllClone ($first.fileCount -eq 1 -and $first.byteLength -eq 3) 'test_exclusion'
    Assert-NllClone ($first.members[0].relativePath -ceq 'NIKKE/game/synthetic.bin') 'test_relative'
    Assert-NllClone ((Get-NllClonePlan $fixtureRoot '151.8.5').planSha256 -ceq $first.planSha256) 'test_determinism'
    Assert-NllClone ((Get-NllClonePlan $fixtureRoot '150.6.9').planSha256 -cne $first.planSha256) 'test_label_binding'
    [IO.File]::WriteAllBytes($body, [byte[]](1,2,4))
    Assert-NllClone ((Get-NllClonePlan $fixtureRoot '151.8.5').planSha256 -cne $first.planSha256) 'test_content_drift'
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'NIKKE/game/extra.bin'), [byte[]](9))
    Assert-NllClone ((Get-NllClonePlan $fixtureRoot '151.8.5').fileCount -eq 2) 'test_added_member'
    Assert-NllClone (([IO.File]::ReadAllBytes($body) -join ',') -ceq '1,2,4') 'test_read_only'
    $errors = $null
    $tokens = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'new-nll-resource-probe-clone.ps1'),
        [ref]$tokens, [ref]$errors) | Out-Null
    Assert-NllClone ($errors.Count -eq 0) 'test_parse'
    Write-Output 'Resource clone: 8 synthetic checks passed; no installation reads, clone or network execution.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    Assert-NllClone ($resolved.StartsWith($tempBase + '\nll-clone-fixture-', [StringComparison]::OrdinalIgnoreCase)) 'fixture_cleanup_boundary'
    Assert-NllCloneNoReparse $resolved
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
