[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Nll.ResourcePreflight.ps1')
# Never read/change actual PlayerPrefs in these synthetic tests.
function Get-NllVoiceResourceSelection { [pscustomobject]@{ language = 'ko'; scope = 'minimal' } }
function Require-Failure([scriptblock]$Action, [string]$Code) {
    $caught = $false
    try { & $Action } catch {
        if ($_.Exception.Message -cne $Code) { throw }
        $caught = $true
    }
    if (-not $caught) { throw ('expected_failure_missing_' + $Code) }
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-resource-preflight-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $toolPath = Join-Path $testRoot 'synthetic-tool.ps1'
    Copy-Item -LiteralPath (Join-Path $repository 'tests/fixtures/synthetic/resource-preflight-tool.ps1') -Destination $toolPath
    foreach ($number in 1..5) { [IO.File]::WriteAllText((Join-Path $testRoot "synthetic-member-$number"), 'synthetic') }
    $receiptPath = Join-Path $testRoot 'input.receipt.json'
    $transportPath = Join-Path $testRoot 'transport.receipt.json'
    [IO.File]::WriteAllText($receiptPath, '{"voiceLanguage":"ko","downloadScope":"minimal"}')
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath).Hash.ToLowerInvariant()
    $toolHash = Get-NllResourcePreflightToolSetSha256 $toolPath
    Assert-NllResourceTransportBeforeClient $toolPath $receiptPath $receiptHash $toolHash $transportPath
    $evidence = Get-Content -LiteralPath $transportPath -Raw | ConvertFrom-Json
    if ($evidence.catalogPairCount -ne 5 -or $evidence.statusCode -cne 'verified' -or $evidence.actualPlayVerified) {
        throw 'synthetic_transport_evidence_invalid'
    }
    # Tool set includes these fixture files; rebind after creating its receipt.
    $toolHash = Get-NllResourcePreflightToolSetSha256 $toolPath
    Require-Failure { Assert-NllResourceTransportBeforeClient $toolPath $receiptPath ('0' * 64) $toolHash $transportPath } `
        'phase_d_resource_preflight_receipt_drifted'
    Require-Failure { Assert-NllResourceTransportBeforeClient $toolPath $receiptPath $receiptHash ('0' * 64) $transportPath } `
        'phase_d_resource_preflight_receipt_drifted'
    [IO.File]::WriteAllText($receiptPath, '{"voiceLanguage":"en","downloadScope":"minimal"}')
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath).Hash.ToLowerInvariant()
    $toolHash = Get-NllResourcePreflightToolSetSha256 $toolPath
    Require-Failure { Assert-NllResourceTransportBeforeClient $toolPath $receiptPath $receiptHash $toolHash $transportPath } `
        'phase_d_resource_voice_selection_changed'
    $executionText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1') -Raw
    if ($executionText.IndexOf('Invoke-NllResourceCatalogPreflight') -gt $executionText.IndexOf('New-Item -ItemType Directory -Path $runtimeRoot')) {
        throw 'synthetic_catalog_preflight_order_invalid'
    }
    if (-not $executionText.Contains('Assert-NllResourceTransportBeforeClient') -or
        -not $executionText.Contains('resource-loopback-preflight.receipt.json')) { throw 'synthetic_transport_integration_missing' }
    foreach ($path in @((Join-Path $PSScriptRoot 'Nll.ResourcePreflight.ps1'), (Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1'))) {
        $tokens = $null; $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'synthetic_script_parse_failed' }
    }
    'resource_preflight_synthetic_passed; game_started=false; registry_changed=false; database_changed=false'
}
finally {
    # Only exact immediate files generated in our unique temporary test folder.
    foreach ($file in [IO.Directory]::GetFiles($testRoot)) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($testRoot)
}
