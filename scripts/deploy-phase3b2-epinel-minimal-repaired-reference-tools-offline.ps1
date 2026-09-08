param(
    [string]$MicronDrive = 'E:',
    [string]$SamsungOutputRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalReferenceTools-v2'
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
    finally { $algorithm.Dispose() }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path, $Text, [Text.UTF8Encoding]::new($false)
    )
}

$expectedRepairReceiptSha256 = `
    'e8fc382f236075a3b96d73c200be9a07ff00536cba4122c2d12118ce98508e2a'
$expectedCurrentStartSha256 = `
    'e176730eabfb59de836c226b3537433ecc541a6a587469cca251361ee571e70e'
$expectedCurrentCompletionSha256 = `
    '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
$expectedServerExeSha256 = `
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedServerDllSha256 = `
    'ba46ae42b59c2058c7c8e5b02e31af1fe32a28e70d685f3a470e63adefc60cfc'

$repairReceiptPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-sampling-log-repair-v1\repair.receipt.json'
$activePointerPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\active-run.pointer.json'
$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$micronOutputRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-tools-v2'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\EpinelMinimalSamplingLogRepair-v1\tools-before-receipt-pin'
$startName = 'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$completeName = 'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$sources = @(
    (Join-Path $PSScriptRoot $startName),
    (Join-Path $PSScriptRoot $completeName)
)
$targets = @(
    (Join-Path $MicronDrive "NLL\Tools\$startName"),
    (Join-Path $MicronDrive "NLL\Tools\$completeName")
)

Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    (Test-Path -LiteralPath $repairReceiptPath -PathType Leaf) -and
    (Get-Sha256Hex $repairReceiptPath) -ceq `
        $expectedRepairReceiptSha256 -and
    @($sources + $targets | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0 -and
    (Get-Sha256Hex $targets[0]) -ceq $expectedCurrentStartSha256 -and
    (Get-Sha256Hex $targets[1]) -ceq `
        $expectedCurrentCompletionSha256 -and
    (Get-Sha256Hex (Join-Path $serverRoot 'EpinelPS.exe')) -ceq `
        $expectedServerExeSha256 -and
    (Get-Sha256Hex (Join-Path $serverRoot 'EpinelPS.dll')) -ceq `
        $expectedServerDllSha256 -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    -not (Test-Path -LiteralPath $micronOutputRoot) -and
    -not (Test-Path -LiteralPath $SamsungOutputRoot) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0
) 'phase3b2_epinel_minimal_repaired_tool_deployment_input_invalid'

foreach ($source in $sources) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $source, [ref]$tokens, [ref]$errors
    )
    Assert-True (@($errors).Count -eq 0) `
        'phase3b2_epinel_minimal_repaired_tool_parse_failed'
}

$repair = Get-Content -LiteralPath $repairReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $repair.contractId -ceq `
        'nll/phase3b2-epinel-minimal-sampling-log-repair/v1' -and
    $repair.deploymentApplied -and
    -not $repair.localAuthTokenLoggingEnabled -and
    -not $repair.rawSensitiveServerLogPersisted
) 'phase3b2_epinel_minimal_repaired_tool_repair_contract_invalid'

New-Item -ItemType Directory -Path $backupRoot, $micronOutputRoot,
    $SamsungOutputRoot -Force | Out-Null
try {
    Copy-Item -LiteralPath $targets[0] -Destination $backupRoot
    Copy-Item -LiteralPath $targets[1] -Destination $backupRoot
    for ($index = 0; $index -lt $sources.Count; $index++) {
        Copy-Item -LiteralPath $sources[$index] -Destination $targets[$index] `
            -Force
        Assert-True (
            (Get-Sha256Hex $sources[$index]) -ceq `
                (Get-Sha256Hex $targets[$index])
        ) 'phase3b2_epinel_minimal_repaired_tool_copy_drift'
    }

    $members = @(
        for ($index = 0; $index -lt $targets.Count; $index++) {
            [pscustomobject]@{
                roleCode = if ($index -eq 0) {
                    'reference_start_repair_pinned'
                } else { 'reference_completion_redacting' }
                name = [IO.Path]::GetFileName($targets[$index])
                byteLength = (Get-Item -LiteralPath $targets[$index]).Length
                sha256 = Get-Sha256Hex $targets[$index]
            }
        }
    )
    $lines = @($members | Sort-Object name | ForEach-Object {
        "$($_.name)`t$($_.byteLength)`t$($_.sha256)"
    })
    $manifestText = ($lines -join "`n") + "`n"
    $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes(
        $manifestText
    )
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-minimal-reference-tool-deployment/v2'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        repairReceiptSha256 = $expectedRepairReceiptSha256
        toolMemberCount = $members.Count
        toolManifestByteLength = $manifestBytes.Length
        toolManifestSha256 = Get-BytesSha256Hex $manifestBytes
        members = $members
        samplingContractCode = `
            'minimum_ten_samples_and_twenty_eight_seconds'
        localAuthTokenLoggingEnabled = $false
        serverLogDefenseInDepthRedactionEnabled = $true
        priorToolsPreserved = $true
        targetOsOfflineDuringDeployment = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = `
            'boot_micron_as_nlloperator_and_run_epinel_minimal_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    $micronManifestPath = Join-Path $micronOutputRoot 'tools.manifest.tsv'
    $samsungManifestPath = Join-Path $SamsungOutputRoot `
        'tools.manifest.tsv'
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
    throw
}
