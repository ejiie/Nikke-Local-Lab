$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Extract only pure file/target functions. Never execute the installer's entrypoint.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'publish-nll-stabilization-release.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'release_test_parse_failed' }
foreach ($name in @('Pin','Plain-Ancestors','Target','Replace-Pinned')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-release-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$install = Join-Path $root 'installed'
$null = New-Item -ItemType Directory -Path $install
$checks = 0
function Assert-Test([bool]$Value) { if (-not $Value) { throw 'release_test_failed' }; $script:checks++ }
function Reject-Test([scriptblock]$Action) { $rejected=$false; try { & $Action | Out-Null } catch { $rejected=$true }; Assert-Test $rejected }
try {
    foreach ($relative in @('../outside','app/../../outside','app/file:stream','desktop\bad','secrets/private','postgresql/data/x')) { Reject-Test { Target $relative } }
    $candidate = Join-Path $root 'candidate'; $old = Join-Path $root 'old'
    [IO.File]::WriteAllText($candidate, 'new synthetic bytes')
    [IO.File]::WriteAllText($old, 'old synthetic bytes')
    $target = Target 'app/synthetic.dll'
    Replace-Pinned $candidate $target '' (Pin $candidate)
    Assert-Test ((Pin $target) -ceq (Pin $candidate))
    Reject-Test { Replace-Pinned $old $target '' (Pin $old) }
    Reject-Test { Replace-Pinned $old $target (Pin $old) (Pin $old) }
    Replace-Pinned $old $target (Pin $candidate) (Pin $old)
    Assert-Test ((Pin $target) -ceq (Pin $old))
    Reject-Test { Replace-Pinned $candidate $target (Pin $old) (Pin $old) }
    $lock = [IO.File]::Open($target, 'Open', 'Read', 'Read')
    try { Reject-Test { Replace-Pinned $candidate $target (Pin $old) (Pin $candidate) } }
    finally { $lock.Dispose() }
    Assert-Test ((Pin $target) -ceq (Pin $old))
    Assert-Test (@(Get-ChildItem -LiteralPath (Split-Path -Parent $target) -Filter '*.partial-*').Count -eq 0)
    Replace-Pinned $candidate $target (Pin $old) (Pin $candidate)
    Replace-Pinned $old $target (Pin $candidate) (Pin $old)
    Assert-Test ((Pin $target) -ceq (Pin $old))
    $startAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'start-nll-phase-d-control-center.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'release_test_start_parse_failed' }
    # Caller-owned stop requests must not be deleted anywhere in the host.
    Assert-Test (-not $startAst.Extent.Text.Contains('Remove-Item -LiteralPath $DesktopStopSignalPath'))
    $smokeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-nll-stabilization-installed.ps1'), [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0)
    $readDefinition=$smokeAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-SmokeBootstrapLines'},$true)
    . ([scriptblock]::Create($readDefinition.Extent.Text))
    $redirectPath=Join-Path $root 'synthetic-redirect.log'
    $writer=[IO.File]::Open($redirectPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes("synthetic log`nNLL_DESKTOP_BOOTSTRAP:c3ludGhldGlj`n")
        $writer.Write($bytes,0,$bytes.Length); $writer.Flush()
        # Negative control: the former reader fails against the still-open writer.
        Reject-Test { [IO.File]::ReadAllLines($redirectPath) }
        $lines=@(Read-SmokeBootstrapLines $redirectPath)
        Assert-Test ($lines.Count -eq 3 -and $lines[1] -ceq 'NLL_DESKTOP_BOOTSTRAP:c3ludGhldGlj')
        $bytes=[Text.Encoding]::UTF8.GetBytes(('x'*65537))
        $writer.Write($bytes,0,$bytes.Length); $writer.Flush()
        Reject-Test { Read-SmokeBootstrapLines $redirectPath }
    } finally { $writer.Dispose() }
}
finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notlike 'nll-release-test-*') { throw 'release_test_cleanup_path_invalid' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
"Release file behavior: $checks checks passed; synthetic files only, no installed application/DB/game."
