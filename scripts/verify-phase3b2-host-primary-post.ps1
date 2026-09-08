[CmdletBinding()]
param(
    [string]$PrimaryRoot = "C:\NIKKE",
    [string]$BeforeManifestPath = "C:\Users\ccccc\AppData\Local\NikkeLocalLab\compatibility\evidence\phase3b2-wave1\assessment-74fedafe-55bc-4446-a2f0-01d5cc62eb3e\trusted\primary-before.manifest.tsv",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\PrimaryPost"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $algorithm.Dispose() }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$primary = [IO.Path]::GetFullPath($PrimaryRoot).TrimEnd('\')
$beforePath = [IO.Path]::GetFullPath($BeforeManifestPath)
$evidence = [IO.Path]::GetFullPath($EvidenceRoot)
Assert-True ($primary -ceq "C:\NIKKE") "phase3b2_primary_post_root_mismatch"
Assert-True (Test-Path -LiteralPath $primary -PathType Container) "phase3b2_primary_post_root_missing"
Assert-True (Test-Path -LiteralPath $beforePath -PathType Leaf) "phase3b2_primary_before_manifest_missing"
Assert-True (-not (Test-Path -LiteralPath $evidence)) "phase3b2_primary_post_evidence_exists"
New-Item -ItemType Directory -Path $evidence -Force | Out-Null

$paths = [Collections.Generic.List[string]]::new()
foreach ($path in [IO.Directory]::EnumerateFiles($primary, "*", [IO.SearchOption]::AllDirectories)) {
    $paths.Add($path)
}
$paths.Sort([StringComparer]::Ordinal)
$builder = [Text.StringBuilder]::new()
foreach ($path in $paths) {
    $relative = $path.Substring($primary.Length + 1).Replace('\', '/')
    $item = [IO.FileInfo]::new($path)
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $null = $builder.Append($relative).Append("`t").Append($item.Length).Append("`t").Append($hash).Append("`n")
}

$afterPath = Join-Path $evidence "primary-after.manifest.tsv"
Write-Utf8NoBom $afterPath $builder.ToString()
$beforeBytes = [IO.File]::ReadAllBytes($beforePath)
$afterBytes = [IO.File]::ReadAllBytes($afterPath)
$beforeSha256 = Get-Sha256Hex $beforeBytes
$afterSha256 = Get-Sha256Hex $afterBytes
Assert-True ($beforeBytes.Length -eq 5397209 -and
    $beforeSha256 -ceq "0e9aaf9c69399e81bc3887660f360bd97ae78d0f6a41a5f339fb629e6fa574b4") `
    "phase3b2_primary_before_manifest_pin_mismatch"
Assert-True ($afterBytes.Length -eq $beforeBytes.Length -and $afterSha256 -ceq $beforeSha256) `
    "phase3b2_primary_install_drift_detected"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-host-primary-post-verification/v1"
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    primaryInstallIntegrityStatusCode = "unchanged"
    fileCount = $paths.Count
    beforeManifestByteLength = $beforeBytes.Length
    beforeManifestSha256 = $beforeSha256
    afterManifestByteLength = $afterBytes.Length
    afterManifestSha256 = $afterSha256
}
$receiptPath = Join-Path $evidence "primary-post-verification.receipt.json"
Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
