param(
    [string]$MicronDrive = 'E:',
    [string]$SamsungOutputRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalReferenceTools-v1'
    )
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
        ([BitConverter]::ToString(
            $algorithm.ComputeHash($Bytes)
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$expectedPreflightSha256 = `
    'f6699da26a55c95ab0d5ed250930910896b098b245907ac73d852fd700f36b0a'
$preflightPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-preflight-v1\preflight.receipt.json'
$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$micronOutputRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-tools-v1'
$targetToolsRoot = Join-Path $MicronDrive 'NLL\Tools'

$names = @(
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1',
    'complete-phase3b2-epinel-minimal-reference-in-micron.ps1',
    'Start-Phase3B2-Epinel-Minimal.ps1',
    'Complete-Phase3B2-Epinel-Minimal.ps1'
)
$sources = @($names | ForEach-Object { Join-Path $PSScriptRoot $_ })
$targets = @($names | ForEach-Object { Join-Path $targetToolsRoot $_ })

Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    (Test-Path -LiteralPath $preflightPath -PathType Leaf) -and
    (Get-Sha256Hex $preflightPath) -ceq $expectedPreflightSha256 -and
    @($sources | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0 -and
    @($targets | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $micronOutputRoot) -and
    -not (Test-Path -LiteralPath $SamsungOutputRoot) -and
    (Get-Sha256Hex (Join-Path $serverRoot 'EpinelPS.dll')) -ceq `
        '25b7251f860518418ae8f50c59c311f25cf3a2615ded34a12f07ab845168bb38' -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0
) 'phase3b2_epinel_minimal_tool_deployment_input_invalid'

foreach ($source in $sources) {
    $errors = $null
    $tokens = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $source, [ref]$tokens, [ref]$errors
    ) | Out-Null
    Assert-True (@($errors).Count -eq 0) `
        'phase3b2_epinel_minimal_tool_deployment_parse_failed'
}

New-Item -ItemType Directory -Path $targetToolsRoot, $micronOutputRoot,
    $SamsungOutputRoot -Force | Out-Null
try {
    for ($index = 0; $index -lt $sources.Count; $index++) {
        Copy-Item -LiteralPath $sources[$index] -Destination $targets[$index]
    }

    $members = @(
        for ($index = 0; $index -lt $targets.Count; $index++) {
            Assert-True (
                (Get-Sha256Hex $targets[$index]) -ceq `
                    (Get-Sha256Hex $sources[$index])
            ) 'phase3b2_epinel_minimal_tool_deployment_copy_drift'
            [pscustomobject]@{
                roleCode = switch ($index) {
                    0 { 'reference_start' }
                    1 { 'reference_completion' }
                    2 { 'operator_start_wrapper' }
                    3 { 'operator_completion_wrapper' }
                }
                name = $names[$index]
                byteLength = (Get-Item -LiteralPath $targets[$index]).Length
                sha256 = Get-Sha256Hex $targets[$index]
            }
        }
    )
    $manifestLines = @($members | Sort-Object name | ForEach-Object {
        "$($_.name)`t$($_.byteLength)`t$($_.sha256)"
    })
    $manifestText = ($manifestLines -join "`n") + "`n"
    $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes($manifestText)
    $manifestSha256 = Get-BytesSha256Hex $manifestBytes

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-minimal-reference-tool-deployment/v1'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        preflightReceiptSha256 = $expectedPreflightSha256
        toolMemberCount = $members.Count
        toolManifestByteLength = $manifestBytes.Length
        toolManifestSha256 = $manifestSha256
        members = $members
        targetToolsRootAtMicronBoot = 'C:\NLL\Tools'
        operatorAccount = 'nlloperator'
        startCommand = `
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-Minimal.ps1'"
        completionRequiresClientClosedFirst = $true
        completionCommandTemplate = `
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
        globalServerSelectionRequired = $true
        repeatedStartProhibited = $true
        officialLauncherExecutionPermitted = $false
        officialOutboundFallbackPermitted = $false
        targetOsOfflineDuringDeployment = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_as_nlloperator_and_run_start_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    $micronManifestPath = Join-Path $micronOutputRoot 'tools.manifest.tsv'
    $samsungManifestPath = Join-Path $SamsungOutputRoot 'tools.manifest.tsv'
    $micronReceiptPath = Join-Path $micronOutputRoot `
        'tool-deployment.receipt.json'
    $samsungReceiptPath = Join-Path $SamsungOutputRoot `
        'tool-deployment.receipt.json'
    [IO.File]::WriteAllBytes($micronManifestPath, $manifestBytes)
    [IO.File]::WriteAllBytes($samsungManifestPath, $manifestBytes)
    Write-Utf8NoBom $micronReceiptPath $receiptText
    Write-Utf8NoBom $samsungReceiptPath $receiptText

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
        SamsungReceiptPath = $samsungReceiptPath
        SamsungReceiptSha256 = Get-Sha256Hex $samsungReceiptPath
    } | ConvertTo-Json -Depth 8
}
catch {
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    throw
}
