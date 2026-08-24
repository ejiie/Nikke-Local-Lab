param(
    [string]$ExternalRepositoryRoot = (
        Join-Path $PSScriptRoot '..\.external\EpinelPS'
    ),
    [string]$ServerBuildRoot = (
        Join-Path $PSScriptRoot `
            '..\.external\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
    ),
    [string]$OutputRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalBuild-v2'
    ),
    [int]$SelectedManagerPassedCount = 64,
    [int]$HandlerIsolationPassedCount = 6
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($Bytes)
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

$expectedBase = '519c3db51ec24ca19307e93e85acde7885928a72'
$expectedHead = '504968cb7800a154f0f8e9aab6d171d640651192'
$expectedTree = '5752ffa481f1b619bc6ef4c1a065272892c1282c'
$expectedBranch = 'agent/phase3b2-season26-epinel-minimal'
$expectedManifestSha256 = `
    'a2ad30f684b4697266557a86a22dd770b39c6ce3ef90af740e86ea17f8308cc0'
$expectedExeSha256 = `
    'f7aa2dc342e93157b620408b887603f62188c8d4a3ad75e94ab3b5b76547bc2d'
$expectedDllSha256 = `
    '25b7251f860518418ae8f50c59c311f25cf3a2615ded34a12f07ab845168bb38'

$externalRepositoryRoot = (
    Resolve-Path -LiteralPath $ExternalRepositoryRoot
).Path
$serverBuildRoot = (Resolve-Path -LiteralPath $ServerBuildRoot).Path

Assert-True (
    -not (Test-Path -LiteralPath $OutputRoot)
) 'phase3b2_epinel_minimal_build_evidence_already_exists'

$git = Get-Command git.exe -ErrorAction Stop
$head = (
    & $git.Source -c "safe.directory=$externalRepositoryRoot" `
        -C $externalRepositoryRoot rev-parse HEAD
).Trim()
$tree = (
    & $git.Source -c "safe.directory=$externalRepositoryRoot" `
        -C $externalRepositoryRoot rev-parse 'HEAD^{tree}'
).Trim()
$branch = (
    & $git.Source -c "safe.directory=$externalRepositoryRoot" `
        -C $externalRepositoryRoot branch --show-current
).Trim()
$status = @(
    & $git.Source -c "safe.directory=$externalRepositoryRoot" `
        -C $externalRepositoryRoot status --porcelain
)
$null = & $git.Source -c "safe.directory=$externalRepositoryRoot" `
    -C $externalRepositoryRoot merge-base --is-ancestor $expectedBase $head
$baseIsAncestor = $LASTEXITCODE -eq 0

Assert-True ($head -ceq $expectedHead) `
    'phase3b2_epinel_minimal_head_mismatch'
Assert-True ($tree -ceq $expectedTree) `
    'phase3b2_epinel_minimal_tree_mismatch'
Assert-True ($branch -ceq $expectedBranch) `
    'phase3b2_epinel_minimal_branch_mismatch'
Assert-True ($status.Count -eq 0) `
    'phase3b2_epinel_minimal_checkout_dirty'
Assert-True $baseIsAncestor `
    'phase3b2_epinel_minimal_base_ancestry_invalid'

$configPath = Join-Path $serverBuildRoot 'gameconfig.json'
$exePath = Join-Path $serverBuildRoot 'EpinelPS.exe'
$dllPath = Join-Path $serverBuildRoot 'EpinelPS.dll'
$assetUtilPath = Join-Path $externalRepositoryRoot `
    'EpinelPS\Utils\AssetDownloadUtil.cs'

Assert-True (
    (Test-Path -LiteralPath $configPath -PathType Leaf) -and
    (Test-Path -LiteralPath $exePath -PathType Leaf) -and
    (Test-Path -LiteralPath $dllPath -PathType Leaf) -and
    (Test-Path -LiteralPath $assetUtilPath -PathType Leaf)
) 'phase3b2_epinel_minimal_build_shape_invalid'

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$assetUtilSource = Get-Content -LiteralPath $assetUtilPath -Raw -Encoding UTF8

Assert-True (
    $config.TargetVersion -ceq '150.6.9' -and
    $config.ResourceBaseURL -ceq `
        'https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/{Platform}' -and
    $config.ResourceCoreVersion -ceq '150.6.b15' -and
    [string]$config.ResourceDataPackVersion -ceq '651'
) 'phase3b2_epinel_minimal_gameconfig_pin_invalid'
Assert-True (
    $assetUtilSource.Contains('Results.Stream(') -and
    -not $assetUtilSource.Contains('NkdbDecryptor') -and
    -not $assetUtilSource.Contains('ProjectLocalCatalogPayload')
) 'phase3b2_epinel_minimal_raw_stream_contract_invalid'

$files = @(
    Get-ChildItem -LiteralPath $serverBuildRoot -File -Recurse |
        Where-Object {
            $candidatePrefix = `
                [IO.Path]::GetFullPath($serverBuildRoot).TrimEnd('\') + '\'
            $candidateRelative = $_.FullName.Substring(
                $candidatePrefix.Length
            ).Replace('\', '/')
            -not $candidateRelative.StartsWith(
                'publish/',
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            -not $candidateRelative.StartsWith(
                'cache/',
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            $candidateRelative -cne 'db.json'
        } |
        Sort-Object FullName
)
$prefix = [IO.Path]::GetFullPath($serverBuildRoot).TrimEnd('\') + '\'
$manifestLines = foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($prefix.Length).Replace('\', '/')
    $fileSha256 = Get-Sha256Hex $file.FullName
    "$relativePath`t$($file.Length)`t$fileSha256"
}
$manifestText = ($manifestLines -join "`n") + "`n"
$utf8 = [Text.UTF8Encoding]::new($false)
$manifestBytes = $utf8.GetBytes($manifestText)
$manifestSha256 = Get-BytesSha256Hex $manifestBytes
$exeSha256 = Get-Sha256Hex $exePath
$dllSha256 = Get-Sha256Hex $dllPath

Assert-True ($files.Count -eq 577) `
    'phase3b2_epinel_minimal_build_file_count_mismatch'
Assert-True ($manifestSha256 -ceq $expectedManifestSha256) `
    'phase3b2_epinel_minimal_manifest_hash_mismatch'
Assert-True ($exeSha256 -ceq $expectedExeSha256) `
    'phase3b2_epinel_minimal_exe_hash_mismatch'
Assert-True ($dllSha256 -ceq $expectedDllSha256) `
    'phase3b2_epinel_minimal_dll_hash_mismatch'
Assert-True (
    $SelectedManagerPassedCount -eq 64 -and
    $HandlerIsolationPassedCount -eq 6
) 'phase3b2_epinel_minimal_focused_test_count_invalid'

$parent = Split-Path -Parent $OutputRoot
$partialRoot = Join-Path $parent (
    '.EpinelMinimalBuild-v2.partial-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $partialRoot -Force | Out-Null

try {
    $manifestPath = Join-Path $partialRoot 'publish.manifest.tsv'
    [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-minimal-build/v2'
        sealedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        externalBase = $expectedBase
        externalHead = $head
        externalTree = $tree
        externalBranch = $branch
        checkoutClean = $true
        targetClientBuild = '150.6.9'
        resourceBaseCode = 'micron_150_b059c3f36c_platform'
        resourceCoreVersion = '150.6.b15'
        resourceDataPackVersion = '651'
        selectedManagerPassedCount = $SelectedManagerPassedCount
        handlerIsolationPassedCount = $HandlerIsolationPassedCount
        focusedTestFailedCount = 0
        rawCatalogTransportCode = 'opaque_file_stream_no_projection'
        deploymentShapeCode = 'release_build_output_excluding_runtime_state'
        buildFileCount = $files.Count
        buildContentByteLength = [long](
            ($files | Measure-Object Length -Sum).Sum
        )
        buildManifestByteLength = $manifestBytes.Length
        buildManifestSha256 = $manifestSha256
        epinelPsExeByteLength = (Get-Item -LiteralPath $exePath).Length
        epinelPsExeSha256 = $exeSha256
        epinelPsDllByteLength = (Get-Item -LiteralPath $dllPath).Length
        epinelPsDllSha256 = $dllSha256
        gameConfigByteLength = (Get-Item -LiteralPath $configPath).Length
        gameConfigSha256 = Get-Sha256Hex $configPath
        excludedPublishDirectory = $true
        excludedCacheDirectory = $true
        excludedRuntimeDatabase = $true
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'recover_micron_p2_cold_then_stage_raw_b15_catalog'
    }

    $receiptPath = Join-Path $partialRoot 'build.receipt.json'
    [IO.File]::WriteAllText(
        $receiptPath,
        (($receipt | ConvertTo-Json) + "`n"),
        $utf8
    )

    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Move-Item -LiteralPath $partialRoot -Destination $OutputRoot

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = Join-Path $OutputRoot 'build.receipt.json'
        ReceiptByteLength = (
            Get-Item -LiteralPath (Join-Path $OutputRoot 'build.receipt.json')
        ).Length
        ReceiptSha256 = Get-Sha256Hex (
            Join-Path $OutputRoot 'build.receipt.json'
        )
    } | ConvertTo-Json -Depth 6
}
catch {
    if (Test-Path -LiteralPath $partialRoot) {
        Remove-Item -LiteralPath $partialRoot -Recurse -Force
    }
    throw
}
