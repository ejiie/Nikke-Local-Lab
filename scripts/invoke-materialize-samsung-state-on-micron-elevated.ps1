[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$materializer = Join-Path $PSScriptRoot 'materialize-samsung-project-state-on-micron.ps1'
if (-not (Test-Path -LiteralPath $materializer -PathType Leaf)) {
    throw 'micron_materialization_launcher_script_missing'
}

$runtimeRoot = Join-Path $PSScriptRoot 'PowerShell7'
$runtimeManifestPath = Join-Path $PSScriptRoot 'powershell7.content.manifest.tsv'
$runtimeReceiptPath = Join-Path $PSScriptRoot 'powershell7.staging.receipt.json'
if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container) -or
    -not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $runtimeReceiptPath -PathType Leaf)) {
    throw 'micron_materialization_launcher_powershell7_bundle_missing'
}
$runtimeReceipt = Get-Content -LiteralPath $runtimeReceiptPath -Raw | ConvertFrom-Json
$runtimeManifestSha256 = (Get-FileHash -LiteralPath $runtimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($runtimeReceipt.contractId -cne 'nll/samsung-to-micron-materializer-powershell7-staging/v1' -or
    $runtimeReceipt.manifestSha256 -cne $runtimeManifestSha256 -or
    $runtimeReceipt.invokeScriptSha256 -cne
        (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -or
    $runtimeReceipt.materializeScriptSha256 -cne
        (Get-FileHash -LiteralPath $materializer -Algorithm SHA256).Hash.ToLowerInvariant() -or
    $runtimeReceipt.allTargetMembersSha256Verified -ne $true) {
    throw 'micron_materialization_launcher_powershell7_receipt_invalid'
}
$runtimeRootFull = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\')
$manifestLines = @(Get-Content -LiteralPath $runtimeManifestPath -Encoding UTF8 | Where-Object { $_ })
if ($manifestLines.Count -ne [int]$runtimeReceipt.memberCount) {
    throw 'micron_materialization_launcher_powershell7_manifest_count_invalid'
}
$manifestKeys = @{}
$verifiedRuntimeByteLength = [long]0
foreach ($line in $manifestLines) {
    $parts = $line.Split("`t")
    $relativePath = [string]$parts[0]
    $normalizedRelativePath = $relativePath.Replace('\', '/')
    if ($parts.Count -ne 3 -or [IO.Path]::IsPathRooted($relativePath) -or
        $normalizedRelativePath -match '(^|/)\.\.(/|$)' -or $parts[1] -notmatch '^[0-9]+$' -or
        $parts[2] -notmatch '^[0-9a-f]{64}$') {
        throw 'micron_materialization_launcher_powershell7_manifest_row_invalid'
    }
    $manifestKey = $normalizedRelativePath.ToLowerInvariant()
    if ($manifestKeys.ContainsKey($manifestKey)) {
        throw 'micron_materialization_launcher_powershell7_manifest_duplicate_member'
    }
    $manifestKeys[$manifestKey] = $true
    $memberPath = [IO.Path]::GetFullPath((Join-Path $runtimeRootFull $normalizedRelativePath.Replace('/', '\')))
    if (-not $memberPath.StartsWith($runtimeRootFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $memberPath -PathType Leaf)) {
        throw 'micron_materialization_launcher_powershell7_member_missing'
    }
    $member = Get-Item -LiteralPath $memberPath -Force
    $memberSha256 = (Get-FileHash -LiteralPath $memberPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($member.Length -ne [long]$parts[1] -or $memberSha256 -cne $parts[2]) {
        throw 'micron_materialization_launcher_powershell7_member_drifted'
    }
    $verifiedRuntimeByteLength += [long]$member.Length
}
if ($verifiedRuntimeByteLength -ne [long]$runtimeReceipt.contentByteLength) {
    throw 'micron_materialization_launcher_powershell7_content_length_invalid'
}
$engine = Join-Path $runtimeRoot 'pwsh.exe'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
    throw 'micron_materialization_launcher_powershell7_engine_missing'
}
$payload = @"
`$ErrorActionPreference = 'Stop'
try {
    & '$materializer' *>&1 | Tee-Object -FilePath 'C:\Users\nlloperator\Desktop\NLL-Micron-Materialization.log.txt'
    Write-Host ''
    Write-Host 'MICRON MATERIALIZATION COMPLETED. Start Codex and verify threads before Samsung cleanup.' -ForegroundColor Green
}
catch {
    `$_ | Format-List * -Force
    Write-Host ''
    Write-Host 'MICRON MATERIALIZATION FAILED. Samsung sources remain the rollback copy.' -ForegroundColor Red
}
Read-Host 'Press Enter to close'
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
Start-Process -FilePath $engine -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
) | Out-Null
